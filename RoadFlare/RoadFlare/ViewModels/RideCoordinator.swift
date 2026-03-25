import Foundation
import os
import RidestrSDK

/// Orchestrates the ride lifecycle by delegating to focused sub-coordinators.
/// Views observe this coordinator's state; it delegates work to:
/// - LocationCoordinator: driver location broadcasts + key shares
/// - ChatCoordinator: in-ride messaging
/// - Ride flow logic: offer → acceptance → PIN → completion (inline, ~200 lines)
@Observable
@MainActor
final class RideCoordinator {
    // MARK: - Sub-Coordinators

    let location: LocationCoordinator
    let chat: ChatCoordinator

    // MARK: - Dependencies

    let relayManager: any RelayManagerProtocol
    private let keypair: NostrKeypair
    private let settings: UserSettings
    private let rideHistory: RideHistoryStore

    // MARK: - State Machine

    let stateMachine = RideStateMachine()

    // MARK: - Ride Data

    var currentFareEstimate: FareEstimate?
    var selectedPaymentMethod: PaymentMethod?
    var pickupLocation: Location?
    var destinationLocation: Location?
    var lastError: String?

    // MARK: - Ride Subscription Tracking

    private var acceptanceSubscriptionId: SubscriptionID?
    private var driverStateSubscriptionId: SubscriptionID?
    private var cancellationSubscriptionId: SubscriptionID?
    private var acceptanceTask: Task<Void, Never>?
    private var driverStateTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    private var processedPinActionTimestamps: Set<Int> = []

    // MARK: - Convenience Accessors (for views)

    var driversRepository: FollowedDriversRepository { location.driversRepository }
    var chatMessages: [(id: String, text: String, isMine: Bool, timestamp: Int)] { chat.chatMessages }

    init(relayManager: any RelayManagerProtocol, keypair: NostrKeypair,
         driversRepository: FollowedDriversRepository, settings: UserSettings,
         rideHistory: RideHistoryStore) {
        self.relayManager = relayManager
        self.keypair = keypair
        self.settings = settings
        self.rideHistory = rideHistory

        self.location = LocationCoordinator(
            relayManager: relayManager, keypair: keypair,
            driversRepository: driversRepository
        )
        self.chat = ChatCoordinator(relayManager: relayManager, keypair: keypair)

        restoreRideState()
    }

    // MARK: - Background Subscriptions (delegated)

    func startLocationSubscriptions() { location.startLocationSubscriptions() }
    func startKeyShareSubscription() { location.startKeyShareSubscription() }
    func publishFollowedDriversList() async { await location.publishFollowedDriversList() }
    func requestKeyRefresh(driverPubkey: String) async { await location.requestKeyRefresh(driverPubkey: driverPubkey) }
    func checkForStaleKeys() async { await location.checkForStaleKeys() }

    // MARK: - State Persistence

    func persistRideState() {
        RideStatePersistence.save(
            stateMachine: stateMachine,
            pickupLocation: pickupLocation,
            destinationLocation: destinationLocation,
            fareEstimate: currentFareEstimate,
            paymentMethod: selectedPaymentMethod,
            processedPinTimestamps: processedPinActionTimestamps
        )
    }

    func restoreRideState() {
        guard let saved = RideStatePersistence.load(),
              let driverPubkey = saved.driverPubkey,
              let confirmationId = saved.confirmationEventId,
              let restoredStage = RiderStage(rawValue: saved.stage) else { return }

        AppLogger.ride.info(" Restoring ride: stage=\(saved.stage), driver=\(driverPubkey.prefix(8))")

        stateMachine.restore(
            stage: restoredStage,
            offerEventId: saved.offerEventId,
            acceptanceEventId: saved.acceptanceEventId,
            confirmationEventId: confirmationId,
            driverPubkey: driverPubkey,
            pin: saved.pin,
            pinVerified: saved.pinVerified,
            paymentMethod: saved.paymentMethodRaw.flatMap { PaymentMethod(rawValue: $0) },
            fiatPaymentMethods: saved.fiatPaymentMethodsRaw.compactMap { PaymentMethod(rawValue: $0) }
        )

        if let lat = saved.pickupLat, let lon = saved.pickupLon {
            pickupLocation = Location(latitude: lat, longitude: lon, address: saved.pickupAddress)
        }
        if let lat = saved.destLat, let lon = saved.destLon {
            destinationLocation = Location(latitude: lat, longitude: lon, address: saved.destAddress)
        }
        if let raw = saved.paymentMethodRaw { selectedPaymentMethod = PaymentMethod(rawValue: raw) }
        if let fareStr = saved.fareUSD, let fareDecimal = Decimal(string: fareStr) {
            currentFareEstimate = FareEstimate(distanceMiles: 0, durationMinutes: 0, fareUSD: fareDecimal)
        }
        // Restore PIN dedup timestamps to prevent double-processing after app kill
        if let timestamps = saved.processedPinTimestamps {
            processedPinActionTimestamps = Set(timestamps)
        }

        subscribeToDriverState(driverPubkey: driverPubkey, confirmationEventId: confirmationId)
        chat.subscribeToChat(driverPubkey: driverPubkey, confirmationEventId: confirmationId)
        subscribeToCancellation(driverPubkey: driverPubkey, confirmationEventId: confirmationId)
        AppLogger.ride.info(" Ride restored at stage: \(restoredStage.rawValue)")
    }

    // MARK: - Send Ride Offer (Kind 3173)

    func sendRideOffer(
        driverPubkey: String, pickup: Location,
        destination: Location, fareEstimate: FareEstimate
    ) async {
        // Prevent concurrent ride starts
        guard stateMachine.stage == .idle else {
            AppLogger.ride.warning("sendRideOffer called while stage is \(self.stateMachine.stage.rawValue) — ignoring")
            return
        }
        do {
            let offerContent = RideOfferContent(
                fareEstimate: fareEstimate.fareUSD,
                destination: destination.approximate(),
                approxPickup: pickup.approximate(),
                rideRouteKm: fareEstimate.distanceMiles / 0.621371,
                rideRouteMin: fareEstimate.durationMinutes,
                destinationGeohash: destination.geohash(precision: GeohashPrecision.settlement).hash,
                paymentMethod: selectedPaymentMethod?.rawValue ?? "cash",
                fiatPaymentMethods: settings.paymentMethods.map(\.rawValue)
            )

            let offerEvent = try await RideshareEventBuilder.rideOffer(
                driverPubkey: driverPubkey,
                driverAvailabilityEventId: nil,
                content: offerContent,
                keypair: keypair
            )
            _ = try await relayManager.publish(offerEvent)

            self.pickupLocation = pickup
            self.destinationLocation = destination

            try stateMachine.startRide(
                offerEventId: offerEvent.id,
                driverPubkey: driverPubkey,
                paymentMethod: selectedPaymentMethod,
                fiatPaymentMethods: settings.paymentMethods
            )
            currentFareEstimate = fareEstimate
            subscribeToAcceptance(offerEventId: offerEvent.id, driverPubkey: driverPubkey)
        } catch {
            lastError = "Failed to send offer: \(error.localizedDescription)"
        }
    }

    // MARK: - Acceptance (Kind 3174)

    func subscribeToAcceptance(offerEventId: String, driverPubkey: String) {
        let subId = SubscriptionID("acceptance-\(offerEventId)")
        acceptanceSubscriptionId = subId
        acceptanceTask?.cancel()
        acceptanceTask = Task {
            do {
                let filter = NostrFilter.rideAcceptances(offerEventId: offerEventId)
                let stream = try await relayManager.subscribe(filter: filter, id: subId)
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    guard event.pubkey == driverPubkey else { continue }
                    let acceptance = try RideshareEventParser.parseAcceptance(event: event, keypair: keypair)
                    guard acceptance.status == "accepted" else { continue }
                    await handleAcceptance(acceptanceEventId: event.id, driverPubkey: driverPubkey)
                    break
                }
            } catch {
                lastError = "Acceptance subscription failed: \(error.localizedDescription)"
            }
        }
    }

    func handleAcceptance(acceptanceEventId: String, driverPubkey: String) async {
        do {
            _ = try stateMachine.handleAcceptance(acceptanceEventId: acceptanceEventId)

            let confirmEvent = try await RideshareEventBuilder.rideConfirmation(
                driverPubkey: driverPubkey,
                acceptanceEventId: acceptanceEventId,
                precisePickup: pickupLocation,
                keypair: keypair
            )
            _ = try await relayManager.publish(confirmEvent)
            stateMachine.markPrecisePickupShared()

            try stateMachine.recordConfirmation(confirmationEventId: confirmEvent.id)
            persistRideState()

            if let subId = acceptanceSubscriptionId { await relayManager.unsubscribe(subId) }

            subscribeToDriverState(driverPubkey: driverPubkey, confirmationEventId: confirmEvent.id)
            chat.subscribeToChat(driverPubkey: driverPubkey, confirmationEventId: confirmEvent.id)
            subscribeToCancellation(driverPubkey: driverPubkey, confirmationEventId: confirmEvent.id)
        } catch {
            lastError = "Failed to confirm ride: \(error.localizedDescription)"
        }
    }

    // MARK: - Driver State (Kind 30180)

    func subscribeToDriverState(driverPubkey: String, confirmationEventId: String) {
        let subId = SubscriptionID("driver-state-\(confirmationEventId)")
        driverStateSubscriptionId = subId
        driverStateTask?.cancel()
        driverStateTask = Task {
            do {
                let filter = NostrFilter.driverRideState(
                    driverPubkey: driverPubkey, confirmationEventId: confirmationEventId
                )
                let stream = try await relayManager.subscribe(filter: filter, id: subId)
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    await handleDriverStateEvent(event, confirmationEventId: confirmationEventId)
                }
            } catch {
                lastError = "Driver state subscription failed: \(error.localizedDescription)"
            }
        }
    }

    func handleDriverStateEvent(_ event: NostrEvent, confirmationEventId: String) async {
        do {
            let driverState = try RideshareEventParser.parseDriverRideState(event: event, keypair: keypair)
            let result = try stateMachine.handleDriverStateUpdate(
                eventId: event.id, confirmationId: confirmationEventId, driverState: driverState
            )

            if result != nil {
                for action in driverState.history where action.isPinSubmitAction {
                    guard !processedPinActionTimestamps.contains(action.at) else { continue }
                    // Safety cap — should never exceed maxPinAttempts in practice
                    guard processedPinActionTimestamps.count < 10 else { continue }
                    processedPinActionTimestamps.insert(action.at)
                    if let pinEncrypted = action.pinEncrypted,
                       let driverPubkey = stateMachine.driverPubkey {
                        await handlePinSubmission(
                            pinEncrypted: pinEncrypted,
                            driverPubkey: driverPubkey,
                            confirmationEventId: confirmationEventId
                        )
                    }
                }
            }

            persistRideState()

            if stateMachine.stage == .completed {
                await handleRideCompletion()
                RideStatePersistence.clear()
            }
        } catch {
            // Invalid state event, skip
        }
    }

    // MARK: - PIN Verification

    func handlePinSubmission(pinEncrypted: String, driverPubkey: String, confirmationEventId: String) async {
        do {
            let decryptedPin = try RideshareEventParser.decryptPin(
                pinEncrypted: pinEncrypted, driverPubkey: driverPubkey, keypair: keypair
            )
            let isCorrect = decryptedPin == stateMachine.pin
            stateMachine.recordPinVerification(verified: isCorrect)
            let currentAttempt = stateMachine.pinAttempts

            let action = RiderRideAction(
                type: "pin_verify", at: Int(Date.now.timeIntervalSince1970),
                locationType: nil, locationEncrypted: nil,
                status: isCorrect ? "verified" : "rejected", attempt: currentAttempt
            )
            stateMachine.addRiderAction(action)

            if isCorrect {
                try await Task.sleep(for: .milliseconds(1100))  // NIP-33 ordering
                var encryptedDest = ""
                if let dest = destinationLocation {
                    encryptedDest = try RideshareEventParser.encryptLocation(
                        location: dest, recipientPubkey: driverPubkey, keypair: keypair
                    )
                }
                let destAction = RiderRideAction(
                    type: "location_reveal", at: Int(Date.now.timeIntervalSince1970),
                    locationType: "destination", locationEncrypted: encryptedDest,
                    status: nil, attempt: nil
                )
                stateMachine.addRiderAction(destAction)
                stateMachine.markPreciseDestinationShared()
            }

            let stateEvent = try await RideshareEventBuilder.riderRideState(
                driverPubkey: driverPubkey, confirmationEventId: confirmationEventId,
                phase: isCorrect ? "verified" : "awaiting_pin",
                history: stateMachine.riderStateHistory, keypair: keypair
            )
            _ = try await relayManager.publish(stateEvent)

            if !isCorrect && stateMachine.pinAttempts >= RideConstants.maxPinAttempts {
                await cancelRide(reason: "PIN verification failed")
            }
        } catch {
            lastError = "PIN verification error: \(error.localizedDescription)"
        }
    }

    // MARK: - Cancel Ride (Kind 3179)

    func cancelRide(reason: String? = nil) async {
        guard let driverPubkey = stateMachine.driverPubkey else {
            stateMachine.reset()
            return
        }

        if let confirmationId = stateMachine.confirmationEventId {
            do {
                let event = try await RideshareEventBuilder.cancellation(
                    counterpartyPubkey: driverPubkey,
                    confirmationEventId: confirmationId,
                    reason: reason, keypair: keypair
                )
                _ = try await relayManager.publish(event)
            } catch { /* Best effort */ }
        }

        await cleanupRideSubscriptions()
        stateMachine.reset()
        chat.reset()
        currentFareEstimate = nil
        pickupLocation = nil
        destinationLocation = nil
        processedPinActionTimestamps = []
        RideStatePersistence.clear()
    }

    // MARK: - Cancellation Subscription

    func subscribeToCancellation(driverPubkey: String, confirmationEventId: String) {
        let subId = SubscriptionID("cancel-\(confirmationEventId)")
        cancellationSubscriptionId = subId
        cancellationTask?.cancel()
        cancellationTask = Task {
            do {
                let filter = NostrFilter.cancellations(
                    counterpartyPubkey: keypair.publicKeyHex,
                    confirmationEventId: confirmationEventId
                )
                let stream = try await relayManager.subscribe(filter: filter, id: subId)
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    let processed = stateMachine.handleCancellation(
                        eventId: event.id, confirmationId: confirmationEventId
                    )
                    if processed {
                        await cleanupRideSubscriptions()
                        chat.reset()
                    }
                }
            } catch { /* Non-fatal */ }
        }
    }

    // MARK: - Chat (delegated)

    func sendChatMessage(_ text: String) async {
        guard let driverPubkey = stateMachine.driverPubkey,
              let confirmationId = stateMachine.confirmationEventId else { return }
        await chat.sendChatMessage(text, driverPubkey: driverPubkey, confirmationEventId: confirmationId)
    }

    // MARK: - Ride Completion

    func handleRideCompletion() async {
        if let driverPubkey = stateMachine.driverPubkey,
           let confirmationId = stateMachine.confirmationEventId {
            let pickup = pickupLocation ?? Location(latitude: 0, longitude: 0)
            let destination = destinationLocation ?? Location(latitude: 0, longitude: 0)
            let entry = RideHistoryEntry(
                id: confirmationId, date: .now,
                counterpartyPubkey: driverPubkey,
                counterpartyName: driversRepository.cachedDriverName(pubkey: driverPubkey),
                pickupGeohash: ProgressiveReveal.historyGeohash(for: pickup),
                dropoffGeohash: ProgressiveReveal.historyGeohash(for: destination),
                pickup: pickup, destination: destination,
                fare: currentFareEstimate?.fareUSD ?? 0,
                paymentMethod: selectedPaymentMethod?.rawValue ?? "cash",
                distance: currentFareEstimate?.distanceMiles,
                duration: currentFareEstimate.map { Int($0.durationMinutes) }
            )
            rideHistory.addRide(entry)
        }
        await cleanupRideSubscriptions()
    }

    // MARK: - Cleanup

    func cleanupRideSubscriptions() async {
        acceptanceTask?.cancel()
        driverStateTask?.cancel()
        cancellationTask?.cancel()
        await chat.cleanup()

        if let id = acceptanceSubscriptionId { await relayManager.unsubscribe(id) }
        if let id = driverStateSubscriptionId { await relayManager.unsubscribe(id) }
        if let id = cancellationSubscriptionId { await relayManager.unsubscribe(id) }

        acceptanceSubscriptionId = nil
        driverStateSubscriptionId = nil
        cancellationSubscriptionId = nil
    }

    func stopAll() async {
        await cleanupRideSubscriptions()
        await location.stopAll()
    }
}

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
    struct StageTimeouts: Equatable, Sendable {
        let waitingForAcceptance: TimeInterval
        let driverAccepted: TimeInterval

        nonisolated static let interopDefault = StageTimeouts(
            waitingForAcceptance: TimeInterval(RideStatePersistence.interopOfferVisibilitySeconds),
            driverAccepted: TimeInterval(RideStatePersistence.interopConfirmationWaitSeconds)
        )
    }

    // MARK: - Sub-Coordinators

    let location: LocationCoordinator
    let chat: ChatCoordinator

    // MARK: - Dependencies

    let relayManager: any RelayManagerProtocol
    private let keypair: NostrKeypair
    private let settings: UserSettings
    private let rideHistory: RideHistoryStore
    private let bitcoinPrice: BitcoinPriceService
    private let roadflareDomainService: RoadflareDomainService?
    private let roadflareSyncStore: RoadflareSyncStateStore?

    // MARK: - State Machine

    let stateMachine = RideStateMachine()

    // MARK: - Ride Data

    var currentFareEstimate: FareEstimate?
    var selectedPaymentMethod: String?
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
    private var stageTimeoutTask: Task<Void, Never>?
    private var processedPinActionKeys: Set<String> = []
    private var inFlightPinActionKeys: Set<String> = []
    private var confirmationPublishInFlight = false
    private let stageTimeouts: StageTimeouts

    // MARK: - Convenience Accessors (for views)

    var driversRepository: FollowedDriversRepository { location.driversRepository }
    var chatMessages: [(id: String, text: String, isMine: Bool, timestamp: Int)] { chat.chatMessages }
    var activeRidePaymentMethods: [String] {
        if !stateMachine.fiatPaymentMethods.isEmpty {
            return stateMachine.fiatPaymentMethods
        }
        if let paymentMethod = stateMachine.paymentMethod {
            return [paymentMethod]
        }
        return []
    }

    init(relayManager: any RelayManagerProtocol, keypair: NostrKeypair,
         driversRepository: FollowedDriversRepository, settings: UserSettings,
         rideHistory: RideHistoryStore, bitcoinPrice: BitcoinPriceService? = nil,
         roadflareDomainService: RoadflareDomainService? = nil,
         roadflareSyncStore: RoadflareSyncStateStore? = nil,
         stageTimeouts: StageTimeouts = .interopDefault) {
        self.relayManager = relayManager
        self.keypair = keypair
        self.settings = settings
        self.rideHistory = rideHistory
        self.bitcoinPrice = bitcoinPrice ?? BitcoinPriceService()
        self.roadflareDomainService = roadflareDomainService
        self.roadflareSyncStore = roadflareSyncStore
        self.stageTimeouts = stageTimeouts

        self.location = LocationCoordinator(
            relayManager: relayManager, keypair: keypair,
            driversRepository: driversRepository,
            roadflareDomainService: roadflareDomainService,
            roadflareSyncStore: roadflareSyncStore
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

    func persistRideState(persistDriverStateCursor: Bool = true) {
        RideStatePersistence.save(
            stateMachine: stateMachine,
            pickupLocation: pickupLocation,
            destinationLocation: destinationLocation,
            fareEstimate: currentFareEstimate,
            paymentMethod: selectedPaymentMethod,
            processedPinActionKeys: processedPinActionKeys,
            persistDriverStateCursor: persistDriverStateCursor
        )
    }

    func restoreRideState() {
        guard let saved = RideStatePersistence.load(),
              let driverPubkey = saved.driverPubkey,
              let restoredStage = RiderStage(rawValue: saved.stage) else { return }

        let requiresConfirmationId: Bool = {
            switch restoredStage {
            case .waitingForAcceptance, .driverAccepted:
                return false
            default:
                return true
            }
        }()
        guard !requiresConfirmationId || saved.confirmationEventId != nil else { return }

        AppLogger.ride.info(" Restoring ride: stage=\(saved.stage), driver=\(driverPubkey.prefix(8))")

        stateMachine.restore(
            stage: restoredStage,
            offerEventId: saved.offerEventId,
            acceptanceEventId: saved.acceptanceEventId,
            confirmationEventId: requiresConfirmationId ? saved.confirmationEventId : nil,
            driverPubkey: driverPubkey,
            pin: saved.pin,
            pinAttempts: saved.pinAttempts ?? 0,
            pinVerified: saved.pinVerified,
            paymentMethod: saved.paymentMethodRaw,
            fiatPaymentMethods: saved.fiatPaymentMethodsRaw,
            precisePickupShared: saved.precisePickupShared ?? false,
            preciseDestinationShared: saved.preciseDestinationShared ?? false,
            lastDriverStatus: saved.lastDriverStatus,
            lastDriverStateTimestamp: saved.lastDriverStateTimestamp ?? 0,
            lastDriverActionCount: saved.lastDriverActionCount ?? 0,
            riderStateHistory: saved.riderStateHistory ?? []
        )

        if let lat = saved.pickupLat, let lon = saved.pickupLon {
            pickupLocation = Location(latitude: lat, longitude: lon, address: saved.pickupAddress)
        }
        if let lat = saved.destLat, let lon = saved.destLon {
            destinationLocation = Location(latitude: lat, longitude: lon, address: saved.destAddress)
        }
        selectedPaymentMethod = saved.paymentMethodRaw
        if let fareStr = saved.fareUSD, let fareDecimal = Decimal(string: fareStr) {
            currentFareEstimate = FareEstimate(
                distanceMiles: saved.fareDistanceMiles ?? 0,
                durationMinutes: saved.fareDurationMinutes ?? 0,
                fareUSD: fareDecimal
            )
        }
        // Restore PIN dedup keys to prevent double-processing after app kill.
        if let actionKeys = saved.processedPinActionKeys {
            processedPinActionKeys = Set(actionKeys)
        } else if let timestamps = saved.processedPinTimestamps {
            processedPinActionKeys = Set(timestamps.map(Self.legacyPinActionKey))
        }
        AppLogger.ride.info(" Ride restored at stage: \(restoredStage.rawValue)")
        scheduleStageTimeout(savedAt: saved.savedAt)
    }

    /// Restore all live subscriptions after app launch, foreground reconnect, or manual reconnect.
    /// Safe to call repeatedly.
    func restoreLiveSubscriptions() async {
        await cleanupRideSubscriptions()
        location.startLocationSubscriptions()
        location.startKeyShareSubscription()
        async let staleKeyRefresh: Void = driversRepository.hasDrivers
            ? location.checkForStaleKeys()
            : ()

        if let driverPubkey = stateMachine.driverPubkey {
            switch stateMachine.stage {
            case .waitingForAcceptance:
                if let offerEventId = stateMachine.offerEventId {
                    subscribeToAcceptance(offerEventId: offerEventId, driverPubkey: driverPubkey)
                }

            case .driverAccepted:
                if stateMachine.confirmationEventId == nil,
                   let acceptanceEventId = stateMachine.acceptanceEventId {
                    if await recoverExistingConfirmationIfNeeded(
                        driverPubkey: driverPubkey,
                        acceptanceEventId: acceptanceEventId
                    ) {
                        _ = await staleKeyRefresh
                        return
                    }
                    await ensureConfirmationPublished(
                        driverPubkey: driverPubkey,
                        acceptanceEventId: acceptanceEventId
                    )
                }

            case .rideConfirmed, .enRoute, .driverArrived, .inProgress:
                if let confirmationEventId = stateMachine.confirmationEventId {
                    restoreConfirmedRideSubscriptions(
                        driverPubkey: driverPubkey,
                        confirmationEventId: confirmationEventId
                    )
                }

            default:
                break
            }
        }

        _ = await staleKeyRefresh
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
            // Protocol prices in sats. Convert USD → sats using live BTC price.
            guard let fareSatsInt = bitcoinPrice.usdToSats(fareEstimate.fareUSD) else {
                lastError = "Bitcoin price not available. Try again in a moment."
                return
            }
            AppLogger.ride.info("Sending offer: $\(fareEstimate.fareUSD) USD = \(fareSatsInt) sats (BTC=$\(self.bitcoinPrice.btcPriceUsd ?? 0))")
            let paymentPreferences = RoadflarePaymentPreferences(methods: settings.roadflarePaymentMethods)
            let primaryPaymentMethod = selectedPaymentMethod ?? paymentPreferences.primaryMethod ?? PaymentMethod.cash.rawValue

            let offerContent = RideOfferContent(
                fareEstimate: Double(fareSatsInt),
                destination: destination.approximate(),
                approxPickup: pickup.approximate(),
                rideRouteKm: fareEstimate.distanceMiles / 0.621371,
                rideRouteMin: fareEstimate.durationMinutes,
                destinationGeohash: destination.geohash(precision: GeohashPrecision.settlement).hash,
                paymentMethod: primaryPaymentMethod,
                fiatPaymentMethods: paymentPreferences.methods
            )

            let offerEvent = try await RideshareEventBuilder.rideOffer(
                driverPubkey: driverPubkey,
                driverAvailabilityEventId: nil,
                content: offerContent,
                keypair: keypair
            )
            _ = try await relayManager.publish(offerEvent)

            selectedPaymentMethod = primaryPaymentMethod
            self.pickupLocation = pickup
            self.destinationLocation = destination

            try stateMachine.startRide(
                offerEventId: offerEvent.id,
                driverPubkey: driverPubkey,
                paymentMethod: primaryPaymentMethod,
                fiatPaymentMethods: paymentPreferences.methods
            )
            currentFareEstimate = fareEstimate
            persistRideState()
            scheduleStageTimeout()
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
                let filter = NostrFilter.rideAcceptances(
                    offerEventId: offerEventId,
                    riderPubkey: keypair.publicKeyHex,
                    driverPubkey: driverPubkey
                )
                let stream = try await relayManager.subscribe(filter: filter, id: subId)
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    do {
                        let acceptance = try RideshareEventParser.parseAcceptance(
                            event: event,
                            keypair: keypair,
                            expectedDriverPubkey: driverPubkey,
                            expectedOfferEventId: offerEventId
                        )
                        guard acceptance.status == "accepted" else { continue }
                        await handleAcceptance(acceptanceEventId: event.id, driverPubkey: driverPubkey)
                        if stateMachine.confirmationEventId != nil {
                            break
                        }
                    } catch {
                        continue
                    }
                }
            } catch {
                lastError = "Acceptance subscription failed: \(error.localizedDescription)"
            }
        }
    }

    func handleAcceptance(acceptanceEventId: String, driverPubkey: String) async {
        do {
            switch stateMachine.stage {
            case .waitingForAcceptance:
                _ = try stateMachine.handleAcceptance(acceptanceEventId: acceptanceEventId)
                persistRideState()
                scheduleStageTimeout()
            case .driverAccepted:
                guard stateMachine.acceptanceEventId == acceptanceEventId,
                      stateMachine.confirmationEventId == nil,
                      stateMachine.driverPubkey == driverPubkey else { return }
            default:
                return
            }
            await ensureConfirmationPublished(
                driverPubkey: driverPubkey,
                acceptanceEventId: acceptanceEventId
            )
        } catch {
            lastError = error.localizedDescription
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
            let driverState = try RideshareEventParser.parseDriverRideState(
                event: event,
                keypair: keypair,
                expectedDriverPubkey: stateMachine.driverPubkey,
                expectedConfirmationEventId: confirmationEventId
            )
            let result = stateMachine.receiveDriverStateEvent(
                eventId: event.id,
                confirmationId: confirmationEventId,
                driverState: driverState,
                createdAt: event.createdAt
            )

            if result == "cancelled" {
                await cleanupRideSubscriptions()
                clearRideState()
            } else if stateMachine.stage == .completed {
                await handleRideCompletion()
                RideStatePersistence.clear()
            } else {
                var persistDriverStateCursor = true
                if result != nil {
                    for action in driverState.history where action.isPinSubmitAction {
                        if let pinEncrypted = action.pinEncrypted,
                           let driverPubkey = stateMachine.driverPubkey {
                            await handlePinSubmission(
                                pinAction: action,
                                pinEncrypted: pinEncrypted,
                                driverPubkey: driverPubkey,
                                confirmationEventId: confirmationEventId
                            )
                        }
                        if !hasProcessedPinAction(action) {
                            persistDriverStateCursor = false
                        }
                    }
                }

                persistRideState(persistDriverStateCursor: persistDriverStateCursor)
            }
        } catch {
            // Invalid state event, skip
        }
    }

    // MARK: - PIN Verification

    func handlePinSubmission(pinEncrypted: String, driverPubkey: String, confirmationEventId: String) async {
        let syntheticAction = DriverRideAction(
            type: "pin_submit",
            at: Int(Date.now.timeIntervalSince1970),
            status: nil,
            approxLocation: nil,
            finalFare: nil,
            invoice: nil,
            pinEncrypted: pinEncrypted
        )
        await handlePinSubmission(
            pinAction: syntheticAction,
            pinEncrypted: pinEncrypted,
            driverPubkey: driverPubkey,
            confirmationEventId: confirmationEventId
        )
    }

    private func handlePinSubmission(
        pinAction: DriverRideAction,
        pinEncrypted: String,
        driverPubkey: String,
        confirmationEventId: String
    ) async {
        guard canProcessPinSubmission(
            driverPubkey: driverPubkey,
            confirmationEventId: confirmationEventId
        ) else { return }

        guard beginProcessingPinAction(pinAction) else { return }
        var processedSuccessfully = false
        var shouldCancelForPinBruteForce = false
        defer { finishProcessingPinAction(pinAction, processed: processedSuccessfully) }

        do {
            let decryptedPin = try RideshareEventParser.decryptPin(
                pinEncrypted: pinEncrypted, driverPubkey: driverPubkey, keypair: keypair
            )
            let isCorrect = decryptedPin == stateMachine.pin
            let currentAttempt = stateMachine.pinAttempts + 1
            shouldCancelForPinBruteForce = !isCorrect && currentAttempt >= RideConstants.maxPinAttempts

            let action = RiderRideAction(
                type: "pin_verify", at: Int(Date.now.timeIntervalSince1970),
                locationType: nil, locationEncrypted: nil,
                status: isCorrect ? "verified" : "rejected", attempt: currentAttempt
            )

            if isCorrect {
                try await Task.sleep(for: .milliseconds(1100))  // NIP-33 ordering
                guard matchesCurrentRide(
                    driverPubkey: driverPubkey,
                    confirmationEventId: confirmationEventId
                ) else { return }

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
                let history = stateMachine.riderStateHistory + [action, destAction]

                let stateEvent = try await RideshareEventBuilder.riderRideState(
                    driverPubkey: driverPubkey, confirmationEventId: confirmationEventId,
                    phase: "verified",
                    history: history, keypair: keypair
                )
                _ = try await relayManager.publish(stateEvent)

                guard matchesCurrentRide(
                    driverPubkey: driverPubkey,
                    confirmationEventId: confirmationEventId
                ) else { return }

                stateMachine.recordPinVerification(verified: true)
                stateMachine.addRiderAction(action)
                stateMachine.addRiderAction(destAction)
                stateMachine.markPreciseDestinationShared()
                processedSuccessfully = true
                persistRideState()
            } else {
                let history = stateMachine.riderStateHistory + [action]
                let stateEvent = try await RideshareEventBuilder.riderRideState(
                    driverPubkey: driverPubkey, confirmationEventId: confirmationEventId,
                    phase: "awaiting_pin",
                    history: history, keypair: keypair
                )
                _ = try await relayManager.publish(stateEvent)
                stateMachine.recordPinVerification(verified: false)
                stateMachine.addRiderAction(action)
                processedSuccessfully = true
                persistRideState()
            }

            if shouldCancelForPinBruteForce {
                await cancelRide(reason: "PIN verification failed")
            }
        } catch {
            lastError = "PIN verification error: \(error.localizedDescription)"
            if shouldCancelForPinBruteForce {
                await cancelRide(reason: "PIN verification failed")
            }
        }
    }

    // MARK: - Cancel Ride (Kind 3179)

    func cancelRide(reason: String? = nil) async {
        if stateMachine.stage == .completed {
            await cleanupRideSubscriptions()
            clearRideState()
            return
        }

        guard let driverPubkey = stateMachine.driverPubkey else {
            clearRideState()
            return
        }

        if let confirmationId = stateMachine.confirmationEventId {
            // Post-confirmation: send Kind 3179 cancellation
            do {
                let event = try await RideshareEventBuilder.cancellation(
                    counterpartyPubkey: driverPubkey,
                    confirmationEventId: confirmationId,
                    reason: reason, keypair: keypair
                )
                _ = try await relayManager.publish(event)
            } catch { /* Best effort */ }
        } else if let offerEventId = stateMachine.offerEventId {
            // Pre-acceptance: delete the offer event via NIP-09 so driver stops seeing it
            do {
                let deletion = try await RideshareEventBuilder.deletion(
                    eventIds: [offerEventId],
                    reason: reason ?? "rider cancelled",
                    kinds: [.rideOffer],
                    keypair: keypair
                )
                _ = try await relayManager.publish(deletion)
            } catch { /* Best effort */ }
        }

        await cleanupRideSubscriptions()
        clearRideState()
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
                    await handleCancellationEvent(event, driverPubkey: driverPubkey, confirmationEventId: confirmationEventId)
                }
            } catch { /* Non-fatal */ }
        }
    }

    func handleCancellationEvent(_ event: NostrEvent, driverPubkey: String, confirmationEventId: String) async {
        do {
            _ = try RideshareEventParser.parseCancellation(
                event: event,
                keypair: keypair,
                expectedDriverPubkey: driverPubkey,
                expectedConfirmationEventId: confirmationEventId
            )
            let processed = stateMachine.handleCancellation(
                eventId: event.id, confirmationId: confirmationEventId
            )
            if processed {
                await cleanupRideSubscriptions()
                clearRideState()
            }
        } catch {
            // Invalid or unauthorised cancellation, ignore.
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
                paymentMethod: stateMachine.paymentMethod
                    ?? selectedPaymentMethod
                    ?? PaymentMethod.cash.rawValue,
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

    private func clearRideState() {
        cancelStageTimeout()
        stateMachine.reset()
        chat.reset()
        currentFareEstimate = nil
        selectedPaymentMethod = nil
        pickupLocation = nil
        destinationLocation = nil
        processedPinActionKeys = []
        inFlightPinActionKeys = []
        confirmationPublishInFlight = false
        RideStatePersistence.clear()
    }

    private func stageTimeout(for stage: RiderStage) -> TimeInterval? {
        switch stage {
        case .waitingForAcceptance:
            stageTimeouts.waitingForAcceptance
        case .driverAccepted:
            stageTimeouts.driverAccepted
        default:
            nil
        }
    }

    private func scheduleStageTimeout(savedAt: Int? = nil) {
        cancelStageTimeout()
        guard let timeout = stageTimeout(for: stateMachine.stage) else { return }

        let expectedStage = stateMachine.stage
        let now = Date.now.timeIntervalSince1970
        let stageEnteredAt = TimeInterval(savedAt ?? Int(now))
        let remainingSeconds = timeout - max(0, now - stageEnteredAt)

        if remainingSeconds <= 0 {
            stageTimeoutTask = Task { [weak self] in
                await self?.handleStageTimeout(expectedStage: expectedStage)
            }
            return
        }

        let delayMillis = max(1, Int((remainingSeconds * 1000).rounded(.up)))
        stageTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMillis))
            guard let self, !Task.isCancelled, self.stateMachine.stage == expectedStage else { return }
            await self.handleStageTimeout(expectedStage: expectedStage)
        }
    }

    private func cancelStageTimeout() {
        stageTimeoutTask?.cancel()
        stageTimeoutTask = nil
    }

    private func handleStageTimeout(expectedStage: RiderStage) async {
        guard stateMachine.stage == expectedStage else { return }

        switch expectedStage {
        case .waitingForAcceptance:
            lastError = "Ride request expired before a driver responded."
            await expirePreConfirmationRide(sendOfferDeletion: true, reason: "offer expired")
        case .driverAccepted:
            lastError = "Ride request expired before confirmation completed."
            await expirePreConfirmationRide(sendOfferDeletion: false, reason: "confirmation timeout")
        default:
            break
        }
    }

    private func expirePreConfirmationRide(sendOfferDeletion: Bool, reason: String) async {
        guard stateMachine.stage == .waitingForAcceptance || stateMachine.stage == .driverAccepted else { return }

        if sendOfferDeletion, let offerEventId = stateMachine.offerEventId {
            do {
                let deletion = try await RideshareEventBuilder.deletion(
                    eventIds: [offerEventId],
                    reason: reason,
                    kinds: [.rideOffer],
                    keypair: keypair
                )
                _ = try await relayManager.publish(deletion)
            } catch {
                // Best effort only.
            }
        }

        await cleanupRideSubscriptions()
        clearRideState()
    }

    private func ensureConfirmationPublished(
        driverPubkey: String,
        acceptanceEventId: String
    ) async {
        guard !confirmationPublishInFlight else { return }
        confirmationPublishInFlight = true
        defer { confirmationPublishInFlight = false }

        do {
            try await publishConfirmationAndRestoreConfirmedRide(
                driverPubkey: driverPubkey,
                acceptanceEventId: acceptanceEventId
            )
        } catch {
            await retryConfirmationIfNeeded(
                driverPubkey: driverPubkey,
                acceptanceEventId: acceptanceEventId
            )
        }
    }

    private func publishConfirmationAndRestoreConfirmedRide(
        driverPubkey: String,
        acceptanceEventId: String
    ) async throws {
        guard let precisePickup = pickupLocation else {
            throw RidestrError.ride(.invalidEvent("Cannot confirm ride without a precise pickup location"))
        }
        let confirmEvent = try await RideshareEventBuilder.rideConfirmation(
            driverPubkey: driverPubkey,
            acceptanceEventId: acceptanceEventId,
            precisePickup: precisePickup,
            keypair: keypair
        )
        _ = try await relayManager.publish(confirmEvent)
        stateMachine.markPrecisePickupShared()
        try stateMachine.recordConfirmation(confirmationEventId: confirmEvent.id)
        persistRideState()
        cancelStageTimeout()

        if let subId = acceptanceSubscriptionId {
            await relayManager.unsubscribe(subId)
        }
        restoreConfirmedRideSubscriptions(
            driverPubkey: driverPubkey,
            confirmationEventId: confirmEvent.id
        )
    }

    private func recoverExistingConfirmationIfNeeded(
        driverPubkey: String,
        acceptanceEventId: String
    ) async -> Bool {
        do {
            let filter = NostrFilter.rideConfirmations(
                acceptanceEventId: acceptanceEventId,
                riderPubkey: keypair.publicKeyHex
            )
            let events = try await relayManager.fetchEvents(filter: filter, timeout: 5)
            let envelope = events
                .sorted(by: { $0.createdAt > $1.createdAt })
                .compactMap { event in
                    try? RideshareEventParser.parseConfirmationEnvelope(
                        event: event,
                        expectedRiderPubkey: keypair.publicKeyHex,
                        expectedDriverPubkey: driverPubkey,
                        expectedAcceptanceEventId: acceptanceEventId
                    )
                }
                .first

            guard let envelope else { return false }
            stateMachine.markPrecisePickupShared()
            try stateMachine.recordConfirmation(confirmationEventId: envelope.eventId)
            persistRideState()
            cancelStageTimeout()
            restoreConfirmedRideSubscriptions(
                driverPubkey: driverPubkey,
                confirmationEventId: envelope.eventId
            )
            return true
        } catch {
            return false
        }
    }

    private func restoreConfirmedRideSubscriptions(
        driverPubkey: String,
        confirmationEventId: String
    ) {
        subscribeToDriverState(driverPubkey: driverPubkey, confirmationEventId: confirmationEventId)
        chat.subscribeToChat(driverPubkey: driverPubkey, confirmationEventId: confirmationEventId)
        subscribeToCancellation(driverPubkey: driverPubkey, confirmationEventId: confirmationEventId)
    }

    private func retryConfirmationIfNeeded(
        driverPubkey: String,
        acceptanceEventId: String
    ) async {
        let retryDelays: [Duration] = [.zero, .seconds(1), .seconds(3)]
        var lastFailure: Error?

        for (index, delay) in retryDelays.enumerated() {
            guard stateMachine.stage == .driverAccepted,
                  stateMachine.confirmationEventId == nil,
                  stateMachine.acceptanceEventId == acceptanceEventId,
                  stateMachine.driverPubkey == driverPubkey else { return }

            if index > 0 {
                try? await Task.sleep(for: delay)
            }
            guard stateMachine.stage == .driverAccepted,
                  stateMachine.confirmationEventId == nil,
                  stateMachine.acceptanceEventId == acceptanceEventId,
                  stateMachine.driverPubkey == driverPubkey else { return }

            do {
                try await publishConfirmationAndRestoreConfirmedRide(
                    driverPubkey: driverPubkey,
                    acceptanceEventId: acceptanceEventId
                )
                return
            } catch {
                lastFailure = error
            }
        }

        if let lastFailure {
            lastError = "Failed to resume ride confirmation: \(lastFailure.localizedDescription)"
        }
    }

    private func beginProcessingPinAction(_ action: DriverRideAction) -> Bool {
        let fullKey = Self.pinActionKey(for: action)
        guard !processedPinActionKeys.contains(fullKey),
              !processedPinActionKeys.contains(Self.legacyPinActionKey(action.at)),
              !inFlightPinActionKeys.contains(fullKey),
              processedPinActionKeys.count + inFlightPinActionKeys.count < 10 else { return false }
        inFlightPinActionKeys.insert(fullKey)
        return true
    }

    private func finishProcessingPinAction(_ action: DriverRideAction, processed: Bool) {
        let fullKey = Self.pinActionKey(for: action)
        inFlightPinActionKeys.remove(fullKey)
        if processed {
            processedPinActionKeys.insert(fullKey)
        }
    }

    private func hasProcessedPinAction(_ action: DriverRideAction) -> Bool {
        let fullKey = Self.pinActionKey(for: action)
        return processedPinActionKeys.contains(fullKey) ||
            processedPinActionKeys.contains(Self.legacyPinActionKey(action.at))
    }

    private static func pinActionKey(for action: DriverRideAction) -> String {
        "pin_submit:\(action.at):\(action.pinEncrypted ?? "")"
    }

    private static func legacyPinActionKey(_ timestamp: Int) -> String {
        "pin_submit:\(timestamp)"
    }

    private func matchesCurrentRide(
        driverPubkey: String,
        confirmationEventId: String
    ) -> Bool {
        stateMachine.driverPubkey == driverPubkey &&
            stateMachine.confirmationEventId == confirmationEventId
    }

    private func canProcessPinSubmission(
        driverPubkey: String,
        confirmationEventId: String
    ) -> Bool {
        matchesCurrentRide(
            driverPubkey: driverPubkey,
            confirmationEventId: confirmationEventId
        ) &&
            stateMachine.stage == .driverArrived &&
            !stateMachine.pinVerified &&
            !stateMachine.preciseDestinationShared
    }

    func stopAll() async {
        cancelStageTimeout()
        await cleanupRideSubscriptions()
        await location.stopAll()
    }

    func closeCompletedRide() async {
        guard stateMachine.stage == .completed else {
            clearRideState()
            return
        }
        await cleanupRideSubscriptions()
        clearRideState()
    }
}

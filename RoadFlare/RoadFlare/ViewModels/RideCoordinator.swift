import Foundation
import RidestrSDK

/// Coordinates the entire ride lifecycle: relay subscriptions, event publishing,
/// state machine management, and driver location tracking.
///
/// This is the bridge between the SDK and the UI. Views observe its published state.
@Observable
@MainActor
final class RideCoordinator {
    // MARK: - Dependencies

    private let relayManager: RelayManager
    private let keypair: NostrKeypair
    private let driversRepository: FollowedDriversRepository
    private let settings: UserSettings
    private let rideHistory: RideHistoryStore

    // MARK: - State Machine

    let stateMachine = RideStateMachine()

    // MARK: - Chat State

    var chatMessages: [(id: String, text: String, isMine: Bool, timestamp: Int)] = []

    // MARK: - Active Ride Tracking

    private var acceptanceSubscriptionId: SubscriptionID?
    private var driverStateSubscriptionId: SubscriptionID?
    private var chatSubscriptionId: SubscriptionID?
    private var cancellationSubscriptionId: SubscriptionID?
    private var locationSubscriptionId: SubscriptionID?
    private var keyShareSubscriptionId: SubscriptionID?

    // MARK: - Subscription Tasks

    private var acceptanceTask: Task<Void, Never>?
    private var driverStateTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    private var locationTask: Task<Void, Never>?
    private var keyShareTask: Task<Void, Never>?
    private var chatRefreshTask: Task<Void, Never>?

    // MARK: - Ride Data

    var currentFareEstimate: FareEstimate?
    var selectedPaymentMethod: PaymentMethod?
    var pickupLocation: Location?
    var destinationLocation: Location?

    /// Set of processed PIN action timestamps to prevent replay.
    private var processedPinActionTimestamps: Set<Int> = []

    // MARK: - Error State

    var lastError: String?

    init(relayManager: RelayManager, keypair: NostrKeypair,
         driversRepository: FollowedDriversRepository, settings: UserSettings,
         rideHistory: RideHistoryStore) {
        self.relayManager = relayManager
        self.keypair = keypair
        self.driversRepository = driversRepository
        self.settings = settings
        self.rideHistory = rideHistory

        // Restore persisted ride state if any
        restoreRideState()
    }

    /// Persist current ride state to UserDefaults.
    func persistRideState() {
        RideStatePersistence.save(
            stateMachine: stateMachine,
            pickupLocation: pickupLocation,
            destinationLocation: destinationLocation,
            fareEstimate: currentFareEstimate,
            paymentMethod: selectedPaymentMethod
        )
    }

    /// Restore ride state after app relaunch.
    private func restoreRideState() {
        guard let saved = RideStatePersistence.load(),
              let driverPubkey = saved.driverPubkey,
              let confirmationId = saved.confirmationEventId else { return }

        // Restore locations
        if let lat = saved.pickupLat, let lon = saved.pickupLon {
            pickupLocation = Location(latitude: lat, longitude: lon, address: saved.pickupAddress)
        }
        if let lat = saved.destLat, let lon = saved.destLon {
            destinationLocation = Location(latitude: lat, longitude: lon, address: saved.destAddress)
        }
        if let raw = saved.paymentMethodRaw {
            selectedPaymentMethod = PaymentMethod(rawValue: raw)
        }

        // Re-subscribe to active ride events
        subscribeToDriverState(driverPubkey: driverPubkey, confirmationEventId: confirmationId)
        subscribeToChat(driverPubkey: driverPubkey, confirmationEventId: confirmationId)
        subscribeToCancellation(driverPubkey: driverPubkey, confirmationEventId: confirmationId)
    }

    // MARK: - Step 2: RoadFlare Location Subscription

    /// Start subscribing to all followed drivers' location broadcasts (Kind 30014).
    func startLocationSubscriptions() {
        let pubkeys = driversRepository.allPubkeys
        guard !pubkeys.isEmpty else { return }

        let subId = SubscriptionID("roadflare-locations")
        locationSubscriptionId = subId

        locationTask?.cancel()
        locationTask = Task {
            do {
                let filter = NostrFilter.roadflareLocations(driverPubkeys: pubkeys)
                let stream = try await relayManager.subscribe(filter: filter, id: subId)

                for await event in stream {
                    guard !Task.isCancelled else { break }
                    await handleLocationEvent(event)
                }
            } catch {
                lastError = "Location subscription failed: \(error.localizedDescription)"
            }
        }
    }

    private func handleLocationEvent(_ event: NostrEvent) async {
        let driverPubkey = event.pubkey
        guard let key = driversRepository.getRoadflareKey(driverPubkey: driverPubkey) else { return }

        do {
            let parsed = try RideshareEventParser.parseRoadflareLocation(
                event: event,
                roadflarePrivateKeyHex: key.privateKeyHex
            )
            driversRepository.updateDriverLocation(
                pubkey: driverPubkey,
                latitude: parsed.location.latitude,
                longitude: parsed.location.longitude,
                status: parsed.location.status.rawValue,
                timestamp: parsed.location.timestamp,
                keyVersion: parsed.keyVersion
            )
        } catch {
            // Decryption failure — might be stale key, silently ignore
        }
    }

    // MARK: - Step 3: Publish Followed Drivers (Kind 30011)

    /// Publish the current followed drivers list so drivers can discover followers.
    func publishFollowedDriversList() async {
        do {
            let event = try await RideshareEventBuilder.followedDriversList(
                drivers: driversRepository.drivers,
                keypair: keypair
            )
            _ = try await relayManager.publish(event)
        } catch {
            lastError = "Failed to publish driver list: \(error.localizedDescription)"
        }
    }

    // MARK: - Step 4: Key Share Subscription (Kind 3186)

    /// Subscribe to incoming key shares from drivers.
    func startKeyShareSubscription() {
        let subId = SubscriptionID("key-shares")
        keyShareSubscriptionId = subId

        keyShareTask?.cancel()
        keyShareTask = Task {
            do {
                let filter = NostrFilter.keyShares(myPubkey: keypair.publicKeyHex)
                let stream = try await relayManager.subscribe(filter: filter, id: subId)

                for await event in stream {
                    guard !Task.isCancelled else { break }
                    await handleKeyShareEvent(event)
                }
            } catch {
                lastError = "Key share subscription failed: \(error.localizedDescription)"
            }
        }
    }

    private func handleKeyShareEvent(_ event: NostrEvent) async {
        do {
            let keyShare = try RideshareEventParser.parseKeyShare(event: event, keypair: keypair)
            driversRepository.updateDriverKey(
                driverPubkey: keyShare.driverPubkey,
                roadflareKey: keyShare.roadflareKey
            )

            // Send acknowledgement (Kind 3188)
            let ackEvent = try await RideshareEventBuilder.keyAcknowledgement(
                driverPubkey: keyShare.driverPubkey,
                keyVersion: keyShare.roadflareKey.version,
                keyUpdatedAt: keyShare.keyUpdatedAt,
                status: "received",
                keypair: keypair
            )
            _ = try await relayManager.publish(ackEvent)

            // Restart location subscriptions to include newly-keyed driver
            startLocationSubscriptions()
        } catch {
            // Expired or invalid key share, ignore
        }
    }

    // MARK: - Step 5: Send Ride Offer (Kind 3173)

    /// Send a RoadFlare ride offer to a specific driver.
    func sendRideOffer(
        driverPubkey: String,
        pickup: Location,
        destination: Location,
        fareEstimate: FareEstimate
    ) async {
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

            // Store locations for later use in confirmation and reveal
            self.pickupLocation = pickup
            self.destinationLocation = destination

            try stateMachine.startRide(
                offerEventId: offerEvent.id,
                driverPubkey: driverPubkey,
                paymentMethod: selectedPaymentMethod,
                fiatPaymentMethods: settings.paymentMethods
            )

            currentFareEstimate = fareEstimate

            // Step 6: Subscribe to acceptance
            subscribeToAcceptance(offerEventId: offerEvent.id, driverPubkey: driverPubkey)

        } catch {
            lastError = "Failed to send offer: \(error.localizedDescription)"
        }
    }

    // MARK: - Step 6: Acceptance Subscription + Auto-Confirm

    private func subscribeToAcceptance(offerEventId: String, driverPubkey: String) {
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
                    break  // First acceptance wins
                }
            } catch {
                lastError = "Acceptance subscription failed: \(error.localizedDescription)"
            }
        }
    }

    private func handleAcceptance(acceptanceEventId: String, driverPubkey: String) async {
        do {
            // Generate PIN and transition state
            let pin = try stateMachine.handleAcceptance(acceptanceEventId: acceptanceEventId)

            // Auto-confirm: publish Kind 3175 with precise pickup
            // RoadFlare rides always share precise pickup immediately (trusted driver)
            let confirmEvent = try await RideshareEventBuilder.rideConfirmation(
                driverPubkey: driverPubkey,
                acceptanceEventId: acceptanceEventId,
                precisePickup: pickupLocation,
                keypair: keypair
            )
            stateMachine.markPrecisePickupShared()
            _ = try await relayManager.publish(confirmEvent)

            try stateMachine.recordConfirmation(confirmationEventId: confirmEvent.id)
            persistRideState()

            // Close acceptance subscription
            if let subId = acceptanceSubscriptionId {
                await relayManager.unsubscribe(subId)
            }

            // Step 7: Subscribe to driver state + chat + cancellation
            subscribeToDriverState(driverPubkey: driverPubkey, confirmationEventId: confirmEvent.id)
            subscribeToChat(driverPubkey: driverPubkey, confirmationEventId: confirmEvent.id)
            subscribeToCancellation(driverPubkey: driverPubkey, confirmationEventId: confirmEvent.id)

        } catch {
            lastError = "Failed to confirm ride: \(error.localizedDescription)"
        }
    }

    // MARK: - Step 7: Driver State Subscription (Kind 30180)

    private func subscribeToDriverState(driverPubkey: String, confirmationEventId: String) {
        let subId = SubscriptionID("driver-state-\(confirmationEventId)")
        driverStateSubscriptionId = subId

        driverStateTask?.cancel()
        driverStateTask = Task {
            do {
                let filter = NostrFilter.driverRideState(
                    driverPubkey: driverPubkey,
                    confirmationEventId: confirmationEventId
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

    private func handleDriverStateEvent(_ event: NostrEvent, confirmationEventId: String) async {
        do {
            let driverState = try RideshareEventParser.parseDriverRideState(
                event: event, keypair: keypair
            )

            let result = try stateMachine.handleDriverStateUpdate(
                eventId: event.id,
                confirmationId: confirmationEventId,
                driverState: driverState
            )

            // Handle PIN submission from driver (with replay protection)
            if result != nil {
                for action in driverState.history where action.isPinSubmitAction {
                    // Deduplicate by action timestamp
                    guard !processedPinActionTimestamps.contains(action.at) else { continue }
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

            // Persist state after every update
            persistRideState()

            // If completed, save to history and clean up
            if stateMachine.stage == .completed {
                await handleRideCompletion()
                RideStatePersistence.clear()
            }
        } catch {
            // Invalid state event, skip
        }
    }

    private func handlePinSubmission(pinEncrypted: String, driverPubkey: String, confirmationEventId: String) async {
        do {
            let decryptedPin = try RideshareEventParser.decryptPin(
                pinEncrypted: pinEncrypted,
                driverPubkey: driverPubkey,
                keypair: keypair
            )

            let isCorrect = decryptedPin == stateMachine.pin
            stateMachine.recordPinVerification(verified: isCorrect)

            let now = Int(Date.now.timeIntervalSince1970)
            let action = RiderRideAction(
                type: "pin_verify",
                at: now,
                locationType: nil,
                locationEncrypted: nil,
                status: isCorrect ? "verified" : "rejected",
                attempt: stateMachine.pinAttempts
            )
            stateMachine.addRiderAction(action)

            if isCorrect {
                // 1100ms delay for NIP-33 ordering
                try await Task.sleep(for: .milliseconds(1100))

                // Reveal precise destination (NIP-44 encrypted to driver)
                var encryptedDest = ""
                if let dest = destinationLocation {
                    encryptedDest = try RideshareEventParser.encryptLocation(
                        location: dest,
                        recipientPubkey: driverPubkey,
                        keypair: keypair
                    )
                }

                let destAction = RiderRideAction(
                    type: "location_reveal",
                    at: Int(Date.now.timeIntervalSince1970),
                    locationType: "destination",
                    locationEncrypted: encryptedDest,
                    status: nil,
                    attempt: nil
                )
                stateMachine.addRiderAction(destAction)
                stateMachine.markPreciseDestinationShared()
            }

            // Publish updated rider state
            let stateEvent = try await RideshareEventBuilder.riderRideState(
                driverPubkey: driverPubkey,
                confirmationEventId: confirmationEventId,
                phase: isCorrect ? "verified" : "awaiting_pin",
                history: stateMachine.riderStateHistory,
                keypair: keypair
            )
            _ = try await relayManager.publish(stateEvent)

            // Auto-cancel after max attempts
            if !isCorrect && stateMachine.pinAttempts >= RideConstants.maxPinAttempts {
                await cancelRide(reason: "PIN verification failed")
            }
        } catch {
            lastError = "PIN verification error: \(error.localizedDescription)"
        }
    }

    // MARK: - Step 8: Cancel Ride (Kind 3179)

    /// Cancel the current ride. Publishes cancellation event and cleans up.
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
                    reason: reason,
                    keypair: keypair
                )
                _ = try await relayManager.publish(event)
            } catch {
                // Best effort — reset state even if publish fails
            }
        }

        await cleanupSubscriptions()
        stateMachine.reset()
        chatMessages = []
        currentFareEstimate = nil
        pickupLocation = nil
        destinationLocation = nil
        processedPinActionTimestamps = []
        RideStatePersistence.clear()
    }

    // MARK: - Step 9: Chat (Kind 3178)

    private func subscribeToChat(driverPubkey: String, confirmationEventId: String) {
        let subId = SubscriptionID("chat-\(confirmationEventId)")
        chatSubscriptionId = subId

        chatTask?.cancel()
        chatTask = Task {
            do {
                let filter = NostrFilter.chatMessages(
                    counterpartyPubkey: driverPubkey,
                    myPubkey: keypair.publicKeyHex
                )
                let stream = try await relayManager.subscribe(filter: filter, id: subId)

                for await event in stream {
                    guard !Task.isCancelled else { break }
                    await handleChatEvent(event)
                }
            } catch {
                // Chat subscription failure is non-fatal
            }
        }
    }

    private func handleChatEvent(_ event: NostrEvent) async {
        do {
            let content = try RideshareEventParser.parseChatMessage(event: event, keypair: keypair)
            let isMine = event.pubkey == keypair.publicKeyHex
            // Deduplicate by event ID
            guard !chatMessages.contains(where: { $0.id == event.id }) else { return }
            chatMessages.append((id: event.id, text: content.message, isMine: isMine, timestamp: event.createdAt))
            chatMessages.sort { $0.timestamp < $1.timestamp }
        } catch {
            // Invalid chat message, skip
        }
    }

    /// Send a chat message to the driver.
    func sendChatMessage(_ text: String) async {
        guard let driverPubkey = stateMachine.driverPubkey,
              let confirmationId = stateMachine.confirmationEventId else { return }

        do {
            let event = try await RideshareEventBuilder.chatMessage(
                recipientPubkey: driverPubkey,
                confirmationEventId: confirmationId,
                message: text,
                keypair: keypair
            )
            _ = try await relayManager.publish(event)
            chatMessages.append((
                id: event.id,
                text: text,
                isMine: true,
                timestamp: Int(Date.now.timeIntervalSince1970)
            ))
        } catch {
            lastError = "Failed to send message: \(error.localizedDescription)"
        }
    }

    // MARK: - Step 9 cont: Cancellation Subscription

    private func subscribeToCancellation(driverPubkey: String, confirmationEventId: String) {
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
                        eventId: event.id,
                        confirmationId: confirmationEventId
                    )
                    if processed {
                        await cleanupSubscriptions()
                        chatMessages = []
                    }
                }
            } catch {
                // Non-fatal
            }
        }
    }

    // MARK: - Step 10: Ride Completion

    private func handleRideCompletion() async {
        // Save to ride history
        if let driverPubkey = stateMachine.driverPubkey,
           let confirmationId = stateMachine.confirmationEventId {
            let pickup = pickupLocation ?? Location(latitude: 0, longitude: 0)
            let destination = destinationLocation ?? Location(latitude: 0, longitude: 0)
            let entry = RideHistoryEntry(
                id: confirmationId,
                date: .now,
                counterpartyPubkey: driverPubkey,
                counterpartyName: driversRepository.cachedDriverName(pubkey: driverPubkey),
                pickupGeohash: ProgressiveReveal.historyGeohash(for: pickup),
                dropoffGeohash: ProgressiveReveal.historyGeohash(for: destination),
                pickup: pickup,
                destination: destination,
                fare: currentFareEstimate?.fareUSD ?? 0,
                paymentMethod: selectedPaymentMethod?.rawValue ?? "cash",
                distance: currentFareEstimate?.distanceMiles,
                duration: currentFareEstimate.map { Int($0.durationMinutes) }
            )
            rideHistory.addRide(entry)
        }

        await cleanupSubscriptions()
    }

    // MARK: - Cleanup

    /// Clean up all active ride subscriptions.
    func cleanupSubscriptions() async {
        acceptanceTask?.cancel()
        driverStateTask?.cancel()
        chatTask?.cancel()
        cancellationTask?.cancel()
        chatRefreshTask?.cancel()

        if let id = acceptanceSubscriptionId { await relayManager.unsubscribe(id) }
        if let id = driverStateSubscriptionId { await relayManager.unsubscribe(id) }
        if let id = chatSubscriptionId { await relayManager.unsubscribe(id) }
        if let id = cancellationSubscriptionId { await relayManager.unsubscribe(id) }

        acceptanceSubscriptionId = nil
        driverStateSubscriptionId = nil
        chatSubscriptionId = nil
        cancellationSubscriptionId = nil
    }

    /// Stop all subscriptions including background ones (for logout).
    func stopAll() async {
        await cleanupSubscriptions()
        locationTask?.cancel()
        keyShareTask?.cancel()
        if let id = locationSubscriptionId { await relayManager.unsubscribe(id) }
        if let id = keyShareSubscriptionId { await relayManager.unsubscribe(id) }
    }
}

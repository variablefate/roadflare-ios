import Foundation
import RidestrSDK

/// Thin app-layer adapter around `RiderRideSession`.
/// The SDK owns ride protocol/runtime behavior; the app owns UI state,
/// chat/location coordinators, and persistence mapping.
@Observable
@MainActor
public final class RideCoordinator {
    public struct StageTimeouts: Equatable, Sendable {
        public let waitingForAcceptance: TimeInterval
        public let driverAccepted: TimeInterval

        public nonisolated static let interopDefault = StageTimeouts(
            waitingForAcceptance: RideConstants.broadcastTimeoutSeconds,
            driverAccepted: RideConstants.confirmationTimeoutSeconds
        )
    }

    let location: LocationCoordinator
    public let chat: ChatCoordinator
    public let session: RiderRideSession

    private let settings: UserSettingsRepository
    private let rideHistory: RideHistoryRepository
    private let bitcoinPrice: BitcoinPriceService
    private let roadflareDomainService: RoadflareDomainService?
    private let roadflareSyncStore: RoadflareSyncStateStore?
    let rideStateRepository: RideStateRepository

    public var currentFareEstimate: FareEstimate?
    public var selectedPaymentMethod: String?
    public var pickupLocation: Location?
    public var destinationLocation: Location?
    public var lastError: String?

    var driversRepository: FollowedDriversRepository { location.driversRepository }
    public var chatMessages: [(id: String, text: String, isMine: Bool, timestamp: Int)] { chat.chatMessages }
    public var activeRidePaymentMethods: [String] {
        if !session.fiatPaymentMethods.isEmpty {
            return session.fiatPaymentMethods
        }
        if let paymentMethod = session.paymentMethod {
            return [paymentMethod]
        }
        return []
    }

    public init(
        relayManager: any RelayManagerProtocol,
        keypair: NostrKeypair,
        driversRepository: FollowedDriversRepository,
        settings: UserSettingsRepository,
        rideHistory: RideHistoryRepository,
        bitcoinPrice: BitcoinPriceService? = nil,
        roadflareDomainService: RoadflareDomainService? = nil,
        roadflareSyncStore: RoadflareSyncStateStore? = nil,
        rideStatePersistence: RideStatePersistence,
        stageTimeouts: StageTimeouts = .interopDefault
    ) {
        self.settings = settings
        self.rideHistory = rideHistory
        self.bitcoinPrice = bitcoinPrice ?? BitcoinPriceService()
        self.roadflareDomainService = roadflareDomainService
        self.roadflareSyncStore = roadflareSyncStore
        let policy = RideStateRestorationPolicy(
            waitingForAcceptance: max(0, Int(stageTimeouts.waitingForAcceptance.rounded(.up))),
            driverAccepted: max(0, Int(stageTimeouts.driverAccepted.rounded(.up))),
            postConfirmation: Int(EventExpiration.rideConfirmationHours * 3600)
        )
        self.rideStateRepository = RideStateRepository(persistence: rideStatePersistence, policy: policy)
        self.location = LocationCoordinator(
            relayManager: relayManager,
            keypair: keypair,
            driversRepository: driversRepository,
            roadflareDomainService: roadflareDomainService,
            roadflareSyncStore: roadflareSyncStore
        )
        self.chat = ChatCoordinator(relayManager: relayManager, keypair: keypair)
        self.session = RiderRideSession(
            relayManager: relayManager,
            keypair: keypair,
            configuration: .init(
                stageTimeouts: .init(
                    waitingForAcceptance: Self.duration(seconds: stageTimeouts.waitingForAcceptance),
                    driverAccepted: Self.duration(seconds: stageTimeouts.driverAccepted)
                ),
                confirmationRetryDelays: [.zero, .seconds(1), .seconds(3)],
                maxPinActionSetSize: 10
            )
        )
        self.session.delegate = self

        restoreRideState()
    }

    public func startLocationSubscriptions() { location.startLocationSubscriptions() }
    func startKeyShareSubscription() { location.startKeyShareSubscription() }
    public func publishFollowedDriversList() async { await location.publishFollowedDriversList() }
    public func requestKeyRefresh(driverPubkey: String) async { await location.requestKeyRefresh(driverPubkey: driverPubkey) }
    public func checkForStaleKeys() async { await location.checkForStaleKeys() }

    func restoreRideState() {
        guard let saved = rideStateRepository.load(),
              let restoredStage = RiderStage(rawValue: saved.stage) else {
            return
        }

        let pickup = saved.pickupLat.flatMap { lat in
            saved.pickupLon.map { lon in
                Location(latitude: lat, longitude: lon, address: saved.pickupAddress)
            }
        }
        let destination = saved.destLat.flatMap { lat in
            saved.destLon.map { lon in
                Location(latitude: lat, longitude: lon, address: saved.destAddress)
            }
        }

        session.restore(
            stage: restoredStage,
            offerEventId: saved.offerEventId,
            acceptanceEventId: saved.acceptanceEventId,
            confirmationEventId: saved.confirmationEventId,
            driverPubkey: saved.driverPubkey,
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
            riderStateHistory: saved.riderStateHistory ?? [],
            processedPinActionKeys: Set(saved.processedPinActionKeys ?? []),
            precisePickup: pickup,
            preciseDestination: destination,
            savedAt: saved.savedAt
        )

        guard session.stage == restoredStage else {
            rideStateRepository.clear()
            return
        }

        pickupLocation = pickup
        destinationLocation = destination
        selectedPaymentMethod = saved.paymentMethodRaw
        if let fareStr = saved.fareUSD, let fareDecimal = Decimal(string: fareStr) {
            currentFareEstimate = FareEstimate(
                distanceMiles: saved.fareDistanceMiles ?? 0,
                durationMinutes: saved.fareDurationMinutes ?? 0,
                fareUSD: fareDecimal
            )
        }
    }

    func persistRideState() {
        let pickup = pickupLocation ?? session.precisePickup
        let destination = destinationLocation ?? session.preciseDestination
        let state = PersistedRideState(
            stage: session.stage.rawValue,
            offerEventId: session.offerEventId,
            acceptanceEventId: session.acceptanceEventId,
            confirmationEventId: session.confirmationEventId,
            driverPubkey: session.driverPubkey,
            pin: session.pin,
            pinVerified: session.pinVerified,
            paymentMethodRaw: session.paymentMethod,
            fiatPaymentMethodsRaw: session.fiatPaymentMethods,
            pickupLat: pickup?.latitude,
            pickupLon: pickup?.longitude,
            pickupAddress: pickup?.address,
            destLat: destination?.latitude,
            destLon: destination?.longitude,
            destAddress: destination?.address,
            fareUSD: currentFareEstimate.map { "\($0.fareUSD)" },
            fareDistanceMiles: currentFareEstimate?.distanceMiles,
            fareDurationMinutes: currentFareEstimate?.durationMinutes,
            savedAt: Int(Date.now.timeIntervalSince1970),
            processedPinActionKeys: session.processedPinActionKeys.isEmpty ? nil : Array(session.processedPinActionKeys),
            processedPinTimestamps: nil,
            pinAttempts: session.pinAttempts > 0 ? session.pinAttempts : nil,
            precisePickupShared: session.precisePickupShared ? true : nil,
            preciseDestinationShared: session.preciseDestinationShared ? true : nil,
            lastDriverStatus: session.lastDriverStatus,
            lastDriverStateTimestamp: session.lastDriverStateTimestamp > 0 ? session.lastDriverStateTimestamp : nil,
            lastDriverActionCount: session.lastDriverActionCount > 0 ? session.lastDriverActionCount : nil,
            riderStateHistory: session.riderStateHistory.isEmpty ? nil : session.riderStateHistory
        )
        rideStateRepository.save(state)
    }

    /// Safe to call repeatedly after launch or reconnect.
    public func restoreLiveSubscriptions() async {
        await chat.cleanup()
        location.startLocationSubscriptions()
        location.startKeyShareSubscription()
        async let staleKeyRefresh: Void = driversRepository.hasDrivers ? location.checkForStaleKeys() : ()

        let stageBefore = session.stage
        await session.restoreSubscriptions()
        restoreChatIfNeeded(stageBefore: stageBefore)

        _ = await staleKeyRefresh
    }

    public func sendRideOffer(
        driverPubkey: String,
        pickup: Location,
        destination: Location,
        fareEstimate: FareEstimate
    ) async {
        guard let fareSats = bitcoinPrice.usdToSats(fareEstimate.fareUSD) else {
            lastError = "Bitcoin price not available. Try again in a moment."
            return
        }

        let paymentPreferences = RoadflarePaymentPreferences(methods: settings.roadflarePaymentMethods)
        let primaryPaymentMethod = selectedPaymentMethod
            ?? paymentPreferences.primaryMethod
            ?? PaymentMethod.cash.rawValue

        let offerContent = RideOfferContent(
            fareEstimate: Double(fareSats),
            destination: destination.approximate(),
            approxPickup: pickup.approximate(),
            rideRouteKm: fareEstimate.distanceMiles / 0.621371,
            rideRouteMin: fareEstimate.durationMinutes,
            destinationGeohash: destination.geohash(precision: GeohashPrecision.settlement).hash,
            paymentMethod: primaryPaymentMethod,
            fiatPaymentMethods: paymentPreferences.methods
        )

        let stageBefore = session.stage
        await session.sendOffer(
            driverPubkey: driverPubkey,
            content: offerContent,
            precisePickup: pickup,
            preciseDestination: destination
        )

        guard stageBefore == .idle,
              session.stage == .waitingForAcceptance,
              session.driverPubkey == driverPubkey else {
            return
        }

        selectedPaymentMethod = session.paymentMethod ?? primaryPaymentMethod
        pickupLocation = pickup
        destinationLocation = destination
        currentFareEstimate = fareEstimate
    }

    public func cancelRide(reason: String? = nil) async {
        await session.cancelRide(reason: reason)
    }

    public func sendChatMessage(_ text: String) async {
        guard let driverPubkey = session.driverPubkey,
              let confirmationId = session.confirmationEventId else {
            return
        }
        await chat.sendChatMessage(text, driverPubkey: driverPubkey, confirmationEventId: confirmationId)
    }

    public func closeCompletedRide() async {
        await session.dismissCompletedRide()
        clearCoordinatorUIState()
    }

    public func forceEndRide() async {
        recordRideHistory()
        await session.forceEndRide()
        clearCoordinatorUIState()
        rideStateRepository.clear()
    }

    public func stopAll() async {
        await chat.cleanup()
        await session.teardownAll()
        await location.stopAll()
    }

    private func restoreChatIfNeeded(stageBefore: RiderStage) {
        guard stageBefore.isActiveRide,
              session.stage.isActiveRide,
              let driverPubkey = session.driverPubkey,
              let confirmationId = session.confirmationEventId else {
            return
        }
        chat.subscribeToChat(driverPubkey: driverPubkey, confirmationEventId: confirmationId)
    }

    private func clearCoordinatorUIState(clearError: Bool = true) {
        currentFareEstimate = nil
        selectedPaymentMethod = nil
        pickupLocation = nil
        destinationLocation = nil
        if clearError {
            lastError = nil
        }
        chat.reset()
    }

    private func recordRideHistory() {
        guard let driverPubkey = session.driverPubkey,
              let confirmationId = session.confirmationEventId else {
            return
        }

        let pickup = pickupLocation ?? session.precisePickup ?? Location(latitude: 0, longitude: 0)
        let destination = destinationLocation ?? session.preciseDestination ?? Location(latitude: 0, longitude: 0)
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
            paymentMethod: session.paymentMethod ?? selectedPaymentMethod ?? PaymentMethod.cash.rawValue,
            distance: currentFareEstimate?.distanceMiles,
            duration: currentFareEstimate.map { Int($0.durationMinutes) }
        )
        rideHistory.addRide(entry)
        backupRideHistory()
    }

    /// Publish the current ride history to Nostr as a backup event.
    /// Fire-and-forget — marks dirty on failure so the next flush retries.
    public func backupRideHistory() {
        guard let service = roadflareDomainService,
              let syncStore = roadflareSyncStore else { return }
        Task {
            do {
                let content = RideHistoryBackupContent(rides: rideHistory.rides)
                let event = try await service.publishRideHistoryBackup(content)
                syncStore.markPublished(.rideHistory, at: event.createdAt)
            } catch {
                syncStore.markDirty(.rideHistory)
            }
        }
    }

    private static func duration(seconds: TimeInterval) -> Duration {
        .milliseconds(Int64((seconds * 1000).rounded()))
    }

    private func terminalMessage(for outcome: RideSessionTerminalOutcome) -> String? {
        switch outcome {
        case .completed:
            return nil
        case .cancelledByRider:
            return nil
        case .cancelledByDriver(let reason):
            if let reason, !reason.isEmpty {
                return "Driver cancelled the ride: \(reason)"
            }
            return "Driver cancelled the ride."
        case .expired(let stage):
            switch stage {
            case .waitingForAcceptance:
                return "Ride request expired before a driver responded."
            case .driverAccepted:
                return "Ride request expired before confirmation completed."
            default:
                return "Ride request expired."
            }
        case .bruteForcePin:
            return "Ride cancelled after too many incorrect PIN attempts."
        }
    }
}

extension RideCoordinator: RiderRideSessionDelegate {
    public func sessionDidReachTerminal(_ outcome: RideSessionTerminalOutcome) {
        if case .completed = outcome {
            recordRideHistory()
        } else {
            let message = terminalMessage(for: outcome)
            clearCoordinatorUIState(clearError: message == nil)
            lastError = message
        }
    }

    public func sessionDidEncounterError(_ error: Error) {
        lastError = error.localizedDescription
    }

    public func sessionDidChangeStage(from: RiderStage, to: RiderStage) {
        if !from.isActiveRide && to.isActiveRide,
           let driverPubkey = session.driverPubkey,
           let confirmationId = session.confirmationEventId {
            chat.subscribeToChat(driverPubkey: driverPubkey, confirmationEventId: confirmationId)
        }
        if to == .idle || to == .completed {
            chat.cleanupAsync()
        }
    }

    public func sessionShouldPersist() {
        if session.stage == .idle || session.stage == .completed {
            rideStateRepository.clear()
        } else {
            persistRideState()
        }
    }
}

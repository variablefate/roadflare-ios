import Foundation
import RidestrSDK

/// Thin app-layer adapter around `RiderRideSession`.
/// The SDK owns ride protocol/runtime behavior; the app owns UI state,
/// chat/location coordinators, and persistence mapping.
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

    let location: LocationCoordinator
    let chat: ChatCoordinator
    let session: RiderRideSession

    private let settings: UserSettings
    private let rideHistory: RideHistoryStore
    private let bitcoinPrice: BitcoinPriceService
    private let rideRestorePolicy: RideStatePersistence.RestorePolicy

    var currentFareEstimate: FareEstimate?
    var selectedPaymentMethod: String?
    var pickupLocation: Location?
    var destinationLocation: Location?
    var lastError: String?

    var driversRepository: FollowedDriversRepository { location.driversRepository }
    var chatMessages: [(id: String, text: String, isMine: Bool, timestamp: Int)] { chat.chatMessages }
    var activeRidePaymentMethods: [String] {
        if !session.fiatPaymentMethods.isEmpty {
            return session.fiatPaymentMethods
        }
        if let paymentMethod = session.paymentMethod {
            return [paymentMethod]
        }
        return []
    }

    init(
        relayManager: any RelayManagerProtocol,
        keypair: NostrKeypair,
        driversRepository: FollowedDriversRepository,
        settings: UserSettings,
        rideHistory: RideHistoryStore,
        bitcoinPrice: BitcoinPriceService? = nil,
        roadflareDomainService: RoadflareDomainService? = nil,
        roadflareSyncStore: RoadflareSyncStateStore? = nil,
        stageTimeouts: StageTimeouts = .interopDefault
    ) {
        self.settings = settings
        self.rideHistory = rideHistory
        self.bitcoinPrice = bitcoinPrice ?? BitcoinPriceService()
        self.rideRestorePolicy = Self.restorePolicy(for: stageTimeouts)
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

    func startLocationSubscriptions() { location.startLocationSubscriptions() }
    func startKeyShareSubscription() { location.startKeyShareSubscription() }
    func publishFollowedDriversList() async { await location.publishFollowedDriversList() }
    func requestKeyRefresh(driverPubkey: String) async { await location.requestKeyRefresh(driverPubkey: driverPubkey) }
    func checkForStaleKeys() async { await location.checkForStaleKeys() }

    func restoreRideState() {
        guard let saved = RideStatePersistence.load(restorePolicy: rideRestorePolicy),
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
            processedPinActionKeys: Set(saved.processedPinActionKeys ?? saved.processedPinTimestamps?.map(Self.legacyPinActionKey) ?? []),
            precisePickup: pickup,
            preciseDestination: destination,
            savedAt: saved.savedAt
        )

        guard session.stage == restoredStage else {
            RideStatePersistence.clear()
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
        RideStatePersistence.save(
            session: session,
            pickup: pickupLocation,
            destination: destinationLocation,
            fare: currentFareEstimate
        )
    }

    /// Safe to call repeatedly after launch or reconnect.
    func restoreLiveSubscriptions() async {
        await chat.cleanup()
        location.startLocationSubscriptions()
        location.startKeyShareSubscription()
        async let staleKeyRefresh: Void = driversRepository.hasDrivers ? location.checkForStaleKeys() : ()

        let stageBefore = session.stage
        await session.restoreSubscriptions()
        restoreChatIfNeeded(stageBefore: stageBefore)

        _ = await staleKeyRefresh
    }

    func sendRideOffer(
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

    func cancelRide(reason: String? = nil) async {
        await session.cancelRide(reason: reason)
    }

    func sendChatMessage(_ text: String) async {
        guard let driverPubkey = session.driverPubkey,
              let confirmationId = session.confirmationEventId else {
            return
        }
        await chat.sendChatMessage(text, driverPubkey: driverPubkey, confirmationEventId: confirmationId)
    }

    func closeCompletedRide() async {
        await session.dismissCompletedRide()
        clearCoordinatorUIState()
    }

    func stopAll() async {
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
    }

    private static func duration(seconds: TimeInterval) -> Duration {
        .milliseconds(Int64((seconds * 1000).rounded()))
    }

    private static func restorePolicy(for stageTimeouts: StageTimeouts) -> RideStatePersistence.RestorePolicy {
        RideStatePersistence.RestorePolicy(
            waitingForAcceptance: max(0, Int(stageTimeouts.waitingForAcceptance.rounded(.up))),
            driverAccepted: max(0, Int(stageTimeouts.driverAccepted.rounded(.up))),
            postConfirmation: Int(EventExpiration.rideConfirmationHours * 3600)
        )
    }

    private static func legacyPinActionKey(_ timestamp: Int) -> String {
        "pin_submit:\(timestamp)"
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
    func sessionDidReachTerminal(_ outcome: RideSessionTerminalOutcome) {
        if case .completed = outcome {
            recordRideHistory()
        } else {
            let message = terminalMessage(for: outcome)
            clearCoordinatorUIState(clearError: message == nil)
            lastError = message
        }
    }

    func sessionDidEncounterError(_ error: Error) {
        lastError = error.localizedDescription
    }

    func sessionDidChangeStage(from: RiderStage, to: RiderStage) {
        if !from.isActiveRide && to.isActiveRide,
           let driverPubkey = session.driverPubkey,
           let confirmationId = session.confirmationEventId {
            chat.subscribeToChat(driverPubkey: driverPubkey, confirmationEventId: confirmationId)
        }
        if to == .idle || to == .completed {
            chat.cleanupAsync()
        }
    }

    func sessionShouldPersist() {
        if session.stage == .idle || session.stage == .completed {
            RideStatePersistence.clear()
        } else {
            persistRideState()
        }
    }
}

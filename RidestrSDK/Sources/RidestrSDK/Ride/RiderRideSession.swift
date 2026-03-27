import Foundation

/// Manages the full rider ride lifecycle: subscriptions, timeouts, retries,
/// PIN deduplication, and state machine transitions.
///
/// The app creates a session, calls `sendOffer()`, observes state, and handles
/// terminal outcomes via the delegate. The session owns all protocol wiring;
/// the app owns UI data, chat/location coordinators, and persistence mapping.
@Observable
@MainActor
public final class RiderRideSession {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public struct StageTimeouts: Sendable, Equatable {
            public let waitingForAcceptance: Duration
            public let driverAccepted: Duration

            public init(waitingForAcceptance: Duration, driverAccepted: Duration) {
                self.waitingForAcceptance = waitingForAcceptance
                self.driverAccepted = driverAccepted
            }
        }

        public let stageTimeouts: StageTimeouts
        public let confirmationRetryDelays: [Duration]
        public let maxPinActionSetSize: Int

        public init(
            stageTimeouts: StageTimeouts,
            confirmationRetryDelays: [Duration],
            maxPinActionSetSize: Int
        ) {
            self.stageTimeouts = stageTimeouts
            self.confirmationRetryDelays = confirmationRetryDelays
            self.maxPinActionSetSize = maxPinActionSetSize
        }

        public static let `default` = Configuration(
            stageTimeouts: StageTimeouts(
                waitingForAcceptance: .seconds(120),
                driverAccepted: .seconds(30)
            ),
            confirmationRetryDelays: [.zero, .seconds(1), .seconds(3)],
            maxPinActionSetSize: 10
        )
    }

    // MARK: - Observable state (forwarded from state machine)

    public var stage: RiderStage { stateMachine.stage }
    public var pin: String? { stateMachine.pin }
    public var confirmationEventId: ConfirmationEventID? { stateMachine.confirmationEventId }
    public var offerEventId: EventID? { stateMachine.offerEventId }
    public var acceptanceEventId: EventID? { stateMachine.acceptanceEventId }
    public var driverPubkey: PublicKeyHex? { stateMachine.driverPubkey }
    public var pinVerified: Bool { stateMachine.pinVerified }
    public var pinAttempts: Int { stateMachine.pinAttempts }
    public var paymentMethod: String? { stateMachine.paymentMethod }
    public var fiatPaymentMethods: [String] { stateMachine.fiatPaymentMethods }
    public var precisePickupShared: Bool { stateMachine.precisePickupShared }
    public var preciseDestinationShared: Bool { stateMachine.preciseDestinationShared }
    public var riderStateHistory: [RiderRideAction] { stateMachine.riderStateHistory }

    // MARK: - Safe cursor

    // Diverges from the state machine's cursor intentionally. The state machine
    // always advances its cursor immediately when a driver state event is processed.
    // This session-owned cursor only advances once ALL PIN actions from that event
    // have been fully processed. This ensures that if the app is killed during PIN
    // processing, the persisted cursor doesn't skip past unprocessed PIN actions,
    // so on relaunch the driver state event is re-fetched and PINs re-processed.
    public private(set) var lastDriverStatus: String?
    public private(set) var lastDriverStateTimestamp: Int = 0
    public private(set) var lastDriverActionCount: Int = 0

    // MARK: - Session-owned state

    public private(set) var lastError: Error?
    public private(set) var precisePickup: Location?
    public private(set) var preciseDestination: Location?
    public var processedPinActionKeys: Set<String> { pinDeduplicator.processedKeys }

    // MARK: - Delegate

    public weak var delegate: (any RiderRideSessionDelegate)?

    // MARK: - Internal components

    let stateMachine: RideStateMachine
    let domainService: RiderRideDomainService
    let configuration: Configuration
    var pinDeduplicator: PinActionDeduplicator

    // MARK: - Init

    public init(
        relayManager: any RelayManagerProtocol,
        keypair: NostrKeypair,
        configuration: Configuration = .default
    ) {
        self.stateMachine = RideStateMachine(riderPubkey: keypair.publicKeyHex)
        self.domainService = RiderRideDomainService(relayManager: relayManager, keypair: keypair)
        self.configuration = configuration
        self.pinDeduplicator = PinActionDeduplicator(maxCombinedSize: configuration.maxPinActionSetSize)
    }

    // MARK: - Restore

    /// Restore session from persisted state after app relaunch.
    public func restore(
        stage: RiderStage,
        offerEventId: String?,
        acceptanceEventId: String?,
        confirmationEventId: String?,
        driverPubkey: String?,
        pin: String?,
        pinAttempts: Int = 0,
        pinVerified: Bool,
        paymentMethod: String?,
        fiatPaymentMethods: [String],
        precisePickupShared: Bool = false,
        preciseDestinationShared: Bool = false,
        lastDriverStatus: String? = nil,
        lastDriverStateTimestamp: Int = 0,
        lastDriverActionCount: Int = 0,
        riderStateHistory: [RiderRideAction] = [],
        processedPinActionKeys: Set<String> = [],
        precisePickup: Location? = nil,
        preciseDestination: Location? = nil,
        savedAt: Int = 0
    ) {
        stateMachine.restore(
            stage: stage,
            offerEventId: offerEventId,
            acceptanceEventId: acceptanceEventId,
            confirmationEventId: confirmationEventId,
            driverPubkey: driverPubkey,
            pin: pin,
            pinAttempts: pinAttempts,
            pinVerified: pinVerified,
            paymentMethod: paymentMethod,
            fiatPaymentMethods: fiatPaymentMethods,
            precisePickupShared: precisePickupShared,
            preciseDestinationShared: preciseDestinationShared,
            lastDriverStatus: lastDriverStatus,
            lastDriverStateTimestamp: lastDriverStateTimestamp,
            lastDriverActionCount: lastDriverActionCount,
            riderStateHistory: riderStateHistory
        )
        // If the state machine rejected the restore (e.g., nil driverPubkey for
        // a non-idle stage), it reset to idle. Clear session-owned state to match.
        guard stateMachine.stage == stage else {
            reset()
            return
        }
        self.pinDeduplicator = PinActionDeduplicator(
            processedKeys: processedPinActionKeys,
            maxCombinedSize: configuration.maxPinActionSetSize
        )
        self.lastDriverStatus = lastDriverStatus
        self.lastDriverStateTimestamp = lastDriverStateTimestamp
        self.lastDriverActionCount = lastDriverActionCount
        self.precisePickup = precisePickup
        self.preciseDestination = preciseDestination
        self.lastError = nil
        self.restoredSavedAt = savedAt
    }

    // Stored for timeout math during restoreSubscriptions().
    var restoredSavedAt: Int = 0

    // MARK: - Reset

    public func reset() {
        stateMachine.reset()
        pinDeduplicator.reset()
        lastDriverStatus = nil
        lastDriverStateTimestamp = 0
        lastDriverActionCount = 0
        precisePickup = nil
        preciseDestination = nil
        lastError = nil
        restoredSavedAt = 0
    }
}

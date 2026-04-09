import Foundation

// MARK: - Persistence Protocol

/// Abstract storage for ride state. iOS implements with UserDefaults;
/// tests use InMemoryRideStatePersistence.
public protocol RideStatePersistence: Sendable {
    func saveRaw(_ state: PersistedRideState)
    func loadRaw() -> PersistedRideState?
    func clear()
}

// MARK: - Restoration Policy

/// Defines how long each ride stage remains valid for restoration.
/// The SDK is the single authority on ride state expiration.
public struct RideStateRestorationPolicy: Sendable, Equatable {
    public let waitingForAcceptance: Int
    public let driverAccepted: Int
    public let postConfirmation: Int

    public init(waitingForAcceptance: Int, driverAccepted: Int, postConfirmation: Int) {
        self.waitingForAcceptance = waitingForAcceptance
        self.driverAccepted = driverAccepted
        self.postConfirmation = postConfirmation
    }

    /// Default policy using protocol constants.
    public static let `default` = RideStateRestorationPolicy(
        waitingForAcceptance: Int(RideConstants.broadcastTimeoutSeconds),
        driverAccepted: Int(RideConstants.confirmationTimeoutSeconds),
        postConfirmation: Int(EventExpiration.rideConfirmationHours * 3600)
    )

    /// Max restore age in seconds for a given stage.
    public func maxRestoreAge(for stage: String) -> Int {
        switch stage {
        case RiderStage.waitingForAcceptance.rawValue:
            waitingForAcceptance
        case RiderStage.driverAccepted.rawValue:
            driverAccepted
        default:
            postConfirmation
        }
    }
}

// MARK: - Repository

/// Manages ride state persistence with SDK-owned validation.
/// The app never sees expired, idle, or legacy-format data.
public final class RideStateRepository: @unchecked Sendable {
    private let persistence: RideStatePersistence
    private let policy: RideStateRestorationPolicy

    public init(
        persistence: RideStatePersistence,
        policy: RideStateRestorationPolicy = .default
    ) {
        self.persistence = persistence
        self.policy = policy
    }

    public func save(_ state: PersistedRideState) {
        persistence.saveRaw(state)
    }

    /// Load validated ride state. Returns nil if expired, idle, completed,
    /// or has an unknown/corrupt stage. Applies legacy field migration.
    public func load(now: Date = .now) -> PersistedRideState? {
        guard let raw = persistence.loadRaw() else { return nil }

        // Reject unknown/corrupt stages — SDK owns the full validation
        guard let stage = RiderStage(rawValue: raw.stage) else {
            persistence.clear()
            return nil
        }

        let age = Int(now.timeIntervalSince1970) - raw.savedAt
        guard age < policy.maxRestoreAge(for: raw.stage) else {
            persistence.clear()
            return nil
        }

        guard stage != .idle, stage != .completed else {
            persistence.clear()
            return nil
        }

        return raw.migrated()
    }

    public func clear() {
        persistence.clear()
    }
}

// MARK: - In-Memory Test Double

public final class InMemoryRideStatePersistence: RideStatePersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PersistedRideState?

    public init() {}

    public func saveRaw(_ state: PersistedRideState) {
        lock.withLock { stored = state }
    }

    public func loadRaw() -> PersistedRideState? {
        lock.withLock { stored }
    }

    public func clear() {
        lock.withLock { stored = nil }
    }
}

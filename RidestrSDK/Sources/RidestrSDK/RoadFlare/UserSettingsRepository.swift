import Foundation

/// Manages the rider's user settings (profile name, payment methods, onboarding state).
///
/// Persists via a delegate and fires sync callbacks for protocol-backed fields
/// (profile name → Kind 0; payment methods → Kind 30177). Profile-completed
/// state is app-local and not synced.
///
/// Thread safety: All mutations are protected by an internal lock. Callbacks
/// are `@Sendable` and fire after the lock is released. Safe to call from any
/// single thread; not safe under concurrent writers (matches sibling SDK repo
/// pattern). Current callers are `@MainActor`-serialized.
@Observable
public final class UserSettingsRepository: @unchecked Sendable {
    /// The user's display name, as set locally or restored from Kind 0.
    public private(set) var profileName: String = ""

    /// Ordered RoadFlare payment methods shared with backup + ride offers.
    public private(set) var roadflarePaymentMethods: [String] = []

    /// Whether onboarding is complete. App-local, never synced to Nostr.
    public private(set) var profileCompleted: Bool = false

    /// Fires when `profileName` changes. Maps to Kind 0 sync.
    public var onProfileChanged: (@Sendable () -> Void)?

    /// Fires when `roadflarePaymentMethods` changes. Maps to Kind 30177 sync.
    public var onProfileBackupChanged: (@Sendable () -> Void)?

    private let persistence: UserSettingsPersistence
    private let lock = NSLock()
    private var suppressChangeNotifications = false

    public init(persistence: UserSettingsPersistence) {
        self.persistence = persistence
        let snap = persistence.load()
        self.profileName = snap.profileName
        self.roadflarePaymentMethods = snap.roadflarePaymentMethods
        self.profileCompleted = snap.profileCompleted
    }

    // MARK: - Profile

    /// Set the user's profile name. Silently no-ops when trying to set an
    /// empty name over an existing non-empty name unless `allowEmpty: true`.
    /// Returns `true` if the value was applied (including no-op on identical
    /// value), `false` only when the empty-guard rejected the write.
    @discardableResult
    public func setProfileName(_ name: String, allowEmpty: Bool = false) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let outcome: SetOutcome = lock.withLock {
            let previousTrimmed = profileName.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty && !previousTrimmed.isEmpty && !allowEmpty {
                return .rejected
            }
            guard profileName != name else { return .unchanged }
            profileName = name
            return .applied
        }
        switch outcome {
        case .rejected: return false
        case .unchanged: return true
        case .applied:
            persistence.save(snapshot())
            notifyProfileChanged()
            return true
        }
    }

    public func setProfileCompleted(_ completed: Bool) {
        let changed: Bool = lock.withLock {
            guard profileCompleted != completed else { return false }
            profileCompleted = completed
            return true
        }
        guard changed else { return }
        persistence.save(snapshot())
        // No notification — profileCompleted is app-state only.
    }

    // MARK: - Payment Methods
    //
    // All mutators route through `setRoadflarePaymentMethods` so normalization,
    // persistence, and `onProfileBackupChanged` notification happen in exactly
    // one place.

    public func setRoadflarePaymentMethods(_ methods: [String]) {
        let normalized = RoadflarePaymentPreferences.normalize(methods)
        let changed: Bool = lock.withLock {
            guard roadflarePaymentMethods != normalized else { return false }
            roadflarePaymentMethods = normalized
            return true
        }
        guard changed else { return }
        persistence.save(snapshot())
        notifyProfileBackupChanged()
    }

    public func togglePaymentMethod(_ method: PaymentMethod) {
        var current = lock.withLock { roadflarePaymentMethods }
        if isEnabled(method) {
            current.removeAll { $0 == method.rawValue }
            if current.isEmpty { current = [PaymentMethod.cash.rawValue] }
        } else {
            current.append(method.rawValue)
        }
        setRoadflarePaymentMethods(current)
    }

    public func toggleRoadflarePaymentMethod(_ method: String) {
        let normalized = PaymentMethod.canonicalRoadflareRawValue(for: method)
            ?? method.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let key = normalizedMethodKey(normalized)
        var current = lock.withLock { roadflarePaymentMethods }
        if current.contains(where: { normalizedMethodKey($0) == key }) {
            current.removeAll { normalizedMethodKey($0) == key }
            if current.isEmpty { current = [PaymentMethod.cash.rawValue] }
        } else {
            current.append(normalized)
        }
        setRoadflarePaymentMethods(current)
    }

    @discardableResult
    public func addCustomPaymentMethod(_ name: String) -> CustomPaymentMethodAddResult {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }
        let canonical = PaymentMethod.canonicalRoadflareRawValue(for: trimmed) ?? trimmed
        let key = normalizedMethodKey(canonical)
        var current = lock.withLock { roadflarePaymentMethods }
        guard !current.contains(where: { normalizedMethodKey($0) == key }) else {
            return .duplicate
        }
        current.append(canonical)
        setRoadflarePaymentMethods(current)
        return .added
    }

    public func removeCustomPaymentMethod(_ name: String) {
        let key = normalizedMethodKey(name)
        var current = lock.withLock { roadflarePaymentMethods }
        current.removeAll {
            PaymentMethod(rawValue: $0) == nil && normalizedMethodKey($0) == key
        }
        setRoadflarePaymentMethods(current)
    }

    public func moveRoadflarePaymentMethods(fromOffsets: IndexSet, toOffset: Int) {
        var methods = lock.withLock { roadflarePaymentMethods }
        let moving = fromOffsets.map { methods[$0] }
        for index in fromOffsets.sorted(by: >) { methods.remove(at: index) }
        let adjustedOffset = min(toOffset, methods.count)
        methods.insert(contentsOf: moving, at: adjustedOffset)
        setRoadflarePaymentMethods(methods)
    }

    // MARK: - Computed helpers (read-only)

    public var paymentMethods: [PaymentMethod] {
        lock.withLock { roadflarePaymentMethods }.compactMap { PaymentMethod(rawValue: $0) }
    }

    public var customPaymentMethods: [String] {
        lock.withLock { roadflarePaymentMethods }.filter { PaymentMethod(rawValue: $0) == nil }
    }

    public var isCashForced: Bool {
        lock.withLock { roadflarePaymentMethods } == [PaymentMethod.cash.rawValue]
    }

    public var roadflarePrimaryPaymentMethod: String? {
        let current = lock.withLock { roadflarePaymentMethods }
        return RoadflarePaymentPreferences(methods: current).primaryMethod
    }

    public var roadflareMethodChoices: [String] {
        let current = lock.withLock { roadflarePaymentMethods }
        let known = PaymentMethod.roadflareAlternates.map(\.rawValue)
        return RoadflarePaymentPreferences.normalize(
            known + current.filter { PaymentMethod(rawValue: $0) == nil }
        )
    }

    public var allPaymentMethodNames: [String] {
        lock.withLock { roadflarePaymentMethods }.map(RoadflarePaymentPreferences.displayName(for:))
    }

    public func isEnabled(_ method: PaymentMethod) -> Bool {
        lock.withLock { roadflarePaymentMethods }.contains(method.rawValue)
    }

    public func isRoadflareMethodEnabled(_ method: String) -> Bool {
        let key = normalizedMethodKey(method)
        return lock.withLock { roadflarePaymentMethods }.contains { normalizedMethodKey($0) == key }
    }

    // MARK: - Sync helpers

    /// Suppress change notifications during sync restore.
    public func performWithoutChangeTracking(_ updates: () -> Void) {
        let previous = suppressChangeNotifications
        suppressChangeNotifications = true
        updates()
        suppressChangeNotifications = previous
    }

    // MARK: - Cleanup

    public func clearAll() {
        performWithoutChangeTracking {
            lock.withLock {
                profileName = ""
                roadflarePaymentMethods = []
                profileCompleted = false
            }
        }
        persistence.clearAll()
    }

    // MARK: - Private

    private func snapshot() -> UserSettingsSnapshot {
        lock.withLock {
            UserSettingsSnapshot(
                profileName: profileName,
                roadflarePaymentMethods: roadflarePaymentMethods,
                profileCompleted: profileCompleted
            )
        }
    }

    private func notifyProfileChanged() {
        guard !suppressChangeNotifications else { return }
        onProfileChanged?()
    }

    private func notifyProfileBackupChanged() {
        guard !suppressChangeNotifications else { return }
        onProfileBackupChanged?()
    }

    /// Case- and diacritic-insensitive equality key for custom method matching.
    private func normalizedMethodKey(_ method: String) -> String {
        method.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private enum SetOutcome { case applied, unchanged, rejected }
}

// MARK: - Snapshot

public struct UserSettingsSnapshot: Sendable, Equatable {
    public var profileName: String
    public var roadflarePaymentMethods: [String]
    public var profileCompleted: Bool

    public init(
        profileName: String = "",
        roadflarePaymentMethods: [String] = [],
        profileCompleted: Bool = false
    ) {
        self.profileName = profileName
        self.roadflarePaymentMethods = roadflarePaymentMethods
        self.profileCompleted = profileCompleted
    }
}

// MARK: - Persistence

/// Abstraction for user settings storage. Inject for testability.
public protocol UserSettingsPersistence: Sendable {
    func load() -> UserSettingsSnapshot
    func save(_ snapshot: UserSettingsSnapshot)
    func clearAll()
}

/// In-memory persistence for testing.
public final class InMemoryUserSettingsPersistence: UserSettingsPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var stored = UserSettingsSnapshot()

    public init() {}
    public init(initial: UserSettingsSnapshot) { self.stored = initial }

    public func load() -> UserSettingsSnapshot { lock.withLock { stored } }
    public func save(_ snapshot: UserSettingsSnapshot) { lock.withLock { stored = snapshot } }
    public func clearAll() { lock.withLock { stored = UserSettingsSnapshot() } }
}

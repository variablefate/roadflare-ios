import Foundation
@testable import RidestrSDK

/// Enhanced mock relay manager for testing.
/// Supports both immediate event delivery and deferred injection via continuations.
public final class FakeRelayManager: RelayManagerProtocol, @unchecked Sendable {
    private let lock = NSLock()

    // MARK: - Call Recording

    private var _publishedEvents: [NostrEvent] = []
    public var publishedEvents: [NostrEvent] {
        lock.withLock { _publishedEvents }
    }

    private var _connectCalls: [[URL]] = []
    public var connectCalls: [[URL]] {
        lock.withLock { _connectCalls }
    }

    private var _disconnectCount = 0
    public var disconnectCount: Int {
        lock.withLock { _disconnectCount }
    }

    private var _subscribeCalls: [(filter: NostrFilter, id: SubscriptionID)] = []
    public var subscribeCalls: [(filter: NostrFilter, id: SubscriptionID)] {
        lock.withLock { _subscribeCalls }
    }

    private var _unsubscribeCalls: [SubscriptionID] = []
    public var unsubscribeCalls: [SubscriptionID] {
        lock.withLock { _unsubscribeCalls }
    }

    private var _fetchCalls: [(filter: NostrFilter, timeout: TimeInterval)] = []
    public var fetchCalls: [(filter: NostrFilter, timeout: TimeInterval)] {
        lock.withLock { _fetchCalls }
    }

    // MARK: - Configuration

    public var shouldFailConnect = false
    public var shouldFailPublish = false
    public var shouldFailSubscribe = false
    public var subscribeDelay: Duration?
    public var publishDelay: Duration?
    private var _isConnected = false

    // MARK: - Publish-started signaling

    private var _publishStartedContinuation: CheckedContinuation<Void, Never>?
    private let _publishStartedLock = NSLock()

    /// Suspends the caller until the next `publish(_:)` call begins executing.
    ///
    /// Tests use this to replace fragile time-based sleeps with a deterministic
    /// suspension point: after `waitForNextPublish()` returns, the publish Task has
    /// definitely entered `relay.publish` and is suspended on its delay (if any).
    public func waitForNextPublish() async {
        await withCheckedContinuation { cont in
            _publishStartedLock.withLock { _publishStartedContinuation = cont }
        }
    }

    /// Events to return immediately from subscribe calls, keyed by subscription ID.
    public var subscriptionEvents: [String: [NostrEvent]] = [:]

    /// Events to return from fetchEvents calls.
    public var fetchResults: [NostrEvent] = []

    /// Live subscription continuations for deferred event injection.
    private var _liveContinuations: [String: AsyncStream<NostrEvent>.Continuation] = [:]
    private var _subscriptionGenerations: [String: UInt64] = [:]

    /// When true, subscription streams stay open for deferred injection.
    /// When false (default), streams finish immediately after yielding canned events.
    public var keepSubscriptionsAlive = false

    public init() {}

    // MARK: - Protocol

    public func connect(to relays: [URL]) async throws {
        if shouldFailConnect {
            throw RidestrError.relay(.connectionFailed(relays.first ?? URL(string: "wss://fake")!, underlying: FakeError.simulated))
        }
        lock.withLock {
            _connectCalls.append(relays)
            _isConnected = true
        }
    }

    public func disconnect() async {
        let continuations = lock.withLock { () -> [AsyncStream<NostrEvent>.Continuation] in
            _disconnectCount += 1
            _isConnected = false
            let continuations = Array(_liveContinuations.values)
            _liveContinuations.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    public var isConnected: Bool {
        lock.withLock { _isConnected }
    }

    public func reconnectIfNeeded() async {
        // No-op in fake — tests control connection state directly
    }

    public func publish(_ event: NostrEvent) async throws -> String {
        // Signal any waiting `waitForNextPublish()` caller before doing any work.
        let pendingCont = _publishStartedLock.withLock { () -> CheckedContinuation<Void, Never>? in
            let c = _publishStartedContinuation
            _publishStartedContinuation = nil
            return c
        }
        pendingCont?.resume()

        if shouldFailPublish {
            throw RidestrError.relay(.notConnected)
        }
        if let publishDelay {
            try? await Task.sleep(for: publishDelay)
        }
        lock.withLock { _publishedEvents.append(event) }
        return event.id
    }

    public func subscribe(filter: NostrFilter, id: SubscriptionID) async throws -> AsyncStream<NostrEvent> {
        if shouldFailSubscribe {
            throw RidestrError.relay(.notConnected)
        }
        lock.withLock { _subscribeCalls.append((filter, id)) }
        let generation = lock.withLock { nextSubscriptionGeneration(for: id.rawValue) }

        let immediateEvents = subscriptionEvents[id.rawValue] ?? []
        if let subscribeDelay {
            try? await Task.sleep(for: subscribeDelay)
        }

        let (stream, continuation) = AsyncStream<NostrEvent>.makeStream()
        let isCurrent = lock.withLock { _subscriptionGenerations[id.rawValue] == generation }
        guard isCurrent else {
            continuation.finish()
            return stream
        }

        // Store continuation for deferred injection
        lock.withLock {
            _liveContinuations[id.rawValue] = continuation
        }

        // Yield immediate events
        for event in immediateEvents {
            continuation.yield(event)
        }

        if keepSubscriptionsAlive {
            // Keep stream alive for deferred injection
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?._liveContinuations[id.rawValue] = nil
                }
            }
        } else {
            // Default: finish immediately (safe for existing tests)
            lock.withLock { _liveContinuations[id.rawValue] = nil }
            continuation.finish()
        }

        return stream
    }

    public func unsubscribe(_ id: SubscriptionID) async {
        let continuation = lock.withLock { () -> AsyncStream<NostrEvent>.Continuation? in
            _unsubscribeCalls.append(id)
            _ = nextSubscriptionGeneration(for: id.rawValue)
            return _liveContinuations.removeValue(forKey: id.rawValue)
        }
        continuation?.finish()
    }

    public func fetchEvents(filter: NostrFilter, timeout: TimeInterval) async throws -> [NostrEvent] {
        lock.withLock { _fetchCalls.append((filter, timeout)) }
        return fetchResults
    }

    // MARK: - Deferred Event Injection

    /// Inject an event into a live subscription stream. Returns true if delivered.
    public func injectEvent(_ event: NostrEvent, subscriptionId: String) -> Bool {
        lock.withLock {
            if let cont = _liveContinuations[subscriptionId] {
                cont.yield(event)
                return true
            }
            return false
        }
    }

    /// Finish a live subscription stream (simulates relay closing the subscription).
    public func finishSubscription(_ subscriptionId: String) {
        let continuation = lock.withLock {
            _liveContinuations.removeValue(forKey: subscriptionId)
        }
        continuation?.finish()
    }

    /// Number of active live subscriptions.
    public var activeSubscriptionCount: Int {
        lock.withLock { _liveContinuations.count }
    }

    /// Whether a specific subscription is currently active.
    public func isSubscriptionActive(_ subscriptionId: String) -> Bool {
        lock.withLock { _liveContinuations[subscriptionId] != nil }
    }

    /// Clear all recorded calls (for multi-step test scenarios).
    public func resetRecording() {
        lock.withLock {
            _publishedEvents.removeAll()
            _connectCalls.removeAll()
            _disconnectCount = 0
            _subscribeCalls.removeAll()
            _unsubscribeCalls.removeAll()
            _fetchCalls.removeAll()
        }
    }

    enum FakeError: Error {
        case simulated
    }

    private func nextSubscriptionGeneration(for id: String) -> UInt64 {
        let next = (_subscriptionGenerations[id] ?? 0) + 1
        _subscriptionGenerations[id] = next
        return next
    }
}

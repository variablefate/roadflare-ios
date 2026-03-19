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
    private var _isConnected = false

    /// Events to return immediately from subscribe calls, keyed by subscription ID.
    public var subscriptionEvents: [String: [NostrEvent]] = [:]

    /// Events to return from fetchEvents calls.
    public var fetchResults: [NostrEvent] = []

    /// Live subscription continuations for deferred event injection.
    private var _liveContinuations: [String: AsyncStream<NostrEvent>.Continuation] = [:]

    /// When true, subscription streams stay open for deferred injection.
    /// When false (default), streams finish immediately after yielding canned events.
    public var keepSubscriptionsAlive = false

    public init() {}

    // MARK: - Protocol

    public func connect(to relays: [URL]) async throws {
        if shouldFailConnect {
            throw RidestrError.relayConnectionFailed(relays.first ?? URL(string: "wss://fake")!, underlying: FakeError.simulated)
        }
        lock.withLock {
            _connectCalls.append(relays)
            _isConnected = true
        }
    }

    public func disconnect() async {
        lock.withLock {
            _disconnectCount += 1
            _isConnected = false
            // Finish all live continuations
            for (_, cont) in _liveContinuations {
                cont.finish()
            }
            _liveContinuations.removeAll()
        }
    }

    public var isConnected: Bool {
        lock.withLock { _isConnected }
    }

    public func publish(_ event: NostrEvent) async throws -> String {
        if shouldFailPublish {
            throw RidestrError.relayNotConnected
        }
        lock.withLock { _publishedEvents.append(event) }
        return event.id
    }

    public func subscribe(filter: NostrFilter, id: SubscriptionID) async throws -> AsyncStream<NostrEvent> {
        if shouldFailSubscribe {
            throw RidestrError.relayNotConnected
        }
        lock.withLock { _subscribeCalls.append((filter, id)) }

        let immediateEvents = subscriptionEvents[id.rawValue] ?? []

        let (stream, continuation) = AsyncStream<NostrEvent>.makeStream()

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
        lock.withLock {
            _unsubscribeCalls.append(id)
            _liveContinuations[id.rawValue]?.finish()
            _liveContinuations[id.rawValue] = nil
        }
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
        lock.withLock {
            _liveContinuations[subscriptionId]?.finish()
            _liveContinuations[subscriptionId] = nil
        }
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
}

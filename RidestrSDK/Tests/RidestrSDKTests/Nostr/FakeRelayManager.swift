import Foundation
@testable import RidestrSDK

/// Mock relay manager for unit testing. Records calls and returns canned responses.
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

    /// Events to return from subscribe calls, keyed by subscription ID.
    public var subscriptionEvents: [String: [NostrEvent]] = [:]

    /// Events to return from fetchEvents calls.
    public var fetchResults: [NostrEvent] = []

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

        let events = subscriptionEvents[id.rawValue] ?? []
        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    public func unsubscribe(_ id: SubscriptionID) async {
        lock.withLock { _unsubscribeCalls.append(id) }
    }

    public func fetchEvents(filter: NostrFilter, timeout: TimeInterval) async throws -> [NostrEvent] {
        lock.withLock { _fetchCalls.append((filter, timeout)) }
        return fetchResults
    }

    enum FakeError: Error {
        case simulated
    }
}

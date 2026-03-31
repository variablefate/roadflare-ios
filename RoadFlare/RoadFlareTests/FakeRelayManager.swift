import Foundation
@testable import RidestrSDK

/// App-test-local relay manager fake.
/// Mirrors the SDK test helper closely enough for RoadFlare view-model tests.
final class FakeRelayManager: RelayManagerProtocol, @unchecked Sendable {
    private let lock = NSLock()

    private var _publishedEvents: [NostrEvent] = []
    var publishedEvents: [NostrEvent] { lock.withLock { _publishedEvents } }

    private var _subscribeCalls: [(filter: NostrFilter, id: SubscriptionID)] = []
    var subscribeCalls: [(filter: NostrFilter, id: SubscriptionID)] { lock.withLock { _subscribeCalls } }

    private var _unsubscribeCalls: [SubscriptionID] = []
    var unsubscribeCalls: [SubscriptionID] { lock.withLock { _unsubscribeCalls } }

    private var _fetchCalls: [(filter: NostrFilter, timeout: TimeInterval)] = []
    var fetchCalls: [(filter: NostrFilter, timeout: TimeInterval)] { lock.withLock { _fetchCalls } }

    private var _isConnected = false
    var shouldFailConnect = false
    var shouldFailPublish = false
    var shouldFailSubscribe = false
    var keepSubscriptionsAlive = false
    var publishDelay: Duration?
    var subscribeDelay: Duration?
    var fetchResults: [NostrEvent] = []

    private var liveContinuations: [String: AsyncStream<NostrEvent>.Continuation] = [:]
    private var subscriptionGenerations: [String: UInt64] = [:]

    func connect(to relays: [URL]) async throws {
        if shouldFailConnect {
            throw RidestrError.relay(.connectionFailed(relays.first ?? URL(string: "wss://fake")!, underlying: URLError(.cannotConnectToHost)))
        }
        lock.withLock { _isConnected = true }
    }

    func disconnect() async {
        let continuations = lock.withLock { () -> [AsyncStream<NostrEvent>.Continuation] in
            _isConnected = false
            let continuations = Array(liveContinuations.values)
            liveContinuations.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    var isConnected: Bool {
        get async { lock.withLock { _isConnected } }
    }

    func reconnectIfNeeded() async {
        // No-op for tests.
    }

    func publish(_ event: NostrEvent) async throws -> String {
        if shouldFailPublish {
            throw RidestrError.relay(.notConnected)
        }
        if let publishDelay {
            try? await Task.sleep(for: publishDelay)
        }
        lock.withLock { _publishedEvents.append(event) }
        return event.id
    }

    func subscribe(filter: NostrFilter, id: SubscriptionID) async throws -> AsyncStream<NostrEvent> {
        if shouldFailSubscribe {
            throw RidestrError.relay(.notConnected)
        }
        lock.withLock { _subscribeCalls.append((filter, id)) }
        let generation = lock.withLock { nextSubscriptionGeneration(for: id.rawValue) }

        let immediateEvents: [NostrEvent] = []
        if let subscribeDelay {
            try? await Task.sleep(for: subscribeDelay)
        }

        let (stream, continuation) = AsyncStream<NostrEvent>.makeStream()
        let isCurrent = lock.withLock { subscriptionGenerations[id.rawValue] == generation }
        guard isCurrent else {
            continuation.finish()
            return stream
        }

        lock.withLock { liveContinuations[id.rawValue] = continuation }

        for event in immediateEvents {
            continuation.yield(event)
        }

        if !keepSubscriptionsAlive {
            lock.withLock {
                if subscriptionGenerations[id.rawValue] == generation {
                    liveContinuations[id.rawValue] = nil
                }
            }
            continuation.finish()
        } else {
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.liveContinuations[id.rawValue] = nil
                }
            }
        }

        return stream
    }

    func unsubscribe(_ id: SubscriptionID) async {
        let continuation = lock.withLock { () -> AsyncStream<NostrEvent>.Continuation? in
            _unsubscribeCalls.append(id)
            _ = nextSubscriptionGeneration(for: id.rawValue)
            return liveContinuations.removeValue(forKey: id.rawValue)
        }
        continuation?.finish()
    }

    func fetchEvents(filter: NostrFilter, timeout: TimeInterval) async throws -> [NostrEvent] {
        lock.withLock { _fetchCalls.append((filter, timeout)) }
        return fetchResults
    }

    func injectEvent(_ event: NostrEvent, subscriptionId: String) -> Bool {
        lock.withLock {
            guard let continuation = liveContinuations[subscriptionId] else { return false }
            continuation.yield(event)
            return true
        }
    }

    var activeSubscriptionCount: Int {
        lock.withLock { liveContinuations.count }
    }

    func isSubscriptionActive(_ subscriptionId: String) -> Bool {
        lock.withLock { liveContinuations[subscriptionId] != nil }
    }

    func resetRecording() {
        lock.withLock {
            _publishedEvents.removeAll()
            _subscribeCalls.removeAll()
            _unsubscribeCalls.removeAll()
            _fetchCalls.removeAll()
        }
    }

    private func nextSubscriptionGeneration(for id: String) -> UInt64 {
        let next = (subscriptionGenerations[id] ?? 0) + 1
        subscriptionGenerations[id] = next
        return next
    }
}

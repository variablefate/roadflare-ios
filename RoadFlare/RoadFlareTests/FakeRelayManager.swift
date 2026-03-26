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
    var fetchResults: [NostrEvent] = []

    private var liveContinuations: [String: AsyncStream<NostrEvent>.Continuation] = [:]

    func connect(to relays: [URL]) async throws {
        if shouldFailConnect {
            throw RidestrError.relay(.connectionFailed(relays.first ?? URL(string: "wss://fake")!, underlying: URLError(.cannotConnectToHost)))
        }
        lock.withLock { _isConnected = true }
    }

    func disconnect() async {
        lock.withLock {
            _isConnected = false
            for (_, continuation) in liveContinuations {
                continuation.finish()
            }
            liveContinuations.removeAll()
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

        let immediateEvents: [NostrEvent] = []
        let (stream, continuation) = AsyncStream<NostrEvent>.makeStream()

        lock.withLock { liveContinuations[id.rawValue] = continuation }

        for event in immediateEvents {
            continuation.yield(event)
        }

        if !keepSubscriptionsAlive {
            lock.withLock { liveContinuations[id.rawValue] = nil }
            continuation.finish()
        } else {
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.liveContinuations[id.rawValue] = nil }
            }
        }

        return stream
    }

    func unsubscribe(_ id: SubscriptionID) async {
        lock.withLock {
            _unsubscribeCalls.append(id)
            liveContinuations[id.rawValue]?.finish()
            liveContinuations[id.rawValue] = nil
        }
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

    func resetRecording() {
        lock.withLock {
            _publishedEvents.removeAll()
            _subscribeCalls.removeAll()
            _unsubscribeCalls.removeAll()
            _fetchCalls.removeAll()
        }
    }
}

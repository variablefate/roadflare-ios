import Foundation

/// Protocol for relay management operations. Abstracted for testability.
///
/// The SDK provides `RelayManager` (actor-based, uses rust-nostr) as the production implementation.
/// For testing, use `FakeRelayManager` from the test target.
///
/// ## Subscription Lifecycle
///
/// 1. Call `subscribe(filter:id:)` to start receiving events matching the filter.
/// 2. Iterate the returned `AsyncStream` to receive events in real-time.
/// 3. Call `unsubscribe(_:)` when done to release relay resources.
///
/// For one-shot queries (fetch all matching events, then stop), use `fetchEvents(filter:timeout:)`.
///
/// ## Publishing
///
/// Use `publish(_:)` for fire-and-forget publishing.
/// Use `publishWithRetry(_:maxAttempts:initialDelay:)` for critical events (offers, confirmations,
/// cancellations) that must survive transient relay failures.
public protocol RelayManagerProtocol: Sendable {
    /// Connect to the given relay URLs.
    /// - Parameter relays: Relay WebSocket URLs (e.g., `wss://relay.damus.io`).
    func connect(to relays: [URL]) async throws

    /// Disconnect from all relays and cancel all subscriptions.
    func disconnect() async

    /// Publish a signed event to all connected relays.
    /// - Parameter event: The signed Nostr event to publish.
    /// - Returns: The event ID on success.
    /// - Throws: `RidestrError.relay(.notConnected)` if not connected.
    func publish(_ event: NostrEvent) async throws -> String

    /// Subscribe to events matching a filter. Returns an async stream of events.
    /// The stream includes both stored events (replayed via EOSE) and new events as they arrive.
    /// - Parameters:
    ///   - filter: The Nostr filter to match events against.
    ///   - id: A unique subscription identifier for management/cleanup.
    /// - Returns: An `AsyncStream` that yields matching events until unsubscribed.
    func subscribe(filter: NostrFilter, id: SubscriptionID) async throws -> AsyncStream<NostrEvent>

    /// Close a subscription and stop receiving events.
    /// - Parameter id: The subscription ID passed to `subscribe()`.
    func unsubscribe(_ id: SubscriptionID) async

    /// Fetch events matching a filter with a timeout (EOSE-aware one-shot query).
    /// Returns all matching events from connected relays, then completes.
    /// - Parameters:
    ///   - filter: The Nostr filter to match events against.
    ///   - timeout: Maximum time to wait for relay responses (default from RelayConstants).
    /// - Returns: Array of matching events.
    func fetchEvents(filter: NostrFilter, timeout: TimeInterval) async throws -> [NostrEvent]

    /// Whether at least one relay is connected.
    var isConnected: Bool { get async }

    /// Reconnect to relays if the notification handler died.
    /// Callers must restart subscriptions after this returns.
    func reconnectIfNeeded() async
}

// MARK: - Retry Extension

extension RelayManagerProtocol {
    /// Publish with exponential backoff retry for critical events.
    ///
    /// Retries are performed outside actor isolation to avoid blocking other
    /// relay operations (subscribe, unsubscribe, fetchEvents) during sleep.
    ///
    /// - Parameters:
    ///   - event: The event to publish.
    ///   - maxAttempts: Maximum number of attempts (default 3).
    ///   - initialDelay: Base delay between retries in seconds (default 1.0). Doubles each retry.
    /// - Returns: The event ID on success.
    public func publishWithRetry(
        _ event: NostrEvent,
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1.0
    ) async throws -> String {
        var lastError: (any Error)?
        for attempt in 0..<maxAttempts {
            do {
                let eventId = try await publish(event)
                if attempt > 0 {
                    RidestrLogger.info("[Relay] Publish succeeded on attempt \(attempt + 1) for \(event.id.prefix(8))")
                }
                return eventId
            } catch {
                lastError = error
                RidestrLogger.warning("[Relay] Publish attempt \(attempt + 1)/\(maxAttempts) failed for \(event.id.prefix(8)): \(error.localizedDescription)")
                if attempt < maxAttempts - 1 {
                    let delay = initialDelay * pow(2.0, Double(attempt))
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        }
        throw lastError ?? RidestrError.relay(.timeout)
    }
}

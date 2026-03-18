import Foundation

/// Protocol for relay management operations. Abstracted for testability.
public protocol RelayManagerProtocol: Sendable {
    /// Connect to the given relay URLs.
    func connect(to relays: [URL]) async throws

    /// Disconnect from all relays.
    func disconnect() async

    /// Publish a signed event to all connected relays.
    func publish(_ event: NostrEvent) async throws -> String

    /// Subscribe to events matching a filter. Returns an async stream of events.
    /// The stream includes both stored events and new events as they arrive.
    func subscribe(filter: NostrFilter, id: SubscriptionID) async throws -> AsyncStream<NostrEvent>

    /// Close a subscription.
    func unsubscribe(_ id: SubscriptionID) async

    /// Fetch events matching a filter with a timeout (EOSE-aware one-shot query).
    func fetchEvents(filter: NostrFilter, timeout: TimeInterval) async throws -> [NostrEvent]

    /// Whether at least one relay is connected.
    var isConnected: Bool { get async }
}

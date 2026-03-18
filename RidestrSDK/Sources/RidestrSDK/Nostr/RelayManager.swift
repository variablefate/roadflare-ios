import Foundation
import NostrSDK

/// Manages Nostr relay connections, event publishing, and subscriptions.
///
/// Wraps rust-nostr's `Client` inside an actor for thread-safe access.
/// Uses `streamEvents` for real-time subscriptions via `AsyncStream`.
public actor RelayManager: RelayManagerProtocol {
    private var client: Client?
    private let keypair: NostrKeypair
    private var activeStreams: [SubscriptionID: Task<Void, Never>] = [:]
    private var connectedRelayURLs: [URL] = []

    public init(keypair: NostrKeypair) {
        self.keypair = keypair
    }

    // MARK: - Connection

    public func connect(to relays: [URL]) async throws {
        let keys = try keypair.toKeys()
        let signer = NostrSigner.keys(keys: keys)
        let newClient = Client(signer: signer)

        for url in relays.prefix(RelayConstants.maxRelays) {
            let relayUrl = try RelayUrl.parse(url: url.absoluteString)
            _ = try await newClient.addRelay(url: relayUrl)
        }

        await newClient.connect()
        self.client = newClient
        self.connectedRelayURLs = Array(relays.prefix(RelayConstants.maxRelays))
    }

    public func disconnect() async {
        // Cancel all active subscription streams
        for (_, task) in activeStreams {
            task.cancel()
        }
        activeStreams.removeAll()

        if let client {
            await client.disconnect()
        }
        client = nil
        connectedRelayURLs = []
    }

    public var isConnected: Bool {
        client != nil && !connectedRelayURLs.isEmpty
    }

    // MARK: - Publishing

    public func publish(_ event: NostrEvent) async throws -> String {
        guard let client else {
            throw RidestrError.relayNotConnected
        }

        let rustEvent = try EventSigner.toRustEvent(event)
        _ = try await client.sendEvent(event: rustEvent)
        return event.id
    }

    // MARK: - Subscriptions (streaming)

    public func subscribe(
        filter: NostrFilter,
        id: SubscriptionID
    ) async throws -> AsyncStream<NostrEvent> {
        guard let client else {
            throw RidestrError.relayNotConnected
        }

        // Cancel any existing subscription with the same ID
        if let existing = activeStreams[id] {
            existing.cancel()
            activeStreams[id] = nil
        }

        let rustFilter = try filter.toRustNostrFilter()

        // Use streamEvents for real-time event delivery
        let stream = try await client.streamEvents(
            filter: rustFilter,
            timeout: RelayConstants.eoseTimeoutSeconds
        )

        // Wrap in AsyncStream with a background task consuming the EventStream
        let (asyncStream, continuation) = AsyncStream<NostrEvent>.makeStream()

        let task = Task { [weak self] in
            defer { continuation.finish() }

            while !Task.isCancelled {
                guard let rustEvent = await stream.next() else {
                    break  // Stream ended
                }
                guard let event = try? EventSigner.fromRustEvent(rustEvent) else {
                    continue  // Skip events that fail conversion
                }
                continuation.yield(event)
            }

            // Clean up from the active streams map
            if let self {
                await self.removeStream(id: id)
            }
        }

        activeStreams[id] = task

        continuation.onTermination = { _ in
            task.cancel()
        }

        return asyncStream
    }

    public func unsubscribe(_ id: SubscriptionID) async {
        if let task = activeStreams[id] {
            task.cancel()
            activeStreams[id] = nil
        }
    }

    // MARK: - One-Shot Fetch (EOSE-aware)

    public func fetchEvents(
        filter: NostrFilter,
        timeout: TimeInterval = RelayConstants.eoseTimeoutSeconds
    ) async throws -> [NostrEvent] {
        guard let client else {
            throw RidestrError.relayNotConnected
        }

        let rustFilter = try filter.toRustNostrFilter()
        let events = try await client.fetchEvents(filter: rustFilter, timeout: timeout)

        return try events.toVec().compactMap { rustEvent in
            try? EventSigner.fromRustEvent(rustEvent)
        }
    }

    // MARK: - Private

    private func removeStream(id: SubscriptionID) {
        activeStreams[id] = nil
    }
}

import Foundation
import NostrSDK

/// Manages Nostr relay connections, event publishing, and subscriptions.
///
/// Uses rust-nostr's `Client.subscribe()` for persistent subscriptions and
/// `Client.handleNotifications()` for real-time event delivery.
/// `streamEvents` is used only for one-shot EOSE-aware fetches.
public actor RelayManager: RelayManagerProtocol {
    private var client: Client?
    private let keypair: NostrKeypair
    private var activeStreams: [SubscriptionID: String] = [:]  // maps our ID → relay subscription ID
    private var connectedRelayURLs: [URL] = []
    private var notificationHandler: NotificationRouter?
    private var notificationTask: Task<Void, Never>?

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

        // Brief wait for relay handshake to complete
        try? await Task.sleep(for: .seconds(1))

        self.client = newClient
        self.connectedRelayURLs = Array(relays.prefix(RelayConstants.maxRelays))

        // Start the global notification handler
        let router = NotificationRouter()
        self.notificationHandler = router
        let clientRef = newClient
        notificationTask = Task.detached { [weak self, router] in
            do {
                try await clientRef.handleNotifications(handler: router)
            } catch {
                RidestrLogger.error("[RelayManager] Notification handler stopped: \(error)")
            }
            // handleNotifications exited — relay disconnected.
            // Finish all continuations so AsyncStream consumers exit their for-await loops.
            router.removeAll()
            RidestrLogger.error("[RelayManager] All subscription streams terminated due to disconnect")
        }
    }

    public func disconnect() async {
        // Finish all subscription continuations via router
        notificationHandler?.removeAll()
        activeStreams.removeAll()
        notificationTask?.cancel()

        if let client {
            await client.disconnect()
        }
        client = nil
        connectedRelayURLs = []
        notificationHandler = nil
    }

    public var isConnected: Bool {
        client != nil && !connectedRelayURLs.isEmpty
    }

    /// Reconnect to relays if disconnected. Call from app foreground handler.
    /// Does NOT restart subscriptions — callers must re-subscribe after this returns.
    public func reconnectIfNeeded() async {
        guard let client else { return }

        // Check if notification handler is still alive
        let handlerDead = notificationTask == nil || notificationTask?.isCancelled == true

        if handlerDead && !connectedRelayURLs.isEmpty {
            RidestrLogger.error("[RelayManager] Reconnecting — notification handler died")
            await client.connect()
            try? await Task.sleep(for: .seconds(1))

            // Restart notification handler
            let router = NotificationRouter()
            self.notificationHandler = router
            let clientRef = client
            notificationTask = Task.detached { [weak self, router] in
                do {
                    try await clientRef.handleNotifications(handler: router)
                } catch {
                    RidestrLogger.error("[RelayManager] Notification handler stopped: \(error)")
                }
                router.removeAll()
            }

            // Clear old stream mappings — callers must re-subscribe
            activeStreams.removeAll()
        }
    }

    // MARK: - Publishing

    public func publish(_ event: NostrEvent) async throws -> String {
        guard let client else {
            throw RidestrError.relay(.notConnected)
        }

        let rustEvent = try EventSigner.toRustEvent(event)
        _ = try await client.sendEvent(event: rustEvent)
        return event.id
    }

    // MARK: - Persistent Subscriptions

    /// Subscribe to events matching a filter. Returns an AsyncStream that stays alive
    /// as long as the relay is connected. Events are delivered via handleNotifications.
    public func subscribe(
        filter: NostrFilter,
        id: SubscriptionID
    ) async throws -> AsyncStream<NostrEvent> {
        guard let client, let router = notificationHandler else {
            throw RidestrError.relay(.notConnected)
        }

        // Cancel any existing subscription with the same ID
        if let oldRelaySubId = activeStreams[id] {
            router.removeSubscription(relaySubscriptionId: oldRelaySubId)
            activeStreams[id] = nil
        }

        let rustFilter = try filter.toRustNostrFilter()

        // Register subscription with the relay (persistent, not EOSE-limited)
        let output = try await client.subscribe(filter: rustFilter)
        let relaySubId = output.id

        // Create AsyncStream backed by the notification router
        let (asyncStream, continuation) = AsyncStream<NostrEvent>.makeStream()

        // Register this subscription's continuation with the router
        router.addSubscription(relaySubscriptionId: relaySubId, continuation: continuation)

        // Track relay subscription ID for cleanup
        activeStreams[id] = relaySubId

        continuation.onTermination = { [router] _ in
            router.removeSubscription(relaySubscriptionId: relaySubId)
        }

        return asyncStream
    }

    public func unsubscribe(_ id: SubscriptionID) async {
        if let relaySubId = activeStreams[id] {
            notificationHandler?.removeSubscription(relaySubscriptionId: relaySubId)
            activeStreams[id] = nil
        }
    }

    // MARK: - One-Shot Fetch (EOSE-aware)

    public func fetchEvents(
        filter: NostrFilter,
        timeout: TimeInterval = RelayConstants.eoseTimeoutSeconds
    ) async throws -> [NostrEvent] {
        guard let client else {
            throw RidestrError.relay(.notConnected)
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

// MARK: - Notification Router

/// Routes events from rust-nostr's handleNotifications callback to the correct
/// subscription's AsyncStream continuation. Thread-safe via NSLock.
final class NotificationRouter: HandleNotification, @unchecked Sendable {
    private let lock = NSLock()
    private var subscriptions: [String: AsyncStream<NostrEvent>.Continuation] = [:]

    func addSubscription(relaySubscriptionId: String, continuation: AsyncStream<NostrEvent>.Continuation) {
        lock.withLock {
            subscriptions[relaySubscriptionId] = continuation
        }
    }

    func removeSubscription(relaySubscriptionId: String) {
        lock.withLock {
            subscriptions[relaySubscriptionId]?.finish()
            subscriptions[relaySubscriptionId] = nil
        }
    }

    func removeAll() {
        lock.withLock {
            for (_, cont) in subscriptions {
                cont.finish()
            }
            subscriptions.removeAll()
        }
    }

    // MARK: - HandleNotification

    func handleMsg(relayUrl: RelayUrl, msg: RelayMessage) async {
        // Not used — we handle individual events via handle()
    }

    func handle(relayUrl: RelayUrl, subscriptionId: String, event: Event) async {
        guard let nostrEvent = try? EventSigner.fromRustEvent(event) else { return }

        lock.withLock {
            // Route event to the matching subscription continuation
            if let cont = subscriptions[subscriptionId] {
                cont.yield(nostrEvent)
            }
        }
    }
}

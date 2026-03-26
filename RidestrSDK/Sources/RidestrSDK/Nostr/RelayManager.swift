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
    private var _handlerAlive = false  // Explicit liveness flag — Task.isCancelled doesn't detect normal completion

    public init(keypair: NostrKeypair) {
        self.keypair = keypair
    }

    // MARK: - Connection

    public func connect(to relays: [URL]) async throws {
        connectedRelayURLs = Array(relays.prefix(RelayConstants.maxRelays))
        try await replaceClient(with: connectedRelayURLs)
    }

    public func disconnect() async {
        await teardownConnection(clearRelayURLs: true)
    }

    public var isConnected: Bool {
        client != nil && !connectedRelayURLs.isEmpty && _handlerAlive
    }

    private func markHandlerDead() {
        _handlerAlive = false
    }

    /// Reconnect to relays if disconnected. Call from app foreground handler.
    /// Does NOT restart subscriptions — callers must re-subscribe after this returns.
    public func reconnectIfNeeded() async {
        guard !connectedRelayURLs.isEmpty else { return }
        guard client == nil || !_handlerAlive else { return }

        RidestrLogger.error("[RelayManager] Reconnecting relay client")
        do {
            try await replaceClient(with: connectedRelayURLs)
        } catch {
            RidestrLogger.error("[RelayManager] Reconnect failed: \(error.localizedDescription)")
        }
    }

    private func replaceClient(with relays: [URL]) async throws {
        await teardownConnection(clearRelayURLs: false)
        let newClient = try await makeConnectedClient(relays: relays)
        client = newClient
        startNotificationHandler(for: newClient)
    }

    private func makeConnectedClient(relays: [URL]) async throws -> Client {
        let keys = try keypair.toKeys()
        let signer = NostrSigner.keys(keys: keys)
        let newClient = Client(signer: signer)

        for url in relays {
            let relayUrl = try RelayUrl.parse(url: url.absoluteString)
            _ = try await newClient.addRelay(url: relayUrl)
        }

        await newClient.connect()

        // Brief wait for relay handshake to complete
        try? await Task.sleep(for: .seconds(1))
        return newClient
    }

    private func startNotificationHandler(for client: Client) {
        let router = NotificationRouter()
        self.notificationHandler = router
        self._handlerAlive = true
        let clientRef = client
        notificationTask = Task.detached { [router] in
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
        // Monitor handler liveness from a separate task
        Task { [weak self] in
            await self?.notificationTask?.value  // Suspends until task completes
            await self?.markHandlerDead()
        }
    }

    private func teardownConnection(clearRelayURLs: Bool) async {
        _handlerAlive = false
        notificationHandler?.removeAll()
        activeStreams.removeAll()
        notificationTask?.cancel()
        notificationTask = nil

        if let client {
            await client.disconnect()
        }
        client = nil
        notificationHandler = nil
        if clearRelayURLs {
            connectedRelayURLs = []
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
            activeStreams[id] = nil
            router.removeSubscription(relaySubscriptionId: oldRelaySubId)
            await client.unsubscribe(subscriptionId: oldRelaySubId)
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

        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.handleStreamTermination(id: id, relaySubscriptionId: relaySubId)
            }
        }

        return asyncStream
    }

    public func unsubscribe(_ id: SubscriptionID) async {
        guard let relaySubId = activeStreams[id] else { return }
        activeStreams[id] = nil
        notificationHandler?.removeSubscription(relaySubscriptionId: relaySubId)
        if let client {
            await client.unsubscribe(subscriptionId: relaySubId)
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

    private func handleStreamTermination(id: SubscriptionID, relaySubscriptionId: String) async {
        guard activeStreams[id] == relaySubscriptionId else { return }
        activeStreams[id] = nil
        notificationHandler?.removeSubscription(relaySubscriptionId: relaySubscriptionId)
        if let client {
            await client.unsubscribe(subscriptionId: relaySubscriptionId)
        }
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

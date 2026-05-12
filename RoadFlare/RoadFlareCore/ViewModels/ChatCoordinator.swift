import Foundation
import RidestrSDK

/// Manages in-ride chat messaging (Kind 3178).
///
/// Owns the subscription lifetime (start/stop, generation-counter guard),
/// outbound message publishing via `sendChatMessage(_:)`, the iOS-side
/// haptic feedback on incoming remote messages, and surfaces send failures
/// via `lastError`. All message-list state — dedup, sort, capacity, unread
/// counting — lives in the SDK-side `ChatMessageStore` so it can be reused
/// by a driver-side consumer.
@Observable
@MainActor
public final class ChatCoordinator {
    private let relayManager: any RelayManagerProtocol
    private let keypair: NostrKeypair
    let store: ChatMessageStore

    public var chatMessages: [ChatMessage] { store.messages }
    public var unreadCount: Int { store.unreadCount }

    private struct ActiveSubscription {
        let id: SubscriptionID
        let generation: UUID
        let task: Task<Void, Never>
    }
    private var activeSubscription: ActiveSubscription?

    public var lastError: String?

    public init(relayManager: any RelayManagerProtocol, keypair: NostrKeypair) {
        self.relayManager = relayManager
        self.keypair = keypair
        self.store = ChatMessageStore()
    }

    // MARK: - Subscribe

    func subscribeToChat(driverPubkey: String, confirmationEventId: String) {
        let previous = takeActiveSubscription()
        store.setUnreadCutoff(Int(Date.now.timeIntervalSince1970))
        let subId = SubscriptionID("chat-\(confirmationEventId)")
        let generation = UUID()
        let task = Task {
            previous?.task.cancel()
            if let oldId = previous?.id {
                await relayManager.unsubscribe(oldId)
            }
            guard !Task.isCancelled,
                  activeSubscription?.generation == generation else { return }
            do {
                let filter = NostrFilter.chatMessages(
                    counterpartyPubkey: driverPubkey,
                    myPubkey: keypair.publicKeyHex,
                    confirmationEventId: confirmationEventId
                )
                let stream = try await relayManager.subscribe(filter: filter, id: subId)
                guard !Task.isCancelled else { return }
                guard activeSubscription?.generation == generation else {
                    if activeSubscription?.id != subId {
                        await relayManager.unsubscribe(subId)
                    }
                    return
                }

                for await event in stream {
                    guard !Task.isCancelled,
                          activeSubscription?.generation == generation else { break }
                    await handleChatEvent(
                        event,
                        expectedConfirmationEventId: confirmationEventId,
                        expectedSenderPubkey: driverPubkey
                    )
                }
            } catch {
                // Chat subscription failure is non-fatal
            }
        }
        activeSubscription = ActiveSubscription(id: subId, generation: generation, task: task)
    }

    // MARK: - Handle Incoming

    func handleChatEvent(
        _ event: NostrEvent,
        expectedConfirmationEventId: String? = nil,
        expectedSenderPubkey: String? = nil
    ) async {
        do {
            let content = try RideshareEventParser.parseChatMessage(
                event: event,
                keypair: keypair,
                expectedSenderPubkey: expectedSenderPubkey,
                expectedConfirmationEventId: expectedConfirmationEventId
            )
            let message = ChatMessage(
                id: event.id,
                text: content.message,
                isMine: event.pubkey == keypair.publicKeyHex,
                timestamp: event.createdAt
            )
            if case .inserted = store.append(message), !message.isMine {
                HapticManager.messageReceived()
            }
        } catch {
            // Invalid chat message, skip
        }
    }

    // MARK: - Send

    public func sendChatMessage(_ text: String, driverPubkey: String, confirmationEventId: String) async {
        do {
            let event = try await RideshareEventBuilder.chatMessage(
                recipientPubkey: driverPubkey,
                confirmationEventId: confirmationEventId,
                message: text,
                keypair: keypair
            )
            _ = try await relayManager.publish(event)
            store.append(ChatMessage(
                id: event.id,
                text: text,
                isMine: true,
                timestamp: event.createdAt
            ))
        } catch {
            lastError = "Failed to send message: \(error.localizedDescription)"
        }
    }

    // MARK: - Cleanup

    func cleanup() async {
        let previous = takeActiveSubscription()
        previous?.task.cancel()
        if let id = previous?.id {
            await relayManager.unsubscribe(id)
        }
    }

    func cleanupAsync() {
        let previous = takeActiveSubscription()
        guard let previous else { return }

        Task {
            previous.task.cancel()
            await relayManager.unsubscribe(previous.id)
        }
    }

    public func markRead() {
        store.markRead()
    }

    func reset() {
        store.reset()
    }

    private func takeActiveSubscription() -> ActiveSubscription? {
        let previous = activeSubscription
        activeSubscription = nil
        return previous
    }
}

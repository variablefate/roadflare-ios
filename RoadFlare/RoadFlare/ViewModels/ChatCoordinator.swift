import Foundation
import RidestrSDK
import RoadFlareCore

/// Manages in-ride chat messaging (Kind 3178).
@Observable
@MainActor
final class ChatCoordinator {
    let relayManager: any RelayManagerProtocol
    private let keypair: NostrKeypair

    var chatMessages: [(id: String, text: String, isMine: Bool, timestamp: Int)] = []
    var unreadCount: Int = 0
    private var chatMessageIds: Set<String> = []
    private var subscriptionStartTime: Int = 0
    private struct ActiveSubscription {
        let id: SubscriptionID
        let generation: UUID
        let task: Task<Void, Never>
    }
    private var activeSubscription: ActiveSubscription?

    var lastError: String?

    init(relayManager: any RelayManagerProtocol, keypair: NostrKeypair) {
        self.relayManager = relayManager
        self.keypair = keypair
    }

    // MARK: - Subscribe

    func subscribeToChat(driverPubkey: String, confirmationEventId: String) {
        let previous = takeActiveSubscription()
        subscriptionStartTime = Int(Date.now.timeIntervalSince1970)
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
            let isMine = event.pubkey == keypair.publicKeyHex
            guard !chatMessageIds.contains(event.id) else { return }
            chatMessageIds.insert(event.id)
            chatMessages.append((id: event.id, text: content.message, isMine: isMine, timestamp: event.createdAt))
            // Sort by timestamp; tie-break by event ID for deterministic ordering
            chatMessages.sort { $0.timestamp != $1.timestamp ? $0.timestamp < $1.timestamp : $0.id < $1.id }
            // Cap at 500 messages to prevent memory bloat
            if chatMessages.count > 500 {
                let removed = chatMessages.removeFirst()
                chatMessageIds.remove(removed.id)
            }
            if !isMine {
                // Only count as unread if the message arrived after subscription start,
                // to avoid inflating the badge with replayed history on app restart.
                if event.createdAt >= subscriptionStartTime {
                    unreadCount += 1
                }
                HapticManager.messageReceived()
            }
        } catch {
            // Invalid chat message, skip
        }
    }

    // MARK: - Send

    func sendChatMessage(_ text: String, driverPubkey: String, confirmationEventId: String) async {
        do {
            let event = try await RideshareEventBuilder.chatMessage(
                recipientPubkey: driverPubkey,
                confirmationEventId: confirmationEventId,
                message: text,
                keypair: keypair
            )
            _ = try await relayManager.publish(event)
            guard !chatMessageIds.contains(event.id) else { return }
            chatMessageIds.insert(event.id)
            chatMessages.append((
                id: event.id,
                text: text,
                isMine: true,
                timestamp: event.createdAt
            ))
            chatMessages.sort { $0.timestamp != $1.timestamp ? $0.timestamp < $1.timestamp : $0.id < $1.id }
            if chatMessages.count > 500 {
                let removed = chatMessages.removeFirst()
                chatMessageIds.remove(removed.id)
            }
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

    func markRead() {
        unreadCount = 0
    }

    func reset() {
        chatMessages = []
        chatMessageIds = []
        unreadCount = 0
    }

    private func takeActiveSubscription() -> ActiveSubscription? {
        let previous = activeSubscription
        activeSubscription = nil
        return previous
    }
}

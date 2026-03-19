import Foundation
import RidestrSDK

/// Manages in-ride chat messaging (Kind 3178).
@Observable
@MainActor
final class ChatCoordinator {
    let relayManager: any RelayManagerProtocol
    private let keypair: NostrKeypair

    var chatMessages: [(id: String, text: String, isMine: Bool, timestamp: Int)] = []
    private var chatMessageIds: Set<String> = []
    private var chatSubscriptionId: SubscriptionID?
    private var chatTask: Task<Void, Never>?

    var lastError: String?

    init(relayManager: any RelayManagerProtocol, keypair: NostrKeypair) {
        self.relayManager = relayManager
        self.keypair = keypair
    }

    // MARK: - Subscribe

    func subscribeToChat(driverPubkey: String, confirmationEventId: String) {
        let subId = SubscriptionID("chat-\(confirmationEventId)")
        chatSubscriptionId = subId

        chatTask?.cancel()
        chatTask = Task {
            do {
                let filter = NostrFilter.chatMessages(
                    counterpartyPubkey: driverPubkey,
                    myPubkey: keypair.publicKeyHex
                )
                let stream = try await relayManager.subscribe(filter: filter, id: subId)

                for await event in stream {
                    guard !Task.isCancelled else { break }
                    await handleChatEvent(event)
                }
            } catch {
                // Chat subscription failure is non-fatal
            }
        }
    }

    // MARK: - Handle Incoming

    func handleChatEvent(_ event: NostrEvent) async {
        do {
            let content = try RideshareEventParser.parseChatMessage(event: event, keypair: keypair)
            let isMine = event.pubkey == keypair.publicKeyHex
            guard !chatMessageIds.contains(event.id) else { return }
            chatMessageIds.insert(event.id)
            chatMessages.append((id: event.id, text: content.message, isMine: isMine, timestamp: event.createdAt))
            chatMessages.sort { $0.timestamp < $1.timestamp }
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
            chatMessages.append((
                id: event.id,
                text: text,
                isMine: true,
                timestamp: Int(Date.now.timeIntervalSince1970)
            ))
        } catch {
            lastError = "Failed to send message: \(error.localizedDescription)"
        }
    }

    // MARK: - Cleanup

    func cleanup() async {
        chatTask?.cancel()
        if let id = chatSubscriptionId { await relayManager.unsubscribe(id) }
        chatSubscriptionId = nil
    }

    func reset() {
        chatMessages = []
        chatMessageIds = []
    }
}

import Foundation
import Testing
@testable import RoadFlare
@testable import RidestrSDK

@Suite("ChatCoordinator Tests")
@MainActor
struct ChatCoordinatorTests {

    private func makeBundle() throws -> (chat: ChatCoordinator, fake: FakeRelayManager, rider: NostrKeypair) {
        let fake = FakeRelayManager()
        fake.keepSubscriptionsAlive = true
        let rider = try NostrKeypair.generate()
        let chat = ChatCoordinator(relayManager: fake, keypair: rider)
        return (chat, fake, rider)
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(10),
        _ condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while !condition() {
            if clock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: pollInterval)
        }

        return true
    }

    @Test func subscribeToChatReplacesExistingSubscription() async throws {
        let (chat, fake, rider) = try makeBundle()
        let firstDriver = try NostrKeypair.generate()
        let secondDriver = try NostrKeypair.generate()
        let firstConfirmationId = String(repeating: "a", count: 64)
        let secondConfirmationId = String(repeating: "b", count: 64)

        chat.subscribeToChat(driverPubkey: firstDriver.publicKeyHex, confirmationEventId: firstConfirmationId)
        #expect(await eventually {
            fake.subscribeCalls.contains { $0.id.rawValue == "chat-\(firstConfirmationId)" }
        })

        chat.subscribeToChat(driverPubkey: secondDriver.publicKeyHex, confirmationEventId: secondConfirmationId)

        let replaced = await eventually {
            fake.unsubscribeCalls.contains { $0.rawValue == "chat-\(firstConfirmationId)" } &&
                fake.subscribeCalls.contains { $0.id.rawValue == "chat-\(secondConfirmationId)" }
        }
        #expect(replaced)

        let staleEvent = try await RideshareEventBuilder.chatMessage(
            recipientPubkey: rider.publicKeyHex,
            confirmationEventId: firstConfirmationId,
            message: "stale",
            keypair: firstDriver
        )
        let activeEvent = try await RideshareEventBuilder.chatMessage(
            recipientPubkey: rider.publicKeyHex,
            confirmationEventId: secondConfirmationId,
            message: "active",
            keypair: secondDriver
        )

        #expect(fake.injectEvent(staleEvent, subscriptionId: "chat-\(firstConfirmationId)") == false)
        #expect(fake.injectEvent(activeEvent, subscriptionId: "chat-\(secondConfirmationId)"))
        #expect(await eventually {
            chat.chatMessages.count == 1 &&
                chat.chatMessages.first?.text == "active"
        })
    }

    @Test func cleanupAsyncDoesNotUnsubscribeReplacementSubscription() async throws {
        let (chat, fake, rider) = try makeBundle()
        let firstDriver = try NostrKeypair.generate()
        let secondDriver = try NostrKeypair.generate()
        let firstConfirmationId = String(repeating: "c", count: 64)
        let secondConfirmationId = String(repeating: "d", count: 64)

        chat.subscribeToChat(driverPubkey: firstDriver.publicKeyHex, confirmationEventId: firstConfirmationId)
        #expect(await eventually {
            fake.subscribeCalls.contains { $0.id.rawValue == "chat-\(firstConfirmationId)" }
        })

        chat.cleanupAsync()
        chat.subscribeToChat(driverPubkey: secondDriver.publicKeyHex, confirmationEventId: secondConfirmationId)

        let stable = await eventually {
            fake.unsubscribeCalls.contains { $0.rawValue == "chat-\(firstConfirmationId)" } &&
                fake.subscribeCalls.contains { $0.id.rawValue == "chat-\(secondConfirmationId)" } &&
                !fake.unsubscribeCalls.contains { $0.rawValue == "chat-\(secondConfirmationId)" }
        }
        #expect(stable)

        let activeEvent = try await RideshareEventBuilder.chatMessage(
            recipientPubkey: rider.publicKeyHex,
            confirmationEventId: secondConfirmationId,
            message: "replacement",
            keypair: secondDriver
        )

        #expect(fake.injectEvent(activeEvent, subscriptionId: "chat-\(secondConfirmationId)"))
        #expect(await eventually {
            chat.chatMessages.count == 1 &&
                chat.chatMessages.first?.text == "replacement"
        })
    }

    @Test func delayedPreviousSubscribeDoesNotReactivateStaleChat() async throws {
        let (chat, fake, rider) = try makeBundle()
        fake.subscribeDelay = .milliseconds(100)
        let firstDriver = try NostrKeypair.generate()
        let secondDriver = try NostrKeypair.generate()
        let firstConfirmationId = String(repeating: "e", count: 64)
        let secondConfirmationId = String(repeating: "f", count: 64)

        chat.subscribeToChat(driverPubkey: firstDriver.publicKeyHex, confirmationEventId: firstConfirmationId)
        chat.subscribeToChat(driverPubkey: secondDriver.publicKeyHex, confirmationEventId: secondConfirmationId)

        let settled = await eventually(timeout: .seconds(2)) {
            fake.subscribeCalls.contains { $0.id.rawValue == "chat-\(secondConfirmationId)" } &&
                fake.isSubscriptionActive("chat-\(secondConfirmationId)") &&
                !fake.isSubscriptionActive("chat-\(firstConfirmationId)")
        }
        #expect(settled)

        let staleEvent = try await RideshareEventBuilder.chatMessage(
            recipientPubkey: rider.publicKeyHex,
            confirmationEventId: firstConfirmationId,
            message: "stale delayed",
            keypair: firstDriver
        )
        let activeEvent = try await RideshareEventBuilder.chatMessage(
            recipientPubkey: rider.publicKeyHex,
            confirmationEventId: secondConfirmationId,
            message: "current delayed",
            keypair: secondDriver
        )

        #expect(fake.injectEvent(staleEvent, subscriptionId: "chat-\(firstConfirmationId)") == false)
        #expect(fake.injectEvent(activeEvent, subscriptionId: "chat-\(secondConfirmationId)"))
        #expect(await eventually {
            chat.chatMessages.count == 1 &&
                chat.chatMessages.first?.text == "current delayed"
        })
    }
}

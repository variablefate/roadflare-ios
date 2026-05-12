import Foundation
import Testing
@testable import RidestrSDK

@Suite("ChatMessageStore Tests")
struct ChatMessageStoreTests {
    private func makeStore(capacity: Int = ChatMessageStore.defaultCapacity) -> ChatMessageStore {
        ChatMessageStore(capacity: capacity)
    }

    private func message(
        id: String,
        text: String = "hi",
        isMine: Bool = false,
        timestamp: Int = 1_000
    ) -> ChatMessage {
        ChatMessage(id: id, text: text, isMine: isMine, timestamp: timestamp)
    }

    // MARK: - Fresh state

    @Test func defaultsEmpty() {
        let store = makeStore()
        #expect(store.messages.isEmpty)
        #expect(store.unreadCount == 0)
        #expect(store.capacity == ChatMessageStore.defaultCapacity)
    }

    @Test func defaultCapacityMatchesLegacyCoordinator() {
        #expect(ChatMessageStore.defaultCapacity == 500)
    }

    // MARK: - Append + dedup

    @Test func appendInsertsNewMessage() {
        let store = makeStore()
        let outcome = store.append(message(id: "a", timestamp: 100))
        #expect(outcome == .inserted)
        #expect(store.messages.count == 1)
        #expect(store.messages[0].id == "a")
    }

    @Test func appendDeduplicatesSameId() {
        let store = makeStore()
        _ = store.append(message(id: "a", text: "first", timestamp: 100))
        let second = store.append(message(id: "a", text: "second-text", timestamp: 200))
        #expect(second == .duplicate)
        #expect(store.messages.count == 1)
        #expect(store.messages[0].text == "first")
        #expect(store.unreadCount == 1)
    }

    @Test func appendDeduplicatesAcrossPubkeyAndTimestampCollisions() {
        // Same event id from two distinct senders/timestamps should still be a duplicate:
        // the dedup key is the event id only.
        let store = makeStore()
        _ = store.append(message(id: "evt-1", isMine: false, timestamp: 100))
        let outcome = store.append(message(id: "evt-1", isMine: true, timestamp: 500))
        #expect(outcome == .duplicate)
        #expect(store.messages.count == 1)
    }

    // MARK: - Sort

    @Test func sortsAscendingByTimestamp() {
        let store = makeStore()
        _ = store.append(message(id: "b", timestamp: 200))
        _ = store.append(message(id: "a", timestamp: 100))
        _ = store.append(message(id: "c", timestamp: 300))
        #expect(store.messages.map(\.id) == ["a", "b", "c"])
    }

    @Test func sortTieBreaksByIdAscending() {
        let store = makeStore()
        _ = store.append(message(id: "z", timestamp: 100))
        _ = store.append(message(id: "a", timestamp: 100))
        _ = store.append(message(id: "m", timestamp: 100))
        #expect(store.messages.map(\.id) == ["a", "m", "z"])
    }

    @Test func sortIsDeterministicAcrossOutOfOrderArrivals() {
        let store = makeStore()
        _ = store.append(message(id: "c", timestamp: 300))
        _ = store.append(message(id: "a", timestamp: 100))
        _ = store.append(message(id: "b2", timestamp: 200))
        _ = store.append(message(id: "b1", timestamp: 200))
        #expect(store.messages.map(\.id) == ["a", "b1", "b2", "c"])
    }

    // MARK: - Capacity

    @Test func evictsOldestWhenOverCapacity() {
        let store = makeStore(capacity: 3)
        _ = store.append(message(id: "a", timestamp: 100))
        _ = store.append(message(id: "b", timestamp: 200))
        _ = store.append(message(id: "c", timestamp: 300))
        _ = store.append(message(id: "d", timestamp: 400))
        #expect(store.messages.map(\.id) == ["b", "c", "d"])
    }

    @Test func evictedIdsCanBeReinserted() {
        // After eviction, the message id is no longer "known" — re-appending
        // it (as could happen with a relay replay much later) inserts again.
        let store = makeStore(capacity: 2)
        _ = store.append(message(id: "a", timestamp: 100))
        _ = store.append(message(id: "b", timestamp: 200))
        _ = store.append(message(id: "c", timestamp: 300)) // evicts a
        let outcome = store.append(message(id: "a", timestamp: 400))
        #expect(outcome != .duplicate)
        #expect(store.messages.map(\.id) == ["c", "a"])
    }

    @Test func arrivingOlderMessageOverCapacityIsEvictedImmediately() {
        // Edge case: a stale message that sorts to the front of an already-full
        // store gets evicted in the same call. Documents the existing behaviour
        // inherited from the coordinator: `unreadCount` is still incremented
        // for the evicted message (the unread check runs after eviction).
        // Locked in by the assertion below; revisit if that semantics changes.
        let store = makeStore(capacity: 2)
        _ = store.append(message(id: "b", isMine: true, timestamp: 200))
        _ = store.append(message(id: "c", isMine: true, timestamp: 300))
        let outcome = store.append(message(id: "a", isMine: false, timestamp: 100))
        #expect(outcome == .inserted)
        #expect(store.messages.map(\.id) == ["b", "c"])
        #expect(store.unreadCount == 1)
    }

    // MARK: - Unread tracking

    @Test func unreadDoesNotIncrementForOwnMessages() {
        let store = makeStore()
        let outcome = store.append(message(id: "a", isMine: true, timestamp: 100))
        #expect(outcome == .inserted)
        #expect(store.unreadCount == 0)
    }

    @Test func unreadIncrementsForRemoteMessages() {
        let store = makeStore()
        _ = store.append(message(id: "a", isMine: false, timestamp: 100))
        _ = store.append(message(id: "b", isMine: false, timestamp: 200))
        #expect(store.unreadCount == 2)
    }

    @Test func unreadCutoffSuppressesReplayedHistory() {
        let store = makeStore()
        store.setUnreadCutoff(500)
        let stale = store.append(message(id: "old", isMine: false, timestamp: 400))
        #expect(stale == .inserted)
        #expect(store.unreadCount == 0)
        let live = store.append(message(id: "new", isMine: false, timestamp: 600))
        #expect(live == .inserted)
        #expect(store.unreadCount == 1)
    }

    @Test func unreadCutoffIsInclusiveAtBoundary() {
        // Matches existing coordinator: `event.createdAt >= subscriptionStartTime`.
        let store = makeStore()
        store.setUnreadCutoff(500)
        let atBoundary = store.append(message(id: "boundary", isMine: false, timestamp: 500))
        #expect(atBoundary == .inserted)
        #expect(store.unreadCount == 1)
    }

    @Test func duplicateMessageDoesNotIncrementUnread() {
        let store = makeStore()
        _ = store.append(message(id: "a", isMine: false, timestamp: 100))
        _ = store.append(message(id: "a", isMine: false, timestamp: 100))
        #expect(store.unreadCount == 1)
    }

    @Test func markReadZeroesUnreadCount() {
        let store = makeStore()
        _ = store.append(message(id: "a", isMine: false, timestamp: 100))
        _ = store.append(message(id: "b", isMine: false, timestamp: 200))
        #expect(store.unreadCount == 2)
        store.markRead()
        #expect(store.unreadCount == 0)
    }

    @Test func markReadDoesNotPreventFutureUnreadIncrements() {
        let store = makeStore()
        _ = store.append(message(id: "a", isMine: false, timestamp: 100))
        store.markRead()
        _ = store.append(message(id: "b", isMine: false, timestamp: 200))
        #expect(store.unreadCount == 1)
    }

    // MARK: - Reset

    @Test func resetClearsMessagesAndUnreadButPreservesCutoff() {
        let store = makeStore()
        store.setUnreadCutoff(500)
        _ = store.append(message(id: "a", isMine: false, timestamp: 600))
        #expect(store.unreadCount == 1)
        store.reset()
        #expect(store.messages.isEmpty)
        #expect(store.unreadCount == 0)
        // Cutoff preserved: a message at timestamp 400 should NOT increment unread.
        let outcome = store.append(message(id: "b", isMine: false, timestamp: 400))
        #expect(outcome == .inserted)
        #expect(store.unreadCount == 0)
    }

    @Test func resetAllowsReinsertingPreviouslyDedupedId() {
        let store = makeStore()
        _ = store.append(message(id: "a", timestamp: 100))
        store.reset()
        let outcome = store.append(message(id: "a", timestamp: 100))
        if case .inserted = outcome {} else { Issue.record("expected inserted after reset") }
        #expect(store.messages.count == 1)
    }

    // MARK: - Configuration

    @Test func customCapacityIsHonored() {
        let store = makeStore(capacity: 5)
        for i in 0..<10 {
            _ = store.append(message(id: "m-\(i)", timestamp: 100 + i))
        }
        #expect(store.messages.count == 5)
        #expect(store.messages.map(\.id) == ["m-5", "m-6", "m-7", "m-8", "m-9"])
    }
}

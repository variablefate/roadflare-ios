import Foundation

/// A single message in an in-ride chat thread.
///
/// `id` is the underlying Nostr event id and is used as the deduplication key.
/// `isMine` is determined by the caller (e.g. by comparing the event's pubkey
/// to the local keypair) so the store stays free of any keypair dependency
/// and is symmetric between rider and driver consumers.
public struct ChatMessage: Hashable, Sendable {
    public let id: String
    public let text: String
    public let isMine: Bool
    public let timestamp: Int

    public init(id: String, text: String, isMine: Bool, timestamp: Int) {
        self.id = id
        self.text = text
        self.isMine = isMine
        self.timestamp = timestamp
    }
}

/// Result of appending a message to a `ChatMessageStore`.
///
/// `.duplicate` is returned when a message with the same `id` is already
/// present; the store is unchanged. `.inserted` is returned when the message
/// is accepted; `incrementedUnread` is `true` iff the message was remote
/// (`!isMine`) and its timestamp was at or after the current unread cutoff.
public enum ChatMessageAppendOutcome: Equatable, Sendable {
    case duplicate
    case inserted(incrementedUnread: Bool)
}

/// Platform-neutral in-memory store for an in-ride chat thread.
///
/// Owns deduplication (by message id), stable timestamp-ascending +
/// id-tiebreak sort, fixed FIFO capacity, and unread counting gated by a
/// caller-supplied cutoff so replayed history on subscription start does
/// not inflate the badge.
///
/// Does not parse Nostr events, decrypt content, manage subscriptions, or
/// fire UI feedback such as haptics — callers layer those on top. This
/// keeps the store usable from both rider and driver consumers without
/// pulling in iOS-specific dependencies.
///
/// Thread safety: All mutations are protected by an internal `NSLock`.
/// Safe to call from any single thread; not safe under concurrent writers
/// (matches sibling SDK repo pattern). Current callers are
/// `@MainActor`-serialized.
@Observable
public final class ChatMessageStore: @unchecked Sendable {
    public static let defaultCapacity = 500

    public private(set) var messages: [ChatMessage] = []
    public private(set) var unreadCount: Int = 0

    public let capacity: Int

    private var messageIds: Set<String> = []
    private var unreadCutoff: Int = 0
    private let lock = NSLock()

    public init(capacity: Int = ChatMessageStore.defaultCapacity) {
        precondition(capacity > 0, "ChatMessageStore capacity must be positive")
        self.capacity = capacity
    }

    /// Set the unread-counting cutoff (Unix seconds). Subsequent remote
    /// messages with `timestamp >= cutoff` will bump `unreadCount`.
    /// Callers typically invoke this when a new subscription session begins.
    public func setUnreadCutoff(_ timestamp: Int) {
        lock.withLock { self.unreadCutoff = timestamp }
    }

    /// Append a message. Deduplicates by `id`, inserts in stable sort order
    /// (timestamp ascending, id tiebreak), evicts oldest if capacity is
    /// exceeded, and updates `unreadCount`.
    @discardableResult
    public func append(_ message: ChatMessage) -> ChatMessageAppendOutcome {
        lock.withLock {
            guard !messageIds.contains(message.id) else { return .duplicate }
            messageIds.insert(message.id)
            messages.append(message)
            messages.sort { lhs, rhs in
                lhs.timestamp != rhs.timestamp
                    ? lhs.timestamp < rhs.timestamp
                    : lhs.id < rhs.id
            }
            while messages.count > capacity {
                let removed = messages.removeFirst()
                messageIds.remove(removed.id)
            }
            let incrementedUnread = !message.isMine && message.timestamp >= unreadCutoff
            if incrementedUnread {
                unreadCount += 1
            }
            return .inserted(incrementedUnread: incrementedUnread)
        }
    }

    public func markRead() {
        lock.withLock { unreadCount = 0 }
    }

    /// Clear all messages and reset `unreadCount`. The unread cutoff is
    /// preserved so an ongoing subscription session keeps its cutoff after
    /// a local clear; callers that want to reset the cutoff too should
    /// call `setUnreadCutoff(_:)` explicitly.
    public func reset() {
        lock.withLock {
            messages = []
            messageIds = []
            unreadCount = 0
        }
    }
}

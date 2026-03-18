import Foundation

/// A signed Nostr event (NIP-01).
///
/// This is the SDK's own Codable struct, independent of rust-nostr's Event class.
/// JSON field names follow the NIP-01 specification.
public struct NostrEvent: Codable, Identifiable, Sendable, Hashable {
    /// Event ID: SHA256 hash of the serialized event (64-char hex).
    public let id: String

    /// Author's public key (64-char hex).
    public let pubkey: String

    /// Creation timestamp.
    public let createdAt: Int

    /// Event kind number.
    public let kind: UInt16

    /// Event tags (arrays of strings).
    public let tags: [[String]]

    /// Event content (often NIP-44 encrypted for Ridestr events).
    public let content: String

    /// Schnorr signature (128-char hex).
    public let sig: String

    // MARK: - Coding

    enum CodingKeys: String, CodingKey {
        case id, pubkey, kind, tags, content, sig
        case createdAt = "created_at"
    }

    // MARK: - Convenience Accessors

    /// Map the raw kind to an EventKind enum value, if recognized.
    public var eventKind: EventKind? {
        EventKind(rawValue: kind)
    }

    /// Get the first value of a named tag, or nil.
    /// Example: `event.tag("p")` returns the first p-tag value.
    public func tag(_ name: String) -> String? {
        tags.first { $0.first == name && $0.count > 1 }?[1]
    }

    /// Get all tags with a given name.
    public func allTags(_ name: String) -> [[String]] {
        tags.filter { $0.first == name }
    }

    /// All values of tags with a given name (second element of each tag).
    public func tagValues(_ name: String) -> [String] {
        tags.compactMap { $0.first == name && $0.count > 1 ? $0[1] : nil }
    }

    /// The "d" tag value (for parameterized replaceable events).
    public var dTag: String? {
        tag(NostrTags.dTag)
    }

    /// The "expiration" tag as a Unix timestamp.
    public var expirationTimestamp: Int? {
        guard let str = tag(NostrTags.expiration) else { return nil }
        return Int(str)
    }

    /// Whether the event has expired (NIP-40).
    public var isExpired: Bool {
        guard let expiry = expirationTimestamp else { return false }
        return Int(Date.now.timeIntervalSince1970) > expiry
    }

    /// All referenced event IDs (from "e" tags).
    public var referencedEventIds: [String] {
        tagValues(NostrTags.eventRef)
    }

    /// All referenced public keys (from "p" tags).
    public var referencedPubkeys: [String] {
        tagValues(NostrTags.pubkeyRef)
    }

    /// All geohash tags.
    public var geohashTags: [String] {
        tagValues(NostrTags.geohash)
    }

    /// The "status" tag value.
    public var statusTag: String? {
        tag(NostrTags.status)
    }

    /// The "key_version" tag as an integer.
    public var keyVersionTag: Int? {
        guard let str = tag(NostrTags.keyVersion) else { return nil }
        return Int(str)
    }

    /// Whether this event has a "roadflare" hashtag.
    public var isRoadflare: Bool {
        tagValues(NostrTags.hashtag).contains(NostrTags.roadflareTag)
    }

    // MARK: - Hashable / Equatable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: NostrEvent, rhs: NostrEvent) -> Bool {
        lhs.id == rhs.id
    }
}

import Foundation
import NostrSDK

/// Signs and verifies Nostr events using rust-nostr internally.
public enum EventSigner {
    /// Sign an unsigned event, producing a full NostrEvent.
    ///
    /// - Parameters:
    ///   - kind: Event kind.
    ///   - content: Event content string.
    ///   - tags: Event tags.
    ///   - keypair: The signing keypair.
    ///   - createdAt: Optional custom timestamp (defaults to now).
    /// - Returns: A signed NostrEvent.
    public static func sign(
        kind: UInt16,
        content: String,
        tags: [[String]],
        keypair: NostrKeypair,
        createdAt: Date = .now
    ) async throws -> NostrEvent {
        do {
            let keys = try keypair.toKeys()

            // Build tags
            var rustTags: [Tag] = []
            for tagArray in tags {
                let tag = try Tag.parse(data: tagArray)
                rustTags.append(tag)
            }

            // Build event
            let builder = EventBuilder(kind: Kind(kind: UInt16(kind)), content: content)
                .tags(tags: rustTags)
                .customCreatedAt(createdAt: Timestamp.fromSecs(secs: UInt64(createdAt.timeIntervalSince1970)))

            // Sign
            let signer = NostrSigner.keys(keys: keys)
            let rustEvent = try await builder.sign(signer: signer)

            // Convert to our NostrEvent
            return try fromRustEvent(rustEvent)
        } catch let error as RidestrError {
            throw error
        } catch {
            throw RidestrError.crypto(.signingFailed(underlying: error))
        }
    }

    /// Sign with an EventKind enum value.
    public static func sign(
        kind: EventKind,
        content: String,
        tags: [[String]],
        keypair: NostrKeypair,
        createdAt: Date = .now
    ) async throws -> NostrEvent {
        try await sign(kind: kind.rawValue, content: content, tags: tags, keypair: keypair, createdAt: createdAt)
    }

    /// Verify an event's signature.
    public static func verify(_ event: NostrEvent) -> Bool {
        guard let rustEvent = try? toRustEvent(event) else {
            return false
        }
        return rustEvent.verify()
    }

    // MARK: - Conversion Helpers

    /// Convert our NostrEvent to a rust-nostr Event via JSON roundtrip.
    internal static func toRustEvent(_ event: NostrEvent) throws -> Event {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(event)
            guard let json = String(data: data, encoding: .utf8) else {
                throw RidestrError.ride(.invalidEvent("Failed to encode event to JSON"))
            }
            return try Event.fromJson(json: json)
        } catch let error as RidestrError {
            throw error
        } catch {
            throw RidestrError.ride(.invalidEvent("Failed to parse event: \(error)"))
        }
    }

    /// Convert a rust-nostr Event to our NostrEvent via JSON roundtrip.
    internal static func fromRustEvent(_ event: Event) throws -> NostrEvent {
        do {
            let json = try event.asJson()
            guard let data = json.data(using: .utf8) else {
                throw RidestrError.ride(.invalidEvent("Failed to decode event JSON"))
            }
            let decoder = JSONDecoder()
            return try decoder.decode(NostrEvent.self, from: data)
        } catch let error as RidestrError {
            throw error
        } catch {
            throw RidestrError.ride(.invalidEvent("Failed to decode event: \(error)"))
        }
    }
}

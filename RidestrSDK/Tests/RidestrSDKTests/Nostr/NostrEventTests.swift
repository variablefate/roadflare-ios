import Foundation
import Testing
@testable import RidestrSDK

@Suite("NostrEvent Tests")
struct NostrEventTests {
    // A known NIP-01 event JSON for testing deserialization
    static let sampleJSON = """
    {"id":"abc123","pubkey":"def456","created_at":1700000000,"kind":3173,\
    "tags":[["p","recipient_hex"],["t","rideshare"],["t","roadflare"],\
    ["e","ref_event_id"],["g","9q8yy"],["d","test-dtag"],\
    ["expiration","1700003600"],["status","online"],["key_version","2"]],\
    "content":"encrypted_content","sig":"sig_hex"}
    """

    @Test func decodeFromJSON() throws {
        let data = Self.sampleJSON.data(using: .utf8)!
        let event = try JSONDecoder().decode(NostrEvent.self, from: data)
        #expect(event.id == "abc123")
        #expect(event.pubkey == "def456")
        #expect(event.createdAt == 1700000000)
        #expect(event.kind == 3173)
        #expect(event.content == "encrypted_content")
        #expect(event.sig == "sig_hex")
        #expect(event.tags.count == 9)
    }

    @Test func encodeToJSON() throws {
        let data = Self.sampleJSON.data(using: .utf8)!
        let event = try JSONDecoder().decode(NostrEvent.self, from: data)
        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(NostrEvent.self, from: encoded)
        #expect(decoded.id == event.id)
        #expect(decoded.kind == event.kind)
        #expect(decoded.createdAt == event.createdAt)
    }

    @Test func tagAccessor() throws {
        let data = Self.sampleJSON.data(using: .utf8)!
        let event = try JSONDecoder().decode(NostrEvent.self, from: data)
        #expect(event.tag("p") == "recipient_hex")
        #expect(event.tag("e") == "ref_event_id")
        #expect(event.tag("d") == "test-dtag")
        #expect(event.tag("nonexistent") == nil)
    }

    @Test func tagValues() throws {
        let data = Self.sampleJSON.data(using: .utf8)!
        let event = try JSONDecoder().decode(NostrEvent.self, from: data)
        let topics = event.tagValues("t")
        #expect(topics == ["rideshare", "roadflare"])
    }

    @Test func dTag() throws {
        let data = Self.sampleJSON.data(using: .utf8)!
        let event = try JSONDecoder().decode(NostrEvent.self, from: data)
        #expect(event.dTag == "test-dtag")
    }

    @Test func expirationTimestamp() throws {
        let data = Self.sampleJSON.data(using: .utf8)!
        let event = try JSONDecoder().decode(NostrEvent.self, from: data)
        #expect(event.expirationTimestamp == 1700003600)
    }

    @Test func isExpired() throws {
        let data = Self.sampleJSON.data(using: .utf8)!
        let event = try JSONDecoder().decode(NostrEvent.self, from: data)
        // Expiration is in 2023, so it's expired
        #expect(event.isExpired)
    }

    @Test func referencedEventIds() throws {
        let data = Self.sampleJSON.data(using: .utf8)!
        let event = try JSONDecoder().decode(NostrEvent.self, from: data)
        #expect(event.referencedEventIds == ["ref_event_id"])
    }

    @Test func referencedPubkeys() throws {
        let data = Self.sampleJSON.data(using: .utf8)!
        let event = try JSONDecoder().decode(NostrEvent.self, from: data)
        #expect(event.referencedPubkeys == ["recipient_hex"])
    }

    @Test func geohashTags() throws {
        let data = Self.sampleJSON.data(using: .utf8)!
        let event = try JSONDecoder().decode(NostrEvent.self, from: data)
        #expect(event.geohashTags == ["9q8yy"])
    }

    @Test func eventKindMapping() throws {
        let data = Self.sampleJSON.data(using: .utf8)!
        let event = try JSONDecoder().decode(NostrEvent.self, from: data)
        #expect(event.eventKind == .rideOffer)
    }

    @Test func isRoadflare() throws {
        let data = Self.sampleJSON.data(using: .utf8)!
        let event = try JSONDecoder().decode(NostrEvent.self, from: data)
        #expect(event.isRoadflare)
    }

    @Test func statusAndKeyVersion() throws {
        let data = Self.sampleJSON.data(using: .utf8)!
        let event = try JSONDecoder().decode(NostrEvent.self, from: data)
        #expect(event.statusTag == "online")
        #expect(event.keyVersionTag == 2)
    }

    @Test func hashableEquatable() throws {
        let data = Self.sampleJSON.data(using: .utf8)!
        let event1 = try JSONDecoder().decode(NostrEvent.self, from: data)
        let event2 = try JSONDecoder().decode(NostrEvent.self, from: data)
        #expect(event1 == event2)
        #expect(event1.hashValue == event2.hashValue)
    }
}

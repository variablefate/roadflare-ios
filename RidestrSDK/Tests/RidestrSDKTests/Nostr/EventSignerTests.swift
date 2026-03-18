import Foundation
import Testing
@testable import RidestrSDK

@Suite("EventSigner Tests")
struct EventSignerTests {
    @Test func signAndVerify() async throws {
        let keypair = try NostrKeypair.generate()
        let event = try await EventSigner.sign(
            kind: .rideOffer,
            content: "test content",
            tags: [["p", "some_pubkey"], ["t", "rideshare"]],
            keypair: keypair
        )
        #expect(EventSigner.verify(event))
    }

    @Test func signedEventHasCorrectPubkey() async throws {
        let keypair = try NostrKeypair.generate()
        let event = try await EventSigner.sign(
            kind: .chatMessage,
            content: "hello",
            tags: [],
            keypair: keypair
        )
        #expect(event.pubkey == keypair.publicKeyHex)
    }

    @Test func signedEventHasCorrectKind() async throws {
        let keypair = try NostrKeypair.generate()
        let event = try await EventSigner.sign(
            kind: .cancellation,
            content: "{}",
            tags: [],
            keypair: keypair
        )
        #expect(event.kind == EventKind.cancellation.rawValue)
    }

    @Test func signedEventHasValidId() async throws {
        let keypair = try NostrKeypair.generate()
        let event = try await EventSigner.sign(
            kind: .rideOffer,
            content: "test",
            tags: [],
            keypair: keypair
        )
        #expect(event.id.count == 64)
        // ID should be hex
        #expect(event.id.allSatisfy { $0.isHexDigit })
    }

    @Test func signedEventHasValidSig() async throws {
        let keypair = try NostrKeypair.generate()
        let event = try await EventSigner.sign(
            kind: .rideOffer,
            content: "test",
            tags: [],
            keypair: keypair
        )
        #expect(event.sig.count == 128)
        #expect(event.sig.allSatisfy { $0.isHexDigit })
    }

    @Test func tagsPreserved() async throws {
        let keypair = try NostrKeypair.generate()
        let inputTags = [
            ["p", "recipient_pubkey"],
            ["t", "rideshare"],
            ["t", "roadflare"],
            ["e", "some_event_id"],
        ]
        let event = try await EventSigner.sign(
            kind: .rideOffer,
            content: "{}",
            tags: inputTags,
            keypair: keypair
        )
        #expect(event.tag("p") == "recipient_pubkey")
        #expect(event.tagValues("t").contains("rideshare"))
        #expect(event.tagValues("t").contains("roadflare"))
        #expect(event.tag("e") == "some_event_id")
    }

    @Test func contentPreserved() async throws {
        let keypair = try NostrKeypair.generate()
        let content = "{\"fare_estimate\":12.50,\"payment_method\":\"zelle\"}"
        let event = try await EventSigner.sign(
            kind: .rideOffer,
            content: content,
            tags: [],
            keypair: keypair
        )
        #expect(event.content == content)
    }

    @Test func verifyTamperedContentFails() async throws {
        let keypair = try NostrKeypair.generate()
        let event = try await EventSigner.sign(
            kind: .rideOffer,
            content: "original",
            tags: [],
            keypair: keypair
        )
        // Create a tampered event by modifying content
        let tampered = NostrEvent(
            id: event.id,
            pubkey: event.pubkey,
            createdAt: event.createdAt,
            kind: event.kind,
            tags: event.tags,
            content: "tampered",
            sig: event.sig
        )
        #expect(!EventSigner.verify(tampered))
    }

    @Test func signWithRawKind() async throws {
        let keypair = try NostrKeypair.generate()
        let event = try await EventSigner.sign(
            kind: UInt16(3173),
            content: "test",
            tags: [],
            keypair: keypair
        )
        #expect(event.kind == 3173)
        #expect(EventSigner.verify(event))
    }

    @Test func signReplaceableEventWithDTag() async throws {
        let keypair = try NostrKeypair.generate()
        let event = try await EventSigner.sign(
            kind: .roadflareLocation,
            content: "encrypted_location",
            tags: [
                ["d", "roadflare-location"],
                ["status", "online"],
                ["key_version", "2"],
                ["expiration", "9999999999"],
            ],
            keypair: keypair
        )
        #expect(event.dTag == "roadflare-location")
        #expect(event.statusTag == "online")
        #expect(event.keyVersionTag == 2)
        #expect(!event.isExpired)
        #expect(EventSigner.verify(event))
    }

    @Test func signedEventHasReasonableTimestamp() async throws {
        let keypair = try NostrKeypair.generate()
        let before = Int(Date.now.timeIntervalSince1970)
        let event = try await EventSigner.sign(
            kind: .rideOffer,
            content: "test",
            tags: [],
            keypair: keypair
        )
        let after = Int(Date.now.timeIntervalSince1970)
        // createdAt should be between before and after (within a few seconds)
        #expect(event.createdAt >= before - 2)
        #expect(event.createdAt <= after + 2)
    }

    @Test func jsonRoundtripConversion() async throws {
        let keypair = try NostrKeypair.generate()
        let original = try await EventSigner.sign(
            kind: .rideOffer,
            content: "roundtrip test",
            tags: [["p", "abc"], ["t", "rideshare"]],
            keypair: keypair
        )
        // Convert to rust-nostr and back
        let rustEvent = try EventSigner.toRustEvent(original)
        let restored = try EventSigner.fromRustEvent(rustEvent)
        #expect(original.id == restored.id)
        #expect(original.pubkey == restored.pubkey)
        #expect(original.kind == restored.kind)
        #expect(original.content == restored.content)
        #expect(original.sig == restored.sig)
    }
}

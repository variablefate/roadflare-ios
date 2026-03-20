import Foundation
import Testing
@testable import RidestrSDK

@Suite("RideshareEventParser Tests")
struct RideshareEventParserTests {
    @Test func parseRoadflareLocation() throws {
        let driverIdentity = try NostrKeypair.generate()
        let roadflareKey = try NostrKeypair.generate()

        // Simulate driver broadcasting location
        let locationJSON = """
        {"lat":40.7128,"lon":-74.006,"timestamp":1700000000,"status":"online"}
        """
        let encrypted = try NIP44.encrypt(
            plaintext: locationJSON,
            senderPrivateKeyHex: driverIdentity.privateKeyHex,
            recipientPublicKeyHex: roadflareKey.publicKeyHex
        )

        // Build a fake event (we construct it manually since we can't sign as the driver here)
        let event = NostrEvent(
            id: "loc_event_1",
            pubkey: driverIdentity.publicKeyHex,
            createdAt: 1700000000,
            kind: EventKind.roadflareLocation.rawValue,
            tags: [
                ["d", "roadflare-location"],
                ["status", "online"],
                ["key_version", "2"],
            ],
            content: encrypted,
            sig: "fake_sig"  // Verification not tested here
        )

        let parsed = try RideshareEventParser.parseRoadflareLocation(
            event: event,
            roadflarePrivateKeyHex: roadflareKey.privateKeyHex
        )

        #expect(parsed.driverPubkey == driverIdentity.publicKeyHex)
        #expect(parsed.location.latitude == 40.7128)
        #expect(parsed.location.longitude == -74.006)
        #expect(parsed.location.status == .online)
        #expect(parsed.keyVersion == 2)
    }

    @Test func parseRoadflareLocationUnauthorizedFails() throws {
        let driverIdentity = try NostrKeypair.generate()
        let roadflareKey = try NostrKeypair.generate()
        let unauthorizedKey = try NostrKeypair.generate()

        let encrypted = try NIP44.encrypt(
            plaintext: "{\"lat\":0,\"lon\":0,\"timestamp\":0,\"status\":\"online\"}",
            senderPrivateKeyHex: driverIdentity.privateKeyHex,
            recipientPublicKeyHex: roadflareKey.publicKeyHex
        )

        let event = NostrEvent(
            id: "loc1", pubkey: driverIdentity.publicKeyHex, createdAt: 1700000000,
            kind: EventKind.roadflareLocation.rawValue,
            tags: [["d", "roadflare-location"]], content: encrypted, sig: "sig"
        )

        #expect(throws: RidestrError.self) {
            try RideshareEventParser.parseRoadflareLocation(
                event: event,
                roadflarePrivateKeyHex: unauthorizedKey.privateKeyHex
            )
        }
    }

    @Test func parseKeyShare() async throws {
        let driver = try NostrKeypair.generate()
        let rider = try NostrKeypair.generate()

        let keyShareContent = KeyShareContent(
            roadflareKey: RoadflareKey(
                privateKeyHex: "abcd1234",
                publicKeyHex: "efgh5678",
                version: 2,
                keyUpdatedAt: 1700000000
            ),
            keyUpdatedAt: 1700000000,
            driverPubKey: driver.publicKeyHex
        )
        let json = try JSONEncoder().encode(keyShareContent)
        let plaintext = String(data: json, encoding: .utf8)!

        let encrypted = try NIP44.encrypt(
            plaintext: plaintext,
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: rider.publicKeyHex
        )

        let futureExpiry = Int(Date.now.timeIntervalSince1970) + 300
        let event = NostrEvent(
            id: "ks1", pubkey: driver.publicKeyHex, createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.keyShare.rawValue,
            tags: [
                ["p", rider.publicKeyHex],
                ["expiration", String(futureExpiry)],
            ],
            content: encrypted, sig: "sig"
        )

        let parsed = try RideshareEventParser.parseKeyShare(event: event, keypair: rider)
        #expect(parsed.driverPubkey == driver.publicKeyHex)
        #expect(parsed.roadflareKey.version == 2)
        #expect(parsed.keyUpdatedAt == 1700000000)
    }

    @Test func parseKeyShareWrongRecipientFails() throws {
        let driver = try NostrKeypair.generate()
        let rider = try NostrKeypair.generate()
        let otherRider = try NostrKeypair.generate()

        let event = NostrEvent(
            id: "ks1", pubkey: driver.publicKeyHex, createdAt: 1700000000,
            kind: EventKind.keyShare.rawValue,
            tags: [["p", otherRider.publicKeyHex]],
            content: "encrypted", sig: "sig"
        )

        #expect(throws: RidestrError.self) {
            try RideshareEventParser.parseKeyShare(event: event, keypair: rider)
        }
    }

    @Test func parseKeyShareExpiredFails() throws {
        let driver = try NostrKeypair.generate()
        let rider = try NostrKeypair.generate()

        let pastExpiry = Int(Date.now.timeIntervalSince1970) - 300
        let event = NostrEvent(
            id: "ks1", pubkey: driver.publicKeyHex, createdAt: 1700000000,
            kind: EventKind.keyShare.rawValue,
            tags: [
                ["p", rider.publicKeyHex],
                ["expiration", String(pastExpiry)],
            ],
            content: "encrypted", sig: "sig"
        )

        #expect(throws: RidestrError.self) {
            try RideshareEventParser.parseKeyShare(event: event, keypair: rider)
        }
    }

    @Test func parseReplaceableKeyShare() async throws {
        let driver = try NostrKeypair.generate()
        let rider = try NostrKeypair.generate()

        let keyShareContent = KeyShareContent(
            roadflareKey: RoadflareKey(
                privateKeyHex: "abcd1234",
                publicKeyHex: "efgh5678",
                version: 3,
                keyUpdatedAt: 1700000000
            ),
            keyUpdatedAt: 1700000000,
            driverPubKey: driver.publicKeyHex
        )
        let json = try JSONEncoder().encode(keyShareContent)
        let plaintext = String(data: json, encoding: .utf8)!

        let encrypted = try NIP44.encrypt(
            plaintext: plaintext,
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: rider.publicKeyHex
        )

        // Kind 30186 — replaceable, no expiration, d-tag = rider pubkey
        let event = NostrEvent(
            id: "rks1", pubkey: driver.publicKeyHex, createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.replaceableKeyShare.rawValue,
            tags: [
                ["d", rider.publicKeyHex],
                ["p", rider.publicKeyHex],
            ],
            content: encrypted, sig: "sig"
        )

        let parsed = try RideshareEventParser.parseKeyShare(event: event, keypair: rider)
        #expect(parsed.driverPubkey == driver.publicKeyHex)
        #expect(parsed.roadflareKey.version == 3)
        #expect(parsed.keyUpdatedAt == 1700000000)
    }

    @Test func parseKeyShareRejectsWrongKind() throws {
        let driver = try NostrKeypair.generate()
        let rider = try NostrKeypair.generate()

        let event = NostrEvent(
            id: "ks1", pubkey: driver.publicKeyHex, createdAt: 1700000000,
            kind: EventKind.rideOffer.rawValue,  // Wrong kind
            tags: [["p", rider.publicKeyHex]],
            content: "encrypted", sig: "sig"
        )

        #expect(throws: RidestrError.self) {
            try RideshareEventParser.parseKeyShare(event: event, keypair: rider)
        }
    }

    @Test func parseChatMessageRoundtrip() async throws {
        let sender = try NostrKeypair.generate()
        let receiver = try NostrKeypair.generate()

        let event = try await RideshareEventBuilder.chatMessage(
            recipientPubkey: receiver.publicKeyHex,
            confirmationEventId: "conf1",
            message: "Hello!",
            keypair: sender
        )

        let parsed = try RideshareEventParser.parseChatMessage(event: event, keypair: receiver)
        #expect(parsed.message == "Hello!")
    }

    @Test func parseCancellationRoundtrip() async throws {
        let sender = try NostrKeypair.generate()
        let receiver = try NostrKeypair.generate()

        let event = try await RideshareEventBuilder.cancellation(
            counterpartyPubkey: receiver.publicKeyHex,
            confirmationEventId: "conf1",
            reason: "Taking too long",
            keypair: sender
        )

        let parsed = try RideshareEventParser.parseCancellation(event: event, keypair: receiver)
        #expect(parsed.reason == "Taking too long")
    }

    @Test func wrongEventKindThrows() throws {
        let keypair = try NostrKeypair.generate()
        let event = NostrEvent(
            id: "e1", pubkey: keypair.publicKeyHex, createdAt: 1700000000,
            kind: 9999, tags: [], content: "{}", sig: "sig"
        )

        #expect(throws: RidestrError.self) {
            try RideshareEventParser.parseAcceptance(event: event, keypair: keypair)
        }
        #expect(throws: RidestrError.self) {
            try RideshareEventParser.parseDriverRideState(event: event, keypair: keypair)
        }
        #expect(throws: RidestrError.self) {
            try RideshareEventParser.parseChatMessage(event: event, keypair: keypair)
        }
    }

    @Test func encryptAndDecryptLocation() throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        let location = Location(latitude: 40.71234, longitude: -74.00567, address: "123 Main St")
        let encrypted = try RideshareEventParser.encryptLocation(
            location: location,
            recipientPubkey: driver.publicKeyHex,
            keypair: rider
        )

        let decrypted = try NIP44.decrypt(
            ciphertext: encrypted,
            receiverKeypair: driver,
            senderPublicKeyHex: rider.publicKeyHex
        )
        let parsed = try JSONDecoder().decode(Location.self, from: Data(decrypted.utf8))
        #expect(parsed.latitude == 40.71234)
        #expect(parsed.longitude == -74.00567)
    }

    @Test func malformedJsonInsideEncryptedEventThrows() throws {
        let alice = try NostrKeypair.generate()
        let bob = try NostrKeypair.generate()

        // Encrypt invalid JSON
        let encrypted = try NIP44.encrypt(
            plaintext: "this is not json",
            senderPrivateKeyHex: alice.privateKeyHex,
            recipientPublicKeyHex: bob.publicKeyHex
        )

        let event = NostrEvent(
            id: "e1", pubkey: alice.publicKeyHex, createdAt: 1700000000,
            kind: EventKind.chatMessage.rawValue,
            tags: [["p", bob.publicKeyHex]],
            content: encrypted, sig: "sig"
        )

        // Decryption succeeds but JSON parsing should fail
        #expect(throws: Error.self) {
            try RideshareEventParser.parseChatMessage(event: event, keypair: bob)
        }
    }

    @Test func parseFollowedDriversWrongAuthorThrows() throws {
        let me = try NostrKeypair.generate()
        let other = try NostrKeypair.generate()

        // Event authored by someone else
        let event = NostrEvent(
            id: "e1", pubkey: other.publicKeyHex, createdAt: 1700000000,
            kind: EventKind.followedDriversList.rawValue,
            tags: [["d", "roadflare-drivers"]],
            content: "encrypted", sig: "sig"
        )

        #expect(throws: RidestrError.self) {
            try RideshareEventParser.parseFollowedDriversList(event: event, keypair: me)
        }
    }

    @Test func decryptPin() throws {
        let driver = try NostrKeypair.generate()
        let rider = try NostrKeypair.generate()

        // Driver encrypts PIN for rider
        let encrypted = try NIP44.encrypt(
            plaintext: "1234",
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: rider.publicKeyHex
        )

        let decrypted = try RideshareEventParser.decryptPin(
            pinEncrypted: encrypted,
            driverPubkey: driver.publicKeyHex,
            keypair: rider
        )
        #expect(decrypted == "1234")
    }
}

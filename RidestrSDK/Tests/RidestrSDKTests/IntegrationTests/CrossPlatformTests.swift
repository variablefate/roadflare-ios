import Foundation
import Testing
@testable import RidestrSDK

private let crossPlatformConfirmationEventId = String(repeating: "b", count: 64)

/// Tests that verify our SDK produces output compatible with the Android implementation.
/// These catch the integration boundary failures that unit tests miss.
@Suite("Cross-Platform Compatibility Tests")
struct CrossPlatformTests {

    // MARK: - JSON Boundary: NostrEvent vs Real Relay Format

    @Test func parseEventFromRealisticRelayJSON() throws {
        // This is exactly what a relay sends — integer kinds, integer timestamps, string arrays
        let relayJSON = """
        {
            "id": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
            "pubkey": "f1e2d3c4b5a6f1e2d3c4b5a6f1e2d3c4b5a6f1e2d3c4b5a6f1e2d3c4b5a6f1e2",
            "created_at": 1700000000,
            "kind": 3173,
            "tags": [
                ["p", "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"],
                ["t", "rideshare"],
                ["t", "roadflare"],
                ["e", "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"],
                ["g", "dr5ru"],
                ["expiration", "1700001000"]
            ],
            "content": "NIP44_encrypted_content_here",
            "sig": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(NostrEvent.self, from: relayJSON)
        #expect(event.kind == 3173)
        #expect(event.eventKind == .rideOffer)
        #expect(event.createdAt == 1700000000)
        #expect(event.isRoadflare)
        #expect(event.referencedPubkeys.count == 1)
        #expect(event.referencedEventIds.count == 1)
        #expect(event.geohashTags == ["dr5ru"])
        #expect(event.expirationTimestamp == 1700001000)
    }

    @Test func parseEventWithLargeKindNumber() throws {
        // Replaceable events have kind 30000+, ensure UInt16 handles it
        let json = """
        {"id":"abc","pubkey":"def","created_at":1700000000,"kind":30180,\
        "tags":[["d","conf123"]],"content":"{}","sig":"sig"}
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(NostrEvent.self, from: json)
        #expect(event.kind == 30180)
        #expect(event.eventKind == .driverRideState)
        #expect(event.dTag == "conf123")
    }

    @Test func parseEventWithExtraUnknownFields() throws {
        // Relays may add fields our model doesn't know about — ensure it doesn't crash
        let json = """
        {"id":"abc","pubkey":"def","created_at":1700000000,"kind":3173,\
        "tags":[],"content":"test","sig":"sig","relay":"wss://example.com","seen_on":["r1","r2"]}
        """.data(using: .utf8)!

        // JSONDecoder by default ignores unknown keys — verify this works
        let event = try JSONDecoder().decode(NostrEvent.self, from: json)
        #expect(event.id == "abc")
        #expect(event.kind == 3173)
    }

    @Test func parseEventWithEmptyTags() throws {
        let json = """
        {"id":"abc","pubkey":"def","created_at":1700000000,"kind":3178,\
        "tags":[],"content":"encrypted","sig":"sig"}
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(NostrEvent.self, from: json)
        #expect(event.tags.isEmpty)
        #expect(event.tag("p") == nil)
        #expect(event.referencedPubkeys.isEmpty)
    }

    // MARK: - Event Signing → rust-nostr Roundtrip

    @Test func signedEventSurvivesRustNostrRoundtrip() async throws {
        let keypair = try NostrKeypair.generate()

        let original = try await EventSigner.sign(
            kind: .rideOffer,
            content: "{\"fare_estimate\":12.50,\"payment_method\":\"zelle\"}",
            tags: [
                ["p", "recipient_pubkey_hex_64chars_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
                ["t", "rideshare"],
                ["t", "roadflare"],
                ["e", "referenced_event_id_hex_64chars_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],
                ["g", "dr5ru"],
                ["d", "test-dtag"],
                ["expiration", "9999999999"],
            ],
            keypair: keypair
        )

        // Convert to rust-nostr and back (this is what happens during publish/receive)
        let rustEvent = try EventSigner.toRustEvent(original)
        let restored = try EventSigner.fromRustEvent(rustEvent)

        // Every field must survive the roundtrip
        #expect(restored.id == original.id)
        #expect(restored.pubkey == original.pubkey)
        #expect(restored.createdAt == original.createdAt)
        #expect(restored.kind == original.kind)
        #expect(restored.content == original.content)
        #expect(restored.sig == original.sig)
        #expect(restored.tags.count == original.tags.count)

        // Tag accessors must work on the restored event
        #expect(restored.isRoadflare)
        #expect(restored.dTag == "test-dtag")
        #expect(restored.geohashTags == ["dr5ru"])

        // Signature must still verify after roundtrip
        #expect(EventSigner.verify(restored))
    }

    // MARK: - NIP-44 Cross-Platform Encryption

    @Test func nip44EncryptionIsSymmetric() throws {
        // Verify the ECDH property: encrypt(A_priv, B_pub) can be decrypted by (B_priv, A_pub)
        // This is what makes cross-platform work — iOS rider encrypts, Android driver decrypts
        let iosRider = try NostrKeypair.generate()
        let androidDriver = try NostrKeypair.generate()

        let offerContent = """
        {"fare_estimate":15.00,"approx_pickup":{"lat":40.71,"lon":-74.01},\
        "destination":{"lat":40.76,"lon":-73.98},"payment_method":"zelle",\
        "fiat_payment_methods":["zelle","venmo","cash"]}
        """

        // iOS rider encrypts for Android driver
        let ciphertext = try NIP44.encrypt(
            plaintext: offerContent,
            senderPrivateKeyHex: iosRider.privateKeyHex,
            recipientPublicKeyHex: androidDriver.publicKeyHex
        )

        // Android driver decrypts (same operation, just swapped keys)
        let decrypted = try NIP44.decrypt(
            ciphertext: ciphertext,
            receiverPrivateKeyHex: androidDriver.privateKeyHex,
            senderPublicKeyHex: iosRider.publicKeyHex
        )

        #expect(decrypted == offerContent)
    }

    @Test func nip44SelfEncryptionForBackups() throws {
        // Kind 30011 (followed drivers) encrypts to self
        let keypair = try NostrKeypair.generate()
        let backupContent = """
        {"drivers":[{"pubkey":"abc","addedAt":1700000000,"note":"test driver","roadflareKey":null}],"updated_at":1700000000}
        """

        let encrypted = try NIP44.encryptToSelf(
            plaintext: backupContent,
            privateKeyHex: keypair.privateKeyHex,
            publicKeyHex: keypair.publicKeyHex
        )
        let decrypted = try NIP44.decryptFromSelf(
            ciphertext: encrypted,
            privateKeyHex: keypair.privateKeyHex,
            publicKeyHex: keypair.publicKeyHex
        )
        #expect(decrypted == backupContent)

        // Verify it's valid JSON that our model can parse
        let parsed = try JSONDecoder().decode(FollowedDriversContent.self, from: Data(decrypted.utf8))
        #expect(parsed.drivers.count == 1)
    }

    // MARK: - RoadFlare Location ECDH Model (Critical for Interop)

    @Test func roadflareLocationFullFlow() throws {
        // Simulate: Android driver broadcasts, iOS rider decrypts

        // 1. Driver has identity key + RoadFlare key
        let driverIdentity = try NostrKeypair.generate()
        let roadflareKey = try NostrKeypair.generate()

        // 2. Driver encrypts location to RoadFlare pubkey
        let locationJSON = """
        {"lat":36.1699,"lon":-115.1398,"timestamp":1700000000,"status":"online"}
        """
        let encrypted = try NIP44.encrypt(
            plaintext: locationJSON,
            senderPrivateKeyHex: driverIdentity.privateKeyHex,
            recipientPublicKeyHex: roadflareKey.publicKeyHex
        )

        // 3. Build the event (as Android driver would publish)
        let event = NostrEvent(
            id: "loc1",
            pubkey: driverIdentity.publicKeyHex,
            createdAt: 1700000000,
            kind: EventKind.roadflareLocation.rawValue,
            tags: [
                ["d", "roadflare-location"],
                ["status", "online"],
                ["key_version", "1"],
                ["expiration", "1700000300"],
            ],
            content: encrypted,
            sig: "fake_sig_for_test"
        )

        // 4. iOS rider decrypts using the shared RoadFlare private key
        let parsed = try RideshareEventParser.parseRoadflareLocation(
            event: event,
            roadflarePrivateKeyHex: roadflareKey.privateKeyHex
        )

        #expect(parsed.driverPubkey == driverIdentity.publicKeyHex)
        #expect(parsed.location.latitude == 36.1699)
        #expect(parsed.location.longitude == -115.1398)
        #expect(parsed.location.status == .online)
        #expect(parsed.keyVersion == 1)
    }

    // MARK: - Full Ride Offer → Acceptance Flow (End-to-End)

    @Test func rideOfferToAcceptanceEndToEnd() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        // 1. Rider builds and signs an offer
        let offerContent = RideOfferContent(
            fareEstimate: 12.50,
            destination: Location(latitude: 40.758, longitude: -73.985),
            approxPickup: Location(latitude: 40.71, longitude: -74.01),
            rideRouteKm: 5.5,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle", "venmo"]
        )
        let offerEvent = try await RideshareEventBuilder.rideOffer(
            driverPubkey: driver.publicKeyHex,
            driverAvailabilityEventId: nil,
            content: offerContent,
            keypair: rider
        )

        // 2. Verify the offer event is properly structured
        #expect(offerEvent.kind == EventKind.rideOffer.rawValue)
        #expect(offerEvent.isRoadflare)
        #expect(EventSigner.verify(offerEvent))

        // 3. Driver decrypts the offer
        let decryptedContent = try NIP44.decrypt(
            ciphertext: offerEvent.content,
            receiverKeypair: driver,
            senderPublicKeyHex: rider.publicKeyHex
        )
        let parsedOffer = try JSONDecoder().decode(RideOfferContent.self, from: Data(decryptedContent.utf8))
        #expect(parsedOffer.fareEstimate == 12.50)
        #expect(parsedOffer.fiatPaymentMethods == ["zelle", "venmo"])

        // 4. Simulate driver acceptance (would be Kind 3174 from Android)
        let acceptanceJSON = """
        {"status":"accepted","wallet_pubkey":null,"payment_method":"zelle","mint_url":null}
        """
        let acceptanceEvent = NostrEvent(
            id: "acc1", pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.rideAcceptance.rawValue,
            tags: [["e", offerEvent.id], ["p", rider.publicKeyHex]],
            content: acceptanceJSON, sig: "fake_sig"
        )

        // 5. Rider parses the acceptance
        let acceptance = try RideshareEventParser.parseAcceptance(
            event: acceptanceEvent, keypair: rider
        )
        #expect(acceptance.status == "accepted")
        #expect(acceptance.paymentMethod == "zelle")

        // 6. State machine processes the acceptance
        let sm = RideStateMachine()
        try sm.startRide(
            offerEventId: offerEvent.id,
            driverPubkey: driver.publicKeyHex,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle", "venmo"]
        )
        let pin = try sm.handleAcceptance(acceptanceEventId: acceptanceEvent.id)
        #expect(pin.count == 4)
        #expect(sm.stage == .driverAccepted)
    }

    @Test func riderRideStateUsesAndroidCompatiblePlaintextEnvelope() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        let history = [
            RiderRideAction(
                type: "pin_verify",
                at: 1700000000,
                locationType: nil,
                locationEncrypted: nil,
                status: "verified",
                attempt: 1
            )
        ]

        let event = try await RideshareEventBuilder.riderRideState(
            driverPubkey: driver.publicKeyHex,
            confirmationEventId: crossPlatformConfirmationEventId,
            phase: "verified",
            history: history,
            keypair: rider
        )

        #expect(event.kind == EventKind.riderRideState.rawValue)
        #expect(event.dTag == crossPlatformConfirmationEventId)
        #expect(event.referencedEventIds.contains(crossPlatformConfirmationEventId))
        #expect(event.referencedPubkeys.contains(driver.publicKeyHex))

        let decoded = try JSONDecoder().decode(RiderRideStateContent.self, from: Data(event.content.utf8))
        #expect(decoded.currentPhase == "verified")
        #expect(decoded.history.count == 1)
    }

    @Test func cancellationUsesAndroidCompatiblePlaintextEnvelope() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        let event = try await RideshareEventBuilder.cancellation(
            counterpartyPubkey: driver.publicKeyHex,
            confirmationEventId: crossPlatformConfirmationEventId,
            reason: "Changed plans",
            keypair: rider
        )

        #expect(event.kind == EventKind.cancellation.rawValue)
        #expect(event.referencedEventIds.contains(crossPlatformConfirmationEventId))
        #expect(event.referencedPubkeys.contains(driver.publicKeyHex))

        let decoded = try JSONDecoder().decode(CancellationContent.self, from: Data(event.content.utf8))
        #expect(decoded.status == "cancelled")
        #expect(decoded.reason == "Changed plans")
    }

    // MARK: - Location Model JSON Compatibility

    @Test func locationJSONMatchesAndroidFormat() throws {
        // Android uses {"lat": double, "lon": double}
        let loc = Location(latitude: 40.71234, longitude: -74.00567)
        let data = try JSONEncoder().encode(loc)
        let json = String(data: data, encoding: .utf8)!

        // Must contain "lat" and "lon" keys (not "latitude"/"longitude")
        #expect(json.contains("\"lat\""))
        #expect(json.contains("\"lon\""))
        #expect(!json.contains("\"latitude\""))
        #expect(!json.contains("\"longitude\""))
    }

    @Test func locationDecodesFromAndroidFormat() throws {
        let androidJSON = """
        {"lat": 40.71234, "lon": -74.00567}
        """.data(using: .utf8)!

        let loc = try JSONDecoder().decode(Location.self, from: androidJSON)
        #expect(loc.latitude == 40.71234)
        #expect(loc.longitude == -74.00567)
    }
}

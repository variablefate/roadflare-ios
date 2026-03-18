import Foundation
import Testing
@testable import RidestrSDK

@Suite("SDK Integration Tests")
struct SDKIntegrationTests {
    @Test func generateKeySignEventVerify() async throws {
        let keypair = try NostrKeypair.generate()

        let event = try await EventSigner.sign(
            kind: .rideOffer,
            content: "{\"fare_estimate\":12.50}",
            tags: [
                ["p", "driver_pubkey_hex"],
                ["t", "rideshare"],
                ["t", "roadflare"],
            ],
            keypair: keypair
        )

        #expect(event.pubkey == keypair.publicKeyHex)
        #expect(event.kind == EventKind.rideOffer.rawValue)
        #expect(event.isRoadflare)
        #expect(EventSigner.verify(event))
    }

    @Test func encryptedEventRoundtrip() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        // Rider encrypts ride offer content for the driver
        let offerJSON = """
        {"fare_estimate":15.00,"approx_pickup":{"lat":40.71,"lon":-74.01},"payment_method":"zelle"}
        """
        let encrypted = try NIP44.encrypt(
            plaintext: offerJSON,
            senderKeypair: rider,
            recipientPublicKeyHex: driver.publicKeyHex
        )

        // Build and sign the event with encrypted content
        let event = try await EventSigner.sign(
            kind: .rideOffer,
            content: encrypted,
            tags: [
                ["p", driver.publicKeyHex],
                ["t", "rideshare"],
                ["t", "roadflare"],
            ],
            keypair: rider
        )

        // Verify signature
        #expect(EventSigner.verify(event))

        // Driver decrypts the content
        let decrypted = try NIP44.decrypt(
            ciphertext: event.content,
            receiverKeypair: driver,
            senderPublicKeyHex: rider.publicKeyHex
        )
        #expect(decrypted == offerJSON)
    }

    @Test func keyManagerPersistenceAndEventSigning() async throws {
        let storage = FakeKeychainStorage()
        let manager = KeyManager(storage: storage)

        // Generate and persist a key
        let keypair = try await manager.generate()
        #expect(await manager.hasKeys)

        // Sign an event
        let event = try await EventSigner.sign(
            kind: .chatMessage,
            content: "{\"message\":\"Hey, on my way!\"}",
            tags: [["t", "rideshare"]],
            keypair: keypair
        )
        #expect(EventSigner.verify(event))

        // Restore from storage and verify same key
        let manager2 = KeyManager(storage: storage)
        let restored = await manager2.getKeypair()
        #expect(restored?.publicKeyHex == keypair.publicKeyHex)
    }

    @Test func geohashLocationIntegration() {
        let pickup = Location(latitude: 40.7128, longitude: -74.0060)
        let destination = Location(latitude: 40.7580, longitude: -73.9855)

        // Generate geohash tags for the ride offer
        let pickupTags = pickup.geohashTags(minPrecision: 3, maxPrecision: 5)
        #expect(pickupTags.count == 3)

        // Approximate location for privacy
        let approxPickup = pickup.approximate()
        #expect(approxPickup.latitude == 40.71)
        #expect(approxPickup.longitude == -74.01)

        // Distance check
        let distKm = pickup.distance(to: destination)
        #expect(distKm > 4 && distKm < 7)  // ~5.5 km
    }

    @Test func filterMatchesEventAccessors() async throws {
        let keypair = try NostrKeypair.generate()

        // Create an event with specific tags
        let event = try await EventSigner.sign(
            kind: .roadflareLocation,
            content: "encrypted_location",
            tags: [
                ["d", "roadflare-location"],
                ["status", "online"],
                ["key_version", "3"],
                ["expiration", "9999999999"],
            ],
            keypair: keypair
        )

        // Verify accessors work
        #expect(event.eventKind == .roadflareLocation)
        #expect(event.dTag == "roadflare-location")
        #expect(event.statusTag == "online")
        #expect(event.keyVersionTag == 3)
        #expect(!event.isExpired)  // Far future expiration
    }

    @Test func nip19Roundtrip() throws {
        let keypair = try NostrKeypair.generate()

        // npub roundtrip
        let npub = try NIP19.npubEncode(publicKeyHex: keypair.publicKeyHex)
        let decodedPub = try NIP19.npubDecode(npub)
        #expect(decodedPub == keypair.publicKeyHex)

        // nsec roundtrip
        let nsec = try NIP19.nsecEncode(privateKeyHex: keypair.privateKeyHex)
        let decodedSec = try NIP19.nsecDecode(nsec)
        #expect(decodedSec == keypair.privateKeyHex)
    }

    @Test func fakeRelayManagerPublishAndFetch() async throws {
        let keypair = try NostrKeypair.generate()
        let fake = FakeRelayManager()
        try await fake.connect(to: DefaultRelays.all)

        // Sign and publish
        let event = try await EventSigner.sign(
            kind: .rideOffer,
            content: "{}",
            tags: [["t", "rideshare"]],
            keypair: keypair
        )
        _ = try await fake.publish(event)

        // Verify it was recorded
        #expect(fake.publishedEvents.count == 1)
        #expect(fake.publishedEvents.first?.id == event.id)
    }
}

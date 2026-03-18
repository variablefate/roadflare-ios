import Foundation
import Testing
@testable import RidestrSDK

@Suite("NIP-44 Tests")
struct NIP44Tests {
    @Test func encryptDecryptRoundtrip() throws {
        let alice = try NostrKeypair.generate()
        let bob = try NostrKeypair.generate()
        let plaintext = "Hello, Bob!"

        let ciphertext = try NIP44.encrypt(
            plaintext: plaintext,
            senderPrivateKeyHex: alice.privateKeyHex,
            recipientPublicKeyHex: bob.publicKeyHex
        )
        #expect(ciphertext != plaintext)

        let decrypted = try NIP44.decrypt(
            ciphertext: ciphertext,
            receiverPrivateKeyHex: bob.privateKeyHex,
            senderPublicKeyHex: alice.publicKeyHex
        )
        #expect(decrypted == plaintext)
    }

    @Test func encryptToSelfRoundtrip() throws {
        let keypair = try NostrKeypair.generate()
        let plaintext = "{\"drivers\": []}"

        let ciphertext = try NIP44.encryptToSelf(
            plaintext: plaintext,
            privateKeyHex: keypair.privateKeyHex,
            publicKeyHex: keypair.publicKeyHex
        )
        let decrypted = try NIP44.decryptFromSelf(
            ciphertext: ciphertext,
            privateKeyHex: keypair.privateKeyHex,
            publicKeyHex: keypair.publicKeyHex
        )
        #expect(decrypted == plaintext)
    }

    @Test func keypairConvenienceEncrypt() throws {
        let alice = try NostrKeypair.generate()
        let bob = try NostrKeypair.generate()
        let plaintext = "Convenience method test"

        let ciphertext = try NIP44.encrypt(
            plaintext: plaintext,
            senderKeypair: alice,
            recipientPublicKeyHex: bob.publicKeyHex
        )
        let decrypted = try NIP44.decrypt(
            ciphertext: ciphertext,
            receiverKeypair: bob,
            senderPublicKeyHex: alice.publicKeyHex
        )
        #expect(decrypted == plaintext)
    }

    @Test func wrongKeyCannotDecrypt() throws {
        let alice = try NostrKeypair.generate()
        let bob = try NostrKeypair.generate()
        let carol = try NostrKeypair.generate()

        let ciphertext = try NIP44.encrypt(
            plaintext: "Secret for Bob",
            senderPrivateKeyHex: alice.privateKeyHex,
            recipientPublicKeyHex: bob.publicKeyHex
        )

        // Carol should not be able to decrypt
        #expect(throws: RidestrError.self) {
            try NIP44.decrypt(
                ciphertext: ciphertext,
                receiverPrivateKeyHex: carol.privateKeyHex,
                senderPublicKeyHex: alice.publicKeyHex
            )
        }
    }

    @Test func emptyStringThrowsError() throws {
        let alice = try NostrKeypair.generate()
        let bob = try NostrKeypair.generate()

        // NIP-44 does not allow empty messages
        #expect(throws: RidestrError.self) {
            try NIP44.encrypt(
                plaintext: "",
                senderPrivateKeyHex: alice.privateKeyHex,
                recipientPublicKeyHex: bob.publicKeyHex
            )
        }
    }

    @Test func unicodeContent() throws {
        let alice = try NostrKeypair.generate()
        let bob = try NostrKeypair.generate()
        let plaintext = "🚗 Ride to 東京タワー café"

        let ciphertext = try NIP44.encrypt(
            plaintext: plaintext,
            senderPrivateKeyHex: alice.privateKeyHex,
            recipientPublicKeyHex: bob.publicKeyHex
        )
        let decrypted = try NIP44.decrypt(
            ciphertext: ciphertext,
            receiverPrivateKeyHex: bob.privateKeyHex,
            senderPublicKeyHex: alice.publicKeyHex
        )
        #expect(decrypted == plaintext)
    }

    @Test func largeJsonPayload() throws {
        let alice = try NostrKeypair.generate()
        let bob = try NostrKeypair.generate()

        // Simulate a ride offer JSON
        let plaintext = """
        {"fare_estimate":12.50,"destination":{"lat":40.123,"lon":-74.456},\
        "approx_pickup":{"lat":40.124,"lon":-74.457},"pickup_route_km":0.5,\
        "ride_route_km":15.2,"payment_method":"zelle",\
        "fiat_payment_methods":["zelle","venmo","cash"]}
        """

        let ciphertext = try NIP44.encrypt(
            plaintext: plaintext,
            senderPrivateKeyHex: alice.privateKeyHex,
            recipientPublicKeyHex: bob.publicKeyHex
        )
        let decrypted = try NIP44.decrypt(
            ciphertext: ciphertext,
            receiverPrivateKeyHex: bob.privateKeyHex,
            senderPublicKeyHex: alice.publicKeyHex
        )
        #expect(decrypted == plaintext)
    }

    @Test func invalidCiphertextThrows() throws {
        let bob = try NostrKeypair.generate()
        let alice = try NostrKeypair.generate()

        #expect(throws: RidestrError.self) {
            try NIP44.decrypt(
                ciphertext: "not-valid-ciphertext",
                receiverPrivateKeyHex: bob.privateKeyHex,
                senderPublicKeyHex: alice.publicKeyHex
            )
        }
    }

    /// Tests the RoadFlare location encryption model:
    /// Driver encrypts with (driver_identity_priv, roadflare_pub).
    /// Follower decrypts with (roadflare_priv, driver_identity_pub).
    /// Works because ECDH(A_priv, B_pub) == ECDH(B_priv, A_pub).
    @Test func roadflareECDHEncryptionModel() throws {
        // Driver's identity keypair
        let driverIdentity = try NostrKeypair.generate()
        // RoadFlare keypair (shared private key with followers)
        let roadflareKey = try NostrKeypair.generate()

        let locationJSON = "{\"lat\":40.7128,\"lon\":-74.0060,\"status\":\"online\"}"

        // Driver encrypts: nip44Encrypt(content, roadflare_pubkey) using driver's identity privkey
        let ciphertext = try NIP44.encrypt(
            plaintext: locationJSON,
            senderPrivateKeyHex: driverIdentity.privateKeyHex,
            recipientPublicKeyHex: roadflareKey.publicKeyHex
        )

        // Follower decrypts: nip44Decrypt(ciphertext, driver_identity_pubkey) using roadflare privkey
        let decrypted = try NIP44.decrypt(
            ciphertext: ciphertext,
            receiverPrivateKeyHex: roadflareKey.privateKeyHex,
            senderPublicKeyHex: driverIdentity.publicKeyHex
        )
        #expect(decrypted == locationJSON)
    }

    /// Verify that someone WITHOUT the roadflare private key cannot decrypt location broadcasts.
    @Test func roadflareECDHUnauthorizedCannotDecrypt() throws {
        let driverIdentity = try NostrKeypair.generate()
        let roadflareKey = try NostrKeypair.generate()
        let unauthorizedRider = try NostrKeypair.generate()

        let ciphertext = try NIP44.encrypt(
            plaintext: "{\"lat\":40.7128}",
            senderPrivateKeyHex: driverIdentity.privateKeyHex,
            recipientPublicKeyHex: roadflareKey.publicKeyHex
        )

        // Unauthorized rider tries to decrypt with their own key — should fail
        #expect(throws: RidestrError.self) {
            try NIP44.decrypt(
                ciphertext: ciphertext,
                receiverPrivateKeyHex: unauthorizedRider.privateKeyHex,
                senderPublicKeyHex: driverIdentity.publicKeyHex
            )
        }
    }

    /// Simulate RoadFlare key rotation: old key can't decrypt new broadcasts.
    @Test func roadflareKeyRotationRevokesAccess() throws {
        let driverIdentity = try NostrKeypair.generate()
        let keyV1 = try NostrKeypair.generate()
        let keyV2 = try NostrKeypair.generate()

        // Broadcast encrypted with v2 key
        let ciphertext = try NIP44.encrypt(
            plaintext: "{\"lat\":40.0}",
            senderPrivateKeyHex: driverIdentity.privateKeyHex,
            recipientPublicKeyHex: keyV2.publicKeyHex
        )

        // Follower with v2 key CAN decrypt
        let decrypted = try NIP44.decrypt(
            ciphertext: ciphertext,
            receiverPrivateKeyHex: keyV2.privateKeyHex,
            senderPublicKeyHex: driverIdentity.publicKeyHex
        )
        #expect(decrypted.contains("40.0"))

        // Muted follower with old v1 key CANNOT decrypt v2 broadcasts
        #expect(throws: RidestrError.self) {
            try NIP44.decrypt(
                ciphertext: ciphertext,
                receiverPrivateKeyHex: keyV1.privateKeyHex,
                senderPublicKeyHex: driverIdentity.publicKeyHex
            )
        }
    }

    @Test func ciphertextIsDifferentEachTime() throws {
        let alice = try NostrKeypair.generate()
        let bob = try NostrKeypair.generate()
        let plaintext = "Same message"

        let ct1 = try NIP44.encrypt(
            plaintext: plaintext,
            senderPrivateKeyHex: alice.privateKeyHex,
            recipientPublicKeyHex: bob.publicKeyHex
        )
        let ct2 = try NIP44.encrypt(
            plaintext: plaintext,
            senderPrivateKeyHex: alice.privateKeyHex,
            recipientPublicKeyHex: bob.publicKeyHex
        )
        // NIP-44 uses random nonce, so same plaintext produces different ciphertext
        #expect(ct1 != ct2)

        // Both should decrypt to the same thing
        let d1 = try NIP44.decrypt(ciphertext: ct1, receiverPrivateKeyHex: bob.privateKeyHex, senderPublicKeyHex: alice.publicKeyHex)
        let d2 = try NIP44.decrypt(ciphertext: ct2, receiverPrivateKeyHex: bob.privateKeyHex, senderPublicKeyHex: alice.publicKeyHex)
        #expect(d1 == plaintext)
        #expect(d2 == plaintext)
    }
}

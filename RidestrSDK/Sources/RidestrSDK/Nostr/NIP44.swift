import Foundation
import NostrSDK

/// NIP-44: Encrypted payloads (version 2).
///
/// Provides ECDH + HKDF + ChaCha20-Poly1305 encryption for Nostr events.
/// Used for all encrypted event content in the Ridestr protocol.
public enum NIP44 {
    /// Encrypt plaintext for a recipient using NIP-44.
    ///
    /// - Parameters:
    ///   - plaintext: The content to encrypt.
    ///   - senderPrivateKeyHex: Sender's private key (hex).
    ///   - recipientPublicKeyHex: Recipient's public key (hex).
    /// - Returns: NIP-44 ciphertext string.
    public static func encrypt(
        plaintext: String,
        senderPrivateKeyHex: String,
        recipientPublicKeyHex: String
    ) throws -> String {
        do {
            let senderKey = try SecretKey.parse(secretKey: senderPrivateKeyHex)
            let recipientKey = try PublicKey.parse(publicKey: recipientPublicKeyHex)
            return try nip44Encrypt(secretKey: senderKey, publicKey: recipientKey, content: plaintext, version: .v2)
        } catch let error as RidestrError {
            throw error
        } catch {
            throw RidestrError.encryptionFailed(underlying: error)
        }
    }

    /// Decrypt NIP-44 ciphertext from a sender.
    ///
    /// - Parameters:
    ///   - ciphertext: The NIP-44 encrypted string.
    ///   - receiverPrivateKeyHex: Receiver's private key (hex).
    ///   - senderPublicKeyHex: Sender's public key (hex).
    /// - Returns: Decrypted plaintext string.
    public static func decrypt(
        ciphertext: String,
        receiverPrivateKeyHex: String,
        senderPublicKeyHex: String
    ) throws -> String {
        do {
            let receiverKey = try SecretKey.parse(secretKey: receiverPrivateKeyHex)
            let senderKey = try PublicKey.parse(publicKey: senderPublicKeyHex)
            return try nip44Decrypt(secretKey: receiverKey, publicKey: senderKey, payload: ciphertext)
        } catch let error as RidestrError {
            throw error
        } catch {
            throw RidestrError.decryptionFailed(underlying: error)
        }
    }

    /// Encrypt plaintext to self (for backup events like Kind 30011, 30174, 30177).
    ///
    /// Uses the same key as both sender and recipient via ECDH(priv, pub) where
    /// pub is derived from priv.
    public static func encryptToSelf(
        plaintext: String,
        privateKeyHex: String,
        publicKeyHex: String
    ) throws -> String {
        try encrypt(
            plaintext: plaintext,
            senderPrivateKeyHex: privateKeyHex,
            recipientPublicKeyHex: publicKeyHex
        )
    }

    /// Decrypt content encrypted to self.
    public static func decryptFromSelf(
        ciphertext: String,
        privateKeyHex: String,
        publicKeyHex: String
    ) throws -> String {
        try decrypt(
            ciphertext: ciphertext,
            receiverPrivateKeyHex: privateKeyHex,
            senderPublicKeyHex: publicKeyHex
        )
    }

    /// Encrypt using a NostrKeypair for convenience.
    public static func encrypt(
        plaintext: String,
        senderKeypair: NostrKeypair,
        recipientPublicKeyHex: String
    ) throws -> String {
        try encrypt(
            plaintext: plaintext,
            senderPrivateKeyHex: senderKeypair.privateKeyHex,
            recipientPublicKeyHex: recipientPublicKeyHex
        )
    }

    /// Decrypt using a NostrKeypair for convenience.
    public static func decrypt(
        ciphertext: String,
        receiverKeypair: NostrKeypair,
        senderPublicKeyHex: String
    ) throws -> String {
        try decrypt(
            ciphertext: ciphertext,
            receiverPrivateKeyHex: receiverKeypair.privateKeyHex,
            senderPublicKeyHex: senderPublicKeyHex
        )
    }
}

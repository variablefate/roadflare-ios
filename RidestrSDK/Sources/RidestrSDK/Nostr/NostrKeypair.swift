import Foundation
import NostrSDK

/// A Nostr identity keypair. Stores hex strings for Sendable compliance.
///
/// Use factory methods to create keypairs:
/// ```swift
/// let keypair = try NostrKeypair.generate()
/// let imported = try NostrKeypair.fromNsec("nsec1...")
/// ```
public struct NostrKeypair: Sendable, Equatable {
    /// Public key in hex format (64 characters).
    public let publicKeyHex: String

    /// Public key in NIP-19 bech32 format (npub1...).
    public let npub: String

    /// Private key in hex format. Internal to prevent accidental exposure.
    internal let privateKeyHex: String

    /// Private key in NIP-19 bech32 format. Internal to prevent accidental exposure.
    internal let nsec: String

    private init(privateKeyHex: String, publicKeyHex: String, nsec: String, npub: String) {
        self.privateKeyHex = privateKeyHex
        self.publicKeyHex = publicKeyHex
        self.nsec = nsec
        self.npub = npub
    }

    /// Generate a new random keypair.
    public static func generate() throws -> NostrKeypair {
        do {
            let keys = Keys.generate()
            return try from(keys: keys)
        } catch {
            throw RidestrError.invalidKey("Failed to generate keypair: \(error)")
        }
    }

    /// Import a keypair from an nsec bech32 string.
    public static func fromNsec(_ nsec: String) throws -> NostrKeypair {
        do {
            let secretKey = try SecretKey.parse(secretKey: nsec)
            let keys = Keys(secretKey: secretKey)
            return try from(keys: keys)
        } catch let error as RidestrError {
            throw error
        } catch {
            throw RidestrError.invalidKey("Invalid nsec: \(error)")
        }
    }

    /// Import a keypair from a hex private key (64 characters).
    public static func fromHex(_ hex: String) throws -> NostrKeypair {
        do {
            let secretKey = try SecretKey.parse(secretKey: hex)
            let keys = Keys(secretKey: secretKey)
            return try from(keys: keys)
        } catch let error as RidestrError {
            throw error
        } catch {
            throw RidestrError.invalidKey("Invalid hex key: \(error)")
        }
    }

    /// Export the private key as nsec bech32.
    public func exportNsec() -> String {
        nsec
    }

    /// Export the public key as npub bech32.
    public func exportNpub() -> String {
        npub
    }

    // MARK: - Internal

    /// Reconstruct rust-nostr Keys from stored hex. Used internally for signing/encryption.
    internal func toKeys() throws -> Keys {
        do {
            let secretKey = try SecretKey.parse(secretKey: privateKeyHex)
            return Keys(secretKey: secretKey)
        } catch {
            throw RidestrError.invalidKey("Failed to reconstruct keys: \(error)")
        }
    }

    private static func from(keys: Keys) throws -> NostrKeypair {
        let secretKey = keys.secretKey()
        let publicKey = keys.publicKey()
        return NostrKeypair(
            privateKeyHex: secretKey.toHex(),
            publicKeyHex: publicKey.toHex(),
            nsec: try secretKey.toBech32(),
            npub: try publicKey.toBech32()
        )
    }

    public static func == (lhs: NostrKeypair, rhs: NostrKeypair) -> Bool {
        lhs.publicKeyHex == rhs.publicKeyHex
    }
}

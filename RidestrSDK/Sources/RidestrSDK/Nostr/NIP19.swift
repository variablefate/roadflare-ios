import Foundation
import NostrSDK

/// NIP-19: bech32-encoded Nostr entities (npub, nsec).
public enum NIP19 {
    /// Encode a hex public key to npub bech32.
    public static func npubEncode(publicKeyHex: String) throws -> String {
        do {
            let pubkey = try PublicKey.parse(publicKey: publicKeyHex)
            return try pubkey.toBech32()
        } catch {
            throw RidestrError.crypto(.invalidKey("Failed to encode npub: \(error)"))
        }
    }

    /// Encode a hex private key to nsec bech32.
    public static func nsecEncode(privateKeyHex: String) throws -> String {
        do {
            let seckey = try SecretKey.parse(secretKey: privateKeyHex)
            return try seckey.toBech32()
        } catch {
            throw RidestrError.crypto(.invalidKey("Failed to encode nsec: \(error)"))
        }
    }

    /// Decode an npub bech32 string to hex public key.
    public static func npubDecode(_ npub: String) throws -> String {
        do {
            let pubkey = try PublicKey.parse(publicKey: npub)
            return pubkey.toHex()
        } catch {
            throw RidestrError.crypto(.invalidKey("Failed to decode npub: \(error)"))
        }
    }

    /// Decode an nsec bech32 string to hex private key.
    public static func nsecDecode(_ nsec: String) throws -> String {
        do {
            let seckey = try SecretKey.parse(secretKey: nsec)
            return seckey.toHex()
        } catch {
            throw RidestrError.crypto(.invalidKey("Failed to decode nsec: \(error)"))
        }
    }

    /// Check if a string is a valid npub.
    public static func isValidNpub(_ string: String) -> Bool {
        guard string.hasPrefix("npub1") else { return false }
        return (try? PublicKey.parse(publicKey: string)) != nil
    }

    /// Check if a string is a valid nsec.
    public static func isValidNsec(_ string: String) -> Bool {
        guard string.hasPrefix("nsec1") else { return false }
        return (try? SecretKey.parse(secretKey: string)) != nil
    }

    /// Check if a string is a valid hex public key (64 hex characters).
    public static func isValidHexPubkey(_ string: String) -> Bool {
        guard string.count == 64, string.allSatisfy(\.isHexDigit) else { return false }
        return (try? PublicKey.parse(publicKey: string)) != nil
    }
}

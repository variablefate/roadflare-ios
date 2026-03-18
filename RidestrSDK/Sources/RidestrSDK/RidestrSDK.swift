/// RidestrSDK — Nostr rideshare protocol for iOS
///
/// A Swift Package implementing the Ridestr/Nostr decentralized rideshare protocol.
/// Built on rust-nostr for relay management, event signing, and NIP-44 encryption.
///
/// Usage:
/// ```swift
/// import RidestrSDK
///
/// let keypair = try NostrKeypair.generate()
/// print(keypair.npub)
/// ```
public enum RidestrSDKVersion {
    public static let version = "0.1.0"
}

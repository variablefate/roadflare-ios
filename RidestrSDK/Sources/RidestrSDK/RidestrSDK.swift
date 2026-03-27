/// RidestrSDK — Nostr rideshare protocol for iOS
///
/// A Swift Package implementing the Ridestr/Nostr decentralized rideshare protocol.
/// Built on rust-nostr for relay management, event signing, and NIP-44 encryption.
///
/// ## Quick Start
///
/// ```swift
/// import RidestrSDK
///
/// // 1. Create or load identity
/// let keypair = try NostrKeypair.generate()
///
/// // 2. Connect to relays
/// let relay = RelayManager(keypair: keypair)
/// try await relay.connect(to: DefaultRelays.all)
///
/// // 3. Set up state machine
/// let stateMachine = RideStateMachine(riderPubkey: keypair.publicKeyHex)
///
/// // 4. Set up logging (optional)
/// RidestrLogger.handler = { level, message, _, _ in
///     print("[\(level.label)] \(message)")
/// }
///
/// // 5. Build and publish a ride offer
/// let content = RideOfferContent(
///     fareEstimate: 12.50,
///     destination: Location(latitude: 40.758, longitude: -73.985),
///     approxPickup: Location(latitude: 40.710, longitude: -74.010),
///     paymentMethod: "zelle",
///     fiatPaymentMethods: ["zelle", "venmo"]
/// )
/// let offer = try await RideshareEventBuilder.rideOffer(
///     driverPubkey: "64-char-hex-pubkey...",
///     driverAvailabilityEventId: nil,
///     content: content,
///     keypair: keypair
/// )
/// try await relay.publish(offer)
/// ```
///
/// ## Architecture
///
/// The SDK is organized into layers:
///
/// - **Nostr**: Relay management, event signing, NIP-44 encryption, event builders/parsers
/// - **Ride**: State machine, transitions, guards, typed events, immutable context
///   plus `RiderRideDomainService` for rider-session orchestration helpers
/// - **Location**: Geohash, fare calculation, routing/geocoding protocols
/// - **RoadFlare**: Followed drivers, key management, location broadcasts
/// - **Storage**: Keychain persistence
/// - **Models**: All Codable/Sendable data types
///
/// ## Key Concepts
///
/// - **AtoB Pattern**: The driver is the source of truth for ride state after confirmation.
///   Use `processEvent()` for rider-initiated actions and `receiveDriverStateEvent()` for
///   driver status updates from Kind 30180 events.
/// - **Protocol-based DI**: All I/O operations are behind protocols for testability.
///   The SDK provides mock implementations: `HaversineRoutingService`,
///   `StubGeocodingService`, `InMemoryFollowedDriversPersistence`.
/// - **Expiration**: All parsed events are checked for NIP-40 expiration before decryption.
/// - **Thread Safety**: `RelayManager` is an actor. `FollowedDriversRepository` uses NSLock.
///   `RideStateMachine` is `@Observable` for SwiftUI.
public enum RidestrSDKVersion {
    public static let version = "0.2.0"
}

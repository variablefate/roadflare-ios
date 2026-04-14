import Foundation

/// Canonical JSON fixtures representing exact Android event formats.
/// These are the single source of truth for cross-platform compatibility.
///
/// To add a new fixture:
/// 1. Capture the JSON from the Android app's log output
/// 2. Add it here as a static string
/// 3. Write a test in AndroidFixtureTests.swift that parses it
///
/// If Android changes its format, update these fixtures and fix any test failures.
enum AndroidFixtures {

    // MARK: - Kind 3174: Ride Acceptance (from Android driver)

    static let rideAcceptance = """
    {"status":"accepted","wallet_pubkey":"abc123def456","escrow_type":"cashu_nut14","mint_url":"https://mint.example.com","payment_method":"zelle"}
    """

    static let rideAcceptanceFiatOnly = """
    {"status":"accepted","wallet_pubkey":null,"mint_url":null,"payment_method":"venmo"}
    """

    // MARK: - Kind 3175: Ride Confirmation content (decrypted, from Android rider)

    static let rideConfirmationContent = """
    {"precise_pickup":{"lat":40.7128,"lon":-74.006},"payment_hash":"abc123hash","escrow_token":"cashu_token_blob"}
    """

    // MARK: - Kind 30180: Driver Ride State (from Android driver)

    static let driverStateEnRoute = """
    {"current_status":"en_route_pickup","history":[{"action":"status","status":"en_route_pickup","at":1700000000,"approx_location":{"lat":40.71,"lon":-74.01},"final_fare":null,"invoice":null,"pin_encrypted":null}]}
    """

    static let driverStateArrived = """
    {"current_status":"arrived","history":[{"action":"status","status":"en_route_pickup","at":1700000000,"approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":null},{"action":"status","status":"arrived","at":1700000100,"approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":null}]}
    """

    static let driverStateWithPinSubmit = """
    {"current_status":"arrived","history":[{"action":"status","status":"arrived","at":1700000100,"approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":null},{"action":"pin_submit","status":null,"at":1700000200,"approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":"nip44_encrypted_pin_data"}]}
    """

    static let driverStateCompleted = """
    {"current_status":"completed","history":[{"action":"status","status":"en_route_pickup","at":1700000000,"approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":null},{"action":"status","status":"arrived","at":1700000100,"approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":null},{"action":"status","status":"in_progress","at":1700000200,"approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":null},{"action":"status","status":"completed","at":1700000300,"approx_location":null,"final_fare":12.50,"invoice":null,"pin_encrypted":null}]}
    """

    static let driverStateWithSettlement = """
    {"current_status":"completed","history":[{"action":"status","status":"completed","at":1700000300,"approx_location":null,"final_fare":12.50,"invoice":null,"pin_encrypted":null},{"action":"settlement","status":null,"at":1700000301,"approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":null,"settlement_proof":"proof123","settled_amount":25000}]}
    """

    // MARK: - Kind 30181: Rider Ride State (from iOS rider, verified by Android)

    static let riderStateWithLocationRevealAndPinVerify = """
    {"current_phase":"verified","history":[{"action":"location_reveal","at":1700000000,"location_type":"pickup","location_encrypted":"nip44_encrypted_location","status":null,"attempt":null},{"action":"pin_verify","at":1700000100,"location_type":null,"location_encrypted":null,"status":"verified","attempt":1},{"action":"location_reveal","at":1700000200,"location_type":"destination","location_encrypted":"nip44_encrypted_destination","status":null,"attempt":null}]}
    """

    static let riderStateWithPreimageShare = """
    {"current_phase":"verified","history":[{"action":"pin_verify","at":1700000100,"location_type":null,"location_encrypted":null,"status":"verified","attempt":1},{"action":"preimage_share","at":1700000101,"location_type":null,"location_encrypted":null,"status":null,"attempt":null,"preimage_encrypted":"preimage_cipher","escrow_token_encrypted":"token_cipher"}]}
    """

    // MARK: - Kind 3178: Chat Message

    static let chatMessage = """
    {"message":"I'm at the corner by Starbucks"}
    """

    // MARK: - Kind 3179: Cancellation

    static let cancellation = """
    {"status":"cancelled","reason":"Driver took too long"}
    """

    static let cancellationNoReason = """
    {"status":"cancelled","reason":null}
    """

    // MARK: - Kind 3186: Key Share (from Android driver)

    static let keyShare = """
    {"roadflareKey":{"privateKey":"aabbccdd11223344aabbccdd11223344aabbccdd11223344aabbccdd11223344","publicKey":"eeff0011eeff0011eeff0011eeff0011eeff0011eeff0011eeff0011eeff0011","version":2,"keyUpdatedAt":1700000000},"keyUpdatedAt":1700000000,"driverPubKey":"driver_identity_pubkey_hex_64_chars_aabbccdd11223344aabbccdd11223344"}
    """

    static let keyShareWithoutKeyUpdatedAt = """
    {"roadflareKey":{"privateKey":"aabb","publicKey":"ccdd","version":1},"keyUpdatedAt":1700000000,"driverPubKey":"driver_pub"}
    """

    // MARK: - Kind 3188: Key Acknowledgement

    static let keyAck = """
    {"keyVersion":2,"keyUpdatedAt":1700000000,"status":"received","riderPubKey":"rider_pub_hex"}
    """

    static let keyAckStale = """
    {"keyVersion":1,"keyUpdatedAt":1699000000,"status":"stale","riderPubKey":"rider_pub_hex"}
    """

    // MARK: - Kind 30014: RoadFlare Location (decrypted content)

    static let roadflareLocation = """
    {"lat":36.1699,"lon":-115.1398,"timestamp":1700000000,"status":"online"}
    """

    static let roadflareLocationOnRide = """
    {"lat":36.17,"lon":-115.14,"timestamp":1700000100,"status":"on_ride","onRide":true}
    """

    // MARK: - Kind 30011: Followed Drivers List (decrypted content)

    static let followedDriversList = """
    {"drivers":[{"pubkey":"d1_hex_pubkey","addedAt":1700000000,"note":"Toyota Camry, airport runs","roadflareKey":{"privateKey":"priv1","publicKey":"pub1","version":2,"keyUpdatedAt":1700000000}},{"pubkey":"d2_hex_pubkey","addedAt":1700001000,"note":"","roadflareKey":null}],"updated_at":1700002000}
    """

    // MARK: - Kind 3173: Ride Offer (decrypted content, from iOS to Android)

    /// Legacy offer (no fiat fields). Represents an offer from an older iOS client that
    /// predates ADR-0008. `fiatFare` must decode to `nil` — backward compat proof.
    static let rideOffer = """
    {"fare_estimate":15.50,"destination":{"lat":40.758,"lon":-73.985},"approx_pickup":{"lat":40.71,"lon":-74.01},"pickup_route_km":null,"pickup_route_min":null,"ride_route_km":8.85,"ride_route_min":22.0,"destination_geohash":"dr5ru","payment_method":"zelle","fiat_payment_methods":["zelle","venmo","cash"]}
    """

    /// Modern offer (with fiat fields per ADR-0008). Represents an offer from an up-to-date
    /// iOS client. `fiatFare` must decode to a non-nil struct with the correct values.
    static let rideOfferWithFiatFare = """
    {"fare_estimate":15000.0,"fare_fiat_amount":"12.50","fare_fiat_currency":"USD","destination":{"lat":40.758,"lon":-73.985},"approx_pickup":{"lat":40.71,"lon":-74.01},"pickup_route_km":null,"pickup_route_min":null,"ride_route_km":8.85,"ride_route_min":22.0,"destination_geohash":"dr5ru","payment_method":"zelle","fiat_payment_methods":["zelle","venmo","cash"]}
    """

    // MARK: - Location object

    static let location = """
    {"lat":40.7128,"lon":-74.006}
    """

    static let locationWithAddress = """
    {"lat":40.7128,"lon":-74.006,"address":"Penn Station, New York"}
    """
}

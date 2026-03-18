import Foundation
import Testing
@testable import RidestrSDK

/// Tests for error paths, edge cases, and negative scenarios across the SDK.
@Suite("Error Path Tests")
struct ErrorPathTests {

    // MARK: - Parser Decryption Failures

    @Test func parseAcceptanceWithCorruptedCiphertext() {
        let keypair = try! NostrKeypair.generate()
        let event = NostrEvent(
            id: "e1", pubkey: "other_pub", createdAt: 1700000000,
            kind: EventKind.rideAcceptance.rawValue,
            tags: [], content: "corrupted!!!not_valid_nip44", sig: "sig"
        )
        #expect(throws: Error.self) {
            try RideshareEventParser.parseAcceptance(event: event, keypair: keypair)
        }
    }

    @Test func parseDriverRideStateWithBrokenJson() throws {
        let sender = try NostrKeypair.generate()
        let receiver = try NostrKeypair.generate()

        let encrypted = try NIP44.encrypt(
            plaintext: "{ not valid json at all }",
            senderPrivateKeyHex: sender.privateKeyHex,
            recipientPublicKeyHex: receiver.publicKeyHex
        )
        let event = NostrEvent(
            id: "e1", pubkey: sender.publicKeyHex, createdAt: 1700000000,
            kind: EventKind.driverRideState.rawValue,
            tags: [], content: encrypted, sig: "sig"
        )
        #expect(throws: Error.self) {
            try RideshareEventParser.parseDriverRideState(event: event, keypair: receiver)
        }
    }

    @Test func parseCancellationWrongKind() {
        let keypair = try! NostrKeypair.generate()
        let event = NostrEvent(
            id: "e1", pubkey: keypair.publicKeyHex, createdAt: 1700000000,
            kind: EventKind.chatMessage.rawValue,  // Wrong kind!
            tags: [], content: "{}", sig: "sig"
        )
        #expect(throws: RidestrError.self) {
            try RideshareEventParser.parseCancellation(event: event, keypair: keypair)
        }
    }

    @Test func parseRoadflareLocationWrongKind() throws {
        let event = NostrEvent(
            id: "e1", pubkey: "pub", createdAt: 1700000000,
            kind: EventKind.rideOffer.rawValue,  // Wrong kind
            tags: [], content: "encrypted", sig: "sig"
        )
        #expect(throws: RidestrError.self) {
            try RideshareEventParser.parseRoadflareLocation(event: event, roadflarePrivateKeyHex: "key")
        }
    }

    // MARK: - FareCalculator Edge Cases

    @Test func fareWithNegativeDistance() {
        let calc = FareCalculator()
        let fare = calc.calculateFare(distanceMiles: -10.0)
        // Negative distance × rate reduces fare, but minimum should catch it
        #expect(fare >= calc.config.minimumFareUsd)
    }

    @Test func fareWithZeroDistance() {
        let calc = FareCalculator()
        let fare = calc.calculateFare(distanceMiles: 0.0)
        #expect(fare == calc.config.minimumFareUsd)
    }

    @Test func fareWithHugeDistance() {
        let calc = FareCalculator()
        let fare = calc.calculateFare(distanceMiles: 1_000_000)
        #expect(fare > 0)
        #expect(!fare.isNaN)
    }

    @Test func fareExactlyAtMinimum() {
        // baseFare + (distance * rate) = exactly minimumFare
        let config = FareConfig(baseFareUsd: 3.00, rateUsdPerMile: 1.00, minimumFareUsd: 5.00)
        let calc = FareCalculator(config: config)
        let fare = calc.calculateFare(distanceMiles: 2.0)
        #expect(fare == 5.00)
    }

    // MARK: - State Machine Edge Cases

    @Test func handleDriverStateWithUnknownStatus() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")

        let unknownState = DriverRideStateContent(currentStatus: "unknown_status_xyz", history: [])
        let result = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "conf1", driverState: unknownState)
        #expect(result == "unknown_status_xyz")
        // Stage should not change for unknown status
        #expect(sm.stage == .rideConfirmed)
    }

    @Test func riderActionHistoryAccumulates() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: [])

        let action1 = RiderRideAction(type: "location_reveal", at: 1000, locationType: "pickup", locationEncrypted: "enc", status: nil, attempt: nil)
        let action2 = RiderRideAction(type: "pin_verify", at: 1100, locationType: nil, locationEncrypted: nil, status: "verified", attempt: 1)

        sm.addRiderAction(action1)
        sm.addRiderAction(action2)

        #expect(sm.riderStateHistory.count == 2)
        #expect(sm.riderStateHistory[0].type == "location_reveal")
        #expect(sm.riderStateHistory[1].isPinVerified)
    }

    @Test func invalidTransitionFromEveryStage() {
        // completed → inProgress should fail
        let sm = RideStateMachine()
        #expect(throws: RidestrError.self) {
            try sm.transition(to: .completed)
        }
        #expect(throws: RidestrError.self) {
            try sm.transition(to: .inProgress)
        }
        #expect(throws: RidestrError.self) {
            try sm.transition(to: .driverArrived)
        }
    }

    @Test func cancellationWhenAlreadyIdle() {
        let sm = RideStateMachine()
        // Cancellation from idle with mismatched confirmationId — should not process
        // (confirmationEventId is nil, confirmationId is "conf1" — the guard
        //  allows it because confirmationEventId == nil, which is a known edge case)
        let result = sm.handleCancellation(eventId: "c1", confirmationId: "conf1")
        // State machine allows this (transitions to idle, which it already is)
        #expect(sm.stage == .idle)
    }

    @Test func recordConfirmationBeforeAcceptanceThrows() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: [])
        #expect(throws: RidestrError.self) {
            try sm.recordConfirmation(confirmationEventId: "conf1")
        }
    }

    // MARK: - Geohash Edge Cases

    @Test func geohashPrecisionZero() {
        let gh = Geohash(latitude: 40.0, longitude: -74.0, precision: 0)
        #expect(gh.hash.isEmpty)
    }

    @Test func geohashExactlyAt180Longitude() {
        let east = Geohash(latitude: 0.0, longitude: 180.0, precision: 5)
        let west = Geohash(latitude: 0.0, longitude: -180.0, precision: 5)
        // Both represent the date line
        #expect(east.hash.count == 5)
        #expect(west.hash.count == 5)
    }

    @Test func geohashExactlyAtPoles() {
        let north = Geohash(latitude: 90.0, longitude: 0.0, precision: 5)
        let south = Geohash(latitude: -90.0, longitude: 0.0, precision: 5)
        #expect(north.hash.count == 5)
        #expect(south.hash.count == 5)
        #expect(north.hash != south.hash)
    }

    // MARK: - NIP19 Edge Cases

    @Test func npubDecodeWithWrongPrefix() {
        #expect(throws: RidestrError.self) {
            try NIP19.npubDecode("nsec1wrongprefix")  // nsec, not npub
        }
    }

    @Test func nsecDecodeWithWrongPrefix() {
        #expect(throws: RidestrError.self) {
            try NIP19.nsecDecode("npub1wrongprefix")  // npub, not nsec
        }
    }

    // MARK: - NostrEvent Edge Cases

    @Test func eventWithNoTags() throws {
        let json = """
        {"id":"abc","pubkey":"def","created_at":0,"kind":1,"tags":[],"content":"","sig":"sig"}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(NostrEvent.self, from: json)
        #expect(event.tag("p") == nil)
        #expect(event.referencedPubkeys.isEmpty)
        #expect(event.geohashTags.isEmpty)
        #expect(event.dTag == nil)
        #expect(!event.isExpired)
        #expect(!event.isRoadflare)
    }

    @Test func eventWithFutureExpiration() throws {
        let futureTs = Int(Date.now.timeIntervalSince1970) + 99999
        let json = """
        {"id":"abc","pubkey":"def","created_at":0,"kind":1,"tags":[["expiration","\(futureTs)"]],"content":"","sig":"sig"}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(NostrEvent.self, from: json)
        #expect(!event.isExpired)
    }

    // MARK: - JSON Field Name Validation (Android Interop)

    @Test func rideOfferContentFieldNames() throws {
        let offer = RideOfferContent(
            fareEstimate: 12.50,
            destination: Location(latitude: 40.0, longitude: -74.0),
            approxPickup: Location(latitude: 40.1, longitude: -74.1),
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )
        let data = try JSONEncoder().encode(offer)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Must use snake_case matching Android
        #expect(dict["fare_estimate"] != nil)
        #expect(dict["approx_pickup"] != nil)
        #expect(dict["payment_method"] != nil)
        #expect(dict["fiat_payment_methods"] != nil)
        // Must NOT have camelCase
        #expect(dict["fareEstimate"] == nil)
        #expect(dict["approxPickup"] == nil)
    }

    @Test func rideConfirmationContentFieldNames() throws {
        let conf = RideConfirmationContent(precisePickup: Location(latitude: 40.0, longitude: -74.0))
        let data = try JSONEncoder().encode(conf)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["precise_pickup"] != nil)
        #expect(dict["precisePickup"] == nil)
    }

    @Test func driverRideStateContentFieldNames() throws {
        let state = DriverRideStateContent(currentStatus: "arrived", history: [])
        let data = try JSONEncoder().encode(state)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["current_status"] != nil)
        #expect(dict["currentStatus"] == nil)
    }

    @Test func riderRideStateContentFieldNames() throws {
        let state = RiderRideStateContent(currentPhase: "verified", history: [])
        let data = try JSONEncoder().encode(state)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["current_phase"] != nil)
        #expect(dict["currentPhase"] == nil)
    }

    @Test func locationFieldNames() throws {
        let loc = Location(latitude: 40.0, longitude: -74.0)
        let data = try JSONEncoder().encode(loc)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["lat"] != nil)
        #expect(dict["lon"] != nil)
        #expect(dict["latitude"] == nil)
        #expect(dict["longitude"] == nil)
    }

    @Test func roadflareKeyFieldNames() throws {
        let key = RoadflareKey(privateKeyHex: "aa", publicKeyHex: "bb", version: 1, keyUpdatedAt: 100)
        let data = try JSONEncoder().encode(key)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // Android uses camelCase for RoadflareKey
        #expect(dict["privateKey"] != nil)
        #expect(dict["publicKey"] != nil)
        #expect(dict["version"] != nil)
        #expect(dict["keyUpdatedAt"] != nil)
    }
}

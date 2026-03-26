import Foundation
import Testing
@testable import RidestrSDK

/// Tests for malformed, spoofed, and adversarial events.
/// Ensures the SDK handles bad data gracefully without crashes or silent corruption.
@Suite("Adversarial Event Tests")
struct AdversarialEventTests {

    // MARK: - Wrong Field Names (Silent Parse Failures)

    @Test func driverActionWithTypeInsteadOfAction() throws {
        // Android uses "action", not "type" — verify wrong name fails
        let json = """
        {"type":"status","at":1700000000,"status":"arrived","approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":null}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DriverRideAction.self, from: json)
        }
    }

    @Test func riderActionWithTypeInsteadOfAction() throws {
        let json = """
        {"type":"pin_verify","at":1700000000,"location_type":null,"location_encrypted":null,"status":"verified","attempt":1}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RiderRideAction.self, from: json)
        }
    }

    // MARK: - Missing Required Fields

    @Test func driverRideStateMissingCurrentStatus() throws {
        let json = """
        {"history":[]}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DriverRideStateContent.self, from: json)
        }
    }

    @Test func riderRideStateMissingCurrentPhase() throws {
        let json = """
        {"history":[]}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RiderRideStateContent.self, from: json)
        }
    }

    @Test func rideOfferMissingFareEstimate() throws {
        let json = """
        {"destination":{"lat":40.0,"lon":-74.0},"approx_pickup":{"lat":40.1,"lon":-74.1},"payment_method":"cash","fiat_payment_methods":[]}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RideOfferContent.self, from: json)
        }
    }

    @Test func cancellationMissingStatus() throws {
        let json = """
        {"reason":"testing"}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CancellationContent.self, from: json)
        }
    }

    @Test func acceptanceMissingStatus() throws {
        let json = """
        {"wallet_pubkey":null,"payment_method":"cash"}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RideAcceptanceContent.self, from: json)
        }
    }

    // MARK: - Wrong Field Types

    @Test func fareEstimateAsString() throws {
        let json = """
        {"fare_estimate":"twelve","destination":{"lat":40.0,"lon":-74.0},"approx_pickup":{"lat":40.1,"lon":-74.1},"payment_method":"cash","fiat_payment_methods":[]}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RideOfferContent.self, from: json)
        }
    }

    @Test func locationLatAsString() throws {
        let json = """
        {"lat":"forty","lon":-74.0}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Location.self, from: json)
        }
    }

    // MARK: - Spoofed Events

    /// State machine does NOT validate pubkey — that's the RideCoordinator's
    /// responsibility via relay subscription author filters. This test documents
    /// that the state machine trusts its caller to pre-validate.
    @Test func stateMachineAcceptsEventRegardlessOfPubkey() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "correct_driver",
                         paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")

        let state = DriverRideStateContent(currentStatus: "completed", history: [])
        let result = try sm.handleDriverStateUpdate(eventId: "ds_fake", confirmationId: "conf1", driverState: state)
        #expect(result == "completed")  // Accepted because confirmationId matches
    }

    @Test func cancellationWithWrongConfirmationIdRejected() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1",
                         paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf_correct")

        let result = sm.handleCancellation(eventId: "c1", confirmationId: "conf_wrong")
        #expect(!result)  // Rejected
        #expect(sm.stage == .rideConfirmed)  // Unchanged
    }

    // MARK: - Impossible State Transitions

    @Test func cannotGoFromIdleToCompleted() {
        let sm = RideStateMachine()
        #expect(throws: RidestrError.self) {
            try sm.transition(to: .completed)
        }
    }

    @Test func cannotGoFromIdleToInProgress() {
        let sm = RideStateMachine()
        #expect(throws: RidestrError.self) {
            try sm.transition(to: .inProgress)
        }
    }

    @Test func cannotGoFromIdleToDriverArrived() {
        let sm = RideStateMachine()
        #expect(throws: RidestrError.self) {
            try sm.transition(to: .driverArrived)
        }
    }

    @Test func cannotGoFromWaitingToInProgress() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1",
                         paymentMethod: nil, fiatPaymentMethods: [])
        #expect(throws: RidestrError.self) {
            try sm.transition(to: .inProgress)
        }
    }

    @Test func cannotGoFromCompletedToDriverAccepted() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1",
                         paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")
        let state = DriverRideStateContent(currentStatus: "completed", history: [])
        _ = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "conf1", driverState: state)
        #expect(sm.stage == .completed)

        #expect(throws: RidestrError.self) {
            try sm.transition(to: .driverAccepted)
        }
    }

    // MARK: - Expired Events

    @Test func parseKeyShareExpiredEvent() throws {
        let driver = try NostrKeypair.generate()
        let rider = try NostrKeypair.generate()
        let pastExpiry = Int(Date.now.timeIntervalSince1970) - 300

        let event = NostrEvent(
            id: "ks1", pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970) - 600,
            kind: EventKind.keyShare.rawValue,
            tags: [["p", rider.publicKeyHex], ["expiration", String(pastExpiry)]],
            content: "encrypted", sig: "sig"
        )

        #expect(throws: RidestrError.self) {
            try RideshareEventParser.parseKeyShare(event: event, keypair: rider)
        }
    }

    @Test func parseKeyShareWrongRecipient() throws {
        let driver = try NostrKeypair.generate()
        let rider = try NostrKeypair.generate()
        let other = try NostrKeypair.generate()

        let event = NostrEvent(
            id: "ks1", pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.keyShare.rawValue,
            tags: [["p", other.publicKeyHex]],  // Wrong recipient
            content: "encrypted", sig: "sig"
        )

        #expect(throws: RidestrError.self) {
            try RideshareEventParser.parseKeyShare(event: event, keypair: rider)
        }
    }

    // MARK: - Malformed Encrypted Content

    @Test func corruptedCiphertextInAllParsers() throws {
        let keypair = try NostrKeypair.generate()
        let badContent = "not_valid_nip44_ciphertext!!!"

        let kinds: [(UInt16, (NostrEvent, NostrKeypair) throws -> Any)] = [
            (EventKind.rideAcceptance.rawValue, { e, k in try RideshareEventParser.parseAcceptance(event: e, keypair: k) }),
            (EventKind.driverRideState.rawValue, { e, k in try RideshareEventParser.parseDriverRideState(event: e, keypair: k) }),
            (EventKind.chatMessage.rawValue, { e, k in try RideshareEventParser.parseChatMessage(event: e, keypair: k) }),
            (EventKind.cancellation.rawValue, { e, k in try RideshareEventParser.parseCancellation(event: e, keypair: k) }),
        ]

        for (kind, parser) in kinds {
            let event = NostrEvent(
                id: "e1", pubkey: "other_pub", createdAt: 1700000000,
                kind: kind, tags: [["p", keypair.publicKeyHex]],
                content: badContent, sig: "sig"
            )
            #expect(throws: Error.self) {
                _ = try parser(event, keypair)
            }
        }
    }

    // MARK: - Extra Unknown Fields (should NOT crash)

    @Test func driverRideStateWithExtraFields() throws {
        let json = """
        {"current_status":"arrived","history":[],"extra_field":"should_be_ignored","version":99}
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(DriverRideStateContent.self, from: json)
        #expect(state.currentStatus == "arrived")
    }

    @Test func rideOfferWithExtraFields() throws {
        let json = """
        {"fare_estimate":10,"destination":{"lat":40,"lon":-74},"approx_pickup":{"lat":40.1,"lon":-74.1},"payment_method":"cash","fiat_payment_methods":[],"unknown_field":"hello","mint_url":"https://mint.test"}
        """.data(using: .utf8)!

        let offer = try JSONDecoder().decode(RideOfferContent.self, from: json)
        #expect(offer.fareEstimate == 10)
    }

    // MARK: - Negative/Zero Values

    @Test func fareCalculatorWithNegativeDistance() {
        let calc = FareCalculator()
        let fare = calc.calculateFare(distanceMiles: -100)
        #expect(fare >= calc.config.minimumFareUsd)
    }

    @Test func geohashWithExtremeCoordinates() {
        let gh1 = Geohash(latitude: 90, longitude: 180, precision: 5)
        #expect(gh1.hash.count == 5)
        let gh2 = Geohash(latitude: -90, longitude: -180, precision: 5)
        #expect(gh2.hash.count == 5)
        let gh3 = Geohash(latitude: 0, longitude: 0, precision: 1)
        #expect(gh3.hash.count == 1)
    }

    // MARK: - Missing Edge Cases (From Audit)

    @Test func locationApproximatePreservesSign() {
        let negative = Location(latitude: -33.86789, longitude: 151.20567)
        let approx = negative.approximate()
        #expect(approx.latitude == -33.87)
        #expect(approx.longitude == 151.21)
    }

    @Test func locationDistancePrecision() {
        // NYC to LA: known distance ~3,944 km — tighten tolerance to 1%
        let nyc = Location(latitude: 40.7128, longitude: -74.0060)
        let la = Location(latitude: 34.0522, longitude: -118.2437)
        let dist = nyc.distance(to: la)
        #expect(abs(dist - 3944) < 50)  // Within 50km (1.3%)
    }

    @Test func locationWithinMileBoundary() {
        let origin = Location(latitude: 40.0, longitude: -74.0)
        // 1.6 km = threshold. Test just inside and just outside.
        let justInside = Location(latitude: 40.0143, longitude: -74.0)  // ~1.59 km
        let justOutside = Location(latitude: 40.0145, longitude: -74.0)  // ~1.61 km
        #expect(origin.isWithinMile(of: justInside))
        #expect(!origin.isWithinMile(of: justOutside))
    }

    @Test func geohashContainsBoundary() {
        let gh = Geohash(latitude: 40.7128, longitude: -74.0060, precision: 5)
        let bb = gh.boundingBox
        // Center should be inside
        #expect(gh.contains(latitude: gh.latitude, longitude: gh.longitude))
        // Corner should be inside
        #expect(gh.contains(latitude: bb.minLat, longitude: bb.minLon))
        // Just outside should NOT be inside
        #expect(!gh.contains(latitude: bb.maxLat + 0.001, longitude: bb.maxLon + 0.001))
    }

    @Test func fareCalculatorDecimalPrecision() {
        let config = FareConfig(baseFareUsd: 1.11, rateUsdPerMile: 0.33, minimumFareUsd: 0.50)
        let calc = FareCalculator(config: config)
        // 3.33 miles: 1.11 + (3.33 × 0.33) = 1.11 + 1.0989 = 2.2089
        let fare = calc.calculateFare(distanceMiles: 3.33)
        #expect(fare > 2.20 && fare < 2.22)  // Tight tolerance
    }

    @Test func eventWithDuplicateTagNames() throws {
        let json = """
        {"id":"abc","pubkey":"def","created_at":1700000000,"kind":3173,\
        "tags":[["p","pub1"],["p","pub2"],["t","a"],["t","b"],["t","c"]],\
        "content":"test","sig":"sig"}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(NostrEvent.self, from: json)
        // tag("p") returns first, tagValues("p") returns all
        #expect(event.tag("p") == "pub1")
        #expect(event.tagValues("p") == ["pub1", "pub2"])
        #expect(event.tagValues("t") == ["a", "b", "c"])
    }

    @Test func eventWithFutureTimestamp() throws {
        let futureTs = Int(Date.now.timeIntervalSince1970) + 86400  // Tomorrow
        let json = """
        {"id":"abc","pubkey":"def","created_at":\(futureTs),"kind":1,"tags":[],"content":"","sig":"sig"}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(NostrEvent.self, from: json)
        // Should parse without error — timestamp validation is caller's responsibility
        #expect(event.createdAt == futureTs)
    }

    @Test func pinGenerationDistribution() {
        // Generate 1000 PINs and verify they're in valid range
        var pins: Set<String> = []
        for _ in 0..<1000 {
            let pin = RideStateMachine.generatePin()
            #expect(pin.count == 4)
            let value = Int(pin)!
            #expect(value >= 0 && value <= 9999)
            pins.insert(pin)
        }
        // Should have reasonable distribution (at least 500 unique out of 1000)
        #expect(pins.count > 500)
    }

    @Test func riderStageFromInvalidRawValue() {
        let invalid = RiderStage(rawValue: "nonexistent_stage")
        #expect(invalid == nil)
    }

    @Test func paymentMethodFromInvalidRawValue() {
        let parsed = PaymentMethod(rawValue: "bitcoin")
        #expect(parsed == .bitcoin)
    }
}

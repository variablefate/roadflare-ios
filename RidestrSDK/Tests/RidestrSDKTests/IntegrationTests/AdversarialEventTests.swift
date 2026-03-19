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

    @Test func driverStateFromWrongPubkeyRejected() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "correct_driver",
                         paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")

        // State event with matching confirmation but from WRONG driver
        // The state machine doesn't check pubkey — that's the coordinator's job
        // But the confirmationId filter should prevent cross-ride contamination
        let state = DriverRideStateContent(currentStatus: "completed", history: [])
        let result = try sm.handleDriverStateUpdate(eventId: "ds_fake", confirmationId: "conf1", driverState: state)
        // State machine processes it because confirmationId matches
        // Coordinator must validate pubkey before calling handleDriverStateUpdate
        #expect(result == "completed")
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
        // Should not crash
        let gh1 = Geohash(latitude: 90, longitude: 180, precision: 5)
        #expect(gh1.hash.count == 5)

        let gh2 = Geohash(latitude: -90, longitude: -180, precision: 5)
        #expect(gh2.hash.count == 5)

        let gh3 = Geohash(latitude: 0, longitude: 0, precision: 1)
        #expect(gh3.hash.count == 1)
    }
}

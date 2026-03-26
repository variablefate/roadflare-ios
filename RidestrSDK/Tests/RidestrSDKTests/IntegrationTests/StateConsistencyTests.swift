import Foundation
import Testing
@testable import RidestrSDK

/// Tests verifying state consistency across multiple components.
/// These catch bugs where individual components work but don't stay in sync.
@Suite("State Consistency Tests")
struct StateConsistencyTests {

    // MARK: - State Machine Restore + Event Processing

    @Test func restoredStateMachineProcessesDriverStateEvents() throws {
        let sm = RideStateMachine()
        sm.restore(
            stage: .rideConfirmed,
            offerEventId: "o1", acceptanceEventId: "a1",
            confirmationEventId: "conf1", driverPubkey: "d1",
            pin: "1234", pinVerified: false,
            paymentMethod: "zelle", fiatPaymentMethods: ["zelle"]
        )

        // Driver state event should be processable after restore
        let state = DriverRideStateContent(currentStatus: "arrived", history: [])
        let result = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "conf1", driverState: state)
        #expect(result == "arrived")
        #expect(sm.stage == .driverArrived)
    }

    @Test func restoredStateMachineRejectsWrongConfirmationId() throws {
        let sm = RideStateMachine()
        sm.restore(
            stage: .rideConfirmed,
            offerEventId: "o1", acceptanceEventId: "a1",
            confirmationEventId: "conf_correct", driverPubkey: "d1",
            pin: "1234", pinVerified: false,
            paymentMethod: nil, fiatPaymentMethods: []
        )

        let state = DriverRideStateContent(currentStatus: "arrived", history: [])
        let result = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "conf_wrong", driverState: state)
        #expect(result == nil)  // Rejected — wrong confirmation
        #expect(sm.stage == .rideConfirmed)  // Unchanged
    }

    @Test func pinSurvivesRestoreAndVerifiesCorrectly() throws {
        let sm = RideStateMachine()
        sm.restore(
            stage: .driverArrived,
            offerEventId: "o1", acceptanceEventId: "a1",
            confirmationEventId: "conf1", driverPubkey: "d1",
            pin: "5678", pinVerified: false,
            paymentMethod: nil, fiatPaymentMethods: []
        )

        // PIN should be available
        #expect(sm.pin == "5678")

        // Verification should work
        sm.recordPinVerification(verified: true)
        #expect(sm.pinVerified)
        #expect(sm.pinAttempts == 1)
    }

    @Test func pinSurvivesRestoreAndRejectsWrongPin() throws {
        let sm = RideStateMachine()
        sm.restore(
            stage: .driverArrived,
            offerEventId: "o1", acceptanceEventId: "a1",
            confirmationEventId: "conf1", driverPubkey: "d1",
            pin: "5678", pinVerified: false,
            paymentMethod: nil, fiatPaymentMethods: []
        )

        sm.recordPinVerification(verified: false)
        #expect(!sm.pinVerified)
        #expect(sm.pinAttempts == 1)
    }

    // MARK: - Rider Action History

    @Test func addRiderActionAccumulatesHistory() {
        let sm = RideStateMachine()
        #expect(sm.riderStateHistory.isEmpty)

        let action1 = RiderRideAction(type: "location_reveal", at: 1000,
            locationType: "pickup", locationEncrypted: "enc1", status: nil, attempt: nil)
        let action2 = RiderRideAction(type: "pin_verify", at: 1100,
            locationType: nil, locationEncrypted: nil, status: "verified", attempt: 1)

        sm.addRiderAction(action1)
        sm.addRiderAction(action2)

        #expect(sm.riderStateHistory.count == 2)
        #expect(sm.riderStateHistory[0].isLocationReveal)
        #expect(sm.riderStateHistory[0].locationType == "pickup")
        #expect(sm.riderStateHistory[1].isPinVerified)
        #expect(sm.riderStateHistory[1].attempt == 1)
    }

    @Test func resetClearsRiderActionHistory() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: [])
        sm.addRiderAction(RiderRideAction(type: "test", at: 100,
            locationType: nil, locationEncrypted: nil, status: nil, attempt: nil))
        #expect(!sm.riderStateHistory.isEmpty)

        sm.reset()
        #expect(sm.riderStateHistory.isEmpty)
    }

    // MARK: - Filter + Subscription Consistency

    @Test func driverStateFilterUsesConfirmationIdAsDTag() {
        let filter = NostrFilter.driverRideState(driverPubkey: "driver_pub", confirmationEventId: "conf_abc")
        #expect(filter.tagFilters["d"] == ["conf_abc"])
        #expect(filter.authors == ["driver_pub"])
        #expect(filter.kinds == [EventKind.driverRideState.rawValue])
    }

    @Test func cancellationFilterUsesRiderPubkeyAndConfirmationId() {
        let filter = NostrFilter.cancellations(counterpartyPubkey: "rider_pub", confirmationEventId: "conf_abc")
        #expect(filter.tagFilters["p"] == ["rider_pub"])
        #expect(filter.tagFilters["e"] == ["conf_abc"])
    }

    // MARK: - Builder + Parser Roundtrip for All Event Types

    @Test func acceptanceRoundtrip() async throws {
        let driver = try NostrKeypair.generate()
        let rider = try NostrKeypair.generate()

        // Simulate Android driver creating acceptance JSON
        let acceptanceJSON = """
        {"status":"accepted","wallet_pubkey":null,"payment_method":"zelle","mint_url":null}
        """
        let event = NostrEvent(
            id: "acc1", pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.rideAcceptance.rawValue,
            tags: [["e", "offer1"], ["p", rider.publicKeyHex]],
            content: acceptanceJSON, sig: "sig"
        )

        let parsed = try RideshareEventParser.parseAcceptance(event: event, keypair: rider)
        #expect(parsed.status == "accepted")
        #expect(parsed.paymentMethod == "zelle")
    }

    @Test func driverRideStateRoundtrip() async throws {
        let driver = try NostrKeypair.generate()
        let rider = try NostrKeypair.generate()

        // Android format: uses "action" not "type"
        let stateJSON = """
        {"current_status":"arrived","history":[{"action":"status","at":1700000000,"status":"arrived","approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":null}]}
        """
        let event = NostrEvent(
            id: "ds1", pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.driverRideState.rawValue,
            tags: [["d", "conf1"], ["e", "conf1"], ["p", rider.publicKeyHex]],
            content: stateJSON, sig: "sig"
        )

        let parsed = try RideshareEventParser.parseDriverRideState(event: event, keypair: rider)
        #expect(parsed.currentStatus == "arrived")
        #expect(parsed.history.count == 1)
        #expect(parsed.history[0].isStatusAction)
    }

    // MARK: - Android Fixture Parsing

    @Test func parseAndroidDriverRideStateWithPinSubmit() throws {
        // Exact JSON format from Android DriverRideStateEvent
        let json = """
        {"current_status":"arrived","history":[{"action":"status","at":1700000000,"status":"en_route_pickup","approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":null},{"action":"status","at":1700000100,"status":"arrived","approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":null},{"action":"pin_submit","at":1700000200,"status":null,"approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":"encrypted_pin_data"}]}
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(DriverRideStateContent.self, from: json)
        #expect(state.currentStatus == "arrived")
        #expect(state.history.count == 3)
        #expect(state.history[0].isStatusAction)
        #expect(state.history[0].type == "status")
        #expect(state.history[2].isPinSubmitAction)
        #expect(state.history[2].pinEncrypted == "encrypted_pin_data")
    }

    @Test func parseAndroidRiderRideStateWithLocationReveal() throws {
        let json = """
        {"current_phase":"verified","history":[{"action":"location_reveal","at":1700000000,"location_type":"pickup","location_encrypted":"enc_pickup","status":null,"attempt":null},{"action":"pin_verify","at":1700000100,"location_type":null,"location_encrypted":null,"status":"verified","attempt":1},{"action":"location_reveal","at":1700000200,"location_type":"destination","location_encrypted":"enc_dest","status":null,"attempt":null}]}
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(RiderRideStateContent.self, from: json)
        #expect(state.currentPhase == "verified")
        #expect(state.history.count == 3)
        #expect(state.history[0].isLocationReveal)
        #expect(state.history[0].locationType == "pickup")
        #expect(state.history[1].isPinVerified)
        #expect(state.history[2].locationType == "destination")
    }

    @Test func parseAndroidCancellationWithStatusField() throws {
        let json = """
        {"status":"cancelled","reason":"Driver cancelled"}
        """.data(using: .utf8)!

        let cancel = try JSONDecoder().decode(CancellationContent.self, from: json)
        #expect(cancel.status == "cancelled")
        #expect(cancel.reason == "Driver cancelled")
    }

    @Test func parseAndroidRoadflareKeyWithOptionalKeyUpdatedAt() throws {
        // Android may omit keyUpdatedAt when <= 0
        let jsonWithout = """
        {"privateKey":"aabb","publicKey":"ccdd","version":1}
        """.data(using: .utf8)!

        let key = try JSONDecoder().decode(RoadflareKey.self, from: jsonWithout)
        #expect(key.version == 1)
        #expect(key.keyUpdatedAt == nil)

        // With keyUpdatedAt
        let jsonWith = """
        {"privateKey":"aabb","publicKey":"ccdd","version":2,"keyUpdatedAt":1700000000}
        """.data(using: .utf8)!

        let key2 = try JSONDecoder().decode(RoadflareKey.self, from: jsonWith)
        #expect(key2.keyUpdatedAt == 1700000000)
    }
}

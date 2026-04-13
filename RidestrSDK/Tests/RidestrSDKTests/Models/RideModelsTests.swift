import Foundation
import Testing
@testable import RidestrSDK

@Suite("RideModels Tests")
struct RideModelsTests {
    // MARK: - RideOfferContent

    @Test func rideOfferContentCodable() throws {
        let offer = RideOfferContent(
            fareEstimate: 15.50,
            destination: Location(latitude: 40.758, longitude: -73.985),
            approxPickup: Location(latitude: 40.71, longitude: -74.01),
            pickupRouteKm: 2.5,
            pickupRouteMin: 5.0,
            rideRouteKm: 8.3,
            rideRouteMin: 18.0,
            destinationGeohash: "dr5ru",
            mintUrl: "https://mint.example.com",
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle", "venmo", "cash"]
        )
        let data = try JSONEncoder().encode(offer)
        let decoded = try JSONDecoder().decode(RideOfferContent.self, from: data)
        #expect(decoded.fareEstimate == 15.50)
        #expect(decoded.approxPickup.latitude == 40.71)
        #expect(decoded.destination.longitude == -73.985)
        #expect(decoded.pickupRouteKm == 2.5)
        #expect(decoded.rideRouteKm == 8.3)
        #expect(decoded.mintUrl == "https://mint.example.com")
        #expect(decoded.paymentMethod == "zelle")
        #expect(decoded.fiatPaymentMethods == ["zelle", "venmo", "cash"])
    }

    @Test func rideOfferContentCodingKeys() throws {
        let json = """
        {"fare_estimate":10,"destination":{"lat":40.0,"lon":-74.0},"approx_pickup":{"lat":40.1,"lon":-74.1},\
        "pickup_route_km":1.0,"ride_route_km":5.0,"payment_method":"cash","fiat_payment_methods":["cash"]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RideOfferContent.self, from: json)
        #expect(decoded.fareEstimate == 10)
        #expect(decoded.paymentMethod == "cash")
    }

    // MARK: - RideAcceptanceContent

    @Test func rideAcceptanceCodable() throws {
        let json = """
        {"status":"accepted","wallet_pubkey":"abc123","escrow_type":"cashu_nut14","escrow_invoice":"inv123","escrow_expiry":1700000300,"payment_method":"venmo","mint_url":null}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RideAcceptanceContent.self, from: json)
        #expect(decoded.status == "accepted")
        #expect(decoded.walletPubkey == "abc123")
        #expect(decoded.escrowType == "cashu_nut14")
        #expect(decoded.escrowInvoice == "inv123")
        #expect(decoded.escrowExpiry == 1700000300)
        #expect(decoded.paymentMethod == "venmo")
        #expect(decoded.mintUrl == nil)
    }

    // MARK: - RideConfirmationContent

    @Test func rideConfirmationCodable() throws {
        let content = RideConfirmationContent(
            precisePickup: Location(latitude: 40.71234, longitude: -74.00567),
            paymentHash: "hash123",
            escrowToken: "token123"
        )
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(RideConfirmationContent.self, from: data)
        #expect(decoded.precisePickup.latitude == 40.71234)
        #expect(decoded.paymentHash == "hash123")
        #expect(decoded.escrowToken == "token123")
    }

    // MARK: - DriverRideStateContent

    @Test func driverRideStateCodable() throws {
        let json = """
        {"current_status":"arrived","history":[{"action":"status","at":1700000000,"status":"en_route_pickup",\
        "approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":null},\
        {"action":"status","at":1700000100,"status":"arrived","approx_location":null,\
        "final_fare":null,"invoice":null,"pin_encrypted":null}]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DriverRideStateContent.self, from: json)
        #expect(decoded.currentStatus == "arrived")
        #expect(decoded.history.count == 2)
        #expect(decoded.history[0].isStatusAction)
        #expect(decoded.history[0].status == "en_route_pickup")
    }

    @Test func driverRideActionPinSubmit() throws {
        let json = """
        {"action":"pin_submit","at":1700000000,"status":null,"approx_location":null,\
        "final_fare":null,"invoice":null,"pin_encrypted":"encrypted_pin_data"}
        """.data(using: .utf8)!
        let action = try JSONDecoder().decode(DriverRideAction.self, from: json)
        #expect(action.isPinSubmitAction)
        #expect(!action.isStatusAction)
        #expect(action.pinEncrypted == "encrypted_pin_data")
    }

    @Test func driverRideActionSettlement() throws {
        let json = """
        {"action":"settlement","at":1700000001,"status":null,"approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":null,"settlement_proof":"proof123","settled_amount":25000}
        """.data(using: .utf8)!
        let action = try JSONDecoder().decode(DriverRideAction.self, from: json)
        #expect(action.isSettlementAction)
        #expect(action.settlementProof == "proof123")
        #expect(action.settledAmount == 25000)
    }

    // MARK: - RiderRideStateContent

    @Test func riderRideStateCodable() throws {
        let json = """
        {"current_phase":"verified","history":[\
        {"action":"location_reveal","at":1700000000,"location_type":"pickup","location_encrypted":"enc_loc","status":null,"attempt":null},\
        {"action":"pin_verify","at":1700000100,"location_type":null,"location_encrypted":null,"status":"verified","attempt":1}]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RiderRideStateContent.self, from: json)
        #expect(decoded.currentPhase == "verified")
        #expect(decoded.history.count == 2)
        #expect(decoded.history[0].isLocationReveal)
        #expect(decoded.history[0].locationType == "pickup")
        #expect(decoded.history[1].isPinVerify)
        #expect(decoded.history[1].isPinVerified)
        #expect(decoded.history[1].attempt == 1)
    }

    @Test func riderRideActionPinRejected() throws {
        let json = """
        {"action":"pin_verify","at":1700000000,"location_type":null,"location_encrypted":null,"status":"rejected","attempt":2}
        """.data(using: .utf8)!
        let action = try JSONDecoder().decode(RiderRideAction.self, from: json)
        #expect(action.isPinVerify)
        #expect(!action.isPinVerified)
        #expect(action.attempt == 2)
    }

    @Test func riderRideActionPreimageShare() throws {
        let json = """
        {"action":"preimage_share","at":1700000002,"location_type":null,"location_encrypted":null,"status":null,"attempt":null,"preimage_encrypted":"pre123","escrow_token_encrypted":"token456"}
        """.data(using: .utf8)!
        let action = try JSONDecoder().decode(RiderRideAction.self, from: json)
        #expect(action.isPreimageShare)
        #expect(action.preimageEncrypted == "pre123")
        #expect(action.escrowTokenEncrypted == "token456")
    }

    // MARK: - ChatMessageContent

    @Test func chatMessageCodable() throws {
        let msg = ChatMessageContent(message: "On my way!")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ChatMessageContent.self, from: data)
        #expect(decoded.message == "On my way!")
    }

    // MARK: - CancellationContent

    @Test func cancellationCodable() throws {
        let cancel = CancellationContent(reason: "Changed plans")
        let data = try JSONEncoder().encode(cancel)
        let decoded = try JSONDecoder().decode(CancellationContent.self, from: data)
        #expect(decoded.reason == "Changed plans")
    }

    @Test func cancellationNullReason() throws {
        let cancel = CancellationContent(reason: nil)
        let data = try JSONEncoder().encode(cancel)
        let decoded = try JSONDecoder().decode(CancellationContent.self, from: data)
        #expect(decoded.reason == nil)
    }

    // MARK: - UserProfile

    @Test func userProfileCodable() throws {
        let profile = UserProfile(name: "Alice", about: "Rider", picture: "https://example.com/pic.jpg")
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(UserProfile.self, from: data)
        #expect(decoded.name == "Alice")
        #expect(decoded.picture == "https://example.com/pic.jpg")
    }

    // MARK: - Vehicle

    @Test func vehicleDisplayName() {
        let v = Vehicle(make: "Toyota", model: "Camry", year: 2022, color: "Silver")
        #expect(v.displayName == "Toyota Camry 2022")
    }

    @Test func vehicleDisplayNameNoYear() {
        let v = Vehicle(make: "Honda", model: "Civic")
        #expect(v.displayName == "Honda Civic")
    }

    @Test func vehicleCodable() throws {
        let v = Vehicle(make: "Tesla", model: "Model 3", year: 2024, color: "White", licensePlate: "ABC123")
        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(Vehicle.self, from: data)
        #expect(decoded.make == "Tesla")
        #expect(decoded.licensePlate == "ABC123")
    }

    // MARK: - FiatFare and RideOfferContent fiat fields

    @Test func fiatFareEncodesFlat() throws {
        // FiatFare serializes as top-level JSON keys, not nested object
        let offer = RideOfferContent(
            fareEstimate: 50_000,
            fiatFare: FiatFare(amount: "12.50", currency: "USD"),
            destination: Location(latitude: 40.758, longitude: -73.985),
            approxPickup: Location(latitude: 40.71, longitude: -74.01),
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )
        let data = try JSONEncoder().encode(offer)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["fare_fiat_amount"] as? String == "12.50")
        #expect(json["fare_fiat_currency"] as? String == "USD")
        // Confirm no nested key
        #expect(json["fiatFare"] == nil)
        #expect(json["fiat_fare"] == nil)
    }

    @Test func fiatFareDecodesFlat() throws {
        // Flat JSON keys decode into a FiatFare struct
        let json = """
        {"fare_estimate":50000,"fare_fiat_amount":"12.50","fare_fiat_currency":"USD",\
        "destination":{"lat":40.758,"lon":-73.985},"approx_pickup":{"lat":40.71,"lon":-74.01},\
        "payment_method":"zelle","fiat_payment_methods":["zelle"]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RideOfferContent.self, from: json)
        #expect(decoded.fiatFare?.amount == "12.50")
        #expect(decoded.fiatFare?.currency == "USD")
        #expect(decoded.fareEstimate == 50_000)
    }

    @Test func fiatFareNilWhenAbsent() throws {
        // Offers without fiat fields decode to fiatFare == nil (backward compat)
        let json = """
        {"fare_estimate":50000,"destination":{"lat":40.758,"lon":-73.985},\
        "approx_pickup":{"lat":40.71,"lon":-74.01},"payment_method":"zelle",\
        "fiat_payment_methods":[]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RideOfferContent.self, from: json)
        #expect(decoded.fiatFare == nil)
    }

    @Test func fiatFareNilWhenPartialPair() throws {
        // Only one of the two fields present → nil (mandatory pair rule)
        let json = """
        {"fare_estimate":50000,"fare_fiat_amount":"12.50",\
        "destination":{"lat":40.758,"lon":-73.985},\
        "approx_pickup":{"lat":40.71,"lon":-74.01},\
        "payment_method":"zelle","fiat_payment_methods":[]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RideOfferContent.self, from: json)
        #expect(decoded.fiatFare == nil)
    }

    @Test func fiatFareAbsentFromJsonWhenNil() throws {
        // fiatFare == nil → fare_fiat_amount and fare_fiat_currency absent from JSON
        let offer = RideOfferContent(
            fareEstimate: 30_000,
            fiatFare: nil,
            destination: Location(latitude: 40.758, longitude: -73.985),
            approxPickup: Location(latitude: 40.71, longitude: -74.01),
            paymentMethod: "cash",
            fiatPaymentMethods: []
        )
        let data = try JSONEncoder().encode(offer)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["fare_fiat_amount"] == nil)
        #expect(json["fare_fiat_currency"] == nil)
    }
}

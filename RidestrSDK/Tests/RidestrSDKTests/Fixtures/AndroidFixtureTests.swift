import Foundation
import Testing
@testable import RidestrSDK

/// Tests that verify iOS can parse every Android JSON format exactly.
/// These are contract tests — if Android changes its format, update AndroidFixtures.swift
/// and fix any failures here.
@Suite("Android Fixture Contract Tests")
struct AndroidFixtureTests {

    // MARK: - Kind 3174: Ride Acceptance

    @Test func parseAndroidAcceptance() throws {
        let data = AndroidFixtures.rideAcceptance.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(RideAcceptanceContent.self, from: data)
        #expect(parsed.status == "accepted")
        #expect(parsed.walletPubkey == "abc123def456")
        #expect(parsed.escrowType == "cashu_nut14")
        #expect(parsed.paymentMethod == "zelle")
        #expect(parsed.mintUrl == "https://mint.example.com")
    }

    @Test func parseAndroidAcceptanceFiatOnly() throws {
        let data = AndroidFixtures.rideAcceptanceFiatOnly.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(RideAcceptanceContent.self, from: data)
        #expect(parsed.status == "accepted")
        #expect(parsed.walletPubkey == nil)
        #expect(parsed.escrowType == nil)
        #expect(parsed.paymentMethod == "venmo")
        #expect(parsed.mintUrl == nil)
    }

    @Test func parseAndroidConfirmationContent() throws {
        let data = AndroidFixtures.rideConfirmationContent.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(RideConfirmationContent.self, from: data)
        #expect(parsed.precisePickup.latitude == 40.7128)
        #expect(parsed.paymentHash == "abc123hash")
        #expect(parsed.escrowToken == "cashu_token_blob")
    }

    // MARK: - Kind 30180: Driver Ride State

    @Test func parseAndroidDriverStateEnRoute() throws {
        let data = AndroidFixtures.driverStateEnRoute.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(DriverRideStateContent.self, from: data)
        #expect(parsed.currentStatus == "en_route_pickup")
        #expect(parsed.history.count == 1)
        #expect(parsed.history[0].isStatusAction)
        #expect(parsed.history[0].status == "en_route_pickup")
    }

    @Test func parseAndroidDriverStateArrived() throws {
        let data = AndroidFixtures.driverStateArrived.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(DriverRideStateContent.self, from: data)
        #expect(parsed.currentStatus == "arrived")
        #expect(parsed.history.count == 2)
    }

    @Test func parseAndroidDriverStateWithPinSubmit() throws {
        let data = AndroidFixtures.driverStateWithPinSubmit.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(DriverRideStateContent.self, from: data)
        #expect(parsed.currentStatus == "arrived")
        #expect(parsed.history.count == 2)
        #expect(parsed.history[1].isPinSubmitAction)
        #expect(parsed.history[1].pinEncrypted == "nip44_encrypted_pin_data")
    }

    @Test func parseAndroidDriverStateWithSettlement() throws {
        let data = AndroidFixtures.driverStateWithSettlement.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(DriverRideStateContent.self, from: data)
        #expect(parsed.currentStatus == "completed")
        #expect(parsed.history.count == 2)
        #expect(parsed.history[1].isSettlementAction)
        #expect(parsed.history[1].settlementProof == "proof123")
        #expect(parsed.history[1].settledAmount == 25000)
    }

    @Test func parseAndroidDriverStateCompleted() throws {
        let data = AndroidFixtures.driverStateCompleted.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(DriverRideStateContent.self, from: data)
        #expect(parsed.currentStatus == "completed")
        #expect(parsed.history.count == 4)
        // Final status should have fare
        let completedAction = parsed.history.last!
        #expect(completedAction.finalFare == 12.50)
    }

    // MARK: - Kind 30181: Rider Ride State

    @Test func parseAndroidRiderState() throws {
        let data = AndroidFixtures.riderStateWithLocationRevealAndPinVerify.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(RiderRideStateContent.self, from: data)
        #expect(parsed.currentPhase == "verified")
        #expect(parsed.history.count == 3)
        #expect(parsed.history[0].isLocationReveal)
        #expect(parsed.history[0].locationType == "pickup")
        #expect(parsed.history[1].isPinVerified)
        #expect(parsed.history[1].attempt == 1)
        #expect(parsed.history[2].locationType == "destination")
    }

    @Test func parseAndroidRiderStateWithPreimageShare() throws {
        let data = AndroidFixtures.riderStateWithPreimageShare.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(RiderRideStateContent.self, from: data)
        #expect(parsed.currentPhase == "verified")
        #expect(parsed.history.count == 2)
        #expect(parsed.history[1].isPreimageShare)
        #expect(parsed.history[1].preimageEncrypted == "preimage_cipher")
        #expect(parsed.history[1].escrowTokenEncrypted == "token_cipher")
    }

    // MARK: - Kind 3178: Chat

    @Test func parseAndroidChatMessage() throws {
        let data = AndroidFixtures.chatMessage.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(ChatMessageContent.self, from: data)
        #expect(parsed.message == "I'm at the corner by Starbucks")
    }

    // MARK: - Kind 3179: Cancellation

    @Test func parseAndroidCancellation() throws {
        let data = AndroidFixtures.cancellation.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(CancellationContent.self, from: data)
        #expect(parsed.status == "cancelled")
        #expect(parsed.reason == "Driver took too long")
    }

    @Test func parseAndroidCancellationNoReason() throws {
        let data = AndroidFixtures.cancellationNoReason.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(CancellationContent.self, from: data)
        #expect(parsed.status == "cancelled")
        #expect(parsed.reason == nil)
    }

    // MARK: - Kind 3186: Key Share

    @Test func parseAndroidKeyShare() throws {
        let data = AndroidFixtures.keyShare.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(KeyShareContent.self, from: data)
        #expect(parsed.roadflareKey.version == 2)
        #expect(parsed.roadflareKey.keyUpdatedAt == 1700000000)
        #expect(parsed.keyUpdatedAt == 1700000000)
        #expect(parsed.driverPubKey.count > 0)
    }

    @Test func parseAndroidKeyShareWithoutKeyUpdatedAt() throws {
        let data = AndroidFixtures.keyShareWithoutKeyUpdatedAt.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(KeyShareContent.self, from: data)
        #expect(parsed.roadflareKey.version == 1)
        #expect(parsed.roadflareKey.keyUpdatedAt == nil)  // Optional, omitted by Android
    }

    // MARK: - Kind 3188: Key Ack

    @Test func parseAndroidKeyAck() throws {
        let data = AndroidFixtures.keyAck.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(KeyAckContent.self, from: data)
        #expect(parsed.keyVersion == 2)
        #expect(parsed.status == "received")
    }

    @Test func parseAndroidKeyAckStale() throws {
        let data = AndroidFixtures.keyAckStale.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(KeyAckContent.self, from: data)
        #expect(parsed.status == "stale")
    }

    // MARK: - Kind 30014: RoadFlare Location

    @Test func parseAndroidRoadflareLocation() throws {
        let data = AndroidFixtures.roadflareLocation.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(RoadflareLocation.self, from: data)
        #expect(parsed.latitude == 36.1699)
        #expect(parsed.longitude == -115.1398)
        #expect(parsed.status == .online)
    }

    @Test func parseAndroidRoadflareLocationOnRide() throws {
        let data = AndroidFixtures.roadflareLocationOnRide.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(RoadflareLocation.self, from: data)
        #expect(parsed.status == .onRide)
        #expect(parsed.onRide == true)
    }

    // MARK: - Kind 30011: Followed Drivers List

    @Test func parseAndroidFollowedDriversList() throws {
        let data = AndroidFixtures.followedDriversList.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(FollowedDriversContent.self, from: data)
        #expect(parsed.drivers.count == 2)
        #expect(parsed.drivers[0].pubkey == "d1_hex_pubkey")
        #expect(parsed.drivers[0].note == "Toyota Camry, airport runs")
        #expect(parsed.drivers[0].roadflareKey?.version == 2)
        #expect(parsed.drivers[1].pubkey == "d2_hex_pubkey")
        #expect(parsed.drivers[1].roadflareKey == nil)
        #expect(parsed.updatedAt == 1700002000)
    }

    // MARK: - Kind 3173: Ride Offer

    @Test func parseAndroidRideOffer() throws {
        // Legacy fixture (no fiat fields) — backward compat: fiatFare must be nil
        let data = AndroidFixtures.rideOffer.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(RideOfferContent.self, from: data)
        #expect(parsed.fareEstimate == 15.50)
        #expect(parsed.approxPickup.latitude == 40.71)
        #expect(parsed.destination.longitude == -73.985)
        #expect(parsed.rideRouteKm == 8.85)
        #expect(parsed.paymentMethod == "zelle")
        #expect(parsed.fiatPaymentMethods == ["zelle", "venmo", "cash"])
        // ADR-0008 backward compat: legacy offers without fiat fields decode with fiatFare == nil
        #expect(parsed.fiatFare == nil)
    }

    @Test func parseAndroidRideOfferWithFiatFare() throws {
        // Modern fixture (with fiat fields per ADR-0008)
        let data = AndroidFixtures.rideOfferWithFiatFare.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(RideOfferContent.self, from: data)
        #expect(parsed.fareEstimate == 15_000.0)
        #expect(parsed.fiatFare?.amount == "12.50")
        #expect(parsed.fiatFare?.currency == "USD")
        #expect(parsed.paymentMethod == "zelle")
        #expect(parsed.fiatPaymentMethods == ["zelle", "venmo", "cash"])
    }

    // MARK: - Location

    @Test func parseAndroidLocation() throws {
        let data = AndroidFixtures.location.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(Location.self, from: data)
        #expect(parsed.latitude == 40.7128)
        #expect(parsed.longitude == -74.006)
        #expect(parsed.address == nil)
    }

    @Test func parseAndroidLocationWithAddress() throws {
        let data = AndroidFixtures.locationWithAddress.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(Location.self, from: data)
        #expect(parsed.address == "Penn Station, New York")
    }

    // MARK: - iOS→Android: Verify Our Encoding Matches Android Expectations

    @Test func iosRideOfferMatchesAndroidFieldNames() throws {
        let offer = RideOfferContent(
            fareEstimate: 15.50,
            destination: Location(latitude: 40.758, longitude: -73.985),
            approxPickup: Location(latitude: 40.71, longitude: -74.01),
            rideRouteKm: 8.85,
            rideRouteMin: 22.0,
            destinationGeohash: "dr5ru",
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle", "venmo", "cash"]
        )
        let data = try JSONEncoder().encode(offer)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // These exact field names must match Android's parser
        #expect(dict["fare_estimate"] != nil)
        #expect(dict["destination"] != nil)
        #expect(dict["approx_pickup"] != nil)
        #expect(dict["ride_route_km"] != nil)
        #expect(dict["ride_route_min"] != nil)
        #expect(dict["destination_geohash"] != nil)
        #expect(dict["payment_method"] != nil)
        #expect(dict["fiat_payment_methods"] != nil)

        // Must NOT have camelCase
        #expect(dict["fareEstimate"] == nil)
        #expect(dict["approxPickup"] == nil)
        #expect(dict["paymentMethod"] == nil)
    }

    @Test func iosCancellationMatchesAndroidFormat() throws {
        let cancel = CancellationContent(reason: "Changed plans")
        let data = try JSONEncoder().encode(cancel)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["status"] as? String == "cancelled")
        #expect(dict["reason"] as? String == "Changed plans")
    }

    @Test func iosDriverActionUsesActionNotType() throws {
        let action = RiderRideAction(
            type: "pin_verify", at: 1700000000,
            locationType: nil, locationEncrypted: nil,
            status: "verified", attempt: 1
        )
        let data = try JSONEncoder().encode(action)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["action"] as? String == "pin_verify")
        #expect(dict["type"] == nil)  // Must NOT use "type"
    }
}

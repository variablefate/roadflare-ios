import Foundation
import Testing
@testable import RidestrSDK

private let validAcceptanceEventId = String(repeating: "a", count: 64)
private let validConfirmationEventId = String(repeating: "b", count: 64)

@Suite("RideshareEventBuilder Tests")
struct RideshareEventBuilderTests {
    @Test func buildRideOffer() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        let content = RideOfferContent(
            fareEstimate: 12.50,
            destination: Location(latitude: 40.758, longitude: -73.985),
            approxPickup: Location(latitude: 40.71, longitude: -74.01),
            rideRouteKm: 5.5,
            rideRouteMin: 12.0,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle", "venmo"]
        )

        let event = try await RideshareEventBuilder.rideOffer(
            driverPubkey: driver.publicKeyHex,
            driverAvailabilityEventId: "avail_123",
            content: content,
            keypair: rider
        )

        #expect(event.kind == EventKind.rideOffer.rawValue)
        #expect(event.pubkey == rider.publicKeyHex)
        #expect(event.isRoadflare)
        #expect(event.referencedPubkeys.contains(driver.publicKeyHex))
        #expect(event.referencedEventIds.contains("avail_123"))
        #expect(event.expirationTimestamp != nil)
        #expect(EventSigner.verify(event))

        // Content should be encrypted (not readable as JSON)
        #expect(!event.content.contains("fare_estimate"))
    }

    @Test func buildRideOfferDecryptable() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        let content = RideOfferContent(
            fareEstimate: 15.00,
            destination: Location(latitude: 40.0, longitude: -74.0),
            approxPickup: Location(latitude: 40.1, longitude: -74.1),
            paymentMethod: "cash",
            fiatPaymentMethods: ["cash"]
        )

        let event = try await RideshareEventBuilder.rideOffer(
            driverPubkey: driver.publicKeyHex,
            driverAvailabilityEventId: nil,
            content: content,
            keypair: rider
        )

        // Driver should be able to decrypt
        let decrypted = try NIP44.decrypt(
            ciphertext: event.content,
            receiverKeypair: driver,
            senderPublicKeyHex: rider.publicKeyHex
        )
        let parsed = try JSONDecoder().decode(RideOfferContent.self, from: Data(decrypted.utf8))
        #expect(parsed.fareEstimate == 15.00)
        #expect(parsed.fiatPaymentMethods == ["cash"])
    }

    @Test func buildConfirmation() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        let event = try await RideshareEventBuilder.rideConfirmation(
            driverPubkey: driver.publicKeyHex,
            acceptanceEventId: validAcceptanceEventId,
            precisePickup: Location(latitude: 40.71234, longitude: -74.00567),
            keypair: rider
        )

        #expect(event.kind == EventKind.rideConfirmation.rawValue)
        #expect(event.referencedEventIds.contains(validAcceptanceEventId))
        #expect(EventSigner.verify(event))

        // Driver can decrypt and see precise pickup
        let decrypted = try NIP44.decrypt(
            ciphertext: event.content,
            receiverKeypair: driver,
            senderPublicKeyHex: rider.publicKeyHex
        )
        let parsed = try JSONDecoder().decode(RideConfirmationContent.self, from: Data(decrypted.utf8))
        #expect(parsed.precisePickup.latitude == 40.71234)
    }

    @Test func buildChatMessage() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        let event = try await RideshareEventBuilder.chatMessage(
            recipientPubkey: driver.publicKeyHex,
            confirmationEventId: validConfirmationEventId,
            message: "On my way out!",
            keypair: rider
        )

        #expect(event.kind == EventKind.chatMessage.rawValue)
        #expect(event.referencedEventIds.contains(validConfirmationEventId))

        // Driver decrypts
        let parsed = try RideshareEventParser.parseChatMessage(event: event, keypair: driver)
        #expect(parsed.message == "On my way out!")
    }

    @Test func buildCancellation() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        let event = try await RideshareEventBuilder.cancellation(
            counterpartyPubkey: driver.publicKeyHex,
            confirmationEventId: validConfirmationEventId,
            reason: "Changed plans",
            keypair: rider
        )

        #expect(event.kind == EventKind.cancellation.rawValue)
        #expect(event.referencedEventIds.contains(validConfirmationEventId))
        #expect(event.referencedPubkeys.contains(driver.publicKeyHex))
        #expect(event.content.contains("cancelled"))

        let parsed = try RideshareEventParser.parseCancellation(event: event, keypair: driver)
        #expect(parsed.reason == "Changed plans")
    }

    @Test func buildFollowedDriversList() async throws {
        let rider = try NostrKeypair.generate()
        let drivers = [
            FollowedDriver(pubkey: "driver1_pub", name: "Alice"),
            FollowedDriver(pubkey: "driver2_pub", name: "Bob"),
        ]

        let event = try await RideshareEventBuilder.followedDriversList(
            drivers: drivers,
            keypair: rider
        )

        #expect(event.kind == EventKind.followedDriversList.rawValue)
        #expect(event.dTag == "roadflare-drivers")
        // Public p-tags for driver discovery
        #expect(event.referencedPubkeys.contains("driver1_pub"))
        #expect(event.referencedPubkeys.contains("driver2_pub"))

        // Content is encrypted to self
        let parsed = try RideshareEventParser.parseFollowedDriversList(event: event, keypair: rider)
        #expect(parsed.drivers.count == 2)
        #expect(parsed.drivers[0].pubkey == "driver1_pub")
    }

    @Test func buildKeyAcknowledgement() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        let event = try await RideshareEventBuilder.keyAcknowledgement(
            driverPubkey: driver.publicKeyHex,
            keyVersion: 3,
            keyUpdatedAt: 1700000000,
            status: "received",
            keypair: rider
        )

        #expect(event.kind == EventKind.keyAcknowledgement.rawValue)
        #expect(event.expirationTimestamp != nil)
    }

    @Test func buildRiderRideState() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        let history: [RiderRideAction] = [
            RiderRideAction(type: "location_reveal", at: 1700000000,
                           locationType: "pickup", locationEncrypted: "enc_loc", status: nil, attempt: nil),
            RiderRideAction(type: "pin_verify", at: 1700000100,
                           locationType: nil, locationEncrypted: nil, status: "verified", attempt: 1),
        ]

        let event = try await RideshareEventBuilder.riderRideState(
            driverPubkey: driver.publicKeyHex,
            confirmationEventId: validConfirmationEventId,
            phase: "verified",
            history: history,
            keypair: rider
        )

        #expect(event.kind == EventKind.riderRideState.rawValue)
        #expect(event.dTag == validConfirmationEventId)
        #expect(event.referencedEventIds.contains(validConfirmationEventId))
        #expect(event.referencedPubkeys.contains(driver.publicKeyHex))
        #expect(EventSigner.verify(event))
        #expect(!event.content.hasPrefix("#"))

        let parsed = try RideshareEventParser.parseRiderRideState(
            event: event,
            keypair: driver,
            expectedRiderPubkey: rider.publicKeyHex,
            expectedConfirmationEventId: validConfirmationEventId
        )
        #expect(parsed.currentPhase == "verified")
        #expect(parsed.history.count == 2)
    }

    @Test func buildFollowNotification() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        let event = try await RideshareEventBuilder.followNotification(
            driverPubkey: driver.publicKeyHex,
            riderName: "Alice",
            keypair: rider
        )

        #expect(event.kind == Int(EventKind.followNotification.rawValue))
        #expect(event.pubkey == rider.publicKeyHex)

        // Verify tags
        let pTag = event.tags.first { $0.first == "p" }
        #expect(pTag?[1] == driver.publicKeyHex)
        let tTag = event.tags.first { $0.first == "t" }
        #expect(tTag?[1] == "roadflare-follow")
        let expTag = event.tags.first { $0.first == "expiration" }
        #expect(expTag != nil)

        // Verify content is NIP-44 encrypted and decryptable by driver
        let decrypted = try NIP44.decrypt(
            ciphertext: event.content,
            receiverKeypair: driver,
            senderPublicKeyHex: rider.publicKeyHex
        )
        #expect(decrypted.contains("\"action\":\"follow\""))
        #expect(decrypted.contains("\"riderName\":\"Alice\""))
    }

    @Test func expirationTagsSet() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let now = Int(Date.now.timeIntervalSince1970)

        let offer = try await RideshareEventBuilder.rideOffer(
            driverPubkey: driver.publicKeyHex,
            driverAvailabilityEventId: nil,
            content: RideOfferContent(fareEstimate: 10, destination: Location(latitude: 0, longitude: 0), approxPickup: Location(latitude: 0, longitude: 0), paymentMethod: "cash", fiatPaymentMethods: []),
            keypair: rider
        )

        // Offer should expire in ~15 minutes
        let expiry = offer.expirationTimestamp!
        let diff = expiry - now
        #expect(diff > 14 * 60 && diff < 16 * 60)
    }

    @Test func allBuildersProduceVerifiableSignatures() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        // Offer
        let offer = try await RideshareEventBuilder.rideOffer(
            driverPubkey: driver.publicKeyHex, driverAvailabilityEventId: nil,
            content: RideOfferContent(fareEstimate: 10, destination: Location(latitude: 0, longitude: 0), approxPickup: Location(latitude: 0, longitude: 0), paymentMethod: "cash", fiatPaymentMethods: []),
            keypair: rider
        )
        #expect(EventSigner.verify(offer))

        // Confirmation
        let confirmation = try await RideshareEventBuilder.rideConfirmation(
            driverPubkey: driver.publicKeyHex, acceptanceEventId: validAcceptanceEventId,
            precisePickup: Location(latitude: 40.0, longitude: -74.0), keypair: rider
        )
        #expect(EventSigner.verify(confirmation))

        // Chat
        let chat = try await RideshareEventBuilder.chatMessage(
            recipientPubkey: driver.publicKeyHex, confirmationEventId: validConfirmationEventId,
            message: "test", keypair: rider
        )
        #expect(EventSigner.verify(chat))

        // Cancellation
        let cancel = try await RideshareEventBuilder.cancellation(
            counterpartyPubkey: driver.publicKeyHex, confirmationEventId: validConfirmationEventId,
            reason: "test", keypair: rider
        )
        #expect(EventSigner.verify(cancel))

        // Followed drivers list
        let driversList = try await RideshareEventBuilder.followedDriversList(
            drivers: [FollowedDriver(pubkey: "d1")], keypair: rider
        )
        #expect(EventSigner.verify(driversList))

        // Key ack
        let keyAck = try await RideshareEventBuilder.keyAcknowledgement(
            driverPubkey: driver.publicKeyHex, keyVersion: 1, keyUpdatedAt: 100,
            status: "received", keypair: rider
        )
        #expect(EventSigner.verify(keyAck))

        // Rider ride state
        let riderState = try await RideshareEventBuilder.riderRideState(
            driverPubkey: driver.publicKeyHex, confirmationEventId: validConfirmationEventId,
            phase: "verified", history: [], keypair: rider
        )
        #expect(EventSigner.verify(riderState))
    }

    @Test func confirmationRejectsMalformedAcceptanceEventId() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        await #expect(throws: RidestrError.self) {
            _ = try await RideshareEventBuilder.rideConfirmation(
                driverPubkey: driver.publicKeyHex,
                acceptanceEventId: "short-id",
                precisePickup: Location(latitude: 40.71234, longitude: -74.00567),
                keypair: rider
            )
        }
    }

    @Test func cancellationRejectsMalformedConfirmationEventId() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        await #expect(throws: RidestrError.self) {
            _ = try await RideshareEventBuilder.cancellation(
                counterpartyPubkey: driver.publicKeyHex,
                confirmationEventId: "conf1",
                reason: "test",
                keypair: rider
            )
        }
    }

    @Test func buildRideOfferWithFiatFareRoundTrip() async throws {
        // fiatFare survives encryption → decryption → JSON decode
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        let content = RideOfferContent(
            fareEstimate: 50_000,
            fiatFare: FiatFare(amount: "12.50", currency: "USD"),
            destination: Location(latitude: 40.758, longitude: -73.985),
            approxPickup: Location(latitude: 40.71, longitude: -74.01),
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )

        let event = try await RideshareEventBuilder.rideOffer(
            driverPubkey: driver.publicKeyHex,
            driverAvailabilityEventId: nil,
            content: content,
            keypair: rider
        )

        // Content must be encrypted (not readable as JSON)
        #expect(!event.content.contains("fare_fiat_amount"))

        // Driver decrypts and gets fiat fields
        let decrypted = try NIP44.decrypt(
            ciphertext: event.content,
            receiverKeypair: driver,
            senderPublicKeyHex: rider.publicKeyHex
        )
        let parsed = try JSONDecoder().decode(RideOfferContent.self, from: Data(decrypted.utf8))
        #expect(parsed.fiatFare?.amount == "12.50")
        #expect(parsed.fiatFare?.currency == "USD")
        #expect(parsed.fareEstimate == 50_000)
    }

    @Test func buildRideOfferWithoutFiatFareRoundTrip() async throws {
        // fiatFare nil → no fiat keys in decrypted JSON (backward compat)
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        let content = RideOfferContent(
            fareEstimate: 30_000,
            fiatFare: nil,
            destination: Location(latitude: 40.0, longitude: -74.0),
            approxPickup: Location(latitude: 40.1, longitude: -74.1),
            paymentMethod: "cash",
            fiatPaymentMethods: []
        )

        let event = try await RideshareEventBuilder.rideOffer(
            driverPubkey: driver.publicKeyHex,
            driverAvailabilityEventId: nil,
            content: content,
            keypair: rider
        )

        let decrypted = try NIP44.decrypt(
            ciphertext: event.content,
            receiverKeypair: driver,
            senderPublicKeyHex: rider.publicKeyHex
        )
        let parsed = try JSONDecoder().decode(RideOfferContent.self, from: Data(decrypted.utf8))
        #expect(parsed.fiatFare == nil)
        // Confirm raw JSON has no fiat keys (not just nil after decode)
        let rawJson = try JSONSerialization.jsonObject(with: Data(decrypted.utf8)) as! [String: Any]
        #expect(rawJson["fare_fiat_amount"] == nil)
        #expect(rawJson["fare_fiat_currency"] == nil)
    }
}

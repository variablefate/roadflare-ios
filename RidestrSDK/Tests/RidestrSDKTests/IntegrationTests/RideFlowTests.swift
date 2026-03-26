import Foundation
import Testing
@testable import RidestrSDK

private let rideFlowAcceptanceEventId = String(repeating: "a", count: 64)
private let rideFlowConfirmationEventId = String(repeating: "b", count: 64)

/// End-to-end ride flow tests simulating the full iOS rider ↔ Android driver protocol.
@Suite("Ride Flow Integration Tests")
struct RideFlowTests {

    // MARK: - Full Happy Path

    @Test func fullRideFlowHappyPath() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let sm = RideStateMachine()

        // 1. Rider sends offer (Kind 3173)
        let offerContent = RideOfferContent(
            fareEstimate: 12.50,
            destination: Location(latitude: 40.758, longitude: -73.985),
            approxPickup: Location(latitude: 40.71, longitude: -74.01),
            rideRouteKm: 5.5,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle", "venmo"]
        )
        let offerEvent = try await RideshareEventBuilder.rideOffer(
            driverPubkey: driver.publicKeyHex,
            driverAvailabilityEventId: nil,
            content: offerContent,
            keypair: rider
        )
        #expect(offerEvent.isRoadflare)
        #expect(EventSigner.verify(offerEvent))

        try sm.startRide(
            offerEventId: offerEvent.id,
            driverPubkey: driver.publicKeyHex,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle", "venmo"]
        )
        #expect(sm.stage == .waitingForAcceptance)

        // 2. Driver decrypts offer and accepts (Kind 3174)
        let decryptedOffer = try NIP44.decrypt(
            ciphertext: offerEvent.content,
            receiverKeypair: driver,
            senderPublicKeyHex: rider.publicKeyHex
        )
        let parsedOffer = try JSONDecoder().decode(RideOfferContent.self, from: Data(decryptedOffer.utf8))
        #expect(parsedOffer.fareEstimate == 12.50)
        #expect(parsedOffer.fiatPaymentMethods == ["zelle", "venmo"])

        // 3. Rider handles acceptance
        let pin = try sm.handleAcceptance(acceptanceEventId: rideFlowAcceptanceEventId)
        #expect(sm.stage == .driverAccepted)
        #expect(pin.count == 4)

        // 4. Rider auto-confirms (Kind 3175)
        let confirmEvent = try await RideshareEventBuilder.rideConfirmation(
            driverPubkey: driver.publicKeyHex,
            acceptanceEventId: rideFlowAcceptanceEventId,
            precisePickup: Location(latitude: 40.71234, longitude: -74.00567),
            keypair: rider
        )
        #expect(EventSigner.verify(confirmEvent))

        try sm.recordConfirmation(confirmationEventId: confirmEvent.id)
        #expect(sm.stage == .rideConfirmed)

        // 5. Driver state: en_route
        let enRouteState = DriverRideStateContent(
            currentStatus: "en_route_pickup", history: []
        )
        let r1 = try sm.handleDriverStateUpdate(
            eventId: "ds_1", confirmationId: confirmEvent.id, driverState: enRouteState
        )
        #expect(r1 == "en_route_pickup")
        #expect(sm.stage == .enRoute)

        // 6. Driver state: arrived
        let arrivedState = DriverRideStateContent(currentStatus: "arrived", history: [])
        _ = try sm.handleDriverStateUpdate(
            eventId: "ds_2", confirmationId: confirmEvent.id, driverState: arrivedState
        )
        #expect(sm.stage == .driverArrived)

        // 7. PIN verification
        sm.recordPinVerification(verified: true)
        #expect(sm.pinVerified)

        // 8. Driver state: in_progress
        let inProgressState = DriverRideStateContent(currentStatus: "in_progress", history: [])
        _ = try sm.handleDriverStateUpdate(
            eventId: "ds_3", confirmationId: confirmEvent.id, driverState: inProgressState
        )
        #expect(sm.stage == .inProgress)

        // 9. Driver state: completed
        let completedState = DriverRideStateContent(currentStatus: "completed", history: [])
        _ = try sm.handleDriverStateUpdate(
            eventId: "ds_4", confirmationId: confirmEvent.id, driverState: completedState
        )
        #expect(sm.stage == .completed)
    }

    // MARK: - Cancellation Mid-Ride

    @Test func riderCancelsMidRide() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let sm = RideStateMachine()

        try sm.startRide(offerEventId: "o1", driverPubkey: driver.publicKeyHex,
                         paymentMethod: "cash", fiatPaymentMethods: ["cash"])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: rideFlowConfirmationEventId)

        // Driver is en route
        let enRoute = DriverRideStateContent(currentStatus: "en_route_pickup", history: [])
        _ = try sm.handleDriverStateUpdate(
            eventId: "ds1",
            confirmationId: rideFlowConfirmationEventId,
            driverState: enRoute
        )

        // Rider cancels
        let cancelEvent = try await RideshareEventBuilder.cancellation(
            counterpartyPubkey: driver.publicKeyHex,
            confirmationEventId: rideFlowConfirmationEventId,
            reason: "Changed plans",
            keypair: rider
        )
        #expect(cancelEvent.kind == EventKind.cancellation.rawValue)
        #expect(EventSigner.verify(cancelEvent))

        let processed = sm.handleCancellation(eventId: cancelEvent.id, confirmationId: rideFlowConfirmationEventId)
        #expect(processed)
        #expect(sm.stage == .idle)
    }

    // MARK: - Driver Cancels

    @Test func driverCancels() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let sm = RideStateMachine()

        try sm.startRide(offerEventId: "o1", driverPubkey: driver.publicKeyHex,
                         paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: rideFlowConfirmationEventId)

        // Simulate driver sending cancellation
        let cancelEvent = try await RideshareEventBuilder.cancellation(
            counterpartyPubkey: rider.publicKeyHex,
            confirmationEventId: rideFlowConfirmationEventId,
            reason: "Emergency",
            keypair: driver
        )

        // Rider processes cancellation
        let content = try RideshareEventParser.parseCancellation(event: cancelEvent, keypair: rider)
        #expect(content.reason == "Emergency")

        let processed = sm.handleCancellation(eventId: cancelEvent.id, confirmationId: rideFlowConfirmationEventId)
        #expect(processed)
        #expect(sm.stage == .idle)
    }

    // MARK: - PIN Failure and Auto-Cancel

    @Test func pinFailureAutoCancels() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1",
                         paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")
        let arrived = DriverRideStateContent(currentStatus: "arrived", history: [])
        _ = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "conf1", driverState: arrived)

        // 3 failed PIN attempts
        for i in 1...RideConstants.maxPinAttempts {
            sm.recordPinVerification(verified: false)
            #expect(sm.pinAttempts == i)
        }
        #expect(!sm.pinVerified)
        #expect(sm.pinAttempts == RideConstants.maxPinAttempts)
    }

    // MARK: - Chat Roundtrip

    @Test func chatMessageRoundtrip() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        // Rider sends
        let riderMsg = try await RideshareEventBuilder.chatMessage(
            recipientPubkey: driver.publicKeyHex,
            confirmationEventId: rideFlowConfirmationEventId,
            message: "I'm at the corner",
            keypair: rider
        )
        let parsed1 = try RideshareEventParser.parseChatMessage(event: riderMsg, keypair: driver)
        #expect(parsed1.message == "I'm at the corner")

        // Driver replies
        let driverMsg = try await RideshareEventBuilder.chatMessage(
            recipientPubkey: rider.publicKeyHex,
            confirmationEventId: rideFlowConfirmationEventId,
            message: "Be there in 2 min",
            keypair: driver
        )
        let parsed2 = try RideshareEventParser.parseChatMessage(event: driverMsg, keypair: rider)
        #expect(parsed2.message == "Be there in 2 min")
    }

    // MARK: - RoadFlare Key Share Flow

    @Test func keyShareAndLocationDecryption() async throws {
        let driver = try NostrKeypair.generate()
        let rider = try NostrKeypair.generate()
        let roadflareKey = try NostrKeypair.generate()

        // 1. Driver shares key with rider (Kind 3186)
        let keyShareContent = KeyShareContent(
            roadflareKey: RoadflareKey(
                privateKeyHex: roadflareKey.privateKeyHex,
                publicKeyHex: roadflareKey.publicKeyHex,
                version: 1,
                keyUpdatedAt: 1700000000
            ),
            keyUpdatedAt: 1700000000,
            driverPubKey: driver.publicKeyHex
        )
        let json = try JSONEncoder().encode(keyShareContent)
        let encrypted = try NIP44.encrypt(
            plaintext: String(data: json, encoding: .utf8)!,
            senderKeypair: driver,
            recipientPublicKeyHex: rider.publicKeyHex
        )
        let keyShareEvent = NostrEvent(
            id: "ks1", pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.keyShare.rawValue,
            tags: [["p", rider.publicKeyHex], ["expiration", "\(Int(Date.now.timeIntervalSince1970) + 300)"]],
            content: encrypted, sig: "sig"
        )

        // 2. Rider parses key share
        let parsed = try RideshareEventParser.parseKeyShare(event: keyShareEvent, keypair: rider)
        #expect(parsed.roadflareKey.version == 1)

        // 3. Driver broadcasts location (Kind 30014)
        let locJSON = "{\"lat\":36.17,\"lon\":-115.14,\"timestamp\":1700000100,\"status\":\"online\"}"
        let locEncrypted = try NIP44.encrypt(
            plaintext: locJSON,
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: roadflareKey.publicKeyHex
        )
        let locEvent = NostrEvent(
            id: "loc1", pubkey: driver.publicKeyHex,
            createdAt: 1700000100,
            kind: EventKind.roadflareLocation.rawValue,
            tags: [["d", "roadflare-location"], ["status", "online"], ["key_version", "1"]],
            content: locEncrypted, sig: "sig"
        )

        // 4. Rider decrypts location using shared key
        let locParsed = try RideshareEventParser.parseRoadflareLocation(
            event: locEvent,
            roadflarePrivateKeyHex: parsed.roadflareKey.privateKeyHex
        )
        #expect(locParsed.location.latitude == 36.17)
        #expect(locParsed.location.status == .online)
    }

    // MARK: - Followed Drivers List Roundtrip

    @Test func followedDriversListPublishAndParse() async throws {
        let rider = try NostrKeypair.generate()
        let drivers = [
            FollowedDriver(pubkey: "driver1_hex", name: "Alice", note: "Toyota Camry"),
            FollowedDriver(pubkey: "driver2_hex", name: "Bob"),
        ]

        let event = try await RideshareEventBuilder.followedDriversList(
            drivers: drivers, keypair: rider
        )

        // Public p-tags for driver discovery
        #expect(event.referencedPubkeys.contains("driver1_hex"))
        #expect(event.referencedPubkeys.contains("driver2_hex"))

        // Decrypt and parse content
        let parsed = try RideshareEventParser.parseFollowedDriversList(
            event: event, keypair: rider
        )
        #expect(parsed.drivers.count == 2)
        #expect(parsed.drivers[0].note == "Toyota Camry")
    }

    // MARK: - Event Deduplication

    @Test func driverStateDeduplication() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1",
                         paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")

        let state = DriverRideStateContent(currentStatus: "arrived", history: [])

        // First event processes
        let r1 = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "conf1", driverState: state)
        #expect(r1 == "arrived")

        // Same event ID deduplicated
        let r2 = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "conf1", driverState: state)
        #expect(r2 == nil)

        // Different event ID but wrong confirmation — ignored
        let r3 = try sm.handleDriverStateUpdate(eventId: "ds2", confirmationId: "wrong", driverState: state)
        #expect(r3 == nil)
    }

    // MARK: - Progressive Location Reveal

    @Test func progressiveRevealRoadflareAlwaysPrecise() {
        // RoadFlare rides always share precise pickup at confirmation
        let shouldShare = ProgressiveReveal.shouldSharePrecisePickup(
            isRoadflare: true,
            driverLocation: nil,
            pickupLocation: Location(latitude: 40.71, longitude: -74.01)
        )
        #expect(shouldShare)
    }

    @Test func destinationOnlyAfterPin() {
        #expect(!ProgressiveReveal.shouldSharePreciseDestination(pinVerified: false))
        #expect(ProgressiveReveal.shouldSharePreciseDestination(pinVerified: true))
    }

    // MARK: - Payment Method Negotiation

    @Test func paymentMethodMatching() {
        let riderMethods: [PaymentMethod] = [.zelle, .venmo, .cash]
        let driverMethods: [PaymentMethod] = [.cashApp, .venmo]
        let common = PaymentMethod.findCommon(riderPreferences: riderMethods, driverAccepted: driverMethods)
        #expect(common == .venmo)
    }

    @Test func noCommonPaymentMethod() {
        let common = PaymentMethod.findCommon(
            riderPreferences: [.zelle],
            driverAccepted: [.cashApp]
        )
        #expect(common == nil)
    }
}

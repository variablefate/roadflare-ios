import Foundation
import Testing
@testable import RidestrSDK

/// Multi-step flow tests that exercise complex ride scenarios.
@Suite("Multi-Step Flow Tests")
struct MultiStepFlowTests {

    // MARK: - PIN Retry Flow

    @Test func pinFailThenRetrySucceed() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1",
                         paymentMethod: .zelle, fiatPaymentMethods: [.zelle])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")

        // Driver arrives
        let arrived = DriverRideStateContent(currentStatus: "arrived", history: [])
        _ = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "conf1", driverState: arrived)
        #expect(sm.stage == .driverArrived)

        // First attempt fails
        sm.recordPinVerification(verified: false)
        #expect(sm.pinAttempts == 1)
        #expect(!sm.pinVerified)

        // Second attempt succeeds
        sm.recordPinVerification(verified: true)
        #expect(sm.pinAttempts == 2)
        #expect(sm.pinVerified)
    }

    @Test func pinMaxAttemptsExhausted() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1",
                         paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")
        let arrived = DriverRideStateContent(currentStatus: "arrived", history: [])
        _ = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "conf1", driverState: arrived)

        for _ in 0..<RideConstants.maxPinAttempts {
            sm.recordPinVerification(verified: false)
        }
        #expect(sm.pinAttempts == RideConstants.maxPinAttempts)
        #expect(!sm.pinVerified)
    }

    // MARK: - Cancel During Active Ride

    @Test func cancelDuringEnRoute() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1",
                         paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")

        let enRoute = DriverRideStateContent(currentStatus: "en_route_pickup", history: [])
        _ = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "conf1", driverState: enRoute)

        let cancelled = sm.handleCancellation(eventId: "c1", confirmationId: "conf1")
        #expect(cancelled)
        #expect(sm.stage == .idle)
    }

    @Test func cancelAfterPinVerified() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1",
                         paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")

        let arrived = DriverRideStateContent(currentStatus: "arrived", history: [])
        _ = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "conf1", driverState: arrived)

        sm.recordPinVerification(verified: true)
        #expect(sm.pinVerified)

        // Cancel even after PIN verified (fiat ride, no escrow concern)
        let cancelled = sm.handleCancellation(eventId: "c1", confirmationId: "conf1")
        #expect(cancelled)
        #expect(sm.stage == .idle)
    }

    // MARK: - Sequential Rides

    @Test func twoConsecutiveRides() throws {
        let sm = RideStateMachine()

        // Ride 1
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1",
                         paymentMethod: .zelle, fiatPaymentMethods: [.zelle])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")

        let completed1 = DriverRideStateContent(currentStatus: "completed", history: [])
        _ = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "conf1", driverState: completed1)
        #expect(sm.stage == .completed)

        sm.reset()

        // Ride 2
        try sm.startRide(offerEventId: "o2", driverPubkey: "d2",
                         paymentMethod: .venmo, fiatPaymentMethods: [.venmo])
        #expect(sm.offerEventId == "o2")
        #expect(sm.driverPubkey == "d2")

        _ = try sm.handleAcceptance(acceptanceEventId: "acc2")
        try sm.recordConfirmation(confirmationEventId: "conf2")

        // Old events from ride 1 should not affect ride 2
        let staleResult = try sm.handleDriverStateUpdate(eventId: "ds_old", confirmationId: "conf1", driverState: completed1)
        #expect(staleResult == nil)  // Wrong confirmation ID

        // New events for ride 2 should work
        let arrived2 = DriverRideStateContent(currentStatus: "arrived", history: [])
        let result = try sm.handleDriverStateUpdate(eventId: "ds2", confirmationId: "conf2", driverState: arrived2)
        #expect(result == "arrived")
    }

    // MARK: - Race Conditions

    @Test func duplicateAcceptanceIgnored() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1",
                         paymentMethod: nil, fiatPaymentMethods: [])

        let pin1 = try sm.handleAcceptance(acceptanceEventId: "acc1")
        #expect(sm.stage == .driverAccepted)

        // Second acceptance (from same or different driver) — state machine is already past waiting
        #expect(throws: RidestrError.self) {
            _ = try sm.handleAcceptance(acceptanceEventId: "acc2")
        }
        // PIN should not change
        #expect(sm.pin == pin1)
    }

    @Test func driverStateAfterCancellation() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1",
                         paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")

        // Cancel the ride
        _ = sm.handleCancellation(eventId: "c1", confirmationId: "conf1")
        #expect(sm.stage == .idle)

        // Late driver state event arrives — should be ignored (confirmationEventId is nil after reset)
        let state = DriverRideStateContent(currentStatus: "arrived", history: [])
        // After reset, confirmationEventId is nil, so this won't match any confirmation
        let result = try sm.handleDriverStateUpdate(eventId: "ds_late", confirmationId: "conf1", driverState: state)
        #expect(result == nil)
    }

    // MARK: - Full End-to-End with Encryption

    @Test func fullRideWithEncryptedEventsAndChat() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let sm = RideStateMachine()

        // 1. Send offer
        let offerContent = RideOfferContent(
            fareEstimate: 15.00,
            destination: Location(latitude: 40.758, longitude: -73.985),
            approxPickup: Location(latitude: 40.71, longitude: -74.01),
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle", "venmo"]
        )
        let offerEvent = try await RideshareEventBuilder.rideOffer(
            driverPubkey: driver.publicKeyHex,
            driverAvailabilityEventId: nil,
            content: offerContent,
            keypair: rider
        )
        try sm.startRide(offerEventId: offerEvent.id, driverPubkey: driver.publicKeyHex,
                         paymentMethod: .zelle, fiatPaymentMethods: [.zelle, .venmo])

        // 2. Driver decrypts and accepts
        let decryptedOffer = try NIP44.decrypt(
            ciphertext: offerEvent.content,
            receiverKeypair: driver,
            senderPublicKeyHex: rider.publicKeyHex
        )
        let parsedOffer = try JSONDecoder().decode(RideOfferContent.self, from: Data(decryptedOffer.utf8))
        #expect(parsedOffer.fareEstimate == 15.00)

        // 3. Handle acceptance
        let pin = try sm.handleAcceptance(acceptanceEventId: "acc1")

        // 4. Confirm with precise pickup
        let confirmEvent = try await RideshareEventBuilder.rideConfirmation(
            driverPubkey: driver.publicKeyHex,
            acceptanceEventId: "acc1",
            precisePickup: Location(latitude: 40.71234, longitude: -74.00567),
            keypair: rider
        )
        try sm.recordConfirmation(confirmationEventId: confirmEvent.id)

        // 5. Driver state: arrived
        let arrived = DriverRideStateContent(currentStatus: "arrived", history: [])
        _ = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: confirmEvent.id, driverState: arrived)
        #expect(sm.stage == .driverArrived)
        #expect(sm.pin == pin)

        // 6. PIN verified
        sm.recordPinVerification(verified: true)

        // 7. Chat
        let chatEvent = try await RideshareEventBuilder.chatMessage(
            recipientPubkey: driver.publicKeyHex,
            confirmationEventId: confirmEvent.id,
            message: "Thanks for the ride!",
            keypair: rider
        )
        let parsedChat = try RideshareEventParser.parseChatMessage(event: chatEvent, keypair: driver)
        #expect(parsedChat.message == "Thanks for the ride!")

        // 8. Complete
        let completed = DriverRideStateContent(currentStatus: "completed", history: [])
        _ = try sm.handleDriverStateUpdate(eventId: "ds2", confirmationId: confirmEvent.id, driverState: completed)
        #expect(sm.stage == .completed)

        // 9. Reset for next ride
        sm.reset()
        #expect(sm.stage == .idle)
        #expect(sm.pin == nil)
    }

    // MARK: - RoadFlare Key Share + Location Flow

    @Test func keyShareEnablesLocationDecryption() async throws {
        let driver = try NostrKeypair.generate()
        let rider = try NostrKeypair.generate()
        let roadflareKey = try NostrKeypair.generate()

        // Driver shares key
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

        // Rider parses key
        let parsed = try RideshareEventParser.parseKeyShare(event: keyShareEvent, keypair: rider)

        // Driver broadcasts location
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

        // Rider decrypts with the shared key
        let locParsed = try RideshareEventParser.parseRoadflareLocation(
            event: locEvent,
            roadflarePrivateKeyHex: parsed.roadflareKey.privateKeyHex
        )
        #expect(locParsed.location.latitude == 36.17)
        #expect(locParsed.location.status == .online)
    }

    // MARK: - Followed Drivers List Publish + Parse

    @Test func followedDriversListRoundtripWithMultipleDrivers() async throws {
        let rider = try NostrKeypair.generate()
        let key1 = RoadflareKey(privateKeyHex: "aa", publicKeyHex: "bb", version: 1, keyUpdatedAt: 100)
        let drivers = [
            FollowedDriver(pubkey: "d1", name: "Alice", note: "Toyota Camry", roadflareKey: key1),
            FollowedDriver(pubkey: "d2", name: "Bob"),
            FollowedDriver(pubkey: "d3"),
        ]

        let event = try await RideshareEventBuilder.followedDriversList(drivers: drivers, keypair: rider)

        // Public p-tags
        #expect(event.referencedPubkeys.count == 3)
        #expect(event.referencedPubkeys.contains("d1"))
        #expect(event.referencedPubkeys.contains("d2"))
        #expect(event.referencedPubkeys.contains("d3"))

        // Decrypt and parse
        let parsed = try RideshareEventParser.parseFollowedDriversList(event: event, keypair: rider)
        #expect(parsed.drivers.count == 3)
        #expect(parsed.drivers[0].note == "Toyota Camry")
        #expect(parsed.drivers[0].roadflareKey?.version == 1)
        #expect(parsed.drivers[1].pubkey == "d2")
        #expect(parsed.drivers[2].roadflareKey == nil)
    }

    // MARK: - Payment Method Negotiation

    @Test func paymentMethodMatchingPriority() {
        // Rider prefers zelle first
        let rider: [PaymentMethod] = [.zelle, .venmo, .cash]
        let driver: [PaymentMethod] = [.cashApp, .venmo, .zelle]
        let common = PaymentMethod.findCommon(riderPreferences: rider, driverAccepted: driver)
        #expect(common == .zelle)  // Rider's first preference that driver accepts
    }

    @Test func paymentMethodNoOverlap() {
        let rider: [PaymentMethod] = [.zelle]
        let driver: [PaymentMethod] = [.cashApp, .venmo]
        let common = PaymentMethod.findCommon(riderPreferences: rider, driverAccepted: driver)
        #expect(common == nil)
    }

    @Test func paymentMethodEmptyLists() {
        #expect(PaymentMethod.findCommon(riderPreferences: [], driverAccepted: [.cash]) == nil)
        #expect(PaymentMethod.findCommon(riderPreferences: [.cash], driverAccepted: []) == nil)
        #expect(PaymentMethod.findCommon(riderPreferences: [], driverAccepted: []) == nil)
    }
}

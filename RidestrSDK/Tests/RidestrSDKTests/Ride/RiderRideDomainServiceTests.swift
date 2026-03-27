import Foundation
import Testing
@testable import RidestrSDK

@Suite("RiderRideDomainService Tests")
struct RiderRideDomainServiceTests {
    @Test func runtimePlanTracksRideSessionStages() {
        let riderPubkey = String(repeating: "1", count: 64)
        let driverPubkey = String(repeating: "2", count: 64)
        let offerEventId = String(repeating: "a", count: 64)
        let acceptanceEventId = String(repeating: "b", count: 64)
        let confirmationEventId = String(repeating: "c", count: 64)
        let service = RiderRideDomainService(
            relayManager: FakeRelayManager(),
            keypair: try! NostrKeypair.fromHex(String(repeating: "3", count: 64))
        )
        let stateMachine = RideStateMachine(riderPubkey: riderPubkey)

        _ = stateMachine.processEvent(.sendOffer(
            offerEventId: offerEventId,
            driverPubkey: driverPubkey,
            paymentMethod: "venmo",
            fiatPaymentMethods: ["venmo", "cash"]
        ))
        #expect(service.runtimePlan(for: stateMachine).subscriptions == [
            .acceptance(offerEventId: offerEventId, driverPubkey: driverPubkey)
        ])

        _ = stateMachine.processEvent(.acceptanceReceived(acceptanceEventId: acceptanceEventId))
        #expect(service.runtimePlan(for: stateMachine).pendingAction == .recoverOrPublishConfirmation(
            acceptanceEventId: acceptanceEventId,
            driverPubkey: driverPubkey
        ))

        _ = stateMachine.processEvent(.confirm(confirmationEventId: confirmationEventId))
        #expect(service.runtimePlan(for: stateMachine).subscriptions == [
            .driverState(confirmationEventId: confirmationEventId, driverPubkey: driverPubkey),
            .cancellation(confirmationEventId: confirmationEventId, driverPubkey: driverPubkey),
        ])
    }

    @Test func publishRideOfferPublishesAndTransitionsStateMachine() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        let service = RiderRideDomainService(relayManager: relay, keypair: rider)
        let stateMachine = RideStateMachine(riderPubkey: rider.publicKeyHex)

        let publication = try await service.publishRideOffer(
            driverPubkey: driver.publicKeyHex,
            content: RideOfferContent(
                fareEstimate: 12_500,
                destination: Location(latitude: 40.758, longitude: -73.985),
                approxPickup: Location(latitude: 40.710, longitude: -74.010),
                rideRouteKm: 8.9,
                rideRouteMin: 21,
                paymentMethod: "bitcoin",
                fiatPaymentMethods: ["bitcoin", "cash"]
            ),
            stateMachine: stateMachine
        )

        #expect(relay.publishedEvents.count == 1)
        #expect(stateMachine.stage == .waitingForAcceptance)
        #expect(stateMachine.offerEventId == publication.event.id)
        #expect(stateMachine.paymentMethod == "bitcoin")
        #expect(publication.runtimePlan.subscriptions == [
            .acceptance(offerEventId: publication.event.id, driverPubkey: driver.publicKeyHex)
        ])

        let plaintext = try NIP44.decrypt(
            ciphertext: publication.event.content,
            receiverKeypair: driver,
            senderPublicKeyHex: rider.publicKeyHex
        )
        let parsed = try JSONDecoder().decode(RideOfferContent.self, from: Data(plaintext.utf8))
        #expect(parsed.paymentMethod == "bitcoin")
        #expect(parsed.fiatPaymentMethods == ["bitcoin", "cash"])
    }

    @Test func receiveAcceptanceEventAdvancesStateAndRequestsConfirmation() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        let service = RiderRideDomainService(relayManager: relay, keypair: rider)
        let stateMachine = RideStateMachine(riderPubkey: rider.publicKeyHex)

        let offerPublication = try await service.publishRideOffer(
            driverPubkey: driver.publicKeyHex,
            content: RideOfferContent(
                fareEstimate: 9_500,
                destination: Location(latitude: 40.758, longitude: -73.985),
                approxPickup: Location(latitude: 40.710, longitude: -74.010),
                paymentMethod: "venmo",
                fiatPaymentMethods: ["venmo", "cash"]
            ),
            stateMachine: stateMachine
        )
        let acceptanceEvent = try await makeAcceptanceEvent(
            driver: driver,
            riderPubkey: rider.publicKeyHex,
            offerEventId: offerPublication.event.id
        )

        let resolution = try service.receiveAcceptanceEvent(
            acceptanceEvent,
            expectedOfferEventId: offerPublication.event.id,
            expectedDriverPubkey: driver.publicKeyHex,
            stateMachine: stateMachine
        )

        #expect(resolution.didAdvanceState)
        #expect(resolution.content.status == "accepted")
        #expect(stateMachine.stage == .driverAccepted)
        #expect(stateMachine.acceptanceEventId == acceptanceEvent.id)
        #expect((resolution.pin ?? "").count == RideConstants.pinDigits)
        #expect(resolution.shouldPublishConfirmation)
        #expect(resolution.runtimePlan.pendingAction == .recoverOrPublishConfirmation(
            acceptanceEventId: acceptanceEvent.id,
            driverPubkey: driver.publicKeyHex
        ))
    }

    @Test func publishAndRecoverConfirmationProduceConfirmedPlan() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        let service = RiderRideDomainService(relayManager: relay, keypair: rider)
        let stateMachine = RideStateMachine(riderPubkey: rider.publicKeyHex)

        let offerPublication = try await service.publishRideOffer(
            driverPubkey: driver.publicKeyHex,
            content: RideOfferContent(
                fareEstimate: 11_000,
                destination: Location(latitude: 40.758, longitude: -73.985),
                approxPickup: Location(latitude: 40.710, longitude: -74.010),
                paymentMethod: "cash",
                fiatPaymentMethods: ["cash"]
            ),
            stateMachine: stateMachine
        )
        let acceptanceEvent = try await makeAcceptanceEvent(
            driver: driver,
            riderPubkey: rider.publicKeyHex,
            offerEventId: offerPublication.event.id
        )
        _ = try service.receiveAcceptanceEvent(
            acceptanceEvent,
            expectedOfferEventId: offerPublication.event.id,
            expectedDriverPubkey: driver.publicKeyHex,
            stateMachine: stateMachine
        )

        let confirmation = try await service.publishConfirmation(
            driverPubkey: driver.publicKeyHex,
            acceptanceEventId: acceptanceEvent.id,
            precisePickup: Location(latitude: 40.71234, longitude: -74.00567),
            stateMachine: stateMachine
        )

        #expect(stateMachine.stage == .rideConfirmed)
        #expect(stateMachine.confirmationEventId == confirmation.event.id)
        #expect(stateMachine.precisePickupShared)
        #expect(confirmation.runtimePlan.subscriptions == [
            .driverState(confirmationEventId: confirmation.event.id, driverPubkey: driver.publicKeyHex),
            .cancellation(confirmationEventId: confirmation.event.id, driverPubkey: driver.publicKeyHex),
        ])

        let recoveryStateMachine = RideStateMachine(riderPubkey: rider.publicKeyHex)
        _ = recoveryStateMachine.processEvent(.sendOffer(
            offerEventId: offerPublication.event.id,
            driverPubkey: driver.publicKeyHex,
            paymentMethod: "cash",
            fiatPaymentMethods: ["cash"]
        ))
        _ = recoveryStateMachine.processEvent(.acceptanceReceived(acceptanceEventId: acceptanceEvent.id))
        relay.fetchResults = [confirmation.event]

        let recovered = try await service.recoverExistingConfirmation(
            driverPubkey: driver.publicKeyHex,
            acceptanceEventId: acceptanceEvent.id,
            stateMachine: recoveryStateMachine
        )

        #expect(recovered?.event.id == confirmation.event.id)
        #expect(recoveryStateMachine.stage == .rideConfirmed)
        #expect(recoveryStateMachine.confirmationEventId == confirmation.event.id)
        #expect(recoveryStateMachine.precisePickupShared)
    }

    @Test func receiveDriverStateEventReturnsPinActionsAndUpdatesStage() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let service = RiderRideDomainService(relayManager: FakeRelayManager(), keypair: rider)
        let stateMachine = try await makeConfirmedRideStateMachine(
            rider: rider,
            driver: driver,
            service: service
        )
        let pinEncrypted = try NIP44.encrypt(
            plaintext: stateMachine.pin ?? "0000",
            senderKeypair: driver,
            recipientPublicKeyHex: rider.publicKeyHex
        )
        let driverStateEvent = try await makeDriverStateEvent(
            driver: driver,
            riderPubkey: rider.publicKeyHex,
            confirmationEventId: stateMachine.confirmationEventId ?? "",
            content: DriverRideStateContent(
                currentStatus: "arrived",
                history: [
                    DriverRideAction(
                        type: "pin_submit",
                        at: 1700000000,
                        status: nil,
                        approxLocation: nil,
                        finalFare: nil,
                        invoice: nil,
                        pinEncrypted: pinEncrypted
                    )
                ]
            )
        )

        let resolution = try service.receiveDriverStateEvent(
            driverStateEvent,
            confirmationEventId: stateMachine.confirmationEventId ?? "",
            expectedDriverPubkey: driver.publicKeyHex,
            stateMachine: stateMachine
        )

        switch resolution {
        case .ignored:
            Issue.record("Driver state event should have been processed")
        case .processed(let update):
            #expect(update.status == "arrived")
            #expect(update.pinActions.count == 1)
            #expect(update.pinActions[0].isPinSubmitAction)
            #expect(update.terminalOutcome == nil)
            #expect(stateMachine.stage == .driverArrived)
        }
    }

    @Test func prepareAndPublishPinVerificationResponsePublishesVerifiedState() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        let service = RiderRideDomainService(relayManager: relay, keypair: rider)
        let stateMachine = try await makeConfirmedRideStateMachine(
            rider: rider,
            driver: driver,
            service: service
        )
        let arrivedEvent = try await makeDriverStateEvent(
            driver: driver,
            riderPubkey: rider.publicKeyHex,
            confirmationEventId: stateMachine.confirmationEventId ?? "",
            content: DriverRideStateContent(currentStatus: "arrived", history: [])
        )
        _ = try service.receiveDriverStateEvent(
            arrivedEvent,
            confirmationEventId: stateMachine.confirmationEventId ?? "",
            expectedDriverPubkey: driver.publicKeyHex,
            stateMachine: stateMachine
        )

        let pinEncrypted = try NIP44.encrypt(
            plaintext: stateMachine.pin ?? "0000",
            senderKeypair: driver,
            recipientPublicKeyHex: rider.publicKeyHex
        )
        let plan = try service.preparePinVerificationResponse(
            pinEncrypted: pinEncrypted,
            driverPubkey: driver.publicKeyHex,
            confirmationEventId: stateMachine.confirmationEventId ?? "",
            destination: Location(latitude: 40.73061, longitude: -73.935242),
            stateMachine: stateMachine
        )
        let publication = try await service.publishPinVerificationResponse(
            plan,
            stateMachine: stateMachine
        )

        #expect(publication.plan.isCorrect)
        #expect(publication.plan.destinationAction != nil)
        #expect(stateMachine.pinVerified)
        #expect(stateMachine.pin == nil)
        #expect(stateMachine.preciseDestinationShared)

        let parsed = try RideshareEventParser.parseRiderRideState(
            event: publication.event,
            keypair: driver,
            expectedRiderPubkey: rider.publicKeyHex,
            expectedConfirmationEventId: stateMachine.confirmationEventId
        )
        let hasVerifiedAction = parsed.history.contains { $0.isPinVerified }
        #expect(parsed.currentPhase == "verified")
        #expect(parsed.history.count == 2)
        #expect(hasVerifiedAction)
    }

    @Test func publishTerminationUsesDeletionBeforeConfirmation() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        let service = RiderRideDomainService(relayManager: relay, keypair: rider)
        let stateMachine = RideStateMachine(riderPubkey: rider.publicKeyHex)

        _ = try await service.publishRideOffer(
            driverPubkey: driver.publicKeyHex,
            content: RideOfferContent(
                fareEstimate: 8_000,
                destination: Location(latitude: 40.758, longitude: -73.985),
                approxPickup: Location(latitude: 40.710, longitude: -74.010),
                paymentMethod: "cash",
                fiatPaymentMethods: ["cash"]
            ),
            stateMachine: stateMachine
        )

        let publication = try await service.publishTermination(for: stateMachine, reason: "expired")

        switch publication {
        case .offerDeletion(let event):
            #expect(event.kind == EventKind.deletion.rawValue)
        default:
            Issue.record("Expected pre-confirmation termination to publish deletion")
        }
    }

    @Test func publishTerminationAndReceiveCancellationUseCancellationAfterConfirmation() async throws {
        let rider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        let service = RiderRideDomainService(relayManager: relay, keypair: rider)
        let stateMachine = try await makeConfirmedRideStateMachine(
            rider: rider,
            driver: driver,
            service: service
        )

        let publication = try await service.publishTermination(for: stateMachine, reason: "changed plans")
        switch publication {
        case .cancellation(let event):
            #expect(event.kind == EventKind.cancellation.rawValue)
        default:
            Issue.record("Expected confirmed ride termination to publish cancellation")
        }

        let cancellationEvent = try await RideshareEventBuilder.cancellation(
            counterpartyPubkey: rider.publicKeyHex,
            confirmationEventId: stateMachine.confirmationEventId ?? "",
            reason: "driver left",
            keypair: driver
        )
        let resolution = try service.receiveCancellationEvent(
            cancellationEvent,
            confirmationEventId: stateMachine.confirmationEventId ?? "",
            expectedDriverPubkey: driver.publicKeyHex,
            stateMachine: stateMachine
        )

        switch resolution {
        case .ignored:
            Issue.record("Cancellation should have been processed")
        case .processed(let update):
            #expect(update.content.reason == "driver left")
            #expect(stateMachine.stage == .idle)
        }
    }
}

private func makeAcceptanceEvent(
    driver: NostrKeypair,
    riderPubkey: String,
    offerEventId: String,
    status: String = "accepted",
    paymentMethod: String = "venmo"
) async throws -> NostrEvent {
    let json = """
    {"status":"\(status)","wallet_pubkey":null,"payment_method":"\(paymentMethod)","mint_url":null}
    """
    return try await EventSigner.sign(
        kind: .rideAcceptance,
        content: json,
        tags: [
            [NostrTags.eventRef, offerEventId],
            [NostrTags.pubkeyRef, riderPubkey],
        ],
        keypair: driver
    )
}

private func makeDriverStateEvent(
    driver: NostrKeypair,
    riderPubkey: String,
    confirmationEventId: String,
    content: DriverRideStateContent
) async throws -> NostrEvent {
    let json = try JSONEncoder().encode(content)
    return try await EventSigner.sign(
        kind: .driverRideState,
        content: String(data: json, encoding: .utf8) ?? "{}",
        tags: [
            [NostrTags.dTag, confirmationEventId],
            [NostrTags.eventRef, confirmationEventId],
            [NostrTags.pubkeyRef, riderPubkey],
        ],
        keypair: driver
    )
}

private func makeConfirmedRideStateMachine(
    rider: NostrKeypair,
    driver: NostrKeypair,
    service: RiderRideDomainService
) async throws -> RideStateMachine {
    let stateMachine = RideStateMachine(riderPubkey: rider.publicKeyHex)
    let offer = try await service.publishRideOffer(
        driverPubkey: driver.publicKeyHex,
        content: RideOfferContent(
            fareEstimate: 10_000,
            destination: Location(latitude: 40.758, longitude: -73.985),
            approxPickup: Location(latitude: 40.710, longitude: -74.010),
            paymentMethod: "cash",
            fiatPaymentMethods: ["cash"]
        ),
        stateMachine: stateMachine
    )
    let acceptanceEvent = try await makeAcceptanceEvent(
        driver: driver,
        riderPubkey: rider.publicKeyHex,
        offerEventId: offer.event.id,
        paymentMethod: "cash"
    )
    _ = try service.receiveAcceptanceEvent(
        acceptanceEvent,
        expectedOfferEventId: offer.event.id,
        expectedDriverPubkey: driver.publicKeyHex,
        stateMachine: stateMachine
    )
    _ = try await service.publishConfirmation(
        driverPubkey: driver.publicKeyHex,
        acceptanceEventId: acceptanceEvent.id,
        precisePickup: Location(latitude: 40.71234, longitude: -74.00567),
        stateMachine: stateMachine
    )
    return stateMachine
}

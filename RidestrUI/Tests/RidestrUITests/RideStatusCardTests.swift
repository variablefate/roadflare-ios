import Testing
import SwiftUI
import RidestrSDK
@testable import RidestrUI

@Suite("RideStatusCard")
@MainActor
struct RideStatusCardTests {

    @Test("Init with all parameters")
    func fullInit() {
        let fare = FareEstimate(distanceMiles: 5.0, durationMinutes: 12, fareUSD: Decimal(15), routeSummary: "via Main St")
        let card = RideStatusCard(
            stage: .driverArrived,
            pin: "1234",
            fareEstimate: fare,
            paymentMethods: ["venmo", "zelle"],
            onCancel: {},
            onChat: {},
            onCloseRide: {}
        )
        #expect(card.stage == .driverArrived)
        #expect(card.pin == "1234")
        #expect(card.fareEstimate != nil)
        #expect(card.paymentMethods.count == 2)
    }

    @Test("Init with minimal parameters")
    func minimalInit() {
        let card = RideStatusCard(stage: .idle)
        #expect(card.stage == .idle)
        #expect(card.pin == nil)
        #expect(card.fareEstimate == nil)
        #expect(card.paymentMethods.isEmpty)
        #expect(card.onCancel == nil)
        #expect(card.onChat == nil)
        #expect(card.onCloseRide == nil)
    }

    @Test("All stages are representable",
          arguments: [
            RiderStage.idle,
            .waitingForAcceptance,
            .driverAccepted,
            .rideConfirmed,
            .enRoute,
            .driverArrived,
            .inProgress,
            .completed
          ])
    func allStages(stage: RiderStage) {
        let card = RideStatusCard(stage: stage)
        #expect(card.stage == stage)
    }

    @Test("Cancel callback fires")
    func cancelCallback() {
        var called = false
        let card = RideStatusCard(stage: .enRoute, onCancel: { called = true })
        card.onCancel?()
        #expect(called)
    }

    @Test("Chat callback fires")
    func chatCallback() {
        var called = false
        let card = RideStatusCard(stage: .inProgress, onChat: { called = true })
        card.onChat?()
        #expect(called)
    }

    @Test("Close ride callback fires")
    func closeRideCallback() {
        var called = false
        let card = RideStatusCard(stage: .completed, onCloseRide: { called = true })
        card.onCloseRide?()
        #expect(called)
    }

    @Test("FareEstimateView compact mode init")
    func fareEstimateCompact() {
        let fare = FareEstimate(distanceMiles: 3.2, durationMinutes: 8, fareUSD: Decimal(string: "9.50")!, routeSummary: nil)
        let view = FareEstimateView(estimate: fare, displayMode: .compact)
        #expect(view.displayMode == .compact)
        #expect(view.paymentMethods.isEmpty)
    }

    @Test("FareEstimateView card mode with payment methods")
    func fareEstimateCard() {
        let fare = FareEstimate(distanceMiles: 10, durationMinutes: 25, fareUSD: Decimal(30), routeSummary: "I-95")
        let view = FareEstimateView(
            estimate: fare,
            paymentMethods: ["cash", "cash_app", "paypal"],
            displayMode: .card
        )
        #expect(view.displayMode == .card)
        #expect(view.paymentMethods.count == 3)
    }
}

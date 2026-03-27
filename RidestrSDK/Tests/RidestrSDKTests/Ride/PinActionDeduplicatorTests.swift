import Testing
@testable import RidestrSDK

@Suite("PinActionDeduplicator Tests")
struct PinActionDeduplicatorTests {

    private func makePinAction(at timestamp: Int = 1000, pinEncrypted: String? = "enc123") -> DriverRideAction {
        DriverRideAction(
            type: "pin_submit",
            at: timestamp,
            status: nil,
            approxLocation: nil,
            finalFare: nil,
            invoice: nil,
            pinEncrypted: pinEncrypted
        )
    }

    // MARK: - beginProcessing

    @Test func newActionIsAccepted() {
        var dedup = PinActionDeduplicator()
        let action = makePinAction()
        #expect(dedup.beginProcessing(action) == true)
        #expect(dedup.inFlightKeys.count == 1)
    }

    @Test func duplicateActionIsRejected() {
        var dedup = PinActionDeduplicator()
        let action = makePinAction()
        _ = dedup.beginProcessing(action)
        dedup.finishProcessing(action, processed: true)
        #expect(dedup.beginProcessing(action) == false)
    }

    @Test func inFlightActionIsRejected() {
        var dedup = PinActionDeduplicator()
        let action = makePinAction()
        _ = dedup.beginProcessing(action)
        #expect(dedup.beginProcessing(action) == false)
    }

    @Test func legacyKeyBlocksNewAction() {
        let action = makePinAction(at: 500, pinEncrypted: "abc")
        let legacyKey = PinActionDeduplicator.legacyActionKey(500)
        var dedup = PinActionDeduplicator(processedKeys: [legacyKey])
        #expect(dedup.beginProcessing(action) == false)
    }

    @Test func sizeCapEnforced() {
        var dedup = PinActionDeduplicator(maxCombinedSize: 3)
        for i in 0..<3 {
            let action = makePinAction(at: i, pinEncrypted: "pin\(i)")
            _ = dedup.beginProcessing(action)
            dedup.finishProcessing(action, processed: true)
        }
        #expect(dedup.processedKeys.count == 3)
        let overflow = makePinAction(at: 99, pinEncrypted: "overflow")
        #expect(dedup.beginProcessing(overflow) == false)
    }

    @Test func inFlightCountsTowardCap() {
        var dedup = PinActionDeduplicator(maxCombinedSize: 2)
        let a = makePinAction(at: 1, pinEncrypted: "a")
        let b = makePinAction(at: 2, pinEncrypted: "b")
        _ = dedup.beginProcessing(a)
        _ = dedup.beginProcessing(b)
        let c = makePinAction(at: 3, pinEncrypted: "c")
        #expect(dedup.beginProcessing(c) == false)
    }

    // MARK: - finishProcessing

    @Test func finishWithProcessedAddsToProcessedKeys() {
        var dedup = PinActionDeduplicator()
        let action = makePinAction()
        _ = dedup.beginProcessing(action)
        dedup.finishProcessing(action, processed: true)
        #expect(dedup.processedKeys.contains(PinActionDeduplicator.actionKey(for: action)))
        #expect(dedup.inFlightKeys.isEmpty)
    }

    @Test func finishWithoutProcessedDoesNotAddToProcessed() {
        var dedup = PinActionDeduplicator()
        let action = makePinAction()
        _ = dedup.beginProcessing(action)
        dedup.finishProcessing(action, processed: false)
        #expect(dedup.processedKeys.isEmpty)
        #expect(dedup.inFlightKeys.isEmpty)
    }

    // MARK: - hasProcessed

    @Test func hasProcessedReturnsTrueForProcessedAction() {
        var dedup = PinActionDeduplicator()
        let action = makePinAction()
        _ = dedup.beginProcessing(action)
        dedup.finishProcessing(action, processed: true)
        #expect(dedup.hasProcessed(action) == true)
    }

    @Test func hasProcessedReturnsTrueForLegacyKey() {
        let action = makePinAction(at: 777, pinEncrypted: "new")
        let legacyKey = PinActionDeduplicator.legacyActionKey(777)
        let dedup = PinActionDeduplicator(processedKeys: [legacyKey])
        #expect(dedup.hasProcessed(action) == true)
    }

    @Test func hasProcessedReturnsFalseForUnknownAction() {
        let dedup = PinActionDeduplicator()
        let action = makePinAction()
        #expect(dedup.hasProcessed(action) == false)
    }

    // MARK: - Key generation

    @Test func actionKeyFormat() {
        let action = makePinAction(at: 1234, pinEncrypted: "secret")
        #expect(PinActionDeduplicator.actionKey(for: action) == "pin_submit:1234:secret")
    }

    @Test func actionKeyWithNilEncrypted() {
        let action = makePinAction(at: 1234, pinEncrypted: nil)
        #expect(PinActionDeduplicator.actionKey(for: action) == "pin_submit:1234:")
    }

    @Test func legacyKeyFormat() {
        #expect(PinActionDeduplicator.legacyActionKey(999) == "pin_submit:999")
    }

    // MARK: - reset

    @Test func resetClearsBothSets() {
        var dedup = PinActionDeduplicator()
        let a = makePinAction(at: 1, pinEncrypted: "a")
        let b = makePinAction(at: 2, pinEncrypted: "b")
        _ = dedup.beginProcessing(a)
        dedup.finishProcessing(a, processed: true)
        _ = dedup.beginProcessing(b)
        dedup.reset()
        #expect(dedup.processedKeys.isEmpty)
        #expect(dedup.inFlightKeys.isEmpty)
    }

    // MARK: - Initialization with existing keys

    @Test func initWithExistingProcessedKeys() {
        let existing: Set<String> = ["pin_submit:100:abc", "pin_submit:200:def"]
        let dedup = PinActionDeduplicator(processedKeys: existing)
        #expect(dedup.processedKeys == existing)
        #expect(dedup.inFlightKeys.isEmpty)
    }
}

import Foundation
import Testing
@testable import RidestrSDK

@Suite("RideStateRepository Tests")
struct RideStateRepositoryTests {

    private func makeRepo(
        policy: RideStateRestorationPolicy = .default
    ) -> (RideStateRepository, InMemoryRideStatePersistence) {
        let persistence = InMemoryRideStatePersistence()
        let repo = RideStateRepository(persistence: persistence, policy: policy)
        return (repo, persistence)
    }

    private func makeState(
        stage: String = RiderStage.waitingForAcceptance.rawValue,
        savedAt: Int = Int(Date.now.timeIntervalSince1970),
        processedPinActionKeys: [String]? = nil,
        processedPinTimestamps: [Int]? = nil
    ) -> PersistedRideState {
        PersistedRideState(
            stage: stage, offerEventId: "offer123",
            driverPubkey: "driver_pubkey_hex", pin: "1234",
            paymentMethodRaw: "zelle", fiatPaymentMethodsRaw: ["zelle", "cash"],
            pickupLat: 40.71, pickupLon: -74.01, pickupAddress: "Penn Station",
            destLat: 40.76, destLon: -73.98, destAddress: "Central Park",
            fareUSD: "12.50", fareDistanceMiles: 5.5, fareDurationMinutes: 18,
            savedAt: savedAt,
            processedPinActionKeys: processedPinActionKeys,
            processedPinTimestamps: processedPinTimestamps
        )
    }

    // MARK: - Round-trip

    @Test func saveAndLoadRoundTrip() {
        let (repo, _) = makeRepo()
        let state = makeState()
        repo.save(state)
        let loaded = repo.load()
        #expect(loaded?.stage == state.stage)
        #expect(loaded?.offerEventId == "offer123")
        #expect(loaded?.pickupLat == 40.71)
        #expect(loaded?.fareUSD == "12.50")
    }

    @Test func loadReturnsNilWhenEmpty() {
        let (repo, _) = makeRepo()
        #expect(repo.load() == nil)
    }

    @Test func clearRemovesData() {
        let (repo, _) = makeRepo()
        repo.save(makeState())
        repo.clear()
        #expect(repo.load() == nil)
    }

    // MARK: - Stage filtering

    @Test func loadRejectsIdle() {
        let (repo, _) = makeRepo()
        repo.save(makeState(stage: RiderStage.idle.rawValue))
        #expect(repo.load() == nil)
    }

    @Test func loadRejectsCompleted() {
        let (repo, _) = makeRepo()
        repo.save(makeState(stage: RiderStage.completed.rawValue))
        #expect(repo.load() == nil)
    }

    @Test func loadAcceptsWaitingForAcceptance() {
        let (repo, _) = makeRepo()
        repo.save(makeState(stage: RiderStage.waitingForAcceptance.rawValue))
        #expect(repo.load() != nil)
    }

    @Test func loadAcceptsDriverAccepted() {
        let (repo, _) = makeRepo()
        repo.save(makeState(stage: RiderStage.driverAccepted.rawValue))
        #expect(repo.load() != nil)
    }

    @Test func loadAcceptsEnRoute() {
        let (repo, _) = makeRepo()
        repo.save(makeState(stage: RiderStage.enRoute.rawValue))
        #expect(repo.load() != nil)
    }

    // MARK: - Expiration

    @Test func waitingForAcceptanceExpiresAtExactBoundary() {
        let (repo, _) = makeRepo()
        let now = Date.now
        let savedAt = Int(now.timeIntervalSince1970) - Int(RideConstants.broadcastTimeoutSeconds)
        repo.save(makeState(stage: RiderStage.waitingForAcceptance.rawValue, savedAt: savedAt))
        #expect(repo.load(now: now) == nil)  // age == window → expired (strict less-than)
    }

    @Test func waitingForAcceptanceSurvivesOneSecondBeforeBoundary() {
        let (repo, _) = makeRepo()
        let now = Date.now
        let savedAt = Int(now.timeIntervalSince1970) - Int(RideConstants.broadcastTimeoutSeconds) + 1
        repo.save(makeState(stage: RiderStage.waitingForAcceptance.rawValue, savedAt: savedAt))
        #expect(repo.load(now: now) != nil)  // age == window - 1 → alive
    }

    @Test func waitingForAcceptanceSurvivesWithinWindow() {
        let (repo, _) = makeRepo()
        let now = Date.now
        let recent = Int(now.timeIntervalSince1970) - 60
        repo.save(makeState(stage: RiderStage.waitingForAcceptance.rawValue, savedAt: recent))
        #expect(repo.load(now: now) != nil)
    }

    @Test func driverAcceptedExpiresAtWindow() {
        let (repo, _) = makeRepo()
        let now = Date.now
        let past = Int(now.timeIntervalSince1970) - Int(RideConstants.confirmationTimeoutSeconds) - 1
        repo.save(makeState(stage: RiderStage.driverAccepted.rawValue, savedAt: past))
        #expect(repo.load(now: now) == nil)
    }

    @Test func postConfirmationExpiresAtEightHours() {
        let (repo, _) = makeRepo()
        let now = Date.now
        let past = Int(now.timeIntervalSince1970) - (8 * 3600 + 1)
        repo.save(makeState(stage: RiderStage.enRoute.rawValue, savedAt: past))
        #expect(repo.load(now: now) == nil)
    }

    @Test func postConfirmationSurvivesWithinWindow() {
        let (repo, _) = makeRepo()
        let now = Date.now
        let recent = Int(now.timeIntervalSince1970) - (4 * 3600)
        repo.save(makeState(stage: RiderStage.enRoute.rawValue, savedAt: recent))
        #expect(repo.load(now: now) != nil)
    }

    @Test func customPolicyOverridesDefaults() {
        let policy = RideStateRestorationPolicy(
            waitingForAcceptance: 10, driverAccepted: 5, postConfirmation: 60
        )
        let (repo, _) = makeRepo(policy: policy)
        let now = Date.now
        let past = Int(now.timeIntervalSince1970) - 11
        repo.save(makeState(stage: RiderStage.waitingForAcceptance.rawValue, savedAt: past))
        #expect(repo.load(now: now) == nil)
    }

    @Test func expirationClearsPersistence() {
        let (repo, persistence) = makeRepo()
        let now = Date.now
        let past = Int(now.timeIntervalSince1970) - 200
        repo.save(makeState(stage: RiderStage.waitingForAcceptance.rawValue, savedAt: past))
        _ = repo.load(now: now)
        #expect(persistence.loadRaw() == nil)
    }

    @Test func unknownStageIsRejected() {
        let (repo, persistence) = makeRepo()
        repo.save(makeState(stage: "corrupt_garbage"))
        #expect(repo.load() == nil)
        #expect(persistence.loadRaw() == nil)
    }

    @Test func idleRejectionClearsPersistence() {
        let (repo, persistence) = makeRepo()
        repo.save(makeState(stage: RiderStage.idle.rawValue))
        _ = repo.load()
        #expect(persistence.loadRaw() == nil)
    }

    // MARK: - Legacy migration

    @Test func migratesLegacyPinTimestamps() {
        let (repo, _) = makeRepo()
        repo.save(makeState(
            processedPinActionKeys: nil,
            processedPinTimestamps: [1000, 2000, 3000]
        ))
        let loaded = repo.load()
        #expect(loaded?.processedPinActionKeys == ["pin_submit:1000", "pin_submit:2000", "pin_submit:3000"])
    }

    @Test func preservesExistingPinActionKeys() {
        let (repo, _) = makeRepo()
        repo.save(makeState(
            processedPinActionKeys: ["existing_key"],
            processedPinTimestamps: [9999]
        ))
        let loaded = repo.load()
        #expect(loaded?.processedPinActionKeys == ["existing_key"])
    }

    @Test func noMigrationWhenBothNil() {
        let (repo, _) = makeRepo()
        repo.save(makeState())
        let loaded = repo.load()
        #expect(loaded?.processedPinActionKeys == nil)
    }
}

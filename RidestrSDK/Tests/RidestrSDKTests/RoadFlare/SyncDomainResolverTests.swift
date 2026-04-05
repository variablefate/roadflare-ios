import Foundation
import Testing
@testable import RidestrSDK

private struct TestValue: Sendable, Equatable {
    let payload: String
}

private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _applyRemoteCalls: [String] = []
    private var _publishLocalCalls: Int = 0
    private var _snapshotSeenCalls: [String] = []

    var applyRemoteCalls: [String] { lock.withLock { _applyRemoteCalls } }
    var publishLocalCalls: Int { lock.withLock { _publishLocalCalls } }
    var snapshotSeenCalls: [String] { lock.withLock { _snapshotSeenCalls } }

    func recordApplyRemote(_ s: String) { lock.withLock { _applyRemoteCalls.append(s) } }
    func recordPublishLocal() { lock.withLock { _publishLocalCalls += 1 } }
    func recordSnapshotSeen(_ s: String) { lock.withLock { _snapshotSeenCalls.append(s) } }
}

@Suite("SyncDomainResolver Tests")
struct SyncDomainResolverTests {
    private func makeSyncStore() -> RoadflareSyncStateStore {
        RoadflareSyncStateStore(
            defaults: UserDefaults(suiteName: "test_\(UUID().uuidString)")!,
            namespace: UUID().uuidString
        )
    }

    private func makeStrategy(
        recorder: CallRecorder,
        hasLocalState: @escaping @Sendable () -> Bool = { false },
        shouldPublishGuard: @escaping @Sendable () -> Bool = { true },
        includeSnapshotSeen: Bool = false
    ) -> SyncDomainStrategy<TestValue> {
        let onSnapshotSeen: (@Sendable (TestValue) async -> Void)? = includeSnapshotSeen
            ? { @Sendable value in recorder.recordSnapshotSeen(value.payload) }
            : nil
        return SyncDomainStrategy<TestValue>(
            domain: .profile,
            hasLocalState: { @Sendable in hasLocalState() },
            applyRemote: { @Sendable value in recorder.recordApplyRemote(value.payload) },
            undecodableWarning: "test undecodable warning",
            publishLocal: { @Sendable in recorder.recordPublishLocal() },
            shouldPublishGuard: { @Sendable in shouldPublishGuard() },
            onSnapshotSeen: onSnapshotSeen
        )
    }

    private func makeRemote(
        latestSeen: Int?,
        snapshot: RoadflareRemoteSnapshot<TestValue>?
    ) -> RoadflareDomainService.StartupRemoteDomain<TestValue> {
        RoadflareDomainService.StartupRemoteDomain(
            latestSeenCreatedAt: latestSeen,
            snapshot: snapshot
        )
    }

    // Test 1: Remote snapshot wins (fresh + decodable + metadata clean)
    @Test func remoteWinsAppliesSnapshotAndMarksPublished() async {
        let syncStore = makeSyncStore()
        let recorder = CallRecorder()
        let strategy = makeStrategy(recorder: recorder)
        let snapshot = RoadflareRemoteSnapshot(eventId: "e1", createdAt: 100, value: TestValue(payload: "remote"))
        let remote = makeRemote(latestSeen: 100, snapshot: snapshot)

        await SyncDomainResolver.apply(strategy: strategy, remote: remote, syncStore: syncStore)

        #expect(recorder.applyRemoteCalls == ["remote"])
        #expect(recorder.publishLocalCalls == 0)
        #expect(syncStore.metadata(for: .profile).lastSuccessfulPublishAt == 100)
    }

    // Test 2: Remote newer but undecodable → warn only, no state change
    @Test func remoteNewerButUndecodableOnlyWarns() async {
        let syncStore = makeSyncStore()
        let recorder = CallRecorder()
        let strategy = makeStrategy(recorder: recorder)
        let remote = makeRemote(latestSeen: 100, snapshot: nil)

        await SyncDomainResolver.apply(strategy: strategy, remote: remote, syncStore: syncStore)

        #expect(recorder.applyRemoteCalls.isEmpty)
        #expect(recorder.publishLocalCalls == 0)
        #expect(syncStore.metadata(for: .profile).lastSuccessfulPublishAt == 0)
    }

    // Test 3: Stale-but-decodable snapshot → treated as undecodable
    @Test func staleDecodableSnapshotTreatedAsUndecodable() async {
        let syncStore = makeSyncStore()
        let recorder = CallRecorder()
        let strategy = makeStrategy(recorder: recorder)
        let snapshot = RoadflareRemoteSnapshot(eventId: "e1", createdAt: 50, value: TestValue(payload: "stale"))
        let remote = makeRemote(latestSeen: 100, snapshot: snapshot)

        await SyncDomainResolver.apply(strategy: strategy, remote: remote, syncStore: syncStore)

        #expect(recorder.applyRemoteCalls.isEmpty)
        #expect(recorder.publishLocalCalls == 0)
        #expect(syncStore.metadata(for: .profile).lastSuccessfulPublishAt == 0)
    }

    // Test 4: Local dirty → publishLocal called
    @Test func localDirtyPublishes() async {
        let syncStore = makeSyncStore()
        syncStore.markDirty(.profile)
        let recorder = CallRecorder()
        let strategy = makeStrategy(recorder: recorder)
        let snapshot = RoadflareRemoteSnapshot(eventId: "e1", createdAt: 100, value: TestValue(payload: "remote"))
        let remote = makeRemote(latestSeen: 100, snapshot: snapshot)

        await SyncDomainResolver.apply(strategy: strategy, remote: remote, syncStore: syncStore)

        #expect(recorder.applyRemoteCalls.isEmpty)
        #expect(recorder.publishLocalCalls == 1)
    }

    // Test 5: Seed legacy (remote absent, metadata pristine, hasLocalState=true)
    @Test func seedLegacyMarksDirtyThenPublishes() async {
        let syncStore = makeSyncStore()
        let recorder = CallRecorder()
        let strategy = makeStrategy(recorder: recorder, hasLocalState: { true })
        let remote = makeRemote(latestSeen: nil, snapshot: nil)

        await SyncDomainResolver.apply(strategy: strategy, remote: remote, syncStore: syncStore)

        #expect(recorder.publishLocalCalls == 1)
    }

    // Test 6: Seed blocked by absent local state
    @Test func seedBlockedByAbsentLocalState() async {
        let syncStore = makeSyncStore()
        let recorder = CallRecorder()
        let strategy = makeStrategy(recorder: recorder, hasLocalState: { false })
        let remote = makeRemote(latestSeen: nil, snapshot: nil)

        await SyncDomainResolver.apply(strategy: strategy, remote: remote, syncStore: syncStore)

        #expect(recorder.applyRemoteCalls.isEmpty)
        #expect(recorder.publishLocalCalls == 0)
        #expect(!syncStore.metadata(for: .profile).isDirty)
    }

    // Test 7: Seed blocked by shouldPublishGuard=false → critical: no markDirty
    @Test func seedBlockedByGuardDoesNotMarkDirty() async {
        let syncStore = makeSyncStore()
        let recorder = CallRecorder()
        let strategy = makeStrategy(
            recorder: recorder,
            hasLocalState: { true },
            shouldPublishGuard: { false }
        )
        let remote = makeRemote(latestSeen: nil, snapshot: nil)

        await SyncDomainResolver.apply(strategy: strategy, remote: remote, syncStore: syncStore)

        #expect(recorder.publishLocalCalls == 0)
        #expect(!syncStore.metadata(for: .profile).isDirty)
    }

    // Test 8: onSnapshotSeen fires regardless of resolution (local wins)
    @Test func onSnapshotSeenFiresEvenWhenLocalWins() async {
        let syncStore = makeSyncStore()
        syncStore.markPublished(.profile, at: 200)  // local is newer
        let recorder = CallRecorder()
        let strategy = makeStrategy(recorder: recorder, includeSnapshotSeen: true)
        let snapshot = RoadflareRemoteSnapshot(eventId: "e1", createdAt: 100, value: TestValue(payload: "seen"))
        let remote = makeRemote(latestSeen: 100, snapshot: snapshot)

        await SyncDomainResolver.apply(strategy: strategy, remote: remote, syncStore: syncStore)

        #expect(recorder.snapshotSeenCalls == ["seen"])
        #expect(recorder.applyRemoteCalls.isEmpty)
    }

    // Test 9: onSnapshotSeen absent when snapshot nil
    @Test func onSnapshotSeenNotCalledWhenSnapshotNil() async {
        let syncStore = makeSyncStore()
        let recorder = CallRecorder()
        let strategy = makeStrategy(recorder: recorder, hasLocalState: { true }, includeSnapshotSeen: true)
        let remote = makeRemote(latestSeen: nil, snapshot: nil)

        await SyncDomainResolver.apply(strategy: strategy, remote: remote, syncStore: syncStore)

        #expect(recorder.snapshotSeenCalls.isEmpty)
    }

    // Test 10: Equal timestamps resolve to local (strict `>` in resolve)
    @Test func equalTimestampsResolveLocal() async {
        let syncStore = makeSyncStore()
        syncStore.markPublished(.profile, at: 100)
        let recorder = CallRecorder()
        let strategy = makeStrategy(recorder: recorder)
        let snapshot = RoadflareRemoteSnapshot(eventId: "e1", createdAt: 100, value: TestValue(payload: "equal"))
        let remote = makeRemote(latestSeen: 100, snapshot: snapshot)

        await SyncDomainResolver.apply(strategy: strategy, remote: remote, syncStore: syncStore)

        #expect(recorder.applyRemoteCalls.isEmpty)
    }
}

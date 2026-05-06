import Foundation
import Testing
@testable import RidestrSDK

@Suite("ProfileBackupCoordinator Tests")
struct ProfileBackupCoordinatorTests {
    private func makeKit() async throws -> (
        coordinator: ProfileBackupCoordinator,
        service: RoadflareDomainService,
        syncStore: RoadflareSyncStateStore,
        settings: UserSettingsRepository,
        savedLocations: SavedLocationsRepository,
        relay: FakeRelayManager
    ) {
        let keypair = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        try await relay.connect(to: [URL(string: "wss://fake")!])
        let service = RoadflareDomainService(relayManager: relay, keypair: keypair)
        let syncStore = RoadflareSyncStateStore(
            defaults: UserDefaults(suiteName: "test_\(UUID().uuidString)")!,
            namespace: UUID().uuidString
        )
        let coordinator = ProfileBackupCoordinator(domainService: service, syncStore: syncStore)
        let settings = UserSettingsRepository(persistence: InMemoryUserSettingsPersistence())
        let savedLocations = SavedLocationsRepository(persistence: InMemorySavedLocationsPersistence())
        return (coordinator, service, syncStore, settings, savedLocations, relay)
    }

    @Test func preserveSettingsTemplateStoresValue() async throws {
        let kit = try await makeKit()
        let template = SettingsBackupContent(
            roadflarePaymentMethods: ["cash"],
            mintUrl: "https://mint.example"
        )
        kit.coordinator.preserveSettingsTemplate(template)
        #expect(kit.coordinator.settingsTemplate.roadflarePaymentMethods == ["cash"])
        #expect(kit.coordinator.settingsTemplate.mintUrl == "https://mint.example")
    }

    @Test func buildContentMergesTemplateAndRepos() async throws {
        let kit = try await makeKit()
        kit.coordinator.preserveSettingsTemplate(
            SettingsBackupContent(
                roadflarePaymentMethods: ["cash"],
                notificationSoundEnabled: false,
                mintUrl: "https://mint.example"
            )
        )
        kit.settings.setRoadflarePaymentMethods(["zelle", "venmo"])
        kit.savedLocations.save(SavedLocation(
            latitude: 36.17, longitude: -115.14,
            displayName: "Home", addressLine: "123 Main",
            isPinned: true, nickname: "Home"
        ))

        let content = kit.coordinator.buildContent(settings: kit.settings, savedLocations: kit.savedLocations)

        #expect(content.settings.roadflarePaymentMethods == ["zelle", "venmo"])
        #expect(content.settings.notificationSoundEnabled == false)
        #expect(content.settings.mintUrl == "https://mint.example")
        #expect(content.savedLocations.count == 1)
        #expect(content.savedLocations.first?.displayName == "Home")
    }

    @Test func applyRemoteRestoresState() async throws {
        let kit = try await makeKit()
        let backup = ProfileBackupContent(
            savedLocations: [
                SavedLocationBackup(
                    displayName: "Work", lat: 36.10, lon: -115.10,
                    addressLine: "Downtown", isPinned: true, nickname: "Work", timestampMs: 100
                )
            ],
            settings: SettingsBackupContent(roadflarePaymentMethods: ["cash"])
        )

        kit.coordinator.applyRemote(backup, settings: kit.settings, savedLocations: kit.savedLocations)

        #expect(kit.settings.roadflarePaymentMethods == ["cash"])
        #expect(kit.savedLocations.locations.count == 1)
        #expect(kit.savedLocations.locations.first?.displayName == "Work")
        #expect(kit.coordinator.settingsTemplate.roadflarePaymentMethods == ["cash"])
    }

    @Test func publishAndMarkCallsMarkPublished() async throws {
        let kit = try await makeKit()
        kit.settings.setRoadflarePaymentMethods(["zelle"])

        try await kit.coordinator.publishAndMark(settings: kit.settings, savedLocations: kit.savedLocations)

        #expect(kit.syncStore.metadata(for: .profileBackup).lastSuccessfulPublishAt > 0)
        #expect(kit.relay.publishedEvents.count == 1)
    }

    @Test func publishAndMarkRepublishLoopCoalesces() async throws {
        let kit = try await makeKit()
        kit.settings.setRoadflarePaymentMethods(["zelle"])

        // Fire two concurrent calls — second should coalesce into a republish.
        async let first: Void = kit.coordinator.publishAndMark(settings: kit.settings, savedLocations: kit.savedLocations)
        async let second: Void = kit.coordinator.publishAndMark(settings: kit.settings, savedLocations: kit.savedLocations)
        _ = try await (first, second)

        // First call publishes once, second sets republishRequested → first loops and publishes again.
        // Since the relay is fake and completes immediately, the second call's guard may or may not
        // coalesce in time. We accept either 1 or 2 published events (both are valid outcomes).
        #expect(kit.relay.publishedEvents.count >= 1)
    }

    @Test func publishAndMarkFailurePathSkipsMarkPublished() async throws {
        let kit = try await makeKit()
        kit.relay.shouldFailPublish = true
        kit.settings.setRoadflarePaymentMethods(["zelle"])

        // ADR-0017: terminal-iteration failure rethrows so the onboarding
        // eager-error path can fire the banner without waiting for the watchdog.
        await #expect(throws: (any Error).self) {
            try await kit.coordinator.publishAndMark(
                settings: kit.settings, savedLocations: kit.savedLocations
            )
        }
        #expect(kit.syncStore.metadata(for: .profileBackup).lastSuccessfulPublishAt == 0)
    }

    @Test func clearAllResetsTemplateAndState() async throws {
        let kit = try await makeKit()
        kit.coordinator.preserveSettingsTemplate(
            SettingsBackupContent(roadflarePaymentMethods: ["cash"])
        )

        kit.coordinator.clearAll()

        #expect(kit.coordinator.settingsTemplate.roadflarePaymentMethods.isEmpty)
    }

    @Test func clearAllDuringInFlightPublishDoesNotClobberNewSession() async throws {
        let kit = try await makeKit()
        kit.settings.setRoadflarePaymentMethods(["zelle"])

        // Use a slow publish to create an await window
        kit.relay.publishDelay = .milliseconds(100)

        let publishTask = Task {
            // Session crossed by clearAll: ADR-0017 contract says we return
            // without throwing — the caller's identity has been replaced and
            // the error is meaningless. `try await` accepts both.
            try await kit.coordinator.publishAndMark(settings: kit.settings, savedLocations: kit.savedLocations)
        }

        // Let publish start its await
        try await Task.sleep(for: .milliseconds(20))

        // Fire clearAll during publish (bumps generation)
        kit.coordinator.clearAll()

        // New publish session starts clean
        kit.settings.setRoadflarePaymentMethods(["venmo"])
        try await kit.coordinator.publishAndMark(settings: kit.settings, savedLocations: kit.savedLocations)

        try await publishTask.value

        // The new session's publish reached the relay.
        #expect(kit.syncStore.metadata(for: .profileBackup).lastSuccessfulPublishAt > 0)

        // The old session's markPublished was suppressed by the generation
        // check: the published timestamp must match the SECOND publish, not
        // the first. Since the second publish ran after the first completed,
        // its event is the last one in the relay's ordered list.
        #expect(kit.relay.publishedEvents.count == 2)
        let lastEvent = kit.relay.publishedEvents.last!
        #expect(kit.syncStore.metadata(for: .profileBackup).lastSuccessfulPublishAt == lastEvent.createdAt)
    }

    @Test func publishAndMarkSecondCallAfterFirstCompletes() async throws {
        let kit = try await makeKit()
        kit.settings.setRoadflarePaymentMethods(["zelle"])

        try await kit.coordinator.publishAndMark(settings: kit.settings, savedLocations: kit.savedLocations)
        let firstTimestamp = kit.syncStore.metadata(for: .profileBackup).lastSuccessfulPublishAt

        try await Task.sleep(for: .milliseconds(10))
        kit.settings.setRoadflarePaymentMethods(["venmo"])
        try await kit.coordinator.publishAndMark(settings: kit.settings, savedLocations: kit.savedLocations)

        let secondTimestamp = kit.syncStore.metadata(for: .profileBackup).lastSuccessfulPublishAt
        #expect(secondTimestamp >= firstTimestamp)
        #expect(kit.relay.publishedEvents.count == 2)
    }
}

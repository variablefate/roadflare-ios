import Foundation
import Testing
@testable import RidestrSDK

@Suite("RemoteConfigManager Tests")
struct RemoteConfigManagerTests {
    @Test func defaultConfigWhenNoRelayData() async {
        let fake = FakeRelayManager()
        let manager = RemoteConfigManager(relayManager: fake)
        let config = await manager.getCachedOrDefault()
        #expect(config.fareRateUsdPerMile == AdminConstants.defaultFareRateUsdPerMile)
        #expect(config.minimumFareUsd == AdminConstants.defaultMinimumFareUsd)
    }

    @Test func fetchConfigFromRelay() async throws {
        let fake = FakeRelayManager()
        try await fake.connect(to: DefaultRelays.all)

        // Simulate a Kind 30182 event from the admin
        let configJSON = """
        {"fare_rate_usd_per_mile":0.75,"minimum_fare_usd":2.00,\
        "roadflare_fare_rate_usd_per_mile":0.60,"roadflare_minimum_fare_usd":1.50,\
        "recommended_mints":[{"name":"TestMint","url":"https://mint.test","description":"Test","recommended":true}]}
        """
        let event = NostrEvent(
            id: "config1",
            pubkey: AdminConstants.adminPubkey,
            createdAt: 1700000000,
            kind: EventKind.remoteConfig.rawValue,
            tags: [["d", "ridestr-admin-config"]],
            content: configJSON,
            sig: "sig"
        )
        fake.fetchResults = [event]

        let manager = RemoteConfigManager(relayManager: fake)
        let config = await manager.fetchConfig()
        #expect(config.fareRateUsdPerMile == 0.75)
        #expect(config.minimumFareUsd == 2.00)
        #expect(config.roadflareFareRateUsdPerMile == 0.60)
        #expect(config.recommendedMints.count == 1)
        #expect(config.recommendedMints[0].name == "TestMint")
    }

    @Test func fetchConfigFromWrongPubkeyIgnored() async throws {
        let fake = FakeRelayManager()
        try await fake.connect(to: DefaultRelays.all)

        let event = NostrEvent(
            id: "config1",
            pubkey: "wrong_pubkey_not_admin",
            createdAt: 1700000000,
            kind: EventKind.remoteConfig.rawValue,
            tags: [],
            content: "{\"fare_rate_usd_per_mile\":999}",
            sig: "sig"
        )
        fake.fetchResults = [event]

        let manager = RemoteConfigManager(relayManager: fake)
        let config = await manager.fetchConfig()
        // Should fall back to defaults, not the spoofed config
        #expect(config.fareRateUsdPerMile == AdminConstants.defaultFareRateUsdPerMile)
    }

    @Test func mostRecentConfigWins() async throws {
        let fake = FakeRelayManager()
        try await fake.connect(to: DefaultRelays.all)

        let oldEvent = NostrEvent(
            id: "old", pubkey: AdminConstants.adminPubkey, createdAt: 1700000000,
            kind: EventKind.remoteConfig.rawValue, tags: [],
            content: "{\"fare_rate_usd_per_mile\":0.50,\"minimum_fare_usd\":1.50,\"roadflare_fare_rate_usd_per_mile\":0.40,\"roadflare_minimum_fare_usd\":1.00,\"recommended_mints\":[]}", sig: "sig"
        )
        let newEvent = NostrEvent(
            id: "new", pubkey: AdminConstants.adminPubkey, createdAt: 1700001000,
            kind: EventKind.remoteConfig.rawValue, tags: [],
            content: "{\"fare_rate_usd_per_mile\":0.80,\"minimum_fare_usd\":2.50,\"roadflare_fare_rate_usd_per_mile\":0.65,\"roadflare_minimum_fare_usd\":2.00,\"recommended_mints\":[]}", sig: "sig"
        )
        fake.fetchResults = [oldEvent, newEvent]

        let manager = RemoteConfigManager(relayManager: fake)
        let config = await manager.fetchConfig()
        #expect(config.fareRateUsdPerMile == 0.80)  // Newer event wins
        #expect(config.minimumFareUsd == 2.50)
    }

    @Test func cacheRetainedAfterFetch() async throws {
        let fake = FakeRelayManager()
        try await fake.connect(to: DefaultRelays.all)

        let event = NostrEvent(
            id: "c1", pubkey: AdminConstants.adminPubkey, createdAt: 1700000000,
            kind: EventKind.remoteConfig.rawValue, tags: [],
            content: "{\"fare_rate_usd_per_mile\":0.90,\"minimum_fare_usd\":3.00,\"roadflare_fare_rate_usd_per_mile\":0.70,\"roadflare_minimum_fare_usd\":2.50,\"recommended_mints\":[]}", sig: "sig"
        )
        fake.fetchResults = [event]

        let manager = RemoteConfigManager(relayManager: fake)
        _ = await manager.fetchConfig()

        // Clear relay results — cache should still work
        fake.fetchResults = []
        let cached = await manager.getCachedOrDefault()
        #expect(cached.fareRateUsdPerMile == 0.90)
    }

    @Test func clearCache() async throws {
        let fake = FakeRelayManager()
        try await fake.connect(to: DefaultRelays.all)

        let event = NostrEvent(
            id: "c1", pubkey: AdminConstants.adminPubkey, createdAt: 1700000000,
            kind: EventKind.remoteConfig.rawValue, tags: [],
            content: "{\"fare_rate_usd_per_mile\":0.90,\"minimum_fare_usd\":3.00,\"roadflare_fare_rate_usd_per_mile\":0.70,\"roadflare_minimum_fare_usd\":2.50,\"recommended_mints\":[]}", sig: "sig"
        )
        fake.fetchResults = [event]

        let manager = RemoteConfigManager(relayManager: fake)
        _ = await manager.fetchConfig()
        await manager.clearCache()
        let config = await manager.getCachedOrDefault()
        #expect(config.fareRateUsdPerMile == AdminConstants.defaultFareRateUsdPerMile)
    }

    @Test func adminConfigToFareConfig() {
        let config = AdminConfig(
            roadflareFareRateUsdPerMile: 0.55,
            roadflareMinimumFareUsd: 1.25
        )
        let fareConfig = config.toFareConfig()
        #expect(fareConfig.rateUsdPerMile == 0.55)
        #expect(fareConfig.minimumFareUsd == 1.25)
    }

    @Test func adminConfigCodable() throws {
        let json = """
        {"fare_rate_usd_per_mile":0.50,"minimum_fare_usd":1.50,\
        "roadflare_fare_rate_usd_per_mile":0.40,"roadflare_minimum_fare_usd":1.00,\
        "recommended_mints":[]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AdminConfig.self, from: json)
        #expect(decoded.fareRateUsdPerMile == 0.50)
        #expect(decoded.recommendedMints.isEmpty)
    }

    @Test func malformedConfigFallsBackToDefault() async throws {
        let fake = FakeRelayManager()
        try await fake.connect(to: DefaultRelays.all)

        // Malformed JSON in content
        let event = NostrEvent(
            id: "c1", pubkey: AdminConstants.adminPubkey, createdAt: 1700000000,
            kind: EventKind.remoteConfig.rawValue, tags: [],
            content: "this is not json", sig: "sig"
        )
        fake.fetchResults = [event]

        let manager = RemoteConfigManager(relayManager: fake)
        let config = await manager.fetchConfig()
        #expect(config.fareRateUsdPerMile == AdminConstants.defaultFareRateUsdPerMile)
    }
}

import Foundation
import Testing
@testable import RidestrSDK

/// Tests for SDK public methods that had zero direct test coverage.
@Suite("Uncovered Method Tests")
struct UncoveredMethodTests {

    // MARK: - NostrFilter Builder Methods

    @Test func rawKindsFilter() {
        let filter = NostrFilter().rawKinds([3173, 3174, 3175])
        #expect(filter.kinds == [3173, 3174, 3175])
    }

    @Test func sinceTimestampFilter() {
        let filter = NostrFilter().sinceTimestamp(1700000000)
        #expect(filter.since == 1700000000)
    }

    @Test func untilFilter() {
        let now = Date()
        let filter = NostrFilter().until(now)
        #expect(filter.until == Int(now.timeIntervalSince1970))
    }

    // MARK: - KeyManager.refresh()

    @Test func keyManagerRefresh() async throws {
        let storage = FakeKeychainStorage()
        let manager = KeyManager(storage: storage)

        // No keys initially
        let hasKeysInitially = await manager.hasKeys
        #expect(!hasKeysInitially)

        // Generate a key
        let kp = try await manager.generate()

        // Manually wipe in-memory state by creating a new manager
        let manager2 = KeyManager(storage: storage)
        // refresh should reload from storage
        await manager2.refresh()
        let loaded = await manager2.getKeypair()
        #expect(loaded?.publicKeyHex == kp.publicKeyHex)
    }

    // MARK: - RemoteConfigManager

    @Test func getConfigFetchesIfNotCached() async {
        let fake = FakeRelayManager()
        let configJSON = """
        {"fare_rate_usd_per_mile":0.60,"minimum_fare_usd":2.00,"roadflare_fare_rate_usd_per_mile":0.50,"roadflare_minimum_fare_usd":1.50,"recommended_mints":[]}
        """
        fake.fetchResults = [NostrEvent(
            id: "c1", pubkey: AdminConstants.adminPubkey, createdAt: 1700000000,
            kind: EventKind.remoteConfig.rawValue, tags: [],
            content: configJSON, sig: "sig"
        )]

        let manager = RemoteConfigManager(relayManager: fake)
        let config = await manager.getConfig()
        #expect(config.fareRateUsdPerMile == 0.60)
    }

    @Test func remoteConfigManagerClearCache() async {
        let fake = FakeRelayManager()
        let configJSON = """
        {"fare_rate_usd_per_mile":0.90,"minimum_fare_usd":3.00,"roadflare_fare_rate_usd_per_mile":0.70,"roadflare_minimum_fare_usd":2.50,"recommended_mints":[]}
        """
        fake.fetchResults = [NostrEvent(
            id: "c1", pubkey: AdminConstants.adminPubkey, createdAt: 1700000000,
            kind: EventKind.remoteConfig.rawValue, tags: [],
            content: configJSON, sig: "sig"
        )]

        let manager = RemoteConfigManager(relayManager: fake)
        _ = await manager.fetchConfig()
        let cached = await manager.getCachedOrDefault()
        #expect(cached.fareRateUsdPerMile == 0.90)

        await manager.clearCache()
        let afterClear = await manager.getCachedOrDefault()
        #expect(afterClear.fareRateUsdPerMile == AdminConstants.defaultFareRateUsdPerMile)
    }

    // MARK: - RideStateMachine.addRiderAction Direct Test

    @Test func addRiderActionDirectly() {
        let sm = RideStateMachine()
        #expect(sm.riderStateHistory.isEmpty)

        let a1 = RiderRideAction(type: "location_reveal", at: 100,
            locationType: "pickup", locationEncrypted: "enc", status: nil, attempt: nil)
        sm.addRiderAction(a1)
        #expect(sm.riderStateHistory.count == 1)
        #expect(sm.riderStateHistory[0].isLocationReveal)

        let a2 = RiderRideAction(type: "pin_verify", at: 200,
            locationType: nil, locationEncrypted: nil, status: "verified", attempt: 1)
        sm.addRiderAction(a2)
        #expect(sm.riderStateHistory.count == 2)
        #expect(sm.riderStateHistory[1].isPinVerified)

        let a3 = RiderRideAction(type: "pin_verify", at: 300,
            locationType: nil, locationEncrypted: nil, status: "rejected", attempt: 2)
        sm.addRiderAction(a3)
        #expect(sm.riderStateHistory.count == 3)
        #expect(!sm.riderStateHistory[2].isPinVerified)
    }

    // MARK: - RideshareEventParser Direct Tests for parseAcceptance and parseDriverRideState

    @Test func parseAcceptanceDirectly() async throws {
        let driver = try NostrKeypair.generate()
        let rider = try NostrKeypair.generate()

        let json = """
        {"status":"accepted","wallet_pubkey":"wallet_hex","payment_method":"venmo","mint_url":null}
        """
        let encrypted = try NIP44.encrypt(
            plaintext: json,
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: rider.publicKeyHex
        )
        let event = NostrEvent(
            id: "acc1", pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.rideAcceptance.rawValue,
            tags: [["e", "offer1"], ["p", rider.publicKeyHex]],
            content: encrypted, sig: "sig"
        )

        let parsed = try RideshareEventParser.parseAcceptance(event: event, keypair: rider)
        #expect(parsed.status == "accepted")
        #expect(parsed.walletPubkey == "wallet_hex")
        #expect(parsed.paymentMethod == "venmo")
    }

    @Test func parseDriverRideStateDirectly() async throws {
        let driver = try NostrKeypair.generate()
        let rider = try NostrKeypair.generate()

        let json = """
        {"current_status":"in_progress","history":[{"action":"status","at":100,"status":"in_progress","approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":null}]}
        """
        let encrypted = try NIP44.encrypt(
            plaintext: json,
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: rider.publicKeyHex
        )
        let event = NostrEvent(
            id: "ds1", pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.driverRideState.rawValue,
            tags: [["d", "conf1"]],
            content: encrypted, sig: "sig"
        )

        let parsed = try RideshareEventParser.parseDriverRideState(event: event, keypair: rider)
        #expect(parsed.currentStatus == "in_progress")
        #expect(parsed.history.count == 1)
        #expect(parsed.history[0].isStatusAction)
    }

    // MARK: - KeychainStorage.exists()

    @Test func keychainStorageExists() throws {
        let storage = FakeKeychainStorage()
        #expect(try !storage.exists(for: "missing"))
        try storage.save(data: "test".data(using: .utf8)!, for: "key1")
        #expect(try storage.exists(for: "key1"))
        try storage.delete(for: "key1")
        #expect(try !storage.exists(for: "key1"))
    }

    // MARK: - EventSigner toRustEvent/fromRustEvent directly

    @Test func eventSignerConversionRoundtrip() async throws {
        let kp = try NostrKeypair.generate()
        let event = try await EventSigner.sign(
            kind: .rideOffer,
            content: "test",
            tags: [["p", "abc"], ["t", "rideshare"], ["d", "test-d"], ["g", "dr5ru"]],
            keypair: kp
        )

        let rustEvent = try EventSigner.toRustEvent(event)
        let restored = try EventSigner.fromRustEvent(rustEvent)

        #expect(restored.id == event.id)
        #expect(restored.pubkey == event.pubkey)
        #expect(restored.kind == event.kind)
        #expect(restored.content == event.content)
        #expect(restored.sig == event.sig)
        #expect(restored.createdAt == event.createdAt)
        #expect(restored.tags.count == event.tags.count)
    }

    // MARK: - Geohash all precision levels

    @Test func geohashAllPrecisionLevels() {
        let lat = 40.7128
        let lon = -74.0060

        for precision in 1...12 {
            let gh = Geohash(latitude: lat, longitude: lon, precision: precision)
            #expect(gh.hash.count == precision)
            // Each shorter hash should be a prefix of longer ones
            if precision > 1 {
                let shorter = Geohash(latitude: lat, longitude: lon, precision: precision - 1)
                #expect(gh.hash.hasPrefix(shorter.hash))
            }
        }
    }

    // MARK: - Location edge cases

    @Test func locationDistanceAntipodal() {
        let nyc = Location(latitude: 40.7128, longitude: -74.0060)
        let sydney = Location(latitude: -33.8688, longitude: 151.2093)
        let dist = nyc.distance(to: sydney)
        // NYC to Sydney is roughly 16,000 km
        #expect(dist > 15000 && dist < 17000)
    }

    @Test func locationApproximateNegativeCoords() {
        let loc = Location(latitude: -33.86, longitude: 151.21)
        let approx = loc.approximate()
        #expect(approx.latitude == -33.86)
        #expect(approx.longitude == 151.21)
    }
}

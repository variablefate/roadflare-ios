import Foundation
import Testing
@testable import RidestrSDK

@Suite("Constants Tests")
struct ConstantsTests {
    @Test func relayTimeouts() {
        #expect(RelayConstants.connectTimeoutSeconds == 10)
        #expect(RelayConstants.eoseTimeoutSeconds == 8)
        #expect(RelayConstants.reconnectBaseDelaySeconds == 5)
        #expect(RelayConstants.reconnectMaxDelaySeconds == 60)
        #expect(RelayConstants.maxRelays == 10)
    }

    @Test func rideConstants() {
        #expect(RideConstants.pinDigits == 4)
        #expect(RideConstants.maxPinAttempts == 3)
        #expect(RideConstants.confirmationTimeoutSeconds == 30)
        #expect(RideConstants.batchSize == 3)
        #expect(RideConstants.batchDelaySeconds == 15)
        #expect(RideConstants.acceptanceTimeoutSeconds == 15)
        #expect(RideConstants.nip33OrderingDelaySeconds == 1.1)
        #expect(RideConstants.progressiveRevealThresholdKm == 1.6)
    }

    @Test func defaultRelays() {
        #expect(DefaultRelays.all.count == 3)
        #expect(DefaultRelays.all.allSatisfy { $0.absoluteString.hasPrefix("wss://") })
    }

    @Test func adminPubkey() {
        #expect(AdminConstants.adminPubkey.count == 64)
        #expect(AdminConstants.adminPubkey == "da790ba18e63ae79b16e172907301906957a45f38ef0c9f219d0f016eaf16128")
    }

    @Test func fareDefaults() {
        #expect(AdminConstants.defaultFareRateUsdPerMile > 0)
        #expect(AdminConstants.defaultMinimumFareUsd > 0)
        #expect(AdminConstants.roadflareUIMinimumFareUsd >= AdminConstants.defaultMinimumFareUsd)
    }

    @Test func geohashPrecisions() {
        #expect(GeohashPrecision.expandedSearch == 3)
        #expect(GeohashPrecision.normalSearch == 4)
        #expect(GeohashPrecision.ride == 5)
        #expect(GeohashPrecision.history == 6)
        #expect(GeohashPrecision.settlement == 7)
    }

    @Test func storageConstants() {
        #expect(StorageConstants.maxRecentLocations == 3)
        #expect(StorageConstants.maxRideHistory == 500)
        #expect(StorageConstants.duplicateLocationThresholdMeters == 50.0)
    }

    @Test func nostrTags() {
        #expect(NostrTags.rideshareTag == "rideshare")
        #expect(NostrTags.roadflareTag == "roadflare")
        #expect(NostrTags.eventRef == "e")
        #expect(NostrTags.pubkeyRef == "p")
        #expect(NostrTags.dTag == "d")
    }
}

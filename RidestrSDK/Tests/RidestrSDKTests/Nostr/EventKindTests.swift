import Foundation
import Testing
@testable import RidestrSDK

@Suite("EventKind Tests")
struct EventKindTests {
    @Test func rawValuesMatchSpec() {
        #expect(EventKind.rideOffer.rawValue == 3173)
        #expect(EventKind.rideAcceptance.rawValue == 3174)
        #expect(EventKind.rideConfirmation.rawValue == 3175)
        #expect(EventKind.chatMessage.rawValue == 3178)
        #expect(EventKind.cancellation.rawValue == 3179)
        #expect(EventKind.keyShare.rawValue == 3186)
        #expect(EventKind.replaceableKeyShare.rawValue == 30186)
        #expect(EventKind.keyAcknowledgement.rawValue == 3188)
        #expect(EventKind.followedDriversList.rawValue == 30011)
        #expect(EventKind.driverRoadflareState.rawValue == 30012)
        #expect(EventKind.roadflareLocation.rawValue == 30014)
        #expect(EventKind.driverAvailability.rawValue == 30173)
        #expect(EventKind.rideHistoryBackup.rawValue == 30174)
        #expect(EventKind.unifiedProfile.rawValue == 30177)
        #expect(EventKind.driverRideState.rawValue == 30180)
        #expect(EventKind.riderRideState.rawValue == 30181)
        #expect(EventKind.remoteConfig.rawValue == 30182)
    }

    @Test func replaceableKinds() {
        #expect(EventKind.driverAvailability.isReplaceable)
        #expect(EventKind.followedDriversList.isReplaceable)
        #expect(EventKind.driverRideState.isReplaceable)
        #expect(EventKind.riderRideState.isReplaceable)
        #expect(EventKind.roadflareLocation.isReplaceable)
        #expect(EventKind.remoteConfig.isReplaceable)
        #expect(EventKind.replaceableKeyShare.isReplaceable)
    }

    @Test func regularKindsNotReplaceable() {
        #expect(!EventKind.rideOffer.isReplaceable)
        #expect(!EventKind.rideAcceptance.isReplaceable)
        #expect(!EventKind.chatMessage.isReplaceable)
        #expect(!EventKind.keyShare.isReplaceable)
    }

    @Test func dTagsForReplaceableEvents() {
        #expect(EventKind.driverAvailability.dTag == "rideshare-availability")
        #expect(EventKind.followedDriversList.dTag == "roadflare-drivers")
        #expect(EventKind.driverRoadflareState.dTag == "roadflare-state")
        #expect(EventKind.roadflareLocation.dTag == "roadflare-location")
        #expect(EventKind.rideHistoryBackup.dTag == "rideshare-history")
        #expect(EventKind.unifiedProfile.dTag == "rideshare-profile")
        #expect(EventKind.remoteConfig.dTag == "ridestr-admin-config")
    }

    @Test func dynamicDTagsAreNil() {
        // driverRideState and riderRideState use confirmationEventId as d-tag
        #expect(EventKind.driverRideState.dTag == nil)
        #expect(EventKind.riderRideState.dTag == nil)
    }

    @Test func expirationValues() {
        #expect(EventKind.rideOffer.defaultExpirationSeconds == TimeInterval(15 * 60))
        #expect(EventKind.rideAcceptance.defaultExpirationSeconds == TimeInterval(10 * 60))
        #expect(EventKind.rideConfirmation.defaultExpirationSeconds == TimeInterval(8 * 3600))
        #expect(EventKind.chatMessage.defaultExpirationSeconds == TimeInterval(8 * 3600))
        #expect(EventKind.cancellation.defaultExpirationSeconds == TimeInterval(24 * 3600))
        #expect(EventKind.roadflareLocation.defaultExpirationSeconds == TimeInterval(5 * 60))
        #expect(EventKind.keyShare.defaultExpirationSeconds == TimeInterval(5 * 60))
        #expect(EventKind.driverAvailability.defaultExpirationSeconds == TimeInterval(30 * 60))
    }

    @Test func noExpirationForBackups() {
        #expect(EventKind.followedDriversList.defaultExpirationSeconds == nil)
        #expect(EventKind.rideHistoryBackup.defaultExpirationSeconds == nil)
        #expect(EventKind.unifiedProfile.defaultExpirationSeconds == nil)
        #expect(EventKind.remoteConfig.defaultExpirationSeconds == nil)
        #expect(EventKind.replaceableKeyShare.defaultExpirationSeconds == nil)
    }

    @Test func replaceableKeyShareHasDynamicDTag() {
        // d-tag is the follower's pubkey (dynamic, not static)
        #expect(EventKind.replaceableKeyShare.dTag == nil)
    }
}

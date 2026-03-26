import Foundation
import Testing
@testable import RidestrSDK

@Suite("NostrFilter Tests")
struct NostrFilterTests {
    @Test func emptyFilter() {
        let filter = NostrFilter()
        #expect(filter.ids == nil)
        #expect(filter.authors == nil)
        #expect(filter.kinds == nil)
        #expect(filter.since == nil)
        #expect(filter.until == nil)
        #expect(filter.limit == nil)
        #expect(filter.tagFilters.isEmpty)
    }

    @Test func builderChaining() {
        let now = Date()
        let filter = NostrFilter()
            .kinds([.rideOffer, .rideAcceptance])
            .authors(["pubkey1", "pubkey2"])
            .pTags(["recipient"])
            .since(now)
            .limit(10)

        #expect(filter.kinds == [3173, 3174])
        #expect(filter.authors == ["pubkey1", "pubkey2"])
        #expect(filter.tagFilters["p"] == ["recipient"])
        #expect(filter.since != nil)
        #expect(filter.limit == 10)
    }

    @Test func tagFilters() {
        let filter = NostrFilter()
            .pTags(["pub1"])
            .eTags(["event1", "event2"])
            .tTags(["rideshare", "roadflare"])
            .dTags(["roadflare-drivers"])
            .gTags(["9q8yy"])

        #expect(filter.tagFilters["p"] == ["pub1"])
        #expect(filter.tagFilters["e"] == ["event1", "event2"])
        #expect(filter.tagFilters["t"] == ["rideshare", "roadflare"])
        #expect(filter.tagFilters["d"] == ["roadflare-drivers"])
        #expect(filter.tagFilters["g"] == ["9q8yy"])
    }

    @Test func rideAcceptancesConvenience() {
        let filter = NostrFilter.rideAcceptances(offerEventId: "offer123")
        #expect(filter.kinds == [EventKind.rideAcceptance.rawValue])
        #expect(filter.tagFilters["e"] == ["offer123"])
    }

    @Test func rideAcceptancesConvenienceSupportsIdentityNarrowing() {
        let filter = NostrFilter.rideAcceptances(
            offerEventId: "offer123",
            riderPubkey: "rider_pub",
            driverPubkey: "driver_pub"
        )
        #expect(filter.kinds == [EventKind.rideAcceptance.rawValue])
        #expect(filter.tagFilters["e"] == ["offer123"])
        #expect(filter.tagFilters["p"] == ["rider_pub"])
        #expect(filter.authors == ["driver_pub"])
    }

    @Test func driverRideStateConvenience() {
        let filter = NostrFilter.driverRideState(driverPubkey: "driver_pub", confirmationEventId: "conf123")
        #expect(filter.kinds == [EventKind.driverRideState.rawValue])
        #expect(filter.authors == ["driver_pub"])
        #expect(filter.tagFilters["d"] == ["conf123"])
    }

    @Test func roadflareLocationsConvenience() {
        let drivers = ["driver1", "driver2", "driver3"]
        let filter = NostrFilter.roadflareLocations(driverPubkeys: drivers)
        #expect(filter.kinds == [EventKind.roadflareLocation.rawValue])
        #expect(filter.authors == drivers)
        #expect(filter.limit == 3)
    }

    @Test func remoteConfigConvenience() {
        let filter = NostrFilter.remoteConfig()
        #expect(filter.kinds == [EventKind.remoteConfig.rawValue])
        #expect(filter.authors == [AdminConstants.adminPubkey])
        #expect(filter.tagFilters["d"] == ["ridestr-admin-config"])
        #expect(filter.limit == 1)
    }

    @Test func cancellationsConvenience() {
        let filter = NostrFilter.cancellations(counterpartyPubkey: "pub1", confirmationEventId: "conf1")
        #expect(filter.kinds == [EventKind.cancellation.rawValue])
        #expect(filter.tagFilters["p"] == ["pub1"])
        #expect(filter.tagFilters["e"] == ["conf1"])
    }

    @Test func chatMessagesConvenience() {
        let filter = NostrFilter.chatMessages(
            counterpartyPubkey: "driver1",
            myPubkey: "me",
            confirmationEventId: "conf1"
        )
        #expect(filter.kinds == [EventKind.chatMessage.rawValue])
        #expect(filter.tagFilters["p"] == ["me"])
        #expect(filter.tagFilters["e"] == ["conf1"])
    }

    @Test func keySharesConvenience() {
        let filter = NostrFilter.keyShares(myPubkey: "my_pub")
        #expect(filter.kinds == [EventKind.keyShare.rawValue])
        #expect(filter.tagFilters["p"] == ["my_pub"])
    }

    @Test func driverRoadflareStateConvenience() {
        let filter = NostrFilter.driverRoadflareState(driverPubkey: "driver_pub")
        #expect(filter.kinds == [EventKind.driverRoadflareState.rawValue])
        #expect(filter.authors == ["driver_pub"])
        #expect(filter.tagFilters["d"] == ["roadflare-state"])
        #expect(filter.limit == 1)
    }

    @Test func profileBackupConvenience() {
        let filter = NostrFilter.profileBackup(myPubkey: "my_pub")
        #expect(filter.kinds == [EventKind.unifiedProfile.rawValue])
        #expect(filter.authors == ["my_pub"])
        #expect(filter.tagFilters["d"] == ["rideshare-profile"])
        #expect(filter.limit == 1)
    }

    @Test func metadataConvenience() {
        let filter = NostrFilter.metadata(pubkeys: ["pub1", "pub2"])
        #expect(filter.kinds == [EventKind.metadata.rawValue])
        #expect(filter.authors == ["pub1", "pub2"])
        #expect(filter.limit == nil)
    }

    @Test func metadataSinglePubkey() {
        let filter = NostrFilter.metadata(pubkeys: ["pub1"])
        #expect(filter.limit == 1)
    }

    // keyShare one-shot filter removed — key persists in Kind 30011 backup

    @Test func followedDriversListConvenience() {
        let filter = NostrFilter.followedDriversList(myPubkey: "my_pub")
        #expect(filter.kinds == [EventKind.followedDriversList.rawValue])
        #expect(filter.authors == ["my_pub"])
        #expect(filter.tagFilters["d"] == ["roadflare-drivers"])
        #expect(filter.limit == 1)
    }

    @Test func riderRideStateConvenience() {
        let filter = NostrFilter.riderRideState(riderPubkey: "rider_pub", confirmationEventId: "conf1")
        #expect(filter.kinds == [EventKind.riderRideState.rawValue])
        #expect(filter.authors == ["rider_pub"])
        #expect(filter.tagFilters["d"] == ["conf1"])
    }

    @Test func customTag() {
        let filter = NostrFilter()
            .customTag("custom", values: ["val1", "val2"])
        #expect(filter.tagFilters["custom"] == ["val1", "val2"])
    }
}

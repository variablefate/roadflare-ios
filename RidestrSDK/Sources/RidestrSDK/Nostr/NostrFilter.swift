import Foundation

/// A Nostr subscription filter (NIP-01).
///
/// Uses a builder pattern for readable filter construction:
/// ```swift
/// let filter = NostrFilter()
///     .kinds([.rideAcceptance])
///     .pTags(["recipient_pubkey"])
///     .since(Date().addingTimeInterval(-600))
/// ```
public struct NostrFilter: Sendable {
    public var ids: [String]?
    public var authors: [String]?
    public var kinds: [UInt16]?
    public var since: Int?         // unix timestamp
    public var until: Int?         // unix timestamp
    public var limit: UInt32?

    // Generic tag filters: key is tag name (without #), value is list of values
    public var tagFilters: [String: [String]]

    public init() {
        self.tagFilters = [:]
    }

    // MARK: - Builder Methods

    /// Filter by specific event IDs.
    public func ids(_ ids: [String]) -> NostrFilter {
        var copy = self; copy.ids = ids; return copy
    }

    /// Filter by author public keys.
    public func authors(_ authors: [String]) -> NostrFilter {
        var copy = self; copy.authors = authors; return copy
    }

    /// Filter by event kinds (typed).
    public func kinds(_ kinds: [EventKind]) -> NostrFilter {
        var copy = self; copy.kinds = kinds.map(\.rawValue); return copy
    }

    /// Filter by raw event kind numbers.
    public func rawKinds(_ kinds: [UInt16]) -> NostrFilter {
        var copy = self; copy.kinds = kinds; return copy
    }

    /// Filter events created after the given date.
    public func since(_ date: Date) -> NostrFilter {
        var copy = self; copy.since = Int(date.timeIntervalSince1970); return copy
    }

    /// Filter events created after the given Unix timestamp.
    public func sinceTimestamp(_ timestamp: Int) -> NostrFilter {
        var copy = self; copy.since = timestamp; return copy
    }

    /// Filter events created before the given date.
    public func until(_ date: Date) -> NostrFilter {
        var copy = self; copy.until = Int(date.timeIntervalSince1970); return copy
    }

    /// Limit the number of events returned.
    public func limit(_ limit: UInt32) -> NostrFilter {
        var copy = self; copy.limit = limit; return copy
    }

    // MARK: - Tag Filter Builders

    /// Filter by referenced public keys (p-tags).
    public func pTags(_ pubkeys: [String]) -> NostrFilter {
        var copy = self; copy.tagFilters["p"] = pubkeys; return copy
    }

    /// Filter by referenced event IDs (e-tags).
    public func eTags(_ eventIds: [String]) -> NostrFilter {
        var copy = self; copy.tagFilters["e"] = eventIds; return copy
    }

    /// Filter by hashtag topics (t-tags).
    public func tTags(_ topics: [String]) -> NostrFilter {
        var copy = self; copy.tagFilters["t"] = topics; return copy
    }

    /// Filter by replaceable event identifiers (d-tags).
    public func dTags(_ identifiers: [String]) -> NostrFilter {
        var copy = self; copy.tagFilters["d"] = identifiers; return copy
    }

    /// Filter by geohash tags (g-tags).
    public func gTags(_ geohashes: [String]) -> NostrFilter {
        var copy = self; copy.tagFilters["g"] = geohashes; return copy
    }

    /// Filter by a custom tag name and values.
    public func customTag(_ name: String, values: [String]) -> NostrFilter {
        var copy = self; copy.tagFilters[name] = values; return copy
    }
}

// MARK: - Rideshare Convenience Filters

extension NostrFilter {
    /// Filter for profile backup (Kind 30177, encrypted to self).
    public static func profileBackup(myPubkey: String) -> NostrFilter {
        NostrFilter()
            .kinds([.unifiedProfile])
            .authors([myPubkey])
            .dTags(["rideshare-profile"])
            .limit(1)
    }

    /// Filter for user profile metadata (Kind 0).
    /// Limits to one event per pubkey (latest by timestamp wins).
    public static func metadata(pubkeys: [String]) -> NostrFilter {
        NostrFilter()
            .kinds([.metadata])
            .authors(pubkeys)
            .limit(UInt32(max(pubkeys.count, 1)))
    }

    /// Filter for ride acceptances targeting a specific offer.
    public static func rideAcceptances(offerEventId: String) -> NostrFilter {
        NostrFilter()
            .kinds([.rideAcceptance])
            .eTags([offerEventId])
    }

    /// Filter for driver ride state updates for a specific ride.
    public static func driverRideState(driverPubkey: String, confirmationEventId: String) -> NostrFilter {
        NostrFilter()
            .kinds([.driverRideState])
            .authors([driverPubkey])
            .dTags([confirmationEventId])
    }

    /// Filter for rider ride state updates for a specific ride.
    public static func riderRideState(riderPubkey: String, confirmationEventId: String) -> NostrFilter {
        NostrFilter()
            .kinds([.riderRideState])
            .authors([riderPubkey])
            .dTags([confirmationEventId])
    }

    /// Filter for cancellation events for a specific ride.
    public static func cancellations(counterpartyPubkey: String, confirmationEventId: String) -> NostrFilter {
        NostrFilter()
            .kinds([.cancellation])
            .pTags([counterpartyPubkey])
            .eTags([confirmationEventId])
    }

    /// Filter for chat messages for a specific ride.
    public static func chatMessages(counterpartyPubkey: String, myPubkey: String) -> NostrFilter {
        NostrFilter()
            .kinds([.chatMessage])
            .authors([counterpartyPubkey])
            .pTags([myPubkey])
    }

    /// Filter for RoadFlare location broadcasts from specific drivers.
    public static func roadflareLocations(driverPubkeys: [String]) -> NostrFilter {
        NostrFilter()
            .kinds([.roadflareLocation])
            .authors(driverPubkeys)
            .dTags(["roadflare-location"])
            .limit(UInt32(driverPubkeys.count))
    }

    /// Filter for RoadFlare key shares addressed to this user.
    /// Listens for both Kind 30186 (replaceable, preferred) and Kind 3186 (legacy)
    /// to support drivers on older Android versions that haven't updated yet.
    public static func keyShares(myPubkey: String) -> NostrFilter {
        NostrFilter()
            .kinds([.replaceableKeyShare, .keyShare])
            .pTags([myPubkey])
    }

    /// Fetch a specific driver's key share for this user (one-shot).
    /// Tries Kind 30186 first (by d-tag), falls back to Kind 3186 (by p-tag).
    public static func keyShare(driverPubkey: String, myPubkey: String) -> NostrFilter {
        NostrFilter()
            .kinds([.replaceableKeyShare, .keyShare])
            .authors([driverPubkey])
            .pTags([myPubkey])
            .limit(1)
    }

    /// Filter for followed drivers list (own backup).
    public static func followedDriversList(myPubkey: String) -> NostrFilter {
        NostrFilter()
            .kinds([.followedDriversList])
            .authors([myPubkey])
            .dTags(["roadflare-drivers"])
            .limit(1)
    }

    /// Filter for remote config from admin.
    public static func remoteConfig() -> NostrFilter {
        NostrFilter()
            .kinds([.remoteConfig])
            .authors([AdminConstants.adminPubkey])
            .dTags(["ridestr-admin-config"])
            .limit(1)
    }
}

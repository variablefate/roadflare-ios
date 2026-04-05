import Foundation

/// SDK-owned helper for RoadFlare startup sync and profile publishing.
///
/// This service keeps the relay fetch/sort/parse logic out of the app target while
/// leaving local state application to the caller.
public final class RoadflareDomainService: @unchecked Sendable {
    private let relayManager: any RelayManagerProtocol
    private let keypair: NostrKeypair
    private let fetchTimeout: TimeInterval

    public init(
        relayManager: any RelayManagerProtocol,
        keypair: NostrKeypair,
        fetchTimeout: TimeInterval = 5
    ) {
        self.relayManager = relayManager
        self.keypair = keypair
        self.fetchTimeout = fetchTimeout
    }

    // MARK: - Startup Sync Fetches

    public struct StartupRemoteState: Sendable {
        public let profile: StartupRemoteDomain<UserProfileContent>
        public let followedDrivers: StartupRemoteDomain<FollowedDriversContent>
        public let profileBackup: StartupRemoteDomain<ProfileBackupContent>
        public let rideHistory: StartupRemoteDomain<RideHistoryBackupContent>

        public init(
            profile: StartupRemoteDomain<UserProfileContent>,
            followedDrivers: StartupRemoteDomain<FollowedDriversContent>,
            profileBackup: StartupRemoteDomain<ProfileBackupContent>,
            rideHistory: StartupRemoteDomain<RideHistoryBackupContent> = StartupRemoteDomain(latestSeenCreatedAt: nil, snapshot: nil)
        ) {
            self.profile = profile
            self.followedDrivers = followedDrivers
            self.profileBackup = profileBackup
            self.rideHistory = rideHistory
        }
    }

    public struct StartupRemoteDomain<Value: Sendable>: Sendable {
        public let latestSeenCreatedAt: Int?
        public let snapshot: RoadflareRemoteSnapshot<Value>?

        public init(latestSeenCreatedAt: Int?, snapshot: RoadflareRemoteSnapshot<Value>?) {
            self.latestSeenCreatedAt = latestSeenCreatedAt
            self.snapshot = snapshot
        }
    }

    /// Fetch the latest remote RoadFlare state for startup sync.
    /// Sorts by `createdAt` and decodes the latest event for each domain.
    public func fetchStartupRemoteState() async -> StartupRemoteState {
        async let profile = fetchStartupProfileState()
        async let followedDrivers = fetchStartupFollowedDriversState()
        async let profileBackup = fetchStartupProfileBackupState()
        async let rideHistory = fetchStartupRideHistoryState()
        return await StartupRemoteState(
            profile: profile,
            followedDrivers: followedDrivers,
            profileBackup: profileBackup,
            rideHistory: rideHistory
        )
    }

    /// Fetch the latest Kind 0 profile for a set of pubkeys.
    public func fetchDriverProfiles(pubkeys: [String]) async -> [String: RoadflareRemoteSnapshot<UserProfileContent>] {
        guard !pubkeys.isEmpty else { return [:] }

        do {
            let filter = NostrFilter.metadata(pubkeys: pubkeys)
            let events = try await relayManager.fetchEvents(filter: filter, timeout: fetchTimeout + 3)
            let grouped = Dictionary(grouping: events, by: \.pubkey)
            var profiles: [String: RoadflareRemoteSnapshot<UserProfileContent>] = [:]

            for (pubkey, driverEvents) in grouped {
                guard let snapshot = latestDecodableSnapshot(in: driverEvents, parse: { event in
                    RideshareEventParser.parseMetadata(event: event)
                }) else { continue }
                profiles[pubkey] = snapshot
            }

            if !profiles.isEmpty {
                RidestrLogger.info("[RoadflareDomainService] Fetched profiles for \(profiles.count) driver(s)")
            }
            return profiles
        } catch {
            RidestrLogger.warning("[RoadflareDomainService] Driver profile fetch failed: \(error.localizedDescription)")
            return [:]
        }
    }

    @available(*, deprecated, message: "Use fetchLatestProfileState() to distinguish stale decodable data from a newer undecodable relay event.")
    public func fetchLatestProfile() async -> RoadflareRemoteSnapshot<UserProfileContent>? {
        do {
            let filter = NostrFilter.metadata(pubkeys: [keypair.publicKeyHex])
            let events = try await relayManager.fetchEvents(filter: filter, timeout: fetchTimeout)
            return latestDecodableSnapshot(in: events, parse: { event in
                RideshareEventParser.parseMetadata(event: event)
            })
        } catch {
            RidestrLogger.warning("[RoadflareDomainService] Profile fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetch the latest profile state while preserving whether a newer undecodable
    /// event exists on the relay.
    public func fetchLatestProfileState() async -> StartupRemoteDomain<UserProfileContent> {
        await fetchStartupProfileState()
    }

    @available(*, deprecated, message: "Use fetchLatestFollowedDriversState() to distinguish stale decodable data from a newer undecodable relay event.")
    public func fetchLatestFollowedDriversList() async -> RoadflareRemoteSnapshot<FollowedDriversContent>? {
        do {
            let filter = NostrFilter.followedDriversList(myPubkey: keypair.publicKeyHex)
            let events = try await relayManager.fetchEvents(filter: filter, timeout: fetchTimeout)
            return latestDecodableSnapshot(in: events, parse: { event in
                try RideshareEventParser.parseFollowedDriversList(event: event, keypair: keypair)
            })
        } catch {
            RidestrLogger.warning("[RoadflareDomainService] Followed drivers fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetch the latest followed-drivers state while preserving whether a newer
    /// undecodable event exists on the relay.
    public func fetchLatestFollowedDriversState() async -> StartupRemoteDomain<FollowedDriversContent> {
        await fetchStartupFollowedDriversState()
    }

    @available(*, deprecated, message: "Use fetchLatestProfileBackupState() to distinguish stale decodable data from a newer undecodable relay event.")
    public func fetchLatestProfileBackup() async -> RoadflareRemoteSnapshot<ProfileBackupContent>? {
        do {
            let filter = NostrFilter.profileBackup(myPubkey: keypair.publicKeyHex)
            let events = try await relayManager.fetchEvents(filter: filter, timeout: fetchTimeout)
            return latestDecodableSnapshot(in: events, parse: { event in
                try RideshareEventParser.parseProfileBackup(event: event, keypair: keypair)
            })
        } catch {
            RidestrLogger.warning("[RoadflareDomainService] Profile backup fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetch the latest profile-backup state while preserving whether a newer
    /// undecodable event exists on the relay.
    public func fetchLatestProfileBackupState() async -> StartupRemoteDomain<ProfileBackupContent> {
        await fetchStartupProfileBackupState()
    }

    // MARK: - Publish Helpers

    public func publishProfile(_ profile: UserProfileContent) async throws -> NostrEvent {
        let event = try await RideshareEventBuilder.metadata(profile: profile, keypair: keypair)
        _ = try await relayManager.publish(event)
        return event
    }

    public func publishFollowedDriversList(_ drivers: [FollowedDriver]) async throws -> NostrEvent {
        let event = try await RideshareEventBuilder.followedDriversList(drivers: drivers, keypair: keypair)
        _ = try await relayManager.publish(event)
        return event
    }

    public func publishProfileBackup(_ backup: ProfileBackupContent) async throws -> NostrEvent {
        let event = try await RideshareEventBuilder.profileBackup(content: backup, keypair: keypair)
        _ = try await relayManager.publish(event)
        return event
    }

    public func publishRideHistoryBackup(_ content: RideHistoryBackupContent) async throws -> NostrEvent {
        let event = try await RideshareEventBuilder.rideHistoryBackup(content: content, keypair: keypair)
        _ = try await relayManager.publish(event)
        return event
    }

    // MARK: - Publish-and-Mark Convenience Helpers
    //
    // Each helper: reads from its repo → builds content → publishes → marks
    // syncStore published on success. Throws swallowed by logging.

    public func publishProfileAndMark(
        from settings: UserSettingsRepository,
        syncStore: RoadflareSyncStateStore
    ) async {
        let profile = UserProfileContent(
            name: settings.profileName,
            displayName: settings.profileName
        )
        do {
            let event = try await publishProfile(profile)
            syncStore.markPublished(.profile, at: event.createdAt)
            RidestrLogger.info("[RoadflareDomainService] Published profile")
        } catch {
            RidestrLogger.info("[RoadflareDomainService] Failed to publish profile: \(error.localizedDescription)")
        }
    }

    public func publishFollowedDriversListAndMark(
        from repository: FollowedDriversRepository,
        syncStore: RoadflareSyncStateStore
    ) async {
        do {
            let event = try await publishFollowedDriversList(repository.drivers)
            syncStore.markPublished(.followedDrivers, at: event.createdAt)
            RidestrLogger.info("[RoadflareDomainService] Published followed drivers list")
        } catch {
            RidestrLogger.info("[RoadflareDomainService] Failed to publish followed drivers list: \(error.localizedDescription)")
        }
    }

    public func publishRideHistoryAndMark(
        from rideHistory: RideHistoryRepository,
        syncStore: RoadflareSyncStateStore
    ) async {
        let content = RideHistoryBackupContent(rides: rideHistory.rides)
        do {
            let event = try await publishRideHistoryBackup(content)
            syncStore.markPublished(.rideHistory, at: event.createdAt)
            RidestrLogger.info("[RoadflareDomainService] Published ride history backup")
        } catch {
            RidestrLogger.info("[RoadflareDomainService] Failed to publish ride history backup: \(error.localizedDescription)")
        }
    }

    public func fetchLatestRideHistoryState() async -> StartupRemoteDomain<RideHistoryBackupContent> {
        await fetchStartupRideHistoryState()
    }

    // MARK: - Resolution

    public static func resolve(domain: RoadflareSyncDomain, metadata: RoadflareSyncMetadata, remoteCreatedAt: Int?) -> RoadflareSyncResolution {
        let shouldUseRemote: Bool
        if metadata.isDirty {
            shouldUseRemote = false
        } else if let remoteCreatedAt {
            shouldUseRemote = remoteCreatedAt > metadata.lastSuccessfulPublishAt
        } else {
            shouldUseRemote = false
        }

        let source: RoadflareSyncSource = shouldUseRemote ? .remote : .local
        return RoadflareSyncResolution(
            domain: domain,
            source: source,
            remoteCreatedAt: remoteCreatedAt,
            shouldPublishLocal: source == .local && metadata.isDirty
        )
    }

    /// Seed legacy local state into Nostr on first launch of the sync system.
    ///
    /// This only applies when there is no remote event at all and we have never
    /// recorded a successful local publish. Remote-present cases still resolve
    /// through the normal timestamp-based path.
    public static func shouldSeedLegacyLocalState(
        metadata: RoadflareSyncMetadata,
        remoteCreatedAt: Int?,
        hasLocalState: Bool
    ) -> Bool {
        guard hasLocalState else { return false }
        guard remoteCreatedAt == nil else { return false }
        return metadata.lastSuccessfulPublishAt == 0 && !metadata.isDirty
    }

    // MARK: - Private

    private func latestEvent(in events: [NostrEvent]) -> NostrEvent? {
        events.max(by: { $0.createdAt < $1.createdAt })
    }

    private func fetchStartupProfileState() async -> StartupRemoteDomain<UserProfileContent> {
        do {
            let filter = NostrFilter.metadata(pubkeys: [keypair.publicKeyHex])
            let events = try await relayManager.fetchEvents(filter: filter, timeout: fetchTimeout)
            return StartupRemoteDomain(
                latestSeenCreatedAt: latestEvent(in: events)?.createdAt,
                snapshot: latestDecodableSnapshot(in: events, parse: { event in
                    RideshareEventParser.parseMetadata(event: event)
                })
            )
        } catch {
            RidestrLogger.warning("[RoadflareDomainService] Profile fetch failed: \(error.localizedDescription)")
            return StartupRemoteDomain(latestSeenCreatedAt: nil, snapshot: nil)
        }
    }

    private func fetchStartupFollowedDriversState() async -> StartupRemoteDomain<FollowedDriversContent> {
        do {
            let filter = NostrFilter.followedDriversList(myPubkey: keypair.publicKeyHex)
            let events = try await relayManager.fetchEvents(filter: filter, timeout: fetchTimeout)
            return StartupRemoteDomain(
                latestSeenCreatedAt: latestEvent(in: events)?.createdAt,
                snapshot: latestDecodableSnapshot(in: events, parse: { event in
                    try RideshareEventParser.parseFollowedDriversList(event: event, keypair: keypair)
                })
            )
        } catch {
            RidestrLogger.warning("[RoadflareDomainService] Followed drivers fetch failed: \(error.localizedDescription)")
            return StartupRemoteDomain(latestSeenCreatedAt: nil, snapshot: nil)
        }
    }

    private func fetchStartupRideHistoryState() async -> StartupRemoteDomain<RideHistoryBackupContent> {
        do {
            let filter = NostrFilter.rideHistoryBackup(myPubkey: keypair.publicKeyHex)
            let events = try await relayManager.fetchEvents(filter: filter, timeout: fetchTimeout)
            return StartupRemoteDomain(
                latestSeenCreatedAt: latestEvent(in: events)?.createdAt,
                snapshot: latestDecodableSnapshot(in: events, parse: { event in
                    try RideshareEventParser.parseRideHistoryBackup(event: event, keypair: keypair)
                })
            )
        } catch {
            RidestrLogger.warning("[RoadflareDomainService] Ride history fetch failed: \(error.localizedDescription)")
            return StartupRemoteDomain(latestSeenCreatedAt: nil, snapshot: nil)
        }
    }

    private func fetchStartupProfileBackupState() async -> StartupRemoteDomain<ProfileBackupContent> {
        do {
            let filter = NostrFilter.profileBackup(myPubkey: keypair.publicKeyHex)
            let events = try await relayManager.fetchEvents(filter: filter, timeout: fetchTimeout)
            return StartupRemoteDomain(
                latestSeenCreatedAt: latestEvent(in: events)?.createdAt,
                snapshot: latestDecodableSnapshot(in: events, parse: { event in
                    try RideshareEventParser.parseProfileBackup(event: event, keypair: keypair)
                })
            )
        } catch {
            RidestrLogger.warning("[RoadflareDomainService] Profile backup fetch failed: \(error.localizedDescription)")
            return StartupRemoteDomain(latestSeenCreatedAt: nil, snapshot: nil)
        }
    }

    private func latestDecodableSnapshot<Value: Sendable>(
        in events: [NostrEvent],
        parse: (NostrEvent) throws -> Value?
    ) -> RoadflareRemoteSnapshot<Value>? {
        let sorted = events.sorted(by: { $0.createdAt > $1.createdAt })
        for event in sorted {
            do {
                guard let value = try parse(event) else { continue }
                return RoadflareRemoteSnapshot(
                    eventId: event.id,
                    createdAt: event.createdAt,
                    value: value
                )
            } catch {
                continue
            }
        }
        return nil
    }
}

/// Persisted startup sync metadata store.
public final class RoadflareSyncStateStore: @unchecked Sendable {
    private static let legacyStorageKey = "roadflare_sync_state"

    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()
    private var state: RoadflareSyncState

    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.storageKey = Self.storageKey(for: namespace)
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(RoadflareSyncState.self, from: data) {
            self.state = decoded
        } else {
            self.state = RoadflareSyncState()
        }
    }

    public func metadata(for domain: RoadflareSyncDomain) -> RoadflareSyncMetadata {
        lock.withLock { state[domain] }
    }

    public func setMetadata(_ metadata: RoadflareSyncMetadata, for domain: RoadflareSyncDomain) {
        lock.withLock {
            state[domain] = metadata
            persistLocked()
        }
    }

    public func markDirty(_ domain: RoadflareSyncDomain, isDirty: Bool = true) {
        lock.withLock {
            var metadata = state[domain]
            metadata.isDirty = isDirty
            state[domain] = metadata
            persistLocked()
        }
    }

    public func markPublished(_ domain: RoadflareSyncDomain, at timestamp: Int) {
        lock.withLock {
            var metadata = state[domain]
            metadata.lastSuccessfulPublishAt = timestamp
            metadata.isDirty = false
            state[domain] = metadata
            persistLocked()
        }
    }

    public func clearAll() {
        lock.withLock {
            state = RoadflareSyncState()
            defaults.removeObject(forKey: storageKey)
        }
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func storageKey(for namespace: String?) -> String {
        guard let namespace, !namespace.isEmpty else { return legacyStorageKey }
        return "\(legacyStorageKey).\(namespace)"
    }
}

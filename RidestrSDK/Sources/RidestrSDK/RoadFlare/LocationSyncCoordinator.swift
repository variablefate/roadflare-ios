// RidestrSDK/Sources/RidestrSDK/RoadFlare/LocationSyncCoordinator.swift
import Foundation

/// SDK-owned coordinator for RoadFlare key sync protocol.
///
/// Owns:
/// - Key share reception + acknowledgement (Kind 3186 → Kind 3188)
/// - Stale key detection via Kind 30012 `key_updated_at` comparison
/// - Key refresh requests (Kind 3188 "stale")
/// - Followed drivers list republish on key update (Kind 30011)
///
/// This is pure Nostr protocol logic with no iOS dependencies. The app-layer
/// `LocationCoordinator` is a thin subscription manager that creates this
/// coordinator in its `init` and delegates all protocol steps to it.
public final class LocationSyncCoordinator: @unchecked Sendable {
    private let relayManager: any RelayManagerProtocol
    private let keypair: NostrKeypair
    private let driversRepository: FollowedDriversRepository
    private let roadflareDomainService: RoadflareDomainService?
    private let roadflareSyncStore: RoadflareSyncStateStore?

    public init(
        relayManager: any RelayManagerProtocol,
        keypair: NostrKeypair,
        driversRepository: FollowedDriversRepository,
        roadflareDomainService: RoadflareDomainService? = nil,
        roadflareSyncStore: RoadflareSyncStateStore? = nil
    ) {
        self.relayManager = relayManager
        self.keypair = keypair
        self.driversRepository = driversRepository
        self.roadflareDomainService = roadflareDomainService
        self.roadflareSyncStore = roadflareSyncStore
    }

    // MARK: - Key Share Processing (Kind 3186)

    /// Process an incoming Kind 3186 key share event from a driver.
    ///
    /// - Parses and validates the event (throws on malformed/expired/misaddressed events)
    /// - Returns `.unknownDriver` if the sender is not in the followed list
    /// - Returns `.ignoredOlder` if the incoming key is older than the stored key
    /// - For `.duplicateCurrent`: clears stale flag, sends "received" ack, returns `.ignoredOlder`
    ///   (no Kind 30011 republish, no subscription restart needed)
    /// - For `.appliedNewer`: stores key, clears stale flag, sends "received" ack,
    ///   republishes Kind 30011, returns `.appliedNewer`
    ///
    /// The caller (app-layer `LocationCoordinator`) should restart location subscriptions
    /// when this returns `.appliedNewer`.
    public func processKeyShare(_ event: NostrEvent) async throws -> KeyShareOutcome {
        let keyShare = try RideshareEventParser.parseKeyShare(event: event, keypair: keypair)

        guard driversRepository.isFollowing(pubkey: keyShare.driverPubkey) else {
            RidestrLogger.info("[LocationSyncCoordinator] Ignoring key share from unknown driver \(keyShare.driverPubkey.prefix(8))")
            return .unknownDriver
        }
        RidestrLogger.info("[LocationSyncCoordinator] Key share received: driver=\(keyShare.driverPubkey.prefix(8)), version=\(keyShare.roadflareKey.version)")

        let updateOutcome = driversRepository.updateDriverKey(
            driverPubkey: keyShare.driverPubkey,
            roadflareKey: keyShare.roadflareKey
        )

        switch updateOutcome {
        case .unknownDriver:
            // Race: driver removed between isFollowing check and updateDriverKey.
            return .unknownDriver
        case .ignoredOlder:
            RidestrLogger.info("[LocationSyncCoordinator] Ignoring older key share for \(keyShare.driverPubkey.prefix(8))")
            return .ignoredOlder
        case .duplicateCurrent, .appliedNewer:
            break
        }

        // Clear stale flag for any accepted key (.appliedNewer or .duplicateCurrent).
        // Preserves existing app behavior (LocationCoordinator.swift:176): the current code clears
        // stale for every outcome that isn't .ignoredOlder, so a duplicate key share also clears
        // the "Key Outdated" badge. This is intentional — if the driver re-sent their current key,
        // the stale detection was a false alarm (their key hasn't actually changed).
        driversRepository.clearKeyStale(pubkey: keyShare.driverPubkey)

        // Send acknowledgement (Kind 3188) for both duplicate and newer keys
        let ackEvent = try await RideshareEventBuilder.keyAcknowledgement(
            driverPubkey: keyShare.driverPubkey,
            keyVersion: keyShare.roadflareKey.version,
            keyUpdatedAt: keyShare.keyUpdatedAt,
            status: "received",
            keypair: keypair
        )
        _ = try await relayManager.publish(ackEvent)

        if updateOutcome == .appliedNewer {
            await publishFollowedDriversList()
            return .appliedNewer
        }

        // .duplicateCurrent: stale cleared, ack sent; followed list unchanged, no restart needed
        return .ignoredOlder
    }

    // MARK: - Stale Key Detection (Kind 30012)

    /// Check all followed drivers for stale keys by comparing the local
    /// `roadflareKey.keyUpdatedAt` against the driver's Kind 30012 public
    /// `key_updated_at` tag. Sends Kind 3188 "stale" acks for outdated keys.
    public func checkForStaleKeys() async {
        for driver in driversRepository.drivers {
            guard driver.hasKey else {
                // No key at all — request one
                await requestKeyRefresh(driverPubkey: driver.pubkey)
                continue
            }
            let localKeyUpdatedAt = driver.roadflareKey?.keyUpdatedAt ?? 0
            do {
                let filter = NostrFilter.driverRoadflareState(driverPubkey: driver.pubkey)
                let events = try await relayManager.fetchEvents(filter: filter, timeout: 5)
                guard let event = events.max(by: { $0.createdAt < $1.createdAt }) else { continue }
                let keyUpdatedAtTag = event.tags.first { $0.count >= 2 && $0[0] == "key_updated_at" }
                guard let remoteTimestamp = keyUpdatedAtTag.flatMap({ Int($0[1]) }) else { continue }
                if remoteTimestamp > localKeyUpdatedAt {
                    RidestrLogger.info("[LocationSyncCoordinator] Stale key for \(driver.pubkey.prefix(8)): local=\(localKeyUpdatedAt), remote=\(remoteTimestamp)")
                    driversRepository.markKeyStale(pubkey: driver.pubkey)
                    await requestKeyRefresh(driverPubkey: driver.pubkey)
                } else {
                    driversRepository.clearKeyStale(pubkey: driver.pubkey)
                }
            } catch {
                // Non-fatal — will retry on next check
            }
        }
    }

    // MARK: - Request Key Refresh (Kind 3188 "stale")

    /// Send a "stale" key ack to a driver, requesting they re-send Kind 3186.
    /// Used when: rider has no key for this driver, or driver rotated keys.
    public func requestKeyRefresh(driverPubkey: String) async {
        let localKey = driversRepository.getRoadflareKey(driverPubkey: driverPubkey)
        do {
            let ackEvent = try await RideshareEventBuilder.keyAcknowledgement(
                driverPubkey: driverPubkey,
                keyVersion: localKey?.version ?? 0,
                keyUpdatedAt: localKey?.keyUpdatedAt ?? 0,
                status: "stale",
                keypair: keypair
            )
            _ = try await relayManager.publish(ackEvent)
            RidestrLogger.info("[LocationSyncCoordinator] Sent stale key ack to \(driverPubkey.prefix(8))")
        } catch {
            // Best effort
        }
    }

    // MARK: - Publish Followed Drivers (Kind 30011)

    /// Publish the followed drivers list to Nostr. Called internally after a
    /// key update; also available for external callers (e.g. app-layer delegate).
    public func publishFollowedDriversList() async {
        roadflareSyncStore?.markDirty(.followedDrivers)
        do {
            let event: NostrEvent
            if let roadflareDomainService {
                event = try await roadflareDomainService.publishFollowedDriversList(driversRepository.drivers)
            } else {
                event = try await RideshareEventBuilder.followedDriversList(
                    drivers: driversRepository.drivers,
                    keypair: keypair
                )
                _ = try await relayManager.publish(event)
            }
            roadflareSyncStore?.markPublished(.followedDrivers, at: event.createdAt)
        } catch {
            RidestrLogger.info("[LocationSyncCoordinator] Failed to publish followed drivers list: \(error)")
        }
    }
}

// MARK: - KeyShareOutcome

/// Result of processing a Kind 3186 key share event via `LocationSyncCoordinator.processKeyShare`.
public enum KeyShareOutcome: Sendable, Equatable {
    /// New key accepted, stored, ack sent, followed list republished.
    /// The app-layer caller should restart location subscriptions.
    case appliedNewer
    /// Incoming key is older, a duplicate, or a driver-not-found race.
    /// No subscription restart is needed.
    case ignoredOlder
    /// Driver is not in the followed list; event was discarded.
    case unknownDriver
}

import Foundation
import os
import RidestrSDK

/// Manages RoadFlare driver location broadcasts (Kind 30014) and key shares (Kind 3186).
///
/// ## Key Share Flow (matching Android Ridestr):
/// 1. Rider adds driver → publishes Kind 30011 (with driver's pubkey in p-tags)
/// 2. Driver discovers follower → accepts → sends Kind 3186 (12-hour expiry)
/// 3. Rider's persistent subscription catches Kind 3186 → stores key → sends Kind 3188 ack
/// 4. Key is stored in rider's Kind 30011 backup — persists across devices/reinstalls
/// 5. On re-add or new device, key is restored from Kind 30011 (no new Kind 3186 needed)
///
/// ## Stale Key Detection (matching Android Ridestr):
/// - Driver's Kind 30012 has a public `key_updated_at` tag (no decryption needed)
/// - Rider compares local `roadflareKey.keyUpdatedAt` vs driver's Kind 30012 tag
/// - If driver's is newer → key was rotated → send Kind 3188 "stale" ack → driver re-sends Kind 3186
@Observable
@MainActor
final class LocationCoordinator {
    let relayManager: any RelayManagerProtocol
    private let keypair: NostrKeypair
    private let roadflareDomainService: RoadflareDomainService?
    private let roadflareSyncStore: RoadflareSyncStateStore?
    let driversRepository: FollowedDriversRepository

    private struct ManagedSubscription {
        let id: SubscriptionID
        let generation: UUID
        let task: Task<Void, Never>
    }

    private var activeLocationSubscription: ManagedSubscription?
    private var activeKeyShareSubscription: ManagedSubscription?

    var lastError: String?

    init(relayManager: any RelayManagerProtocol, keypair: NostrKeypair,
         driversRepository: FollowedDriversRepository,
         roadflareDomainService: RoadflareDomainService? = nil,
         roadflareSyncStore: RoadflareSyncStateStore? = nil) {
        self.relayManager = relayManager
        self.keypair = keypair
        self.roadflareDomainService = roadflareDomainService
        self.roadflareSyncStore = roadflareSyncStore
        self.driversRepository = driversRepository
    }

    // MARK: - Location Subscription (Kind 30014)

    func startLocationSubscriptions() {
        let pubkeys = driversRepository.allPubkeys
        let previous = takeLocationSubscription()

        guard !pubkeys.isEmpty else {
            if let previous {
                Task {
                    previous.task.cancel()
                    await relayManager.unsubscribe(previous.id)
                }
            }
            return
        }

        let subId = SubscriptionID("roadflare-locations")
        let generation = UUID()

        let task = Task {
            previous?.task.cancel()
            if let oldId = previous?.id {
                await relayManager.unsubscribe(oldId)
            }
            guard !Task.isCancelled,
                  activeLocationSubscription?.generation == generation else { return }

            do {
                let filter = NostrFilter.roadflareLocations(driverPubkeys: pubkeys)
                let stream = try await relayManager.subscribe(filter: filter, id: subId)
                guard !Task.isCancelled,
                      activeLocationSubscription?.generation == generation else { return }

                for await event in stream {
                    guard !Task.isCancelled,
                          activeLocationSubscription?.generation == generation else { break }
                    await handleLocationEvent(event)
                }
            } catch {
                guard activeLocationSubscription?.generation == generation else { return }
                lastError = "Location subscription failed: \(error.localizedDescription)"
            }
        }
        activeLocationSubscription = ManagedSubscription(id: subId, generation: generation, task: task)
    }

    func handleLocationEvent(_ event: NostrEvent) async {
        let driverPubkey = event.pubkey
        guard let key = driversRepository.getRoadflareKey(driverPubkey: driverPubkey) else {
            AppLogger.location.debug("Location event ignored — no key for driver \(driverPubkey.prefix(8))")
            return
        }

        do {
            let parsed = try RideshareEventParser.parseRoadflareLocation(
                event: event,
                roadflarePrivateKeyHex: key.privateKeyHex
            )
            driversRepository.updateDriverLocation(
                pubkey: driverPubkey,
                latitude: parsed.location.latitude,
                longitude: parsed.location.longitude,
                status: parsed.location.status.rawValue,
                timestamp: parsed.location.timestamp,
                keyVersion: parsed.keyVersion
            )
        } catch {
            AppLogger.location.info("Location decryption failed for driver \(driverPubkey.prefix(8)) (key v\(key.version)): \(error)")
        }
    }

    // MARK: - Key Share Subscription (Kind 3186)

    /// Persistent subscription for incoming key shares from drivers.
    /// When a driver accepts a follow request, they send Kind 3186 (12-hour expiry).
    /// The key is then stored locally and in the rider's Kind 30011 backup.
    func startKeyShareSubscription() {
        let previous = takeKeyShareSubscription()

        let subId = SubscriptionID("key-shares")
        let generation = UUID()

        let task = Task {
            previous?.task.cancel()
            if let oldId = previous?.id {
                await relayManager.unsubscribe(oldId)
            }
            guard !Task.isCancelled,
                  activeKeyShareSubscription?.generation == generation else { return }
            do {
                let filter = NostrFilter.keyShares(myPubkey: keypair.publicKeyHex)
                AppLogger.location.info("Subscribing to key shares for \(self.keypair.publicKeyHex.prefix(8))...")
                let stream = try await relayManager.subscribe(filter: filter, id: subId)
                guard !Task.isCancelled,
                      activeKeyShareSubscription?.generation == generation else { return }
                AppLogger.location.info("Key share subscription active")

                for await event in stream {
                    guard !Task.isCancelled,
                          activeKeyShareSubscription?.generation == generation else { break }
                    await handleKeyShareEvent(event)
                }
            } catch {
                guard activeKeyShareSubscription?.generation == generation else { return }
                lastError = "Key share subscription failed: \(error.localizedDescription)"
            }
        }
        activeKeyShareSubscription = ManagedSubscription(id: subId, generation: generation, task: task)
    }

    func handleKeyShareEvent(_ event: NostrEvent) async {
        do {
            let keyShare = try RideshareEventParser.parseKeyShare(event: event, keypair: keypair)
            guard driversRepository.isFollowing(pubkey: keyShare.driverPubkey) else {
                AppLogger.location.info("Ignoring key share from unknown driver \(keyShare.driverPubkey.prefix(8))")
                return
            }
            AppLogger.location.info("Key share received: driver=\(keyShare.driverPubkey.prefix(8)), version=\(keyShare.roadflareKey.version)")

            let updateOutcome = driversRepository.updateDriverKey(
                driverPubkey: keyShare.driverPubkey,
                roadflareKey: keyShare.roadflareKey
            )
            guard updateOutcome != .ignoredOlder else {
                AppLogger.location.info("Ignoring older key share for \(keyShare.driverPubkey.prefix(8))")
                return
            }
            driversRepository.clearKeyStale(pubkey: keyShare.driverPubkey)

            // Send acknowledgement (Kind 3188)
            let ackEvent = try await RideshareEventBuilder.keyAcknowledgement(
                driverPubkey: keyShare.driverPubkey,
                keyVersion: keyShare.roadflareKey.version,
                keyUpdatedAt: keyShare.keyUpdatedAt,
                status: "received",
                keypair: keypair
            )
            _ = try await relayManager.publish(ackEvent)

            if updateOutcome == .appliedNewer {
                // Republish Kind 30011 so the key is backed up to Nostr
                await publishFollowedDriversList()

                // Restart location subscriptions to include newly-keyed driver
                startLocationSubscriptions()
            }
        } catch {
            AppLogger.location.info("Key share handling failed: \(error)")
        }
    }

    // MARK: - Stale Key Detection (Kind 30012)

    /// Check all followed drivers for stale keys by comparing local keyUpdatedAt
    /// against the driver's Kind 30012 public `key_updated_at` tag.
    /// Sends Kind 3188 "stale" ack for any outdated keys so the driver re-sends Kind 3186.
    func checkForStaleKeys() async {
        for driver in driversRepository.drivers {
            guard driver.hasKey else {
                // No key at all — request one
                await requestKeyRefresh(driverPubkey: driver.pubkey)
                continue
            }

            // Compare local keyUpdatedAt (may be nil/0 for old keys) against
            // driver's Kind 30012 public key_updated_at tag
            let localKeyUpdatedAt = driver.roadflareKey?.keyUpdatedAt ?? 0

            do {
                let filter = NostrFilter.driverRoadflareState(driverPubkey: driver.pubkey)
                let events = try await relayManager.fetchEvents(filter: filter, timeout: 5)
                guard let event = events.max(by: { $0.createdAt < $1.createdAt }) else { continue }

                let keyUpdatedAtTag = event.tags.first { $0.count >= 2 && $0[0] == "key_updated_at" }
                guard let remoteTimestamp = keyUpdatedAtTag.flatMap({ Int($0[1]) }) else { continue }

                if remoteTimestamp > localKeyUpdatedAt {
                    AppLogger.location.info("Stale key detected for \(driver.pubkey.prefix(8)): local=\(localKeyUpdatedAt), remote=\(remoteTimestamp)")
                    driversRepository.markKeyStale(pubkey: driver.pubkey)
                    await requestKeyRefresh(driverPubkey: driver.pubkey)
                } else {
                    driversRepository.clearKeyStale(pubkey: driver.pubkey)
                }
            } catch {
                // Non-fatal — will check again next time
            }
        }
    }

    // MARK: - Publish Followed Drivers (Kind 30011)

    func publishFollowedDriversList() async {
        roadflareSyncStore?.markDirty(.followedDrivers)
        do {
            let event: NostrEvent
            if let roadflareDomainService {
                event = try await roadflareDomainService.publishFollowedDriversList(
                    driversRepository.drivers
                )
            } else {
                event = try await RideshareEventBuilder.followedDriversList(
                    drivers: driversRepository.drivers,
                    keypair: keypair
                )
                _ = try await relayManager.publish(event)
            }
            roadflareSyncStore?.markPublished(.followedDrivers, at: event.createdAt)
        } catch {
            lastError = "Failed to publish driver list: \(error.localizedDescription)"
        }
    }

    // MARK: - Request Key Refresh (Kind 3188 "stale")

    /// Send a "stale" key ack to a driver, requesting they re-send Kind 3186.
    /// Used when: (1) rider has no key for this driver, or (2) driver rotated keys.
    func requestKeyRefresh(driverPubkey: String) async {
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
            AppLogger.location.info("Sent stale key ack to \(driverPubkey.prefix(8))")
        } catch {
            // Best effort
        }
    }

    // MARK: - Cleanup

    func stopAll() async {
        let location = takeLocationSubscription()
        let keyShare = takeKeyShareSubscription()
        location?.task.cancel()
        keyShare?.task.cancel()
        if let id = location?.id { await relayManager.unsubscribe(id) }
        if let id = keyShare?.id { await relayManager.unsubscribe(id) }
    }

    private func takeLocationSubscription() -> ManagedSubscription? {
        let previous = activeLocationSubscription
        activeLocationSubscription = nil
        return previous
    }

    private func takeKeyShareSubscription() -> ManagedSubscription? {
        let previous = activeKeyShareSubscription
        activeKeyShareSubscription = nil
        return previous
    }
}

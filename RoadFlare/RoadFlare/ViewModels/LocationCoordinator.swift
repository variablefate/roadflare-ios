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
    let driversRepository: FollowedDriversRepository

    private var locationSubscriptionId: SubscriptionID?
    private var keyShareSubscriptionId: SubscriptionID?
    private var locationTask: Task<Void, Never>?
    private var keyShareTask: Task<Void, Never>?

    var lastError: String?

    init(relayManager: any RelayManagerProtocol, keypair: NostrKeypair,
         driversRepository: FollowedDriversRepository) {
        self.relayManager = relayManager
        self.keypair = keypair
        self.driversRepository = driversRepository
    }

    // MARK: - Location Subscription (Kind 30014)

    func startLocationSubscriptions() {
        let pubkeys = driversRepository.allPubkeys
        guard !pubkeys.isEmpty else { return }

        locationTask?.cancel()
        let oldId = locationSubscriptionId

        let subId = SubscriptionID("roadflare-locations")
        locationSubscriptionId = subId

        locationTask = Task {
            if let oldId { await relayManager.unsubscribe(oldId) }

            do {
                let filter = NostrFilter.roadflareLocations(driverPubkeys: pubkeys)
                let stream = try await relayManager.subscribe(filter: filter, id: subId)

                for await event in stream {
                    guard !Task.isCancelled else { break }
                    await handleLocationEvent(event)
                }
            } catch {
                lastError = "Location subscription failed: \(error.localizedDescription)"
            }
        }
    }

    func handleLocationEvent(_ event: NostrEvent) async {
        let driverPubkey = event.pubkey
        guard let key = driversRepository.getRoadflareKey(driverPubkey: driverPubkey) else { return }

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
            // Decryption failure — stale key or wrong driver, silently ignore
        }
    }

    // MARK: - Key Share Subscription (Kind 3186)

    /// Persistent subscription for incoming key shares from drivers.
    /// When a driver accepts a follow request, they send Kind 3186 (12-hour expiry).
    /// The key is then stored locally and in the rider's Kind 30011 backup.
    func startKeyShareSubscription() {
        keyShareTask?.cancel()
        let oldId = keyShareSubscriptionId

        let subId = SubscriptionID("key-shares")
        keyShareSubscriptionId = subId

        keyShareTask = Task {
            if let oldId { await relayManager.unsubscribe(oldId) }

            do {
                let filter = NostrFilter.keyShares(myPubkey: keypair.publicKeyHex)
                AppLogger.location.info("Subscribing to key shares for \(self.keypair.publicKeyHex.prefix(8))...")
                let stream = try await relayManager.subscribe(filter: filter, id: subId)
                AppLogger.location.info("Key share subscription active")

                for await event in stream {
                    guard !Task.isCancelled else { break }
                    await handleKeyShareEvent(event)
                }
            } catch {
                lastError = "Key share subscription failed: \(error.localizedDescription)"
            }
        }
    }

    func handleKeyShareEvent(_ event: NostrEvent) async {
        do {
            let keyShare = try RideshareEventParser.parseKeyShare(event: event, keypair: keypair)
            AppLogger.location.info("Key share received: driver=\(keyShare.driverPubkey.prefix(8)), version=\(keyShare.roadflareKey.version)")

            driversRepository.updateDriverKey(
                driverPubkey: keyShare.driverPubkey,
                roadflareKey: keyShare.roadflareKey
            )

            // Send acknowledgement (Kind 3188)
            let ackEvent = try await RideshareEventBuilder.keyAcknowledgement(
                driverPubkey: keyShare.driverPubkey,
                keyVersion: keyShare.roadflareKey.version,
                keyUpdatedAt: keyShare.keyUpdatedAt,
                status: "received",
                keypair: keypair
            )
            _ = try await relayManager.publish(ackEvent)

            // Republish Kind 30011 so the key is backed up to Nostr
            await publishFollowedDriversList()

            // Restart location subscriptions to include newly-keyed driver
            startLocationSubscriptions()
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
                guard let event = events.first else { continue }

                let keyUpdatedAtTag = event.tags.first { $0.count >= 2 && $0[0] == "key_updated_at" }
                guard let remoteTimestamp = keyUpdatedAtTag.flatMap({ Int($0[1]) }) else { continue }

                if remoteTimestamp > localKeyUpdatedAt {
                    AppLogger.location.info("Stale key detected for \(driver.pubkey.prefix(8)): local=\(localKeyUpdatedAt), remote=\(remoteTimestamp)")
                    await requestKeyRefresh(driverPubkey: driver.pubkey)
                }
            } catch {
                // Non-fatal — will check again next time
            }
        }
    }

    // MARK: - Publish Followed Drivers (Kind 30011)

    func publishFollowedDriversList() async {
        do {
            let event = try await RideshareEventBuilder.followedDriversList(
                drivers: driversRepository.drivers,
                keypair: keypair
            )
            _ = try await relayManager.publish(event)
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
        locationTask?.cancel()
        keyShareTask?.cancel()
        if let id = locationSubscriptionId { await relayManager.unsubscribe(id) }
        if let id = keyShareSubscriptionId { await relayManager.unsubscribe(id) }
        locationSubscriptionId = nil
        keyShareSubscriptionId = nil
    }
}

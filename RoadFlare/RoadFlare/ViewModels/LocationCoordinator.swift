import Foundation
import RidestrSDK

/// Manages RoadFlare driver location broadcasts (Kind 30014) and key shares (Kind 3186).
/// Background subscriptions that run for the lifetime of the app session.
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

    func startKeyShareSubscription() {
        keyShareTask?.cancel()
        let oldId = keyShareSubscriptionId

        let subId = SubscriptionID("key-shares")
        keyShareSubscriptionId = subId

        keyShareTask = Task {
            if let oldId { await relayManager.unsubscribe(oldId) }

            do {
                let filter = NostrFilter.keyShares(myPubkey: keypair.publicKeyHex)
                AppLogger.location.info(" Subscribing to key shares for \(keypair.publicKeyHex.prefix(8))...")
                let stream = try await relayManager.subscribe(filter: filter, id: subId)
                AppLogger.location.info(" Key share subscription active")

                for await event in stream {
                    guard !Task.isCancelled else { break }
                    AppLogger.location.info(" Received Kind \(event.kind) from \(event.pubkey.prefix(8))...")
                    await handleKeyShareEvent(event)
                }
                AppLogger.location.info(" Key share stream ended")
            } catch {
                AppLogger.location.info(" Key share subscription FAILED: \(error)")
                lastError = "Key share subscription failed: \(error.localizedDescription)"
            }
        }
    }

    func handleKeyShareEvent(_ event: NostrEvent) async {
        do {
            let keyShare = try RideshareEventParser.parseKeyShare(event: event, keypair: keypair)
            AppLogger.location.info(" Key share parsed: driver=\(keyShare.driverPubkey.prefix(8)), version=\(keyShare.roadflareKey.version)")

            driversRepository.updateDriverKey(
                driverPubkey: keyShare.driverPubkey,
                roadflareKey: keyShare.roadflareKey
            )
            AppLogger.location.info(" Driver key updated in repository")

            // Send acknowledgement (Kind 3188)
            let ackEvent = try await RideshareEventBuilder.keyAcknowledgement(
                driverPubkey: keyShare.driverPubkey,
                keyVersion: keyShare.roadflareKey.version,
                keyUpdatedAt: keyShare.keyUpdatedAt ?? 0,
                status: "received",
                keypair: keypair
            )
            _ = try await relayManager.publish(ackEvent)
            AppLogger.location.info(" Key acknowledgement published")

            // Restart location subscriptions to include newly-keyed driver
            startLocationSubscriptions()
        } catch {
            AppLogger.location.info(" Key share handling FAILED: \(error)")
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

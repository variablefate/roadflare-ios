import Foundation
import os
import RidestrSDK

/// Thin subscription manager for RoadFlare location broadcasts (Kind 30014)
/// and key shares (Kind 3186).
///
/// All Nostr protocol logic (key share state machine, stale key detection,
/// ack publishing) is owned by `LocationSyncCoordinator` in the SDK.
/// This class manages subscription lifetimes and feeds events to the SDK coordinator.
@Observable
@MainActor
final class LocationCoordinator {
    let relayManager: any RelayManagerProtocol
    private let keypair: NostrKeypair
    private let locationSync: LocationSyncCoordinator
    let driversRepository: FollowedDriversRepository

    private struct ManagedSubscription {
        let id: SubscriptionID
        let generation: UUID
        let task: Task<Void, Never>
    }

    private var activeLocationSubscription: ManagedSubscription?
    private var activeKeyShareSubscription: ManagedSubscription?
    private var activeDriverAvailabilitySubscription: ManagedSubscription?

    /// Hook fired after every successfully parsed Kind 30173 event, so an outer
    /// coordinator (currently `RideCoordinator`) can opportunistically adopt the
    /// vehicle as the active-ride snapshot when it would otherwise stay nil
    /// (cold-start mid-ride, or fresh acceptance whose cache was empty at the
    /// transition). See issue #91 / `RideCoordinator.adoptVehicleIfNeeded`.
    ///
    /// Not `@Sendable` (unlike sibling SDK callbacks `onProfileChanged` /
    /// `onDriversChanged`): `LocationCoordinator` is `@MainActor`, so the
    /// callsite always runs on the main actor and the closure cannot escape.
    ///
    /// Fires even when `driversRepository.updateDriverVehicle(...)` was a no-op
    /// (e.g. driver unfollowed before this event arrived). This is intentional:
    /// the active-ride snapshot represents "the vehicle the rider agreed to,"
    /// which is meaningful for an in-flight ride even if the rider unfollowed
    /// the driver mid-trip. `adoptVehicleIfNeeded` independently gates on the
    /// active session driverPubkey.
    var onDriverVehicleUpdate: ((String, VehicleInfo) -> Void)?

    var lastError: String?

    init(relayManager: any RelayManagerProtocol, keypair: NostrKeypair,
         driversRepository: FollowedDriversRepository,
         roadflareDomainService: RoadflareDomainService? = nil,
         roadflareSyncStore: RoadflareSyncStateStore? = nil) {
        self.relayManager = relayManager
        self.keypair = keypair
        self.driversRepository = driversRepository
        self.locationSync = LocationSyncCoordinator(
            relayManager: relayManager,
            keypair: keypair,
            driversRepository: driversRepository,
            roadflareDomainService: roadflareDomainService,
            roadflareSyncStore: roadflareSyncStore
        )
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

    // MARK: - Driver Availability Subscription (Kind 30173)

    /// Subscribe to Kind 30173 driver-availability events from followed drivers, so the
    /// rider sees the driver's currently active vehicle. Mirrors `startLocationSubscriptions`:
    /// the author filter is restricted to followed drivers, and the subscription must be
    /// restarted whenever the followed-drivers list changes.
    ///
    /// Without this, the rider only ever sees Kind 0 vehicle data, which Drivestr does not
    /// reliably re-publish when a multi-vehicle driver swaps active vehicles. See issue #91.
    func startDriverAvailabilitySubscription() {
        let pubkeys = driversRepository.allPubkeys
        let previous = takeDriverAvailabilitySubscription()

        guard !pubkeys.isEmpty else {
            if let previous {
                Task {
                    previous.task.cancel()
                    await relayManager.unsubscribe(previous.id)
                }
            }
            return
        }

        let subId = SubscriptionID("driver-availability")
        let generation = UUID()

        let task = Task {
            previous?.task.cancel()
            if let oldId = previous?.id {
                await relayManager.unsubscribe(oldId)
            }
            guard !Task.isCancelled,
                  activeDriverAvailabilitySubscription?.generation == generation else { return }

            do {
                let filter = NostrFilter.driverAvailability(driverPubkeys: pubkeys)
                let stream = try await relayManager.subscribe(filter: filter, id: subId)
                guard !Task.isCancelled,
                      activeDriverAvailabilitySubscription?.generation == generation else { return }

                for await event in stream {
                    guard !Task.isCancelled,
                          activeDriverAvailabilitySubscription?.generation == generation else { break }
                    handleDriverAvailabilityEvent(event)
                }
            } catch {
                guard activeDriverAvailabilitySubscription?.generation == generation else { return }
                lastError = "Driver availability subscription failed: \(error.localizedDescription)"
            }
        }
        activeDriverAvailabilitySubscription = ManagedSubscription(id: subId, generation: generation, task: task)
    }

    func handleDriverAvailabilityEvent(_ event: NostrEvent) {
        guard let parsed = RideshareEventParser.parseDriverAvailability(event: event) else {
            AppLogger.location.debug("Driver availability event ignored — unparseable from \(event.pubkey.prefix(8))")
            return
        }
        // Overwrite-only: the cache always replaces the prior entry, even when fields are
        // nil — Kind 30173 is a parameterized replaceable event, so the latest payload is
        // the driver's current active vehicle in full. Merging field-by-field would let
        // stale values leak across vehicle swaps. See issue #91.
        driversRepository.updateDriverVehicle(pubkey: parsed.driverPubkey, vehicle: parsed.vehicle)
        onDriverVehicleUpdate?(parsed.driverPubkey, parsed.vehicle)
    }

    // MARK: - Key Share Subscription (Kind 3186)

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
            let outcome = try await locationSync.processKeyShare(event)
            if outcome == .appliedNewer {
                startLocationSubscriptions()
            }
        } catch {
            AppLogger.location.info("Key share handling failed from \(event.pubkey.prefix(8)): \(error)")
        }
    }

    // MARK: - Delegates to SDK

    func publishFollowedDriversList() async {
        do {
            try await locationSync.publishFollowedDriversList()
        } catch {
            lastError = "Failed to publish driver list: \(error.localizedDescription)"
        }
    }

    func checkForStaleKeys() async {
        await locationSync.checkForStaleKeys()
    }

    func requestKeyRefresh(driverPubkey: String) async throws {
        try await locationSync.requestKeyRefresh(driverPubkey: driverPubkey)
    }

    // MARK: - Cleanup

    func stopAll() async {
        let location = takeLocationSubscription()
        let keyShare = takeKeyShareSubscription()
        let availability = takeDriverAvailabilitySubscription()
        location?.task.cancel()
        keyShare?.task.cancel()
        availability?.task.cancel()
        if let id = location?.id { await relayManager.unsubscribe(id) }
        if let id = keyShare?.id { await relayManager.unsubscribe(id) }
        if let id = availability?.id { await relayManager.unsubscribe(id) }
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

    private func takeDriverAvailabilitySubscription() -> ManagedSubscription? {
        let previous = activeDriverAvailabilitySubscription
        activeDriverAvailabilitySubscription = nil
        return previous
    }
}

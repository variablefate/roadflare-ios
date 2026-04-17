import Foundation

// MARK: - Result Models

/// Result of scanning relays for user-authored events.
public struct RelayScanResult: Sendable {
    /// RoadFlare/Ridestr events found (12 rider-authored kinds, excluding Kind 0).
    public let roadflareEvents: [NostrEvent]
    /// Kind 0 metadata events found (shared Nostr identity, used by all apps).
    public let metadataEvents: [NostrEvent]
    /// Human-readable error messages from queries that failed (relay unreachable,
    /// timeout, etc.). When non-empty, the scan was incomplete — the caller should
    /// warn the user before proceeding to deletion.
    public let scanErrors: [String]
    /// Relay URLs that were scanned.
    public let targetRelayURLs: [URL]

    public init(
        roadflareEvents: [NostrEvent],
        metadataEvents: [NostrEvent],
        scanErrors: [String],
        targetRelayURLs: [URL]
    ) {
        self.roadflareEvents = roadflareEvents
        self.metadataEvents = metadataEvents
        self.scanErrors = scanErrors
        self.targetRelayURLs = targetRelayURLs
    }

    public var roadflareCount: Int { roadflareEvents.count }
    public var metadataCount: Int { metadataEvents.count }
    public var totalCount: Int { roadflareCount + metadataCount }
    public var hasErrors: Bool { !scanErrors.isEmpty }
}

/// Result of a relay-side deletion pass.
public struct RelayDeletionResult: Sendable {
    /// Event IDs included in the Kind 5 deletion request.
    public let deletedEventIds: [String]
    /// Relay URLs the deletion was published to.
    public let targetRelayURLs: [URL]
    /// True if the Kind 5 event was published, or if there was nothing to delete.
    public let publishedSuccessfully: Bool
    /// Human-readable error from the publish step, if any.
    public let publishError: String?

    public init(
        deletedEventIds: [String],
        targetRelayURLs: [URL],
        publishedSuccessfully: Bool,
        publishError: String?
    ) {
        self.deletedEventIds = deletedEventIds
        self.targetRelayURLs = targetRelayURLs
        self.publishedSuccessfully = publishedSuccessfully
        self.publishError = publishError
    }
}

/// Result of verifying a deletion — re-scans relays and counts how many of the
/// originally-requested event IDs are still visible. Relays implementing NIP-09
/// should have removed the events; relays that refuse NIP-09 (policy choice)
/// will still have them. The counts let callers tell the user honestly.
public struct DeletionVerificationResult: Sendable {
    /// How many event IDs were in the Kind 5 deletion request.
    public let requestedCount: Int
    /// How many of those are still visible on relays after the verification scan.
    public let remainingCount: Int
    /// How many appear to have been honoured (requested - remaining).
    public var deletedCount: Int { requestedCount - remainingCount }
    /// Whether the verification scan itself produced relay errors (timeouts,
    /// disconnects). When non-empty the `remainingCount` is a lower bound —
    /// some relays couldn't be checked.
    public let scanErrors: [String]

    public init(requestedCount: Int, remainingCount: Int, scanErrors: [String]) {
        self.requestedCount = requestedCount
        self.remainingCount = remainingCount
        self.scanErrors = scanErrors
    }

    /// True when every requested event is gone from every reachable relay.
    public var fullyHonoured: Bool { remainingCount == 0 && scanErrors.isEmpty }
}

// MARK: - Service

/// Scans relays for rider-authored events and publishes NIP-09 Kind 5 deletion requests.
///
/// Create with the app's live `relayManager` (already connected). The service is stateless —
/// create a fresh instance for each deletion flow.
///
/// ## Usage
/// ```swift
/// let service = AccountDeletionService(relayManager: rm, keypair: kp)
/// let scan = await service.scanRelays()
/// // Show results to user, then:
/// let result = await service.deleteRoadflareEvents(from: scan)
/// ```
public final class AccountDeletionService: Sendable {
    private let relayManager: any RelayManagerProtocol
    private let keypair: NostrKeypair

    /// The 12 rider-authored Ridestr event kinds (excludes Kind 0 metadata).
    public static let roadflareKinds: [EventKind] = [
        // Parameterized replaceable (always on relays)
        .followedDriversList,    // 30011
        .rideHistoryBackup,      // 30174
        .unifiedProfile,         // 30177
        .riderRideState,         // 30181
        // Regular (ephemeral, may still be on relays)
        .rideOffer,              // 3173
        .rideConfirmation,       // 3175
        .chatMessage,            // 3178
        .cancellation,           // 3179
        .keyShare,               // 3186
        .followNotification,     // 3187
        .keyAcknowledgement,     // 3188
        .driverPingRequest,      // 3189
    ]

    public init(relayManager: any RelayManagerProtocol, keypair: NostrKeypair) {
        self.relayManager = relayManager
        self.keypair = keypair
    }

    // MARK: - Scan

    /// Query connected relays for all rider-authored events.
    /// Two queries: one for all 12 RoadFlare kinds, one for Kind 0 metadata.
    /// Captures fetch errors in `RelayScanResult.scanErrors` so the caller can
    /// warn the user when a query failed (rather than silently reporting 0 events).
    public func scanRelays() async -> RelayScanResult {
        let roadflareFilter = NostrFilter()
            .authors([keypair.publicKeyHex])
            .rawKinds(Self.roadflareKinds.map(\.rawValue))

        let metadataFilter = NostrFilter.metadata(pubkeys: [keypair.publicKeyHex])

        async let rfFetch = fetchWithError(filter: roadflareFilter, label: "RoadFlare events")
        async let metaFetch = fetchWithError(filter: metadataFilter, label: "Nostr profile")

        let (rfResult, metaResult) = await (rfFetch, metaFetch)

        var errors: [String] = []
        if let err = rfResult.error { errors.append(err) }
        if let err = metaResult.error { errors.append(err) }

        return RelayScanResult(
            roadflareEvents: rfResult.events,
            metadataEvents: metaResult.events,
            scanErrors: errors,
            targetRelayURLs: DefaultRelays.all
        )
    }

    // MARK: - Delete

    /// Delete only RoadFlare events (12 Ridestr kinds). Does NOT delete Kind 0 metadata.
    public func deleteRoadflareEvents(from scan: RelayScanResult) async -> RelayDeletionResult {
        let eventIds = scan.roadflareEvents.map(\.id)
        return await publishDeletion(
            eventIds: eventIds,
            kinds: Self.roadflareKinds
        )
    }

    /// Delete all Ridestr events (12 RoadFlare kinds + Kind 0 metadata).
    public func deleteAllRidestrEvents(from scan: RelayScanResult) async -> RelayDeletionResult {
        let eventIds = scan.roadflareEvents.map(\.id) + scan.metadataEvents.map(\.id)
        return await publishDeletion(
            eventIds: eventIds,
            kinds: Self.roadflareKinds + [.metadata]
        )
    }

    // MARK: - Verify

    /// Re-scan relays and count how many of the requested event IDs are still
    /// visible. Intended to run a beat after a deletion publish so relays have
    /// time to process the Kind 5 and drop the referenced events.
    ///
    /// Waits `settleDelay` seconds before the scan to give relays time to
    /// process the Kind 5. Defaults to 2s which comfortably covers healthy
    /// relay processing time; slow relays may still be mid-process when the
    /// scan runs, in which case their events will show up in `remainingCount`.
    public func verifyDeletion(
        targetEventIds: [String],
        settleDelay: TimeInterval = 2.0
    ) async -> DeletionVerificationResult {
        if targetEventIds.isEmpty {
            return DeletionVerificationResult(requestedCount: 0, remainingCount: 0, scanErrors: [])
        }
        try? await Task.sleep(for: .seconds(settleDelay))
        let scan = await scanRelays()
        let stillPresent = Set(scan.roadflareEvents.map(\.id))
            .union(scan.metadataEvents.map(\.id))
        let remaining = Set(targetEventIds).intersection(stillPresent)
        return DeletionVerificationResult(
            requestedCount: targetEventIds.count,
            remainingCount: remaining.count,
            scanErrors: scan.scanErrors
        )
    }

    // MARK: - Private

    private func fetchWithError(
        filter: NostrFilter,
        label: String
    ) async -> (events: [NostrEvent], error: String?) {
        do {
            let events = try await relayManager.fetchEvents(
                filter: filter,
                timeout: RelayConstants.eoseTimeoutSeconds
            )
            return (events, nil)
        } catch {
            return ([], "\(label) query failed: \(error.localizedDescription)")
        }
    }

    private func publishDeletion(eventIds: [String], kinds: [EventKind]) async -> RelayDeletionResult {
        guard !eventIds.isEmpty else {
            return RelayDeletionResult(
                deletedEventIds: [],
                targetRelayURLs: DefaultRelays.all,
                publishedSuccessfully: true,
                publishError: nil
            )
        }

        do {
            let deletionEvent = try await RideshareEventBuilder.deletion(
                eventIds: eventIds,
                reason: "Account deleted by user",
                kinds: kinds,
                keypair: keypair
            )
            // Use publishWithRetry: deletion is a critical, non-retryable operation
            // once the user logs out (keypair is destroyed). Retry survives transient
            // relay failures that a single publish would surface as permanent errors.
            _ = try await relayManager.publishWithRetry(deletionEvent)
            return RelayDeletionResult(
                deletedEventIds: eventIds,
                targetRelayURLs: DefaultRelays.all,
                publishedSuccessfully: true,
                publishError: nil
            )
        } catch {
            return RelayDeletionResult(
                deletedEventIds: eventIds,
                targetRelayURLs: DefaultRelays.all,
                publishedSuccessfully: false,
                publishError: error.localizedDescription
            )
        }
    }
}

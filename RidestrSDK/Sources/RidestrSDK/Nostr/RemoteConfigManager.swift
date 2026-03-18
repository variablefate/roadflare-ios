import Foundation

/// Parsed admin configuration from Kind 30182.
public struct AdminConfig: Codable, Sendable {
    public let fareRateUsdPerMile: Decimal
    public let minimumFareUsd: Decimal
    public let roadflareFareRateUsdPerMile: Decimal
    public let roadflareMinimumFareUsd: Decimal
    public let recommendedMints: [MintOption]

    enum CodingKeys: String, CodingKey {
        case fareRateUsdPerMile = "fare_rate_usd_per_mile"
        case minimumFareUsd = "minimum_fare_usd"
        case roadflareFareRateUsdPerMile = "roadflare_fare_rate_usd_per_mile"
        case roadflareMinimumFareUsd = "roadflare_minimum_fare_usd"
        case recommendedMints = "recommended_mints"
    }

    public init(
        fareRateUsdPerMile: Decimal = AdminConstants.defaultFareRateUsdPerMile,
        minimumFareUsd: Decimal = AdminConstants.defaultMinimumFareUsd,
        roadflareFareRateUsdPerMile: Decimal = AdminConstants.defaultRoadflareFareRateUsdPerMile,
        roadflareMinimumFareUsd: Decimal = AdminConstants.defaultRoadflareMinimumFareUsd,
        recommendedMints: [MintOption] = []
    ) {
        self.fareRateUsdPerMile = fareRateUsdPerMile
        self.minimumFareUsd = minimumFareUsd
        self.roadflareFareRateUsdPerMile = roadflareFareRateUsdPerMile
        self.roadflareMinimumFareUsd = roadflareMinimumFareUsd
        self.recommendedMints = recommendedMints
    }

    /// Convert to a FareConfig for use with FareCalculator.
    public func toFareConfig() -> FareConfig {
        FareConfig(
            baseFareUsd: AdminConstants.roadflareBaseFareUsd,
            rateUsdPerMile: roadflareFareRateUsdPerMile,
            minimumFareUsd: roadflareMinimumFareUsd
        )
    }
}

/// A recommended Cashu mint (future use).
public struct MintOption: Codable, Sendable {
    public let name: String
    public let url: String
    public let description: String?
    public let recommended: Bool?
}

/// Fetches and caches admin configuration from Kind 30182 Nostr events.
public actor RemoteConfigManager {
    private let relayManager: any RelayManagerProtocol
    private var cachedConfig: AdminConfig?
    private var lastFetchTime: Date?

    public init(relayManager: any RelayManagerProtocol) {
        self.relayManager = relayManager
    }

    /// Get the current config, fetching from relay if not cached.
    public func getConfig() async -> AdminConfig {
        if let cached = cachedConfig { return cached }
        return await fetchConfig()
    }

    /// Fetch config from relay. Falls back to defaults on failure.
    @discardableResult
    public func fetchConfig() async -> AdminConfig {
        do {
            let filter = NostrFilter.remoteConfig()
            let events = try await relayManager.fetchEvents(
                filter: filter,
                timeout: RelayConstants.eoseTimeoutSeconds
            )

            // Find the most recent config event from the admin
            guard let event = events
                .filter({ $0.pubkey == AdminConstants.adminPubkey })
                .max(by: { $0.createdAt < $1.createdAt })
            else {
                return cachedConfig ?? AdminConfig()
            }

            let config = try JSONDecoder().decode(AdminConfig.self, from: Data(event.content.utf8))
            cachedConfig = config
            lastFetchTime = .now
            return config
        } catch {
            return cachedConfig ?? AdminConfig()
        }
    }

    /// Get the cached config without fetching. Returns defaults if no cache.
    public func getCachedOrDefault() -> AdminConfig {
        cachedConfig ?? AdminConfig()
    }

    /// Clear the cache (for testing or logout).
    public func clearCache() {
        cachedConfig = nil
        lastFetchTime = nil
    }
}

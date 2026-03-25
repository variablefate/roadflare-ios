import Foundation
import os

/// Fetches and caches the Bitcoin price in USD.
/// CoinGecko is the primary API, UTXOracle is the fallback (rate-limited to 1 call/hour).
/// Fetches on app start, then refreshes every hour.
///
/// ## Conversion:
/// - 1 BTC = 100,000,000 sats
/// - USD → sats: `dollars * 100_000_000 / btcPriceUsd`
/// - sats → USD: `sats * btcPriceUsd / 100_000_000`
@Observable
@MainActor
final class BitcoinPriceService {
    /// BTC price in whole USD (e.g., 90610 means $90,610 per BTC).
    private(set) var btcPriceUsd: Int?

    /// Test-only setter for btcPriceUsd.
    var btcPriceUsdForTesting: Int? {
        get { btcPriceUsd }
        set { btcPriceUsd = newValue }
    }
    private var refreshTask: Task<Void, Never>?
    private var lastUTXOracleCall: Date?
    private static let refreshInterval: TimeInterval = 3600  // 1 hour

    /// Fetch price immediately and start hourly refresh. Retries on failure.
    func start() {
        refreshTask?.cancel()
        refreshTask = Task {
            // Initial fetch with retry
            await fetchPrice()
            if btcPriceUsd == nil {
                // First attempt failed — retry after 10 seconds
                try? await Task.sleep(for: .seconds(10))
                await fetchPrice()
            }
            if btcPriceUsd == nil {
                // Still failed — retry after 30 seconds
                try? await Task.sleep(for: .seconds(30))
                await fetchPrice()
            }
            // Hourly refresh
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
                guard !Task.isCancelled else { break }
                await fetchPrice()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Convert USD dollars to satoshis. Returns nil if price not available.
    /// Uses Double arithmetic (matching Android) to avoid Decimal encoding issues.
    func usdToSats(_ dollars: Decimal) -> Int? {
        guard let price = btcPriceUsd, price > 0 else { return nil }
        let usd = NSDecimalNumber(decimal: dollars).doubleValue
        let sats = usd * 100_000_000.0 / Double(price)
        return Int(sats)
    }

    /// Convert satoshis to USD dollars. Returns nil if price not available.
    func satsToUsd(_ sats: Int) -> Decimal? {
        guard let price = btcPriceUsd, price > 0 else { return nil }
        let usd = Double(sats) * Double(price) / 100_000_000.0
        return Decimal(usd)
    }

    // MARK: - Private

    private func fetchPrice() async {
        // Try CoinGecko first (primary, no rate limit for free tier simple/price)
        if let price = await fetchFromCoinGecko() {
            btcPriceUsd = price
            AppLogger.auth.info("BTC price from CoinGecko: $\(price)")
            return
        }
        // Fallback to UTXOracle (rate-limited to 1 call per hour)
        if let price = await fetchFromUTXOracle() {
            btcPriceUsd = price
            AppLogger.auth.info("BTC price from UTXOracle: $\(price)")
            return
        }
        AppLogger.auth.info("All BTC price APIs failed")
    }

    /// CoinGecko (primary): `{ "bitcoin": { "usd": 90610.0 } }`
    private func fetchFromCoinGecko() async -> Int? {
        guard let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else {
                AppLogger.auth.info("CoinGecko API returned \(statusCode)")
                return nil
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let bitcoin = json?["bitcoin"] as? [String: Any]
            let price = bitcoin?["usd"] as? Double
            return price.map { Int($0) }
        } catch {
            AppLogger.auth.info("CoinGecko API error: \(error)")
            return nil
        }
    }

    /// UTXOracle (fallback, max 1 call per hour): `{ "price": 90610 }`
    private func fetchFromUTXOracle() async -> Int? {
        if let last = lastUTXOracleCall, Date.now.timeIntervalSince(last) < 3600 {
            return nil  // Rate limited
        }
        guard let url = URL(string: "https://api.utxoracle.io/latest.json") else { return nil }
        do {
            lastUTXOracleCall = .now
            let (data, response) = try await URLSession.shared.data(from: url)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else {
                AppLogger.auth.info("UTXOracle API returned \(statusCode)")
                return nil
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json?["price"] as? Int
        } catch {
            AppLogger.auth.info("UTXOracle API error: \(error)")
            return nil
        }
    }
}

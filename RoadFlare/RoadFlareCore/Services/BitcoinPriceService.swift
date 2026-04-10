import Foundation
import os

/// Fetches and caches the Bitcoin price in USD.
/// CoinGecko is the primary API, Coinbase is the fallback.
/// Fetches on app start, then refreshes every hour.
///
/// ## Conversion:
/// - 1 BTC = 100,000,000 sats
/// - USD → sats: `dollars * 100_000_000 / btcPriceUsd`
/// - sats → USD: `sats * btcPriceUsd / 100_000_000`
@Observable
@MainActor
public final class BitcoinPriceService {
    /// BTC price in whole USD (e.g., 90610 means $90,610 per BTC).
    public private(set) var btcPriceUsd: Int?

    /// Test-only setter for btcPriceUsd.
    public var btcPriceUsdForTesting: Int? {
        get { btcPriceUsd }
        set { btcPriceUsd = newValue }
    }
    private var refreshTask: Task<Void, Never>?
    private static let refreshInterval: TimeInterval = 3600  // 1 hour

    public init() {}

    /// Fetch price immediately and start hourly refresh. Retries on failure.
    public func start() {
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

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Convert USD dollars to satoshis. Returns nil if price not available.
    /// Uses Double arithmetic (matching Android) to avoid Decimal encoding issues.
    public func usdToSats(_ dollars: Decimal) -> Int? {
        guard let price = btcPriceUsd, price > 0 else { return nil }
        let usd = NSDecimalNumber(decimal: dollars).doubleValue
        let sats = usd * 100_000_000.0 / Double(price)
        return Int(sats)
    }

    /// Convert satoshis to USD dollars. Returns nil if price not available.
    public func satsToUsd(_ sats: Int) -> Decimal? {
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
        // Fallback to Coinbase
        if let price = await fetchFromCoinbase() {
            btcPriceUsd = price
            AppLogger.auth.info("BTC price from Coinbase: $\(price)")
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

    /// Coinbase (fallback): `{ "data": { "amount": "90610.00", ... } }`
    private func fetchFromCoinbase() async -> Int? {
        guard let url = URL(string: "https://api.coinbase.com/v2/prices/BTC-USD/spot") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else {
                AppLogger.auth.info("Coinbase API returned \(statusCode)")
                return nil
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let dataObj = json?["data"] as? [String: Any]
            let amountStr = dataObj?["amount"] as? String
            guard let amount = amountStr, let price = Double(amount) else { return nil }
            return Int(price)
        } catch {
            AppLogger.auth.info("Coinbase API error: \(error)")
            return nil
        }
    }
}

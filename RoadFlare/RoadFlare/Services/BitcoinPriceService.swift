import Foundation
import os

/// Fetches and caches the Bitcoin price in USD.
/// Uses UTXOracle as primary API with CoinGecko as fallback (matching Android).
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
    private var refreshTask: Task<Void, Never>?
    private static let refreshInterval: TimeInterval = 3600  // 1 hour

    private static let primaryURL = "https://api.utxoracle.io/latest.json"
    private static let backupURL = "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd"

    /// Fetch price immediately and start hourly refresh.
    func start() {
        refreshTask?.cancel()
        refreshTask = Task {
            await fetchPrice()
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
    func usdToSats(_ dollars: Decimal) -> Int? {
        guard let price = btcPriceUsd, price > 0 else { return nil }
        // dollars * 100_000_000 / price
        let sats = (dollars * 100_000_000) / Decimal(price)
        return NSDecimalNumber(decimal: sats).intValue
    }

    /// Convert satoshis to USD dollars. Returns nil if price not available.
    func satsToUsd(_ sats: Int) -> Decimal? {
        guard let price = btcPriceUsd, price > 0 else { return nil }
        return Decimal(sats) * Decimal(price) / 100_000_000
    }

    // MARK: - Private

    private func fetchPrice() async {
        // Try UTXOracle first
        if let price = await fetchFromUTXOracle() {
            btcPriceUsd = price
            AppLogger.auth.info("BTC price from UTXOracle: $\(price)")
            return
        }
        // Fallback to CoinGecko
        if let price = await fetchFromCoinGecko() {
            btcPriceUsd = price
            AppLogger.auth.info("BTC price from CoinGecko: $\(price)")
            return
        }
        AppLogger.auth.info("All BTC price APIs failed")
    }

    /// UTXOracle: `{ "price": 90610, "updated_at": "..." }`
    private func fetchFromUTXOracle() async -> Int? {
        guard let url = URL(string: Self.primaryURL) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json?["price"] as? Int
        } catch {
            return nil
        }
    }

    /// CoinGecko: `{ "bitcoin": { "usd": 90610.0 } }`
    private func fetchFromCoinGecko() async -> Int? {
        guard let url = URL(string: Self.backupURL) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let bitcoin = json?["bitcoin"] as? [String: Any]
            let price = bitcoin?["usd"] as? Double
            return price.map { Int($0) }
        } catch {
            return nil
        }
    }
}

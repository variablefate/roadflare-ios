import Foundation
import Testing
@testable import RoadFlare

@Suite("BitcoinPriceService")
@MainActor
struct BitcoinPriceServiceTests {

    @Test("usdToSats with known BTC price")
    func usdToSatsBasic() {
        let service = BitcoinPriceService()
        service.btcPriceUsdForTesting = 100_000  // $100k per BTC

        // $1 = 100_000_000 / 100_000 = 1000 sats
        #expect(service.usdToSats(1) == 1000)

        // $10 = 10_000 sats
        #expect(service.usdToSats(10) == 10_000)

        // $21.05 = 21_050 sats
        #expect(service.usdToSats(Decimal(string: "21.05")!) == 21_050)

        // $0 = 0 sats
        #expect(service.usdToSats(0) == 0)
    }

    @Test("usdToSats at various BTC prices")
    func usdToSatsVariousPrices() {
        let service = BitcoinPriceService()

        // At $50k BTC
        service.btcPriceUsdForTesting = 50_000
        #expect(service.usdToSats(10) == 20_000)  // $10 = 20k sats

        // At $70,724 BTC (realistic price)
        service.btcPriceUsdForTesting = 70_724
        let sats = service.usdToSats(Decimal(string: "21.05")!)
        #expect(sats != nil)
        #expect(sats! > 29_000)  // ~29,762 sats
        #expect(sats! < 30_500)
    }

    @Test("usdToSats returns nil when price unavailable")
    func usdToSatsNilPrice() {
        let service = BitcoinPriceService()
        // btcPriceUsd is nil by default
        #expect(service.usdToSats(10) == nil)
    }

    @Test("usdToSats returns nil when price is zero")
    func usdToSatsZeroPrice() {
        let service = BitcoinPriceService()
        service.btcPriceUsdForTesting = 0
        #expect(service.usdToSats(10) == nil)
    }

    @Test("satsToUsd with known BTC price")
    func satsToUsdBasic() {
        let service = BitcoinPriceService()
        service.btcPriceUsdForTesting = 100_000

        // 1000 sats = $1
        let usd = service.satsToUsd(1000)
        #expect(usd != nil)
        #expect(NSDecimalNumber(decimal: usd!).doubleValue > 0.99)
        #expect(NSDecimalNumber(decimal: usd!).doubleValue < 1.01)

        // 21050 sats = $21.05
        let usd2 = service.satsToUsd(21_050)
        #expect(usd2 != nil)
        #expect(NSDecimalNumber(decimal: usd2!).doubleValue > 21.0)
        #expect(NSDecimalNumber(decimal: usd2!).doubleValue < 21.1)
    }

    @Test("satsToUsd returns nil when price unavailable")
    func satsToUsdNilPrice() {
        let service = BitcoinPriceService()
        #expect(service.satsToUsd(1000) == nil)
    }

    @Test("roundtrip: USD → sats → USD preserves value")
    func roundtrip() {
        let service = BitcoinPriceService()
        service.btcPriceUsdForTesting = 87_500

        let originalUsd = Decimal(string: "23.00")!
        guard let sats = service.usdToSats(originalUsd) else {
            Issue.record("usdToSats returned nil")
            return
        }
        #expect(sats > 0)

        guard let recoveredUsd = service.satsToUsd(sats) else {
            Issue.record("satsToUsd returned nil")
            return
        }

        let diff = abs(NSDecimalNumber(decimal: recoveredUsd).doubleValue - 23.0)
        #expect(diff < 0.02)  // Within 2 cents
    }

    @Test("large fare conversion doesn't overflow")
    func largeFare() {
        let service = BitcoinPriceService()
        service.btcPriceUsdForTesting = 70_000

        // $500 fare
        let sats = service.usdToSats(500)
        #expect(sats != nil)
        #expect(sats! > 700_000)
    }
}

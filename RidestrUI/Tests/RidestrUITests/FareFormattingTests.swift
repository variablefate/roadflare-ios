import Testing
import Foundation
@testable import RidestrUI

@Suite("FareFormatting")
struct FareFormattingTests {

    @Test("Formats standard fare")
    func standardFare() {
        let result = formatFare(Decimal(12.50))
        #expect(result.contains("12.50"))
    }

    @Test("Formats zero fare")
    func zeroFare() {
        let result = formatFare(Decimal(0))
        #expect(result.contains("0.00"))
    }

    @Test("Formats large fare")
    func largeFare() {
        let result = formatFare(Decimal(999.99))
        #expect(result.contains("999.99"))
    }

    @Test("Formats fare with currency symbol")
    func currencySymbol() {
        let result = formatFare(Decimal(25))
        #expect(result.contains("$"))
    }

    @Test("Formats with different currency code")
    func eurCurrency() {
        let result = formatFare(Decimal(15), currencyCode: "EUR")
        #expect(result.contains("15"))
    }

    @Test("Formats single digit cents correctly")
    func singleDigitCents() {
        let result = formatFare(Decimal(string: "7.05")!)
        #expect(result.contains("7.05"))
    }

    @Test("Two decimal places enforced")
    func twoDecimalPlaces() {
        let result = formatFare(Decimal(10))
        #expect(result.contains("10.00"))
    }
}

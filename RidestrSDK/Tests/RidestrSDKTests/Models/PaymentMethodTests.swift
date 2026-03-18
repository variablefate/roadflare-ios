import Foundation
import Testing
@testable import RidestrSDK

@Suite("PaymentMethod Tests")
struct PaymentMethodTests {
    @Test func rawValues() {
        #expect(PaymentMethod.zelle.rawValue == "zelle")
        #expect(PaymentMethod.paypal.rawValue == "paypal")
        #expect(PaymentMethod.cashApp.rawValue == "cash_app")
        #expect(PaymentMethod.venmo.rawValue == "venmo")
        #expect(PaymentMethod.strike.rawValue == "strike")
        #expect(PaymentMethod.cash.rawValue == "cash")
    }

    @Test func displayNames() {
        #expect(PaymentMethod.zelle.displayName == "Zelle")
        #expect(PaymentMethod.cashApp.displayName == "Cash App")
    }

    @Test func findCommonFirstMatch() {
        let rider: [PaymentMethod] = [.zelle, .venmo, .cash]
        let driver: [PaymentMethod] = [.paypal, .venmo, .cash]
        let common = PaymentMethod.findCommon(riderPreferences: rider, driverAccepted: driver)
        #expect(common == .venmo)  // First in rider's list that driver accepts
    }

    @Test func findCommonRiderPriorityWins() {
        let rider: [PaymentMethod] = [.cash, .venmo]
        let driver: [PaymentMethod] = [.venmo, .cash]
        let common = PaymentMethod.findCommon(riderPreferences: rider, driverAccepted: driver)
        #expect(common == .cash)  // Rider prefers cash, driver accepts it
    }

    @Test func findCommonNoMatch() {
        let rider: [PaymentMethod] = [.zelle]
        let driver: [PaymentMethod] = [.venmo]
        let common = PaymentMethod.findCommon(riderPreferences: rider, driverAccepted: driver)
        #expect(common == nil)
    }

    @Test func findCommonEmptyLists() {
        #expect(PaymentMethod.findCommon(riderPreferences: [], driverAccepted: [.cash]) == nil)
        #expect(PaymentMethod.findCommon(riderPreferences: [.cash], driverAccepted: []) == nil)
    }

    @Test func codableRoundtrip() throws {
        let method = PaymentMethod.cashApp
        let data = try JSONEncoder().encode(method)
        let decoded = try JSONDecoder().decode(PaymentMethod.self, from: data)
        #expect(decoded == method)

        // Verify raw value in JSON
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("cash_app"))
    }
}

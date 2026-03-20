import Foundation

/// Format a Decimal fare as a currency string (e.g., "$12.50").
func formatFare(_ fare: Decimal, currencyCode: String = "USD") -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currencyCode
    formatter.maximumFractionDigits = 2
    formatter.minimumFractionDigits = 2
    return formatter.string(from: fare as NSDecimalNumber) ?? "$\(fare)"
}

import SwiftUI
import RidestrSDK

/// Displays a fare estimate with optional payment method badges.
public struct FareEstimateView: View {
    public let estimate: FareEstimate
    public var paymentMethods: [String]
    public var displayMode: DisplayMode

    public enum DisplayMode: Sendable {
        case compact  // "5.5 mi" left, "$12.50" right
        case card     // Full card with label, divider, payment badges
    }

    public init(
        estimate: FareEstimate,
        paymentMethods: [String] = [],
        displayMode: DisplayMode = .card
    ) {
        self.estimate = estimate
        self.paymentMethods = paymentMethods
        self.displayMode = displayMode
    }

    @Environment(\.ridestrTheme) private var theme

    public var body: some View {
        switch displayMode {
        case .compact:
            compactView
        case .card:
            cardView
        }
    }

    private var compactView: some View {
        HStack {
            Text(String(format: "%.1f mi", estimate.distanceMiles))
                .font(theme.caption())
                .foregroundColor(theme.onSurfaceSecondaryColor)
            Spacer()
            Text(formatFare(estimate.fareUSD))
                .font(theme.headline(24))
                .foregroundColor(theme.accentColor)
        }
        .themedCard()
    }

    private var cardView: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Fare")
                    .font(theme.body(15))
                    .foregroundColor(theme.onSurfaceSecondaryColor)
                Spacer()
                Text(formatFare(estimate.fareUSD))
                    .font(theme.headline(24))
                    .foregroundColor(theme.accentColor)
            }

            if !paymentMethods.isEmpty {
                Rectangle()
                    .fill(theme.onSurfaceSecondaryColor.opacity(0.2))
                    .frame(height: 1)

                HStack(spacing: 8) {
                    ForEach(paymentMethods, id: \.self) { method in
                        Text(PaymentMethod.displayName(for: method))
                            .font(theme.caption(12))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(theme.onSurfaceSecondaryColor.opacity(0.12))
                            .foregroundColor(theme.onSurfaceSecondaryColor)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .themedCard()
    }
}

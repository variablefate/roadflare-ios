import SwiftUI

/// Displays a 4-digit ride verification PIN prominently.
///
/// Used by the rider to show to the driver at pickup. The driver enters this PIN
/// on their device to verify rider identity (Ridestr protocol requirement).
///
/// Customizable via `RidestrTheme`: accent color, surface color, corner radius, font design.
public struct PINDisplayView: View {
    public let pin: String

    public init(pin: String) {
        self.pin = pin
    }

    @Environment(\.ridestrTheme) private var theme

    public var body: some View {
        Text(pin)
            .font(theme.display(72))
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .background(theme.surfaceSecondaryColor)
            .clipShape(RoundedRectangle(cornerRadius: theme.cardCornerRadius + 4))
            .themedShadow()
            .accessibilityLabel("Your ride PIN is \(pin.map(String.init).joined(separator: " "))")
            .accessibilityHint("Show this number to your driver")
    }
}

#Preview {
    PINDisplayView(pin: "4821")
        .padding()
}

#Preview("Custom Theme") {
    PINDisplayView(pin: "1234")
        .padding()
        .background(Color.black)
        .environment(\.ridestrTheme, RidestrTheme(
            accentColor: .orange,
            surfaceSecondaryColor: .gray,
            fontDesign: .rounded
        ))
}

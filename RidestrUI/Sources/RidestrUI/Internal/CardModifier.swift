import SwiftUI

/// Card background modifier that reads from RidestrTheme.
struct ThemedCardModifier: ViewModifier {
    @Environment(\.ridestrTheme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(theme.surfaceSecondaryColor)
            .clipShape(RoundedRectangle(cornerRadius: theme.cardCornerRadius))
    }
}

/// Ambient shadow with theme accent color.
struct ThemedShadowModifier: ViewModifier {
    @Environment(\.ridestrTheme) private var theme
    var radius: CGFloat = 24
    var opacity: Double = 0.15

    func body(content: Content) -> some View {
        content
            .shadow(color: theme.accentColor.opacity(opacity), radius: radius, x: 0, y: 12)
    }
}

extension View {
    func themedCard() -> some View {
        modifier(ThemedCardModifier())
    }

    func themedShadow(radius: CGFloat = 24, opacity: Double = 0.15) -> some View {
        modifier(ThemedShadowModifier(radius: radius, opacity: opacity))
    }
}

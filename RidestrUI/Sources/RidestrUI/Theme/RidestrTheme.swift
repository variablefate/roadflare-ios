import SwiftUI

/// Theme configuration for all RidestrUI components.
/// Inject via `.environment(\.ridestrTheme, myTheme)` to customize.
/// Defaults to system dynamic colors (works in light and dark mode).
public struct RidestrTheme: Sendable {
    public var accentColor: Color
    public var successColor: Color
    public var warningColor: Color
    public var errorColor: Color
    public var surfaceColor: Color
    public var surfaceSecondaryColor: Color
    public var onSurfaceColor: Color
    public var onSurfaceSecondaryColor: Color
    public var cardCornerRadius: CGFloat
    public var fontDesign: Font.Design

    #if os(iOS)
    public static let defaultSurface = Color(.systemBackground)
    public static let defaultSurfaceSecondary = Color(.secondarySystemBackground)
    public static let defaultOnSurface = Color(.label)
    public static let defaultOnSurfaceSecondary = Color(.secondaryLabel)
    #else
    public static let defaultSurface = Color.white
    public static let defaultSurfaceSecondary = Color(white: 0.95)
    public static let defaultOnSurface = Color.black
    public static let defaultOnSurfaceSecondary = Color.gray
    #endif

    public init(
        accentColor: Color = .blue,
        successColor: Color = .green,
        warningColor: Color = .yellow,
        errorColor: Color = .red,
        surfaceColor: Color = defaultSurface,
        surfaceSecondaryColor: Color = defaultSurfaceSecondary,
        onSurfaceColor: Color = defaultOnSurface,
        onSurfaceSecondaryColor: Color = defaultOnSurfaceSecondary,
        cardCornerRadius: CGFloat = 16,
        fontDesign: Font.Design = .default
    ) {
        self.accentColor = accentColor
        self.successColor = successColor
        self.warningColor = warningColor
        self.errorColor = errorColor
        self.surfaceColor = surfaceColor
        self.surfaceSecondaryColor = surfaceSecondaryColor
        self.onSurfaceColor = onSurfaceColor
        self.onSurfaceSecondaryColor = onSurfaceSecondaryColor
        self.cardCornerRadius = cardCornerRadius
        self.fontDesign = fontDesign
    }
}

// MARK: - Environment Key

private struct RidestrThemeKey: EnvironmentKey {
    static let defaultValue = RidestrTheme()
}

extension EnvironmentValues {
    public var ridestrTheme: RidestrTheme {
        get { self[RidestrThemeKey.self] }
        set { self[RidestrThemeKey.self] = newValue }
    }
}

// MARK: - Themed Font Helper

extension RidestrTheme {
    func display(_ size: CGFloat = 56) -> Font { .system(size: size, weight: .bold, design: fontDesign) }
    func headline(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .bold, design: fontDesign) }
    func title(_ size: CGFloat = 20) -> Font { .system(size: size, weight: .semibold, design: fontDesign) }
    func body(_ size: CGFloat = 16) -> Font { .system(size: size, weight: .regular, design: fontDesign) }
    func caption(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .medium, design: fontDesign) }
}

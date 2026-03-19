import SwiftUI

// MARK: - Color Palette: "The Kinetic Beacon"

extension Color {
    // Primary flare
    static let rfPrimary = Color(hex: 0xFF906C)
    static let rfPrimaryContainer = Color(hex: 0xFF784D)
    static let rfPrimaryDim = Color(hex: 0xFF7346)
    static let rfOnPrimary = Color.black

    // Secondary heat
    static let rfSecondary = Color(hex: 0xFF7076)
    static let rfTertiary = Color(hex: 0xFFC563)

    // Surface hierarchy (dark road)
    static let rfSurface = Color(hex: 0x0E0E0E)
    static let rfSurfaceContainerLowest = Color.black
    static let rfSurfaceContainerLow = Color(hex: 0x131313)
    static let rfSurfaceContainer = Color(hex: 0x1A1919)
    static let rfSurfaceContainerHigh = Color(hex: 0x201F1F)
    static let rfSurfaceContainerHighest = Color(hex: 0x262626)
    static let rfSurfaceVariant = Color(hex: 0x262626)

    // Text
    static let rfOnSurface = Color.white
    static let rfOnSurfaceVariant = Color(hex: 0xADAAAA)

    // Outlines
    static let rfOutlineVariant = Color(hex: 0x484847).opacity(0.15)

    // Status
    static let rfOnline = Color(hex: 0x4ADE80)
    static let rfOnRide = Color(hex: 0xFBBF24)
    static let rfOffline = Color(hex: 0x6B7280)
    static let rfError = Color(hex: 0xFF4444)

    // Hex initializer
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Gradients

extension LinearGradient {
    /// Primary "burning flare" gradient for hero CTAs.
    static let rfFlare = LinearGradient(
        colors: [.rfPrimary, .rfPrimaryDim],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Subtle surface gradient for cards.
    static let rfSurfaceGradient = LinearGradient(
        colors: [.rfSurfaceContainerHigh, .rfSurfaceContainer],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - Typography

struct RFFont {
    // Display — large, bold, mechanical (Space Grotesk when bundled, system rounded as fallback)
    static func display(_ size: CGFloat = 56) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }

    // Headline
    static func headline(_ size: CGFloat = 28) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }

    // Title
    static func title(_ size: CGFloat = 20) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    // Body
    static func body(_ size: CGFloat = 16) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }

    // Caption
    static func caption(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .medium, design: .default)
    }

    // Mono (for keys, pubkeys)
    static func mono(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}

// MARK: - Component Styles

/// Primary CTA button with flare gradient.
struct RFPrimaryButtonStyle: ButtonStyle {
    var isDisabled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RFFont.title(18))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                isDisabled
                    ? AnyShapeStyle(Color.rfSurfaceContainerHighest)
                    : AnyShapeStyle(LinearGradient.rfFlare)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Secondary button — outlined feel via tonal surface.
struct RFSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RFFont.title(16))
            .foregroundColor(Color.rfPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.rfSurfaceContainerHigh)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Ghost/text button.
struct RFGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RFFont.body(15))
            .foregroundColor(Color.rfOnSurfaceVariant)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}

// MARK: - Card Modifier

struct RFCardModifier: ViewModifier {
    var level: CardLevel = .standard

    enum CardLevel {
        case low, standard, high
        var color: Color {
            switch self {
            case .low: .rfSurfaceContainerLow
            case .standard: .rfSurfaceContainer
            case .high: .rfSurfaceContainerHigh
            }
        }
    }

    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(level.color)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

extension View {
    func rfCard(_ level: RFCardModifier.CardLevel = .standard) -> some View {
        modifier(RFCardModifier(level: level))
    }
}

// MARK: - Flare Indicator

/// Vertical orange bar on the leading edge — "The Flare Indicator" for active states.
struct FlareIndicator: View {
    var color: Color = .rfPrimary

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 4)
    }
}

// MARK: - Ambient Shadow

extension View {
    func rfAmbientShadow(color: Color = .rfSecondary, radius: CGFloat = 32, opacity: Double = 0.08) -> some View {
        self.shadow(color: color.opacity(opacity), radius: radius, x: 0, y: 12)
    }
}

// MARK: - Status Dot

struct StatusDot: View {
    let status: String

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
    }

    private var statusColor: Color {
        switch status {
        case "online": .rfOnline
        case "on_ride": .rfOnRide
        default: .rfOffline
        }
    }
}

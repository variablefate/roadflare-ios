/// RidestrUI — Drop-in SwiftUI components for Ridestr protocol flows.
///
/// ## Components
///
/// - ``RideStatusCard``: Stage-aware ride display with action callbacks.
///   Renders the correct UI for each ride stage (waiting, en route, arrived,
///   in progress, completed) following the Ridestr protocol lifecycle.
///
/// - ``PINDisplayView``: Large PIN display for rider pickup verification.
///   Shows a 4-digit PIN prominently with full VoiceOver support.
///
/// - ``PINEntryView``: PIN entry keypad for driver verification.
///   4-digit entry with auto-submit, error display, and attempt tracking.
///
/// - ``FareEstimateView``: Fare amount with payment method badges.
///   Compact (inline) or card (full) display modes.
///
/// ## Theming
///
/// All components read from ``RidestrTheme`` via SwiftUI environment.
/// Inject your brand's theme:
///
/// ```swift
/// RideStatusCard(stage: .driverArrived, pin: "1234")
///     .environment(\.ridestrTheme, RidestrTheme(
///         accentColor: .orange,
///         fontDesign: .rounded
///     ))
/// ```
///
/// Default theme uses system dynamic colors (light/dark mode compatible).
public enum RidestrUIVersion {
    public static let version = "0.1.0"
}

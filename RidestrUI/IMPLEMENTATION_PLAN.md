# RidestrUI Implementation Plan

## Status: VERIFIED & READY FOR EXECUTION
Last verified: 2026-03-19

## Overview

Extract reusable ride UI components from the RoadFlare app into the RidestrUI Swift Package.
Third-party developers can `import RidestrUI` to get protocol-correct ride flow UI with customizable theming.

## Architecture

- RidestrUI depends on RidestrSDK (for RiderStage, FareEstimate, PaymentMethod, RideStateMachine)
- RidestrUI does NOT depend on the RoadFlare app
- Theming via `RidestrTheme` environment value (neutral defaults, host app overrides)
- All action callbacks (cancel, chat, close) are closures — host app controls navigation

## Verified SDK Types (confirmed stable as of 2026-03-19)

- `RideStateMachine` — @Observable, `.stage: RiderStage`, `.pin: String?`, `.pinVerified: Bool`
- `RiderStage` — enum: idle, waitingForAcceptance, driverAccepted, rideConfirmed, enRoute, driverArrived, inProgress, completed
- `FareEstimate` — struct: distanceMiles, durationMinutes, fareUSD (Decimal), routeSummary
- `PaymentMethod` — enum: zelle, paypal, cashApp, venmo, strike, cash; `.displayName: String`
- New: `RideContext` (immutable ride data), `RideEvent` (transition events), `TransitionResult`

## Files to Create (in order)

### Step 1: Theme/RidestrTheme.swift
```swift
public struct RidestrTheme: Sendable {
    public var accentColor: Color          // default: .blue
    public var successColor: Color         // default: .green
    public var warningColor: Color         // default: .yellow
    public var errorColor: Color           // default: .red
    public var surfaceColor: Color         // default: .systemBackground
    public var surfaceSecondaryColor: Color // default: .secondarySystemBackground
    public var onSurfaceColor: Color       // default: .label
    public var onSurfaceSecondaryColor: Color // default: .secondaryLabel
    public var cardCornerRadius: CGFloat   // default: 16
    public var fontDesign: Font.Design     // default: .default
}
extension EnvironmentValues { @Entry var ridestrTheme: RidestrTheme }
```

### Step 2: Internal/FareFormatting.swift
- Copy `formatFare(_:)` from DesignSystem.swift
- Add `currencyCode` parameter (default "USD")

### Step 3: Internal/CardModifier.swift
- Card background modifier (reads surfaceSecondaryColor from theme)
- Ambient shadow modifier (reads accentColor from theme)

### Step 4: Components/PINDisplayView.swift
- Input: `pin: String`
- Large display font, accent-colored, rounded card background
- Accessibility: reads digits individually
- Theme-aware colors and corner radius

### Step 5: Components/PINEntryView.swift (NEW — for future driver app)
- Input: `onSubmit: (String) -> Void`, `errorMessage: String?`, `remainingAttempts: Int?`
- 4-digit entry with numeric input
- Theme-aware

### Step 6: Components/FareEstimateView.swift
- Input: `estimate: FareEstimate`, `paymentMethods: [PaymentMethod]`, `displayMode: .compact | .card`
- Compact: distance + fare on one line
- Card: full card with fare label, divider, payment method badges
- Uses formatFare() internally

### Step 7: Components/RideStatusCard.swift (THE BIG ONE)
```swift
public struct RideStatusCard: View {
    public let stage: RiderStage
    public let pin: String?
    public let fareEstimate: FareEstimate?
    public let paymentMethods: [PaymentMethod]
    public var onCancel: (() -> Void)?
    public var onChat: (() -> Void)?
    public var onCloseRide: (() -> Void)?
}
```
- Switches on stage to render:
  - .idle → EmptyView
  - .waitingForAcceptance → spinner + cancel
  - .driverAccepted/.rideConfirmed/.enRoute → "on the way" + chat/cancel
  - .driverArrived → PINDisplayView + chat/cancel
  - .inProgress → "ride in progress" + FareEstimateView + chat
  - .completed → "ride complete" + FareEstimateView + close button
- Stage ordering is NOT customizable
- Actions are closures (host app controls sheets/alerts/haptics)

### Step 8: Update RidestrUI.swift
- Module-level documentation
- Version bump

### Step 9: Update RideTab.swift (in RoadFlare app)
Replace lines 214-400 (5 stage views + paymentInfoCard + rideActionButtons) with:
```swift
case .idle:
    idleView
default:
    RideStatusCard(
        stage: stage,
        pin: coordinator?.stateMachine.pin,
        fareEstimate: coordinator?.currentFareEstimate,
        paymentMethods: appState.settings.paymentMethods,
        onCancel: { showCancelWarning = true },
        onChat: { showChat = true },
        onCloseRide: { Task { await coordinator?.cancelRide() }; reset() }
    )
    .environment(\.ridestrTheme, roadFlareTheme)
```

### Step 10: Tests
- RidestrThemeTests: defaults, environment injection
- FareFormattingTests: zero, negative, large, currency code
- PINDisplayViewTests: accessibility label verification
- RideStatusCardTests: correct sub-view rendered per stage

## What STAYS in RideTab (NOT extracted)
- idleView (driver selection, address autocomplete, fare calculation — app-specific)
- sendOffer() (MapKit geocoding, coordinator integration)
- onChange haptics (app-level UX)
- Toast error handling (app-level)
- Cancel confirmation alert (app-level)
- Navigation shell + toolbar

## RoadFlare Theme Injection
```swift
let roadFlareTheme = RidestrTheme(
    accentColor: .rfPrimary,          // Bitcoin orange
    successColor: .rfOnline,
    warningColor: .rfOnRide,
    errorColor: .rfError,
    surfaceColor: .rfSurface,
    surfaceSecondaryColor: .rfSurfaceContainer,
    onSurfaceColor: .rfOnSurface,
    onSurfaceSecondaryColor: .rfOnSurfaceVariant,
    cardCornerRadius: 16,
    fontDesign: .rounded
)
```

## Edge Cases
- stateMachine nil → stage defaults to .idle → RideStatusCard shows nothing
- pin nil → PINDisplayView not rendered (Optional guard)
- fareEstimate nil → FareEstimateView not rendered (Optional guard)
- paymentMethods empty → badges section hidden

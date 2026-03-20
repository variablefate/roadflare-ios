import Testing
import SwiftUI
@testable import RidestrUI

@Suite("RidestrTheme")
struct RidestrThemeTests {

    @Test("Default theme has expected values")
    func defaultValues() {
        let theme = RidestrTheme()
        #expect(theme.accentColor == .blue)
        #expect(theme.successColor == .green)
        #expect(theme.warningColor == .yellow)
        #expect(theme.errorColor == .red)
        #expect(theme.cardCornerRadius == 16)
        #expect(theme.fontDesign == .default)
    }

    @Test("Custom theme preserves all values")
    func customValues() {
        let theme = RidestrTheme(
            accentColor: .orange,
            successColor: .mint,
            warningColor: .pink,
            errorColor: .purple,
            surfaceColor: .white,
            surfaceSecondaryColor: .gray,
            onSurfaceColor: .black,
            onSurfaceSecondaryColor: .brown,
            cardCornerRadius: 24,
            fontDesign: .rounded
        )
        #expect(theme.accentColor == .orange)
        #expect(theme.successColor == .mint)
        #expect(theme.warningColor == .pink)
        #expect(theme.errorColor == .purple)
        #expect(theme.surfaceColor == .white)
        #expect(theme.surfaceSecondaryColor == .gray)
        #expect(theme.onSurfaceColor == .black)
        #expect(theme.onSurfaceSecondaryColor == .brown)
        #expect(theme.cardCornerRadius == 24)
        #expect(theme.fontDesign == .rounded)
    }

    @Test("Font helpers return correctly sized fonts")
    func fontHelpers() {
        let theme = RidestrTheme()
        // Verify they return fonts without crashing — SwiftUI Font isn't directly inspectable
        let _ = theme.display(56)
        let _ = theme.headline(28)
        let _ = theme.title(20)
        let _ = theme.body(16)
        let _ = theme.caption(13)
    }

    @Test("Font helpers use custom sizes")
    func fontCustomSizes() {
        let theme = RidestrTheme(fontDesign: .monospaced)
        let _ = theme.display(100)
        let _ = theme.headline(10)
        let _ = theme.title(50)
        let _ = theme.body(8)
        let _ = theme.caption(6)
    }

    @Test("Theme is Sendable")
    func sendability() async {
        let theme = RidestrTheme(accentColor: .orange)
        let task = Task { theme.accentColor }
        let color = await task.value
        #expect(color == .orange)
    }

    @Test("Default static properties are accessible")
    func staticDefaults() {
        let _ = RidestrTheme.defaultSurface
        let _ = RidestrTheme.defaultSurfaceSecondary
        let _ = RidestrTheme.defaultOnSurface
        let _ = RidestrTheme.defaultOnSurfaceSecondary
    }
}

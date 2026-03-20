import Testing
import SwiftUI
@testable import RidestrUI

@Suite("PINDisplayView")
@MainActor
struct PINDisplayViewTests {

    @Test("Initializes with pin string")
    func initialization() {
        let view = PINDisplayView(pin: "4821")
        #expect(view.pin == "4821")
    }

    @Test("Accepts any 4-digit string")
    func fourDigitPins() {
        let pins = ["0000", "1234", "9999", "0001"]
        for pin in pins {
            let view = PINDisplayView(pin: pin)
            #expect(view.pin == pin)
        }
    }

    @Test("PIN entry view calls onSubmit with digits")
    func pinEntrySubmit() {
        var submitted: String?
        let view = PINEntryView(onSubmit: { submitted = $0 })
        view.onSubmit("1234")
        #expect(submitted == "1234")
    }

    @Test("PIN entry accepts error message")
    func pinEntryError() {
        let view = PINEntryView(
            onSubmit: { _ in },
            errorMessage: "Wrong PIN",
            remainingAttempts: 2
        )
        #expect(view.errorMessage == "Wrong PIN")
        #expect(view.remainingAttempts == 2)
    }

    @Test("PIN entry nil error by default")
    func pinEntryDefaults() {
        let view = PINEntryView(onSubmit: { _ in })
        #expect(view.errorMessage == nil)
        #expect(view.remainingAttempts == nil)
    }
}

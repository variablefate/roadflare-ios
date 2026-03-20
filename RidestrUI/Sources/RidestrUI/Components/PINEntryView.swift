import SwiftUI

/// PIN entry keypad for the driver to verify the rider's identity at pickup.
///
/// Displays a 4-digit entry field. Calls `onSubmit` when all digits are entered.
public struct PINEntryView: View {
    public let onSubmit: (String) -> Void
    public var errorMessage: String?
    public var remainingAttempts: Int?

    public init(
        onSubmit: @escaping (String) -> Void,
        errorMessage: String? = nil,
        remainingAttempts: Int? = nil
    ) {
        self.onSubmit = onSubmit
        self.errorMessage = errorMessage
        self.remainingAttempts = remainingAttempts
    }

    @Environment(\.ridestrTheme) private var theme
    @State private var digits: String = ""
    @FocusState private var isFocused: Bool

    public var body: some View {
        VStack(spacing: 16) {
            // Digit display boxes
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { index in
                    let digit = index < digits.count ? String(digits[digits.index(digits.startIndex, offsetBy: index)]) : ""
                    Text(digit)
                        .font(theme.headline(32))
                        .foregroundColor(theme.onSurfaceColor)
                        .frame(width: 56, height: 64)
                        .background(theme.surfaceSecondaryColor)
                        .clipShape(RoundedRectangle(cornerRadius: theme.cardCornerRadius / 2))
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.cardCornerRadius / 2)
                                .stroke(digit.isEmpty ? theme.onSurfaceSecondaryColor.opacity(0.3) : theme.accentColor, lineWidth: 2)
                        )
                }
            }

            // Hidden text field for keyboard input
            TextField("", text: $digits)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .focused($isFocused)
                .opacity(0)
                .frame(height: 0)
                .onChange(of: digits) {
                    // Filter non-numeric characters (paste, macOS input)
                    let filtered = String(digits.filter(\.isNumber).prefix(4))
                    if filtered != digits { digits = filtered }
                    // Auto-submit on 4 digits
                    if digits.count == 4 {
                        onSubmit(digits)
                        digits = ""
                    }
                }

            if let error = errorMessage {
                Text(error)
                    .font(theme.caption())
                    .foregroundColor(theme.errorColor)
            }

            if let remaining = remainingAttempts {
                Text("\(remaining) attempt\(remaining == 1 ? "" : "s") remaining")
                    .font(theme.caption())
                    .foregroundColor(theme.onSurfaceSecondaryColor)
            }
        }
        .onAppear { isFocused = true }
        .accessibilityLabel("PIN entry")
        .accessibilityHint("Enter the 4-digit PIN shown by the rider")
    }
}

#Preview {
    PINEntryView(onSubmit: { pin in print("PIN: \(pin)") })
        .padding()
}

#Preview("With Error") {
    PINEntryView(
        onSubmit: { _ in },
        errorMessage: "Incorrect PIN",
        remainingAttempts: 2
    )
    .padding()
}

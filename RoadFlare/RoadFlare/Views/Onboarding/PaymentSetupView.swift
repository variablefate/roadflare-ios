import SwiftUI
import RidestrSDK

/// Onboarding step: choose which payment methods you have.
struct PaymentSetupView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "creditcard")
                        .font(.system(size: 50))
                        .foregroundStyle(.tint)

                    Text("Payment Methods")
                        .font(.title2.bold())

                    Text("Select all the payment methods you can use. Your driver will see these when you request a ride.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                PaymentMethodPicker(settings: appState.settings)
                    .padding(.horizontal)

                Spacer()

                VStack(spacing: 8) {
                    if appState.settings.paymentMethods.isEmpty {
                        Text("Select at least one payment method to continue")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Button {
                        if appState.settings.paymentMethods.isEmpty {
                            // Force cash if they try to continue with nothing
                            appState.settings.paymentMethods = [.cash]
                        }
                        appState.completePaymentSetup()
                    } label: {
                        Text("Continue")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }
}

/// Reusable payment method picker used in both onboarding and settings.
struct PaymentMethodPicker: View {
    @Bindable var settings: UserSettings

    var body: some View {
        VStack(spacing: 0) {
            ForEach(PaymentMethod.allCases, id: \.self) { method in
                let isEnabled = settings.isEnabled(method)
                let isCashLocked = method == .cash && settings.isCashForced

                Button {
                    if !isCashLocked {
                        settings.togglePaymentMethod(method)
                    }
                } label: {
                    HStack {
                        Image(systemName: iconName(for: method))
                            .frame(width: 24)
                            .foregroundColor(isEnabled ? .accentColor : .secondary)

                        Text(method.displayName)
                            .foregroundStyle(isCashLocked ? .secondary : .primary)

                        Spacer()

                        Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isEnabled ? .accentColor : .gray.opacity(0.3))
                            .font(.title3)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isCashLocked ? 0.5 : 1.0)

                if method != PaymentMethod.allCases.last {
                    Divider().padding(.leading, 56)
                }
            }
        }
        .background(.fill.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 12))

        if settings.isCashForced {
            Text("Cash is required when no other methods are selected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private func iconName(for method: PaymentMethod) -> String {
        switch method {
        case .zelle: "building.columns"
        case .paypal: "p.circle"
        case .cashApp: "dollarsign.square"
        case .venmo: "v.circle"
        case .strike: "bolt"
        case .cash: "banknote"
        }
    }
}

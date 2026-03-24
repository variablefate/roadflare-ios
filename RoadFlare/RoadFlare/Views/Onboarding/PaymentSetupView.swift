import SwiftUI
import RidestrSDK

struct PaymentSetupView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer().frame(height: 40)

                Image(systemName: "creditcard")
                    .font(.system(size: 50))
                    .foregroundColor(Color.rfPrimary)

                VStack(spacing: 8) {
                    Text("Payment Methods")
                        .font(RFFont.headline(24))
                        .foregroundColor(Color.rfOnSurface)
                    Text("Select all the payment methods you can use.\nYour driver will see these when you request a ride.")
                        .font(RFFont.body(14))
                        .foregroundColor(Color.rfOnSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                PaymentMethodPicker(settings: appState.settings)
                    .padding(.horizontal, 24)

                Spacer()

                VStack(spacing: 8) {
                    if appState.settings.paymentMethods.isEmpty {
                        Text("Select at least one payment method to continue")
                            .font(RFFont.caption())
                            .foregroundColor(Color.rfTertiary)
                    }

                    Button {
                        if appState.settings.paymentMethods.isEmpty {
                            appState.settings.paymentMethods = [.cash]
                        }
                        Task { await appState.completePaymentSetup() }
                    } label: {
                        Text("Continue")
                    }
                    .buttonStyle(RFPrimaryButtonStyle())
                    .padding(.horizontal, 24)
                }

                Spacer().frame(height: 20)
            }
        }
    }
}

struct PaymentMethodPicker: View {
    @Bindable var settings: UserSettings

    var body: some View {
        VStack(spacing: 0) {
            ForEach(PaymentMethod.allCases, id: \.self) { method in
                let isEnabled = settings.isEnabled(method)
                let isCashLocked = method == .cash && settings.isCashForced

                Button {
                    if !isCashLocked { settings.togglePaymentMethod(method) }
                } label: {
                    HStack(spacing: 12) {
                        // Flare indicator for active methods
                        if isEnabled {
                            FlareIndicator()
                                .frame(height: 24)
                        } else {
                            Color.clear.frame(width: 4, height: 24)
                        }

                        Image(systemName: iconName(for: method))
                            .frame(width: 24)
                            .foregroundColor(isEnabled ? Color.rfPrimary : Color.rfOffline)

                        Text(method.displayName)
                            .font(RFFont.body())
                            .foregroundColor(isCashLocked ? Color.rfOnSurfaceVariant : Color.rfOnSurface)

                        Spacer()

                        Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isEnabled ? Color.rfPrimary : Color.rfOffline)
                            .font(.title3)
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isCashLocked ? 0.5 : 1.0)
            }
        }
        .background(Color.rfSurfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 16))

        if settings.isCashForced {
            Text("Cash is required when no other methods are selected")
                .font(RFFont.caption(12))
                .foregroundColor(Color.rfOnSurfaceVariant)
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

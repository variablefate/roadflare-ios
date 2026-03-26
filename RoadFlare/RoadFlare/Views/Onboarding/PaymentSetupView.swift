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
                    Text("Select the payment methods you can use.\nYour driver will see these when you request a ride.")
                        .font(RFFont.body(14))
                        .foregroundColor(Color.rfOnSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                PaymentMethodPicker(settings: appState.settings)
                    .padding(.horizontal, 24)

                Spacer()

                VStack(spacing: 8) {
                    if appState.settings.roadflarePaymentMethods.isEmpty {
                        Text("Select at least one payment method to continue")
                            .font(RFFont.caption())
                            .foregroundColor(Color.rfTertiary)
                    }

                    Button {
                        if appState.settings.roadflarePaymentMethods.isEmpty {
                            appState.settings.setRoadflarePaymentMethods([PaymentMethod.cash.rawValue])
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
    private struct CustomMethodError: Identifiable {
        let id: String
        let message: String
    }

    @Bindable var settings: UserSettings
    @State private var showAddCustom = false
    @State private var customName = ""
    @State private var customMethodError: CustomMethodError?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !settings.roadflarePaymentMethods.isEmpty {
                Text("Priority order matters. Your first method is sent as the primary RoadFlare payment method.")
                    .font(RFFont.caption(12))
                    .foregroundColor(Color.rfOnSurfaceVariant)
                    .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    ForEach(Array(settings.roadflarePaymentMethods.enumerated()), id: \.element) { index, method in
                        activeMethodRow(method: method, index: index)
                    }
                }
                .background(Color.rfSurfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            VStack(spacing: 0) {
                ForEach(disabledMethods, id: \.self) { method in
                    disabledMethodRow(method: method)
                }

                customSection
            }
            .background(Color.rfSurfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .alert(item: $customMethodError) { error in
            Alert(
                title: Text("Payment Method Not Added"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var disabledMethods: [String] {
        settings.roadflareMethodChoices.filter { !settings.isRoadflareMethodEnabled($0) }
    }

    private func activeMethodRow(method: String, index: Int) -> some View {
        HStack(spacing: 12) {
            FlareIndicator()
                .frame(height: 24)

            Image(systemName: iconName(for: method))
                .frame(width: 24)
                .foregroundColor(Color.rfPrimary)

            VStack(alignment: .leading, spacing: 4) {
                Text(PaymentMethod.displayName(for: method))
                    .font(RFFont.body())
                    .foregroundColor(Color.rfOnSurface)

                if index == 0 {
                    Text("Primary")
                        .font(RFFont.caption(11))
                        .foregroundColor(Color.rfPrimary)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                reorderButton(systemName: "arrow.up", disabled: index == 0) {
                    moveMethod(at: index, offset: -1)
                }
                reorderButton(systemName: "arrow.down", disabled: index == settings.roadflarePaymentMethods.count - 1) {
                    moveMethod(at: index, offset: 1)
                }
                Button {
                    settings.toggleRoadflarePaymentMethod(method)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(Color.rfOffline)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
    }

    private func disabledMethodRow(method: String) -> some View {
        Button {
            settings.toggleRoadflarePaymentMethod(method)
        } label: {
            HStack(spacing: 12) {
                Color.clear.frame(width: 4, height: 24)

                Image(systemName: iconName(for: method))
                    .frame(width: 24)
                    .foregroundColor(Color.rfOffline)

                Text(PaymentMethod.displayName(for: method))
                    .font(RFFont.body())
                    .foregroundColor(Color.rfOnSurface)

                Spacer()

                Image(systemName: "plus.circle")
                    .foregroundColor(Color.rfPrimary)
                    .font(.title3)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func reorderButton(systemName: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .foregroundColor(disabled ? Color.rfOffline : Color.rfOnSurfaceVariant)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func moveMethod(at index: Int, offset: Int) {
        let destination = index + offset
        guard settings.roadflarePaymentMethods.indices.contains(index),
              settings.roadflarePaymentMethods.indices.contains(destination) else { return }

        var reordered = settings.roadflarePaymentMethods
        reordered.swapAt(index, destination)
        settings.setRoadflarePaymentMethods(reordered)
    }

    // Custom payment methods
    private var customSection: some View {
        VStack(spacing: 0) {
            Button { showAddCustom = true } label: {
                HStack(spacing: 12) {
                    Color.clear.frame(width: 4, height: 24)

                    Image(systemName: "plus.circle")
                        .frame(width: 24)
                        .foregroundColor(Color.rfOnSurfaceVariant)

                    Text("Add Custom Payment Method")
                        .font(RFFont.body())
                        .foregroundColor(Color.rfOnSurfaceVariant)

                    Spacer()
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .alert("Custom Payment Method", isPresented: $showAddCustom) {
            TextField("e.g., Apple Pay, Venmo Business", text: $customName)
            Button("Add") {
                switch settings.addCustomPaymentMethod(customName) {
                case .added:
                    customName = ""
                case .empty:
                    customMethodError = CustomMethodError(
                        id: "empty",
                        message: "Enter a payment method name first."
                    )
                case .duplicate:
                    customMethodError = CustomMethodError(
                        id: "duplicate-\(customName.lowercased())",
                        message: "\"\(customName.trimmingCharacters(in: .whitespacesAndNewlines))\" is already in your list."
                    )
                }
            }
            Button("Cancel", role: .cancel) { customName = "" }
        } message: {
            Text("Enter the name of the payment method")
        }
    }

    private func iconName(for rawMethod: String) -> String {
        switch PaymentMethod(rawValue: rawMethod) {
        case .zelle: "building.columns"
        case .paypal: "p.circle"
        case .cashApp: "dollarsign.square"
        case .venmo: "v.circle"
        case .strike: "bolt"
        case .cash: "banknote"
        case .bitcoin: "bitcoinsign.circle"
        case nil: "tag"
        }
    }
}

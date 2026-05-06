import SwiftUI
import RidestrSDK
import RoadFlareCore

/// Full-screen payment methods management. Navigated from Settings.
struct PaymentMethodsScreen: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    PaymentMethodPicker(settings: appState.settings)
                        .onChange(of: appState.settings.roadflarePaymentMethods) { oldValue, newValue in
                            guard oldValue != newValue, appState.authState == .ready else { return }
                            Task { try? await appState.publishProfileBackup() }
                        }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Payment Methods")
        .toolbarBackground(Color.rfSurface, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

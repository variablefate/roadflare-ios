import SwiftUI

/// Root view that switches between auth states.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.authState {
        case .loading:
            ProgressView("Loading...")

        case .loggedOut:
            WelcomeView()

        case .profileIncomplete:
            ProfileSetupView()

        case .paymentSetup:
            PaymentSetupView()

        case .ready:
            MainTabView()
        }
    }
}

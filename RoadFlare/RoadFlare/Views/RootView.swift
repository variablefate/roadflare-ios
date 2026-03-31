import SwiftUI

/// Root view that switches between auth states.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.authState {
        case .loading:
            LaunchLoadingView()

        case .loggedOut:
            WelcomeView()

        case .syncing:
            SyncScreen()

        case .profileIncomplete:
            ProfileSetupView()

        case .paymentSetup:
            PaymentSetupView()

        case .ready:
            MainTabView()
        }
    }
}

// MARK: - Launch Loading View

private struct LaunchLoadingView: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()

            VStack(spacing: 32) {
                Image("LaunchMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120)
                    .scaleEffect(pulse ? 1.06 : 0.94)
                    .opacity(pulse ? 1.0 : 0.7)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)

                ProgressView()
                    .tint(Color.rfPrimary)
                    .scaleEffect(1.2)
            }
        }
        .onAppear { pulse = true }
    }
}

import SwiftUI
import RoadFlareCore

/// Root view that switches between auth states.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            if case .failed(let domain) = appState.onboardingPublishStatus {
                OnboardingPublishFailureBanner(domain: domain) {
                    appState.retryOnboardingPublish()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            authStateContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Each `authStateContent` view paints its own `Color.rfSurface
        // .ignoresSafeArea()` background, but that only extends adjacent to
        // its own frame — when the banner is showing, the strip above the
        // banner (status bar / Dynamic Island zone) is no longer adjacent
        // to the auth-state content, so the system default would bleed
        // through. Painting `rfSurface` behind the whole VStack keeps the
        // status-bar zone on-brand in both banner-visible and banner-
        // hidden states.
        .background(Color.rfSurface.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: appState.onboardingPublishStatus)
    }

    @ViewBuilder
    private var authStateContent: some View {
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
                    .accessibilityLabel("Loading")
            }
        }
        .onAppear { pulse = true }
    }
}

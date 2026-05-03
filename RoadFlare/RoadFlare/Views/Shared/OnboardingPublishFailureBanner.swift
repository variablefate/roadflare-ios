import SwiftUI
import RoadFlareCore

/// Top-of-RootView banner shown when an onboarding-domain publish has been
/// stuck in the dirty state for longer than the watchdog window with the
/// relay reachable. The banner is the user-visible counterpart to ADR-0014's
/// optimistic-transition contract — without it, a publish that silently
/// fails on a relay-broken network leaves the user in `.ready` with no
/// indication that their profile or settings haven't been backed up.
///
/// Tap "Retry" to re-invoke the publish and re-arm the watchdog. The
/// banner self-dismisses (status returns to `.idle`) on retry success.
struct OnboardingPublishFailureBanner: View {
    let domain: OnboardingPublishDomain
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Color.rfError)
                .font(.system(size: 18))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't reach the relay")
                    .font(RFFont.title(13))
                    .foregroundColor(Color.rfOnSurface)
                Text(detailText)
                    .font(RFFont.caption(12))
                    .foregroundColor(Color.rfOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Couldn't reach the relay. \(detailText)")

            Spacer(minLength: 8)

            Button(action: onRetry) {
                Text("Retry")
                    .font(RFFont.title(13))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.rfPrimary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry publish")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.rfSurfaceContainer)
    }

    private var detailText: String {
        switch domain {
        case .profile:
            "Your profile hasn't been backed up yet."
        case .settingsBackup:
            "Your profile and settings haven't been backed up yet."
        }
    }
}

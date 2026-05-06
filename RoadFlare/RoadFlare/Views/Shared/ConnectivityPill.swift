import SwiftUI
import RoadFlareCore

/// Top-of-RootView pill shown whenever the relay is not reachable. Stacks
/// above the onboarding publish-failure banner (ADR-0016) so the user sees
/// the connection state first, then the specific consequence.
///
/// Tapping the pill presents `ConnectivitySheet` for diagnostics + manual
/// reconnect — the same sheet the per-tab toolbar buttons already open. The
/// pill is global so the user does not have to be on a specific tab to spot
/// connectivity issues.
///
/// Hidden during `.loading` because the relay manager isn't configured yet
/// at that point; the launch screen would otherwise flash the pill for a
/// fraction of a second on every cold start. Per-tab inline offline UI
/// (e.g. the empty states in `RideTab`/`DriversTab`/`HistoryTab`) is
/// intentionally retained — those communicate per-tab consequences, this
/// pill communicates global state.
struct ConnectivityPill: View {
    @Environment(AppState.self) private var appState
    @State private var isOffline = false
    @State private var showSheet = false

    /// Polling cadence matches `ConnectivitySheet`'s own self-refresh loop.
    private static let pollIntervalSeconds: UInt64 = 5

    var body: some View {
        ZStack {
            if isOffline && appState.authState != .loading {
                pillBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isOffline)
        .sheet(isPresented: $showSheet) { ConnectivitySheet() }
        .task { await pollLoop() }
    }

    private var pillBar: some View {
        Button {
            showSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "wifi.slash")
                    .foregroundColor(Color.rfOffline)
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityHidden(true)

                Text("You're offline")
                    .font(RFFont.title(13))
                    .foregroundColor(Color.rfOnSurface)

                Text("Tap for details")
                    .font(RFFont.caption(12))
                    .foregroundColor(Color.rfOnSurfaceVariant)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.rfSurfaceContainer)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You're offline. Tap for connectivity details.")
        .accessibilityAddTraits(.isButton)
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            isOffline = !(await appState.isRelayConnected())
            try? await Task.sleep(nanoseconds: Self.pollIntervalSeconds * 1_000_000_000)
        }
    }
}

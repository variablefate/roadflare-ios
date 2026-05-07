import Foundation
import Network

/// Owns the periodic relay connection watchdog task and a path-change
/// reactive signal.
///
/// Two complementary mechanisms drive reconnects:
///
/// 1. **Periodic watchdog** — polls `isConnected` on a fixed interval and
///    triggers reconnect when it returns false. Bounded latency for any
///    drop the relay manager has noticed.
///
/// 2. **`NWPathMonitor` reactive signal** — fires whenever iOS observes a
///    network path change (Wi-Fi/cellular swap, airplane mode toggle,
///    captive portal). Forces a reconnect immediately, bypassing the
///    `isConnected` gate, because the previous connection's cached state
///    is by definition suspect after a path change. rust-nostr's
///    per-relay status doesn't update until its next read/write fails,
///    which can take minutes on a silently-killed socket — the OS-level
///    signal is much faster.
///
/// All behavior is injected via closures so the coordinator has no
/// direct dependencies on AppState or SDK services.
@MainActor
final class ConnectionCoordinator {
    private var watchdogTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var pathMonitorQueue: DispatchQueue?
    /// Most recently spawned path-event reconnect Task. `isReconnecting`
    /// already serializes path-spawned reconnects (a second event during an
    /// in-flight reconnect short-circuits via the guard), so at most one
    /// such Task is doing real work at any moment — tracking the latest
    /// is sufficient to cancel an in-flight reconnect on `stop()` (e.g.
    /// logout / identity replacement). Mirrors the tracked-Task pattern
    /// from PR #95's onboarding-publish watchdog.
    private var pathReconnectTask: Task<Void, Never>?
    private var hasReceivedFirstPath = false
    private var isReconnecting = false

    /// Start the periodic watchdog and the path-change reactive signal.
    ///
    /// - Parameters:
    ///   - interval: Time between connectivity checks.
    ///   - shouldReconnect: Return `true` when the app is in a state that needs a relay (e.g. `.ready`).
    ///   - isConnected: Async check for current relay connectivity.
    ///   - reconnect: Async action to reconnect relays and restore subscriptions.
    func start(
        interval: Duration,
        shouldReconnect: @escaping @MainActor () -> Bool,
        isConnected: @escaping @MainActor () async -> Bool,
        reconnect: @escaping @MainActor () async -> Void
    ) {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !self.isReconnecting, shouldReconnect() else { continue }
                guard !(await isConnected()) else { continue }
                self.isReconnecting = true
                defer { self.isReconnecting = false }
                await reconnect()
            }
        }

        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.roadflare.connection-coordinator.path-monitor")
        monitor.pathUpdateHandler = { [weak self] _ in
            // The very first path update fires on monitor start with the
            // current path — not a real change in production paths. Skip
            // it to avoid a spurious rebuild on app launch right after
            // `setupServices` has established the initial connection.
            // (Apple's `NWPathMonitor` documentation does not strictly
            // contract this, but it is the consistently observed behavior
            // for `start(queue:)` and is widely relied on across iOS apps.)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.hasReceivedFirstPath {
                    self.hasReceivedFirstPath = true
                    return
                }
                guard !self.isReconnecting, shouldReconnect() else { return }
                self.pathReconnectTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard !Task.isCancelled else { return }
                    self.isReconnecting = true
                    defer { self.isReconnecting = false }
                    await reconnect()
                }
            }
        }
        monitor.start(queue: queue)
        self.pathMonitor = monitor
        self.pathMonitorQueue = queue
    }

    /// Stop the watchdog, cancel the path monitor, and any in-flight reconnection.
    func stop() {
        watchdogTask?.cancel()
        watchdogTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        pathMonitorQueue = nil
        pathReconnectTask?.cancel()
        pathReconnectTask = nil
        hasReceivedFirstPath = false
        isReconnecting = false
    }
}

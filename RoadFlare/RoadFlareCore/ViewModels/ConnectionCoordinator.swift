import Foundation

/// Owns the periodic relay connection watchdog task.
///
/// Checks connectivity on a fixed interval and triggers reconnection
/// when the relay drops. All behavior is injected via closures so the
/// coordinator has no direct dependencies on AppState or SDK services.
@MainActor
final class ConnectionCoordinator {
    private var watchdogTask: Task<Void, Never>?
    private var isReconnecting = false

    /// Start the periodic watchdog.
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
    }

    /// Stop the watchdog and cancel any in-flight reconnection.
    func stop() {
        watchdogTask?.cancel()
        watchdogTask = nil
        isReconnecting = false
    }
}

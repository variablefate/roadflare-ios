import Foundation
import Observation

/// Tiny observable holder for the in-flight state of an async UI action.
///
/// Used by buttons whose tap kicks off async work that takes long enough that
/// the user needs explicit "working…" feedback (e.g. the system passkey sheet
/// has a 1-2s cold-start delay before it renders).
///
/// Pairs naturally with `defer { state.end() }` inside a Task so the loading
/// flag clears on the success, cancel, and error paths alike.
@MainActor
@Observable
public final class LoadingTaskState {

    public private(set) var isLoading: Bool = false

    public init() {}

    /// Atomically claims the in-flight slot. Returns `true` if the caller may
    /// proceed; returns `false` if a task is already running (debounces
    /// double-taps so the second tap is a no-op).
    @discardableResult
    public func begin() -> Bool {
        if isLoading { return false }
        isLoading = true
        return true
    }

    /// Releases the in-flight slot. Safe to call from any completion path.
    public func end() {
        isLoading = false
    }
}

import Testing
@testable import RoadFlareCore

// Pins the loading-state lifecycle used by the "Sign In with Passkey" button:
// begin() flips to loading, debounces double-taps, end() always resets — on
// success, on cancellation, and on error.

@Suite("LoadingTaskState")
@MainActor
struct LoadingTaskStateTests {

    @Test func initialStateIsNotLoading() {
        let state = LoadingTaskState()
        #expect(state.isLoading == false)
    }

    @Test func beginTransitionsToLoading() {
        let state = LoadingTaskState()
        let started = state.begin()
        #expect(started == true)
        #expect(state.isLoading == true)
    }

    @Test func beginIsRejectedWhenAlreadyLoading() {
        let state = LoadingTaskState()
        _ = state.begin()
        let secondAttempt = state.begin()
        #expect(secondAttempt == false)
        #expect(state.isLoading == true)
    }

    @Test func endResetsToIdle() {
        let state = LoadingTaskState()
        _ = state.begin()
        state.end()
        #expect(state.isLoading == false)
    }

    @Test func canRestartAfterCompletion() {
        let state = LoadingTaskState()
        _ = state.begin()
        state.end()
        let restart = state.begin()
        #expect(restart == true)
        #expect(state.isLoading == true)
    }

    @Test func happyPathLifecycleClearsLoading() async {
        let state = LoadingTaskState()
        let started = state.begin()
        #expect(started == true)
        #expect(state.isLoading == true)

        // Simulate the system passkey sheet appearing + auth completing.
        try? await Task.sleep(nanoseconds: 1_000_000)
        #expect(state.isLoading == true, "stays loading until end() is called")

        state.end()
        #expect(state.isLoading == false)
    }

    @Test func cancellationPathClearsLoading() async {
        let state = LoadingTaskState()
        _ = state.begin()
        #expect(state.isLoading == true)

        // Simulate user cancelling the system passkey sheet — the awaited
        // call throws, the caller still hits end() in its defer block.
        do {
            try await Task.sleep(nanoseconds: 500_000)
            throw CancellationError()
        } catch {
            state.end()
        }
        #expect(state.isLoading == false)
    }

    @Test func errorPathClearsLoading() async {
        struct StubError: Error {}
        let state = LoadingTaskState()
        _ = state.begin()

        do {
            try await Task.sleep(nanoseconds: 500_000)
            throw StubError()
        } catch {
            state.end()
        }
        #expect(state.isLoading == false)
    }
}

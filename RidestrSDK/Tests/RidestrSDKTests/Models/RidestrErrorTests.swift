import Foundation
import Testing
@testable import RidestrSDK

@Suite("RidestrError Tests")
struct RidestrErrorTests {
    @Test func errorDescriptions() {
        let errors: [RidestrError] = [
            .crypto(.invalidKey("bad key")),
            .ride(.invalidEvent("bad event")),
            .location(.invalidGeohash("bad hash")),
            .keychain(.osError(-25300)),
            .keychain(.dataCorrupted),
            .relay(.notConnected),
            .relay(.timeout),
            .ride(.stateMachineViolation(from: "idle", to: "inProgress")),
        ]

        for error in errors {
            // All errors should have non-nil descriptions
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    @Test func stateMachineViolationDescription() {
        let error = RidestrError.ride(.stateMachineViolation(from: "idle", to: "completed"))
        #expect(error.errorDescription!.contains("idle"))
        #expect(error.errorDescription!.contains("completed"))
    }

    @Test func keychainErrorIncludesStatus() {
        let error = RidestrError.keychain(.osError(-25300))
        #expect(error.errorDescription!.contains("-25300"))
    }

    @Test func wrappedErrorsIncludeUnderlying() {
        struct TestError: Error, LocalizedError {
            var errorDescription: String? { "test failure" }
        }
        let error = RidestrError.crypto(.encryptionFailed(underlying: TestError()))
        #expect(error.errorDescription!.contains("test failure"))
    }

    @Test func invalidKeyDetail() {
        let error = RidestrError.crypto(.invalidKey("wrong format"))
        #expect(error.errorDescription!.contains("wrong format"))
    }
}

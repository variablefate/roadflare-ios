import Foundation
import Testing
@testable import RidestrSDK

@Suite("RidestrError Tests")
struct RidestrErrorTests {
    @Test func errorDescriptions() {
        let errors: [RidestrError] = [
            .invalidKey("bad key"),
            .invalidEvent("bad event"),
            .invalidGeohash("bad hash"),
            .keychainError(-25300),
            .keychainDataCorrupted,
            .relayNotConnected,
            .relayTimeout,
            .rideStateMachineViolation(from: "idle", to: "inProgress"),
        ]

        for error in errors {
            // All errors should have non-nil descriptions
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    @Test func stateMachineViolationDescription() {
        let error = RidestrError.rideStateMachineViolation(from: "idle", to: "completed")
        #expect(error.errorDescription!.contains("idle"))
        #expect(error.errorDescription!.contains("completed"))
    }

    @Test func keychainErrorIncludesStatus() {
        let error = RidestrError.keychainError(-25300)
        #expect(error.errorDescription!.contains("-25300"))
    }

    @Test func wrappedErrorsIncludeUnderlying() {
        struct TestError: Error, LocalizedError {
            var errorDescription: String? { "test failure" }
        }
        let error = RidestrError.encryptionFailed(underlying: TestError())
        #expect(error.errorDescription!.contains("test failure"))
    }

    @Test func invalidKeyDetail() {
        let error = RidestrError.invalidKey("wrong format")
        #expect(error.errorDescription!.contains("wrong format"))
    }
}

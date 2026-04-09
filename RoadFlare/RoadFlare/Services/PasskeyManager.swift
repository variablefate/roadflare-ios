import AuthenticationServices
import CryptoKit
import SwiftUI
import RidestrSDK

/// Manages passkey-derived Nostr keys using the WebAuthn PRF extension (iOS 18+).
///
/// Flow:
/// 1. Create passkey → PRF with fixed salt → deterministic 32 bytes → secp256k1 private key
/// 2. On any device: authenticate with passkey → same PRF output → same Nostr key
/// 3. Passkey syncs via iCloud Keychain automatically
@MainActor @Observable
final class PasskeyManager: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    static let relyingPartyID = "roadflare.app"
    static let prfSalt = "nostr-key-v1".data(using: .utf8)!

    var isProcessing = false
    var error: String?

    private var registrationContinuation: CheckedContinuation<SymmetricKey, Error>?
    private var assertionContinuation: CheckedContinuation<SymmetricKey, Error>?

    // MARK: - Public API

    @available(iOS 18.0, *)
    func createPasskeyAndDeriveKey() async throws -> NostrKeypair {
        let prfKey = try await createPasskey()
        return try NostrKeypair.deriveFromSymmetricKey(prfKey)
    }

    @available(iOS 18.0, *)
    func authenticateAndDeriveKey() async throws -> NostrKeypair {
        let prfKey = try await authenticateWithPasskey()
        return try NostrKeypair.deriveFromSymmetricKey(prfKey)
    }

    // MARK: - Registration

    @available(iOS 18.0, *)
    private func createPasskey() async throws -> SymmetricKey {
        isProcessing = true
        error = nil
        defer { isProcessing = false }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: Self.relyingPartyID
        )

        var challengeBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &challengeBytes)
        var userIdBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &userIdBytes)

        let request = provider.createCredentialRegistrationRequest(
            challenge: Data(challengeBytes),
            name: "RoadFlare Nostr Key",
            userID: Data(userIdBytes)
        )

        // Attach PRF with salt
        let inputValues = ASAuthorizationPublicKeyCredentialPRFRegistrationInput.InputValues(
            saltInput1: Self.prfSalt
        )
        request.prf = .inputValues(inputValues)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        return try await withCheckedThrowingContinuation { continuation in
            self.registrationContinuation = continuation
            controller.performRequests()
        }
    }

    // MARK: - Assertion

    @available(iOS 18.0, *)
    private func authenticateWithPasskey() async throws -> SymmetricKey {
        isProcessing = true
        error = nil
        defer { isProcessing = false }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: Self.relyingPartyID
        )

        var challengeBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &challengeBytes)

        let request = provider.createCredentialAssertionRequest(
            challenge: Data(challengeBytes)
        )

        let inputValues = ASAuthorizationPublicKeyCredentialPRFAssertionInput.InputValues(
            saltInput1: Self.prfSalt
        )
        request.prf = .inputValues(inputValues)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        return try await withCheckedThrowingContinuation { continuation in
            self.assertionContinuation = continuation
            controller.performRequests()
        }
    }

    // MARK: - ASAuthorizationControllerDelegate

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            if #available(iOS 18.0, *) {
                if let registration = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration {
                    guard let prfOutput = registration.prf,
                          prfOutput.isSupported,
                          let prfBytes = prfOutput.first else {
                        registrationContinuation?.resume(throwing: PasskeyError.prfNotSupported)
                        registrationContinuation = nil
                        return
                    }
                    registrationContinuation?.resume(returning: prfBytes)
                    registrationContinuation = nil
                    return
                }

                if let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
                    guard let prfOutput = assertion.prf else {
                        assertionContinuation?.resume(throwing: PasskeyError.prfOutputMissing)
                        assertionContinuation = nil
                        return
                    }
                    assertionContinuation?.resume(returning: prfOutput.first)
                    assertionContinuation = nil
                    return
                }
            }

            registrationContinuation?.resume(throwing: PasskeyError.unexpectedCredentialType)
            registrationContinuation = nil
            assertionContinuation?.resume(throwing: PasskeyError.unexpectedCredentialType)
            assertionContinuation = nil
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            let passkeyError = PasskeyError.authenticationFailed(error.localizedDescription)
            self.error = error.localizedDescription
            // Only resume the continuation that's actually in flight
            if let cont = registrationContinuation {
                cont.resume(throwing: passkeyError)
                registrationContinuation = nil
            } else if let cont = assertionContinuation {
                cont.resume(throwing: passkeyError)
                assertionContinuation = nil
            }
        }
    }

    // MARK: - Presentation

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first as? UIWindowScene
        return windowScene?.windows.first ?? ASPresentationAnchor()
    }
}

enum PasskeyError: Error, LocalizedError {
    case prfNotAvailable
    case prfNotSupported
    case prfOutputMissing
    case unexpectedCredentialType
    case authenticationFailed(String)

    var errorDescription: String? {
        switch self {
        case .prfNotAvailable: "Passkey login requires iOS 18 or later. Use \"Create Without Passkey\" instead."
        case .prfNotSupported: "Your device doesn't support passkey login. Use the backup key option instead."
        case .prfOutputMissing: "Passkey authentication succeeded but account recovery failed. Please try again."
        case .unexpectedCredentialType: "Something went wrong with passkey authentication. Please try again."
        case .authenticationFailed(let d):
            d.contains("cancelled") ? nil : "Authentication failed. Please try again."
        }
    }
}

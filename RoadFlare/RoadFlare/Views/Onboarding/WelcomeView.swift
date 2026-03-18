import SwiftUI
import RidestrSDK

/// First screen: welcome + create account via passkey or traditional key.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    @State private var passkeyManager = PasskeyManager()
    @State private var showImport = false
    @State private var showManualCreate = false
    @State private var importText = ""
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                Image(systemName: "car.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.tint)

                VStack(spacing: 8) {
                    Text("RoadFlare")
                        .font(.largeTitle.bold())
                    Text("Your personal driver network")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                Text("Request rides from drivers you know and trust. No strangers, no platform fees.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                Spacer()

                VStack(spacing: 16) {
                    // Primary: Passkey (iOS 18+)
                    if #available(iOS 18.0, *) {
                        Button {
                            createWithPasskey()
                        } label: {
                            Label("Create with Passkey", systemImage: "person.badge.key.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading)
                    }

                    // Secondary: Traditional key generation
                    Button {
                        generateTraditionalKey()
                    } label: {
                        Text(isPasskeyAvailable ? "Create Without Passkey" : "Create New Account")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)

                    // Import existing key
                    Button {
                        showImport = true
                    } label: {
                        Text("I Have a Key")
                            .font(.subheadline)
                    }
                    .disabled(isLoading)
                }
                .padding(.horizontal)

                if isLoading {
                    ProgressView()
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
            }
            .padding()
            .sheet(isPresented: $showImport) {
                ImportKeySheet(importText: $importText, errorMessage: $errorMessage) {
                    importKey()
                }
            }
        }
    }

    private var isPasskeyAvailable: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    private func createWithPasskey() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let keypair = try await passkeyManager.createPasskeyAndDeriveKey()
                // Store the derived key in keychain so the app can use it
                try await appState.importKey(keypair.exportNsec())
                appState.authState = .profileIncomplete
            } catch {
                errorMessage = error.localizedDescription
                // If passkey fails, suggest traditional method
                if errorMessage?.contains("cancelled") == true {
                    errorMessage = nil  // User cancelled, not an error
                }
            }
            isLoading = false
        }
    }

    private func generateTraditionalKey() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await appState.generateNewKey()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func importKey() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await appState.importKey(importText)
                showImport = false
            } catch {
                errorMessage = "Invalid key. Enter an nsec or hex private key."
            }
            isLoading = false
        }
    }
}

/// Import key sheet — supports passkey login or manual nsec/hex entry.
struct ImportKeySheet: View {
    @Binding var importText: String
    @Binding var errorMessage: String?
    let onImport: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var passkeyManager = PasskeyManager()
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Passkey login option
                if #available(iOS 18.0, *) {
                    VStack(spacing: 8) {
                        Button {
                            loginWithPasskey()
                        } label: {
                            Label("Sign In with Passkey", systemImage: "person.badge.key.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading)

                        Text("Use your existing passkey to recover your Nostr key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()
                        .padding(.vertical, 4)

                    Text("Or enter your key manually:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                TextField("nsec1... or hex key", text: $importText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Import Key") {
                    onImport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(importText.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()
            }
            .padding()
            .navigationTitle("Import Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func loginWithPasskey() {
        isLoading = true
        Task {
            do {
                let keypair = try await passkeyManager.authenticateAndDeriveKey()
                try await appState.importKey(keypair.exportNsec())
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                if errorMessage?.contains("cancelled") == true {
                    errorMessage = nil
                }
            }
            isLoading = false
        }
    }
}

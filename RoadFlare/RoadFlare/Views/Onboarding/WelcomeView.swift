import SwiftUI
import RidestrSDK

struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    @State private var passkeyManager = PasskeyManager()
    @State private var showImport = false
    @State private var importText = ""
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()

            VStack(spacing: 40) {
                Spacer()

                // Logo group (title + icon + subtitle, tight spacing)
                VStack(spacing: 20) {
                    HStack(spacing: 0) {
                        Text("Road")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundColor(Color.rfOnSurface)
                        Text("Flare")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundColor(Color.rfPrimary)
                    }

                    ZStack {
                        Circle()
                            .fill(LinearGradient.rfFlare)
                            .frame(width: 100, height: 100)
                            .rfAmbientShadow(color: .rfPrimary, radius: 40, opacity: 0.2)
                        Image(systemName: "car.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.black)
                    }
                }

                // Subtitle
                VStack(spacing: 8) {
                    VStack(spacing: -4) {
                        Text("Your Personal")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(Color.rfOnSurface)
                        Text("Driver Network")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(Color.rfOnSurface)
                    }

                    Text("Request rides from drivers you know and trust.")
                        .font(RFFont.body(15))
                        .foregroundColor(Color.rfOnSurfaceVariant)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, -16)

                // Bullet points
                VStack(alignment: .leading, spacing: 14) {
                    bulletPoint("NO STRANGERS")
                    bulletPoint("NO PLATFORM FEES")
                    bulletPoint("NO MIDDLEMAN")
                }
                .padding(.leading, 44)
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                VStack(spacing: 16) {
                    if #available(iOS 18.0, *) {
                        Button {
                            createWithPasskey()
                        } label: {
                            Label("Create with Passkey", systemImage: "person.badge.key.fill")
                        }
                        .buttonStyle(RFPrimaryButtonStyle())
                        .disabled(isLoading)
                    }

                    Button {
                        showImport = true
                    } label: {
                        Text("Log In With Existing Account")
                    }
                    .buttonStyle(RFSecondaryButtonStyle())
                    .disabled(isLoading)

                    Button {
                        generateTraditionalKey()
                    } label: {
                        Text(isPasskeyAvailable ? "Create Without Passkey" : "Create New Account")
                    }
                    .buttonStyle(RFGhostButtonStyle())
                    .disabled(isLoading)
                }
                .padding(.horizontal, 24)

                if isLoading {
                    ProgressView()
                        .tint(.rfPrimary)
                }

                if let error = errorMessage {
                    Text(error)
                        .font(RFFont.caption())
                        .foregroundColor(Color.rfError)
                        .padding(.horizontal, 24)
                }

                Spacer().frame(height: 20)
            }
        }
        .sheet(isPresented: $showImport) {
            ImportKeySheet(importText: $importText, errorMessage: $errorMessage) {
                importKey()
            }
        }
    }

    private func bulletPoint(_ text: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.rfPrimary)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .default))
                .tracking(1.5)
                .foregroundColor(Color.rfOnSurfaceVariant)
        }
    }

    private var isPasskeyAvailable: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    private func createWithPasskey() {
        guard !isLoading else { return }
        isLoading = true; errorMessage = nil
        Task {
            do {
                let keypair = try await passkeyManager.createPasskeyAndDeriveKey()
                try await appState.importKey(keypair.exportNsec())
                appState.authState = .profileIncomplete
            } catch {
                if !"\(error)".contains("cancelled") { errorMessage = error.localizedDescription }
            }
            isLoading = false
        }
    }

    private func generateTraditionalKey() {
        guard !isLoading else { return }  // Prevent rapid double-tap
        isLoading = true; errorMessage = nil
        Task {
            do { try await appState.generateNewKey() }
            catch { errorMessage = error.localizedDescription }
            isLoading = false
        }
    }

    private func importKey() {
        guard !isLoading else { return }
        isLoading = true; errorMessage = nil
        Task {
            do {
                try await appState.importKey(importText)
                showImport = false
            } catch {
                errorMessage = "Invalid backup key. Check that you pasted the full key."
            }
            isLoading = false
        }
    }
}

struct ImportKeySheet: View {
    @Binding var importText: String
    @Binding var errorMessage: String?
    let onImport: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var passkeyManager = PasskeyManager()
    @State private var isLoading = false

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()

            NavigationStack {
                VStack(spacing: 24) {
                    if #available(iOS 18.0, *) {
                        Button {
                            loginWithPasskey()
                        } label: {
                            Label("Sign In with Passkey", systemImage: "person.badge.key.fill")
                        }
                        .buttonStyle(RFPrimaryButtonStyle())
                        .disabled(isLoading)

                        Text("Use your existing passkey to recover your account")
                            .font(RFFont.caption())
                            .foregroundColor(Color.rfOnSurfaceVariant)

                        Rectangle()
                            .fill(Color.rfSurfaceContainerHigh)
                            .frame(height: 1)
                            .padding(.vertical, 4)

                        Text("Or enter your backup key:")
                            .font(RFFont.body(14))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                    }

                    TextField("Paste your backup key", text: $importText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(RFFont.mono(14))
                        .padding(12)
                        .background(Color.rfSurfaceContainerLow)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .foregroundColor(Color.rfOnSurface)

                    if let error = errorMessage {
                        Text(error)
                            .font(RFFont.caption())
                            .foregroundColor(Color.rfError)
                    }

                    Button("Log In") { onImport() }
                        .buttonStyle(RFSecondaryButtonStyle())
                        .disabled(importText.trimmingCharacters(in: .whitespaces).isEmpty)

                    Spacer()
                }
                .padding(24)
                .navigationTitle("Log In")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color.rfSurface, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.foregroundColor(Color.rfOnSurfaceVariant)
                    }
                }
            }
        }
    }

    private func loginWithPasskey() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            do {
                let keypair = try await passkeyManager.authenticateAndDeriveKey()
                try await appState.importKey(keypair.exportNsec())
                dismiss()
            } catch {
                if !"\(error)".contains("cancelled") { errorMessage = error.localizedDescription }
            }
            isLoading = false
        }
    }
}

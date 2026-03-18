import SwiftUI
import RidestrSDK

/// Profile setup after key generation.
struct ProfileSetupView: View {
    @Environment(AppState.self) private var appState
    @State private var displayName = ""
    @State private var showNsecBackup = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 60))
                    .foregroundStyle(.tint)

                VStack(spacing: 8) {
                    Text("Set Up Your Profile")
                        .font(.title2.bold())
                    Text("This is how drivers will see you")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Display Name")
                        .font(.subheadline.bold())
                    TextField("Your name", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal)

                if let npub = appState.keypair?.npub {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your Public Key")
                            .font(.subheadline.bold())
                        Text(npub)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    .padding(.horizontal)
                }

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        showNsecBackup = true
                    } label: {
                        Label("Back Up Your Key", systemImage: "key")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.bordered)

                    Button {
                        appState.completeProfileSetup(name: displayName)
                    } label: {
                        Text("Continue")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal)
            }
            .padding()
            .sheet(isPresented: $showNsecBackup) {
                NsecBackupSheet()
            }
        }
    }
}

/// Sheet displaying the nsec for backup.
struct NsecBackupSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var nsec: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)

                Text("Save This Key Securely")
                    .font(.title3.bold())

                Text("This is your private key. Anyone with this key can access your account. Store it somewhere safe — we cannot recover it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let nsec {
                    VStack(spacing: 8) {
                        Text(nsec)
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                            .background(.fill.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .textSelection(.enabled)

                        Button {
                            UIPasteboard.general.string = nsec
                            copied = true
                        } label: {
                            Label(copied ? "Copied!" : "Copy to Clipboard", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    ProgressView("Loading key...")
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Key Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                nsec = try? await appState.keyManager?.exportNsec()
            }
        }
    }
}

import SwiftUI
import Security
import RidestrSDK

struct ProfileSetupView: View {
    @Environment(AppState.self) private var appState
    @State private var displayName = ""
    @State private var showBackup = false

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 60))
                    .foregroundColor(Color.rfPrimary)

                VStack(spacing: 8) {
                    Text("Set Up Your Profile")
                        .font(RFFont.headline(24))
                        .foregroundColor(Color.rfOnSurface)
                    Text("This is how drivers will see you")
                        .font(RFFont.body(15))
                        .foregroundColor(Color.rfOnSurfaceVariant)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Display Name")
                        .font(RFFont.caption())
                        .foregroundColor(Color.rfOnSurfaceVariant)
                    TextField("Your name", text: $displayName)
                        .font(RFFont.body())
                        .padding(12)
                        .background(Color.rfSurfaceContainerLow)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .foregroundColor(Color.rfOnSurface)
                }
                .padding(.horizontal, 24)

                Spacer()

                VStack(spacing: 16) {
                    Button { showBackup = true } label: {
                        Label("Back Up Account Key", systemImage: "key")
                    }
                    .buttonStyle(RFSecondaryButtonStyle())

                    Button { appState.completeProfileSetup(name: displayName) } label: {
                        Text("Continue")
                    }
                    .buttonStyle(RFPrimaryButtonStyle(isDisabled: displayName.trimmingCharacters(in: .whitespaces).isEmpty))
                    .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 24)

                Spacer().frame(height: 20)
            }
        }
        .sheet(isPresented: $showBackup) {
            BackupKeySheet()
        }
    }
}

/// Backup key sheet — user-friendly language, no Nostr jargon.
struct BackupKeySheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var backupKey: String?
    @State private var showFullKey = false
    @State private var copied = false
    @State private var savedToPasswords = false

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()
            NavigationStack {
                VStack(spacing: 24) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(Color.rfTertiary)

                    Text("Save Your Backup Key")
                        .font(RFFont.headline(20))
                        .foregroundColor(Color.rfOnSurface)

                    Text("This key is required to recover your account on a new device. Keep it somewhere safe — we can't recover it for you.")
                        .font(RFFont.body(14))
                        .foregroundColor(Color.rfOnSurfaceVariant)
                        .multilineTextAlignment(.center)

                    if let key = backupKey {
                        VStack(spacing: 12) {
                            // Truncated by default, full on tap
                            Button { showFullKey.toggle() } label: {
                                Text(showFullKey ? key : truncateKey(key))
                                    .font(RFFont.mono(showFullKey ? 11 : 13))
                                    .foregroundColor(Color.rfOnSurface)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.rfSurfaceContainerLow)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .textSelection(.enabled)
                            }
                            .buttonStyle(.plain)

                            Text(showFullKey ? "Tap to hide" : "Tap to reveal full key")
                                .font(RFFont.caption(11))
                                .foregroundColor(Color.rfOffline)

                            Button {
                                UIPasteboard.general.string = key
                                copied = true
                            } label: {
                                Label(copied ? "Copied!" : "Copy to Clipboard", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(RFSecondaryButtonStyle())
                        }
                    } else {
                        ProgressView().tint(Color.rfPrimary)
                    }

                    // Save to Apple Passwords
                    if let key = backupKey, let npub = appState.keypair?.npub {
                        Button {
                            SecAddSharedWebCredential(
                                "roadflare.app" as CFString,
                                npub as CFString,
                                key as CFString
                            ) { error in
                                DispatchQueue.main.async {
                                    if error == nil { savedToPasswords = true }
                                }
                            }
                        } label: {
                            Label(
                                savedToPasswords ? "Saved to Passwords" : "Save to Apple Passwords",
                                systemImage: savedToPasswords ? "checkmark.shield" : "lock.shield"
                            )
                        }
                        .buttonStyle(RFSecondaryButtonStyle())
                        .disabled(savedToPasswords)
                    }

                    // Collapsible "About Your Keys" section
                    DisclosureGroup {
                        Text("RoadFlare is built on Nostr, an open protocol where your identity is a cryptographic key pair — not an email or phone number. Your backup key (nsec) is your private key. Your Account ID (npub) is your public identity. Never share your backup key with anyone.")
                            .font(RFFont.caption(12))
                            .foregroundColor(Color.rfOffline)
                            .padding(.top, 8)
                    } label: {
                        Text("About Your Keys")
                            .font(RFFont.caption(13))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                    }
                    .tint(Color.rfOnSurfaceVariant)

                    Spacer()
                }
                .padding(24)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color.rfSurface, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.foregroundColor(Color.rfPrimary)
                    }
                }
            }
        }
        .task { backupKey = try? await appState.keyManager?.exportNsec() }
    }

    private func truncateKey(_ key: String) -> String {
        guard key.count > 28 else { return key }
        return String(key.prefix(20)) + "..." + String(key.suffix(8))
    }
}

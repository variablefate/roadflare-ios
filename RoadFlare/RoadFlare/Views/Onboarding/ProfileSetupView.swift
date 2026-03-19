import SwiftUI
import RidestrSDK

struct ProfileSetupView: View {
    @Environment(AppState.self) private var appState
    @State private var displayName = ""
    @State private var showNsecBackup = false

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

                if let npub = appState.keypair?.npub {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your Public Key")
                            .font(RFFont.caption())
                            .foregroundColor(Color.rfOnSurfaceVariant)
                        Text(npub)
                            .font(RFFont.mono(11))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 24)
                }

                Spacer()

                VStack(spacing: 16) {
                    Button { showNsecBackup = true } label: {
                        Label("Back Up Your Key", systemImage: "key")
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
        .sheet(isPresented: $showNsecBackup) {
            NsecBackupSheet()
        }
    }
}

struct NsecBackupSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var nsec: String?
    @State private var copied = false

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()
            NavigationStack {
                VStack(spacing: 24) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(Color.rfTertiary)

                    Text("Save This Key Securely")
                        .font(RFFont.headline(20))
                        .foregroundColor(Color.rfOnSurface)

                    Text("This is your private key. Anyone with this key can access your account. Store it somewhere safe — we cannot recover it.")
                        .font(RFFont.body(14))
                        .foregroundColor(Color.rfOnSurfaceVariant)
                        .multilineTextAlignment(.center)

                    if let nsec {
                        VStack(spacing: 12) {
                            Text(nsec)
                                .font(RFFont.mono(11))
                                .foregroundColor(Color.rfOnSurface)
                                .padding(12)
                                .background(Color.rfSurfaceContainerLow)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .textSelection(.enabled)

                            Button {
                                UIPasteboard.general.string = nsec
                                copied = true
                            } label: {
                                Label(copied ? "Copied!" : "Copy to Clipboard", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(RFSecondaryButtonStyle())
                        }
                    } else {
                        ProgressView().tint(Color.rfPrimary)
                    }
                    Spacer()
                }
                .padding(24)
                .navigationTitle("Key Backup")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color.rfSurface, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.foregroundColor(Color.rfPrimary)
                    }
                }
            }
        }
        .task { nsec = try? await appState.keyManager?.exportNsec() }
    }
}

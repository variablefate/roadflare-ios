import SwiftUI
import RidestrSDK

/// Sheet for adding a new driver by QR scan, npub, or hex pubkey.
struct AddDriverSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var pubkeyInput = ""
    @State private var noteInput = ""
    @State private var errorMessage: String?
    @State private var isValid = false
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showScanner = true
                    } label: {
                        HStack {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.title)
                            VStack(alignment: .leading) {
                                Text("Scan QR Code")
                                    .font(.headline)
                                Text("Point your camera at the driver's QR code")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                } header: {
                    Text("Quick Add")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Driver's Public Key")
                            .font(.subheadline.bold())
                        TextField("npub1... or hex public key", text: $pubkeyInput)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: pubkeyInput) {
                                validateInput()
                            }

                        if isValid {
                            Label("Valid key", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else if !pubkeyInput.isEmpty {
                            Label("Enter a valid npub or 64-character hex key", systemImage: "xmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Manual Entry")
                } footer: {
                    Text("Ask your driver for their npub, or scan their QR code.")
                }

                Section("Note (optional)") {
                    TextField("e.g., Toyota Camry, airport runs", text: $noteInput)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Driver")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addDriver()
                    }
                    .disabled(!isValid)
                    .bold()
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                QRScannerSheet { scannedValue in
                    handleScan(scannedValue)
                }
            }
        }
    }

    private func validateInput() {
        let trimmed = pubkeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        isValid = NIP19.isValidNpub(trimmed) || NIP19.isValidHexPubkey(trimmed)
        errorMessage = nil
    }

    private func handleScan(_ value: String) {
        showScanner = false
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle various QR formats
        if trimmed.hasPrefix("nostr:npub1") {
            pubkeyInput = String(trimmed.dropFirst(6))  // Remove "nostr:" prefix
        } else if trimmed.hasPrefix("npub1") || trimmed.count == 64 {
            pubkeyInput = trimmed
        } else {
            errorMessage = "QR code doesn't contain a valid Nostr public key"
            return
        }
        validateInput()
    }

    private func addDriver() {
        let trimmed = pubkeyInput.trimmingCharacters(in: .whitespacesAndNewlines)

        let hexPubkey: String
        if trimmed.hasPrefix("npub1") {
            guard let decoded = try? NIP19.npubDecode(trimmed) else {
                errorMessage = "Invalid npub format"
                return
            }
            hexPubkey = decoded
        } else {
            hexPubkey = trimmed
        }

        if appState.driversRepository?.isFollowing(pubkey: hexPubkey) == true {
            errorMessage = "You're already following this driver"
            return
        }

        let driver = FollowedDriver(
            pubkey: hexPubkey,
            name: nil,
            note: noteInput.isEmpty ? nil : noteInput
        )
        appState.driversRepository?.addDriver(driver)

        // Publish updated Kind 30011 so driver can discover this follower
        Task {
            await appState.rideCoordinator?.publishFollowedDriversList()
        }

        dismiss()
    }
}

/// Full-screen QR scanner with close button overlay.
struct QRScannerSheet: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            QRScannerView { code in
                onScan(code)
            }
            .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            .padding()
        }
    }
}

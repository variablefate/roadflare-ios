import SwiftUI
import RoadFlareCore

/// Detail view for a followed driver.
struct DriverDetailSheet: View {
    let pubkey: String
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var note: String = ""
    @State private var keyRefreshToastMessage: String?
    @State private var keyRefreshToastIsError: Bool = false
    @State private var isRequestingKeyRefresh: Bool = false

    var body: some View {
        // Capture the presentation state once per body invocation. Each access
        // to `appState.driverDetailViewState(pubkey:)` rebuilds the struct from
        // repo state (6 lock acquisitions + RelativeDateTimeFormatter alloc),
        // so reading it 13× across the body adds up.
        let state = appState.driverDetailViewState(pubkey: pubkey)
        return NavigationStack {
            List {
                Section("Driver Info") {
                    LabeledContent("Name", value: state?.displayName ?? "")
                    LabeledContent("Status", value: state?.statusLabel ?? "")

                    if let vehicle = state?.vehicleDescription {
                        LabeledContent("Vehicle", value: vehicle)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Account ID")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(pubkey)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                if let version = state?.keyVersion {
                    Section("RoadFlare Key") {
                        LabeledContent("Version", value: "\(version)")
                        if state?.isKeyStale == true {
                            LabeledContent("Key Status", value: "Outdated")
                                .foregroundStyle(.red)
                            Button {
                                requestKeyRefresh()
                            } label: {
                                Label("Request Fresh Key", systemImage: "arrow.clockwise")
                            }
                            .disabled(isRequestingKeyRefresh)
                        } else {
                            LabeledContent("Key Status", value: "Active")
                                .foregroundStyle(.green)
                        }
                    }
                } else if state?.hasKey == false {
                    Section("RoadFlare Key") {
                        Label("Waiting for driver to approve your follow request", systemImage: "hourglass")
                            .foregroundStyle(.orange)
                    }
                }

                if let statusRaw = state?.lastLocationStatus,
                   let timestampLabel = state?.lastLocationTimestampLabel {
                    Section("Last Known Location") {
                        LabeledContent("Status", value: statusRaw)
                        LabeledContent("Last Update", value: timestampLabel)
                    }
                }

                Section("Personal Note") {
                    TextField("Add a note about this driver", text: $note)
                        .onSubmit {
                            persistNoteIfNeeded()
                        }
                }

                Section {
                    if state?.canRequestRide == true {
                        Button("Request Ride") {
                            appState.requestRideDriverPubkey = pubkey
                            appState.selectedTab = 0
                            dismiss()
                        }
                        .bold()
                    }
                }

                Section {
                    Button("Remove Driver", role: .destructive) {
                        appState.removeDriver(pubkey: pubkey)
                        dismiss()
                    }
                }
            }
            .navigationTitle(state?.displayName ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        persistNoteIfNeeded()
                        dismiss()
                    }
                }
            }
            .onAppear {
                // `state` captured above is in scope of the body evaluation that
                // registered this onAppear — re-fetch here because the sheet may
                // appear after the initial body render settled and `state` could
                // still be nil if the driver is no longer in the repo.
                note = appState.driverDetailViewState(pubkey: pubkey)?.note ?? ""
            }
            // Auto-dismiss when the backing driver disappears from the repo (e.g.
            // background Kind 30011 sync drops them, or another session logs out).
            // Without this, every `state?.foo` short-circuits and the sheet renders
            // blank with no explanation. `initial: true` also covers the case where
            // the sheet opens for an already-missing pubkey.
            .onChange(of: state == nil, initial: true) { _, isMissing in
                if isMissing { dismiss() }
            }
            .toast($keyRefreshToastMessage, isError: keyRefreshToastIsError)
        }
    }

    private func requestKeyRefresh() {
        isRequestingKeyRefresh = true
        Task {
            let outcome = await appState.requestKeyRefresh(pubkey: pubkey)
            isRequestingKeyRefresh = false
            switch outcome {
            case .sent:
                keyRefreshToastMessage = "Refresh requested. Waiting for the driver to respond."
                keyRefreshToastIsError = false
            case .rateLimited(let retryAt):
                let seconds = max(1, Int(retryAt.timeIntervalSinceNow.rounded(.up)))
                keyRefreshToastMessage = "Just sent — wait \(seconds)s before requesting again."
                keyRefreshToastIsError = true
            case .publishFailed:
                keyRefreshToastMessage = "Couldn't reach the relay. Check your connection and try again."
                keyRefreshToastIsError = true
            }
        }
    }

    private func persistNoteIfNeeded() {
        let existingNote = appState.driverDetailViewState(pubkey: pubkey)?.note ?? ""
        let normalized = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = existingNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != existing else { return }
        appState.updateDriverNote(pubkey: pubkey, note: normalized)
    }
}

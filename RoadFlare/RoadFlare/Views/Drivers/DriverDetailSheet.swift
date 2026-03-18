import SwiftUI
import RidestrSDK

/// Detail view for a followed driver.
struct DriverDetailSheet: View {
    let driver: FollowedDriver
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var note: String

    init(driver: FollowedDriver) {
        self.driver = driver
        self._note = State(initialValue: driver.note ?? "")
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Driver Info") {
                    LabeledContent("Name", value: displayName)
                    LabeledContent("Status", value: statusText)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Public Key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(driver.pubkey)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                if let key = driver.roadflareKey {
                    Section("RoadFlare Key") {
                        LabeledContent("Version", value: "\(key.version)")
                        LabeledContent("Key Status", value: "Active")
                            .foregroundStyle(.green)
                    }
                } else {
                    Section("RoadFlare Key") {
                        Label("Waiting for driver to approve your follow request", systemImage: "hourglass")
                            .foregroundStyle(.orange)
                    }
                }

                if let loc = appState.driversRepository?.driverLocations[driver.pubkey] {
                    Section("Last Known Location") {
                        LabeledContent("Status", value: loc.status)
                        LabeledContent("Last Update", value: formatTimestamp(loc.timestamp))
                    }
                }

                Section("Personal Note") {
                    TextField("Add a note about this driver", text: $note)
                        .onChange(of: note) {
                            appState.driversRepository?.updateDriverNote(
                                driverPubkey: driver.pubkey, note: note
                            )
                        }
                }

                Section {
                    if driver.hasKey {
                        Button("Request Ride") {
                            // TODO: Navigate to ride tab with this driver selected
                            dismiss()
                        }
                        .bold()
                    }
                }

                Section {
                    Button("Remove Driver", role: .destructive) {
                        appState.driversRepository?.removeDriver(pubkey: driver.pubkey)
                        dismiss()
                    }
                }
            }
            .navigationTitle(displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var displayName: String {
        appState.driversRepository?.driverNames[driver.pubkey]
            ?? driver.name
            ?? String(driver.pubkey.prefix(8)) + "..."
    }

    private var statusText: String {
        guard driver.hasKey else { return "Pending approval" }
        guard let loc = appState.driversRepository?.driverLocations[driver.pubkey] else { return "Offline" }
        switch loc.status {
        case "online": return "Available"
        case "on_ride": return "On a ride"
        default: return "Offline"
        }
    }

    private func formatTimestamp(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

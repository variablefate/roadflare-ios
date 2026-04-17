import SwiftUI
import RidestrSDK
import RoadFlareCore

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

                    if let vehicle = appState.driverProfile(pubkey: driver.pubkey)?.vehicleDescription {
                        LabeledContent("Vehicle", value: vehicle)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Account ID")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(driver.pubkey)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                if let key = currentDriver.roadflareKey {
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

                if let loc = appState.driverLocation(pubkey: driver.pubkey) {
                    Section("Last Known Location") {
                        LabeledContent("Status", value: loc.status)
                        LabeledContent("Last Update", value: formatTimestamp(loc.timestamp))
                    }
                }

                Section("Personal Note") {
                    TextField("Add a note about this driver", text: $note)
                        .onSubmit {
                            persistNoteIfNeeded()
                        }
                }

                Section {
                    if canRequestRide {
                        Button("Request Ride") {
                            appState.requestRideDriverPubkey = driver.pubkey
                            appState.selectedTab = 0  // Switch to RoadFlare tab
                            dismiss()
                        }
                        .bold()
                    }
                }

                Section {
                    Button("Remove Driver", role: .destructive) {
                        appState.removeDriver(pubkey: driver.pubkey)
                        dismiss()
                    }
                }
            }
            .navigationTitle(displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        persistNoteIfNeeded()
                        dismiss()
                    }
                }
            }
        }
    }

    private var currentDriver: FollowedDriver {
        appState.getDriver(pubkey: driver.pubkey) ?? driver
    }

    private var currentLocation: CachedDriverLocation? {
        appState.driverLocation(pubkey: driver.pubkey)
    }

    private var canRequestRide: Bool {
        appState.canRequestRide(currentDriver)
    }

    private var displayName: String {
        appState.driverDisplayName(pubkey: driver.pubkey)
            ?? currentDriver.name
            ?? String(driver.pubkey.prefix(8)) + "..."
    }

    private var statusText: String {
        guard currentDriver.hasKey else { return "Pending approval" }
        guard let loc = currentLocation else { return "Offline" }
        switch loc.status {
        case "online": return "Available"
        case "on_ride": return "On a ride"
        default: return "Offline"
        }
    }

    private func persistNoteIfNeeded() {
        let normalized = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = currentDriver.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard normalized != existing else { return }
        appState.updateDriverNote(pubkey: driver.pubkey, note: normalized)
    }

    private func formatTimestamp(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

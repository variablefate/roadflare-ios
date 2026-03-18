import SwiftUI
import RidestrSDK

/// Ride tab: request rides from your trusted drivers.
struct RideTab: View {
    @Environment(AppState.self) private var appState
    @State private var pickupAddress = ""
    @State private var destinationAddress = ""
    @State private var selectedDriverPubkey: String?
    @State private var showChat = false

    var body: some View {
        NavigationStack {
            Group {
                if let sm = appState.rideStateMachine {
                    switch sm.stage {
                    case .idle:
                        idleView
                    case .waitingForAcceptance:
                        waitingView
                    case .driverAccepted, .rideConfirmed:
                        enRouteView(sm: sm)
                    case .driverArrived:
                        arrivedView(sm: sm)
                    case .inProgress:
                        inProgressView(sm: sm)
                    case .completed:
                        completedView(sm: sm)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Ride")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ConnectivityIndicator()
                }
            }
            .sheet(isPresented: $showChat) {
                ChatView()
            }
        }
    }

    // MARK: - Idle State

    private var idleView: some View {
        VStack(spacing: 0) {
            // Online drivers
            if let repo = appState.driversRepository {
                let onlineDrivers = repo.drivers.filter { driver in
                    guard driver.hasKey else { return false }
                    guard let loc = repo.driverLocations[driver.pubkey] else { return false }
                    return loc.status == "online"
                }

                if onlineDrivers.isEmpty {
                    ContentUnavailableView {
                        Label("No Drivers Online", systemImage: "car.side")
                    } description: {
                        Text("None of your drivers are available right now. Check back later.")
                    }
                } else {
                    List {
                        Section("Available Drivers") {
                            ForEach(onlineDrivers) { driver in
                                Button {
                                    selectedDriverPubkey = driver.pubkey
                                } label: {
                                    DriverRow(
                                        driver: driver,
                                        displayName: repo.driverNames[driver.pubkey] ?? driver.name,
                                        location: repo.driverLocations[driver.pubkey]
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if selectedDriverPubkey != nil {
                            Section("Ride Details") {
                                TextField("Pickup address", text: $pickupAddress)
                                TextField("Destination", text: $destinationAddress)

                                // TODO: Fare estimate display
                                // TODO: Payment method picker
                            }

                            Section {
                                Button {
                                    sendOffer()
                                } label: {
                                    Text("Send RoadFlare Request")
                                        .font(.headline)
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(pickupAddress.isEmpty || destinationAddress.isEmpty)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Waiting for Acceptance

    private var waitingView: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Waiting for driver to accept...")
                .font(.title3)
            Text("This usually takes a few seconds")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel Request", role: .destructive) {
                appState.rideStateMachine?.reset()
            }
            .buttonStyle(.bordered)
            .padding()
        }
    }

    // MARK: - Driver En Route

    private func enRouteView(sm: RideStateMachine) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "car.fill")
                .font(.system(size: 60))
                .foregroundStyle(.tint)
            Text("Driver is on the way!")
                .font(.title2.bold())
            Text("Your driver has accepted and is heading to your pickup location.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            chatAndCancelButtons
        }
        .padding()
    }

    // MARK: - Driver Arrived (Show PIN)

    private func arrivedView(sm: RideStateMachine) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("Driver Has Arrived!")
                .font(.title2.bold())

            Text("Show this PIN to your driver:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let pin = sm.pin {
                Text(pin)
                    .font(.system(size: 64, weight: .bold, design: .monospaced))
                    .padding()
                    .background(.fill.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            Text("The driver will enter this PIN to verify your identity")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
            chatAndCancelButtons
        }
        .padding()
    }

    // MARK: - In Progress

    private func inProgressView(sm: RideStateMachine) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "road.lanes")
                .font(.system(size: 60))
                .foregroundStyle(.tint)
            Text("Ride in Progress")
                .font(.title2.bold())
            Text("Sit back and enjoy the ride.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()

            Button {
                showChat = true
            } label: {
                Label("Chat with Driver", systemImage: "message")
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
        }
        .padding()
    }

    // MARK: - Completed

    private func completedView(sm: RideStateMachine) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("Ride Complete!")
                .font(.title2.bold())

            // TODO: Show fare and payment instructions
            Text("Don't forget to pay your driver via your agreed payment method.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            Button {
                sm.reset()
                selectedDriverPubkey = nil
                pickupAddress = ""
                destinationAddress = ""
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
        }
        .padding()
    }

    // MARK: - Shared Components

    private var chatAndCancelButtons: some View {
        VStack(spacing: 12) {
            Button {
                showChat = true
            } label: {
                Label("Chat with Driver", systemImage: "message")
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.bordered)

            Button("Cancel Ride", role: .destructive) {
                // TODO: Publish cancellation event, handle safety warning
                appState.rideStateMachine?.reset()
            }
            .font(.subheadline)
        }
        .padding(.horizontal)
    }

    // MARK: - Actions

    private func sendOffer() {
        // TODO: Build ride offer, encrypt, publish via relay
        // For now, transition state machine for UI testing
        guard let sm = appState.rideStateMachine,
              let driverPubkey = selectedDriverPubkey else { return }
        do {
            try sm.startRide(
                offerEventId: "placeholder_offer_id",
                driverPubkey: driverPubkey,
                paymentMethod: .zelle,
                fiatPaymentMethods: [.zelle, .venmo, .cash]
            )
        } catch {
            print("Failed to start ride: \(error)")
        }
    }
}

import SwiftUI
import RidestrSDK

/// Ride tab: request rides from your trusted drivers.
struct RideTab: View {
    @Environment(AppState.self) private var appState
    @State private var pickupAddress = ""
    @State private var destinationAddress = ""
    @State private var selectedDriverPubkey: String?
    @State private var showChat = false
    @State private var showCancelWarning = false

    private var coordinator: RideCoordinator? { appState.rideCoordinator }
    private var stage: RiderStage { coordinator?.stateMachine.stage ?? .idle }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .idle:
                    idleView
                case .waitingForAcceptance:
                    waitingView
                case .driverAccepted, .rideConfirmed:
                    enRouteView
                case .driverArrived:
                    arrivedView
                case .inProgress:
                    inProgressView
                case .completed:
                    completedView
                }
            }
            .navigationTitle("Ride")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ConnectivityIndicator()
                }
            }
            .sheet(isPresented: $showChat) {
                WiredChatView()
            }
            .alert("Cancel Ride?", isPresented: $showCancelWarning) {
                Button("Cancel Ride", role: .destructive) {
                    Task { await coordinator?.cancelRide(reason: "Cancelled by rider") }
                }
                Button("Keep Riding", role: .cancel) {}
            } message: {
                if coordinator?.stateMachine.pinVerified == true {
                    Text("The driver may have already verified your PIN. Are you sure?")
                } else {
                    Text("Your driver has been notified and is on the way.")
                }
            }
        }
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: 0) {
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

                                if let fare = coordinator?.currentFareEstimate {
                                    LabeledContent("Estimated Fare", value: "$\(fare.fareUSD)")
                                    LabeledContent("Distance", value: String(format: "%.1f mi", fare.distanceMiles))
                                }
                            }

                            Section("Payment") {
                                if !appState.settings.paymentMethods.isEmpty {
                                    Text("Sending: \(appState.settings.paymentMethods.map(\.displayName).joined(separator: ", "))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("No payment methods configured")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
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
                                .disabled(pickupAddress.isEmpty || destinationAddress.isEmpty || appState.settings.paymentMethods.isEmpty)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Waiting

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
                Task { await coordinator?.cancelRide(reason: "Cancelled before acceptance") }
            }
            .buttonStyle(.bordered)
            .padding()
        }
    }

    // MARK: - En Route

    private var enRouteView: some View {
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
            rideActionButtons
        }
        .padding()
    }

    // MARK: - Arrived (PIN)

    private var arrivedView: some View {
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

            if let pin = coordinator?.stateMachine.pin {
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
            rideActionButtons
        }
        .padding()
    }

    // MARK: - In Progress

    private var inProgressView: some View {
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

    private var completedView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            Text("Ride Complete!")
                .font(.title2.bold())

            if let fare = coordinator?.currentFareEstimate,
               let method = coordinator?.selectedPaymentMethod ?? appState.settings.paymentMethods.first {
                Text("Pay your driver $\(fare.fareUSD) via \(method.displayName)")
                    .font(.headline)
                    .foregroundStyle(.tint)
            } else {
                Text("Don't forget to pay your driver.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Button {
                coordinator?.stateMachine.reset()
                coordinator?.chatMessages = []
                coordinator?.currentFareEstimate = nil
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

    // MARK: - Shared

    private var rideActionButtons: some View {
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
                showCancelWarning = true
            }
            .font(.subheadline)
        }
        .padding(.horizontal)
    }

    // MARK: - Actions

    private func sendOffer() {
        guard let driverPubkey = selectedDriverPubkey else { return }

        // For MVP: use a placeholder fare estimate
        // TODO: Calculate real fare via MapKit MKDirections
        let fare = FareEstimate(
            distanceMiles: 5.0,
            durationMinutes: 15.0,
            fareUSD: appState.fareCalculator?.calculateFare(distanceMiles: 5.0) ?? 10.0,
            routeSummary: nil
        )

        let pickup = Location(latitude: 0, longitude: 0, address: pickupAddress)
        let destination = Location(latitude: 0, longitude: 0, address: destinationAddress)

        Task {
            await coordinator?.sendRideOffer(
                driverPubkey: driverPubkey,
                pickup: pickup,
                destination: destination,
                fareEstimate: fare
            )
        }
    }
}

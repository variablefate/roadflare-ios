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
                Button("Go Back", role: .cancel) {}
            } message: {
                Text("Are you sure you want to cancel and close out this ride?")
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

            // Payment info card
            paymentInfoCard
                .padding(.horizontal)

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

            paymentInfoCard
                .padding(.horizontal)

            Spacer()
            Button {
                Task { await coordinator?.cancelRide() }
                selectedDriverPubkey = nil
                pickupAddress = ""
                destinationAddress = ""
            } label: {
                Label("I've Paid — Close Ride", systemImage: "checkmark.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
        }
        .padding()
    }

    // MARK: - Payment Info Card

    private var paymentInfoCard: some View {
        VStack(spacing: 12) {
            if let fare = coordinator?.currentFareEstimate {
                HStack {
                    Text("Fare")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("$\(fare.fareUSD)")
                        .font(.title3.bold())
                }
            }

            if !appState.settings.paymentMethods.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Payment Methods")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(appState.settings.paymentMethods, id: \.self) { method in
                            Text(method.displayName)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.fill.quaternary)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding()
        .background(.fill.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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

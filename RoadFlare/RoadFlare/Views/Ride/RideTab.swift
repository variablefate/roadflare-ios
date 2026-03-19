import SwiftUI
import RidestrSDK

struct RideTab: View {
    @Environment(AppState.self) private var appState
    @State private var pickupAddress = ""
    @State private var destinationAddress = ""
    @State private var selectedDriverPubkey: String?
    @State private var showChat = false
    @State private var showCancelWarning = false
    @State private var isCalculatingFare = false
    @State private var fareError: String?
    @State private var mapKit = MapKitServices()

    private var coordinator: RideCoordinator? { appState.rideCoordinator }
    private var stage: RiderStage { coordinator?.stateMachine.stage ?? .idle }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.rfSurface.ignoresSafeArea()

                switch stage {
                case .idle: idleView
                case .waitingForAcceptance: waitingView
                case .driverAccepted, .rideConfirmed, .enRoute: enRouteView
                case .driverArrived: arrivedView
                case .inProgress: inProgressView
                case .completed: completedView
                }
            }
            .navigationTitle("RoadFlare")
            .toolbarBackground(Color.rfSurface, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectivityIndicator() }
            }
            .sheet(isPresented: $showChat) { WiredChatView() }
            .onAppear {
                if let pubkey = appState.requestRideDriverPubkey {
                    selectedDriverPubkey = pubkey
                    appState.requestRideDriverPubkey = nil
                }
            }
            .onChange(of: stage) { oldStage, newStage in
                switch newStage {
                case .driverAccepted, .rideConfirmed, .enRoute:
                    if oldStage == .waitingForAcceptance { HapticManager.rideAccepted() }
                case .driverArrived:
                    HapticManager.driverArrived()
                case .completed:
                    HapticManager.rideCompleted()
                case .idle:
                    if oldStage != .idle { HapticManager.rideCancelled() }
                default: break
                }
            }
            .toast($fareError)
            .onChange(of: coordinator?.lastError) { _, newError in
                if let error = newError {
                    fareError = error
                    coordinator?.lastError = nil
                }
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
        ScrollView {
            VStack(spacing: 16) {
                if let repo = appState.driversRepository {
                    let onlineDrivers = repo.drivers.filter { d in
                        d.hasKey && (repo.driverLocations[d.pubkey]?.status == "online")
                    }

                    if onlineDrivers.isEmpty {
                        VStack(spacing: 24) {
                            Spacer().frame(height: 80)
                            Image(systemName: "car.side")
                                .font(.system(size: 48))
                                .foregroundColor(Color.rfOnSurfaceVariant)
                            Text("No Drivers Online")
                                .font(RFFont.headline(20))
                                .foregroundColor(Color.rfOnSurface)
                            Text("Check back later.")
                                .font(RFFont.body(15))
                                .foregroundColor(Color.rfOnSurfaceVariant)
                        }
                    } else {
                        // Available drivers
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("Available Drivers")
                            ForEach(onlineDrivers) { driver in
                                Button { selectedDriverPubkey = driver.pubkey } label: {
                                    HStack(spacing: 12) {
                                        FlareIndicator(color: selectedDriverPubkey == driver.pubkey ? .rfPrimary : .rfOnline)
                                            .frame(height: 36)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(repo.driverNames[driver.pubkey] ?? driver.name ?? String(driver.pubkey.prefix(8)) + "...")
                                                .font(RFFont.title(15))
                                                .foregroundColor(Color.rfOnSurface)
                                            Text("Available")
                                                .font(RFFont.caption(11))
                                                .foregroundColor(Color.rfOnline)
                                        }
                                        Spacer()
                                        if selectedDriverPubkey == driver.pubkey {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(Color.rfPrimary)
                                        }
                                    }
                                    .rfCard(selectedDriverPubkey == driver.pubkey ? .high : .standard)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Ride details
                        if selectedDriverPubkey != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionLabel("Ride Details")

                                VStack(spacing: 0) {
                                    AddressSearchField(
                                        placeholder: "Pickup address",
                                        icon: "circle.fill",
                                        iconColor: .rfOnline,
                                        text: $pickupAddress,
                                        onSelect: { _ in }
                                    )

                                    Rectangle().fill(Color.rfSurfaceContainerHigh).frame(height: 1).padding(.leading, 32)

                                    AddressSearchField(
                                        placeholder: "Destination",
                                        icon: "circle.fill",
                                        iconColor: .rfPrimary,
                                        text: $destinationAddress,
                                        onSelect: { _ in }
                                    )
                                }
                                .background(Color.rfSurfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: 16))

                                if let fare = coordinator?.currentFareEstimate {
                                    HStack {
                                        Text(String(format: "%.1f mi", fare.distanceMiles))
                                            .font(RFFont.caption())
                                            .foregroundColor(Color.rfOnSurfaceVariant)
                                        Spacer()
                                        Text("$\(fare.fareUSD)")
                                            .font(RFFont.headline(24))
                                            .foregroundColor(Color.rfPrimary)
                                    }
                                    .rfCard(.high)
                                }

                                // Payment info
                                HStack {
                                    Image(systemName: "creditcard")
                                        .foregroundColor(Color.rfPrimary)
                                    Text(appState.settings.paymentMethods.map(\.displayName).joined(separator: ", "))
                                        .font(RFFont.caption(12))
                                        .foregroundColor(Color.rfOnSurfaceVariant)
                                }
                                .padding(.horizontal, 4)

                                if let error = fareError {
                                    Text(error).font(RFFont.caption()).foregroundColor(Color.rfError)
                                }

                                Button { sendOffer() } label: {
                                    if isCalculatingFare {
                                        ProgressView().tint(.black)
                                    } else {
                                        Text("Send RoadFlare Request")
                                    }
                                }
                                .buttonStyle(RFPrimaryButtonStyle(isDisabled: pickupAddress.isEmpty || destinationAddress.isEmpty))
                                .disabled(pickupAddress.isEmpty || destinationAddress.isEmpty || isCalculatingFare)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    // MARK: - Waiting

    private var waitingView: some View {
        VStack(spacing: 32) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
                .tint(Color.rfPrimary)
            Text("Waiting for driver...")
                .font(RFFont.headline(22))
                .foregroundColor(Color.rfOnSurface)
            Text("This usually takes a few seconds")
                .font(RFFont.body(14))
                .foregroundColor(Color.rfOnSurfaceVariant)
            Spacer()
            Button("Cancel Request") {
                Task { await coordinator?.cancelRide(reason: "Cancelled before acceptance") }
            }
            .buttonStyle(RFSecondaryButtonStyle())
            .padding(.horizontal, 24)
            Spacer().frame(height: 40)
        }
    }

    // MARK: - En Route

    private var enRouteView: some View {
        VStack(spacing: 32) {
            Spacer()
            ZStack {
                Circle().fill(Color.rfPrimary.opacity(0.1)).frame(width: 120, height: 120)
                Image(systemName: "car.fill")
                    .font(.system(size: 48))
                    .foregroundColor(Color.rfPrimary)
            }
            Text("Driver is on the way!")
                .font(RFFont.headline(24))
                .foregroundColor(Color.rfOnSurface)
            Text("Heading to your pickup location")
                .font(RFFont.body(15))
                .foregroundColor(Color.rfOnSurfaceVariant)
            Spacer()
            rideActionButtons
            Spacer().frame(height: 40)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Arrived (PIN)

    private var arrivedView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(Color.rfOnline)

            Text("Driver Has Arrived!")
                .font(RFFont.headline(24))
                .foregroundColor(Color.rfOnSurface)

            Text("Show this PIN to your driver:")
                .font(RFFont.body(14))
                .foregroundColor(Color.rfOnSurfaceVariant)

            if let pin = coordinator?.stateMachine.pin {
                Text(pin)
                    .font(RFFont.display(72))
                    .foregroundColor(Color.rfPrimary)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(Color.rfSurfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .rfAmbientShadow(color: .rfPrimary, radius: 24, opacity: 0.15)
            }

            Text("The driver enters this to verify your identity")
                .font(RFFont.caption(12))
                .foregroundColor(Color.rfOffline)
            Spacer()
            rideActionButtons
            Spacer().frame(height: 40)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - In Progress

    private var inProgressView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "road.lanes")
                .font(.system(size: 56))
                .foregroundColor(Color.rfPrimary)
            Text("Ride in Progress")
                .font(RFFont.headline(24))
                .foregroundColor(Color.rfOnSurface)

            paymentInfoCard.padding(.horizontal, 24)

            Spacer()
            Button { showChat = true } label: {
                Label("Chat with Driver", systemImage: "message")
            }
            .buttonStyle(RFSecondaryButtonStyle())
            .padding(.horizontal, 24)
            Spacer().frame(height: 40)
        }
    }

    // MARK: - Completed

    private var completedView: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(Color.rfOnline.opacity(0.1)).frame(width: 100, height: 100)
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundColor(Color.rfOnline)
            }
            Text("Ride Complete!")
                .font(RFFont.headline(28))
                .foregroundColor(Color.rfOnSurface)

            paymentInfoCard.padding(.horizontal, 24)

            Spacer()
            Button {
                Task { await coordinator?.cancelRide() }
                selectedDriverPubkey = nil; pickupAddress = ""; destinationAddress = ""
            } label: {
                Label("I've Paid — Close Ride", systemImage: "checkmark.circle")
            }
            .buttonStyle(RFPrimaryButtonStyle())
            .padding(.horizontal, 24)
            Spacer().frame(height: 40)
        }
    }

    // MARK: - Payment Info Card

    private var paymentInfoCard: some View {
        VStack(spacing: 12) {
            if let fare = coordinator?.currentFareEstimate {
                HStack {
                    Text("Fare")
                        .font(RFFont.body(15))
                        .foregroundColor(Color.rfOnSurfaceVariant)
                    Spacer()
                    Text("$\(fare.fareUSD)")
                        .font(RFFont.headline(24))
                        .foregroundColor(Color.rfPrimary)
                }
            }
            if !appState.settings.paymentMethods.isEmpty {
                Rectangle().fill(Color.rfSurfaceContainerHigh).frame(height: 1)
                HStack(spacing: 8) {
                    ForEach(appState.settings.paymentMethods, id: \.self) { method in
                        Text(method.displayName)
                            .font(RFFont.caption(12))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.rfSurfaceContainerHigh)
                            .foregroundColor(Color.rfOnSurfaceVariant)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .rfCard(.high)
    }

    // MARK: - Shared

    private var rideActionButtons: some View {
        VStack(spacing: 12) {
            Button { showChat = true } label: {
                Label("Chat with Driver", systemImage: "message")
            }
            .buttonStyle(RFSecondaryButtonStyle())

            Button("Cancel Ride") { showCancelWarning = true }
                .buttonStyle(RFGhostButtonStyle())
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Actions

    private func sendOffer() {
        guard let driverPubkey = selectedDriverPubkey,
              let calculator = appState.fareCalculator else { return }
        isCalculatingFare = true; fareError = nil
        Task {
            do {
                guard let pickup = try await mapKit.geocode(address: pickupAddress) else {
                    fareError = "Could not find pickup address"; isCalculatingFare = false; return
                }
                guard let destination = try await mapKit.geocode(address: destinationAddress) else {
                    fareError = "Could not find destination"; isCalculatingFare = false; return
                }
                let fare = try await mapKit.estimateFare(from: pickup, to: destination, calculator: calculator)
                coordinator?.currentFareEstimate = fare
                await coordinator?.sendRideOffer(driverPubkey: driverPubkey, pickup: pickup, destination: destination, fareEstimate: fare)
            } catch {
                fareError = "Route calculation failed. Check addresses."
            }
            isCalculatingFare = false
        }
    }
}

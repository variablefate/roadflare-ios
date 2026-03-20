import SwiftUI
import RidestrSDK
import RidestrUI

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
                case .idle:
                    idleView
                default:
                    RideStatusCard(
                        stage: stage,
                        pin: coordinator?.stateMachine.pin,
                        fareEstimate: coordinator?.currentFareEstimate,
                        paymentMethods: appState.settings.paymentMethods,
                        onCancel: { showCancelWarning = true },
                        onChat: { showChat = true },
                        onCloseRide: {
                            Task { await coordinator?.cancelRide() }
                            selectedDriverPubkey = nil
                            pickupAddress = ""
                            destinationAddress = ""
                        }
                    )
                    .environment(\.ridestrTheme, roadFlareTheme)
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
                // Pick up driver selection from DriverDetailSheet navigation
                if let pubkey = appState.requestRideDriverPubkey {
                    selectedDriverPubkey = pubkey
                    appState.requestRideDriverPubkey = nil
                }
                // Restore ride state from persistence after app kill
                if selectedDriverPubkey == nil, let driverPub = coordinator?.stateMachine.driverPubkey {
                    selectedDriverPubkey = driverPub
                }
                if pickupAddress.isEmpty, let addr = coordinator?.pickupLocation?.address {
                    pickupAddress = addr
                }
                if destinationAddress.isEmpty, let addr = coordinator?.destinationLocation?.address {
                    destinationAddress = addr
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
                                        Text(formatFare(fare.fareUSD))
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

    // MARK: - RoadFlare Theme for RidestrUI

    private var roadFlareTheme: RidestrTheme {
        RidestrTheme(
            accentColor: .rfPrimary,
            successColor: .rfOnline,
            warningColor: .rfOnRide,
            errorColor: .rfError,
            surfaceColor: .rfSurface,
            surfaceSecondaryColor: .rfSurfaceContainer,
            onSurfaceColor: .rfOnSurface,
            onSurfaceSecondaryColor: .rfOnSurfaceVariant,
            cardCornerRadius: 16,
            fontDesign: .rounded
        )
    }

    // MARK: - Actions

    private func sendOffer() {
        guard !isCalculatingFare else { return }  // Prevent double-tap
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

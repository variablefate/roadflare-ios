import SwiftUI
import CoreLocation
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
    @State private var locationManager = RiderLocationManager()
    @State private var fareCalcTask: Task<Void, Never>?

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
                                        onSelect: { _ in recalculateFare() },
                                        showCurrentLocation: true,
                                        onUseCurrentLocation: { useCurrentLocation() }
                                    )

                                    Rectangle().fill(Color.rfSurfaceContainerHigh).frame(height: 1).padding(.leading, 32)

                                    AddressSearchField(
                                        placeholder: "Destination",
                                        icon: "circle.fill",
                                        iconColor: .rfPrimary,
                                        text: $destinationAddress,
                                        onSelect: { _ in recalculateFare() }
                                    )
                                }
                                .background(Color.rfSurfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: 16))

                                if isCalculatingFare {
                                    HStack {
                                        ProgressView().tint(Color.rfPrimary)
                                        Text("Calculating fare...")
                                            .font(RFFont.body(14))
                                            .foregroundColor(Color.rfOnSurfaceVariant)
                                        Spacer()
                                    }
                                    .rfCard(.high)
                                } else if let fare = coordinator?.currentFareEstimate {
                                    HStack {
                                        Text(String(format: "%.1f mi · %.0f min", fare.distanceMiles, fare.durationMinutes))
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
                                    Text("Send RoadFlare Request")
                                }
                                .buttonStyle(RFPrimaryButtonStyle(isDisabled: coordinator?.currentFareEstimate == nil))
                                .disabled(coordinator?.currentFareEstimate == nil || isCalculatingFare)
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

    /// Use the rider's current GPS location as the pickup address.
    private func useCurrentLocation() {
        locationManager.requestLocation { clLocation in
            Task {
                let lat = clLocation.coordinate.latitude
                let lon = clLocation.coordinate.longitude
                do {
                    let loc = try await mapKit.reverseGeocode(latitude: lat, longitude: lon)
                    pickupAddress = loc.address ?? String(format: "%.5f, %.5f", lat, lon)
                } catch {
                    pickupAddress = String(format: "%.5f, %.5f", lat, lon)
                }
                recalculateFare()
            }
        }
    }

    /// Auto-calculate fare when addresses are selected. Debounced to avoid rapid geocoding.
    private func recalculateFare() {
        guard !pickupAddress.isEmpty, !destinationAddress.isEmpty else { return }
        guard let calculator = appState.fareCalculator else { return }

        // Cancel any in-flight calculation (debounce)
        fareCalcTask?.cancel()
        coordinator?.currentFareEstimate = nil
        isCalculatingFare = true; fareError = nil

        fareCalcTask = Task {
            // Brief debounce — wait for typing to settle
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { isCalculatingFare = false; return }

            do {
                guard let pickup = try await mapKit.geocode(address: pickupAddress) else {
                    fareError = "Could not find pickup address"; isCalculatingFare = false; return
                }
                guard !Task.isCancelled else { isCalculatingFare = false; return }
                guard let destination = try await mapKit.geocode(address: destinationAddress) else {
                    fareError = "Could not find destination"; isCalculatingFare = false; return
                }
                guard !Task.isCancelled else { isCalculatingFare = false; return }
                let fare = try await mapKit.estimateFare(from: pickup, to: destination, calculator: calculator)
                guard !Task.isCancelled else { isCalculatingFare = false; return }
                coordinator?.currentFareEstimate = fare
                coordinator?.pickupLocation = pickup
                coordinator?.destinationLocation = destination
            } catch {
                if !Task.isCancelled { fareError = "Route calculation failed. Check addresses." }
            }
            isCalculatingFare = false
        }
    }

    /// Send ride offer using the pre-calculated fare.
    private func sendOffer() {
        guard let driverPubkey = selectedDriverPubkey,
              let fare = coordinator?.currentFareEstimate,
              let pickup = coordinator?.pickupLocation,
              let destination = coordinator?.destinationLocation else { return }
        Task {
            await coordinator?.sendRideOffer(
                driverPubkey: driverPubkey, pickup: pickup,
                destination: destination, fareEstimate: fare
            )
        }
    }
}

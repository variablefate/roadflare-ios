import SwiftUI
import CoreLocation
import RidestrSDK
import RidestrUI

struct RideTab: View {
    @Environment(AppState.self) private var appState
    @State private var pickupAddress = ""
    @State private var destinationAddress = ""
    @State private var resolvedPickupCoord: (lat: Double, lon: Double)?
    @State private var resolvedDestCoord: (lat: Double, lon: Double)?
    @State private var selectedDriverPubkey: String?
    @State private var showChat = false
    @State private var showCancelWarning = false
    @State private var isCalculatingFare = false
    @State private var fareError: String?
    @State private var mapKit = MapKitServices()
    @State private var locationManager = RiderLocationManager()
    @State private var fareCalcTask: Task<Void, Never>?
    @State private var showProfile = false
    @State private var showConnectivity = false
    @State private var isOffline = false

    private var coordinator: RideCoordinator? { appState.rideCoordinator }
    private var stage: RiderStage { coordinator?.stateMachine.stage ?? .idle }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AppHeader(title: "RoadFlare", showProfile: $showProfile, showConnectivity: $showConnectivity, isOffline: isOffline)

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
            }
            .background(Color.rfSurface)
            .navigationBarHidden(true)
            .sheet(isPresented: $showProfile) { EditProfileSheet() }
            .sheet(isPresented: $showConnectivity) { ConnectivitySheet() }
            .sheet(isPresented: $showChat) { WiredChatView() }
            .task { await monitorConnection() }
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
                // Auto-select first online driver if none selected
                if selectedDriverPubkey == nil, let repo = appState.driversRepository {
                    let firstOnline = repo.drivers.first { d in
                        d.hasKey && repo.driverLocations[d.pubkey]?.status == "online"
                    }
                    selectedDriverPubkey = firstOnline?.pubkey
                }
                if pickupAddress.isEmpty, let addr = coordinator?.pickupLocation?.address {
                    pickupAddress = addr
                }
                if destinationAddress.isEmpty, let addr = coordinator?.destinationLocation?.address {
                    destinationAddress = addr
                }
            }
            .onChange(of: pickupAddress) {
                if pickupAddress.isEmpty {
                    fareCalcTask?.cancel()
                    coordinator?.currentFareEstimate = nil
                    resolvedPickupCoord = nil
                    isCalculatingFare = false
                    fareError = nil
                }
            }
            .onChange(of: destinationAddress) {
                if destinationAddress.isEmpty {
                    fareCalcTask?.cancel()
                    coordinator?.currentFareEstimate = nil
                    resolvedDestCoord = nil
                    isCalculatingFare = false
                    fareError = nil
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
                            VStack(alignment: .leading, spacing: 14) {
                                SectionLabel("Ride Details")

                                HStack(spacing: 0) {
                                    VStack(spacing: 0) {
                                        AddressSearchField(
                                            placeholder: "Pickup address",
                                            icon: "circle.fill",
                                            iconColor: .rfOnline,
                                            text: $pickupAddress,
                                            onSelect: { _ in recalculateFare() },
                                            onResolvedLocation: { lat, lon in resolvedPickupCoord = (lat, lon) },
                                            showCurrentLocation: true,
                                            onUseCurrentLocation: { useCurrentLocation() },
                                            savedLocations: recentLocationItems
                                        )

                                        Rectangle().fill(Color.rfSurfaceContainerHigh).frame(height: 1).padding(.leading, 32)

                                        AddressSearchField(
                                            placeholder: "Destination",
                                            icon: "circle.fill",
                                            iconColor: .rfPrimary,
                                            text: $destinationAddress,
                                            onSelect: { _ in recalculateFare() },
                                            onResolvedLocation: { lat, lon in resolvedDestCoord = (lat, lon) },
                                            savedLocations: recentLocationItems
                                        )
                                    }

                                    // Swap button
                                    Button {
                                        let temp = pickupAddress
                                        pickupAddress = destinationAddress
                                        destinationAddress = temp
                                        let tempCoord = resolvedPickupCoord
                                        resolvedPickupCoord = resolvedDestCoord
                                        resolvedDestCoord = tempCoord
                                        coordinator?.currentFareEstimate = nil
                                        recalculateFare()
                                    } label: {
                                        Image(systemName: "arrow.up.arrow.down")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(Color.rfOnSurfaceVariant)
                                            .frame(width: 36, height: 36)
                                            .background(Color.rfSurfaceContainerHigh)
                                            .clipShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.trailing, 8)
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
                                    VStack(spacing: 6) {
                                        HStack {
                                            Text(String(format: "%.1f mi · %.0f min", fare.distanceMiles, fare.durationMinutes))
                                                .font(RFFont.caption())
                                                .foregroundColor(Color.rfOnSurfaceVariant)
                                            Spacer()
                                            Text(formatFare(fare.fareUSD))
                                                .font(RFFont.headline(24))
                                                .foregroundColor(Color.rfPrimary)
                                        }
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

                                // Show send button only when fare is calculated
                                if coordinator?.currentFareEstimate != nil && !isCalculatingFare {
                                    Button { sendOffer() } label: {
                                        Text("Send RoadFlare Request")
                                    }
                                    .buttonStyle(RFPrimaryButtonStyle())
                                } else if pickupAddress.isEmpty || destinationAddress.isEmpty {
                                    // Show saved locations as quick picks (matching saved locations menu style)
                                    VStack(alignment: .leading, spacing: 8) {
                                        // Favorites
                                        ForEach(appState.savedLocations.favorites) { loc in
                                            Button {
                                                fillNextAddress(loc)
                                            } label: {
                                                HStack(spacing: 12) {
                                                    Image(systemName: iconForLocation(loc.nickname ?? loc.displayName))
                                                        .foregroundColor(Color.rfPrimary)
                                                        .frame(width: 24)
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(loc.nickname ?? loc.displayName)
                                                            .font(RFFont.title(15))
                                                            .foregroundColor(Color.rfOnSurface)
                                                        Text(loc.addressLine)
                                                            .font(RFFont.caption(12))
                                                            .foregroundColor(Color.rfOnSurfaceVariant)
                                                            .lineLimit(1)
                                                    }
                                                    Spacer()
                                                }
                                                .rfCard()
                                            }
                                            .buttonStyle(.plain)
                                        }

                                        // Recents
                                        ForEach(appState.savedLocations.recents) { loc in
                                            HStack(spacing: 12) {
                                                Button {
                                                    fillNextAddress(loc)
                                                } label: {
                                                    HStack(spacing: 12) {
                                                        Image(systemName: "clock")
                                                            .foregroundColor(Color.rfOffline)
                                                            .frame(width: 24)
                                                        VStack(alignment: .leading, spacing: 2) {
                                                            Text(loc.displayName)
                                                                .font(RFFont.body(14))
                                                                .foregroundColor(Color.rfOnSurface)
                                                            Text(loc.addressLine)
                                                                .font(RFFont.caption(12))
                                                                .foregroundColor(Color.rfOnSurfaceVariant)
                                                                .lineLimit(1)
                                                        }
                                                        Spacer()
                                                    }
                                                }
                                                .buttonStyle(.plain)

                                                // Delete recent
                                                Button {
                                                    withAnimation { appState.savedLocations.remove(id: loc.id) }
                                                } label: {
                                                    Image(systemName: "xmark")
                                                        .font(.system(size: 12))
                                                        .foregroundColor(Color.rfOffline)
                                                }
                                            }
                                            .rfCard(.low)
                                        }
                                    }
                                }
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

    private func fillNextAddress(_ loc: SavedLocation) {
        let address = loc.addressLine.isEmpty ? loc.displayName : loc.addressLine
        if pickupAddress.isEmpty {
            pickupAddress = address
            resolvedPickupCoord = (loc.latitude, loc.longitude)
        } else {
            destinationAddress = address
            resolvedDestCoord = (loc.latitude, loc.longitude)
        }
        recalculateFare()
    }

    private func iconForLocation(_ name: String) -> String {
        switch name.lowercased() {
        case "home": return "house.fill"
        case "work": return "briefcase.fill"
        default: return "mappin"
        }
    }

    /// Saved locations (favorites first, then recents) for address field dropdowns.
    private var recentLocationItems: [(name: String, address: String, lat: Double, lon: Double)] {
        let favorites = appState.savedLocations.favorites.map { loc in
            (name: loc.nickname ?? loc.displayName, address: loc.addressLine, lat: loc.latitude, lon: loc.longitude)
        }
        let recents = appState.savedLocations.recents.prefix(5).map { loc in
            (name: loc.displayName, address: loc.addressLine, lat: loc.latitude, lon: loc.longitude)
        }
        return favorites + recents
    }

    /// Use the rider's current GPS location as the pickup address.
    @State private var isLocating = false

    private func useCurrentLocation() {
        isLocating = true
        pickupAddress = "Finding your location..."
        locationManager.requestLocation { clLocation in
            Task {
                let lat = clLocation.coordinate.latitude
                let lon = clLocation.coordinate.longitude
                resolvedPickupCoord = (lat, lon)
                do {
                    let loc = try await mapKit.reverseGeocode(latitude: lat, longitude: lon)
                    pickupAddress = loc.address ?? String(format: "%.5f, %.5f", lat, lon)
                } catch {
                    pickupAddress = String(format: "%.5f, %.5f", lat, lon)
                }
                isLocating = false
                recalculateFare()
            }
        }
    }

    /// Auto-calculate fare when addresses are selected. Debounced to avoid rapid geocoding.
    /// Uses pre-resolved coordinates from MKLocalSearch when available (handles POIs correctly).
    private func recalculateFare() {
        guard !pickupAddress.isEmpty, !destinationAddress.isEmpty else { return }
        guard let calculator = appState.fareCalculator else { return }

        fareCalcTask?.cancel()
        coordinator?.currentFareEstimate = nil
        isCalculatingFare = true; fareError = nil

        fareCalcTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { isCalculatingFare = false; return }

            do {
                // Use pre-resolved coordinates if available, otherwise geocode from text
                let pickup: Location
                if let coord = resolvedPickupCoord {
                    pickup = Location(latitude: coord.lat, longitude: coord.lon, address: pickupAddress)
                } else if let geocoded = try await mapKit.geocode(address: pickupAddress) {
                    pickup = geocoded
                } else {
                    fareError = "Could not find pickup address"; isCalculatingFare = false; return
                }
                guard !Task.isCancelled else { isCalculatingFare = false; return }

                let destination: Location
                if let coord = resolvedDestCoord {
                    destination = Location(latitude: coord.lat, longitude: coord.lon, address: destinationAddress)
                } else if let geocoded = try await mapKit.geocode(address: destinationAddress) {
                    destination = geocoded
                } else {
                    fareError = "Could not find destination"; isCalculatingFare = false; return
                }
                guard !Task.isCancelled else { isCalculatingFare = false; return }

                let fare = try await mapKit.estimateFare(from: pickup, to: destination, calculator: calculator)
                guard !Task.isCancelled else { isCalculatingFare = false; return }
                coordinator?.currentFareEstimate = fare
                coordinator?.pickupLocation = pickup
                coordinator?.destinationLocation = destination

                // Save as recents for quick access next time
                appState.savedLocations.save(SavedLocation(
                    id: UUID().uuidString, latitude: pickup.latitude, longitude: pickup.longitude,
                    displayName: pickupAddress, addressLine: pickup.address ?? pickupAddress,
                    isPinned: false, timestampMs: Int(Date.now.timeIntervalSince1970 * 1000)
                ))
                appState.savedLocations.save(SavedLocation(
                    id: UUID().uuidString, latitude: destination.latitude, longitude: destination.longitude,
                    displayName: destinationAddress, addressLine: destination.address ?? destinationAddress,
                    isPinned: false, timestampMs: Int(Date.now.timeIntervalSince1970 * 1000)
                ))
                // Backup saved locations to Nostr
                await appState.publishProfileBackup()
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

    private func monitorConnection() async {
        while !Task.isCancelled {
            if let rm = appState.relayManager { isOffline = !(await rm.isConnected) }
            try? await Task.sleep(for: .seconds(10))
        }
    }
}

import SwiftUI
import CoreLocation
import RidestrSDK
import RidestrUI
import RoadFlareCore

struct RideRequestView: View {
    @Environment(AppState.self) private var appState
    @Binding var pickupAddress: String
    @Binding var destinationAddress: String
    @Binding var resolvedPickupCoord: Coordinate?
    @Binding var resolvedDestCoord: Coordinate?
    @Binding var selectedDriverPubkey: String?
    @Binding var fareError: String?

    @State private var isCalculatingFare = false
    @State private var fareCalcTask: Task<Void, Never>?
    @State private var mapKit = MapKitServices()
    @State private var locationManager = RiderLocationManager()
    @State private var isLocating = false

    private var coordinator: RideCoordinator? { appState.rideCoordinator }
    private var stage: RiderStage { coordinator?.session.stage ?? .idle }
    private var onlineDrivers: [FollowedDriver] {
        appState.followedDrivers.filter { driver in
            driver.hasKey && appState.driverLocation(pubkey: driver.pubkey)?.status == "online"
        }
    }
    private var onlineDriverPubkeys: [String] { onlineDrivers.map(\.pubkey) }
    private var hasValidSelectedDriver: Bool {
        guard let selectedDriverPubkey else { return false }
        return onlineDriverPubkeys.contains(selectedDriverPubkey)
    }
    private func displayName(for driver: FollowedDriver) -> String {
        appState.driverDisplayName(pubkey: driver.pubkey)
            ?? driver.name
            ?? String(driver.pubkey.prefix(8)) + "..."
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if appState.hasFollowedDrivers {
                    if onlineDrivers.isEmpty {
                        VStack(spacing: 24) {
                            Spacer().frame(height: 80)
                            Image(systemName: "car.side")
                                .font(.system(size: 48))
                                .foregroundColor(Color.rfOnSurfaceVariant)
                            Text("No Drivers Online")
                                .font(RFFont.headline(20))
                                .foregroundColor(Color.rfOnSurface)
                            Text("Check back later, or ping a driver to let them know you need a ride.")
                                .font(RFFont.body(15))
                                .foregroundColor(Color.rfOnSurfaceVariant)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                            if appState.followedDrivers.contains(where: { appState.canPingDriver($0) }) {
                                Button("Ping a Driver") {
                                    appState.selectedTab = 1
                                }
                                .buttonStyle(RFPrimaryButtonStyle())
                                .padding(.horizontal, 48)
                            }
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
                                            Text(displayName(for: driver))
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
                        if hasValidSelectedDriver {
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
                                            onResolvedLocation: { lat, lon in resolvedPickupCoord = Coordinate(lat: lat, lon: lon) },
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
                                            onResolvedLocation: { lat, lon in resolvedDestCoord = Coordinate(lat: lat, lon: lon) },
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
                                    Text(appState.settings.allPaymentMethodNames.joined(separator: ", "))
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
                                    // Show saved locations as quick picks
                                    VStack(alignment: .leading, spacing: 8) {
                                        // Favorites
                                        ForEach(appState.favoriteLocations) { loc in
                                            Button {
                                                fillNextAddress(loc)
                                            } label: {
                                                HStack(spacing: 10) {
                                                    Image(systemName: iconForLocation(loc.nickname ?? loc.displayName))
                                                        .font(.system(size: 13))
                                                        .foregroundColor(Color.rfPrimary)
                                                        .frame(width: 20)
                                                    VStack(alignment: .leading, spacing: 1) {
                                                        Text(loc.nickname ?? loc.displayName)
                                                            .font(RFFont.title(13))
                                                            .foregroundColor(Color.rfOnSurface)
                                                        Text(loc.addressLine)
                                                            .font(RFFont.caption(11))
                                                            .foregroundColor(Color.rfOnSurfaceVariant)
                                                            .lineLimit(1)
                                                    }
                                                    Spacer()
                                                }
                                                .padding(10)
                                                .background(Color.rfSurfaceContainer)
                                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                            }
                                            .buttonStyle(.plain)
                                        }

                                        // Recents (swipe left to delete)
                                        ForEach(appState.recentLocations) { loc in
                                            SwipeToDeleteRow {
                                                fillNextAddress(loc)
                                            } onDelete: {
                                                withAnimation { appState.removeLocation(id: loc.id) }
                                            } content: {
                                                HStack(spacing: 10) {
                                                    Image(systemName: "clock")
                                                        .font(.system(size: 13))
                                                        .foregroundColor(Color.rfOffline)
                                                        .frame(width: 20)
                                                    VStack(alignment: .leading, spacing: 1) {
                                                        Text(loc.displayName)
                                                            .font(RFFont.body(13))
                                                            .foregroundColor(Color.rfOnSurface)
                                                        Text(loc.addressLine)
                                                            .font(RFFont.caption(11))
                                                            .foregroundColor(Color.rfOnSurfaceVariant)
                                                            .lineLimit(1)
                                                    }
                                                    Spacer()
                                                }
                                                .padding(10)
                                                .background(Color.rfSurfaceContainer)
                                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                            }
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
        .onAppear {
            refreshSelectedDriverSelection()
            if pickupAddress.isEmpty, let addr = coordinator?.pickupLocation?.address {
                pickupAddress = addr
            }
            if destinationAddress.isEmpty, let addr = coordinator?.destinationLocation?.address {
                destinationAddress = addr
            }
        }
        .onDisappear {
            fareCalcTask?.cancel()
            fareCalcTask = nil
            isCalculatingFare = false
        }
        .onChange(of: appState.requestRideDriverPubkey) {
            refreshSelectedDriverSelection()
        }
        .onChange(of: onlineDriverPubkeys) {
            refreshSelectedDriverSelection()
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
    }

    // MARK: - Actions

    private func fillNextAddress(_ loc: SavedLocation) {
        let address = loc.addressLine.isEmpty ? loc.displayName : loc.addressLine
        if pickupAddress.isEmpty {
            pickupAddress = address
            resolvedPickupCoord = Coordinate(lat: loc.latitude, lon: loc.longitude)
        } else {
            destinationAddress = address
            resolvedDestCoord = Coordinate(lat: loc.latitude, lon: loc.longitude)
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

    private var recentLocationItems: [(name: String, address: String, lat: Double, lon: Double)] {
        let favorites = appState.favoriteLocations.map { loc in
            (name: loc.nickname ?? loc.displayName, address: loc.addressLine, lat: loc.latitude, lon: loc.longitude)
        }
        let recents = appState.recentLocations.prefix(5).map { loc in
            (name: loc.displayName, address: loc.addressLine, lat: loc.latitude, lon: loc.longitude)
        }
        return favorites + recents
    }

    private func useCurrentLocation() {
        let previousPickupAddress = pickupAddress
        isLocating = true
        pickupAddress = "Finding your location..."
        locationManager.requestLocation { clLocation in
            Task {
                let lat = clLocation.coordinate.latitude
                let lon = clLocation.coordinate.longitude
                resolvedPickupCoord = Coordinate(lat: lat, lon: lon)
                do {
                    let loc = try await mapKit.reverseGeocode(latitude: lat, longitude: lon)
                    pickupAddress = loc.address ?? String(format: "%.5f, %.5f", lat, lon)
                } catch {
                    pickupAddress = String(format: "%.5f, %.5f", lat, lon)
                }
                isLocating = false
                recalculateFare()
            }
        } onFailure: {
            Task { @MainActor in
                isLocating = false
                pickupAddress = previousPickupAddress
                fareError = locationManager.permissionDenied
                    ? "Location access is disabled. Enable it in Settings to use your current location."
                    : "Couldn't get your current location. Try again."
            }
        }
    }

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

                appState.saveLocation(SavedLocation(
                    id: UUID().uuidString, latitude: pickup.latitude, longitude: pickup.longitude,
                    displayName: pickupAddress, addressLine: pickup.address ?? pickupAddress,
                    isPinned: false, timestampMs: Int(Date.now.timeIntervalSince1970 * 1000)
                ))
                appState.saveLocation(SavedLocation(
                    id: UUID().uuidString, latitude: destination.latitude, longitude: destination.longitude,
                    displayName: destinationAddress, addressLine: destination.address ?? destinationAddress,
                    isPinned: false, timestampMs: Int(Date.now.timeIntervalSince1970 * 1000)
                ))
            } catch {
                if !Task.isCancelled { fareError = "Route calculation failed. Check addresses." }
            }
            isCalculatingFare = false
        }
    }

    private func sendOffer() {
        fareCalcTask?.cancel()
        fareCalcTask = nil
        guard let driverPubkey = selectedDriverPubkey,
              onlineDriverPubkeys.contains(driverPubkey),
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

    func refreshSelectedDriverSelection() {
        var appliedExplicitSelection = false
        if let requestedPubkey = appState.requestRideDriverPubkey {
            selectedDriverPubkey = requestedPubkey
            appState.requestRideDriverPubkey = nil
            appliedExplicitSelection = true
        }

        if selectedDriverPubkey == nil, let activeRideDriver = coordinator?.session.driverPubkey {
            selectedDriverPubkey = activeRideDriver
        }

        guard stage == .idle else { return }
        guard !onlineDriverPubkeys.isEmpty else {
            self.selectedDriverPubkey = nil
            return
        }

        if let selectedDriverPubkey {
            guard onlineDriverPubkeys.contains(selectedDriverPubkey) else {
                self.selectedDriverPubkey = nil
                return
            }
            return
        }

        if !appliedExplicitSelection {
            self.selectedDriverPubkey = onlineDrivers.first?.pubkey
        }
    }
}

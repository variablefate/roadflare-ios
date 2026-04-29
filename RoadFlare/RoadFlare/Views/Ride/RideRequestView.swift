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
    @State private var staleRefreshToastMessage: String?
    @State private var staleRefreshToastIsError: Bool = false
    @State private var isRefreshingStaleKeys: Bool = false

    private var coordinator: RideCoordinator? { appState.rideCoordinator }
    private var stage: RiderStage { coordinator?.session.stage ?? .idle }

    var body: some View {
        // Capture expensive façade reads once per body invocation. `body` uses
        // each of these in multiple places (isEmpty / ForEach / .onChange /
        // the ride-details gate), and every access to `appState.onlineDriverOptions()`
        // rebuilds the filtered `RideRequestDriverOption` list from the repo.
        let onlineOptions = appState.onlineDriverOptions()
        let onlinePubkeys = onlineOptions.map(\.pubkey)
        let staleKeyDriverCount = appState.staleKeyDriverPubkeys.count
        let favorites = appState.favoriteLocationRows
        let recents = appState.recentLocationRows
        let addressSearchItems = makeAddressSearchItems(favorites: favorites, recents: recents)
        let hasValidSelectedDriver: Bool = {
            guard let selectedDriverPubkey else { return false }
            return onlinePubkeys.contains(selectedDriverPubkey)
        }()
        return ScrollView {
            VStack(spacing: 16) {
                if !appState.hasFollowedDrivers {
                    VStack(spacing: 24) {
                        Spacer().frame(height: 80)
                        Image(systemName: "person.2")
                            .font(.system(size: 48))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                        Text("No Drivers Added")
                            .font(RFFont.headline(20))
                            .foregroundColor(Color.rfOnSurface)
                        Text("Add trusted drivers to your network to request a ride.")
                            .font(RFFont.body(15))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button("Add a Driver") {
                            appState.selectedTab = 1
                        }
                        .buttonStyle(RFPrimaryButtonStyle())
                        .padding(.horizontal, 48)
                    }
                } else if onlineOptions.isEmpty {
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
                            if appState.hasPingableDriver {
                                Button("Ping a Driver") {
                                    appState.selectedTab = 1
                                }
                                .buttonStyle(RFPrimaryButtonStyle())
                                .padding(.horizontal, 48)
                            }
                            if staleKeyDriverCount > 0 {
                                StaleKeyRefreshBanner(
                                    count: staleKeyDriverCount,
                                    isRefreshing: isRefreshingStaleKeys,
                                    onRefresh: refreshStaleKeys
                                )
                                .padding(.horizontal, 16)
                            }
                        }
                } else {
                    // Available drivers
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Available Drivers")
                        ForEach(onlineOptions) { option in
                            Button { selectedDriverPubkey = option.pubkey } label: {
                                HStack(spacing: 12) {
                                    FlareIndicator(color: selectedDriverPubkey == option.pubkey ? .rfPrimary : .rfOnline)
                                        .frame(height: 36)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.displayName)
                                            .font(RFFont.title(15))
                                            .foregroundColor(Color.rfOnSurface)
                                        Text("Available")
                                            .font(RFFont.caption(11))
                                            .foregroundColor(Color.rfOnline)
                                    }
                                    Spacer()
                                    if selectedDriverPubkey == option.pubkey {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(Color.rfPrimary)
                                    }
                                }
                                .rfCard(selectedDriverPubkey == option.pubkey ? .high : .standard)
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
                                        savedLocations: addressSearchItems
                                    )

                                    Rectangle().fill(Color.rfSurfaceContainerHigh).frame(height: 1).padding(.leading, 32)

                                    AddressSearchField(
                                        placeholder: "Destination",
                                        icon: "circle.fill",
                                        iconColor: .rfPrimary,
                                        text: $destinationAddress,
                                        onSelect: { _ in recalculateFare() },
                                        onResolvedLocation: { lat, lon in resolvedDestCoord = Coordinate(lat: lat, lon: lon) },
                                        savedLocations: addressSearchItems
                                    )
                                }

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

                            HStack {
                                Image(systemName: "creditcard")
                                    .foregroundColor(Color.rfPrimary)
                                Text(appState.allPaymentMethodNames.joined(separator: ", "))
                                    .font(RFFont.caption(12))
                                    .foregroundColor(Color.rfOnSurfaceVariant)
                            }
                            .padding(.horizontal, 4)

                            if let error = fareError {
                                Text(error).font(RFFont.caption()).foregroundColor(Color.rfError)
                            }

                            if coordinator?.currentFareEstimate != nil && !isCalculatingFare {
                                Button { sendOffer() } label: {
                                    Text("Send RoadFlare Request")
                                }
                                .buttonStyle(RFPrimaryButtonStyle())
                            } else if pickupAddress.isEmpty || destinationAddress.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(favorites) { row in
                                        Button {
                                            fillNextAddress(row)
                                        } label: {
                                            HStack(spacing: 10) {
                                                Image(systemName: row.iconSystemName)
                                                    .font(.system(size: 13))
                                                    .foregroundColor(Color.rfPrimary)
                                                    .frame(width: 20)
                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(row.label)
                                                        .font(RFFont.title(13))
                                                        .foregroundColor(Color.rfOnSurface)
                                                    Text(row.addressLine)
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

                                    ForEach(recents) { row in
                                        SwipeToDeleteRow {
                                            fillNextAddress(row)
                                        } onDelete: {
                                            withAnimation { appState.removeLocation(id: row.id) }
                                        } content: {
                                            HStack(spacing: 10) {
                                                Image(systemName: "clock")
                                                    .font(.system(size: 13))
                                                    .foregroundColor(Color.rfOffline)
                                                    .frame(width: 20)
                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(row.displayName)
                                                        .font(RFFont.body(13))
                                                        .foregroundColor(Color.rfOnSurface)
                                                    Text(row.addressLine)
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
        .onChange(of: onlinePubkeys) {
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
        .toast($staleRefreshToastMessage, isError: staleRefreshToastIsError)
    }

    private func refreshStaleKeys() {
        guard !isRefreshingStaleKeys else { return }
        isRefreshingStaleKeys = true
        Task {
            let sentCount = await appState.refreshAllStaleDriverKeys()
            isRefreshingStaleKeys = false
            if sentCount == 0 {
                staleRefreshToastMessage = "Just sent — try again in a minute."
                staleRefreshToastIsError = true
            } else {
                let plural = sentCount == 1 ? "driver" : "drivers"
                staleRefreshToastMessage = "Refresh requested for \(sentCount) \(plural)."
                staleRefreshToastIsError = false
            }
        }
    }

    // MARK: - Actions

    private func fillNextAddress(_ row: SavedLocationRow) {
        let address = row.addressLine.isEmpty ? row.displayName : row.addressLine
        if pickupAddress.isEmpty {
            pickupAddress = address
            resolvedPickupCoord = Coordinate(lat: row.latitude, lon: row.longitude)
        } else {
            destinationAddress = address
            resolvedDestCoord = Coordinate(lat: row.latitude, lon: row.longitude)
        }
        recalculateFare()
    }

    /// Build the flat (name, address, lat, lon) tuple list that
    /// `AddressSearchField` consumes. Takes already-captured row arrays so the
    /// façade is not re-read twice (once per AddressSearchField instance).
    private func makeAddressSearchItems(
        favorites: [SavedLocationRow],
        recents: [SavedLocationRow]
    ) -> [(name: String, address: String, lat: Double, lon: Double)] {
        let favItems = favorites.map { row in
            (name: row.label, address: row.addressLine, lat: row.latitude, lon: row.longitude)
        }
        let recentItems = recents.prefix(5).map { row in
            (name: row.displayName, address: row.addressLine, lat: row.latitude, lon: row.longitude)
        }
        return favItems + Array(recentItems)
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

                appState.saveGeocodedLocation(
                    latitude: pickup.latitude, longitude: pickup.longitude,
                    displayName: pickupAddress, addressLine: pickup.address ?? pickupAddress
                )
                appState.saveGeocodedLocation(
                    latitude: destination.latitude, longitude: destination.longitude,
                    displayName: destinationAddress, addressLine: destination.address ?? destinationAddress
                )
            } catch {
                if !Task.isCancelled { fareError = "Route calculation failed. Check addresses." }
            }
            isCalculatingFare = false
        }
    }

    private func sendOffer() {
        fareCalcTask?.cancel()
        fareCalcTask = nil
        let onlinePubkeys = appState.onlineDriverOptions().map(\.pubkey)
        guard let driverPubkey = selectedDriverPubkey,
              onlinePubkeys.contains(driverPubkey),
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
        // Pay for the façade call once per invocation rather than four times
        // (3 `onlineDriverPubkeys` reads + 1 `onlineDriverOptions.first` read
        // in the pre-capture shape).
        let onlineOptions = appState.onlineDriverOptions()
        let onlinePubkeys = onlineOptions.map(\.pubkey)

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
        guard !onlinePubkeys.isEmpty else {
            self.selectedDriverPubkey = nil
            return
        }

        if let selectedDriverPubkey {
            guard onlinePubkeys.contains(selectedDriverPubkey) else {
                self.selectedDriverPubkey = nil
                return
            }
            return
        }

        if !appliedExplicitSelection {
            self.selectedDriverPubkey = onlineOptions.first?.pubkey
        }
    }
}

// MARK: - Stale Key Refresh Banner

/// Empty-state CTA shown when the rider has no eligible online drivers but at
/// least one followed driver has a stale key. Without this, the rider sees an
/// empty list with no explanation — the SDK already supports the refresh
/// request (Kind 3188 "stale" ack), but riders had no surface to fire it.
struct StaleKeyRefreshBanner: View {
    let count: Int
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "key.slash")
                    .foregroundColor(Color.rfError)
                Text(headline)
                    .font(RFFont.title(15))
                    .foregroundColor(Color.rfOnSurface)
            }
            Text("Their keys rotated and need to be re-shared before you can request a ride.")
                .font(RFFont.body(13))
                .foregroundColor(Color.rfOnSurfaceVariant)
            Button(action: onRefresh) {
                HStack(spacing: 8) {
                    if isRefreshing {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Request Fresh Keys")
                }
            }
            .buttonStyle(RFPrimaryButtonStyle())
            .disabled(isRefreshing)
        }
        .rfCard(.high)
    }

    private var headline: String {
        count == 1
            ? "1 driver has an outdated key"
            : "\(count) drivers have outdated keys"
    }
}

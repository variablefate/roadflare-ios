import SwiftUI
import CoreLocation
import RidestrSDK
import RidestrUI

struct Coordinate: Equatable {
    let lat: Double
    let lon: Double
}

struct RideTab: View {
    @Environment(AppState.self) private var appState

    // Cross-mode state (passed as bindings to child views)
    @State private var pickupAddress = ""
    @State private var destinationAddress = ""
    @State private var resolvedPickupCoord: Coordinate?
    @State private var resolvedDestCoord: Coordinate?
    @State private var selectedDriverPubkey: String?
    @State private var fareError: String?

    // Tab-level state
    @State private var showProfile = false
    @State private var showConnectivity = false
    @State private var isOffline = false

    private var coordinator: RideCoordinator? { appState.rideCoordinator }
    private var stage: RiderStage { coordinator?.session.stage ?? .idle }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AppHeader(title: "RoadFlare", showProfile: $showProfile, showConnectivity: $showConnectivity, isOffline: isOffline)

                ZStack {
                    Color.rfSurface.ignoresSafeArea()

                    switch stage {
                    case .idle:
                        RideRequestView(
                            pickupAddress: $pickupAddress,
                            destinationAddress: $destinationAddress,
                            resolvedPickupCoord: $resolvedPickupCoord,
                            resolvedDestCoord: $resolvedDestCoord,
                            selectedDriverPubkey: $selectedDriverPubkey,
                            fareError: $fareError
                        )
                    default:
                        ActiveRideView(onRideClosed: {
                            selectedDriverPubkey = nil
                            pickupAddress = ""
                            destinationAddress = ""
                            resolvedPickupCoord = nil
                            resolvedDestCoord = nil
                            fareError = nil
                            coordinator?.currentFareEstimate = nil
                            coordinator?.pickupLocation = nil
                            coordinator?.destinationLocation = nil
                        })
                    }
                }
            }
            .background(Color.rfSurface)
            .navigationBarHidden(true)
            .sheet(isPresented: $showProfile) { EditProfileSheet() }
            .sheet(isPresented: $showConnectivity) { ConnectivitySheet() }
            .task { await monitorConnection() }
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
        }
    }

    private func monitorConnection() async {
        while !Task.isCancelled {
            if let rm = appState.relayManager { isOffline = !(await rm.isConnected) }
            try? await Task.sleep(for: .seconds(10))
        }
    }
}

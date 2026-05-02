import SwiftUI
import RidestrSDK
import RidestrUI
import RoadFlareCore

struct ActiveRideView: View {
    @Environment(AppState.self) private var appState
    let onRideClosed: () -> Void

    @State private var showChat = false
    @State private var showCancelWarning = false

    private var coordinator: RideCoordinator? { appState.rideCoordinator }
    private var stage: RiderStage { coordinator?.session.stage ?? .idle }

    var body: some View {
        RideStatusCard(
            stage: stage,
            pin: coordinator?.session.pin,
            fareEstimate: coordinator?.currentFareEstimate,
            paymentMethods: coordinator?.activeRidePaymentMethods
                ?? appState.settings.roadflarePaymentMethods,
            driverName: coordinator?.session.driverPubkey.flatMap {
                appState.driverDisplayName(pubkey: $0)
            },
            // Prefer the Kind 30173 snapshot taken at acceptance — locks the active
            // ride to the agreed vehicle even if the driver swaps mid-trip. Fall
            // back to the Kind 0 profile when no snapshot is available (driver
            // never published Kind 30173, or app cold-started mid-ride before the
            // first availability event arrived). See issue #91.
            vehicleDescription: coordinator?.activeRideVehicle?.description
                ?? coordinator?.session.driverPubkey.flatMap {
                    appState.driverProfile(pubkey: $0)?.vehicleDescription
                },
            pickupAddress: coordinator?.pickupLocation?.address,
            destinationAddress: coordinator?.destinationLocation?.address,
            unreadChatCount: coordinator?.chat.unreadCount ?? 0,
            onCancel: { showCancelWarning = true },
            onChat: {
                coordinator?.chat.markRead()
                showChat = true
            },
            onCloseRide: {
                Task {
                    if coordinator?.session.stage == .completed {
                        await coordinator?.closeCompletedRide()
                    } else {
                        await coordinator?.forceEndRide()
                    }
                }
                onRideClosed()
            }
        )
        .environment(\.ridestrTheme, roadFlareTheme)
        .sheet(isPresented: $showChat) {
            WiredChatView()
                .onDisappear { coordinator?.chat.markRead() }
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
}

import SwiftUI
import RidestrSDK

/// Drop-in view that displays the current ride stage with appropriate visuals and actions.
///
/// Stage rendering follows the Ridestr protocol lifecycle — NOT customizable.
/// Colors, fonts, and corner radius are customizable via `RidestrTheme`.
/// Actions (cancel, chat, close) are closures — the host app controls navigation.
///
/// ```swift
/// RideStatusCard(
///     stage: stateMachine.stage,
///     pin: stateMachine.pin,
///     fareEstimate: fareEstimate,
///     paymentMethods: [.zelle, .venmo],
///     onCancel: { showCancelAlert = true },
///     onChat: { showChatSheet = true },
///     onCloseRide: { resetRide() }
/// )
/// .environment(\.ridestrTheme, myTheme)
/// ```
public struct RideStatusCard: View {
    public let stage: RiderStage
    public let pin: String?
    public let fareEstimate: FareEstimate?
    public let paymentMethods: [PaymentMethod]

    public var onCancel: (() -> Void)?
    public var onChat: (() -> Void)?
    public var onCloseRide: (() -> Void)?

    public init(
        stage: RiderStage,
        pin: String? = nil,
        fareEstimate: FareEstimate? = nil,
        paymentMethods: [PaymentMethod] = [],
        onCancel: (() -> Void)? = nil,
        onChat: (() -> Void)? = nil,
        onCloseRide: (() -> Void)? = nil
    ) {
        self.stage = stage
        self.pin = pin
        self.fareEstimate = fareEstimate
        self.paymentMethods = paymentMethods
        self.onCancel = onCancel
        self.onChat = onChat
        self.onCloseRide = onCloseRide
    }

    @Environment(\.ridestrTheme) private var theme

    public var body: some View {
        switch stage {
        case .idle:
            EmptyView()
        case .waitingForAcceptance:
            waitingView
        case .driverAccepted, .rideConfirmed, .enRoute:
            enRouteView
        case .driverArrived:
            arrivedView
        case .inProgress:
            inProgressView
        case .completed:
            completedView
        }
    }

    // MARK: - Waiting

    private var waitingView: some View {
        VStack(spacing: 32) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
                .tint(theme.accentColor)
            Text("Waiting for driver...")
                .font(theme.headline(22))
                .foregroundColor(theme.onSurfaceColor)
            Text("This usually takes a few seconds")
                .font(theme.body(14))
                .foregroundColor(theme.onSurfaceSecondaryColor)
            Spacer()
            if let onCancel {
                Button("Cancel Request") { onCancel() }
                    .font(theme.title(16))
                    .foregroundColor(theme.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(theme.surfaceSecondaryColor)
                    .clipShape(RoundedRectangle(cornerRadius: theme.cardCornerRadius))
                    .padding(.horizontal, 24)
            }
            Spacer().frame(height: 40)
        }
    }

    // MARK: - En Route

    private var enRouteView: some View {
        VStack(spacing: 32) {
            Spacer()
            ZStack {
                Circle().fill(theme.accentColor.opacity(0.1)).frame(width: 120, height: 120)
                Image(systemName: "car.fill")
                    .font(.system(size: 48))
                    .foregroundColor(theme.accentColor)
            }
            Text("Driver is on the way!")
                .font(theme.headline(24))
                .foregroundColor(theme.onSurfaceColor)
            Text("Heading to your pickup location")
                .font(theme.body(15))
                .foregroundColor(theme.onSurfaceSecondaryColor)
            Spacer()
            actionButtons
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
                .foregroundColor(theme.successColor)
            Text("Driver Has Arrived!")
                .font(theme.headline(24))
                .foregroundColor(theme.onSurfaceColor)
            Text("Show this PIN to your driver:")
                .font(theme.body(14))
                .foregroundColor(theme.onSurfaceSecondaryColor)

            if let pin {
                PINDisplayView(pin: pin)
            }

            Text("The driver enters this to verify your identity")
                .font(theme.caption(12))
                .foregroundColor(theme.onSurfaceSecondaryColor.opacity(0.6))
            Spacer()
            actionButtons
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
                .foregroundColor(theme.accentColor)
            Text("Ride in Progress")
                .font(theme.headline(24))
                .foregroundColor(theme.onSurfaceColor)

            if let fare = fareEstimate {
                FareEstimateView(estimate: fare, paymentMethods: paymentMethods, displayMode: .card)
                    .padding(.horizontal, 24)
            }

            Spacer()
            if let onChat {
                Button { onChat() } label: {
                    Label("Chat with Driver", systemImage: "message")
                        .font(theme.title(16))
                        .foregroundColor(theme.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(theme.surfaceSecondaryColor)
                        .clipShape(RoundedRectangle(cornerRadius: theme.cardCornerRadius))
                }
                .padding(.horizontal, 24)
            }
            Spacer().frame(height: 40)
        }
    }

    // MARK: - Completed

    private var completedView: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(theme.successColor.opacity(0.1)).frame(width: 100, height: 100)
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundColor(theme.successColor)
            }
            Text("Ride Complete!")
                .font(theme.headline(28))
                .foregroundColor(theme.onSurfaceColor)

            if let fare = fareEstimate {
                FareEstimateView(estimate: fare, paymentMethods: paymentMethods, displayMode: .card)
                    .padding(.horizontal, 24)
            }

            Spacer()
            if let onCloseRide {
                Button { onCloseRide() } label: {
                    Label("I've Paid — Close Ride", systemImage: "checkmark.circle")
                        .font(theme.title(18))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(theme.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: theme.cardCornerRadius))
                }
                .padding(.horizontal, 24)
            }
            Spacer().frame(height: 40)
        }
    }

    // MARK: - Shared Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 12) {
            if let onChat {
                Button { onChat() } label: {
                    Label("Chat with Driver", systemImage: "message")
                        .font(theme.title(16))
                        .foregroundColor(theme.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(theme.surfaceSecondaryColor)
                        .clipShape(RoundedRectangle(cornerRadius: theme.cardCornerRadius))
                }
            }

            if let onCancel {
                Button("Cancel Ride") { onCancel() }
                    .font(theme.body(15))
                    .foregroundColor(theme.onSurfaceSecondaryColor)
            }
        }
    }
}

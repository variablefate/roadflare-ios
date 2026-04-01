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
///     paymentMethods: ["zelle", "venmo"],
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
    public let paymentMethods: [String]
    public let driverName: String?
    public let pickupAddress: String?
    public let destinationAddress: String?

    public var unreadChatCount: Int
    public var onCancel: (() -> Void)?
    public var onChat: (() -> Void)?
    public var onCloseRide: (() -> Void)?

    public init(
        stage: RiderStage,
        pin: String? = nil,
        fareEstimate: FareEstimate? = nil,
        paymentMethods: [String] = [],
        driverName: String? = nil,
        pickupAddress: String? = nil,
        destinationAddress: String? = nil,
        unreadChatCount: Int = 0,
        onCancel: (() -> Void)? = nil,
        onChat: (() -> Void)? = nil,
        onCloseRide: (() -> Void)? = nil
    ) {
        self.stage = stage
        self.pin = pin
        self.fareEstimate = fareEstimate
        self.paymentMethods = paymentMethods
        self.driverName = driverName
        self.pickupAddress = pickupAddress
        self.destinationAddress = destinationAddress
        self.unreadChatCount = unreadChatCount
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
        VStack(spacing: 24) {
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

            if let fare = fareEstimate {
                FareEstimateView(estimate: fare, paymentMethods: paymentMethods, displayMode: .compact)
                    .padding(.horizontal, 24)
            }

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
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle().fill(theme.accentColor.opacity(0.1)).frame(width: 100, height: 100)
                Image(systemName: "car.fill")
                    .font(.system(size: 44))
                    .foregroundColor(theme.accentColor)
            }
            if let driverName, !driverName.isEmpty {
                Text("\(driverName) is on the way!")
                    .font(theme.headline(22))
                    .foregroundColor(theme.onSurfaceColor)
            } else {
                Text("Driver is on the way!")
                    .font(theme.headline(22))
                    .foregroundColor(theme.onSurfaceColor)
            }

            rideSummaryCard

            if let pin, stage == .rideConfirmed || stage == .enRoute {
                VStack(spacing: 6) {
                    Text("Your Pickup PIN")
                        .font(theme.caption(12))
                        .foregroundColor(theme.onSurfaceSecondaryColor)
                    PINDisplayView(pin: pin)
                }
            }

            Spacer()
            actionButtons
            Spacer().frame(height: 40)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Arrived (PIN)

    private var arrivedView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(theme.successColor)
            if let driverName, !driverName.isEmpty {
                Text("\(driverName) has arrived!")
                    .font(theme.headline(24))
                    .foregroundColor(theme.onSurfaceColor)
            } else {
                Text("Driver Has Arrived!")
                    .font(theme.headline(24))
                    .foregroundColor(theme.onSurfaceColor)
            }
            if let pin {
                Text("Show this PIN to your driver:")
                    .font(theme.body(14))
                    .foregroundColor(theme.onSurfaceSecondaryColor)
                PINDisplayView(pin: pin)
                Text("The driver enters this to verify your identity")
                    .font(theme.caption(12))
                    .foregroundColor(theme.onSurfaceSecondaryColor.opacity(0.6))
            } else {
                Text("PIN verified. Waiting for the driver to start the ride.")
                    .font(theme.body(14))
                    .foregroundColor(theme.onSurfaceSecondaryColor)
                    .multilineTextAlignment(.center)
            }
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
            if let onCloseRide {
                Button { onCloseRide() } label: {
                    Label("I've Paid — End Ride", systemImage: "checkmark.circle")
                        .font(theme.title(18))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(theme.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: theme.cardCornerRadius))
                }
                .padding(.horizontal, 24)
            }
            chatButton
                .padding(.horizontal, 24)
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

    // MARK: - Ride Summary Card

    @ViewBuilder
    private var rideSummaryCard: some View {
        let hasContent = pickupAddress != nil || destinationAddress != nil || fareEstimate != nil
        if hasContent {
            VStack(spacing: 0) {
                if let pickup = pickupAddress {
                    HStack(spacing: 10) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 8))
                            .foregroundColor(theme.successColor)
                        Text(pickup)
                            .font(theme.body(14))
                            .foregroundColor(theme.onSurfaceColor)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                }
                if let dest = destinationAddress {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(theme.accentColor)
                        Text(dest)
                            .font(theme.body(14))
                            .foregroundColor(theme.onSurfaceColor)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                }
                if let fare = fareEstimate {
                    Divider().padding(.vertical, 4)
                    FareEstimateView(estimate: fare, paymentMethods: paymentMethods, displayMode: .compact)
                }
            }
            .padding(16)
            .background(theme.surfaceSecondaryColor)
            .clipShape(RoundedRectangle(cornerRadius: theme.cardCornerRadius))
        }
    }

    // MARK: - Shared Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 12) {
            chatButton
            if let onCancel {
                Button("Cancel Ride") { onCancel() }
                    .font(theme.body(15))
                    .foregroundColor(theme.onSurfaceSecondaryColor)
            }
        }
    }

    @ViewBuilder
    private var chatButton: some View {
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
            .overlay(alignment: .topTrailing) {
                if unreadChatCount > 0 {
                    Text("\(unreadChatCount)")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .offset(x: -8, y: -8)
                }
            }
        }
    }
}

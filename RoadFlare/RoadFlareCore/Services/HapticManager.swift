import UIKit

/// Centralized haptic feedback for ride lifecycle events.
public enum HapticManager {
    /// Ride accepted by driver — strong impact.
    public static func rideAccepted() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    /// Driver has arrived at pickup — success notification.
    public static func driverArrived() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// PIN verified successfully — light impact.
    public static func pinVerified() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// PIN verification failed — error notification.
    public static func pinFailed() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// Ride completed — success notification.
    public static func rideCompleted() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Ride cancelled — warning notification.
    public static func rideCancelled() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// Chat message received — light impact.
    public static func messageReceived() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Button tap — soft impact.
    public static func buttonTap() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    /// QR code scanned — medium impact.
    public static func qrScanned() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Selection changed — selection feedback.
    public static func selectionChanged() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

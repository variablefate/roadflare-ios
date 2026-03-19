import UIKit

/// Centralized haptic feedback for ride lifecycle events.
enum HapticManager {
    /// Ride accepted by driver — strong impact.
    static func rideAccepted() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    /// Driver has arrived at pickup — success notification.
    static func driverArrived() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// PIN verified successfully — light impact.
    static func pinVerified() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// PIN verification failed — error notification.
    static func pinFailed() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// Ride completed — success notification.
    static func rideCompleted() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Ride cancelled — warning notification.
    static func rideCancelled() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// Chat message received — light impact.
    static func messageReceived() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Button tap — soft impact.
    static func buttonTap() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    /// QR code scanned — medium impact.
    static func qrScanned() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Selection changed — selection feedback.
    static func selectionChanged() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

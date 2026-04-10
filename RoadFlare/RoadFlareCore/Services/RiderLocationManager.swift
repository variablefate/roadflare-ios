import CoreLocation

/// Simple location manager for getting the rider's current GPS position.
/// Used for "Use My Current Location" in the pickup address field.
@Observable
@MainActor
public final class RiderLocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var completion: ((CLLocation) -> Void)?
    private var failure: (() -> Void)?
    public private(set) var permissionDenied = false

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Request a single location fix. Calls completion with the location.
    /// Requests permission if not yet granted. Sets permissionDenied if user denied.
    public func requestLocation(
        completion: @escaping (CLLocation) -> Void,
        onFailure: @escaping () -> Void = {}
    ) {
        self.completion = completion
        self.failure = onFailure
        permissionDenied = false

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            permissionDenied = true
            self.completion = nil
            self.failure?()
            self.failure = nil
        @unknown default:
            self.completion = nil
            self.failure?()
            self.failure = nil
        }
    }

    // MARK: - CLLocationManagerDelegate

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            completion?(location)
            completion = nil
            failure = nil
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            completion = nil
            failure?()
            failure = nil
        }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                if completion != nil {
                    manager.requestLocation()
                }
            case .denied, .restricted:
                permissionDenied = true
                completion = nil
                failure?()
                failure = nil
            default:
                break
            }
        }
    }
}

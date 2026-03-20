import Foundation
import MapKit
import RidestrSDK

/// MapKit-based geocoding and routing service.
@MainActor
final class MapKitServices {
    private let geocoder = CLGeocoder()
    private let searchCompleter = MKLocalSearchCompleter()

    // MARK: - Forward Geocode

    /// Convert an address string to a Location.
    func geocode(address: String) async throws -> Location? {
        let placemarks = try await geocoder.geocodeAddressString(address)
        guard let placemark = placemarks.first,
              let coordinate = placemark.location?.coordinate else { return nil }

        let displayName = [placemark.name, placemark.locality]
            .compactMap { $0 }
            .joined(separator: ", ")

        return Location(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            address: displayName.isEmpty ? address : displayName
        )
    }

    // MARK: - Reverse Geocode

    /// Convert coordinates to an address string.
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> Location {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let placemarks = try await geocoder.reverseGeocodeLocation(location)

        let displayName: String
        if let placemark = placemarks.first {
            displayName = [placemark.name, placemark.locality]
                .compactMap { $0 }
                .joined(separator: ", ")
        } else {
            displayName = "\(latitude), \(longitude)"
        }

        return Location(latitude: latitude, longitude: longitude, address: displayName)
    }

    // MARK: - Route Calculation

    /// Calculate driving route between two locations.
    func calculateRoute(from pickup: Location, to destination: Location) async throws -> RouteResult {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: pickup.latitude, longitude: pickup.longitude)
        ))
        request.destination = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude)
        ))
        request.transportType = .automobile

        let directions = MKDirections(request: request)
        let response = try await directions.calculate()

        guard let route = response.routes.first else {
            throw RidestrError.location(.routeCalculationFailed(underlying: NSError(domain: "MapKit", code: 0, userInfo: [NSLocalizedDescriptionKey: "No routes found"])))
        }

        return RouteResult(
            distanceKm: route.distance / 1000.0,
            durationMinutes: route.expectedTravelTime / 60.0,
            summary: route.name
        )
    }

    // MARK: - Fare Estimate

    /// Calculate fare estimate using MapKit route.
    func estimateFare(
        from pickup: Location,
        to destination: Location,
        calculator: FareCalculator
    ) async throws -> FareEstimate {
        let route = try await calculateRoute(from: pickup, to: destination)
        return calculator.estimate(route: route)
    }
}

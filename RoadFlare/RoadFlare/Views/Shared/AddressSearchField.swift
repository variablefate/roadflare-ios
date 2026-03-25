import SwiftUI
import MapKit
import CoreLocation

/// Address search field with MKLocalSearchCompleter autocomplete.
/// Resolves selected completions via MKLocalSearch for routable coordinates.
/// Optionally shows "Use My Current Location" as the first dropdown item.
struct AddressSearchField: View {
    let placeholder: String
    let icon: String
    let iconColor: Color
    @Binding var text: String
    /// Called with the display text when a suggestion is selected. Coordinates are resolved internally.
    let onSelect: (String) -> Void
    /// Called with resolved coordinates when a suggestion is tapped.
    var onResolvedLocation: ((Double, Double) -> Void)? = nil
    var showCurrentLocation: Bool = false
    var onUseCurrentLocation: (() -> Void)? = nil

    @State private var completer = AddressCompleter()
    @State private var showSuggestions = false
    @State private var isResolving = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle().fill(iconColor).frame(width: 8, height: 8)
                TextField(placeholder, text: $text)
                    .font(RFFont.body())
                    .foregroundColor(Color.rfOnSurface)
                    .focused($isFocused)
                    .onChange(of: text) {
                        completer.search(text)
                        showSuggestions = isFocused
                    }
                    .onChange(of: isFocused) {
                        showSuggestions = isFocused
                    }

                if isResolving {
                    ProgressView().scaleEffect(0.7)
                } else if !text.isEmpty {
                    Button { text = ""; showSuggestions = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color.rfOffline)
                    }
                }
            }
            .padding(14)

            if showSuggestions {
                VStack(spacing: 0) {
                    Rectangle().fill(Color.rfSurfaceContainerHigh).frame(height: 1)

                    // "Use My Current Location" button (pickup field only)
                    if showCurrentLocation, let onUseCurrentLocation {
                        Button {
                            onUseCurrentLocation()
                            showSuggestions = false
                            isFocused = false
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "location.fill")
                                    .foregroundColor(Color.rfPrimary)
                                    .frame(width: 20)
                                Text("Use My Current Location")
                                    .font(RFFont.body(14))
                                    .foregroundColor(Color.rfPrimary)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if !completer.results.isEmpty {
                            Rectangle().fill(Color.rfSurfaceContainerHigh).frame(height: 1)
                        }
                    }

                    // Search suggestions
                    ForEach(completer.results.prefix(4), id: \.self) { result in
                        Button {
                            selectCompletion(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .font(RFFont.body(14))
                                    .foregroundColor(Color.rfOnSurface)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle)
                                        .font(RFFont.caption(12))
                                        .foregroundColor(Color.rfOnSurfaceVariant)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Resolve a search completion to routable coordinates via MKLocalSearch,
    /// then update the text field and notify the caller.
    private func selectCompletion(_ completion: MKLocalSearchCompletion) {
        showSuggestions = false
        isFocused = false
        isResolving = true

        let displayText = [completion.title, completion.subtitle]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        text = displayText

        // Resolve to actual coordinates via MKLocalSearch
        Task {
            let request = MKLocalSearch.Request(completion: completion)
            request.resultTypes = [.address, .pointOfInterest]
            let search = MKLocalSearch(request: request)

            do {
                let response = try await search.start()
                if let mapItem = response.mapItems.first {
                    let coord = mapItem.placemark.coordinate
                    // Use the resolved address if available
                    let resolvedAddress = [
                        mapItem.placemark.subThoroughfare,
                        mapItem.placemark.thoroughfare,
                        mapItem.placemark.locality
                    ].compactMap { $0 }.joined(separator: " ")

                    if !resolvedAddress.isEmpty {
                        text = "\(completion.title), \(resolvedAddress)"
                    }
                    onResolvedLocation?(coord.latitude, coord.longitude)
                }
            } catch {
                // MKLocalSearch failed — fall back to text-based geocoding
            }

            isResolving = false
            onSelect(text)
        }
    }
}

/// MKLocalSearchCompleter wrapper for SwiftUI.
@Observable
class AddressCompleter: NSObject, MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func search(_ query: String) {
        guard query.count >= 2 else {
            results = []
            return
        }
        completer.queryFragment = query
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}

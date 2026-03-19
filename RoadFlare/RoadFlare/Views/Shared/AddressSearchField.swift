import SwiftUI
import MapKit

/// Address search field with MKLocalSearchCompleter autocomplete.
struct AddressSearchField: View {
    let placeholder: String
    let icon: String
    let iconColor: Color
    @Binding var text: String
    let onSelect: (String) -> Void

    @State private var completer = AddressCompleter()
    @State private var showSuggestions = false
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
                        showSuggestions = isFocused && !text.isEmpty
                    }
                    .onChange(of: isFocused) {
                        showSuggestions = isFocused && !text.isEmpty
                    }

                if !text.isEmpty {
                    Button { text = ""; showSuggestions = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color.rfOffline)
                    }
                }
            }
            .padding(14)

            if showSuggestions && !completer.results.isEmpty {
                VStack(spacing: 0) {
                    Rectangle().fill(Color.rfSurfaceContainerHigh).frame(height: 1)
                    ForEach(completer.results.prefix(4), id: \.self) { result in
                        Button {
                            text = [result.title, result.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
                            showSuggestions = false
                            isFocused = false
                            onSelect(text)
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

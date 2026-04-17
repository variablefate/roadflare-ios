import SwiftUI
import MapKit
import RidestrSDK
import RoadFlareCore

/// Settings screen for managing saved locations (favorites + recents).
struct SavedLocationsView: View {
    @Environment(AppState.self) private var appState
    @State private var showAddFavorite = false
    @State private var editingLocation: SavedLocationRow?

    var body: some View {
        // Capture each row list once per body invocation — SwiftUI calls
        // body frequently, and reading these twice (empty-check + ForEach)
        // each time would double the `SavedLocationsRepository.favorites`
        // and `.recents` compute (and for recents, the proximity-filter
        // pass against favorites).
        let favorites = appState.favoriteLocationRows
        let recents = appState.recentLocationRows
        return ZStack {
            Color.rfSurface.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    // Favorites
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Favorites")

                        if favorites.isEmpty {
                            HStack {
                                Image(systemName: "star")
                                    .foregroundColor(Color.rfOnSurfaceVariant)
                                Text("Add your home, work, or frequent destinations.")
                                    .font(RFFont.caption(13))
                                    .foregroundColor(Color.rfOnSurfaceVariant)
                            }
                            .rfCard(.low)
                        } else {
                            ForEach(favorites) { row in
                                Button { editingLocation = row } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: row.iconSystemName)
                                            .foregroundColor(Color.rfPrimary)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(row.label)
                                                .font(RFFont.title(15))
                                                .foregroundColor(Color.rfOnSurface)
                                            Text(row.addressLine)
                                                .font(RFFont.caption(12))
                                                .foregroundColor(Color.rfOnSurfaceVariant)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundColor(Color.rfOffline)
                                    }
                                    .rfCard()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Recents
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Recent Locations")

                        if recents.isEmpty {
                            HStack {
                                Image(systemName: "clock")
                                    .foregroundColor(Color.rfOnSurfaceVariant)
                                Text("Recent locations appear here after rides.")
                                    .font(RFFont.caption(13))
                                    .foregroundColor(Color.rfOnSurfaceVariant)
                            }
                            .rfCard(.low)
                        } else {
                            ForEach(recents) { row in
                                SwipeToDeleteRow {
                                    editingLocation = row
                                } onDelete: {
                                    withAnimation { appState.removeLocation(id: row.id) }
                                } content: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "clock")
                                            .foregroundColor(Color.rfOffline)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(row.displayName)
                                                .font(RFFont.body(14))
                                                .foregroundColor(Color.rfOnSurface)
                                            Text(row.addressLine)
                                                .font(RFFont.caption(12))
                                                .foregroundColor(Color.rfOnSurfaceVariant)
                                                .lineLimit(1)
                                        }
                                        Spacer()

                                        Button { editingLocation = row } label: {
                                            Image(systemName: "star")
                                                .foregroundColor(Color.rfOffline)
                                                .frame(width: 36, height: 36)
                                                .contentShape(Rectangle())
                                        }
                                    }
                                    .rfCard(.low)
                                }
                            }
                        }
                    }

                    if !appState.allSavedLocations.isEmpty {
                        Button("Clear All Locations") {
                            Task { await appState.clearAllLocations() }
                        }
                        .buttonStyle(RFGhostButtonStyle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Saved Locations")
        .toolbarBackground(Color.rfSurface, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddFavorite = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(Color.rfPrimary)
                }
            }
        }
        .sheet(isPresented: $showAddFavorite) {
            AddFavoriteSheet()
        }
        .sheet(item: $editingLocation) { row in
            EditLocationSheet(location: row)
        }
    }
}

// MARK: - Add Favorite Sheet

struct AddFavoriteSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var completer = AddressCompleter()
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.rfSurface.ignoresSafeArea()

                VStack(spacing: 16) {
                    // Search field
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(Color.rfOnSurfaceVariant)
                        TextField("Search for an address or place", text: $searchText)
                            .font(RFFont.body())
                            .foregroundColor(Color.rfOnSurface)
                            .onChange(of: searchText) { completer.search(searchText) }
                    }
                    .padding(14)
                    .background(Color.rfSurfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)

                    if isSearching {
                        ProgressView().tint(Color.rfPrimary)
                    }

                    // Results
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(completer.results.prefix(8), id: \.self) { result in
                                Button {
                                    resolveAndSave(result)
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
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Spacer()
                }
                .padding(.top, 8)
            }
            .navigationTitle("Add Favorite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.rfSurface, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Color.rfOnSurfaceVariant)
                }
            }
        }
    }

    private func resolveAndSave(_ completion: MKLocalSearchCompletion) {
        isSearching = true
        Task {
            let request = MKLocalSearch.Request(completion: completion)
            do {
                let response = try await MKLocalSearch(request: request).start()
                if let item = response.mapItems.first {
                    let coord = item.placemark.coordinate
                    let address = [item.placemark.subThoroughfare, item.placemark.thoroughfare, item.placemark.locality]
                        .compactMap { $0 }.joined(separator: " ")

                    let loc = SavedLocation(
                        id: UUID().uuidString,
                        latitude: coord.latitude, longitude: coord.longitude,
                        displayName: completion.title,
                        addressLine: address.isEmpty ? completion.subtitle : address,
                        isPinned: true, nickname: completion.title,
                        timestampMs: Int(Date.now.timeIntervalSince1970 * 1000)
                    )
                    appState.saveLocation(loc)
                    await appState.publishProfileBackup()
                }
            } catch {
                // Non-fatal
            }
            isSearching = false
            dismiss()
        }
    }
}

// MARK: - Edit Location Sheet

struct EditLocationSheet: View {
    let location: SavedLocationRow
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var nickname: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.rfSurface.ignoresSafeArea()

                VStack(spacing: 24) {
                    Spacer().frame(height: 8)

                    VStack(spacing: 4) {
                        Text(location.displayName)
                            .font(RFFont.headline(18))
                            .foregroundColor(Color.rfOnSurface)
                        Text(location.addressLine)
                            .font(RFFont.caption(13))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Label")
                            .font(RFFont.caption())
                            .foregroundColor(Color.rfOnSurfaceVariant)
                        TextField("e.g., Home, Work, Gym", text: $nickname)
                            .font(RFFont.body())
                            .padding(14)
                            .background(Color.rfSurfaceContainerLow)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .foregroundColor(Color.rfOnSurface)
                    }
                    .padding(.horizontal, 24)

                    HStack(spacing: 12) {
                        QuickLabelButton(icon: "house.fill", label: "Home") {
                            nickname = "Home"
                        }
                        QuickLabelButton(icon: "briefcase.fill", label: "Work") {
                            nickname = "Work"
                        }
                    }
                    .padding(.horizontal, 24)

                    Spacer()

                    if !location.isFavorite {
                        Button {
                            appState.pinLocation(id: location.id, nickname: nickname.isEmpty ? location.displayName : nickname)
                            Task { await appState.publishProfileBackup() }
                            dismiss()
                        } label: {
                            Label("Save as Favorite", systemImage: "star.fill")
                        }
                        .buttonStyle(RFPrimaryButtonStyle())
                        .padding(.horizontal, 24)
                    } else {
                        Button {
                            if !nickname.isEmpty {
                                appState.pinLocation(id: location.id, nickname: nickname)
                            }
                            Task { await appState.publishProfileBackup() }
                            dismiss()
                        } label: {
                            Text("Save")
                        }
                        .buttonStyle(RFPrimaryButtonStyle(isDisabled: nickname.isEmpty))
                        .disabled(nickname.isEmpty)
                        .padding(.horizontal, 24)
                    }

                    Button(role: .destructive) {
                        appState.removeLocation(id: location.id)
                        Task { await appState.publishProfileBackup() }
                        dismiss()
                    } label: {
                        Text(location.isFavorite ? "Remove Favorite" : "Remove")
                            .font(RFFont.body(15))
                            .foregroundColor(Color.rfError)
                    }

                    Spacer().frame(height: 16)
                }
            }
            .navigationTitle(location.isFavorite ? "Edit Favorite" : "Save Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.rfSurface, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Color.rfOnSurfaceVariant)
                }
            }
            .onAppear {
                nickname = location.label
            }
        }
    }
}

struct QuickLabelButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(label)
                    .font(RFFont.title(14))
            }
            .foregroundColor(Color.rfPrimary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.rfPrimary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI
import MapKit
import RidestrSDK

/// Settings screen for managing saved locations (favorites + recents).
struct SavedLocationsView: View {
    @Environment(AppState.self) private var appState
    @State private var showAddFavorite = false
    @State private var editingLocation: SavedLocation?

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    // Favorites
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Favorites")

                        if appState.savedLocations.favorites.isEmpty {
                            HStack {
                                Image(systemName: "star")
                                    .foregroundColor(Color.rfOnSurfaceVariant)
                                Text("Add your home, work, or frequent destinations.")
                                    .font(RFFont.caption(13))
                                    .foregroundColor(Color.rfOnSurfaceVariant)
                            }
                            .rfCard(.low)
                        } else {
                            ForEach(appState.savedLocations.favorites) { loc in
                                Button { editingLocation = loc } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: iconForNickname(loc.nickname))
                                            .foregroundColor(Color.rfPrimary)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(loc.nickname ?? loc.displayName)
                                                .font(RFFont.title(15))
                                                .foregroundColor(Color.rfOnSurface)
                                            Text(loc.addressLine)
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

                        if appState.savedLocations.recents.isEmpty {
                            HStack {
                                Image(systemName: "clock")
                                    .foregroundColor(Color.rfOnSurfaceVariant)
                                Text("Recent locations appear here after rides.")
                                    .font(RFFont.caption(13))
                                    .foregroundColor(Color.rfOnSurfaceVariant)
                            }
                            .rfCard(.low)
                        } else {
                            ForEach(appState.savedLocations.recents) { loc in
                                HStack(spacing: 12) {
                                    Image(systemName: "clock")
                                        .foregroundColor(Color.rfOffline)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(loc.displayName)
                                            .font(RFFont.body(14))
                                            .foregroundColor(Color.rfOnSurface)
                                        Text(loc.addressLine)
                                            .font(RFFont.caption(12))
                                            .foregroundColor(Color.rfOnSurfaceVariant)
                                            .lineLimit(1)
                                    }
                                    Spacer()

                                    // Save as favorite
                                    Button { editingLocation = loc } label: {
                                        Image(systemName: "star")
                                            .foregroundColor(Color.rfOffline)
                                            .frame(width: 36, height: 36)
                                            .contentShape(Rectangle())
                                    }

                                    // Delete
                                    Button {
                                        withAnimation {
                                            appState.savedLocations.remove(id: loc.id)
                                        }
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 12))
                                            .foregroundColor(Color.rfOffline)
                                            .frame(width: 36, height: 36)
                                            .contentShape(Rectangle())
                                    }
                                }
                                .rfCard(.low)
                            }
                        }
                    }

                    if !appState.savedLocations.locations.isEmpty {
                        Button("Clear All Locations") {
                            appState.savedLocations.clearAll()
                            Task { await appState.publishProfileBackup() }
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
        .sheet(item: $editingLocation) { loc in
            EditLocationSheet(location: loc)
        }
    }

    private func iconForNickname(_ nickname: String?) -> String {
        switch nickname?.lowercased() {
        case "home": return "house.fill"
        case "work": return "briefcase.fill"
        default: return "star.fill"
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
                    appState.savedLocations.save(loc)
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
    let location: SavedLocation
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var nickname: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.rfSurface.ignoresSafeArea()

                VStack(spacing: 24) {
                    Spacer().frame(height: 8)

                    // Address display
                    VStack(spacing: 4) {
                        Text(location.displayName)
                            .font(RFFont.headline(18))
                            .foregroundColor(Color.rfOnSurface)
                        Text(location.addressLine)
                            .font(RFFont.caption(13))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                    }

                    // Nickname field
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

                    // Quick label buttons
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

                    // Save as favorite
                    if !location.isPinned {
                        Button {
                            appState.savedLocations.pin(id: location.id, nickname: nickname.isEmpty ? location.displayName : nickname)
                            Task { await appState.publishProfileBackup() }
                            dismiss()
                        } label: {
                            Label("Save as Favorite", systemImage: "star.fill")
                        }
                        .buttonStyle(RFPrimaryButtonStyle())
                        .padding(.horizontal, 24)
                    } else {
                        // Update nickname
                        Button {
                            if !nickname.isEmpty {
                                appState.savedLocations.pin(id: location.id, nickname: nickname)
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

                    // Delete
                    Button(role: .destructive) {
                        appState.savedLocations.remove(id: location.id)
                        Task { await appState.publishProfileBackup() }
                        dismiss()
                    } label: {
                        Text(location.isPinned ? "Remove Favorite" : "Remove")
                            .font(RFFont.body(15))
                            .foregroundColor(Color.rfError)
                    }

                    Spacer().frame(height: 16)
                }
            }
            .navigationTitle(location.isPinned ? "Edit Favorite" : "Save Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.rfSurface, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Color.rfOnSurfaceVariant)
                }
            }
            .onAppear {
                nickname = location.nickname ?? location.displayName
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

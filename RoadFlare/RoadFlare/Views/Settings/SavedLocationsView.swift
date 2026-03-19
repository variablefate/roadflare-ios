import SwiftUI
import RidestrSDK

/// Settings screen for managing saved locations.
struct SavedLocationsView: View {
    @Environment(AppState.self) private var appState
    @State private var showAddFavorite = false
    @State private var newFavoriteName = ""
    @State private var newFavoriteAddress = ""

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
                                Text("No favorites yet. Pin a location to add it here.")
                                    .font(RFFont.caption(13))
                                    .foregroundColor(Color.rfOnSurfaceVariant)
                            }
                            .rfCard(.low)
                        } else {
                            ForEach(appState.savedLocations.favorites) { loc in
                                HStack(spacing: 12) {
                                    FlareIndicator(color: .rfTertiary)
                                        .frame(height: 36)
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
                                    Button {
                                        appState.savedLocations.unpin(id: loc.id)
                                    } label: {
                                        Image(systemName: "star.fill")
                                            .foregroundColor(Color.rfTertiary)
                                    }
                                }
                                .rfCard()
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
                                Text("Recent locations will appear here after rides.")
                                    .font(RFFont.caption(13))
                                    .foregroundColor(Color.rfOnSurfaceVariant)
                            }
                            .rfCard(.low)
                        } else {
                            ForEach(appState.savedLocations.recents) { loc in
                                HStack(spacing: 12) {
                                    Image(systemName: "clock")
                                        .foregroundColor(Color.rfOffline)
                                        .frame(width: 20)
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
                                    Button {
                                        appState.savedLocations.pin(id: loc.id, nickname: loc.displayName)
                                    } label: {
                                        Image(systemName: "star")
                                            .foregroundColor(Color.rfOffline)
                                    }
                                }
                                .rfCard(.low)
                            }
                        }
                    }

                    if !appState.savedLocations.locations.isEmpty {
                        Button("Clear All Locations") {
                            appState.savedLocations.clearAll()
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
    }
}

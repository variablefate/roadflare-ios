import SwiftUI
import UIKit

/// An image view that loads from URL with URLCache-first strategy.
/// Unlike AsyncImage, this checks the cache synchronously first to avoid flicker.
struct CachedAsyncImage: View {
    let url: URL?
    let size: CGFloat

    @State private var image: UIImage?
    @State private var hasLoaded = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if !hasLoaded {
                // Only show placeholder before first load attempt
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            guard let url, image == nil else { return }
            await loadImage(from: url)
        }
    }

    private func loadImage(from url: URL) async {
        let request = URLRequest(url: url)

        // Check cache first (synchronous, no flicker)
        if let cached = URLCache.shared.cachedResponse(for: request),
           let uiImage = UIImage(data: cached.data) {
            image = uiImage
            hasLoaded = true
            return
        }

        // Not cached — fetch from network
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let uiImage = UIImage(data: data) {
                // Store in cache for next time
                let cachedResponse = CachedURLResponse(response: response, data: data)
                URLCache.shared.storeCachedResponse(cachedResponse, for: request)
                image = uiImage
            }
        } catch {
            // Non-fatal
        }
        hasLoaded = true
    }
}

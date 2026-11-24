// HAo Studio 2.0 — Emby poster image (S5-B leg).
//
// Emby poster URLs carry NO api_key — auth rides the request
// header (EmbyClient.imageUrl), so plain AsyncImage can never
// load them (it would 401 and show the placeholder). This view
// loads through EmbyImageLoader (A leg), which attaches the
// credential, and shows a themed placeholder tile while loading
// or on failure — never a broken image.
//
// Call shape mirrors MusicCoverView (urlString + size +
// cornerRadius). `size` is optional: pass it for a square
// cover; leave it out and the image fills the space the caller
// sizes (the poster card's 2:3 frame).

import SwiftUI
import UIKit

struct EmbyPosterImage: View {
    var urlString: String
    var size: CGFloat?
    var cornerRadius: CGFloat = 8

    @Environment(\.haoTheme) private var theme
    @State private var image: UIImage?
    /// The URL the in-flight load was started for. Poster cells
    /// are reused while scrolling: an older load that lands after
    /// the cell moved to another poster must not overwrite the
    /// new one (b35 sweep — the old code assigned whatever load
    /// finished last).
    @State private var loadingURL: String?

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(
            width: size,
            height: size
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onAppear {
            loadImage()
        }
        .onChange(of: urlString) { _, _ in
            loadImage()
        }
    }

    private func loadImage() {
        guard !urlString.isEmpty else {
            image = nil
            loadingURL = nil
            return
        }
        let requested = urlString
        loadingURL = requested
        EmbyImageLoader.shared.load(urlString: urlString) { loaded in
            guard loadingURL == requested else { return }
            image = loaded
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(theme.surfaceStrong)
            .overlay {
                Image(systemName: "film")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(theme.textSecondary)
            }
    }
}

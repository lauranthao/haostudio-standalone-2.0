// HAo Studio 2.0 — video poster card (S3-C leg).
//
// Infuse copy (Flutter video_poster_card.dart):
// - 2:3 portrait poster, radius 16 (b42 polish, was 12).
// - Title 13px/600 below, one muted 12px meta line (`year · type`).
// - NO rating badge on the poster (rating lives on the detail page
//   only, as in Infuse). No coloured corner badge.
// - Missing artwork = a themed placeholder tile (film glyph on
//   glass), never a grey block.
// - Watched state = a small white check in a dark circle top-left
//   (lookup is prebuilt once per render by the caller via
//   isWatched).
// - Remarks (e.g. 更新至 12 集) ride as a subtle dark pill on the
//   poster bottom when the source gives one; the seam VideoItem
//   carries no episode total, so there is no count badge.
//
// Poster fetches use the shared image loader (HaoCachedImage,
// build 36 item 10 leg 6 — downsampled to 120x180, cached).
// Some CMS posters 403 without a Referer header — those show the
// placeholder tile. A referer-capable loader is a B-leg follow-up,
// not a reason to fake artwork here.

import SwiftUI

/// One poster cell: 2:3 artwork + title + `year · type` meta line.
/// `isEmby` routes the artwork through EmbyPosterImage (token in
/// the request header); CMS posters go through the shared image
/// loader (HaoCachedImage).
/// The card also self-detects (an item with no CMS source id is
/// Emby), so mixed grids — favourites, CMS search's Emby section
/// — cannot forget the flag and show placeholder tiles.
struct VideoPosterCard: View {
    var item: VideoItem
    var isWatched: Bool = false
    var isEmby: Bool = false
    var onTap: () -> Void

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            // b42 polish (VidHub / Streamyfin rhythm): tighter
            // title/meta stack (8 -> 6) so the card reads as one
            // unit, and the meta line in textSecondary instead of
            // textMuted — on a photo-backed page the muted grey
            // washed out, the secondary still reads quiet.
            VStack(alignment: .leading, spacing: 6) {
                posterImage
                    .overlay(alignment: .topLeading) {
                        if isWatched {
                            Image(systemName: "checkmark")
                                .font(.haoBadge)
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Color.black.opacity(0.6), in: Circle())
                                .padding(6)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let remarks = item.remarks, !remarks.isEmpty {
                            Text(remarks)
                                .font(.haoBadge)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .haoDarkGlassCapsule(darkness: 0.6)
                                .padding(6)
                        }
                    }
                Text(item.title)
                    .font(.haoSubheadStrong)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(metaLine)
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(MusicPressScaleStyle())
        .contextMenu {
            Button(VideoLibraryStore.isFavourite(item: item) ? "取消收藏" : "收藏") {
                _ = VideoLibraryStore.toggleFavourite(item: item)
            }
        }
    }

    private var metaLine: String {
        let year = item.year ?? ""
        let type = item.typeName ?? ""
        switch (year.isEmpty, type.isEmpty) {
        case (false, false): return "\(year) · \(type)"
        case (false, true): return year
        case (true, false): return type
        case (true, true): return "影视"
        }
    }

    private var posterImage: some View {
        Group {
            if isEmby || item.detailSource == .emby {
                EmbyPosterImage(urlString: item.coverURL?.absoluteString ?? "")
            } else if let url = item.coverURL {
                // Shared loader (build 36 item 10 leg 6): the card
                // is ~110pt wide in the 3-column grid, so 120x180
                // covers it at any phone width — the old AsyncImage
                // downloaded and decoded the full original. No
                // Referer is sent here, same as before (B5 / video
                // O1 is a separate leg).
                HaoCachedImage(
                    urlString: url.absoluteString,
                    targetWidth: 120,
                    targetHeight: 180
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        // b42 polish: radius 12 -> 16 — the poster is the card's
        // whole visual, and 16 reads softer and more premium next
        // to the 18pt library cards and the 14pt continue cards,
        // instead of the sharper 12 that matched nothing else.
        .clipShape(RoundedRectangle(cornerRadius: HaoLayout.cornerLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: HaoLayout.cornerLarge, style: .continuous)
                .strokeBorder(theme.hairline, lineWidth: 0.5)
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: HaoLayout.cornerLarge, style: .continuous)
            .fill(theme.surfaceStrong)
            .overlay {
                Image(systemName: "film")
                    // .title is 28pt regular: pixel-identical to the
                    // old literal, same fix as D7 (EmbyPosterImage)
                    // and MusicEmptyState.
                    .font(.title)
                    .foregroundStyle(theme.textSecondary)
            }
    }
}

/// A poster grid with the card's own metrics (never a hardcoded
/// child aspect ratio elsewhere). The column count follows the
/// container width (sweep-4 B13): 3 on phones, 4 on mid widths,
/// 5 on wide iPad landscape — so iPad cards stay near phone size
/// instead of stretching to ~500pt. `isEmby` forwards to every
/// card (Emby token header loading).
/// `watchedKeys` defaults to the store's watched set, so every
/// grid shows the same "already watched" checkmark the home rows
/// show (callers with a live list pass their own set instead).
/// The default is cheap: the set lives in memory in
/// VideoLibraryStore (build 36, item 10) — constructing a grid
/// no longer reads the history file.
struct VideoPosterGrid: View {
    var items: [VideoItem]
    var watchedKeys: Set<String> = VideoLibraryStore.watchedKeys()
    var isEmby: Bool = false
    var onTap: (VideoItem) -> Void

    /// Width of the grid's container, measured on layout (0 until
    /// the first pass — 3 columns, the phone layout). The grid's
    /// width is set by its parent, never by the column count, so
    /// writing it back cannot loop.
    @State private var containerWidth: CGFloat = 0

    private var columns: [GridItem] {
        let count: Int
        if containerWidth >= 900 { count = 5 }
        else if containerWidth >= 600 { count = 4 }
        else { count = 3 }
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(items) { item in
                VideoPosterCard(
                    item: item,
                    isWatched: watchedKeys.contains(
                        VideoResumeKey.key(title: item.title, year: item.year)),
                    isEmby: isEmby,
                    onTap: { onTap(item) }
                )
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { containerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in
                        containerWidth = width
                    }
            }
        )
    }
}

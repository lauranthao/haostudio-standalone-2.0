// HAo Studio 2.0 — live room card (S4-C leg).
//
// One room card, shared by the tab grid, search results, the
// follows page and the history page (Flutter _RoomCard):
// 16:9 cover, LIVE badge (theme liveRed — the only red in the
// app) when the room is live, title, anchor nick, watching
// count. No cover URL means the themed placeholder, never a fake
// image. Tapping is the caller's job (the card itself holds no
// navigation) so the same card works in every list.

import Foundation
import SwiftUI

/// A room card for a grid (tab / search). Fixed 16:9 cover.
struct LiveRoomCard: View {
    var room: LiveRoom
    var onTap: () -> Void

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                coverView
                Text(room.title.isEmpty ? "直播间" : room.title)
                    .font(.haoDenseTitle)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                // Anchor + watching on ONE row (Pure Live card):
                // the anchor truncates, the flame + count is a
                // fixed trailing group after a Spacer, so a long
                // anchor name can only truncate — never squeeze
                // or overlap the count. (Build 33 squeezed both
                // into one HStack with no truncation priority;
                // the 2026-11-24 fix split them onto two lines.
                // This keeps that guarantee in one row: the
                // count group has a fixed size and the anchor is
                // lineLimit 1, so the two can never collide.)
                HStack(spacing: 4) {
                    Text(room.streamer.isEmpty ? room.platform.displayName : room.streamer)
                        .font(.haoCaption)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if !liveWatchingText(room.onlineCount).isEmpty {
                        Image(systemName: "flame.fill")
                            .font(.haoCaption2)
                            .foregroundStyle(theme.textMuted)
                        Text(liveWatchingText(room.onlineCount))
                            .font(.haoCaption)
                            .foregroundStyle(theme.textMuted)
                            .lineLimit(1)
                    }
                }
            }
            // Bound the label to the grid cell: the VStack must
            // never report wider than the cell, or the card
            // draws past the cell (and past the screen edge on
            // the right column). Truncation above handles long
            // text inside that bound.
            .frame(maxWidth: .infinity, alignment: .leading)
        }        .buttonStyle(MusicPressScaleStyle())
        .contextMenu {
            Button(LiveLibraryStore.isFollowed(platform: room.platform.rawValue, roomId: room.roomId) ? "取消关注" : "关注") {
                _ = LiveLibraryStore.toggleFollow(
                    platform: room.platform.rawValue, roomId: room.roomId,
                    title: room.title, nick: room.streamer, cover: room.cover,
                    playUrlsJSON: LiveLibraryStore.playUrlsJSON(from: room.data))
            }
        }
    }

    private var coverView: some View {
        ZStack(alignment: .topLeading) {
            // .fit, not .fill (fix 2026-11-24, build 35): in a
            // LazyVGrid row the height proposal is unbounded, so
            // .fill lets the downloaded image's intrinsic size
            // drive the cell — a portrait cover drew at portrait
            // proportions, several times the 16:9 height,
            // overlapping the rows below it and burying the
            // titles. .fit derives the height from the
            // grid-proposed width (cell / 16:9,
            // LiveGridLayout.coverHeight), the same pattern
            // VideoPosterCard uses in its grid; the inner
            // scaledToFill image is cropped to that box by
            // .clipped() below. The follow/history cards keep
            // .fill — they pin an explicit .frame(width: 140).
            coverImage
                .aspectRatio(CGFloat(LiveGridLayout.coverAspectRatio), contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if room.isLive {
                // O-D3: async confirmation flips isLive false ->
                // true; the badge fades in (0.2s ease-out) instead
                // of popping. Removal stays instant (.identity):
                // disappearance behaviour is unchanged.
                Text("LIVE")
                    .font(.haoBadge)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(theme.liveRed, in: Capsule())
                    .padding(6)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: room.isLive)
    }

    @ViewBuilder
    private var coverImage: some View {
        if let url = liveCoverURL(for: room) {
            // Shared loader (build 36 item 10 leg 6): 2-column
            // grid cell is ~173pt wide on a 390pt phone, so
            // 180x101 covers it — the old AsyncImage decoded the
            // full platform original.
            HaoCachedImage(
                urlString: url.absoluteString,
                targetWidth: 180,
                targetHeight: 101
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                coverPlaceholder
            }
        } else {
            coverPlaceholder
        }
    }

    private var coverPlaceholder: some View {
        Rectangle()
            .fill(theme.surfaceStrong)
            .overlay {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 20))
                    .foregroundStyle(theme.textSecondary)
            }
    }
}

/// A room row for a list (follows / history): small cover thumb
/// + title + anchor + watching, chevron on the right.
struct LiveRoomRow: View {
    var room: LiveRoom
    var onTap: () -> Void

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                rowCover
                VStack(alignment: .leading, spacing: 4) {
                    Text(room.title.isEmpty ? "直播间" : room.title)
                        .font(.haoSubheadStrong)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if room.isLive {
                            // O-D3: fade in on async confirmation
                            // (0.2s ease-out); removal stays instant.
                            Text("LIVE")
                                .font(.haoBadge)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(theme.liveRed, in: Capsule())
                                .transition(.asymmetric(insertion: .opacity, removal: .identity))
                        }
                        Text(room.streamer.isEmpty ? room.platform.displayName : room.streamer)
                            .font(.haoFootnote)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                    .animation(.easeOut(duration: 0.2), value: room.isLive)
                    if !liveWatchingText(room.onlineCount).isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "flame.fill")
                                .font(.haoCaption2)
                                .foregroundStyle(theme.textMuted)
                            Text(liveWatchingText(room.onlineCount))
                                .font(.haoCaption)
                                .foregroundStyle(theme.textMuted)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.haoFootnoteStrong)
                    .foregroundStyle(theme.textMuted)
            }
            .contentShape(Rectangle())
        }        .buttonStyle(MusicPressScaleStyle())
        .contextMenu {
            Button(LiveLibraryStore.isFollowed(platform: room.platform.rawValue, roomId: room.roomId) ? "取消关注" : "关注") {
                _ = LiveLibraryStore.toggleFollow(
                    platform: room.platform.rawValue, roomId: room.roomId,
                    title: room.title, nick: room.streamer, cover: room.cover,
                    playUrlsJSON: LiveLibraryStore.playUrlsJSON(from: room.data))
            }
        }
    }

    private var rowCover: some View {
        Group {
            if let url = liveCoverURL(for: room) {
                // Shared loader (build 36 item 10 leg 6): 96x54
                // row thumb — the old AsyncImage decoded the full
                // original for a 96pt thumb.
                HaoCachedImage(
                    urlString: url.absoluteString,
                    targetWidth: 96,
                    targetHeight: 54
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    rowCoverPlaceholder
                }
            } else {
                rowCoverPlaceholder
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: HaoLayout.cornerSmall, style: .continuous))
    }

    private var rowCoverPlaceholder: some View {
        Rectangle()
            .fill(theme.surfaceStrong)
            .overlay {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.haoCallout)
                    .foregroundStyle(theme.textSecondary)
            }
    }
}

/// Relative time for a history row ("刚刚" / "5 分钟前" / "3 小时前" /
/// "昨天" / "3 天前" / date). Pure function of the two dates.
func liveRelativeTimeText(date: Date, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 {
        return "刚刚"
    }
    if seconds < 3600 {
        return "\(Int(seconds / 60)) 分钟前"
    }
    if seconds < 86400 {
        return "\(Int(seconds / 3600)) 小时前"
    }
    let days = Int(seconds / 86400)
    if days == 1 {
        return "昨天"
    }
    if days < 7 {
        return "\(days) 天前"
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

// MARK: - Shared grid definition (fix 2026-11-24)

/// The SwiftUI half of LiveGridLayout (AppCore, Double math):
/// the two flexible columns, row spacing and page margin every
/// live room grid uses — tab recommend, search results, home
/// hot-live. One definition, so the three grids cannot drift
/// apart again. `flexible(minimum: 0)` means a column never
/// demands more than its share of the container width; the card
/// itself is width-bounded and truncates, so nothing can draw
/// past the cell — or past the screen edge on the right column.
extension LiveGridLayout {
    static var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: CGFloat(interItemSpacing)),
            count: columns
        )
    }

    /// Adaptive columns for a grid inside a container of the
    /// given width (b49fix2 B13): phones stay at 2, a landscape
    /// phone / portrait iPad gets 3, a wide container 4 — the
    /// fixed 2-column grid left an iPad grid using a third of
    /// the width. Same AppCore math as HomeView's
    /// homeLiveGridColumns; the GridItem array lives here
    /// because LiveDataGateway is Foundation-only (AppCore)
    /// and cannot build SwiftUI items.
    static func gridColumns(forWidth width: CGFloat) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: CGFloat(interItemSpacing)),
            count: columns(forWidth: Double(width))
        )
    }

    /// Row spacing between grid rows, in points.
    static var gridRowSpacing: CGFloat { CGFloat(rowSpacing) }

    /// Horizontal page margin the grids sit inside, in points.
    static var gridEdgePadding: CGFloat { CGFloat(edgePadding) }
}

/// Reports a live grid container's laid-out width up the tree
/// (sweep-5 P2-12): UIScreen.main.bounds.width is stale in
/// Split View / Stage Manager, so the tab recommend grid and
/// the search results grid read their real container width
/// instead (same pattern as HomeView's HomeLiveGridWidthKey).
/// One key for both grids — a container reports one width.
struct LiveGridWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

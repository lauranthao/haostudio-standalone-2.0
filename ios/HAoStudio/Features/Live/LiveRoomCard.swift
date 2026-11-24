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
            VStack(alignment: .leading, spacing: 6) {
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
        }
        .buttonStyle(.plain)
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
                Text("LIVE")
                    .font(.haoBadge)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(theme.liveRed, in: Capsule())
                    .padding(6)
            }
        }
    }

    @ViewBuilder
    private var coverImage: some View {
        if let url = liveCoverURL(for: room) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure, .empty:
                    coverPlaceholder
                @unknown default:
                    coverPlaceholder
                }
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
                            Text("LIVE")
                                .font(.haoBadge)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(theme.liveRed, in: Capsule())
                        }
                        Text(room.streamer.isEmpty ? room.platform.displayName : room.streamer)
                            .font(.haoFootnote)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
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
        }
        .buttonStyle(.plain)
    }

    private var rowCover: some View {
        Group {
            if let url = liveCoverURL(for: room) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure, .empty:
                        rowCoverPlaceholder
                    @unknown default:
                        rowCoverPlaceholder
                    }
                }
            } else {
                rowCoverPlaceholder
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

    /// Row spacing between grid rows, in points.
    static var gridRowSpacing: CGFloat { CGFloat(rowSpacing) }

    /// Horizontal page margin the grids sit inside, in points.
    static var gridEdgePadding: CGFloat { CGFloat(edgePadding) }
}

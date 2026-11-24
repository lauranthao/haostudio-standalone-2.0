// HAo Studio 2.0 — live room card (S4-C leg).
//
// One room card, shared by the tab grid, search results, the
// follows page and the history page (Flutter _RoomCard):
// 16:10 cover, LIVE badge (theme liveRed — the only red in the
// app) when the room is live, title, anchor nick, watching
// count. No cover URL means the themed placeholder, never a fake
// image. Tapping is the caller's job (the card itself holds no
// navigation) so the same card works in every list.

import Foundation
import SwiftUI

/// A room card for a grid (tab / search). Fixed 16:10 cover.
struct LiveRoomCard: View {
    var room: LiveRoom
    var onTap: () -> Void

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                coverView
                Text(room.title.isEmpty ? "直播间" : room.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                // Anchor and watching on SEPARATE lines (fix
                // 2026-11-24): build 33 squeezed both into one
                // HStack, so a long anchor name squeezed the
                // count and the two read as overlapping. One
                // line each can only truncate, never overlap.
                Text(room.streamer.isEmpty ? room.platform.displayName : room.streamer)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                // Always rendered, blank when the count is 0:
                // every card keeps the same three text lines, so
                // all cards in a grid row stay the same height.
                Text(watchingLine)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
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

    /// Watching line: "12.3万 人在看" (same wording as the list
    /// row), blank when the platform gave no count.
    private var watchingLine: String {
        let text = liveWatchingText(room.onlineCount)
        guard !text.isEmpty else { return " " }
        return "\(text) 人在看"
    }

    private var coverView: some View {
        ZStack(alignment: .topLeading) {
            coverImage
                .aspectRatio(CGFloat(LiveGridLayout.coverAspectRatio), contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if room.isLive {
                Text("LIVE")
                    .font(.system(size: 10, weight: .bold))
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
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if room.isLive {
                            Text("LIVE")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(theme.liveRed, in: Capsule())
                        }
                        Text(room.streamer.isEmpty ? room.platform.displayName : room.streamer)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                    if !liveWatchingText(room.onlineCount).isEmpty {
                        Text("\(liveWatchingText(room.onlineCount)) 人在看")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
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
        .frame(width: 96, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var rowCoverPlaceholder: some View {
        Rectangle()
            .fill(theme.surfaceStrong)
            .overlay {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 16))
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

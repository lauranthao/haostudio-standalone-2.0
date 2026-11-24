// HAo Studio 2.0 — live data gateway (S4-C leg).
//
// The ONE seam between the live UI (this leg) and the live
// services (B leg: the five platform site clients + danmaku
// transports) and the player core (A leg: LiveDriver).
//
// Why a protocol instead of calling the B-leg clients directly:
// the three S4 legs are built in parallel clones from the same
// seam commit, so the B-leg types do not exist in this clone yet.
// The UI below talks ONLY to this protocol (seam models only:
// LiveRoom). The B leg (or the merge coordinator) provides the
// adapter that maps these methods onto the site clients — no UI
// file changes are needed at merge.
//
// The gateway is OPTIONAL on the tab/search view models (nil =
// no source wired yet): the tab then shows the local rows
// (follows + history, real data) and an honest empty state for
// the recommend section — never fake rooms, never a dead button.
//
// Method shapes mirror the Flutter side:
// - LiveTabController: recommend rooms per platform + area
//   categories, pull to refresh, paged "load more".
// - LiveSearchPage: per-platform room search, keywords only in
//   history.
// - LiveRoomPage entry records history (L01) before opening.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.
// All completions fire on the main queue.

import Foundation

/// One live platform — B leg's `LivePlatform` enum
/// (`Services/LiveSites/LiveModels.swift`, canonical): raw values
/// are the player-kernel ids (`bili` / `douyu` / `huya` /
/// `douyin` / `ks`); `flutterSiteId` is the Flutter site id used
/// for the danmaku enabled-map keys. Only these five — the other
/// 29 Pure Live platforms are never added (chen 2026-11-16).
/// (The C leg's own `LivePlatform` struct was deleted at merge:
/// one type, one file.)

/// One page of rooms from a list endpoint. `hasMore` is false
/// when the last page returned fewer rooms than the page size, or
/// when the service says there is nothing after this page.
struct LiveRoomPage: Equatable {
    let rooms: [LiveRoom]
    let hasMore: Bool

    static let empty = LiveRoomPage(rooms: [], hasMore: false)
}

/// What the live UI needs from the services. Every method takes
/// the narrowest inputs and returns seam models only.
protocol LiveDataGateway {
    /// Recommended rooms for one platform, optionally inside one
    /// category (`area` nil = all categories). Page 0-based; an
    /// empty page means the end of the list.
    func fetchRecommended(
        platform: String,
        area: String?,
        page: Int,
        completion: @escaping (LiveRoomPage) -> Void
    )

    /// Category (area) names for the platform's category strip.
    /// Empty when the platform exposes no categories.
    func fetchCategories(
        platform: String,
        completion: @escaping ([String]) -> Void
    )

    /// Room search on one platform, fastest first. Empty query
    /// answers empty — the UI never searches a blank string.
    func searchRooms(
        query: String,
        platform: String,
        completion: @escaping ([LiveRoom]) -> Void
    )

    /// Full room detail (title / anchor / watching / cover /
    /// live status) for one room. Nil when the room cannot be
    /// resolved on its platform — the UI then keeps the card's
    /// stored values, never a fake detail.
    func fetchRoomDetail(
        room: LiveRoom,
        completion: @escaping (LiveRoom?) -> Void
    )
}

/// Watching count for a room card / room page ("1.2万" above ten
/// thousand, plain below — Pure Live's compact count).
func liveWatchingText(_ watching: Int) -> String {
    guard watching > 0 else { return "" }
    if watching >= 10000 {
        let value = Double(watching) / 10000
        if value >= 100 {
            return "\(Int(value))万"
        }
        return String(format: "%.1f万", value)
    }
    return "\(watching)"
}

/// Cover URL for a room card (B-leg `cover` is the raw string,
/// like the Flutter model; an empty string means no cover).
func liveCoverURL(for room: LiveRoom) -> URL? {
    guard !room.cover.isEmpty else { return nil }
    return URL(string: room.cover)
}

/// Avatar URL for an anchor row (empty string means no avatar).
func liveAvatarURL(for room: LiveRoom) -> URL? {
    guard !room.avatar.isEmpty else { return nil }
    return URL(string: room.avatar)
}

// MARK: - Recommend / search grid layout (fix 2026-11-24)
//
// Build 33 on chen's phone showed the recommend grid unaligned:
// the right column ran past the screen edge, the title overlapped
// the watching count, and rows overlapped. The grid itself was
// already two flexible columns — the defects were (a) the grid
// identified cells by `roomId` alone while room identity is
// platform + room id, so a repeated room in one page (the
// recommend endpoints merge sub-lists and can repeat a room)
// gave SwiftUI duplicate cell identities, which misplaces cells;
// and (b) the card squeezed anchor + watching into one HStack,
// so a long anchor name squeezed the count. The fix: dedupe by
// the real identity before the grid ever sees the list, identify
// cells by the room itself (LiveRoom's Hashable IS platform +
// room id), anchor and watching on separate lines, and one
// canonical set of metrics below that every live grid (tab
// recommend, search results, home hot-live) shares — the numbers
// here are the single source of truth and the unit tests assert
// the arithmetic (cell width + spacing + margins == container,
// no overflow) for every iPhone width.
//
// Pure numbers on purpose (Double, no SwiftUI / CoreGraphics):
// this file is in AppCore, so the tests run under `swift test` on
// Linux too. The SwiftUI views convert with CGFloat(...) at the
// call site; LiveRoomCard.swift adds the GridItem columns.

/// Canonical metrics for the two-column live room grids.
enum LiveGridLayout {
    /// Columns in every live room grid.
    static let columns = 2
    /// Horizontal page margin the grid sits inside (points).
    static let edgePadding: Double = 24
    /// Gap between the two columns (points).
    static let interItemSpacing: Double = 12
    /// Gap between grid rows (points).
    static let rowSpacing: Double = 14
    /// Cover aspect ratio (width / height), 16:10.
    static let coverAspectRatio: Double = 16.0 / 10.0

    /// Width of one cell inside a container of the given width:
    /// margins and the inter-column gap come off first, the rest
    /// splits evenly over the two columns. Never negative.
    static func cellWidth(containerWidth: Double) -> Double {
        let usable = containerWidth - 2 * edgePadding - Double(columns - 1) * interItemSpacing
        return max(0, usable / Double(columns))
    }

    /// Cover height for a cell of the given width (16:10).
    static func coverHeight(cellWidth: Double) -> Double {
        cellWidth / coverAspectRatio
    }

    /// True when the two cells, the gap and the margins exactly
    /// fill the container — i.e. the grid cannot overflow it.
    /// (Floating-point equality with a 0.001 pt tolerance.)
    static func fills(containerWidth: Double) -> Bool {
        let cell = cellWidth(containerWidth: containerWidth)
        guard cell > 0 else { return false }
        let total = 2 * edgePadding + Double(columns) * cell + Double(columns - 1) * interItemSpacing
        return abs(total - containerWidth) < 0.001
    }
}

/// Drop repeated rooms from a list page, keeping the first
/// occurrence in order. Identity is platform + room id — the
/// same identity LiveRoom's own Equatable/Hashable uses. A page
/// from a recommend endpoint can repeat a room (the endpoints
/// merge sub-lists); without this the grid's ForEach sees
/// duplicate identities and SwiftUI misplaces cells (rows
/// overlapping, a cell drawn past the edge). Same-room-id on a
/// different platform is a different room and is kept.
func deduplicatedLiveRooms(_ rooms: [LiveRoom]) -> [LiveRoom] {
    var seen = Set<String>()
    var kept: [LiveRoom] = []
    kept.reserveCapacity(rooms.count)
    for room in rooms {
        let key = room.platform.rawValue + "|" + room.roomId
        guard !seen.contains(key) else { continue }
        seen.insert(key)
        kept.append(room)
    }
    return kept
}

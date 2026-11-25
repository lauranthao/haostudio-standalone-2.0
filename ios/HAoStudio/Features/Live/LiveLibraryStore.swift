// HAo Studio 2.0 — live library store (S4-C leg).
//
// Followed rooms, watch history, search history and the live
// resume key. Key names are the contract (Flutter Hive keys —
// `hao_live_follows` / `hao_live_hist` / `hao_live_search_hist` /
// `hao_live_hist_limit`): JSON collections live in
// Documents/<key>.json and are read through LocalStore; the
// history limit stays a UserDefaults scalar. Nothing here renames
// a key — a rename is data loss.
//
// Resume rules (Flutter live_follow_store.dart +
// live_history_store.dart, verbatim):
// - Identity is `platform|roomId` (LiveResumeKey) — a room id
//   alone is not unique across the five platforms.
// - One room = one follow row / one history row. Re-adding moves
//   the row to the front with fresh title/cover/time, never a
//   duplicate.
// - History is recorded on ENTERING a room. Live is real-time:
//   there is no playback position to resume, so "resume" means
//   re-entering the most recent room (the history row lists it
//   first; there is no separate resume entry — b49 sweep #33
//   deleted the dead `resumeEntry` API).
// - History cap is 50 by default, 0 = unlimited (Pure Live's
//   history-limit rule); follows are uncapped.
// - Search history holds keywords only (max 20, most recent
//   first) — results are per-platform and time-sensitive, so
//   re-running re-searches live.
//
// The store is a plain value-access layer (no ObservableObject):
// view models own the published state and call reload() when they
// appear or after a mutation. That keeps the store unit-testable
// without a runloop and keeps every write explicit.
//
// Foundation-only (no SwiftUI, no UIKit): B leg registers this
// single file in the AppCore target (Package.swift) so the
// LiveFeaturesTests target can import it. The store takes plain
// values (platform / roomId / title / nick / cover), never a
// B-leg LiveRoom — the UI layer maps rooms onto these calls, so
// the store stays independent of the B-leg model shape.

import Foundation

/// One followed anchor / room.
struct LiveFollowedRoom: Codable, Equatable, Identifiable {
    var platform: String
    var roomId: String
    var title: String
    var nick: String
    var cover: String
    var followedAt: Date
    /// The list feed's signed `playUrls` payload, JSON-encoded
    /// (b49 sweep #16): Kuaishou rooms opened from 关注/历史
    /// keep their list-feed fallback — without this the room
    /// re-parse is the only source and a rate-limited room page
    /// fails the room. Nil for rooms saved before this field
    /// existed, or for rooms whose feed carried no playUrls.
    var playUrlsJSON: String? = nil

    var id: String { LiveResumeKey.key(platform: platform, roomId: roomId) }
}

/// One watched live room.
struct LiveHistoryEntry: Codable, Equatable, Identifiable {
    var platform: String
    var roomId: String
    var title: String
    var nick: String
    var cover: String
    var watchedAt: Date
    /// Same as LiveFollowedRoom.playUrlsJSON (b49 sweep #16).
    var playUrlsJSON: String? = nil

    var id: String { LiveResumeKey.key(platform: platform, roomId: roomId) }
}

/// The live resume key: `platform|roomId`. The coordinator, the
/// history row and the follow row all use this one string. Live
/// has no playback position — the key re-opens the room.
enum LiveResumeKey {
    static func key(platform: String, roomId: String) -> String {
        "\(platform)|\(roomId)"
    }
}

/// Day-group section (Pure Live `HistorySection.of`: today /
/// yesterday / 2–6 days ago / earlier).
enum LiveHistorySection: String, CaseIterable {
    case today
    case yesterday
    case recent
    case earlier

    var label: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .recent: return "2–6 天前"
        case .earlier: return "更早"
        }
    }

    /// Section for `date` relative to `now` (calendar days, local
    /// time).
    static func of(_ date: Date, now: Date = Date()) -> LiveHistorySection {
        let calendar = Calendar.current
        let startOfDate = calendar.startOfDay(for: date)
        let startOfNow = calendar.startOfDay(for: now)
        let diff = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? 0
        if diff <= 0 {
            return .today
        }
        if diff == 1 {
            return .yesterday
        }
        if diff <= 6 {
            return .recent
        }
        return .earlier
    }
}

enum LiveLibraryStore {
    // MARK: - Collection names (Documents/<name>.json)

    static let followsCollection = "hao_live_follows"
    static let historyCollection = "hao_live_hist"
    static let searchHistoryCollection = "hao_live_search_hist"

    /// UserDefaults key for the history cap (0 = unlimited).
    static let historyLimitKey = "hao_live_hist_limit"

    static let defaultHistoryLimit = 50
    static let maxSearchHistory = 20

    // MARK: - Pure rules (unit-tested, no I/O)

    /// Merge a follow into the stored list: same room replaces
    /// its old row, newest first, uncapped.
    static func mergedFollows(
        _ stored: [LiveFollowedRoom],
        with follow: LiveFollowedRoom
    ) -> [LiveFollowedRoom] {
        var list = stored.filter { $0.id != follow.id }
        list.insert(follow, at: 0)
        return list
    }

    /// Merge a history row into the stored list: same room
    /// replaces its old row, newest first, capped at `limit`
    /// (0 = unlimited).
    static func mergedHistory(
        _ stored: [LiveHistoryEntry],
        with entry: LiveHistoryEntry,
        limit: Int
    ) -> [LiveHistoryEntry] {
        var list = stored.filter { $0.id != entry.id }
        list.insert(entry, at: 0)
        return applyHistoryLimit(list, limit: limit)
    }

    /// Cap a history list at `limit` (0 = unlimited).
    static func applyHistoryLimit(
        _ entries: [LiveHistoryEntry],
        limit: Int
    ) -> [LiveHistoryEntry] {
        guard limit > 0 else { return entries }
        return Array(entries.prefix(limit))
    }

    /// Merge a search keyword: same query replaces its old spot,
    /// newest first, capped at maxSearchHistory.
    static func mergedSearchHistory(
        _ stored: [String],
        with query: String
    ) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return stored }
        var list = stored.filter { $0 != trimmed }
        list.insert(trimmed, at: 0)
        return Array(list.prefix(maxSearchHistory))
    }

    /// Drop one keyword from a search history list (pure — the
    /// long-press delete on a history chip; the video side has the
    /// same shape on VideoLibraryStore).
    static func removingSearchHistory(_ stored: [String], term: String) -> [String] {
        stored.filter { $0 != term }
    }

    /// How many stored entries a new limit would delete (0 when
    /// the new limit is unlimited or >= the stored count).
    /// Pure cap math, covered by LiveLibraryStoreTests; the
    /// setter that used it is gone (b49 sweep #33), but the math
    /// itself stays for the cap rule.
    static func wouldDeleteCount(_ stored: [LiveHistoryEntry], newLimit: Int) -> Int {
        if newLimit <= 0 { return 0 }
        let count = stored.count
        return count > newLimit ? count - newLimit : 0
    }

    // MARK: - Follows

    static func follows() -> [LiveFollowedRoom] {
        LocalStore.loadCollection(named: followsCollection, default: [LiveFollowedRoom]())
    }

    static func saveFollows(_ rooms: [LiveFollowedRoom]) {
        LocalStore.saveCollection(named: followsCollection, value: rooms)
    }

    static func isFollowed(platform: String, roomId: String) -> Bool {
        let key = LiveResumeKey.key(platform: platform, roomId: roomId)
        return follows().contains { $0.id == key }
    }

    /// Platforms that have at least one follow, in first-seen
    /// order.
    static func followedPlatforms() -> [String] {
        var seen: [String] = []
        for follow in follows() where !seen.contains(follow.platform) {
            seen.append(follow.platform)
        }
        return seen
    }

    /// Encode a room's list-feed `playUrls` payload for storage
    /// (b49 sweep #16): the value in `room.data["playUrls"]` is
    /// JSON-shaped (array of descriptors), so it round-trips as a
    /// JSON string. Nil when the room carries no encodable
    /// playUrls — the caller then stores nothing and the room
    /// resolves from the network as before.
    static func playUrlsJSON(from roomData: [String: Any]?) -> String? {
        guard let playUrls = roomData?["playUrls"],
              JSONSerialization.isValidJSONObject(playUrls),
              let data = try? JSONSerialization.data(withJSONObject: playUrls, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    /// Decode a stored `playUrls` payload back into the `data`
    /// map a `LiveRoom` carries (`toRoom()` uses this): the
    /// resolver's `resolutionFromRoom` fallback reads exactly
    /// `data["playUrls"]`.
    static func playUrlsData(from json: String?) -> [String: Any]? {
        guard let json = json, let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }
        return ["playUrls": parsed]
    }

    static func addFollow(
        platform: String,
        roomId: String,
        title: String,
        nick: String,
        cover: String,
        playUrlsJSON: String? = nil
    ) {
        let follow = LiveFollowedRoom(
            platform: platform, roomId: roomId, title: title,
            nick: nick, cover: cover, followedAt: Date(),
            playUrlsJSON: playUrlsJSON)
        saveFollows(mergedFollows(follows(), with: follow))
        NotificationCenter.default.post(name: .haoLiveFollowChanged, object: nil)
    }

    static func removeFollow(platform: String, roomId: String) {
        let key = LiveResumeKey.key(platform: platform, roomId: roomId)
        saveFollows(follows().filter { $0.id != key })
        NotificationCenter.default.post(name: .haoLiveFollowChanged, object: nil)
    }

    /// Toggle follow. Returns true when the room was followed.
    @discardableResult
    static func toggleFollow(
        platform: String,
        roomId: String,
        title: String,
        nick: String,
        cover: String,
        playUrlsJSON: String? = nil
    ) -> Bool {
        if isFollowed(platform: platform, roomId: roomId) {
            removeFollow(platform: platform, roomId: roomId)
            return false
        }
        addFollow(platform: platform, roomId: roomId, title: title, nick: nick, cover: cover, playUrlsJSON: playUrlsJSON)
        return true
    }

    static func clearFollows() {
        saveFollows([])
        NotificationCenter.default.post(name: .haoLiveFollowChanged, object: nil)
    }

    // MARK: - History

    static func history() -> [LiveHistoryEntry] {
        LocalStore.loadCollection(named: historyCollection, default: [LiveHistoryEntry]())
    }

    static func saveHistory(_ entries: [LiveHistoryEntry]) {
        // b49fix18 D-7: the write takes
        // MigrationStore.collectionWriteQueue, the same queue
        // the backup import's history merge and the rollback
        // take — a history write landing inside the merge's
        // re-read → write gap, or the restore's remove → copy
        // gap, is serialised after it instead of cancelling
        // the merge / rollback. The import never calls back
        // into this store, so taking the queue here cannot
        // deadlock. The notification stays outside the queue:
        // it is not file state.
        MigrationStore.collectionWriteQueue.sync {
            LocalStore.saveCollection(named: historyCollection, value: entries)
        }
        // A2: history changed — home 热门直播 and 我的's 直播历史
        // count reload on this (they used to refresh only on
        // appear / pop-back).
        NotificationCenter.default.post(name: .haoLiveHistoryChanged, object: nil)
    }

    /// Record entering a room: same room moves to the front with
    /// fresh title/cover/time.
    static func recordHistory(
        platform: String,
        roomId: String,
        title: String,
        nick: String,
        cover: String,
        playUrlsJSON: String? = nil
    ) {
        let entry = LiveHistoryEntry(
            platform: platform, roomId: roomId, title: title,
            nick: nick, cover: cover, watchedAt: Date(),
            playUrlsJSON: playUrlsJSON)
        saveHistory(mergedHistory(history(), with: entry, limit: historyLimit()))
    }

    /// Record a pre-built entry (tests / re-entry from the history
    /// page).
    static func recordHistoryEntry(_ entry: LiveHistoryEntry) {
        saveHistory(mergedHistory(history(), with: entry, limit: historyLimit()))
    }

    static func removeHistory(platform: String, roomId: String) {
        let key = LiveResumeKey.key(platform: platform, roomId: roomId)
        saveHistory(history().filter { $0.id != key })
    }

    static func clearHistory() {
        saveHistory([])
    }

    // MARK: - History limit

    /// Current history cap: 0 = unlimited, default 50.
    /// (b49 sweep #33) The cap reader stays — recordHistory
    /// enforces it on every write. The setter is deleted: no UI
    /// ever set it and no caller used it, so it was a dead API
    /// with no "history-cap setting" to wire it to. Likewise
    /// `resumeEntry` is deleted: there is no "继续观看" entry for
    /// live, and the history row already opens with the most
    /// recent room first.
    static func historyLimit(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: historyLimitKey) != nil else {
            return defaultHistoryLimit
        }
        return defaults.integer(forKey: historyLimitKey)
    }

    // MARK: - Search history

    static func searchHistory() -> [String] {
        LocalStore.loadCollection(named: searchHistoryCollection, default: [String]())
    }

    static func saveSearchQuery(_ query: String) {
        LocalStore.saveCollection(
            named: searchHistoryCollection,
            value: mergedSearchHistory(searchHistory(), with: query))
    }

    static func clearSearchHistory() {
        LocalStore.saveCollection(named: searchHistoryCollection, value: [String]())
    }

    /// Delete one search keyword (long-press on a history chip).
    static func removeSearchHistory(term: String) {
        LocalStore.saveCollection(
            named: searchHistoryCollection,
            value: removingSearchHistory(searchHistory(), term: term))
    }
}

/// Follow-list change signal: posted whenever the follow list
/// changes (follow / unfollow / clear-all), so the tab's follow
/// row and the follows page refresh without waiting for a
/// re-appear — the context-menu toggle on a card writes the store
/// directly and no view owns that write. Posted from the store so
/// every writer is covered (card menu, room page, swipe delete,
/// clear-all); views observe and re-read.
extension Notification.Name {
    static let haoLiveFollowChanged = Notification.Name("haoLiveFollowChanged")
    /// Posted by `LiveLibraryStore.saveHistory` on every history
    /// write (room entered, remove, clear-all). saveHistory is the
    /// single funnel, so every writer is covered. Home's 热门直播
    /// and 我的's 直播历史 count listen for it; without it they
    /// only refreshed on appear / pop-back.
    static let haoLiveHistoryChanged = Notification.Name("haoLiveHistoryChanged")
}

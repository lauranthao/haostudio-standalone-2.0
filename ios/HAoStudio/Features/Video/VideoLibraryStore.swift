// HAo Studio 2.0 — video library store (S3-C leg).
//
// Watch history, favourites, resume positions, search history,
// home cache and category prefs. Key names are the contract
// (docs/storage-mapping.md — the S1 migration writes the same
// names, so a migrated user keeps their history): JSON collections
// live in Documents/<key>.json and are read through LocalStore;
// the tab mode stays a UserDefaults scalar. Nothing here renames
// a key — a rename is data loss.
//
// Resume rules (Flutter video_history_store.dart, verbatim):
// - One film = one history row (dedupe by normalised title + year;
//   a remake with a different known year never matches).
// - A position under 5 s is not saved at all.
// - Resume only when the position is over 10 s in AND at least
//   30 s from the end (a finished episode does not resume).
// - The resume identity is title + year (VideoResumeKey) — a CMS
//   vod_id drifts on reseed and is never the resume key.
//
// The store is a plain value-access layer (no ObservableObject):
// view models own the published state and call reload() when they
// appear or after a mutation. That keeps the store unit-testable
// without a runloop and keeps every write explicit.

import Foundation

/// Posted by `VideoLibraryStore.toggleFavourite` on every change
/// (add or remove). The favourites grid listens for it; the
/// detail page owns its own `isFavourite` state and does not
/// need it. (Music has the same pattern: `haoMusicFavChanged`.)
extension Notification.Name {
    static let haoVideoFavChanged = Notification.Name("haoVideoFavChanged")
}

/// One history row: the film + where playback stopped. The film
/// identity is title + year; the row is replaced (not duplicated)
/// when the same film is watched again.
struct VideoHistoryEntry: Codable, Equatable, Identifiable {
    var item: VideoItem
    var episodeName: String
    var episodeIndex: Int
    var lineName: String
    var positionSeconds: Double
    var durationSeconds: Double
    var updatedAt: Date

    var id: String { VideoResumeKey.key(title: item.title, year: item.year) }

    /// Finished when the position is within 30 s of the end
    /// (or the duration is unknown and the position is 0).
    var isFinished: Bool {
        durationSeconds > 0 && positionSeconds >= durationSeconds - 30
    }

    /// Progress 0...1 for the continue-watching card; 0 when the
    /// duration is unknown.
    var progress: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(1, max(0, positionSeconds / durationSeconds))
    }
}

/// Category display prefs: hidden categories + manual order.
/// Categories not listed here keep gateway order.
struct VideoCategoryPrefs: Codable, Equatable {
    var hidden: [String] = []
    var order: [String] = []

    static let empty = VideoCategoryPrefs()
}

enum VideoLibraryStore {
    // MARK: - Collection names (Documents/<name>.json)

    static let historyCollection = "hao_video_hist"
    static let favCollection = "hao_video_fav"
    static let searchHistoryCollection = "hao_video_search_hist"
    static let homeCacheCollection = "hao_video_home"
    static let categoryPrefsCollection = "hao_video_category_prefs"

    /// UserDefaults key for the video tab mode (`cms` / `emby`).
    static let tabModeKey = "hao_video_tab_mode"

    static let maxHistory = 20
    static let maxSearchHistory = 20

    /// Positions under 5 s are not saved (Flutter web rule).
    static let minSaveSeconds = 5.0
    /// Resume needs more than 10 s watched (Flutter loadResume).
    static let minResumeSeconds = 10.0
    /// Within 30 s of the end counts as finished, not resumable.
    static let finishMarginSeconds = 30.0

    // MARK: - Pure rules (unit-tested, no I/O)

    /// Whether a stored position is a real resume point.
    static func shouldResume(positionSeconds: Double, durationSeconds: Double) -> Bool {
        guard positionSeconds > minResumeSeconds else { return false }
        guard durationSeconds > 0 else { return true }
        return positionSeconds < durationSeconds - finishMarginSeconds
    }

    /// Merge a new history row into the stored list: same film
    /// (title + year) replaces its old row, newest first, capped.
    static func mergedHistory(_ stored: [VideoHistoryEntry], with entry: VideoHistoryEntry) -> [VideoHistoryEntry] {
        var list = stored.filter { $0.id != entry.id }
        list.insert(entry, at: 0)
        return Array(list.prefix(maxHistory))
    }

    // MARK: - History

    static func history() -> [VideoHistoryEntry] {
        LocalStore.loadCollection(named: historyCollection, default: [VideoHistoryEntry]())
    }

    static func saveHistory(_ entries: [VideoHistoryEntry]) {
        LocalStore.saveCollection(named: historyCollection, value: entries)
    }

    static func historyEntry(title: String, year: String?) -> VideoHistoryEntry? {
        let key = VideoResumeKey.key(title: title, year: year)
        return history().first { $0.id == key }
    }

    /// Record a playback position. Positions under 5 s are ignored
    /// (not saved); a finished position keeps its row but is not a
    /// resume point (shouldResume decides at read time).
    static func savePosition(
        item: VideoItem,
        episodeName: String,
        episodeIndex: Int,
        lineName: String,
        positionSeconds: Double,
        durationSeconds: Double
    ) {
        guard positionSeconds >= minSaveSeconds else { return }
        let entry = VideoHistoryEntry(
            item: item, episodeName: episodeName, episodeIndex: episodeIndex,
            lineName: lineName, positionSeconds: positionSeconds,
            durationSeconds: durationSeconds, updatedAt: Date())
        saveHistory(mergedHistory(history(), with: entry))
    }

    /// The resume bookmark for a film, or nil when there is nothing
    /// resumable (never watched, too short, or finished).
    static func resumeInfo(title: String, year: String?) -> ResumeInfo? {
        guard let entry = historyEntry(title: title, year: year) else { return nil }
        guard shouldResume(positionSeconds: entry.positionSeconds, durationSeconds: entry.durationSeconds) else {
            return nil
        }
        return ResumeInfo(
            key: entry.id, episodeName: entry.episodeName,
            episodeIndex: entry.episodeIndex,
            positionSeconds: entry.positionSeconds,
            durationSeconds: entry.durationSeconds,
            updatedAt: entry.updatedAt)
    }

    static func clearHistory() {
        saveHistory([])
    }

    static func removeHistory(title: String, year: String?) {
        let key = VideoResumeKey.key(title: title, year: year)
        saveHistory(history().filter { $0.id != key })
    }

    /// Resume keys of everything with watch history (title +
    /// year). The poster grid reads this as its default watched
    /// set, so the "already watched" checkmark is the same on
    /// every grid (home, browse, category, search, favourites) —
    /// it used to appear only on the home rows, which pass their
    /// own keys. Callers with a live list may still pass their
    /// own set; it wins over this default.
    static func watchedKeys() -> Set<String> {
        Set(history().map { $0.id })
    }

    // MARK: - Favourites

    static func favourites() -> [VideoItem] {
        LocalStore.loadCollection(named: favCollection, default: [VideoItem]())
    }

    static func saveFavourites(_ items: [VideoItem]) {
        LocalStore.saveCollection(named: favCollection, value: items)
    }

    static func isFavourite(item: VideoItem) -> Bool {
        let key = VideoResumeKey.key(title: item.title, year: item.year)
        return favourites().contains {
            VideoResumeKey.key(title: $0.title, year: $0.year) == key
        }
    }

    /// Toggle favourite. Returns true when the item was added.
    /// Posts `haoVideoFavChanged` on every change: the favourites
    /// grid only re-reads on appear, so a long-press unfavourite
    /// from a poster card would otherwise leave the card sitting
    /// in "我的收藏" until the user left and came back.
    @discardableResult
    static func toggleFavourite(item: VideoItem) -> Bool {
        var items = favourites()
        let key = VideoResumeKey.key(title: item.title, year: item.year)
        if let index = items.firstIndex(where: {
            VideoResumeKey.key(title: $0.title, year: $0.year) == key
        }) {
            items.remove(at: index)
            saveFavourites(items)
            NotificationCenter.default.post(name: .haoVideoFavChanged, object: nil)
            return false
        }
        items.insert(item, at: 0)
        saveFavourites(items)
        NotificationCenter.default.post(name: .haoVideoFavChanged, object: nil)
        return true
    }

    // MARK: - Search history

    static func searchHistory() -> [String] {
        LocalStore.loadCollection(named: searchHistoryCollection, default: [String]())
    }

    static func saveSearchQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var history = searchHistory().filter { $0 != trimmed }
        history.insert(trimmed, at: 0)
        LocalStore.saveCollection(named: searchHistoryCollection, value: Array(history.prefix(maxSearchHistory)))
    }

    static func clearSearchHistory() {
        LocalStore.saveCollection(named: searchHistoryCollection, value: [String]())
    }

    /// Delete one search term (video search history chips,
    /// build 36 item 19). Same write path as clearSearchHistory.
    static func removeSearchHistory(term: String) {
        let history = searchHistory().filter { $0 != term }
        LocalStore.saveCollection(named: searchHistoryCollection, value: history)
    }

    // MARK: - Home cache

    static func cachedHome() -> [VideoHomeRow] {
        LocalStore.loadCollection(named: homeCacheCollection, default: [VideoHomeRow]())
    }

    static func saveHomeCache(_ rows: [VideoHomeRow]) {
        LocalStore.saveCollection(named: homeCacheCollection, value: rows)
    }

    // MARK: - Category prefs

    static func categoryPrefs() -> VideoCategoryPrefs {
        LocalStore.loadCollection(named: categoryPrefsCollection, default: VideoCategoryPrefs.empty)
    }

    static func saveCategoryPrefs(_ prefs: VideoCategoryPrefs) {
        LocalStore.saveCollection(named: categoryPrefsCollection, value: prefs)
    }

    /// Apply stored prefs to a gateway category list: hidden
    /// categories drop out, the stored order comes first, anything
    /// new keeps gateway order after it.
    static func visibleCategories(_ names: [String], prefs: VideoCategoryPrefs) -> [String] {
        let visible = names.filter { !prefs.hidden.contains($0) }
        var ordered: [String] = []
        for name in prefs.order where visible.contains(name) {
            ordered.append(name)
        }
        for name in visible where !ordered.contains(name) {
            ordered.append(name)
        }
        return ordered
    }

    // MARK: - Tab mode

    static func tabMode(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: tabModeKey) ?? "cms"
    }

    static func setTabMode(_ mode: String, defaults: UserDefaults = .standard) {
        defaults.set(mode, forKey: tabModeKey)
    }
}

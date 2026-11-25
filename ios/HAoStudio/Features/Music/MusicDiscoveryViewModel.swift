// HAo Studio 2.0 — music discovery view model (S2-C leg).
//
// Daily picks, plaza, charts, listen report. The report is a pure
// local aggregation of the listen log (Flutter ListenReport.compute):
// calendar ranges (week = Monday 00:00 local to now, month = 1st
// 00:00 local to now, all = everything), total seconds, top songs /
// artists / platforms, per-day counts.
//
// Daily picks are cached per day (hao_daily.json); a missing day is
// built from local data (listen log + favourites + recent +
// playlists, ranked — no shuffle, no seed).
// Plaza (S7-A): the platform APIs ARE in the music API leg —
// MusicPlaylistImportAPI.plaza(platform:) (S3) serves wy / tx /
// kg / kw from the real platform endpoints, never a fallback
// platform. A platform that answers with nothing shows the honest
// "暂无推荐" empty state, never fake rows. Charts moved to
// MusicChartsView.swift (S3-C).

import SwiftUI
import UIKit // b49fix12 P2-2: UIApplication.didBecomeActiveNotification

/// One listen-report range. Calendar ranges, matching the labels
/// (Flutter ListenReport.compute).
enum ListenReportRange: String, CaseIterable {
    case week
    case month
    case all

    var label: String {
        switch self {
        case .week: return "本周"
        case .month: return "本月"
        case .all: return "全部"
        }
    }
}

struct ListenReportTopSong: Equatable {
    var song: MusicSong
    var plays: Int
}

struct ListenReportTopArtist: Equatable {
    var artist: String
    var plays: Int
}

struct ListenReportTopPlatform: Equatable {
    var platform: MusicPlatform
    var plays: Int
}

struct ListenReportDayCount: Equatable {
    var label: String
    var plays: Int
}

struct ListenReport: Equatable {
    var totalSeconds: Int
    var totalPlays: Int
    var topSongs: [ListenReportTopSong]
    var topArtists: [ListenReportTopArtist]
    var topPlatforms: [ListenReportTopPlatform]
    var perDay: [ListenReportDayCount]

    static let empty = ListenReport(
        totalSeconds: 0, totalPlays: 0,
        topSongs: [], topArtists: [], topPlatforms: [], perDay: []
    )
}

@MainActor
final class MusicDiscoveryViewModel: ObservableObject {
    @Published private(set) var dailyTracks: [MusicSong] = []
    @Published private(set) var dailyDayKey = ""
    @Published private(set) var report = ListenReport.empty
    @Published var reportRange: ListenReportRange = .week {
        didSet { recomputeReport() }
    }
    @Published var plazaPlatform: MusicPlatform = .wy
    /// Plaza rows for the current platform (real platform data,
    /// S7-A). `plazaFailed` is true when the platform answered with
    /// nothing — failure and empty are indistinguishable from the
    /// API, so the page shows one honest "暂无推荐" state for both.
    @Published private(set) var plazaPlaylists: [PlaylistSummary] = []
    @Published private(set) var plazaLoading = false
    @Published private(set) var plazaFailed = false

    // MARK: - Daily replacement spares (b45-b, Coda §3.5)

    /// Spare picks behind today's daily list, so "不喜欢换一首"
    /// can replace a song in place. Empty = no replacement left
    /// (the button hides instead of going dead).
    @Published private(set) var dailySpares: [MusicSong] = []

    // MARK: - Explore snapshots (b45-b, Coda §3.9)

    /// Per-category playlist snapshots, cached 15 minutes
    /// (Coda §3.9: switching categories answers instantly).
    @Published private(set) var exploreSnapshots: [String: [PlaylistSummary]] = [:]
    @Published private(set) var exploreLoading: Set<String> = []
    @Published private(set) var exploreFailed: Set<String> = []
    /// b49fix3 P2-10: a failed pull-to-refresh used to be silent
    /// (old snapshots kept, no feedback, no retry). True after a
    /// refresh fetch returns nothing; cleared when a refresh
    /// starts or succeeds. The per-category failure state
    /// (exploreFailed) is separate — it covers the first load.
    @Published private(set) var exploreRefreshFailed = false
    /// Categories the explore page actually renders (chips +
    /// shelves). Only categories with a non-empty result from
    /// the loaded plaza data are listed — the 26 chips used to
    /// render unconditionally while most keyword filters matched
    /// nothing, so most shelves were empty by construction ("该
    /// 分类暂无歌单"). Starts as ["全部"] until the first plaza
    /// fetch lands; "全部" itself is always valid (it is the
    /// merged list, and its failure state carries the retry).
    @Published private(set) var exploreAvailableCategories: [String] = ["全部"]

    private var exploreAllPlaylists: [PlaylistSummary] = []
    private var exploreAllLoadedAt: Date? = nil
    private var exploreLoadedAt: [String: Date] = [:]

    /// Coda §3.9: 26 category chips. 排行榜 is deliberately
    /// excluded — it already lives on the home / charts page.
    static let exploreCategories = [
        "全部", "推荐歌单", "精品歌单", "官方", "华语", "流行", "摇滚",
        "民谣", "电子", "轻音乐", "说唱", "爵士", "古典", "影视原声",
        "ACG", "古风", "怀旧", "治愈", "放松", "伤感", "快乐", "学习",
        "工作", "运动", "驾车", "夜晚",
    ]

    static let exploreSnapshotTTL: TimeInterval = 900

    private var listenLog: [ListenEvent] = []

    /// Day-change / foreground observers (b49fix12 P2-2): the
    /// daily page had none — it sat across midnight showing
    /// yesterday's list while Home's observers refreshed Home
    /// (b49-sweep14 deepread P2-2). Same shape as Home's
    /// (b49fix11 P2-1): at most one of each, removed in deinit.
    /// Every pushed instance registers its own pair (a new
    /// @StateObject per push); a duplicate recompute across two
    /// live instances is harmless — reloadDaily runs on the main
    /// thread and its save is compare-and-swap guarded, so both
    /// compute the same list.
    private var dayChangedObserver: NSObjectProtocol?
    private var didBecomeActiveObserver: NSObjectProtocol?

    init() {
        plazaPlatform = MusicLibraryStore.plazaPlatform()
        dailyDayKey = musicDayKey(of: Date())
        // b49fix12 P2-2: two triggers, both gated by
        // shouldReloadForDayChange so a same-day foreground costs
        // nothing: the calendar-day notification fires at midnight
        // while the app is foregrounded; the become-active check
        // catches a midnight crossed while backgrounded (the
        // day-change notification is not delivered to a suspended
        // app). The init seeds dailyDayKey with today's key, so a
        // notification right after the push is a no-op too.
        dayChangedObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            // Explicit main-actor hop: the observer block is
            // @Sendable, so the reload cannot happen inside it
            // directly (same shape as the settle Timer hop in
            // MusicSearchViewModel; a direct call fails Swift 6
            // type-check with [#ActorIsolatedCall]).
            Task { @MainActor [weak self] in self?.reloadDailyIfDayChanged() }
        }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reloadDailyIfDayChanged() }
        }
    }

    deinit {
        if let token = dayChangedObserver { NotificationCenter.default.removeObserver(token) }
        if let token = didBecomeActiveObserver { NotificationCenter.default.removeObserver(token) }
    }

    /// Day-change / foreground re-check (b49fix12 P2-2): reload
    /// the daily list only when the cached list is not today's
    /// — the predicate makes a same-day foreground a no-op.
    /// Calls reload() rather than reloadDaily() so the recompute
    /// also refreshes the listen log (a stale log would rank
    /// today's list on yesterday's listening) and the report;
    /// all three are local reads, no network.
    private func reloadDailyIfDayChanged() {
        if HomeViewModel.shouldReloadForDayChange(todayKey: musicDayKey(of: Date()), cachedDayKey: dailyDayKey) {
            reload()
        }
    }

    func reload() {
        listenLog = MusicLibraryStore.getListenLog()
        reloadDaily()
        recomputeReport()
    }

    // MARK: - Daily

    /// Daily picks, cached per day key (Coda §3.1: 86400s, day-keyed).
    /// A plain call serves the cache; `force` regenerates today
    /// (pull-to-refresh and the "刷新今日推荐" menu — the menu was
    /// a no-op while the cache lived, b45-g). The cache is trusted
    /// only when it validates (HomeViewModel.validatedDailyTracks:
    /// today's key, non-empty, every track with a real song id) —
    /// a stale / empty / identity-less entry is recomputed instead
    /// of shown, same rule as the home reader of this cache.
    /// b49fix4 P1-2 / P2-30: this reads through
    /// HomeViewModel.loadDailyPicksAndSpares — the SAME total-40
    /// composition and the SAME cache as home. The old code ran
    /// its own total-20 ranking plus a second total-40 run for
    /// spares, so whichever page loaded first decided the other
    /// page's content for the day.
    func reloadDaily(force: Bool = false) {
        let dayKey = musicDayKey(of: Date())
        dailyDayKey = dayKey
        let result = HomeViewModel.loadDailyPicksAndSpares(
            listenLog: listenLog,
            recent: MusicLibraryStore.getRecent(),
            dayKey: dayKey,
            force: force)
        // b49fix5 P2-4: this runs synchronously on the main thread,
        // so the save is already serialised against Home's publish
        // and replaceDailySong; the compare-and-swap still guards
        // against a Home reload that published in between. force
        // (explicit refresh) writes unconditionally.
        // b49fix11 P2-2: re-check today's key before writing — this
        // call is synchronous, so midnight must fall inside it to
        // matter (local reads + ranking, generally <100ms), but if
        // it does, the result was computed under yesterday's key
        // and saving it would stamp yesterday's list as today's
        // cache — the exact bug b49fix10 P2-3 closed on the Home
        // side. Reuse shouldPublishDaily's same-key rule: on
        // rollover, skip the write and publish memory only; the
        // next reload recomputes. dailyDayKey stays at the start
        // key, which correctly names the list on screen. (Saving
        // under the fresh key instead would be worse: it would
        // persist yesterday's ranking as today's cache.)
        if let saveTracks = result.saveTracks,
           HomeViewModel.shouldPublishDaily(startDayKey: dayKey, publishDayKey: musicDayKey(of: Date())) {
            MusicLibraryStore.saveDailyTracksIfUnchanged(
                saveTracks, for: dayKey,
                expectedKeys: result.expectedDiskKeys, force: force)
        }
        dailyTracks = result.picks
        dailySpares = result.spares
    }

    /// "不喜欢换一首" (Coda §3.5): replace the song in place
    /// with the next spare, and persist the day's list. The
    /// disliked song is also recorded so it never comes back.
    /// b49fix4 P2-31: the dislike is recorded BEFORE the
    /// spares-empty guard (the old order silently dropped it
    /// when the spares ran out at that instant), and the save
    /// writes the full 40 (picks + spares) — saving only the
    /// picks shrank the cache back to 20 and lost the spares.
    /// b49fix10 P2-3: same midnight staleness as Home's
    /// replaceDailySong — the save takes a FRESH day key at
    /// save time, not the cached dailyDayKey (only refreshed
    /// by init / reloadDaily), or a replace after midnight
    /// saved under yesterday's key and the next load dropped
    /// it. The cached key is updated to match.
    /// b49fix12 P2-1: the save is gated on the cached key
    /// still being today — after midnight the on-screen list
    /// is yesterday's ranking, and saving it under today's
    /// key would stamp it as today's cache; the next reload
    /// would take the cache-hit branch and never recompute,
    /// locking yesterday's list in for the whole day
    /// (b49-sweep14 deepread P2-1). So on rollover the save
    /// is skipped: the dislike is already recorded above, and
    /// a recompute is triggered instead — the recompute
    /// naturally excludes the disliked song, so the user's
    /// intent still lands and today's list is computed today.
    /// (The b49fix10 note that the on-screen list "becomes
    /// today's cached list until a force refresh recomputes
    /// it" is void per b49-sweep14 ruling §2: once saved under
    /// today's key the next reload takes the cache-hit branch,
    /// so the force refresh never comes.)
    func replaceDailySong(_ song: MusicSong) {
        guard let index = dailyTracks.firstIndex(where: { $0.identityKey == song.identityKey }) else { return }
        MusicLibraryStore.addFMDisliked(key: song.identityKey)
        guard !dailySpares.isEmpty else { return }
        dailyTracks[index] = dailySpares.removeFirst()
        // b49fix12 P2-1: only persist when the on-screen list
        // still belongs to today (see the doc above). On
        // rollover, do NOT save — reload() recomputes today's
        // list (and refreshes the listen log + report); the
        // in-memory swap above stays visible until it lands.
        guard HomeViewModel.shouldSaveReplacedDaily(cachedDayKey: dailyDayKey, todayKey: musicDayKey(of: Date())) else {
            reload()
            return
        }
        let key = musicDayKey(of: Date())
        dailyDayKey = key
        MusicLibraryStore.saveDailyTracks(dailyTracks + dailySpares, for: key)
    }

    // MARK: - Explore (b45-b, Coda §3.9)

    func explorePlaylists(for category: String) -> [PlaylistSummary] {
        return exploreSnapshots[category] ?? []
    }

    func loadExploreCategory(_ category: String) {
        let now = Date()
        if let loadedAt = exploreLoadedAt[category],
           now.timeIntervalSince(loadedAt) < Self.exploreSnapshotTTL,
           exploreSnapshots[category] != nil {
            return
        }
        guard !exploreLoading.contains(category) else { return }
        exploreLoading.insert(category)
        exploreFailed.remove(category)
        loadExploreAll { [weak self] all in
            guard let self = self else { return }
            self.exploreLoading.remove(category)
            guard let all = all else {
                if self.exploreSnapshots[category] == nil {
                    self.exploreFailed.insert(category)
                }
                return
            }
            self.exploreLoadedAt[category] = Date()
            self.exploreSnapshots[category] = Self.filterExplorePlaylists(all, category: category)
        }
    }

    /// Pull-to-refresh (b45-g, Coda §8.2 PanelRefresh): drop every
    /// explore snapshot + the shared plaza cache, then re-filter
    /// every already-loaded category from ONE fresh plaza fetch —
    /// not one fetch per shelf. A failed fetch keeps the old
    /// snapshots (with cleared timestamps, so the next shelf
    /// appear refetches) instead of blanking the page — but the
    /// failure is surfaced now (b49fix3 P2-10 exploreRefreshFailed
    /// + banner), never silent. A successful fetch also recomputes
    /// exploreAvailableCategories (loadExploreAll sets it before
    /// completing), so a category that went empty loses its chip
    /// and shelf; on failure the old categories stay, consistent
    /// with the kept snapshots.
    func refreshExplore() {
        exploreRefreshFailed = false
        let loadedCategories = Set(exploreSnapshots.keys)
        exploreLoadedAt.removeAll()
        exploreAllLoadedAt = nil
        exploreAllPlaylists = []
        if loadedCategories.isEmpty {
            loadExploreCategory("全部")
            return
        }
        loadExploreAll { [weak self] all in
            guard let self = self else { return }
            guard let all = all else {
                self.exploreRefreshFailed = true
                return
            }
            self.exploreRefreshFailed = false
            for category in loadedCategories {
                self.exploreLoadedAt[category] = Date()
                self.exploreSnapshots[category] = Self.filterExplorePlaylists(all, category: category)
            }
        }
    }

    /// Categories with a non-empty result from the loaded plaza
    /// data, in exploreCategories order. Pure: the same filter
    /// the shelves use, so a listed category can never render an
    /// empty shelf. "全部" is always listed (it is the merged
    /// list itself — its failure state carries the retry).
    /// No NetEase category/tag playlist endpoint exists in the
    /// codebase (plaza is the only per-platform list source), so
    /// no new network API is invented here: availability is
    /// computed from the merged plaza data already loaded.
    static func availableCategories(from all: [PlaylistSummary]) -> [String] {
        exploreCategories.filter { category in
            category == "全部" || !filterExplorePlaylists(all, category: category).isEmpty
        }
    }

    /// Merged plaza from all four platforms, loaded once and
    /// shared by every category snapshot.
    private func loadExploreAll(completion: @escaping ([PlaylistSummary]?) -> Void) {
        let now = Date()
        if let loadedAt = exploreAllLoadedAt,
           now.timeIntervalSince(loadedAt) < Self.exploreSnapshotTTL,
           !exploreAllPlaylists.isEmpty {
            completion(exploreAllPlaylists)
            return
        }
        let platforms: [MusicPlatform] = [.wy, .tx, .kg, .kw]
        var merged: [PlaylistSummary] = []
        var settled = 0
        for platform in platforms {
            MusicPlaylistImportAPI.shared.plaza(platform: platform) { [weak self] playlists in
                guard let self = self else { return }
                merged.append(contentsOf: playlists)
                settled += 1
                if settled == platforms.count {
                    if merged.isEmpty {
                        completion(nil)
                    } else {
                        self.exploreAllPlaylists = merged
                        self.exploreAllLoadedAt = Date()
                        self.exploreAvailableCategories = Self.availableCategories(from: merged)
                        completion(merged)
                    }
                }
            }
        }
    }

    /// Category matching on the playlist's own text (name / desc /
    /// creator). "全部" = everything; "推荐歌单" = NetEase plaza;
    /// "精品歌单" = most-played; the rest match their keyword.
    /// A category with no textual match shows an honest empty
    /// state — no playlist is invented for it.
    static func filterExplorePlaylists(_ all: [PlaylistSummary], category: String) -> [PlaylistSummary] {
        switch category {
        case "全部":
            return all
        case "推荐歌单":
            return all.filter { $0.platform == .wy }
        case "精品歌单":
            return all.filter { $0.playCount >= 100_000 }.sorted { $0.playCount > $1.playCount }
        default:
            return all.filter {
                $0.name.localizedCaseInsensitiveContains(category)
                    || $0.desc.localizedCaseInsensitiveContains(category)
                    || $0.creator.localizedCaseInsensitiveContains(category)
            }
        }
    }

    // MARK: - Plaza

    func setPlazaPlatform(_ platform: MusicPlatform) {
        plazaPlatform = platform
        MusicLibraryStore.setPlazaPlatform(platform)
        loadPlaza()
    }

    /// Fetch the plaza for the current platform ONLY — never silently
    /// fall back to another platform. The API completion runs on the
    /// main queue (MusicAPITransport), same as the charts view model.
    func loadPlaza() {
        plazaLoading = true
        plazaFailed = false
        let platform = plazaPlatform
        MusicPlaylistImportAPI.shared.plaza(platform: platform) { [weak self] playlists in
            guard let self = self else { return }
            // A9: a stale response must never overwrite the current
            // platform's list — fast platform switches (wy -> tx)
            // used to show the wrong platform's results and clear
            // the loading flag of the newer request. The search
            // view model already guards its completions this way;
            // the plaza did not.
            guard platform == self.plazaPlatform else { return }
            self.plazaLoading = false
            self.plazaPlaylists = playlists
            self.plazaFailed = playlists.isEmpty
        }
    }

    // MARK: - Listen report

    func recomputeReport() {
        report = MusicDiscoveryViewModel.computeReport(events: listenLog, range: reportRange)
    }

    /// Pure report computation (Flutter ListenReport.compute). `now`
    /// is injectable so tests are deterministic.
    static func computeReport(events: [ListenEvent], range: ListenReportRange, now: Date = Date()) -> ListenReport {
        let calendar = Calendar.current
        let refDay = calendar.startOfDay(for: now)
        let startMs: Int
        switch range {
        case .week:
            // Monday 00:00 local (Calendar weekday: 1 = Sunday).
            let weekday = calendar.component(.weekday, from: now)
            let daysBack = (weekday + 5) % 7
            let monday = calendar.date(byAdding: .day, value: -daysBack, to: refDay) ?? refDay
            startMs = Int(monday.timeIntervalSince1970 * 1000)
        case .month:
            let comps = calendar.dateComponents([.year, .month], from: now)
            let first = calendar.date(from: comps) ?? refDay
            startMs = Int(first.timeIntervalSince1970 * 1000)
        case .all:
            startMs = 0
        }
        let filtered = startMs > 0 ? events.filter { $0.at >= startMs } : events
        var totalSeconds = 0
        var bySong: [String: (song: MusicSong, plays: Int)] = [:]
        var songOrder: [String] = []
        var byArtist: [String: Int] = [:]
        var byPlatform: [MusicPlatform: Int] = [:]
        var byDay: [String: Int] = [:]
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        for event in filtered {
            totalSeconds += event.dur
            let key = "\(event.platform.rawValue)|\(event.songId)"
            let song = MusicSong(
                songId: event.songId, title: event.title, artist: event.artist,
                cover: event.cover, platform: event.platform, dur: event.totalDur
            )
            if let existing = bySong[key] {
                bySong[key] = (song: existing.song, plays: existing.plays + 1)
            } else {
                bySong[key] = (song: song, plays: 1)
                songOrder.append(key)
            }
            let artist = event.artist.isEmpty ? "—" : event.artist
            byArtist[artist] = (byArtist[artist] ?? 0) + 1
            byPlatform[event.platform] = (byPlatform[event.platform] ?? 0) + 1
            let day = dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(event.at) / 1000))
            byDay[day] = (byDay[day] ?? 0) + 1
        }
        // No force unwraps: songOrder is built only from keys
        // inserted into bySong in the same loop, but a lookup can
        // still only be trusted via compactMap — one future edit
        // to the loop would otherwise turn this into a crash.
        let topSongs = songOrder
            .compactMap { bySong[$0] }
            .sorted { $0.plays > $1.plays }
            .map { ListenReportTopSong(song: $0.song, plays: $0.plays) }
        let topArtists = byArtist
            .sorted { $0.value > $1.value }
            .map { ListenReportTopArtist(artist: $0.key, plays: $0.value) }
        let topPlatforms = byPlatform
            .sorted { $0.value > $1.value }
            .map { ListenReportTopPlatform(platform: $0.key, plays: $0.value) }
        var perDay: [ListenReportDayCount] = []
        if range == .all {
            var byMonth: [String: Int] = [:]
            for (day, plays) in byDay {
                let month = String(day.prefix(7))
                byMonth[month] = (byMonth[month] ?? 0) + plays
            }
            let months = byMonth.keys.sorted().suffix(12)
            // B5: the label was only the month ("11"), so the same
            // month in two years collided on the chart. Keep the
            // full yyyy-MM key.
            perDay = months.map { ListenReportDayCount(label: $0, plays: byMonth[$0] ?? 0) }
        } else {
            perDay = byDay.keys.sorted().map { ListenReportDayCount(label: String($0.suffix(5)), plays: byDay[$0] ?? 0) }
        }
        return ListenReport(
            totalSeconds: totalSeconds,
            totalPlays: filtered.count,
            topSongs: topSongs,
            topArtists: topArtists,
            topPlatforms: topPlatforms,
            perDay: perDay
        )
    }
}

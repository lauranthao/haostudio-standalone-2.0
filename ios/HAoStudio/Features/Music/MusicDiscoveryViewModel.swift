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

    private var listenLog: [ListenEvent] = []

    init() {
        plazaPlatform = MusicLibraryStore.plazaPlatform()
        dailyDayKey = musicDayKey(of: Date())
    }

    func reload() {
        listenLog = MusicLibraryStore.getListenLog()
        reloadDaily()
        recomputeReport()
    }

    // MARK: - Daily

    func reloadDaily() {
        let dayKey = musicDayKey(of: Date())
        dailyDayKey = dayKey
        if let cached = MusicLibraryStore.dailyTracks(for: dayKey) {
            dailyTracks = cached
            return
        }
        let picks = MusicRadio.dailyPicks(
            listenLog: listenLog,
            favourites: MusicLibraryStore.favSongs(),
            recent: MusicLibraryStore.getRecent(),
            playlistTracks: MusicLibraryStore.getLists().flatMap { $0.tracks },
            dislikedIds: MusicLibraryStore.fmDislikedIds(),
            dayKey: dayKey
        )
        dailyTracks = picks
        if !picks.isEmpty {
            MusicLibraryStore.saveDailyTracks(picks, for: dayKey)
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
        let topSongs = songOrder
            .sorted { bySong[$0]!.plays > bySong[$1]!.plays }
            .map { ListenReportTopSong(song: bySong[$0]!.song, plays: bySong[$0]!.plays) }
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

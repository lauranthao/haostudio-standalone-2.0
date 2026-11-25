// HAo Studio 2.0 — music home view model (S2-C leg).
//
// The music tab root (Flutter MusicTabPage): feature shelf, 我的歌单,
// 最近播放. All data is local (playlists / favourites / recent /
// downloads / local files); the shelf tiles navigate to the search,
// daily, plaza, charts and report pages.
//
// b45-b (Coda §3.1 home discovery): the home also carries the
// discovery sections — recommended playlists (plaza, NetEase),
// discovered songs (local top songs), charts preview (NetEase
// toplist, tracks lazy-loaded per chart), discovered playlists /
// radio (plaza, other platforms), new albums + recommended
// artists (derived from the local library — no login, no
// server-side "for you"). Caching (Coda §3.1): home 1800s,
// discovery 900s, chart preview 1800s; a failed section keeps
// its old content and offers a retry; manual refresh bypasses
// the cache. Regional hot (Coda §3.1): 华语/欧美/日本/韩国 four
// keyword legs in parallel, interleaved, deduped by id, capped
// at 100 songs — a partial region failure still shows the rest.

import Combine
import SwiftUI

@MainActor
final class MusicHomeViewModel: ObservableObject {
    @Published private(set) var playlists: [UserPlaylist] = []
    @Published private(set) var recent: [MusicSong] = []
    @Published private(set) var favCount = 0
    @Published private(set) var downloadCount = 0
    @Published private(set) var localCount = 0
    @Published var playlistsExpanded = true
    @Published var recentExpanded = true

    // MARK: - Discovery (b45-b)

    /// Recommended playlists (plaza, NetEase). Home preview
    /// caps at 18 cards (Coda §3.1); the plaza page shows all.
    @Published private(set) var recommendedPlaylists: [PlaylistSummary] = []
    @Published private(set) var recommendedLoading = false
    @Published private(set) var recommendedFailed = false
    /// Discovered songs: local top songs, capped at 36 (Coda §3.1).
    @Published private(set) var discoveredSongs: [MusicSong] = []
    /// Regional hot: four parallel legs interleaved, deduped,
    /// capped at 100 (Coda §3.1).
    @Published private(set) var regionalHotSongs: [MusicSong] = []
    @Published private(set) var regionalLoading = false
    /// Discovered playlists / radio: plaza from the other
    /// platforms, for the two-row shelf.
    @Published private(set) var discoveredPlaylists: [PlaylistSummary] = []
    @Published private(set) var discoveredLoading = false
    /// Charts preview (NetEase toplist).
    @Published private(set) var charts: [PlaylistSummary] = []
    @Published private(set) var chartsLoading = false
    @Published private(set) var chartsFailed = false
    /// Per-chart top tracks (lazy, cached 1800s).
    @Published private(set) var chartTracks: [String: [MusicSong]] = [:]
    /// New albums, derived from the local library (album name +
    /// artist, newest year first).
    @Published private(set) var newAlbums: [AlbumSummary] = []
    /// Recommended artists: most-listened artists, cover from a
    /// local copy of their songs.
    @Published private(set) var recommendedArtists: [ArtistSummary] = []

    private var cancellables = Set<AnyCancellable>()
    private var homeLoadedAt: Date? = nil
    private var regionalLoadedAt: Date? = nil
    private var chartTracksLoadedAt: [String: Date] = [:]
    private var chartTracksLoading: Set<String> = []

    /// Coda cache TTLs (§3.1): home 1800s, discovery 900s,
    /// chart preview 1800s.
    static let homeCacheTTL: TimeInterval = 1800
    static let discoveryCacheTTL: TimeInterval = 900
    static let chartPreviewCacheTTL: TimeInterval = 1800

    init() {
        playlistsExpanded = MusicLibraryStore.playlistsExpanded()
        recentExpanded = MusicLibraryStore.recentExpanded()
        // 最近播放实时更新 (chen 2026-11-20): a song can start
        // from any page while the user stays on this tab, so the
        // list reloads the moment the store changes — not only
        // when the tab re-appears (onAppear reload stays as well).
        NotificationCenter.default.publisher(for: .haoMusicRecentChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    func reload() {
        reloadLocal()
        loadDiscovery(force: false)
    }

    /// Manual refresh: bypasses every cache (Coda §3.1).
    func refresh() {
        homeLoadedAt = nil
        regionalLoadedAt = nil
        chartTracksLoadedAt = [:]
        reloadLocal()
        loadDiscovery(force: true)
    }

    func reloadLocal() {
        playlists = MusicLibraryStore.getLists()
        recent = MusicLibraryStore.getRecent()
        favCount = MusicLibraryStore.favIds().count
        downloadCount = MusicLibraryStore.getDownloads().count
        localCount = MusicLibraryStore.localMusicFiles().count
        rebuildLocalDiscovery()
    }

    func setPlaylistsExpanded(_ value: Bool) {
        playlistsExpanded = value
        MusicLibraryStore.setPlaylistsExpanded(value)
    }

    func setRecentExpanded(_ value: Bool) {
        recentExpanded = value
        MusicLibraryStore.setRecentExpanded(value)
    }

    // MARK: - Local discovery (no network, no login)

    private func rebuildLocalDiscovery() {
        let log = MusicLibraryStore.getListenLog()
        discoveredSongs = Array(MusicRadio.mostPlayedSongs(from: log, limit: 36))
        // New albums: local songs grouped by album, newest year
        // first, then most tracks.
        var byAlbum: [String: (name: String, artist: String, cover: String, year: Int, count: Int)] = [:]
        for song in MusicLibraryStore.favSongs() + recent {
            guard !song.album.isEmpty else { continue }
            let key = "\(song.album)|\(song.artist)"
            if var entry = byAlbum[key] {
                entry.count += 1
                entry.year = max(entry.year, song.albumYear)
                if entry.cover.isEmpty { entry.cover = song.cover }
                byAlbum[key] = entry
            } else {
                byAlbum[key] = (song.album, song.artist, song.cover, song.albumYear, 1)
            }
        }
        newAlbums = byAlbum.values
            .sorted { ($0.year, $0.count) > ($1.year, $1.count) }
            .prefix(18)
            .map {
                AlbumSummary(
                    id: "", name: $0.name, cover: $0.cover, artist: $0.artist,
                    publishTime: 0, songCount: $0.count, platform: .wy)
            }
        // Recommended artists: most-listened, cover from a local song.
        var coverByArtist: [String: String] = [:]
        for song in MusicLibraryStore.favSongs() + recent where !song.artist.isEmpty {
            if coverByArtist[song.artist] == nil, !song.cover.isEmpty {
                coverByArtist[song.artist] = song.cover
            }
        }
        recommendedArtists = MusicRadio.topArtists(from: log, limit: 18).map { name in
            ArtistSummary(
                id: "", name: name, cover: coverByArtist[name] ?? "",
                musicSize: 0, albumSize: 0, platform: .wy, alias: "")
        }
    }

    // MARK: - Network discovery (plaza + charts + regional)

    private func loadDiscovery(force: Bool) {
        let now = Date()
        if !force, let loadedAt = homeLoadedAt, now.timeIntervalSince(loadedAt) < Self.homeCacheTTL {
            return
        }
        homeLoadedAt = now
        loadRecommendedPlaylists()
        loadDiscoveredPlaylists()
        loadCharts()
        loadRegionalHot(force: force)
    }

    func loadRecommendedPlaylists() {
        recommendedLoading = true
        MusicPlaylistImportAPI.shared.plaza(platform: .wy) { [weak self] playlists in
            guard let self = self else { return }
            self.recommendedLoading = false
            // A failed section keeps its old content (Coda §3.1):
            // only overwrite on a non-empty answer.
            if !playlists.isEmpty {
                self.recommendedPlaylists = playlists
                self.recommendedFailed = false
            } else if self.recommendedPlaylists.isEmpty {
                self.recommendedFailed = true
            }
        }
    }

    func loadDiscoveredPlaylists() {
        discoveredLoading = true
        let platforms: [MusicPlatform] = [.tx, .kg, .kw]
        var merged: [PlaylistSummary] = []
        var settled = 0
        for platform in platforms {
            MusicPlaylistImportAPI.shared.plaza(platform: platform) { [weak self] playlists in
                guard let self = self else { return }
                merged.append(contentsOf: playlists)
                settled += 1
                if settled == platforms.count {
                    self.discoveredLoading = false
                    if !merged.isEmpty { self.discoveredPlaylists = merged }
                }
            }
        }
    }

    func loadCharts() {
        chartsLoading = true
        MusicAPIClient.shared.getJson(
            "https://music.163.com/api/toplist",
            headers: ["User-Agent": MusicUA.value],
            timeout: 15
        ) { [weak self] json in
            guard let self = self else { return }
            self.chartsLoading = false
            guard let json = json else {
                if self.charts.isEmpty { self.chartsFailed = true }
                return
            }
            let parsed = MusicChartsViewModel.parseNeteaseCharts(json)
            if !parsed.isEmpty {
                self.charts = parsed
                self.chartsFailed = false
            } else if self.charts.isEmpty {
                self.chartsFailed = true
            }
        }
    }

    /// Lazy per-chart top tracks (10 per chart, Coda §3.1),
    /// cached 1800s. A chart that already has cached tracks is
    /// never re-fetched for the same home visit.
    func loadChartTracks(chart: PlaylistSummary) {
        let now = Date()
        if let loadedAt = chartTracksLoadedAt[chart.id],
           now.timeIntervalSince(loadedAt) < Self.chartPreviewCacheTTL,
           chartTracks[chart.id] != nil {
            return
        }
        guard !chartTracksLoading.contains(chart.id) else { return }
        chartTracksLoading.insert(chart.id)
        MusicPlaylistImportAPI.shared.importWyPlaylist(chart.id) { [weak self] imported in
            guard let self = self else { return }
            self.chartTracksLoading.remove(chart.id)
            self.chartTracksLoadedAt[chart.id] = Date()
            self.chartTracks[chart.id] = Array(imported.tracks.map(MusicSong.init(from:)).prefix(10))
        }
    }

    /// Regional hot (Coda §3.1): 华语 / 欧美 / 日本 / 韩国 four
    /// keyword legs in parallel, interleaved so no single region
    /// fills the first screen, deduped by identityKey, capped at
    /// 100. A region that fails still leaves the other three.
    /// Each leg runs NetEase + QQ via `searchOne` (exactly one
    /// completion per leg — the streaming `search` has no "done"
    /// flag, so it cannot drive a settled count).
    func loadRegionalHot(force: Bool) {
        let now = Date()
        if !force, let loadedAt = regionalLoadedAt,
           now.timeIntervalSince(loadedAt) < Self.discoveryCacheTTL {
            return
        }
        regionalLoading = true
        let keywords = ["华语热门", "欧美热门", "日本热门", "韩国热门"]
        let platforms: [MusicPlatform] = [.wy, .tx]
        var legs: [[MusicSong]] = Array(repeating: [], count: keywords.count)
        var settled = 0
        let total = keywords.count * platforms.count
        for (index, keyword) in keywords.enumerated() {
            for platform in platforms {
                MusicSearchAPI.shared.searchOne(platform: platform, keyword: keyword) { [weak self] tracks in
                    guard let self = self else { return }
                    legs[index].append(contentsOf: tracks.map(MusicSong.init(from:)))
                    settled += 1
                    if settled == total {
                        self.regionalLoading = false
                        self.regionalLoadedAt = Date()
                        var seen = Set<String>()
                        var merged: [MusicSong] = []
                        var round = 0
                        while merged.count < 100 {
                            var addedInRound = false
                            for leg in legs {
                                guard round < leg.count else { continue }
                                let song = leg[round]
                                if seen.insert(song.identityKey).inserted {
                                    merged.append(song)
                                    addedInRound = true
                                    if merged.count >= 100 { break }
                                }
                            }
                            if !addedInRound { break }
                            round += 1
                        }
                        if !merged.isEmpty { self.regionalHotSongs = merged }
                    }
                }
            }
        }
    }
}

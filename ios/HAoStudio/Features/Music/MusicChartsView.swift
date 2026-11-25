// HAo Studio 2.0 — music charts (S3-C leg).
//
// Replaces the S2 placeholder ("排行榜暂未接入"). Charts are
// NetEase toplist ids (Flutter music_api.dart neteaseCharts +
// charts_page.dart): `GET music.163.com/api/toplist` returns the
// chart list, the four canonical charts (飙升/新歌/原创/热歌) pin
// first, the rest keep API order. A chart IS a NetEase playlist
// id — tapping one opens its tracks via the existing playlist
// import (MusicPlaylistImportAPI.importWyPlaylist). No new track
// loading path, no new protocol.
//
// Platform gate (Flutter parity): there is no QQ/Kugou/Kuwo
// chart source in this app, so when the search platform is not
// NetEase the page says so honestly instead of showing NetEase
// charts under another platform's name.

import SwiftUI

@MainActor
final class MusicChartsViewModel: ObservableObject {
    @Published private(set) var charts: [PlaylistSummary] = []
    @Published private(set) var isLoading = true
    @Published private(set) var failed = false
    /// Top tracks per chart for the grid cards (b45-b, Coda
    /// §3.9: the card shows the top 3). Lazy, cached 1800s.
    @Published private(set) var topTracks: [String: [MusicSong]] = [:]

    private var topTracksLoadedAt: [String: Date] = [:]
    private var topTracksLoading: Set<String> = []
    /// Chart list itself, cached 1800s (b45-g, Coda §3.1 榜单
    /// 1800s — b45-b only cached the per-card top tracks).
    private var chartsLoadedAt: Date? = nil

    static let topTracksCacheTTL: TimeInterval = 1800
    static let chartsCacheTTL: TimeInterval = 1800

    /// The four canonical charts, pinned first in this order.
    static let pinnedNames = ["飙升榜", "新歌榜", "原创榜", "热歌榜"]

    /// NetEase toplist payload -> [PlaylistSummary]. Pure function
    /// (Flutter parseNeteaseCharts, verbatim field mapping).
    static func parseNeteaseCharts(_ json: [String: Any]) -> [PlaylistSummary] {
        let all = MusicAPIJSON.asList(json["list"]).compactMap { entry -> PlaylistSummary? in
            let summary = PlaylistSummary(
                id: MusicAPIJSON.asString(entry["id"]),
                name: MusicAPIJSON.asString(entry["name"]),
                cover: MusicAPIJSON.asString(entry["coverImgUrl"]),
                trackCount: MusicAPIJSON.asInt(entry["trackCount"]),
                desc: MusicAPIJSON.asString(entry["updateFrequency"]),
                platform: .wy)
            guard !summary.id.isEmpty, !summary.name.isEmpty else { return nil }
            return summary
        }
        var head: [PlaylistSummary] = []
        var rest = all
        for name in pinnedNames {
            if let index = rest.firstIndex(where: { $0.name == name }) {
                head.append(rest.remove(at: index))
            }
        }
        return head + rest
    }

    /// Chart list, cached 1800s (b45-g). A fresh cache answers
    /// instantly on re-appear; pull-to-refresh forces a refetch.
    /// A failed load never stamps the cache, so retry still works.
    func load(force: Bool = false) {
        if !force, let loadedAt = chartsLoadedAt,
           Date().timeIntervalSince(loadedAt) < Self.chartsCacheTTL,
           !charts.isEmpty {
            return
        }
        isLoading = true
        failed = false
        MusicAPIClient.shared.getJson(
            "https://music.163.com/api/toplist",
            headers: ["User-Agent": MusicUA.value],
            timeout: 15
        ) { [weak self] json in
            guard let self = self else { return }
            self.isLoading = false
            guard let json = json else {
                self.failed = true
                return
            }
            let parsed = Self.parseNeteaseCharts(json)
            self.charts = parsed
            self.failed = parsed.isEmpty
            if !parsed.isEmpty {
                self.chartsLoadedAt = Date()
            }
        }
    }

    /// Lazy top-3 tracks for one chart card, cached 1800s.
    func loadTopTracks(chart: PlaylistSummary) {
        let now = Date()
        if let loadedAt = topTracksLoadedAt[chart.id],
           now.timeIntervalSince(loadedAt) < Self.topTracksCacheTTL,
           topTracks[chart.id] != nil {
            return
        }
        guard !topTracksLoading.contains(chart.id) else { return }
        topTracksLoading.insert(chart.id)
        MusicPlaylistImportAPI.shared.importWyPlaylist(chart.id) { [weak self] imported in
            guard let self = self else { return }
            self.topTracksLoading.remove(chart.id)
            self.topTracksLoadedAt[chart.id] = Date()
            self.topTracks[chart.id] = Array(imported.tracks.map(MusicSong.init(from:)).prefix(3))
        }
    }
}

struct MusicChartsView: View {
    @StateObject private var viewModel = MusicChartsViewModel()

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            // A6: the old gate read `musicSearchPlatform` and told
            // the user to "switch the platform back to NetEase on
            // the search page" — but the search page has no platform
            // selector (chen's rule) and nothing in the music slice
            // writes that key, so a migrated non-wy value locked
            // charts out forever with an impossible instruction.
            // Charts are NetEase data; the gate is gone.
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.failed {
                VStack {
                    MusicEmptyState(
                        icon: "list.number",
                        title: "排行榜加载失败",
                        note: "网易云没有返回榜单，稍后再试。",
                        onRetry: { viewModel.load() }
                    )
                    Spacer()
                }
            } else {
                // b45-b (Coda §3.9): adaptive grid (min 300, max
                // 420, group spacing 24, section spacing 20).
                // Each card: 110×110 r8 cover, padding 12,
                // primary 0.04 background, r12; name secondary
                // semibold, update frequency caption tertiary,
                // top 3 as "1. 歌名 - 歌手" caption secondary.
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 24),
                        ],
                        spacing: 20
                    ) {
                        ForEach(viewModel.charts, id: \.id) { chart in
                            NavigationLink(destination: MusicChartDetailView(chart: chart)) {
                                chartCard(chart)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .haoBottomChromeContentPadding()
                    // b45-g (Coda §8.2): pull-to-refresh bypasses
                    // the 1800s chart-list cache.
                    .refreshable { viewModel.load(force: true) }
                }
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("排行榜")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.load() }
    }

    private func chartCard(_ chart: PlaylistSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            MusicCoverView(urlString: chart.cover, size: 110, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 6) {
                Text(chart.name)
                    .font(.haoSubheadStrong)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                if !chart.desc.isEmpty {
                    Text(chart.desc)
                        .font(.haoCaption)
                        .foregroundStyle(theme.textMuted)
                        .lineLimit(1)
                }
                if let tracks = viewModel.topTracks[chart.id] {
                    ForEach(Array(tracks.prefix(3).enumerated()), id: \.element.id) { index, song in
                        Text("\(index + 1). \(song.title) - \(song.artist)")
                            .font(.haoCaption)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in
                            MusicSkeletonBlock(width: 160, height: 11)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onAppear { viewModel.loadTopTracks(chart: chart) }
    }

    private func chartSubtitle(_ chart: PlaylistSummary) -> String {
        var parts: [String] = []
        if !chart.desc.isEmpty { parts.append(chart.desc) }
        if chart.trackCount > 0 { parts.append("\(chart.trackCount) 首") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - One chart's tracks (a NetEase playlist id)

@MainActor
final class MusicChartDetailViewModel: ObservableObject {
    @Published private(set) var tracks: [MusicSong] = []
    @Published private(set) var isLoading = true
    @Published private(set) var note = ""

    private let chart: PlaylistSummary

    init(chart: PlaylistSummary) {
        self.chart = chart
    }

    func load() {
        isLoading = true
        MusicPlaylistImportAPI.shared.importWyPlaylist(chart.id) { [weak self] imported in
            guard let self = self else { return }
            self.isLoading = false
            self.tracks = imported.tracks.map(MusicSong.init(from:))
            if imported.missing > 0 {
                self.note = "其中 \(imported.missing) 首未能导入"
            } else if !imported.note.isEmpty {
                self.note = imported.note
            }
        }
    }
}

struct MusicChartDetailView: View {
    var chart: PlaylistSummary

    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var viewModel: MusicChartDetailViewModel

    @Environment(\.haoTheme) private var theme

    init(chart: PlaylistSummary) {
        self.chart = chart
        _viewModel = StateObject(wrappedValue: MusicChartDetailViewModel(chart: chart))
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.tracks.isEmpty {
                MusicEmptyState(
                    icon: "list.number",
                    title: "榜单曲目加载失败",
                    note: "该榜单没有返回曲目，稍后再试。",
                    onRetry: { viewModel.load() }
                )
            } else {
                List {
                    if !viewModel.note.isEmpty {
                        Section {
                            Text(viewModel.note)
                                .font(.haoFootnote)
                                .foregroundStyle(theme.textSecondary)
                        }
                        .listRowBackground(theme.scaffoldBackground)
                    }
                    Section {
                        ForEach(Array(viewModel.tracks.enumerated()), id: \.element.id) { index, song in
                            MusicSongRow(
                                song: song,
                                isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
                                trackNumber: index + 1,
                                onTap: {
                                    playerVM.play(song: song, in: viewModel.tracks, startAt: index)
                                }
                            )
                            .listRowBackground(theme.scaffoldBackground)
                            .listRowSeparatorTint(theme.hairline)
                        }
                    }
                }
                .haoBottomChromePadding()
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle(chart.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MusicCapsuleButton(icon: "play.fill", label: "播放全部", enabled: !viewModel.tracks.isEmpty) {
                    playerVM.playAll(viewModel.tracks)
                }
            }
        }
        .onAppear { viewModel.load() }
    }
}

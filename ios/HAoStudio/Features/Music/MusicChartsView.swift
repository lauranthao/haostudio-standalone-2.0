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

    func load() {
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
                        note: "网易云没有返回榜单，稍后再试。"
                    )
                    Spacer()
                }
            } else {
                List {
                    ForEach(Array(viewModel.charts.enumerated()), id: \.element.id) { index, chart in
                        NavigationLink(destination: MusicChartDetailView(chart: chart)) {
                            HStack(spacing: 12) {
                                // Apple Music charts: a big bold rank
                                // number leads each row.
                                Text("\(index + 1)")
                                    .font(.haoDetailTitle)
                                    .foregroundStyle(theme.textPrimary)
                                    .frame(width: 28, alignment: .center)
                                MusicCoverView(urlString: chart.cover, size: 56, cornerRadius: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(chart.name)
                                        .font(.haoCalloutStrong)
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                    Text(chartSubtitle(chart))
                                        .font(.haoRowSubtitle)
                                        .foregroundStyle(theme.textSecondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                        .listRowBackground(theme.scaffoldBackground)
                        .listRowSeparatorTint(theme.hairline)
                    }
                }
                .haoBottomChromePadding()
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("排行榜")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.load() }
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
                    note: "该榜单没有返回曲目，稍后再试。"
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
                                },
                                onToggleFav: {
                                    _ = MusicLibraryStore.toggleFav(song)
                                },
                                onAddToPlaylist: nil
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

// HAo Studio 2.0 — music discovery pages (S2-C leg).
//
// Daily picks, plaza, charts, listen report.
//
// - Daily: cached per day (hao_daily.json); a missing day is built
//   from local data (most-played + top artists, seeded by day).
// - Listen report: pure local aggregation of the listen log
//   (Flutter ListenReport.compute).
// - Plaza (S7-A): real platform data via
//   MusicPlaylistImportAPI.plaza(platform:) (wy / tx / kg / kw,
//   S3) — one platform at a time, never a silent fallback.
//   Tapping a row opens its tracks through the existing playlist
//   import (same pattern as MusicChartDetailView). A platform that
//   answers with nothing shows the honest "暂无推荐" empty state
//   with the reason — no fake rows are invented.
// - Charts moved to MusicChartsView.swift (S3-C): NetEase toplist
//   via the existing music API, no new protocol.

import SwiftUI

// MARK: - Daily

struct MusicDailyView: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var discoveryVM = MusicDiscoveryViewModel()

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            if discoveryVM.dailyTracks.isEmpty {
                MusicEmptyState(
                    icon: "calendar", title: "今天还没有推荐",
                    note: "先收藏几首歌或播几首歌，每日推荐会从你听过的歌里挑。"
                )
            } else {
                List {
                    ForEach(Array(discoveryVM.dailyTracks.enumerated()), id: \.element.id) { index, song in
                        MusicSongRow(
                            song: song,
                            isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
                            onTap: {
                                playerVM.play(song: song, in: discoveryVM.dailyTracks, startAt: index)
                            },
                            onToggleFav: {
                                _ = MusicLibraryStore.toggleFav(song)
                            }
                        )
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
        .navigationTitle("每日推荐")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MusicCapsuleButton(icon: "play.fill", label: "播放全部", enabled: !discoveryVM.dailyTracks.isEmpty) {
                    playerVM.playAll(discoveryVM.dailyTracks)
                }
            }
        }
        .onAppear { discoveryVM.reload() }
    }
}

// MARK: - Plaza

/// Play-count text for a plaza row. Pure function (unit-tested).
func plazaPlayCountText(_ count: Int) -> String {
    if count <= 0 { return "" }
    if count >= 100_000_000 {
        return String(format: "%.1f亿次播放", Double(count) / 100_000_000)
    }
    if count >= 10_000 {
        return String(format: "%.1f万次播放", Double(count) / 10_000)
    }
    return "\(count)次播放"
}

struct MusicPlazaView: View {
    @StateObject private var discoveryVM = MusicDiscoveryViewModel()

    @Environment(\.haoTheme) private var theme

    private let platforms: [MusicPlatform] = [.wy, .tx, .kw, .kg]

    var body: some View {
        VStack(spacing: 0) {
            Picker("平台", selection: Binding(
                get: { discoveryVM.plazaPlatform },
                set: { discoveryVM.setPlazaPlatform($0) }
            )) {
                ForEach(platforms, id: \.rawValue) { platform in
                    Text(platform.displayName).tag(platform)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            plazaContent
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("歌单广场")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            discoveryVM.reload()
            discoveryVM.loadPlaza()
        }
    }

    private var plazaContent: some View {
        Group {
            if discoveryVM.plazaLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if discoveryVM.plazaFailed {
                MusicEmptyState(
                    icon: "square.grid.2x2", title: "暂无推荐",
                    note: "\(discoveryVM.plazaPlatform.displayName)没有返回歌单，稍后再试或换个平台。"
                )
                Spacer()
            } else {
                plazaList
            }
        }
    }

    private var plazaList: some View {
        List {
            ForEach(discoveryVM.plazaPlaylists, id: \.id) { summary in
                NavigationLink(destination: MusicPlazaDetailView(summary: summary)) {
                    plazaRow(summary)
                }
                .listRowBackground(theme.scaffoldBackground)
                .listRowSeparatorTint(theme.hairline)
            }
        }
        .haoBottomChromePadding()
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func plazaRow(_ summary: PlaylistSummary) -> some View {
        HStack(spacing: 12) {
            MusicCoverView(urlString: summary.cover, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(plazaSubtitle(summary))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private func plazaSubtitle(_ summary: PlaylistSummary) -> String {
        var parts: [String] = []
        if !summary.creator.isEmpty { parts.append(summary.creator) }
        let plays = plazaPlayCountText(summary.playCount)
        if !plays.isEmpty { parts.append(plays) }
        if summary.trackCount > 0 { parts.append("\(summary.trackCount) 首") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - One plaza playlist's tracks (imported, not saved)

@MainActor
final class MusicPlazaDetailViewModel: ObservableObject {
    @Published private(set) var tracks: [MusicSong] = []
    @Published private(set) var isLoading = true
    @Published private(set) var note = ""

    private let summary: PlaylistSummary

    init(summary: PlaylistSummary) {
        self.summary = summary
    }

    func load() {
        isLoading = true
        // One platform at a time, same import paths as the pasted-link
        // import — never a silent fallback to another platform. The
        // completion label is written out: with progress + completion
        // closures a trailing closure would bind to the wrong one.
        switch summary.platform {
        case .wy:
            MusicPlaylistImportAPI.shared.importWyPlaylist(summary.id, completion: { [weak self] imported in
                self?.finish(imported)
            })
        case .tx:
            MusicPlaylistImportAPI.shared.importTxPlaylist(summary.id, completion: { [weak self] imported in
                self?.finish(imported)
            })
        case .kw:
            MusicPlaylistImportAPI.shared.importKwPlaylist(summary.id, completion: { [weak self] imported in
                self?.finish(imported)
            })
        case .kg:
            MusicPlaylistImportAPI.shared.importKgPlaylist(summary.id, completion: { [weak self] imported in
                self?.finish(imported)
            })
        case .mg:
            isLoading = false
            note = "该平台暂不支持歌单浏览。"
        }
    }

    private func finish(_ imported: ImportedPlaylist) {
        isLoading = false
        tracks = imported.tracks.map(MusicSong.init(from:))
        if imported.missing > 0 {
            note = "其中 \(imported.missing) 首未能导入"
        } else if !imported.note.isEmpty {
            note = imported.note
        }
    }
}

struct MusicPlazaDetailView: View {
    var summary: PlaylistSummary

    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var viewModel: MusicPlazaDetailViewModel

    @Environment(\.haoTheme) private var theme

    init(summary: PlaylistSummary) {
        self.summary = summary
        _viewModel = StateObject(wrappedValue: MusicPlazaDetailViewModel(summary: summary))
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.tracks.isEmpty {
                MusicEmptyState(
                    icon: "music.note.list",
                    title: "歌单曲目加载失败",
                    note: viewModel.note.isEmpty ? "该歌单没有返回曲目，稍后再试。" : viewModel.note
                )
            } else {
                List {
                    if !viewModel.note.isEmpty {
                        Section {
                            Text(viewModel.note)
                                .font(.system(size: 13))
                                .foregroundStyle(theme.textSecondary)
                        }
                        .listRowBackground(theme.scaffoldBackground)
                    }
                    Section {
                        ForEach(Array(viewModel.tracks.enumerated()), id: \.element.id) { index, song in
                            MusicSongRow(
                                song: song,
                                isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
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
        .navigationTitle(summary.name)
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

// MARK: - Listen report

struct MusicListenReportView: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var discoveryVM = MusicDiscoveryViewModel()

    @Environment(\.haoTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("范围", selection: $discoveryVM.reportRange) {
                    ForEach(ListenReportRange.allCases, id: \.rawValue) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                summaryCard
                topSongsSection
                topArtistsSection
                topPlatformsSection
                perDaySection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .haoBottomChromePadding()
        .background(theme.scaffoldBackground)
        .navigationTitle("听歌报告")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { discoveryVM.reload() }
    }

    private var summaryCard: some View {
        let report = discoveryVM.report
        let hours = report.totalSeconds / 3600
        let minutes = (report.totalSeconds % 3600) / 60
        return HStack(spacing: 0) {
            summaryStat(value: "\(report.totalPlays)", label: "播放次数")
            Divider().background(theme.hairline)
            summaryStat(value: hours > 0 ? "\(hours)小时\(minutes)分" : "\(minutes)分", label: "收听时长")
            Divider().background(theme.hairline)
            summaryStat(value: "\(report.topSongs.count)", label: "听过的歌")
        }
        .padding(.vertical, 16)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func summaryStat(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var topSongsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最常听")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            if discoveryVM.report.topSongs.isEmpty {
                Text("这段时间还没有收听记录。")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(Array(discoveryVM.report.topSongs.prefix(10).enumerated()), id: \.element.song.id) { rank, top in
                    HStack(spacing: 12) {
                        Text("\(rank + 1)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(theme.accent)
                            .frame(width: 20)
                        MusicSongRow(
                            song: top.song,
                            showPlatformBadge: false,
                            isPlaying: playerVM.currentSong?.identityKey == top.song.identityKey && playerVM.isPlaying,
                            onTap: {
                                let songs = discoveryVM.report.topSongs.map { $0.song }
                                if let index = songs.firstIndex(where: { $0.identityKey == top.song.identityKey }) {
                                    playerVM.play(song: top.song, in: songs, startAt: index)
                                }
                            }
                        )
                        Text("\(top.plays) 次")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
        }
    }

    private var topArtistsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最常听的歌手")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            if discoveryVM.report.topArtists.isEmpty {
                Text("这段时间还没有收听记录。")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(discoveryVM.report.topArtists.prefix(10), id: \.artist) { top in
                    HStack {
                        Text(top.artist)
                            .font(.system(size: 15))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text("\(top.plays) 次")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var topPlatformsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("来源平台")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            if discoveryVM.report.topPlatforms.isEmpty {
                Text("这段时间还没有收听记录。")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(discoveryVM.report.topPlatforms, id: \.platform) { top in
                    HStack {
                        Text(top.platform.displayName)
                            .font(.system(size: 15))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text("\(top.plays) 次")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var perDaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(discoveryVM.reportRange == .all ? "按月" : "按天")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            if discoveryVM.report.perDay.isEmpty {
                Text("这段时间还没有收听记录。")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(discoveryVM.report.perDay, id: \.label) { day in
                    HStack {
                        Text(day.label)
                            .font(.system(size: 15))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text("\(day.plays) 次")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

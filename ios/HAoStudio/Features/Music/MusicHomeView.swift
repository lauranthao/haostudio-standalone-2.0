// HAo Studio 2.0 — music tab home (S2-C leg).
//
// Replaces the MusicPlaceholderView. Mirrors Flutter MusicTabPage:
// large title 音乐, feature shelf (搜歌 / 每日推荐 / 歌单广场 /
// 排行榜 / 听歌报告), 私人漫游 + 心动模式 row, 我的歌单 section,
// 最近播放 section + 播放全部. The MiniPlayerBar lives in
// MainTabView (above the tab bar), not here — one bar only.
//
// Tile colours: the Flutter tiles used red/pink gradients. Music UI
// must not use red (iron law — red is LIVE badge / recording only),
// so the tiles are theme-accent glass cards instead of coloured
// gradients. Same layout, same destinations, no red.

import SwiftUI

/// Music navigation destinations (NavigationStack path).
enum MusicDestination: Hashable {
    case search
    case daily
    case plaza
    case charts
    case report
    case favourites
    case downloads
    case localMusic
    case playlist(String)
    case equalizer
}

struct MusicHomeView: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var homeVM = MusicHomeViewModel()
    @State private var path: [MusicDestination] = []
    @State private var fmEmptyNote = false

    @Environment(\.haoTheme) private var theme

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Scroll anchor for the bottom chrome (b35 tab-bar
                    // link): drives minimize / restore as this tab scrolls.
                    HaoChromeScrollAnchor()
                    featureShelf
                    fmRow
                        .padding(.top, 12)
                    playlistsSection
                        .padding(.top, 12)
                    recentSection
                        .padding(.top, 12)
                    Spacer(minLength: 16)
                }
                .padding(.horizontal, 24)
            }
            .haoBottomChromePadding()
            .haoChromeScrollTracking()
            .background(theme.scaffoldBackground)
            .navigationTitle("音乐")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: MusicDestination.self) { destination in
                destinationView(destination)
            }
            .onAppear { homeVM.reload() }
            .alert("本地曲库还是空的", isPresented: $fmEmptyNote) {
                Button("知道了", role: .cancel) { }
            } message: {
                Text("先收藏几首歌或播几首歌，私人漫游和心动模式才能从本地生成歌单。")
            }
        }
    }

    // MARK: - Feature shelf

    private var featureShelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                featureTile(icon: "magnifyingglass", title: "搜歌") {
                    path.append(.search)
                }
                featureTile(icon: "calendar", title: "每日推荐") {
                    path.append(.daily)
                }
                featureTile(icon: "square.grid.2x2", title: "歌单广场") {
                    path.append(.plaza)
                }
                featureTile(icon: "list.number", title: "排行榜") {
                    path.append(.charts)
                }
                featureTile(icon: "chart.bar", title: "听歌报告") {
                    path.append(.report)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func featureTile(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Spacer()
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
            }
            .padding(16)
            .frame(width: 148, height: 128, alignment: .leading)
            .background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: - FM / heartbeat

    private var fmRow: some View {
        HStack(spacing: 16) {
            featureTileWide(icon: "waveform", title: "私人漫游") { startFM() }
            featureTileWide(icon: "heart.fill", title: "心动模式") { startHeartbeat() }
        }
    }

    private func featureTileWide(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(theme.surfaceStrong, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func startFM() {
        let favourites = MusicLibraryStore.favSongs()
        let recent = MusicLibraryStore.getRecent()
        let top = MusicRadio.mostPlayedSongs(from: MusicLibraryStore.getListenLog(), limit: 20)
        let queue = MusicRadio.fmQueue(
            favourites: favourites, recent: recent, listenTop: top,
            dislikedIds: MusicLibraryStore.fmDislikedIds(),
            seed: musicDayKey(of: Date())
        )
        if queue.isEmpty {
            fmEmptyNote = true
            return
        }
        playerVM.playAll(queue)
    }

    private func startHeartbeat() {
        let favourites = MusicLibraryStore.favSongs()
        let queue = MusicRadio.heartbeatQueue(favourites: favourites, seed: musicDayKey(of: Date()))
        if queue.isEmpty {
            fmEmptyNote = true
            return
        }
        playerVM.playAll(queue)
    }

    // MARK: - 我的歌单

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MusicSectionHeader(
                title: "我的歌单",
                expanded: homeVM.playlistsExpanded,
                onToggle: { homeVM.setPlaylistsExpanded(!homeVM.playlistsExpanded) }
            )
            .padding(.vertical, 10)
            if homeVM.playlistsExpanded {
                VStack(spacing: 0) {
                    libraryRow(
                        icon: "heart.fill", title: "我的收藏",
                        subtitle: homeVM.favCount == 0 ? "还没有收藏的歌曲" : "\(homeVM.favCount) 首歌曲"
                    ) { path.append(.favourites) }
                    divider
                    libraryRow(
                        icon: "arrow.down.circle.fill", title: "已下载",
                        subtitle: homeVM.downloadCount == 0 ? "还没有下载" : "\(homeVM.downloadCount) 首歌曲"
                    ) { path.append(.downloads) }
                    divider
                    libraryRow(
                        icon: "folder.fill", title: "本地音乐",
                        subtitle: homeVM.localCount == 0 ? "还没有导入本地文件" : "\(homeVM.localCount) 个文件"
                    ) { path.append(.localMusic) }
                    ForEach(homeVM.playlists) { list in
                        divider
                        libraryRow(
                            icon: "music.note.list", title: list.name,
                            subtitle: "\(list.trackCount) 首歌曲"
                        ) { path.append(.playlist(list.id)) }
                    }
                    if homeVM.playlists.isEmpty {
                        divider
                        MusicEmptyState(icon: "music.note", title: "还没有歌单")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    private var divider: some View {
        Divider()
            .background(theme.hairline)
            // Inset to the text column (icon 28 + spacing 12),
            // not to the row edge — the iOS grouped-list rule.
            .padding(.leading, 40)
    }

    private func libraryRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textMuted)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 最近播放

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MusicSectionHeader(
                title: "最近播放",
                expanded: homeVM.recentExpanded,
                onToggle: { homeVM.setRecentExpanded(!homeVM.recentExpanded) },
                trailing: {
                    AnyView(MusicCapsuleButton(
                        icon: "play.fill", label: "播放全部",
                        enabled: !homeVM.recent.isEmpty
                    ) {
                        playerVM.playAll(homeVM.recent)
                    })
                }
            )
            .padding(.vertical, 10)
            if homeVM.recentExpanded {
                if homeVM.recent.isEmpty {
                    MusicEmptyState(icon: "clock", title: "还没有播放记录", note: "播过的歌会出现在这里。")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(homeVM.recent.prefix(20).enumerated()), id: \.element.id) { index, song in
                            MusicSongRow(
                                song: song,
                                isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
                                onTap: {
                                    playerVM.play(song: song, in: homeVM.recent, startAt: index)
                                },
                                onToggleFav: {
                                    _ = MusicLibraryStore.toggleFav(song)
                                    homeVM.reload()
                                },
                                onAddToPlaylist: nil
                            )
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Destinations

    @ViewBuilder
    private func destinationView(_ destination: MusicDestination) -> some View {
        switch destination {
        case .search:
            MusicSearchView()
        case .daily:
            MusicDailyView()
        case .plaza:
            MusicPlazaView()
        case .charts:
            MusicChartsView()
        case .report:
            MusicListenReportView()
        case .favourites:
            MusicFavouritesView()
        case .downloads:
            MusicDownloadsView()
        case .localMusic:
            MusicLocalMusicView()
        case .playlist(let id):
            MusicPlaylistDetailView(listId: id)
        case .equalizer:
            MusicEqualizerView()
        }
    }
}

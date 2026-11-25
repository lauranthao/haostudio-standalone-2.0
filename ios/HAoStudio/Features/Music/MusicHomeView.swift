// HAo Studio 2.0 — music tab home (S2-C leg).
//
// Replaces the MusicPlaceholderView. Mirrors Flutter MusicTabPage:
// large title 音乐, feature shelf (搜歌 / 每日推荐 / 歌单广场 /
// 排行榜 / 听歌报告), 私人漫游 + 心动模式 row, 我的歌单 section,
// 最近播放 section + 播放全部. The MiniPlayerBar lives in
// MainTabView (above the tab bar), not here — one bar only.
//
// b40: music home restyled after Sonar + vibrdrome (chen
// 2026-11-25: "那些界面你都抄了吗，我怎么看不出变化" —
// b39's copies landed on video home / live room / crossfade /
// the home title, music home itself never moved, so this page
// now visibly changes): vibrdrome 2-column category grid,
// Sonar library-style playlist cards with counts, 28pt section
// headers with a Sonar-style count, playing EQ on the current
// recent card. Same 5 entries, same destinations, same local
// FM / heartbeat (no login anywhere). Tile colours are dynamic
// system colours (never a hardcoded hex, never purple, never
// red — red stays LIVE-only), so they read in light and dark.
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
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Scroll anchor for the bottom chrome (b35 tab-bar
                        // link): drives minimize / restore as this tab scrolls.
                        // It also carries this tab's scroll-to-top id (chrome
                        // O1): a reselect scrolls the proxy to it.
                        HaoChromeScrollAnchor()
                            .id(HaoTabScrollTop.id(for: .music))
                        featureShelf
                        fmRow
                            .padding(.top, 12)
                        playlistsSection
                            .padding(.top, 12)
                        recentSection
                            .padding(.top, 12)
                        Spacer(minLength: 16)
                    }
                    .padding(.horizontal, 20)
                    .haoBottomChromeContentPadding()
                }
                .haoChromeScrollTracking()
                .haoReselectScrollToTop(tab: .music, proxy: proxy)
                .haoBackdropLayer()
                .haoTabBackground()
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
    }

    // MARK: - Feature shelf (b40: vibrdrome 2-column grid)

    /// vibrdrome Library: two columns of tall category tiles —
    /// coloured SF icon + bold label on a surface card, ~64pt
    /// high, radius ~16. Was a horizontal scroll of 148x128
    /// accent-soft tiles; the grid is visible at a glance and
    /// needs no sideways scrolling. All 5 entries stay, same
    /// destinations; the 5th tile spans the full width.
    private var featureShelf: some View {
        VStack(spacing: 12) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ],
                spacing: 12
            ) {
                featureTile(icon: "magnifyingglass", title: "搜歌", tint: .blue) {
                    path.append(.search)
                }
                featureTile(icon: "calendar", title: "每日推荐", tint: .orange) {
                    path.append(.daily)
                }
                featureTile(icon: "square.grid.2x2", title: "歌单广场", tint: .green) {
                    path.append(.plaza)
                }
                featureTile(icon: "list.number", title: "排行榜", tint: .teal) {
                    path.append(.charts)
                }
            }
            featureTile(icon: "chart.bar", title: "听歌报告", tint: .cyan) {
                path.append(.report)
            }
        }
    }

    private func featureTile(icon: String, title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))  // icon size, not text
                    .foregroundStyle(tint)
                Text(title)
                    .font(.haoBodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(MusicPressScaleStyle())
        .accessibilityLabel(title)
    }

    // MARK: - FM / heartbeat (b40: vibrdrome-style wide cards)

    /// Same two local tiles (no login anywhere), restyled to the
    /// vibrdrome card: coloured icon in a tinted square + bold
    /// label, surface card, radius 16, 80pt high (was 96pt
    /// surfaceStrong with a bare accent icon).
    private var fmRow: some View {
        HStack(spacing: 12) {
            featureTileWide(icon: "waveform", title: "私人漫游", tint: .blue) { startFM() }
            featureTileWide(icon: "heart.fill", title: "心动模式", tint: .orange) { startHeartbeat() }
        }
    }

    private func featureTileWide(icon: String, title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))  // icon size, not text
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(title)
                    .font(.haoBodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 80)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(MusicPressScaleStyle())
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

    // MARK: - 我的歌单 (b40: Sonar 资料库式卡片)

    /// Sonar 资料库: each row is its own big rounded card — 56pt
    /// thumbnail + title + count ("N 首歌曲") + chevron, radius
    /// ~18, surface card. Was one grouped card with hairline
    /// dividers and a bare 28pt icon. Same rows, same
    /// destinations (我的收藏 / 已下载 / 本地音乐 / 歌单).
    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MusicSectionHeader(
                title: "我的歌单",
                expanded: homeVM.playlistsExpanded,
                onToggle: { homeVM.setPlaylistsExpanded(!homeVM.playlistsExpanded) },
                titleFont: .haoPageTitle
            )
            .padding(.vertical, 10)
            if homeVM.playlistsExpanded {
                VStack(spacing: 12) {
                    libraryRow(
                        icon: "heart.fill", tint: .orange, title: "我的收藏",
                        subtitle: homeVM.favCount == 0 ? "还没有收藏的歌曲" : "\(homeVM.favCount) 首歌曲"
                    ) { path.append(.favourites) }
                    libraryRow(
                        icon: "arrow.down.circle.fill", tint: .green, title: "已下载",
                        subtitle: homeVM.downloadCount == 0 ? "还没有下载" : "\(homeVM.downloadCount) 首歌曲"
                    ) { path.append(.downloads) }
                    libraryRow(
                        icon: "folder.fill", tint: .teal, title: "本地音乐",
                        subtitle: homeVM.localCount == 0 ? "还没有导入本地文件" : "\(homeVM.localCount) 个文件"
                    ) { path.append(.localMusic) }
                    ForEach(homeVM.playlists) { list in
                        libraryRow(
                            icon: "music.note.list", tint: .blue, title: list.name,
                            subtitle: "\(list.trackCount) 首歌曲"
                        ) { path.append(.playlist(list.id)) }
                    }
                    if homeVM.playlists.isEmpty {
                        MusicEmptyState(icon: "music.note", title: "还没有歌单")
                    }
                }
            }
        }
    }

    private func libraryRow(icon: String, tint: Color, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))  // icon size, not text
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.haoBodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Text(subtitle)
                        .font(.haoFootnote)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.haoFootnoteStrong)
                    .foregroundStyle(theme.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 最近播放 (b40: Sonar count + playing EQ)

    /// Sonar-style header: the section title carries its count
    /// ("N 首歌曲") on the right, next to the working 播放全部.
    /// No "查看全部" — there is no recent-plays full list
    /// reachable from this tab (MyRecentPlaysView lives on the
    /// 我的 tab), and a dead button is worse than none. Cards
    /// keep the Apple Music shelf, plus the vibrdrome playing
    /// indicator (animated EQ on the cover of the song that is
    /// actually playing).
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MusicSectionHeader(
                title: "最近播放",
                expanded: homeVM.recentExpanded,
                onToggle: { homeVM.setRecentExpanded(!homeVM.recentExpanded) },
                trailing: {
                    AnyView(HStack(spacing: 10) {
                        if !homeVM.recent.isEmpty {
                            Text("\(homeVM.recent.count) 首歌曲")
                                .font(.haoFootnote)
                                .foregroundStyle(theme.textSecondary)
                        }
                        MusicCapsuleButton(
                            icon: "play.fill", label: "播放全部",
                            enabled: !homeVM.recent.isEmpty
                        ) {
                            playerVM.playAll(homeVM.recent)
                        }
                    })
                },
                titleFont: .haoPageTitle
            )
            .padding(.vertical, 10)
            if homeVM.recentExpanded {
                if homeVM.recent.isEmpty {
                    MusicEmptyState(icon: "clock", title: "还没有播放记录", note: "播过的歌会出现在这里。")
                } else {
                    // Apple Music home: recent plays are a horizontal
                    // shelf of square album cards (cover on top,
                    // title + artist below), not a vertical song
                    // list. Same songs, same tap-to-play, same
                    // 播放全部 — only the layout follows Apple.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(Array(homeVM.recent.prefix(20).enumerated()), id: \.element.id) { index, song in
                                recentCard(
                                    song: song,
                                    index: index,
                                    isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying
                                )
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    /// One recent-play card on the horizontal shelf: square cover
    /// (148, radius 12), title 15 semibold + artist 13 below —
    /// Apple Music's 最近播放 card. The playing song's title takes
    /// the accent, and (b40, vibrdrome) its cover carries the
    /// animated EQ — visible at a glance which card is playing.
    /// Long-press opens the same shared song menu as
    /// the rows (build 36, item 12); a "…" button does not fit
    /// the card layout.
    private func recentCard(song: MusicSong, index: Int, isPlaying: Bool) -> some View {
        MusicSongMenuHost(song: song, onFavToggled: { homeVM.reload() }) { menu in
            Button(action: {
                playerVM.play(song: song, in: homeVM.recent, startAt: index)
            }) {
                VStack(alignment: .leading, spacing: 6) {
                    MusicCoverView(urlString: song.cover, size: 148, cornerRadius: 12)
                        .overlay(alignment: .bottomLeading) {
                            if isPlaying {
                                MusicPlayingEQView()
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(Color.black.opacity(0.55), in: Capsule())
                                    .padding(8)
                            }
                        }
                    Text(song.title.isEmpty ? "未知歌曲" : song.title)
                        .font(.haoSubheadStrong)
                        .foregroundStyle(isPlaying ? theme.accentText : theme.textPrimary)
                        .lineLimit(1)
                    Text(song.artist.isEmpty ? "未知艺人" : song.artist)
                        .font(.haoFootnote)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                .frame(width: 148, alignment: .leading)
            }
            .buttonStyle(.plain)
            .contextMenu { menu.menuContent() }
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

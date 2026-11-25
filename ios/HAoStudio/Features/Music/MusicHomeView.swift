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
// b45-b (Coda §3.1 home reorder): order is feature cards
// (daily / FM / heartbeat / radar, local only) → recommended
// playlists → discovered songs → charts → discovered
// playlists / radio → new albums → recommended artists, then
// the local 我的歌单 + 最近播放 sections. Section spacing 32,
// top padding 12, bottom 12. No system large title (in-content
// title, b42). All discovery data is local or public platform
// data — the login-gated home blocks (daily / radar / FM /
// heartbeat / liked recommendations) are replaced by local
// equivalents (local playlists / likes / recent / local seeds).

// b47-home (chen 2026-11-25: "这些推荐什么的不可以单独放
// 一个页面吗" / "不然点我的歌单都要翻到最下面"): the home keeps
// search + 我的歌单 + 最近播放 at the top; every recommendation
// section lives on its own 推荐 page (MusicRecommendView, below),
// reached from the home with one tap on the 推荐 row. Nothing was
// removed — the tiles, 推荐歌单， 发现歌曲， 榜单， 分地区热门，
// 发现歌单， 新专辑， 推荐歌手 and the 探索歌单分类 entry all
// moved there verbatim, same destinations.

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
    case fm
    case heartbeat
    case explore
    case recommend
}

struct MusicHomeView: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var homeVM = MusicHomeViewModel()
    @State private var path: [MusicDestination] = []
    @State private var fmEmptyNote = false

    @Environment(\.haoTheme) private var theme


    var body: some View {
        // b49 (chen 2026-11-25 build 48: the white strip was
        // still there): b48's page-background fade painted an
        // opaque solid scaffold colour over the photo — the strip
        // just changed painting method. The root is now exactly
        // HomeView's (HomeView.swift:44-45): a bare
        // NavigationStack, nothing covering the top. HomeView
        // proves "nothing covering it" is correct — rows sliding
        // under the status text need no protection here.
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
                        // b42: in-content large title (HomeView's
                        // homeHeader pattern). The system large
                        // title is unreliable on chen's iPhone Air
                        // in this setup — build 38 it did not render
                        // at all on Home, build 41 it renders ~300pt
                        // too low on Music, drawn OVER the card grid
                        // A title row in the scroll content is
                        // ordinary VStack layout: it sits above the
                        // cards with normal spacing and cannot
                        // overlap them. b49fix3 P1-18: the tab
                        // root's horizontal padding is 24, same
                        // as Home.
                        musicHeader
                        searchEntry
                            .padding(.top, 12)
                        recommendEntry
                            .padding(.top, 8)
                        playlistsSection
                            .padding(.top, HaoLayout.sectionTopSpacing)
                        recentSection
                            .padding(.top, HaoLayout.sectionTopSpacing)
                        Spacer(minLength: 12)
                    }
                    .padding(.horizontal, HaoLayout.pageMargin)
                    .haoBottomChromeContentPadding()
                }
                .haoChromeScrollTracking()
                .haoReselectScrollToTop(tab: .music, proxy: proxy)
                .haoBackdropLayer()
                .haoTabBackground()
                .refreshable { homeVM.refresh() }
            }
            // b42: no system nav bar on this root (see
            // musicHeader above — the system large title
            // overlaps the cards on chen's phone). Pushed
            // pages keep their own bars and back buttons.
            .toolbar(.hidden, for: .navigationBar)
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

    // MARK: - In-content large title (b42)

    /// Same 34pt bold title as HomeView's homeHeader, as a row
    /// in the scroll content — it can never vanish or overlap
    /// the cards, because it is ordinary VStack layout.
    private var musicHeader: some View {
        Text("音乐")
            .font(.haoScreenTitle)
            .foregroundStyle(theme.textPrimary)
            .padding(.top, 12)
    }

    // MARK: - Search entry

    /// The search box lives in the page (Coda §5.4): a tappable
    /// field look that opens the search page. No dead entry — it
    /// always navigates. b49fix4 P1-1/P2-4: the placeholder is
    /// textSecondary (textMuted on this fill failed AA in dark
    /// mode + light wallpaper) and the fill is theme.surface +
    /// hairline — the same entry grammar as recommendEntry below.
    private var searchEntry: some View {
        Button(action: { path.append(.search) }) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.textSecondary)
                Text("搜索歌曲、歌手、专辑、歌单")
                    .font(.haoSubhead)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: HaoLayout.searchFieldHeight)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: HaoLayout.cornerMedium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: HaoLayout.cornerMedium, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("搜索")
    }

    /// Entry to the 推荐 page (b47-home): all recommendation content
    /// lives there now, so the home stays short — search, 我的歌单，
    /// 最近播放. Same card grammar as the old 探索歌单分类 row, which
    /// moved into the 推荐 page.
    private var recommendEntry: some View {
        Button(action: { path.append(.recommend) }) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(theme.accentText)
                Text("推荐")
                    .font(.haoSubheadStrong)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textMuted)
            }
            .padding(.horizontal, 16)
            .frame(height: HaoLayout.detailSearchHeight)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: HaoLayout.cornerMedium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: HaoLayout.cornerMedium, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("推荐")
    }

    // MARK: - 我的歌单 (kept: local, collapsible)

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MusicSectionHeader(
                title: "我的歌单",
                expanded: homeVM.playlistsExpanded,
                onToggle: { homeVM.setPlaylistsExpanded(!homeVM.playlistsExpanded) }
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
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(tint, in: RoundedRectangle(cornerRadius: HaoLayout.cornerMedium, style: .continuous))
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
            .background(theme.surface, in: RoundedRectangle(cornerRadius: HaoLayout.cornerXLarge, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: HaoLayout.cornerXLarge, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 最近播放 (kept: Sonar count + playing EQ)

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
                            // b46: recent plays are a reloadable place.
                            playerVM.playAll(homeVM.recent, source: PlaySource(kind: .recent, id: "recent"), sourceDisplayName: "最近播放")
                        }
                    })
                },
            )
            .padding(.vertical, 10)
            if homeVM.recentExpanded {
                if homeVM.recent.isEmpty {
                    MusicEmptyState(icon: "clock", title: "还没有播放记录", note: "播过的歌会出现在这里。")
                } else {
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

    private func recentCard(song: MusicSong, index: Int, isPlaying: Bool) -> some View {
        MusicSongMenuHost(song: song, onFavToggled: { homeVM.reload() }) { menu in
            Button(action: {
                playerVM.play(song: song, in: homeVM.recent, startAt: index, source: PlaySource(kind: .recent, id: "recent"), sourceDisplayName: "最近播放")
            }) {
                VStack(alignment: .leading, spacing: 6) {
                    MusicCoverView(urlString: song.cover, size: 148, cornerRadius: HaoLayout.cornerMedium)
                        .overlay(alignment: .bottomLeading) {
                            if isPlaying {
                                MusicPlayingEQView()
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .haoDarkGlassCapsule(darkness: 0.55)
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
        case .fm:
            MusicFMView(mode: .fm)
        case .heartbeat:
            MusicFMView(mode: .heartbeat)
        case .explore:
            MusicExploreView()
        case .recommend:
            MusicRecommendView(homeVM: homeVM, path: $path, fmEmptyNote: $fmEmptyNote)
        }
    }
}

// MARK: - 推荐 page (b47-home)

/// 推荐 page: all recommendation content moved off the Music home
/// (chen 2026-11-25: "这些推荐什么的不可以单独放一个页面吗" /
/// "不然点我的歌单都要翻到最下面"). The home keeps search +
/// 我的歌单 + 最近播放 at the top; this page holds the 4 feature
/// tiles, 推荐歌单， 发现歌曲， 榜单， 分地区热门， 发现歌单，
/// 新专辑 and 推荐歌手, plus the 探索歌单分类 entry at the top.
/// Every destination is the same as before — nothing was removed,
/// only moved. Pushed from the Music home via .recommend; it uses
/// the system nav bar (inline "推荐" + back button) like every
/// other pushed music page, so the status-bar zone is covered by
/// the bar itself. Shares the home's view model, so the data is
/// already loaded; pull-to-refresh re-fetches it.
struct MusicRecommendView: View {
    @ObservedObject var homeVM: MusicHomeViewModel
    @Binding var path: [MusicDestination]
    @Binding var fmEmptyNote: Bool

    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @Environment(\.haoTheme) private var theme

    /// b48 (chen 2026-11-25 build 47: "这些太丑了 你不知道收进去
    /// 吗"): each chart folds into its header; expanded chart ids
    /// live here. Default: all collapsed, so the 榜单 section is
    /// three compact headers instead of 30 inline rows. The full
    /// charts page (榜单 >) and each chart's detail page (from the
    /// charts page) are unchanged.
    @State private var expandedCharts: Set<String> = []

    var body: some View {
        GeometryReader { geo in
            let availableWidth = max(geo.size.width - 40, 200)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    exploreEntry
                        .padding(.top, 12)
                    featureCards(width: availableWidth)
                        .padding(.top, HaoLayout.discoverySectionTopSpacing)
                    recommendedPlaylistsSection(width: availableWidth)
                        .padding(.top, HaoLayout.discoverySectionTopSpacing)
                    discoveredSongsSection(width: availableWidth)
                        .padding(.top, HaoLayout.discoverySectionTopSpacing)
                    chartsSection
                        .padding(.top, HaoLayout.discoverySectionTopSpacing)
                    regionalHotSection(width: availableWidth)
                        .padding(.top, HaoLayout.discoverySectionTopSpacing)
                    discoveredPlaylistsSection(width: availableWidth)
                        .padding(.top, HaoLayout.discoverySectionTopSpacing)
                    newAlbumsSection(width: availableWidth)
                        .padding(.top, HaoLayout.discoverySectionTopSpacing)
                    recommendedArtistsSection
                        .padding(.top, HaoLayout.discoverySectionTopSpacing)
                    Spacer(minLength: 12)
                }
                .padding(.horizontal, HaoLayout.pushedPageMargin)
                .haoBottomChromeContentPadding()
            }
            .refreshable { homeVM.refresh() }
            .background(theme.scaffoldBackground)
            .navigationTitle("推荐")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Explore entry: the 26-category explore page (Coda §3.9).
    private var exploreEntry: some View {
        Button(action: { path.append(.explore) }) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(theme.accentText)
                Text("探索歌单分类")
                    .font(.haoSubheadStrong)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textMuted)
            }
            .padding(.horizontal, 16)
            .frame(height: HaoLayout.detailSearchHeight)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: HaoLayout.cornerMedium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: HaoLayout.cornerMedium, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("探索歌单分类")
    }

    // MARK: - Feature cards (Coda §3.1, local only)

    /// Feature cards: 每日推荐 / 私人漫游 / 心动模式 / 我的雷达
    /// (local listen report). Horizontal paging shelf, 2 rows,
    /// cards 178² (computed down to fit the real width),
    /// spacing 16. Every card is local — no login-gated block.
    private func featureCards(width: CGFloat) -> some View {
        let cardSize = min(178, (width - 16) / 2)
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(
                rows: [
                    GridItem(.fixed(cardSize), spacing: 16),
                    GridItem(.fixed(cardSize), spacing: 16),
                ],
                spacing: 16
            ) {
                MusicFeatureCollageCard(
                    icon: "calendar", title: "每日推荐", subtitle: "每天更新",
                    palette: [.orange, .yellow], size: cardSize, isDateCard: true
                ) { path.append(.daily) }
                MusicFeatureCollageCard(
                    icon: "waveform", title: "私人漫游", subtitle: "本地漫游",
                    palette: [.blue, .teal], size: cardSize
                ) { startFM() }
                MusicFeatureCollageCard(
                    icon: "heart.fill", title: "心动模式", subtitle: "从喜欢出发",
                    palette: [.pink, .orange], size: cardSize
                ) { startHeartbeat() }
                MusicFeatureCollageCard(
                    icon: "chart.bar", title: "听歌报告", subtitle: "你的收听总结",
                    palette: [.green, .teal], size: cardSize
                ) { path.append(.report) }
            }
            .padding(.vertical, 6)
        }
        .frame(height: cardSize * 2 + 16 + 12)
    }

    private func startFM() {
        if MusicRadio.fmQueue(
            favourites: MusicLibraryStore.favSongs(),
            recent: MusicLibraryStore.getRecent(),
            listenTop: MusicRadio.mostPlayedSongs(from: MusicLibraryStore.getListenLog(), limit: 20),
            dislikedIds: MusicLibraryStore.fmDislikedIds(),
            seed: musicDayKey(of: Date())
        ).isEmpty {
            fmEmptyNote = true
            return
        }
        path.append(.fm)
    }

    private func startHeartbeat() {
        if MusicRadio.heartbeatQueue(
            favourites: MusicLibraryStore.favSongs(),
            seed: musicDayKey(of: Date())
        ).isEmpty {
            fmEmptyNote = true
            return
        }
        path.append(.heartbeat)
    }

    // MARK: - Recommended playlists (Coda §3.1)

    /// 3 rows per column, column width from the real width
    /// (available width − 20 peek, never a hardcoded 357).
    /// Home preview caps at 18 cards; the plaza page shows all.
    private func recommendedPlaylistsSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // b49fix2 A8: this shelf is NetEase's plaza, so "全部"
            // opens the plaza on wy — the 发现歌单 shelf below opens
            // it on tx (the first of its merged platforms). Two
            // shelves, two different plaza landings.
            MusicCodaSectionHeader(title: "推荐歌单") {
                MusicLibraryStore.setPlazaPlatform(.wy)
                path.append(.plaza)
            }
            if homeVM.recommendedLoading && homeVM.recommendedPlaylists.isEmpty {
                HStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { _ in MusicSkeletonCard() }
                }
            } else if homeVM.recommendedPlaylists.isEmpty {
                MusicEmptyState(
                    icon: "square.grid.2x2", title: "暂无推荐歌单",
                    note: "歌单广场没有返回内容，稍后再试。",
                    onRetry: { homeVM.loadRecommendedPlaylists() }
                )
            } else {
                let columnWidth = width - 20
                let columns = Array(Array(homeVM.recommendedPlaylists.prefix(18)).chunked(into: 3))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                            VStack(spacing: 16) {
                                ForEach(column, id: \.id) { summary in
                                    NavigationLink(destination: MusicPlazaDetailView(summary: summary)) {
                                        playlistMiniRow(summary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                // A short column keeps the shelf
                                // height steady — an empty slot is
                                // better than a jumping layout.
                                ForEach(0..<(3 - column.count), id: \.self) { _ in
                                    Color.clear.frame(width: columnWidth, height: 56)
                                }
                            }
                            .frame(width: columnWidth, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private func playlistMiniRow(_ summary: PlaylistSummary) -> some View {
        HStack(spacing: 12) {
            MusicCoverView(urlString: summary.cover, size: 56, cornerRadius: HaoLayout.cornerSmall)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(plazaMiniSubtitle(summary))
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textMuted)
        }
        .contentShape(Rectangle())
    }

    private func plazaMiniSubtitle(_ summary: PlaylistSummary) -> String {
        var parts: [String] = []
        if !summary.creator.isEmpty { parts.append(summary.creator) }
        let plays = musicCompactCount(summary.playCount)
        if !plays.isEmpty { parts.append("\(plays)次播放") }
        if summary.trackCount > 0 { parts.append("\(summary.trackCount) 首") }
        return parts.joined(separator: " · ")
    }

    /// Grid-card meta (b47-home): plays + track count only. The
    /// mini rows (plazaMiniSubtitle) can afford the creator, but
    /// in a 178pt card "creator · plays · tracks" truncates
    /// ("51…") and a single-glyph creator renders as a tofu box —
    /// the card meta must be fully visible, so the creator stays
    /// out of it.
    private func plazaCardSubtitle(_ summary: PlaylistSummary) -> String {
        var parts: [String] = []
        let plays = musicCompactCount(summary.playCount)
        if !plays.isEmpty { parts.append("\(plays)次播放") }
        if summary.trackCount > 0 { parts.append("\(summary.trackCount) 首") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Discovered songs (Coda §3.1 发现歌曲行)

    /// Local top songs, 36 cap. Columns of 4 compact rows in a
    /// horizontal shelf — tap plays in place.
    private func discoveredSongsSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MusicCodaSectionHeader(title: "发现歌曲")
            if homeVM.discoveredSongs.isEmpty {
                MusicEmptyState(
                    icon: "music.note", title: "还没有发现歌曲",
                    note: "播过的歌会出现在这里。"
                )
            } else {
                let columnWidth = width - 20
                let columns = Array(Array(homeVM.discoveredSongs.prefix(36)).chunked(into: 4))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                            VStack(spacing: 1) {
                                ForEach(Array(column.enumerated()), id: \.element.id) { index, song in
                                    discoverSongCell(
                                        song: song,
                                        play: {
                                            let songs = homeVM.discoveredSongs
                                            if let at = songs.firstIndex(where: { $0.identityKey == song.identityKey }) {
                                                // b46: discovered list is a reloadable place.
                                                playerVM.play(song: song, in: songs, startAt: at, source: PlaySource(kind: .discover, id: "discovered"), sourceDisplayName: "发现歌曲")
                                            }
                                        }
                                    )
                                    .frame(width: columnWidth, alignment: .leading)
                                }
                            }
                            .frame(width: columnWidth, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private func discoverSongCell(song: MusicSong, play: @escaping () -> Void) -> some View {
        Button(action: play) {
            HStack(spacing: 12) {
                MusicCoverView(urlString: song.cover, size: 48, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title.isEmpty ? "未知歌曲" : song.title)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(song.artist.isEmpty ? "未知艺人" : song.artist)
                        .font(.haoSubhead)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if song.dur > 0 {
                    Text(musicDurationText(seconds: song.dur))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.textMuted)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Charts (Coda §3.1 榜单)

    /// Three charts on the home, each with its top 10 rows
    /// (lazy-loaded, cached 1800s). A horizontal paged 3-charts-
    /// per-page layout does not fit a phone: three 10-row charts
    /// stacked are ~800pt tall per page, so the home shows the
    /// three charts stacked vertically instead — same 3 charts,
    /// same 10 rows each, no paging. The charts page has all of
    /// them.
    private var chartsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MusicCodaSectionHeader(title: "榜单") { path.append(.charts) }
            if homeVM.chartsLoading && homeVM.charts.isEmpty {
                VStack(spacing: 1) {
                    ForEach(0..<10, id: \.self) { _ in MusicSkeletonRow() }
                }
            } else if homeVM.charts.isEmpty {
                MusicEmptyState(
                    icon: "list.number", title: "排行榜加载失败",
                    note: "网易云没有返回榜单，稍后再试。",
                    onRetry: { homeVM.loadCharts() }
                )
            } else {
                VStack(spacing: 24) {
                    ForEach(homeVM.charts.prefix(3), id: \.id) { chart in
                        chartBlock(chart: chart)
                    }
                }
            }
        }
    }

    /// b48: a chart is a foldable block — its header (cover + name
    /// + source + chevron) is always visible; tap it to expand /
    /// collapse the top-10 rows with animation. Default collapsed.
    /// The header no longer navigates to the chart detail (that
    /// page is one tap away from the 榜单 > charts page); the
    /// header tap is the fold, so the two never fight.
    private func chartBlock(chart: PlaylistSummary) -> some View {
        let isExpanded = expandedCharts.contains(chart.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                withAnimation(HaoLayout.settleSpring) {
                    if isExpanded {
                        expandedCharts.remove(chart.id)
                    } else {
                        expandedCharts.insert(chart.id)
                    }
                }
            }) {
                HStack(spacing: 12) {
                    MusicCoverView(urlString: chart.cover, size: 48, cornerRadius: HaoLayout.cornerSmall)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chart.name)
                            .font(.haoBodyStrong)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(chart.desc.isEmpty ? "网易云音乐" : chart.desc)
                            .font(.haoFootnote)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textMuted)
                        .animation(HaoLayout.settleSpring, value: isExpanded)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                if let tracks = homeVM.chartTracks[chart.id] {
                    if tracks.isEmpty {
                        Text("该榜单没有返回曲目。")
                            .font(.haoFootnote)
                            .foregroundStyle(theme.textSecondary)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 1) {
                            ForEach(Array(tracks.prefix(10).enumerated()), id: \.element.id) { index, song in
                                Button(action: {
                                    // b46: chart list is a reloadable place.
                                    playerVM.play(song: song, in: tracks, startAt: index, source: PlaySource(kind: .chart, id: chart.id), sourceDisplayName: chart.name)
                                }) {
                                    HStack(spacing: 12) {
                                        Text("\(index + 1)")
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            // b49fix2 A17: red means LIVE in this app — chart
                                            // ranks use the accent colour, not liveRed.
                                            .foregroundStyle(index < 3 ? theme.accentText : theme.textSecondary)
                                            .frame(width: 28, alignment: .center)
                                        Text(song.title.isEmpty ? "未知歌曲" : song.title)
                                            .font(.system(size: 17, weight: .medium))
                                            .foregroundStyle(theme.textPrimary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .layoutPriority(1)
                                        Spacer()
                                        Text(song.artist.isEmpty ? "" : song.artist)
                                            .font(.haoSubhead)
                                            .foregroundStyle(theme.textSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .frame(maxWidth: 150, alignment: .trailing)
                                    }
                                    // b49fix3 P2-48: the rank row is
                                    // intentionally 32, not 64 — it
                                    // is a dense text-only ranking
                                    // row (rank + title + artist),
                                    // not a song row with a 48 cover.
                                    // Unifying it to 64 would make
                                    // the chart list sparse for
                                    // nothing.
                                    .frame(minHeight: 32)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else if homeVM.chartTracksFailed.contains(chart.id) {
                    // b49fix2 P1-11: a failed chart offers a retry —
                    // the old code showed skeletons with no way back
                    // (the VM had cached the empty result for 30 min).
                    Button(action: { homeVM.loadChartTracks(chart: chart, force: true) }) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise")
                            Text("加载失败，点按重试")
                        }
                        .font(.haoFootnoteStrong)
                        .foregroundStyle(theme.accentText)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 8)
                } else {
                    VStack(spacing: 1) {
                        ForEach(0..<4, id: \.self) { _ in MusicSkeletonRow() }
                    }
                }
            }
        }
        .onAppear { homeVM.loadChartTracks(chart: chart) }
    }

    // MARK: - Regional hot (Coda §3.1 分地区热门)

    private func regionalHotSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MusicCodaSectionHeader(title: "分地区热门")
            if homeVM.regionalLoading && homeVM.regionalHotSongs.isEmpty {
                VStack(spacing: 1) {
                    ForEach(0..<4, id: \.self) { _ in MusicSkeletonRow() }
                }
            } else if homeVM.regionalHotSongs.isEmpty {
                MusicEmptyState(
                    icon: "globe", title: "暂无热门歌曲",
                    note: homeVM.regionalFailed ? "加载失败，请检查网络后重试。" : "分地区热门没有返回内容，稍后再试。",
                    onRetry: { homeVM.loadRegionalHot(force: true) }
                )
            } else {
                let columnWidth = width - 20
                let columns = Array(Array(homeVM.regionalHotSongs.prefix(36)).chunked(into: 4))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                            VStack(spacing: 1) {
                                ForEach(column) { song in
                                    discoverSongCell(song: song) {
                                        let songs = homeVM.regionalHotSongs
                                        if let at = songs.firstIndex(where: { $0.identityKey == song.identityKey }) {
                                            // b46: regional-hot list is a reloadable place.
                                            playerVM.play(song: song, in: songs, startAt: at, source: PlaySource(kind: .discover, id: "regional-hot"), sourceDisplayName: "地区热门")
                                        }
                                    }
                                    .frame(width: columnWidth, alignment: .leading)
                                }
                            }
                            .frame(width: columnWidth, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Discovered playlists / radio (Coda §3.1 双行货架)

    /// Two-row CoverCard shelf (178, r22 body), other platforms'
    /// plaza merged. Preview caps at 18 cards.
    private func discoveredPlaylistsSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // b49fix2 A8: this shelf merges the other platforms'
            // plazas (tx/kg/kw), so "全部" opens the plaza on tx —
            // the first of its merged platforms — not wy like the
            // 推荐歌单 shelf above.
            MusicCodaSectionHeader(title: "发现歌单") {
                MusicLibraryStore.setPlazaPlatform(.tx)
                path.append(.plaza)
            }
            if homeVM.discoveredLoading && homeVM.discoveredPlaylists.isEmpty {
                HStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { _ in MusicSkeletonCard() }
                }
            } else if homeVM.discoveredPlaylists.isEmpty {
                MusicEmptyState(
                    icon: "square.grid.2x2", title: "暂无发现歌单",
                    note: "其他平台没有返回歌单，稍后再试。",
                    onRetry: { homeVM.loadDiscoveredPlaylists() }
                )
            } else {
                let columns = Array(Array(homeVM.discoveredPlaylists.prefix(18)).chunked(into: 2))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                            VStack(alignment: .leading, spacing: 24) {
                                ForEach(Array(column.enumerated()), id: \.offset) { _, summary in
                                    NavigationLink(destination: MusicPlazaDetailView(summary: summary)) {
                                        MusicCoverCardBody(
                                            coverURL: summary.cover, title: summary.name,
                                            subtitle: plazaCardSubtitle(summary)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - New albums (Coda §3.1 新专辑)

    private func newAlbumsSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MusicCodaSectionHeader(title: "新专辑")
            if homeVM.newAlbums.isEmpty {
                MusicEmptyState(
                    icon: "square.stack", title: "还没有专辑",
                    note: "收藏或播过的歌的专辑会出现在这里。"
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(homeVM.newAlbums) { album in
                            NavigationLink(destination: MusicAlbumDetailView(album: album)) {
                                MusicCoverCardBody(
                                    coverURL: album.cover, title: album.name,
                                    subtitle: album.artist
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Recommended artists (Coda §3.1 推荐歌手)

    /// 128 circle in a 140 frame, name body medium.
    private var recommendedArtistsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MusicCodaSectionHeader(title: "推荐歌手")
            if homeVM.recommendedArtists.isEmpty {
                MusicEmptyState(
                    icon: "person", title: "还没有推荐歌手",
                    note: "常听的歌手会出现在这里。"
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(homeVM.recommendedArtists, id: \.name) { artist in
                            NavigationLink(destination: MusicArtistDetailView(artist: artist)) {
                                VStack(spacing: 8) {
                                    MusicCoverView(urlString: artist.cover, size: 128, cornerRadius: 64)
                                    Text(artist.name)
                                        .font(.system(size: 17, weight: .medium))
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                        .frame(width: 140, alignment: .center)
                                }
                                .frame(width: 140, alignment: .top)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - Feature collage card (Coda §3.1, b45-b)

/// Coda HomeView feature card: a 3×4 collage of ~57.3pt blocks
/// (spacing 3, r4), middle column shifted down −0.55 block,
/// side columns −0.15; a black gradient 0.18→0.76 over the
/// collage; a 46pt white-0.20 icon circle; title sectionTitle
/// bold white, subtitle body white 0.85. The date card (daily)
/// carries a white-0.28 date tile. Colours are theme/system
/// tints (never purple, never red as a brand colour).
struct MusicFeatureCollageCard: View {
    var icon: String
    var title: String
    var subtitle: String
    var palette: [Color]
    var size: CGFloat
    var isDateCard: Bool = false
    var action: () -> Void

    private var block: CGFloat { (size - 2 * 3) / 3 }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                // 3×4 collage.
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { column in
                        VStack(spacing: 3) {
                            ForEach(0..<4, id: \.self) { row in
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(collageColor(column: column, row: row))
                                    .frame(width: block, height: block)
                            }
                        }
                        .offset(y: column == 1 ? -0.55 * block : -0.15 * block)
                    }
                }
                // Black gradient 0.18 → 0.76 for legibility.
                LinearGradient(
                    colors: [Color.black.opacity(0.18), Color.black.opacity(0.76)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .frame(width: size, height: size)
            // b49fix3 P1-24: same-width cards share one radius —
            // the collage tile was 20 while the 178 search cards
            // are 12; 12 (cornerMedium) is the shared value.
            .clipShape(RoundedRectangle(cornerRadius: HaoLayout.cornerMedium, style: .continuous))
            // b47-home: the icon row and the text block are pinned to
            // the tile's bounds as overlays. The old Spacer-expanded
            // VStack inside this ZStack rendered its content beyond
            // the tile's top/bottom edges on device (icons
            // half-clipped at the top, subtitle crowded at the
            // bottom — chen's 16:11 frames). An overlay is
            // positioned against the tile's fixed frame, so the 12pt
            // insets hold exactly and nothing can spill; the layout
            // values are unchanged.
            .overlay(alignment: .topLeading) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.20))
                            .frame(width: 46, height: 46)
                        Image(systemName: icon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    if isDateCard {
                        Text("\(Calendar.current.component(.day, from: Date()))")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 17))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(12)
            }
        }
        .buttonStyle(MusicPressScaleStyle())
        .accessibilityLabel(title)
    }

    private func collageColor(column: Int, row: Int) -> Color {
        let base = palette[(column + row) % palette.count]
        let alpha: Double = [0.85, 0.55, 0.7, 0.45][row % 4]
        return base.opacity(alpha)
    }
}

// MARK: - Array chunking (b45-b)

extension Array {
    /// Split into consecutive chunks of `size` (last chunk may
    /// be short). Used by the home shelves (3 rows / 4 rows /
    /// 2 rows per column).
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        var out: [[Element]] = []
        var index = 0
        while index < count {
            out.append(Array(self[index..<Swift.min(index + size, count)]))
            index += size
        }
        return out
    }
}

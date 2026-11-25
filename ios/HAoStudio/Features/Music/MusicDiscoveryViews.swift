// HAo Studio 2.0 — music discovery pages (S2-C leg).
//
// Daily picks, plaza, charts, listen report.
//
// - Daily: cached per day (hao_daily.json); a missing day is built
//   from local data (listen log + favourites + recent +
//   playlists, ranked — no shuffle, no seed).
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

// MARK: - Daily (Coda §3.5, local version, b45-b)

/// Daily picks, local seeds only (recent + likes): no server
/// daily, no login. VStack spacing 16 (phone); header =
/// PlaylistHeader (cover = first song's album, title = daily
/// title, subtitle = platform/local, metadata "N 首歌曲 · 每天
/// 更新" — regeneration is on first load of a new calendar day,
/// not at 6:00, so the copy no longer claims a time); actions have NO save button; "不喜欢换一首"
/// replaces the song in place; title inline; empty state
/// calendar.badge.clock "暂无推荐歌曲", min height 300; cache
/// 24h per day key (hao_daily, see MusicDiscoveryViewModel).
/// No big date header, no big cover hero.
struct MusicDailyView: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    // b49fix13 P2-3: the only instance that refreshes the daily
    // list at midnight (full reload).
    @StateObject private var discoveryVM = MusicDiscoveryViewModel(midnightRefresh: .daily)

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            if discoveryVM.dailyTracks.isEmpty {
                MusicEmptyState(
                    icon: "calendar.badge.clock", title: "暂无推荐歌曲",
                    note: "先收藏几首歌或播几首歌，每日推荐会从你听过的歌里挑。"
                )
                .frame(minHeight: 300)
            } else {
                List {
                    Section {
                        dailyHeader
                    }
                    .listRowBackground(theme.scaffoldBackground)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    Section {
                        HStack {
                            Spacer()
                            dailyActions
                            Spacer()
                        }
                    }
                    .listRowBackground(theme.scaffoldBackground)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    Section {
                        ForEach(Array(discoveryVM.dailyTracks.enumerated()), id: \.element.id) { index, song in
                            HStack(spacing: 8) {
                                MusicSongRow(
                                    song: song,
                                    isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
                                    showFavHeart: true,
                                    onTap: {
                                        playerVM.play(song: song, in: discoveryVM.dailyTracks, startAt: index, source: PlaySource(kind: .daily, id: "daily"), sourceDisplayName: "每日推荐")
                                    }
                                )
                                if !discoveryVM.dailySpares.isEmpty {
                                    Button("换一首") {
                                        discoveryVM.replaceDailySong(song)
                                    }
                                    .font(.haoFootnoteStrong)
                                    .foregroundStyle(theme.accentText)
                                    .accessibilityLabel("不喜欢《\(song.title)》，换一首")
                                }
                            }
                            .listRowBackground(theme.scaffoldBackground)
                            .listRowSeparatorTint(theme.hairline)
                        }
                    }
                }
                .haoBottomChromePadding()
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // b45-g (Coda §8.2): pull-to-refresh regenerates
                // today's picks, bypassing the day-key cache.
                .refreshable { discoveryVM.reload(forceDaily: true) }
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("每日推荐")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { discoveryVM.reload() }
    }

    /// PlaylistHeader: cover = first song's album cover, title
    /// = daily title, subtitle = local source, metadata
    /// "N 首歌曲 · 每天更新" (not 6:00 — the list regenerates on
    /// first load of a new calendar day; no 6:00 rollover exists).
    private var dailyHeader: some View {
        let first = discoveryVM.dailyTracks.first
        return MusicDetailHero(
            coverURL: first?.cover ?? "",
            title: "每日推荐",
            subtitle: "本地推荐",
            metadata: "\(discoveryVM.dailyTracks.count) 首歌曲 · 每天更新"
        )
    }

    /// Actions without a save button (Coda §3.5): play capsule
    /// (theme accent, headline) + a refresh-today menu.
    private var dailyActions: some View {
        HStack(spacing: 12) {
            Button(action: { playerVM.playAll(discoveryVM.dailyTracks, source: PlaySource(kind: .daily, id: "daily"), sourceDisplayName: "每日推荐") }) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("播放")
                }
                .font(.headline)
                .foregroundStyle(theme.onAccent)
                .frame(minWidth: 116, maxWidth: .infinity, minHeight: 56, maxHeight: 56)
                .background(theme.accent, in: Capsule())
            }
            .buttonStyle(MusicPressScaleStyle())
            .accessibilityLabel("播放全部")
            Menu {
                Button("刷新今日推荐") { discoveryVM.reload(forceDaily: true) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 56, height: 56)
                    .haoGlassCircle()
            }
            .accessibilityLabel("更多操作")
        }
        .modifier(MusicPrimaryActionsLayout())
    }
}

// MARK: - Explore (Coda §3.9, b45-b)

/// Shelf frames in the explore scroll view's coordinate space
/// (b49fix4 P2-33): the sticky chips' highlight follows manual
/// scrolling, and the last shelf's height sizes the bottom
/// padding so it can scroll to the top. Only the derived values
/// (the selected shelf, the last shelf's height) become state —
/// the raw frames are never stored, so scrolling does not
/// re-render the page on every frame.
private struct ExploreShelfFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Explore = search empty state + ExploreShelves. Category chips
/// (排行榜 excluded — it already lives on home/charts) render
/// only categories with a non-empty result from the loaded plaza
/// data (discoveryVM.exploreAvailableCategories) — the full 26
/// used to render unconditionally while most keyword filters
/// matched nothing, so most shelves were empty by construction;
/// each category snapshot caches 15 minutes, so switching
/// categories answers instantly; each category is one two-row
/// playlist shelf with its own loading state; the header arrow
/// opens the category's full page. There is no ExploreView
/// struct — this view is the explore page.
struct MusicExploreView: View {
    // b49fix13 P2-3: explore shows 15-minute snapshots with
    // their own TTL — nothing to refresh at midnight.
    @StateObject private var discoveryVM = MusicDiscoveryViewModel(midnightRefresh: .none)
    @State private var selectedCategory = "全部"
    @State private var showCategoryFull = false
    /// Height of the explore scroll viewport (P2-33), measured by
    /// the GeometryReader around the ScrollView — the bottom
    /// padding needs it. 0 until the first measurement lands.
    @State private var exploreScrollHeight: CGFloat = 0
    /// Height of the last shelf (P2-33), reported by its frame
    /// preference — the bottom padding needs it. 0 until reported.
    @State private var lastShelfHeight: CGFloat = 0

    @Environment(\.haoTheme) private var theme
    /// The chrome clearance under this page's scroll content
    /// (P2-33 — same rule as haoBottomChromeContentPadding,
    /// which already reads these objects on this view): the
    /// bottom padding is what remains after it.
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var musicPlayer: MusicPlayerViewModel

    /// Bottom padding for the scroll content (b49fix4 P2-33):
    /// enough for the last shelf to scroll to the top — the
    /// viewport height minus the last shelf's height minus the
    /// chrome clearance already under the content. Never below
    /// the old 12 (and 12 while either measurement is missing,
    /// so the page never jumps on first paint).
    private var exploreBottomPadding: CGFloat {
        guard exploreScrollHeight > 0, lastShelfHeight > 0 else { return 12 }
        let chrome = HaoLayout.floatingStackClearance(
            miniPlayerVisible: coordinator.currentItem != nil
                || musicPlayer.miniFallbackSong != nil)
        return max(12, exploreScrollHeight - lastShelfHeight - chrome)
    }

    var body: some View {
        // b49fix3 P1-4: the chips are section navigation, not a
        // filter — tapping one scrolls to that shelf (the page
        // renders every shelf; a highlight-only chip was a dead
        // control). ScrollViewReader owns the proxy; the chips
        // take it as a parameter.
        // b49fix4 P2-33: the chips are a sticky header ABOVE the
        // scroll view now, not rows inside it — they used to scroll
        // away after one tap, so navigation worked exactly once.
        // The highlight follows manual scrolling too (each shelf
        // reports its frame; the selected shelf is the last one
        // whose top has reached the visible top).
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                categoryChips(proxy: proxy)
                    // b49fix4 P2-10: the chips' old bottom 16 is
                    // gone — the first shelf's own top 32 is the
                    // gap now (and the refresh banner, when shown,
                    // carries its own top 16).
                    .padding(.top, 12)
                    .padding(.horizontal, HaoLayout.pushedPageMargin)
                GeometryReader { geo in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if discoveryVM.exploreRefreshFailed {
                                refreshFailedBanner
                            }
                            ForEach(discoveryVM.exploreAvailableCategories, id: \.self) { category in
                                exploreShelf(category: category)
                                    .id(category)
                                    // b49fix3 P1-21: true discovery shelves
                                    // keep the 32pt section gap, as a token.
                                    .padding(.top, HaoLayout.discoverySectionTopSpacing)
                                    .background(
                                        GeometryReader { shelfGeo in
                                            Color.clear.preference(
                                                key: ExploreShelfFrameKey.self,
                                                value: [category: shelfGeo.frame(in: .named("exploreScroll"))]
                                            )
                                        }
                                    )
                            }
                        }
                        .padding(.horizontal, HaoLayout.pushedPageMargin)
                        .padding(.bottom, exploreBottomPadding)
                        .haoBottomChromeContentPadding()
                    }
                    .coordinateSpace(name: "exploreScroll")
                    .onPreferenceChange(ExploreShelfFrameKey.self) { frames in
                        // Only derived values become state (see the
                        // key): the highlight and the last shelf's
                        // height change on data load, not on scroll.
                        let current = discoveryVM.exploreAvailableCategories.last(where: { category in
                            (frames[category]?.minY ?? .infinity) <= 80
                        })
                        if let current = current, current != selectedCategory {
                            selectedCategory = current
                        }
                        if let last = discoveryVM.exploreAvailableCategories.last,
                           let height = frames[last]?.height, height > 0, height != lastShelfHeight {
                            lastShelfHeight = height
                        }
                    }
                    // b45-g (Coda §8.2): pull-to-refresh re-fetches the plaza
                    // once and re-filters every loaded category (900s snapshots
                    // are bypassed, not waited out).
                    .refreshable { discoveryVM.refreshExplore() }
                    .onAppear { exploreScrollHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, height in exploreScrollHeight = height }
                }
            }
        }
        .background(
            // One hidden link for every shelf header's arrow:
            // the header sets selectedCategory, then flips this.
            NavigationLink(
                destination: MusicExploreCategoryView(category: selectedCategory, discoveryVM: discoveryVM),
                isActive: $showCategoryFull
            ) { EmptyView() }
            .hidden()
        )
        .background(theme.scaffoldBackground)
        .navigationTitle("探索")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { discoveryVM.loadExploreCategory("全部") }
    }

    /// b49fix3 P2-10: a failed pull-to-refresh used to be silent
    /// (old snapshots kept, no feedback, no retry). The banner
    /// says the data is stale and offers one-tap retry.
    /// b49fix4 P2-7: a bare row, like the video search CMS/Emby
    /// banners — the old card (surface bg, radius 12) was the
    /// second of two banner systems. P2-10: the top 16 is the gap
    /// to the sticky chips above (the first shelf's own top 32
    /// separates the banner from it).
    private var refreshFailedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
            Text("刷新失败，显示的是旧数据。")
                .font(.haoFootnote)
            Spacer()
            Button("重试") { discoveryVM.refreshExplore() }
                .font(.haoFootnoteMedium)
                .foregroundStyle(theme.accentText)
        }
        .foregroundStyle(theme.textSecondary)
        // b49fix5 P2-17: the banner carries its own top 12 (was
        // 16 — the gap to the sticky chips); the container adds
        // nothing.
        .padding(.top, 12)
    }

    private func categoryChips(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(discoveryVM.exploreAvailableCategories, id: \.self) { category in
                    Button(action: {
                        selectedCategory = category
                        discoveryVM.loadExploreCategory(category)
                        // P1-4: the chip jumps to its shelf — the
                        // highlight alone changed nothing before.
                        withAnimation { proxy.scrollTo(category, anchor: .top) }
                    }) {
                        Text(category)
                            .font(.haoSubheadMedium)
                            .foregroundStyle(selectedCategory == category ? theme.onAccent : theme.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                // b49fix4 P2-20: unselected chips are
                                // surface + hairline, like the Emby /
                                // FlowChips chips — the old 0.06 fill
                                // with no border was a third chip
                                // system. Selected states are
                                // identical in all three, untouched.
                                selectedCategory == category ? theme.accent : theme.surface,
                                in: Capsule()
                            )
                            .overlay(
                                selectedCategory == category ? nil : Capsule().strokeBorder(theme.hairline, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("分类：\(category)")
                }
            }
        }
    }

    /// One category: header (min height 44, 16pt to content) +
    /// a two-row playlist shelf. Each shelf loads independently.
    private func exploreShelf(category: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MusicCodaSectionHeader(title: category) {
                // The header arrow opens the category's full page.
                selectedCategory = category
                showCategoryFull = true
            }
            .padding(.bottom, 16)
            if discoveryVM.exploreLoading.contains(category) && discoveryVM.explorePlaylists(for: category).isEmpty {
                HStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { _ in MusicSkeletonCard() }
                }
            } else if discoveryVM.exploreFailed.contains(category) {
                MusicEmptyState(
                    icon: "square.grid.2x2", title: "该分类加载失败",
                    note: "稍后再试。",
                    onRetry: { discoveryVM.loadExploreCategory(category) }
                )
            } else {
                let playlists = discoveryVM.explorePlaylists(for: category)
                if playlists.isEmpty {
                    // Not loaded yet (below the fold): trigger the
                    // load and show a compact empty state, never a
                    // blank hole.
                    Color.clear
                        .frame(height: 0)
                        .onAppear { discoveryVM.loadExploreCategory(category) }
                    Text("该分类暂无歌单。")
                        .font(.haoFootnote)
                        .foregroundStyle(theme.textSecondary)
                        .frame(minHeight: 120, alignment: .center)
                        .frame(maxWidth: .infinity)
                } else {
                    let columns = Array(Array(playlists.prefix(12)).chunked(into: 2))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 24) {
                            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                                VStack(alignment: .leading, spacing: 24) {
                                    ForEach(Array(column.enumerated()), id: \.offset) { _, summary in
                                        NavigationLink(destination: MusicPlazaDetailView(summary: summary)) {
                                            MusicCoverCardBody(
                                                coverURL: summary.cover, title: summary.name,
                                                subtitle: summary.creator
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
    }
}

/// One category's full page: all of its snapshot, client-side
/// paging (20 per page, "加载更多" appends the next page).
/// Shares the explore page's view model (observed, not owned):
/// the old build created its own MusicDiscoveryViewModel, which
/// discarded the explore page's already-loaded snapshots and
/// refetched all 4 platforms for one category. With the shared
/// model the snapshot is usually already there and onAppear is a
/// cache hit.
struct MusicExploreCategoryView: View {
    var category: String
    @ObservedObject var discoveryVM: MusicDiscoveryViewModel
    @State private var shownCount = 20

    @Environment(\.haoTheme) private var theme

    private var playlists: [PlaylistSummary] {
        discoveryVM.explorePlaylists(for: category)
    }

    var body: some View {
        Group {
            if discoveryVM.exploreLoading.contains(category) && playlists.isEmpty {
                // b49fix4 P2-24: the skeleton rows use the same 24pt
                // spacing as the loaded LazyVGrid below, so the page
                // does not reflow when the data lands.
                VStack(spacing: 24) {
                    ForEach(0..<6, id: \.self) { _ in MusicSkeletonCard() }
                }
                .padding(.horizontal, HaoLayout.pushedPageMargin)
            } else if playlists.isEmpty {
                MusicEmptyState(
                    icon: "square.grid.2x2", title: "该分类暂无歌单",
                    note: "换个分类试试。",
                    onRetry: { discoveryVM.loadExploreCategory(category) }
                )
            } else {
                // b49fix2 B15: the card size comes from the page's
                // real width (GeometryReader), not UIScreen — Split
                // View / Stage Manager narrow the window without
                // changing the screen.
                GeometryReader { geo in
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 16),
                                GridItem(.flexible(), spacing: 16),
                            ],
                            spacing: 24
                        ) {
                            ForEach(Array(playlists.prefix(shownCount).enumerated()), id: \.offset) { _, summary in
                                NavigationLink(destination: MusicPlazaDetailView(summary: summary)) {
                                    MusicCoverCardBody(
                                        coverURL: summary.cover, title: summary.name,
                                        subtitle: summary.creator,
                                        size: (geo.size.width - 40 - 16) / 2
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, HaoLayout.pushedPageMargin)
                        .padding(.vertical, 12)
                        if shownCount < playlists.count {
                            // b49fix4 P2-25: load-more is 15 semibold
                            // with 12pt vertical padding, site-wide
                            // (the old 13 + 44pt min-height was a
                            // second load-more system).
                            Button("加载更多") { shownCount += 20 }
                                .font(.haoSubheadStrong)
                                .foregroundStyle(theme.accentText)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity)
                        }
                        // b49fix8 P2-14: page-bottom spacer is 16
                        // site-wide (was 12 here).
                        Spacer(minLength: 16)
                    }
                    .haoBottomChromeContentPadding()
                }
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle(category)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { discoveryVM.loadExploreCategory(category) }
    }
}

// MARK: - Plaza

/// Play-count text for a plaza row. Pure function (unit-tested).
/// Same ".0"-tail rule as liveWatchingText: 10000 -> "1万次播放",
/// 100000000 -> "1亿次播放", never "1.0万次播放" / "1.0亿次播放".
/// Same ≥100 cap as liveWatchingText: 99_999_999 -> "9999万次播放",
/// never "10000万次播放".
func plazaPlayCountText(_ count: Int) -> String {
    if count <= 0 { return "" }
    if count >= 100_000_000 {
        let formatted = String(format: "%.1f亿次播放", Double(count) / 100_000_000)
        if formatted.hasSuffix(".0亿次播放") {
            return String(formatted.dropLast(6)) + "亿次播放"
        }
        return formatted
    }
    if count >= 10_000 {
        let value = Double(count) / 10_000
        if value >= 100 {
            return "\(Int(value))万次播放"
        }
        let formatted = String(format: "%.1f万次播放", value)
        if formatted.hasSuffix(".0万次播放") {
            return String(formatted.dropLast(6)) + "万次播放"
        }
        return formatted
    }
    return "\(count)次播放"
}

struct MusicPlazaView: View {
    // b49fix13 P2-3: plaza shows 15-minute snapshots with their
    // own TTL — nothing to refresh at midnight.
    @StateObject private var discoveryVM = MusicDiscoveryViewModel(midnightRefresh: .none)

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
            .padding(.horizontal, HaoLayout.pushedPageMargin)
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
                    note: "\(discoveryVM.plazaPlatform.displayName)没有返回歌单，稍后再试或换个平台。",
                    onRetry: { discoveryVM.loadPlaza() }
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
            MusicCoverView(urlString: summary.cover, size: 56, cornerRadius: HaoLayout.chipCornerRadius)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name)
                    .font(.haoCalloutStrong)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(plazaSubtitle(summary))
                    .font(.haoRowSubtitle)
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

    /// Server playlist, cached 300s (b45-g, Coda §3.1 歌单 300s).
    private var loadedAt: Date? = nil
    static let playlistCacheTTL: TimeInterval = 300

    init(summary: PlaylistSummary) {
        self.summary = summary
    }

    /// A fresh cache answers instantly on re-appear;
    /// pull-to-refresh forces a refetch. A failed load never
    /// stamps the cache, so retry still works.
    func load(force: Bool = false) {
        if !force, let loadedAt = loadedAt,
           Date().timeIntervalSince(loadedAt) < Self.playlistCacheTTL,
           !tracks.isEmpty {
            return
        }
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
        if !tracks.isEmpty {
            loadedAt = Date()
        }
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
                    note: viewModel.note.isEmpty ? "该歌单没有返回曲目，稍后再试。" : viewModel.note,
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
                                    playerVM.play(song: song, in: viewModel.tracks, startAt: index, source: PlaySource(kind: .playlist, id: summary.id), sourceDisplayName: summary.name)
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
                // b45-g (Coda §8.2): pull-to-refresh bypasses the
                // 300s playlist cache.
                .refreshable { viewModel.load(force: true) }
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle(summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MusicCapsuleButton(icon: "play.fill", label: "播放全部", enabled: !viewModel.tracks.isEmpty) {
                    playerVM.playAll(viewModel.tracks, source: PlaySource(kind: .playlist, id: summary.id), sourceDisplayName: summary.name)
                }
            }
        }
        .onAppear { viewModel.load() }
    }
}

// MARK: - Listen report

struct MusicListenReportView: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    // b49fix13 P2-3: the report only needs its week/month window
    // recomputed at midnight — no daily recompute.
    @StateObject private var discoveryVM = MusicDiscoveryViewModel(midnightRefresh: .report)

    @Environment(\.haoTheme) private var theme

    var body: some View {
        ScrollView {
            // b49fix4 P2-12: the outer spacing is the 16pt token,
            // not a third value (20) — the sections are separated
            // by the same 16 as every other page.
            VStack(alignment: .leading, spacing: 16) {
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
            .padding(.horizontal, HaoLayout.pushedPageMargin)
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
        .background(theme.surface, in: RoundedRectangle(cornerRadius: HaoLayout.cornerXLarge, style: .continuous))
    }

    private func summaryStat(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.haoDetailTitle)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.haoCaption)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var topSongsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最常听")
                .font(.haoSectionTitle)
                .foregroundStyle(theme.textPrimary)
            if discoveryVM.report.topSongs.isEmpty {
                Text("这段时间还没有收听记录。")
                    .font(.haoRowSubtitle)
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(Array(discoveryVM.report.topSongs.prefix(10).enumerated()), id: \.element.song.id) { rank, top in
                    HStack(spacing: 12) {
                        Text("\(rank + 1)")
                            .font(.haoDenseTitle)
                            .foregroundStyle(theme.accentText)
                            .frame(width: 20)
                        MusicSongRow(
                            song: top.song,
                            showPlatformBadge: false,
                            isPlaying: playerVM.currentSong?.identityKey == top.song.identityKey && playerVM.isPlaying,
                            onTap: {
                                let songs = discoveryVM.report.topSongs.map { $0.song }
                                if let index = songs.firstIndex(where: { $0.identityKey == top.song.identityKey }) {
                                    // b46: most-played list is a reloadable place.
                                    playerVM.play(song: top.song, in: songs, startAt: index, source: PlaySource(kind: .discover, id: "report-top"), sourceDisplayName: "最常听")
                                }
                            }
                        )
                        Text("\(top.plays) 次")
                            .font(.haoFootnote)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
        }
    }

    private var topArtistsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最常听的歌手")
                .font(.haoSectionTitle)
                .foregroundStyle(theme.textPrimary)
            if discoveryVM.report.topArtists.isEmpty {
                Text("这段时间还没有收听记录。")
                    .font(.haoRowSubtitle)
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(discoveryVM.report.topArtists.prefix(10), id: \.artist) { top in
                    HStack {
                        Text(top.artist)
                            .font(.haoSubhead)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text("\(top.plays) 次")
                            .font(.haoFootnote)
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
                .font(.haoSectionTitle)
                .foregroundStyle(theme.textPrimary)
            if discoveryVM.report.topPlatforms.isEmpty {
                Text("这段时间还没有收听记录。")
                    .font(.haoRowSubtitle)
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(discoveryVM.report.topPlatforms, id: \.platform) { top in
                    HStack {
                        Text(top.platform.displayName)
                            .font(.haoSubhead)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text("\(top.plays) 次")
                            .font(.haoFootnote)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var perDaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // b49fix4 P2-11: the section title is 20 semibold, like
            // the other three sections on this page (the old 22 bold
            // made this one section read as a page title).
            Text(discoveryVM.reportRange == .all ? "按月" : "按天")
                .font(.haoSectionTitle)
                .foregroundStyle(theme.textPrimary)
            if discoveryVM.report.perDay.isEmpty {
                Text("这段时间还没有收听记录。")
                    .font(.haoRowSubtitle)
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(discoveryVM.report.perDay, id: \.label) { day in
                    HStack {
                        Text(day.label)
                            .font(.haoSubhead)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text("\(day.plays) 次")
                            .font(.haoFootnote)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

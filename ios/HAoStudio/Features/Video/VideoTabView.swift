// HAo Studio 2.0 — video tab (S3-C leg).
//
// Home tab for 影视: CMS home rows + categories + search entry +
// continue watching, with a CMS / Emby mode switch (persisted in
// `hao_video_tab_mode`, Flutter parity). Mirrors Flutter
// video_tab_page.dart (_CmsHomePage): cached rows first, then a
// fresh fetch; pull to refresh; section headers with a "全部"
// button into the browse page, and a "浏览全部" chip first in the
// category strip (build 36 item 18).
//
// The tab never invents rows: when the gateway answers empty
// (placeholder, or no source reachable) the page says so honestly.

import SwiftUI

/// Video tab navigation destinations.
enum VideoDestination: Hashable {
    case search
    case embySearch
    case category(String)
    case history
    case favourites
    case detail(VideoItem)
    case embyDetail(VideoItem)
    /// Genre page with the library it was opened from (b49 sweep
    /// #5): nil = all libraries, as the browse page does — the
    /// genre page used to drop the selection and always search
    /// every library.
    case embyGenre(libraryId: String?, genre: String)
    /// Browse page (build 36 item 18). nil = no type pre-selected
    /// (first visible category); non-nil = pre-selected type.
    case browse(String?)
    /// The "每日推荐" row's own list (sweep-3 A16): daily picks
    /// have no single type, and no fake "daily" type is invented
    /// — the row's "全部" used to open the browse page with nil
    /// (first category), which is not the daily list at all. The
    /// list is the row's items as loaded, shown as a static grid.
    case dailyList([VideoItem])
}

@MainActor
final class VideoTabViewModel: ObservableObject {
    @Published private(set) var rows: [VideoHomeRow] = []
    @Published private(set) var categories: [String] = []
    @Published private(set) var continueWatching: [VideoHistoryEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    /// True when the last refresh failed but cached rows are
    /// showing (b49 sweep #18): the rows stay, with a stale-age
    /// banner + retry instead of silent staleness.
    @Published private(set) var homeRefreshFailed = false
    /// Human age of the rows on screen, for the stale banner.
    @Published private(set) var homeCacheAgeText = ""

    private let gateway: VideoDataGateway

    init(gateway: VideoDataGateway = VideoServices.makeGateway()) {
        self.gateway = gateway
    }

    var watchedKeys: Set<String> {
        Set(continueWatching.map { $0.id })
    }

    /// Throttle for `loadFresh()` on tab re-entry (build 36 item 10):
    /// returning to the tab re-reads the local cache, but only
    /// re-fetches when there is nothing cached or the last
    /// successful fetch is older than this. Pull-to-refresh
    /// calls `loadFresh()` directly and bypasses the throttle.
    private static let freshInterval: TimeInterval = 5 * 60

    /// Set when a home fetch completes without failing
    /// (see `loadFresh()`); nil = never fetched successfully.
    private var lastFreshFetch: Date?

    func reload() {
        rows = VideoLibraryStore.cachedHome()
        homeCacheAgeText = VideoLibraryStore.homeCacheAgeText()
        continueWatching = VideoLibraryStore.history()
        reloadIfNeeded()
    }

    /// Local rows always refresh; the network fetch only runs
    /// when there is nothing cached or the last successful fetch
    /// is older than `freshInterval` (mirrors
    /// `LiveTabViewModel.loadIfNeeded`).
    func reloadIfNeeded() {
        guard rows.isEmpty || isFreshFetchStale else { return }
        loadFresh()
    }

    private var isFreshFetchStale: Bool {
        guard let last = lastFreshFetch else { return true }
        return Date().timeIntervalSince(last) >= Self.freshInterval
    }

    func loadFresh() {
        guard !isLoading else { return }
        isLoading = true
        loadFailed = false
        gateway.fetchHome { [weak self] fresh in
            guard let self = self else { return }
            self.isLoading = false
            if fresh.isEmpty {
                if self.rows.isEmpty {
                    self.loadFailed = true
                } else {
                    // b49 sweep #18: a failed refresh with cached
                    // rows keeps the stale rows but says so, with
                    // their age — and does NOT count as a fresh
                    // fetch, so the next tab entry retries instead
                    // of throttling for 5 minutes on dead data.
                    self.homeRefreshFailed = true
                    self.homeCacheAgeText = VideoLibraryStore.homeCacheAgeText()
                }
            } else {
                self.rows = fresh
                VideoLibraryStore.saveHomeCache(fresh)
                self.homeRefreshFailed = false
                self.homeCacheAgeText = VideoLibraryStore.homeCacheAgeText()
                self.lastFreshFetch = Date()
            }
        }
        gateway.fetchTypeNames { [weak self] names in
            guard let self = self else { return }
            self.categories = VideoLibraryStore.visibleCategories(
                names, prefs: VideoLibraryStore.categoryPrefs())
        }
    }
}

struct VideoTabView: View {
    /// Whether this tab is the selected one (sweep-5 P2-19):
    /// mounted tabs stay in the hierarchy at opacity 0, so
    /// onAppear / onDisappear never fire on a tab switch and
    /// cannot gate the hero timer — the parent passes the
    /// selection down instead. Defaults true (the only
    /// constructor is MainTabView.tabRoot).
    var isSelected = true
    @StateObject private var viewModel = VideoTabViewModel()
    @State private var path: [VideoDestination] = []
    @State private var mode: String = VideoLibraryStore.tabMode()
    /// Hero carousel index + auto-advance timer (VidHub /
    /// Streamyfin home, TV-App-SwiftUI pattern: TabView(.page)
    /// + Timer + custom capsule dots — the system dots don't
    /// match the banner).
    @State private var heroIndex = 0
    @State private var heroTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    /// Whether the hero carousel is on screen (b49 sweep #23):
    /// the timer publisher fires forever, so the advance is gated
    /// on this + scene phase + an empty nav path — the hero must
    /// not advance under the fullscreen player, in Emby mode, or
    /// while backgrounded. (sweep-5 P2-19: "on another tab" used
    /// to be claimed here too, but it was never gated — mounted
    /// tabs stay in the hierarchy at opacity 0, so onAppear /
    /// onDisappear never fire on a tab switch; the tab gate is
    /// `isSelected`, passed down by MainTabView.)
    @State private var heroTimerActive = false
    /// Whether the user is mid-drag on the hero (sweep-4 P2-19):
    /// the timer used to fire mid-swipe and fight the drag,
    /// advancing the page the user was already moving.
    @State private var isHeroDragging = false
    /// When the user last interacted with the hero (sweep-4
    /// P2-19): the timer stays quiet for a full 5 s after a
    /// manual swipe, so it never advances right on the heels of
    /// the page the user just chose.
    @State private var lastHeroInteraction = Date.distantPast

    @Environment(\.haoTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var settingsStore: SettingsStore
    /// Hero items the user has revealed past the spoiler guard
    /// (sweep-3 A18): per item id, never persisted — the next
    /// visit hides again, like the detail cover's reveal.
    @State private var heroSpoilerRevealed: Set<String> = []

    /// Whether this hero page hides behind the spoiler guard
    /// (sweep-3 A18): the hero art is already blurred 24 by
    /// design, so the readable leak is the title + meta text —
    /// an unwatched title's hero shows the reveal pill instead
    /// of the title until tapped. Watched titles and the
    /// spoiler setting off never hide.
    private func isHeroBlurred(item: VideoItem) -> Bool {
        spoilerCoverBlurred(
            blurUnwatched: settingsStore.blurUnwatchedPosters,
            watched: viewModel.watchedKeys.contains(
                VideoResumeKey.key(title: item.title, year: item.year)),
            revealed: heroSpoilerRevealed.contains(item.id))
    }

    /// Hero pages: the daily row first (VidHub's featured
    /// banner), else the first row; max 5.
    private var heroItems: [VideoItem] {
        let source = viewModel.rows.first(where: { $0.id == "daily" }) ?? viewModel.rows.first
        return Array((source?.items ?? []).prefix(5))
    }

    /// Hero height from the real screen width (16:10) — one
    /// place, so the banner is proportional on every iPhone,
    /// never a fixed number.
    private var heroHeight: CGFloat { UIScreen.main.bounds.width * 0.625 }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                // b42: in-content "影视" title (HomeView's
                // homeHeader pattern) — build 41 there was no
                // title at all and the Picker's "影视" text was
                // clipped under the status bar / Dynamic Island.
                videoHeader
                Picker("片源", selection: $mode) {
                Text("影视").tag("cms")
                Text("Emby").tag("emby")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, HaoLayout.pageMargin)
            .padding(.top, 8)
            .onChange(of: mode) { newMode in
                VideoLibraryStore.setTabMode(newMode)
            }
            .haoSensoryFeedback(.selection, trigger: mode)
            if mode == "emby" {
                EmbyTabView(
                    onSelect: { path.append(.embyDetail($0)) },
                    onSelectGenre: { libraryId, genre in path.append(.embyGenre(libraryId: libraryId, genre: genre)) },
                    onSearch: { path.append(.embySearch) }
                )
            } else {
                cmsHome
            }
            }
            // b43: the GeometryReader + top padding are gone —
            // they existed only to compensate for the backdrop
            // ZStack inflating this root to full screen (build 41:
            // the Picker's "影视" text was clipped under the
            // status bar). The backdrop is a background now
            // (haoBackdropLayer) — it never sizes its parent — so
            // this VStack starts at the safe-area top like the
            // other roots' ScrollViews, and the title sits below
            // the status bar with no compensation.
            .haoBackdropLayer()
            .haoTabBackground()
            // b39: no system nav bar on this root — VidHub's home
            // has a custom header, not a large title, and the
            // system large title proved unreliable on chen's phone
            // (Home's "首页" did not render, build 38). The hero
            // below is the top of the page; pushed pages (detail,
            // browse, search) keep their own bars and back buttons.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: VideoDestination.self) { destination in
                switch destination {
                case .search:
                    VideoSearchView(
                        onSelect: { path.append(.detail($0)) },
                        onOpenEmbySearch: { path.append(.embySearch) }
                    )
                case .embySearch:
                    EmbySearchView(onSelect: { path.append(.embyDetail($0)) })
                case .category(let type):
                    VideoCategoryView(type: type, onSelect: { path.append(.detail($0)) })
                case .history:
                    VideoHistoryView()
                case .favourites:
                    VideoFavsView()
                case .detail(let item):
                    VideoDetailView(item: item)
                case .embyDetail(let item):
                    EmbyDetailView(item: item)
                case .embyGenre(let libraryId, let genre):
                    EmbyCategoryView(genre: genre, libraryId: libraryId, onSelect: { path.append(.embyDetail($0)) })
                case .browse(let type):
                    VideoBrowseView(
                        initialType: type,
                        onSelectCMS: { path.append(.detail($0)) },
                        onSelectEmby: { path.append(.embyDetail($0)) },
                        onOpenHistory: { path.append(.history) },
                        onOpenFavourites: { path.append(.favourites) }
                    )
                case .dailyList(let items):
                    VideoDailyListView(items: items, onSelect: { path.append(.detail($0)) })
                }
            }
            .onAppear {
                // The browse page can change the persisted tab mode
                // (its 影视/Emby switch writes hao_video_tab_mode);
                // re-read it when switching back to this tab so the
                // picker shows the mode the user left the browse
                // page in.
                mode = VideoLibraryStore.tabMode()
                viewModel.reload()
            }
            .onChange(of: path) { _, newPath in
                // Popping back from a pushed page does NOT re-trigger
                // onAppear (the tab root never disappeared), so a mode
                // change made in the browse page is re-read here when
                // the stack returns to its root.
                if newPath.isEmpty {
                    mode = VideoLibraryStore.tabMode()
                }
            }
    }
}

    // MARK: - In-content large title (b42)

    /// Same 34pt bold title as HomeView's homeHeader, as a row
    /// above the Picker — the tab finally has a visible "影视"
    /// title with room above the hero, instead of the Picker's
    /// clipped "影视" text under the status bar.
    private var videoHeader: some View {
        Text("影视")
            .font(.haoScreenTitle)
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, HaoLayout.pageMargin)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - CMS home

    private var cmsHome: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Scroll anchor for the bottom chrome (b35 tab-bar
                    // link): drives minimize / restore as this tab scrolls.
                    HaoChromeScrollAnchor()
                        .id(HaoTabScrollTop.id(for: .movies))
                    if !heroItems.isEmpty {
                        heroCarousel
                    }
                    searchEntry
                        .padding(.horizontal, HaoLayout.pageMargin)
                        .padding(.top, 12)
                    categoryStrip
                        .padding(.top, 12)
                    libraryRow
                        .padding(.horizontal, HaoLayout.pageMargin)
                        .padding(.top, 12)
                    if !viewModel.continueWatching.isEmpty {
                        continueSection
                            .padding(.top, 16)
                    }
                    if viewModel.isLoading && viewModel.rows.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    } else if viewModel.rows.isEmpty {
                        // b49fix2 B3: the empty state named an
                        // action ("下拉重试") with no visible path
                        // — a retry button, same as the #18 retry
                        // below for stale rows.
                        VStack(spacing: 0) {
                            MusicEmptyState(
                                icon: "film",
                                title: viewModel.loadFailed ? "片源暂不可用" : "还没有内容",
                                note: viewModel.loadFailed
                                    ? "影视源没有返回数据，下拉重试或检查源设置。"
                                    : "影视源返回了空列表。"
                            )
                            MusicCapsuleButton(icon: "arrow.clockwise", label: "重试") {
                                viewModel.loadFresh()
                            }
                            .padding(.top, 6)
                        }
                        .padding(.horizontal, 24)
                    } else {
                        // b49 sweep #18: a failed refresh kept
                        // stale rows — show their age + retry
                        // instead of presenting them as fresh.
                        if viewModel.homeRefreshFailed {
                            HStack(spacing: 8) {
                                Image(systemName: "wifi.exclamationmark")
                                // (sweep-4 P2-53) homeCacheAgeText
                                // is "旧缓存" when the cache
                                // predates timestamps — "显示 旧缓存
                                // 的缓存" reads as a stutter.
                                Text(viewModel.homeCacheAgeText == "旧缓存"
                                    ? "影视源没有响应，显示旧缓存"
                                    : "影视源没有响应，显示 \(viewModel.homeCacheAgeText) 的缓存")
                                    .font(.haoFootnote)
                                Spacer()
                                Button("重试") { viewModel.loadFresh() }
                                    .font(.haoFootnote)
                                    .foregroundStyle(theme.accentText)
                            }
                            .foregroundStyle(theme.textSecondary)
                            .padding(.horizontal, HaoLayout.pageMargin)
                            .padding(.top, 12)
                        }
                        ForEach(viewModel.rows) { row in
                            homeRowSection(row)
                                .padding(.top, 16)
                        }
                    }
                    Spacer(minLength: 16)
                }
                .haoBottomChromeContentPadding()
            }
            .haoChromeScrollTracking()
            .haoReselectScrollToTop(tab: .movies, proxy: proxy)
            .refreshable { viewModel.loadFresh() }
        }
    }

    // MARK: - Hero carousel (VidHub / Streamyfin home)

    /// Featured hero carousel (VidHub shot0 / Streamyfin home
    /// screen): full-bleed poster art with a bottom gradient,
    /// title + meta overlaid, custom capsule page dots,
    /// auto-advancing every 5 s. Sized from the real screen
    /// width (heroHeight, 16:10) — the banner is edge-to-edge,
    /// never a fixed height. Tapping a page opens its detail.
    /// The poster is 2:3 art shown as a full blur under the dark
    /// gradient (b49 sweep #36) — the CMS gives no landscape
    /// backdrop, and a hard crop cut faces and title text.
    private var heroCarousel: some View {
        TabView(selection: $heroIndex) {
            ForEach(Array(heroItems.enumerated()), id: \.element.id) { index, item in
                // sweep-3 A18: a spoiler-hidden page reveals on
                // tap instead of opening the detail — same rule as
                // the detail cover's "点按查看海报".
                Button(action: {
                    if isHeroBlurred(item: item) {
                        heroSpoilerRevealed.insert(item.id)
                    } else {
                        path.append(.detail(item))
                    }
                }) {
                    ZStack(alignment: .bottomLeading) {
                        heroArt(item: item)
                        LinearGradient(
                            colors: [Color.black.opacity(0), Color.black.opacity(0.75)],
                            startPoint: .top, endPoint: .bottom
                        )
                        if isHeroBlurred(item: item) {
                            HStack(spacing: 6) {
                                Image(systemName: "eye")
                                    .font(.haoDenseTitle)
                                Text("点按查看海报")
                                    .font(.haoDenseTitle)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .haoDarkGlassCapsule(darkness: 0.6)
                            .padding(.horizontal, HaoLayout.pageMargin)
                            .padding(.bottom, 28)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    // sweep-5 P2-33: back to the 22pt
                                    // detail-title token — the b42 24pt
                                    // broke the app-wide title scale
                                    // (chen 2026-11-25: all pages
                                    // visually aligned); the hero is
                                    // the page's one big moment, but
                                    // it is a detail title, not a
                                    // page title.
                                    .font(.haoDetailTitle)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    if let year = item.year, !year.isEmpty {
                                        Text(year)
                                    }
                                    if let type = item.typeName, !type.isEmpty {
                                        Text(type)
                                    }
                                    if let remarks = item.remarks, !remarks.isEmpty {
                                        Text(remarks)
                                    }
                                }
                                .font(.haoFootnoteMedium)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                            }
                            .padding(.horizontal, HaoLayout.pageMargin)
                            .padding(.bottom, 28)
                        }
                    }
                }
                .buttonStyle(.plain)
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: heroHeight)
        // sweep-4 P2-19: a simultaneous drag gesture tracks the
        // user's swipe without stealing it from the TabView's own
        // paging gesture — while a drag is in flight (or within
        // 5 s after one) the timer stays out.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isHeroDragging = true }
                .onEnded { _ in
                    isHeroDragging = false
                    lastHeroInteraction = Date()
                }
        )
        .overlay(alignment: .bottom) {
            // Custom capsule dots (TV-App-SwiftUI): the selected
            // dot is a wide white capsule, the rest are small
            // white-0.5 dots.
            HStack(spacing: 6) {
                ForEach(heroItems.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == heroIndex ? Color.white : Color.white.opacity(0.5))
                        .frame(width: index == heroIndex ? 16 : 6, height: 6)
                }
            }
            .padding(.bottom, 10)
        }
        .onReceive(heroTimer) { _ in
            // b49 sweep #23: the publisher fires forever — advance
            // only while the hero is actually visible, the app is
            // foreground, and no page is pushed on top. sweep-4
            // P2-19 adds the drag gate: never mid-swipe, and never
            // within 5 s after a manual swipe. sweep-5 P2-19 adds
            // the tab gate (isSelected): onAppear / onDisappear
            // never fire on a tab switch, so the timer would
            // otherwise advance the hero of a hidden tab.
            guard heroTimerActive, isSelected, scenePhase == .active, path.isEmpty,
                  !isHeroDragging,
                  Date().timeIntervalSince(lastHeroInteraction) > 5,
                  heroItems.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                heroIndex = (heroIndex + 1) % heroItems.count
            }
        }
        .onAppear { heroTimerActive = true }
        .onDisappear { heroTimerActive = false }
        .onChange(of: heroItems.count) { _, _ in
            if heroIndex >= heroItems.count { heroIndex = 0 }
        }
    }

    /// Hero art (b49 sweep #36): the 2:3 poster used to be
    /// hard-cropped to 16:10 (scaledToFill), cutting faces and
    /// title text. It is now the blurred full poster under the
    /// dark gradient — VidHub's backdrop treatment, since CMS
    /// supplies no landscape art.
    private func heroArt(item: VideoItem) -> some View {
        Group {
            if item.detailSource == .emby {
                EmbyPosterImage(urlString: item.coverURL?.absoluteString ?? "", cornerRadius: 0)
            } else if let url = item.coverURL {
                HaoCachedImage(
                    urlString: url.absoluteString,
                    targetWidth: UIScreen.main.bounds.width,
                    targetHeight: heroHeight
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(theme.surfaceStrong)
                }
            } else {
                Rectangle().fill(theme.surfaceStrong)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
        .blur(radius: 24)
        .clipped()
    }

    private var searchEntry: some View {
        Button(action: { path.append(.search) }) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.haoSubheadStrong)
                    .foregroundStyle(theme.textMuted)
                Text("搜索影片、剧集")
                    .font(.haoSubhead)
                    .foregroundStyle(theme.textMuted)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: HaoLayout.searchFieldHeight)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // First chip, never scrolled out of sight: the
                // browse page (build 36 item 18), first visible
                // category pre-selected.
                Button(action: { path.append(.browse(nil)) }) {
                    Label("浏览全部", systemImage: "square.grid.2x2")
                        .font(.haoDenseBody)
                        .foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                ForEach(viewModel.categories, id: \.self) { type in
                    Button(action: { path.append(.category(type)) }) {
                        Text(type)
                            .font(.haoDenseBody)
                            .foregroundStyle(theme.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(theme.surface, in: Capsule())
                            .overlay {
                                Capsule().strokeBorder(theme.hairline, lineWidth: 0.5)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, HaoLayout.pageMargin)
        }
    }

    private var libraryRow: some View {
        HStack(spacing: 12) {
            Button(action: { path.append(.history) }) {
                Label("观看历史", systemImage: "clock")
                    .font(.haoDenseBody)
                    .foregroundStyle(theme.accentText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(theme.accentSoft, in: Capsule())
            }
            .buttonStyle(.plain)
            Button(action: { path.append(.favourites) }) {
                Label("我的收藏", systemImage: "heart")
                    .font(.haoDenseBody)
                    .foregroundStyle(theme.accentText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(theme.accentSoft, in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("继续观看")
                    .font(.haoSectionTitle)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Button("全部") { path.append(.history) }
                    .font(.haoDenseBody)
                    .foregroundStyle(theme.accentText)
            }
            .padding(.horizontal, HaoLayout.pageMargin)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.continueWatching) { entry in
                        VideoContinueCard(entry: entry) {
                            path.append(.detail(entry.item))
                        }
                    }
                }
                .padding(.horizontal, HaoLayout.pageMargin)
            }
        }
    }

    private func homeRowSection(_ row: VideoHomeRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(row.title)
                    .font(.haoSectionTitle)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                // Same 14pt medium accent style as the continue
                // section's "全部". The daily row opens its own
                // list (sweep-3 A16); every other row passes its
                // own type to the browse page.
                Button("全部") {
                    if row.id == "daily" {
                        path.append(.dailyList(row.items))
                    } else {
                        path.append(.browse(row.title))
                    }
                }
                    .font(.haoDenseBody)
                    .foregroundStyle(theme.accentText)
            }
            .padding(.horizontal, HaoLayout.pageMargin)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(row.items) { item in
                        VideoPosterCard(item: item, isWatched: viewModel.watchedKeys.contains(
                            VideoResumeKey.key(title: item.title, year: item.year)
                        )) {
                            path.append(.detail(item))
                        }
                        .frame(width: 120)
                    }
                }
                .padding(.horizontal, HaoLayout.pageMargin)
            }
        }
    }
}

/// One continue-watching card: small poster + title + episode +
/// progress bar (Flutter _ContinueCard).
struct VideoContinueCard: View {
    var entry: VideoHistoryEntry
    var onTap: () -> Void

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                VideoPosterCardImage(item: entry.item, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.item.title)
                        .font(.haoSubheadStrong)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(entry.episodeName.isEmpty ? "正片" : entry.episodeName)
                        .font(.haoCaption)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                    if entry.durationSeconds > 0 {
                        ProgressView(value: entry.progress)
                            .tint(theme.accent)
                            // Full text-column width (was a fixed
                            // 120pt, so the bar stopped well short
                            // of the title above it and read as an
                            // orphaned stub — build-35 polish).
                            .frame(maxWidth: .infinity)
                        Text(videoTimeText(seconds: entry.positionSeconds))
                            .font(.haoCaption2)
                            .foregroundStyle(theme.textMuted)
                    } else {
                        Text("上次看到这里")
                            .font(.haoCaption2)
                            .foregroundStyle(theme.textMuted)
                    }
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 260, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(MusicPressScaleStyle())
    }
}

/// Small square-ish poster thumb used by the continue card (the
/// full VideoPosterCard carries its own title/meta lines, which
/// the card does not want).
struct VideoPosterCardImage: View {
    var item: VideoItem
    var size: CGFloat

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            // Emby thumbs need the server token in the request
            // header (EmbyPosterImage); plain AsyncImage sends
            // none, so continue-watching cards and history rows
            // showed placeholder tiles for every Emby title.
            if item.detailSource == .emby {
                EmbyPosterImage(urlString: item.coverURL?.absoluteString ?? "", cornerRadius: 8)
            } else if let url = item.coverURL {
                // Shared loader (build 36 item 10 leg 6): thumb is
                // size x 2/3 wide — decode that, not the original.
                HaoCachedImage(
                    urlString: url.absoluteString,
                    targetWidth: size * 2 / 3,
                    targetHeight: size
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: size * 2 / 3, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.surfaceStrong)
            .overlay {
                Image(systemName: "film")
                    .font(.haoCallout)
                    .foregroundStyle(theme.textSecondary)
            }
    }
}

/// mm:ss / h:mm:ss for video positions (shared by the video pages).
func videoTimeText(seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}

/// The "每日推荐" row's full list (sweep-3 A16): the row's items
/// as loaded, in the shared poster grid — a static snapshot, no
/// filters, no paging (the daily list is one fetch, not a
/// browsable category). The row's "全部" used to open the browse
/// page with no type (first category), which is not the daily
/// list at all.
struct VideoDailyListView: View {
    var items: [VideoItem]
    var onSelect: (VideoItem) -> Void

    @Environment(\.haoTheme) private var theme

    var body: some View {
        ScrollView {
            if items.isEmpty {
                MusicEmptyState(
                    icon: "film",
                    title: "今日暂无推荐",
                    note: "每日推荐为空，稍后再来看看。"
                )
                .padding(.horizontal, HaoLayout.pushedPageMargin)
                .padding(.top, 32)
            } else {
                VideoPosterGrid(items: items) { onSelect($0) }
                    .padding(.horizontal, HaoLayout.pushedPageMargin)
                    .padding(.top, 16)
                Spacer(minLength: 16)
            }
        }
        .haoBottomChromeContentPadding()
        .background(theme.scaffoldBackground)
        .navigationTitle("每日推荐")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// HAo Studio 2.0 — live tab (S4-C leg).
//
// Home tab for 直播: five-platform row + category strip +
// search entry + follow row + history row + recommended rooms
// grid (Flutter live_tab_page.dart, Pure Live layout). Pull to
// refresh; paged "load more" at the grid footer.
//
// Data: the tab talks ONLY to LiveDataGateway (the C-leg seam;
// B leg provides the adapter at merge). Until a gateway is
// wired the recommend section says so honestly and the tab
// still shows the local rows (follows + history, real data) —
// never fake rooms. Tapping a room card records a history entry
// first (Flutter L01), then opens the room page with the current
// list as the switch playlist (Flutter L04).
//
// Merge requirement (coordinator): B-leg LiveRoom must be
// Hashable in its own file (Services/LiveSites/LiveModels.swift)
// — LiveDestination carries rooms, and the S3 lesson is that a
// Hashable conformance belongs in the file that declares the
// type, never in an extension elsewhere.

import SwiftUI

/// Live tab navigation destinations.
enum LiveDestination: Hashable {
    case search
    case follows
    case history
    case room(LiveRoom, [LiveRoom])
}

@MainActor
final class LiveTabViewModel: ObservableObject {
    @Published private(set) var rooms: [LiveRoom] = []
    @Published private(set) var categories: [String] = []
    @Published private(set) var follows: [LiveFollowedRoom] = []
    @Published private(set) var history: [LiveHistoryEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    @Published private(set) var loadingMore = false
    @Published private(set) var loadMoreFailed = false
    @Published private(set) var hasMore = false
    /// (b49fix2 P2-3) The category strip failed to load: the
    /// strip shows a retry in its place instead of vanishing
    /// silently. Kept separate from `categories.isEmpty` so a
    /// platform that genuinely has no categories (empty success)
    /// does not show a retry for nothing.
    @Published private(set) var categoriesFailed = false
    /// (b49fix2 P2-2) The current load-more page failed twice
    /// in a row: terminal — no more auto-loads, no more retry
    /// button, just a note to pull down and refresh.
    @Published private(set) var loadMoreDead = false

    @Published var platform: LivePlatform = .bilibili
    @Published var selectedArea: String?
    /// Platforms the settings switches leave enabled (b49 sweep
    /// #2): the tabs only ever show these. Refreshed on every
    /// appear / reload, because the user may have toggled a
    /// platform in settings since the tab last loaded.
    @Published private(set) var enabledPlatforms: [LivePlatform] = LivePlatform.enabledCases

    /// The gateway, readable so the search page can share it.
    let gateway: LiveDataGateway?
    private var page = 0
    /// (b49fix2 P2-2) Consecutive load-more failures for one
    /// page: the first shows the retry row, the second marks
    /// the page dead. Reset by any fresh load / success.
    private var loadMoreFailureCount = 0
    private var loadMoreFailedPage: Int?
    /// Load generation (build 35 sweep S4): bumped by every
    /// `reload()` / category change, so a slow answer for the old
    /// platform / area can never overwrite the new one — fast
    /// platform switching used to show Bilibili's rooms under the
    /// Douyu tab, because the in-flight load was neither
    /// cancelled nor checked.
    private var loadGeneration = 0

    /// `gateway` nil = no live source wired yet (merge provides
    /// the B-leg adapter); the tab still shows local rows.
    init(gateway: LiveDataGateway? = nil) {
        self.gateway = gateway
    }

    /// No gateway wired (merge provides the adapter).
    var hasGateway: Bool { gateway != nil }

    /// Fresh-list state: page 0, no rooms, no load-more state.
    /// Callers bump `loadGeneration` themselves (each site owns
    /// its generation bump for the in-flight callbacks).
    private func resetListState() {
        page = 0
        rooms = []
        hasMore = false
        loadMoreFailed = false
        loadMoreDead = false
        loadMoreFailureCount = 0
        loadMoreFailedPage = nil
    }

    func reload() {
        refreshEnabledPlatforms()
        follows = LiveLibraryStore.follows()
        history = LiveLibraryStore.history()
        resetListState()
        loadGeneration += 1
        loadFresh()
        loadCategories()
    }

    /// Refresh only the local rows (follows + history), without
    /// touching the recommend grid (build 35 sweep S4): entering
    /// a room used to call `reload()`, which cleared `rooms` and
    /// re-fetched — so every return from a room flashed the grid
    /// empty and lost the scroll position. `openRoom` calls this;
    /// the grid only reloads on pull-to-refresh / platform /
    /// category change, or when it has never loaded.
    func refreshLibrary() {
        follows = LiveLibraryStore.follows()
        history = LiveLibraryStore.history()
    }

    /// What the tab's `onAppear` calls (build 35 sweep S4): the
    /// local rows always refresh (a follow toggled in the room
    /// must show on return), but the recommend grid only loads
    /// when it has nothing — returning from a room used to
    /// re-run `reload()` and wipe the grid + scroll position.
    func loadIfNeeded() {
        refreshLibrary()
        if refreshEnabledPlatforms() {
            // (b49fix2 P1-25) The platform moved under the grid:
            // drop the old platform's rooms and categories and
            // reload, like `reload()` does — the old code only
            // flipped the tab and left the old grid underneath
            // it until `rooms` happened to be empty.
            resetListState()
            categories = []
            categoriesFailed = false
            loadFailed = false
            loadGeneration += 1
            loadFresh()
            loadCategories()
            return
        }
        if rooms.isEmpty && !isLoading {
            loadFresh()
        }
        if categories.isEmpty {
            loadCategories()
        }
    }

    /// Re-read the enabled platforms from the settings switches
    /// (b49 sweep #2) and move off a platform that was just
    /// switched off: the selected platform must always be one of
    /// the enabled tabs, or the tab would fetch a platform the
    /// user turned off. Returns whether the platform moved, so
    /// the caller can drop the old platform's grid (b49fix2
    /// P1-25). All platforms off leaves the selection alone —
    /// there is nothing to move to, and the adapter answers
    /// `.empty` for a disabled platform instead of trapping
    /// on `enabledPlatforms[0]`.
    @discardableResult
    private func refreshEnabledPlatforms() -> Bool {
        enabledPlatforms = LivePlatform.enabledCases
        guard !enabledPlatforms.contains(platform) else { return false }
        guard let first = enabledPlatforms.first else { return false }
        platform = first
        selectedArea = nil
        return true
    }

    func selectPlatform(_ next: LivePlatform) {
        guard next != platform, enabledPlatforms.contains(next) else { return }
        platform = next
        selectedArea = nil
        reload()
    }

    func selectCategory(_ area: String?) {
        guard area != selectedArea else { return }
        selectedArea = area
        resetListState()
        loadGeneration += 1
        loadFresh()
    }

    func loadFresh() {
        // Build 35 sweep S4: no `!isLoading` start-guard — a
        // reload during a load must still start a fetch, or the
        // tab is left empty with nothing in flight (the old
        // guard dropped the new load and the stale callback then
        // bailed). Concurrent fetches are arbitrated by the
        // generation check in the callback below.
        guard let gateway = gateway else { return }
        isLoading = true
        loadFailed = false
        // A fresh load supersedes any dead load-more page.
        loadMoreFailed = false
        loadMoreDead = false
        loadMoreFailureCount = 0
        loadMoreFailedPage = nil
        let platformId = platform.rawValue
        let area = selectedArea
        let generation = loadGeneration
        gateway.fetchRecommended(platform: platformId, area: area, page: 0) { [weak self] result in
            guard let self = self else { return }
            // Stale answer (platform / area moved on): touch
            // nothing — not even `isLoading`, which the current
            // load's callback owns.
            guard generation == self.loadGeneration,
                  platformId == self.platform.rawValue,
                  area == self.selectedArea else { return }
            self.isLoading = false
            if result.failed {
                // (b49fix2 P2-1) The load failed: the rooms stay
                // (they may still be good) and loadFailed shows
                // the retry row under them. An empty success is
                // NOT this branch — see below.
                self.loadFailed = true
            } else if result.rooms.isEmpty {
                // (b49fix2 P2-1) Genuine empty: the platform has
                // no rooms right now. Not a failure — the empty
                // state says "暂无直播间", not "加载失败".
                self.rooms = []
                self.hasMore = false
                self.page = 0
            } else {
                // Dedupe by platform + room id before the grid
                // sees the list: a recommend page can repeat a
                // room, and duplicate ForEach identities misplace
                // cells (fix 2026-11-24).
                self.rooms = deduplicatedLiveRooms(result.rooms)
                self.hasMore = result.hasMore
                self.page = 0
            }
        }
    }

    func loadMore() {
        guard let gateway = gateway, hasMore, !loadingMore, !isLoading else { return }
        loadingMore = true
        loadMoreFailed = false
        let nextPage = page + 1
        let platformId = platform.rawValue
        let area = selectedArea
        let generation = loadGeneration
        gateway.fetchRecommended(platform: platformId, area: area, page: nextPage) { [weak self] result in
            guard let self = self else { return }
            // The loading flag is always cleared (no newer
            // loadMore can be in flight — the `!loadingMore`
            // guard above forbids it); the data is only applied
            // when this answer is still current.
            self.loadingMore = false
            guard generation == self.loadGeneration,
                  platformId == self.platform.rawValue,
                  area == self.selectedArea else { return }
            if result.failed {
                // (b49fix2 P2-2) A page that deterministically
                // fails must not be retried forever: the first
                // failure shows the retry row, the second
                // consecutive failure for the same page marks it
                // dead and stops paging.
                self.noteLoadMoreFailure(page: nextPage)
                return
            }
            if result.rooms.isEmpty {
                // (b49fix2 P2-1) Genuine end of list, not a
                // failure: stop paging, no retry row.
                self.hasMore = false
                return
            }
            // A platform that repeats a page (or a page that only
            // overlaps the rooms already shown) appends nothing:
            // report it as a failed load-more, never duplicate
            // cards — ForEach identity is the room itself
            // (platform + room id) and must never see a repeat.
            let known = Set(self.rooms.map { $0.platform.rawValue + "|" + $0.roomId })
            let fresh = deduplicatedLiveRooms(result.rooms)
                .filter { !known.contains($0.platform.rawValue + "|" + $0.roomId) }
            if fresh.isEmpty {
                // Same page, same answer on retry: count it
                // toward the dead page, or the retry row would
                // loop forever on a page that can never append.
                self.noteLoadMoreFailure(page: nextPage)
                return
            }
            self.loadMoreFailureCount = 0
            self.loadMoreFailedPage = nil
            self.rooms.append(contentsOf: fresh)
            self.hasMore = result.hasMore
            self.page = nextPage
        }
    }

    /// (b49fix2 P2-2) Record one load-more failure for a page:
    /// first consecutive failure → retry row; second → the page
    /// is dead (terminal note, paging stops).
    private func noteLoadMoreFailure(page: Int) {
        if loadMoreFailedPage == page {
            loadMoreFailureCount += 1
        } else {
            loadMoreFailedPage = page
            loadMoreFailureCount = 1
        }
        loadMoreFailed = true
        if loadMoreFailureCount >= 2 {
            loadMoreDead = true
            hasMore = false
        }
    }

    /// (b49fix2 P2-3) Internal (not private) — the category
    /// strip's retry button calls it from the view.
    func loadCategories() {
        guard let gateway = gateway else {
            categories = []
            return
        }
        let platformId = platform.rawValue
        let generation = loadGeneration
        gateway.fetchCategories(platform: platformId) { [weak self] result in
            guard let self = self,
                  generation == self.loadGeneration,
                  platformId == self.platform.rawValue else { return }
            switch result {
            case .success(let names):
                self.categoriesFailed = false
                self.categories = names
            case .failure:
                // Keep any previously loaded strip; the strip
                // shows its own retry while this is set.
                self.categoriesFailed = true
            }
        }
    }
}

struct LiveTabView: View {
    @StateObject private var viewModel: LiveTabViewModel
    @State private var path: [LiveDestination] = []
    /// (sweep-5 P2-12, sibling of the search grid) This tab's
    /// own laid-out grid width — same preference-key pattern
    /// as the search page; 0 until the first measurement.
    @State private var gridWidth: CGFloat = 0

    @Environment(\.haoTheme) private var theme

    /// `gateway` nil = no live source wired (the tab then shows
    /// the honest empty state for recommend + search). Production
    /// passes `LiveDataGatewayAdapter.shared` (MainTabView).
    init(gateway: LiveDataGateway? = nil) {
        _viewModel = StateObject(wrappedValue: LiveTabViewModel(gateway: gateway))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Scroll anchor for the bottom chrome (b35 tab-bar
                        // link): drives minimize / restore as this tab scrolls.
                        HaoChromeScrollAnchor()
                            .id(HaoTabScrollTop.id(for: .live))
                        // b42: in-content large title + header
                        // buttons (HomeView's homeHeader pattern).
                        // The system large title is unreliable on
                        // chen's iPhone Air in this setup — build 41
                        // it renders at the category-strip's height,
                        // so the red "全部" chip sits ON the "直播"
                        // title, and the toolbar's clock+heart pill
                        // covers the "快手" platform tab. A title
                        // row in the scroll content is ordinary
                        // VStack layout: it sits above the platform
                        // row and cannot be covered by the chips.
                        liveHeader
                        platformRow
                            .padding(.top, 12)
                        if !viewModel.categories.isEmpty {
                            categoryStrip
                                .padding(.top, 12)
                        } else if viewModel.categoriesFailed {
                            // (b49fix2 P2-3) The strip failed to
                            // load: a retry in its place, same
                            // slot as the strip, instead of
                            // silently hiding the categories.
                            Button("分类加载失败，点击重试") { viewModel.loadCategories() }
                                .font(.haoFootnoteMedium)
                                .foregroundStyle(theme.accentText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 24)
                                .padding(.top, 12)
                                .buttonStyle(.plain)
                        }
                        searchEntry
                            .padding(.horizontal, 24)
                            .padding(.top, 12)
                        if !viewModel.follows.isEmpty {
                            followSection
                                .padding(.top, 16)
                        }
                        if !viewModel.history.isEmpty {
                            historySection
                                .padding(.top, 16)
                        }
                        recommendSection
                            .padding(.top, 16)
                        Spacer(minLength: 16)
                    }
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: LiveGridWidthKey.self, value: proxy.size.width)
                        }
                    )
                    .haoBottomChromeContentPadding()
                }
                .onPreferenceChange(LiveGridWidthKey.self) { gridWidth = $0 }
                .haoChromeScrollTracking()
                .haoReselectScrollToTop(tab: .live, proxy: proxy)
                .refreshable { viewModel.reload() }
                .haoBackdropLayer()
                .haoTabBackground()
                // (b49fix2 B11) Fixed chrome (header, tabs, chips,
                // search field, 140pt cards) is laid out at fixed
                // sizes: cap Dynamic Type at accessibility1 so the
                // chrome cannot blow out at larger sizes. Pushed
                // pages inherit the cap through the stack.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                // b42: no system nav bar on this root (see
                // liveHeader above — the system large title and
                // toolbar pill overlap the content on chen's
                // phone). Pushed pages keep their own bars and
                // back buttons.
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: LiveDestination.self) { destination in
                    switch destination {
                    case .search:
                        LiveSearchView(gateway: viewModel.gateway, onSelect: { room, rooms in
                            openRoom(room, playlist: rooms)
                        })
                    case .follows:
                        LiveFollowsView(onSelect: { room in
                            openRoom(room, playlist: [room])
                        })
                    case .history:
                        LiveHistoryView(onSelect: { room in
                            openRoom(room, playlist: [room])
                        })
                    case .room(let room, let playlist):
                        LiveRoomView(room: room, playlist: playlist)
                    }
                }
                .onAppear { viewModel.loadIfNeeded() }
                // Follow toggles from a card's long-press menu (or the
                // room page, or the follows page's swipe delete) write
                // the store directly — refresh the local rows at once
                // instead of waiting for the next appear.
                .onReceive(NotificationCenter.default.publisher(for: .haoLiveFollowChanged)) { _ in
                    viewModel.refreshLibrary()
                }
            }
        }
    }

    /// Enter a room: record history first (Flutter L01), then
    /// navigate with the current list as the switch playlist.
    /// Only the local rows refresh (build 35 sweep S4) — the
    /// recommend grid keeps its rooms and scroll position.
    private func openRoom(_ room: LiveRoom, playlist: [LiveRoom]) {
        LiveLibraryStore.recordHistory(
            platform: room.platform.rawValue, roomId: room.roomId,
            title: room.title, nick: room.streamer, cover: room.cover,
            playUrlsJSON: LiveLibraryStore.playUrlsJSON(from: room.data))
        viewModel.refreshLibrary()
        path.append(.room(room, playlist))
    }

    // MARK: - In-content large title (b42)

    /// Same 34pt bold title as HomeView's homeHeader, as a row
    /// in the scroll content — it can never be covered by the
    /// category chips, because it is ordinary VStack layout. The
    /// history / follows buttons move here from the nav bar
    /// (their pill used to cover the "快手" platform tab); they
    /// sit in the header row, above the platform row, as plain
    /// icon buttons with a full 40pt hit target.
    private var liveHeader: some View {
        HStack(alignment: .center) {
            Text("直播")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Button(action: { path.append(.history) }) {
                Image(systemName: "clock")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("观看历史")
            Button(action: { path.append(.follows) }) {
                Image(systemName: "heart")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("我的关注")
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    // MARK: - Platform row (Big-5 only, Pure Live TabBar style)

    /// Text tabs, not capsule chips (Pure Live home TabBar):
    /// the selected platform reads in the accent with a 2.5pt
    /// indicator bar under it, the rest in secondary. The
    /// category strip below keeps capsule chips, so the two
    /// levels of navigation no longer look equal — platform is
    /// the tab level, category is the chip level.
    private var platformRow: some View {
        LivePlatformTextTabs(
            platforms: viewModel.enabledPlatforms,
            selected: viewModel.platform) { platform in
            viewModel.selectPlatform(platform)
        }
    }

    // MARK: - Category strip

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button(action: { viewModel.selectCategory(nil) }) {
                    Text("全部")
                        .font(.haoDenseBody)
                        .foregroundStyle(
                            viewModel.selectedArea == nil
                                ? theme.onAccent : theme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            viewModel.selectedArea == nil
                                ? theme.accent : theme.surface,
                            in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(theme.hairline, lineWidth: 0.5)
                        }
                }
                .buttonStyle(.plain)
                ForEach(viewModel.categories, id: \.self) { area in
                    Button(action: { viewModel.selectCategory(area) }) {
                        Text(area)
                            .font(.haoDenseBody)
                            .foregroundStyle(
                                viewModel.selectedArea == area
                                    ? theme.onAccent : theme.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                viewModel.selectedArea == area
                                    ? theme.accent : theme.surface,
                                in: Capsule())
                            .overlay {
                                Capsule().strokeBorder(theme.hairline, lineWidth: 0.5)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Search entry

    private var searchEntry: some View {
        Button(action: { path.append(.search) }) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.haoSubheadStrong)
                    .foregroundStyle(theme.textMuted)
                // (sweep-6 P1-1) The placeholder sits on
                // theme.surface: muted fails AA there in dark
                // gold/mint/ice-blue — textSecondary passes.
                Text("搜索直播间、主播")
                    .font(.haoSubhead)
                    .foregroundStyle(theme.textSecondary)
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

    // MARK: - Follow row

    private var followSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "我的关注") { path.append(.follows) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.follows) { follow in
                        LiveFollowCard(follow: follow) {
                            let room = follow.toRoom()
                            openRoom(room, playlist: [room])
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - History row

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "最近看过") { path.append(.history) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.history) { entry in
                        LiveHistoryCard(entry: entry) {
                            let room = entry.toRoom()
                            openRoom(room, playlist: [room])
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func sectionHeader(title: String, onAll: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.haoSectionTitle)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Button("全部", action: onAll)
                .font(.haoDenseBody)
                .foregroundStyle(theme.accentText)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Recommend grid

    private var recommendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("推荐直播")
                    .font(.haoSectionTitle)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 24)
            if viewModel.isLoading && viewModel.rooms.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else if viewModel.rooms.isEmpty {
                MusicEmptyState(
                    icon: "antenna.radiowaves.left.and.right",
                    title: viewModel.hasGateway
                        ? (viewModel.loadFailed ? "加载失败" : "暂无直播间")
                        : "直播源尚未接入",
                    note: viewModel.hasGateway
                        ? (viewModel.loadFailed ? "直播源没有返回数据，下拉重试。" : "该平台暂时没有在播的房间。")
                        : "推荐直播由直播源提供，接入后在这里显示。关注与历史不受影响。"
                )
                .padding(.horizontal, 24)
                if viewModel.hasGateway && viewModel.loadFailed {
                    // (sweep-6 P2-6) Standard retry capsule:
                    // 15 semibold, 24/12.
                    Button("重试") { viewModel.loadFresh() }
                        .font(.haoSubheadStrong)
                        .foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(theme.accent, in: Capsule())
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                }
            } else {
                LazyVGrid(
                    columns: LiveGridLayout.gridColumns(forWidth: gridWidth > 0 ? gridWidth : UIScreen.main.bounds.width),
                    spacing: LiveGridLayout.gridRowSpacing
                ) {
                    // Identity is the room itself: LiveRoom's
                    // Hashable is platform + room id (roomId
                    // alone is NOT unique — fix 2026-11-24).
                    ForEach(viewModel.rooms, id: \.self) { room in
                        LiveRoomCard(room: room) {
                            openRoom(room, playlist: viewModel.rooms)
                        }
                    }
                }
                .padding(.horizontal, LiveGridLayout.gridEdgePadding)
                if viewModel.loadFailed {
                    // (b49 sweep #34) The last refresh returned
                    // empty over these rooms: say so and offer a
                    // retry instead of leaving stale rooms with no
                    // indication. loadFresh clears the flag when it
                    // starts, so a good refresh hides this row.
                    // (sweep-6 P2-6) Inline text retry: 13 medium
                    // with the same 12pt top as the categories
                    // retry above; the bottom stays 16.
                    Button("刷新没有返回新房间，点击重试") { viewModel.loadFresh() }
                        .font(.haoFootnoteMedium)
                        .foregroundStyle(theme.accentText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                        .buttonStyle(.plain)
                } else if viewModel.loadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else if viewModel.loadMoreDead {
                    // (b49fix2 P2-2) Terminal: this page failed
                    // twice — no retry button, no more auto-loads.
                    // Pull-to-refresh (reload) is the way out.
                    Text("这一页暂时加载不出来，下拉刷新试试。")
                        .font(.haoFootnoteMedium)
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else if viewModel.loadMoreFailed {
                    // (sweep-6 P2-6) Inline text retry: 13 medium
                    // with the same 12pt top as the other inline
                    // retries; the bottom stays 16.
                    Button("加载失败，点击重试") { viewModel.loadMore() }
                        .font(.haoFootnoteMedium)
                        .foregroundStyle(theme.accentText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                        .buttonStyle(.plain)
                } else if viewModel.hasMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .onAppear { viewModel.loadMore() }
                }
            }
        }
    }
}

/// One followed room in the tab's horizontal follow row: cover
/// + nick + title. No LIVE badge: stored entries carry no live
/// status by design (the pages show the stored title/cover/nick,
/// never a faked badge — same rule as the follows page).
struct LiveFollowCard: View {
    var follow: LiveFollowedRoom
    var onTap: () -> Void

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    followCover
                        .aspectRatio(16.0 / 9.0, contentMode: .fill)
                        .frame(width: 140)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                Text(follow.nick.isEmpty ? follow.title : follow.nick)
                    .font(.haoFootnoteStrong)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
                Text(follow.title.isEmpty ? "直播间" : follow.title)
                    .font(.haoCaption)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
            }
        }
        .buttonStyle(MusicPressScaleStyle())
    }

    @ViewBuilder
    private var followCover: some View {
        if let url = URL(string: follow.cover), !follow.cover.isEmpty {
            // Shared loader (build 36 item 10 leg 6): 140pt-wide
            // 16:9 card — decode 140x79, not the original.
            HaoCachedImage(
                urlString: follow.cover,
                targetWidth: 140,
                targetHeight: 79
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                followCoverPlaceholder
            }
        } else {
            followCoverPlaceholder
        }
    }

    private var followCoverPlaceholder: some View {
        Rectangle()
            .fill(theme.surfaceStrong)
            .overlay {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 18))
                    .foregroundStyle(theme.textSecondary)
            }
    }
}

/// One history entry in the tab's horizontal history row: cover
/// + title + relative time.
struct LiveHistoryCard: View {
    var entry: LiveHistoryEntry
    var onTap: () -> Void

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                historyCover
                    .aspectRatio(16.0 / 9.0, contentMode: .fill)
                    .frame(width: 140)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(entry.title.isEmpty ? "直播间" : entry.title)
                    .font(.haoFootnoteStrong)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
                Text(liveRelativeTimeText(date: entry.watchedAt))
                    .font(.haoCaption)
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
            }
        }
        .buttonStyle(MusicPressScaleStyle())
    }

    @ViewBuilder
    private var historyCover: some View {
        if let url = URL(string: entry.cover), !entry.cover.isEmpty {
            // Shared loader (build 36 item 10 leg 6): 140pt-wide
            // 16:9 card — decode 140x79, not the original.
            HaoCachedImage(
                urlString: entry.cover,
                targetWidth: 140,
                targetHeight: 79
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                historyCoverPlaceholder
            }
        } else {
            historyCoverPlaceholder
        }
    }

    private var historyCoverPlaceholder: some View {
        Rectangle()
            .fill(theme.surfaceStrong)
            .overlay {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 18))
                    .foregroundStyle(theme.textSecondary)
            }
    }
}

// MARK: - Store entries back to rooms

/// The follow/history pages and tab rows open rooms from stored
/// entries. The conversion is a plain method (not a protocol
/// conformance), so it may live here: the stored fields map
/// one-to-one onto the B-leg room fields (Flutter
/// LiveFollow.toRoom / LiveHistoryEntry.toRoom).
extension LiveFollowedRoom {
    func toRoom() -> LiveRoom {
        LiveRoom(
            roomId: roomId, platform: LivePlatform(rawValue: platform) ?? .bilibili,
            title: title, streamer: nick, avatar: "", cover: cover,
            onlineCount: 0, isLive: false, link: "",
            data: LiveLibraryStore.playUrlsData(from: playUrlsJSON))
    }
}

extension LiveHistoryEntry {
    func toRoom() -> LiveRoom {
        LiveRoom(
            roomId: roomId, platform: LivePlatform(rawValue: platform) ?? .bilibili,
            title: title, streamer: nick, avatar: "", cover: cover,
            onlineCount: 0, isLive: false, link: "",
            data: LiveLibraryStore.playUrlsData(from: playUrlsJSON))
    }
}

// MARK: - Shared platform text tabs (Pure Live home TabBar style)

/// The one platform switcher the live tab and live search share:
/// text tabs with a 2.5pt accent indicator under the selected
/// platform, the rest in secondary. Same weight (medium) selected
/// and unselected, so selecting never changes a tab's width and
/// the strip never jumps. Used by LiveTabView and LiveSearchView
/// so the two pages cannot drift apart again.
struct LivePlatformTextTabs: View {
    /// Platforms to show (b49 sweep #2): the live tab passes the
    /// settings-enabled list; the search page does the same. The
    /// default is all five, so a caller that does not filter
    /// behaves exactly as before.
    var platforms: [LivePlatform] = LivePlatform.allCases
    var selected: LivePlatform
    /// (sweep-6 P2-1) The strip's own horizontal padding IS the
    /// page's side margin: 24 on the tab root (the default),
    /// 20 on the pushed search page (pushedPageMargin).
    var edgePadding: CGFloat = 24
    var onSelect: (LivePlatform) -> Void

    @Environment(\.haoTheme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(platforms) { platform in
                    Button(action: { onSelect(platform) }) {
                        VStack(spacing: 6) {
                            Text(platform.displayName)
                                .font(.haoSubheadMedium)
                                .foregroundStyle(
                                    platform == selected
                                        ? theme.accentText : theme.textSecondary)
                            Capsule()
                                .fill(platform == selected ? theme.accent : Color.clear)
                                .frame(height: 2.5)
                                .animation(HaoLayout.settleSpring, value: selected)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, edgePadding)
        }
        .haoSensoryFeedback(.selection, trigger: selected)
    }
}

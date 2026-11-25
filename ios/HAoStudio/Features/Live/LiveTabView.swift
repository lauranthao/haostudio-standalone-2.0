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

    @Published var platform: LivePlatform = .bilibili
    @Published var selectedArea: String?

    /// The gateway, readable so the search page can share it.
    let gateway: LiveDataGateway?
    private var page = 0
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

    func reload() {
        follows = LiveLibraryStore.follows()
        history = LiveLibraryStore.history()
        page = 0
        rooms = []
        hasMore = false
        loadMoreFailed = false
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
        if rooms.isEmpty && !isLoading {
            loadFresh()
        }
        if categories.isEmpty {
            loadCategories()
        }
    }

    func selectPlatform(_ next: LivePlatform) {
        guard next != platform else { return }
        platform = next
        selectedArea = nil
        reload()
    }

    func selectCategory(_ area: String?) {
        guard area != selectedArea else { return }
        selectedArea = area
        page = 0
        rooms = []
        hasMore = false
        loadMoreFailed = false
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
            if result.rooms.isEmpty && self.rooms.isEmpty {
                self.loadFailed = true
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
            if result.rooms.isEmpty {
                self.loadMoreFailed = true
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
                self.loadMoreFailed = true
                return
            }
            self.rooms.append(contentsOf: fresh)
            self.hasMore = result.hasMore
            self.page = nextPage
        }
    }

    private func loadCategories() {
        guard let gateway = gateway else {
            categories = []
            return
        }
        let platformId = platform.rawValue
        let generation = loadGeneration
        gateway.fetchCategories(platform: platformId) { [weak self] names in
            guard let self = self,
                  generation == self.loadGeneration,
                  platformId == self.platform.rawValue else { return }
            self.categories = names
        }
    }
}

struct LiveTabView: View {
    @StateObject private var viewModel: LiveTabViewModel
    @State private var path: [LiveDestination] = []

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
                        platformRow
                            .padding(.top, 12)
                        if !viewModel.categories.isEmpty {
                            categoryStrip
                                .padding(.top, 12)
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
                    .haoBottomChromeContentPadding()
                }
                .haoChromeScrollTracking()
                .haoReselectScrollToTop(tab: .live, proxy: proxy)
                .refreshable { viewModel.reload() }
                .background(theme.scaffoldBackground)
                .navigationTitle("直播")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { path.append(.history) }) {
                            Image(systemName: "clock")
                        }
                        .accessibilityLabel("观看历史")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { path.append(.follows) }) {
                            Image(systemName: "heart")
                        }
                        .accessibilityLabel("我的关注")
                    }
                }
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
            title: room.title, nick: room.streamer, cover: room.cover)
        viewModel.refreshLibrary()
        path.append(.room(room, playlist))
    }

    // MARK: - Platform row (Big-5 only, Pure Live TabBar style)

    /// Text tabs, not capsule chips (Pure Live home TabBar):
    /// the selected platform reads in the accent with a 2.5pt
    /// indicator bar under it, the rest in secondary. The
    /// category strip below keeps capsule chips, so the two
    /// levels of navigation no longer look equal — platform is
    /// the tab level, category is the chip level.
    private var platformRow: some View {
        LivePlatformTextTabs(selected: viewModel.platform) { platform in
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
                Text("搜索直播间、主播")
                    .font(.haoSubhead)
                    .foregroundStyle(theme.textMuted)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
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
                    Button("重试") { viewModel.loadFresh() }
                        .font(.haoDenseTitle)
                        .foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(theme.accent, in: Capsule())
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                }
            } else {
                LazyVGrid(
                    columns: LiveGridLayout.gridColumns,
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
                if viewModel.loadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else if viewModel.loadMoreFailed {
                    Button("加载失败，点击重试") { viewModel.loadMore() }
                        .font(.haoFootnoteMedium)
                        .foregroundStyle(theme.accentText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
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
            onlineCount: 0, isLive: false, link: "")
    }
}

extension LiveHistoryEntry {
    func toRoom() -> LiveRoom {
        LiveRoom(
            roomId: roomId, platform: LivePlatform(rawValue: platform) ?? .bilibili,
            title: title, streamer: nick, avatar: "", cover: cover,
            onlineCount: 0, isLive: false, link: "")
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
    var selected: LivePlatform
    var onSelect: (LivePlatform) -> Void

    @Environment(\.haoTheme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(LivePlatform.allCases) { platform in
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
            .padding(.horizontal, 24)
        }
        .haoSensoryFeedback(.selection, trigger: selected)
    }
}

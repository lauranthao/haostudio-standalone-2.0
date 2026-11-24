// HAo Studio 2.0 — video browse page (build 36, item 18).
//
// Chen 2026-11-24: "影视所有都展示不全，要有单独页面可以打开，
// 里面可以选分类" + "Emby 也是啊". The video home only shows the
// first 10 rows × 10 items (and types 13+ never get a row), so this
// page is the full grid: type chips + area / year / sort filters
// (CMS) or library + genre pickers (Emby), paged to the bottom.
//
// "全部" semantics (decided): the page opens with the first visible
// category pre-selected and loading immediately — never an empty
// "pick a type first" dead end. CMS has no all-types endpoint, so
// there is no merged all-types grid; per-row "全部" opens the page
// pre-selected to that row's type, and the "每日推荐" row opens it
// with no type (first category). No fake "每日推荐" type is invented.
//
// The view-model copies the EmbyCategoryViewModel generation guard
// (stale-page drop + re-issue); VideoCategoryViewModel has none, so
// its gap is NOT copied here. Area filtering stays inside
// CmsClient.filterByTypeItems — VideoItem has no area field, so the
// UI never filters VideoItems by area itself. Emby mode shows no
// area / year / sort rows: the Emby gateway has none, and none are
// invented.
//
// Layout follows the VidHub reference: clean poster grid, filter
// chips on top, no clutter. Style reuses theme tokens exactly as
// categoryStrip / libraryChip do — no new colours, no hardcoded
// colours, no font-size changes (item 4 owns fonts).

import SwiftUI

@MainActor
final class VideoBrowseViewModel: ObservableObject {
    @Published private(set) var categories: [String] = []
    @Published private(set) var libraries: [VideoEmbyLibrary] = []
    @Published private(set) var genres: [String] = []
    @Published private(set) var items: [VideoItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    /// Human error text from the last failed Emby load
    /// (EmbyError.message). Set only on failure — an empty
    /// library stays an empty state, never an error state.
    @Published private(set) var errorMessage: String?

    /// Changing any of these reloads the grid from page 0 (one
    /// mechanism only: didSet + the ready gate below). The oldValue
    /// guard keeps a same-value assignment from refetching.
    @Published var selectedType: String? { didSet { if oldValue != selectedType { reload() } } }
    @Published var area = "all" { didSet { if oldValue != area { reload() } } }
    @Published var year = "all" { didSet { if oldValue != year { reload() } } }
    @Published var sort = "" { didSet { if oldValue != sort { reload() } } }
    @Published var mode: String { didSet { if oldValue != mode { reload() } } }
    @Published var selectedLibraryId: String? { didSet { if oldValue != selectedLibraryId { reload() } } }
    @Published var selectedGenre: String? { didSet { if oldValue != selectedGenre { reload() } } }

    private let gateway: VideoDataGateway
    private let initialType: String?
    private var page = 0
    private var loadingMore = false
    /// Load generation: every reload bumps it. A page that lands
    /// for an older generation is dropped and the current query
    /// re-issued — otherwise a filter change mid-pagination lands
    /// the stale page over fresh items (same class as the
    /// EmbyCategoryViewModel race, b35 sweep).
    private var generation = 0
    /// False until the first category list lands. didSet reloads
    /// before that point are no-ops: there is no selected type yet
    /// and nothing to fetch.
    private var ready = false

    init(initialType: String?, gateway: VideoDataGateway = VideoServices.makeGateway()) {
        self.initialType = initialType
        self.gateway = gateway
        self.mode = VideoLibraryStore.tabMode()
        loadMeta()
    }

    var isEmbyConfigured: Bool { gateway.embyConfigured }

    /// Quiet footnote above the Emby grid naming the active filter
    /// (nil = "全部" everywhere, nothing to say). With the sidebar
    /// closed the active library / genre is otherwise invisible.
    var activeEmbyFilterText: String? {
        var parts: [String] = []
        if let id = selectedLibraryId, let library = libraries.first(where: { $0.id == id }) {
            parts.append(library.name)
        }
        if let genre = selectedGenre { parts.append(genre) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// Category / library / genre lists. On the category list
    /// landing, the initial type is kept when it is still in the
    /// list (a refresh must not reset the user's pick), else the
    /// requested initial type, else the first visible category —
    /// hidden-category prefs apply via visibleCategories, so a
    /// hidden category never reappears here. Then the grid loads.
    private func loadMeta() {
        gateway.fetchTypeNames { [weak self] names in
            guard let self = self else { return }
            self.categories = VideoLibraryStore.visibleCategories(
                names, prefs: VideoLibraryStore.categoryPrefs())
            if let current = self.selectedType, self.categories.contains(current) {
                // Keep the user's pick across a refresh.
            } else if let initial = self.initialType, self.categories.contains(initial) {
                self.selectedType = initial
            } else {
                self.selectedType = self.categories.first
            }
            self.ready = true
            self.reload()
        }
        gateway.fetchEmbyLibraries { [weak self] libs in
            self?.libraries = libs
        }
        gateway.fetchEmbyGenres { [weak self] names in
            self?.genres = names
        }
    }

    /// Pull-to-refresh: re-fetch the lists (categories may have
    /// changed) and reload the grid from page 0.
    func refresh() {
        loadMeta()
    }

    func reload() {
        // The ready gate exists for CMS (the first category list
        // has not landed yet). Emby mode has no CMS categories to
        // wait for: a slow or dead CMS left the Emby grid on the
        // empty state forever. Emby bypasses the gate.
        guard ready || mode == "emby" else { return }
        generation += 1
        page = 0
        hasMore = true
        items = []
        errorMessage = nil
        loadMore()
    }

    func loadMore() {
        guard !loadingMore, hasMore else { return }
        if mode == "emby" {
            guard gateway.embyConfigured else { return }
        } else {
            guard selectedType != nil else { return }
        }
        loadingMore = true
        isLoading = true
        let requestGeneration = generation
        let pageToLoad = page
        if mode == "emby" {
            gateway.fetchEmbyItems(libraryId: selectedLibraryId, genre: selectedGenre, page: pageToLoad) { [weak self] result in
                self?.handleEmbyPage(result, requestGeneration: requestGeneration)
            }
        } else {
            // selectedType is non-nil by the guard above.
            gateway.fetchByType(selectedType ?? "", page: pageToLoad, area: area, year: year, by: sort) { [weak self] result in
                self?.handlePage(result, requestGeneration: requestGeneration)
            }
        }
    }

    /// Emby page handler: on failure set the honest error (a dead
    /// server used to show "这个分类下没有内容") and stop paging;
    /// on success the shared handler runs (stale-generation drop
    /// + empty-page advance included).
    private func handleEmbyPage(_ result: Result<VideoItemPage, EmbyError>, requestGeneration: Int) {
        switch result {
        case .success(let page):
            handlePage(page, requestGeneration: requestGeneration)
        case .failure(let error):
            loadingMore = false
            isLoading = false
            guard requestGeneration == generation else {
                if items.isEmpty { loadMore() }
                return
            }
            errorMessage = error.message
            hasMore = false
        }
    }

    private func handlePage(_ result: VideoItemPage, requestGeneration: Int) {
        loadingMore = false
        isLoading = false
        guard requestGeneration == generation else {
            // Stale page: a reload / filter change landed while it
            // was in flight. Its items belong to the old query, so
            // drop them; the new query was dropped by the
            // loadingMore guard above, so re-issue it now (items
            // is empty after the reset).
            if items.isEmpty { loadMore() }
            return
        }
        if result.items.isEmpty {
            // An empty page ends the list ONLY when the service
            // says there is nothing after it. A filtered window
            // can come back empty while later windows still hold
            // matches (a rare area in the first 10 CMS pages, a
            // parent page whose children all filter out) — ending
            // there shows "这个分类下没有内容" for a list that is
            // not empty. Advance instead; hasMore (page <
            // pagecount) still bounds the walk, so this cannot
            // spin forever.
            if result.hasMore {
                page += 1
                loadMore()
            } else {
                hasMore = false
            }
        } else {
            var seen = Set(items.map { "\($0.sourceId ?? -1)|\($0.id)" })
            for item in result.items {
                let key = "\(item.sourceId ?? -1)|\(item.id)"
                if seen.insert(key).inserted { items.append(item) }
            }
            page += 1
            hasMore = result.hasMore
        }
    }
}

/// The browse page: mode switch + pickers + paged poster grid.
/// Poster taps go out through the callbacks so the caller (the
/// video tab, which owns the NavigationStack) routes CMS posters
/// to .detail and Emby posters to .embyDetail on the existing
/// chains.
struct VideoBrowseView: View {
    var initialType: String?
    var onSelectCMS: (VideoItem) -> Void
    var onSelectEmby: (VideoItem) -> Void
    var onOpenHistory: () -> Void
    var onOpenFavourites: () -> Void

    @StateObject private var viewModel: VideoBrowseViewModel
    @StateObject private var sidebarDrag = HaoSidebarDragState()

    @Environment(\.haoTheme) private var theme

    init(
        initialType: String?,
        onSelectCMS: @escaping (VideoItem) -> Void,
        onSelectEmby: @escaping (VideoItem) -> Void,
        onOpenHistory: @escaping () -> Void = {},
        onOpenFavourites: @escaping () -> Void = {}
    ) {
        self.initialType = initialType
        self.onSelectCMS = onSelectCMS
        self.onSelectEmby = onSelectEmby
        self.onOpenHistory = onOpenHistory
        self.onOpenFavourites = onOpenFavourites
        _viewModel = StateObject(wrappedValue: VideoBrowseViewModel(initialType: initialType))
    }

    /// One filter option: `id` is the filter value sent to the
    /// gateway (e.g. "all", "hits"), `label` is the chip text.
    /// (Was an unnamed `(String, String)` tuple; the two elements
    /// only meant anything by position.)
    private struct FilterOption {
        let id: String
        let label: String
    }

    /// Area options. Values are the CmsClient
    /// filter values: "all" default, "other" = none of the known
    /// areas; area filtering itself lives in filterByTypeItems.
    private static let areaOptions: [FilterOption] = [
        FilterOption(id: "all", label: "全部"),
        FilterOption(id: "大陆", label: "大陆"),
        FilterOption(id: "香港", label: "香港"),
        FilterOption(id: "台湾", label: "台湾"),
        FilterOption(id: "美国", label: "美国"),
        FilterOption(id: "韩国", label: "韩国"),
        FilterOption(id: "日本", label: "日本"),
        FilterOption(id: "英国", label: "英国"),
        FilterOption(id: "other", label: "其他"),
    ]

    /// Sort options (`by` value): "" default, "hits" most
    /// viewed, "score" highest rated.
    private static let sortOptions: [FilterOption] = [
        FilterOption(id: "", label: "默认"),
        FilterOption(id: "hits", label: "最热"),
        FilterOption(id: "score", label: "评分最高"),
    ]

    /// Year options: 全部 + the 5 most recent years from the
    /// calendar (never hardcoded) + 更早 (year ≤ 2021).
    private var yearOptions: [FilterOption] {
        let current = Calendar.current.component(.year, from: Date())
        var options: [FilterOption] = [FilterOption(id: "all", label: "全部")]
        for offset in 0..<5 {
            let year = String(current - offset)
            options.append(FilterOption(id: year, label: year))
        }
        options.append(FilterOption(id: "earlier", label: "更早"))
        return options
    }

    var body: some View {
        HaoDragSidebar(state: sidebarDrag) {
            BrowseSidebarView(
                mode: viewModel.mode,
                categories: viewModel.categories,
                libraries: viewModel.libraries,
                genres: viewModel.genres,
                selectedType: viewModel.selectedType,
                selectedLibraryId: viewModel.selectedLibraryId,
                selectedGenre: viewModel.selectedGenre,
                onOpenHistory: {
                    // Like the type rows below: close the panel
                    // first, or it is still open over the grid
                    // when the user comes back from history.
                    sidebarDrag.close()
                    onOpenHistory()
                },
                onOpenFavourites: {
                    sidebarDrag.close()
                    onOpenFavourites()
                },
                onSelectType: { type in
                    viewModel.selectedType = type
                    sidebarDrag.close()
                },
                onSelectLibrary: { id in
                    viewModel.selectedLibraryId = id
                    sidebarDrag.close()
                },
                onSelectGenre: { genre in
                    viewModel.selectedGenre = genre
                    sidebarDrag.close()
                }
            )
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                Picker("片源", selection: $viewModel.mode) {
                    Text("影视").tag("cms")
                    Text("Emby").tag("emby")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .onChange(of: viewModel.mode) { newMode in
                    VideoLibraryStore.setTabMode(newMode)
                }
                .sensoryFeedback(.selection, trigger: viewModel.mode)
                if viewModel.mode == "emby" && !viewModel.isEmbyConfigured {
                    MusicEmptyState(
                        icon: "server.rack",
                        title: "未配置 Emby 服务器",
                        note: "在设置 → Emby 连接里添加服务器地址并登录后，这里会显示你的媒体库。"
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                    Spacer()
                } else if viewModel.mode == "emby" {
                    // Emby libraries + genres live in the sidebar;
                    // nothing on top of the grid in this mode.
                    gridScrollView
                } else {
                    cmsFilterRows
                        .padding(.top, 12)
                    gridScrollView
                }
            }
        }
        .haoBottomChromePadding()
        .background(theme.scaffoldBackground)
        .navigationTitle("浏览")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { sidebarDrag.toggle() }) {
                    Image(systemName: "sidebar.left")
                }
                .accessibilityLabel(sidebarDrag.isOpen ? "关闭分类" : "打开分类")
            }
        }
    }

    /// The grid's own scroll view: the sidebar drag gesture lives
    /// here and only here, so a horizontal swipe on a filter strip
    /// scrolls the strip and never moves the panel.
    private var gridScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                gridSection
                Spacer(minLength: 16)
            }
        }
        .simultaneousGesture(sidebarDrag.contentDragGesture)
        .refreshable { viewModel.refresh() }
    }

    // MARK: - CMS filter rows

    /// Area / year / sort only. The type list left the top row:
    /// it lives in the sidebar now (build 36, item 19 — one
    /// picker for the list, not two).
    private var cmsFilterRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            filterRow(title: "地区", options: Self.areaOptions, selected: viewModel.area) {
                viewModel.area = $0
            }
            filterRow(title: "年份", options: yearOptions, selected: viewModel.year) {
                viewModel.year = $0
            }
            filterRow(title: "排序", options: Self.sortOptions, selected: viewModel.sort) {
                viewModel.sort = $0
            }
        }
    }


    // MARK: - Grid

    private var gridSection: some View {
        Group {
            if viewModel.items.isEmpty && viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else if viewModel.mode == "emby", let error = viewModel.errorMessage {
                VStack(spacing: 12) {
                    MusicEmptyState(
                        icon: "wifi.exclamationmark",
                        title: "连不上 Emby",
                        note: error
                    )
                    Button("重试") { viewModel.reload() }
                        .font(.haoSubheadStrong)
                        .foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(theme.accent, in: Capsule())
                }
                .padding(.horizontal, 16)
            } else if viewModel.items.isEmpty {
                MusicEmptyState(
                    icon: "film",
                    title: "这个分类下没有内容",
                    note: viewModel.mode == "emby"
                        ? "Emby 没有返回该分类的影片。"
                        : "影视源没有返回该分类的数据。"
                )
                .padding(.horizontal, 16)
            } else {
                if viewModel.mode == "emby", let filter = viewModel.activeEmbyFilterText {
                    Text(filter)
                        .font(.haoFootnote)
                        .foregroundStyle(theme.textMuted)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
                VideoPosterGrid(items: viewModel.items, isEmby: viewModel.mode == "emby") { item in
                    if viewModel.mode == "emby" {
                        onSelectEmby(item)
                    } else {
                        onSelectCMS(item)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                if viewModel.hasMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .onAppear { viewModel.loadMore() }
                }
            }
        }
    }

    // MARK: - Filter chips

    /// One filter row: a small muted label + a horizontal chip
    /// strip, same capsule style as categoryStrip / libraryChip.
    private func filterRow(
        title: String,
        options: [FilterOption],
        selected: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.haoDenseBody)
                .foregroundStyle(theme.textMuted)
                .frame(width: 36, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.id) { option in
                        filterChip(label: option.label, selected: selected == option.id) {
                            onSelect(option.id)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func filterChip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.haoDenseBody)
                .foregroundStyle(selected ? theme.onAccent : theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? theme.accent : theme.surface, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(theme.hairline, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
    }
}

/// Sidebar rows for the browse page (build 36, item 19): the
/// category picker lives here, not in a top chip row (chen's
/// Emby-style screenshot is the authority — one picker for the
/// list, not two). CMS: quick links + 分类; Emby: 媒体库 + 分类.
/// A row tap changes the same view-model selection the chip used
/// to change (same reload() path) and springs the sidebar closed.
private struct BrowseSidebarView: View {
    var mode: String
    var categories: [String]
    var libraries: [VideoEmbyLibrary]
    var genres: [String]
    var selectedType: String?
    var selectedLibraryId: String?
    var selectedGenre: String?
    var onOpenHistory: () -> Void
    var onOpenFavourites: () -> Void
    var onSelectType: (String) -> Void
    var onSelectLibrary: (String?) -> Void
    var onSelectGenre: (String?) -> Void

    @Environment(\.haoTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if mode == "emby" {
                    sectionTitle("媒体库")
                    sidebarRow(label: "全部", selected: selectedLibraryId == nil) {
                        onSelectLibrary(nil)
                    }
                    ForEach(libraries) { library in
                        sidebarRow(label: library.name, selected: selectedLibraryId == library.id) {
                            onSelectLibrary(library.id)
                        }
                    }
                    sectionTitle("分类")
                    sidebarRow(label: "全部", selected: selectedGenre == nil) {
                        onSelectGenre(nil)
                    }
                    ForEach(genres, id: \.self) { genre in
                        sidebarRow(label: genre, selected: selectedGenre == genre) {
                            onSelectGenre(genre)
                        }
                    }
                } else {
                    sidebarRow(label: "继续观看", icon: "clock") {
                        onOpenHistory()
                    }
                    sidebarRow(label: "我的收藏", icon: "heart") {
                        onOpenFavourites()
                    }
                    sectionTitle("分类")
                    ForEach(categories, id: \.self) { type in
                        sidebarRow(label: type, selected: selectedType == type) {
                            onSelectType(type)
                        }
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.haoFootnote)
            .foregroundStyle(theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 12)
    }

    private func sidebarRow(
        label: String,
        icon: String? = nil,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.haoFootnoteStrong)
                }
                Text(label)
                    .font(.haoSubhead)
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(selected ? theme.accent : theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.accentSoft)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

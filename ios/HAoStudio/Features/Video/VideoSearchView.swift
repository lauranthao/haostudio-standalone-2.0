// HAo Studio 2.0 — video search + category browse (S3-C leg).
//
// Mirrors Flutter video_search_page.dart (search history chips,
// CMS search across enabled sources, poster grid results) and
// video_type_page.dart (one category as a paged poster grid).
// Search is serial, fastest first on the service side — the UI
// fires one request per submitted query and shows the first
// answer; it never fans out per source itself.
//
// Detail navigation is handed in as `onSelect` by the video tab
// (the tab owns the NavigationStack path); the pages never push
// on their own.

import SwiftUI

@MainActor
final class VideoSearchViewModel: ObservableObject {
    @Published private(set) var results: [VideoItem] = []
    @Published private(set) var embyResults: [VideoItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searched = false
    @Published private(set) var history: [String] = VideoLibraryStore.searchHistory()
    /// CMS search failure (b49 sweep #3): a dead source is an
    /// error state with a retry, never a fake "没有找到相关影片".
    /// Set only on failure — an empty result stays an empty state.
    @Published private(set) var cmsErrorMessage: String?
    /// Load-more paging (b49 sweep #22): CMS pages are 40 items
    /// (dedupeAndRankSearch cap); a full page means there may be
    /// more on the next source-page.
    @Published private(set) var cmsHasMore = false
    /// Same for the Emby section (50 per server page).
    @Published private(set) var embyHasMore = false
    /// Emby search failure (sweep-5 P2-1 / P2-13): like
    /// cmsErrorMessage, set only on failure. The initial search
    /// and the load-more share it — the view tells them apart by
    /// whether embyResults is empty (hint row) or not (banner).
    @Published private(set) var embyErrorMessage: String?
    /// Whether Emby is configured (the hint row only makes sense
    /// when the user has an Emby server to search).
    var embyConfigured: Bool { gateway.embyConfigured }

    private let gateway: VideoDataGateway
    /// Generation bumped on every submitted query: a completion
    /// from an older query is stale and must not overwrite the
    /// newer query's results (CMS search takes up to 15 s; a
    /// second submit while the first is in flight used to let the
    /// first answer win when it landed later).
    private var searchGeneration = 0
    /// One flag per in-flight request: the spinner clears only
    /// when BOTH are done. CMS used to clear it alone, so a fast
    /// empty CMS answer flashed "没有找到相关影片" while the Emby
    /// request was still flying — even when Emby had results.
    /// `embyDone` starts true when Emby is not configured, so
    /// the CMS-only path is unchanged.
    private var cmsDone = true
    private var embyDone = true
    /// Last submitted query (retry + load-more) and the CMS page
    /// cursor. Load-more flags guard against double taps.
    private var lastQuery = ""
    private var cmsPage = 1
    private var cmsLoadingMore = false
    private var embyStartIndex = 0
    private var embyLoadingMore = false

    init(gateway: VideoDataGateway = VideoServices.makeGateway()) {
        self.gateway = gateway
    }

    func search(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        VideoLibraryStore.saveSearchQuery(query)
        history = VideoLibraryStore.searchHistory()
        isSearching = true
        searched = true
        results = []
        embyResults = []
        cmsErrorMessage = nil
        embyErrorMessage = nil
        cmsHasMore = false
        embyHasMore = false
        lastQuery = query
        cmsPage = 1
        embyStartIndex = 0
        cmsDone = false
        embyDone = !gateway.embyConfigured
        searchGeneration += 1
        let generation = searchGeneration
        gateway.search(keyword: query, page: 1) { [weak self] result in
            guard let self = self, self.searchGeneration == generation else { return }
            switch result {
            case .success(let items):
                self.results = items
                self.cmsHasMore = items.count >= 40
            case .failure(let error):
                self.results = []
                self.cmsHasMore = false
                self.cmsErrorMessage = error.message
            }
            self.cmsDone = true
            if self.embyDone { self.isSearching = false }
        }
        if gateway.embyConfigured {
            gateway.searchEmby(keyword: query, startIndex: 0) { [weak self] result in
                guard let self = self, self.searchGeneration == generation else { return }
                switch result {
                case .success(let items):
                    self.embyResults = items
                    self.embyHasMore = items.count >= 50
                    self.embyErrorMessage = nil
                case .failure(let error):
                    self.embyResults = []
                    self.embyHasMore = false
                    self.embyErrorMessage = error.message
                }
                // Failure keeps the Emby section hidden (CMS results
                // still show); the hint row below points at the
                // dedicated Emby search page, where the error is
                // surfaced in full.
                self.embyDone = true
                if self.cmsDone { self.isSearching = false }
            }
        }
    }

    /// Retry the last query after a CMS failure (error-card button).
    func retrySearch() {
        guard !lastQuery.isEmpty else { return }
        search(lastQuery)
    }

    /// Clear the query + results and return to history (sweep-5
    /// P1-5): the ✕ used to clear only the text, leaving
    /// `searched` true and the old results on screen with no way
    /// back (an empty submit is guarded). Bumps the generation
    /// so a late completion from the abandoned query cannot
    /// overwrite the cleared state. Mirrors
    /// MusicSearchViewModel.clear().
    func clear() {
        searchGeneration += 1
        isSearching = false
        searched = false
        results = []
        embyResults = []
        cmsErrorMessage = nil
        embyErrorMessage = nil
        cmsHasMore = false
        embyHasMore = false
        lastQuery = ""
        cmsPage = 1
        embyStartIndex = 0
        cmsDone = true
        embyDone = true
    }

    /// Retry only the failed load-more page (sweep-4 P2-48): the
    /// banner's retry used to re-run the whole search from page 1
    /// and blank the loaded grid. The failed page is retried in
    /// place — cmsPage was never advanced past it, so the same
    /// page is re-issued; cmsHasMore is restored first (the
    /// failure cleared it), so the guard lets the retry through.
    func retryLoadMoreCMS() {
        guard !cmsLoadingMore, !lastQuery.isEmpty else { return }
        cmsHasMore = true
        loadMoreCMS()
    }

    /// Retry only the failed Emby load-more page (sweep-5 P2-1):
    /// same shape as retryLoadMoreCMS — the failed page is
    /// re-issued in place, the loaded grid stays.
    func retryLoadMoreEmby() {
        guard !embyLoadingMore, !lastQuery.isEmpty else { return }
        embyHasMore = true
        loadMoreEmby()
    }

    /// Next CMS source-page, appended (b49 sweep #22). A failure
    /// keeps the loaded results and surfaces as a banner over
    /// them; paging ends either way for this query.
    func loadMoreCMS() {
        guard !cmsLoadingMore, cmsHasMore, !lastQuery.isEmpty else { return }
        cmsLoadingMore = true
        let generation = searchGeneration
        let nextPage = cmsPage + 1
        gateway.search(keyword: lastQuery, page: nextPage) { [weak self] result in
            guard let self = self, self.searchGeneration == generation else { return }
            self.cmsLoadingMore = false
            switch result {
            case .success(let items):
                self.cmsPage = nextPage
                self.cmsErrorMessage = nil
                var seen = Set(self.results.map { "\($0.sourceId ?? -1)|\($0.id)" })
                for item in items where seen.insert("\(item.sourceId ?? -1)|\(item.id)").inserted {
                    self.results.append(item)
                }
                self.cmsHasMore = items.count >= 40
            case .failure(let error):
                self.cmsHasMore = false
                self.cmsErrorMessage = error.message
            }
        }
    }

    /// Next Emby server page, appended (b49 sweep #22).
    func loadMoreEmby() {
        guard !embyLoadingMore, embyHasMore, !lastQuery.isEmpty else { return }
        embyLoadingMore = true
        let generation = searchGeneration
        let nextStart = embyStartIndex + 50
        gateway.searchEmby(keyword: lastQuery, startIndex: nextStart) { [weak self] result in
            guard let self = self, self.searchGeneration == generation else { return }
            self.embyLoadingMore = false
            switch result {
            case .success(let items):
                self.embyStartIndex = nextStart
                self.embyErrorMessage = nil
                var seen = Set(self.embyResults.map { "\($0.sourceId ?? -1)|\($0.id)" })
                for item in items where seen.insert("\(item.sourceId ?? -1)|\(item.id)").inserted {
                    self.embyResults.append(item)
                }
                self.embyHasMore = items.count >= 50
            case .failure(let error):
                self.embyHasMore = false
                self.embyErrorMessage = error.message
            }
        }
    }

    func clearHistory() {
        VideoLibraryStore.clearSearchHistory()
        history = []
    }

    func removeHistoryItem(_ term: String) {
        VideoLibraryStore.removeSearchHistory(term: term)
        history = VideoLibraryStore.searchHistory()
    }
}

struct VideoSearchView: View {
    var onSelect: (VideoItem) -> Void
    /// Open the dedicated Emby search page (sweep-5 P2-13):
    /// wired by the video tab to its .embySearch destination.
    /// Nil when the view is presented outside the tab.
    var onOpenEmbySearch: (() -> Void)? = nil

    @StateObject private var viewModel = VideoSearchViewModel()
    @State private var query = ""
    @State private var showClearHistoryConfirm = false

    @Environment(\.haoTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, HaoLayout.pushedPageMargin)
                .padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if viewModel.isSearching {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    } else if viewModel.searched {
                        // b49 sweep #3: a dead CMS source is an
                        // error card + retry, never a fake "没有
                        // 找到相关影片" — but only when the CMS
                        // section is empty; Emby results below
                        // still show, and a load-more failure
                        // degrades to a banner over the grid.
                        if let error = viewModel.cmsErrorMessage, viewModel.results.isEmpty {
                            VStack(spacing: 12) {
                                MusicEmptyState(
                                    icon: "wifi.exclamationmark",
                                    title: "搜不了影视源",
                                    note: error
                                )
                                Button("重试") { viewModel.retrySearch() }
                                    .font(.haoSubheadStrong)
                                    .foregroundStyle(theme.onAccent)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 12)
                                    .background(theme.accent, in: Capsule())
                            }
                            .padding(.horizontal, HaoLayout.pushedPageMargin)
                        }
                        if viewModel.results.isEmpty && viewModel.embyResults.isEmpty
                            && viewModel.cmsErrorMessage == nil {
                            MusicEmptyState(
                                icon: "magnifyingglass",
                                title: "没有找到相关影片",
                                note: "换个关键词试试，或检查影视源是否可用。"
                            )
                            .padding(.horizontal, HaoLayout.pushedPageMargin)
                        } else {
                            if let error = viewModel.cmsErrorMessage, !viewModel.results.isEmpty {
                                HStack(spacing: 8) {
                                    Image(systemName: "wifi.exclamationmark")
                                    Text(error)
                                        .font(.haoFootnote)
                                    Spacer()
                                    // sweep-4 P2-48: results are
                                    // non-empty, so this error is a
                                    // load-more failure — retry only
                                    // that page, never the whole
                                    // search (which would blank the
                                    // grid).
                                    Button("重试") { viewModel.retryLoadMoreCMS() }
                                        .font(.haoFootnoteMedium)
                                        .foregroundStyle(theme.accentText)
                                }
                                .foregroundStyle(theme.textSecondary)
                                // b49fix5 P2-17: the banner carries
                                // its own top 12 (same as the Emby
                                // banner below) — it is the first
                                // element of the results branch, so
                                // without it the banner sticks to the
                                // search field.
                                .padding(.horizontal, HaoLayout.pushedPageMargin)
                                .padding(.top, 12)
                            }
                            if !viewModel.results.isEmpty {
                                resultSection(
                                    title: "影视源", items: viewModel.results,
                                    hasMore: viewModel.cmsHasMore,
                                    loadFailed: viewModel.cmsErrorMessage != nil,
                                    onLoadMore: { viewModel.loadMoreCMS() })
                            }
                            // sweep-5 P2-1: an Emby load-more
                            // failure is a banner with a retry over
                            // the loaded grid (same as the CMS side),
                            // not a silent stop.
                            if let error = viewModel.embyErrorMessage, !viewModel.embyResults.isEmpty {
                                HStack(spacing: 8) {
                                    Image(systemName: "wifi.exclamationmark")
                                    Text(error)
                                        .font(.haoFootnote)
                                    Spacer()
                                    Button("重试") { viewModel.retryLoadMoreEmby() }
                                        .font(.haoFootnoteMedium)
                                        .foregroundStyle(theme.accentText)
                                }
                                .foregroundStyle(theme.textSecondary)
                                .padding(.horizontal, HaoLayout.pushedPageMargin)
                                .padding(.top, 12)
                            }
                            // sweep-5 P2-13: Emby is configured but
                            // the search failed — one hint row with a
                            // link to the dedicated Emby search page,
                            // instead of silence.
                            if viewModel.embyConfigured, viewModel.embyErrorMessage != nil, viewModel.embyResults.isEmpty {
                                HStack(spacing: 8) {
                                    Image(systemName: "wifi.exclamationmark")
                                    Text("Emby 没有响应")
                                        .font(.haoFootnote)
                                    Spacer()
                                    if let openEmbySearch = onOpenEmbySearch {
                                        Button("去 Emby 搜索") { openEmbySearch() }
                                            .font(.haoFootnoteMedium)
                                            .foregroundStyle(theme.accentText)
                                    }
                                }
                                .foregroundStyle(theme.textSecondary)
                                .padding(.horizontal, HaoLayout.pushedPageMargin)
                                .padding(.top, 12)
                            }
                            if !viewModel.embyResults.isEmpty {
                                resultSection(
                                    title: "Emby", items: viewModel.embyResults, isEmby: true,
                                    hasMore: viewModel.embyHasMore,
                                    loadFailed: viewModel.embyErrorMessage != nil,
                                    onLoadMore: { viewModel.loadMoreEmby() })
                                    .padding(.top, 16)
                            }
                        }
                    } else {
                        historySection
                    }
                    Spacer(minLength: 16)
                }
                .padding(.top, 12)
            }
            .haoBottomChromePadding()
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("清除搜索历史？", isPresented: $showClearHistoryConfirm, titleVisibility: .visible) {
            Button("清除", role: .destructive) { viewModel.clearHistory() }
            Button("取消", role: .cancel) { }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.haoSubheadStrong)
                .foregroundStyle(theme.textMuted)
            TextField("搜索影片、剧集", text: $query)
                .font(.haoSubhead)
                .foregroundStyle(theme.textPrimary)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .onSubmit { viewModel.search(query) }
            if !query.isEmpty {
                Button(action: { query = ""; viewModel.clear() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.haoSubhead)
                        .foregroundStyle(theme.textMuted)
                }
                .buttonStyle(.plain)
            }
            Button("搜索") { viewModel.search(query) }
                .font(.haoSubheadStrong)
                .foregroundStyle(theme.accentText)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: HaoLayout.searchFieldHeight)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: HaoLayout.cornerMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: HaoLayout.cornerMedium, style: .continuous)
                .strokeBorder(theme.hairline, lineWidth: 0.5)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("搜索历史")
                    .font(.haoSectionTitle)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if !viewModel.history.isEmpty {
                    Button("清除") { showClearHistoryConfirm = true }
                        .font(.haoRowSubtitle)
                        .foregroundStyle(theme.accentText)
                }
            }
            .padding(.horizontal, HaoLayout.pushedPageMargin)
            if viewModel.history.isEmpty {
                Text("还没有搜索记录。")
                    .font(.haoRowSubtitle)
                    .foregroundStyle(theme.textMuted)
                    .padding(.horizontal, HaoLayout.pushedPageMargin)
            } else {
                FlowChips(
                    items: viewModel.history,
                    onTap: { term in
                        query = term
                        viewModel.search(term)
                    },
                    onDelete: { term in viewModel.removeHistoryItem(term) }
                )
                .padding(.horizontal, HaoLayout.pushedPageMargin)
                // sweep-5 P2-8: deletion used to live only in a
                // long-press menu, with nothing on screen saying
                // so — one visible line states it.
                Text("长按一条记录可以删除")
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textMuted)
                    .padding(.horizontal, HaoLayout.pushedPageMargin)
            }
        }
    }

    private func resultSection(title: String, items: [VideoItem], isEmby: Bool = false, hasMore: Bool = false, loadFailed: Bool = false, onLoadMore: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.haoSectionTitle)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                // VidHub-style count: the number comes from the
                // loaded results, never invented — "共 N 部" only
                // once everything is loaded; while more pages
                // remain it is "已加载 N 部".
                // A failed load-more leaves hasMore false, so the
                // bare "共 N 部" would claim everything loaded
                // (sweep-5 P2-1): a failed section always reads
                // "已加载 N 部".
                Text(hasMore || loadFailed ? "已加载 \(items.count) 部" : "共 \(items.count) 部")
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textMuted)
            }
            .padding(.horizontal, HaoLayout.pushedPageMargin)
            // Emby posters carry no api_key (auth rides the
            // request header), so plain AsyncImage 401s on them:
            // the Emby section must route through EmbyPosterImage
            // or every result shows the placeholder tile.
            VideoPosterGrid(items: items, isEmby: isEmby) { item in
                onSelect(item)
            }
            .padding(.horizontal, HaoLayout.pushedPageMargin)
            // b49 sweep #22: explicit load-more — CMS pages are
            // 40 items, Emby pages 50; the 41st / 51st result used
            // to be unreachable.
            if hasMore {
                Button("加载更多") { onLoadMore?() }
                    .font(.haoSubheadStrong)
                    .foregroundStyle(theme.accentText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
    }
}

/// Wrapping chips layout for search history (no LazyVGrid: chips
/// have intrinsic widths). Shared by the video search and the live
/// search — one chip language for the whole app (build-35 polish:
/// live used a stretched adaptive grid, video used this flow).
/// The wrap width is the real content width (screen − 48), not a
/// fixed 340 — a fixed width overflowed the 320pt iPhone SE and
/// wasted space on 430pt phones. A single over-long term is
/// capped at the content width instead of drawing past the edge.
struct FlowChips: View {
    var items: [String]
    var onTap: (String) -> Void
    /// Optional per-term delete (video search history). Nil at
    /// the live-search reuse site: no menu there.
    var onDelete: ((String) -> Void)? = nil

    @Environment(\.haoTheme) private var theme

    /// Content width the chips wrap inside, measured from layout
    /// (sweep-5 P2-12): UIScreen.main.bounds.width froze at launch
    /// orientation and never updated on rotation / Split View.
    /// 342pt is the pre-measurement fallback (390pt phone − 48).
    @State private var measuredWidth: CGFloat = 342
    private var availableWidth: CGFloat { measuredWidth }

    var body: some View {
        // A simple left-aligned flow built from rows: measure-free,
        // chunked into rows of ~3 by the caller-independent greedy
        // pass below (widths vary, so rows are approximate).
        VStack(alignment: .leading, spacing: 8) {
            ForEach(chipRows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { term in
                        Button(action: { onTap(term) }) {
                            Text(term)
                                .font(.haoDenseBody)
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(theme.surface, in: Capsule())
                                .overlay {
                                    Capsule().strokeBorder(theme.hairline, lineWidth: 0.5)
                                }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let onDelete = onDelete {
                                Button("删除这条记录", role: .destructive) {
                                    onDelete(term)
                                }
                            }
                        }
                        .frame(maxWidth: availableWidth)
                    }
                }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { measuredWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newWidth in
                        measuredWidth = newWidth
                    }
            }
        }
    }

    /// Greedy rows by estimated width (13pt average per character +
    /// padding). Approximation only affects wrapping, never data.
    private var chipRows: [[String]] {
        var rows: [[String]] = []
        var current: [String] = []
        var width = 0
        for term in items {
            let w = term.count * 15 + 28
            if !current.isEmpty && CGFloat(width + w + 8) > availableWidth {
                rows.append(current)
                current = []
                width = 0
            }
            current.append(term)
            width += w + 8
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Category browse (Flutter video_type_page.dart)

@MainActor
final class VideoCategoryViewModel: ObservableObject {
    @Published private(set) var items: [VideoItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    /// Human error text from the last failed CMS load
    /// (VideoFetchError.message). Set only on failure — an empty
    /// category stays an empty state, never an error state.
    @Published private(set) var errorMessage: String?

    private let gateway: VideoDataGateway
    private let type: String
    private var page = 0
    private var loadingMore = false
    /// Load generation, copied from VideoBrowseViewModel: every
    /// reload bumps it, and a page landing for an older generation
    /// is dropped. Without it, a reload issued while a page was in
    /// flight cleared `items` and then the stale page appended its
    /// (wrong-page) items as if they were page 0. The re-issue
    /// below matters too: a reload whose loadMore is blocked by the
    /// in-flight guard must not leave the grid empty forever.
    private var generation = 0
    /// Snapshot of the last good grid, taken by reload() before it
    /// clears (Phase 3, §4.1 — same rule as VideoBrowseViewModel).
    /// The query here is fixed (one type), so no query key is needed.
    private var reloadSnapshot: (items: [VideoItem], page: Int, hasMore: Bool)?

    init(type: String, gateway: VideoDataGateway = VideoServices.makeGateway()) {
        self.type = type
        self.gateway = gateway
    }

    func reload() {
        generation += 1
        // Snapshot before clearing (Phase 3, §4.1 — same rule as
        // VideoBrowseViewModel).
        reloadSnapshot = (items: items, page: page, hasMore: hasMore)
        page = 0
        hasMore = true
        items = []
        errorMessage = nil
        loadMore()
    }

    /// First load only. The view used to call reload() on every
    /// appear, so coming back from a detail page re-fetched page 0
    /// and lost the scroll position; returning must keep the grid
    /// as it was. Pull-to-refresh still calls reload() explicitly.
    func loadIfNeeded() {
        guard items.isEmpty else { return }
        reload()
    }

    func loadMore() {
        guard !loadingMore && hasMore else { return }
        loadingMore = true
        isLoading = true
        let requestGeneration = generation
        gateway.fetchByType(type, page: page, area: "all", year: "all", by: "") { [weak self] result in
            guard let self = self else { return }
            self.loadingMore = false
            self.isLoading = false
            guard requestGeneration == self.generation else {
                // Stale page: a reload landed while it was in
                // flight. Its items belong to the old query, so
                // drop them; the reload's loadMore was dropped by
                // the loadingMore guard above, so re-issue it now
                // (items is empty after the reset).
                if self.items.isEmpty { self.loadMore() }
                return
            }
            switch result {
            case .success(let page):
                if page.items.isEmpty {
                    // An empty page ends the list only when the service
                    // says there is nothing after it. A hole page (all
                    // rows dropped in parsing) with hasMore set must
                    // advance instead of stranding the list.
                    if page.hasMore {
                        self.page += 1
                        self.loadMore()
                    } else {
                        self.hasMore = false
                    }
                } else {
                    var seen = Set(self.items.map { "\($0.sourceId ?? -1)|\($0.id)" })
                    for item in page.items where seen.insert("\(item.sourceId ?? -1)|\(item.id)").inserted {
                        self.items.append(item)
                    }
                    self.page += 1
                    self.hasMore = page.hasMore
                }
            case .failure(let error):
                self.handleCmsFailure(error)
            }
        }
    }

    /// CMS page failure (Phase 3, §4.1 — same rule as
    /// VideoBrowseViewModel.handleCmsFailure): a page-0 failure
    /// after a reload restores the snapshot; any other failure
    /// just records the error and ends paging.
    private func handleCmsFailure(_ error: VideoFetchError) {
        if page == 0, let snapshot = reloadSnapshot, !snapshot.items.isEmpty {
            items = snapshot.items
            page = snapshot.page
            hasMore = snapshot.hasMore
        } else {
            hasMore = false
        }
        errorMessage = error.message
    }
}

/// One category as a paged poster grid.
struct VideoCategoryView: View {
    var type: String
    var onSelect: (VideoItem) -> Void

    @StateObject private var viewModel: VideoCategoryViewModel

    @Environment(\.haoTheme) private var theme

    init(type: String, onSelect: @escaping (VideoItem) -> Void) {
        self.type = type
        self.onSelect = onSelect
        _viewModel = StateObject(wrappedValue: VideoCategoryViewModel(type: type))
    }

    var body: some View {
        ScrollView {
            if viewModel.items.isEmpty && viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
                VStack(spacing: 12) {
                    MusicEmptyState(
                        icon: "wifi.exclamationmark",
                        title: "连不上影视源",
                        note: error
                    )
                    Button("重试") { viewModel.reload() }
                        .font(.haoSubheadStrong)
                        .foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(theme.accent, in: Capsule())
                }
                .padding(.horizontal, HaoLayout.pushedPageMargin)
            } else if viewModel.items.isEmpty {
                MusicEmptyState(
                    icon: "film",
                    title: "这个分类下没有内容",
                    note: "影视源没有返回该分类的数据。"
                )
                .padding(.horizontal, HaoLayout.pushedPageMargin)
            } else {
                // A failed refresh kept the old grid: show the error
                // as a compact banner instead of hiding the results
                // behind an error card.
                if let error = viewModel.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark")
                        Text(error)
                            .font(.haoFootnote)
                        Spacer()
                        Button("重试") { viewModel.reload() }
                            .font(.haoFootnoteMedium)
                            .foregroundStyle(theme.accentText)
                    }
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, HaoLayout.pushedPageMargin)
                    .padding(.top, 12)
                }
                VideoPosterGrid(items: viewModel.items) { item in
                    onSelect(item)
                }
                .padding(.horizontal, HaoLayout.pushedPageMargin)
                .padding(.top, 12)
                if viewModel.hasMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .onAppear { viewModel.loadMore() }
                }
            }
            Spacer(minLength: 16)
        }
        .haoBottomChromePadding()
        .background(theme.scaffoldBackground)
        .navigationTitle(type)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { viewModel.reload() }
        .onAppear { viewModel.loadIfNeeded() }
    }
}

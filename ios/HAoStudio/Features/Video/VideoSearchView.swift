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
        cmsDone = false
        embyDone = !gateway.embyConfigured
        searchGeneration += 1
        let generation = searchGeneration
        gateway.search(keyword: query) { [weak self] items in
            guard let self = self, self.searchGeneration == generation else { return }
            self.results = items
            self.cmsDone = true
            if self.embyDone { self.isSearching = false }
        }
        if gateway.embyConfigured {
            gateway.searchEmby(keyword: query) { [weak self] result in
                guard let self = self, self.searchGeneration == generation else { return }
                if case .success(let items) = result { self.embyResults = items }
                // Failure keeps the Emby section hidden (CMS results
                // still show); the dedicated Emby search page is
                // where the error is surfaced.
                self.embyDone = true
                if self.cmsDone { self.isSearching = false }
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

    @StateObject private var viewModel = VideoSearchViewModel()
    @State private var query = ""

    @Environment(\.haoTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 16)
                .padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if viewModel.isSearching {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    } else if viewModel.searched {
                        if viewModel.results.isEmpty && viewModel.embyResults.isEmpty {
                            MusicEmptyState(
                                icon: "magnifyingglass",
                                title: "没有找到相关影片",
                                note: "换个关键词试试，或检查影视源是否可用。"
                            )
                            .padding(.horizontal, 16)
                        } else {
                            if !viewModel.results.isEmpty {
                                resultSection(title: "影视源", items: viewModel.results)
                            }
                            if !viewModel.embyResults.isEmpty {
                                resultSection(title: "Emby", items: viewModel.embyResults, isEmby: true)
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
                Button(action: { query = "" }) {
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
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
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
                    Button("清除") { viewModel.clearHistory() }
                        .font(.haoRowSubtitle)
                        .foregroundStyle(theme.accentText)
                }
            }
            .padding(.horizontal, 16)
            if viewModel.history.isEmpty {
                Text("还没有搜索记录。")
                    .font(.haoRowSubtitle)
                    .foregroundStyle(theme.textMuted)
                    .padding(.horizontal, 16)
            } else {
                FlowChips(
                    items: viewModel.history,
                    onTap: { term in
                        query = term
                        viewModel.search(term)
                    },
                    onDelete: { term in viewModel.removeHistoryItem(term) }
                )
                .padding(.horizontal, 16)
            }
        }
    }

    private func resultSection(title: String, items: [VideoItem], isEmby: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.haoSectionTitle)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                // VidHub-style count ("共 3 部"): the number comes
                // from the results themselves, never invented.
                Text("共 \(items.count) 部")
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textMuted)
            }
            .padding(.horizontal, 16)
            // Emby posters carry no api_key (auth rides the
            // request header), so plain AsyncImage 401s on them:
            // the Emby section must route through EmbyPosterImage
            // or every result shows the placeholder tile.
            VideoPosterGrid(items: items, isEmby: isEmby) { item in
                onSelect(item)
            }
            .padding(.horizontal, 16)
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

    /// Content width the chips wrap inside (screen − 24pt margins
    /// each side).
    private var availableWidth: CGFloat {
        UIScreen.main.bounds.width - 48
    }

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
                .padding(.horizontal, 16)
            } else if viewModel.items.isEmpty {
                MusicEmptyState(
                    icon: "film",
                    title: "这个分类下没有内容",
                    note: "影视源没有返回该分类的数据。"
                )
                .padding(.horizontal, 16)
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
                            .font(.haoFootnote)
                            .foregroundStyle(theme.accentText)
                    }
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                VideoPosterGrid(items: viewModel.items) { item in
                    onSelect(item)
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

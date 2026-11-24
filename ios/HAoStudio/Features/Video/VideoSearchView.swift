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
        searchGeneration += 1
        let generation = searchGeneration
        gateway.search(keyword: query) { [weak self] items in
            guard let self = self, self.searchGeneration == generation else { return }
            self.results = items
            self.isSearching = false
        }
        if gateway.embyConfigured {
            gateway.searchEmby(keyword: query) { [weak self] result in
                guard let self = self, self.searchGeneration == generation else { return }
                if case .success(let items) = result { self.embyResults = items }
                // Failure keeps the Emby section hidden (CMS results
                // still show); the dedicated Emby search page is
                // where the error is surfaced.
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
                                resultSection(title: "Emby", items: viewModel.embyResults)
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
                .foregroundStyle(theme.accent)
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
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, 24)
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

    private func resultSection(title: String, items: [VideoItem]) -> some View {
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
            VideoPosterGrid(items: items) { item in
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

    private let gateway: VideoDataGateway
    private let type: String
    private var page = 0
    private var loadingMore = false

    init(type: String, gateway: VideoDataGateway = VideoServices.makeGateway()) {
        self.type = type
        self.gateway = gateway
    }

    func reload() {
        page = 0
        hasMore = true
        items = []
        loadMore()
    }

    func loadMore() {
        guard !loadingMore && hasMore else { return }
        loadingMore = true
        isLoading = true
        gateway.fetchByType(type, page: page, area: "all", year: "all", by: "") { [weak self] result in
            guard let self = self else { return }
            self.loadingMore = false
            self.isLoading = false
            if result.items.isEmpty {
                self.hasMore = false
            } else {
                self.items.append(contentsOf: result.items)
                self.page += 1
                self.hasMore = result.hasMore
            }
        }
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
            } else if viewModel.items.isEmpty {
                MusicEmptyState(
                    icon: "film",
                    title: "这个分类下没有内容",
                    note: "影视源没有返回该分类的数据。"
                )
                .padding(.horizontal, 16)
            } else {
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
        .onAppear { viewModel.reload() }
    }
}

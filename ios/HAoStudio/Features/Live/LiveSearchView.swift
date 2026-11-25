// HAo Studio 2.0 — live search (S4-C leg).
//
// Search rooms on one platform (Flutter live_search_page.dart).
// History holds keywords only (max 20, most recent first) —
// results are per-platform and time-sensitive, so re-running
// re-searches live. An empty query never searches. Until a
// gateway is wired the page shows the history chips and an
// honest note — never fake results.

import SwiftUI

@MainActor
final class LiveSearchViewModel: ObservableObject {
    @Published private(set) var results: [LiveRoom] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasSearched = false
    /// (b49fix2 P1-9) The last search failed at the network /
    /// parse level: the empty state must say so and offer a
    /// retry, instead of reading as "没有找到相关直播间".
    @Published private(set) var searchFailed = false
    @Published var platform: LivePlatform = .bilibili
    /// Platforms the settings switches leave enabled (b49 sweep
    /// #2): the search tabs only ever show these.
    @Published private(set) var enabledPlatforms: [LivePlatform] = LivePlatform.enabledCases

    /// Search history, read from disk once (build 36, item
    /// 10): this used to be a computed property, so every
    /// keystroke — every body re-evaluation — paid a full
    /// history-file read + JSON decode. It is now stored and
    /// refreshed only when history actually changes (search
    /// submit / clear / delete), like the music and video
    /// search view models.
    @Published private(set) var searchHistory: [String] = []

    private let gateway: LiveDataGateway?
    /// Generation bumped on every submitted query: a completion
    /// from an older query is stale and must not overwrite the
    /// newer query's results (same class as the VideoSearch
    /// searchGeneration fix — a slow first search used to win
    /// when it landed after a second submit, and a platform
    /// switch mid-flight showed the old platform's rooms under
    /// the new one).
    private var searchGeneration = 0
    /// The last submitted query, for the error state's retry
    /// button (b49fix2 P1-9).
    private var lastQuery = ""

    init(gateway: LiveDataGateway? = nil) {
        self.gateway = gateway
        self.searchHistory = LiveLibraryStore.searchHistory()
        // (b49 sweep #2) Never start on a switched-off platform.
        // All platforms off leaves the default in place — the
        // adapter answers `.empty` for a disabled platform, and
        // `enabledPlatforms[0]` would trap (same guard as the
        // tab's refreshEnabledPlatforms, b49fix2 P1-25).
        if !enabledPlatforms.contains(platform), let first = enabledPlatforms.first {
            platform = first
        }
    }

    var hasGateway: Bool { gateway != nil }

    /// Re-read history from the store after a write. One
    /// disk read per history change — never per keystroke.
    private func refreshSearchHistory() {
        searchHistory = LiveLibraryStore.searchHistory()
    }

    func search(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        LiveLibraryStore.saveSearchQuery(trimmed)
        refreshSearchHistory()
        lastQuery = trimmed
        searchGeneration += 1
        let generation = searchGeneration
        guard let gateway = gateway else {
            results = []
            hasSearched = true
            return
        }
        isSearching = true
        hasSearched = true
        searchFailed = false
        let platformId = platform.rawValue
        gateway.searchRooms(query: trimmed, platform: platformId) { [weak self] result in
            guard let self = self, self.searchGeneration == generation else { return }
            self.isSearching = false
            switch result {
            case .success(let rooms):
                // Same dedupe as the tab grid: a repeated room in
                // one page must never reach the ForEach (fix
                // 2026-11-24).
                self.searchFailed = false
                self.results = deduplicatedLiveRooms(rooms)
            case .failure:
                // (b49fix2 P1-9) A failed search is not "no
                // results": clear the stale list so the old
                // platform's rooms never show under the new
                // query, and surface the error state + retry.
                self.searchFailed = true
                self.results = []
            }
        }
    }

    /// Re-run the last query (error state's retry button).
    func retrySearch() {
        guard !lastQuery.isEmpty else { return }
        search(query: lastQuery)
    }

    /// Back to the history view (sweep-5 P1-5): the ✕ used to
    /// clear only the text, leaving hasSearched true and the old
    /// results on screen — and an empty submit is guarded, so
    /// there was no way back to history. Same shape as
    /// MusicSearchViewModel.clear(): reset the state and bump
    /// the generation so an in-flight search cannot resurrect
    /// the cleared results.
    func clear() {
        results = []
        hasSearched = false
        searchFailed = false
        isSearching = false
        searchGeneration += 1
    }

    func clearSearchHistory() {
        LiveLibraryStore.clearSearchHistory()
        refreshSearchHistory()
    }

    /// Delete one history keyword (long-press on a history chip —
    /// the same shape as the video search's `removeHistoryItem`).
    func removeHistoryItem(_ term: String) {
        LiveLibraryStore.removeSearchHistory(term: term)
        refreshSearchHistory()
    }

    /// Switch platform (build 36 item 8): the old platform's
    /// results must not stay visible under the new platform's
    /// tab. When a search is showing, re-run the same query on
    /// the new platform; when the field is empty there is nothing
    /// to re-run, so drop back to the history view.
    func selectPlatform(_ next: LivePlatform, query: String) {
        guard next != platform, enabledPlatforms.contains(next) else { return }
        platform = next
        guard hasSearched else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            results = []
            hasSearched = false
        } else {
            search(query: trimmed)
        }
    }
}

struct LiveSearchView: View {
    var gateway: LiveDataGateway?
    var onSelect: (LiveRoom, [LiveRoom]) -> Void

    @StateObject private var viewModel: LiveSearchViewModel
    @State private var query = ""
    @State private var showClearHistoryConfirm = false
    /// (sweep-5 P2-12) This page's own laid-out grid width —
    /// UIScreen.main.bounds.width is stale in Split View /
    /// Stage Manager, so the grid reads its real container
    /// width (same preference-key pattern as HomeView's
    /// homeLiveGridColumns). 0 until the first measurement.
    @State private var gridWidth: CGFloat = 0

    @Environment(\.haoTheme) private var theme

    init(gateway: LiveDataGateway? = nil, onSelect: @escaping (LiveRoom, [LiveRoom]) -> Void) {
        self.gateway = gateway
        self.onSelect = onSelect
        _viewModel = StateObject(wrappedValue: LiveSearchViewModel(gateway: gateway))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 24)
                .padding(.top, 12)
            // Results scroll (fix 2026-11-24, build 35): the body
            // used to be a plain VStack, so a result list taller
            // than the screen had no way to reach its bottom rows
            // — and the page never had the bottom-chrome padding,
            // so the last row could sit under the tab bar. Same
            // shape as VideoSearchView: fixed field on top,
            // scrolling content below.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    platformRow
                        .padding(.top, 12)
                    if !viewModel.hasSearched {
                        searchHistorySection
                            .padding(.top, 16)
                    }
                    resultsSection
                        .padding(.top, 16)
                    Spacer(minLength: 16)
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: LiveGridWidthKey.self, value: proxy.size.width)
                    }
                )
            }
            .onPreferenceChange(LiveGridWidthKey.self) { gridWidth = $0 }
            .haoBottomChromePadding()
        }
        .background(theme.scaffoldBackground)
        // (b49fix2 B11) Same cap as the tab (fixed-height search
        // field, chips, 140pt cards); harmless if the page was
        // pushed from the tab and already inherits it.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .navigationTitle("搜索直播")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.haoSubheadStrong)
                .foregroundStyle(theme.textMuted)
            TextField("搜索直播间、主播", text: $query)
                .font(.haoSubhead)
                .foregroundStyle(theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit {
                    viewModel.search(query: query)
                }
            if !query.isEmpty {
                Button(action: {
                    query = ""
                    viewModel.clear()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.haoSubhead)
                        .foregroundStyle(theme.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
            // (sweep-5 P2-6) A visible search button — onSubmit
            // alone left keyboard-less users with no way to
            // submit. Same shape as VideoSearchView.
            Button("搜索") { viewModel.search(query: query) }
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

    private var platformRow: some View {
        LivePlatformTextTabs(
            platforms: viewModel.enabledPlatforms,
            selected: viewModel.platform) { platform in
            viewModel.selectPlatform(platform, query: query)
        }
    }

    private var searchHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("搜索历史")
                    .font(.haoSectionTitle)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if !viewModel.searchHistory.isEmpty {
                    Button("清空") {
                        showClearHistoryConfirm = true
                    }
                    .font(.haoDenseBody)
                    .foregroundStyle(theme.accentText)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .confirmationDialog("清除搜索历史？", isPresented: $showClearHistoryConfirm, titleVisibility: .visible) {
                Button("清除", role: .destructive) { viewModel.clearSearchHistory() }
                Button("取消", role: .cancel) {}
            }
            if viewModel.searchHistory.isEmpty {
                Text("还没有搜索记录")
                    .font(.haoRowSubtitle)
                    .foregroundStyle(theme.textMuted)
                    .padding(.horizontal, 24)
            } else {
                FlowChips(
                    items: viewModel.searchHistory,
                    onTap: { keyword in
                        query = keyword
                        viewModel.search(query: keyword)
                    },
                    onDelete: { term in
                        viewModel.removeHistoryItem(term)
                    }
                )
                .padding(.horizontal, 24)
            }
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else if viewModel.hasSearched {
                if viewModel.results.isEmpty {
                    if viewModel.searchFailed {
                        // (b49fix2 P1-9) Real error state + retry,
                        // not "没有找到相关直播间".
                        MusicEmptyState(
                            icon: "magnifyingglass",
                            title: "搜索失败",
                            note: "直播源没有返回数据，换个网络或稍后再试。"
                        )
                        .padding(.horizontal, 24)
                        Button("重试") { viewModel.retrySearch() }
                            .font(.haoDenseTitle)
                            .foregroundStyle(theme.onAccent)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(theme.accent, in: Capsule())
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                    } else {
                        MusicEmptyState(
                            icon: "magnifyingglass",
                            title: viewModel.hasGateway ? "没有找到相关直播间" : "直播源尚未接入",
                            note: viewModel.hasGateway
                                ? "换个关键词或平台再试试。"
                                : "搜索由直播源提供，接入后在这里显示。"
                        )
                        .padding(.horizontal, 24)
                    }
                } else {
                    LazyVGrid(
                        columns: LiveGridLayout.gridColumns(forWidth: gridWidth > 0 ? gridWidth : UIScreen.main.bounds.width),
                        spacing: LiveGridLayout.gridRowSpacing
                    ) {
                        // Identity is the room itself (platform +
                        // room id), same as the tab grid.
                        ForEach(viewModel.results, id: \.self) { room in
                            LiveRoomCard(room: room) {
                                onSelect(room, viewModel.results)
                            }
                        }
                    }
                    .padding(.horizontal, LiveGridLayout.gridEdgePadding)
                }
            }
        }
    }
}

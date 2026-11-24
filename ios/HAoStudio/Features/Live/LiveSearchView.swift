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
    @Published var platform: LivePlatform = .bilibili

    private let gateway: LiveDataGateway?
    /// Generation bumped on every submitted query: a completion
    /// from an older query is stale and must not overwrite the
    /// newer query's results (same class as the VideoSearch
    /// searchGeneration fix — a slow first search used to win
    /// when it landed after a second submit, and a platform
    /// switch mid-flight showed the old platform's rooms under
    /// the new one).
    private var searchGeneration = 0

    init(gateway: LiveDataGateway? = nil) {
        self.gateway = gateway
    }

    var hasGateway: Bool { gateway != nil }

    var searchHistory: [String] {
        LiveLibraryStore.searchHistory()
    }

    func search(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        LiveLibraryStore.saveSearchQuery(trimmed)
        searchGeneration += 1
        let generation = searchGeneration
        guard let gateway = gateway else {
            results = []
            hasSearched = true
            return
        }
        isSearching = true
        hasSearched = true
        let platformId = platform.rawValue
        gateway.searchRooms(query: trimmed, platform: platformId) { [weak self] rooms in
            guard let self = self, self.searchGeneration == generation else { return }
            self.isSearching = false
            // Same dedupe as the tab grid: a repeated room in
            // one page must never reach the ForEach (fix
            // 2026-11-24).
            self.results = deduplicatedLiveRooms(rooms)
        }
    }

    func clearSearchHistory() {
        LiveLibraryStore.clearSearchHistory()
    }
}

struct LiveSearchView: View {
    var gateway: LiveDataGateway?
    var onSelect: (LiveRoom, [LiveRoom]) -> Void

    @StateObject private var viewModel: LiveSearchViewModel
    @State private var query = ""
    @State private var historyVersion = 0

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
            }
            .haoBottomChromePadding()
        }
        .background(theme.scaffoldBackground)
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
                    historyVersion += 1
                }
            if !query.isEmpty {
                Button(action: { query = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.haoSubhead)
                        .foregroundStyle(theme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.hairline, lineWidth: 0.5)
        }
    }

    private var platformRow: some View {
        LivePlatformTextTabs(selected: viewModel.platform) { platform in
            viewModel.platform = platform
        }
    }

    private var searchHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("搜索历史")
                    .font(.haoBodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if !viewModel.searchHistory.isEmpty {
                    Button("清空") {
                        viewModel.clearSearchHistory()
                        historyVersion += 1
                    }
                    .font(.haoDenseBody)
                    .foregroundStyle(theme.accent)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
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
                    }
                )
                .padding(.horizontal, 24)
            }
        }
        .id(historyVersion)
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else if viewModel.hasSearched {
                if viewModel.results.isEmpty {
                    MusicEmptyState(
                        icon: "magnifyingglass",
                        title: viewModel.hasGateway ? "没有找到相关直播间" : "直播源尚未接入",
                        note: viewModel.hasGateway
                            ? "换个关键词或平台再试试。"
                            : "搜索由直播源提供，接入后在这里显示。"
                    )
                    .padding(.horizontal, 24)
                } else {
                    LazyVGrid(
                        columns: LiveGridLayout.gridColumns,
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

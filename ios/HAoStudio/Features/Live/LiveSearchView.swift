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
        guard let gateway = gateway else {
            results = []
            hasSearched = true
            return
        }
        isSearching = true
        hasSearched = true
        let platformId = platform.rawValue
        gateway.searchRooms(query: trimmed, platform: platformId) { [weak self] rooms in
            guard let self = self else { return }
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
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.horizontal, 24)
                .padding(.top, 12)
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
        .background(theme.scaffoldBackground)
        .navigationTitle("搜索直播")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textMuted)
            TextField("搜索直播间、主播", text: $query)
                .font(.system(size: 15))
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
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.hairline, lineWidth: 0.5)
        }
    }

    private var platformRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LivePlatform.allCases) { platform in
                    Button(action: { viewModel.platform = platform }) {
                        Text(platform.displayName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(
                                platform == viewModel.platform
                                    ? theme.onAccent : theme.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                platform == viewModel.platform
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

    private var searchHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("搜索历史")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if !viewModel.searchHistory.isEmpty {
                    Button("清空") {
                        viewModel.clearSearchHistory()
                        historyVersion += 1
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            if viewModel.searchHistory.isEmpty {
                Text("还没有搜索记录")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textMuted)
                    .padding(.horizontal, 24)
            } else {
                FlexibleChips(
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

/// Wrapping keyword chips (history). A fixed-height flow: rows of
/// capsules that wrap to the next line.
private struct FlexibleChips: View {
    var items: [String]
    var onTap: (String) -> Void

    @Environment(\.haoTheme) private var theme

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 80), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(items, id: \.self) { keyword in
                Button(action: { onTap(keyword) }) {
                    Text(keyword)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(theme.surface, in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(theme.hairline, lineWidth: 0.5)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

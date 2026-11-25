// HAo Studio 2.0 — Emby search (build 36, item 17).
//
// chen: "Emby 也没有搜索". The Emby tab had no search entry at
// all, and the client-level search API had no UI. This page is
// the dedicated Emby search: submit-only (every keystroke would
// hit chen's home server), first page only (client default limit
// 50), no history — Emby search stays separate from CMS search
// and never writes into `hao_video_search_hist` (that is CMS
// history). Failures surface honestly (offline is an error state,
// never an empty "no results").
//
// Detail navigation is handed in as `onSelect` by the video tab
// (the tab owns the NavigationStack path); the page never pushes
// on its own. Results route to `.embyDetail`, never `.detail`.

import SwiftUI

@MainActor
final class EmbySearchViewModel: ObservableObject {
    @Published private(set) var results: [VideoItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searched = false
    /// Human error text (EmbyError.message — never contains the URL or key).
    @Published private(set) var errorMessage: String?
    /// Load-more paging (b49 sweep #22): the server page is 50;
    /// a full page means there may be more.
    @Published private(set) var hasMore = false

    private let gateway: VideoDataGateway
    private var searchGeneration = 0
    private var lastQuery = ""
    private var startIndex = 0
    private var loadingMore = false

    init(gateway: VideoDataGateway = VideoServices.makeGateway()) {
        self.gateway = gateway
    }

    func search(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        searched = true
        errorMessage = nil
        results = []
        hasMore = false
        lastQuery = query
        startIndex = 0
        searchGeneration += 1
        let generation = searchGeneration
        gateway.searchEmby(keyword: query, startIndex: 0) { [weak self] result in
            guard let self = self, self.searchGeneration == generation else { return }
            self.isSearching = false
            switch result {
            case .success(let items):
                self.results = items
                self.hasMore = items.count >= 50
            case .failure(let error):
                self.errorMessage = error.message
            }
        }
    }

    /// Retry the last query after a failure (error-card button).
    func retrySearch() {
        guard !lastQuery.isEmpty else { return }
        search(lastQuery)
    }

    /// Next server page, appended (b49 sweep #22). A failure
    /// keeps the loaded results and surfaces as a banner over
    /// them; paging ends either way for this query.
    func loadMore() {
        guard !loadingMore, hasMore, !lastQuery.isEmpty else { return }
        loadingMore = true
        let generation = searchGeneration
        let nextStart = startIndex + 50
        gateway.searchEmby(keyword: lastQuery, startIndex: nextStart) { [weak self] result in
            guard let self = self, self.searchGeneration == generation else { return }
            self.loadingMore = false
            switch result {
            case .success(let items):
                self.startIndex = nextStart
                var seen = Set(self.results.map { "\($0.sourceId ?? -1)|\($0.id)" })
                for item in items where seen.insert("\(item.sourceId ?? -1)|\(item.id)").inserted {
                    self.results.append(item)
                }
                self.hasMore = items.count >= 50
            case .failure(let error):
                self.hasMore = false
                self.errorMessage = error.message
            }
        }
    }
}

struct EmbySearchView: View {
    var onSelect: (VideoItem) -> Void

    @StateObject private var viewModel = EmbySearchViewModel()
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
                    } else if let error = viewModel.errorMessage, viewModel.results.isEmpty {
                        VStack(spacing: 12) {
                            MusicEmptyState(
                                icon: "wifi.exclamationmark",
                                title: "搜不了 Emby",
                                note: error
                            )
                            Button("重试") { viewModel.retrySearch() }
                                .font(.haoSubheadStrong)
                                .foregroundStyle(theme.onAccent)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .background(theme.accent, in: Capsule())
                        }
                        .padding(.horizontal, 16)
                    } else if viewModel.searched {
                        if viewModel.results.isEmpty {
                            MusicEmptyState(
                                icon: "magnifyingglass",
                                title: "没有找到相关影片",
                                note: "换个关键词试试。"
                            )
                            .padding(.horizontal, 16)
                        } else {
                            // b49 sweep #6/#22: a load-more failure
                            // is a banner over the loaded grid, not
                            // a full-page error card.
                            if let error = viewModel.errorMessage {
                                HStack(spacing: 8) {
                                    Image(systemName: "wifi.exclamationmark")
                                    Text(error)
                                        .font(.haoFootnote)
                                    Spacer()
                                    Button("重试") { viewModel.retrySearch() }
                                        .font(.haoFootnote)
                                        .foregroundStyle(theme.accentText)
                                }
                                .foregroundStyle(theme.textSecondary)
                                .padding(.horizontal, 16)
                            }
                            resultSection(items: viewModel.results)
                        }
                    } else {
                        Text("在你的 Emby 服务器上搜索电影和剧集。")
                            .font(.haoRowSubtitle)
                            .foregroundStyle(theme.textMuted)
                            .padding(.horizontal, 16)
                    }
                    Spacer(minLength: 16)
                }
                .padding(.top, 12)
            }
            .haoBottomChromePadding()
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("搜索 Emby")
        .navigationBarTitleDisplayMode(.inline)
    }

    // Same 40pt rounded search field as VideoSearchView.searchField
    // (magnifyingglass + TextField + xmark clear + 搜索 button, .onSubmit).
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.haoSubheadStrong)
                .foregroundStyle(theme.textMuted)
            TextField("搜索 Emby 影片、剧集", text: $query)
                .font(.haoSubhead)
                .foregroundStyle(theme.textPrimary)
                .submitLabel(.search)
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

    private func resultSection(items: [VideoItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Emby")
                    .font(.haoSectionTitle)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                // VidHub-style count: the number comes from the
                // loaded results, never invented — "共 N 部" only
                // once everything is loaded; while more pages
                // remain it is "已加载 N 部".
                Text(viewModel.hasMore ? "已加载 \(items.count) 部" : "共 \(items.count) 部")
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textMuted)
            }
            .padding(.horizontal, 16)
            VideoPosterGrid(items: items, isEmby: true) { item in
                onSelect(item)
            }
            .padding(.horizontal, 16)
            // b49 sweep #22: explicit load-more — the 51st result
            // used to be unreachable.
            if viewModel.hasMore {
                Button("加载更多") { viewModel.loadMore() }
                    .font(.haoSubheadStrong)
                    .foregroundStyle(theme.accentText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
    }
}

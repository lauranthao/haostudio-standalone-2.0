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

    private let gateway: VideoDataGateway
    private var searchGeneration = 0

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
        searchGeneration += 1
        let generation = searchGeneration
        gateway.searchEmby(keyword: query) { [weak self] result in
            guard let self = self, self.searchGeneration == generation else { return }
            self.isSearching = false
            switch result {
            case .success(let items):
                self.results = items
            case .failure(let error):
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
                    } else if let error = viewModel.errorMessage {
                        MusicEmptyState(
                            icon: "wifi.exclamationmark",
                            title: "搜不了 Emby",
                            note: error
                        )
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
                // VidHub-style count ("共 N 部"): the number comes
                // from the results themselves, never invented.
                // The first page is capped at 50: "共 50 部" would
                // claim the whole library. Say "前 50 部" at the cap.
                Text(items.count == 50 ? "前 50 部" : "共 \(items.count) 部")
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textMuted)
            }
            .padding(.horizontal, 16)
            VideoPosterGrid(items: items, isEmby: true) { item in
                onSelect(item)
            }
            .padding(.horizontal, 16)
        }
    }
}

// HAo Studio 2.0 — Emby category page (S3-C leg).
//
// One genre as a paged poster grid (Flutter
// emby_category_page.dart, kind = genre). The Genres chips on the
// Emby tab push here; tapping a poster opens the Emby detail page
// (the caller hands in `onSelect`).

import SwiftUI

@MainActor
final class EmbyCategoryViewModel: ObservableObject {
    @Published private(set) var items: [VideoItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true

    private let gateway: VideoDataGateway
    private let genre: String
    private var page = 0
    private var loadingMore = false
    /// Load generation: every reload bumps it. A page that lands
    /// for an older generation is dropped and the current query
    /// re-issued — otherwise a pull-to-refresh during pagination
    /// drops the fresh load and the stale page-1 items land in
    /// place of page 0 (same class as the tab's library-switch
    /// race, b35 sweep).
    private var generation = 0

    init(genre: String, gateway: VideoDataGateway = VideoServices.makeGateway()) {
        self.genre = genre
        self.gateway = gateway
    }

    func reload() {
        generation += 1
        page = 0
        hasMore = true
        items = []
        loadMore()
    }

    func loadMore() {
        guard !loadingMore, hasMore else { return }
        loadingMore = true
        isLoading = true
        let requestGeneration = generation
        gateway.fetchEmbyItems(libraryId: nil, genre: genre, page: page) { [weak self] result in
            guard let self = self else { return }
            self.loadingMore = false
            self.isLoading = false
            guard requestGeneration == self.generation else {
                if self.items.isEmpty { self.loadMore() }
                return
            }
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

/// Items in one Emby genre.
struct EmbyCategoryView: View {
    var genre: String
    var onSelect: (VideoItem) -> Void

    @StateObject private var viewModel: EmbyCategoryViewModel

    @Environment(\.haoTheme) private var theme

    init(genre: String, onSelect: @escaping (VideoItem) -> Void) {
        self.genre = genre
        self.onSelect = onSelect
        _viewModel = StateObject(wrappedValue: EmbyCategoryViewModel(genre: genre))
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
                    note: "Emby 没有返回该分类的影片。"
                )
                .padding(.horizontal, 16)
            } else {
                VideoPosterGrid(items: viewModel.items, isEmby: true) { item in
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
        .navigationTitle(genre)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { viewModel.reload() }
        .onAppear { viewModel.reload() }
    }
}

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
    /// Human error text from the last failed load (EmbyError.message).
    /// Set only on failure — an empty genre stays an empty state,
    /// never an error state.
    @Published private(set) var errorMessage: String?

    private let gateway: VideoDataGateway
    private let genre: String
    /// The library the genre was opened from (b49 sweep #5):
    /// nil = all libraries. Passed through from the Emby tab's
    /// selected chip — the page used to hardcode nil and search
    /// every library regardless of the selection.
    private let libraryId: String?
    private var page = 0
    private var loadingMore = false
    /// True once the first load was issued (E5): returning from
    /// detail must not refetch page 0 and lose the scroll position.
    private var hasLoaded = false
    /// Load generation: every reload bumps it. A page that lands
    /// for an older generation is dropped and the current query
    /// re-issued — otherwise a pull-to-refresh during pagination
    /// drops the fresh load and the stale page-1 items land in
    /// place of page 0 (same class as the tab's library-switch
    /// race, b35 sweep).
    private var generation = 0

    init(genre: String, libraryId: String? = nil, gateway: VideoDataGateway = VideoServices.makeGateway()) {
        self.genre = genre
        self.libraryId = libraryId
        self.gateway = gateway
    }

    func reload() {
        generation += 1
        page = 0
        hasMore = true
        items = []
        errorMessage = nil
        hasLoaded = true
        loadMore()
    }

    /// Return-from-detail must not refetch page 0 (the grid would
    /// jump back to the top). The first appear loads; later appears
    /// keep the grid. Pull-to-refresh still calls reload().
    func reloadIfNeeded() {
        guard !hasLoaded else { return }
        reload()
    }

    func loadMore() {
        guard !loadingMore, hasMore else { return }
        loadingMore = true
        isLoading = true
        let requestGeneration = generation
        gateway.fetchEmbyItems(libraryId: libraryId, genre: genre, page: page) { [weak self] result in
            guard let self = self else { return }
            self.loadingMore = false
            self.isLoading = false
            guard requestGeneration == self.generation else {
                if self.items.isEmpty { self.loadMore() }
                return
            }
            switch result {
            case .success(let page):
                // b49 sweep #21: a partial page carries the failed
                // side's line as a note — banner, never page error.
                self.errorMessage = page.note
                if page.items.isEmpty {
                    self.hasMore = false
                } else {
                    // Same overlap dedupe as the CMS lists: a page
                    // boundary that shifts under a changing library
                    // must not show the same poster twice.
                    var seen = Set(self.items.map { "\($0.sourceId ?? -1)|\($0.id)" })
                    for item in page.items where seen.insert("\(item.sourceId ?? -1)|\(item.id)").inserted {
                        self.items.append(item)
                    }
                    self.page += 1
                    self.hasMore = page.hasMore
                }
            case .failure(let error):
                // A dead server used to show "这个分类下没有内容"
                // (the gateway swallowed the failure to .empty).
                // Say so.
                self.errorMessage = error.message
                self.hasMore = false
            }
        }
    }
}

/// Items in one Emby genre.
struct EmbyCategoryView: View {
    var genre: String
    var libraryId: String?
    var onSelect: (VideoItem) -> Void

    @StateObject private var viewModel: EmbyCategoryViewModel

    @Environment(\.haoTheme) private var theme

    init(genre: String, libraryId: String? = nil, onSelect: @escaping (VideoItem) -> Void) {
        self.genre = genre
        self.libraryId = libraryId
        self.onSelect = onSelect
        _viewModel = StateObject(wrappedValue: EmbyCategoryViewModel(genre: genre, libraryId: libraryId))
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
                .padding(.horizontal, HaoLayout.pushedPageMargin)
            } else if viewModel.items.isEmpty {
                MusicEmptyState(
                    icon: "film",
                    title: "这个分类下没有内容",
                    note: "Emby 没有返回该分类的影片。"
                )
                .padding(.horizontal, HaoLayout.pushedPageMargin)
            } else {
                // b49 sweep #6: a later-page failure keeps the
                // loaded grid — the error is a banner, not a
                // full-page card (same rule as VideoBrowseView).
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
                VideoPosterGrid(items: viewModel.items, isEmby: true) { item in
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
        .navigationTitle(genre)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { viewModel.reload() }
        .onAppear { viewModel.reloadIfNeeded() }
    }
}

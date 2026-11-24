// HAo Studio 2.0 — Emby tab (S3-C leg).
//
// Mirrors Flutter emby_tab_page.dart: libraries + Genres chips +
// poster grids. The server connection itself (address + login)
// is B leg's EmbyClient with credentials in the Keychain; the
// settings page that configures it lands in S5. Until then the
// gateway reports `embyConfigured == false` and this tab shows
// the "not configured" state — no fake library rows, no button
// that leads nowhere.
//
// Detail and genre navigation are handed in by the video tab
// (it owns the NavigationStack path).

import SwiftUI

@MainActor
final class EmbyTabViewModel: ObservableObject {
    @Published private(set) var libraries: [VideoEmbyLibrary] = []
    @Published private(set) var genres: [String] = []
    @Published private(set) var items: [VideoItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    @Published var selectedLibraryId: String?

    private let gateway: VideoDataGateway
    private var page = 0
    private var loadingMore = false
    /// Load generation: every reload / library switch bumps it.
    /// A page that lands for an older generation belongs to the
    /// previous query — it is dropped, and the current query is
    /// re-issued (b35 sweep: tapping a library chip mid-load used
    /// to swallow the switch and show the old library's items
    /// under the new chip, because loadMore() was dropped by the
    /// loadingMore guard and nothing re-triggered it).
    private var generation = 0

    init(gateway: VideoDataGateway = VideoServices.makeGateway()) {
        self.gateway = gateway
    }

    var isConfigured: Bool { gateway.embyConfigured }

    func reload() {
        guard isConfigured else { return }
        generation += 1
        page = 0
        hasMore = true
        items = []
        gateway.fetchEmbyLibraries { [weak self] libs in
            self?.libraries = libs
        }
        gateway.fetchEmbyGenres { [weak self] names in
            self?.genres = names
        }
        loadMore()
    }

    func selectLibrary(_ id: String?) {
        selectedLibraryId = id
        generation += 1
        page = 0
        hasMore = true
        items = []
        loadMore()
    }

    func loadMore() {
        guard isConfigured, !loadingMore, hasMore else { return }
        loadingMore = true
        isLoading = true
        let requestGeneration = generation
        gateway.fetchEmbyItems(libraryId: selectedLibraryId, genre: nil, page: page) { [weak self] result in
            guard let self = self else { return }
            self.loadingMore = false
            self.isLoading = false
            guard requestGeneration == self.generation else {
                // Stale page: a reload / library switch landed
                // while it was in flight. Its items belong to the
                // old query, so drop them; the new query was
                // dropped by the loadingMore guard above, so
                // re-issue it now (items is empty after the reset).
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

struct EmbyTabView: View {
    var onSelect: (VideoItem) -> Void
    var onSelectGenre: (String) -> Void

    @StateObject private var viewModel = EmbyTabViewModel()

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            if !viewModel.isConfigured {
                VStack {
                    MusicEmptyState(
                        icon: "server.rack",
                        title: "未配置 Emby 服务器",
                        note: "在设置 → Emby 连接里添加服务器地址并登录后，这里会显示你的媒体库。"
                    )
                    Spacer()
                }
                .padding(.horizontal, 16)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Scroll anchor for the bottom chrome (b35 tab-bar
                        // link): drives minimize / restore as this tab scrolls.
                        HaoChromeScrollAnchor()
                        libraryStrip
                            .padding(.top, 12)
                        if !viewModel.genres.isEmpty {
                            genreStrip
                                .padding(.top, 12)
                        }
                        if viewModel.items.isEmpty && viewModel.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 32)
                        } else if viewModel.items.isEmpty {
                            MusicEmptyState(
                                icon: "film",
                                title: "媒体库是空的",
                                note: "该媒体库下没有影片。"
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
                }
                .haoBottomChromePadding()
                .haoChromeScrollTracking()
                .refreshable { viewModel.reload() }
            }
        }
        .onAppear { viewModel.reload() }
    }

    private var libraryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                libraryChip(id: nil, name: "全部")
                ForEach(viewModel.libraries) { library in
                    libraryChip(id: library.id, name: library.name)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func libraryChip(id: String?, name: String) -> some View {
        let selected = viewModel.selectedLibraryId == id
        return Button(action: { viewModel.selectLibrary(id) }) {
            Text(name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? theme.onAccent : theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? theme.accent : theme.surface, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(theme.hairline, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
    }

    /// Genres chips (P0-10: Emby 分类扩展 — 电影/电视之外接 Genres).
    private var genreStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("分类")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.genres, id: \.self) { genre in
                        Button(action: { onSelectGenre(genre) }) {
                            Text(genre)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(theme.textPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(theme.surface, in: Capsule())
                                .overlay {
                                    Capsule().strokeBorder(theme.hairline, lineWidth: 0.5)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

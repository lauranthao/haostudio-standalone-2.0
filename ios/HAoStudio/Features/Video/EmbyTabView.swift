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
    /// Server continue watching (b38): the server's Resume list
    /// (in-progress movies + episodes with positions), loaded
    /// alongside the libraries. A failed fetch reads as empty —
    /// resume is best-effort, never a page error.
    @Published private(set) var resumeItems: [EmbyResumeItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    /// Human error text from the last failed load (EmbyError.message).
    /// Set only on failure — an empty library stays an empty state,
    /// never an error state.
    @Published private(set) var errorMessage: String?
    /// (b49fix2 P1-12) The last loadMore failed: the grid keeps
    /// its loaded rows and the banner retries just that page
    /// (retryFailedPage), instead of reload() wiping the grid
    /// and losing the scroll position. `hasMore` stays false so
    /// the auto-load trigger does not retry it on its own.
    @Published private(set) var loadMoreFailed = false
    /// True when the last failure was a 401: the credential is
    /// wrong, so the error state offers a re-login path (not just
    /// a retry that fails the same way).
    @Published private(set) var isUnauthorized = false
    @Published var selectedLibraryId: String?

    private let gateway: VideoDataGateway
    private var page = 0
    private var loadingMore = false
    /// True once the first load was issued (E5): returning from
    /// detail must not refetch page 0 and lose the scroll position.
    private var hasLoaded = false
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
        resumeItems = []
        errorMessage = nil
        loadMoreFailed = false
        isUnauthorized = false
        hasLoaded = true
        gateway.fetchEmbyLibraries { [weak self] libs in
            self?.libraries = libs
        }
        gateway.fetchEmbyGenres { [weak self] names in
            self?.genres = names
        }
        let requestGeneration = generation
        gateway.fetchEmbyResume { [weak self] result in
            guard let self = self, requestGeneration == self.generation else { return }
            switch result {
            case .success(let resume): self.resumeItems = resume
            case .failure: self.resumeItems = []
            }
        }
        loadMore()
    }

    /// Return-from-detail must not refetch page 0 (the grid would
    /// jump back to the top). The first appear loads; later appears
    /// keep the grid. Pull-to-refresh still calls reload().
    func reloadIfNeeded() {
        guard !hasLoaded else { return }
        reload()
    }

    func selectLibrary(_ id: String?) {
        selectedLibraryId = id
        generation += 1
        page = 0
        hasMore = true
        items = []
        errorMessage = nil
        loadMoreFailed = false
        isUnauthorized = false
        loadMore()
    }

    /// (b49fix2 P1-12) Retry only the page that failed: the
    /// loaded rows stay, the scroll position stays, and only
    /// the failed page is re-requested. `loadMore()` is guarded
    /// by `hasMore`, so re-arm it first — the failure set it
    /// false to stop the auto-load trigger.
    func retryFailedPage() {
        guard isConfigured, !loadingMore, loadMoreFailed else { return }
        loadMoreFailed = false
        errorMessage = nil
        isUnauthorized = false
        hasMore = true
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
            switch result {
            case .success(let page):
                // b49 sweep #21: a partial page carries the failed
                // side's line as a note — it shows as a banner
                // over the grid, never as a page error.
                self.errorMessage = page.note
                self.loadMoreFailed = false
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
                // A dead server used to show "媒体库是空的" (the
                // gateway swallowed the failure to .empty). Say so.
                // (b49fix2 P1-12) The rows stay: only the flag +
                // the banner change, so the retry is page-only.
                self.errorMessage = error.message
                self.loadMoreFailed = true
                self.isUnauthorized = error.kind == .unauthorized
                self.hasMore = false
            }
        }
    }
}

struct EmbyTabView: View {
    var onSelect: (VideoItem) -> Void
    /// Genre tap hands over the selected library too (b49 sweep
    /// #5): the genre page filters within it instead of silently
    /// searching every library.
    var onSelectGenre: (String?, String) -> Void
    /// Opens the dedicated Emby search page (build 36, item 17).
    /// Handed in like onSelect: the tab owns the NavigationStack
    /// path and never pushes on its own.
    var onSearch: () -> Void

    @StateObject private var viewModel = EmbyTabViewModel()
    /// Re-login sheet (401 only): the config page lives in
    /// Settings; from here it opens as a sheet, never pushed
    /// onto the video tab's NavigationStack.
    @State private var showingEmbyConfig = false

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
                .padding(.horizontal, HaoLayout.pageMargin)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            // Scroll anchor for the bottom chrome (b35 tab-bar
                            // link): drives minimize / restore as this tab scrolls.
                            HaoChromeScrollAnchor()
                                .id(HaoTabScrollTop.id(for: .movies))
                            searchEntry
                                .padding(.horizontal, HaoLayout.pageMargin)
                                .padding(.top, 12)
                            if !viewModel.resumeItems.isEmpty {
                                embyContinueSection
                                    .padding(.top, HaoLayout.sectionTopSpacing)
                            }
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
                        } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
                            VStack(spacing: 12) {
                                MusicEmptyState(
                                    icon: "wifi.exclamationmark",
                                    title: "连不上 Emby",
                                    note: error
                                )
                                HStack(spacing: 12) {
                                    Button("重试") { viewModel.reload() }
                                        .font(.haoSubheadStrong)
                                        .foregroundStyle(theme.onAccent)
                                        .padding(.horizontal, 24)
                                        .padding(.vertical, 12)
                                        .background(theme.accent, in: Capsule())
                                    // 401 means the credential itself
                                    // is wrong: retrying fails the
                                    // same way. Offer the login page
                                    // directly instead of stranding
                                    // the user on a dead retry.
                                    if viewModel.isUnauthorized {
                                        Button("重新登录") { showingEmbyConfig = true }
                                            .font(.haoSubheadStrong)
                                            .foregroundStyle(theme.accentText)
                                            .padding(.horizontal, 24)
                                            .padding(.vertical, 12)
                                            .background(theme.surface, in: Capsule())
                                            .overlay {
                                                Capsule()
                                                    .strokeBorder(theme.hairline, lineWidth: 0.5)
                                            }
                                    }
                                }
                            }
                            .padding(.horizontal, HaoLayout.pageMargin)
                            } else if viewModel.items.isEmpty {
                                MusicEmptyState(
                                    icon: "film",
                                    title: "媒体库是空的",
                                    note: "该媒体库下没有影片。"
                                )
                                .padding(.horizontal, HaoLayout.pageMargin)
                            } else {
                                // b49 sweep #6: a later-page failure
                                // keeps the loaded grid — the error
                                // is a banner, not a full-page card
                                // (same rule as VideoBrowseView).
                                if let error = viewModel.errorMessage {
                                    HStack(spacing: 8) {
                                        Image(systemName: "wifi.exclamationmark")
                                        Text(error)
                                            .font(.haoFootnote)
                                        Spacer()
                                        // (b49fix2 P1-12) A failed
                                        // page retries just that
                                        // page (rows + scroll stay);
                                        // a partial-page note
                                        // reloads, as before.
                                        Button("重试") {
                                            if viewModel.loadMoreFailed {
                                                viewModel.retryFailedPage()
                                            } else {
                                                viewModel.reload()
                                            }
                                        }
                                            .font(.haoFootnoteMedium)
                                            .foregroundStyle(theme.accentText)
                                    }
                                    .foregroundStyle(theme.textSecondary)
                                    .padding(.horizontal, HaoLayout.pageMargin)
                                    .padding(.top, 12)
                                }
                                VideoPosterGrid(items: viewModel.items, isEmby: true) { item in
                                    onSelect(item)
                                }
                                .padding(.horizontal, HaoLayout.pageMargin)
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
                        // b42: bottom clearance lives INSIDE the
                        // scroll content (same as the other tab
                        // roots) — the ScrollView's safeAreaPadding
                        // (.haoBottomChromePadding) never reached
                        // the rows inside a NavigationStack, so the
                        // Emby grid's last row stayed under the
                        // chrome on device.
                        .haoBottomChromeContentPadding()
                    }
                    .haoChromeScrollTracking()
                    .haoReselectScrollToTop(tab: .movies, proxy: proxy)
                    .refreshable { viewModel.reload() }
                }
            }
        }
        .onAppear { viewModel.reloadIfNeeded() }
        .sheet(isPresented: $showingEmbyConfig, onDismiss: { viewModel.reload() }) {
            NavigationStack { EmbyConfigView() }
        }
    }

    /// Server continue watching (b38): the server's Resume list,
    /// not the local history — items in progress on any device.
    /// Same card + rhythm as the CMS home's continue section.
    private var embyContinueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("继续观看")
                    .font(.haoSectionTitle)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, HaoLayout.pageMargin)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.resumeItems) { entry in
                        VideoContinueCard(entry: resumeHistoryEntry(entry)) {
                            openResumeItem(entry)
                        }
                    }
                }
                .padding(.horizontal, HaoLayout.pageMargin)
            }
        }
    }

    /// Map a server resume entry onto the local history row the
    /// continue card renders (same shape: item + episode +
    /// position + duration). The card never writes the store —
    /// the tap does.
    private func resumeHistoryEntry(_ entry: EmbyResumeItem) -> VideoHistoryEntry {
        VideoHistoryEntry(
            item: entry.item, episodeName: entry.episodeName, episodeIndex: 0,
            lineName: "直链", positionSeconds: entry.positionSeconds,
            durationSeconds: entry.durationSeconds, updatedAt: Date())
    }

    /// Tap a server resume row: seed the local resume from the
    /// server position first (the detail page's play button reads
    /// only the local store), then open the detail. The seed is
    /// the server's own position for this item — no invented
    /// numbers — and the normal playback flow takes over from
    /// there, so the seed never goes stale.
    private func openResumeItem(_ entry: EmbyResumeItem) {
        VideoLibraryStore.savePosition(
            item: entry.item, episodeName: entry.episodeName, episodeIndex: 0,
            lineName: "直链", positionSeconds: entry.positionSeconds,
            durationSeconds: entry.durationSeconds)
        onSelect(entry.item)
    }

    /// Search entry (build 36, item 17): visually identical to
    /// the CMS `searchEntry` in VideoTabView (48pt,
    /// RoundedRectangle(cornerRadius: 12), magnifyingglass +
    /// placeholder) so the two modes feel consistent — but it
    /// opens the dedicated Emby search page, never CMS search.
    /// Configured branch only: the not-configured branch shows
    /// no button leading nowhere.
    private var searchEntry: some View {
        Button(action: onSearch) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.haoSubheadStrong)
                    .foregroundStyle(theme.textMuted)
                Text("搜索 Emby 影片、剧集")
                    .font(.haoSubhead)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: HaoLayout.searchFieldHeight)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: HaoLayout.cornerMedium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: HaoLayout.cornerMedium, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private var libraryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                libraryChip(id: nil, name: "全部")
                ForEach(viewModel.libraries) { library in
                    libraryChip(id: library.id, name: library.name)
                }
            }
            .padding(.horizontal, HaoLayout.pageMargin)
        }
        .haoSensoryFeedback(.selection, trigger: viewModel.selectedLibraryId)
    }

    private func libraryChip(id: String?, name: String) -> some View {
        let selected = viewModel.selectedLibraryId == id
        return Button(action: { viewModel.selectLibrary(id) }) {
            Text(name)
                .font(.haoDenseBody)
                .foregroundStyle(selected ? theme.onAccent : theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? theme.accent : theme.surface, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(theme.hairline, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .animation(HaoLayout.settleSpring, value: viewModel.selectedLibraryId)
    }

    /// Genres chips (P0-10: Emby 分类扩展 — 电影/电视之外接 Genres).
    private var genreStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("分类")
                .font(.haoSectionTitle)
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, HaoLayout.pageMargin)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.genres, id: \.self) { genre in
                        Button(action: { onSelectGenre(viewModel.selectedLibraryId, genre) }) {
                            Text(genre)
                                .font(.haoDenseBody)
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
                .padding(.horizontal, HaoLayout.pageMargin)
            }
        }
    }
}

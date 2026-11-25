// HAo Studio 2.0 — music search view model (S2-C leg + b45-d tabs).
//
// Streaming search (Flutter SongSearchService.searchAllStream):
// - one query searches ALL platforms by default — there is NO
//   platform selector in this UI (chen's rule; the search-platform
//   capsule in Flutter is not carried over);
// - each settled leg appends its batch through the merge (first
//   result ~1s, no waiting for the slowest leg; NetEase + QQ first);
// - search history (max 20, newest first) is saved on every
//   submitted query.
//
// b45-d (Coda P4, §5): five tabs — 综合 / 单曲 / 歌手 / 专辑 / 歌单.
// The song stream is unchanged and still renders first (~1s); the
// card kinds (artists / albums / playlists) arrive afterwards, each
// from its own fan-out, and a failed kind contributes empty while
// the others still render (per-kind error + in-section retry, never
// a whole-page error). Tab switches restore a snapshot instead of
// re-fetching; a generation UUID drops stale results from an older
// query. There is NO 400 ms tab debounce (Coda's) and NO
// type-to-search debounce — search still only fires on submit.
// Suggestion words are a separate debounced task (250 ms) and never
// touch the results.
//
// Finality: the LX contract's completion handler is called once per
// settled leg batch and carries no "done" flag (see the C-leg
// report). The "searching" footer therefore settles by quiet: no
// batch for 10 s (the per-platform timeout Flutter used) means the
// search is done. A new batch re-arms it.

import Combine
import SwiftUI

/// Search tab (Coda §5.2 form, our values). `all` is always
/// available; the other tabs render only when the matching category
/// endpoint exists (see `supportedTabs` — all four kinds have
/// verified no-login endpoints, so all five show today).
enum MusicSearchTab: String, CaseIterable, Identifiable {
    case all = "综合"
    case songs = "单曲"
    case artists = "歌手"
    case albums = "专辑"
    case playlists = "歌单"

    var id: String { rawValue }

    /// Category kind behind this tab, if any (`.all` and `.songs`
    /// have none — songs come from the stream, not a category fetch).
    var categoryKind: MusicSearchAPI.MusicSearchCategoryKind? {
        switch self {
        case .artists: return .artists
        case .albums: return .albums
        case .playlists: return .playlists
        case .all, .songs: return nil
        }
    }
}

@MainActor
final class MusicSearchViewModel: ObservableObject {
    @Published var keyword = ""
    @Published private(set) var results: [MusicSong] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasSearched = false
    @Published private(set) var history: [String] = []

    // MARK: - Tabs + snapshots (b45-d)

    @Published private(set) var tab: MusicSearchTab = .all
    @Published private(set) var artists: [ArtistSummary] = []
    @Published private(set) var albums: [AlbumSummary] = []
    @Published private(set) var playlists: [PlaylistSummary] = []

    /// Tabs the Picker renders. Gated on real endpoints: 综合 is
    /// always there; a kind tab hides only if its category has no
    /// endpoint at all (none today — all four kinds verified).
    var supportedTabs: [MusicSearchTab] {
        MusicSearchTab.allCases.filter { tab in
            tab == .all || tab == .songs || tab.categoryKind != nil
        }
    }

    /// One tab's restorable state (Coda §5.2 Snapshot): the four
    /// result arrays (songs are shared, so only their paging is
    /// snapshotted) + song paging + per-kind paging + per-kind
    /// errors. The per-kind merges ride along too — without them a
    /// load-more after switching back would append onto the other
    /// tab's 50-item page instead of this tab's 10. Restoring never
    /// re-fetches.
    struct SearchSnapshot {
        var artists: [ArtistSummary] = []
        var albums: [AlbumSummary] = []
        var playlists: [PlaylistSummary] = []
        var artistMerge: MusicSearchCategoryMerge<ArtistSummary>?
        var albumMerge: MusicSearchCategoryMerge<AlbumSummary>?
        var playlistMerge: MusicSearchCategoryMerge<PlaylistSummary>?
        var songPage = 0
        var hasMoreSongs = true
        var cardPages: [MusicSearchAPI.MusicSearchCategoryKind: Int] = [:]
        var cardHasMore: [MusicSearchAPI.MusicSearchCategoryKind: Bool] = [:]
        var cardErrors: [MusicSearchAPI.MusicSearchCategoryKind: Bool] = [:]
    }

    private var snapshots: [MusicSearchTab: SearchSnapshot] = [:]
    private var loadedTabs: Set<MusicSearchTab> = []

    /// Generation guard (Coda §5.2): a new UUID on every search;
    /// every category / page completion checks it and drops stale
    /// results from an older query instead of mixing them in.
    private var generation = UUID()

    // MARK: - Songs paging (b45-d)

    /// Extra song pages loaded (0 = streamed first page only).
    @Published private(set) var songPage = 0
    @Published private(set) var hasMoreSongs = true
    @Published private(set) var isLoadingMoreSongs = false
    /// A page fetch failed with nothing new: keep the old rows and
    /// offer "加载更多失败，点击重试".
    @Published private(set) var songPageError = false
    /// Deep-page cap: five extra pages (~350 more songs). Kugou /
    /// Kuwo page server-side, so this is a UI cap, not a cost cap.
    static let maxSongPages = 5

    // MARK: - Card paging + errors (b45-d)

    /// First-page size on the 综合 tab (Coda §5.3: 10 per kind).
    static let allTabCardLimit = 10
    /// Single-kind tab page size (Coda §5.3: 50 per kind).
    static let singleTabCardLimit = 50

    /// Pages loaded per kind (0 = first page not yet loaded).
    @Published private(set) var cardPages: [MusicSearchAPI.MusicSearchCategoryKind: Int] = [:]
    @Published private(set) var cardHasMore: [MusicSearchAPI.MusicSearchCategoryKind: Bool] = [:]
    /// Kinds currently fetching (one at a time per kind).
    @Published private(set) var loadingCards: Set<MusicSearchAPI.MusicSearchCategoryKind> = []
    /// Kinds whose last fetch failed (empty results, retry offered
    /// inside that section — never a whole-page error).
    @Published private(set) var cardErrors: [MusicSearchAPI.MusicSearchCategoryKind: Bool] = [:]

    // MARK: - Suggestions + hot keywords (b45-d)

    /// Suggestion / hot words for the current draft query (empty
    /// query = hot words, otherwise suggestions). Capped at 8 by
    /// the API; the view shows them as chips.
    @Published private(set) var suggestions: [String] = []
    private var suggestionTask: Task<Void, Never>?
    private var lastSuggestionText = ""

    /// Seconds of quiet after the last batch before the search is
    /// considered settled (Flutter's per-platform search timeout).
    static let settleQuietSeconds: TimeInterval = 10

    private var merge = MusicSearchMerge()
    private var artistMerge = MusicSearchViewModel.freshArtistMerge()
    private var albumMerge = MusicSearchViewModel.freshAlbumMerge()
    private var playlistMerge = MusicSearchViewModel.freshPlaylistMerge()

    /// Which tab started each kind's in-flight fetch. A fetch that
    /// lands after the user switched tabs updates its OWNER tab's
    /// snapshot — never the live arrays of the tab now on screen
    /// (otherwise switching back would restore the stale empty
    /// snapshot over the fresh data).
    private var categoryFetchTab: [MusicSearchAPI.MusicSearchCategoryKind: MusicSearchTab] = [:]

    static func freshArtistMerge() -> MusicSearchCategoryMerge<ArtistSummary> {
        MusicSearchCategoryMerge(
            key: { $0.id.isEmpty ? "name|\($0.name.lowercased())" : "\($0.platform.rawValue)|\($0.id)" },
            priority: { $0.platform.searchPriority })
    }

    static func freshAlbumMerge() -> MusicSearchCategoryMerge<AlbumSummary> {
        MusicSearchCategoryMerge(
            key: { $0.id.isEmpty ? "name|\($0.name.lowercased())|\($0.artist.lowercased())" : "\($0.platform.rawValue)|\($0.id)" },
            priority: { $0.platform.searchPriority })
    }

    static func freshPlaylistMerge() -> MusicSearchCategoryMerge<PlaylistSummary> {
        MusicSearchCategoryMerge(
            key: { $0.id.isEmpty ? "name|\($0.name.lowercased())|\($0.creator.lowercased())" : "\($0.platform.rawValue)|\($0.id)" },
            priority: { $0.platform.searchPriority })
    }
    private var settleTimer: Timer?
    private var currentQuery = ""

    init() {
        history = MusicLibraryStore.getSearchHistory()
    }

    // MARK: - Search

    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        currentQuery = trimmed
        keyword = trimmed
        generation = UUID()
        merge.reset()
        artistMerge.reset()
        albumMerge.reset()
        playlistMerge.reset()
        results = []
        artists = []
        albums = []
        playlists = []
        tab = .all
        snapshots = [:]
        loadedTabs = []
        categoryFetchTab = [:]
        songPage = 0
        hasMoreSongs = true
        isLoadingMoreSongs = false
        songPageError = false
        cardPages = [:]
        cardHasMore = [:]
        loadingCards = []
        cardErrors = [:]
        hasSearched = true
        isSearching = true
        armSettleTimer()
        MusicLibraryStore.saveSearchQuery(trimmed)
        history = MusicLibraryStore.getSearchHistory()
        MusicSearchAPI.shared.search(keyword: trimmed) { [weak self] batch in
            guard let self = self else { return }
            // Stale leg from an older query: drop it, never mix.
            guard trimmed == self.currentQuery else { return }
            let songs = batch.map(MusicSong.init(from:))
            self.merge.appendBatch(songs)
            self.results = self.merge.tracks
            self.isSearching = true
            self.armSettleTimer()
        }
        // Card kinds stream in after the songs — each kind fails
        // independently (empty + in-section retry, others unaffected).
        loadTabCategories(.all, limit: Self.allTabCardLimit)
    }

    /// A new query cancels the old one: results clear immediately and
    /// late batches from the old query are dropped by the query check.
    func clear() {
        keyword = ""
        currentQuery = ""
        generation = UUID()
        merge.reset()
        artistMerge.reset()
        albumMerge.reset()
        playlistMerge.reset()
        results = []
        artists = []
        albums = []
        playlists = []
        tab = .all
        snapshots = [:]
        loadedTabs = []
        categoryFetchTab = [:]
        songPage = 0
        hasMoreSongs = true
        isLoadingMoreSongs = false
        songPageError = false
        cardPages = [:]
        cardHasMore = [:]
        loadingCards = []
        cardErrors = [:]
        suggestions = []
        lastSuggestionText = ""
        suggestionTask?.cancel()
        suggestionTask = nil
        hasSearched = false
        isSearching = false
        settleTimer?.invalidate()
        settleTimer = nil
    }

    func clearHistory() {
        MusicLibraryStore.clearSearchHistory()
        history = []
    }

    func removeHistoryItem(_ query: String) {
        MusicLibraryStore.removeSearchQuery(query)
        history = MusicLibraryStore.getSearchHistory()
    }

    private func armSettleTimer() {
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: Self.settleQuietSeconds, repeats: false) { [weak self] _ in
            self?.isSearching = false
        }
    }

    // MARK: - Tabs (b45-d)

    /// Switch tabs. A snapshotted tab restores without re-fetching;
    /// a never-loaded tab fetches its first page (songs need no
    /// fetch — the stream already fills them).
    func selectTab(_ newTab: MusicSearchTab) {
        guard newTab != tab, supportedTabs.contains(newTab) else { return }
        saveSnapshot()
        tab = newTab
        if let snapshot = snapshots[newTab] {
            restore(snapshot)
            return
        }
        guard !loadedTabs.contains(newTab) else { return }
        loadedTabs.insert(newTab)
        switch newTab {
        case .all:
            loadTabCategories(.all, limit: Self.allTabCardLimit)
        case .songs:
            break
        case .artists, .albums, .playlists:
            if let kind = newTab.categoryKind {
                loadCategory(kind, limit: Self.singleTabCardLimit, offset: 0, isFirstPage: true)
            }
        }
    }

    /// Save the current tab's state so switching back restores it.
    private func saveSnapshot() {
        var snapshot = snapshots[tab] ?? SearchSnapshot()
        snapshot.artists = artists
        snapshot.albums = albums
        snapshot.playlists = playlists
        snapshot.artistMerge = artistMerge
        snapshot.albumMerge = albumMerge
        snapshot.playlistMerge = playlistMerge
        snapshot.songPage = songPage
        snapshot.hasMoreSongs = hasMoreSongs
        snapshot.cardPages = cardPages
        snapshot.cardHasMore = cardHasMore
        snapshot.cardErrors = cardErrors
        snapshots[tab] = snapshot
    }

    private func restore(_ snapshot: SearchSnapshot) {
        artists = snapshot.artists
        albums = snapshot.albums
        playlists = snapshot.playlists
        if let merge = snapshot.artistMerge { artistMerge = merge }
        if let merge = snapshot.albumMerge { albumMerge = merge }
        if let merge = snapshot.playlistMerge { playlistMerge = merge }
        songPage = snapshot.songPage
        hasMoreSongs = snapshot.hasMoreSongs
        cardPages = snapshot.cardPages
        cardHasMore = snapshot.cardHasMore
        cardErrors = snapshot.cardErrors
    }

    /// Fetch all three card kinds for the 综合 tab (first page).
    private func loadTabCategories(_ tab: MusicSearchTab, limit: Int) {
        guard tab == .all else { return }
        loadedTabs.insert(.all)
        for kind in MusicSearchAPI.MusicSearchCategoryKind.allCases {
            loadCategory(kind, limit: limit, offset: 0, isFirstPage: true)
        }
    }

    /// Fetch one page of one kind. First page replaces, later pages
    /// append (deduped). `hasMore` follows Coda §5.3: the page was
    /// full AND (when a total is known) the cumulative count is
    /// still below it; with no total, a full page means "more".
    private func loadCategory(_ kind: MusicSearchAPI.MusicSearchCategoryKind, limit: Int, offset: Int, isFirstPage: Bool) {
        guard hasSearched, !loadingCards.contains(kind) else { return }
        let query = currentQuery
        guard !query.isEmpty else { return }
        let gen = generation
        categoryFetchTab[kind] = tab
        loadingCards.insert(kind)
        cardErrors[kind] = false
        switch kind {
        case .artists:
            MusicSearchAPI.shared.searchArtists(keyword: query, limit: limit, offset: offset) { [weak self] items, total, ok in
                self?.finishCategory(kind, items: items, total: total, ok: ok, limit: limit, offset: offset, isFirstPage: isFirstPage, gen: gen)
            }
        case .albums:
            MusicSearchAPI.shared.searchAlbums(keyword: query, limit: limit, offset: offset) { [weak self] items, total, ok in
                self?.finishCategory(kind, items: items, total: total, ok: ok, limit: limit, offset: offset, isFirstPage: isFirstPage, gen: gen)
            }
        case .playlists:
            MusicSearchAPI.shared.searchPlaylists(keyword: query, limit: limit, offset: offset) { [weak self] items, total, ok in
                self?.finishCategory(kind, items: items, total: total, ok: ok, limit: limit, offset: offset, isFirstPage: isFirstPage, gen: gen)
            }
        }
    }

    /// Shared guard for a category completion: stale fetch from an
    /// older query is dropped. Returns the tab that owns this fetch
    /// (the tab it was started from), or nil to stop. A failed kind
    /// contributes empty and records its error — on the live state
    /// when the owner is on screen, in the owner's snapshot when
    /// the user has since switched away (so switching back still
    /// offers the retry instead of a false empty state).
    private func beginCategoryFinish(_ kind: MusicSearchAPI.MusicSearchCategoryKind, ok: Bool, gen: UUID) -> MusicSearchTab? {
        guard gen == generation, hasSearched else { return nil }
        let owner = categoryFetchTab[kind] ?? tab
        loadingCards.remove(kind)
        guard ok else {
            if owner == tab {
                cardErrors[kind] = true
                cardHasMore[kind] = false
            } else {
                var snap = snapshots[owner] ?? SearchSnapshot()
                snap.cardErrors[kind] = true
                snap.cardHasMore[kind] = false
                snapshots[owner] = snap
            }
            return nil
        }
        if owner == tab {
            cardErrors[kind] = false
        }
        return owner
    }

    /// `hasMore` follows Coda §5.3: the page was full AND (when a
    /// total is known) the cumulative count is still below it; with
    /// no total, a full page means "more".
    private func finishCategory(_ kind: MusicSearchAPI.MusicSearchCategoryKind, items: [ArtistSummary], total: Int?, ok: Bool, limit: Int, offset: Int, isFirstPage: Bool, gen: UUID) {
        guard let owner = beginCategoryFinish(kind, ok: ok, gen: gen) else { return }
        if owner == tab {
            if isFirstPage {
                artistMerge.reset()
                cardPages[kind] = 0
            } else {
                cardPages[kind] = offset / max(limit, 1)
            }
            _ = artistMerge.append(items)
            artists = artistMerge.items
            cardHasMore[kind] = items.count == limit && (total.map { artists.count < $0 } ?? true)
            saveSnapshot()
        } else {
            var snap = snapshots[owner] ?? SearchSnapshot()
            var merge = snap.artistMerge ?? Self.freshArtistMerge()
            if isFirstPage { merge.reset() }
            _ = merge.append(items)
            snap.artistMerge = merge
            snap.artists = merge.items
            snap.cardPages[kind] = isFirstPage ? 0 : offset / max(limit, 1)
            snap.cardHasMore[kind] = items.count == limit && (total.map { merge.count < $0 } ?? true)
            snap.cardErrors[kind] = false
            snapshots[owner] = snap
        }
    }

    private func finishCategory(_ kind: MusicSearchAPI.MusicSearchCategoryKind, items: [AlbumSummary], total: Int?, ok: Bool, limit: Int, offset: Int, isFirstPage: Bool, gen: UUID) {
        guard let owner = beginCategoryFinish(kind, ok: ok, gen: gen) else { return }
        if owner == tab {
            if isFirstPage {
                albumMerge.reset()
                cardPages[kind] = 0
            } else {
                cardPages[kind] = offset / max(limit, 1)
            }
            _ = albumMerge.append(items)
            albums = albumMerge.items
            cardHasMore[kind] = items.count == limit && (total.map { albums.count < $0 } ?? true)
            saveSnapshot()
        } else {
            var snap = snapshots[owner] ?? SearchSnapshot()
            var merge = snap.albumMerge ?? Self.freshAlbumMerge()
            if isFirstPage { merge.reset() }
            _ = merge.append(items)
            snap.albumMerge = merge
            snap.albums = merge.items
            snap.cardPages[kind] = isFirstPage ? 0 : offset / max(limit, 1)
            snap.cardHasMore[kind] = items.count == limit && (total.map { merge.count < $0 } ?? true)
            snap.cardErrors[kind] = false
            snapshots[owner] = snap
        }
    }

    private func finishCategory(_ kind: MusicSearchAPI.MusicSearchCategoryKind, items: [PlaylistSummary], total: Int?, ok: Bool, limit: Int, offset: Int, isFirstPage: Bool, gen: UUID) {
        guard let owner = beginCategoryFinish(kind, ok: ok, gen: gen) else { return }
        if owner == tab {
            if isFirstPage {
                playlistMerge.reset()
                cardPages[kind] = 0
            } else {
                cardPages[kind] = offset / max(limit, 1)
            }
            _ = playlistMerge.append(items)
            playlists = playlistMerge.items
            cardHasMore[kind] = items.count == limit && (total.map { playlists.count < $0 } ?? true)
            saveSnapshot()
        } else {
            var snap = snapshots[owner] ?? SearchSnapshot()
            var merge = snap.playlistMerge ?? Self.freshPlaylistMerge()
            if isFirstPage { merge.reset() }
            _ = merge.append(items)
            snap.playlistMerge = merge
            snap.playlists = merge.items
            snap.cardPages[kind] = isFirstPage ? 0 : offset / max(limit, 1)
            snap.cardHasMore[kind] = items.count == limit && (total.map { merge.count < $0 } ?? true)
            snap.cardErrors[kind] = false
            snapshots[owner] = snap
        }
    }

    // MARK: - Load more (b45-d)

    /// Next songs page (songs tab, last row appeared). Guards: the
    /// songs tab is active, more is expected, no page in flight.
    /// A failed page keeps the old rows and sets `songPageError`
    /// (retry button); an empty successful page ends pagination.
    func loadMoreSongs() {
        guard hasSearched, tab == .songs, hasMoreSongs, !isLoadingMoreSongs, songPage < Self.maxSongPages else { return }
        let query = currentQuery
        guard !query.isEmpty else { return }
        let gen = generation
        let nextPage = songPage + 1
        isLoadingMoreSongs = true
        songPageError = false
        MusicSearchAPI.shared.searchSongsPage(keyword: query, page: nextPage) { [weak self] tracks, ok, full in
            guard let self = self else { return }
            // Dropped when the user left the songs tab mid-flight:
            // the page is re-requested on the next scroll-to-end
            // instead of landing its page counter in the wrong tab's
            // snapshot (where a pure-duplicate re-fetch would then
            // wrongly end pagination).
            guard gen == self.generation, self.hasSearched, self.tab == .songs else {
                self.isLoadingMoreSongs = false
                return
            }
            self.isLoadingMoreSongs = false
            guard ok else {
                self.songPageError = true
                return
            }
            self.songPageError = false
            let songs = tracks.map(MusicSong.init(from:))
            let added = self.merge.appendBatch(songs)
            self.results = self.merge.tracks
            self.armSettleTimer()
            if !added.isEmpty {
                self.songPage = nextPage
            }
            // A full page means more may exist; a short page ends it.
            // (A page of pure duplicates also ends it — the next
            // page would only repeat the same window.)
            self.hasMoreSongs = full && !added.isEmpty && nextPage < Self.maxSongPages
            self.saveSnapshot()
        }
    }

    /// Retry a failed songs page (the bottom "加载更多失败，点击重试"
    /// button). Same guards as `loadMoreSongs`, minus the error flag.
    func retrySongsPage() {
        guard hasSearched, tab == .songs, hasMoreSongs, !isLoadingMoreSongs else { return }
        songPageError = false
        loadMoreSongs()
    }

    /// Next card page for one kind (shelf / grid scrolled to the
    /// end). Guards: the kind's tab (or 综合) is active, the kind
    /// is loaded, more is expected, no fetch in flight for it.
    func loadMoreCards(_ kind: MusicSearchAPI.MusicSearchCategoryKind) {
        guard hasSearched, !loadingCards.contains(kind) else { return }
        guard tab == .all || tab.categoryKind == kind else { return }
        guard cardHasMore[kind] == true else { return }
        let page = (cardPages[kind] ?? 0) + 1
        // Single-kind tabs page at 50; the 综合 shelves page at 10.
        let limit = tab == .all ? Self.allTabCardLimit : Self.singleTabCardLimit
        loadCategory(kind, limit: limit, offset: page * limit, isFirstPage: false)
    }

    /// Retry one failed kind from inside its own section.
    func retryCategory(_ kind: MusicSearchAPI.MusicSearchCategoryKind) {
        guard hasSearched, !loadingCards.contains(kind) else { return }
        let limit = tab == .all ? Self.allTabCardLimit : Self.singleTabCardLimit
        let offset = (cardPages[kind] ?? 0) * limit
        let isFirst = (cardPages[kind] ?? 0) == 0 && {
            switch kind {
            case .artists: return artists.isEmpty
            case .albums: return albums.isEmpty
            case .playlists: return playlists.isEmpty
            }
        }()
        loadCategory(kind, limit: limit, offset: offset, isFirstPage: isFirst)
    }

    // MARK: - Suggestions + hot keywords (b45-d)

    /// Refresh the chips for the draft text. Debounced 250 ms in
    /// its own task; an empty query fetches hot words, otherwise
    /// suggestion words. Stale results (text already changed, task
    /// cancelled) are dropped — chips never overwrite a newer query.
    func refreshSuggestions(for text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastSuggestionText = trimmed
        suggestionTask?.cancel()
        suggestionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self = self, !Task.isCancelled else { return }
            guard trimmed == self.lastSuggestionText else { return }
            if trimmed.isEmpty {
                MusicSearchAPI.shared.hotKeywords { [weak self] words in
                    guard let self = self, !Task.isCancelled else { return }
                    guard self.lastSuggestionText.isEmpty else { return }
                    self.suggestions = words
                }
            } else {
                MusicSearchAPI.shared.searchSuggestions(keyword: trimmed) { [weak self] words in
                    guard let self = self, !Task.isCancelled else { return }
                    guard trimmed == self.lastSuggestionText else { return }
                    self.suggestions = words
                }
            }
        }
    }
}

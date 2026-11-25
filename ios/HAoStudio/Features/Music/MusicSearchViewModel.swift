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
// report). The "searching" footer therefore settles by quiet (3 s
// after the last batch — each leg is capped at 5 s, so 10 s was far
// past complete) or at once when a batch adds no new songs after
// two batches landed (shouldSettleSearch). A new batch re-arms the
// quiet timer unless the footer already settled, in which case
// late results still stream in without resurrecting the spinner.

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
        /// Kinds the zero-growth guard closed (b49fix7 P2-6) —
        /// the grid footer reads it for the "没有更多" end state.
        var cardClosedByGuard: [MusicSearchAPI.MusicSearchCategoryKind: Bool] = [:]
        /// The limit each kind's last successful page used (10 on
        /// 综合, 50 on a single-kind tab) — retryCategory needs it
        /// to tell a real next page from a limit change (P2-34).
        var cardLimits: [MusicSearchAPI.MusicSearchCategoryKind: Int] = [:]
    }

    // Internal (not private) so XCTest can stage the restore
    // scenario — b49fix8 P2-5: a snapshot for a tab plus a stale
    // zero-growth baseline, then selectTab, then assert the
    // baseline is gone. No production code outside this file
    // touches them.
    var snapshots: [MusicSearchTab: SearchSnapshot] = [:]
    private var loadedTabs: Set<MusicSearchTab> = []
    /// Tabs the user visited while their kind was still in flight
    /// under another tab, so the first fetch never started (P1-3).
    /// A tab leaves this set only when its first fetch really
    /// starts (or it turns out to already have data / an error);
    /// the flush in beginCategoryFinish / finishCategory retries
    /// it when the blocking fetch settles. Cleared on search() /
    /// clear() with everything else.
    private var pendingTabFetch: Set<MusicSearchTab> = []

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
    /// b49fix2 P2-4: the whole songs stream failed — every leg
    /// never answered (not a genuine no-match: an answered leg
    /// with zero matches reports ok). The view shows a retry
    /// instead of "没有找到".
    @Published private(set) var songsFailed = false
    /// Deep-page cap: five extra pages (~350 more songs). Kugou /
    /// Kuwo page server-side, so this is a UI cap, not a cost cap.
    static let maxSongPages = 5

    // MARK: - Card paging + errors (b45-d)

    /// First-page size on the 综合 tab (Coda §5.3: 10 per kind).
    static let allTabCardLimit = 10
    /// Single-kind tab page size (Coda §5.3: 50 per kind).
    static let singleTabCardLimit = 50

    /// Pages loaded per kind (0 = first page not yet loaded).
    /// b49fix5 P1-2: recorded for the snapshot only — offsets no
    /// longer derive from it (a page recorded under limit 10 is
    /// not a page under limit 50; loadMoreCards / retryCategory
    /// offset from the live array count instead).
    @Published private(set) var cardPages: [MusicSearchAPI.MusicSearchCategoryKind: Int] = [:]
    @Published private(set) var cardHasMore: [MusicSearchAPI.MusicSearchCategoryKind: Bool] = [:]
    /// Kinds currently fetching (one at a time per kind).
    @Published private(set) var loadingCards: Set<MusicSearchAPI.MusicSearchCategoryKind> = []
    /// Kinds whose last fetch failed (empty results, retry offered
    /// inside that section — never a whole-page error).
    @Published private(set) var cardErrors: [MusicSearchAPI.MusicSearchCategoryKind: Bool] = [:]
    /// Kinds the zero-growth guard closed (b49fix7 P2-6): the
    /// source answered two consecutive next-page requests with
    /// the same page, so load-more is off — but that must be a
    /// VISIBLE end state ("没有更多" in the grid footer), not a
    /// silent disappearance. A fresh first page for the kind
    /// clears it (finishCategory); a new search clears all of
    /// them. Persisted in the snapshot with cardHasMore, so a
    /// tab switch does not lose the end state while keeping the
    /// closed pagination.
    @Published private(set) var cardClosedByGuard: [MusicSearchAPI.MusicSearchCategoryKind: Bool] = [:]

    // MARK: - Suggestions + hot keywords (b45-d)

    /// Suggestion / hot words for the current draft query (empty
    /// query = hot words, otherwise suggestions). Capped at 8 by
    /// the API; the view shows them as chips.
    @Published private(set) var suggestions: [String] = []
    private var suggestionTask: Task<Void, Never>?
    private var lastSuggestionText = ""

    /// Seconds of quiet after the last batch before the search is
    /// considered settled. The streaming API calls its completion
    /// once per settled leg batch and carries no "done" flag, so
    /// the footer cannot know from the API alone when the last
    /// leg has landed — but each platform leg is capped at 5 s,
    /// so 10 s of quiet was far past the point where results
    /// were complete, and the "搜索中…" footer + skeletons
    /// outlived the actual search by up to 10 s. 3 s now, plus
    /// the settled-legs rule below (shouldSettleSearch): a batch
    /// that adds nothing new once two batches have landed means
    /// the remaining legs are only returning duplicates or
    /// failures, so the footer settles at once. The search itself
    /// is untouched — late legs still append their results; only
    /// the spinner state settles early.
    static let settleQuietSeconds: TimeInterval = 3

    /// Streamed song batches seen for the current query (one per
    /// settled leg batch). Together with the merge's added count
    /// this is the settled-legs signal the API does not provide.
    private var settledBatchCount = 0
    /// The footer has settled (quiet timeout or the no-new-songs
    /// rule): later batches still append results but never
    /// resurrect the spinner.
    private var searchSettled = false

    /// Pure settle decision for one streamed batch: settle when
    /// the batch added no new songs, at least two batches have
    /// landed, and results already exist. The first batch can
    /// legitimately add nothing (a failed fastest leg), and an
    /// empty result list must keep the skeletons — so both guards
    /// matter. A true done flag would need a MusicSearchAPI
    /// change (outside this file); this is the most the view
    /// model can know from the stream.
    static func shouldSettleSearch(addedCount: Int, settledBatches: Int, hasResults: Bool) -> Bool {
        addedCount == 0 && settledBatches >= 2 && hasResults
    }

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
    /// The limit each kind's last successful page used, for the
    /// live tab (mirrors SearchSnapshot.cardLimits for restored
    /// tabs). Written in finishCategory, read by retryCategory
    /// through retryPlan (P2-34).
    private var cardLimits: [MusicSearchAPI.MusicSearchCategoryKind: Int] = [:]

    /// Zero-growth guard state (b49fix6 P2-5): the last next-page
    /// request per kind (offset + loaded count at fire time) and
    /// how many consecutive times a request fired with an
    /// identical (offset, count) — i.e. the previous request
    /// produced zero growth because the source ignores the
    /// offset and answers every page with the same rows.
    /// b49fix9 P2-2: the baseline also records the LIMIT the
    /// request fired under (综合 10 vs single-kind 50) — a
    /// (offset, count) recorded under one limit is not
    /// comparable to requests under the other, so restore()
    /// only clears a baseline whose limit differs from the
    /// restored tab's paging limit; a same-limit baseline
    /// survives a tab flip, so the guard can still close.
    /// Internal (not private) so XCTest can stage the restore
    /// scenario — b49fix8 P2-5 (see `snapshots` above).
    var lastNextPageRequest: [MusicSearchAPI.MusicSearchCategoryKind: (offset: Int, loadedCount: Int, limit: Int)] = [:]
    var zeroGrowthStreak: [MusicSearchAPI.MusicSearchCategoryKind: Int] = [:]

    /// Clear one kind's zero-growth guard state (b49fix7 P2-5).
    /// A fresh first page invalidates the old baseline: the
    /// source may now answer a new limit / new content, so the
    /// previous (offset, count) and its streak must not close a
    /// load-more that has never fired under the new page.
    private func resetZeroGrowthState(for kind: MusicSearchAPI.MusicSearchCategoryKind) {
        lastNextPageRequest[kind] = nil
        zeroGrowthStreak[kind] = nil
    }

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
    /// b49fix5 P2-11: backup-import observer (reload the search
    /// history after a restore changes it). Token pattern, same
    /// as MusicPlayerViewModel — removed in deinit (b49fix2 P1-30:
    /// a discarded token kills the observer on arrival).
    private var backupImportedObserver: NSObjectProtocol?

    init() {
        history = MusicLibraryStore.getSearchHistory()
        backupImportedObserver = NotificationCenter.default.addObserver(
            forName: .haoBackupImported, object: nil, queue: .main
        ) { [weak self] _ in
            self?.history = MusicLibraryStore.getSearchHistory()
        }
    }

    deinit {
        if let token = backupImportedObserver {
            NotificationCenter.default.removeObserver(token)
        }
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
        pendingTabFetch = []
        categoryFetchTab = [:]
        songPage = 0
        hasMoreSongs = true
        isLoadingMoreSongs = false
        songPageError = false
        songsFailed = false
        cardPages = [:]
        cardHasMore = [:]
        cardLimits = [:]
        loadingCards = []
        cardErrors = [:]
        cardClosedByGuard = [:]
        hasSearched = true
        isSearching = true
        settledBatchCount = 0
        lastNextPageRequest = [:]
        zeroGrowthStreak = [:]
        searchSettled = false
        armSettleTimer()
        MusicLibraryStore.saveSearchQuery(trimmed)
        history = MusicLibraryStore.getSearchHistory()
        MusicSearchAPI.shared.search(keyword: trimmed) { [weak self] batch, allFailed in
            guard let self = self else { return }
            // Stale leg from an older query: drop it, never mix.
            guard trimmed == self.currentQuery else { return }
            let songs = batch.map(MusicSong.init(from:))
            let added = self.merge.appendBatch(songs)
            self.results = self.merge.tracks
            // b49fix2 P2-4: mirror the stream's all-legs-failed
            // signal — a later batch with tracks clears it.
            self.songsFailed = allFailed
            self.settledBatchCount += 1
            if self.searchSettled {
                // Late leg after the footer settled: its results
                // still stream in, the spinner stays settled.
            } else if Self.shouldSettleSearch(
                addedCount: added.count,
                settledBatches: self.settledBatchCount,
                hasResults: !self.results.isEmpty
            ) {
                self.searchSettled = true
                self.isSearching = false
                self.settleTimer?.invalidate()
                self.settleTimer = nil
            } else {
                self.isSearching = true
                self.armSettleTimer()
            }
        }
        // Card kinds stream in after the songs — each kind fails
        // independently (empty + in-section retry, others unaffected).
        // Nothing is in flight right after the reset, so all three
        // issue and .all is loaded; the else is unreachable today
        // but keeps the pending rule uniform (see selectTab).
        if loadTabCategories(.all, limit: Self.allTabCardLimit) {
            loadedTabs.insert(.all)
        } else {
            pendingTabFetch.insert(.all)
        }
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
        pendingTabFetch = []
        categoryFetchTab = [:]
        songPage = 0
        hasMoreSongs = true
        isLoadingMoreSongs = false
        songPageError = false
        songsFailed = false
        cardPages = [:]
        cardHasMore = [:]
        cardLimits = [:]
        loadingCards = []
        cardErrors = [:]
        cardClosedByGuard = [:]
        suggestions = []
        lastSuggestionText = ""
        lastNextPageRequest = [:]
        zeroGrowthStreak = [:]
        suggestionTask?.cancel()
        suggestionTask = nil
        hasSearched = false
        isSearching = false
        settledBatchCount = 0
        searchSettled = false
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
            // Explicit main-actor hop: the Timer block is @Sendable
            // on some toolchains, so the mutation cannot happen
            // inside it directly (and the timer fires on the main
            // runloop anyway, so the hop is immediate).
            Task { @MainActor [weak self] in
                self?.isSearching = false
                self?.searchSettled = true
            }
        }
    }

    // MARK: - Tabs (b45-d)

    /// Switch tabs. A snapshotted tab restores without re-fetching;
    /// a never-loaded tab fetches its first page (songs need no
    /// fetch — the stream already fills them). b49fix4 P1-3: a tab
    /// is marked loaded ONLY when its first fetch really starts.
    /// The old code inserted into loadedTabs before fetching, so a
    /// tab switched to while its kind was in flight under 综合 was
    /// marked loaded with an empty array — and the empty snapshot
    /// saved on the next switch locked the fake empty state in.
    /// A blocked tab goes into pendingTabFetch instead; the flush
    /// retries it when the blocking fetch settles.
    func selectTab(_ newTab: MusicSearchTab) {
        guard newTab != tab, supportedTabs.contains(newTab) else { return }
        saveSnapshot()
        tab = newTab
        if let snapshot = snapshots[newTab] {
            restore(snapshot, for: newTab)
            return
        }
        guard !loadedTabs.contains(newTab) else { return }
        fetchFirstPage(for: newTab)
    }

    /// Issue a tab's first fetch (or queue it as pending when its
    /// kind is in flight under another tab — P1-3). Shared by
    /// selectTab and retrySongs: a tab is marked loaded ONLY when
    /// its first fetch really starts; a blocked tab goes into
    /// pendingTabFetch and the flush retries it when the blocking
    /// fetch settles.
    private func fetchFirstPage(for newTab: MusicSearchTab) {
        switch newTab {
        case .all:
            if loadTabCategories(.all, limit: Self.allTabCardLimit) {
                loadedTabs.insert(.all)
            } else {
                pendingTabFetch.insert(.all)
            }
        case .songs:
            loadedTabs.insert(.songs)
        case .artists, .albums, .playlists:
            if let kind = newTab.categoryKind {
                if loadCategory(kind, limit: Self.singleTabCardLimit, offset: 0, isFirstPage: true) {
                    loadedTabs.insert(newTab)
                } else {
                    pendingTabFetch.insert(newTab)
                }
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
        snapshot.cardClosedByGuard = cardClosedByGuard
        snapshot.cardLimits = cardLimits
        snapshots[tab] = snapshot
    }

    private func restore(_ snapshot: SearchSnapshot, for tab: MusicSearchTab) {
        // b49fix8 P2-5: a restored tab may page at a different
        // limit than the tab the streak was recorded under
        // (综合 10 vs single-kind 50), and its rows were deduped
        // under that limit too — the global per-kind (offset,
        // count) baseline from the old tab must not close a
        // load-more that has never fired under this tab.
        // b49fix9 P2-2: the clear is limit-aware, not
        // unconditional — a baseline recorded under the SAME
        // limit as the restored tab's paging survives the flip
        // (the requests are comparable, so the streak is real),
        // and only a cross-limit baseline is cleared. Clearing
        // unconditionally let a tab flip reset the streak every
        // time, so the guard could never accumulate the two
        // identical repeats it needs to close. The reset is
        // still scoped: kinds of other tabs keep their baseline,
        // so a genuine zero-growth loop on another tab still
        // closes. A failed first page still keeps its streak
        // (beginCategoryFinish returns before finishCategory):
        // the list did not change, so the old baseline is still
        // valid for it.
        let tabLimit = tab == .all ? Self.allTabCardLimit : Self.singleTabCardLimit
        let kinds: [MusicSearchAPI.MusicSearchCategoryKind] = tab == .all
            ? MusicSearchAPI.MusicSearchCategoryKind.allCases
            : (tab.categoryKind.map { [$0] } ?? [])
        for kind in kinds where lastNextPageRequest[kind]?.limit != tabLimit {
            resetZeroGrowthState(for: kind)
        }
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
        cardClosedByGuard = snapshot.cardClosedByGuard
        cardLimits = snapshot.cardLimits
    }

    /// Fetch all three card kinds for the 综合 tab (first page).
    /// Returns true iff all three kinds really started — a kind
    /// already in flight under another tab blocks its own fetch,
    /// and the caller must not mark .all loaded then (P1-3).
    /// It no longer inserts .all itself; the caller inserts only
    /// on true.
    @discardableResult
    private func loadTabCategories(_ tab: MusicSearchTab, limit: Int) -> Bool {
        guard tab == .all else { return false }
        var issued = true
        for kind in MusicSearchAPI.MusicSearchCategoryKind.allCases {
            issued = loadCategory(kind, limit: limit, offset: 0, isFirstPage: true) && issued
        }
        return issued
    }

    /// Fetch one page of one kind. First page replaces, later pages
    /// append (deduped). `hasMore` follows Coda §5.3: the page was
    /// full AND (when a total is known) the cumulative count is
    /// still below it; with no total, a full page means "more".
    /// Returns false when nothing was issued (no search yet, or the
    /// kind is already in flight) — the caller must not treat the
    /// kind as loaded then (P1-3). `owner` attributes the fetch to
    /// a tab other than the current one (the flush re-issues a
    /// pending tab's first page); nil means the current tab.
    @discardableResult
    private func loadCategory(_ kind: MusicSearchAPI.MusicSearchCategoryKind, limit: Int, offset: Int, isFirstPage: Bool, owner: MusicSearchTab? = nil) -> Bool {
        guard hasSearched, !loadingCards.contains(kind) else { return false }
        let query = currentQuery
        guard !query.isEmpty else { return false }
        let gen = generation
        categoryFetchTab[kind] = owner ?? tab
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
        return true
    }

    /// Shared guard for a category completion: stale fetch from an
    /// older query is dropped. Returns the tab that owns this fetch
    /// (the tab it was started from), or nil to stop. A failed kind
    /// contributes empty and records its error — on the live state
    /// when the owner is on screen, in the owner's snapshot when
    /// the user has since switched away (so switching back still
    /// offers the retry instead of a false empty state). On a
    /// failure the pending-tab flush runs here (no data lands, so
    /// it is safe to run before the write); on success it runs at
    /// the end of finishCategory, after the data lands (P1-3).
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
            flushPendingTabFetches()
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
        // b49fix7 P2-5: a fresh first page invalidates the old
        // zero-growth baseline — clear this kind's last request
        // and streak. The streak is per-kind GLOBAL state (not
        // per tab), so one reset covers both owner paths: a
        // stale streak from the 综合 tab must not close the
        // single tab's load-more, and vice versa.
        if isFirstPage { resetZeroGrowthState(for: kind) }
        if owner == tab {
            cardLimits[kind] = limit
            if isFirstPage {
                artistMerge.reset()
                cardPages[kind] = 0
                // b49fix7 P2-6: a fresh first page re-opens a
                // kind the guard had closed.
                cardClosedByGuard[kind] = false
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
            if isFirstPage {
                merge.reset()
                snap.cardClosedByGuard[kind] = false
            }
            _ = merge.append(items)
            snap.artistMerge = merge
            snap.artists = merge.items
            snap.cardPages[kind] = isFirstPage ? 0 : offset / max(limit, 1)
            snap.cardHasMore[kind] = items.count == limit && (total.map { merge.count < $0 } ?? true)
            snap.cardErrors[kind] = false
            snap.cardLimits[kind] = limit
            snapshots[owner] = snap
        }
        flushPendingTabFetches()
    }

    private func finishCategory(_ kind: MusicSearchAPI.MusicSearchCategoryKind, items: [AlbumSummary], total: Int?, ok: Bool, limit: Int, offset: Int, isFirstPage: Bool, gen: UUID) {
        guard let owner = beginCategoryFinish(kind, ok: ok, gen: gen) else { return }
        // b49fix7 P2-5: a fresh first page invalidates the old
        // zero-growth baseline — clear this kind's last request
        // and streak (per-kind global state; covers both owner
        // paths).
        if isFirstPage { resetZeroGrowthState(for: kind) }
        if owner == tab {
            cardLimits[kind] = limit
            if isFirstPage {
                albumMerge.reset()
                cardPages[kind] = 0
                // b49fix7 P2-6: a fresh first page re-opens a
                // kind the guard had closed.
                cardClosedByGuard[kind] = false
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
            if isFirstPage {
                merge.reset()
                snap.cardClosedByGuard[kind] = false
            }
            _ = merge.append(items)
            snap.albumMerge = merge
            snap.albums = merge.items
            snap.cardPages[kind] = isFirstPage ? 0 : offset / max(limit, 1)
            snap.cardHasMore[kind] = items.count == limit && (total.map { merge.count < $0 } ?? true)
            snap.cardErrors[kind] = false
            snap.cardLimits[kind] = limit
            snapshots[owner] = snap
        }
        flushPendingTabFetches()
    }

    private func finishCategory(_ kind: MusicSearchAPI.MusicSearchCategoryKind, items: [PlaylistSummary], total: Int?, ok: Bool, limit: Int, offset: Int, isFirstPage: Bool, gen: UUID) {
        guard let owner = beginCategoryFinish(kind, ok: ok, gen: gen) else { return }
        // b49fix7 P2-5: a fresh first page invalidates the old
        // zero-growth baseline — clear this kind's last request
        // and streak (per-kind global state; covers both owner
        // paths).
        if isFirstPage { resetZeroGrowthState(for: kind) }
        if owner == tab {
            cardLimits[kind] = limit
            if isFirstPage {
                playlistMerge.reset()
                cardPages[kind] = 0
                // b49fix7 P2-6: a fresh first page re-opens a
                // kind the guard had closed.
                cardClosedByGuard[kind] = false
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
            if isFirstPage {
                merge.reset()
                snap.cardClosedByGuard[kind] = false
            }
            _ = merge.append(items)
            snap.playlistMerge = merge
            snap.playlists = merge.items
            snap.cardPages[kind] = isFirstPage ? 0 : offset / max(limit, 1)
            snap.cardHasMore[kind] = items.count == limit && (total.map { merge.count < $0 } ?? true)
            snap.cardErrors[kind] = false
            snap.cardLimits[kind] = limit
            snapshots[owner] = snap
        }
        flushPendingTabFetches()
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
    /// b49fix5 P1-2: the offset comes from the LIVE array count,
    /// never from cardPages × limit — the recorded page was
    /// written under the OLD tab's limit (综合 10 vs single-kind
    /// 50), so a limit change made the next fetch skip a whole
    /// range (20 loaded, page 1 under limit 10, then limit 50
    /// asked for offset 100 and items 20–99 were never requested
    /// again, hasMore going false on a short page). The count is
    /// the truth the merge already holds; a duplicate overlap
    /// (dedupe dropped some rows) can only re-request a few rows,
    /// which the merge dedupes.
    func loadMoreCards(_ kind: MusicSearchAPI.MusicSearchCategoryKind) {
        guard hasSearched, !loadingCards.contains(kind) else { return }
        guard tab == .all || tab.categoryKind == kind else { return }
        guard cardHasMore[kind] == true else { return }
        // Single-kind tabs page at 50; the 综合 shelves page at 10.
        let limit = tab == .all ? Self.allTabCardLimit : Self.singleTabCardLimit
        let loadedCount = liveCardCount(for: kind)
        let offset = Self.nextCardOffset(loadedCount: loadedCount)
        // b49fix6 P2-5: a source that ignores the offset answers
        // every load-more with the same page; the merge dedupes,
        // the live count never grows, and cardHasMore stays true
        // forever. Two consecutive identical (offset, count)
        // requests close the kind instead of looping — the button
        // disappears rather than re-requesting the same page.
        let last = lastNextPageRequest[kind]
        let decision = Self.loadMoreStreakDecision(
            lastOffset: last?.offset, lastLoadedCount: last?.loadedCount,
            streak: zeroGrowthStreak[kind] ?? 0,
            offset: offset, loadedCount: loadedCount)
        zeroGrowthStreak[kind] = decision.streak
        guard decision.fire else {
            cardHasMore[kind] = false
            // b49fix7 P2-6: the guard closing a kind must be a
            // VISIBLE end state, not a silent disappearance — the
            // grid footer reads cardClosedByGuard and shows
            // "没有更多". A fresh first page (or a new search)
            // re-opens the kind. Persisted with the snapshot, so
            // a tab switch keeps the end state with the closed
            // pagination. b49fix8 P2-6: the end state is also a
            // way back in — tapping it calls reopenClosedKind,
            // so a wrongly closed kind is not a dead end for the
            // whole search session.
            cardClosedByGuard[kind] = true
            saveSnapshot()
            return
        }
        lastNextPageRequest[kind] = (offset: offset, loadedCount: loadedCount, limit: limit)
        loadCategory(kind, limit: limit, offset: offset, isFirstPage: false)
    }

    /// Live row count for one kind on the current tab — the source
    /// loadMoreCards / retryCategory offset from. The live arrays
    /// belong to the current tab (the guard in both callers
    /// guarantees tab == .all or tab.categoryKind == kind).
    private func liveCardCount(for kind: MusicSearchAPI.MusicSearchCategoryKind) -> Int {
        switch kind {
        case .artists: return artists.count
        case .albums: return albums.count
        case .playlists: return playlists.count
        }
    }

    /// Pure next-page offset (b49fix5 P1-2, unit-tested): the next
    /// page starts where the loaded rows end. Nonisolated (pure)
    /// so XCTest can call it without the main actor.
    nonisolated static func nextCardOffset(loadedCount: Int) -> Int {
        max(loadedCount, 0)
    }

    /// Pure zero-growth decision (b49fix6 P2-5, unit-tested): a
    /// source that ignores the offset answers every load-more
    /// with the same page; the merge dedupes, the live count
    /// never grows, and cardHasMore stays true forever. Two
    /// consecutive requests that fire the identical offset with
    /// the identical loaded count mean the previous request
    /// produced zero growth — the first repeat still fires (one
    /// transient dup is forgiven), the second closes the kind
    /// instead of looping. Any change in offset or count (growth
    /// happened) resets the streak. Nonisolated (pure) so XCTest
    /// can call it without the main actor.
    nonisolated static func loadMoreStreakDecision(
        lastOffset: Int?, lastLoadedCount: Int?, streak: Int,
        offset: Int, loadedCount: Int
    ) -> (fire: Bool, streak: Int) {
        if lastOffset == offset && lastLoadedCount == loadedCount {
            let next = streak + 1
            return (next < 2, next)
        }
        return (true, 0)
    }

    /// Re-open a kind the zero-growth guard closed (b49fix8
    /// P2-6): the footer "没有更多" was a dead end without it —
    /// the only other exits were a new search or a fresh first
    /// page landing on its own. Tapping re-issues a FIRST page
    /// under the current tab's limit, not a next page: the guard
    /// closed because the source kept answering the same
    /// next-page window, and a fresh first page is the recovery
    /// that re-opens the kind. b49fix9 P2-5: the first page is
    /// offset 0 with the current tab's limit — rows 0–9 on 综合,
    /// 0–49 on a single-kind tab — so it OVERLAPS rows already
    /// held (the merge dedupes them); the old comment's "rows
    /// 20–49, never fetched" was wrong. The first-page finish
    /// clears the guard state and re-opens the kind
    /// (finishCategory isFirstPage); if the source really has no
    /// more, the short page ends pagination honestly instead of
    /// re-closing through the guard. Retries are never blocked
    /// by the guard — an explicit retry is the recovery path.
    /// No XCTest yet: the search side has no stub seam (the
    /// video side has StubVideoGateway); XCTest waits on search
    /// stub infrastructure (b49fix9 P2-5).
    func reopenClosedKind(_ kind: MusicSearchAPI.MusicSearchCategoryKind) {
        guard hasSearched, !loadingCards.contains(kind) else { return }
        cardClosedByGuard[kind] = false
        resetZeroGrowthState(for: kind)
        let limit = tab == .all ? Self.allTabCardLimit : Self.singleTabCardLimit
        loadCategory(kind, limit: limit, offset: 0, isFirstPage: true)
    }

    /// Retry one failed kind from inside its own section.
    /// The offset comes from retryPlan (P2-34): a retry after a
    /// 综合 first fetch (limit 10) that lands on a single-kind tab
    /// (limit 50) is a fresh first page at offset 0 — the recorded
    /// page (0 under limit 10) is not a page under limit 50.
    func retryCategory(_ kind: MusicSearchAPI.MusicSearchCategoryKind) {
        guard hasSearched, !loadingCards.contains(kind) else { return }
        let limit = tab == .all ? Self.allTabCardLimit : Self.singleTabCardLimit
        let isEmpty: Bool = {
            switch kind {
            case .artists: return artists.isEmpty
            case .albums: return albums.isEmpty
            case .playlists: return playlists.isEmpty
            }
        }()
        let plan = Self.retryPlan(
            loadedCount: liveCardCount(for: kind), cardLimits: cardLimits[kind],
            limit: limit, isEmpty: isEmpty)
        if !plan.isFirstPage {
            // A next-page retry is a next-page request too: record
            // it so the zero-growth guard (b49fix6 P2-5) can see
            // whether it grew the list. Retries are never blocked
            // — an explicit retry is the recovery path. The limit
            // rides along (b49fix9 P2-2) so restore() can tell a
            // same-limit baseline from a cross-limit one.
            lastNextPageRequest[kind] = (offset: plan.offset, loadedCount: liveCardCount(for: kind), limit: limit)
        }
        loadCategory(kind, limit: limit, offset: plan.offset, isFirstPage: plan.isFirstPage)
    }

    /// Pure retry plan for one kind (P2-34, unit-tested): a retry
    /// is a fresh first page at offset 0 when nothing is loaded
    /// yet, when no page was ever recorded at any limit, or when
    /// the last successful page used a DIFFERENT limit than the
    /// current tab (a 综合 page-0 under limit 10 is not a page
    /// under limit 50 — retrying it as a next page would append
    /// 50 items starting at 0, the first 10 duplicated). Only
    /// when the last page used the SAME limit and something is
    /// loaded does the retry re-request the failed next page —
    /// retrying that as a first page would clobber the pages
    /// already loaded.
    /// b49fix5 P1-2: the same-limit branch is count-based too —
    /// it re-requests from the live row count, not from
    /// (cardPages + 1) × limit. The old form had the same
    /// cross-limit hole as loadMoreCards: 70 rows loaded, then a
    /// retry under a new limit asked for offset 100 and rows
    /// 70–99 were skipped for good (the merge only self-heals
    /// overlaps, never gaps). Nonisolated (pure) so XCTest can
    /// call it without the main actor.
    nonisolated static func retryPlan(loadedCount: Int, cardLimits: Int?, limit: Int, isEmpty: Bool) -> (offset: Int, isFirstPage: Bool) {
        if isEmpty || cardLimits == nil || cardLimits != limit {
            return (0, true)
        }
        return (max(loadedCount, 0), false)
    }

    /// Kinds a pending tab still lacks: no items, no error, and
    /// not currently in flight. For the current tab the live
    /// arrays are the source; for any other tab its snapshot is
    /// (its live arrays belong to whichever tab is on screen).
    /// An errored kind is NOT missing — its retry button owns it.
    private func missingKinds(for pending: MusicSearchTab) -> [MusicSearchAPI.MusicSearchCategoryKind] {
        let snap = snapshots[pending]
        let kinds: [MusicSearchAPI.MusicSearchCategoryKind] = pending == .all
            ? MusicSearchAPI.MusicSearchCategoryKind.allCases
            : (pending.categoryKind.map { [$0] } ?? [])
        return kinds.filter { kind in
            guard !loadingCards.contains(kind) else { return false }
            let hasItems: Bool
            let hasError: Bool
            if pending == tab {
                switch kind {
                case .artists: hasItems = !artists.isEmpty
                case .albums: hasItems = !albums.isEmpty
                case .playlists: hasItems = !playlists.isEmpty
                }
                hasError = cardErrors[kind] == true
            } else {
                switch kind {
                case .artists: hasItems = !(snap?.artists.isEmpty ?? true)
                case .albums: hasItems = !(snap?.albums.isEmpty ?? true)
                case .playlists: hasItems = !(snap?.playlists.isEmpty ?? true)
                }
                hasError = snap?.cardErrors[kind] == true
            }
            return !hasItems && !hasError
        }
    }

    /// Retry the first fetch for tabs that visited while their
    /// kind was in flight (P1-3). Runs after every category
    /// completion (see beginCategoryFinish / finishCategory), so
    /// a tab switched to mid-fetch fills in once the blocking
    /// fetch settles instead of sitting on a fake empty state. A
    /// tab leaves pending only when nothing is missing any more —
    /// issuing one kind while another is still in flight must NOT
    /// mark the tab loaded, or the in-flight kind would never be
    /// retried for it. Pending 综合 only retries when no kind is
    /// in flight (its three kinds share one first page — a
    /// partial re-issue while others are still landing could
    /// reset the kinds that already landed).
    private func flushPendingTabFetches() {
        guard hasSearched else { return }
        for pending in Array(pendingTabFetch) {
            if pending == .all && !loadingCards.isEmpty { continue }
            let missing = missingKinds(for: pending)
            guard !missing.isEmpty else {
                pendingTabFetch.remove(pending)
                loadedTabs.insert(pending)
                continue
            }
            let limit = pending == .all ? Self.allTabCardLimit : Self.singleTabCardLimit
            var allIssued = true
            for kind in missing {
                if !loadCategory(kind, limit: limit, offset: 0, isFirstPage: true, owner: pending) {
                    allIssued = false
                }
            }
            if allIssued {
                pendingTabFetch.remove(pending)
                loadedTabs.insert(pending)
            }
        }
    }

    /// Re-run the current query from scratch — the songs-stream
    /// retry (b49fix2 P2-4). b49fix3 P2-11: search() resets the tab
    /// to .all, so a retry tapped on the 歌曲 tab used to jump the
    /// user back to 综合. The retry re-runs the same query, so the
    /// tab is restored right after the reset.
    func retrySongs() {
        guard !currentQuery.isEmpty else { return }
        let currentTab = tab
        search(currentQuery)
        tab = currentTab
        // b49fix4 P1-3: search() reset the tab state to .all, so
        // the restored tab has no fetch of its own — without this
        // it would sit on the .all fetch's 10 items (or a fake
        // empty) until the user tapped load-more. Issue its first
        // page now (or queue it pending — the .all fetch is in
        // flight, so it usually waits for the flush).
        if currentTab != .all {
            fetchFirstPage(for: currentTab)
        }
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

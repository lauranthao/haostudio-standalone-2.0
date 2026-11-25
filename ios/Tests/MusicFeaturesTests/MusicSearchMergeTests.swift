// HAo Studio 2.0 — streaming search merge tests (S2-C leg).
//
// Dedupe by platform + songId (empty id falls back to title+artist),
// NetEase + QQ first, stable order within a platform.

import XCTest

@testable import HAoStudio

final class MusicSearchMergeTests: XCTestCase {
    private func song(_ id: String, platform: MusicPlatform, title: String = "Song") -> MusicSong {
        return MusicSong(songId: id, title: title, artist: "Artist", platform: platform, dur: 200)
    }

    func testDedupeSamePlatformAndId() {
        var merge = MusicSearchMerge()
        let added = merge.appendBatch([song("1", platform: .wy), song("1", platform: .wy)])
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(merge.count, 1)
    }

    func testSameIdDifferentPlatformKept() {
        var merge = MusicSearchMerge()
        merge.appendBatch([song("1", platform: .wy), song("1", platform: .tx)])
        XCTAssertEqual(merge.count, 2)
    }

    func testEmptyIdFallsBackToTitleArtist() {
        var merge = MusicSearchMerge()
        let first = MusicSong(songId: "", title: "Same", artist: "A", platform: .wy)
        let dup = MusicSong(songId: "", title: "Same", artist: "A", platform: .wy)
        let other = MusicSong(songId: "", title: "Different", artist: "A", platform: .wy)
        merge.appendBatch([first, dup, other])
        XCTAssertEqual(merge.count, 2)
    }

    func testNetEaseAndQQFirst() {
        var merge = MusicSearchMerge()
        merge.appendBatch([
            song("kw1", platform: .kw, title: "Kw"),
            song("wy1", platform: .wy, title: "Wy"),
            song("tx1", platform: .tx, title: "Tx"),
            song("kg1", platform: .kg, title: "Kg"),
        ])
        XCTAssertEqual(merge.tracks.map { $0.platform }, [.wy, .tx, .kg, .kw])
    }

    func testLaterLegNeverReordersEarlierLeg() {
        var merge = MusicSearchMerge()
        merge.appendBatch([song("wy1", platform: .wy, title: "Wy1"), song("wy2", platform: .wy, title: "Wy2")])
        // A slower QQ leg arrives afterwards: its rows go after the
        // NetEase rows, but before any Kugou/Kuwo rows.
        merge.appendBatch([song("tx1", platform: .tx, title: "Tx1")])
        merge.appendBatch([song("kg1", platform: .kg, title: "Kg1")])
        XCTAssertEqual(merge.tracks.map { $0.title }, ["Wy1", "Wy2", "Tx1", "Kg1"])
    }

    func testStableWithinPlatform() {
        var merge = MusicSearchMerge()
        merge.appendBatch([
            song("a", platform: .wy, title: "A"),
            song("b", platform: .wy, title: "B"),
            song("c", platform: .wy, title: "C"),
        ])
        XCTAssertEqual(merge.tracks.map { $0.title }, ["A", "B", "C"])
    }

    func testDedupeAcrossBatchesKeepsFirstArrival() {
        var merge = MusicSearchMerge()
        merge.appendBatch([song("1", platform: .wy, title: "First")])
        let added = merge.appendBatch([song("1", platform: .wy, title: "Second")])
        XCTAssertEqual(added.count, 0)
        XCTAssertEqual(merge.tracks.first?.title, "First")
    }

    func testResetClears() {
        var merge = MusicSearchMerge()
        merge.appendBatch([song("1", platform: .wy)])
        merge.reset()
        XCTAssertTrue(merge.isEmpty)
        XCTAssertEqual(merge.count, 0)
        // After reset the same song can arrive again.
        merge.appendBatch([song("1", platform: .wy)])
        XCTAssertEqual(merge.count, 1)
    }

    func testDedupeKeyFoldsLiveVariants() {
        // "(Live)" variants of the same title+artist are one result.
        let live = musicSearchDedupeKey(title: "Song (Live)", artist: "A")
        let plain = musicSearchDedupeKey(title: "Song", artist: "A")
        XCTAssertEqual(live, plain)
    }
}

// MARK: - Card paging offsets (b49fix5 P1-2, b49fix6 P2-5)
//
// The offset of every next-page request comes from the live row
// count (MusicSearchViewModel.nextCardOffset), never from
// (cardPages + 1) × limit — the page count is recorded under the
// OLD tab's limit, so a limit change made the next fetch skip a
// whole range. A source that ignores the offset answers every
// page with the same rows; two consecutive identical
// (offset, count) requests close the kind instead of looping
// (loadMoreStreakDecision).

final class MusicSearchOffsetTests: XCTestCase {
    func testNextCardOffsetCrossLimit() {
        // b49fix5 P1-2 repro: the 综合 page (limit 10) paged once,
        // 20 rows loaded, then the user switched to a single-kind
        // tab (limit 50) and tapped load more. The offset must be
        // 20 — the old page-based form asked for offset 100 and
        // items 20–99 were never requested again.
        XCTAssertEqual(MusicSearchViewModel.nextCardOffset(loadedCount: 20), 20)
    }

    func testNextCardOffsetZeroAndNegative() {
        XCTAssertEqual(MusicSearchViewModel.nextCardOffset(loadedCount: 0), 0)
        XCTAssertEqual(MusicSearchViewModel.nextCardOffset(loadedCount: -3), 0)
    }

    func testRetryPlanCrossLimitIsFirstPage() {
        // A retry after a 综合 first fetch (limit 10) that lands
        // on a single-kind tab (limit 50) is a fresh first page
        // at offset 0 — the recorded page is not a page under
        // limit 50.
        let plan = MusicSearchViewModel.retryPlan(
            loadedCount: 20, cardLimits: 10, limit: 50, isEmpty: false)
        XCTAssertEqual(plan.offset, 0)
        XCTAssertTrue(plan.isFirstPage)
    }

    func testRetryPlanSameLimitResumesFromCount() {
        // Same limit, rows already loaded: re-request the failed
        // next page from the live row count, not from a page
        // number (70 loaded, then a retry under the same limit
        // asked for offset 100 under the old form).
        let plan = MusicSearchViewModel.retryPlan(
            loadedCount: 70, cardLimits: 50, limit: 50, isEmpty: false)
        XCTAssertEqual(plan.offset, 70)
        XCTAssertFalse(plan.isFirstPage)
    }

    func testRetryPlanEmptyIsFirstPage() {
        let plan = MusicSearchViewModel.retryPlan(
            loadedCount: 0, cardLimits: 50, limit: 50, isEmpty: true)
        XCTAssertEqual(plan.offset, 0)
        XCTAssertTrue(plan.isFirstPage)
    }

    func testStreakFirstRepeatStillFires() {
        // The first identical request is forgiven (one transient
        // dup): it fires, streak becomes 1.
        let decision = MusicSearchViewModel.loadMoreStreakDecision(
            lastOffset: 20, lastLoadedCount: 20, streak: 0,
            offset: 20, loadedCount: 20)
        XCTAssertTrue(decision.fire)
        XCTAssertEqual(decision.streak, 1)
    }

    func testStreakSecondRepeatStops() {
        // The second identical request closes the kind: no fire,
        // streak 2 — the caller sets cardHasMore = false.
        let decision = MusicSearchViewModel.loadMoreStreakDecision(
            lastOffset: 20, lastLoadedCount: 20, streak: 1,
            offset: 20, loadedCount: 20)
        XCTAssertFalse(decision.fire)
        XCTAssertEqual(decision.streak, 2)
    }

    func testStreakResetsOnGrowth() {
        // The count grew (or the offset moved): the source is
        // honouring the offset, streak resets, fire.
        let decision = MusicSearchViewModel.loadMoreStreakDecision(
            lastOffset: 20, lastLoadedCount: 20, streak: 1,
            offset: 30, loadedCount: 30)
        XCTAssertTrue(decision.fire)
        XCTAssertEqual(decision.streak, 0)
    }

    func testStreakNoRecordFires() {
        let decision = MusicSearchViewModel.loadMoreStreakDecision(
            lastOffset: nil, lastLoadedCount: nil, streak: 0,
            offset: 20, loadedCount: 20)
        XCTAssertTrue(decision.fire)
        XCTAssertEqual(decision.streak, 0)
    }

    func testStreakResetByFirstPageLetsLoadMoreFire() {
        // b49fix7 P2-5 repro: the 综合 tab's load-more fired an
        // identical (20, 20) request once (streak 1) — then the
        // user switched to the single-kind tab, whose first page
        // landed and reset the kind's guard state (finishCategory
        // clears lastNextPageRequest / zeroGrowthStreak on
        // isFirstPage). Deduping the new page down to 20 rows,
        // the next load-more is again (20, 20) — but the baseline
        // is gone, so it must FIRE (streak 0), not close the
        // kind. Before the fix the stale streak made the
        // identical request close the kind without any fetch.
        let decision = MusicSearchViewModel.loadMoreStreakDecision(
            lastOffset: nil, lastLoadedCount: nil, streak: 0,
            offset: 20, loadedCount: 20)
        XCTAssertTrue(decision.fire)
        XCTAssertEqual(decision.streak, 0)
        // And the stale state, had it survived, WOULD have closed
        // it — the guard against a regression in the reset itself.
        let stale = MusicSearchViewModel.loadMoreStreakDecision(
            lastOffset: 20, lastLoadedCount: 20, streak: 1,
            offset: 20, loadedCount: 20)
        XCTAssertFalse(stale.fire)
        XCTAssertEqual(stale.streak, 2)
    }
}

/// Snapshot-restore zero-growth tests (b49fix8 P2-5). These drive
/// the REAL view model (no network: selectTab only restores a
/// staged snapshot, and the assertions read synchronous state).
@MainActor
final class MusicSearchRestoreTests: XCTestCase {
    func testRestoreClearsZeroGrowthStateForRestoredTabKinds() {
        // b49fix8 P2-5 repro (same numbers as the ninth-round
        // P2-5 scenario): the 综合 tab's load-more fired twice
        // with zero growth — the first records (20, 20), the
        // second is the forgiven identical repeat (streak 1) —
        // then the user switches to the artists single tab, whose
        // snapshot restores 20 rows. The restore must clear the
        // kind's baseline: the next load-more under the new limit
        // 50 has never fired, so it must FIRE instead of closing
        // on the stale (20, 20) baseline. Before the fix the
        // restore never touched the global per-kind state, so the
        // identical request closed the kind without ever trying
        // the limit-50 second page.
        let vm = MusicSearchViewModel()
        // b49fix9 P2-2: the baseline was recorded under the
        // 综合 limit 10, so restoring the artists tab (limit
        // 50) clears it — cross-limit baselines are not
        // comparable. The limit rides in the tuple now.
        vm.lastNextPageRequest[.artists] = (offset: 20, loadedCount: 20, limit: 10)
        vm.zeroGrowthStreak[.artists] = 1
        // A kind from another tab keeps its baseline — the reset
        // is scoped to the restored tab's kinds.
        vm.lastNextPageRequest[.albums] = (offset: 20, loadedCount: 20, limit: 10)
        vm.zeroGrowthStreak[.albums] = 1
        var snapshot = MusicSearchViewModel.SearchSnapshot()
        snapshot.cardHasMore[.artists] = true
        vm.snapshots[.artists] = snapshot
        vm.selectTab(.artists)
        XCTAssertNil(vm.lastNextPageRequest[.artists])
        XCTAssertNil(vm.zeroGrowthStreak[.artists])
        XCTAssertEqual(vm.lastNextPageRequest[.albums]?.offset, 20)
        XCTAssertEqual(vm.lastNextPageRequest[.albums]?.limit, 10)
        XCTAssertEqual(vm.zeroGrowthStreak[.albums], 1)
        // With the baseline gone, the next (20, 20) load-more
        // under the new limit fires (streak 0) — the pure
        // decision on the post-restore state.
        let decision = MusicSearchViewModel.loadMoreStreakDecision(
            lastOffset: vm.lastNextPageRequest[.artists]?.offset,
            lastLoadedCount: vm.lastNextPageRequest[.artists]?.loadedCount,
            streak: vm.zeroGrowthStreak[.artists] ?? 0,
            offset: 20, loadedCount: 20)
        XCTAssertTrue(decision.fire)
        XCTAssertEqual(decision.streak, 0)
        // And the stale state, had it survived, WOULD have closed
        // it — the guard against a regression in the reset itself.
        let stale = MusicSearchViewModel.loadMoreStreakDecision(
            lastOffset: 20, lastLoadedCount: 20, streak: 1,
            offset: 20, loadedCount: 20)
        XCTAssertFalse(stale.fire)
        XCTAssertEqual(stale.streak, 2)
    }

    func testRestoreAllTabClearsAllKinds() {
        // Restoring 综合 clears all three kinds: streaks recorded
        // under the single tabs' limit 50 do not apply to the
        // 综合 limit-10 paging either.
        let vm = MusicSearchViewModel()
        vm.lastNextPageRequest[.artists] = (offset: 50, loadedCount: 50, limit: 50)
        vm.zeroGrowthStreak[.artists] = 1
        vm.lastNextPageRequest[.playlists] = (offset: 50, loadedCount: 50, limit: 50)
        vm.zeroGrowthStreak[.playlists] = 2
        var snapshot = MusicSearchViewModel.SearchSnapshot()
        snapshot.cardHasMore[.artists] = true
        vm.snapshots[.all] = snapshot
        // tab starts at .all, so switch away and back to restore.
        // .songs needs no fetch (the stream already fills it).
        vm.selectTab(.songs)
        vm.selectTab(.all)
        XCTAssertNil(vm.lastNextPageRequest[.artists])
        XCTAssertNil(vm.zeroGrowthStreak[.artists])
        XCTAssertNil(vm.lastNextPageRequest[.playlists])
        XCTAssertNil(vm.zeroGrowthStreak[.playlists])
    }

    func testRestoreKeepsBaselineWhenLimitMatches() {
        // b49fix9 P2-2: a baseline recorded under the SAME
        // limit as the restored tab's paging survives the
        // flip — the requests are comparable, so the streak
        // is real and the guard can still close. Before the
        // fix the restore cleared unconditionally, so flipping
        // tabs reset the streak every time and the guard never
        // accumulated the two identical repeats it needs.
        let vm = MusicSearchViewModel()
        vm.lastNextPageRequest[.artists] = (offset: 50, loadedCount: 50, limit: 50)
        vm.zeroGrowthStreak[.artists] = 1
        var snapshot = MusicSearchViewModel.SearchSnapshot()
        snapshot.cardHasMore[.artists] = true
        vm.snapshots[.artists] = snapshot
        vm.selectTab(.artists)
        XCTAssertEqual(vm.lastNextPageRequest[.artists]?.offset, 50)
        XCTAssertEqual(vm.lastNextPageRequest[.artists]?.loadedCount, 50)
        XCTAssertEqual(vm.lastNextPageRequest[.artists]?.limit, 50)
        XCTAssertEqual(vm.zeroGrowthStreak[.artists], 1)
        // The kept baseline still closes the kind: the next
        // identical (50, 50) request is the second repeat.
        let decision = MusicSearchViewModel.loadMoreStreakDecision(
            lastOffset: vm.lastNextPageRequest[.artists]?.offset,
            lastLoadedCount: vm.lastNextPageRequest[.artists]?.loadedCount,
            streak: vm.zeroGrowthStreak[.artists] ?? 0,
            offset: 50, loadedCount: 50)
        XCTAssertFalse(decision.fire)
        XCTAssertEqual(decision.streak, 2)
    }

    func testFlipThroughSongsKeepsAllTabBaseline() {
        // b49fix9 P2-2: the sweep's flip scenario — the 综合
        // baseline (limit 10, streak 1) survives a round trip
        // through a tab that pages no cards (.songs restores
        // nothing for the card kinds), so the next identical
        // (20, 20) load-more on 综合 still closes the kind.
        let vm = MusicSearchViewModel()
        vm.lastNextPageRequest[.artists] = (offset: 20, loadedCount: 20, limit: 10)
        vm.zeroGrowthStreak[.artists] = 1
        var snapshot = MusicSearchViewModel.SearchSnapshot()
        snapshot.cardHasMore[.artists] = true
        vm.snapshots[.all] = snapshot
        vm.selectTab(.songs)
        vm.selectTab(.all)
        XCTAssertEqual(vm.lastNextPageRequest[.artists]?.offset, 20)
        XCTAssertEqual(vm.lastNextPageRequest[.artists]?.loadedCount, 20)
        XCTAssertEqual(vm.lastNextPageRequest[.artists]?.limit, 10)
        XCTAssertEqual(vm.zeroGrowthStreak[.artists], 1)
        let decision = MusicSearchViewModel.loadMoreStreakDecision(
            lastOffset: vm.lastNextPageRequest[.artists]?.offset,
            lastLoadedCount: vm.lastNextPageRequest[.artists]?.loadedCount,
            streak: vm.zeroGrowthStreak[.artists] ?? 0,
            offset: 20, loadedCount: 20)
        XCTAssertFalse(decision.fire)
        XCTAssertEqual(decision.streak, 2)
    }

    func testStreamBatchGenerationGuard() {
        // b49fix10 P2-1: a resend of the SAME query bumps the
        // generation while the string stays identical, so the
        // string check alone cannot tell the old round's batches
        // from the new round's. The old batches must be dropped
        // (they inflated settledBatchCount with all-duplicate
        // batches and could flip songsFailed on), and only a
        // batch matching BOTH the query and the generation is
        // accepted.
        let gen = UUID()
        let otherGen = UUID()
        XCTAssertTrue(MusicSearchViewModel.shouldAcceptStreamBatch(
            query: "周杰伦", currentQuery: "周杰伦", gen: gen, generation: gen))
        XCTAssertFalse(MusicSearchViewModel.shouldAcceptStreamBatch(
            query: "周杰伦", currentQuery: "周杰伦", gen: otherGen, generation: gen))
        XCTAssertFalse(MusicSearchViewModel.shouldAcceptStreamBatch(
            query: "周杰伦", currentQuery: "林俊杰", gen: gen, generation: gen))
        XCTAssertFalse(MusicSearchViewModel.shouldAcceptStreamBatch(
            query: "周杰伦", currentQuery: "林俊杰", gen: otherGen, generation: gen))
    }

    func testCardErrorKeepsAllTabNonEmpty() {
        // b49fix10 P2-2: a failed card kind is not an empty page
        // — hasCardError is true when any kind failed, so the
        // view renders the sections (with the failed shelf's
        // error row + retry) instead of the whole-page "没有找到
        // 相关结果". Staged through a snapshot restore, the same
        // path the tab switch takes (saveSnapshot would wipe a
        // staged .all snapshot, so the .artists tab carries it).
        let vm = MusicSearchViewModel()
        var snapshot = MusicSearchViewModel.SearchSnapshot()
        snapshot.cardErrors[.artists] = true
        vm.snapshots[.artists] = snapshot
        vm.selectTab(.artists)
        XCTAssertTrue(vm.hasCardError)
        // And a clean restore clears it again.
        var clean = MusicSearchViewModel.SearchSnapshot()
        clean.cardErrors = [:]
        vm.snapshots[.albums] = clean
        vm.selectTab(.albums)
        XCTAssertFalse(vm.hasCardError)
    }
}

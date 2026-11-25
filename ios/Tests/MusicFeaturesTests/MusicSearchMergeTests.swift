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

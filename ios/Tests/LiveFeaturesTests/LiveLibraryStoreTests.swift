// HAo Studio 2.0 — live library store tests (S4-C leg).
//
// Pure rules only (no file I/O, no network): resume key, follow
// merge/dedupe, history merge/dedupe/cap, day sections, search
// history merge. The store's disk methods go through LocalStore
// and are covered by the S1 migration tests' approach (real
// Documents dir), not here.
//
// Wiring (merge, per the build #18 lesson — one file, one
// target): this target imports AppCore; B leg adds this single
// file Features/Live/LiveLibraryStore.swift (Foundation only —
// no SwiftUI, no UIKit) to the AppCore sources, and a
// LiveFeaturesTests test target depending on it. Do NOT add
// LiveLibraryStore.swift to a second target.

import XCTest

@testable import AppCore

final class LiveLibraryStoreTests: XCTestCase {
    private func follow(
        platform: String = "bilibili",
        roomId: String = "1",
        followedAt: Date = Date()
    ) -> LiveFollowedRoom {
        LiveFollowedRoom(
            platform: platform, roomId: roomId, title: "标题",
            nick: "主播", cover: "", followedAt: followedAt)
    }

    private func entry(
        platform: String = "bilibili",
        roomId: String = "1",
        watchedAt: Date = Date(),
        playUrlsJSON: String? = nil
    ) -> LiveHistoryEntry {
        LiveHistoryEntry(
            platform: platform, roomId: roomId, title: "标题",
            nick: "主播", cover: "", watchedAt: watchedAt,
            playUrlsJSON: playUrlsJSON)
    }

    // MARK: - Resume key (Flutter identityKey)

    func testResumeKeyJoinsPlatformAndRoomId() {
        XCTAssertEqual(
            LiveResumeKey.key(platform: "douyu", roomId: "123"),
            "douyu|123")
    }

    func testSameRoomIdOnTwoPlatformsHasDifferentKeys() {
        XCTAssertNotEqual(
            LiveResumeKey.key(platform: "bilibili", roomId: "1"),
            LiveResumeKey.key(platform: "huya", roomId: "1"))
    }

    // MARK: - Follows merge

    func testSameRoomReplacesInsteadOfDuplicating() {
        let merged = LiveLibraryStore.mergedFollows([follow()], with: follow())
        XCTAssertEqual(merged.count, 1)
    }

    func testReFollowMovesToFrontWithFreshTime() {
        let old = follow(roomId: "1", followedAt: Date(timeIntervalSince1970: 1000))
        let fresh = follow(roomId: "1", followedAt: Date(timeIntervalSince1970: 2000))
        let merged = LiveLibraryStore.mergedFollows(
            [follow(roomId: "2"), old], with: fresh)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].roomId, "1")
        XCTAssertEqual(merged[0].followedAt, Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(merged[1].roomId, "2")
    }

    func testFollowsAreUncapped() {
        var stored: [LiveFollowedRoom] = []
        for index in 0..<120 {
            stored = LiveLibraryStore.mergedFollows(
                stored, with: follow(roomId: "\(index)"))
        }
        XCTAssertEqual(stored.count, 120)
    }

    // MARK: - History merge + cap

    func testReEnterMovesToFrontWithFreshTime() {
        let old = entry(roomId: "1", watchedAt: Date(timeIntervalSince1970: 1000))
        let fresh = entry(roomId: "1", watchedAt: Date(timeIntervalSince1970: 2000))
        let merged = LiveLibraryStore.mergedHistory(
            [entry(roomId: "2"), old], with: fresh, limit: 50)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].roomId, "1")
        XCTAssertEqual(merged[0].watchedAt, Date(timeIntervalSince1970: 2000))
    }

    /// A record WITHOUT playUrls never wipes the stored URLs for
    /// the same room (b49fix44 S33-P1-3): the Home / My entry
    /// points record before the room page carries `data`, and the
    /// nil write used to replace the stored row for good.
    func testNilPlayUrlsRecordKeepsStoredUrls() {
        let urls = "[{\"url\":\"https://example.com/ks.m3u8\"}]"
        let stored = entry(roomId: "1", playUrlsJSON: urls)
        let fresh = entry(roomId: "1", watchedAt: Date(timeIntervalSince1970: 3000))
        XCTAssertNil(fresh.playUrlsJSON)
        let merged = LiveLibraryStore.mergedHistory(
            [entry(roomId: "2"), stored], with: fresh, limit: 50)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].roomId, "1")
        XCTAssertEqual(merged[0].playUrlsJSON, urls)
        XCTAssertEqual(merged[0].watchedAt, Date(timeIntervalSince1970: 3000))
    }

    /// A record WITH playUrls still replaces the stored ones —
    /// the inheritance above only fills in a missing value, it
    /// never freezes the URLs.
    func testPlayUrlsRecordReplacesStoredUrls() {
        let old = entry(roomId: "1", playUrlsJSON: "[{\"url\":\"https://example.com/old.m3u8\"}]")
        let fresh = entry(
            roomId: "1", watchedAt: Date(timeIntervalSince1970: 3000),
            playUrlsJSON: "[{\"url\":\"https://example.com/new.m3u8\"}]")
        let merged = LiveLibraryStore.mergedHistory([old], with: fresh, limit: 50)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].playUrlsJSON, "[{\"url\":\"https://example.com/new.m3u8\"}]")
    }

    func testHistoryCapTrimsOldest() {
        var stored: [LiveHistoryEntry] = []
        for index in 0..<55 {
            stored = LiveLibraryStore.mergedHistory(
                stored, with: entry(roomId: "\(index)"), limit: 50)
        }
        XCTAssertEqual(stored.count, 50)
        XCTAssertEqual(stored[0].roomId, "54")
        XCTAssertEqual(stored[49].roomId, "5")
    }

    func testZeroLimitMeansUnlimited() {
        var stored: [LiveHistoryEntry] = []
        for index in 0..<80 {
            stored = LiveLibraryStore.mergedHistory(
                stored, with: entry(roomId: "\(index)"), limit: 0)
        }
        XCTAssertEqual(stored.count, 80)
    }

    func testWouldDeleteCount() {
        let stored = (0..<10).map { entry(roomId: "\($0)") }
        XCTAssertEqual(LiveLibraryStore.wouldDeleteCount(stored, newLimit: 6), 4)
        XCTAssertEqual(LiveLibraryStore.wouldDeleteCount(stored, newLimit: 10), 0)
        XCTAssertEqual(LiveLibraryStore.wouldDeleteCount(stored, newLimit: 20), 0)
        XCTAssertEqual(LiveLibraryStore.wouldDeleteCount(stored, newLimit: 0), 0)
    }

    // MARK: - Day sections (Pure Live HistorySection.of)

    func testSectionTodayYesterdayRecentEarlier() {
        let now = Date(timeIntervalSince1970: 1_764_000_000)
        let calendar = Calendar.current
        XCTAssertEqual(LiveHistorySection.of(now, now: now), .today)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        XCTAssertEqual(LiveHistorySection.of(yesterday, now: now), .yesterday)
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: now) ?? now
        XCTAssertEqual(LiveHistorySection.of(threeDaysAgo, now: now), .recent)
        let tenDaysAgo = calendar.date(byAdding: .day, value: -10, to: now) ?? now
        XCTAssertEqual(LiveHistorySection.of(tenDaysAgo, now: now), .earlier)
    }

    func testSectionLabels() {
        XCTAssertEqual(LiveHistorySection.today.label, "今天")
        XCTAssertEqual(LiveHistorySection.yesterday.label, "昨天")
        XCTAssertEqual(LiveHistorySection.recent.label, "2–6 天前")
        XCTAssertEqual(LiveHistorySection.earlier.label, "更早")
    }

    // MARK: - Search history merge

    func testSameQueryMovesToFront() {
        let merged = LiveLibraryStore.mergedSearchHistory(["a", "b"], with: "a")
        XCTAssertEqual(merged, ["a", "b"])
    }

    func testBlankQueryIsIgnored() {
        let merged = LiveLibraryStore.mergedSearchHistory(["a"], with: "   ")
        XCTAssertEqual(merged, ["a"])
    }

    func testSearchHistoryCapsAtTwenty() {
        var stored: [String] = []
        for index in 0..<25 {
            stored = LiveLibraryStore.mergedSearchHistory(stored, with: "q\(index)")
        }
        XCTAssertEqual(stored.count, 20)
        XCTAssertEqual(stored[0], "q24")
        XCTAssertEqual(stored[19], "q5")
    }

    // MARK: - Search history single-term delete (build 36 item 8)

    func testRemovingSearchHistoryDropsOneTerm() {
        XCTAssertEqual(
            LiveLibraryStore.removingSearchHistory(["a", "b", "c"], term: "b"),
            ["a", "c"])
    }

    func testRemovingAbsentSearchTermKeepsList() {
        XCTAssertEqual(
            LiveLibraryStore.removingSearchHistory(["a", "b"], term: "z"),
            ["a", "b"])
    }
}

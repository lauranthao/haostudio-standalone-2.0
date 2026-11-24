// HAo Studio 2.0 — video source tombstone-merge tests (build 36 item 6).
//
// Ports the item-6 design harness fixtures (cases A–D) against the
// real `VideoSourceStore.mergeVideoSources`: upstream-deleted
// defaults disappear, user-added sources survive, user-deleted
// defaults stay deleted, matched defaults refresh sort + http→https
// without touching the user's enabled toggle.
//
// Pure tests only: `mergeVideoSources` takes every input explicitly
// and touches no UserDefaults / disk, except
// `testMergeDefaultsNoOpWhenCurrent`, which covers the IO wrapper's
// no-op path (it records the applied set in UserDefaults the first
// time it runs — app-specific keys, test-process only).

import Foundation
import XCTest

@testable import AppCore

final class VideoSourceMergeTests: XCTestCase {
    private func src(id: Int, name: String, url: String, kind: String = "play", enabled: Bool = true, sort: Int = 10) -> VideoSource {
        VideoSource(id: id, name: name, apiUrl: url, kind: kind, enabled: enabled, sort: sort)
    }

    /// chen's build-34 stored list (rev-5 18, minus user-deleted
    /// 360资源) with user edits: reordered, one http twin
    /// (魔都资源), one user-added custom source (id 99).
    private func chenStoredList() -> [VideoSource] {
        [
            src(id: 12, name: "金鹰资源", url: "https://jyzyapi.com/api.php/provide/vod", sort: 5),
            src(id: 13, name: "非凡资源", url: "https://ffzy5.tv/api.php/provide/vod", kind: "search", sort: 6),
            src(id: 18, name: "非凡主站", url: "https://cj.ffzyapi.com/api.php/provide/vod", kind: "search", sort: 7),
            src(id: 8, name: "极速资源", url: "https://jszyapi.com/api.php/provide/vod", sort: 10),
            src(id: 6, name: "魔都资源", url: "http://caiji.moduapi.cc/api.php/provide/vod", sort: 11),
            src(id: 17, name: "iKun资源", url: "https://ikunzyapi.com/api.php/provide/vod", sort: 12),
            src(id: 7, name: "光速资源", url: "https://api.guangsuapi.com/api.php/provide/vod", sort: 13),
            src(id: 9, name: "虎牙资源", url: "https://www.huyaapi.com/api.php/provide/vod", sort: 14),
            src(id: 10, name: "新狼资源", url: "https://api.xinlangapi.com/xinlangapi.php/provide/vod", sort: 15),
            src(id: 14, name: "厂长资源", url: "https://api.changzhang.tv/api.php/provide/vod/", sort: 16),
            src(id: 2, name: "豪华资源", url: "https://hhzyapi.com/api.php/provide/vod/", sort: 17),
            src(id: 1, name: "红牛资源", url: "https://www.hongniuzy2.com/api.php/provide/vod/", sort: 18),
            src(id: 15, name: "速播备用", url: "https://subocaiji.com/api.php/provide/vod", sort: 19),
            src(id: 3, name: "速播资源", url: "https://www.subozy.com/api.php/provide/vod/", sort: 20),
            src(id: 16, name: "如意资源", url: "https://cj.rycjapi.com/api.php/provide/vod", sort: 21),
            src(id: 4, name: "量子资源", url: "https://cj.lziapi.com/api.php/provide/vod", enabled: false, sort: 23),
            src(id: 19, name: "电影天堂资源", url: "https://caiji.dyttzyapi.com/api.php/provide/vod", sort: 25),
            src(id: 99, name: "我的自建源", url: "https://my-own.example.com/api.php/provide/vod", sort: 30),
        ]
    }

    private func mergeA() -> (merged: [VideoSource], applied: Set<String>) {
        VideoSourceStore.mergeVideoSources(
            stored: chenStoredList(), seen: 5, currentRevision: 7,
            currentDefaults: CmsClient.defaultSources, applied: nil,
            legacyRemoved: VideoSourceStore.legacyRemovedURLs)
    }

    func testRevisionIs7AndDefaultsAreRev6Set() {
        XCTAssertEqual(CmsClient.sourcesRevision, 7)
        XCTAssertEqual(CmsClient.defaultSources.count, 13)
        let urls = Set(CmsClient.defaultSources.map { $0.apiUrl })
        XCTAssertTrue(urls.contains("https://caiji.mgzyapi.com/api.php/provide/vod"))
        XCTAssertTrue(urls.contains("https://mujiziyuan00.com/api.php/provide/vod"))
        // Rev 6 = rev 5 minus the 7 deleted, plus mango + muji.
        let rev5 = Set(VideoSourceStore.rev5DefaultURLs)
        XCTAssertEqual(rev5.count, 18)
        XCTAssertEqual(VideoSourceStore.legacyRemovedURLs.count, 7)
        XCTAssertEqual(urls, rev5.subtracting(VideoSourceStore.legacyRemovedURLs)
            .union(["https://caiji.mgzyapi.com/api.php/provide/vod",
                    "https://mujiziyuan00.com/api.php/provide/vod"]))
    }

    func testCaseAUpstreamDeletedGoneAndNewDefaultsAdded() {
        let a = mergeA()
        let urls = Set(a.merged.map { videoToHttps($0.apiUrl) })
        XCTAssertTrue(VideoSourceStore.legacyRemovedURLs.isDisjoint(with: urls))
        XCTAssertTrue(urls.contains("https://caiji.mgzyapi.com/api.php/provide/vod"))
        XCTAssertTrue(urls.contains("https://mujiziyuan00.com/api.php/provide/vod"))
        XCTAssertEqual(a.merged.count, 13)
        XCTAssertEqual(a.applied, Set(CmsClient.defaultSources.map { $0.apiUrl }))
    }

    func testCaseAUserAddedSurvivesAndUserDeletedStaysDeleted() {
        let a = mergeA()
        let urls = Set(a.merged.map { videoToHttps($0.apiUrl) })
        XCTAssertTrue(urls.contains("https://my-own.example.com/api.php/provide/vod"))
        // 360资源 was user-deleted in the rev-5 era: the recovered
        // rev-5 applied set distinguishes it from the upstream
        // deletions, so it must NOT come back.
        XCTAssertFalse(urls.contains("https://360zy.com/api.php/provide/vod"))
    }

    func testCaseAHttpTwinUpgradedSortRefreshedToggleKept() {
        let a = mergeA()
        let modu = a.merged.first { $0.id == 6 }
        XCTAssertEqual(modu?.apiUrl, "https://caiji.moduapi.cc/api.php/provide/vod")
        XCTAssertEqual(modu?.sort, 11)
        XCTAssertEqual(modu?.enabled, true)
        // A matched default the user switched off stays off, with
        // its sort still refreshed.
        let off = VideoSourceStore.mergeVideoSources(
            stored: [src(id: 12, name: "金鹰资源", url: "https://jyzyapi.com/api.php/provide/vod", enabled: false, sort: 99)],
            seen: 5, currentRevision: 7, currentDefaults: CmsClient.defaultSources,
            applied: nil, legacyRemoved: VideoSourceStore.legacyRemovedURLs)
        XCTAssertEqual(off.merged.first?.enabled, false)
        XCTAssertEqual(off.merged.first?.sort, 5)
    }

    func testCaseBUserDeletedMangoNotResurrected() {
        let a = mergeA()
        let stored = a.merged.filter { $0.apiUrl != "https://caiji.mgzyapi.com/api.php/provide/vod" }
        let b = VideoSourceStore.mergeVideoSources(
            stored: stored, seen: 7, currentRevision: 8,
            currentDefaults: CmsClient.defaultSources, applied: a.applied,
            legacyRemoved: VideoSourceStore.legacyRemovedURLs)
        let urls = Set(b.merged.map { videoToHttps($0.apiUrl) })
        XCTAssertFalse(urls.contains("https://caiji.mgzyapi.com/api.php/provide/vod"))
        XCTAssertEqual(b.merged.count, 12)
    }

    func testCaseCAlreadyCurrentIsNoOp() {
        let a = mergeA()
        let c = VideoSourceStore.mergeVideoSources(
            stored: a.merged, seen: 7, currentRevision: 7,
            currentDefaults: CmsClient.defaultSources, applied: a.applied,
            legacyRemoved: VideoSourceStore.legacyRemovedURLs)
        XCTAssertEqual(c.merged, a.merged)
    }

    func testCaseDFixtureReallyContainsTheSevenDead() {
        let dead = chenStoredList().filter { VideoSourceStore.legacyRemovedURLs.contains(videoToHttps($0.apiUrl)) }.count
        XCTAssertEqual(dead, 7)
    }

    func testNoRecordFallsBackToLegacyRemovedSet() {
        // A pre-fix install with no applied record and seen != 5:
        // only the known-dead urls are dropped (user-deleted
        // defaults cannot be distinguished there, so they come
        // back — the rev-5 recovery above is what avoids that on
        // chen's device, where seen == 5).
        let result = VideoSourceStore.mergeVideoSources(
            stored: chenStoredList(), seen: 0, currentRevision: 7,
            currentDefaults: CmsClient.defaultSources, applied: nil,
            legacyRemoved: VideoSourceStore.legacyRemovedURLs)
        let urls = Set(result.merged.map { videoToHttps($0.apiUrl) })
        XCTAssertTrue(VideoSourceStore.legacyRemovedURLs.isDisjoint(with: urls))
        XCTAssertEqual(result.merged.count, 14)
    }

    func testMergeDefaultsNoOpWhenCurrent() {
        let stored = mergeA().merged
        XCTAssertEqual(VideoSourceStore.mergeDefaults(stored, seenRevision: 7), stored)
    }
}

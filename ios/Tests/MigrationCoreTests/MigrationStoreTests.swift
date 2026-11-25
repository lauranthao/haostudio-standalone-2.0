// HAo Studio 2.0 — migration tests (S1).
//
// Covers the migration paths the plan requires: happy-path migration
// with per-key verification, corrupt snapshot skipped, bad type
// skips only the bad key, write failure rolls back in full, repeat
// migration is idempotent, backup JSON imports as a merge, and the
// mapping table keeps its shape (136 named keys, 3 prefix families).
// Keychain round-trip lives in KeychainStoreTests; the Emby token
// split (file without the key, key in the Keychain) is covered there
// too, because a CI runner without keychain access must skip it
// instead of failing the whole migration suite.

import Foundation
import XCTest

@testable import AppCore

final class MigrationStoreTests: XCTestCase {
    private var docs: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.haostudio.migration.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        docs = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-migration-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        MigrationStore.testFailOnKey = nil
        _ = KeychainStore.deleteEmbyApiKey()
    }

    override func tearDown() {
        MigrationStore.testFailOnKey = nil
        _ = KeychainStore.deleteEmbyApiKey()
        if let docs = docs {
            try? FileManager.default.removeItem(at: docs)
        }
        if let suiteName = suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    // MARK: - Fixtures

    private func writeSnapshot(_ data: [String: Any], schema: Int = 1, appVersion: String? = "1.1.6") {
        var root: [String: Any] = [
            "schema": schema,
            "app": "HAo Studio",
            "data": data,
        ]
        if let version = appVersion {
            root["appVersion"] = version
            root["appBuild"] = 31
        }
        let json = try! JSONSerialization.data(withJSONObject: root, options: [])
        try! json.write(to: docs.appendingPathComponent("migration_snapshot.json"), options: [.atomic])
    }

    private func writeSnapshotRaw(_ text: String) {
        try! text.write(to: docs.appendingPathComponent("migration_snapshot.json"), atomically: true, encoding: .utf8)
    }

    private func readJSONFile(_ name: String) -> Any? {
        let url = docs.appendingPathComponent("\(name).json")
        guard let raw = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: raw, options: [])
    }

    private func runMigration() -> MigrationReport {
        MigrationStore.runIfNeeded(documentsURL: docs, defaults: defaults)
    }

    // MARK: - Happy path

    func testHappyPathMigrationVerifiesEveryKey() {
        writeSnapshot([
            "videoPlayerKey": "ijk",
            "musicSpeed": 1.5,
            "hapticsEnabled": false,
            "lastUpdateCheckAt": 1700000000000,
            "hao_tabbar_accent_presets": [4294967295, 4278190335],
            "hao_eq_band_gains": [0.5, -1.0, 0, 0, 0, 0, 0, 0, 0, 0],
            "hao_lists": "[{\"id\":\"pl1\",\"name\":\"收藏\"}]",
            "hao_fav": [["key": "song-a"]],
            "haoVodProg:cms:vod42": 1234.5,
            "hao_daily_2026-11-23": "{\"picks\":[\"a\"]}",
            "hao_listen_2026-11": "[{\"at\":1700000000000,\"dur\":180}]",
            "hao_live_hist_limit": 25,
            "some_future_key_xyz": "keep me",
        ])

        let report = runMigration()

        XCTAssertEqual(report.outcome, .migrated)
        XCTAssertEqual(report.totalKeys, 13)
        XCTAssertEqual(report.unknownKeys, 1)
        XCTAssertEqual(report.skippedKeys, 0)
        XCTAssertEqual(report.failedKeys, 0)
        XCTAssertEqual(report.unknownKeyNames, ["some_future_key_xyz"])
        XCTAssertTrue(MigrationStore.isMigrationDone(defaults: defaults))
        XCTAssertFalse(MigrationStore.migrationNoticeNeeded(defaults: defaults))

        XCTAssertEqual(defaults.string(forKey: "videoPlayerKey"), "ijk")
        XCTAssertEqual(defaults.double(forKey: "musicSpeed"), 1.5)
        XCTAssertEqual(defaults.bool(forKey: "hapticsEnabled"), false)
        XCTAssertEqual(defaults.integer(forKey: "lastUpdateCheckAt"), 1700000000000)
        XCTAssertEqual(defaults.integer(forKey: "hao_live_hist_limit"), 25)
        XCTAssertEqual((defaults.array(forKey: "hao_tabbar_accent_presets") as? [Int])?.count, 2)
        XCTAssertEqual((defaults.array(forKey: "hao_eq_band_gains") as? [Double])?.count, 10)
        XCTAssertEqual((defaults.array(forKey: "hao_eq_band_gains") as? [Double])?.first, 0.5)

        XCTAssertEqual((readJSONFile("hao_lists") as? [[String: Any]])?.count, 1)
        XCTAssertEqual((readJSONFile("hao_fav") as? [[String: Any]])?.count, 1)
        XCTAssertEqual((readJSONFile("haoVodProg") as? [String: Any])?["haoVodProg:cms:vod42"] as? Double, 1234.5)
        XCTAssertNotNil((readJSONFile("hao_daily") as? [String: Any])?["hao_daily_2026-11-23"])
        XCTAssertEqual((readJSONFile("hao_listen") as? [[String: Any]])?.count, 1)
        XCTAssertEqual((readJSONFile("migration_unknown_keys") as? [String: Any])?["some_future_key_xyz"] as? String, "keep me")

        // The pre-write backup holds a copy of the snapshot file.
        let backupRoot = docs.appendingPathComponent("migration_backup")
        let backupDirs = (try? FileManager.default.contentsOfDirectory(atPath: backupRoot.path)) ?? []
        XCTAssertEqual(backupDirs.count, 1)
        let snapshotCopy = backupRoot
            .appendingPathComponent(backupDirs[0])
            .appendingPathComponent("migration_snapshot.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotCopy.path))
    }

    // MARK: - Snapshot problems are skips, never crashes

    func testMissingSnapshotSkipped() {
        let report = runMigration()
        XCTAssertEqual(report.outcome, .noSnapshot)
        XCTAssertFalse(MigrationStore.isMigrationDone(defaults: defaults))
        XCTAssertTrue(MigrationStore.migrationNoticeNeeded(defaults: defaults))
        XCTAssertEqual(MigrationStore.migrationState(defaults: defaults), MigrationStore.stateNoSnapshot)
    }

    func testCorruptSnapshotSkipped() {
        writeSnapshotRaw("this is not json {{{")
        let report = runMigration()
        XCTAssertEqual(report.outcome, .invalidSnapshot)
        XCTAssertFalse(MigrationStore.isMigrationDone(defaults: defaults))
        XCTAssertTrue(MigrationStore.migrationNoticeNeeded(defaults: defaults))
    }

    func testWrongSchemaSkipped() {
        writeSnapshot(["videoPlayerKey": "ijk"], schema: 2)
        XCTAssertEqual(runMigration().outcome, .invalidSnapshot)
        XCTAssertNil(defaults.string(forKey: "videoPlayerKey"))
    }

    func testWrongVersionSkipped() {
        writeSnapshot(["videoPlayerKey": "ijk"], appVersion: "2.0.0")
        XCTAssertEqual(runMigration().outcome, .invalidSnapshot)
        XCTAssertNil(defaults.string(forKey: "videoPlayerKey"))
    }

    func testMissingVersionAccepted() {
        writeSnapshot(["videoPlayerKey": "ijk"], appVersion: nil)
        XCTAssertEqual(runMigration().outcome, .migrated)
        XCTAssertEqual(defaults.string(forKey: "videoPlayerKey"), "ijk")
    }

    // MARK: - Bad types skip only the bad key

    func testBadTypeSkipsOnlyBadKey() {
        writeSnapshot([
            "videoPlayerKey": "ijk",
            "musicSpeed": "fast",
            "hao_lists": "[1,2",
            "hao_live_hist_limit": 25,
        ])
        let report = runMigration()
        XCTAssertEqual(report.outcome, .migrated)
        XCTAssertEqual(report.skippedKeyNames, ["hao_lists", "musicSpeed"])
        XCTAssertEqual(defaults.string(forKey: "videoPlayerKey"), "ijk")
        XCTAssertEqual(defaults.integer(forKey: "hao_live_hist_limit"), 25)
        XCTAssertNil(readJSONFile("hao_lists"))
        XCTAssertTrue(MigrationStore.isMigrationDone(defaults: defaults))
    }

    // MARK: - Failure rolls back in full, retry works

    func testWriteFailureRollsBackEverything() {
        defaults.set("mpv", forKey: "videoPlayerKey")
        let priorFav = "{\"old\":true}".data(using: .utf8)!
        try! priorFav.write(to: docs.appendingPathComponent("hao_fav.json"), options: [.atomic])
        writeSnapshot([
            "videoPlayerKey": "ijk",
            "hao_fav": "[{\"key\":\"new\"}]",
            "hao_lists": "[{\"id\":\"x\"}]",
        ])
        MigrationStore.testFailOnKey = "hao_lists"

        let failed = runMigration()
        XCTAssertEqual(failed.outcome, .failed)
        XCTAssertFalse(MigrationStore.isMigrationDone(defaults: defaults))
        XCTAssertEqual(MigrationStore.migrationState(defaults: defaults), MigrationStore.stateFailed)
        XCTAssertEqual(defaults.string(forKey: "videoPlayerKey"), "mpv")
        XCTAssertEqual(try? Data(contentsOf: docs.appendingPathComponent("hao_fav.json")), Optional(priorFav))
        XCTAssertFalse(FileManager.default.fileExists(atPath: docs.appendingPathComponent("hao_lists.json").path))

        MigrationStore.testFailOnKey = nil
        let retried = runMigration()
        XCTAssertEqual(retried.outcome, .migrated)
        XCTAssertEqual(defaults.string(forKey: "videoPlayerKey"), "ijk")
        XCTAssertNotNil(readJSONFile("hao_lists"))
    }

    // MARK: - Idempotency

    func testRepeatMigrationIsIdempotent() {
        writeSnapshot(["videoPlayerKey": "ijk", "musicSpeed": 1.5])
        XCTAssertEqual(runMigration().outcome, .migrated)
        let second = runMigration()
        XCTAssertEqual(second.outcome, .alreadyDone)
        XCTAssertEqual(defaults.string(forKey: "videoPlayerKey"), "ijk")
        XCTAssertEqual(defaults.double(forKey: "musicSpeed"), 1.5)
    }

    // MARK: - Route B: backup import merges, never replaces

    func testBackupImportMergesAndSkipsBadKeys() {
        defaults.set("mpv", forKey: "videoPlayerKey")
        defaults.set(true, forKey: "hapticsEnabled")
        let backup: [String: Any] = [
            "schema": 1,
            "app": "HAo Studio",
            "version": "1.0.4",
            "exportedAt": "2026-11-23T00:00:00.000Z",
            "entries": 3,
            "data": [
                "videoPlayerKey": "ijk",
                "musicSpeed": "fast",
                "hao_lists": "[{\"id\":\"pl1\"}]",
            ],
        ]
        let json = String(data: try! JSONSerialization.data(withJSONObject: backup, options: []), encoding: .utf8)!
        let report = MigrationStore.importBackupJSON(json, documentsURL: docs, defaults: defaults)
        XCTAssertEqual(report.outcome, .migrated)
        XCTAssertEqual(report.skippedKeyNames, ["musicSpeed"])
        XCTAssertEqual(defaults.string(forKey: "videoPlayerKey"), "ijk")
        XCTAssertEqual(defaults.bool(forKey: "hapticsEnabled"), true)
        XCTAssertEqual((readJSONFile("hao_lists") as? [[String: Any]])?.count, 1)
    }

    func testBackupImportRejectsWrongSchema() {
        defaults.set("mpv", forKey: "videoPlayerKey")
        let backup: [String: Any] = ["schema": 9, "data": ["videoPlayerKey": "ijk"]]
        let json = String(data: try! JSONSerialization.data(withJSONObject: backup, options: []), encoding: .utf8)!
        XCTAssertEqual(
            MigrationStore.importBackupJSON(json, documentsURL: docs, defaults: defaults).outcome,
            .invalidSnapshot
        )
        XCTAssertEqual(defaults.string(forKey: "videoPlayerKey"), "mpv")
    }

    // MARK: - Notice lifecycle

    func testMigrationNoticeLifecycle() {
        XCTAssertTrue(MigrationStore.migrationNoticeNeeded(defaults: defaults))
        MigrationStore.dismissMigrationNotice(defaults: defaults)
        XCTAssertFalse(MigrationStore.migrationNoticeNeeded(defaults: defaults))
    }

    // MARK: - Mapping table shape

    func testMappingTableShape() {
        XCTAssertEqual(MigrationStore.mappings.count, 136)
        XCTAssertEqual(Set(MigrationStore.mappings.map { $0.key }).count, 136)
        XCTAssertEqual(MigrationStore.prefixRules.count, 3)
        XCTAssertEqual(MigrationStore.ignoredPrefixes, ["hao_play_url_cache:"])
        XCTAssertNotNil(MigrationStore.mapping(for: "hao_emby_config"))
        XCTAssertNotNil(MigrationStore.mapping(for: "hao_lists"))
        XCTAssertNil(MigrationStore.mapping(for: "no_such_key"))
        XCTAssertEqual(MigrationStore.prefixRule(for: "haoVodProg:cms:x")?.fileName, "haoVodProg")
        XCTAssertTrue(MigrationStore.isIgnored("hao_play_url_cache:a|wy|hires"))
    }

    // MARK: - b49fix17: Route B merge for hao_recent / musicResume (P1-4)

    /// A recent song dict (the shape MusicSong.toJSON writes:
    /// platform + songId — the identityKey is platform|songId).
    private func recentSong(_ id: String) -> [String: Any] {
        ["platform": "wy", "songId": id, "title": "t\(id)", "artist": "a", "album": ""]
    }

    private func writeJSONFile(_ name: String, _ value: Any) {
        let json = try! JSONSerialization.data(withJSONObject: value, options: [])
        try! json.write(to: docs.appendingPathComponent("\(name).json"), options: [.atomic])
    }

    private func jsonString(_ value: Any) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: value, options: []), encoding: .utf8)!
    }

    func testRouteBRecentMergesWithLiveInsteadOfOverwriting() {
        // Live file: the just-played song. Snapshot: one backup
        // song. The merge must keep BOTH, live first — the old
        // whole-file write silently dropped the live song.
        writeJSONFile("hao_recent", [recentSong("live-1")])
        writeSnapshot(["hao_recent": jsonString([recentSong("backup-1")])])

        let report = runMigration()

        XCTAssertEqual(report.outcome, .migrated)
        let file = readJSONFile("hao_recent") as? [[String: Any]]
        XCTAssertEqual(file?.count, 2)
        XCTAssertEqual(file?.first?["songId"] as? String, "live-1")
        XCTAssertEqual(file?.last?["songId"] as? String, "backup-1")
    }

    func testRouteBResumeDictMergesAndListShapeSkips() {
        // Dict shape (the real Flutter shape,
        // docs/storage-mapping.md:112): live + backup keys merge.
        writeJSONFile("musicResume", ["live|wy": 30.0])
        writeSnapshot(["musicResume": jsonString(["backup|wy": 60.0])])

        let report = runMigration()

        XCTAssertEqual(report.outcome, .migrated)
        let merged = readJSONFile("musicResume") as? [String: Any]
        XCTAssertEqual(merged?["live|wy"] as? Double, 30.0)
        XCTAssertEqual(merged?["backup|wy"] as? Double, 60.0)
    }

    func testRouteBResumeListShapeIsSkippedNotMerged() {
        // The old fixture sampled musicResume as a list — a list
        // is not the dict resumeMap() reads, so it must be
        // skipped (and the live dict left untouched), not merged
        // into a file the player cannot read.
        writeJSONFile("musicResume", ["live|wy": 30.0])
        writeSnapshot(["musicResume": jsonString([["id": "x"]])])

        let report = runMigration()

        XCTAssertEqual(report.outcome, .migrated)
        XCTAssertTrue(report.skippedKeyNames.contains("musicResume"))
        let kept = readJSONFile("musicResume") as? [String: Any]
        XCTAssertEqual(kept?["live|wy"] as? Double, 30.0)
        XCTAssertEqual(kept?.count, 1)
    }

    // MARK: - b49fix17: merge / cap / prune pure helpers (P2-1, P2-4, P1-2)

    func testCappedVodProgKeepsAllIncomingKeys() {
        // Incoming key sorts FIRST lexicographically — the old
        // "take last 200" dropped exactly this key on every
        // repeat import, silently.
        let incoming = ["haoVodProg:aaa:early": 1.0]
        var dict = incoming
        for i in 0..<200 { dict["haoVodProg:zzz:\(i)"] = Double(i) }

        let capped = MigrationStore.cappedVodProgEntries(dict, keeping: Set(incoming.keys))

        XCTAssertEqual(capped.count, 200)
        XCTAssertNotNil(capped["haoVodProg:aaa:early"])
    }

    func testPrunedDailyEntriesKeepsUnparseableAndKeepingKey() {
        // Fixed "now" so the test does not drift with the date.
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 26))!
        let dict: [String: Any] = [
            "2026-11-15": [[String: Any]](), // 11 days old, pruned
            "2026-11-22": [[String: Any]](), // 4 days old, kept
            "not-a-date": [[String: Any]](), // unparseable, kept
            "2026-11-01": [[String: Any]](), // old but `keeping`, kept
        ]

        let pruned = MigrationStore.prunedDailyEntries(dict, keeping: "2026-11-01", now: now)

        XCTAssertEqual(Set(pruned.keys), ["2026-11-22", "not-a-date", "2026-11-01"])
    }

    func testMergedRecentEntriesLiveFirstDedupesAndCapsAt100() {
        let live = [recentSong("live-1"), recentSong("live-2")]
        var incoming = [recentSong("live-1")] // duplicate of live
        for i in 0..<99 { incoming.append(recentSong("b\(i)")) }

        let merged = MigrationStore.mergedRecentEntries(live: live, incoming: incoming)

        XCTAssertEqual(merged.count, 100)
        XCTAssertEqual(merged[0]["songId"] as? String, "live-1")
        XCTAssertEqual(merged[1]["songId"] as? String, "live-2")
        XCTAssertEqual(merged.filter { ($0["songId"] as? String) == "live-1" }.count, 1)
    }

    func testMergedListEntriesDedupesByKeyLiveWins() {
        let live = [["id": "a", "name": "old"]]
        let incoming = [["id": "a", "name": "new"], ["id": "b", "name": "x"]]

        let merged = MigrationStore.mergedListEntries(live: live, incoming: incoming) { $0["id"] as? String }

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0]["name"] as? String, "old")
        XCTAssertEqual(merged[1]["id"] as? String, "b")
    }

    func testMergedStringListDedupesAndCaps() {
        let merged = MigrationStore.mergedStringList(live: ["a", "b"], incoming: ["b", "c", "d"], cap: 3)

        XCTAssertEqual(merged, ["a", "b", "c"])
    }

    func testRecentContainsAllToleratesFrontInsertDisplacement() {
        // 100 merged entries; a new song inserted at the front
        // pushes the oldest merged entry out of the 100 cap.
        // The tolerant check must pass — plain multiset subset
        // would fail and roll back the whole import.
        let merged = (0..<100).map { recentSong("k\($0)") }
        var actual = [recentSong("new-song")] + Array(merged.prefix(99))

        XCTAssertTrue(MigrationStore.recentContainsAll(actual: actual, expected: merged))

        // A missing MIDDLE entry with no displacement is a real
        // loss, not a front insert — must fail.
        actual = merged
        actual.remove(at: 50)
        XCTAssertFalse(MigrationStore.recentContainsAll(actual: actual, expected: merged))

        // A missing TAIL entry with NO concurrent insert is a
        // write that never landed — must fail.
        actual = Array(merged.prefix(99))
        XCTAssertFalse(MigrationStore.recentContainsAll(actual: actual, expected: merged))
    }

    func testResumeEntriesPresentToleratesOnlyRecordedDeletions() {
        writeJSONFile("musicResume", ["a": 1.0, "b": 2.0])

        // "c" never landed but was recorded as deleted by
        // clearResume — excused. Without the record it fails.
        XCTAssertTrue(MigrationStore.resumeEntriesPresent(
            ["a": 1.0, "b": 2.0, "c": 3.0], documentsURL: docs, toleratingDeleted: ["c"]))
        XCTAssertFalse(MigrationStore.resumeEntriesPresent(
            ["a": 1.0, "b": 2.0, "c": 3.0], documentsURL: docs, toleratingDeleted: []))
        XCTAssertTrue(MigrationStore.resumeEntriesPresent(
            ["a": 1.0, "b": 2.0], documentsURL: docs, toleratingDeleted: []))
    }
}

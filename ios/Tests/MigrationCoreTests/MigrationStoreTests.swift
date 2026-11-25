// HAo Studio 2.0 — migration tests (S1).
//
// Covers the migration paths the plan requires: happy-path migration
// with per-key verification, corrupt snapshot skipped, bad type
// skips only the bad key, write failure rolls back in full, repeat
// migration is idempotent, backup JSON imports as a merge, and the
// mapping table keeps its shape (117 named keys, 3 prefix families).
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
        XCTAssertEqual(MigrationStore.mappings.count, 117)
        XCTAssertEqual(Set(MigrationStore.mappings.map { $0.key }).count, 117)
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
        // docs/storage-mapping.md:105): live + backup keys merge.
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

    // MARK: - b49fix18: identity normalisation, recent budget, shape, quarantine, Route B

    func testFix18SongIdentityKeyNormalisesUnknownPlatformToWy() {
        // A Flutter backup's lx:… entry and the live wy entry
        // for the same song are one song (D-4): the merge key
        // must not keep both.
        let lx: [String: Any] = ["platform": "lx:netease", "songId": "s1"]
        let wy: [String: Any] = ["platform": "wy", "songId": "s1"]
        XCTAssertEqual(MigrationStore.songIdentityKey(for: lx),
                       MigrationStore.songIdentityKey(for: wy))
        // A known code stays distinct — normalisation is not
        // collapsing everything onto wy.
        XCTAssertNotEqual(MigrationStore.songIdentityKey(for: ["platform": "tx", "songId": "s1"]),
                          MigrationStore.songIdentityKey(for: wy))
        // A missing platform normalises the same way the typed
        // layer does (fromCode(nil) -> wy).
        XCTAssertEqual(MigrationStore.songIdentityKey(for: ["songId": "s1"]),
                       MigrationStore.songIdentityKey(for: wy))
        // The empty-id fallback normalises too (title/artist/album).
        let lxTitle: [String: Any] = ["platform": "lx:netease", "title": "t", "artist": "a", "album": ""]
        let wyTitle: [String: Any] = ["platform": "wy", "title": "t", "artist": "a", "album": ""]
        XCTAssertEqual(MigrationStore.songIdentityKey(for: lxTitle),
                       MigrationStore.songIdentityKey(for: wyTitle))
    }

    func testFix18ListenDedupeKeyNormalisesUnknownPlatform() {
        let lx: [String: Any] = ["platform": "lx:netease", "songId": "s1", "at": 1700000000000]
        let wy: [String: Any] = ["platform": "wy", "songId": "s1", "at": 1700000000000]
        XCTAssertEqual(MigrationStore.listenDedupeKey(for: lx),
                       MigrationStore.listenDedupeKey(for: wy))
        let later: [String: Any] = ["platform": "wy", "songId": "s1", "at": 1700000001000]
        XCTAssertNotEqual(MigrationStore.listenDedupeKey(for: wy),
                          MigrationStore.listenDedupeKey(for: later))
    }

    func testFix18RecentContainsAllIgnoresReAddsAndCapsBudget() {
        // D-5: a re-add displaces nothing, so it gives no
        // budget — a lost tail entry next to a re-add is a
        // real loss and must fail.
        let merged = (0..<100).map { recentSong("k\($0)") }
        var reAdded = merged
        reAdded.remove(at: 50)
        reAdded.insert(merged[50], at: 0)
        reAdded.removeLast() // the tail entry is gone
        XCTAssertFalse(MigrationStore.recentContainsAll(actual: reAdded, expected: merged))
        XCTAssertEqual(MigrationStore.recentMissingKeys(actual: reAdded, expected: merged), ["k99"])

        // One genuinely new song still excuses one displaced
        // tail entry, and the missing entry is observable.
        var oneNew = [recentSong("new-1")] + Array(merged.prefix(99))
        XCTAssertTrue(MigrationStore.recentContainsAll(actual: oneNew, expected: merged))
        XCTAssertEqual(MigrationStore.recentMissingKeys(actual: oneNew, expected: merged), ["k99"])
        oneNew = merged
        XCTAssertTrue(MigrationStore.recentMissingKeys(actual: oneNew, expected: merged).isEmpty)

        // The cap: 11 new songs displace 11 tail entries, but
        // the budget stops at 10 — the 11th loss fails.
        let elevenNew = (0..<11).map { recentSong("new-\($0)") } + Array(merged.prefix(89))
        XCTAssertFalse(MigrationStore.recentContainsAll(actual: elevenNew, expected: merged))
        // Exactly at the cap it still passes.
        let tenNew = (0..<10).map { recentSong("new-\($0)") } + Array(merged.prefix(90))
        XCTAssertTrue(MigrationStore.recentContainsAll(actual: tenNew, expected: merged))
    }

    func testFix18CappedVodProgSoftCapKeepsAllIncomingOver200() {
        // D-6: a single backup's incoming set alone exceeds
        // 200 — the file keeps all 250 (soft cap, not hard),
        // and a re-import of the same backup stays at 250.
        var incoming: [String: Any] = [:]
        for i in 0..<250 { incoming["haoVodProg:zzz:\(i)"] = Double(i) }
        let capped = MigrationStore.cappedVodProgEntries(incoming, keeping: Set(incoming.keys))
        XCTAssertEqual(capped.count, 250)
        XCTAssertEqual(MigrationStore.cappedVodProgEntries(capped, keeping: Set(incoming.keys)).count, 250)
    }

    func testFix18ExpectedCollectionShapeSpotRows() {
        // D-8: the shape table the plan check and the
        // whole-file guard share.
        XCTAssertEqual(MigrationStore.expectedCollectionShape(for: "hao_fav"), .list)
        XCTAssertEqual(MigrationStore.expectedCollectionShape(for: "musicQueue"), .dict)
        XCTAssertEqual(MigrationStore.expectedCollectionShape(for: "hao_music_search_hist"), .stringList)
        XCTAssertNil(MigrationStore.expectedCollectionShape(for: "hao_music_sources"))
        // A dict where a list belongs is the wrong shape;
        // a list of dicts is the wrong shape for a string list.
        let fav = MigrationStore.expectedCollectionShape(for: "hao_fav")!
        XCTAssertFalse(fav.matches(["a": 1] as [String: Any]))
        XCTAssertTrue(fav.matches([["key": "k1"]] as [[String: Any]]))
        let hist = MigrationStore.expectedCollectionShape(for: "hao_music_search_hist")!
        XCTAssertFalse(hist.matches([["q": "x"]] as [[String: Any]]))
        XCTAssertTrue(hist.matches(["a", "b"]))
        XCTAssertFalse(hist.matches(bytes: Data("not json".utf8)))
    }

    func testFix18QuarantineSameSecondTwiceKeepsBothFiles() {
        // D-9: two quarantines of the same file in the same
        // second used to collide on one destination — the
        // second move failed silently and the corrupt bytes
        // were destroyed by the following overwrite. The UUID
        // suffix makes both destinations distinct.
        let firstURL = docs.appendingPathComponent("hao_fav.json")
        try! "first-corrupt".write(to: firstURL, atomically: true, encoding: .utf8)
        LocalStore.quarantineFile(at: firstURL, name: "hao_fav", reason: "test-1", documentsURL: docs)
        let secondURL = docs.appendingPathComponent("hao_fav.json")
        try! "second-corrupt".write(to: secondURL, atomically: true, encoding: .utf8)
        LocalStore.quarantineFile(at: secondURL, name: "hao_fav", reason: "test-2", documentsURL: docs)

        let names = (try? FileManager.default.contentsOfDirectory(atPath: docs.path)) ?? []
        let quarantined = names.filter { $0.hasPrefix("hao_fav.corrupt-") && $0.hasSuffix(".json") }
        XCTAssertEqual(quarantined.count, 2)
        let contents = quarantined.compactMap {
            try? String(contentsOf: docs.appendingPathComponent($0), encoding: .utf8)
        }
        XCTAssertTrue(contents.contains("first-corrupt"))
        XCTAssertTrue(contents.contains("second-corrupt"))
    }

    func testFix18RouteBFavMergesLiveToggleInsteadOfOverwriting() {
        // D-1: a favourite toggled before the import used to
        // be silently dropped by Route B's whole-file write.
        writeJSONFile("hao_fav", [["key": "live-1"]])
        writeSnapshot(["hao_fav": jsonString([["key": "backup-1"]])])

        let report = runMigration()

        XCTAssertEqual(report.outcome, .migrated)
        let file = readJSONFile("hao_fav") as? [[String: Any]]
        XCTAssertEqual(file?.count, 2)
        XCTAssertEqual(file?.first?["key"] as? String, "live-1")
        XCTAssertEqual(file?.last?["key"] as? String, "backup-1")
    }

    func testFix18RouteBMusicQueueLiveWins() {
        // D-1: Route B had no live-wins rule — the backup
        // queue directly replaced the listening queue.
        writeJSONFile("musicQueue", ["songs": [recentSong("live-1")], "index": 0])
        writeSnapshot(["musicQueue": jsonString(["songs": [recentSong("backup-1")], "index": 0])])

        let report = runMigration()

        XCTAssertEqual(report.outcome, .migrated)
        XCTAssertTrue(report.skippedKeyNames.contains("musicQueue"))
        let kept = readJSONFile("musicQueue") as? [String: Any]
        let songs = kept?["songs"] as? [[String: Any]]
        XCTAssertEqual(songs?.count, 1)
        XCTAssertEqual(songs?.first?["songId"] as? String, "live-1")
    }

    func testFix18RouteBWrongShapeWholeFileIsSkippedNotInstalled() {
        // D-8: a dict where a list belongs used to be
        // installed as-is; the next live write then rewrote
        // from an empty table. Healthy live file -> skipped.
        writeJSONFile("hao_fav", [["key": "live-1"]])
        writeSnapshot(["hao_fav": jsonString(["not": "a list"])])

        let report = runMigration()

        XCTAssertEqual(report.outcome, .migrated)
        XCTAssertTrue(report.skippedKeyNames.contains("hao_fav"))
        let kept = readJSONFile("hao_fav") as? [[String: Any]]
        XCTAssertEqual(kept?.count, 1)
        XCTAssertEqual(kept?.first?["key"] as? String, "live-1")
    }

    // MARK: - b49fix19: history normalisation, key verify, fav key, rollback, warnings, recent budget, cache eviction, new mappings, live cap

    private func videoHistoryEntry(itemId: String, title: String, updatedAt: Any) -> [String: Any] {
        ["item": ["id": itemId, "title": title, "year": "2024"],
         "episodeName": "第1集", "episodeIndex": 0, "lineName": "線路1",
         "positionSeconds": 120, "durationSeconds": 3600, "updatedAt": updatedAt]
    }

    private func liveHistoryEntry(roomId: String, watchedAt: Any) -> [String: Any] {
        ["platform": "bilibili", "roomId": roomId, "title": "測試直播",
         "nick": "主播", "cover": "https://example.com/c.jpg", "watchedAt": watchedAt]
    }

    func testFix19HistoryEntriesNormaliseISODatesAndMsDatesAndDropBadRows() {
        // P1-1: the live typed reader only accepts
        // seconds-since-1970 numbers, but Flutter backups
        // carry ISO strings and ms integers — both must
        // normalise, and entries missing a required field must
        // drop, never poison the whole file.
        let iso = videoHistoryEntry(itemId: "v1", title: "測試影片", updatedAt: "2026-11-20T10:00:00.000Z")
        let ms = videoHistoryEntry(itemId: "v2", title: "毫秒影片", updatedAt: 1795000000000)
        let noItem: [String: Any] = ["episodeName": "第1集", "updatedAt": 1795168800]
        let noTitle = videoHistoryEntry(itemId: "v3", title: "", updatedAt: 1795168800)
        let video = MigrationStore.normalizedHistoryEntries([iso, ms, noItem, noTitle], file: "hao_video_hist")
        XCTAssertEqual(video.kept.count, 2)
        XCTAssertEqual(video.dropped, 2)
        XCTAssertEqual((video.kept[0]["updatedAt"] as? NSNumber)?.intValue, 1795168800)
        XCTAssertEqual((video.kept[1]["updatedAt"] as? NSNumber)?.intValue, 1795000000)

        let liveISO = liveHistoryEntry(roomId: "1", watchedAt: "2026-11-20T10:00:00.000Z")
        let liveMS = liveHistoryEntry(roomId: "2", watchedAt: 1795000000000)
        let noRoom = liveHistoryEntry(roomId: "", watchedAt: 1795000000)
        let live = MigrationStore.normalizedHistoryEntries([liveISO, liveMS, noRoom], file: "hao_live_hist")
        XCTAssertEqual(live.kept.count, 2)
        XCTAssertEqual(live.dropped, 1)
        XCTAssertEqual((live.kept[0]["watchedAt"] as? NSNumber)?.intValue, 1795168800)
        XCTAssertEqual((live.kept[1]["watchedAt"] as? NSNumber)?.intValue, 1795000000)
    }

    func testFix19RouteBVideoHistoryISODateImports() {
        // P1-1 at the import level: an ISO-date entry used to
        // fail the whole file's typed decode (quarantine, then
        // the next live write overwrote the imported history).
        let entry = videoHistoryEntry(itemId: "v1", title: "測試影片", updatedAt: "2026-11-20T10:00:00.000Z")
        writeSnapshot(["hao_video_hist": jsonString([entry])])

        let report = runMigration()

        XCTAssertEqual(report.outcome, .migrated)
        let file = readJSONFile("hao_video_hist") as? [[String: Any]]
        XCTAssertEqual(file?.count, 1)
        XCTAssertEqual((file?.first?["updatedAt"] as? NSNumber)?.intValue, 1795168800)
    }

    func testFix19ListKeysContainAllIgnoresTypedRewrite() {
        // P1-2: a live writer round-trips the file through its
        // typed struct (drops unknown fields, normalises the
        // platform code) — the bytes change, the content does
        // not, so the verify must compare identity keys.
        let expectedListen: [[String: Any]] = [
            ["platform": "lx:netease", "songId": "s1", "at": 1700000000000, "dur": 180, "extra": "x"],
        ]
        let actualListen: [[String: Any]] = [
            ["platform": "wy", "songId": "s1", "at": 1700000000000, "dur": 180],
        ]
        XCTAssertTrue(MigrationStore.listKeysContainAll(actual: actualListen, expected: expectedListen, file: "hao_listen"))
        XCTAssertFalse(MigrationStore.listKeysContainAll(actual: [], expected: expectedListen, file: "hao_listen"))

        let expectedFav: [[String: Any]] = [
            ["key": "lx:netease|s1", "song": ["platform": "lx:netease", "songId": "s1"]],
        ]
        let actualFav: [[String: Any]] = [
            ["key": "wy|s1", "song": ["platform": "wy", "songId": "s1"]],
        ]
        XCTAssertTrue(MigrationStore.listKeysContainAll(actual: actualFav, expected: expectedFav, file: "hao_fav"))

        let expectedDownloads: [[String: Any]] = [
            ["song": ["platform": "lx:netease", "songId": "s1"], "quality": "hires"],
        ]
        let actualDownloads: [[String: Any]] = [
            ["song": ["platform": "wy", "songId": "s1"], "quality": "hires"],
        ]
        XCTAssertTrue(MigrationStore.listKeysContainAll(actual: actualDownloads, expected: expectedDownloads, file: "musicDownloads"))
    }

    func testFix19FavMergeKeyDedupesLxAndWy() {
        // P1-3: the same song favourited as lx:… in the backup
        // and wy in live is one favourite, and the merged row
        // carries the normalised key so toggleFav can remove it.
        let lx: [String: Any] = ["key": "lx:netease|s1", "song": ["platform": "lx:netease", "songId": "s1"]]
        let wy: [String: Any] = ["key": "wy|s1", "song": ["platform": "wy", "songId": "s1"]]
        XCTAssertEqual(MigrationStore.favMergeKey(for: lx), MigrationStore.favMergeKey(for: wy))
        XCTAssertEqual(MigrationStore.favMergeKey(for: lx), "wy|s1")

        writeJSONFile("hao_fav", [wy])
        writeSnapshot(["hao_fav": jsonString([lx])])

        let report = runMigration()

        XCTAssertEqual(report.outcome, .migrated)
        let file = readJSONFile("hao_fav") as? [[String: Any]]
        XCTAssertEqual(file?.count, 1)
        XCTAssertEqual(file?.first?["key"] as? String, "wy|s1")
    }

    func testFix19RestoredPreservingLiveKeepsLiveIncrements() {
        // P1-4: a rollback must not wipe live writes made
        // during the import — merged files restore prior +
        // live-added entries, whole files keep the live file
        // when it replaced the import's write.
        func data(_ value: Any) -> Data {
            try! JSONSerialization.data(withJSONObject: value, options: [])
        }
        let prior = data([["id": "a"]])
        let written = data([["id": "a"], ["id": "b"]])
        let current = data([["id": "a"], ["id": "b"], ["id": "c"]])
        let restored = MigrationStore.restoredPreservingLive(prior: prior, written: written, current: current, file: "hao_lists", kind: .mergeList)
        guard case .data(let bytes) = restored else {
            XCTFail("expected .data, got \(restored)")
            return
        }
        let list = try! JSONSerialization.jsonObject(with: bytes, options: []) as? [[String: Any]]
        XCTAssertEqual(list?.compactMap { $0["id"] as? String }, ["a", "c"])

        // Whole file, live untouched since the write: prior bytes.
        let whole = MigrationStore.restoredPreservingLive(prior: data(["a"]), written: data(["b"]), current: data(["b"]), file: "downloadTasks", kind: .wholeFile)
        guard case .data(let oldBytes) = whole else {
            XCTFail("expected .data, got \(whole)")
            return
        }
        XCTAssertEqual(try! JSONSerialization.jsonObject(with: oldBytes, options: []) as? [String], ["a"])
        // Whole file, live replaced the import's write: keep live.
        let kept = MigrationStore.restoredPreservingLive(prior: data(["a"]), written: data(["b"]), current: data(["c"]), file: "downloadTasks", kind: .wholeFile)
        guard case .keepCurrent = kept else {
            XCTFail("expected .keepCurrent, got \(kept)")
            return
        }
    }

    func testFix19RouteBSuccessCarriesWarnings() {
        // P1-5: a dropped history entry on a successful import
        // must be visible in report.warnings (Route A prints
        // them; Route B used to drop them).
        let good = videoHistoryEntry(itemId: "v1", title: "測試影片", updatedAt: "2026-11-20T10:00:00.000Z")
        let bad: [String: Any] = ["episodeName": "第1集", "updatedAt": 1795168800]
        writeSnapshot(["hao_video_hist": jsonString([good, bad])])

        let report = runMigration()

        XCTAssertEqual(report.outcome, .migrated)
        XCTAssertTrue(report.warnings.contains { $0.contains("影视历史") && $0.contains("1") },
                      "warnings were \(report.warnings)")
    }

    func testFix19RecentContainsAllNoBudgetWhenListNotFull() {
        // P1-6: the displacement budget only exists when the
        // list is actually full — an unfull list loses nothing
        // to new inserts, so a cleared-and-replayed list must
        // fail, not pass inside the old tail budget.
        let small = (0..<5).map { recentSong("k\($0)") }
        let replayed = (0..<5).map { recentSong("new-\($0)") }
        XCTAssertFalse(MigrationStore.recentContainsAll(actual: replayed, expected: small))
        // The full-list case still passes with one displaced
        // tail entry (the fix18 behaviour, unchanged).
        let full = (0..<100).map { recentSong("k\($0)") }
        let oneNew = [recentSong("new-1")] + Array(full.prefix(99))
        XCTAssertTrue(MigrationStore.recentContainsAll(actual: oneNew, expected: full))
    }

    func testFix19LyricsCacheOrderKeepsImportedKeysNewest() {
        // P1-7: imported lyrics keys are written into the order
        // file as newest, so the next eviction takes an older
        // key first instead of the imported one.
        defaults.set(["a"], forKey: "hao.lyricsCacheOrder")
        MigrationStore.reconcileLyricsCacheOrder(
            mergedKeys: ["a", "b", "c"], importedKeys: ["b", "c"], defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "hao.lyricsCacheOrder"), ["a", "b", "c"])
        // The eviction record excuses a key a live writer
        // dropped between the merge and the verify.
        MigrationStore.resetCacheEvictionRecord()
        MigrationStore.noteCacheKeyEvicted(file: "hao_lyrics", key: "b")
        XCTAssertTrue(MigrationStore.cacheEvictionRecord(for: "hao_lyrics").contains("b"))
        MigrationStore.resetCacheEvictionRecord()
        XCTAssertTrue(MigrationStore.cacheEvictionRecord(for: "hao_lyrics").isEmpty)
    }

    func testFix19RouteBFiveNewFilesInstall() {
        // P2-1: the five files Route B used to drop into
        // unknown now install like Route A does.
        writeSnapshot([
            "downloadTasks": jsonString([["id": "x"]]),
            "hao_fav_playlists": jsonString(["pl1", "pl2"]),
            "hao_fav_albums": jsonString([["id": "x"]]),
            "hao_fav_artists": jsonString([["id": "x"]]),
            "hao_daily_pool": jsonString(["a": 1]),
        ])

        let report = runMigration()

        XCTAssertEqual(report.outcome, .migrated)
        XCTAssertEqual(report.migratedKeys, 5)
        XCTAssertEqual((readJSONFile("downloadTasks") as? [[String: Any]])?.count, 1)
        XCTAssertEqual(readJSONFile("hao_fav_playlists") as? [String], ["pl1", "pl2"])
        XCTAssertEqual((readJSONFile("hao_fav_albums") as? [[String: Any]])?.count, 1)
        XCTAssertEqual((readJSONFile("hao_fav_artists") as? [[String: Any]])?.count, 1)
        XCTAssertEqual(readJSONFile("hao_daily_pool") as? [String: Any], ["a": 1])
    }

    func testFix19LiveHistoryCapZeroMeansUnlimited() {
        // P2-4: hao_live_hist_limit = 0 is unlimited, not 50.
        XCTAssertEqual(MigrationStore.liveHistoryCap(defaults: defaults), 50)
        defaults.set(0, forKey: "hao_live_hist_limit")
        XCTAssertNil(MigrationStore.liveHistoryCap(defaults: defaults))
        let entries = (0..<60).map { liveHistoryEntry(roomId: "r\($0)", watchedAt: 1795000000000) }
        writeSnapshot(["hao_live_hist": jsonString(entries)])

        let report = runMigration()

        XCTAssertEqual(report.outcome, .migrated)
        XCTAssertEqual((readJSONFile("hao_live_hist") as? [[String: Any]])?.count, 60)
    }

    func testFix19DailyPerSongMergeKeepsLiveSongs() {
        // P2-7: a day's backup list merges song-by-song with
        // the live day instead of replacing the whole day.
        writeJSONFile("hao_daily", ["2026-11-22": [recentSong("live-1")]])
        writeSnapshot(["hao_daily_2026-11-22": jsonString([recentSong("backup-1")])])

        let report = runMigration()

        XCTAssertEqual(report.outcome, .migrated)
        let daily = readJSONFile("hao_daily") as? [String: Any]
        let day = daily?["2026-11-22"] as? [[String: Any]]
        XCTAssertEqual(day?.count, 2)
        XCTAssertEqual(day?.first?["songId"] as? String, "live-1")
        XCTAssertEqual(day?.last?["songId"] as? String, "backup-1")
    }

    // MARK: - b49fix20: in-section verify, stale writers, rollback deletion/change, daily cap, unknown sweep

    func testFix20HistoryDateMicrosecondsAndPureDate() {
        // D22-11: microseconds divide by 1e6 (the old single
        // threshold divided them by 1000, landing in the year
        // 55,000), and a pure date parses instead of falling
        // back to now.
        XCTAssertEqual(MigrationStore.historyDateSeconds(from: 1_700_000_000_000_000), 1_700_000_000)
        XCTAssertEqual(MigrationStore.historyDateSeconds(from: 1_700_000_000_000), 1_700_000_000)
        XCTAssertEqual(MigrationStore.historyDateSeconds(from: 1_700_000_000), 1_700_000_000)
        let pure = MigrationStore.historyDateSeconds(from: "2026-11-25")
        XCTAssertNotNil(pure)
        XCTAssertEqual(pure ?? 0, 1_795_564_800, accuracy: 1)
        XCTAssertNotNil(MigrationStore.historyDateSeconds(from: "2026-11-25T10:00:00Z"))
        XCTAssertNil(MigrationStore.historyDateSeconds(from: "not-a-date"))
    }

    func testFix20MergedDailyDayCapsAtTwentyLiveFirst() {
        // D22-7: a merged day caps at live's 20 (live first,
        // so the excess is always incoming) and the excess is
        // counted, never silently dropped.
        MigrationStore.resetDailyCapDroppedRecord()
        let live = (0..<5).map { recentSong("live-\($0)") }
        let incoming = (0..<25).map { recentSong("in-\($0)") }
        let merged = MigrationStore.mergedDailyDay(live: live, incoming: incoming)
        XCTAssertEqual(merged.count, 20)
        XCTAssertEqual(merged.first?["songId"] as? String, "live-0")
        XCTAssertEqual(merged.last?["songId"] as? String, "in-14")
        XCTAssertEqual(MigrationStore.dailyCapDroppedDuringImport(), 10)
        MigrationStore.resetDailyCapDroppedRecord()
    }

    func testFix20DailyCapWarnsOnImport() {
        // D22-7 at the import level: 5 live + 25 incoming
        // songs on one day merge to 20, and the 10 dropped
        // incoming songs appear in the report warnings.
        writeJSONFile("hao_daily", ["2026-11-22": (0..<5).map { recentSong("live-\($0)") }])
        writeSnapshot(["hao_daily_2026-11-22": jsonString((0..<25).map { recentSong("in-\($0)") })])

        let report = runMigration()

        XCTAssertEqual(report.outcome, .migrated)
        let daily = readJSONFile("hao_daily") as? [String: Any]
        let day = daily?["2026-11-22"] as? [[String: Any]]
        XCTAssertEqual(day?.count, 20)
        XCTAssertTrue(report.warnings.contains { $0.contains("超出每日 20 首上限") },
                      "warnings were \(report.warnings)")
    }

    func testFix20DailyDaysContainAll() {
        // D22-7: the per-day value check passes while the day
        // still holds its songs, and fails when a live
        // overwrite replaced the whole day — the old key-only
        // check passed that silently.
        let day: [String: Any] = ["2026-11-25": [recentSong("a"), recentSong("b")]]
        XCTAssertTrue(MigrationStore.dailyDaysContainAll(actual: day, expected: day))
        let replaced: [String: Any] = ["2026-11-25": [recentSong("x"), recentSong("y")]]
        XCTAssertFalse(MigrationStore.dailyDaysContainAll(actual: replaced, expected: day))
    }

    func testFix20ListKeysContainAllSecondaryKey() {
        // D22-6: a live rewrite that adds a songId changes the
        // primary key; the secondary title+artist key still
        // matches the same song.
        let expected: [[String: Any]] = [
            ["key": "wy|", "song": ["platform": "wy", "songId": "", "title": "T", "artist": "A"]],
        ]
        let actual: [[String: Any]] = [
            ["key": "wy|s1", "song": ["platform": "wy", "songId": "s1", "title": "T", "artist": "A"]],
        ]
        XCTAssertTrue(MigrationStore.listKeysContainAll(actual: actual, expected: expected, file: "hao_fav"))
        let other: [[String: Any]] = [
            ["key": "wy|", "song": ["platform": "wy", "songId": "", "title": "Other", "artist": "A"]],
        ]
        XCTAssertFalse(MigrationStore.listKeysContainAll(actual: actual, expected: other, file: "hao_fav"))
    }

    func testFix20RestoredPreservingLiveKeepsLiveDeletionAndChange() {
        // D22-4: a rollback must not resurrect a live deletion
        // or revert a live value change.
        func data(_ value: Any) -> Data {
            try! JSONSerialization.data(withJSONObject: value, options: [])
        }
        // List: live-deleted "b" stays deleted.
        let deleted = MigrationStore.restoredPreservingLive(
            prior: data([["id": "a"], ["id": "b"]]),
            written: data([["id": "a"], ["id": "b"]]),
            current: data([["id": "a"]]),
            file: "hao_lists", kind: .mergeList)
        guard case .data(let deletedBytes) = deleted else {
            XCTFail("expected .data, got \(deleted)")
            return
        }
        let deletedList = try! JSONSerialization.jsonObject(with: deletedBytes, options: []) as? [[String: Any]]
        XCTAssertEqual(deletedList?.compactMap { $0["id"] as? String }, ["a"])
        // List: a live-changed value takes the live value.
        let changed = MigrationStore.restoredPreservingLive(
            prior: data([["id": "a", "v": 1]]),
            written: data([["id": "a", "v": 2]]),
            current: data([["id": "a", "v": 3]]),
            file: "hao_lists", kind: .mergeList)
        guard case .data(let changedBytes) = changed else {
            XCTFail("expected .data, got \(changed)")
            return
        }
        let changedList = try! JSONSerialization.jsonObject(with: changedBytes, options: []) as? [[String: Any]]
        XCTAssertEqual(changedList?.first?["v"] as? Int, 3)
        // Dict: live-deleted "b" stays deleted, untouched "a" rolls back.
        let dict = MigrationStore.restoredPreservingLive(
            prior: data(["a": 1, "b": 1]),
            written: data(["a": 2, "b": 1]),
            current: data(["a": 2]),
            file: "hao_cover_cache", kind: .mergeDict)
        guard case .data(let dictBytes) = dict else {
            XCTFail("expected .data, got \(dict)")
            return
        }
        XCTAssertEqual(try! JSONSerialization.jsonObject(with: dictBytes, options: []) as? [String: Int], ["a": 1])
        // String list: live-deleted "b" stays deleted.
        let strings = MigrationStore.restoredPreservingLive(
            prior: data(["a", "b"]),
            written: data(["a", "b"]),
            current: data(["a"]),
            file: "hao_music_search_hist", kind: .mergeStringList)
        guard case .data(let stringBytes) = strings else {
            XCTFail("expected .data, got \(strings)")
            return
        }
        XCTAssertEqual(try! JSONSerialization.jsonObject(with: stringBytes, options: []) as? [String], ["a"])
    }

    func testFix20TrimmedCoverCacheKeepsIncomingFirst() {
        // D22-9: a merged cover cache trims to 500, incoming
        // keys first.
        var merged: [String: Any] = [:]
        for i in 0..<400 { merged["live-\(i)"] = "u" }
        for i in 0..<200 { merged["in-\(i)"] = "u" }
        let trimmed = MigrationStore.trimmedCoverCache(
            merged: merged, incomingKeys: Set((0..<200).map { "in-\($0)" }))
        XCTAssertEqual(trimmed.count, 500)
        XCTAssertTrue((0..<200).allSatisfy { trimmed["in-\($0)"] != nil })
    }

    func testFix20UnknownKeysSweptAfterImport() {
        // D22-8: keys that gained a mapping row leave the old
        // unknown-keys file after a successful import;
        // unmapped keys stay.
        writeJSONFile("migration_unknown_keys", ["downloadTasks": [["id": "x"]], "weird_key": ["v"]])
        writeSnapshot(["downloadTasks": jsonString([["id": "y"]])])

        let report = runMigration()

        XCTAssertEqual(report.outcome, .migrated)
        let unknown = readJSONFile("migration_unknown_keys") as? [String: Any]
        XCTAssertNil(unknown?["downloadTasks"])
        XCTAssertNotNil(unknown?["weird_key"])
    }

    func testFix20FailReportCarriesWarnings() {
        // D22-12: plan-time warnings (e.g. dropped history
        // entries) survive into the failure report instead of
        // only appearing on success.
        let report = MigrationStore.failReport(
            total: 5, migrated: 1, skipped: [], unknown: [],
            detail: "write failed",
            warnings: ["影视历史有 1 条记录格式不符，已跳过"])
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertEqual(report.warnings, ["影视历史有 1 条记录格式不符，已跳过"])
    }

    func testFix21WholeFileSubsetVerifies() {
        // D23-1: the final sweep subsets whole-file files by
        // shape — a live writer that merged-preserved the
        // import's content changes the bytes without losing
        // anything, so byte equality must not fail the import.
        // Resolver dict: key-only, a live-changed value and a
        // live-added key still pass.
        writeJSONFile("hao_resolver_speed",
                      ["wy": ["avg": 999], "qq": ["avg": 300], "lx": ["avg": 50]])
        XCTAssertTrue(MigrationStore.wholeFileSubsetVerifies(
            name: "hao_resolver_speed",
            expected: ["wy": ["avg": 120], "qq": ["avg": 300]] as [String: Any],
            documentsURL: docs))
        XCTAssertFalse(MigrationStore.wholeFileSubsetVerifies(
            name: "hao_resolver_speed",
            expected: ["wy": ["avg": 120], "missing": ["avg": 1]] as [String: Any],
            documentsURL: docs))
        // Download tasks: identity is request.key, so a live
        // typed round-trip that drops an unknown field still
        // passes.
        writeJSONFile("downloadTasks", [["request": ["key": "k1"]]])
        XCTAssertTrue(MigrationStore.wholeFileSubsetVerifies(
            name: "downloadTasks",
            expected: [["request": ["key": "k1"], "extra": "x"]],
            documentsURL: docs))
        XCTAssertFalse(MigrationStore.wholeFileSubsetVerifies(
            name: "downloadTasks",
            expected: [["request": ["key": "k1"]], ["request": ["key": "k2"]]],
            documentsURL: docs))
        // Video favourites identify by id, not bytes.
        writeJSONFile("hao_video_fav", [["id": "v1"]])
        XCTAssertTrue(MigrationStore.wholeFileSubsetVerifies(
            name: "hao_video_fav",
            expected: [["id": "v1", "title": "T"]],
            documentsURL: docs))
        // Search histories are string subsets.
        writeJSONFile("hao_video_search_hist", ["a", "b", "c"])
        XCTAssertTrue(MigrationStore.wholeFileSubsetVerifies(
            name: "hao_video_search_hist", expected: ["a", "b"], documentsURL: docs))
        XCTAssertFalse(MigrationStore.wholeFileSubsetVerifies(
            name: "hao_video_search_hist", expected: ["a", "z"], documentsURL: docs))
        // Scalars fall back to value equality.
        try! Data("5".utf8).write(to: docs.appendingPathComponent("hao_test_scalar.json"),
                                  options: [.atomic])
        XCTAssertTrue(MigrationStore.wholeFileSubsetVerifies(
            name: "hao_test_scalar", expected: 5, documentsURL: docs))
        XCTAssertFalse(MigrationStore.wholeFileSubsetVerifies(
            name: "hao_test_scalar", expected: 6, documentsURL: docs))
    }

    func testFix21MergedDailyDayNeverTruncatesLive() {
        // D23-7: the cap is max(20, live count) — a live day
        // longer than 20 (left by a fix19 no-cap import) is
        // never truncated, and the dropped count is the incoming
        // entries past the live-sized cap, by identity.
        MigrationStore.resetDailyCapDroppedRecord()
        let live25 = (0..<25).map { recentSong("live-\($0)") }
        let incoming5 = (0..<5).map { recentSong("in-\($0)") }
        let kept = MigrationStore.mergedDailyDay(live: live25, incoming: incoming5)
        XCTAssertEqual(kept.count, 25)
        XCTAssertEqual(kept.last?["songId"] as? String, "live-24")
        XCTAssertEqual(MigrationStore.dailyCapDroppedDuringImport(), 5)
        MigrationStore.resetDailyCapDroppedRecord()
        let keptNoIncoming = MigrationStore.mergedDailyDay(live: live25, incoming: [])
        XCTAssertEqual(keptNoIncoming.count, 25)
        XCTAssertEqual(MigrationStore.dailyCapDroppedDuringImport(), 0)
        MigrationStore.resetDailyCapDroppedRecord()
        // An incoming song deduped against a live song (same
        // songId under the lx: prefix) is not a drop.
        let dup = MigrationStore.mergedDailyDay(
            live: live25,
            incoming: [["platform": "lx:netease", "songId": "live-0",
                        "title": "tlive-0", "artist": "a", "album": ""]])
        XCTAssertEqual(dup.count, 25)
        XCTAssertEqual(MigrationStore.dailyCapDroppedDuringImport(), 0)
        MigrationStore.resetDailyCapDroppedRecord()
        // With a small live day the 20 cap still applies.
        let big = MigrationStore.mergedDailyDay(
            live: [], incoming: (0..<30).map { recentSong("in-\($0)") })
        XCTAssertEqual(big.count, 20)
        XCTAssertEqual(MigrationStore.dailyCapDroppedDuringImport(), 10)
        MigrationStore.resetDailyCapDroppedRecord()
    }

    func testFix21ListenLightProof() {
        // D23-8: the hao_listen in-section verify is a light
        // proof (count + head/tail identity); the full subset
        // stays at the final sweep, so a middle change passes
        // here and is caught there.
        func listen(_ id: String, at: Int) -> [String: Any] {
            ["platform": "wy", "songId": id, "at": at]
        }
        let expected = (0..<3000).map { listen("s\($0)", at: $0) }
        XCTAssertTrue(MigrationStore.listenLightProof(actual: expected, expected: expected))
        var middleChanged = expected
        middleChanged[1500] = listen("other", at: 1500)
        XCTAssertTrue(MigrationStore.listenLightProof(actual: middleChanged, expected: expected))
        XCTAssertFalse(MigrationStore.listenLightProof(
            actual: Array(expected.dropLast()), expected: expected))
        var headChanged = expected
        headChanged[0] = listen("other", at: 0)
        XCTAssertFalse(MigrationStore.listenLightProof(actual: headChanged, expected: expected))
        var tailChanged = expected
        tailChanged[2999] = listen("other", at: 2999)
        XCTAssertFalse(MigrationStore.listenLightProof(actual: tailChanged, expected: expected))
    }

    func testFix21RestoredPreservingLiveUsesLiveAtMerge() {
        // D23-6: the rollback takes the live value at merge
        // time, so a live change in the snapshot -> merge-read
        // window is preserved instead of reverted to prior.
        func data(_ value: Any) -> Data {
            try! JSONSerialization.data(withJSONObject: value, options: [])
        }
        func ids(_ result: MigrationStore.RestoredFile) -> [String]? {
            guard case .data(let bytes) = result else { return nil }
            let list = try! JSONSerialization.jsonObject(with: bytes, options: []) as? [[String: Any]]
            return list?.compactMap { $0["id"] as? String }
        }
        // A prior entry the import wrote but live had already
        // deleted before the merge read stays deleted.
        XCTAssertEqual(ids(MigrationStore.restoredPreservingLive(
            prior: data([["id": "a"], ["id": "b"]]),
            written: data([["id": "a"], ["id": "b"], ["id": "c"]]),
            current: data([["id": "a"], ["id": "b"], ["id": "c"]]),
            file: "hao_lists", kind: .mergeList,
            liveAtMerge: data([["id": "b"]]))), ["b"])
        // A cap-dropped entry live-changed before the merge read
        // restores with the merge-time live value, not prior.
        let capDropped = MigrationStore.restoredPreservingLive(
            prior: data([["id": "a", "v": 1], ["id": "x", "v": 1]]),
            written: data([["id": "a", "v": 1]]),
            current: data([["id": "a", "v": 1]]),
            file: "hao_lists", kind: .mergeList,
            liveAtMerge: data([["id": "a", "v": 1], ["id": "x", "v": 2]]))
        guard case .data(let capBytes) = capDropped else {
            XCTFail("expected .data, got \(capDropped)")
            return
        }
        let capList = try! JSONSerialization.jsonObject(with: capBytes, options: []) as? [[String: Any]]
        XCTAssertEqual(capList?.first { ($0["id"] as? String) == "x" }?["v"] as? Int, 2)
        // Without liveAtMerge the old rule applies unchanged.
        let fallback = MigrationStore.restoredPreservingLive(
            prior: data([["id": "a", "v": 1], ["id": "x", "v": 1]]),
            written: data([["id": "a", "v": 1]]),
            current: data([["id": "a", "v": 1]]),
            file: "hao_lists", kind: .mergeList)
        guard case .data(let fallbackBytes) = fallback else {
            XCTFail("expected .data, got \(fallback)")
            return
        }
        let fallbackList = try! JSONSerialization.jsonObject(with: fallbackBytes, options: []) as? [[String: Any]]
        XCTAssertEqual(fallbackList?.first { ($0["id"] as? String) == "x" }?["v"] as? Int, 1)
    }

    func testFix23RestoredPreservingLiveKeepsLiveAdditionAlsoInstalled() {
        // D25-1: rollback keeps a live addition the import ALSO
        // installed — the three merge branches can tell it apart
        // from the import's install alone (current != written,
        // or live had it at merge time). The D24-6 residual
        // (current == written, live never had it) still drops.
        func data(_ value: Any) -> Data {
            try! JSONSerialization.data(withJSONObject: value, options: [])
        }
        func ids(_ result: MigrationStore.RestoredFile) -> [String]? {
            guard case .data(let bytes) = result else { return nil }
            let list = try! JSONSerialization.jsonObject(with: bytes, options: []) as? [[String: Any]]
            return list?.compactMap { $0["id"] as? String }
        }
        func dict(_ result: MigrationStore.RestoredFile) -> [String: Any]? {
            guard case .data(let bytes) = result else { return nil }
            return try! JSONSerialization.jsonObject(with: bytes, options: []) as? [String: Any]
        }
        func strings(_ result: MigrationStore.RestoredFile) -> [String]? {
            guard case .data(let bytes) = result else { return nil }
            return try! JSONSerialization.jsonObject(with: bytes, options: []) as? [String]
        }
        // LIST — live had the new entry at merge time (written
        // IS the live value): kept.
        XCTAssertEqual(ids(MigrationStore.restoredPreservingLive(
            prior: data([["id": "a"]]),
            written: data([["id": "a"], ["id": "c"]]),
            current: data([["id": "a"], ["id": "c"]]),
            file: "hao_lists", kind: .mergeList,
            liveAtMerge: data([["id": "a"], ["id": "c"]]))), ["a", "c"])
        // LIST — live changed it after the merge read: the
        // current value is kept.
        let changed = MigrationStore.restoredPreservingLive(
            prior: data([["id": "a"]]),
            written: data([["id": "a"], ["id": "c", "v": 1]]),
            current: data([["id": "a"], ["id": "c", "v": 9]]),
            file: "hao_lists", kind: .mergeList,
            liveAtMerge: data([["id": "a"]]))
        guard case .data(let changedBytes) = changed else {
            XCTFail("expected .data, got \(changed)")
            return
        }
        let changedList = try! JSONSerialization.jsonObject(with: changedBytes, options: []) as? [[String: Any]]
        XCTAssertEqual(changedList?.first { ($0["id"] as? String) == "c" }?["v"] as? Int, 9)
        // LIST — D24-6 boundary: live never had it, current
        // still equals written: dropped.
        XCTAssertEqual(ids(MigrationStore.restoredPreservingLive(
            prior: data([["id": "a"]]),
            written: data([["id": "a"], ["id": "c"]]),
            current: data([["id": "a"], ["id": "c"]]),
            file: "hao_lists", kind: .mergeList,
            liveAtMerge: data([["id": "a"]]))), ["a"])
        // DICT — the dict merge is incoming-wins, so written is
        // the backup's value; the merge-time live value is
        // restored.
        XCTAssertEqual(dict(MigrationStore.restoredPreservingLive(
            prior: data(["a": 1]),
            written: data(["a": 1, "b": 9]),
            current: data(["a": 1, "b": 9]),
            file: "musicResume", kind: .mergeDict,
            liveAtMerge: data(["a": 1, "b": 7])))?["b"] as? Int, 7)
        // DICT — D24-6 boundary: live never had it, current
        // still equals written: dropped.
        XCTAssertNil(dict(MigrationStore.restoredPreservingLive(
            prior: data(["a": 1]),
            written: data(["a": 1, "b": 9]),
            current: data(["a": 1, "b": 9]),
            file: "musicResume", kind: .mergeDict,
            liveAtMerge: data(["a": 1])))?["b"])
        // STRING LIST — live had it at merge time: kept.
        XCTAssertEqual(strings(MigrationStore.restoredPreservingLive(
            prior: data(["a"]),
            written: data(["a", "c"]),
            current: data(["a", "c"]),
            file: "hao_fav_playlists", kind: .mergeStringList,
            liveAtMerge: data(["a", "c"]))), ["a", "c"])
        // STRING LIST — D24-6 boundary: live never had it:
        // dropped.
        XCTAssertEqual(strings(MigrationStore.restoredPreservingLive(
            prior: data(["a"]),
            written: data(["a", "c"]),
            current: data(["a", "c"]),
            file: "hao_fav_playlists", kind: .mergeStringList,
            liveAtMerge: data(["a"]))), ["a"])
    }

    func testFix21UnknownKeysSweepKeepsUninstalledKeys() {
        // D23-5: the unknown-keys sweep only clears keys THIS
        // import installed. A backup without downloadTasks
        // leaves its isolated record alone — the unknown file
        // may be its only copy.
        writeJSONFile("migration_unknown_keys",
                      ["downloadTasks": [["id": "x"]], "weird_key": ["v"]])
        writeSnapshot(["hao_fav_playlists": jsonString(["p1", "p2"])])

        let report = runMigration()

        XCTAssertEqual(report.outcome, .migrated)
        let installed = readJSONFile("hao_fav_playlists") as? [String]
        XCTAssertEqual(installed, ["p1", "p2"])
        let unknown = readJSONFile("migration_unknown_keys") as? [String: Any]
        XCTAssertNotNil(unknown?["downloadTasks"])
        XCTAssertNotNil(unknown?["weird_key"])
    }

    func testFix21JournalRestoreDefaultsGuard() {
        // D23-9: the rollback restores only defaults this
        // attempt actually wrote + verified, and keeps the live
        // value when current != written (same rule as files).
        // (a) Live changed after the write: keepCurrent.
        var journal = MigrationJournal()
        journal.recordDefault(key: "k1", defaults: defaults)
        defaults.set(2, forKey: "k1")
        journal.recordWrittenDefault(key: "k1", value: 2)
        defaults.set(3, forKey: "k1")
        let kept = journal.restore(documentsURL: docs, defaults: defaults)
        XCTAssertEqual(kept.keptLiveDefaults, ["k1"])
        XCTAssertEqual(defaults.integer(forKey: "k1"), 3)
        // (b) Unchanged since the write: restored to prior.
        var journal2 = MigrationJournal()
        defaults.set(1, forKey: "k2")
        journal2.recordDefault(key: "k2", defaults: defaults)
        defaults.set(2, forKey: "k2")
        journal2.recordWrittenDefault(key: "k2", value: 2)
        let restored = journal2.restore(documentsURL: docs, defaults: defaults)
        XCTAssertTrue(restored.keptLiveDefaults.isEmpty)
        XCTAssertEqual(defaults.integer(forKey: "k2"), 1)
        // (c) Recorded but never written + verified: not restored.
        var journal3 = MigrationJournal()
        defaults.set(5, forKey: "k3")
        journal3.recordDefault(key: "k3", defaults: defaults)
        defaults.set(9, forKey: "k3")
        let skipped = journal3.restore(documentsURL: docs, defaults: defaults)
        XCTAssertTrue(skipped.keptLiveDefaults.isEmpty)
        XCTAssertEqual(defaults.integer(forKey: "k3"), 9)
        // (d) Prior absent + written + unchanged: removed.
        var journal4 = MigrationJournal()
        journal4.recordDefault(key: "k4", defaults: defaults)
        defaults.set(2, forKey: "k4")
        journal4.recordWrittenDefault(key: "k4", value: 2)
        let removed = journal4.restore(documentsURL: docs, defaults: defaults)
        XCTAssertTrue(removed.keptLiveDefaults.isEmpty)
        XCTAssertNil(defaults.object(forKey: "k4"))
    }

    func testFix21ResolverBackfillAfterImport() {
        // D23-3: a cooldown created before the import learns the
        // imported speeds at the next save — no restart needed.
        // `now` is frozen so record() never trips the auto-save
        // threshold mid-test.
        let cooldown = ResolverCooldown(documentsDirectory: docs)
        cooldown.now = { Date(timeIntervalSince1970: 1_700_000_000) }
        XCTAssertEqual(cooldown.averageMs("wy"), ResolverCooldown.unknownSpeedMs)
        // Simulate the import installing speeds on disk.
        writeJSONFile("hao_resolver_speed",
                      ["wy": ["avg": 120, "fails": 2, "cooled": 1_795_000_000_000],
                       "qq": ["avg": 300]])
        cooldown.saveNow()
        XCTAssertEqual(cooldown.averageMs("wy"), 120)
        XCTAssertEqual(cooldown.averageMs("qq"), 300)
        XCTAssertEqual(cooldown.fails["wy"], 2)
        XCTAssertNotNil(cooldown.cooledUntil["wy"])
        // Memory-known keys still win disk.
        cooldown.record("lx", outcome: .success, milliseconds: 200)
        XCTAssertEqual(cooldown.averageMs("lx"), 200)
        writeJSONFile("hao_resolver_speed",
                      ["lx": ["avg": 50], "wy": ["avg": 120]])
        cooldown.saveNow()
        XCTAssertEqual(cooldown.averageMs("lx"), 200)
    }
}

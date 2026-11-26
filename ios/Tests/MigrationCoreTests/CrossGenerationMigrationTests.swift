// HAo Studio 2.0 — cross-generation migration tests (S6, C leg).
//
// Builds a Flutter 1.1.6 build 32 snapshot fixture from the real
// mapping table in MigrationStore (never a hand-copied list), runs
// the S1 migration, and asserts every snapshot key lands in the 2.0
// location the mapping table promises. The fixture shape mirrors
// ios/Tests/simulate_upgrade.py, which proves the same table at the
// file level; these tests prove the Swift code itself.
//
// A corrupt snapshot skips migration, starts on defaults, and raises
// the My-page notice flag instead of crashing.

import Foundation
import XCTest

@testable import AppCore

final class CrossGenerationMigrationTests: XCTestCase {
    private var docs: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.haostudio.crossgen.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        docs = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-crossgen-tests-\(UUID().uuidString)")
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

    // MARK: - Fixture

    /// Keys whose JSON value is a list, not a dict. Same set as
    /// simulate_upgrade.py; a list key given a dict value would
    /// still migrate, but the fixture mirrors real Flutter shapes.
    /// b49fix17 P1-4: musicResume is NOT here — it is a dict
    /// {identityKey: seconds} (docs/storage-mapping.md:105;
    /// 2.0's resumeMap() only reads a dict). The old set listed
    /// it only because the generator sampled [{"id":"x"}] for
    /// every .json key, not a real Flutter shape.
    private static let jsonListKeys: Set<String> = [
        "hao_lists", "hao_fav", "hao_recent", "hao_listen",
        "hao_music_search_hist", "hao_cover_cache", "hao_lyrics",
        "musicQueue", "musicDownloads", "fmDislikedIds",
        "hao_music_loudness_cache",
        "hao_local_music",
        "hao_resolver_speed",
        "hao_video_category_prefs", "hao_vod_skip_intro_durations",
        "hao_video_home", "hao_video_hist", "hao_video_fav",
        "hao_video_search_hist", "hao_douban_detail", "hao_douban_idmap",
        "hao_sa_video", "hao_live_sources",
        "hao_live_hist", "hao_live_follows", "hao_live_search_hist",
        "hao_danmaku_enabled", "hao_dm_block",
        "hao_lx_disabled", "hao_lx_explicit_enabled", "hao_lx_custom",
        "hao_lx_deleted_bundled", "hao_lx_order", "hao_eq_custom_presets",
        "hao_wallpaper_paths",
        // b49fix19 P2-1: the five new mappings are list-shaped
        // (downloadTasks and the two fav collections); their
        // samples must be lists or the plan shape check skips
        // them and the migrated count lands one short each.
        "hao_fav_albums", "hao_fav_artists", "downloadTasks",
    ]

    /// Prefix-family members: 3 per family, same values as
    /// simulate_upgrade.py.
    private static let familyMembers: [(String, Any)] = [
        ("haoVodProg:cms:vod42", 1234.5),
        ("haoVodProg:emby:ep7", 300),
        ("haoVodProg:cms:vod43", 60),
        ("hao_daily_2026-11-22", "{\"picks\":[\"a\"]}"),
        ("hao_daily_2026-11-23", "{\"picks\":[\"b\"]}"),
        ("hao_daily_2026-11-21", "{\"picks\":[\"c\"]}"),
        ("hao_listen_2026-10", "[{\"at\":1698000000000,\"dur\":180}]"),
        ("hao_listen_2026-11", "[{\"at\":1700000000000,\"dur\":200}]"),
        ("hao_listen_2026-09", "[{\"at\":1695000000000,\"dur\":90}]"),
    ]

    /// Play-URL cache entries: deliberately not migrated, expired by
    /// construction, so they are skipped, never carried over.
    private static let ignoredKeys: [(String, Any)] = [
        ("hao_play_url_cache:song1|wy|hires", "{\"url\":\"https://cdn.example/x.mp3\"}"),
        ("hao_play_url_cache:song2|kg|320k", "{\"url\":\"https://cdn.example/y.mp3\"}"),
    ]

    /// Keys no 1.1.6 build knows: isolated, never dropped.
    private static let unknownKeys: [(String, Any)] = [
        ("hao_future_feature_flag", "keep me"),
        ("hao_unknown_2027_key", "keep me"),
        ("custom_plugin_key", "keep me"),
    ]

    private static let embyConfig: [String: Any] = [
        "baseUrl": "http://192.168.1.10:8096",
        "apiKey": "test-api-key-123",
        "userId": "u1",
        "enabled": true,
        "movieLibraryId": "m1",
        "tvLibraryId": "t1",
    ]

    private struct Fixture {
        let data: [String: Any]
        let expectedFiles: [String: Any]
    }

    private func jsonString(_ value: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [])
        return String(data: data, encoding: .utf8)!
    }

    private func parsedJSON(_ value: Any) -> Any {
        if let text = value as? String,
           let data = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: []) {
            return parsed
        }
        return value
    }

    /// One plausible snapshot value per mapping row. String-encoded
    /// JSON mirrors Hive, where collections are JSON strings.
    private func snapshotValue(for mapping: MigrationKeyMapping) -> Any {
        if mapping.key == "hao_emby_config" {
            return jsonString(Self.embyConfig)
        }
        if mapping.key == "hao_local_music" {
            return jsonString(["local_music/b.mp3"])
        }
        if mapping.key == "hao_wallpaper_paths" {
            return jsonString(["wallpapers/w.png"])
        }
        if mapping.key == "hao_lists" {
            return jsonString([["id": "pl1", "name": "收藏"]])
        }
        if mapping.key == "hao_eq_band_gains" {
            return [0.5, -1.0, 0, 0, 0, 0, 0, 0, 0, 0]
        }
        // b49fix19 P1-1: real Flutter shapes for the two
        // history files — an ISO date for video, an ms date
        // for live — so the plan-time normalisation is
        // exercised (the generic [{"id":"x"}] sample would be
        // dropped by the normaliser and the expected file
        // would never match).
        if mapping.key == "hao_video_hist" {
            return jsonString([[
                "item": ["id": "v1", "title": "測試影片", "year": "2024"],
                "episodeName": "第1集", "episodeIndex": 0, "lineName": "線路1",
                "positionSeconds": 120, "durationSeconds": 3600,
                "updatedAt": "2026-11-20T10:00:00.000Z",
            ]])
        }
        if mapping.key == "hao_live_hist" {
            return jsonString([[
                "platform": "bilibili", "roomId": "123", "title": "測試直播",
                "nick": "主播", "cover": "https://example.com/c.jpg",
                "watchedAt": 1795000000000,
            ]])
        }
        // b49fix19 P2-1: hao_fav_playlists is a string list —
        // the generic .json dict sample {"a": 1} fails its
        // shape check and the file would never install.
        if mapping.key == "hao_fav_playlists" {
            return jsonString(["pl1", "pl2"])
        }
        switch mapping.kind {
        case .string:
            return "sample"
        case .int:
            return 42
        case .double:
            return 1.5
        case .bool:
            return true
        case .json:
            if Self.jsonListKeys.contains(mapping.key) {
                return jsonString([["id": "x"]])
            }
            return jsonString(["a": 1])
        case .intList:
            return [1, 2, 3]
        case .doubleList:
            return [0.5, -1.0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .data:
            // b49fix32: .data travels base64 in the JSON envelope
            // (MigrationKeyKind, b49fix2 P1-4; coerce() encodes Data
            // to base64 on export). No mapping is .data yet, but
            // return the envelope form so the arm is real if one is.
            return Data("sample".utf8).base64EncodedString()
        }
    }

    /// Builds the full 1.1.6 build 32 snapshot: 117 named keys + 9
    /// family members + 2 ignored cache keys + 3 unknown keys = 131.
    /// expectedFiles holds what each collection file must contain
    /// after migration, including the merged prefix families.
    private func buildFixture() -> Fixture {
        var data: [String: Any] = [:]
        var expectedFiles: [String: Any] = [:]
        for mapping in MigrationStore.mappings {
            let value = snapshotValue(for: mapping)
            data[mapping.key] = value
            switch mapping.destination {
            case .collectionFile(let name):
                expectedFiles[name] = parsedJSON(value)
            case .emby:
                var config = Self.embyConfig
                config.removeValue(forKey: "apiKey")
                expectedFiles["hao_emby_config"] = config
            case .userDefaults:
                break
            }
        }
        var vodProg: [String: Any] = [:]
        var daily: [String: Any] = [:]
        var listen: [[String: Any]] = []
        // b49fix19: the mapping loop above samples the RAW
        // snapshot values, but three files are transformed by
        // the merge — the expected values are the TRANSFORMED
        // ones. History dates normalise (P1-1: ISO string and
        // ms integer both become seconds), and hao_fav merges
        // with the pre-existing live file (buildFakeFlutterDocuments
        // writes [["key": "old-song"]]; since fix18 D-1 Route B
        // merges instead of whole-file overwriting, the actual
        // file is live-first + incoming).
        expectedFiles["hao_video_hist"] = [[
            "item": ["id": "v1", "title": "測試影片", "year": "2024"],
            "episodeName": "第1集", "episodeIndex": 0, "lineName": "線路1",
            "positionSeconds": 120, "durationSeconds": 3600,
            "updatedAt": 1795168800,
        ]]
        expectedFiles["hao_live_hist"] = [[
            "platform": "bilibili", "roomId": "123", "title": "測試直播",
            "nick": "主播", "cover": "https://example.com/c.jpg",
            "watchedAt": 1795000000,
        ]]
        expectedFiles["hao_fav"] = [["key": "old-song"], ["id": "x"]]
        for member in Self.familyMembers.sorted(by: { $0.0 < $1.0 }) {
            data[member.0] = member.1
            if member.0.hasPrefix("haoVodProg:") {
                vodProg[member.0] = member.1
            } else if member.0.hasPrefix("hao_daily_") {
                daily[member.0] = parsedJSON(member.1)
            } else if member.0.hasPrefix("hao_listen_") {
                if let entries = parsedJSON(member.1) as? [[String: Any]] {
                    listen.append(contentsOf: entries)
                }
            }
        }
        expectedFiles["haoVodProg"] = vodProg
        expectedFiles["hao_daily"] = daily
        var listenExpected = (expectedFiles["hao_listen"] as? [[String: Any]]) ?? []
        listenExpected.append(contentsOf: listen)
        expectedFiles["hao_listen"] = listenExpected
        for ignored in Self.ignoredKeys {
            data[ignored.0] = ignored.1
        }
        var unknown: [String: Any] = [:]
        for entry in Self.unknownKeys {
            data[entry.0] = entry.1
            unknown[entry.0] = entry.1
        }
        expectedFiles[MigrationStore.unknownKeysFileName] = unknown
        return Fixture(data: data, expectedFiles: expectedFiles)
    }

    private func writeSnapshot(_ data: [String: Any], schema: Int = 1, appVersion: String? = "1.1.6", appBuild: Int = 32) {
        var root: [String: Any] = [
            "schema": schema,
            "app": "HAo Studio",
            "data": data,
        ]
        if let version = appVersion {
            root["appVersion"] = version
            root["appBuild"] = appBuild
        }
        root["exportedAt"] = "2026-11-23T00:00:00.000Z"
        root["entries"] = data.count
        let json = try! JSONSerialization.data(withJSONObject: root, options: [])
        try! json.write(to: docs.appendingPathComponent("migration_snapshot.json"), options: [.atomic])
    }

    private func writeSnapshotRaw(_ text: String) {
        try! text.write(to: docs.appendingPathComponent("migration_snapshot.json"), atomically: true, encoding: .utf8)
    }

    private func readJSONFile(_ name: String) -> Any? {
        let url = docs.appendingPathComponent("\(name).json")
        guard let raw = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: raw, options: [])
    }

    /// Builds the fake 1.1.6 Documents directory an overwrite
    /// install would leave: a Hive box, the four user-file subdirs,
    /// and a pre-existing Swift collection file the migration must
    /// back up, not merge into.
    private func buildFakeFlutterDocuments() {
        let hiveBytes = Data("fake hive box bytes".utf8)
        try! hiveBytes.write(to: docs.appendingPathComponent("app_settings.hive"), options: [.atomic])
        for pair in [("music_downloads", "a.mp3"), ("local_music", "b.mp3"), ("wallpapers", "w.png"), ("fonts", "f.ttf")] {
            let dir = docs.appendingPathComponent(pair.0)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try! Data("fake file bytes".utf8).write(to: dir.appendingPathComponent(pair.1), options: [.atomic])
        }
        try! jsonString([["key": "old-song"]]).write(to: docs.appendingPathComponent("hao_fav.json"), atomically: true, encoding: .utf8)
    }

    // MARK: - Assertion helpers

    private func canonicalJSONData(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func assertJSONEqual(_ actual: Any?, _ expected: Any, label: String, file: StaticString = #file, line: UInt = #line) {
        guard let actual = actual else {
            XCTFail("missing JSON value for \(label)", file: file, line: line)
            return
        }
        guard let actualData = canonicalJSONData(actual), let expectedData = canonicalJSONData(expected) else {
            XCTFail("values for \(label) are not JSON objects", file: file, line: line)
            return
        }
        XCTAssertEqual(actualData, expectedData, "\(label) mismatch", file: file, line: line)
    }

    private func assertDefaultScalar(key: String, kind: MigrationKeyKind, expected: Any, file: StaticString = #file, line: UInt = #line) {
        guard let stored = defaults.object(forKey: key) else {
            XCTFail("missing UserDefaults key \(key)", file: file, line: line)
            return
        }
        switch kind {
        case .string:
            XCTAssertEqual(stored as? String, expected as? String, "key \(key)", file: file, line: line)
        case .int:
            guard let number = stored as? NSNumber else {
                XCTFail("key \(key) is not a number", file: file, line: line)
                return
            }
            XCTAssertNotEqual(CFGetTypeID(number), CFBooleanGetTypeID(), "key \(key) must not be a bool", file: file, line: line)
            XCTAssertEqual(number.intValue, (expected as? NSNumber)?.intValue, "key \(key)", file: file, line: line)
        case .double:
            guard let number = stored as? NSNumber else {
                XCTFail("key \(key) is not a number", file: file, line: line)
                return
            }
            XCTAssertNotEqual(CFGetTypeID(number), CFBooleanGetTypeID(), "key \(key) must not be a bool", file: file, line: line)
            XCTAssertEqual(number.doubleValue, (expected as? NSNumber)?.doubleValue, "key \(key)", file: file, line: line)
        case .bool:
            guard let number = stored as? NSNumber else {
                XCTFail("key \(key) is not a bool", file: file, line: line)
                return
            }
            XCTAssertEqual(CFGetTypeID(number), CFBooleanGetTypeID(), "key \(key) must be a bool", file: file, line: line)
            XCTAssertEqual(number.boolValue, (expected as? NSNumber)?.boolValue, "key \(key)", file: file, line: line)
        case .intList:
            XCTAssertEqual(stored as? [Int], expected as? [Int], "key \(key)", file: file, line: line)
        case .doubleList:
            XCTAssertEqual(stored as? [Double], expected as? [Double], "key \(key)", file: file, line: line)
        case .json:
            // b49fix18 D-2: hao_sa_video_applied is the table's
            // only .json kind in UserDefaults (a [String] of
            // applied CMS source URLs, CmsClient.appliedKey).
            // coerce() stores the parsed JSON object, so compare
            // canonical JSON of the stored value against the
            // parsed expected value.
            guard let actualData = canonicalJSONData(stored),
                  let expectedData = canonicalJSONData(parsedJSON(expected)) else {
                XCTFail("key \(key) is not JSON", file: file, line: line)
                return
            }
            XCTAssertEqual(actualData, expectedData, "key \(key)", file: file, line: line)
        case .data:
            // b49fix32: the snapshot carries a base64 string (see
            // snapshotValue); coerce() decodes it to Data on import
            // and UserDefaults stores Data. No mapping is .data yet.
            guard let text = expected as? String,
                  let expectedData = Data(base64Encoded: text) else {
                XCTFail("key \(key) is not base64", file: file, line: line)
                return
            }
            XCTAssertEqual(stored as? Data, expectedData, "key \(key)", file: file, line: line)
        }
    }

    private func requireKeychain() throws {
        let probeAccount = "hao-keychain-probe-crossgen"
        _ = KeychainStore.delete(account: probeAccount)
        guard KeychainStore.save("__probe__", account: probeAccount) else {
            throw XCTSkip("keychain write unavailable on this runner")
        }
        _ = KeychainStore.delete(account: probeAccount)
    }

    // MARK: - Full snapshot

    func testFullSnapshotMigratesEveryKey() {
        XCTAssertEqual(MigrationStore.mappings.count, 117, "the mapping table is the contract; a new row belongs in the table first")
        let fixture = buildFixture()
        XCTAssertEqual(fixture.data.count, 131, "117 named + 9 family + 2 ignored + 3 unknown")
        buildFakeFlutterDocuments()
        writeSnapshot(fixture.data)
        let snapshotURL = docs.appendingPathComponent("migration_snapshot.json")
        let hiveURL = docs.appendingPathComponent("app_settings.hive")
        let snapshotBefore = try? Data(contentsOf: snapshotURL)
        let hiveBefore = try? Data(contentsOf: hiveURL)

        let report = MigrationStore.runIfNeeded(documentsURL: docs, defaults: defaults)

        XCTAssertEqual(report.outcome, .migrated)
        XCTAssertEqual(report.totalKeys, 131)
        // 120, not 126: family keys merge into one file per family
        // (9 keys -> haoVodProg, hao_daily, hao_listen), and the 3
        // unknown keys land in one unknown-keys file: 75 defaults +
        // 40 collection files + 1 emby config + 3 family files +
        // 1 unknown-keys file = 120. The 40 is 38 whole-file writes
        // + 2 merged family files (hao_daily, haoVodProg); the 3
        // family files are the merged singles hao_listen, hao_recent
        // and musicResume — the bare hao_listen key merges via the
        // listen family instead of a whole-file write (b49fix16 P2-1),
        // so it is counted once, not once per write path — the
        // accounting is now exact (120 + 2 skipped + 3 unknown
        // = 125 = 131 total - 6 family-key reduction). b49fix19
        // P2-1 added 5 rows (downloadTasks, hao_fav_playlists,
        // hao_fav_albums, hao_fav_artists, hao_daily_pool):
        // 115 -> 120, 38 whole-file writes was 33.
        XCTAssertEqual(report.migratedKeys, 120)
        XCTAssertEqual(report.skippedKeys, 2)
        XCTAssertEqual(report.unknownKeys, 3)
        XCTAssertEqual(report.failedKeys, 0)
        XCTAssertEqual(report.skippedKeyNames, ["hao_play_url_cache:song1|wy|hires", "hao_play_url_cache:song2|kg|320k"])
        XCTAssertEqual(report.unknownKeyNames, ["custom_plugin_key", "hao_future_feature_flag", "hao_unknown_2027_key"])
        XCTAssertTrue(MigrationStore.isMigrationDone(defaults: defaults))
        XCTAssertEqual(MigrationStore.migrationState(defaults: defaults), MigrationStore.stateDone)
        XCTAssertFalse(MigrationStore.migrationNoticeNeeded(defaults: defaults))

        for mapping in MigrationStore.mappings {
            switch mapping.destination {
            case .userDefaults:
                assertDefaultScalar(key: mapping.key, kind: mapping.kind, expected: fixture.data[mapping.key]!)
            case .collectionFile:
                break
            case .emby:
                break
            }
        }
        for entry in fixture.expectedFiles {
            assertJSONEqual(readJSONFile(entry.key), entry.value, label: entry.key)
        }
        let vodProg = readJSONFile("haoVodProg") as? [String: Any]
        XCTAssertEqual(vodProg?.count, 3)
        XCTAssertEqual((vodProg?["haoVodProg:cms:vod42"] as? NSNumber)?.doubleValue, 1234.5)
        XCTAssertEqual((vodProg?["haoVodProg:emby:ep7"] as? NSNumber)?.doubleValue, 300)
        let daily = readJSONFile("hao_daily") as? [String: Any]
        XCTAssertEqual(daily?.count, 3)
        let listen = readJSONFile("hao_listen") as? [[String: Any]]
        XCTAssertEqual(listen?.count, 4, "mapping value plus 3 family entries")
        XCTAssertEqual(listen?.first?["id"] as? String, "x")
        let unknown = readJSONFile(MigrationStore.unknownKeysFileName) as? [String: Any]
        XCTAssertEqual(unknown?.count, 3)
        XCTAssertEqual(unknown?["hao_future_feature_flag"] as? String, "keep me")

        let jsonNames = Set(((try? FileManager.default.contentsOfDirectory(atPath: docs.path)) ?? []).filter { $0.hasSuffix(".json") })
        let expectedNames = Set(fixture.expectedFiles.keys.map { "\($0).json" } + ["migration_snapshot.json"])
        XCTAssertEqual(jsonNames, expectedNames, "no file missing, no extra file written")

        XCTAssertEqual(try? Data(contentsOf: hiveURL), hiveBefore as Data?, "Hive box untouched")
        XCTAssertEqual(try? Data(contentsOf: snapshotURL), snapshotBefore as Data?, "snapshot file untouched")
        for pair in [("music_downloads", "a.mp3"), ("local_music", "b.mp3"), ("wallpapers", "w.png"), ("fonts", "f.ttf")] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: docs.appendingPathComponent(pair.0).appendingPathComponent(pair.1).path), "\(pair.0)/\(pair.1) kept")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: docs.appendingPathComponent("local_music/b.mp3").path), "relative name local_music/b.mp3 resolves")
        XCTAssertTrue(FileManager.default.fileExists(atPath: docs.appendingPathComponent("wallpapers/w.png").path), "relative name wallpapers/w.png resolves")

        let backupRoot = docs.appendingPathComponent(MigrationStore.backupDirectoryName)
        let stamps = (try? FileManager.default.contentsOfDirectory(atPath: backupRoot.path)) ?? []
        XCTAssertEqual(stamps.count, 1, "one pre-write backup")
        let backupDir = backupRoot.appendingPathComponent(stamps[0])
        XCTAssertEqual(try? Data(contentsOf: backupDir.appendingPathComponent(MigrationStore.snapshotFileName)), snapshotBefore as Data?, "backup holds a snapshot copy")
        if let backedFavData = try? Data(contentsOf: backupDir.appendingPathComponent("collections").appendingPathComponent("hao_fav.json")),
           let backedFav = try? JSONSerialization.jsonObject(with: backedFavData, options: []) {
            assertJSONEqual(backedFav, [["key": "old-song"]], label: "backed-up hao_fav.json")
        } else {
            XCTFail("backup is missing the prior hao_fav.json")
        }
    }

    // MARK: - Emby split

    func testEmbyApiKeyGoesToKeychain() throws {
        try requireKeychain()
        writeSnapshot(["hao_emby_config": jsonString(Self.embyConfig)])
        let report = MigrationStore.runIfNeeded(documentsURL: docs, defaults: defaults)
        XCTAssertEqual(report.outcome, .migrated)
        XCTAssertEqual(KeychainStore.loadEmbyApiKey(), "test-api-key-123")
        let file = readJSONFile("hao_emby_config") as? [String: Any]
        XCTAssertNil(file?["apiKey"], "the key must never sit in the JSON file")
        XCTAssertEqual(file?["baseUrl"] as? String, "http://192.168.1.10:8096")
        XCTAssertEqual(file?["userId"] as? String, "u1")
    }

    // MARK: - Corrupt, missing, wrong-version snapshots

    func testCorruptSnapshotSkipsWithDefaultsAndNotice() {
        writeSnapshotRaw("not json at all")
        let report = MigrationStore.runIfNeeded(documentsURL: docs, defaults: defaults)
        XCTAssertEqual(report.outcome, .invalidSnapshot)
        XCTAssertFalse(MigrationStore.isMigrationDone(defaults: defaults))
        XCTAssertTrue(MigrationStore.migrationNoticeNeeded(defaults: defaults))
        XCTAssertNil(defaults.object(forKey: "videoPlayerKey"))
        XCTAssertNil(readJSONFile("hao_fav"))
    }

    func testMissingSnapshotIsNoSnapshot() {
        let report = MigrationStore.runIfNeeded(documentsURL: docs, defaults: defaults)
        XCTAssertEqual(report.outcome, .noSnapshot)
        XCTAssertFalse(MigrationStore.isMigrationDone(defaults: defaults))
        XCTAssertTrue(MigrationStore.migrationNoticeNeeded(defaults: defaults))
    }

    func testWrongSchemaSnapshotIsInvalid() {
        writeSnapshot(["videoPlayerKey": "ijk"], schema: 2)
        let report = MigrationStore.runIfNeeded(documentsURL: docs, defaults: defaults)
        XCTAssertEqual(report.outcome, .invalidSnapshot)
        XCTAssertFalse(MigrationStore.isMigrationDone(defaults: defaults))
        XCTAssertNil(defaults.object(forKey: "videoPlayerKey"))
    }

    func testSnapshotWithoutAppVersionStillMigrates() {
        writeSnapshot(["videoPlayerKey": "ijk"], appVersion: nil)
        let report = MigrationStore.runIfNeeded(documentsURL: docs, defaults: defaults)
        XCTAssertEqual(report.outcome, .migrated)
        XCTAssertEqual(defaults.string(forKey: "videoPlayerKey"), "ijk")
    }

    // MARK: - Bad-typed keys

    func testBadTypedKeysSkipOnlyThoseKeys() {
        writeSnapshot([
            "musicSpeed": "fast",
            "hapticsEnabled": 1,
            "hao_lists": 42,
            "videoPlayerKey": "ijk",
            "hao_live_hist_limit": 25,
        ])
        let report = MigrationStore.runIfNeeded(documentsURL: docs, defaults: defaults)
        XCTAssertEqual(report.outcome, .migrated)
        XCTAssertEqual(report.totalKeys, 5)
        XCTAssertEqual(report.skippedKeys, 3)
        XCTAssertEqual(report.skippedKeyNames, ["hao_lists", "hapticsEnabled", "musicSpeed"])
        XCTAssertEqual(report.migratedKeys, 2)
        XCTAssertEqual(defaults.string(forKey: "videoPlayerKey"), "ijk")
        XCTAssertEqual(defaults.integer(forKey: "hao_live_hist_limit"), 25)
        XCTAssertNil(defaults.object(forKey: "musicSpeed"))
        XCTAssertNil(defaults.object(forKey: "hapticsEnabled"))
        XCTAssertNil(readJSONFile("hao_lists"))
    }
}

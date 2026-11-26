// HAo Studio 2.0 — backup engine tests (S6-A leg).
//
// Fixture-only, no network, no real data. Persistence tests use
// a temp documents directory (injected, like LXScriptStore) and
// an isolated UserDefaults suite (UUID), mirroring
// MigrationStoreTests — nothing here touches the real Documents
// directory or the standard defaults. The engine is driven
// through its completion-handler seam (`FileBackupEngine`, B's
// `BackupEngine` protocol); the synchronous core
// (`BackupEngineCore`) is used directly only where a test needs
// its detail (rollback outcome, skipped/unknown key names) or
// must craft a backup (newer version, bad key).
//
// NOTE FOR THE COORDINATOR: these tests import `BackupImportReport`
// and the `BackupEngine` protocol from B's
// Features/My/BackupUpdateLogic.swift, so that file must be
// merged in (and registered in Package.swift by the B leg)
// before BackupTests compiles. The tests are written, not run:
// this VM has no Swift toolchain.
//
// Count check: testRoundTripOneHundredItems seeds exactly 102
// items (every covered defaults key + 5 collection files) and
// verifies each one after a wipe + import. If the key catalogue
// grows, the test fails loudly on the count — update the number,
// do not lower the bar. (100 at S6; 102 after the settings-wiring
// work added two covered keys; 101 after chen 2026-11-24 removed
// the profile nickname key with the profile/membership deletion;
// 102 after build-36 item 11 added the VOD danmaku API address
// key `hao_vod_danmaku_api_url` — the token stays excluded from
// the backup whitelist, see ignoredImportKeys.)

import Foundation
import XCTest

@testable import AppCore

final class BackupEngineTests: XCTestCase {
    private var docs: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var engine: FileBackupEngine!
    private var currentVersion: BackupVersion!

    override func setUp() {
        super.setUp()
        guard let version = BackupVersion(raw: "2.0.0") else {
            XCTFail("test version 2.0.0 must parse")
            return
        }
        currentVersion = version
        suiteName = "com.haostudio.backup.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        docs = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-backup-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        engine = FileBackupEngine(
            documentsURL: docs, defaults: defaults,
            currentVersion: currentVersion
        )
        BackupEngineCore.testFailOnKey = nil
        BackupEngineCore.testFailOnFile = nil
        BackupEngineCore.testEmbyCredentialPresent = nil
        _ = KeychainStore.deleteEmbyApiKey()
    }

    override func tearDown() {
        if let docs = docs {
            try? FileManager.default.removeItem(at: docs)
        }
        if let suiteName = suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        BackupEngineCore.testFailOnKey = nil
        BackupEngineCore.testFailOnFile = nil
        BackupEngineCore.testEmbyCredentialPresent = nil
        _ = KeychainStore.deleteEmbyApiKey()
        super.tearDown()
    }

    // MARK: - Helpers

    private struct SeededKey {
        let key: String
        let kind: MigrationKeyKind
        let value: Any
    }

    private func sampleValue(for kind: MigrationKeyKind, key: String) -> Any {
        switch kind {
        case .string:
            return "sample-" + key
        case .int:
            return 7
        case .double:
            return 1.5
        case .bool:
            return true
        case .intList:
            return [1, 2, 3]
        case .doubleList:
            return [0.5, -1.0]
        case .json:
            return ["a", "b"]
        case .data:
            // b49fix32: UserDefaults stores Data directly for a
            // .data key (coerce / isValidValue). No key in
            // userDefaultsKeyKinds() is .data yet, but seed a real
            // Data value so the arm is real if one is added.
            return Data("sample".utf8)
        }
    }

    /// Seeds every covered defaults key plus the two
    /// section-expanded keys. Returns the seeded keys, sorted.
    private func seedSampleDefaults(into targetDefaults: UserDefaults) -> [SeededKey] {
        var seeded: [SeededKey] = []
        for (key, kind) in BackupEngineCore.userDefaultsKeyKinds() {
            let value = sampleValue(for: kind, key: key)
            targetDefaults.set(value, forKey: key)
            seeded.append(SeededKey(key: key, kind: kind, value: value))
        }
        targetDefaults.set(true, forKey: "settingsSectionExpanded_appearance")
        seeded.append(SeededKey(key: "settingsSectionExpanded_appearance", kind: .bool, value: true))
        targetDefaults.set(false, forKey: "settingsSectionExpanded_music")
        seeded.append(SeededKey(key: "settingsSectionExpanded_music", kind: .bool, value: false))
        seeded.sort(by: { $0.key < $1.key })
        return seeded
    }

    private func verifySampleValue(
        _ actual: Any?,
        kind: MigrationKeyKind,
        key: String,
        expected: Any,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        switch kind {
        case .string:
            XCTAssertEqual(actual as? String, expected as? String, file: file, line: line)
        case .int:
            XCTAssertEqual((actual as? NSNumber)?.intValue, (expected as? NSNumber)?.intValue, file: file, line: line)
        case .double:
            XCTAssertEqual((actual as? NSNumber)?.doubleValue ?? 0, (expected as? NSNumber)?.doubleValue ?? 0, accuracy: 0.0001, file: file, line: line)
        case .bool:
            XCTAssertEqual((actual as? NSNumber)?.boolValue, (expected as? NSNumber)?.boolValue, file: file, line: line)
        case .intList:
            XCTAssertEqual(actual as? [Int], expected as? [Int], file: file, line: line)
        case .doubleList:
            let actualList = actual as? [Double] ?? []
            let expectedList = expected as? [Double] ?? []
            XCTAssertEqual(actualList.count, expectedList.count, file: file, line: line)
            for (index, value) in expectedList.enumerated() where index < actualList.count {
                XCTAssertEqual(actualList[index], value, accuracy: 0.0001, file: file, line: line)
            }
        case .json:
            XCTFail("unexpected json-kind defaults key: \(key)", file: file, line: line)
        case .data:
            // b49fix32: mirrors sampleValue — a .data key stores
            // Data in UserDefaults; compare it directly.
            XCTAssertEqual(actual as? Data, expected as? Data, file: file, line: line)
        }
    }

    /// Seeds 5 collection files with distinct bytes. Returns
    /// name (without .json) -> bytes.
    private func seedCollectionFiles(into targetDocs: URL) -> [String: Data] {
        let files: [String: String] = [
            "hao_fav": "[{\"platform\":\"wy\",\"songId\":\"1\"}]",
            "hao_lists": "[{\"id\":\"l1\",\"name\":\"list one\"}]",
            "hao_recent": "[{\"songId\":\"2\"}]",
            "hao_video_hist": "[{\"vodId\":\"v1\"}]",
            "hao_live_follows": "[{\"roomId\":\"r1\"}]",
        ]
        var out: [String: Data] = [:]
        for (name, json) in files {
            guard let data = json.data(using: .utf8) else {
                XCTFail("seed JSON must encode: \(name)")
                continue
            }
            try? data.write(to: targetDocs.appendingPathComponent(name + ".json"), options: [.atomic])
            out[name] = data
        }
        return out
    }

    /// Removes every defaults key and every file under a docs dir.
    private func wipe(docs targetDocs: URL, defaults targetDefaults: UserDefaults) {
        for key in targetDefaults.dictionaryRepresentation().keys {
            targetDefaults.removeObject(forKey: key)
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: targetDocs.path)) ?? []
        for name in names {
            try? FileManager.default.removeItem(at: targetDocs.appendingPathComponent(name))
        }
    }

    private func exportZip(using targetEngine: FileBackupEngine) -> URL? {
        let exp = expectation(description: "export")
        var url: URL?
        var failure: Error?
        targetEngine.exportBackup(completion: { result in
            switch result {
            case .success(let exportedURL):
                url = exportedURL
            case .failure(let error):
                failure = error
            }
            exp.fulfill()
        })
        waitForExpectations(timeout: 10, handler: nil)
        XCTAssertNil(failure, "export failed: \(String(describing: failure))")
        return url
    }

    private func importZip(_ zipURL: URL, using targetEngine: FileBackupEngine) -> Result<BackupImportReport, Error>? {
        let exp = expectation(description: "import")
        var result: Result<BackupImportReport, Error>?
        targetEngine.importBackup(from: zipURL, completion: { imported in
            result = imported
            exp.fulfill()
        })
        waitForExpectations(timeout: 10, handler: nil)
        return result
    }

    /// Rebuilds a zip with a mutated `backup.json` (same other
    /// entries, byte-identical). Used to craft a newer schema, a
    /// bad-typed key, and an unknown key.
    private func rewriteBackupJSON(
        in zipURL: URL,
        mutate: (inout [String: Any]) -> Void
    ) -> URL? {
        guard let entries = ZipArchive.listEntries(at: zipURL) else { return nil }
        var newEntries: [ZipEntry] = []
        for entry in entries {
            guard let data = ZipArchive.readEntryData(entry, from: zipURL) else {
                return nil
            }
            if entry.name == BackupEngineCore.envelopeFileName {
                guard var root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
                    return nil
                }
                mutate(&root)
                guard let newData = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else {
                    return nil
                }
                newEntries.append(.data(name: entry.name, data: newData))
            } else {
                newEntries.append(.data(name: entry.name, data: data))
            }
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-backup-rewritten-\(UUID().uuidString).zip")
        guard ZipArchive.write(entries: newEntries, to: outURL) else { return nil }
        return outURL
    }

    private func writeFile(_ relativePath: String, bytes: Data, into targetDocs: URL) {
        let url = targetDocs.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? bytes.write(to: url, options: [.atomic])
    }

    private func readFile(_ relativePath: String, from targetDocs: URL) -> Data? {
        return try? Data(contentsOf: targetDocs.appendingPathComponent(relativePath))
    }

    // MARK: - Round trip: 100 items, one by one

    func testRoundTripOneHundredItems() {
        let seededKeys = seedSampleDefaults(into: defaults)
        let seededCollections = seedCollectionFiles(into: docs)
        let total = seededKeys.count + seededCollections.count
        XCTAssertEqual(total, 102, "seed catalogue changed: expected 102 items")
        guard let zipURL = exportZip(using: engine) else { return }
        wipe(docs: docs, defaults: defaults)
        guard let result = importZip(zipURL, using: engine) else {
            return XCTFail("no import result")
        }
        switch result {
        case .failure(let error):
            XCTFail("import failed: \(error.localizedDescription)")
        case .success(let report):
            XCTAssertFalse(report.rolledBack)
            XCTAssertEqual(report.importedCount, 102)
            XCTAssertTrue(report.skippedKeys.isEmpty)
            XCTAssertFalse(report.embyCredentialsMissing)
        }
        for seeded in seededKeys {
            verifySampleValue(defaults.object(forKey: seeded.key), kind: seeded.kind, key: seeded.key, expected: seeded.value)
        }
        for (name, bytes) in seededCollections {
            guard let actual = readFile(name + ".json", from: docs) else {
                XCTFail("collection \(name) missing after import")
                continue
            }
            XCTAssertEqual(actual, bytes, "collection \(name) mismatch")
        }
    }

    // MARK: - Corrupt zip: refused, existing data untouched

    func testCorruptZipKeepsExistingData() {
        defaults.set("keep-me", forKey: "musicQuality")
        let favBytes = "[{\"songId\":\"9\"}]".data(using: .utf8) ?? Data()
        writeFile("hao_fav.json", bytes: favBytes, into: docs)
        let garbageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-backup-garbage-\(UUID().uuidString).zip")
        try? "not a zip at all".data(using: .utf8)?.write(to: garbageURL)
        guard let result = importZip(garbageURL, using: engine) else {
            return XCTFail("no import result")
        }
        switch result {
        case .failure:
            break
        case .success:
            XCTFail("corrupt zip must be refused")
        }
        XCTAssertEqual(defaults.string(forKey: "musicQuality"), "keep-me")
        XCTAssertEqual(readFile("hao_fav.json", from: docs), favBytes)
    }

    // MARK: - Newer backup: refused

    func testNewerBackupRejected() {
        defaults.set("from-newer", forKey: "musicQuality")
        guard let newerVersion = BackupVersion(raw: "99.0.0") else {
            return XCTFail("99.0.0 must parse")
        }
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-backup-newer-\(UUID().uuidString).zip")
        guard let exported = BackupEngineCore.exportBackup(
            to: zipURL, documentsURL: docs, defaults: defaults,
            currentVersion: newerVersion
        ) else {
            return XCTFail("crafting the newer backup failed")
        }
        guard let result = importZip(exported.zipURL, using: engine) else {
            return XCTFail("no import result")
        }
        switch result {
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("更新的版本"))
        case .success:
            XCTFail("newer backup must be refused")
        }
        XCTAssertEqual(defaults.string(forKey: "musicQuality"), "from-newer")
    }

    // MARK: - Schema mismatch: refused

    func testSchemaMismatchRejected() {
        defaults.set("v", forKey: "musicQuality")
        guard let zipURL = exportZip(using: engine) else { return }
        guard let rewritten = rewriteBackupJSON(in: zipURL, mutate: { root in
            root["schema"] = 99
        }) else {
            return XCTFail("rewriting the backup failed")
        }
        guard let result = importZip(rewritten, using: engine) else {
            return XCTFail("no import result")
        }
        switch result {
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("schema"))
        case .success:
            XCTFail("schema 99 backup must be refused")
        }
    }

    // MARK: - Import is a merge, not a replace

    func testImportIsMergeNotReplace() {
        let sourceDocs = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-backup-merge-src-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sourceDocs, withIntermediateDirectories: true)
        let sourceSuite = "com.haostudio.backup.merge.\(UUID().uuidString)"
        guard let sourceDefaults = UserDefaults(suiteName: sourceSuite) ?? defaults else {
            return XCTFail("cannot create source defaults")
        }
        defer {
            try? FileManager.default.removeItem(at: sourceDocs)
            sourceDefaults.removePersistentDomain(forName: sourceSuite)
        }
        sourceDefaults.set("from-backup", forKey: "musicQuality")
        let favBytes = "[{\"songId\":\"7\"}]".data(using: .utf8) ?? Data()
        writeFile("hao_fav.json", bytes: favBytes, into: sourceDocs)
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-backup-merge-\(UUID().uuidString).zip")
        guard let exported = BackupEngineCore.exportBackup(
            to: zipURL, documentsURL: sourceDocs, defaults: sourceDefaults,
            currentVersion: currentVersion
        ) else {
            return XCTFail("crafting the merge backup failed")
        }
        defaults.set("target-old", forKey: "musicQuality")
        defaults.set("target-theme", forKey: "haoThemeId")
        let recentBytes = "[{\"songId\":\"8\"}]".data(using: .utf8) ?? Data()
        writeFile("hao_recent.json", bytes: recentBytes, into: docs)
        guard let result = importZip(exported.zipURL, using: engine) else {
            return XCTFail("no import result")
        }
        switch result {
        case .failure(let error):
            XCTFail("import failed: \(error.localizedDescription)")
        case .success(let report):
            XCTAssertFalse(report.rolledBack)
        }
        XCTAssertEqual(defaults.string(forKey: "musicQuality"), "from-backup")
        XCTAssertEqual(defaults.string(forKey: "haoThemeId"), "target-theme")
        XCTAssertEqual(readFile("hao_fav.json", from: docs), favBytes)
        XCTAssertEqual(readFile("hao_recent.json", from: docs), recentBytes)
    }

    // MARK: - Injected write failure: full rollback

    func testWriteFailureRollsBackEverything() {
        defaults.set("after", forKey: "musicQuality")
        defaults.set(true, forKey: "hapticsEnabled")
        defaults.set("after", forKey: "videoPlayerKey")
        defaults.set("after", forKey: "haoThemeId")
        defaults.set("dark", forKey: "haoThemeMode")
        guard let sourceZip = exportZip(using: engine) else { return }
        defaults.set("before", forKey: "musicQuality")
        defaults.set(false, forKey: "hapticsEnabled")
        defaults.set("before", forKey: "videoPlayerKey")
        defaults.set("before", forKey: "haoThemeId")
        defaults.removeObject(forKey: "haoThemeMode")
        BackupEngineCore.testFailOnKey = "musicQuality"
        defer { BackupEngineCore.testFailOnKey = nil }
        let detail = BackupEngineCore.importBackup(
            from: sourceZip, documentsURL: docs, defaults: defaults,
            currentVersion: currentVersion
        )
        XCTAssertEqual(detail.outcome, .failed)
        XCTAssertEqual(defaults.string(forKey: "musicQuality"), "before")
        XCTAssertEqual(defaults.bool(forKey: "hapticsEnabled"), false)
        XCTAssertEqual(defaults.string(forKey: "videoPlayerKey"), "before")
        XCTAssertEqual(defaults.string(forKey: "haoThemeId"), "before")
        XCTAssertNil(defaults.object(forKey: "haoThemeMode"))
    }

    // MARK: - Canary: no apiKey bytes anywhere in the export

    func testCanaryApiKeyNeverInExportBytes() {
        let canary = "CANARY-APIKEY-TEST-12345"
        let config = "{\"baseUrl\":\"https://example.invalid\",\"userId\":\"u1\",\"apiKey\":\"\(canary)\"}"
        guard let configData = config.data(using: .utf8) else {
            return XCTFail("canary config must encode")
        }
        writeFile("hao_emby_config.json", bytes: configData, into: docs)
        XCTAssertTrue(KeychainStore.saveEmbyApiKey(canary))
        guard let exported = BackupEngineCore.exportBackup(
            to: FileManager.default.temporaryDirectory
                .appendingPathComponent("hao-backup-canary-\(UUID().uuidString).zip"),
            documentsURL: docs, defaults: defaults,
            currentVersion: currentVersion
        ) else {
            return XCTFail("export failed")
        }
        XCTAssertTrue(exported.warnings.contains(BackupEngineCore.embyCredentialWarning))
        guard let zipData = try? Data(contentsOf: exported.zipURL),
              let canaryData = canary.data(using: .utf8)
        else {
            return XCTFail("cannot read exported zip")
        }
        XCTAssertNil(zipData.range(of: canaryData), "canary apiKey leaked into export bytes")
        guard let entries = ZipArchive.listEntries(at: exported.zipURL),
              let configEntry = entries.first(where: { $0.name == "collections/hao_emby_config.json" }),
              let exportedConfig = ZipArchive.readEntryData(configEntry, from: exported.zipURL),
              let parsed = try? JSONSerialization.jsonObject(with: exportedConfig, options: []),
              let configDict = parsed as? [String: Any]
        else {
            return XCTFail("exported Emby config missing")
        }
        XCTAssertNil(configDict["apiKey"])
        XCTAssertEqual(configDict["baseUrl"] as? String, "https://example.invalid")
    }

    // MARK: - VOD danmaku token never in a backup (b36 follow-up)

    func testDanmakuTokenNeverInExportButUrlIs() {
        // Same canary shape as the Emby test: the address is not
        // a secret and stays exportable, the token must not appear
        // anywhere in the zip bytes or the envelope data.
        let canary = "CANARY-DANMAKU-TOKEN-12345"
        defaults.set("https://danmaku.example.invalid/api", forKey: "hao_vod_danmaku_api_url")
        defaults.set(canary, forKey: "hao_vod_danmaku_api_token")
        guard let exported = BackupEngineCore.exportBackup(
            to: FileManager.default.temporaryDirectory
                .appendingPathComponent("hao-backup-danmaku-\(UUID().uuidString).zip"),
            documentsURL: docs, defaults: defaults,
            currentVersion: currentVersion
        ) else {
            return XCTFail("export failed")
        }
        guard let zipData = try? Data(contentsOf: exported.zipURL),
              let canaryData = canary.data(using: .utf8)
        else {
            return XCTFail("cannot read exported zip")
        }
        XCTAssertNil(zipData.range(of: canaryData), "danmaku token leaked into export bytes")
        guard let entries = ZipArchive.listEntries(at: exported.zipURL),
              let envelopeEntry = entries.first(where: { $0.name == BackupEngineCore.envelopeFileName }),
              let envelopeData = ZipArchive.readEntryData(envelopeEntry, from: exported.zipURL),
              let parsed = try? JSONSerialization.jsonObject(with: envelopeData, options: []),
              let root = parsed as? [String: Any],
              let data = root["data"] as? [String: Any]
        else {
            return XCTFail("exported envelope missing")
        }
        XCTAssertEqual(data["hao_vod_danmaku_api_url"] as? String, "https://danmaku.example.invalid/api")
        XCTAssertNil(data["hao_vod_danmaku_api_token"])
    }

    func testOldBackupTokenIsSkippedNotRestored() {
        // An old backup (b36 item 11) already carries the token:
        // import must succeed, restore the address, and leave the
        // token exactly as it is on this device — never applied,
        // never isolated into backup_unknown_keys.json (that file
        // would still leave the token on disk in plain text).
        defaults.set("https://danmaku.example.invalid/api", forKey: "hao_vod_danmaku_api_url")
        defaults.set("DEVICE-TOKEN-STAYS", forKey: "hao_vod_danmaku_api_token")
        guard let zipURL = exportZip(using: engine) else { return }
        guard let rewritten = rewriteBackupJSON(in: zipURL, mutate: { root in
            var data = root["data"] as? [String: Any] ?? [:]
            data["hao_vod_danmaku_api_token"] = "CANARY-OLD-BACKUP-TOKEN"
            data["hao_vod_danmaku_api_url"] = "https://old-backup.example.invalid/api"
            root["data"] = data
        }) else {
            return XCTFail("rewriting the backup failed")
        }
        // Wipe the device values: the address must come back from
        // the backup, the token must stay absent.
        defaults.removeObject(forKey: "hao_vod_danmaku_api_url")
        defaults.removeObject(forKey: "hao_vod_danmaku_api_token")
        let detail = BackupEngineCore.importBackup(
            from: rewritten, documentsURL: docs, defaults: defaults,
            currentVersion: currentVersion
        )
        XCTAssertEqual(detail.outcome, .imported)
        XCTAssertTrue(detail.skippedKeyNames.contains("hao_vod_danmaku_api_token"))
        XCTAssertEqual(defaults.string(forKey: "hao_vod_danmaku_api_url"), "https://old-backup.example.invalid/api")
        XCTAssertNil(defaults.object(forKey: "hao_vod_danmaku_api_token"))
        XCTAssertFalse(detail.unknownKeyNames.contains("hao_vod_danmaku_api_token"))
        XCTAssertNil(readFile("backup_unknown_keys.json", from: docs), "token must not be isolated to disk")
    }

    // MARK: - Bad-typed key: skipped, rest still lands

    func testBadKeySkippedNotFatal() {
        defaults.set("keep-me", forKey: "musicQuality")
        defaults.set(false, forKey: "hapticsEnabled")
        guard let zipURL = exportZip(using: engine) else { return }
        guard let rewritten = rewriteBackupJSON(in: zipURL, mutate: { root in
            var data = root["data"] as? [String: Any] ?? [:]
            data["musicQuality"] = NSNumber(value: 12345)
            data["hapticsEnabled"] = true
            root["data"] = data
        }) else {
            return XCTFail("rewriting the backup failed")
        }
        let detail = BackupEngineCore.importBackup(
            from: rewritten, documentsURL: docs, defaults: defaults,
            currentVersion: currentVersion
        )
        XCTAssertEqual(detail.outcome, .imported)
        XCTAssertTrue(detail.skippedKeyNames.contains("musicQuality"))
        XCTAssertEqual(defaults.string(forKey: "musicQuality"), "keep-me")
        XCTAssertEqual(defaults.bool(forKey: "hapticsEnabled"), true)
    }

    // MARK: - Unknown key: isolated, never applied

    func testUnknownKeysIsolated() {
        guard let zipURL = exportZip(using: engine) else { return }
        guard let rewritten = rewriteBackupJSON(in: zipURL, mutate: { root in
            var data = root["data"] as? [String: Any] ?? [:]
            data["hao_future_unknown_key"] = "zzz"
            root["data"] = data
        }) else {
            return XCTFail("rewriting the backup failed")
        }
        let detail = BackupEngineCore.importBackup(
            from: rewritten, documentsURL: docs, defaults: defaults,
            currentVersion: currentVersion
        )
        XCTAssertEqual(detail.outcome, .imported)
        XCTAssertTrue(detail.unknownKeyNames.contains("hao_future_unknown_key"))
        XCTAssertNil(defaults.object(forKey: "hao_future_unknown_key"))
        guard let isolatedData = readFile("backup_unknown_keys.json", from: docs),
              let parsed = try? JSONSerialization.jsonObject(with: isolatedData, options: []),
              let isolated = parsed as? [String: Any]
        else {
            return XCTFail("unknown-keys file missing")
        }
        XCTAssertEqual(isolated["hao_future_unknown_key"] as? String, "zzz")
    }

    func testUnknownZipEntryWarnsButImports() {
        // b35-sweep-settings: an unrecognised top-level zip entry
        // must be ignored with a warning, not fail the import —
        // and the warning must reach the UI-facing report (the
        // engine used to produce it but FileBackupEngine dropped it).
        guard let zipURL = exportZip(using: engine) else { return }
        guard let entries = ZipArchive.listEntries(at: zipURL) else {
            return XCTFail("cannot list exported backup")
        }
        var newEntries: [ZipEntry] = []
        for entry in entries {
            guard let data = ZipArchive.readEntryData(entry, from: zipURL) else {
                return XCTFail("cannot read entry \(entry.name)")
            }
            newEntries.append(.data(name: entry.name, data: data))
        }
        newEntries.append(.data(name: "strange.txt", data: "nonsense".data(using: .utf8) ?? Data()))
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-backup-strange-\(UUID().uuidString).zip")
        guard ZipArchive.write(entries: newEntries, to: outURL) else {
            return XCTFail("rewriting the backup failed")
        }
        guard let result = importZip(outURL, using: engine) else {
            return XCTFail("import returned nothing")
        }
        switch result {
        case .success(let report):
            XCTAssertFalse(report.rolledBack)
            XCTAssertFalse(report.warnings.isEmpty, "unknown entry must surface as a warning")
            XCTAssertTrue(report.warnings.contains { $0.contains("strange.txt") })
            XCTAssertTrue(UpdateCheckLogic.importResultMessage(report: report).contains("strange.txt"))
        case .failure(let error):
            XCTFail("import must succeed despite unknown entry: \(error)")
        }
    }

    // MARK: - Manifest: a backup missing a promised entry is refused

    func testImportRejectsBackupMissingManifestEntry() {
        // The envelope manifest promises every collection; a zip
        // that lost one entry must be refused before anything is
        // written, not imported "successfully" with data missing.
        defaults.set("keep-me", forKey: "musicQuality")
        let favBytes = "[{\"songId\":\"9\"}]".data(using: .utf8) ?? Data()
        writeFile("hao_fav.json", bytes: favBytes, into: docs)
        guard let zipURL = exportZip(using: engine) else { return }
        guard let entries = ZipArchive.listEntries(at: zipURL) else {
            return XCTFail("cannot list exported backup")
        }
        var newEntries: [ZipEntry] = []
        for entry in entries where entry.name != "collections/hao_fav.json" {
            guard let data = ZipArchive.readEntryData(entry, from: zipURL) else {
                return XCTFail("cannot read entry \(entry.name)")
            }
            newEntries.append(.data(name: entry.name, data: data))
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-backup-dropped-\(UUID().uuidString).zip")
        guard ZipArchive.write(entries: newEntries, to: outURL) else {
            return XCTFail("rewriting the backup failed")
        }
        guard let result = importZip(outURL, using: engine) else {
            return XCTFail("import returned nothing")
        }
        switch result {
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("不完整"))
        case .success:
            XCTFail("a backup missing a manifest entry must be refused")
        }
        XCTAssertEqual(defaults.string(forKey: "musicQuality"), "keep-me")
        XCTAssertEqual(readFile("hao_fav.json", from: docs), favBytes)
    }

    func testImportRejectsManifestByteCountMismatch() {
        // Same promise, other direction: the manifest says an
        // entry has N bytes but the zip carries fewer/more.
        defaults.set("keep-me", forKey: "musicQuality")
        let favBytes = "[{\"songId\":\"9\"}]".data(using: .utf8) ?? Data()
        writeFile("hao_fav.json", bytes: favBytes, into: docs)
        guard let zipURL = exportZip(using: engine) else { return }
        guard let rewritten = rewriteBackupJSON(in: zipURL, mutate: { root in
            guard var contents = root["contents"] as? [[String: Any]],
                  let index = contents.firstIndex(where: { ($0["path"] as? String)?.hasPrefix("collections/") == true })
            else { return }
            contents[index]["bytes"] = 999_999_999
            root["contents"] = contents
        }) else {
            return XCTFail("rewriting the backup failed")
        }
        guard let result = importZip(rewritten, using: engine) else {
            return XCTFail("import returned nothing")
        }
        switch result {
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("不完整"))
        case .success:
            XCTFail("a backup whose manifest byte count mismatches must be refused")
        }
        XCTAssertEqual(defaults.string(forKey: "musicQuality"), "keep-me")
        XCTAssertEqual(readFile("hao_fav.json", from: docs), favBytes)
    }

    // MARK: - ZIP: stored round trip + CRC vector + extract

    func testZipStoredRoundTrip() {
        let checkData = "123456789".data(using: .utf8) ?? Data()
        XCTAssertEqual(ZipArchive.crc32(checkData), 0xCBF4_3926)
        let small = "hello zip".data(using: .utf8) ?? Data()
        var bigBytes: [UInt8] = []
        bigBytes.reserveCapacity(2 * 1024 * 1024)
        for index in 0..<(2 * 1024 * 1024) {
            bigBytes.append(UInt8(index % 251))
        }
        let big = Data(bigBytes)
        let sourceFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-backup-zip-src-\(UUID().uuidString).bin")
        try? big.write(to: sourceFile)
        defer { try? FileManager.default.removeItem(at: sourceFile) }
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-backup-zip-\(UUID().uuidString).zip")
        XCTAssertTrue(ZipArchive.write(entries: [
            .data(name: "a.txt", data: small),
            .data(name: "big.bin", data: big),
            .file(name: "from-disk.bin", fileURL: sourceFile),
        ], to: zipURL))
        guard let entries = ZipArchive.listEntries(at: zipURL) else {
            return XCTFail("cannot list zip entries")
        }
        XCTAssertEqual(entries.map { $0.name }, ["a.txt", "big.bin", "from-disk.bin"])
        XCTAssertTrue(entries.allSatisfy { $0.method == 0 })
        guard let smallEntry = entries.first(where: { $0.name == "a.txt" }),
              let bigEntry = entries.first(where: { $0.name == "big.bin" }),
              let fileEntry = entries.first(where: { $0.name == "from-disk.bin" })
        else {
            return XCTFail("entries missing")
        }
        XCTAssertEqual(ZipArchive.readEntryData(smallEntry, from: zipURL), small)
        XCTAssertEqual(ZipArchive.readEntryData(bigEntry, from: zipURL), big)
        let extractedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-backup-zip-out-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: extractedURL) }
        XCTAssertTrue(ZipArchive.extract(fileEntry, from: zipURL, to: extractedURL))
        XCTAssertEqual(try? Data(contentsOf: extractedURL), big)
    }

    // MARK: - Successful import posts the reload notification

    func testImportPostsReloadNotification() {
        defaults.set("v", forKey: "musicQuality")
        guard let zipURL = exportZip(using: engine) else { return }
        wipe(docs: docs, defaults: defaults)
        // The import posts `.haoBackupImported` synchronously from
        // its background work queue, before the import completion
        // fires — so by the time importZip returns the post has
        // already happened. Assert with a flag, not an expectation:
        // waiting on an already-fulfilled expectation is an XCTest
        // API violation, and the exception it throws skips the
        // defer that removes the observer, leaking it into the
        // next test (which then double-fulfills and crashes the
        // whole test process).
        var posted = false
        let token = NotificationCenter.default.addObserver(
            forName: .haoBackupImported, object: nil, queue: nil, using: { _ in
                posted = true
            }
        )
        defer { NotificationCenter.default.removeObserver(token) }
        guard let result = importZip(zipURL, using: engine) else {
            return XCTFail("no import result")
        }
        switch result {
        case .failure(let error):
            XCTFail("import failed: \(error.localizedDescription)")
        case .success(let report):
            XCTAssertFalse(report.rolledBack)
        }
        XCTAssertTrue(posted, "import must post haoBackupImported")
    }

    // MARK: - Payload files ride along (and .part files do not)

    func testExportIncludesPayloadFiles() {
        let payloads: [String: String] = [
            "wallpapers/w1.jpg": "wallpaper-bytes",
            "lx_scripts/custom-foo.js": "console.log('foo');",
            "live_recordings/r1.mp4": "recording-bytes",
            "logs/app.log": "log line 1\n",
            "music_downloads/song.mp3": "mp3-bytes",
            "local_music/track.mp3": "local-bytes",
            "fonts/f.ttf": "font-bytes",
        ]
        for (path, text) in payloads {
            guard let bytes = text.data(using: .utf8) else { continue }
            writeFile(path, bytes: bytes, into: docs)
        }
        writeFile("music_downloads/x.part", bytes: "resume-state".data(using: .utf8) ?? Data(), into: docs)
        guard let zipURL = exportZip(using: engine) else { return }
        guard let entries = ZipArchive.listEntries(at: zipURL) else {
            return XCTFail("cannot list zip entries")
        }
        let names = Set(entries.map { $0.name })
        for path in payloads.keys {
            XCTAssertTrue(names.contains("files/" + path), "missing payload: \(path)")
        }
        XCTAssertFalse(names.contains("files/music_downloads/x.part"))
        wipe(docs: docs, defaults: defaults)
        guard let result = importZip(zipURL, using: engine) else {
            return XCTFail("no import result")
        }
        switch result {
        case .failure(let error):
            XCTFail("import failed: \(error.localizedDescription)")
        case .success(let report):
            XCTAssertEqual(report.importedCount, payloads.count)
            XCTAssertFalse(report.rolledBack)
        }
        for (path, text) in payloads {
            guard let expected = text.data(using: .utf8) else { continue }
            XCTAssertEqual(readFile(path, from: docs), expected, "payload mismatch: \(path)")
        }
        XCTAssertNil(readFile("music_downloads/x.part", from: docs))
    }

    // MARK: - Emby credential flag on the report

    func testEmbyCredentialsMissingFlag() {
        let config = "{\"baseUrl\":\"https://example.invalid\",\"userId\":\"u1\",\"enabled\":true}"
        guard let configData = config.data(using: .utf8) else {
            return XCTFail("config must encode")
        }
        writeFile("hao_emby_config.json", bytes: configData, into: docs)
        guard let zipURL = exportZip(using: engine) else { return }
        BackupEngineCore.testEmbyCredentialPresent = false
        defer { BackupEngineCore.testEmbyCredentialPresent = nil }
        guard let missing = importZip(zipURL, using: engine) else {
            return XCTFail("no import result")
        }
        switch missing {
        case .failure(let error):
            XCTFail("import failed: \(error.localizedDescription)")
        case .success(let report):
            XCTAssertTrue(report.embyCredentialsMissing)
        }
        BackupEngineCore.testEmbyCredentialPresent = true
        guard let present = importZip(zipURL, using: engine) else {
            return XCTFail("no import result")
        }
        switch present {
        case .failure(let error):
            XCTFail("import failed: \(error.localizedDescription)")
        case .success(let report):
            XCTAssertFalse(report.embyCredentialsMissing)
        }
    }

    // MARK: - Completions arrive on the main thread

    func testCompletionsArriveOnMainThread() {
        defaults.set("v", forKey: "musicQuality")
        let exportExp = expectation(description: "export on main")
        // Created up front: waitForExpectations only waits for
        // expectations that exist when it is called, so one
        // created inside the export completion is never waited
        // on and the test fails with "unwaited expectation".
        let importExp = expectation(description: "import on main")
        engine.exportBackup(completion: { result in
            XCTAssertTrue(Thread.isMainThread, "export completion must be on the main thread")
            switch result {
            case .success(let zipURL):
                self.engine.importBackup(from: zipURL, completion: { imported in
                    XCTAssertTrue(Thread.isMainThread, "import completion must be on the main thread")
                    switch imported {
                    case .success(let report):
                        XCTAssertFalse(report.rolledBack)
                    case .failure(let error):
                        XCTFail("import failed: \(error.localizedDescription)")
                    }
                    importExp.fulfill()
                })
            case .failure(let error):
                XCTFail("export failed: \(error.localizedDescription)")
                importExp.fulfill()
            }
            exportExp.fulfill()
        })
        waitForExpectations(timeout: 10, handler: nil)
    }

    // MARK: - b49fix22 D24-2: rollback surfaces dropped history

    func testHistoryDroppedLines() {
        // Same wording as the manual restore's restoreMessage
        // and the import warnings — one line per history file,
        // sorted by path, zero counts omitted.
        XCTAssertEqual(
            BackupEngineCore.historyDroppedLines(for: ["hao_video_hist.json": 2, "hao_live_hist.json": 1]),
            ["直播历史有 1 条记录格式不符，已跳过。", "影视历史有 2 条记录格式不符，已跳过。"])
        XCTAssertTrue(BackupEngineCore.historyDroppedLines(for: [:]).isEmpty)
        XCTAssertTrue(BackupEngineCore.historyDroppedLines(for: ["hao_video_hist.json": 0]).isEmpty)
    }
}

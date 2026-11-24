// HAo Studio 2.0 — LX bundled-script refresh tests (build 36 item 6).
//
// Ports the item-6 design harness fixtures (M1–M6) against the real
// `LXScriptRefresh.decision` and `LXScriptFileStore.seedOrRefresh`:
// a stale seed refreshes, a user-modified file is never touched, a
// missing file is seeded, a removed id (`tang`) is never re-seeded
// and its orphan file is deleted. File tests use a temp Documents
// dir (same pattern as LXEngineTests).

import Foundation
import XCTest

@testable import AppCore

final class LXScriptRefreshTests: XCTestCase {
    private var docs: URL!

    override func setUp() {
        super.setUp()
        docs = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-script-refresh-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let docs = docs {
            try? FileManager.default.removeItem(at: docs)
        }
        super.tearDown()
    }

    private var store: LXScriptFileStore { LXScriptFileStore(documentsDirectory: docs) }

    private let oldSuyin = "/* @version v1 */\n// OLD NetEase parsing (broken)\nfoo();"
    private let newSuyin = "/* @version v1 */\n// FIXED NetEase parsing (build 35)\nfoo();"

    private func isWrite(_ decision: LXScriptRefresh, content: String, backup: String?) -> Bool {
        if case .write(let c, let b, _) = decision { return c == content && b == backup }
        return false
    }

    private func isKeep(_ decision: LXScriptRefresh) -> Bool {
        if case .keep = decision { return true }
        return false
    }

    // MARK: - Pure decisions (M1–M6)

    func testM1StalePreFixFileRefreshesWithBackup() {
        let d = LXScriptRefresh.decision(existing: oldSuyin, bundle: newSuyin, storedHash: nil)
        XCTAssertTrue(isWrite(d, content: newSuyin, backup: oldSuyin))
    }

    func testM2PristineSeedRefreshesWithoutBackup() {
        let d = LXScriptRefresh.decision(existing: oldSuyin, bundle: newSuyin, storedHash: LXScriptFileStore.sha256Hex(oldSuyin))
        XCTAssertTrue(isWrite(d, content: newSuyin, backup: nil))
    }

    func testM3UserModifiedFileKept() {
        let userEdit = newSuyin + "\n// my tweak\n"
        let d = LXScriptRefresh.decision(existing: userEdit, bundle: newSuyin + "\n// v2 fix\n", storedHash: LXScriptFileStore.sha256Hex(newSuyin))
        XCTAssertTrue(isKeep(d))
    }

    func testM4MissingFileSeeded() {
        let d = LXScriptRefresh.decision(existing: nil, bundle: newSuyin, storedHash: nil)
        XCTAssertTrue(isWrite(d, content: newSuyin, backup: nil))
    }

    func testM5CurrentFileKept() {
        let d = LXScriptRefresh.decision(existing: newSuyin, bundle: newSuyin, storedHash: LXScriptFileStore.sha256Hex(newSuyin))
        XCTAssertTrue(isKeep(d))
    }

    func testM6RemovedIdNeverReSeeded() {
        let d = LXScriptRefresh.decision(existing: "// tang", bundle: nil, storedHash: nil)
        XCTAssertTrue(isKeep(d))
    }

    func testSHA256IsRealSHA256() {
        XCTAssertEqual(LXScriptFileStore.sha256Hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    // MARK: - File behaviour

    func testSeedOrRefreshStaleFileRefreshesAndBacksUp() {
        let s = store
        XCTAssertTrue(s.write(code: oldSuyin, fileName: "suyin.js"))
        XCTAssertEqual(s.seedOrRefresh(id: "suyin", bundleCode: newSuyin)?.lastPathComponent, "suyin.js")
        XCTAssertEqual(s.read(id: "suyin"), newSuyin)
        XCTAssertEqual(s.readFile(named: "suyin.js.bak"), oldSuyin)
        XCTAssertEqual(s.recordedSeedHash(for: "suyin"), LXScriptFileStore.sha256Hex(newSuyin))
    }

    func testSeedOrRefreshPristineSeedRefreshesWithoutBackup() {
        let s = store
        XCTAssertNotNil(s.seedOrRefresh(id: "suyin", bundleCode: oldSuyin))
        XCTAssertEqual(s.read(id: "suyin"), oldSuyin)
        XCTAssertEqual(s.seedOrRefresh(id: "suyin", bundleCode: newSuyin)?.lastPathComponent, "suyin.js")
        XCTAssertEqual(s.read(id: "suyin"), newSuyin)
        XCTAssertNil(s.readFile(named: "suyin.js.bak"))
    }

    func testSeedOrRefreshNeverTouchesUserModifiedFile() {
        let s = store
        XCTAssertNotNil(s.seedOrRefresh(id: "suyin", bundleCode: newSuyin))
        let userEdit = newSuyin + "\n// my tweak\n"
        XCTAssertTrue(s.write(code: userEdit, fileName: "suyin.js"))
        XCTAssertEqual(s.seedOrRefresh(id: "suyin", bundleCode: newSuyin + "\n// v2 fix\n")?.lastPathComponent, "suyin.js")
        XCTAssertEqual(s.read(id: "suyin"), userEdit)
        XCTAssertEqual(s.recordedSeedHash(for: "suyin"), LXScriptFileStore.sha256Hex(newSuyin))
    }

    func testSeedOrRefreshSeedsMissingFile() {
        let s = store
        XCTAssertNotNil(s.seedOrRefresh(id: "suyin", bundleCode: newSuyin))
        XCTAssertEqual(s.read(id: "suyin"), newSuyin)
    }

    func testSeedOrRefreshKeepsCurrentFile() {
        let s = store
        XCTAssertNotNil(s.seedOrRefresh(id: "suyin", bundleCode: newSuyin))
        XCTAssertEqual(s.seedOrRefresh(id: "suyin", bundleCode: newSuyin)?.lastPathComponent, "suyin.js")
        XCTAssertEqual(s.read(id: "suyin"), newSuyin)
    }

    func testRemovedIdOrphanDeletedAndNeverReSeeded() {
        let s = store
        XCTAssertTrue(LxBundledScript.removedBundledIDs.contains("tang"))
        XCTAssertFalse(LxBundledScript.isBundled("tang"))
        XCTAssertTrue(s.write(code: "// tang", fileName: "tang.js"))
        XCTAssertNil(s.seedOrRefresh(id: "tang", bundleCode: nil))
        XCTAssertEqual(s.read(id: "tang"), "// tang")
        XCTAssertTrue(s.removeOrphanBundledFile(id: "tang"))
        XCTAssertNil(s.read(id: "tang"))
        XCTAssertNil(s.seedOrRefresh(id: "tang", bundleCode: nil))
        XCTAssertNil(s.read(id: "tang"))
    }
}

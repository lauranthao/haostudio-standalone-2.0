// HAo Studio 2.0 — cache manager tests (S5, leg A).
//
// iOS-only (see SettingsStoreTests.swift header): unwired in
// `ios/Package.swift`, runs under the S7 Xcode test target.
// Isolation: all file assertions use a temporary Documents
// directory passed as `documentsURL`; nothing touches the real
// container. The URLCache.shared figure is global, so the size
// test asserts "at least the .part bytes", never an exact total.

import Foundation
import XCTest

@testable import HAoStudio

final class CacheManagerTests: XCTestCase {
    private var docs: URL!

    override func setUp() {
        super.setUp()
        docs = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-cache-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let docs = docs {
            try? FileManager.default.removeItem(at: docs)
        }
        super.tearDown()
    }

    private func writePartFile(named name: String, bytes: Int) {
        let dir = docs.appendingPathComponent(DownloadEngine.downloadSubdir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = Data(repeating: 0x61, count: bytes)
        try? data.write(to: dir.appendingPathComponent(name), options: [.atomic])
    }

    func testPartFilesSizeCountsOnlyPartFiles() {
        writePartFile(named: "a.mp3.part", bytes: 100)
        writePartFile(named: "b.mp3.part", bytes: 250)
        writePartFile(named: "done.mp3", bytes: 9999)
        XCTAssertEqual(CacheManager.partFilesSize(documentsURL: docs), 350)
    }

    func testPartFilesSizeIsZeroWhenDirectoryMissing() {
        XCTAssertEqual(CacheManager.partFilesSize(documentsURL: docs), 0)
    }

    func testTotalSizeIncludesPartFiles() {
        writePartFile(named: "a.mp3.part", bytes: 4096)
        let expectation = self.expectation(description: "totalSizeBytes completes")
        CacheManager.totalSizeBytes(documentsURL: docs) { total in
            XCTAssertGreaterThanOrEqual(total, 4096)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testClearAllRemovesPartFilesButKeepsCompleted() {
        writePartFile(named: "a.mp3.part", bytes: 100)
        writePartFile(named: "done.mp3", bytes: 200)
        let expectation = self.expectation(description: "clearAll completes")
        CacheManager.clearAll(documentsURL: docs) {
            XCTAssertEqual(CacheManager.partFilesSize(documentsURL: self.docs), 0)
            let done = self.docs
                .appendingPathComponent(DownloadEngine.downloadSubdir)
                .appendingPathComponent("done.mp3")
            XCTAssertTrue(FileManager.default.fileExists(atPath: done.path))
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - Wallpaper + avatar stores (same isolation)

    func testWallpaperImportListDeleteRoundTrip() {
        let data = SettingsTestImages.pngData()
        XCTAssertFalse(data.isEmpty)
        let name = WallpaperStore.importImage(data: data, documentsURL: docs)
        XCTAssertNotNil(name)
        XCTAssertTrue(name!.hasPrefix("wallpapers/"))
        XCTAssertTrue(name!.hasSuffix(".jpg"))
        XCTAssertEqual(WallpaperStore.list(documentsURL: docs), [name!])
        let url = WallpaperStore.fileURL(for: name!, documentsURL: docs)
        XCTAssertNotNil(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path))
        WallpaperStore.delete(name!, documentsURL: docs)
        XCTAssertTrue(WallpaperStore.list(documentsURL: docs).isEmpty)
        XCTAssertNil(WallpaperStore.fileURL(for: name!, documentsURL: docs))
    }

    func testWallpaperImportRejectsNonImage() {
        XCTAssertNil(WallpaperStore.importImage(data: Data("not an image".utf8), documentsURL: docs))
        XCTAssertTrue(WallpaperStore.list(documentsURL: docs).isEmpty)
    }

    // （chen 2026-11-24: 个人资料/会员已删，ProfileStore 整文件删除；
    // 测头像存取的两个用例随之删除。）
}

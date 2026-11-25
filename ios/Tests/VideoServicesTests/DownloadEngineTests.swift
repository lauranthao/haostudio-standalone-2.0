// HAo Studio 2.0 — DownloadEngine state-machine tests (S3 leg B).
//
// No network: downloads run against local file:// URLs, which the
// engine copies in chunks on a background queue. A fresh engine
// instance per test; unique keys/file names per test so the
// persisted `downloadTasks` index can never cross-contaminate.
// Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class DownloadEngineTests: XCTestCase {
    private var engine: DownloadEngine!
    private var keys: [String] = []
    private var tempFiles: [URL] = []

    override func setUp() {
        super.setUp()
        engine = DownloadEngine()
        keys = []
        tempFiles = []
    }

    override func tearDown() {
        for key in keys {
            engine.delete(key: key)
        }
        for url in tempFiles {
            try? FileManager.default.removeItem(at: url)
        }
        engine = nil
        super.tearDown()
    }

    private func makeSourceFile(size: Int) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-src-\(UUID().uuidString).bin")
        var data = Data(count: size)
        // Non-zero content so a truncated copy is distinguishable.
        for i in stride(from: 0, to: size, by: 4096) {
            data[i] = UInt8(i & 0xFF)
        }
        try! data.write(to: url)
        tempFiles.append(url)
        return url
    }

    private func request(key: String, source: URL, fileName: String) -> DownloadRequest {
        keys.append(key)
        return DownloadRequest(
            key: key,
            title: "test \(key)",
            sourceURL: source,
            fileName: fileName,
            kind: .music,
            qualityCode: "320k"
        )
    }

    private func downloadsDir() -> URL {
        LocalStore.documentsDirectory().appendingPathComponent(DownloadEngine.downloadSubdir)
    }

    // MARK: - Happy path

    func testFileDownloadCompletesAndLandsAtRelativePath() {
        let key = "t-complete-\(UUID().uuidString)"
        let source = makeSourceFile(size: 256 * 1024)
        let fileName = "test-\(UUID().uuidString).bin"
        let done = expectation(description: "download completes")
        var sawProgress = false
        let req = request(key: key, source: source, fileName: fileName)
        engine.enqueue(request: req, progress: { _, _ in
            sawProgress = true
        }) { info in
            XCTAssertEqual(info.state, .completed)
            XCTAssertEqual(info.downloadedBytes, 256 * 1024)
            XCTAssertEqual(info.totalBytes, 256 * 1024)
            XCTAssertEqual(info.localRelativePath, "music_downloads/\(fileName)")
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(sawProgress)
        let landed = downloadsDir().appendingPathComponent(fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: landed.path))
        XCTAssertEqual((try? Data(contentsOf: landed))?.count, 256 * 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsDir().appendingPathComponent(DownloadEngine.partFileName(for: req)).path))
    }

    // MARK: - Duplicate key

    func testDuplicateEnqueueReturnsExistingTask() {
        let key = "t-dup-\(UUID().uuidString)"
        // 2 MB, not 8: the full copy is what this test waits on, and
        // the same 8 MB copy took 19.69 s on Bitrise #31 (20 s
        // timeout) — the test asserts dedup, not throughput.
        let source = makeSourceFile(size: 2 * 1024 * 1024)
        engine.testChunkDelay = 0.05
        let done = expectation(description: "download completes")
        let first = engine.enqueue(request: request(key: key, source: source, fileName: "dup.bin")) { _ in
            done.fulfill()
        }
        XCTAssertEqual(first.state, .queued)
        let second = engine.enqueue(request: request(key: key, source: source, fileName: "dup.bin"))
        XCTAssertEqual(second.request.key, key)
        XCTAssertEqual(engine.allTasks().filter { $0.request.key == key }.count, 1)
        wait(for: [done], timeout: 20)
    }

    // MARK: - Pause / resume

    func testPauseThenResumeCompletes() {
        let key = "t-pause-\(UUID().uuidString)"
        // 2 MB, not 8: the resume phase alone must fit the 20 s
        // deadline, and the same 8 MB copy took 19.69 s on Bitrise
        // #31 — pause + resume of 8 MB cannot fit 20 s on a loaded
        // runner. The assertions (paused, partial part, resume
        // completes) are unchanged.
        let source = makeSourceFile(size: 2 * 1024 * 1024)
        let fileName = "pause-\(UUID().uuidString).bin"
        engine.testChunkDelay = 0.05
        let progressSeen = expectation(description: "first progress then pause")
        var didPause = false
        let req = request(key: key, source: source, fileName: fileName)
        engine.enqueue(request: req, progress: { [weak self] downloaded, _ in
            guard let self = self, !didPause, downloaded > 0 else { return }
            didPause = true
            self.engine.pause(key: key)
            progressSeen.fulfill()
        }, completion: nil)
        wait(for: [progressSeen], timeout: 10)

        // Paused mid-file: part file exists, partial, no final file.
        let info = engine.taskInfo(for: key)
        XCTAssertEqual(info?.state, .paused)
        let part = downloadsDir().appendingPathComponent(DownloadEngine.partFileName(for: req))
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
        let partSize = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(partSize, 0)
        XCTAssertLessThan(partSize, 2 * 1024 * 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsDir().appendingPathComponent(fileName).path))

        // Resume from the part file and finish.
        engine.resume(key: key)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if engine.taskInfo(for: key)?.state == .completed { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(engine.taskInfo(for: key)?.state, .completed)
        XCTAssertEqual(engine.taskInfo(for: key)?.downloadedBytes, 2 * 1024 * 1024)
    }

    // MARK: - Cancel

    func testCancelDeletesPartFile() {
        let key = "t-cancel-\(UUID().uuidString)"
        let source = makeSourceFile(size: 8 * 1024 * 1024)
        let fileName = "cancel-\(UUID().uuidString).bin"
        engine.testChunkDelay = 0.05
        let cancelled = expectation(description: "cancel completes")
        var didCancel = false
        let req = request(key: key, source: source, fileName: fileName)
        engine.enqueue(request: req, progress: { [weak self] downloaded, _ in
            guard let self = self, !didCancel, downloaded > 0 else { return }
            didCancel = true
            self.engine.cancel(key: key)
        }) { info in
            XCTAssertEqual(info.state, .cancelled)
            cancelled.fulfill()
        }
        wait(for: [cancelled], timeout: 10)
        let part = downloadsDir().appendingPathComponent(DownloadEngine.partFileName(for: req))
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsDir().appendingPathComponent(fileName).path))
    }

    // MARK: - Failure

    func testUnsupportedSchemeIsNotDownloadable() {
        let key = "t-badscheme-\(UUID().uuidString)"
        let failed = expectation(description: "unsupported scheme is not downloadable")
        engine.enqueue(request: DownloadRequest(
            key: key,
            title: "bad",
            sourceURL: URL(string: "ftp://example.com/x.mp3")!,
            fileName: "bad.mp3",
            kind: .music,
            qualityCode: "320k"
        )) { info in
            // b45-F 12-state machine: an unsupported scheme is
            // "暂不可下载", not a failure.
            XCTAssertEqual(info.state, .notDownloadable)
            XCTAssertEqual(info.errorMessage, "暂不可下载")
            failed.fulfill()
        }
        keys.append(key)
        wait(for: [failed], timeout: 10)
    }

    func testMissingLocalFileFails() {
        let key = "t-missing-\(UUID().uuidString)"
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).bin")
        let failed = expectation(description: "missing file fails")
        engine.enqueue(request: request(key: key, source: missing, fileName: "missing.bin")) { info in
            XCTAssertEqual(info.state, .failed)
            failed.fulfill()
        }
        wait(for: [failed], timeout: 10)
    }

    // MARK: - File-name sanitising

    func testSanitisedFileName() {
        XCTAssertEqual(DownloadEngine.sanitisedFileName("a/b\\c:d.mp3", fallbackKey: "k"), "a_b_c_d.mp3")
        XCTAssertEqual(DownloadEngine.sanitisedFileName("../evil.mp3", fallbackKey: "k"), "evil.mp3")
        XCTAssertEqual(DownloadEngine.sanitisedFileName("", fallbackKey: "k"), "k.bin")
        XCTAssertEqual(DownloadEngine.sanitisedFileName("  song.mp3  ", fallbackKey: "k"), "song.mp3")
    }

    // MARK: - §2.1 Problem A: malicious fallbackKey

    func testSanitisedFileNameMaliciousFallbackKey() {
        XCTAssertEqual(DownloadEngine.sanitisedFileName("", fallbackKey: "../../evil"), "evil.bin")
        XCTAssertEqual(DownloadEngine.sanitisedFileName("", fallbackKey: "a/b"), "a_b.bin")
        XCTAssertEqual(DownloadEngine.sanitisedFileName("", fallbackKey: "/abs"), "abs.bin")
        XCTAssertEqual(DownloadEngine.sanitisedFileName("", fallbackKey: "x:y"), "x_y.bin")
        XCTAssertEqual(DownloadEngine.sanitisedFileName("...", fallbackKey: "../../evil"), "evil.bin")
        XCTAssertEqual(DownloadEngine.sanitisedFileName("", fallbackKey: "..."), "download.bin")
        // A flat name must never contain a separator, whatever the key.
        for key in ["../../evil", "a/b/c", "/tmp/x", "a:b:c", "..", "."] {
            let name = DownloadEngine.sanitisedFileName("", fallbackKey: key)
            XCTAssertFalse(name.contains("/"))
            XCTAssertFalse(name.contains("\\"))
            XCTAssertFalse(name.hasPrefix("."))
        }
    }

    // MARK: - §2.1 Problem B: Content-Range validation

    func testParseContentRange() {
        let range = DownloadEngine.parseContentRange("bytes 0-1023/4096")
        XCTAssertEqual(range?.start, 0)
        XCTAssertEqual(range?.end, 1023)
        XCTAssertEqual(range?.total, 4096)
        XCTAssertEqual(DownloadEngine.parseContentRange("bytes 512-1023/*")?.total, nil)
        XCTAssertNil(DownloadEngine.parseContentRange("bytes 10-5/100"))
        XCTAssertNil(DownloadEngine.parseContentRange("items 0-9/10"))
        XCTAssertNil(DownloadEngine.parseContentRange("bytes abc-def/100"))
        XCTAssertNil(DownloadEngine.parseContentRange("bytes 0-1023"))
        XCTAssertNil(DownloadEngine.parseContentRange(""))
    }

    func testValidateResumeResponse() {
        // Correct 206 for a fresh 0-byte part, full file 1024.
        if case .valid(let total) = DownloadEngine.validateResumeResponse(contentRange: "bytes 0-1023/1024", contentLength: 1024, baseOffset: 0) {
            XCTAssertEqual(total, 1024)
        } else {
            XCTFail("correct 206 must validate")
        }
        // Wrong start offset.
        if case .invalid = DownloadEngine.validateResumeResponse(contentRange: "bytes 500-1023/1024", contentLength: 524, baseOffset: 0) {
        } else { XCTFail("wrong start must fail") }
        // Missing Content-Range.
        if case .invalid = DownloadEngine.validateResumeResponse(contentRange: nil, contentLength: 1024, baseOffset: 0) {
        } else { XCTFail("missing Content-Range must fail") }
        // Content-Length disagrees with the range.
        if case .invalid = DownloadEngine.validateResumeResponse(contentRange: "bytes 0-511/1024", contentLength: 1024, baseOffset: 0) {
        } else { XCTFail("length mismatch must fail") }
        // Total disagrees with the segment.
        if case .invalid = DownloadEngine.validateResumeResponse(contentRange: "bytes 0-1023/2048", contentLength: 1024, baseOffset: 0) {
        } else { XCTFail("total mismatch must fail") }
        // Unknown total (*) is accepted when the segment is consistent.
        if case .valid(let total) = DownloadEngine.validateResumeResponse(contentRange: "bytes 512-1023/*", contentLength: 512, baseOffset: 512) {
            XCTAssertEqual(total, 1024)
        } else {
            XCTFail("unknown-total 206 must validate")
        }
    }

    // MARK: - §2.1 Problem D: same file name, different tasks

    func testSameFileNameCrossTaskCollision() {
        let fileName = "collision-\(UUID().uuidString).bin"
        let key1 = "t-col1-\(UUID().uuidString)"
        let key2 = "t-col2-\(UUID().uuidString)"
        let source1 = makeSourceFile(size: 64 * 1024)
        let source2 = makeSourceFile(size: 128 * 1024)
        let done1 = expectation(description: "first completes")
        let done2 = expectation(description: "second completes")
        var info1: DownloadTaskInfo?
        var info2: DownloadTaskInfo?
        engine.enqueue(request: request(key: key1, source: source1, fileName: fileName)) { info in
            info1 = info
            done1.fulfill()
        }
        engine.enqueue(request: request(key: key2, source: source2, fileName: fileName)) { info in
            info2 = info
            done2.fulfill()
        }
        wait(for: [done1, done2], timeout: 20)
        XCTAssertEqual(info1?.state, .completed)
        XCTAssertEqual(info2?.state, .completed)
        let path1 = info1?.localRelativePath
        let path2 = info2?.localRelativePath
        XCTAssertNotNil(path1)
        XCTAssertNotEqual(path1, path2)
        // Each task's path holds its own bytes.
        for info in [info1, info2] {
            guard let info = info, let relative = info.localRelativePath,
                  let url = LocalFileIndex.resolve(relative, subdir: DownloadEngine.downloadSubdir) else {
                XCTFail("missing path for \(String(describing: info?.request.key))")
                continue
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual((try? Data(contentsOf: url))?.count, Int(info.downloadedBytes))
        }
        // One of them kept the plain name.
        XCTAssertTrue([path1, path2].contains("music_downloads/\(fileName)"))
    }

    // MARK: - §2.1 Finding E: restore validation

    func testRestoreMarksCompletedTaskWithMissingFileFailed() {
        let key = "t-restore-drop-\(UUID().uuidString)"
        let source = makeSourceFile(size: 64 * 1024)
        let fileName = "restore-drop-\(UUID().uuidString).bin"
        let done = expectation(description: "download completes")
        engine.enqueue(request: request(key: key, source: source, fileName: fileName)) { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(engine.taskInfo(for: key)?.state, .completed)
        // Delete the landed file out from under the index.
        let landed = downloadsDir().appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: landed)
        // A fresh engine restores the persisted index — b45-F (plan
        // §9.3): a completed entry whose file is gone becomes a
        // FAILED task with a message, not a silent drop.
        let restored = DownloadEngine()
        XCTAssertEqual(restored.taskInfo(for: key)?.state, .failed)
        XCTAssertEqual(restored.taskInfo(for: key)?.errorMessage, "本地文件缺失，请重新下载")
        XCTAssertTrue(restored.allTasks().contains { $0.request.key == key })
    }

    func testRestoreClampsStaleDownloadedBytes() {
        let key = "t-restore-clamp-\(UUID().uuidString)"
        let source = makeSourceFile(size: 8 * 1024 * 1024)
        let fileName = "restore-clamp-\(UUID().uuidString).bin"
        engine.testChunkDelay = 0.05
        let progressSeen = expectation(description: "first progress then pause")
        var didPause = false
        let req = request(key: key, source: source, fileName: fileName)
        engine.enqueue(request: req, progress: { [weak self] downloaded, _ in
            guard let self = self, !didPause, downloaded > 0 else { return }
            didPause = true
            self.engine.pause(key: key)
            progressSeen.fulfill()
        }, completion: nil)
        wait(for: [progressSeen], timeout: 10)
        let part = downloadsDir().appendingPathComponent(DownloadEngine.partFileName(for: req))
        let partSize = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(partSize, 0)
        // Corrupt the persisted count (simulates a kill mid-download
        // with a stale in-memory value) and restore in a fresh engine.
        var infos: [DownloadTaskInfo] = LocalStore.loadCollection(named: DownloadEngine.tasksCollection, default: [])
        guard let idx = infos.firstIndex(where: { $0.request.key == key }) else {
            XCTFail("task not persisted")
            return
        }
        infos[idx].downloadedBytes = partSize + 1_000_000
        LocalStore.saveCollection(named: DownloadEngine.tasksCollection, value: infos)
        let restored = DownloadEngine()
        XCTAssertEqual(restored.taskInfo(for: key)?.state, .paused)
        XCTAssertEqual(restored.taskInfo(for: key)?.downloadedBytes, partSize)
    }

    // MARK: - b49fix22 D24-4: imported tasks reconcile without a restart

    func testImportedMirrorTaskAppearsAfterBackupImportedNotification() {
        let key = "t-import-\(UUID().uuidString)"
        let fileName = "imported-\(UUID().uuidString).mp3"
        let info = DownloadTaskInfo(
            request: DownloadRequest(key: key, title: "imported", sourceURL: URL(string: "https://example.com/x.mp3")!, fileName: fileName, kind: .music, qualityCode: "320k"),
            state: .paused, downloadedBytes: 0, totalBytes: 0,
            errorMessage: nil, localRelativePath: nil)
        // Simulate the import: the mirror holds the task, the
        // engine has no live record for it. Append to the
        // existing mirror — never overwrite it whole, other
        // tests' entries live there too.
        var mirror: [DownloadTaskInfo] = LocalStore.loadCollection(named: DownloadEngine.tasksCollection, default: [])
        mirror.append(info)
        LocalStore.saveCollection(named: DownloadEngine.tasksCollection, value: mirror)
        XCTAssertNil(engine.taskInfo(for: key))
        NotificationCenter.default.post(name: .haoBackupImported, object: nil)
        // taskInfo serialises on syncQueue behind the reconcile.
        XCTAssertEqual(engine.taskInfo(for: key)?.state, .paused)
        XCTAssertTrue(engine.allTasks().contains { $0.request.key == key })
        // Paused, never auto-started: still paused a second later.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(engine.taskInfo(for: key)?.state, .paused)
        keys.append(key)
    }

    // MARK: - b49fix22 D24-5: delete is atomic and reports catalog failure

    func testDeleteRemovesTaskFromMirrorAndCatalog() {
        let key = "t-del-\(UUID().uuidString)"
        let source = makeSourceFile(size: 64 * 1024)
        let fileName = "delete-\(UUID().uuidString).bin"
        let done = expectation(description: "download completes")
        engine.enqueue(request: request(key: key, source: source, fileName: fileName)) { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(engine.taskInfo(for: key)?.state, .completed)
        // The completed task is in the catalog and the mirror.
        XCTAssertTrue((DownloadCatalogStore.load()?.tasks ?? []).contains { $0.request.key == key })
        XCTAssertTrue((LocalStore.loadCollection(named: DownloadEngine.tasksCollection, default: []) as [DownloadTaskInfo]).contains { $0.request.key == key })
        XCTAssertTrue(engine.delete(key: key))
        XCTAssertNil(engine.taskInfo(for: key))
        XCTAssertFalse((LocalStore.loadCollection(named: DownloadEngine.tasksCollection, default: []) as [DownloadTaskInfo]).contains { $0.request.key == key })
        XCTAssertFalse((DownloadCatalogStore.load()?.tasks ?? []).contains { $0.request.key == key })
        // No resurrection on the next launch either.
        let restored = DownloadEngine()
        XCTAssertNil(restored.taskInfo(for: key))
        // Deleting again is a no-op success, not a failure.
        XCTAssertTrue(engine.delete(key: key))
    }
}

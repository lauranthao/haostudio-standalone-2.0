// HAo Studio 2.0 — shared download engine (S3 leg B).
//
// Music + video share ONE engine. Foundation-only, completion
// handlers (Swift 5.0: no async/await, no `any`).
//
// - Max 2 concurrent downloads, FIFO queue.
// - http(s): URLSession data task with `Range` resume. A 206
//   continues the existing `.part` file; a 200 (server ignores
//   Range) truncates and restarts from 0. Chunks stream to disk
//   through the session delegate — a whole file is never held in
//   memory.
// - file:// URLs are copied in chunks on a background queue.
//   That path exists so tests can drive the whole state machine
//   (enqueue → progress → pause → resume → complete / cancel)
//   with a local file and no network.
// - Partial files live as `<fileName>.part` in
//   `Documents/music_downloads/`; on completion the part file is
//   moved to the final name. Only RELATIVE names are ever
//   persisted (`music_downloads/<file>`) — the app container UUID
//   changes on every reinstall, so an absolute path stored in an
//   index dies with the old container (see LocalStore).
// - The task index is persisted in the `downloadTasks` collection
//   (LocalStore). The engine does NOT depend on MusicLibraryStore:
//   the music view model registers a completed file into the
//   existing downloads index on completion. A relaunch restores
//   in-flight tasks as paused (the `.part` file on disk makes them
//   resumable); nothing auto-starts on launch.
//
// Pause is cooperative: the in-flight task is cancelled and the
// `.part` file kept; resume re-issues the request with
// `Range: bytes=<downloaded>-`. Cancel deletes the `.part` file.

import Foundation

// MARK: - Public types

enum DownloadKind: String, Codable {
    case music
    case video
}

struct DownloadRequest: Codable, Equatable {
    /// Stable key, e.g. the song id or `emby:<itemId>`. One active
    /// task per key — enqueueing the same key twice returns the
    /// existing task instead of a duplicate download.
    let key: String
    let title: String
    let sourceURL: URL
    let fileName: String
    let kind: DownloadKind
    /// Quality code as shown in the UI (e.g. "flac", "320k").
    /// The engine never interprets it; the caller does.
    let qualityCode: String
}

enum DownloadState: String, Codable {
    case queued
    case downloading
    case paused
    case completed
    case failed
    case cancelled
}

/// Serializable snapshot of one task. `localRelativePath` is set
/// only once the file is complete.
struct DownloadTaskInfo: Codable, Equatable {
    var request: DownloadRequest
    var state: DownloadState
    var downloadedBytes: Int64
    /// Total bytes when the server / file reports a size, -1 when
    /// unknown.
    var totalBytes: Int64
    var errorMessage: String?
    var localRelativePath: String?
}

// MARK: - Engine

final class DownloadEngine: NSObject {
    static let shared = DownloadEngine()

    /// Subdirectory of Documents holding downloads + part files.
    static let downloadSubdir = "music_downloads"
    /// Collection name for the persisted task index.
    static let tasksCollection = "downloadTasks"
    /// Max concurrent downloads.
    static let maxConcurrent = 2

    /// Test seam: artificial delay between file-copy chunks, so a
    /// test can observe pause/resume on a local file. Production
    /// leaves it at 0.
    var testChunkDelay: TimeInterval = 0

    private final class TaskRecord {
        var info: DownloadTaskInfo
        var progress: ((Int64, Int64) -> Void)?
        var completion: ((DownloadTaskInfo) -> Void)?
        var sessionTask: URLSessionTask?
        var fileHandle: FileHandle?
        /// Bytes already on disk when the current attempt started
        /// (the Range offset for a 206 resume).
        var baseOffset: Int64 = 0
        /// Expected total for the current attempt (baseOffset +
        /// Content-Length), -1 when unknown.
        var expectedTotal: Int64 = -1
        /// Set by pause/cancel; the delegate / copy loop checks it
        /// between chunks.
        var stopRequested = false
        /// Generation of the current copy attempt. A resume starts
        /// a new attempt while the old loop may still be alive (it
        /// only notices the stop between chunks); the old loop must
        /// not write progress, bytes, or a terminal state for the
        /// new attempt — it checks this every iteration and on exit.
        var attempt: Int = 0
        /// Set when a 416 response restarts the download from 0;
        /// httpDidComplete re-issues the request when it sees the
        /// cancelled task. Guarded by `restartedAfter416` so a
        /// server that always 416s fails instead of looping.
        var restartAfter416Pending = false
        var restartedAfter416 = false

        init(info: DownloadTaskInfo) {
            self.info = info
        }
    }

    private let syncQueue = DispatchQueue(label: "com.haostudio.downloadengine", qos: .utility)
    private let workQueue = DispatchQueue(label: "com.haostudio.downloadwork", qos: .utility, attributes: .concurrent)
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 0
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return URLSession(configuration: config, delegate: DownloadSessionDelegate(engine: self), delegateQueue: queue)
    }()

    private var records: [String: TaskRecord] = [:]
    /// Enqueue order, for a stable snapshot.
    private var order: [String] = []

    override init() {
        super.init()
        restorePersistedTasks()
    }

    // MARK: Directories / paths

    private func downloadsDirectory() -> URL {
        let dir = LocalStore.documentsDirectory().appendingPathComponent(DownloadEngine.downloadSubdir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// One path component, safe to append under the downloads dir:
    /// no separators, no parent traversal, no control characters.
    static func sanitiseComponent(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        name = name.components(separatedBy: .controlCharacters).joined()
        for bad in ["/", "\\", ":"] {
            name = name.replacingOccurrences(of: bad, with: "_")
        }
        // Strip leading dots AND underscores: the separator
        // replacement above turns "../evil.mp3" into ".._evil.mp3",
        // and the leading "_" must go too.
        while name.hasPrefix(".") || name.hasPrefix("_") { name = String(name.dropFirst()) }
        return name
    }

    /// Sanitised file name: no separators, no parent traversal.
    /// The fallback key goes through the SAME sanitising — it used
    /// to be used verbatim (§2.1 Problem A), so a key containing
    /// `../` controlled the filesystem path.
    static func sanitisedFileName(_ raw: String, fallbackKey: String) -> String {
        let name = sanitiseComponent(raw)
        if name.isEmpty {
            let fallback = sanitiseComponent(fallbackKey)
            return fallback.isEmpty ? "download.bin" : "\(fallback).bin"
        }
        return name
    }

    private func finalURL(for request: DownloadRequest) -> URL {
        let dir = downloadsDirectory()
        let name = DownloadEngine.sanitisedFileName(request.fileName, fallbackKey: request.key)
        let final = dir.appendingPathComponent(name)
        // Belt-and-braces containment: the sanitised name is a flat
        // component by construction, but never let a file land
        // outside the downloads dir even if sanitising regresses.
        if final.standardized.path.hasPrefix(dir.standardized.path + "/") {
            return final
        }
        return dir.appendingPathComponent(UUID().uuidString + ".bin")
    }

    private func partURL(for request: DownloadRequest) -> URL {
        finalURL(for: request).appendingPathExtension("part")
    }

    /// Relative name for the index (`music_downloads/<file>`).
    static func relativePath(for fileName: String) -> String {
        "\(downloadSubdir)/\(fileName)"
    }

    // MARK: - Resume validation (§2.1 Problem B)

    /// Parsed `Content-Range: bytes <start>-<end>/<total>`; total is
    /// nil for `*` (unknown total).
    struct ContentRange {
        let start: Int64
        let end: Int64
        let total: Int64?
    }

    /// Pure parser, unit-tested (DownloadEngineTests).
    static func parseContentRange(_ value: String) -> ContentRange? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("bytes ") else { return nil }
        let rest = String(trimmed.dropFirst("bytes ".count))
        let parts = rest.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let rangeParts = parts[0].split(separator: "-")
        guard rangeParts.count == 2,
              let start = Int64(rangeParts[0]),
              let end = Int64(rangeParts[1]) else { return nil }
        let total: Int64?
        if parts[1] == "*" {
            total = nil
        } else {
            guard let parsed = Int64(parts[1]) else { return nil }
            total = parsed
        }
        guard start >= 0, end >= start else { return nil }
        return ContentRange(start: start, end: end, total: total)
    }

    /// Outcome of validating a 206 resume response against the part
    /// on disk. The engine always requests an open-ended range
    /// (`bytes=<base>-`), so a well-formed 206 must start at
    /// baseOffset and run to the end of the file.
    enum ResumeResponseValidation {
        case valid(expectedTotal: Int64)
        case invalid(reason: String)
    }

    /// Pure decision function, unit-tested (DownloadEngineTests).
    static func validateResumeResponse(contentRange: String?, contentLength: Int64?, baseOffset: Int64) -> ResumeResponseValidation {
        guard let rangeString = contentRange,
              let range = parseContentRange(rangeString) else {
            return .invalid(reason: "服务器返回的分段信息无效")
        }
        guard range.start == baseOffset else {
            return .invalid(reason: "服务器返回的分段起始位置不符")
        }
        let segmentLength = range.end - range.start + 1
        if let length = contentLength, length != segmentLength {
            return .invalid(reason: "服务器返回的分段长度不符")
        }
        let expectedTotal = baseOffset + segmentLength
        if let total = range.total, total != expectedTotal {
            return .invalid(reason: "服务器返回的文件总长度不符")
        }
        return .valid(expectedTotal: expectedTotal)
    }

    // MARK: Public API

    /// Enqueue a download. An already-active task with the same key
    /// (queued / downloading / paused) is returned unchanged —
    /// never a duplicate. A finished task with the same key
    /// (completed / failed / cancelled) is replaced by a fresh one.
    /// Progress and completion are called on the main queue;
    /// completion fires exactly once, when the task reaches a
    /// terminal state.
    @discardableResult
    func enqueue(request: DownloadRequest, progress: ((Int64, Int64) -> Void)? = nil, completion: ((DownloadTaskInfo) -> Void)? = nil) -> DownloadTaskInfo {
        var result: DownloadTaskInfo!
        syncQueue.sync {
            if let existing = records[request.key], existing.info.state == .queued || existing.info.state == .downloading || existing.info.state == .paused {
                if let progress = progress { existing.progress = progress }
                if let completion = completion { existing.completion = completion }
                result = existing.info
                return
            }
            let info = DownloadTaskInfo(request: request, state: .queued, downloadedBytes: 0, totalBytes: -1, errorMessage: nil, localRelativePath: nil)
            let record = TaskRecord(info: info)
            record.progress = progress
            record.completion = completion
            records[request.key] = record
            if !order.contains(request.key) { order.append(request.key) }
            result = info
            persistLocked()
            startNextLocked()
        }
        return result
    }

    func pause(key: String) {
        syncQueue.sync {
            guard let record = records[key] else { return }
            switch record.info.state {
            case .downloading:
                record.stopRequested = true
                record.sessionTask?.cancel()
                record.info.state = .paused
                closeHandleLocked(record)
                persistLocked()
            case .queued:
                record.info.state = .paused
                persistLocked()
            default:
                return
            }
        }
    }

    func resume(key: String) {
        syncQueue.sync {
            guard let record = records[key] else { return }
            guard record.info.state == .paused || record.info.state == .failed else { return }
            record.info.state = .queued
            record.info.errorMessage = nil
            record.stopRequested = false
            persistLocked()
            startNextLocked()
        }
    }

    func cancel(key: String) {
        syncQueue.sync {
            guard let record = records[key] else { return }
            switch record.info.state {
            case .completed, .cancelled:
                return
            default:
                break
            }
            record.stopRequested = true
            record.sessionTask?.cancel()
            closeHandleLocked(record)
            try? FileManager.default.removeItem(at: partURL(for: record.info.request))
            finishLocked(record, state: .cancelled, errorMessage: nil)
        }
    }

    /// Remove a task record (and its file when completed). The
    /// downloads list uses this for its delete action.
    func delete(key: String) {
        syncQueue.sync {
            guard let record = records[key] else { return }
            if record.info.state == .downloading || record.info.state == .queued {
                record.stopRequested = true
                record.sessionTask?.cancel()
                closeHandleLocked(record)
            }
            try? FileManager.default.removeItem(at: partURL(for: record.info.request))
            if let relative = record.info.localRelativePath,
               let url = LocalFileIndex.resolve(relative, subdir: DownloadEngine.downloadSubdir) {
                try? FileManager.default.removeItem(at: url)
            }
            records.removeValue(forKey: key)
            order.removeAll { $0 == key }
            persistLocked()
        }
    }

    func taskInfo(for key: String) -> DownloadTaskInfo? {
        syncQueue.sync { records[key]?.info }
    }

    /// Snapshot of all tasks, in enqueue order.
    func allTasks() -> [DownloadTaskInfo] {
        syncQueue.sync { order.compactMap { records[$0]?.info } }
    }

    // MARK: Scheduling (syncQueue only)

    private func activeCountLocked() -> Int {
        records.values.filter { $0.info.state == .downloading }.count
    }

    private func startNextLocked() {
        while activeCountLocked() < DownloadEngine.maxConcurrent {
            guard let next = order.compactMap({ records[$0] }).first(where: { $0.info.state == .queued }) else { return }
            startLocked(next)
        }
    }

    private func startLocked(_ record: TaskRecord) {
        record.info.state = .downloading
        record.stopRequested = false
        let request = record.info.request
        guard let scheme = request.sourceURL.scheme?.lowercased() else {
            finishLocked(record, state: .failed, errorMessage: "不支持的下载地址")
            return
        }
        if scheme == "file" {
            startFileCopyLocked(record)
            return
        }
        if scheme != "http" && scheme != "https" {
            finishLocked(record, state: .failed, errorMessage: "不支持的下载地址")
            return
        }
        startHTTPDownloadLocked(record)
    }

    // MARK: HTTP download (Range resume)

    private func startHTTPDownloadLocked(_ record: TaskRecord) {
        let request = record.info.request
        let part = partURL(for: request)
        let existing = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        record.baseOffset = existing
        // Finding E: the part size on disk is the truth — reconcile
        // downloadedBytes with it, or a kill-and-restore resume
        // restarts the count from the stale persisted value and a
        // byte-complete file is marked failed.
        record.info.downloadedBytes = existing
        record.expectedTotal = -1
        record.restartAfter416Pending = false
        record.restartedAfter416 = false
        var urlRequest = URLRequest(url: request.sourceURL, timeoutInterval: 60)
        if existing > 0 {
            urlRequest.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        let handle: FileHandle
        if existing > 0 {
            guard let h = try? FileHandle(forUpdating: part) else {
                finishLocked(record, state: .failed, errorMessage: "无法打开下载文件")
                return
            }
            handle = h
            // seekToEnd() needs macOS 10.15.4; the package targets
            // 10.15.0, so use the long-available seekToEndOfFile().
            _ = handle.seekToEndOfFile()
        } else {
            FileManager.default.createFile(atPath: part.path, contents: nil)
            guard let h = try? FileHandle(forWritingTo: part) else {
                finishLocked(record, state: .failed, errorMessage: "无法创建下载文件")
                return
            }
            handle = h
        }
        record.fileHandle = handle
        record.sessionTask = session.dataTask(with: urlRequest)
        record.sessionTask?.resume()
    }

    /// Called by the session delegate on the delegate queue; hops
    /// onto syncQueue for all state mutation.
    fileprivate func httpDidReceiveResponse(_ task: URLSessionTask, response: HTTPURLResponse) {
        syncQueue.async {
            guard let record = self.record(forSessionTask: task) else { return }
            if record.stopRequested { return }
            if response.statusCode == 206 {
                // Server honours Range: validate the segment before
                // appending anything (§2.1 Problem B). A wrong
                // segment must never pollute the .part file.
                let contentLength = response.value(forHTTPHeaderField: "Content-Length").flatMap({ Int64($0) })
                switch DownloadEngine.validateResumeResponse(
                    contentRange: response.value(forHTTPHeaderField: "Content-Range"),
                    contentLength: contentLength,
                    baseOffset: record.baseOffset) {
                case .valid(let expectedTotal):
                    record.expectedTotal = expectedTotal
                    record.info.totalBytes = expectedTotal
                    // Finding E: reconcile with the part on disk.
                    record.info.downloadedBytes = record.baseOffset
                case .invalid(let reason):
                    // Discard the part so a later resume restarts
                    // from 0 instead of appending to bad bytes.
                    self.closeHandleLocked(record)
                    try? FileManager.default.removeItem(at: self.partURL(for: record.info.request))
                    self.finishLocked(record, state: .failed, errorMessage: reason)
                    return
                }
            } else if response.statusCode == 200 {
                // Server ignores Range: restart from 0.
                record.baseOffset = 0
                record.info.downloadedBytes = 0
                self.closeHandleLocked(record)
                let part = self.partURL(for: record.info.request)
                try? FileManager.default.removeItem(at: part)
                FileManager.default.createFile(atPath: part.path, contents: nil)
                guard let handle = try? FileHandle(forWritingTo: part) else {
                    // §2.1 Problem C: a nil replacement handle used
                    // to silently drop all data and, with no
                    // Content-Length, complete an empty file.
                    self.finishLocked(record, state: .failed, errorMessage: "无法创建下载文件")
                    return
                }
                record.fileHandle = handle
                if let length = response.value(forHTTPHeaderField: "Content-Length").flatMap({ Int64($0) }), length >= 0 {
                    record.expectedTotal = length
                    record.info.totalBytes = length
                }
            } else if response.statusCode == 416 {
                // Range no longer satisfiable (part past EOF after a
                // server-side change): restart from 0 once. A second
                // 416 means the server will never serve this URL.
                if record.restartedAfter416 {
                    self.finishLocked(record, state: .failed, errorMessage: "服务器返回了错误（416）")
                    return
                }
                record.restartedAfter416 = true
                record.restartAfter416Pending = true
                self.closeHandleLocked(record)
                try? FileManager.default.removeItem(at: self.partURL(for: record.info.request))
                record.baseOffset = 0
                record.info.downloadedBytes = 0
                record.expectedTotal = -1
                task.cancel()
                return
            } else {
                record.stopRequested = true
                task.cancel()
                self.finishLocked(record, state: .failed, errorMessage: "服务器返回了错误（\(response.statusCode)）")
                return
            }
            self.persistLocked()
        }
    }

    /// Called by the session delegate on the delegate queue.
    fileprivate func httpDidReceiveData(_ task: URLSessionTask, data: Data) {
        syncQueue.async {
            guard let record = self.record(forSessionTask: task) else { return }
            if record.stopRequested { return }
            guard let handle = record.fileHandle else { return }
            // Over-long segment: the part cannot be trusted, discard
            // it so a later resume restarts from 0 (§2.1 Problem B).
            if record.expectedTotal >= 0 && record.info.downloadedBytes + Int64(data.count) > record.expectedTotal {
                record.stopRequested = true
                task.cancel()
                self.closeHandleLocked(record)
                try? FileManager.default.removeItem(at: self.partURL(for: record.info.request))
                self.finishLocked(record, state: .failed, errorMessage: "服务器返回了过长的数据")
                return
            }
            // A failed write (disk full) is silent with the
            // non-throwing API — verify the offset advanced (§2.1 C).
            let offsetBefore = handle.offsetInFile
            handle.write(data)
            if handle.offsetInFile != offsetBefore + UInt64(data.count) {
                record.stopRequested = true
                task.cancel()
                self.closeHandleLocked(record)
                self.finishLocked(record, state: .failed, errorMessage: "写入下载文件失败")
                return
            }
            record.info.downloadedBytes += Int64(data.count)
            let downloaded = record.info.downloadedBytes
            let total = record.info.totalBytes
            let progress = record.progress
            if let progress = progress {
                DispatchQueue.main.async { progress(downloaded, total) }
            }
        }
    }

    /// Called by the session delegate on the delegate queue.
    fileprivate func httpDidComplete(_ task: URLSessionTask, error: Error?) {
        syncQueue.async {
            guard let record = self.record(forSessionTask: task) else { return }
            record.sessionTask = nil
            self.closeHandleLocked(record)
            if record.stopRequested {
                // Pause or cancel already set the state; the
                // completion callback for a pause fires only on the
                // later resume/terminal outcome. A cancelled task
                // was already finished by cancel().
                if record.info.state == .paused {
                    self.startNextLocked()
                }
                return
            }
            if let error = error {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                    // 416 restart: re-issue from 0 (§2.1 Problem C).
                    if record.restartAfter416Pending {
                        record.restartAfter416Pending = false
                        self.startHTTPDownloadLocked(record)
                    }
                    return
                }
                self.finishLocked(record, state: .failed, errorMessage: error.localizedDescription)
                return
            }
            if record.expectedTotal >= 0 && record.info.downloadedBytes != record.expectedTotal {
                self.finishLocked(record, state: .failed, errorMessage: "下载不完整，请重试")
                return
            }
            self.completeLocked(record)
        }
    }

    private func record(forSessionTask task: URLSessionTask) -> TaskRecord? {
        records.values.first { $0.sessionTask === task }
    }

    // MARK: file:// copy

    private func startFileCopyLocked(_ record: TaskRecord) {
        let request = record.info.request
        let part = partURL(for: request)
        let source = request.sourceURL
        let delay = testChunkDelay
        // New attempt: bump the generation on syncQueue so any
        // still-running older loop becomes stale.
        record.attempt += 1
        let attempt = record.attempt
        workQueue.async {
            let sourceSize = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? -1
            var existing: Int64 = 0
            if let handle = try? FileHandle(forUpdating: part) {
                existing = Int64(handle.seekToEndOfFile())
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: part.path, contents: nil)
            }
            if sourceSize >= 0 && existing > sourceSize {
                existing = 0
                try? FileManager.default.removeItem(at: part)
                FileManager.default.createFile(atPath: part.path, contents: nil)
            }
            self.syncQueue.async {
                record.info.totalBytes = sourceSize
                record.info.downloadedBytes = existing
            }
            guard let reader = try? FileHandle(forReadingFrom: source) else {
                self.syncQueue.async {
                    self.finishLocked(record, state: .failed, errorMessage: "无法读取源文件")
                }
                return
            }
            if existing > 0 {
                try? reader.seek(toOffset: UInt64(existing))
            }
            guard let writer = try? FileHandle(forUpdating: part) else {
                reader.closeFile()
                self.syncQueue.async {
                    self.finishLocked(record, state: .failed, errorMessage: "无法打开下载文件")
                }
                return
            }
            // seekToEnd() needs macOS 10.15.4; the package targets
            // 10.15.0, so use the long-available seekToEndOfFile().
            _ = writer.seekToEndOfFile()
            var downloaded = existing
            while true {
                let (stop, stale) = self.syncQueue.sync { (record.stopRequested, record.attempt != attempt) }
                if stop || stale { break }
                let chunk = reader.readData(ofLength: 64 * 1024)
                if chunk.isEmpty { break }
                let offsetBefore = writer.offsetInFile
                writer.write(chunk)
                if writer.offsetInFile != offsetBefore + UInt64(chunk.count) {
                    // Silent write failure (disk full) — fail instead
                    // of completing a short file (§2.1 Problem C).
                    reader.closeFile()
                    writer.closeFile()
                    self.syncQueue.async {
                        guard record.attempt == attempt else { return }
                        self.finishLocked(record, state: .failed, errorMessage: "写入下载文件失败")
                    }
                    return
                }
                downloaded += Int64(chunk.count)
                let (progress, current) = self.syncQueue.sync { (record.progress, record.attempt == attempt) }
                let total = sourceSize
                if let progress = progress, current {
                    DispatchQueue.main.async { progress(downloaded, total) }
                }
                self.syncQueue.async {
                    if record.attempt == attempt { record.info.downloadedBytes = downloaded }
                }
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            }
            reader.closeFile()
            writer.closeFile()
            self.syncQueue.async {
                // A newer attempt owns the record now; this stale
                // loop must not persist, fail, or complete anything.
                guard record.attempt == attempt else { return }
                if record.stopRequested {
                    if record.info.state == .paused {
                        self.persistLocked()
                        self.startNextLocked()
                    }
                    return
                }
                if sourceSize >= 0 && downloaded < sourceSize {
                    self.finishLocked(record, state: .failed, errorMessage: "下载不完整，请重试")
                    return
                }
                self.completeLocked(record)
            }
        }
    }

    // MARK: Completion / persistence

    private func completeLocked(_ record: TaskRecord) {
        let request = record.info.request
        let fileName = DownloadEngine.sanitisedFileName(request.fileName, fallbackKey: request.key)
        let part = partURL(for: request)
        // Verify the part on disk before moving: its size must equal
        // what we believe we downloaded (and the expected total when
        // known) — a short/failed write must never complete (§2.1 D).
        let partSize = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard partSize >= 0, partSize == record.info.downloadedBytes,
              record.expectedTotal < 0 || partSize == record.expectedTotal else {
            finishLocked(record, state: .failed, errorMessage: "下载不完整，请重试")
            return
        }
        // Never clobber another task's completed file: the same
        // "title - artist.ext" from two platforms/keys used to map
        // to one filename, and the second completion deleted the
        // first task's file while it still reported .completed.
        let finalName = uniqueFinalName(for: fileName, excludingKey: request.key)
        let final = downloadsDirectory().appendingPathComponent(finalName)
        // Move to a temp name in the same dir, then atomic replace.
        let temp = downloadsDirectory().appendingPathComponent(UUID().uuidString + ".tmp")
        do {
            try FileManager.default.moveItem(at: part, to: temp)
            if FileManager.default.fileExists(atPath: final.path) {
                try FileManager.default.replaceItem(at: final, withItemAt: temp, backupItemName: nil, options: [], resultingItemURL: nil)
            } else {
                try FileManager.default.moveItem(at: temp, to: final)
            }
        } catch {
            // Try to put the part back so the task stays resumable.
            try? FileManager.default.moveItem(at: temp, to: part)
            finishLocked(record, state: .failed, errorMessage: "无法保存下载文件")
            return
        }
        record.info.localRelativePath = DownloadEngine.relativePath(for: finalName)
        finishLocked(record, state: .completed, errorMessage: nil)
    }

    /// If another task already owns `fileName` as its completed file,
    /// return `name (2).ext`, `name (3).ext`, … instead of deleting
    /// that task's file.
    private func uniqueFinalName(for fileName: String, excludingKey key: String) -> String {
        let ownedByOther = records.values.contains { other in
            other.info.request.key != key
                && other.info.localRelativePath == DownloadEngine.relativePath(for: fileName)
        }
        guard ownedByOther else { return fileName }
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            let taken = records.values.contains { $0.info.localRelativePath == DownloadEngine.relativePath(for: candidate) }
            if !taken { return candidate }
            n += 1
        }
    }

    private func closeHandleLocked(_ record: TaskRecord) {
        record.fileHandle?.closeFile()
        record.fileHandle = nil
    }

    /// Move a task to a terminal state, persist, free a slot, and
    /// fire its completion callback exactly once (on the main
    /// queue). Callers hold syncQueue.
    private func finishLocked(_ record: TaskRecord, state: DownloadState, errorMessage: String?) {
        record.info.state = state
        record.info.errorMessage = errorMessage
        closeHandleLocked(record)
        record.sessionTask = nil
        persistLocked()
        let info = record.info
        let completion = record.completion
        record.completion = nil
        record.progress = nil
        startNextLocked()
        if let completion = completion {
            DispatchQueue.main.async { completion(info) }
        }
    }

    private func persistLocked() {
        let infos = order.compactMap { records[$0]?.info }
        LocalStore.saveCollection(named: DownloadEngine.tasksCollection, value: infos)
    }

    /// Restore the persisted index. In-flight tasks come back as
    /// paused — the `.part` file on disk makes them resumable, and
    /// nothing auto-starts on launch.
    private func restorePersistedTasks() {
        let infos: [DownloadTaskInfo] = LocalStore.loadCollection(named: DownloadEngine.tasksCollection, default: [])
        for info in infos {
            var restored = info
            if restored.state == .downloading || restored.state == .queued {
                restored.state = .paused
            }
            restored.errorMessage = restored.state == .failed ? restored.errorMessage : nil
            let record = TaskRecord(info: restored)
            records[restored.request.key] = record
            order.append(restored.request.key)
        }
    }
}

// MARK: - Session delegate

private final class DownloadSessionDelegate: NSObject, URLSessionDataDelegate {
    private weak var engine: DownloadEngine?

    init(engine: DownloadEngine) {
        self.engine = engine
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            engine?.httpDidReceiveResponse(dataTask, response: http)
            completionHandler(.allow)
            return
        }
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        engine?.httpDidReceiveData(dataTask, data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        engine?.httpDidComplete(task, error: error)
    }
}

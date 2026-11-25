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
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif

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
    case fetchingURL
    case downloading
    case waitingNetwork
    case paused
    case validating
    case completed
    case failed
    case notDownloadable
    case cancelled

    /// Chinese copy for the 12-state machine (plan §9.3). The
    /// 12th Coda state, "等待登录原账号", is excluded — this app
    /// has no login.
    var chineseLabel: String {
        switch self {
        case .queued: return "排队中"
        case .fetchingURL: return "获取下载地址"
        case .downloading: return "下载中"
        case .waitingNetwork: return "等待可用网络"
        case .paused: return "已暂停"
        case .validating: return "校验中"
        case .completed: return "已下载"
        case .failed: return "下载失败"
        case .notDownloadable: return "暂不可下载"
        case .cancelled: return "已取消"
        }
    }

    var isActive: Bool {
        self == .queued || self == .fetchingURL || self == .downloading || self == .validating
    }

    var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled || self == .notDownloadable
    }
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
    /// Owners sharing this one job (plan §9.3): the same song
    /// downloaded from several playlists / singles builds ONE
    /// job. Cancelling removes one owner; the job only really
    /// cancels when the owner set is empty.
    var owners: Set<String> = []
    /// Retry attempts used so far (backoff 1s / 2s / 4s).
    var retryCount: Int = 0
    /// Absolute URL string the resume state (`.part` file) belongs
    /// to. When the request URL changes (CDN switch) the old
    /// resume is discarded and the download restarts from 0.
    var lastSourceURL: String? = nil
    /// True until the user approves a metered-network download
    /// (batch on cellular/hotspot/low-data, or a single song in
    /// low-data mode). Unapproved tasks wait for Wi-Fi.
    var needsMeteredConfirmation: Bool = false
    /// True while the user chose "等待 Wi-Fi" for this task: it
    /// sits in `waitingNetwork` and re-queues itself when the
    /// path stops being expensive. Cleared on approve / manual
    /// resume / reconnect.
    var waitingForUnmetered: Bool = false
}

// MARK: - b45-F: metered-network confirmation policy (plan §9.3)
//
// Pure decision rule: a BATCH download on cellular / hotspot /
// low-data mode asks once first ("继续下载 / 等待 Wi-Fi /
// 取消"); a SINGLE song only asks in low-data mode. Unapproved
// batch tasks wait for Wi-Fi.

enum MeteredDownloadPolicy {
    static func needsConfirmation(
        isBatch: Bool,
        isCellular: Bool,
        isHotspot: Bool,
        isLowDataMode: Bool
    ) -> Bool {
        if isBatch { return isCellular || isHotspot || isLowDataMode }
        return isLowDataMode
    }
}

// MARK: - b45-F: downloads.json catalog store (plan §9.3)
//
// The download directory persists as `downloads.json` with a
// monotonically increasing revision, so a slow old save can never
// overwrite a newer pause / cancel. The LocalStore collection is
// kept as a compatibility mirror on write and a fallback on read.

struct DownloadCatalogFile: Codable {
    var revision: Int
    var tasks: [DownloadTaskInfo]
}

enum DownloadCatalogStore {
    static let fileName = "downloads.json"

    static func catalogURL(documentsURL: URL? = nil) -> URL {
        let docs = documentsURL ?? LocalStore.documentsDirectory()
        return docs.appendingPathComponent(DownloadEngine.downloadSubdir)
            .appendingPathComponent(fileName)
    }

    static func load(documentsURL: URL? = nil) -> DownloadCatalogFile? {
        guard let data = try? Data(contentsOf: catalogURL(documentsURL: documentsURL)) else { return nil }
        return try? JSONDecoder().decode(DownloadCatalogFile.self, from: data)
    }

    @discardableResult
    static func save(_ file: DownloadCatalogFile, documentsURL: URL? = nil) -> Bool {
        let url = catalogURL(documentsURL: documentsURL)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(file) else { return false }
        do {
            try data.write(to: url, options: [.atomic])
            return true
        } catch { return false }
    }
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
        /// MIME type of the current response (completion
        /// validation: music must be audio/*).
        var mimeType: String?
        /// Last HTTP status received (completion validation
        /// requires 200 / 206).
        var lastStatusCode: Int?
        /// Source URL the `.part` file on disk belongs to (CDN
        /// switch detection: a changed URL discards the resume).
        var resumeSourceURL: String?
        /// Pending backoff retry (cancelled by pause / cancel).
        var retryWork: DispatchWorkItem?
        /// Whether the metered-confirmation callback already fired
        /// for this task (fire once).
        var meteredCallbackFired = false

        init(info: DownloadTaskInfo) {
            self.info = info
            self.resumeSourceURL = info.lastSourceURL
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

    /// Monotonic revision of `downloads.json` (plan §9.3).
    private var catalogRevision = 0
    /// Retry backoff delays, seconds (plan §9.3): 1s / 2s / 4s.
    static let retryDelays: [TimeInterval] = [1, 2, 4]
    /// Max automatic retries for a network failure.
    static let maxRetries = 3

    /// Network state from the path monitor (b45-F). Defaults
    /// assume "online, unmetered" until the first path update.
    private(set) var isNetworkAvailable = true
    private(set) var isMeteredNetwork = false
    private(set) var isLowDataMode = false
#if canImport(Network)
    private var pathMonitor: NWPathMonitor?
#endif

    /// Fired once (main queue) when a task needs metered-network
    /// confirmation — the UI shows "继续下载 / 等待 Wi-Fi /
    /// 取消" and calls `approveMetered(key:)` / `holdMetered(key:)`
    /// / `denyMetered(key:)`.
    var onMeteredConfirmationNeeded: ((DownloadTaskInfo) -> Void)?

    /// Fired (main queue) when download activity starts or stops
    /// (b49fix2 P2-59): the app root holds a background task
    /// while any download is active, so iOS does not suspend the
    /// app mid-download. A background URLSessionConfiguration is
    /// NOT used — this engine streams through data tasks with
    /// Range resume, and background sessions support only
    /// upload/download tasks.
    var onActivityChanged: ((Bool) -> Void)?
    /// Whether any download is active right now, as last
    /// reported to onActivityChanged.
    private var lastReportedActivity = false

    /// Recompute activity from the records and fire
    /// onActivityChanged when it flips (b49fix2 P2-59). Called
    /// from persistLocked, which runs at every state mutation —
    /// no call site can forget it. Deduped: the app root only
    /// starts/ends one background task per flip, never per chunk.
    private func refreshActivityLocked() {
        let active = records.values.contains { $0.info.state.isActive }
        guard active != lastReportedActivity else { return }
        lastReportedActivity = active
        let callback = onActivityChanged
        DispatchQueue.main.async { callback?(active) }
    }

    override init() {
        super.init()
        restorePersistedTasks()
        startPathMonitor()
    }

    /// Max concurrent downloads for the current network
    /// (plan §9.3): Wi-Fi 2, metered 1.
    var currentMaxConcurrent: Int { isMeteredNetwork ? 1 : DownloadEngine.maxConcurrent }

    /// Start the path monitor: a disconnect moves active tasks to
    /// `waitingNetwork`, a reconnect resumes them automatically.
    private func startPathMonitor() {
#if canImport(Network)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.syncQueue.async {
                let wasAvailable = self.isNetworkAvailable
                let wasMetered = self.isMeteredNetwork
                self.isNetworkAvailable = path.status == .satisfied
                self.isMeteredNetwork = path.isExpensive
                self.isLowDataMode = path.isConstrained
                if !self.isNetworkAvailable {
                    // Active downloads will fail through the error
                    // path into waitingNetwork; queued ones move now.
                    for record in self.records.values where record.info.state == .queued {
                        record.info.state = .waitingNetwork
                    }
                    self.persistLocked()
                } else if !wasAvailable || (wasMetered && !self.isMeteredNetwork) {
                    // Reconnected, or moved off an expensive path
                    // (cellular / hotspot -> Wi-Fi): waiting tasks
                    // re-queue and run — except metered-held tasks
                    // while the path is still expensive.
                    var resumed = false
                    for record in self.records.values where record.info.state == .waitingNetwork {
                        if record.info.waitingForUnmetered && self.isMeteredNetwork { continue }
                        record.info.waitingForUnmetered = false
                        record.info.state = .queued
                        record.info.errorMessage = nil
                        resumed = true
                    }
                    if resumed {
                        self.persistLocked()
                        self.startNextLocked()
                    }
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.haostudio.downloadpath"))
        pathMonitor = monitor
#endif
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

    /// Part-file name for a task: the final name plus a short stable
    /// hash of the task key. Two tasks with the same file name (same
    /// song title/artist from two platforms) must NOT share one
    /// `.part` file — concurrent copies into a shared part corrupt
    /// each other, and the part-size check then fails both (§2.1 D).
    /// The hash keeps the name short and deterministic across
    /// launches, so resume finds the same part.
    static func partFileName(for request: DownloadRequest) -> String {
        let base = sanitisedFileName(request.fileName, fallbackKey: request.key)
        return "\(base).\(stableKeyHash(request.key)).part"
    }

    /// FNV-1a 64-bit, hex, 16 chars. Deterministic; no crypto needed.
    static func stableKeyHash(_ key: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    private func partURL(for request: DownloadRequest) -> URL {
        downloadsDirectory().appendingPathComponent(DownloadEngine.partFileName(for: request))
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
        enqueue(request: request, owner: nil, isBatch: false, progress: progress, completion: completion)
    }

    /// Enqueue with a sharing owner and a batch flag (plan §9.3).
    /// The same song from several playlists / singles builds ONE
    /// job (`owners` grows); a batch enqueue on a metered network
    /// (or any enqueue in low-data mode) waits for the user's
    /// metered confirmation before it starts.
    func enqueue(request: DownloadRequest, owner: String?, isBatch: Bool, progress: ((Int64, Int64) -> Void)? = nil, completion: ((DownloadTaskInfo) -> Void)? = nil) -> DownloadTaskInfo {
        var result: DownloadTaskInfo!
        syncQueue.sync {
            if let existing = records[request.key], existing.info.state == .queued || existing.info.state == .downloading || existing.info.state == .paused || existing.info.state == .waitingNetwork || existing.info.state == .fetchingURL || existing.info.state == .validating {
                if let owner = owner { existing.info.owners.insert(owner) }
                if let progress = progress { existing.progress = progress }
                if let completion = completion { existing.completion = completion }
                result = existing.info
                persistLocked()
                return
            }
            var info = DownloadTaskInfo(request: request, state: .queued, downloadedBytes: 0, totalBytes: -1, errorMessage: nil, localRelativePath: nil)
            if let owner = owner { info.owners.insert(owner) }
            info.needsMeteredConfirmation = MeteredDownloadPolicy.needsConfirmation(
                isBatch: isBatch, isCellular: isMeteredNetwork,
                isHotspot: false, isLowDataMode: isLowDataMode)
            let record = TaskRecord(info: info)
            record.progress = progress
            record.completion = completion
            records[request.key] = record
            if !order.contains(request.key) { order.append(request.key) }
            result = info
            persistLocked()
            if info.needsMeteredConfirmation {
                fireMeteredConfirmationLocked(record)
            } else {
                startNextLocked()
            }
        }
        return result
    }

    private func fireMeteredConfirmationLocked(_ record: TaskRecord) {
        guard !record.meteredCallbackFired else { return }
        record.meteredCallbackFired = true
        let info = record.info
        let callback = onMeteredConfirmationNeeded
        DispatchQueue.main.async { callback?(info) }
    }

    /// Approve a metered-network download: it starts now.
    func approveMetered(key: String) {
        syncQueue.sync {
            guard let record = records[key] else { return }
            guard record.info.needsMeteredConfirmation else { return }
            record.info.needsMeteredConfirmation = false
            record.info.state = .queued
            persistLocked()
            startNextLocked()
        }
    }

    /// Decline a metered-network download: the task is cancelled.
    func denyMetered(key: String) {
        syncQueue.sync {
            guard let record = records[key] else { return }
            guard record.info.needsMeteredConfirmation else { return }
            record.info.needsMeteredConfirmation = false
            finishLocked(record, state: .cancelled, errorMessage: nil)
        }
    }

    /// Hold a metered-network download for Wi-Fi (b45-h, plan
    /// §9.3): the task waits in `waitingNetwork` and resumes
    /// itself when the path stops being expensive (see the path
    /// monitor above). Unlike `denyMetered` (cancel) the
    /// download is not lost; unlike `approveMetered` it spends
    /// no metered data.
    func holdMetered(key: String) {
        syncQueue.sync {
            guard let record = records[key] else { return }
            guard record.info.needsMeteredConfirmation else { return }
            record.info.needsMeteredConfirmation = false
            record.info.waitingForUnmetered = true
            record.info.state = .waitingNetwork
            persistLocked()
        }
    }

    /// Cancel one owner of a shared job (plan §9.3): the job only
    /// really cancels when the owner set is empty. Passing nil
    /// cancels the whole job (the old behaviour).
    func cancel(key: String, owner: String?) {
        syncQueue.sync {
            guard let record = records[key] else { return }
            if let owner = owner {
                record.info.owners.remove(owner)
                persistLocked()
                guard record.info.owners.isEmpty else { return }
            }
            cancelLocked(record)
        }
    }

    private func cancelLocked(_ record: TaskRecord) {
        switch record.info.state {
        case .completed, .cancelled:
            return
        default:
            break
        }
        record.retryWork?.cancel()
        record.retryWork = nil
        record.stopRequested = true
        record.sessionTask?.cancel()
        closeHandleLocked(record)
        try? FileManager.default.removeItem(at: partURL(for: record.info.request))
        finishLocked(record, state: .cancelled, errorMessage: nil)
    }

    /// Quality upgrade (plan §9.3): move the overlapping owners
    /// from the old-quality job to the new one; the old job stays
    /// for its remaining owners.
    func migrateOwners(fromKey: String, toKey: String, owners: Set<String>) {
        syncQueue.sync {
            guard let from = records[fromKey], let to = records[toKey] else { return }
            for owner in owners where from.info.owners.contains(owner) {
                from.info.owners.remove(owner)
                to.info.owners.insert(owner)
            }
            persistLocked()
            if from.info.owners.isEmpty, from.info.state != .completed {
                cancelLocked(from)
            }
        }
    }

    func pause(key: String) {
        syncQueue.sync {
            guard let record = records[key] else { return }
            switch record.info.state {
            case .downloading:
                record.retryWork?.cancel()
                record.retryWork = nil
                record.stopRequested = true
                record.sessionTask?.cancel()
                record.info.state = .paused
                closeHandleLocked(record)
                persistLocked()
            case .queued, .waitingNetwork, .fetchingURL, .validating:
                record.retryWork?.cancel()
                record.retryWork = nil
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
            guard record.info.state == .paused || record.info.state == .failed || record.info.state == .waitingNetwork else { return }
            record.info.waitingForUnmetered = false
            record.info.state = .queued
            record.info.errorMessage = nil
            record.info.retryCount = 0
            record.stopRequested = false
            persistLocked()
            startNextLocked()
        }
    }

    func cancel(key: String) {
        cancel(key: key, owner: nil)
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
        while activeCountLocked() < currentMaxConcurrent {
            // Unapproved metered tasks and offline tasks never
            // start: the former wait for the user's confirmation,
            // the latter for the network (waitingNetwork).
            if !isNetworkAvailable {
                for record in records.values where record.info.state == .queued {
                    record.info.state = .waitingNetwork
                }
                persistLocked()
                return
            }
            guard let next = order.compactMap({ records[$0] }).first(where: {
                $0.info.state == .queued && !$0.info.needsMeteredConfirmation
            }) else { return }
            startLocked(next)
        }
    }

    private func startLocked(_ record: TaskRecord) {
        record.info.state = .downloading
        record.stopRequested = false
        let request = record.info.request
        guard let scheme = request.sourceURL.scheme?.lowercased() else {
            finishLocked(record, state: .notDownloadable, errorMessage: "暂不可下载")
            return
        }
        if scheme == "file" {
            startFileCopyLocked(record)
            return
        }
        if scheme != "http" && scheme != "https" {
            finishLocked(record, state: .notDownloadable, errorMessage: "暂不可下载")
            return
        }
        startHTTPDownloadLocked(record)
    }

    // MARK: HTTP download (Range resume)

    private func startHTTPDownloadLocked(_ record: TaskRecord) {
        let request = record.info.request
        let part = partURL(for: request)
        // b45-F: the URL changed (CDN switch) — the old resume
        // belongs to another URL, so discard it and restart from 0.
        if let resumeURL = record.resumeSourceURL,
           resumeURL != request.sourceURL.absoluteString {
            try? FileManager.default.removeItem(at: part)
            record.info.downloadedBytes = 0
        }
        record.resumeSourceURL = request.sourceURL.absoluteString
        record.info.lastSourceURL = request.sourceURL.absoluteString
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
            record.lastStatusCode = response.statusCode
            if response.statusCode == 200 || response.statusCode == 206 {
                record.mimeType = response.mimeType
            }
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
                    // b45-F: reserve only the REMAINING space — the
                    // bytes already on disk are already paid for.
                    if !self.checkRemainingSpaceLocked(record) { return }
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
                    // b45-F: reserve only the remaining space.
                    if !self.checkRemainingSpaceLocked(record) { return }
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
            } else if response.statusCode == 401 || response.statusCode == 403 || response.statusCode == 404 {
                // b45-F: 401 / 403 / 404 get ONE retry (plan §9.3);
                // a second failure is terminal.
                record.stopRequested = true
                task.cancel()
                if record.info.retryCount == 0 {
                    self.scheduleRetryLocked(record, errorMessage: "服务器返回了错误（\(response.statusCode)）")
                } else {
                    self.finishLocked(record, state: .failed, errorMessage: "服务器返回了错误（\(response.statusCode)）")
                }
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

    /// True when the remaining bytes fit in the free space (the
    /// bytes already downloaded are already paid for). Fails the
    /// task with the storage message when they do not fit.
    private func checkRemainingSpaceLocked(_ record: TaskRecord) -> Bool {
        guard record.expectedTotal >= 0 else { return true }
        let remaining = record.expectedTotal - record.info.downloadedBytes
        guard remaining > 0 else { return true }
        if remaining > AutomaticCacheLimit.freeBytes() {
            record.stopRequested = true
            record.sessionTask?.cancel()
            closeHandleLocked(record)
            finishLocked(record, state: .failed, errorMessage: "存储空间不足，请清理后重试")
            return false
        }
        return true
    }

    /// Schedule a backoff retry (1s / 2s / 4s). The task keeps its
    /// `.downloading` state — holding its slot — until the delay
    /// elapses, then re-queues. The completion callback does NOT
    /// fire: a retry is not a terminal state.
    private func scheduleRetryLocked(_ record: TaskRecord, errorMessage: String) {
        record.info.retryCount += 1
        let delay = DownloadEngine.retryDelays[
            min(record.info.retryCount - 1, DownloadEngine.retryDelays.count - 1)]
        record.info.errorMessage = errorMessage
        record.info.state = .downloading
        closeHandleLocked(record)
        record.sessionTask = nil
        persistLocked()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.syncQueue.async {
                guard record.retryWork != nil, record.info.state == .downloading else { return }
                record.retryWork = nil
                record.info.state = .queued
                self.persistLocked()
                self.startNextLocked()
            }
        }
        record.retryWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
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
                    // A cancelled task whose backoff retry owns the
                    // restart does nothing here.
                    return
                }
                // b45-F: a disconnect parks the task in
                // waitingNetwork — it resumes automatically on
                // reconnect instead of failing.
                if !self.isNetworkAvailable {
                    record.info.state = .waitingNetwork
                    record.info.errorMessage = error.localizedDescription
                    self.persistLocked()
                    return
                }
                // b45-F: network failures retry 1s / 2s / 4s
                // (max 3); then they fail for real.
                if record.info.retryCount < DownloadEngine.maxRetries {
                    self.scheduleRetryLocked(record, errorMessage: error.localizedDescription)
                    return
                }
                self.finishLocked(record, state: .failed, errorMessage: error.localizedDescription)
                return
            }
            if record.expectedTotal >= 0 && record.info.downloadedBytes != record.expectedTotal {
                self.finishLocked(record, state: .failed, errorMessage: "下载不完整，请重试")
                return
            }
            // b45-F: completion validation (plan §9.3) — status
            // must be 200 / 206 and the MIME must match the kind.
            record.info.state = .validating
            if let status = record.lastStatusCode, status != 200 && status != 206 {
                self.finishLocked(record, state: .failed, errorMessage: "服务器返回了错误（\(status)）")
                return
            }
            if let mime = record.mimeType, !mime.isEmpty {
                let isMusic = record.info.request.kind == .music
                let ok = isMusic
                    ? (mime.hasPrefix("audio/") || mime == "application/octet-stream")
                    : (mime.hasPrefix("video/") || mime == "application/octet-stream"
                        || mime == "application/vnd.apple.mpegurl")
                if !ok {
                    self.finishLocked(
                        record, state: .failed,
                        errorMessage: isMusic ? "音频校验失败，请重试" : "视频校验失败，请重试")
                    return
                }
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
                #if canImport(FoundationNetworking)
                // swift-corelibs-foundation drops the resultingItemURL
                // parameter (autoreleased pointers unsupported).
                try FileManager.default.replaceItem(at: final, withItemAt: temp, backupItemName: nil, options: [])
                #else
                try FileManager.default.replaceItem(at: final, withItemAt: temp, backupItemName: nil, options: [], resultingItemURL: nil)
                #endif
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
        // b49fix2 B5: the shell's one-time backup nudge listens
        // for a completed download (a user with something worth
        // keeping is the user who needs a backup).
        if state == .completed {
            NotificationCenter.default.post(name: .haoDownloadCompleted, object: nil)
        }
    }

    private func persistLocked() {
        let infos = order.compactMap { records[$0]?.info }
        // b45-F: downloads.json with a monotonic revision — a slow
        // old save can never overwrite a newer pause / cancel.
        // The LocalStore collection stays as a compatibility mirror.
        catalogRevision += 1
        DownloadCatalogStore.save(DownloadCatalogFile(revision: catalogRevision, tasks: infos))
        LocalStore.saveCollection(named: DownloadEngine.tasksCollection, value: infos)
        // b49fix2 P2-59: every state mutation re-derives activity
        // (start/stop of the app-root background task).
        refreshActivityLocked()
    }

    /// Restore the persisted index. In-flight tasks come back as
    /// paused — the `.part` file on disk makes them resumable, and
    /// nothing auto-starts on launch.
    private func restorePersistedTasks() {
        // b45-F: downloads.json is primary; the LocalStore
        // collection is the fallback for pre-b45 indexes.
        let catalog = DownloadCatalogStore.load()
        let infos: [DownloadTaskInfo]
        if let catalog = catalog {
            catalogRevision = catalog.revision
            infos = catalog.tasks
        } else {
            infos = LocalStore.loadCollection(named: DownloadEngine.tasksCollection, default: [])
        }
        for info in infos {
            let key = info.request.key
            // Dedupe: a crafted index can repeat a key; the second
            // copy must not duplicate the snapshot.
            guard records[key] == nil else { continue }
            var restored = info
            if restored.state == .downloading || restored.state == .queued
                || restored.state == .fetchingURL || restored.state == .validating
                || restored.state == .waitingNetwork {
                restored.state = .paused
                // b45-h: a held task restarts paused, never
                // auto-held — the hold flag is only meaningful
                // while the task sits in waitingNetwork.
                restored.waitingForUnmetered = false
            }
            restored.errorMessage = restored.state == .failed ? restored.errorMessage : nil
            // Re-sanitise the stored file name: a crafted/migrated
            // index must not smuggle a traversal past the use-site
            // sanitiser (the part/final URLs re-sanitise anyway).
            let cleanName = DownloadEngine.sanitisedFileName(restored.request.fileName, fallbackKey: key)
            if cleanName != restored.request.fileName {
                restored.request = DownloadRequest(
                    key: key,
                    title: restored.request.title,
                    sourceURL: restored.request.sourceURL,
                    fileName: cleanName,
                    kind: restored.request.kind,
                    qualityCode: restored.request.qualityCode)
            }
            // b45-F: a completed entry whose file is gone is a
            // FAILED task with a message — not a silent drop.
            // ("本地文件缺失，请重新下载")
            if restored.state == .completed {
                let missing: Bool
                if let relative = restored.localRelativePath,
                   let url = LocalFileIndex.resolve(relative, subdir: DownloadEngine.downloadSubdir) {
                    missing = !FileManager.default.fileExists(atPath: url.path)
                } else {
                    missing = true
                }
                if missing {
                    restored.state = .failed
                    restored.errorMessage = "本地文件缺失，请重新下载"
                    restored.localRelativePath = nil
                    let record = TaskRecord(info: restored)
                    records[key] = record
                    order.append(key)
                    continue
                }
            } else {
                // b45-F: a crash between "file finished" and
                // "catalog entry written" leaves an in-flight task
                // whose FINAL file is already on disk — claim it
                // instead of re-downloading.
                let final = finalURL(for: restored.request)
                if FileManager.default.fileExists(atPath: final.path),
                   restored.downloadedBytes > 0 || restored.totalBytes > 0 {
                    restored.state = .completed
                    restored.localRelativePath = DownloadEngine.relativePath(for: final.lastPathComponent)
                    restored.downloadedBytes = restored.totalBytes >= 0
                        ? restored.totalBytes
                        : ((try? FileManager.default.attributesOfItem(atPath: final.path)[.size] as? NSNumber)?.int64Value ?? restored.downloadedBytes)
                    let record = TaskRecord(info: restored)
                    records[key] = record
                    order.append(key)
                    continue
                }
                // Adopt a legacy `<name>.part` (pre-2.1 layout, shared
                // per file name) into this task's per-key part name,
                // so an in-flight download from before the upgrade
                // resumes instead of restarting from 0.
                let part = partURL(for: restored.request)
                if !FileManager.default.fileExists(atPath: part.path) {
                    let legacy = downloadsDirectory()
                        .appendingPathComponent(DownloadEngine.sanitisedFileName(restored.request.fileName, fallbackKey: key))
                        .appendingPathExtension("part")
                    if FileManager.default.fileExists(atPath: legacy.path) {
                        try? FileManager.default.moveItem(at: legacy, to: part)
                    }
                }
                // Clamp downloadedBytes to the part size on disk —
                // the persisted count is stale after a kill (Finding E).
                let partSize = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
                restored.downloadedBytes = partSize
                if restored.totalBytes >= 0 && restored.downloadedBytes > restored.totalBytes {
                    restored.totalBytes = restored.downloadedBytes
                }
            }
            let record = TaskRecord(info: restored)
            records[key] = record
            order.append(key)
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

// MARK: - Automatic cache limit (moved here, b45-fix #25)
//
// Moved verbatim from CacheManager.swift: that file cannot join
// AppCore (its clearAll calls the UIKit image loaders), while
// this file is an AppCore member and needs the limit for
// checkRemainingSpaceLocked. Foundation-only (LocalStore + math).

// MARK: - b45-F: automatic cache limit (plan §9.3)
//
// Automatic mode = free space / 10, clamped to 2–30 GB, always
// keeping the last 1 GB free. Bytes already occupied by the cache
// count back into the free space (a full cache does not shrink
// its own allowance). The computed result is cached for
// 10 minutes.

enum AutomaticCacheLimit {
    static let minBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maxBytes: Int64 = 30 * 1024 * 1024 * 1024
    /// Always keep this much free, even if the clamp says more.
    static let reserveBytes: Int64 = 1 * 1024 * 1024 * 1024
    static let cacheTTL: TimeInterval = 10 * 60

    private static var cachedValue: Int64?
    private static var cachedAt: Date?
    private static let lock = NSLock()

    static func freeBytes(documentsURL: URL? = nil) -> Int64 {
        let dir = documentsURL ?? LocalStore.documentsDirectory()
        guard let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage
        else { return 0 }
        return Int64(free)
    }

    /// Pure computation (harness-testable): free space / 10,
    /// clamped 2–30 GB, never eating the last 1 GB. `cachedBytes`
    /// is the audio cache's own size — it counts back into the
    /// available space.
    static func limitBytes(freeBytes: Int64, cachedBytes: Int64) -> Int64 {
        let tenth = (freeBytes + cachedBytes) / 10
        let clamped = min(max(tenth, minBytes), maxBytes)
        return min(clamped, max(freeBytes - reserveBytes, 0))
    }

    /// Cached automatic limit (10-minute memo). `freeBytes` is
    /// read live on a miss.
    static func automaticLimitBytes(cachedBytes: Int64, freeBytes: Int64? = nil) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        if let value = cachedValue, let at = cachedAt,
           Date().timeIntervalSince(at) < cacheTTL {
            return value
        }
        let free = freeBytes ?? AutomaticCacheLimit.freeBytes()
        let value = limitBytes(freeBytes: free, cachedBytes: cachedBytes)
        cachedValue = value
        cachedAt = Date()
        return value
    }

    static func invalidateMemo() {
        lock.lock(); cachedValue = nil; cachedAt = nil; lock.unlock()
    }
}


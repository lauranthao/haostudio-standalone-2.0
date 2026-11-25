// HAo Studio 2.0 — cache manager (S5, leg A).
//
// Disk-cache accounting for the Settings "清理缓存" row. Only
// caches that REALLY exist are counted:
// - URLCache.shared on-disk usage (HTTP cache),
// - unfinished downloads: the `.part` files under
//   `Documents/music_downloads/` (DownloadEngine.downloadSubdir;
//   a `.part` file is the resume state of a paused / interrupted
//   download — see Services/DownloadEngine/DownloadEngine.swift),
// - b45-F: the audio cache under `Caches/hao-audio/audio/`
//   (HaoAudioCache.totalBytes; metadata `.json` files are tiny
//   and not counted, same as the `.part` accounting counts
//   payload only).
//
// Deliberately NOT counted: the music / video JSON collections
// (user data, not cache), and completed downloads (user files).
// Clearing removes the HTTP cache, the image memory caches
// (HaoImageLoader + EmbyImageLoader — RAM, not disk; the Emby
// one was previously defined but never called from anywhere),
// the `.part` files, and the whole audio cache (an explicit
// user clear — plan §7.4 "用户清空"); completed downloads are
// never deleted by a cache clear.

import Foundation

enum CacheManager {
    /// Total on-disk cache size in bytes (URLCache disk usage +
    /// `.part` files + audio cache). Completion fires on the main queue.
    static func totalSizeBytes(
        documentsURL: URL? = nil,
        cachesURL: URL? = nil,
        completion: @escaping (Int64) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            var total: Int64 = Int64(URLCache.shared.currentDiskUsage)
            total += partFilesSize(documentsURL: documentsURL)
            total += HaoAudioCache.totalBytes(cachesURL: cachesURL)
            let result = total
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Delete the HTTP cache, the image memory caches, all
    /// `.part` files, and the audio cache. Completion fires on
    /// the main queue, after the deletes.
    static func clearAll(
        documentsURL: URL? = nil,
        cachesURL: URL? = nil,
        completion: @escaping () -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            URLCache.shared.removeAllCachedResponses()
            HaoImageLoader.shared.clearMemoryCache()
            EmbyImageLoader.shared.clearCache()
            HaoAudioCache.clear(cachesURL: cachesURL)
            let docs = documentsURL ?? LocalStore.documentsDirectory()
            let dir = docs.appendingPathComponent(DownloadEngine.downloadSubdir)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names where name.hasSuffix(".part") {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
            DispatchQueue.main.async { completion() }
        }
    }

    /// Sum of `.part` file sizes under the downloads directory.
    /// `documentsURL` is the test seam (nil = the real container).
    static func partFilesSize(documentsURL: URL? = nil) -> Int64 {
        let docs = documentsURL ?? LocalStore.documentsDirectory()
        let dir = docs.appendingPathComponent(DownloadEngine.downloadSubdir)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var total: Int64 = 0
        for name in names where name.hasSuffix(".part") {
            let url = dir.appendingPathComponent(name)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value {
                total += size
            }
        }
        return total
    }

    /// Total on-disk audio-cache size (b45-F `HaoAudioCache`).
    static func audioCacheSizeBytes(cachesURL: URL? = nil) -> Int64 {
        HaoAudioCache.totalBytes(cachesURL: cachesURL)
    }

    /// Clear the audio file cache (regenerable — never user
    /// downloads). Completion fires on the main queue.
    static func clearAudioCache(
        cachesURL: URL? = nil,
        completion: @escaping () -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            HaoAudioCache.clear(cachesURL: cachesURL)
            DispatchQueue.main.async { completion() }
        }
    }
}

// MARK: - b45-F: audio file cache (plan §7.4)
//
// Play URLs are NEVER cached (signatures are short-lived);
// AUDIO FILES are. Layout under Caches `<namespace>/audio/`:
// metadata `<trackID>.json` + audio `<trackID>-<uuid>.<ext>`,
// key = trackID (the same id at another quality overwrites).
// Metadata stores requestedQuality / servedQuality / source /
// servedBitrate / byteCount / completedAt. No TTL — invalidation
// is capacity LRU (oldest mtime first), size-vs-metadata
// mismatch, or user clear. A file playing right now holds a
// lease and is never evicted. Trial clips never enter the cache.

struct AudioCacheEntry: Codable, Equatable {
    let trackID: String
    let requestedQuality: String
    let servedQuality: String
    let source: String
    let servedBitrate: Int
    let byteCount: Int64
    let completedAt: Date
    /// Audio file name (sibling of this metadata file).
    let fileName: String
}

enum HaoAudioCache {
    /// Caches namespace for the audio cache.
    static let namespace = "hao-audio"
    /// Default cap when the user has not picked one (500 MB).
    static let defaultLimitBytes: Int64 = 500 * 1024 * 1024
    /// User-settable range: 100 MB – 10 GB, step 100 MB.
    static let minLimitBytes: Int64 = 100 * 1024 * 1024
    static let maxLimitBytes: Int64 = 10 * 1024 * 1024 * 1024
    static let limitStepBytes: Int64 = 100 * 1024 * 1024
    /// UserDefaults keys. `limitMB == 0` (or unset) = automatic.
    static let enabledKey = "hao_audio_cache_enabled"
    static let limitMBKey = "hao_audio_cache_limit_mb"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        // Default ON: no stored value reads back as "enabled".
        // (object(forKey:) is nil until the user toggles it off.)
        if defaults.object(forKey: enabledKey) == nil { return true }
        return defaults.bool(forKey: enabledKey)
    }

    /// User-chosen cap in bytes, or nil for automatic.
    static func userLimitBytes(defaults: UserDefaults = .standard) -> Int64? {
        let mb = defaults.integer(forKey: limitMBKey)
        guard mb > 0 else { return nil }
        let bytes = Int64(mb) * 1024 * 1024
        return min(max(bytes, minLimitBytes), maxLimitBytes)
    }

    /// Effective cap: the user value, else the automatic limit.
    /// `freeBytes` is read live by the caller (pass the test
    /// seam's value in tests); the cache's own bytes count back
    /// into the allowance. When free space is unreadable (0),
    /// fall back to the 500 MB default instead of disabling the
    /// cache entirely.
    static func limitBytes(
        freeBytes: Int64,
        defaults: UserDefaults = .standard,
        cachesURL: URL? = nil
    ) -> Int64 {
        if let user = userLimitBytes(defaults: defaults) { return user }
        guard freeBytes > 0 else { return defaultLimitBytes }
        return AutomaticCacheLimit.limitBytes(freeBytes: freeBytes, cachedBytes: totalBytes(cachesURL: cachesURL))
    }

    static func audioDirectory(cachesURL: URL? = nil) -> URL {
        let base = cachesURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(namespace).appendingPathComponent("audio")
    }

    /// Sanitised track id for use as a file name (no separators).
    static func sanitisedTrackID(_ trackID: String) -> String {
        var out = trackID.trimmingCharacters(in: .whitespaces)
        for bad in ["/", "\\", ":", "\0"] {
            out = out.replacingOccurrences(of: bad, with: "_")
        }
        return out.isEmpty ? "unknown" : out
    }

    static func metadataURL(trackID: String, cachesURL: URL? = nil) -> URL {
        audioDirectory(cachesURL: cachesURL)
            .appendingPathComponent("\(sanitisedTrackID(trackID)).json")
    }

    static func fileExtension(forMimeType mime: String?) -> String {
        switch mime?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/aac": return "aac"
        case "audio/ogg": return "ogg"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/mpeg", "audio/mp3": return "mp3"
        default: return "mp3"
        }
    }

    /// Look a track up. NetEase hits require served == requested
    /// (its served tier is what the badge shows); other sources
    /// accept any served tier (the "any-quality cache fallback").
    /// A size mismatch deletes the entry — the file cannot be
    /// trusted. Returns nil on any miss.
    static func entry(
        trackID: String,
        requestedQuality: String,
        sourceIsNetease: Bool,
        cachesURL: URL? = nil
    ) -> AudioCacheEntry? {
        guard isEnabled() else { return nil }
        let metaURL = metadataURL(trackID: trackID, cachesURL: cachesURL)
        guard let data = try? Data(contentsOf: metaURL),
              let entry = try? JSONDecoder().decode(AudioCacheEntry.self, from: data)
        else { return nil }
        if sourceIsNetease, entry.servedQuality != requestedQuality { return nil }
        let audioURL = audioDirectory(cachesURL: cachesURL).appendingPathComponent(entry.fileName)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? NSNumber)?.int64Value,
              size == entry.byteCount, size > 0
        else {
            // Size mismatch (or file gone): drop both halves.
            try? FileManager.default.removeItem(at: metaURL)
            try? FileManager.default.removeItem(at: audioURL)
            return nil
        }
        // Touch the audio file: LRU eviction is by mtime, so a hit
        // counts as recent use.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: audioURL.path)
        return entry
    }

    /// Local file URL for a cache entry.
    static func localURL(for entry: AudioCacheEntry, cachesURL: URL? = nil) -> URL {
        audioDirectory(cachesURL: cachesURL).appendingPathComponent(entry.fileName)
    }

    // MARK: Leases (playback protection)

    private static var leasedTrackIDs = Set<String>()
    private static let leaseLock = NSLock()

    /// Hold a lease while a file plays: LRU never evicts it.
    static func lease(trackID: String) {
        leaseLock.lock(); leasedTrackIDs.insert(trackID); leaseLock.unlock()
    }

    static func releaseLease(trackID: String) {
        leaseLock.lock(); leasedTrackIDs.remove(trackID); leaseLock.unlock()
    }

    static func isLeased(trackID: String) -> Bool {
        leaseLock.lock(); defer { leaseLock.unlock() }
        return leasedTrackIDs.contains(trackID)
    }

    // MARK: Writes

    /// Store a finished audio payload. The same track id at
    /// another quality overwrites (key = trackID). A single file
    /// over the cap is never cached — the caller streams it
    /// without writing. Returns the stored entry, or nil when
    /// caching is off / the file is over the cap.
    @discardableResult
    static func store(
        trackID: String,
        requestedQuality: String,
        servedQuality: String,
        source: String,
        servedBitrate: Int,
        fileExtension: String,
        data: Data,
        cachesURL: URL? = nil
    ) -> AudioCacheEntry? {
        guard isEnabled() else { return nil }
        let cap = limitBytes(freeBytes: AutomaticCacheLimit.freeBytes(), cachesURL: cachesURL)
        guard Int64(data.count) <= cap else { return nil } // over the cap: stream, don't cache
        let dir = audioDirectory(cachesURL: cachesURL)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileName = "\(sanitisedTrackID(trackID))-\(UUID().uuidString).\(fileExtension)"
        let audioURL = dir.appendingPathComponent(fileName)
        do {
            try data.write(to: audioURL, options: [.atomic])
        } catch { return nil }
        let entry = AudioCacheEntry(
            trackID: trackID, requestedQuality: requestedQuality,
            servedQuality: servedQuality, source: source,
            servedBitrate: servedBitrate, byteCount: Int64(data.count),
            completedAt: Date(), fileName: fileName)
        guard let meta = try? JSONEncoder().encode(entry) else {
            try? FileManager.default.removeItem(at: audioURL)
            return nil
        }
        // Overwrite semantics: remove the previous audio file for
        // this id (a different quality overwrites the old one).
        if let old = try? Data(contentsOf: metadataURL(trackID: trackID, cachesURL: cachesURL)),
           let oldEntry = try? JSONDecoder().decode(AudioCacheEntry.self, from: old),
           oldEntry.fileName != fileName {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(oldEntry.fileName))
        }
        try? meta.write(to: metadataURL(trackID: trackID, cachesURL: cachesURL), options: [.atomic])
        evictLRUIfNeeded(cachesURL: cachesURL)
        return entry
    }

    /// Streaming writer: appends chunks to a temp file and commits
    /// atomically on finish (sparse temp + atomic submit; sources
    /// without Range fall back to direct streaming and never
    /// cache). Trial clips must never be handed to this writer.
    final class StreamingWriter {
        private let trackID: String
        private let requestedQuality: String
        private let servedQuality: String
        private let source: String
        private let servedBitrate: Int
        private let fileExtension: String
        private let cachesURL: URL?
        private let tempURL: URL
        private var handle: FileHandle?
        private(set) var byteCount: Int64 = 0
        private var finished = false

        init?(trackID: String, requestedQuality: String, servedQuality: String,
              source: String, servedBitrate: Int, fileExtension: String,
              cachesURL: URL? = nil) {
            guard HaoAudioCache.isEnabled() else { return nil }
            self.trackID = trackID
            self.requestedQuality = requestedQuality
            self.servedQuality = servedQuality
            self.source = source
            self.servedBitrate = servedBitrate
            self.fileExtension = fileExtension
            self.cachesURL = cachesURL
            let dir = HaoAudioCache.audioDirectory(cachesURL: cachesURL)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.tempURL = dir.appendingPathComponent("tmp-\(UUID().uuidString).part")
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: tempURL) else { return nil }
            self.handle = handle
        }

        func append(_ data: Data) {
            guard !finished, let handle = handle else { return }
            handle.write(data)
            byteCount += Int64(data.count)
        }

        /// Commit: atomically move the temp file into place and
        /// write its metadata. Returns nil when the single file
        /// is over the cap (stream-only, nothing cached).
        func finish() -> AudioCacheEntry? {
            guard !finished else { return nil }
            finished = true
            try? handle?.close()
            handle = nil
            let cap = HaoAudioCache.limitBytes(freeBytes: AutomaticCacheLimit.freeBytes(), cachesURL: cachesURL)
            guard byteCount <= cap, byteCount > 0 else {
                try? FileManager.default.removeItem(at: tempURL)
                return nil
            }
            let dir = HaoAudioCache.audioDirectory(cachesURL: cachesURL)
            let fileName = "\(HaoAudioCache.sanitisedTrackID(trackID))-\(UUID().uuidString).\(fileExtension)"
            let audioURL = dir.appendingPathComponent(fileName)
            do {
                try FileManager.default.moveItem(at: tempURL, to: audioURL)
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                return nil
            }
            let entry = AudioCacheEntry(
                trackID: trackID, requestedQuality: requestedQuality,
                servedQuality: servedQuality, source: source,
                servedBitrate: servedBitrate, byteCount: byteCount,
                completedAt: Date(), fileName: fileName)
            guard let meta = try? JSONEncoder().encode(entry) else {
                try? FileManager.default.removeItem(at: audioURL)
                return nil
            }
            if let old = try? Data(contentsOf: HaoAudioCache.metadataURL(trackID: trackID, cachesURL: cachesURL)),
               let oldEntry = try? JSONDecoder().decode(AudioCacheEntry.self, from: old),
               oldEntry.fileName != fileName {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(oldEntry.fileName))
            }
            try? meta.write(to: HaoAudioCache.metadataURL(trackID: trackID, cachesURL: cachesURL), options: [.atomic])
            HaoAudioCache.evictLRUIfNeeded(cachesURL: cachesURL)
            return entry
        }

        func cancel() {
            guard !finished else { return }
            finished = true
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    // MARK: Eviction / accounting

    /// Total bytes of cached audio files.
    static func totalBytes(cachesURL: URL? = nil) -> Int64 {
        let dir = audioDirectory(cachesURL: cachesURL)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var total: Int64 = 0
        for name in names where !name.hasPrefix("tmp-") && !name.hasSuffix(".json") {
            if let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value {
                total += size
            }
        }
        return total
    }

    /// Evict least-recently-used (by mtime) files until under the
    /// cap. Leased (playing) files are never evicted.
    ///
    /// b49fix2 P2-15: the track id used to be parsed by splitting
    /// the audio file name on "-" (`<trackID>-<uuid>.<ext>`), but
    /// a track id may itself contain "-" (only /, \, : and NUL
    /// are sanitised out), so the first segment was the wrong id:
    /// the lease check missed and the metadata delete removed the
    /// wrong `<id>.json`. The metadata file is the authority now:
    /// each `<trackID>.json` names its own audio file and track
    /// id, so no filename parsing happens at all. An audio file
    /// with no metadata (orphan) is evicted by its own mtime
    /// with no metadata to delete.
    static func evictLRUIfNeeded(cachesURL: URL? = nil) {
        let cap = limitBytes(freeBytes: AutomaticCacheLimit.freeBytes(), cachesURL: cachesURL)
        var total = totalBytes(cachesURL: cachesURL)
        guard total > cap else { return }
        let dir = audioDirectory(cachesURL: cachesURL)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        // Metadata files: the authority for track id + audio name.
        var byFileName: [String: AudioCacheEntry] = [:]
        for name in names where name.hasSuffix(".json") {
            let metaURL = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: metaURL),
                  let entry = try? JSONDecoder().decode(AudioCacheEntry.self, from: data)
            else { continue }
            byFileName[entry.fileName] = entry
        }
        var files: [(url: URL, mtime: Date, size: Int64, trackID: String?)] = []
        for name in names where !name.hasPrefix("tmp-") && !name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber,
                  let mtime = attrs[.modificationDate] as? Date
            else { continue }
            files.append((url, mtime, size.int64Value, byFileName[name]?.trackID))
        }
        files.sort { $0.mtime < $1.mtime }
        for file in files where total > cap {
            if let trackID = file.trackID, isLeased(trackID: trackID) { continue }
            try? FileManager.default.removeItem(at: file.url)
            if let trackID = file.trackID {
                try? FileManager.default.removeItem(at: metadataURL(trackID: trackID, cachesURL: cachesURL))
            }
            total -= file.size
        }
    }

    /// Remove every cached audio file + metadata (user clear).
    /// The directory itself is kept.
    static func clear(cachesURL: URL? = nil) {
        let dir = audioDirectory(cachesURL: cachesURL)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}

// MARK: - Automatic cache limit (moved, b45-fix #25)

// `AutomaticCacheLimit` moved to DownloadEngine.swift: this
// file cannot join AppCore (clearAll calls the UIKit image
// loaders HaoImageLoader / EmbyImageLoader), while
// DownloadEngine.swift is in AppCore and needs the limit for
// its storage check. The enum is Foundation-only, so it
// compiles in both targets.

// MARK: - b45-F: offline metadata directory (plan §7.1/§7.5)
//
// Track metadata for offline recovery (playlist snapshots,
// downloaded tracks): non-NetEase tracks get a negative
// synthetic id (SHA-free FNV-1a of `provider:kind:value`, so it
// can never collide with a NetEase positive id). Writes are
// debounced 500 ms and batched to one disk write.

struct OfflineTrackMeta: Codable, Equatable {
    /// Negative synthetic id for non-NetEase tracks; the real id
    /// for NetEase tracks.
    let id: Int
    let title: String
    let artist: String
    let album: String
    let cover: String
    let durationMs: Int
    let platform: String
}

enum OfflineMetadataStore {
    static let fileName = "hao_offline_catalog.json"
    /// Debounce window for batched disk writes.
    static let writeDebounce: TimeInterval = 0.5

    private static var entries: [String: OfflineTrackMeta] = [:]
    private static var loaded = false
    private static var pendingWrite: DispatchWorkItem?
    private static let queue = DispatchQueue(label: "com.haostudio.offlinemeta")

    /// Negative synthetic id: FNV-1a 64-bit hash, folded into a
    /// negative Int. Never collides with a NetEase positive id.
    static func syntheticID(provider: String, kind: String, value: String) -> Int {
        let text = "\(provider):\(kind):\(value)"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let magnitude = Int64(bitPattern: hash & 0x00FF_FFFF_FFFF_FFFF)
        return -Int(magnitude) - 1
    }

    static func catalogURL(documentsURL: URL? = nil) -> URL {
        let docs = documentsURL ?? LocalStore.documentsDirectory()
        return docs.appendingPathComponent(fileName)
    }

    static func record(_ meta: OfflineTrackMeta, documentsURL: URL? = nil) {
        queue.async {
            loadIfNeeded(documentsURL: documentsURL)
            entries["\(meta.id)"] = meta
            scheduleWrite(documentsURL: documentsURL)
        }
    }

    static func meta(forID id: Int, documentsURL: URL? = nil) -> OfflineTrackMeta? {
        queue.sync {
            loadIfNeeded(documentsURL: documentsURL)
            return entries["\(id)"]
        }
    }

    static func all(documentsURL: URL? = nil) -> [OfflineTrackMeta] {
        queue.sync {
            loadIfNeeded(documentsURL: documentsURL)
            return Array(entries.values)
        }
    }

    /// Flush any pending debounced write immediately (tests /
    /// backgrounding).
    static func flush(documentsURL: URL? = nil) {
        queue.sync {
            pendingWrite?.cancel()
            pendingWrite = nil
            writeNow(documentsURL: documentsURL)
        }
    }

    private static func loadIfNeeded(documentsURL: URL?) {
        guard !loaded else { return }
        loaded = true
        // b49fix2 P0-1: a corrupt catalog used to read as empty,
        // and the next debounced write then overwrote the user's
        // metadata with the empty map. Quarantine it instead —
        // same shape as LocalStore.loadCollection — so the data
        // survives for manual recovery.
        guard let data = try? Data(contentsOf: catalogURL(documentsURL: documentsURL)) else { return }
        guard let decoded = try? JSONDecoder().decode([String: OfflineTrackMeta].self, from: data)
        else {
            LocalStore.quarantineFile(
                at: catalogURL(documentsURL: documentsURL),
                name: fileName.replacingOccurrences(of: ".json", with: ""),
                reason: "decode failed", documentsURL: documentsURL)
            return
        }
        entries = decoded
    }

    private static func scheduleWrite(documentsURL: URL?) {
        pendingWrite?.cancel()
        let work = DispatchWorkItem {
            writeNow(documentsURL: documentsURL)
        }
        pendingWrite = work
        queue.asyncAfter(deadline: .now() + writeDebounce, execute: work)
    }

    private static func writeNow(documentsURL: URL?) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: catalogURL(documentsURL: documentsURL), options: [.atomic])
    }
}

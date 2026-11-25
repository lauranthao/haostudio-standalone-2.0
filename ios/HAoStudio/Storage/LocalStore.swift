// HAo Studio 2.0 — local storage layer (foundation slice).
//
// Two tiers, and nothing else:
// - SETTINGS: UserDefaults (theme, appearance, audio target quality …).
//   Small scalar values only; keys are documented where they are used
//   (see docs/storage-mapping.md for the Flutter Hive correspondence).
// - COLLECTIONS / INDEXES: Codable JSON files under Documents
//   (`Documents/<collection>.json`). These are the lists the app owns:
//   local files, downloads, wallpapers, favourites, custom sources …
// - Stored file references are RELATIVE NAMES ONLY (`<subdir>/<file>`),
///   never absolute paths. iOS changes the app container UUID on every
///   (re)install, so an absolute path stored in an index dies with the
///   old container — and the 1.1.0 -> 1.1.1 upgrade then pruned the
///   index entry itself and lost the user's imported files (chen
///   2026-11-18). The rules, enforced by `LocalFileIndex` below:
///   1. Load repairs before it deletes: an old absolute entry is
///      re-resolved under the CURRENT Documents directory first.
///   2. Before anything is pruned, the directory is rescanned: a file
///      found on disk under its basename is kept, not dropped.
///   3. An entry is pruned ONLY when the file is gone in every place
///      we know (old absolute path, current relative path, rescan).
///   4. A repaired/pruned index is written back only after the load
///      above — never during a bare read that failed halfway.

import Foundation

enum LocalStore {
    /// App Documents directory (current container — rebuilt on every
    /// read, never cached across launches).
    static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// URL of a collection JSON file: `Documents/<name>.json`.
    static func collectionURL(named name: String) -> URL {
        documentsDirectory().appendingPathComponent("\(name).json")
    }

    /// Load a Codable collection, returning `defaultValue` when the file
    /// does not exist or cannot be decoded (a corrupt index must never
    /// crash launch; the player/settings slices surface it if needed).
    ///
    /// A file that EXISTS but does not decode is quarantined, never
    /// silently read as empty: reading it as empty and then saving
    /// would permanently overwrite the user's data with the default
    /// (b49fix2 P0-1). The corrupt file moves aside to
    /// `<name>.corrupt-<date>.json` and is recorded in
    /// `hao_store_quarantine.json`, so the data survives for manual
    /// recovery; `.haoStoreQuarantined` posts once per file.
    static func loadCollection<T: Decodable>(
        named name: String,
        default defaultValue: T
    ) -> T {
        let url = collectionURL(named: name)
        guard let data = try? Data(contentsOf: url) else { return defaultValue }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            quarantineFile(at: url, name: name, reason: "decode failed")
            return defaultValue
        }
        return decoded
    }

    /// Move a corrupt file aside and record it, so a later save can
    /// never overwrite the user's data with a default. The record
    /// file carries a `version` field (schema version 1) so a future
    /// reader can tell the record's shape apart. `documentsURL` is
    /// the test seam (nil = the real container); MigrationStore
    /// passes its own documents URL so tests quarantine into the
    /// temp container, never the real one.
    ///
    /// b49fix19 P2-9a: the record read → append → write is
    /// guarded by a lock — two simultaneous quarantines used to
    /// race (both read the same record, both appended, the
    /// second write dropped the first record; the file itself
    /// was already moved aside, only the record was lost).
    private static let quarantineLock = NSLock()

    static func quarantineFile(
        at url: URL,
        name: String,
        reason: String,
        documentsURL: URL? = nil
    ) {
        let docs = documentsURL ?? documentsDirectory()
        let stamp: String = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            return formatter.string(from: Date())
        }()
        // b49fix18 D-9: the stamp alone is second-precision —
        // a second quarantine of the same file within the same
        // second collided on the destination, moveItem failed,
        // and the guard below returned silently: the corrupt
        // file stayed in place and the following overwrite
        // destroyed the very bytes quarantine exists to
        // preserve, with no record. The UUID suffix makes the
        // destination unique (same pattern as
        // MigrationBackup.timestamp()).
        let quarantinedURL = docs
            .appendingPathComponent("\(name).corrupt-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        guard (try? FileManager.default.moveItem(at: url, to: quarantinedURL)) != nil else {
            return
        }
        quarantineLock.lock()
        defer { quarantineLock.unlock() }
        let recordURL = docs
            .appendingPathComponent("\(quarantineRecordFile).json")
        var record = (try? Data(contentsOf: recordURL))
            .flatMap { try? JSONDecoder().decode(StoreQuarantineRecord.self, from: $0) }
            ?? StoreQuarantineRecord(version: 1, files: [])
        record.files.append(QuarantinedStoreFile(
            name: name, quarantinedAt: Date(), reason: reason))
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: recordURL, options: [.atomic])
        }
        NotificationCenter.default.post(name: .haoStoreQuarantined, object: name)
    }

    /// Quarantine record file name (without extension).
    static let quarantineRecordFile = "hao_store_quarantine"

    /// Save-failure notices are posted at most once per collection
    /// per launch (b49fix2 P1-13): 27 call sites ignore the Bool,
    /// and a full disk would otherwise spam the toast on every
    /// write. Guarded by a lock: saves run on background queues
    /// (download engine, backup engine) as well as main.
    private static var reportedSaveFailures = Set<String>()
    private static let saveFailureLock = NSLock()

    /// Save a Codable collection atomically.
    /// Returns false when the encode or the write failed (callers
    /// that keep a second copy — e.g. EmbyConfigStore, whose
    /// credential lives in the Keychain — must know the JSON did
    /// not land). @discardableResult: most callers ignore it.
    /// A failed write posts `.haoStoreSaveFailed` once per
    /// collection per launch, so the shell can warn about a full
    /// disk instead of losing data silently.
    @discardableResult
    static func saveCollection<T: Encodable>(named name: String, value: T) -> Bool {
        let url = collectionURL(named: name)
        guard let data = try? JSONEncoder().encode(value) else { return false }
        do {
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            saveFailureLock.lock()
            let firstReport = reportedSaveFailures.insert(name).inserted
            saveFailureLock.unlock()
            if firstReport {
                NotificationCenter.default.post(name: .haoStoreSaveFailed, object: name)
            }
            return false
        }
    }
}

/// One file moved aside by quarantine (b49fix2 P0-1).
struct QuarantinedStoreFile: Codable {
    let name: String
    let quarantinedAt: Date
    let reason: String
}

/// The quarantine record (`hao_store_quarantine.json`). `version`
/// is the record schema version (1); a future reader can tell
/// the record's shape apart from the file list itself.
struct StoreQuarantineRecord: Codable {
    let version: Int
    var files: [QuarantinedStoreFile]
}

enum LocalFileIndex {
    /// Resolve a stored value to an existing file URL, or nil.
    /// Order (mirrors the Flutter LocalPaths resolution):
    ///   1. the stored value as-is, when it is absolute and the file
    ///      still exists (same container — covers pre-migration files);
    ///   2. `<current Documents>/<subdir>/<basename>` (container moved);
    ///   3. nil — the file is gone in every place we know.
    /// A stored value that is already relative goes straight to step 2.
    static func resolve(_ stored: String, subdir: String) -> URL? {
        guard !stored.isEmpty else { return nil }
        if stored.hasPrefix("/") {
            let absolute = URL(fileURLWithPath: stored)
            if FileManager.default.fileExists(atPath: absolute.path) {
                return absolute
            }
        }
        let name = URL(fileURLWithPath: stored).lastPathComponent
        guard !name.isEmpty else { return nil }
        let candidate = LocalStore.documentsDirectory()
            .appendingPathComponent(subdir)
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Repair-then-prune load for an index of stored file names.
    /// - Repairs old absolute entries to their relative form when the
    ///   file still exists under the current container.
    /// - Rescans `subdir` before pruning: a file found on disk under
    ///   its basename is kept (the index was stale, the file was not
    ///   lost).
    /// - Drops an entry ONLY when the file is missing in all three
    ///   places (old absolute path, current relative path, rescan).
    /// Returns the surviving relative names. Callers write the result
    /// back with `LocalStore.saveCollection` when it differs from what
    /// was stored.
    static func loadRepaired(_ stored: [String], subdir: String) -> [String] {
        let dir = LocalStore.documentsDirectory().appendingPathComponent(subdir)
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let onDiskSet = Set(onDisk)
        var kept: [String] = []
        for entry in stored {
            if let resolved = resolve(entry, subdir: subdir) {
                // Keep the RELATIVE form from now on.
                let name = resolved.lastPathComponent
                kept.append("\(subdir)/\(name)")
            } else if onDiskSet.contains(URL(fileURLWithPath: entry).lastPathComponent) {
                // Rescan found it: the file exists, only the index was stale.
                let name = URL(fileURLWithPath: entry).lastPathComponent
                kept.append("\(subdir)/\(name)")
            }
            // Else: gone everywhere — pruned.
        }
        return kept
    }
}

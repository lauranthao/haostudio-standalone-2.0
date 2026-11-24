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
    static func loadCollection<T: Decodable>(
        named name: String,
        default defaultValue: T
    ) -> T {
        let url = collectionURL(named: name)
        guard let data = try? Data(contentsOf: url) else { return defaultValue }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            return defaultValue
        }
        return decoded
    }

    /// Save a Codable collection atomically.
    /// Returns false when the encode or the write failed (callers
    /// that keep a second copy — e.g. EmbyConfigStore, whose
    /// credential lives in the Keychain — must know the JSON did
    /// not land). @discardableResult: most callers ignore it.
    @discardableResult
    static func saveCollection<T: Encodable>(named name: String, value: T) -> Bool {
        let url = collectionURL(named: name)
        guard let data = try? JSONEncoder().encode(value) else { return false }
        do {
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }
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

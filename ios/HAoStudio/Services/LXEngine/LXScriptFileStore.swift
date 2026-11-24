// LXScriptFileStore.swift
// Script files on disk: `Documents/lx_scripts/<id>.js`.
//
// Mirrors the Flutter layout exactly: bundled scripts are seeded
// from the app bundle the first time (seed-if-missing, never
// overwriting a user edit), user scripts live in the same directory,
// and a bundled id the user deleted is never re-seeded. File names
// are relative names only — never absolute paths (iOS changes the
// container UUID on reinstall; see `LocalStore`).

import Foundation
import CryptoKit

final class LXScriptFileStore {
    /// Directory name under Documents (contract, same as Flutter).
    static let directoryName = "lx_scripts"

    private let documentsDirectory: URL
    private let fileManager: FileManager

    init(documentsDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.documentsDirectory = documentsDirectory ?? LocalStore.documentsDirectory()
        self.fileManager = fileManager
    }

    var directory: URL {
        documentsDirectory.appendingPathComponent(Self.directoryName)
    }

    func fileURL(forFileName fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    func fileURL(forScriptID id: String) -> URL {
        fileURL(forFileName: "\(id).js")
    }

    // MARK: - Seed / read / write / delete

    /// Copies the bundled script into Documents when no user file
    /// exists yet. Never overwrites. Returns the file URL when the
    /// file exists afterwards, nil when there is no bundled code to
    /// seed from and no file yet.
    @discardableResult
    func seedIfMissing(id: String, bundleCode: String?) -> URL? {
        let url = fileURL(forScriptID: id)
        if fileManager.fileExists(atPath: url.path) { return url }
        guard let code = bundleCode else { return nil }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try code.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Seed refresh (build 36 item 6)

    /// File holding the seed hashes, `Documents/lx_script_seed_hashes.json`
    /// (id → SHA-256 hex of the content last seeded/refreshed).
    /// Same Documents JSON-file pattern as LXScriptStore; the
    /// record is what lets a refresh tell a pristine seed from a
    /// user-modified file. Pre-fix installs have no record.
    static let seedHashesFileName = "lx_script_seed_hashes.json"

    /// SHA-256 hex of a script body (equality only — never a secret).
    static func sha256Hex(_ code: String) -> String {
        let digest = SHA256.hash(data: Data(code.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func loadSeedHashes() -> [String: String] {
        let url = documentsDirectory.appendingPathComponent(Self.seedHashesFileName)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private func saveSeedHashes(_ hashes: [String: String]) {
        let url = documentsDirectory.appendingPathComponent(Self.seedHashesFileName)
        guard let data = try? JSONEncoder().encode(hashes) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    /// Recorded seed hash for one bundled id (nil = pre-fix
    /// install, no record yet).
    func recordedSeedHash(for id: String) -> String? {
        loadSeedHashes()[id]
    }

    func recordSeedHash(_ hash: String, for id: String) {
        var hashes = loadSeedHashes()
        hashes[id] = hash
        saveSeedHashes(hashes)
    }

    func dropSeedHash(for id: String) {
        var hashes = loadSeedHashes()
        hashes.removeValue(forKey: id)
        saveSeedHashes(hashes)
    }

    /// Seed a bundled script, refreshing a stale seed when the
    /// bundle changed (build 36 item 6). Decision table — see
    /// `LXScriptRefresh.decision`:
    /// - no file → seed from the bundle, record its hash;
    /// - file already current → keep, record the hash if missing;
    /// - pristine seed (hash matches the recorded seed) and the
    ///   bundle changed → refresh to the new bundle code, no backup;
    /// - user-modified file (hash differs from the recorded seed)
    ///   → NEVER touch;
    /// - stale pre-fix file with no recorded hash → refresh WITH a
    ///   one-time `<id>.js.bak` backup of the old content.
    /// A user-deleted bundled id is never re-seeded here: callers
    /// only pass ids the user has not deleted (LXEngine skips
    /// `deletedBundledIds`). Returns the file URL when the file
    /// exists afterwards, nil when there is no bundled code to
    /// seed from and no file yet. When `bundleCode` is nil AND the
    /// id is a removed bundled id (`LxBundledScript.removedBundledIDs`,
    /// e.g. `tang`): return nil even if an orphan file exists
    /// — the orphan must never be treated as a seeded script
    /// (LXEngine would load it) — and leave the file untouched;
    /// deleting it is `removeOrphanBundledFile`'s job. A nil bundle
    /// code for any other id (non-bundled user/test script, e.g.
    /// `fake1`) is NOT a removal: it falls through to the decision
    /// below, so its existing on-disk file still loads.
    @discardableResult
    func seedOrRefresh(id: String, bundleCode: String?) -> URL? {
        // Removed bundled id only: a nil bundle code alone does
        // not mean "removed" — non-bundled ids (user scripts, test
        // fakes like `fake1`) load their on-disk file through this
        // same path, so only a removed bundled id returns nil here.
        if bundleCode == nil && LxBundledScript.removedBundledIDs.contains(id) { return nil }
        let url = fileURL(forScriptID: id)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        let storedHash = recordedSeedHash(for: id)
        switch LXScriptRefresh.decision(existing: existing, bundle: bundleCode, storedHash: storedHash) {
        case .keep:
            return existing == nil ? nil : url
        case .write(let content, let backup, let newHash):
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                if let backup = backup {
                    let backupURL = fileURL(forFileName: "\(id).js.bak")
                    if !fileManager.fileExists(atPath: backupURL.path) {
                        try backup.write(to: backupURL, atomically: true, encoding: .utf8)
                    }
                }
                try content.write(to: url, atomically: true, encoding: .utf8)
                recordSeedHash(newHash, for: id)
                return url
            } catch {
                return existing == nil ? nil : url
            }
        }
    }

    /// Delete the on-disk copy of a bundled id that no longer ships
    /// (e.g. `tang`): the orphan file — and its `.bak`, if any —
    /// is removed and the seed-hash record dropped, so the id can
    /// never be re-seeded. Never touches custom scripts or bundled
    /// ids that still ship.
    @discardableResult
    func removeOrphanBundledFile(id: String) -> Bool {
        dropSeedHash(for: id)
        let fileOK = delete(id: id)
        _ = deleteFile(named: "\(id).js.bak")
        return fileOK
    }

    func read(id: String) -> String? {
        try? String(contentsOf: fileURL(forScriptID: id), encoding: .utf8)
    }

    func readFile(named fileName: String) -> String? {
        try? String(contentsOf: fileURL(forFileName: fileName), encoding: .utf8)
    }

    @discardableResult
    func write(code: String, fileName: String) -> Bool {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try code.write(to: fileURL(forFileName: fileName), atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func delete(id: String) -> Bool {
        let url = fileURL(forScriptID: id)
        guard fileManager.fileExists(atPath: url.path) else { return true }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func deleteFile(named fileName: String) -> Bool {
        let url = fileURL(forFileName: fileName)
        guard fileManager.fileExists(atPath: url.path) else { return true }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Custom-script identity

    /// Stable id for a user-imported script, derived from its content
    /// (SHA-1, first 12 hex chars — identity only, never a secret).
    /// Re-importing the same content yields the same id, so the old
    /// record is replaced, never duplicated (Flutter parity).
    static func customScriptID(for code: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(code.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "custom:file:\(hex.prefix(12))"
    }

    /// File name for a custom script: `custom-file-<digest>.js`.
    /// The `custom-` prefix guarantees it can never collide with a
    /// bundled `<id>.js` file.
    static func customFileName(for code: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(code.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "custom-file-\(hex.prefix(12)).js"
    }

    /// Best-effort name for a user script from its header
    /// (`@name` tag) or its file name.
    static func displayName(for code: String, fileName: String) -> String {
        if let name = LXScriptHeader.parseName(from: code) { return name }
        return URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    }
}

/// Pure refresh decision for one bundled script file (unit-tested).
/// Port of the build-36 item-6 design harness `refreshDecision`,
/// with SHA-256 (`LXScriptFileStore.sha256Hex`) in place of the
/// harness's stand-in hash — the algorithm only needs equality.
/// - `bundle` nil means the id no longer ships: never re-seed
///   (orphan deletion is the caller's job, see
///   `LXScriptFileStore.removeOrphanBundledFile`).
enum LXScriptRefresh {
    case keep
    case write(content: String, backup: String?, newHash: String)

    static func decision(existing: String?, bundle: String?, storedHash: String?) -> LXScriptRefresh {
        guard let bundle = bundle else { return .keep }
        guard let existing = existing else {
            return .write(content: bundle, backup: nil, newHash: LXScriptFileStore.sha256Hex(bundle))
        }
        if LXScriptFileStore.sha256Hex(existing) == LXScriptFileStore.sha256Hex(bundle) {
            if storedHash == nil {
                return .write(content: existing, backup: nil, newHash: LXScriptFileStore.sha256Hex(existing))
            }
            return .keep
        }
        if let stored = storedHash {
            if LXScriptFileStore.sha256Hex(existing) == stored {
                return .write(content: bundle, backup: nil, newHash: LXScriptFileStore.sha256Hex(bundle))
            }
            return .keep
        }
        return .write(content: bundle, backup: existing, newHash: LXScriptFileStore.sha256Hex(bundle))
    }
}

/// Minimal reader for a script's leading comment header. The engine
/// reads `@`-tags from the FIRST comment block only (scripts' own
/// `parseHeader` does the same), so the de-key comment we insert
/// AFTER that block is never mistaken for metadata.
enum LXScriptHeader {
    /// Returns the `@name` tag value from the leading comment block.
    static func parseName(from code: String) -> String? {
        guard let header = leadingCommentBlock(in: code) else { return nil }
        return tagValue("name", in: header)
    }

    /// Returns the `@version` tag value from the leading comment block.
    static func parseVersion(from code: String) -> String? {
        guard let header = leadingCommentBlock(in: code) else { return nil }
        return tagValue("version", in: header)
    }

    /// The first `/* … */` block at the start of the file (allowing
    /// leading whitespace). Nil when the file starts with code.
    static func leadingCommentBlock(in code: String) -> String? {
        let trimmed = code.drop(while: { $0.isWhitespace })
        guard trimmed.hasPrefix("/*") else { return nil }
        guard let end = trimmed.range(of: "*/") else { return nil }
        return String(trimmed[trimmed.startIndex..<end.upperBound])
    }

    private static func tagValue(_ tag: String, in header: String) -> String? {
        // Lines look like ` * @name suyin` or `@name suyin`.
        let pattern = "@\(tag)\\s+([^\\r\\n*]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: header,
                range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header)
        else { return nil }
        let value = header[range].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

// HAo Studio 2.0 — backup engine (S6, leg A).
//
// Export / import / validate / roll back, engine only — no UI, no
// update checker. One file, one `.zip`:
//   backup.json                 envelope + all UserDefaults values
//   collections/<name>.json     every Documents collection file, raw bytes
//   files/<relative path>       payload files (wallpapers, user LX
//                               scripts, downloads, local music,
//                               fonts, live recordings, logs)
//
// Form (correction 2026-11-23): completion handlers only, never
// the newer concurrency spelling — the project pins Swift 5.0
// and preflight check 5e forbids it. The public seam is B's
// `BackupEngine` protocol (see BackupUpdateLogic.swift):
// `exportBackup(completion:)` / `importBackup(from:completion:)`,
// completions on the main thread. `FileBackupEngine` below is the
// concrete implementation of that protocol; it runs the work on
// a background queue and waits for ALL writes with a dispatch
// group before the completion fires — the group leave happens
// only after the synchronous body (every write, plus any
// rollback) has returned, so "all writes finished before
// success is reported" holds structurally. `BackupEngineCore`
// is the static implementation with the test seams
// (documentsURL / defaults / currentVersion).
//
// Ownership at merge (one type, one file — S3 lesson): B owns
// `protocol BackupEngine`, `struct BackupImportReport`, and the
// `.haoBackupImported` notification declaration. This file
// declares NONE of those: its internal import result is
// `BackupImportDetail`, and it posts B's notification. This
// file does NOT compile on its own before B's
// BackupUpdateLogic.swift is merged in — that is the merge
// dependency, not a missing piece.
//
// Rules (plan section 7.2, S1 backup-before-write rule):
// - Export reads the CURRENT app version from the bundle for the
//   envelope; no version string is hardcoded here.
// - Import validates the envelope first, snapshots current storage
//   second, and only then writes. The core functions are
//   synchronous and return only after EVERY write has finished —
//   there is no fire-and-forget work anywhere in this file, and
//   the completion-handler wrapper waits on a dispatch group, so
//   success is never reported before the last write lands.
// - A failed write rolls EVERYTHING back to the snapshot:
//   defaults restored, files restored or removed, nothing left
//   half-applied.
// - Bad-typed keys are skipped, never fatal. Unknown keys are
//   isolated into `Documents/backup_unknown_keys.json`, never
//   applied, never dropped. Import is a merge, never a replace:
//   keys absent from the backup keep their current values.
// - Credentials NEVER enter a backup file. The Emby apiKey lives
//   only in the Keychain; the export strips it from the Emby
//   config and warns, in plain words, that the credential was
//   not exported and a fresh login is needed. LX script keys are
//   Keychain-only too and are never exported either.
// - Import never writes to the Keychain. A restored Emby config
//   without a stored key means "log in again", not a silent
//   failure.
// - After a successful import the engine posts B's
//   `Notification.Name.haoBackupImported` (declared in
//   BackupUpdateLogic.swift). The app layer observes it and
//   re-reads every setting (theme, stores, libraries) so
//   "import succeeded but nothing changed" cannot happen. The
//   engine itself touches no UI and no SwiftUI state.
//
// Coverage — what is backed up, from the real on-disk layout
// (docs/storage-mapping.md + the stores themselves, not invented):
// - S1's 136 keys + 4 key families (via MigrationStore.mappings,
//   prefix rules, and the ignored play-URL-cache prefix).
// - S5's new keys: `hao_glass_intensity`,
//   `hao_video_player_key`, `hao_video_last_engine`, and the
//   `settingsSectionExpanded_<id>` family.
//   （`hao_profile_nickname` removed chen 2026-11-24: 个人资料/会员已删。）
// - Every `Documents/*.json` collection file (playlists, favs,
//   recent, history, downloads index, sources, LX state, Emby
//   config without its key, …), except the transient
//   `migration_snapshot.json`.
// - Payload directories under Documents: `wallpapers/`,
//   `lx_scripts/` (bundled scripts are seeded from the bundle,
//   but a user-edited copy IS user data, so all of them go in),
//   `music_downloads/` (finished files only — `.part` resume
//   state is cache, not data), `local_music/`, `fonts/`,
//   `live_recordings/`, `logs/`.
// - `live_recordings/` and `logs/` have no Swift writer yet
//   (the plan lists them as missing from the old export); they
//   are defined here as the contract directories and packed
//   whenever they exist, empty when they do not — never an error.
// - NOT backed up: Keychain items, `music_playback_cache/`
//   (transient playback cache), `.part` files, the
//   `migration_backup/` and `backup_snapshots/` folders
//   (backups of backups), and the migration state keys
//   (`hao_migration_*` describe this install's migration, not
//   user data — restoring them would skip migration on a fresh
//   install).

import Foundation

enum BackupImportOutcome {
    case imported
    case rejected
    case failed
}

/// What one export produced. The zip is already on disk at
/// `zipURL` when this is returned; `warnings` is what the UI
/// shows the user (notably the Emby credential warning).
struct BackupExportResult {
    let zipURL: URL
    let envelope: BackupEnvelope
    let keyCount: Int
    let collectionCount: Int
    let fileCount: Int
    let warnings: [String]
}

/// What one import did, in full detail, for the engine's own
/// use. `outcome` is `.imported` only after every write landed
/// AND verified; `.rejected` means the file was refused before
/// anything was touched; `.failed` means a write or
/// verification failed and a full rollback ran. The UI-facing
/// shape is B's `BackupImportReport` (four fields); the
/// `FileBackupEngine` adapter below maps this detail onto it.
/// This struct is deliberately NOT named `BackupImportReport`:
/// that name belongs to B's file (one type, one file).
struct BackupImportDetail {
    let outcome: BackupImportOutcome
    let appliedKeys: Int
    let appliedCollections: Int
    let appliedFiles: Int
    let skippedKeyNames: [String]
    let unknownKeyNames: [String]
    let warnings: [String]
    let detail: String
    /// True when the backup carried an Emby config but no
    /// credential is stored now, so the user must log in again.
    let embyCredentialsMissing: Bool
}

enum BackupEngineCore {
    static let envelopeFileName = "backup.json"
    static let collectionsPrefix = "collections/"
    static let filesPrefix = "files/"
    static let unknownKeysFileName = "backup_unknown_keys"
    static let snapshotDirectoryName = "backup_snapshots"
    static let embyConfigFileName = "hao_emby_config"
    static let embyApiKeyField = "apiKey"

    /// The exact warning the export must show when the Emby
    /// credential is left out of the file. Keep this string
    /// verbatim: tests and the settings UI match on it.
    static let embyCredentialWarning = "Emby 凭证未导出，需重新登录"
    static let lxKeysWarning = "LX 脚本密钥未导出，需重新填入"

    /// Payload directories packed under `files/` (relative to
    /// Documents). A directory that does not exist yet packs
    /// zero entries — never an error.
    static let payloadSubdirs = [
        "wallpapers",
        "lx_scripts",
        "music_downloads",
        "local_music",
        "fonts",
        "live_recordings",
        "logs",
    ]

    /// Collection files that are never exported: the Flutter
    /// migration snapshot is a transient input, not user data.
    static let excludedCollectionFileNames: Set<String> = ["migration_snapshot"]

    /// Keys that are skipped on import without even being
    /// isolated: the play-URL cache is expired by construction
    /// (1 hour TTL, signed URLs), and the migration state keys
    /// describe this install, not the user's data.
    static let ignoredImportPrefixes = ["hao_play_url_cache:"]
    static let ignoredImportKeys: Set<String> = [
        "hao_migration_done_v1",
        "hao_migration_state",
        "hao_migration_notice_dismissed",
        // b36 follow-up: the VOD danmaku API token is a credential
        // and never enters a backup (see userDefaultsKeyKinds).
        // Old backups made by b36 item 11 already carry it — on
        // import it is skipped here, before the unknown-key
        // branch, so it is neither restored nor isolated into
        // backup_unknown_keys.json: the import succeeds, the
        // token simply stays whatever it is on this device.
        "hao_vod_danmaku_api_token",
    ]

    /// Test-only fault injection, mirroring MigrationStore:
    /// when set, the write for this defaults key (or this
    /// collection / payload path) fails on purpose so tests can
    /// prove the rollback. Never set in production code.
    static var testFailOnKey: String?
    static var testFailOnFile: String?

    /// Test-only override for the Keychain check below. Nil in
    /// production (the real Keychain is read).
    static var testEmbyCredentialPresent: Bool?

    /// True when an Emby apiKey is currently stored in the
    /// Keychain — i.e. when an export is about to leave a
    /// credential behind and must warn about it.
    static func embyCredentialPresent() -> Bool {
        if let test = testEmbyCredentialPresent {
            return test
        }
        return KeychainStore.loadEmbyApiKey() != nil
    }

    /// Suggested file name for a fresh export, e.g.
    /// `HAoStudio-backup-20261123-204500-a1b2c3d4.zip`. The
    /// short UUID suffix keeps two exports in the same second
    /// from colliding in the temp directory.
    static func backupFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "HAoStudio-backup-" + formatter.string(from: date)
            + "-" + String(UUID().uuidString.prefix(8)) + ".zip"
    }

    // MARK: - Key catalogue (S1 + S5, from the real stores)

    /// Every UserDefaults key the backup covers, with the type
    /// the mapping table promises. S1's table comes from
    /// MigrationStore itself (one source of truth, no copy);
    /// the S5 additions are the keys S5 introduced that S1
    /// never had (see ios/SEAM-S5.md).
    static func userDefaultsKeyKinds() -> [String: MigrationKeyKind] {
        var out: [String: MigrationKeyKind] = [:]
        for mapping in MigrationStore.mappings {
            if case .userDefaults = mapping.destination {
                out[mapping.key] = mapping.kind
            }
        }
        out["hao_glass_intensity"] = .double
        out["hao_video_player_key"] = .string
        out["hao_video_last_engine"] = .string
        // b36 item 11: VOD danmaku API address (plain UserDefaults
        // string, same as the S5 additions above). The address is
        // not a secret, so it stays in the whitelist and a restore
        // brings it back without re-typing. The TOKEN does not:
        // b36 follow-up removes it from the whitelist, like the
        // Emby apiKey precedent — a credential must never sit in
        // a backup zip in plain text. Old backups that already
        // carry it are handled on import: the key is listed in
        // ignoredImportKeys below, so it is skipped, never
        // applied, and never isolated into backup_unknown_keys.json
        // (isolating it would still leave the token on disk in
        // plain text).
        out["hao_vod_danmaku_api_url"] = .string
        return out
    }

    /// The settings-section expanded-state family
    /// (`settingsSectionExpanded_<id>`, one bool per section).
    /// Members are discovered by scanning the defaults domain,
    /// because the section ids are UI-owned, not a fixed list.
    static let sectionExpandedPrefix = "settingsSectionExpanded_"

    // MARK: - Validation only (for the UI to preview before import)

    /// Reads only `backup.json` out of a zip and validates its
    /// envelope. No storage is touched. The settings UI calls
    /// this to show the backup's contents before asking the
    /// user to confirm the import.
    static func validateBackupFile(
        at zipURL: URL,
        currentVersion: BackupVersion? = nil,
        bundle: Bundle = .main
    ) -> BackupValidation {
        guard let entries = ZipArchive.listEntries(at: zipURL) else {
            return .rejected("不是有效的备份压缩包")
        }
        guard let envelopeEntry = entries.first(where: { $0.name == envelopeFileName }) else {
            return .rejected("压缩包里没有备份信封")
        }
        guard let envelopeData = ZipArchive.readEntryData(envelopeEntry, from: zipURL),
              let parsed = try? JSONSerialization.jsonObject(with: envelopeData, options: []),
              let root = parsed as? [String: Any]
        else {
            return .rejected("备份信封损坏")
        }
        let current = currentVersion ?? BackupEnvelope.currentAppVersion(bundle: bundle)
        return BackupEnvelope.validate(dictionary: root, currentVersion: current)
    }
}

extension BackupEngineCore {
    // MARK: - Export

    /// Exports everything into a single zip file at `zipURL`.
    /// Returns the result (with the envelope and warnings) when
    /// the zip was written, nil when the zip could not be
    /// written. The zip is written to a file, not held in
    /// memory, so large payload files fit. `documentsURL` and
    /// `defaults` are test seams (nil / standard = the real
    /// container); `currentVersion` overrides the bundle
    /// version in tests.
    static func exportBackup(
        to zipURL: URL,
        documentsURL: URL? = nil,
        defaults: UserDefaults = .standard,
        currentVersion: BackupVersion? = nil,
        bundle: Bundle = .main
    ) -> BackupExportResult? {
        let docs = documentsURL ?? LocalStore.documentsDirectory()
        let current = currentVersion ?? BackupEnvelope.currentAppVersion(bundle: bundle)
        let appVersion = current?.raw ?? ""
        let appBuild = BackupEnvelope.currentAppBuild(bundle: bundle)

        // 1. UserDefaults values, coerced to their promised types.
        // A value with the wrong type is left out and warned
        // about, never written as-is.
        let collected = collectExportData(defaults: defaults)
        let data = collected.data
        var warnings: [String] = []
        if !collected.skipped.isEmpty {
            warnings.append("\(collected.skipped.count) 个设置值类型异常，未导出")
        }

        // 2. Collection files, raw bytes, Emby config scrubbed.
        let collections = collectCollectionFiles(documentsURL: docs)
        var collectionBytes: [(name: String, bytes: Data)] = []
        for collection in collections {
            if collection.name == embyConfigFileName {
                guard let scrubbed = scrubEmbyConfig(bytes: collection.bytes) else {
                    warnings.append("Emby 配置无法解析，未导出")
                    continue
                }
                collectionBytes.append((name: collection.name, bytes: scrubbed))
            } else {
                collectionBytes.append(collection)
            }
        }

        // 3. Payload files (streamed into the zip, never loaded
        // whole into memory).
        let payloadPaths = collectPayloadFiles(documentsURL: docs)

        // 4. Envelope + manifest. The manifest is the import's
        // verification source: every entry's expected byte count.
        var contents: [BackupContentEntry] = []
        var zipEntries: [ZipEntry] = []
        let envelopePlaceholder = BackupContentEntry(path: envelopeFileName, kind: "envelope", bytes: 0)
        contents.append(envelopePlaceholder)
        for collection in collectionBytes.sorted(by: { $0.name < $1.name }) {
            let path = collectionsPrefix + collection.name + ".json"
            contents.append(BackupContentEntry(path: path, kind: "collection", bytes: collection.bytes.count))
            zipEntries.append(.data(name: path, data: collection.bytes))
        }
        for relativePath in payloadPaths.sorted() {
            let path = filesPrefix + relativePath
            let fileURL = docs.appendingPathComponent(relativePath)
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
            contents.append(BackupContentEntry(path: path, kind: "file", bytes: size))
            zipEntries.append(.file(name: path, fileURL: fileURL))
        }

        // 5. Credential warnings. The Emby apiKey stays in the
        // Keychain and out of the file — the warning says so in
        // plain words instead of silently dropping it. LX script
        // keys are Keychain-only too; warn when the user has
        // custom scripts (the only scripts that can hold keys).
        if embyCredentialPresent() {
            warnings.append(embyCredentialWarning)
        }
        if hasCustomLXScripts(data: data, documentsURL: docs) {
            warnings.append(lxKeysWarning)
        }

        let counts: [String: Int] = [
            "keys": data.count,
            "collections": collectionBytes.count,
            "files": payloadPaths.count,
            "skippedKeys": collected.skipped.count,
        ]
        let exportedAt = ISO8601DateFormatter().string(from: Date())
        // The manifest's envelope entry must state the envelope's
        // own final byte count, but the count is part of the
        // encoded envelope — so encode to a fixed point: the byte
        // count only grows when its digit length grows, which
        // settles within a couple of rounds.
        var envelope = BackupEnvelope(
            appVersion: appVersion, appBuild: appBuild,
            exportedAt: exportedAt, contents: contents,
            warnings: warnings, counts: counts
        )
        var envelopeBytes = 0
        var finalData = Data()
        for _ in 0..<4 {
            contents[0] = BackupContentEntry(path: envelopeFileName, kind: "envelope", bytes: envelopeBytes)
            envelope = BackupEnvelope(
                appVersion: appVersion, appBuild: appBuild,
                exportedAt: exportedAt, contents: contents,
                warnings: warnings, counts: counts
            )
            var root = envelope.asDictionary()
            root["data"] = data
            guard let encoded = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else {
                return nil
            }
            finalData = encoded
            if encoded.count == envelopeBytes {
                break
            }
            envelopeBytes = encoded.count
        }
        guard finalData.count == envelopeBytes else { return nil }
        var allEntries: [ZipEntry] = [.data(name: envelopeFileName, data: finalData)]
        allEntries.append(contentsOf: zipEntries)
        guard ZipArchive.write(entries: allEntries, to: zipURL) else {
            return nil
        }
        return BackupExportResult(
            zipURL: zipURL, envelope: envelope,
            keyCount: data.count,
            collectionCount: collectionBytes.count,
            fileCount: payloadPaths.count,
            warnings: warnings
        )
    }

    /// Reads the covered UserDefaults keys out of a defaults
    /// suite, coerced to their promised types. Returns the data
    /// dict plus the keys whose stored value had the wrong type.
    static func collectExportData(defaults: UserDefaults) -> (data: [String: Any], skipped: [String]) {
        var data: [String: Any] = [:]
        var skipped: [String] = []
        let kinds = userDefaultsKeyKinds()
        for key in kinds.keys.sorted() {
            guard let kind = kinds[key],
                  let raw = defaults.object(forKey: key)
            else { continue }
            if let coerced = MigrationStore.coerce(raw, as: kind) {
                data[key] = coerced
            } else {
                skipped.append(key)
            }
        }
        for key in defaults.dictionaryRepresentation().keys.sorted() {
            guard key.hasPrefix(sectionExpandedPrefix) else { continue }
            guard let number = defaults.object(forKey: key) as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID()
            else {
                skipped.append(key)
                continue
            }
            data[key] = number.boolValue
        }
        return (data: data, skipped: skipped)
    }

    /// Every `Documents/*.json` collection file as raw bytes.
    /// The transient migration snapshot is excluded; everything
    /// else is user data and goes in byte-identical.
    static func collectCollectionFiles(documentsURL: URL) -> [(name: String, bytes: Data)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: documentsURL.path)) ?? []
        var out: [(name: String, bytes: Data)] = []
        for fileName in names.sorted() {
            guard fileName.hasSuffix(".json") else { continue }
            let base = String(fileName.dropLast(".json".count))
            guard !base.isEmpty, !excludedCollectionFileNames.contains(base) else {
                continue
            }
            let url = documentsURL.appendingPathComponent(fileName)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  !isDir.boolValue,
                  let bytes = try? Data(contentsOf: url)
            else { continue }
            out.append((name: base, bytes: bytes))
        }
        return out
    }

    /// Relative paths (`<subdir>/<file>`) of every payload file
    /// under the known subdirectories, recursive. Hidden files
    /// and `.part` resume state are skipped: the first is never
    /// user data, the second is cache, not data.
    static func collectPayloadFiles(documentsURL: URL) -> [String] {
        var out: [String] = []
        for subdir in payloadSubdirs {
            let dir = documentsURL.appendingPathComponent(subdir)
            collectPayloadFilesRecursive(dir: dir, prefix: subdir, into: &out)
        }
        return out
    }

    private static func collectPayloadFilesRecursive(dir: URL, prefix: String, into out: inout [String]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names.sorted() {
            guard !name.hasPrefix(".") else { continue }
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                continue
            }
            let relative = prefix + "/" + name
            if isDir.boolValue {
                collectPayloadFilesRecursive(dir: url, prefix: relative, into: &out)
            } else if !name.hasSuffix(".part") {
                out.append(relative)
            }
        }
    }

    /// Removes the `apiKey` field from Emby config JSON bytes.
    /// Returns nil when the bytes do not parse as a JSON object
    /// at all — an unparseable config is excluded rather than
    /// exported raw, because raw bytes could still carry the
    /// key as plain text.
    static func scrubEmbyConfig(bytes: Data) -> Data? {
        guard let parsed = try? JSONSerialization.jsonObject(with: bytes, options: []),
              var config = parsed as? [String: Any]
        else { return nil }
        config.removeValue(forKey: embyApiKeyField)
        guard let scrubbed = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) else {
            return nil
        }
        return scrubbed
    }

    /// True when the user has self-imported LX scripts (the
    /// `hao_lx_custom` collection is non-empty): only those
    /// scripts can hold Keychain keys, so only then is the LX
    /// warning factual.
    static func hasCustomLXScripts(data: [String: Any], documentsURL: URL) -> Bool {
        if let custom = data["hao_lx_custom"] {
            if let list = custom as? [Any], !list.isEmpty {
                return true
            }
            if let dict = custom as? [String: Any], !dict.isEmpty {
                return true
            }
        }
        let url = documentsURL.appendingPathComponent("hao_lx_custom.json")
        guard let bytes = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: bytes, options: [])
        else { return false }
        if let list = parsed as? [Any] {
            return !list.isEmpty
        }
        if let dict = parsed as? [String: Any] {
            return !dict.isEmpty
        }
        return false
    }
}

extension BackupEngineCore {
    // MARK: - Import

    /// Imports a backup zip: validates the envelope, snapshots
    /// current storage, applies every entry, verifies every
    /// write, and rolls everything back on any failure. Merge,
    /// not replace: keys absent from the backup keep their
    /// current values. Synchronous — it returns only after all
    /// writes (and any rollback) have finished. On success it
    /// posts `Notification.Name.haoBackupImported` so the app
    /// layer re-reads every setting.
    static func importBackup(
        from zipURL: URL,
        documentsURL: URL? = nil,
        defaults: UserDefaults = .standard,
        currentVersion: BackupVersion? = nil,
        bundle: Bundle = .main
    ) -> BackupImportDetail {
        let docs = documentsURL ?? LocalStore.documentsDirectory()
        let current = currentVersion ?? BackupEnvelope.currentAppVersion(bundle: bundle)
        switch validateBackupFile(at: zipURL, currentVersion: current, bundle: bundle) {
        case .rejected(let reason):
            return BackupImportDetail(
                outcome: .rejected, appliedKeys: 0, appliedCollections: 0,
                appliedFiles: 0, skippedKeyNames: [], unknownKeyNames: [],
                warnings: [], detail: reason, embyCredentialsMissing: false
            )
        case .valid:
            break
        }
        guard let entries = ZipArchive.listEntries(at: zipURL),
              let envelopeEntry = entries.first(where: { $0.name == envelopeFileName }),
              let envelopeData = ZipArchive.readEntryData(envelopeEntry, from: zipURL),
              let parsed = try? JSONSerialization.jsonObject(with: envelopeData, options: []),
              let root = parsed as? [String: Any],
              let data = root["data"] as? [String: Any]
        else {
            return BackupImportDetail(
                outcome: .rejected, appliedKeys: 0, appliedCollections: 0,
                appliedFiles: 0, skippedKeyNames: [], unknownKeyNames: [],
                warnings: [], detail: "备份信封损坏", embyCredentialsMissing: false
            )
        }

        // 1. Plan: classify every data key and every zip entry
        // BEFORE touching storage. Nothing is written in this step.
        let plan = planImport(data: data, entries: entries, zipURL: zipURL, documentsURL: docs)
        switch plan {
        case .failure(let reason):
            return BackupImportDetail(
                outcome: .failed, appliedKeys: 0, appliedCollections: 0,
                appliedFiles: 0, skippedKeyNames: [], unknownKeyNames: [],
                warnings: [], detail: reason, embyCredentialsMissing: false
            )
        case .planned(let planned):
            return applyPlannedImport(
                planned: planned, zipURL: zipURL,
                documentsURL: docs, defaults: defaults
            )
        }
    }

    // MARK: - Import planning

    private struct PlannedCollection {
        let name: String
        let bytes: Data
    }

    private struct PlannedFile {
        let relativePath: String
        let entry: ZipEntryInfo
    }

    private struct PlannedImport {
        var defaultWrites: [(key: String, value: Any, kind: MigrationKeyKind)] = []
        var collections: [PlannedCollection] = []
        var mergedFiles: [String: Data] = [:]
        var payloadFiles: [PlannedFile] = []
        var unknown: [String: Any] = [:]
        var skipped: [String] = []
        var warnings: [String] = []
        var hasEmbyConfig = false
    }

    private enum ImportPlan {
        case planned(PlannedImport)
        case failure(String)
    }

    private static func planImport(
        data: [String: Any],
        entries: [ZipEntryInfo],
        zipURL: URL,
        documentsURL: URL
    ) -> ImportPlan {
        var planned = PlannedImport()
        let kinds = userDefaultsKeyKinds()

        for key in data.keys.sorted() {
            guard let rawValue = data[key] else { continue }
            if let kind = kinds[key] {
                if let coerced = MigrationStore.coerce(rawValue, as: kind) {
                    planned.defaultWrites.append((key: key, value: coerced, kind: kind))
                } else {
                    planned.skipped.append(key)
                }
            } else if key.hasPrefix(sectionExpandedPrefix) {
                if let number = rawValue as? NSNumber,
                   CFGetTypeID(number) == CFBooleanGetTypeID() {
                    planned.defaultWrites.append((key: key, value: number.boolValue, kind: .bool))
                } else {
                    planned.skipped.append(key)
                }
            } else if key == embyConfigFileName {
                if let config = rawValue as? [String: Any] {
                    var stored = config
                    stored.removeValue(forKey: embyApiKeyField)
                    if let bytes = try? JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys]) {
                        planned.collections.append(PlannedCollection(name: embyConfigFileName, bytes: bytes))
                        planned.hasEmbyConfig = true
                    } else {
                        planned.skipped.append(key)
                    }
                } else {
                    planned.skipped.append(key)
                }
            } else if let rule = MigrationStore.prefixRule(for: key) {
                if let coerced = MigrationStore.coerce(rawValue, as: rule.kind) {
                    mergePrefixValue(
                        key: key, value: coerced, rule: rule,
                        documentsURL: documentsURL, planned: &planned
                    )
                } else {
                    planned.skipped.append(key)
                }
            } else if ignoredImportKeys.contains(key) || isIgnoredImportKey(key) {
                planned.skipped.append(key)
            } else {
                planned.unknown[key] = rawValue
            }
        }

        // Zip entries: collections and payload files. Unknown
        // entry paths are ignored with a warning, never applied.
        for entry in entries {
            if entry.name == envelopeFileName {
                continue
            } else if entry.name.hasPrefix(collectionsPrefix) {
                let fileName = String(entry.name.dropFirst(collectionsPrefix.count))
                guard isSafeCollectionName(fileName) else {
                    planned.warnings.append("忽略了无法识别的备份条目：\(entry.name)")
                    continue
                }
                let base = String(fileName.dropLast(".json".count))
                guard let bytes = ZipArchive.readEntryData(entry, from: zipURL) else {
                    return .failure("备份条目损坏：\(entry.name)")
                }
                if base == embyConfigFileName {
                    guard let scrubbed = scrubEmbyConfig(bytes: bytes) else {
                        planned.warnings.append("Emby 配置无法解析，未恢复")
                        planned.skipped.append(embyConfigFileName)
                        continue
                    }
                    // The collection file wins over an Emby config
                    // that also arrived inside `data`.
                    planned.collections.removeAll(where: { $0.name == embyConfigFileName })
                    planned.collections.append(PlannedCollection(name: base, bytes: scrubbed))
                    planned.hasEmbyConfig = true
                } else {
                    planned.collections.append(PlannedCollection(name: base, bytes: bytes))
                }
            } else if entry.name.hasPrefix(filesPrefix) {
                let relativePath = String(entry.name.dropFirst(filesPrefix.count))
                guard isSafePayloadPath(relativePath) else {
                    planned.warnings.append("忽略了无法识别的备份条目：\(entry.name)")
                    continue
                }
                guard !relativePath.hasSuffix(".part") else { continue }
                planned.payloadFiles.append(PlannedFile(relativePath: relativePath, entry: entry))
            } else {
                planned.warnings.append("忽略了无法识别的备份条目：\(entry.name)")
            }
        }
        return .planned(planned)
    }

    /// Merges one key-family member (resume position, daily
    /// pick, listen shard) into its merged file, mirroring
    /// MigrationStore: resume positions cap at 200 entries,
    /// listen shards append and cap at 3000.
    private static func mergePrefixValue(
        key: String,
        value: Any,
        rule: MigrationPrefixRule,
        documentsURL: URL,
        planned: inout PlannedImport
    ) {
        if rule.fileName == "hao_listen" {
            var existing = MigrationStore.readJSONList(name: "hao_listen", documentsURL: documentsURL)
            if let priorBytes = planned.mergedFiles["hao_listen"],
               let priorParsed = try? JSONSerialization.jsonObject(with: priorBytes, options: []),
               let priorList = priorParsed as? [[String: Any]] {
                existing = priorList
            }
            if let list = value as? [[String: Any]] {
                existing.append(contentsOf: list)
            } else if let single = value as? [String: Any] {
                existing.append(single)
            } else {
                planned.skipped.append(key)
                return
            }
            if existing.count > 3000 {
                existing = Array(existing.suffix(3000))
            }
            if let bytes = try? JSONSerialization.data(withJSONObject: existing, options: []) {
                planned.mergedFiles["hao_listen"] = bytes
            }
            return
        }
        var existing = MigrationStore.readJSONDictionary(name: rule.fileName, documentsURL: documentsURL)
        if let priorBytes = planned.mergedFiles[rule.fileName],
           let priorParsed = try? JSONSerialization.jsonObject(with: priorBytes, options: []),
           let priorDict = priorParsed as? [String: Any] {
            existing = priorDict
        }
        existing[key] = value
        if rule.fileName == "haoVodProg", existing.count > 200 {
            existing = Dictionary(uniqueKeysWithValues: Array(existing.prefix(200)))
        }
        if let bytes = try? JSONSerialization.data(withJSONObject: existing, options: []) {
            planned.mergedFiles[rule.fileName] = bytes
        }
    }

    private static func isIgnoredImportKey(_ key: String) -> Bool {
        return ignoredImportPrefixes.contains { key.hasPrefix($0) }
    }

    private static func isSafeCollectionName(_ name: String) -> Bool {
        guard name.hasSuffix(".json"), !name.contains("/"), !name.hasPrefix(".") else {
            return false
        }
        let base = String(name.dropLast(".json".count))
        return !base.isEmpty && base != ".."
    }

    private static func isSafePayloadPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else {
            return false
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = parts.first, payloadSubdirs.contains(String(first)) else {
            return false
        }
        for part in parts {
            if part.isEmpty || part == "." || part == ".." {
                return false
            }
        }
        return true
    }
}

extension BackupEngineCore {
    // MARK: - Import: snapshot, apply, verify, roll back

    /// Applies a planned import. Snapshot first — when the
    /// snapshot cannot be created, nothing is written at all.
    /// Every write is synchronous and finishes before this
    /// function returns; a failure anywhere rolls back every
    /// write that already landed.
    private static func applyPlannedImport(
        planned: PlannedImport,
        zipURL: URL,
        documentsURL: URL,
        defaults: UserDefaults
    ) -> BackupImportDetail {
        // Touched files, relative to Documents: collections by
        // file name, merged files, the unknown-keys file, and
        // every payload path.
        var touchedFiles: [String] = []
        for collection in planned.collections {
            touchedFiles.append(collection.name + ".json")
        }
        for name in planned.mergedFiles.keys {
            touchedFiles.append(name + ".json")
        }
        if !planned.unknown.isEmpty {
            touchedFiles.append(unknownKeysFileName + ".json")
        }
        for file in planned.payloadFiles {
            touchedFiles.append(file.relativePath)
        }
        let defaultKeys = planned.defaultWrites.map { $0.key }

        guard let snapshotDir = createSnapshot(
            defaultKeys: defaultKeys, filePaths: touchedFiles,
            documentsURL: documentsURL, defaults: defaults
        ) else {
            return BackupImportDetail(
                outcome: .failed, appliedKeys: 0, appliedCollections: 0,
                appliedFiles: 0, skippedKeyNames: planned.skipped.sorted(),
                unknownKeyNames: Array(planned.unknown.keys).sorted(),
                warnings: planned.warnings,
                detail: "导入前快照失败，未写入任何内容", embyCredentialsMissing: false
            )
        }

        var journal = BackupJournal()
        var appliedKeys = 0
        var appliedCollections = 0
        var appliedFiles = 0
        var expectedCollectionBytes: [String: Data] = [:]
        var failureReason: String?

        // Defaults first, in sorted order (the plan already
        // sorted them via the data dict's sorted keys).
        for write in planned.defaultWrites {
            if testFailOnKey == write.key {
                failureReason = "写入失败：\(write.key)"
                break
            }
            journal.recordDefault(key: write.key, defaults: defaults)
            defaults.set(write.value, forKey: write.key)
            appliedKeys += 1
        }

        // Collections (including merged prefix files).
        if failureReason == nil {
            for collection in planned.collections.sorted(by: { $0.name < $1.name }) {
                let relativePath = collection.name + ".json"
                if testFailOnFile == relativePath {
                    failureReason = "写入失败：\(relativePath)"
                    break
                }
                let url = documentsURL.appendingPathComponent(relativePath)
                do {
                    try collection.bytes.write(to: url, options: [.atomic])
                } catch {
                    failureReason = "写入失败：\(relativePath)"
                    break
                }
                expectedCollectionBytes[relativePath] = collection.bytes
                appliedCollections += 1
            }
        }
        if failureReason == nil {
            for name in planned.mergedFiles.keys.sorted() {
                guard let bytes = planned.mergedFiles[name] else { continue }
                let relativePath = name + ".json"
                if testFailOnFile == relativePath {
                    failureReason = "写入失败：\(relativePath)"
                    break
                }
                let url = documentsURL.appendingPathComponent(relativePath)
                do {
                    try bytes.write(to: url, options: [.atomic])
                } catch {
                    failureReason = "写入失败：\(relativePath)"
                    break
                }
                expectedCollectionBytes[relativePath] = bytes
                appliedCollections += 1
            }
        }

        // Unknown keys: isolated into their own file, merged
        // with whatever a previous import isolated. Never
        // applied to settings.
        if failureReason == nil, !planned.unknown.isEmpty {
            let relativePath = unknownKeysFileName + ".json"
            var existing = MigrationStore.readJSONDictionary(name: unknownKeysFileName, documentsURL: documentsURL)
            for entry in planned.unknown {
                existing[entry.key] = entry.value
            }
            if let bytes = try? JSONSerialization.data(withJSONObject: existing, options: [.sortedKeys]) {
                let url = documentsURL.appendingPathComponent(relativePath)
                do {
                    try bytes.write(to: url, options: [.atomic])
                    expectedCollectionBytes[relativePath] = bytes
                    appliedCollections += 1
                } catch {
                    failureReason = "写入失败：\(relativePath)"
                }
            } else {
                failureReason = "写入失败：\(relativePath)"
            }
        }

        // Payload files, streamed out of the zip one by one.
        if failureReason == nil {
            for file in planned.payloadFiles {
                if testFailOnFile == file.relativePath {
                    failureReason = "写入失败：\(file.relativePath)"
                    break
                }
                let destination = documentsURL.appendingPathComponent(file.relativePath)
                let parent = destination.deletingLastPathComponent()
                do {
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                } catch {
                    failureReason = "写入失败：\(file.relativePath)"
                    break
                }
                if !ZipArchive.extract(file.entry, from: zipURL, to: destination) {
                    failureReason = "写入失败：\(file.relativePath)"
                    break
                }
                appliedFiles += 1
            }
        }

        // Verify everything that was written, then either commit
        // (notify) or roll back. Verification failure is treated
        // exactly like a write failure.
        if failureReason == nil {
            for write in planned.defaultWrites {
                if !MigrationStore.verifyDefault(key: write.key, kind: write.kind, defaults: defaults) {
                    failureReason = "校验失败：\(write.key)"
                    break
                }
            }
        }
        if failureReason == nil {
            for entry in expectedCollectionBytes {
                guard let actual = try? Data(contentsOf: documentsURL.appendingPathComponent(entry.key)),
                      actual == entry.value
                else {
                    failureReason = "校验失败：\(entry.key)"
                    break
                }
            }
        }
        if failureReason == nil {
            for file in planned.payloadFiles {
                let url = documentsURL.appendingPathComponent(file.relativePath)
                guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
                      size == Int(file.entry.uncompressedSize)
                else {
                    failureReason = "校验失败：\(file.relativePath)"
                    break
                }
            }
        }

        if let reason = failureReason {
            rollback(
                journal: journal, snapshotDir: snapshotDir,
                documentsURL: documentsURL, defaults: defaults
            )
            return BackupImportDetail(
                outcome: .failed, appliedKeys: 0, appliedCollections: 0,
                appliedFiles: 0, skippedKeyNames: planned.skipped.sorted(),
                unknownKeyNames: Array(planned.unknown.keys).sorted(),
                warnings: planned.warnings,
                detail: reason + "，已全量回滚", embyCredentialsMissing: false
            )
        }

        // Commit: tell the app layer to re-read everything.
        // The snapshot folder is kept (same rule as S1's
        // migration_backup): the pre-import state stays on disk
        // until the user clears it.
        var warnings = planned.warnings
        if planned.hasEmbyConfig, !embyCredentialPresent() {
            warnings.append(embyCredentialWarning)
        }
        NotificationCenter.default.post(name: .haoBackupImported, object: nil)
        let detail = "已恢复 \(appliedKeys) 个设置、\(appliedCollections) 个集合、\(appliedFiles) 个文件"
            + (planned.skipped.isEmpty ? "" : "，跳过 \(planned.skipped.count) 个坏键")
            + (planned.unknown.isEmpty ? "" : "，隔离 \(planned.unknown.count) 个未知键")
        return BackupImportDetail(
            outcome: .imported, appliedKeys: appliedKeys,
            appliedCollections: appliedCollections, appliedFiles: appliedFiles,
            skippedKeyNames: planned.skipped.sorted(),
            unknownKeyNames: Array(planned.unknown.keys).sorted(),
            warnings: warnings, detail: detail,
            embyCredentialsMissing: planned.hasEmbyConfig && !embyCredentialPresent()
        )
    }

    // MARK: - Snapshot

    /// Copies every value about to change into a timestamped
    /// folder under `Documents/backup_snapshots/`: prior defaults
    /// values (as JSON) plus prior file bytes. Returns the
    /// snapshot directory, or nil when it cannot be created —
    /// in which case the caller must not write anything.
    private static func createSnapshot(
        defaultKeys: [String],
        filePaths: [String],
        documentsURL: URL,
        defaults: UserDefaults
    ) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date()) + "-" + String(UUID().uuidString.prefix(8))
        let dir = documentsURL
            .appendingPathComponent(snapshotDirectoryName)
            .appendingPathComponent(stamp)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var presentDefaults: [String: Any] = [:]
            var absentDefaults: [String] = []
            for key in defaultKeys {
                if let value = defaults.object(forKey: key) {
                    presentDefaults[key] = value
                } else {
                    absentDefaults.append(key)
                }
            }
            var filesPresent: [String] = []
            var filesAbsent: [String] = []
            for relativePath in filePaths {
                let source = documentsURL.appendingPathComponent(relativePath)
                if FileManager.default.fileExists(atPath: source.path) {
                    let target = dir.appendingPathComponent(relativePath)
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(at: source, to: target)
                    filesPresent.append(relativePath)
                } else {
                    filesAbsent.append(relativePath)
                }
            }
            let manifest: [String: Any] = [
                "defaultsPresent": presentDefaults,
                "defaultsAbsent": absentDefaults,
                "filesPresent": filesPresent,
                "filesAbsent": filesAbsent,
            ]
            guard JSONSerialization.isValidJSONObject(manifest),
                  let manifestData = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            else { return nil }
            try manifestData.write(
                to: dir.appendingPathComponent("snapshot-manifest.json"),
                options: [.atomic]
            )
            return dir
        } catch {
            return nil
        }
    }

    /// Puts every touched value back the way the snapshot found
    /// it: defaults from the in-memory journal, files from the
    /// snapshot folder (restored, or removed when they did not
    /// exist before). The snapshot folder itself is kept.
    private static func rollback(
        journal: BackupJournal,
        snapshotDir: URL,
        documentsURL: URL,
        defaults: UserDefaults
    ) {
        journal.restore(defaults: defaults)
        guard let manifestData = try? Data(contentsOf: snapshotDir.appendingPathComponent("snapshot-manifest.json")),
              let parsed = try? JSONSerialization.jsonObject(with: manifestData, options: []),
              let manifest = parsed as? [String: Any]
        else { return }
        for relativePath in (manifest["filesPresent"] as? [String] ?? []) {
            let source = snapshotDir.appendingPathComponent(relativePath)
            let target = documentsURL.appendingPathComponent(relativePath)
            do {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: source, to: target)
            } catch {
                continue
            }
        }
        for relativePath in (manifest["filesAbsent"] as? [String] ?? []) {
            let target = documentsURL.appendingPathComponent(relativePath)
            try? FileManager.default.removeItem(at: target)
        }
    }
}

/// The prior value of every defaults key one import attempt
/// changed, so a failure can put each key back (including keys
/// that did not exist before the attempt). File priors live in
/// the durable snapshot folder; only defaults need the journal.
private struct BackupJournal {
    var priorDefaults: [(key: String, value: Any?)] = []

    mutating func recordDefault(key: String, defaults: UserDefaults) {
        if priorDefaults.contains(where: { $0.key == key }) { return }
        priorDefaults.append((key: key, value: defaults.object(forKey: key)))
    }

    func restore(defaults: UserDefaults) {
        for prior in priorDefaults {
            if let value = prior.value {
                defaults.set(value, forKey: prior.key)
            } else {
                defaults.removeObject(forKey: prior.key)
            }
        }
    }
}

extension BackupEngineCore {
    // MARK: - Export warnings (for the UI footnote)

    /// The envelope warnings of an already-exported zip (the
    /// Emby credential warning above all), or nil when the file
    /// is not a readable backup. The settings UI calls this
    /// after a successful export to show the footnote: the
    /// export completion itself only carries the file URL (B's
    /// protocol shape), so the warnings travel in the envelope.
    static func warningsInBackup(at zipURL: URL) -> [String]? {
        guard let entries = ZipArchive.listEntries(at: zipURL),
              let envelopeEntry = entries.first(where: { $0.name == envelopeFileName }),
              let envelopeData = ZipArchive.readEntryData(envelopeEntry, from: zipURL),
              let parsed = try? JSONSerialization.jsonObject(with: envelopeData, options: []),
              let root = parsed as? [String: Any],
              let envelope = BackupEnvelope(dictionary: root)
        else { return nil }
        return envelope.warnings
    }
}

/// Errors the completion-handler seam reports. A refused file
/// (not a backup, wrong schema, newer version) arrives as
/// `.failure` with one of these; a write that failed midway
/// arrives as a successful `BackupImportReport` with
/// `rolledBack == true` instead, because B's result alert
/// already has the rollback wording for that case.
enum BackupError: Error {
    case invalidBackup(String)
    case exportFailed(String)
}

extension BackupError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidBackup(let message):
            return message
        case .exportFailed(let message):
            return message
        }
    }
}

/// The concrete backup engine: B's `BackupEngine` protocol
/// (declared in BackupUpdateLogic.swift) implemented on top of
/// `BackupEngineCore`.
///
/// - Export writes to a fresh file in the temp directory (the
///   settings UI shares or saves it from there) and completes
///   with its URL.
/// - Import reads the zip at the given URL and completes with
///   B's `BackupImportReport`: a refused file is a `.failure`,
///   a rolled-back import is a success with `rolledBack == true`,
///   a clean import is a success with the imported item count.
///   `skippedKeys` merges the bad-typed keys and the isolated
///   unknown keys: both are keys the import did not apply.
/// - Both completions arrive on the main thread. The work runs
///   on a background queue, and a dispatch group gates the
///   completion: the group leaves only after the synchronous
///   core body — every write, plus any rollback — has returned,
///   so success is never reported before the last write lands.
/// - Test seams: `documentsURL` / `defaults` / `bundle` /
///   `currentVersion`. Production uses the real container
///   (nil documentsURL, standard defaults, main bundle).
final class FileBackupEngine: BackupEngine {
    private let workQueue = DispatchQueue(label: "com.haostudio.backup.work", qos: .utility)
    private let documentsURL: URL?
    private let defaults: UserDefaults
    private let bundle: Bundle
    private let currentVersion: BackupVersion?

    init(
        documentsURL: URL? = nil,
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main,
        currentVersion: BackupVersion? = nil
    ) {
        self.documentsURL = documentsURL
        self.defaults = defaults
        self.bundle = bundle
        self.currentVersion = currentVersion
    }

    func exportBackup(completion: @escaping (Result<URL, Error>) -> Void) {
        let group = DispatchGroup()
        group.enter()
        var result: Result<URL, Error> = .failure(BackupError.exportFailed("备份导出失败"))
        workQueue.async {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(BackupEngineCore.backupFileName())
            if let exported = BackupEngineCore.exportBackup(
                to: destination, documentsURL: self.documentsURL,
                defaults: self.defaults,
                currentVersion: self.currentVersion, bundle: self.bundle
            ) {
                result = .success(exported.zipURL)
            } else {
                result = .failure(BackupError.exportFailed("备份文件写入失败"))
            }
            group.leave()
        }
        group.notify(queue: .main) {
            completion(result)
        }
    }

    func importBackup(from url: URL, completion: @escaping (Result<BackupImportReport, Error>) -> Void) {
        let group = DispatchGroup()
        group.enter()
        var result: Result<BackupImportReport, Error> = .failure(BackupError.invalidBackup("备份导入失败"))
        workQueue.async {
            let detail = BackupEngineCore.importBackup(
                from: url, documentsURL: self.documentsURL,
                defaults: self.defaults,
                currentVersion: self.currentVersion, bundle: self.bundle
            )
            switch detail.outcome {
            case .rejected:
                result = .failure(BackupError.invalidBackup(detail.detail))
            case .failed:
                result = .success(BackupImportReport(
                    importedCount: 0,
                    skippedKeys: (detail.skippedKeyNames + detail.unknownKeyNames).sorted(),
                    rolledBack: true,
                    embyCredentialsMissing: false,
                    warnings: detail.warnings
                ))
            case .imported:
                result = .success(BackupImportReport(
                    importedCount: detail.appliedKeys + detail.appliedCollections + detail.appliedFiles,
                    skippedKeys: (detail.skippedKeyNames + detail.unknownKeyNames).sorted(),
                    rolledBack: false,
                    embyCredentialsMissing: detail.embyCredentialsMissing,
                    warnings: detail.warnings
                ))
            }
            group.leave()
        }
        group.notify(queue: .main) {
            completion(result)
        }
    }
}

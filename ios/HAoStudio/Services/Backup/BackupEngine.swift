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
// - S1's 117 keys + 4 key families (via MigrationStore.mappings,
//   prefix rules, and the ignored play-URL-cache prefix) — 75
//   UserDefaults keys + 42 non-UserDefaults rows (41 collection
//   files + 1 Emby config) after b49fix19 P2-1 added 5 rows.
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
    /// b49fix4 P2-36: a failed import used to report "已全量回滚"
    /// on every path, including paths where the rollback itself
    /// could not put a file back (copy failure, removal failure,
    /// or an unreadable snapshot manifest). The engine now
    /// collects the relative paths it could not restore, so the
    /// UI can say "回滚未完成，请检查 X" instead of lying.
    let rollbackFailures: [String]
    /// True when nothing was ever written — the plan was
    /// rejected before any write, or the pre-import snapshot
    /// failed. There was nothing to roll back, so the UI must
    /// not say "已全部回滚" (it must say nothing was touched).
    let nothingWritten: Bool

    init(
        outcome: BackupImportOutcome,
        appliedKeys: Int,
        appliedCollections: Int,
        appliedFiles: Int,
        skippedKeyNames: [String],
        unknownKeyNames: [String],
        warnings: [String],
        detail: String,
        embyCredentialsMissing: Bool,
        rollbackFailures: [String] = [],
        nothingWritten: Bool = false
    ) {
        self.outcome = outcome
        self.appliedKeys = appliedKeys
        self.appliedCollections = appliedCollections
        self.appliedFiles = appliedFiles
        self.skippedKeyNames = skippedKeyNames
        self.unknownKeyNames = unknownKeyNames
        self.warnings = warnings
        self.detail = detail
        self.embyCredentialsMissing = embyCredentialsMissing
        self.rollbackFailures = rollbackFailures
        self.nothingWritten = nothingWritten
    }
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
        // b49fix2 P2-10: the playlist snapshots subdir
        // (PlaylistSnapshotStore.subdir) was in neither export
        // list, so a restore lost every play context's snapshot.
        "hao_playlist_snapshots",
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
        // b49fix2 P1-4: the catalogue was frozen at S1+S5 and
        // dropped every 2.0-native UserDefaults key the app
        // actually writes. Enumerated from the stores (see the
        // census in the fix report): audio-cache switch + cap,
        // disclaimer version, last update-check date, live
        // preferred-quality map, video-home cache stamp, VOD
        // per-playback settings, the persisted play context
        // (Data — base64 through the envelope, see
        // MigrationKeyKind.data), and the lyrics-cache order +
        // version. Deliberately NOT here: MPV option names, the
        // Emby apiKey, hao_migration_* state keys,
        // hao_profile_nickname (deleted feature), hao_song_cache_*
        // (legacy, migrated away), hao_vod_danmaku_api_token
        // (credential), hao_resolver_speed (a collection file,
        // exported as one already).
        out["hao_audio_cache_enabled"] = .bool
        out["hao_audio_cache_limit_mb"] = .int
        out["hao_disclaimer_accepted_version"] = .int
        out["hao_last_update_check_date"] = .double
        out["hao_live_preferred_quality"] = .json
        out["hao_video_home_saved_at"] = .double
        out["hao_vod_audio_track"] = .int
        out["hao_vod_danmaku"] = .bool
        out["hao_vod_danmaku_opacity"] = .double
        out["hao_vod_speed"] = .double
        out["hao_vod_subtitle_track"] = .int
        out["hao.currentPlayContext"] = .data
        out["hao.lyricsCacheOrder"] = .json
        out["hao.lyricsCacheVersion"] = .int
        // b49fix4 P2-39: five keys the app writes but the export
        // never collected — a restore silently dropped them
        // (welcome card re-appeared, backup nudge re-appeared,
        // last manifest / confirmed quality forgotten). One
        // catalogue feeds both export and import, so adding
        // them here makes them round-trip. Deliberately NOT
        // here: hao_store_quarantine.json — that is a Documents
        // file, and collectCollectionFiles already exports every
        // Documents/*.json except migration_snapshot, so it was
        // never missing (the sweep's sub-claim was wrong).
        out["hao_home_welcome_dismissed"] = .bool
        out["hao_backup_nudge_shown"] = .bool
        out["hao_backup_exported_once"] = .bool
        out["hao_last_primary_manifest"] = .string
        out["hao_last_confirmed_quality"] = .json
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
        let validation = BackupEnvelope.validate(dictionary: root, currentVersion: current)
        guard case .valid(let envelope) = validation else {
            return validation
        }
        // The manifest is the import's verification source: every
        // entry it promises must be present in the zip at the
        // promised size. A zip that lost an entry (truncated or
        // hand-built) used to import "successfully" with the data
        // silently missing; refuse it before anything is written.
        // The envelope row itself is excluded: backup.json is
        // re-encoded whenever it is rewritten, so its own row
        // legitimately disagrees after a rewrite.
        guard manifestMatchesContents(envelope: envelope, entries: entries) else {
            return .rejected("备份内容不完整，缺少部分数据")
        }
        return .valid(envelope)
    }

    /// True when every manifest entry the envelope promises
    /// (except the envelope itself, see above) exists in the zip
    /// at exactly the promised byte count.
    static func manifestMatchesContents(envelope: BackupEnvelope, entries: [ZipEntryInfo]) -> Bool {
        for content in envelope.contents {
            guard content.path != envelopeFileName else { continue }
            guard content.bytes >= 0,
                  let entry = entries.first(where: { $0.name == content.path }),
                  entry.uncompressedSize == UInt32(content.bytes)
            else { return false }
        }
        return true
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
        let plan = planImport(data: data, entries: entries, zipURL: zipURL)
        switch plan {
        case .failure(let reason):
            // b49fix4 P2-36: the plan runs before any write, so
            // a plan failure wrote nothing — there was nothing
            // to roll back, and the UI must not claim a rollback.
            return BackupImportDetail(
                outcome: .failed, appliedKeys: 0, appliedCollections: 0,
                appliedFiles: 0, skippedKeyNames: [], unknownKeyNames: [],
                warnings: [], detail: reason, embyCredentialsMissing: false,
                nothingWritten: true
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
        /// Merge INPUTS accumulated at plan time (b49fix15 P2-1):
        /// the incoming values per merged file — listen entries
        /// for hao_listen, key→value pairs for dict files
        /// (hao_daily, haoVodProg). The plan only classifies; it
        /// must NOT read the disk file. The old shape stored the
        /// fully merged bytes here, computed from the plan-time
        /// file — apply then wrote those bytes back whole, so a
        /// listen event recorded between plan and apply (the
        /// window spans the whole import: plan + snapshot +
        /// apply) was overwritten and lost. The merge itself now
        /// happens in applyPlannedImport, re-reading the live
        /// file first, so an event recorded mid-import is in the
        /// file the merge reads.
        var mergedListInputs: [String: [[String: Any]]] = [:]
        var mergedDictInputs: [String: [String: Any]] = [:]
        /// Names of the files the merge will touch (derived from
        /// the inputs above); used for the pre-import snapshot.
        var mergedFileNames: Set<String> {
            Set(mergedListInputs.keys).union(mergedDictInputs.keys)
        }
        var payloadFiles: [PlannedFile] = []
        var unknown: [String: Any] = [:]
        var skipped: [String] = []
        var warnings: [String] = []
        var hasEmbyConfig = false
        /// True when the backup restores non-empty custom LX
        /// scripts (b49fix2 P2-13): their keys live in the
        /// Keychain and are never in a backup, so the import
        /// must warn that the keys need re-entering — the export
        /// side already warns, the import side never did.
        var hasCustomLXScripts = false
    }

    private enum ImportPlan {
        case planned(PlannedImport)
        case failure(String)
    }

    private static func planImport(
        data: [String: Any],
        entries: [ZipEntryInfo],
        zipURL: URL
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
                        planned: &planned
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
                    // b49fix17 P1-1 / b49fix18 D-8: shape-check
                    // every collection with a known expected
                    // shape (see
                    // MigrationStore.expectedCollectionShape),
                    // not just the three merge files — a
                    // whole-file file whose backup bytes parse
                    // but have the wrong shape (a dict where a
                    // list belongs) used to be installed
                    // straight through, and the next live write
                    // then rewrote it from an empty table.
                    // Damaged entries go to skipped with a
                    // warning; the apply-time guard in
                    // writeWholeCollectionBytes stays as the
                    // second line of defence. Files with no
                    // known shape (nil) are not checked here.
                    if let shape = MigrationStore.expectedCollectionShape(for: base) {
                        guard shape.matches(bytes: bytes) else {
                            planned.warnings.append("备份条目损坏，已跳过：\(entry.name)")
                            planned.skipped.append(base)
                            continue
                        }
                    }
                    // b49fix19 P1-1: history entries are
                    // normalised at PLAN time — ISO/ms dates to
                    // seconds, missing required fields filled,
                    // unusable entries dropped with a warning.
                    // A raw entry straight into the merge would
                    // fail the live typed reader for the WHOLE
                    // file (loadCollection quarantines it) and
                    // the next live write would overwrite the
                    // imported history.
                    var installBytes = bytes
                    if base == "hao_video_hist" || base == "hao_live_hist",
                       let parsed = try? JSONSerialization.jsonObject(with: bytes, options: []),
                       let list = parsed as? [[String: Any]] {
                        let normalized = MigrationStore.normalizedHistoryEntries(list, file: base)
                        if normalized.dropped > 0 {
                            planned.warnings.append("\(base == "hao_video_hist" ? "影视" : "直播")历史有 \(normalized.dropped) 条记录格式不符，已跳过")
                        }
                        if let data = try? JSONSerialization.data(withJSONObject: normalized.kept, options: []) {
                            installBytes = data
                        }
                    }
                    planned.collections.append(PlannedCollection(name: base, bytes: installBytes))
                    // b49fix2 P2-13: a backup that restores custom
                    // LX scripts restores the scripts but never
                    // their Keychain keys — flag it so the commit
                    // warns the user to re-enter them.
                    if base == "hao_lx_custom",
                       let parsed = try? JSONSerialization.jsonObject(with: bytes, options: []),
                       ((parsed as? [Any])?.isEmpty == false || (parsed as? [String: Any])?.isEmpty == false) {
                        planned.hasCustomLXScripts = true
                    }
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

    /// Accumulates one key-family member (resume position, daily
    /// pick, listen shard) into the plan's merge inputs,
    /// mirroring MigrationStore: resume positions cap at 200 entries,
    /// listen shards append and cap at 3000. Plan-time only: this
    /// records the INCOMING values and reads nothing from disk
    /// (b49fix15 P2-1) — the merge against the live file happens
    /// in applyPlannedImport.
    private static func mergePrefixValue(
        key: String,
        value: Any,
        rule: MigrationPrefixRule,
        planned: inout PlannedImport
    ) {
        if rule.fileName == "hao_listen" {
            if let list = value as? [[String: Any]] {
                planned.mergedListInputs["hao_listen", default: []].append(contentsOf: list)
            } else if let single = value as? [String: Any] {
                planned.mergedListInputs["hao_listen", default: []].append(single)
            } else {
                planned.skipped.append(key)
            }
            return
        }
        planned.mergedDictInputs[rule.fileName, default: [:]][key] = value
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

    // MARK: - Collection writes (b49fix16 P1-1/P1-2/P2-5/P2-6)

    /// Outcome of one collection write, distinguishing the two
    /// failure kinds (b49fix16 P2-5): a serialisation failure
    /// is NOT a write failure — reporting it as one sends the
    /// diagnosis to the disk when the bytes were never formable.
    /// `.skipped` (b49fix17 P1-1/P1-3) is neither: the file was
    /// deliberately not written — the live file is healthy and
    /// the backup's bytes are corrupt, or the live queue wins
    /// over the backup queue — and the import records it as
    /// skipped, not as applied and not as failed.
    private enum CollectionWriteOutcome {
        case written(Data)
        case skipped
        case serializationFailed
        case writeFailed
        /// The write landed but the immediate re-read inside
        /// the write's critical section did not match it
        /// (b49fix19 P1-4, b49fix20 D22-1): a live writer
        /// replaced the file between the write and its verify.
        /// The caller fails the import with a verification
        /// failure, not a write failure — the write itself
        /// succeeded. Carries the written bytes so the caller
        /// can record them in expectedCollectionBytes before
        /// failing: the rollback must treat this file as
        /// written, or it would skip it and leave suspect
        /// content in place.
        case verifyFailed(Data)
    }

    /// Collections a concurrent writer can change while an
    /// import runs (b49fix16 P1-2, b49fix17 P1-2/P1-3/P2-6): a
    /// resume checkpoint (musicResume, at most once per 10 s
    /// of playback), a song switch (hao_recent, musicQueue),
    /// a pool pin (hao_daily_pool), a listen completion
    /// (hao_listen), a daily replace (hao_daily), a favourite
    /// toggle, a playlist edit, a cover/lyrics fetch, a
    /// download. Byte-equality verify would fail the whole
    /// import whenever one of them lands between the write and
    /// the verify — an import over 10 s while music plays would
    /// almost certainly fail — so these verify by subset
    /// instead: every imported entry must still be present, but
    /// a concurrent writer's later additions do not fail the
    /// import. haoVodProg has no live writer in 2.0; it is
    /// listed because it merges like the others and subset is
    /// equivalent to byte equality when nothing else writes it.
    /// musicQueue is NOT in this set: it is replaced wholesale
    /// on every switch, so no subset of it is meaningful — it
    /// verifies by shape only (see collectionVerifies).
    ///
    /// Per-file dispositions (b49fix17 P2-6 — the fix16
    /// comment that called this set "complete" was wrong; the
    /// table below is the honest record, one line per
    /// collection the app writes):
    ///
    /// MERGE + SUBSET VERIFY, live writer on the same queue:
    /// - hao_listen — recordListenEvent, every completion —
    ///   merge under listenLogWriteQueue (fix15/16).
    /// - hao_daily — saveDailyTracks / CAS, daily replace —
    ///   merge under dailyWriteQueue + 7-day prune (fix17 P2-4).
    /// - haoVodProg — no live writer in 2.0 — merge under
    ///   dailyWriteQueue; cap keeps incoming keys (fix17 P2-1).
    /// - hao_daily_pool — saveDailyPool, pool pin — merge under
    ///   dailyWriteQueue (fix17: the pool writer moved off its
    ///   own dailyPoolQueue onto dailyWriteQueue, so the merge
    ///   and the save finally share one queue).
    /// - hao_recent — writeRecent, every song switch — merge
    ///   under recentWriteQueue + tolerant verify (fix17 P1-2).
    /// - musicResume — saveResume (10 s checkpoint) /
    ///   clearResume (natural completion) — merge under
    ///   resumeWriteQueue + deletion tolerance (fix17 P1-4/P2-2).
    /// - hao_fav — toggleFav, user tap — merge under
    ///   collectionWriteQueue, dedupe by key.
    /// - hao_lists — saveLists + playlist edits, user action —
    ///   merge under collectionWriteQueue, dedupe by id; the
    ///   view-model edits are atomic store methods now.
    /// - hao_music_search_hist — saveSearchQuery, user search —
    ///   string-list merge under collectionWriteQueue, cap 20.
    /// - hao_cover_cache — saveCover, cover resolve (often per
    ///   switch) — dict overlay under collectionWriteQueue.
    /// - hao_lyrics — putLyrics / read-path cleanup, per song
    ///   first play — dict overlay under collectionWriteQueue.
    /// - musicDownloads — saveDownloads / removeDownload, user
    ///   action — merge under collectionWriteQueue, dedupe by
    ///   the nested song's identityKey.
    /// - hao_music_loudness_cache — NO 2.0 writer found — dict
    ///   overlay under collectionWriteQueue (belt-and-braces).
    /// - hao_fav_playlists — toggleFavPlaylist, user tap —
    ///   string-list merge under collectionWriteQueue.
    /// - hao_fav_albums / hao_fav_artists — toggleFavAlbum /
    ///   toggleFavArtist, user tap — merge under
    ///   collectionWriteQueue, dedupe by id+name.
    /// - fmDislikedIds — addFMDisliked, FM dislike tap —
    ///   string-list merge under collectionWriteQueue.
    /// - hao_video_hist — VideoLibraryStore.saveHistory, every
    ///   VOD play — merge under collectionWriteQueue, dedupe
    ///   title+year, cap 20 (b49fix18 D-7: the writer takes
    ///   the queue now).
    /// - hao_live_hist — LiveLibraryStore.saveHistory, every
    ///   room open — merge under collectionWriteQueue, dedupe
    ///   platform|roomId, cap 50 (b49fix18 D-7: the writer
    ///   takes the queue now).
    ///
    /// Route B (MigrationStore.importData) shares these
    /// dispositions — see MigrationStore.applyRouteBFileWrite
    /// for the 33-file table (the merge files above plus the
    /// whole-file files below, same rules).
    ///
    /// MERGE ON THE IMPORT SIDE ONLY, live-wins rule:
    /// - musicQueue — saveQueueAsync, every switch + queue edit
    ///   — live queue wins when non-empty (importing a backup
    ///   never replaces the queue being listened to); the
    ///   backup queue lands only when live is empty. Shape-only
    ///   verify (fix17 P1-3).
    ///
    /// WHOLE-FILE + BYTE VERIFY, no 2.0 concurrent writer (no
    /// window in 2.0; a user action landing mid-import is the
    /// only way in, and it fails loud with a rollback):
    /// - hao_local_music — pruneLocalSongs / rescan, explicit
    ///   user action only.
    /// - hao_music_bookmarks, hao_music_queue_memory,
    ///   hao_feature_cover_plaza, hao_feature_cover_charts,
    ///   hao_music_sources — no 2.0 writer found.
    /// - hao_video_fav, hao_video_search_hist, hao_video_home,
    ///   hao_video_category_prefs — video settings / caches,
    ///   user action or home load.
    /// - hao_live_follows, hao_live_search_hist,
    ///   hao_live_sources, hao_live_hidden_platforms — live
    ///   settings, user action.
    /// - hao_danmaku_enabled, hao_dm_block — danmaku settings.
    /// - hao_douban_detail, hao_douban_idmap — Douban caches.
    /// - hao_sa_video — CMS sources, settings action.
    /// - hao_emby_home — Emby home cache.
    /// - hao_vod_metadata_overrides,
    ///   hao_vod_skip_intro_durations — VOD prefs.
    /// - hao_lx_custom, hao_lx_disabled,
    ///   hao_lx_explicit_enabled, hao_lx_deleted_bundled,
    ///   hao_lx_order — LX script store, settings action.
    /// - hao_eq_custom_presets — EQ presets, settings action.
    /// - hao_wallpaper_paths — wallpaper, settings action.
    /// - hao_resolver_speed — ResolverPolicy speed persistence,
    ///   per resolve; the writer takes collectionWriteQueue
    ///   (b49fix18 D-7), so the whole-file write serialises
    ///   against it — but the write → verify gap is still
    ///   open, and a speed save landing there fails the
    ///   import loud (byte verify). Millisecond window.
    /// - downloadTasks — DownloadEngine task mirror, every
    ///   download state mutation; the writer takes
    ///   collectionWriteQueue (b49fix18 D-7), same residual
    ///   write → verify gap as hao_resolver_speed
    ///   (downloads.json is the primary index now).
    /// - hao_emby_config — Emby config, settings action.
    /// - migration_unknown_keys — import-only, no live writer.
    /// - Legacy Flutter-only files (downloads.json,
    ///   favourites.json, fonts.json, local_music.json,
    ///   playback_resume.json, wallpapers.json) — no 2.0
    ///   writer; a backup may still carry them.
    private static let concurrentlyWrittenCollections: Set<String> = [
        "hao_listen", "hao_daily", "haoVodProg",
        "musicResume", "hao_recent", "hao_daily_pool",
        "hao_fav", "hao_lists", "hao_music_search_hist",
        "hao_cover_cache", "hao_lyrics", "musicDownloads",
        "hao_music_loudness_cache", "hao_fav_playlists",
        "hao_fav_albums", "hao_fav_artists", "fmDislikedIds",
        "hao_video_hist", "hao_live_hist",
    ]

    /// Writes one planned collection (b49fix16 P1-1, b49fix17
    /// P1-1/P1-2/P1-3/P1-4/P2-6): every collection with a live
    /// writer merges at apply time instead of taking the
    /// whole-file overwrite — a listen completion / daily
    /// replace / song switch / checkpoint landing before this
    /// write is merged in, not overwritten by the backup's
    /// bytes. The merge rule per file is in the
    /// concurrentlyWrittenCollections table above. An
    /// unparseable backup file cannot merge; it falls back to
    /// fallbackForUnparseable (b49fix17 P1-1), which checks the
    /// live file first — the old behaviour (whole-file write,
    /// "the on-disk file was already unreadable") was never
    /// verified, and it destroyed healthy live files.
    private static func writeCollection(
        _ collection: PlannedCollection,
        documentsURL: URL,
        defaults: UserDefaults,
        liveHistLimit: Int? = 50
    ) -> CollectionWriteOutcome {
        switch collection.name {
        case "hao_listen":
            guard let parsed = try? JSONSerialization.jsonObject(with: collection.bytes, options: []),
                  let list = parsed as? [[String: Any]]
            else { return fallbackForUnparseable(collection, documentsURL: documentsURL, queue: MigrationStore.listenLogWriteQueue) }
            return mergeListenEntries(list, documentsURL: documentsURL)
        case "hao_daily", "haoVodProg", "hao_daily_pool":
            guard let parsed = try? JSONSerialization.jsonObject(with: collection.bytes, options: []),
                  let dict = parsed as? [String: Any]
            else { return fallbackForUnparseable(collection, documentsURL: documentsURL, queue: MigrationStore.dailyWriteQueue) }
            return mergeDictEntries(dict, into: collection.name, documentsURL: documentsURL, queue: MigrationStore.dailyWriteQueue, defaults: defaults)
        case "hao_recent":
            guard let parsed = try? JSONSerialization.jsonObject(with: collection.bytes, options: []),
                  let list = parsed as? [[String: Any]]
            else { return fallbackForUnparseable(collection, documentsURL: documentsURL, queue: MigrationStore.recentWriteQueue) }
            return mergeRecentEntries(list, documentsURL: documentsURL)
        case "musicResume":
            guard let parsed = try? JSONSerialization.jsonObject(with: collection.bytes, options: []),
                  let dict = parsed as? [String: Any]
            else { return fallbackForUnparseable(collection, documentsURL: documentsURL, queue: MigrationStore.resumeWriteQueue) }
            return mergeResumeEntries(dict, documentsURL: documentsURL)
        case "musicQueue":
            guard let parsed = try? JSONSerialization.jsonObject(with: collection.bytes, options: []),
                  let dict = parsed as? [String: Any]
            else { return fallbackForUnparseable(collection, documentsURL: documentsURL, queue: MigrationStore.musicQueueWriteQueue) }
            return mergeMusicQueue(dict, documentsURL: documentsURL)
        case "hao_fav":
            guard let parsed = try? JSONSerialization.jsonObject(with: collection.bytes, options: []),
                  let list = parsed as? [[String: Any]]
            else { return fallbackForUnparseable(collection, documentsURL: documentsURL, queue: MigrationStore.collectionWriteQueue) }
            // b49fix19 P1-3: dedupe by the normalised fav key
            // (not the raw stored "key") and rewrite each stored
            // key to it — an lx favourite and a wy favourite are
            // otherwise duplicate rows, and the lx row can never
            // be unfavourited. b49fix19 P2-6: the secondary
            // title+artist key dedupes a key-only legacy entry
            // against the same song that later gained a songId.
            return mergeListEntries(list, into: collection.name, documentsURL: documentsURL, keyFor: { MigrationStore.favMergeKey(for: $0) }, cap: nil, secondaryKeyFor: { guard let song = $0["song"] as? [String: Any] else { return "" }; return MigrationStore.songTitleArtistKey(for: song) }, mapEntry: { var entry = $0; let key = MigrationStore.favMergeKey(for: entry); if !key.isEmpty { entry["key"] = key }; return entry })
        case "hao_lists":
            guard let parsed = try? JSONSerialization.jsonObject(with: collection.bytes, options: []),
                  let list = parsed as? [[String: Any]]
            else { return fallbackForUnparseable(collection, documentsURL: documentsURL, queue: MigrationStore.collectionWriteQueue) }
            return mergeListEntries(list, into: collection.name, documentsURL: documentsURL, keyFor: { ($0["id"] as? String) ?? "" }, cap: nil)
        case "hao_fav_albums", "hao_fav_artists":
            guard let parsed = try? JSONSerialization.jsonObject(with: collection.bytes, options: []),
                  let list = parsed as? [[String: Any]]
            else { return fallbackForUnparseable(collection, documentsURL: documentsURL, queue: MigrationStore.collectionWriteQueue) }
            return mergeListEntries(list, into: collection.name, documentsURL: documentsURL, keyFor: { (($0["id"] as? String) ?? "") + "|" + (($0["name"] as? String) ?? "") }, cap: nil)
        case "musicDownloads":
            guard let parsed = try? JSONSerialization.jsonObject(with: collection.bytes, options: []),
                  let list = parsed as? [[String: Any]]
            else { return fallbackForUnparseable(collection, documentsURL: documentsURL, queue: MigrationStore.collectionWriteQueue) }
            return mergeListEntries(list, into: collection.name, documentsURL: documentsURL, keyFor: { guard let song = $0["song"] as? [String: Any] else { return "" }; return MigrationStore.songIdentityKey(for: song) }, cap: nil, secondaryKeyFor: { guard let song = $0["song"] as? [String: Any] else { return "" }; return MigrationStore.songTitleArtistKey(for: song) })
        case "hao_video_hist":
            guard let parsed = try? JSONSerialization.jsonObject(with: collection.bytes, options: []),
                  let list = parsed as? [[String: Any]]
            else { return fallbackForUnparseable(collection, documentsURL: documentsURL, queue: MigrationStore.collectionWriteQueue) }
            return mergeListEntries(list, into: collection.name, documentsURL: documentsURL, keyFor: { MigrationStore.videoHistoryDedupeKey(for: $0) }, cap: 20)
        case "hao_live_hist":
            guard let parsed = try? JSONSerialization.jsonObject(with: collection.bytes, options: []),
                  let list = parsed as? [[String: Any]]
            else { return fallbackForUnparseable(collection, documentsURL: documentsURL, queue: MigrationStore.collectionWriteQueue) }
            // b49fix19 P2-4: the cap comes from the user's
            // setting (nil = unlimited), not a hard-coded 50.
            return mergeListEntries(list, into: collection.name, documentsURL: documentsURL, keyFor: { (($0["platform"] as? String) ?? "") + "|" + (($0["roomId"] as? String) ?? "") }, cap: liveHistLimit)
        case "hao_music_search_hist":
            guard let parsed = try? JSONSerialization.jsonObject(with: collection.bytes, options: []),
                  let list = parsed as? [String]
            else { return fallbackForUnparseable(collection, documentsURL: documentsURL, queue: MigrationStore.collectionWriteQueue) }
            return mergeStringListEntries(list, into: collection.name, documentsURL: documentsURL, cap: 20)
        case "hao_fav_playlists", "fmDislikedIds":
            guard let parsed = try? JSONSerialization.jsonObject(with: collection.bytes, options: []),
                  let list = parsed as? [String]
            else { return fallbackForUnparseable(collection, documentsURL: documentsURL, queue: MigrationStore.collectionWriteQueue) }
            return mergeStringListEntries(list, into: collection.name, documentsURL: documentsURL, cap: nil)
        case "hao_cover_cache", "hao_lyrics", "hao_music_loudness_cache":
            guard let parsed = try? JSONSerialization.jsonObject(with: collection.bytes, options: []),
                  let dict = parsed as? [String: Any]
            else { return fallbackForUnparseable(collection, documentsURL: documentsURL, queue: MigrationStore.collectionWriteQueue) }
            return mergeDictEntries(dict, into: collection.name, documentsURL: documentsURL, queue: MigrationStore.collectionWriteQueue, defaults: defaults)
        default:
            return writeWholeCollection(collection, documentsURL: documentsURL)
        }
    }

    /// Fallback for an unparseable merge-file backup (b49fix17
    /// P1-1): the backup's bytes cannot merge, so the only
    /// question is whether the live file is still good. Asked
    /// INSIDE the file's queue, so the check and the write are
    /// atomic against the live writer: a live file that parses
    /// is healthy — refuse to overwrite it with corrupt bytes
    /// (`.skipped`, recorded in the report, not a failure);
    /// a live file that is missing or unparseable is
    /// quarantined first (so the corrupt bytes survive for
    /// manual recovery, same policy as readJSONDictionary)
    /// and the backup's bytes are installed as the repair.
    /// The plan-time shape check in planImport already skips
    /// corrupt bytes for the three merge files, so this is the
    /// second line of defence — and the only line for the
    /// files planImport does not shape-check.
    private static func fallbackForUnparseable(
        _ collection: PlannedCollection,
        documentsURL: URL,
        queue: DispatchQueue
    ) -> CollectionWriteOutcome {
        queue.sync { () -> CollectionWriteOutcome in
            let url = documentsURL.appendingPathComponent(collection.name + ".json")
            if let liveData = try? Data(contentsOf: url),
               (try? JSONSerialization.jsonObject(with: liveData, options: [])) != nil {
                return .skipped
            }
            if FileManager.default.fileExists(atPath: url.path) {
                LocalStore.quarantineFile(at: url, name: collection.name, reason: "decode failed", documentsURL: documentsURL)
            }
            return writeWholeCollectionBytes(collection, documentsURL: documentsURL)
        }
    }

    /// The pre-fix16 collections write: whole-file, atomic.
    /// Kept for every collection that does not merge. Takes the
    /// file's queue when it has one, so the write serialises
    /// against the live writer's read-modify-write.
    private static func writeWholeCollection(
        _ collection: PlannedCollection,
        documentsURL: URL
    ) -> CollectionWriteOutcome {
        if let queue = MigrationStore.writeQueue(forCollection: collection.name) {
            return queue.sync { writeWholeCollectionBytes(collection, documentsURL: documentsURL) }
        }
        return writeWholeCollectionBytes(collection, documentsURL: documentsURL)
    }

    /// The whole-file write itself, assuming the caller's queue
    /// is held when the file has one (b49fix17 P1-1, b49fix18
    /// D-8): backup bytes that do not parse as JSON at all
    /// never overwrite a healthy live file — the live file is
    /// checked first (parseable → `.skipped`); only a missing
    /// or unparseable live file is replaced, after quarantine
    /// when it exists. b49fix18 D-8: parseable-but-wrong-shape
    /// bytes are corrupt for this file, same as unparseable
    /// bytes — a dict where the reader expects a list would
    /// otherwise be installed straight through, and the next
    /// live write would rewrite the file from an empty table.
    /// Files with no known shape keep the old parse-only
    /// check. The plan-time check in planImport already skips
    /// these, so this is the second line of defence.
    private static func writeWholeCollectionBytes(
        _ collection: PlannedCollection,
        documentsURL: URL
    ) -> CollectionWriteOutcome {
        let url = documentsURL.appendingPathComponent(collection.name + ".json")
        // b49fix18 D-8: expected-shape check (nil shape =
        // unknown file = parse-only, as before).
        let parsesAsExpectedShape: Bool = {
            if let shape = MigrationStore.expectedCollectionShape(for: collection.name) {
                return shape.matches(bytes: collection.bytes)
            }
            return (try? JSONSerialization.jsonObject(with: collection.bytes, options: [])) != nil
        }()
        if !parsesAsExpectedShape {
            if let liveData = try? Data(contentsOf: url),
               (try? JSONSerialization.jsonObject(with: liveData, options: [])) != nil {
                return .skipped
            }
            if FileManager.default.fileExists(atPath: url.path) {
                LocalStore.quarantineFile(at: url, name: collection.name, reason: "decode failed", documentsURL: documentsURL)
            }
        }
        do {
            try collection.bytes.write(to: url, options: [.atomic])
        } catch {
            return .writeFailed
        }
        // b49fix19 P1-4: verify the write immediately, inside
        // the caller's queue when there is one (writeWholeCollection
        // and fallbackForUnparseable both hold it) — a queued
        // writer (ResolverCooldown.save, DownloadEngine
        // .persistLocked) writes from in-memory state without
        // re-reading the file, so it cannot be tolerated by a
        // key-subset verify the way merge files can; the
        // immediate canonical re-read is what makes an
        // interleave fail loud here instead of at a later
        // end-of-apply verify.
        guard let expected = try? JSONSerialization.jsonObject(with: collection.bytes, options: []),
              MigrationStore.fileContentEquals(name: collection.name, expected: expected, documentsURL: documentsURL)
        else { return .verifyFailed(collection.bytes) }
        return .written(collection.bytes)
    }

    /// Merges incoming recent entries into the live hao_recent
    /// file (b49fix17 P1-2): re-read → merge → write, whole
    /// under MigrationStore.recentWriteQueue, the same queue
    /// writeRecent uses — a song switch landing between the
    /// re-read and the write is serialised after it instead of
    /// being overwritten by the backup. Returns the merged
    /// bytes so the caller can verify them (tolerant check,
    /// see collectionVerifies).
    private static func mergeRecentEntries(
        _ incoming: [[String: Any]],
        documentsURL: URL
    ) -> CollectionWriteOutcome {
        MigrationStore.recentWriteQueue.sync { () -> CollectionWriteOutcome in
            let existing = MigrationStore.readJSONList(name: "hao_recent", documentsURL: documentsURL)
            // b49fix21 D23-6: record the live value at merge
            // time (see MigrationStore.recordLiveAtMerge).
            MigrationStore.recordLiveAtMerge(file: "hao_recent", value: existing)
            let merged = MigrationStore.mergedRecentEntries(live: existing, incoming: incoming)
            guard let bytes = try? JSONSerialization.data(withJSONObject: merged, options: []) else {
                return .serializationFailed
            }
            do {
                try bytes.write(to: documentsURL.appendingPathComponent("hao_recent.json"), options: [.atomic])
            } catch {
                return .writeFailed
            }
            // b49fix20 D22-1: verify INSIDE the critical
            // section (tolerant check — a song switch at the
            // 100 cap may squeeze the oldest merged entry out).
            let reread = MigrationStore.readJSONList(name: "hao_recent", documentsURL: documentsURL)
            guard MigrationStore.recentContainsAll(actual: reread, expected: merged) else {
                return .verifyFailed(bytes)
            }
            return .written(bytes)
        }
    }

    /// Merges incoming resume points into the live musicResume
    /// file (b49fix17 P1-4): re-read → dict overlay → write,
    /// whole under MigrationStore.resumeWriteQueue, the same
    /// queue saveResume / clearResume use. Returns the merged
    /// bytes so the caller can verify them (key-only subset,
    /// see collectionVerifies).
    private static func mergeResumeEntries(
        _ incoming: [String: Any],
        documentsURL: URL
    ) -> CollectionWriteOutcome {
        MigrationStore.resumeWriteQueue.sync { () -> CollectionWriteOutcome in
            var existing = MigrationStore.readJSONDictionary(name: "musicResume", documentsURL: documentsURL)
            // b49fix21 D23-6: record the live value at merge
            // time (see MigrationStore.recordLiveAtMerge).
            MigrationStore.recordLiveAtMerge(file: "musicResume", value: existing)
            for (key, value) in incoming {
                existing[key] = value
            }
            guard let bytes = try? JSONSerialization.data(withJSONObject: existing, options: []) else {
                return .serializationFailed
            }
            do {
                try bytes.write(to: documentsURL.appendingPathComponent("musicResume.json"), options: [.atomic])
            } catch {
                return .writeFailed
            }
            // b49fix20 D22-1: verify INSIDE the critical
            // section (see mergeListEntries above).
            let reread = MigrationStore.readJSONDictionary(name: "musicResume", documentsURL: documentsURL)
            guard MigrationStore.resumeEntriesPresent(existing, actual: reread, toleratingDeleted: MigrationStore.resumeDeletionRecord()) else {
                return .verifyFailed(bytes)
            }
            return .written(bytes)
        }
    }

    /// Merges the backup queue into the live musicQueue file
    /// (b49fix17 P1-3): the live queue WINS when it is
    /// non-empty — the user is listening to it right now, and
    /// importing a backup must never replace the queue being
    /// listened to (the next song switch's saveQueueAsync
    /// would overwrite an imported queue anyway, so
    /// overwriting it here would only lose the live queue).
    /// The backup queue lands only when live is empty or
    /// unreadable (fresh install / first restore). Runs whole
    /// under MigrationStore.musicQueueWriteQueue, the same
    /// queue saveQueueAsync uses, and re-reads the file right after
    /// writing — that apply-time exact check is what justifies
    /// the shape-only verify (a switch landing after the write
    /// legitimately replaces the whole queue, so byte or subset
    /// equality would false-fail the import).
    private static func mergeMusicQueue(
        _ incoming: [String: Any],
        documentsURL: URL
    ) -> CollectionWriteOutcome {
        MigrationStore.musicQueueWriteQueue.sync { () -> CollectionWriteOutcome in
            let url = documentsURL.appendingPathComponent("musicQueue.json")
            let live = MigrationStore.readJSONDictionary(name: "musicQueue", documentsURL: documentsURL)
            let liveSongs = live["songs"] as? [[String: Any]] ?? []
            guard liveSongs.isEmpty else { return .skipped }
            guard let bytes = try? JSONSerialization.data(withJSONObject: incoming, options: []) else {
                return .serializationFailed
            }
            do {
                try bytes.write(to: url, options: [.atomic])
            } catch {
                return .writeFailed
            }
            guard let reread = try? Data(contentsOf: url), reread == bytes else {
                return .writeFailed
            }
            return .written(bytes)
        }
    }

    /// Merges incoming list entries into a live list file
    /// (b49fix17 P2-6): re-read → merge → write, whole under
    /// the file's queue — the generic list-merge wrapper (see
    /// MigrationStore.mergedListEntries for the rule).
    private static func mergeListEntries(
        _ incoming: [[String: Any]],
        into name: String,
        documentsURL: URL,
        keyFor: @escaping ([String: Any]) -> String,
        cap: Int?,
        secondaryKeyFor: (([String: Any]) -> String)? = nil,
        mapEntry: (([String: Any]) -> [String: Any])? = nil
    ) -> CollectionWriteOutcome {
        guard let queue = MigrationStore.writeQueue(forCollection: name) else {
            return .writeFailed
        }
        return queue.sync { () -> CollectionWriteOutcome in
            let existing = MigrationStore.readJSONList(name: name, documentsURL: documentsURL)
            // b49fix21 D23-6: record the live value at merge
            // time (see MigrationStore.recordLiveAtMerge).
            MigrationStore.recordLiveAtMerge(file: name, value: existing)
            let merged = MigrationStore.mergedListEntries(live: existing, incoming: incoming, keyFor: keyFor, cap: cap, secondaryKeyFor: secondaryKeyFor, mapEntry: mapEntry)
            guard let bytes = try? JSONSerialization.data(withJSONObject: merged, options: []) else {
                return .serializationFailed
            }
            do {
                try bytes.write(to: documentsURL.appendingPathComponent("\(name).json"), options: [.atomic])
            } catch {
                return .writeFailed
            }
            // b49fix20 D22-1: verify INSIDE the critical
            // section — the re-read runs in the same queue.sync
            // as the write, so no queued writer can land
            // between them (the old outer collectionVerifies
            // ran after the return, with the whole remaining
            // apply in between).
            let reread = MigrationStore.readJSONList(name: name, documentsURL: documentsURL)
            guard MigrationStore.listKeysContainAll(actual: reread, expected: merged, file: name) else {
                return .verifyFailed(bytes)
            }
            return .written(bytes)
        }
    }

    /// Merges incoming string-list entries into a live
    /// string-list file (b49fix17 P2-6): same shape as
    /// mergeListEntries, for search history, fav playlists
    /// and FM dislikes.
    private static func mergeStringListEntries(
        _ incoming: [String],
        into name: String,
        documentsURL: URL,
        cap: Int?
    ) -> CollectionWriteOutcome {
        guard let queue = MigrationStore.writeQueue(forCollection: name) else {
            return .writeFailed
        }
        return queue.sync { () -> CollectionWriteOutcome in
            let existing = MigrationStore.readJSONStringList(name: name, documentsURL: documentsURL)
            // b49fix21 D23-6: record the live value at merge
            // time (see MigrationStore.recordLiveAtMerge).
            MigrationStore.recordLiveAtMerge(file: name, value: existing)
            let merged = MigrationStore.mergedStringList(live: existing, incoming: incoming, cap: cap)
            guard let bytes = try? JSONSerialization.data(withJSONObject: merged, options: []) else {
                return .serializationFailed
            }
            do {
                try bytes.write(to: documentsURL.appendingPathComponent("\(name).json"), options: [.atomic])
            } catch {
                return .writeFailed
            }
            // b49fix20 D22-1: verify INSIDE the critical
            // section (see mergeListEntries above).
            let reread = MigrationStore.readJSONStringList(name: name, documentsURL: documentsURL)
            guard MigrationStore.stringListContainsAll(actual: reread, expected: merged) else {
                return .verifyFailed(bytes)
            }
            return .written(bytes)
        }
    }

    /// Merges incoming listen entries into the live hao_listen
    /// file: re-read → append → dedupe → cap 3000 → write,
    /// whole under MigrationStore.listenLogWriteQueue, the same
    /// queue recordListenEvent uses. Shared by the collections
    /// loop (b49fix16 P1-1) and the merged-files loop (b49fix15
    /// P2-1) — one rule for both import paths. Returns the
    /// merged bytes so the caller can verify them (subset,
    /// b49fix16 P1-2).
    private static func mergeListenEntries(
        _ incoming: [[String: Any]],
        documentsURL: URL
    ) -> CollectionWriteOutcome {
        MigrationStore.listenLogWriteQueue.sync { () -> CollectionWriteOutcome in
            var existing = MigrationStore.readJSONList(name: "hao_listen", documentsURL: documentsURL)
            // b49fix21 D23-6: record the live value at merge
            // time, BEFORE the append (see
            // MigrationStore.recordLiveAtMerge).
            MigrationStore.recordLiveAtMerge(file: "hao_listen", value: existing)
            // b49fix19 P2-6: the split point is known here (live
            // entries first, incoming appended after), so the
            // secondary title+artist key dedupes only incoming
            // entries against live ones — the live log itself is
            // never rewritten by a dedupe.
            let liveCount = existing.count
            existing.append(contentsOf: incoming)
            // b49fix2 P2-11: a re-import of the same backup used
            // to double the history (append with no dedupe).
            // Same song at the same second is the same listen,
            // not two.
            existing = MigrationStore.dedupedListenEntries(existing, liveCount: liveCount)
            if existing.count > 3000 {
                existing = Array(existing.suffix(3000))
            }
            guard let merged = try? JSONSerialization.data(withJSONObject: existing, options: []) else {
                return .serializationFailed
            }
            do {
                try merged.write(to: documentsURL.appendingPathComponent("hao_listen.json"), options: [.atomic])
            } catch {
                return .writeFailed
            }
            // b49fix20 D22-1: verify INSIDE the critical
            // section (see mergeListEntries above). b49fix21
            // D23-8: the light proof (count + head/tail identity
            // — see MigrationStore.listenLightProof), not the
            // full subset: a 3000-entry re-read + parse + full
            // subset holds listenLogWriteQueue ~60 ms, and the
            // full subset still runs at the final sweep.
            let reread = MigrationStore.readJSONList(name: "hao_listen", documentsURL: documentsURL)
            guard MigrationStore.listenLightProof(actual: reread, expected: existing) else {
                return .verifyFailed(merged)
            }
            return .written(merged)
        }
    }

    /// Merges incoming dict entries into the live file:
    /// re-read → overlay → prune/cap → write, whole under the
    /// file's queue — the queue is explicit at every call site
    /// (dailyWriteQueue for hao_daily / haoVodProg /
    /// hao_daily_pool, collectionWriteQueue for the caches),
    /// because the queue is what makes the merge atomic against
    /// that file's live writer. Shared by the collections loop
    /// (b49fix16 P1-1) and the merged-files loop. haoVodProg's
    /// cap is deterministic (b49fix16 P2-6, b49fix17 P2-1:
    /// incoming keys always survive it). hao_daily and
    /// hao_daily_pool apply the same 7-day prune live writes
    /// apply (b49fix17 P2-4). b49fix19 P2-7: hao_daily merges
    /// per song within each day (see MigrationStore
    /// .mergedDailyDay), not per day — the old overlay replaced
    /// the whole day's list with the backup's. b49fix19 P1-7:
    /// a hao_lyrics merge writes the imported keys into the
    /// lyrics order file so the next putLyrics does not evict
    /// them first.
    private static func mergeDictEntries(
        _ incoming: [String: Any],
        into name: String,
        documentsURL: URL,
        queue: DispatchQueue,
        defaults: UserDefaults = .standard
    ) -> CollectionWriteOutcome {
        queue.sync { () -> CollectionWriteOutcome in
            var existing = MigrationStore.readJSONDictionary(name: name, documentsURL: documentsURL)
            // b49fix21 D23-6: record the live value at merge
            // time (see MigrationStore.recordLiveAtMerge).
            MigrationStore.recordLiveAtMerge(file: name, value: existing)
            for (key, value) in incoming {
                if name == "hao_daily",
                   let liveDay = existing[key] as? [[String: Any]],
                   let incomingDay = value as? [[String: Any]] {
                    existing[key] = MigrationStore.mergedDailyDay(live: liveDay, incoming: incomingDay)
                } else {
                    existing[key] = value
                }
            }
            if name == "hao_daily" || name == "hao_daily_pool" {
                existing = MigrationStore.prunedDailyEntries(existing, keeping: nil)
            }
            if name == "haoVodProg" {
                existing = MigrationStore.cappedVodProgEntries(existing, keeping: Set(incoming.keys))
            }
            if name == "hao_lyrics" {
                MigrationStore.reconcileLyricsCacheOrder(
                    mergedKeys: Set(existing.keys),
                    importedKeys: Array(incoming.keys),
                    defaults: defaults
                )
            }
            if name == "hao_cover_cache" {
                // b49fix20 D22-9: trim the merged cache to
                // the live 500 cap (see
                // MigrationStore.trimmedCoverCache) — the merge
                // used to grow the file past the cap the live
                // writer enforces.
                existing = MigrationStore.trimmedCoverCache(merged: existing, incomingKeys: Set(incoming.keys))
            }
            guard let merged = try? JSONSerialization.data(withJSONObject: existing, options: []) else {
                return .serializationFailed
            }
            do {
                try merged.write(to: documentsURL.appendingPathComponent("\(name).json"), options: [.atomic])
            } catch {
                return .writeFailed
            }
            // b49fix20 D22-1/D22-7: verify INSIDE the critical
            // section — hao_daily uses the per-day value check,
            // the other dict files the key-only dict check.
            let reread = MigrationStore.readJSONDictionary(name: name, documentsURL: documentsURL)
            if name == "hao_daily" {
                guard MigrationStore.dailyDaysContainAll(actual: reread, expected: existing) else {
                    return .verifyFailed(merged)
                }
            } else {
                guard dictContainsAll(reread, existing, keyOnly: true, toleratingDeleted: MigrationStore.cacheEvictionRecord(for: name)) else {
                    return .verifyFailed(merged)
                }
            }
            return .written(merged)
        }
    }

    /// Verifies one written collection (b49fix16 P1-2, b49fix17
    /// P1-2/P1-3/P2-2, b49fix19 P1-2/P1-4/P2-9d): canonical
    /// equality for ordinary collections; identity subset for
    /// the concurrently-written set (see
    /// concurrentlyWrittenCollections) — a resume checkpoint, a
    /// song switch, a pool pin, a listen completion, a daily
    /// replace or a favourite toggle landing between the write
    /// and this check must not fail the whole import. An
    /// expected value that does not parse as a list/dict (the
    /// unparseable-bytes fallback) falls back to canonical
    /// byte equality: subset has nothing to compare.
    /// b49fix21 D23-1: `finalSweep` is the final sweep only —
    /// there, whole-file files ALSO verify by subset (see
    /// MigrationStore.wholeFileSubsetVerifies), not canonical
    /// byte equality. The in-section verify already proved the
    /// write landed; the final sweep only proves the imported
    /// content survived, and a live writer that
    /// merged-preserved it (a resolver save, a download
    /// persist, a favourite toggle, a search write) changes
    /// the bytes without losing anything. Byte equality at the
    /// final sweep used to fail the whole import — and roll
    /// back every other merged file — for a file whose content
    /// was intact. The immediate (non-final-sweep) calls keep
    /// byte equality: the unknown-keys file has no live writer,
    /// and a strict immediate proof is the right check there.
    private static func collectionVerifies(
        relativePath: String, expectedBytes: Data, documentsURL: URL, finalSweep: Bool = false
    ) -> Bool {
        guard let actualData = try? Data(contentsOf: documentsURL.appendingPathComponent(relativePath)) else {
            return false
        }
        let base = String(relativePath.dropLast(".json".count))
        // b49fix17 P1-3: musicQueue verifies by shape only. The
        // live queue is replaced wholesale on every song switch
        // (saveQueueAsync), so neither byte equality nor subset
        // can hold across the write → verify window — and the
        // apply-time exact re-read inside mergeMusicQueue
        // already proved the backup queue landed. Shape-only
        // still catches a clobbered file (a concurrent writer
        // keeps it a valid queue dict; anything else fails).
        if base == "musicQueue" {
            return (try? JSONSerialization.jsonObject(with: actualData, options: [])) is [String: Any]
        }
        if finalSweep, !concurrentlyWrittenCollections.contains(base) {
            // b49fix21 D23-1 (see the doc comment above):
            // whole-file files verify by subset at the final
            // sweep — lists by identity key, string lists by
            // set subset, dicts by key only; a scalar falls
            // back to value equality (b49fix22 O-2: Route B
            // already compared scalars by value with
            // jsonValuesEqual; canonicalJSONData returns nil
            // for a scalar, which used to fall back to raw byte
            // equality here). Dicts are key-only on purpose
            // (b49fix22 D24-1, see wholeFileSubsetVerifies):
            // a dict value may legitimately be superseded by a
            // newer live recording — ResolverSpeedRecord merges
            // newest-wins — and value equality here would
            // re-introduce the D23-1 false-fail.
            guard let expected = try? JSONSerialization.jsonObject(with: expectedBytes, options: []),
                  let actual = try? JSONSerialization.jsonObject(with: actualData, options: [])
            else { return actualData == expectedBytes }
            if let expectedList = expected as? [[String: Any]],
               let actualList = actual as? [[String: Any]] {
                return MigrationStore.listKeysContainAll(actual: actualList, expected: expectedList, file: base)
            }
            if let expectedStrings = expected as? [String],
               let actualStrings = actual as? [String] {
                return MigrationStore.stringListContainsAll(actual: actualStrings, expected: expectedStrings)
            }
            if let expectedDict = expected as? [String: Any],
               let actualDict = actual as? [String: Any] {
                return dictContainsAll(actualDict, expectedDict, keyOnly: true)
            }
            return MigrationStore.jsonValuesEqual(expected, actual)
        }
        guard concurrentlyWrittenCollections.contains(base),
              let expected = try? JSONSerialization.jsonObject(with: expectedBytes, options: []),
              let actual = try? JSONSerialization.jsonObject(with: actualData, options: [])
        else {
            // Ordinary collection, or unparseable expected bytes
            // (the whole-file fallback): canonical byte equality
            // (b49fix19 P2-9d — raw byte equality failed the
            // same live re-serialisation Route B passed, because
            // the key order differs; canonical bytes compare
            // content, not serialisation order). Unparseable
            // bytes fall back to raw equality.
            guard let expectedParsed = try? JSONSerialization.jsonObject(with: expectedBytes, options: []),
                  let actualParsed = try? JSONSerialization.jsonObject(with: actualData, options: []),
                  let expectedCanonical = MigrationStore.canonicalJSONData(expectedParsed),
                  let actualCanonical = MigrationStore.canonicalJSONData(actualParsed)
            else { return actualData == expectedBytes }
            return actualCanonical == expectedCanonical
        }
        if let expectedList = expected as? [[String: Any]],
           let actualList = actual as? [[String: Any]] {
            // b49fix17 P1-2: hao_recent verifies by the tolerant
            // structural check, not the plain multiset subset —
            // a song switch at the routine 100 cap squeezes the
            // oldest merged entry out, and that must not fail
            // the import. hao_listen keeps the plain subset (its
            // 3000 cap edge is the accepted rarity, same as
            // before). b49fix19 P1-2: the subset is by identity
            // key, not canonical bytes — a live writer's typed
            // round-trip rewrites the bytes (drops unknown
            // fields, fills defaults, normalises platform
            // codes) without changing the content.
            if base == "hao_recent" {
                return MigrationStore.recentContainsAll(actual: actualList, expected: expectedList)
            }
            return MigrationStore.listKeysContainAll(actual: actualList, expected: expectedList, file: base)
        }
        if let expectedStrings = expected as? [String],
           let actualStrings = actual as? [String] {
            // b49fix20 D22-3: string-list collections verify
            // by subset, not canonical byte equality — a live
            // writer appending a search term between the write
            // and the verify used to fail the whole import
            // (Route B already verified these by subset).
            return MigrationStore.stringListContainsAll(actual: actualStrings, expected: expectedStrings)
        }
        if let expectedDict = expected as? [String: Any],
           let actualDict = actual as? [String: Any] {
            // b49fix19 P1-2: merged dicts verify by key only.
            // A live writer round-trips values through its typed
            // struct (saveDailyTracks rewrites the day's songs,
            // saveCover filters to [String: String]) — the
            // values change bytes without changing the merged
            // content, so value equality false-failed whenever
            // such a write landed in the window. Key presence is
            // the content guarantee; a live writer replacing a
            // value is newer intent, not import loss.
            // b49fix17 P2-2: a natural completion may delete an
            // imported resume key between the write and this
            // check — keys clearResume deleted during this
            // import are excused (deleting a key is a legitimate
            // concurrent event, same class as a checkpoint
            // advancing). b49fix19 P1-7: the same excuse covers
            // keys a live cache eviction removed during this
            // import (hao_lyrics / hao_cover_cache).
            // b49fix20 D22-7: hao_daily verifies per day by
            // value, not key-only (see
            // MigrationStore.dailyDaysContainAll).
            if base == "hao_daily" {
                return MigrationStore.dailyDaysContainAll(actual: actualDict, expected: expectedDict)
            }
            if base == "musicResume" {
                return dictContainsAll(actualDict, expectedDict, keyOnly: true, toleratingDeleted: MigrationStore.resumeDeletionRecord())
            }
            return dictContainsAll(actualDict, expectedDict, keyOnly: true, toleratingDeleted: MigrationStore.cacheEvictionRecord(for: base))
        }
        // Expected parses but is neither a list nor a dict (a
        // scalar): nothing to subset-compare — value equality
        // (b49fix22 O-2: jsonValuesEqual wraps in an array, so
        // a bare scalar compares; canonicalJSONData returns nil
        // for one, which used to fall back to raw byte equality
        // here while Route B already compared by value).
        guard let expectedParsed = try? JSONSerialization.jsonObject(with: expectedBytes, options: []),
              let actualParsed = try? JSONSerialization.jsonObject(with: actualData, options: [])
        else { return actualData == expectedBytes }
        return MigrationStore.jsonValuesEqual(expectedParsed, actualParsed)
    }

    /// Multiset subset: every expected entry must still be in
    /// the actual file, compared by canonical JSON bytes
    /// (sorted keys) so key order does not matter. A concurrent
    /// append cannot break it. Edge, accepted: at exactly 3000
    /// entries a concurrent append can push the oldest imported
    /// entry out of the cap — extremely unlikely, and the
    /// failure mode is the same loud failure + rollback as
    /// today, just far rarer. b49fix19 P1-2: no verify path
    /// uses this any more — the merged-list verifies compare
    /// identity keys (MigrationStore.listKeysContainAll),
    /// because a live writer's typed round-trip rewrites the
    /// bytes a byte subset compares. Kept as the byte-level
    /// subset utility (the harness's retained behaviour cases
    /// cover it); internal, not private, so tests can use it.
    static func listContainsAll(
        _ actual: [[String: Any]], _ expected: [[String: Any]]
    ) -> Bool {
        var counts: [Data: Int] = [:]
        counts.reserveCapacity(actual.count)
        for entry in actual {
            guard let bytes = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { continue }
            counts[bytes, default: 0] += 1
        }
        for entry in expected {
            guard let bytes = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
                  let remaining = counts[bytes], remaining > 0
            else { return false }
            counts[bytes] = remaining - 1
        }
        return true
    }

    /// Dict subset: every expected key must be present; unless
    /// keyOnly, with a canonically-equal value. Values compare
    /// by wrapping them in an array first — data(withJSONObject:)
    /// on a top-level scalar raises an uncatchable NSException,
    /// so a bare Double (haoVodProg values) must never be
    /// serialised directly. `toleratingDeleted` excuses keys
    /// a legitimate concurrent deletion removed after the write
    /// (b49fix17 P2-2: clearResume on natural completion;
    /// b49fix19 P1-7: live cache evictions). Internal, not
    /// private: Route B (MigrationStore.importData) verifies
    /// its merged dicts with the same rule (b49fix18 D-1) —
    /// one subset rule for both import routes. Both routes now
    /// pass keyOnly: true for merged dicts (b49fix19 P1-2).
    static func dictContainsAll(
        _ actual: [String: Any], _ expected: [String: Any], keyOnly: Bool, toleratingDeleted deletedKeys: Set<String> = []
    ) -> Bool {
        for (key, expectedValue) in expected {
            if deletedKeys.contains(key) { continue }
            guard let actualValue = actual[key] else { return false }
            if keyOnly { continue }
            guard let expectedData = try? JSONSerialization.data(withJSONObject: [expectedValue], options: [.sortedKeys]),
                  let actualData = try? JSONSerialization.data(withJSONObject: [actualValue], options: [.sortedKeys]),
                  expectedData == actualData
            else { return false }
        }
        return true
    }

    /// The rollback-failure detail string (b49fix27 D28-1):
    /// factored out of `applyPlannedImport` so tests can assert
    /// its paren balance directly. The failure branch prefixes
    /// each note with "；" and does NOT close it with "）" —
    /// round-26's hoisted-`let` refactor miscopied the success
    /// branch's closing "）" into these two suffixes, leaving
    /// orphan right parens whenever either list is non-empty.
    /// The success branch (`（…）` wrapping) is built inline
    /// in `applyPlannedImport` and is byte-identical to the
    /// pre-round-26 text.
    static func rollbackFailureDetail(
        reason: String, rollbackFailures: [String],
        keptLive: [String], keptLiveDefaults: [String],
        droppedSuffix: String
    ) -> String {
        let keptLiveSuffixSemi = keptLive.isEmpty ? "" : "；导入期间被 live 改写（新增／删除／改值）的文件已保留 live 版本：" + keptLive.joined(separator: "、")
        let keptLiveDefaultsSuffixSemi = keptLiveDefaults.isEmpty ? "" : "；导入期间被改写的设置已保留 live 值：" + keptLiveDefaults.joined(separator: "、")
        return reason + "，回滚未完成，未恢复："
            + rollbackFailures.joined(separator: "、")
            + keptLiveSuffixSemi + keptLiveDefaultsSuffixSemi
            + droppedSuffix
    }

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
        for name in planned.mergedFileNames {
            touchedFiles.append(name + ".json")
        }
        if !planned.unknown.isEmpty {
            touchedFiles.append(unknownKeysFileName + ".json")
        }
        for file in planned.payloadFiles {
            touchedFiles.append(file.relativePath)
        }
        // b49fix16 P2-4: dedupe — a foreign backup can carry
        // both collections/X.json and the matching merge/unknown
        // input, and createSnapshot copyItem throws on the second
        // copy of the same path, failing the whole import before
        // anything is written. Order-preserving dedupe (first
        // occurrence wins); the snapshot only needs each path once.
        var seenTouched = Set<String>()
        touchedFiles = touchedFiles.filter { seenTouched.insert($0).inserted }
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
                detail: "导入前快照失败，未写入任何内容", embyCredentialsMissing: false,
                nothingWritten: true
            )
        }

        var journal = BackupJournal()
        var appliedKeys = 0
        var appliedCollections = 0
        var appliedFiles = 0
        var expectedCollectionBytes: [String: Data] = [:]
        // b49fix20 D22-5/D22-14: payload paths extracted this
        // round — expectedCollectionBytes only holds
        // collections, so payload files are tracked separately
        // for the rollback (a payload file extracted this round
        // counts as written; one never reached does not).
        var writtenPayloadPaths: Set<String> = []
        // b49fix17 P1-1/P1-3: files deliberately not written at
        // apply time (live file healthy + backup bytes corrupt,
        // or the live queue wins) — reported as skipped, not
        // applied and not failed.
        var applySkipped: [String] = []
        // b49fix18 D-5c/D-6: warnings a passing verify still
        // owes the user (tolerated recent displacement, soft
        // vodProg cap) — collected here, merged into the
        // report at commit.
        var verifyWarnings: [String] = []
        var failureReason: String?

        // Import is a MERGE, not a replace (b49fix17 §6): live
        // keys absent from the backup are kept, so an old backup
        // cannot restore the exact backup-time state — the
        // pre-import snapshot (kept under backup_snapshots) and
        // the rollback below are what preserve the pre-import
        // state. The import preview says the same to the user.
        // b49fix17 P2-2: clear the resume-deletion record — the
        // verify below excuses exactly the keys clearResume
        // deletes during THIS import.
        MigrationStore.resetResumeDeletionRecord()
        // b49fix19 P1-7: clear the cache-eviction record — the
        // verify excuses exactly the keys a live eviction
        // removes during THIS import.
        MigrationStore.resetCacheEvictionRecord()
        // b49fix20 D22-7: clear the daily-cap record — the
        // report counts exactly the incoming songs the cap
        // dropped during THIS import.
        MigrationStore.resetDailyCapDroppedRecord()
        // b49fix21 D23-6: clear the live-at-merge record — the
        // rollback reads exactly the live values THIS import's
        // merges saw.
        MigrationStore.resetLiveAtMergeRecord()
        // b49fix19 P2-4: the live-history cap the merge uses —
        // 0 in the setting means unlimited (nil), absent means
        // the 50 default.
        let liveHistLimit = MigrationStore.liveHistoryCap(defaults: defaults)

        // Defaults first, in sorted order (the plan already
        // sorted them via the data dict's sorted keys).
        for write in planned.defaultWrites {
            if testFailOnKey == write.key {
                failureReason = "写入失败：\(write.key)"
                break
            }
            journal.recordDefault(key: write.key, defaults: defaults)
            defaults.set(write.value, forKey: write.key)
            // b49fix19 P1-4: verify this default now — a
            // settings write landing between the set and an
            // end-of-apply verify used to fail the whole import
            // the same way a file write did.
            if !MigrationStore.verifyDefault(key: write.key, kind: write.kind, defaults: defaults) {
                failureReason = "校验失败：\(write.key)"
                break
            }
            // b49fix21 D23-9: mark this default written +
            // verified — only now is it restorable by the
            // rollback (see BackupJournal.writtenDefaults).
            journal.recordWrittenDefault(key: write.key, value: write.value)
            appliedKeys += 1
        }

        // Collections (b49fix16 P1-1, b49fix17 P1-1/P1-2/P1-3/
        // P1-4/P2-6): every collection with a live writer merges
        // at apply time via writeCollection, under the file's
        // serial queue, so a concurrent writer landing before
        // this write is merged in, not overwritten by the
        // backup's bytes. The collections without a live writer
        // keep the whole-file write (with the P1-1 guard in
        // writeWholeCollectionBytes: corrupt backup bytes never
        // overwrite a healthy live file).
        if failureReason == nil {
            for collection in planned.collections.sorted(by: { $0.name < $1.name }) {
                let relativePath = collection.name + ".json"
                if testFailOnFile == relativePath {
                    failureReason = "写入失败：\(relativePath)"
                    break
                }
                switch writeCollection(collection, documentsURL: documentsURL, defaults: defaults, liveHistLimit: liveHistLimit) {
                case .written(let bytes):
                    expectedCollectionBytes[relativePath] = bytes
                    appliedCollections += 1
                    // b49fix20 D22-1: no outer verify any more —
                    // each merge helper verified inside its own
                    // critical section (see mergeListEntries and
                    // friends); whole-file files verified inside
                    // writeWholeCollectionBytes. The old
                    // collectionVerifies call ran after the
                    // return, with the whole remaining apply in
                    // between.
                    // b49fix18 D-5c: a passing recent verify that
                    // still excused missing entries warns — the
                    // displacement is observable instead of silent.
                    if relativePath == "hao_recent.json",
                       let expected = try? JSONSerialization.jsonObject(with: bytes, options: []) as? [[String: Any]],
                       let actualData = try? Data(contentsOf: documentsURL.appendingPathComponent(relativePath)),
                       let actual = try? JSONSerialization.jsonObject(with: actualData, options: []) as? [[String: Any]] {
                        let missing = MigrationStore.recentMissingKeys(actual: actual, expected: expected).count
                        if missing > 0 {
                            verifyWarnings.append("最近播放有 \(missing) 条记录在导入期间被替换，已按容忍规则通过校验")
                        }
                    }
                case .skipped:
                    applySkipped.append(collection.name)
                case .serializationFailed:
                    // b49fix16 P2-5: a serialisation failure is
                    // reported as one, not as a write failure.
                    failureReason = "序列化失败：\(relativePath)"
                case .writeFailed:
                    failureReason = "写入失败：\(relativePath)"
                case .verifyFailed(let bytes):
                    // b49fix20 D22-1: record what was written
                    // before failing, so the rollback treats
                    // this file as written (otherwise it would
                    // skip it and leave suspect content in
                    // place).
                    expectedCollectionBytes[relativePath] = bytes
                    failureReason = "校验失败：\(relativePath)"
                }
                if failureReason != nil { break }
            }
        }
        // Merged files (b49fix15 P2-1, b49fix16 P1-1/P2-2/P2-5):
        // the merge happens HERE, at apply time — the plan only
        // accumulated the incoming values, so this re-reads the
        // LIVE file first. A listen event recorded while the
        // import was running is in the file this merge reads,
        // not overwritten by plan-time bytes. The listen merge's
        // re-read → merge → write runs whole under
        // MigrationStore.listenLogWriteQueue, the same queue
        // recordListenEvent uses; the dict merges run whole
        // under MigrationStore.dailyWriteQueue, the same queue
        // saveDailyTracks / saveDailyTracksIfUnchanged use — the
        // write must be in the same critical section as the
        // re-read, or a completion / replace landing between
        // merge and write is lost. A serialisation failure is
        // reported as one, not as a write failure (b49fix16
        // P2-5): the bytes were never formable, and sending the
        // diagnosis to the disk would mislead.
        if failureReason == nil {
            for name in planned.mergedFileNames.sorted() {
                let relativePath = name + ".json"
                if testFailOnFile == relativePath {
                    failureReason = "写入失败：\(relativePath)"
                    break
                }
                let outcome: CollectionWriteOutcome
                if name == "hao_listen" {
                    outcome = mergeListenEntries(
                        planned.mergedListInputs[name] ?? [],
                        documentsURL: documentsURL)
                } else {
                    outcome = mergeDictEntries(
                        planned.mergedDictInputs[name] ?? [:],
                        into: name, documentsURL: documentsURL,
                        queue: MigrationStore.dailyWriteQueue,
                        defaults: defaults)
                }
                switch outcome {
                case .written(let bytes):
                    expectedCollectionBytes[relativePath] = bytes
                    appliedCollections += 1
                    // b49fix20 D22-1: no outer verify any more —
                    // each merge helper verified inside its own
                    // critical section (same reason as the
                    // collections loop above).
                case .skipped:
                    // Unreachable: neither merge helper returns
                    // .skipped — recorded defensively so the
                    // switch stays exhaustive if one ever does.
                    applySkipped.append(name)
                case .serializationFailed:
                    failureReason = "序列化失败：\(relativePath)"
                case .writeFailed:
                    failureReason = "写入失败：\(relativePath)"
                case .verifyFailed(let bytes):
                    // b49fix20 D22-1: record what was written
                    // before failing, so the rollback treats
                    // this file as written (otherwise it would
                    // skip it and leave suspect content in
                    // place).
                    expectedCollectionBytes[relativePath] = bytes
                    failureReason = "校验失败：\(relativePath)"
                }
                if failureReason != nil { break }
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
                    // b49fix19 P1-4: verify this file now (same
                    // reason as the collections loop above).
                    if !collectionVerifies(relativePath: relativePath, expectedBytes: bytes, documentsURL: documentsURL) {
                        failureReason = "校验失败：\(relativePath)"
                    }
                } catch {
                    failureReason = "写入失败：\(relativePath)"
                }
            } else {
                // b49fix17 P2-5: this is a serialisation failure,
                // not a write failure — same wording as the
                // collections and merged loops above.
                failureReason = "序列化失败：\(relativePath)"
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
                // b49fix19 P1-4: verify this file's size now
                // (same reason as the collections loop above).
                guard let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue,
                      size == Int(file.entry.uncompressedSize)
                else {
                    failureReason = "校验失败：\(file.relativePath)"
                    break
                }
                // b49fix20 D22-5/D22-14: this payload file was
                // extracted this round — it counts as written
                // for the rollback (see writtenPayloadPaths).
                writtenPayloadPaths.insert(file.relativePath)
                appliedFiles += 1
            }
        }

        // b49fix20 D22-2(a): the final sweep — every collection
        // was verified inside its own critical section at
        // write time (D22-1), but a stale-state writer
        // (ResolverCooldown.save, DownloadEngine.persistLocked,
        // saveDailyTracks' day overwrite) can still wipe
        // imported content AFTER its file verified, because
        // those writers re-read nothing — and the payload phase
        // above (seconds to tens of seconds on a big backup)
        // stretches that window longest. Re-verify every
        // applied collection file now, after the payload phase
        // and before the success report — a failure here is
        // loud (fail + preserving rollback), never silent.
        // musicQueue verifies by shape only (a song switch
        // after the write legitimately replaced it). b49fix21
        // D23-1: whole-file files verify by subset at this
        // sweep (finalSweep: true), not byte equality — a live
        // writer that merged-preserved the import's content
        // changes the bytes without losing anything.
        if failureReason == nil {
            for relativePath in expectedCollectionBytes.keys.sorted() {
                guard collectionVerifies(relativePath: relativePath, expectedBytes: expectedCollectionBytes[relativePath]!, documentsURL: documentsURL, finalSweep: true) else {
                    failureReason = "最终校验失败：\(relativePath)"
                    break
                }
            }
        }

        // b49fix21 D23-10: re-verify payload SIZES at the final
        // sweep too. The old comment claimed "no live writer
        // touches them", which is false for music_downloads —
        // a live download completing during the payload phase
        // (.part promoted onto the same target name) overwrites
        // an unpacked payload file, and the final sweep never
        // re-checked it, so the import passed silently with the
        // wrong file in place. Size-only (attributes, no file
        // read): a same-name overwrite with a different size
        // fails loud here and rolls back; local_music /
        // wallpapers have no live writer and re-verify
        // trivially. A same-size overwrite is indistinguishable
        // by size alone and is accepted as vanishingly unlikely
        // (it would also be a valid download of the same name
        // and size).
        if failureReason == nil {
            for file in planned.payloadFiles where writtenPayloadPaths.contains(file.relativePath) {
                let url = documentsURL.appendingPathComponent(file.relativePath)
                guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
                      size == Int(file.entry.uncompressedSize)
                else {
                    failureReason = "最终校验失败：\(file.relativePath)"
                    break
                }
            }
        }

        // b49fix17 P1-1/P1-3: plan-time skips plus apply-time
        // skips, reported together.
        let allSkipped = (planned.skipped + applySkipped).sorted()

        if let reason = failureReason {
            // b49fix19 P1-4: the rollback preserves live
            // increments made during the import (see
            // restoreFilesFromSnapshot) instead of writing the
            // snapshot bytes back whole.
            let (rollbackFailures, keptLive, keptLiveDefaults, normalizedHistory) = rollback(
                journal: journal, snapshotDir: snapshotDir,
                documentsURL: documentsURL, defaults: defaults,
                writtenBytes: expectedCollectionBytes,
                writtenPayloadPaths: writtenPayloadPaths
            )
            // b49fix22 D24-2: the rollback normalises restored
            // history files (see normalizeRestoredHistory) — the
            // dropped count used to be dropped by rollback()
            // itself, so a failed import never told the user
            // history entries were skipped, while a manual
            // restore of the same snapshot did. Same wording as
            // the manual restore (see historyDroppedLines).
            let droppedLines = historyDroppedLines(for: normalizedHistory)
            let droppedSuffix = droppedLines.isEmpty ? "" : "；" + droppedLines.joined(separator: "；")
            // b49fix4 P2-36: "已全量回滚" is only true when the
            // rollback itself restored everything. When it did
            // not, say so and name what was not put back.
            // b49fix26: the two detail expressions below used to be
            // single multi-line `+` chains with nested ternaries —
            // the compiler could not type-check them in reasonable
            // time (Bitrise #36). Each suffix is now built once, as
            // its own statement, and the detail assignments are
            // plain linear concatenations. The success branch is
            // byte-identical to the old text (each note wrapped in
            // full-width parens); the failure branch prefixes each
            // note with "；" and closes nothing (b49fix27 D28-1:
            // round-26 had miscopied the success branch's closing
            // "）" into the two failure suffixes).
            let keptLiveSuffix = keptLive.isEmpty ? "" : "（导入期间被 live 改写（新增／删除／改值）的文件已保留 live 版本：" + keptLive.joined(separator: "、") + "）"
            let keptLiveDefaultsSuffix = keptLiveDefaults.isEmpty ? "" : "（导入期间被改写的设置已保留 live 值：" + keptLiveDefaults.joined(separator: "、") + "）"
            let detail: String
            if rollbackFailures.isEmpty {
                detail = reason + "，已全量回滚" + keptLiveSuffix + keptLiveDefaultsSuffix + droppedSuffix
            } else {
                detail = rollbackFailureDetail(
                    reason: reason, rollbackFailures: rollbackFailures,
                    keptLive: keptLive, keptLiveDefaults: keptLiveDefaults,
                    droppedSuffix: droppedSuffix
                )
            }
            return BackupImportDetail(
                outcome: .failed, appliedKeys: 0, appliedCollections: 0,
                appliedFiles: 0, skippedKeyNames: allSkipped,
                unknownKeyNames: Array(planned.unknown.keys).sorted(),
                warnings: planned.warnings,
                detail: detail, embyCredentialsMissing: false,
                rollbackFailures: rollbackFailures
            )
        }

        // Commit: tell the app layer to re-read everything.
        // The snapshot folder is kept (same rule as S1's
        // migration_backup): the pre-import state stays on disk
        // until the user clears it.
        // b49fix20 D22-8: sweep both unknown-keys files
        // against the current mapping table (see
        // MigrationStore.sweepUnknownKeysFiles) — after the
        // final sweep above, and only on success. b49fix21
        // D23-5: only keys THIS import installed (written
        // collections + planned default writes) — a key this
        // backup never carried keeps its isolation.
        let installedKeys = Set(expectedCollectionBytes.keys.compactMap { path -> String? in
            guard !path.contains("/"), path.hasSuffix(".json") else { return nil }
            return String(path.dropLast(".json".count))
        }).union(planned.defaultWrites.map { $0.key })
        MigrationStore.sweepUnknownKeysFiles(documentsURL: documentsURL, installedKeys: installedKeys)
        var warnings = planned.warnings + verifyWarnings
        // b49fix20 D22-7: days that exceeded the 20-song cap
        // dropped incoming songs — counted, never silent.
        let dailyDropped = MigrationStore.dailyCapDroppedDuringImport()
        if dailyDropped > 0 {
            warnings.append("每日推薦有 \(dailyDropped) 首匯入歌曲超出每日 20 首上限，已跳過")
        }
        if planned.hasEmbyConfig, !embyCredentialPresent() {
            warnings.append(embyCredentialWarning)
        }
        // b49fix18 D-6: the vodProg cap is a soft cap — when
        // the incoming set alone exceeded 200 the merged file
        // exceeds 200 too (see cappedVodProgEntries), and it
        // will not converge back below 200 on re-import of the
        // same backup. The merged count equals the incoming
        // count whenever it exceeds 200 (the cap only ever
        // fills UP to 200), so the written count is the
        // incoming count here.
        if let vodData = expectedCollectionBytes["haoVodProg.json"],
           let vod = try? JSONSerialization.jsonObject(with: vodData, options: []) as? [String: Any],
           vod.count > 200 {
            warnings.append("点播续播记录超过 200 条上限（本次导入带入 \(vod.count) 条），已全部保留")
        }
        // b49fix2 P2-13: the scripts are back, their keys are
        // not — they live in the Keychain and never enter a
        // backup file. Say so instead of letting the scripts
        // fail silently on their first use.
        if planned.hasCustomLXScripts {
            warnings.append(lxKeysWarning)
        }
        NotificationCenter.default.post(name: .haoBackupImported, object: nil)
        // b49fix3 P2-17: keep only the newest 5 snapshots — every
        // import leaves one behind, and the folder would otherwise
        // grow without bound. The settings row offers per-snapshot
        // delete on top of this.
        pruneSnapshots(documentsURL: documentsURL)
        let detail = "已恢复 \(appliedKeys) 个设置、\(appliedCollections) 个集合、\(appliedFiles) 个文件"
            + (allSkipped.isEmpty ? "" : "，跳过 \(allSkipped.count) 个坏键")
            + (planned.unknown.isEmpty ? "" : "，隔离 \(planned.unknown.count) 个未知键")
        return BackupImportDetail(
            outcome: .imported, appliedKeys: appliedKeys,
            appliedCollections: appliedCollections, appliedFiles: appliedFiles,
            skippedKeyNames: allSkipped,
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
        // b49fix9 P2-7: the stamp carries milliseconds
        // ("yyyyMMdd-HHmmssSSS"), so two snapshots taken in
        // the same second — an import and its safety net —
        // still order by the stamp when a whole-device
        // migration rewrites every birthtime to one value.
        // en_US_POSIX: the stamp must be ASCII digits in
        // every locale, or it would not parse back.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmssSSS"
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
                    // b49fix2 P1-4: Data / Date values are not
                    // JSON-safe, and isValidJSONObject below would
                    // fail the whole snapshot — refusing an import
                    // over a key the user never touched. Store them
                    // in a JSON-safe form (Data as base64, Date as
                    // a timestamp). b49fix4 P1-4: the manifest is
                    // now also the durable restore source, and
                    // restoreSnapshot decodes these back per key
                    // kind — so the encoding must stay reversible.
                    if let data = value as? Data {
                        presentDefaults[key] = data.base64EncodedString()
                    } else if let date = value as? Date {
                        presentDefaults[key] = date.timeIntervalSince1970
                    } else {
                        presentDefaults[key] = value
                    }
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
                    // b49fix20 D22-17: the copy takes the file's
                    // queue when it has one — same as
                    // MigrationBackup.create (b49fix19 P2-9b): a
                    // live write landing between the copy and
                    // the import's write used to give a mixed
                    // snapshot. Payload paths have no queue and
                    // copy bare. The snapshot is taken before
                    // any import write, so taking the queue here
                    // cannot deadlock.
                    // b49fix20 O-2: the queue serialises THIS
                    // file's copy against THIS file's writes —
                    // there is no global point across files (see
                    // MigrationBackup.create).
                    let copyOne = {
                        try FileManager.default.copyItem(at: source, to: target)
                    }
                    if let queue = restoreQueue(for: relativePath) {
                        try queue.sync(execute: copyOne)
                    } else {
                        try copyOne()
                    }
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
            else {
                // b49fix6 P2-4: a snapshot that cannot get its
                // manifest must not leave a partial folder behind
                // — listSnapshots would show it as a
                // "清单无法读取" orphan row.
                try? FileManager.default.removeItem(at: dir)
                return nil
            }
            try manifestData.write(
                to: dir.appendingPathComponent("snapshot-manifest.json"),
                options: [.atomic]
            )
            return dir
        } catch {
            // b49fix6 P2-4: same as above — a failed copy or
            // manifest write (disk full is the classic case)
            // must not leave a partial folder behind.
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    // MARK: - Snapshot management (b49fix3 P1-6 / P2-17)

    /// Parses the stamp at the start of a snapshot folder
    /// name: 18 characters ("yyyyMMdd-HHmmssSSS") on folders
    /// taken since b49fix9, 15 ("yyyyMMdd-HHmmss") before —
    /// the millisecond stamp orders two snapshots taken in
    /// the same second (an import and its safety net) even
    /// when a whole-device migration rewrites every
    /// birthtime to one value, where the old second stamp
    /// tied and the order fell through to the random UUID
    /// suffix. Both formats parse; the 15-char one stays
    /// for old folders. en_US_POSIX: the stamp must be
    /// ASCII digits in every locale. Nil when the name
    /// carries no stamp (e.g. a hand-made folder). Shared
    /// by listSnapshots (ordering) and snapshotInfo
    /// (display).
    static func snapshotDate(fromName name: String) -> Date? {
        // A stamp is at least 15 characters; anything
        // shorter cannot carry one (and an empty prefix
        // must not parse — Linux Foundation accepts it).
        guard name.count >= 15 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // The 16th character decides the format: a digit
        // means a millisecond stamp, "-" means the old
        // second stamp. (Parsing the 18-char prefix of an
        // old name with the millisecond format is not
        // relied on — the discriminator is explicit.)
        if name.count >= 18,
           name[name.index(name.startIndex, offsetBy: 15)].isNumber {
            formatter.dateFormat = "yyyyMMdd-HHmmssSSS"
            if let date = formatter.date(from: String(name.prefix(18))) {
                return date
            }
        }
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: String(name.prefix(15)))
    }

    /// Lists the import snapshots under
    /// `Documents/backup_snapshots/`, newest first (by file
    /// creation date — the folder name starts with a
    /// yyyyMMdd-HHmmssSSS stamp (15-char seconds stamps on
    /// folders taken before b49fix9), which orders
    /// same-second snapshots; only two taken in the same
    /// millisecond still tie on the name, so creation date
    /// decides first). Empty when no import ever ran.
    /// b49fix4 P1-4: a snapshot is now user-restorable — the
    /// settings row offers restore per snapshot (restoreSnapshot
    /// below), on top of list + delete.
    static func listSnapshots(documentsURL: URL? = nil) -> [URL] {
        let docs = documentsURL ?? LocalStore.documentsDirectory()
        let dir = docs.appendingPathComponent(snapshotDirectoryName)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        // b49fix8 P2-9: the sort key is computed ONCE per folder
        // (creation date, then the yyyyMMdd-HHmmssSSS stamp
        // in the name), so the comparator never silently falls through
        // to the random UUID suffix in the name:
        //  * one side dateless (concurrent delete / filesystem
        //    anomaly) → the dateless folder sorts FIRST, i.e.
        //    it is treated as NEWEST. Pruning deletes from the
        //    end of this list, and a snapshot whose date cannot
        //    be read must never be pruned as "oldest" — that is
        //    how a just-taken safety net used to die. Keeping an
        //    undatable folder is the safe side; the user can
        //    still delete it by hand.
        //  * both dates equal (e.g. birthtimes rewritten to one
        //    value by a whole-device migration restore) → the
        //    name stamp still carries the original take time
        //    (folder names survive a migration), so it orders
        //    before the full name. Since b49fix9 the stamp
        //    carries milliseconds, so a tie now needs two
        //    snapshots in the same millisecond. Only when the
        //    stamps tie too does the full name decide, as a
        //    stable last resort.
        struct DatedFolder {
            var url: URL
            var creationDate: Date?
            var nameStamp: Date?
        }
        let folders = names
            .map { dir.appendingPathComponent($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { url in
                DatedFolder(
                    url: url,
                    creationDate: (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                    nameStamp: Self.snapshotDate(fromName: url.lastPathComponent)
                )
            }
        return folders.sorted { lhs, rhs in
            switch (lhs.creationDate, rhs.creationDate) {
            case let (l?, r?) where l != r:
                return l > r
            case (nil, _?):
                return true
            case (_?, nil):
                return false
            default:
                if let l = lhs.nameStamp, let r = rhs.nameStamp, l != r {
                    return l > r
                }
                return lhs.url.lastPathComponent > rhs.url.lastPathComponent
            }
        }.map { $0.url }
    }

    /// Deletes one snapshot folder. Only removes the safety net
    /// for that import — never live data.
    static func deleteSnapshot(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Snapshot restore (b49fix4 P1-4)

    /// What a user-triggered snapshot restore did. `succeeded`
    /// is false when anything failed — the UI reports the failed
    /// keys/files by name instead of claiming a full restore.
    struct SnapshotRestoreResult {
        /// Manifest-level failure (missing / unreadable /
        /// corrupt manifest); nothing was restored. `nil` means
        /// the manifest parsed.
        var manifestError: String?
        var restoredKeys: Int = 0
        var restoredFiles: Int = 0
        var failedKeys: [String] = []
        var failedFiles: [String] = []
        /// History files the restore normalised (b49fix20
        /// D22-10): file -> entries dropped because their shape
        /// could not be read by the live typed reader (raw ISO
        /// dates from a pre-fix19 snapshot).
        var historyNormalizedDropped: [String: Int] = [:]
        var succeeded: Bool {
            manifestError == nil && failedKeys.isEmpty && failedFiles.isEmpty
        }
    }

    /// One row of the snapshot list: when it was taken and what
    /// it holds. Counts come from the manifest; nil counts mean
    /// the manifest could not be read (the row still shows its
    /// date from the folder name).
    struct SnapshotInfo {
        var url: URL
        var folderName: String
        var date: Date
        var keyCount: Int?
        var fileCount: Int?
    }

    /// Reads one snapshot folder's row info: the date from the
    /// yyyyMMdd-HHmmssSSS stamp (15-char seconds stamps on
    /// folders taken before b49fix9; creation date as fallback)
    /// and the key/file counts from its manifest.
    static func snapshotInfo(at url: URL) -> SnapshotInfo {
        let name = url.lastPathComponent
        var date = Self.snapshotDate(fromName: name)
        if date == nil {
            date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        }
        var keyCount: Int?
        var fileCount: Int?
        if let manifestData = try? Data(contentsOf: url.appendingPathComponent("snapshot-manifest.json")),
           let parsed = try? JSONSerialization.jsonObject(with: manifestData, options: []),
           let manifest = parsed as? [String: Any] {
            let present = manifest["defaultsPresent"] as? [String: Any] ?? [:]
            let absent = manifest["defaultsAbsent"] as? [String] ?? []
            keyCount = present.count + absent.count
            fileCount = (manifest["filesPresent"] as? [String] ?? []).count
        }
        return SnapshotInfo(
            url: url, folderName: name, date: date ?? Date(),
            keyCount: keyCount, fileCount: fileCount
        )
    }

    /// Safety-net snapshot taken immediately BEFORE a
    /// user-triggered restore (b49fix5 P2-9): captures the
    /// CURRENT value of exactly the keys/files the target
    /// snapshot would touch, so restoring the wrong row can
    /// itself be undone by restoring this new snapshot. Returns
    /// the new snapshot dir, or nil when the safety net could
    /// not be taken (the caller still restores — the confirm
    /// dialog already warned — but says so in the result).
    /// b49fix6 P1-1: this function does NOT prune. Pruning here
    /// (keep-5) deleted the restore TARGET whenever it was the
    /// oldest snapshot — the safety net makes 6 folders, the
    /// prune drops the oldest, and the restore then reported a
    /// "corrupt manifest" for a snapshot its own safety net
    /// had just deleted. b49fix7 P1-1/P2-7: the caller prunes
    /// after every restore that changed something
    /// (performRestore) and always excludes the target —
    /// pruning only after success still deleted a snapshot on
    /// every successful restore, and pruning nothing on failure
    /// let safety nets pile up to 6, 7, 8 folders. b49fix8
    /// P2-8: the one exception is a restore that changed
    /// nothing (manifest failure, or a success that restored
    /// nothing) — it skips the prune and this safety net is
    /// deleted again (it captured a state identical to the live
    /// one), so the list is left exactly as it was. b49fix9
    /// P2-3: a FAILED restore that restored nothing is not in
    /// that exception — its zero-change is not provable, so the
    /// prune still runs there (and the net is kept).
    static func createSafetyNetSnapshot(
        for snapshotDir: URL,
        documentsURL: URL,
        defaults: UserDefaults = .standard
    ) -> URL? {
        guard let manifestData = try? Data(contentsOf: snapshotDir.appendingPathComponent("snapshot-manifest.json")),
              let parsed = try? JSONSerialization.jsonObject(with: manifestData, options: []),
              let manifest = parsed as? [String: Any]
        else { return nil }
        let present = manifest["defaultsPresent"] as? [String: Any] ?? [:]
        var keys = Array(present.keys)
        keys += (manifest["defaultsAbsent"] as? [String] ?? [])
        var files = (manifest["filesPresent"] as? [String] ?? [])
        files += (manifest["filesAbsent"] as? [String] ?? [])
        guard let dir = createSnapshot(
            defaultKeys: keys, filePaths: files,
            documentsURL: documentsURL, defaults: defaults
        ) else { return nil }
        return dir
    }

    /// Restores the pre-import state captured in one snapshot
    /// folder: defaults values from the manifest (decoded per
    /// key kind — Data from base64, section-expanded keys as
    /// bool, the rest from the export catalogue), file bytes
    /// from the folder. The snapshot folder is kept, so the same
    /// snapshot can be restored again — and pruning after a
    /// restore excludes this folder (see
    /// pruneSnapshots(excluding:)), so a restore never deletes
    /// its own target. Posts `.haoBackupImported` when anything
    /// was restored, so the app layer re-reads. Runs
    /// synchronously; the caller puts it on a background queue.
    static func restoreSnapshot(
        at snapshotDir: URL,
        documentsURL: URL,
        defaults: UserDefaults = .standard
    ) -> SnapshotRestoreResult {
        // b49fix6 P1-1: a missing manifest and a corrupt one are
        // different states — the first means the snapshot was
        // already pruned/deleted ("已被清理"), the second means
        // the folder is there but unreadable ("清单损坏"). The
        // old single message blamed the manifest for a snapshot
        // the safety-net prune had itself deleted.
        let manifestURL = snapshotDir.appendingPathComponent("snapshot-manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return SnapshotRestoreResult(manifestError: "该快照已被清理，无法恢复")
        }
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let parsed = try? JSONSerialization.jsonObject(with: manifestData, options: []),
              let manifest = parsed as? [String: Any]
        else { return SnapshotRestoreResult(manifestError: "该快照的清单损坏，无法恢复") }
        var result = SnapshotRestoreResult()
        // The kind comes from the EXPORT catalogue
        // (userDefaultsKeyKinds), not from
        // MigrationStore.kindForDefaultKey: the catalogue is the
        // union of the migration mappings + the extras (audio
        // cache, play context, lyrics keys, the five P2-39 keys),
        // and kindForDefaultKey defaults every extra to .string —
        // a bool/int/double/json/data value does not coerce as a
        // string, so the restore would fail every non-string key.
        // (Caught by the Linux harness, which failed 7 of 9
        // present keys before this fix.)
        let kinds = userDefaultsKeyKinds()
        let present = manifest["defaultsPresent"] as? [String: Any] ?? [:]
        for key in present.keys.sorted() {
            guard let raw = present[key] else {
                result.failedKeys.append(key)
                continue
            }
            // The import plan coerces section-expanded keys as
            // bool; the export catalogue has no entry for them
            // (they are discovered by scanning), so the prefix
            // branch comes first, same as planImport.
            let kind: MigrationKeyKind = key.hasPrefix(sectionExpandedPrefix)
                ? .bool : (kinds[key] ?? .string)
            guard let value = MigrationStore.coerce(raw, as: kind) else {
                result.failedKeys.append(key)
                continue
            }
            defaults.set(value, forKey: key)
            if MigrationStore.verifyDefault(key: key, kind: kind, defaults: defaults) {
                result.restoredKeys += 1
            } else {
                defaults.removeObject(forKey: key)
                result.failedKeys.append(key)
            }
        }
        for key in (manifest["defaultsAbsent"] as? [String] ?? []).sorted() {
            // b49fix5 P2-8: only count a key that actually exists
            // now. A key the snapshot says was absent — and still
            // is — was already at its pre-import state; counting
            // it inflated "已恢复 N 个设置" and posted
            // .haoBackupImported for a pure no-op restore.
            if defaults.object(forKey: key) != nil {
                defaults.removeObject(forKey: key)
                result.restoredKeys += 1
            }
        }
        let filesPresent = manifest["filesPresent"] as? [String] ?? []
        // b49fix10 P1-1: a deletion IS a restoration — a file
        // the snapshot says was absent is removed here, and
        // that removal counts toward restoredFiles, symmetric
        // with the keys side (b49fix5 P2-8 counts a removed
        // defaultsAbsent key). Before this, a delete-only
        // restore reported 0 restored files, so performRestore
        // judged it provably zero-change and deleted the
        // safety net — the only copy of the deleted file —
        // misreported "没有需要恢复的内容", and never posted
        // .haoBackupImported (the app kept showing the file
        // until the next reload).
        let fileRestore = restoreFilesFromSnapshot(
            snapshotDir: snapshotDir, documentsURL: documentsURL
        )
        result.failedFiles = fileRestore.failures
        result.restoredFiles = filesPresent.filter { !result.failedFiles.contains($0) }.count
            + fileRestore.deletedAbsent
        result.historyNormalizedDropped = fileRestore.normalizedHistory
        if result.restoredKeys + result.restoredFiles > 0 {
            NotificationCenter.default.post(name: .haoBackupImported, object: nil)
        }
        return result
    }

    /// Keeps only the newest `keeping` snapshots. Called on
    /// every successful import; the settings row also offers
    /// per-snapshot delete. b49fix7 P1-1: `excluding` keeps one
    /// folder from being DELETED — a restore must never prune
    /// the snapshot it just restored (the target is kept, so
    /// the same snapshot can be restored again), so the restore
    /// path passes its target here; the safety net is the newest
    /// folder and always survives. b49fix8 P2-7 (option a): the
    /// excluded folder still COUNTS toward `keeping` — only the
    /// act of deleting it is exempted. Round 7 removed the
    /// target from the list before counting, so a restore left
    /// 5 others + the target = 6 folders while the settings
    /// footer still said "只保留最近 5 份". Now the total is
    /// capped at `keeping` including the target, so the restore
    /// path and the import path (no excluding) agree on the
    /// total. Compared by folder name: the excluded URL may be
    /// built from a different path prefix than the listed one
    /// (symlinked tmp dirs).
    static func pruneSnapshots(keeping: Int = 5, excluding: URL? = nil, documentsURL: URL? = nil) {
        let snapshots = listSnapshots(documentsURL: documentsURL)
        let excludedName = excluding?.lastPathComponent
        let targetPresent = excludedName.map { name in
            snapshots.contains { $0.lastPathComponent == name }
        } ?? false
        // Slots for non-target folders: the target occupies one
        // of the `keeping` slots when it is in the list.
        let otherSlots = max(keeping - (targetPresent ? 1 : 0), 0)
        var keptOthers = 0
        for url in snapshots {
            if url.lastPathComponent == excludedName {
                continue // never deleted; occupies one slot
            }
            if keptOthers < otherSlots {
                keptOthers += 1
            } else {
                deleteSnapshot(at: url)
            }
        }
    }

    /// One dropped-history line per history file the restore
    /// normalised (b49fix21 D23-2, shared by b49fix22 D24-2):
    /// "影视历史有 N 条记录格式不符，已跳过。" /
    /// "直播历史有 N 条记录格式不符，已跳过。" — the same
    /// wording the import warnings use for the same drops, and
    /// the manual restore's restoreMessage (SettingsGroupsView
    /// delegates here so the wording has one home).
    static func historyDroppedLines(for normalizedHistory: [String: Int]) -> [String] {
        var lines: [String] = []
        for (path, count) in normalizedHistory.sorted(by: { $0.key < $1.key }) where count > 0 {
            let kind = path.hasPrefix("hao_video_hist") ? "影视" : "直播"
            lines.append("\(kind)历史有 \(count) 条记录格式不符，已跳过。")
        }
        return lines
    }

    /// Puts every touched value back the way the snapshot found
    /// it: defaults from the in-memory journal, files from the
    /// snapshot folder (restored, or removed when they did not
    /// exist before). The snapshot folder itself is kept.
    /// b49fix4 P2-36: returns the relative paths the file
    /// restore could not put back, so the caller can report an
    /// incomplete rollback instead of claiming "已全量回滚".
    private static func rollback(
        journal: BackupJournal,
        snapshotDir: URL,
        documentsURL: URL,
        defaults: UserDefaults,
        writtenBytes: [String: Data]? = nil,
        writtenPayloadPaths: Set<String> = []
    ) -> (failures: [String], keptLive: [String], keptLiveDefaults: [String], normalizedHistory: [String: Int]) {
        let keptLiveDefaults = journal.restore(defaults: defaults)
        let restored = restoreFilesFromSnapshot(
            snapshotDir: snapshotDir, documentsURL: documentsURL,
            writtenBytes: writtenBytes,
            writtenPayloadPaths: writtenPayloadPaths
        )
        return (restored.failures, restored.keptLive, keptLiveDefaults, restored.normalizedHistory)
    }

    /// Normalises a restored history file (b49fix20 D22-10):
    /// a snapshot taken after a fix18 import can hold raw ISO
    /// dates the live typed reader cannot decode — restoring
    /// exact bytes would reinstall the hole P1-1 closed.
    /// Returns the number of entries dropped (0 when the file
    /// needed no change). Takes the file's queue when it has
    /// one, so the re-read -> write serialises against the live
    /// writer the same way the restore did; called after the
    /// restore lands, holding no queue. Only the two history
    /// files can carry the hole — other files pass through
    /// untouched.
    static func normalizeRestoredHistory(relativePath: String, documentsURL: URL) -> Int {
        let base = String(relativePath.dropLast(".json".count))
        guard base == "hao_video_hist" || base == "hao_live_hist" else { return 0 }
        let normalizeOne = { () -> Int in
            let url = documentsURL.appendingPathComponent(relativePath)
            guard let data = try? Data(contentsOf: url),
                  let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
                  let list = parsed as? [[String: Any]]
            else { return 0 }
            let normalized = MigrationStore.normalizedHistoryEntries(list, file: base)
            guard let keptData = try? JSONSerialization.data(withJSONObject: normalized.kept, options: [.sortedKeys]),
                  let listData = try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]),
                  normalized.dropped > 0 || keptData != listData
            else { return 0 }
            try? keptData.write(to: url, options: [.atomic])
            return normalized.dropped
        }
        if let queue = restoreQueue(for: relativePath) {
            return queue.sync(execute: normalizeOne)
        }
        return normalizeOne()
    }

    /// Restores the files captured in a snapshot folder, from
    /// the manifest. Returns the relative paths it could NOT
    /// restore (copy failure, removal failure, or an unreadable
    /// manifest — in that last case a single descriptive entry,
    /// since the manifest is the only record of what was
    /// captured) plus the number of files it actually DELETED
    /// for the filesAbsent list. b49fix4 P1-4/P2-36: the old
    /// rollback swallowed every failure with `catch { continue }`
    /// / `try?` and still reported "已全量回滚". b49fix10 P1-1:
    /// only a removal that actually happened counts — a file
    /// that was never there needs no restoring, same rule as
    /// the keys side (b49fix5 P2-8). Shared by the in-import
    /// rollback and by the user-triggered snapshot restore.
    ///
    /// b49fix19 P1-4: `writtenBytes` is what the import wrote,
    /// keyed by relative path — passed by the in-import
    /// rollback only (nil = a user-triggered restore, which
    /// restores EXACTLY the snapshot). With it, the restore
    /// preserves live increments made during the import (see
    /// MigrationStore.restoredPreservingLive) instead of
    /// writing the snapshot bytes back whole, which used to
    /// wipe every live write that landed during the import.
    /// Files whose live version replaced the import's write
    /// are kept and reported in `keptLive`.
    static func restoreFilesFromSnapshot(
        snapshotDir: URL,
        documentsURL: URL,
        writtenBytes: [String: Data]? = nil,
        writtenPayloadPaths: Set<String> = []
    ) -> (failures: [String], deletedAbsent: Int, keptLive: [String], normalizedHistory: [String: Int]) {
        guard let manifestData = try? Data(contentsOf: snapshotDir.appendingPathComponent("snapshot-manifest.json")),
              let parsed = try? JSONSerialization.jsonObject(with: manifestData, options: []),
              let manifest = parsed as? [String: Any]
        else { return (["快照清单（snapshot-manifest.json）无法读取"], 0, [], [:]) }
        var failures: [String] = []
        var deletedAbsent = 0
        var keptLive: [String] = []
        var normalizedHistory: [String: Int] = [:]
        for relativePath in (manifest["filesPresent"] as? [String] ?? []) {
            // b49fix17 P2-3: the restore takes the file's queue
            // when it has one — a queued writer landing between
            // the restore's remove and copy used to write back
            // "imported content + new event", cancelling the
            // rollback for that file. The rollback is never
            // called while holding one of these queues, so
            // taking it here cannot deadlock. Payload paths
            // (music_downloads/..., local_music/...) have no
            // queue and restore bare.
            let restoreOne = { () -> (restored: Bool, kept: Bool) in
                if let writtenBytes = writtenBytes {
                    // b49fix20 D22-5/D22-14: only files this
                    // round actually wrote are restored — a
                    // file the snapshot captured but the import
                    // never reached (failed on an earlier file)
                    // keeps its live content instead of being
                    // prior-restored, and a payload file
                    // extracted this round counts as written
                    // (tracked separately — expectedCollectionBytes
                    // only holds collections).
                    guard writtenBytes[relativePath] != nil || writtenPayloadPaths.contains(relativePath) else {
                        return (true, false)
                    }
                    // Preserving restore (in-import rollback):
                    // prior + live-added entries, or keep the
                    // live file when it replaced the import's
                    // write after it landed.
                    let target = documentsURL.appendingPathComponent(relativePath)
                    let prior = try? Data(contentsOf: snapshotDir.appendingPathComponent(relativePath))
                    let current = try? Data(contentsOf: target)
                    let restored = MigrationStore.restoredPreservingLive(
                        prior: prior, written: writtenBytes[relativePath], current: current,
                        file: String(relativePath.dropLast(".json".count)),
                        kind: restoreKind(for: relativePath),
                        // b49fix21 D23-6: the live value the merge
                        // read at merge time (nil when this import
                        // never merged the file — the old rule).
                        liveAtMerge: MigrationStore.liveAtMerge(for: String(relativePath.dropLast(".json".count)))
                    )
                    switch restored {
                    case .data(let bytes):
                        do {
                            try bytes.write(to: target, options: [.atomic])
                            return (true, false)
                        } catch {
                            return (false, false)
                        }
                    case .keepCurrent:
                        return (true, true)
                    case .remove:
                        if FileManager.default.fileExists(atPath: target.path) {
                            do {
                                try FileManager.default.removeItem(at: target)
                            } catch {
                                return (false, false)
                            }
                        }
                        return (true, false)
                    }
                }
                return (restorePresentFile(relativePath: relativePath, snapshotDir: snapshotDir, documentsURL: documentsURL), false)
            }
            let outcome: (restored: Bool, kept: Bool)
            if let queue = restoreQueue(for: relativePath) {
                outcome = queue.sync(execute: restoreOne)
            } else {
                outcome = restoreOne()
            }
            if !outcome.restored {
                failures.append(relativePath)
            } else if outcome.kept {
                keptLive.append(relativePath)
            } else {
                // b49fix20 D22-10: a restored history file is
                // normalised (see normalizeRestoredHistory) —
                // the snapshot may hold raw ISO dates the live
                // typed reader cannot decode.
                let dropped = normalizeRestoredHistory(relativePath: relativePath, documentsURL: documentsURL)
                if dropped > 0 { normalizedHistory[relativePath] = dropped }
            }
        }
        for relativePath in (manifest["filesAbsent"] as? [String] ?? []) {
            let target = documentsURL.appendingPathComponent(relativePath)
            // Only a removal that actually happens counts: a
            // file that was never there needs no restoring
            // (same rule as the keys side, b49fix5 P2-8), and
            // a failed removal is a failure, not a restore.
            if FileManager.default.fileExists(atPath: target.path) {
                if let writtenBytes = writtenBytes {
                    // b49fix20 D22-14(b): a file the snapshot
                    // says was absent, that the import never
                    // wrote, but live created during the import
                    // (a first-ever video favourite) is NOT
                    // deleted by the rollback — it keeps its
                    // live content. Only files this round wrote
                    // (or payload files extracted this round) go
                    // through the preserving restore below.
                    guard writtenBytes[relativePath] != nil || writtenPayloadPaths.contains(relativePath) else {
                        continue
                    }
                    // Preserving restore (in-import rollback):
                    // the file did not exist before the import —
                    // keep only the live entries added after the
                    // import created it; delete it when there are
                    // none.
                    let current = try? Data(contentsOf: target)
                    let restored = MigrationStore.restoredPreservingLive(
                        prior: nil, written: writtenBytes[relativePath], current: current,
                        file: String(relativePath.dropLast(".json".count)),
                        kind: restoreKind(for: relativePath),
                        // b49fix21 D23-6: the live value the merge
                        // read at merge time (nil when this import
                        // never merged the file — the old rule).
                        liveAtMerge: MigrationStore.liveAtMerge(for: String(relativePath.dropLast(".json".count)))
                    )
                    switch restored {
                    case .data(let bytes):
                        do {
                            try bytes.write(to: target, options: [.atomic])
                        } catch {
                            failures.append(relativePath)
                        }
                    case .keepCurrent:
                        keptLive.append(relativePath)
                    case .remove:
                        let removed: Bool
                        if let queue = restoreQueue(for: relativePath) {
                            removed = queue.sync {
                                do {
                                    try FileManager.default.removeItem(at: target)
                                    return true
                                } catch {
                                    return false
                                }
                            }
                        } else {
                            do {
                                try FileManager.default.removeItem(at: target)
                                removed = true
                            } catch {
                                removed = false
                            }
                        }
                        if removed {
                            deletedAbsent += 1
                        } else {
                            failures.append(relativePath)
                        }
                    }
                    continue
                }
                let removed: Bool
                if let queue = restoreQueue(for: relativePath) {
                    removed = queue.sync {
                        do {
                            try FileManager.default.removeItem(at: target)
                            return true
                        } catch {
                            return false
                        }
                    }
                } else {
                    do {
                        try FileManager.default.removeItem(at: target)
                        removed = true
                    } catch {
                        removed = false
                    }
                }
                if removed {
                    deletedAbsent += 1
                } else {
                    failures.append(relativePath)
                }
            }
        }
        return (failures, deletedAbsent, keptLive, normalizedHistory)
    }

    /// The restore kind of one relative path (b49fix19 P1-4):
    /// merge files restore as prior + live-added entries,
    /// whole-file files restore as prior bytes unless a live
    /// writer replaced the import's write. musicQueue is a
    /// whole-file file here (its live-wins rule makes a merge
    /// restore meaningless — a switch after the write
    /// legitimately replaced it, so it is kept, not merged).
    private static func restoreKind(for relativePath: String) -> MigrationStore.RestoreKind {
        let base = String(relativePath.dropLast(".json".count))
        guard concurrentlyWrittenCollections.contains(base),
              base != "musicQueue",
              let shape = MigrationStore.expectedCollectionShape(for: base)
        else { return .wholeFile }
        switch shape {
        case .list: return .mergeList
        case .dict: return .mergeDict
        case .stringList: return .mergeStringList
        }
    }

    /// The serial queue a snapshot restore takes for one
    /// relative path (b49fix17 P2-3): only top-level
    /// collection files have one; payload files restore bare.
    private static func restoreQueue(for relativePath: String) -> DispatchQueue? {
        guard !relativePath.contains("/"), relativePath.hasSuffix(".json") else { return nil }
        return MigrationStore.writeQueue(forCollection: String(relativePath.dropLast(".json".count)))
    }

    /// Restores one present file from the snapshot folder.
    /// Returns false when the copy could not be put back.
    private static func restorePresentFile(
        relativePath: String, snapshotDir: URL, documentsURL: URL
    ) -> Bool {
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
            return true
        } catch {
            return false
        }
    }
}

/// The prior value of every defaults key one import attempt
/// changed, so a failure can put each key back (including keys
/// that did not exist before the attempt). File priors live in
/// the durable snapshot folder; only defaults need the journal.
private struct BackupJournal {
    var priorDefaults: [(key: String, value: Any?)] = []
    /// Defaults this attempt actually wrote AND verified
    /// (b49fix21 D23-9 — same rule as MigrationJournal):
    /// key -> the written value. The restore only ever puts
    /// back keys in this map, and keeps the live value when
    /// current != written. `recordDefault` stays BEFORE the
    /// write (it must read the PRIOR value); the
    /// written-marking below is what moves after success.
    var writtenDefaults: [String: Any] = [:]

    mutating func recordDefault(key: String, defaults: UserDefaults) {
        if priorDefaults.contains(where: { $0.key == key }) { return }
        priorDefaults.append((key: key, value: defaults.object(forKey: key)))
    }

    /// Marks one default as successfully written + verified.
    /// Called by the import loop after its verify passes.
    mutating func recordWrittenDefault(key: String, value: Any) {
        writtenDefaults[key] = value
    }

    /// Restores the journalled prior defaults — only those this
    /// attempt actually wrote + verified (b49fix21 D23-9), and
    /// only when the live value still equals the written one.
    /// Returns the defaults whose live value was kept.
    func restore(defaults: UserDefaults) -> [String] {
        var keptLiveDefaults: [String] = []
        for prior in priorDefaults {
            guard let writtenValue = writtenDefaults[prior.key] else { continue }
            guard MigrationStore.defaultsValuesEqual(defaults.object(forKey: prior.key), writtenValue) else {
                keptLiveDefaults.append(prior.key)
                continue
            }
            if let value = prior.value {
                defaults.set(value, forKey: prior.key)
            } else {
                defaults.removeObject(forKey: prior.key)
            }
        }
        return keptLiveDefaults
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
            // b49sweep: the export lives in Documents, not tmp —
            // a tmp zip could be reclaimed before the user
            // shares it, and it was invisible in the Files app.
            // The test seam (documentsURL) still decides the
            // directory under test; production uses the real
            // container. The file name already carries a UUID,
            // so repeated exports never collide.
            let destination = (self.documentsURL ?? LocalStore.documentsDirectory())
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
                    warnings: detail.warnings,
                    rollbackFailures: detail.rollbackFailures,
                    nothingWritten: detail.nothingWritten
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

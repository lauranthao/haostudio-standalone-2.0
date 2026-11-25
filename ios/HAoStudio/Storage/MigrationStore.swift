// HAo Studio 2.0 — migration store (S1).
//
// Reads the Flutter 1.1.6 migration snapshot (route A) or a schema-1
// backup JSON (route B) and writes every key into the Swift storage
// the mapping table in docs/storage-mapping.md promises. Keys keep
// their Flutter Hive names; only the storage mechanism changes.
//
// Rules enforced here (plan section 5.5):
// - Backup before writing: the snapshot file and the current Swift
//   storage are copied to Documents/migration_backup/ first.
// - Any failure rolls the whole migration back to the pre-migration
//   state; the done flag is set only after per-key verification.
// - A missing snapshot means a fresh install: there is no old
//   data to migrate, so the migration IS complete and the done
//   flag is set — the My page must not show the "no old data"
//   notice forever on a brand-new install (b49 sweep P1). A
//   corrupt or wrong-version snapshot is skipped, never fatal:
//   the app starts on defaults and the My page shows the
//   "no old data" notice. Nothing is deleted: the Hive box and the
//   snapshot file stay on disk until the user clears them by hand.
// - A bad-typed key is skipped, never fatal; unknown keys are kept
//   apart in migration_unknown_keys.json instead of being dropped.
//
// Synchronous by design: the project pins Swift 5.0 and the launch
// path runs this before the theme store loads, so the first frame
// already uses the migrated theme.

import Foundation

/// The value shape a snapshot key carries.
enum MigrationKeyKind {
    case string
    case int
    case double
    case bool
    case json
    case intList
    case doubleList
}

/// Where one Flutter key lands in Swift storage.
enum MigrationDestination {
    /// UserDefaults, under the same Flutter key name.
    case userDefaults
    /// A Documents JSON collection file, named without extension.
    case collectionFile(String)
    /// Emby config: the token goes to the Keychain, the rest to a
    /// JSON collection file. See MigrationStore.applyEmby.
    case emby
}

/// One row of the mapping table. The table is the contract: a key
/// missing here is treated as unknown and isolated, never dropped.
struct MigrationKeyMapping {
    let key: String
    let kind: MigrationKeyKind
    let destination: MigrationDestination
}

/// A key family whose members share one merged file (resume positions,
/// daily picks, listen shards). The snapshot key stays the entry key
/// inside the merged file.
struct MigrationPrefixRule {
    let prefix: String
    let fileName: String
    let kind: MigrationKeyKind
}

enum MigrationOutcome {
    case migrated
    case alreadyDone
    case noSnapshot
    case invalidSnapshot
    case failed
}

/// Counts for one migration attempt. A key is accounted for when it
/// is migrated, knowingly skipped, or isolated as unknown; only a
/// write or verification failure makes the whole attempt fail.
struct MigrationReport {
    let outcome: MigrationOutcome
    let totalKeys: Int
    let migratedKeys: Int
    let skippedKeys: Int
    let unknownKeys: Int
    let failedKeys: Int
    let skippedKeyNames: [String]
    let unknownKeyNames: [String]
    let detail: String

    static func empty(_ outcome: MigrationOutcome, detail: String) -> MigrationReport {
        MigrationReport(
            outcome: outcome, totalKeys: 0, migratedKeys: 0,
            skippedKeys: 0, unknownKeys: 0, failedKeys: 0,
            skippedKeyNames: [], unknownKeyNames: [], detail: detail
        )
    }
}

enum MigrationStore {
    static let snapshotFileName = "migration_snapshot.json"
    static let backupDirectoryName = "migration_backup"
    static let doneKey = "hao_migration_done_v1"
    static let stateKey = "hao_migration_state"
    static let noticeDismissedKey = "hao_migration_notice_dismissed"
    static let unknownKeysFileName = "migration_unknown_keys"
    static let snapshotSchemaVersion = 1
    static let backupSchemaVersion = 1

    static let stateDone = "done"
    static let stateNoSnapshot = "noSnapshot"
    static let stateInvalidSnapshot = "invalidSnapshot"
    static let stateFailed = "failed"
    static let stateNotAttempted = "notAttempted"

    /// Test-only fault injection: when set, the write for this key
    /// fails on purpose so tests can prove rollback works. Never
    /// set in production code.
    static var testFailOnKey: String?

    // MARK: - Mapping table (docs/storage-mapping.md, same rows)

    static let mappings: [MigrationKeyMapping] = [
        // Playback / player preference.
        MigrationKeyMapping(key: "videoPlayerKey", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hapticsEnabled", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "audioMixWithOthers", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "autoResumeLastPlayback", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "preferResolution", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "liveCrashStage", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "skippedVersion", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "lastUpdateCheckAt", kind: .int, destination: .userDefaults),
        MigrationKeyMapping(key: "autoUpdateCheck", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "engineSectionExpanded", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "playbackSectionExpanded", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "haoThemeId", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "haoThemeMode", kind: .string, destination: .userDefaults),
        // Music: scalars.
        MigrationKeyMapping(key: "musicQuality", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "musicPlazaPf", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "musicSpeed", kind: .double, destination: .userDefaults),
        MigrationKeyMapping(key: "musicSearchPlatform", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "curListId", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "playMode", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "musicPlaylistsExpanded", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "musicRecentExpanded", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "musicSleepCustomMinutes", kind: .int, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_music_normalization_enabled", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_music_normalization_strength", kind: .int, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_music_fade_enabled", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_music_lyric_offset_ms", kind: .int, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_music_lyric_show_translation", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_music_playback_cache_enabled", kind: .bool, destination: .userDefaults),
        // Music: collections (JSON strings in Hive, files in Swift).
        MigrationKeyMapping(key: "hao_lists", kind: .json, destination: .collectionFile("hao_lists")),
        MigrationKeyMapping(key: "hao_fav", kind: .json, destination: .collectionFile("hao_fav")),
        MigrationKeyMapping(key: "hao_recent", kind: .json, destination: .collectionFile("hao_recent")),
        MigrationKeyMapping(key: "hao_listen", kind: .json, destination: .collectionFile("hao_listen")),
        MigrationKeyMapping(key: "hao_music_search_hist", kind: .json, destination: .collectionFile("hao_music_search_hist")),
        MigrationKeyMapping(key: "hao_cover_cache", kind: .json, destination: .collectionFile("hao_cover_cache")),
        MigrationKeyMapping(key: "hao_lyrics", kind: .json, destination: .collectionFile("hao_lyrics")),
        MigrationKeyMapping(key: "musicQueue", kind: .json, destination: .collectionFile("musicQueue")),
        MigrationKeyMapping(key: "musicDownloads", kind: .json, destination: .collectionFile("musicDownloads")),
        MigrationKeyMapping(key: "musicResume", kind: .json, destination: .collectionFile("musicResume")),
        MigrationKeyMapping(key: "fmDislikedIds", kind: .json, destination: .collectionFile("fmDislikedIds")),
        MigrationKeyMapping(key: "hao_feature_cover_plaza", kind: .json, destination: .collectionFile("hao_feature_cover_plaza")),
        MigrationKeyMapping(key: "hao_feature_cover_charts", kind: .json, destination: .collectionFile("hao_feature_cover_charts")),
        MigrationKeyMapping(key: "hao_music_bookmarks", kind: .json, destination: .collectionFile("hao_music_bookmarks")),
        MigrationKeyMapping(key: "hao_music_loudness_cache", kind: .json, destination: .collectionFile("hao_music_loudness_cache")),
        MigrationKeyMapping(key: "hao_music_sources", kind: .json, destination: .collectionFile("hao_music_sources")),
        MigrationKeyMapping(key: "hao_local_music", kind: .json, destination: .collectionFile("hao_local_music")),
        MigrationKeyMapping(key: "hao_music_queue_memory", kind: .json, destination: .collectionFile("hao_music_queue_memory")),
        MigrationKeyMapping(key: "hao_resolver_speed", kind: .json, destination: .collectionFile("hao_resolver_speed")),
        MigrationKeyMapping(key: "hao_sa_xh_device", kind: .string, destination: .userDefaults),
        // Appearance.
        MigrationKeyMapping(key: "hao_wallpaper_enabled", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_wallpaper_paths", kind: .json, destination: .collectionFile("hao_wallpaper_paths")),
        MigrationKeyMapping(key: "hao_wallpaper_current", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_wallpaper_v115_off_once", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_bgcolor_enabled", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_bgcolor_hex", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_tabbar_accent", kind: .int, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_tabbar_accent_presets", kind: .intList, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_custom_font_family", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_custom_font_name", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_custom_font_path", kind: .string, destination: .userDefaults),
        // Video / VOD: scalars.
        MigrationKeyMapping(key: "hao_video_auto_next", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_playback_rate", kind: .double, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_double_tap_seconds", kind: .int, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_dialogue_boost", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_spoiler_hide_synopsis", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_spoiler_blur_unwatched", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_audio_only", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_sleep_custom_minutes", kind: .int, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_sleep_episode_count", kind: .int, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_video_fit", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_super_resolution", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_skip_intro_mode", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_interpolation", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_sdr_to_hdr", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_subtitle_delay", kind: .double, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_subtitle_font_size", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_subtitle_color", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_subtitle_position", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_danmaku_occlusion_avoidance", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_dv_p8_downgrade", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_low_memory_mode", kind: .string, destination: .userDefaults),
        // Video / VOD: collections.
        MigrationKeyMapping(key: "hao_vod_metadata_overrides", kind: .json, destination: .collectionFile("hao_vod_metadata_overrides")),
        MigrationKeyMapping(key: "hao_video_category_prefs", kind: .json, destination: .collectionFile("hao_video_category_prefs")),
        MigrationKeyMapping(key: "hao_vod_skip_intro_durations", kind: .json, destination: .collectionFile("hao_vod_skip_intro_durations")),
        MigrationKeyMapping(key: "hao_video_home", kind: .json, destination: .collectionFile("hao_video_home")),
        MigrationKeyMapping(key: "hao_video_hist", kind: .json, destination: .collectionFile("hao_video_hist")),
        MigrationKeyMapping(key: "hao_video_fav", kind: .json, destination: .collectionFile("hao_video_fav")),
        MigrationKeyMapping(key: "hao_video_search_hist", kind: .json, destination: .collectionFile("hao_video_search_hist")),
        MigrationKeyMapping(key: "hao_douban_detail", kind: .json, destination: .collectionFile("hao_douban_detail")),
        MigrationKeyMapping(key: "hao_douban_idmap", kind: .json, destination: .collectionFile("hao_douban_idmap")),
        MigrationKeyMapping(key: "hao_douban_no_suggest", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_sa_video", kind: .json, destination: .collectionFile("hao_sa_video")),
        MigrationKeyMapping(key: "hao_sa_video_rev", kind: .int, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_emby_config", kind: .json, destination: .emby),
        MigrationKeyMapping(key: "hao_video_tab_mode", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_emby_home", kind: .json, destination: .collectionFile("hao_emby_home")),
        // Live.
        MigrationKeyMapping(key: "hao_live_sources", kind: .json, destination: .collectionFile("hao_live_sources")),
        MigrationKeyMapping(key: "hao_live_hist", kind: .json, destination: .collectionFile("hao_live_hist")),
        MigrationKeyMapping(key: "hao_live_hist_limit", kind: .int, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_live_hist_retention_days", kind: .int, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_live_follows", kind: .json, destination: .collectionFile("hao_live_follows")),
        MigrationKeyMapping(key: "hao_live_search_hist", kind: .json, destination: .collectionFile("hao_live_search_hist")),
        MigrationKeyMapping(key: "hao_live_hidden_platforms", kind: .json, destination: .collectionFile("hao_live_hidden_platforms")),
        MigrationKeyMapping(key: "hao_live_cellular_downgrade", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_live_clock_corner", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_live_volume_boost_pct", kind: .int, destination: .userDefaults),
        // Danmaku.
        MigrationKeyMapping(key: "hao_danmaku_enabled", kind: .json, destination: .collectionFile("hao_danmaku_enabled")),
        MigrationKeyMapping(key: "hao_danmaku_font_size", kind: .double, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_dm_block", kind: .json, destination: .collectionFile("hao_dm_block")),
        MigrationKeyMapping(key: "hao_danmaku_list_style", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_danmaku_list_spacing", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_danmaku_show_names", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_danmaku_similarity", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_danmaku_similarity_threshold", kind: .int, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_danmaku_block_emote", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_danmaku_block_long", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_danmaku_block_long_len", kind: .int, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_danmaku_douyu_bot", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_danmaku_opacity", kind: .double, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_danmaku_area", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_danmaku_stroke", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_danmaku_stroke_width", kind: .double, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_danmaku_speed", kind: .double, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_danmaku_max_count", kind: .int, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_danmaku_color_mode", kind: .string, destination: .userDefaults),
        // LX scripts.
        MigrationKeyMapping(key: "hao_lx_disabled", kind: .json, destination: .collectionFile("hao_lx_disabled")),
        MigrationKeyMapping(key: "hao_lx_explicit_enabled", kind: .json, destination: .collectionFile("hao_lx_explicit_enabled")),
        MigrationKeyMapping(key: "hao_lx_custom", kind: .json, destination: .collectionFile("hao_lx_custom")),
        MigrationKeyMapping(key: "hao_lx_deleted_bundled", kind: .json, destination: .collectionFile("hao_lx_deleted_bundled")),
        MigrationKeyMapping(key: "hao_lx_order", kind: .json, destination: .collectionFile("hao_lx_order")),
        // Equalizer.
        MigrationKeyMapping(key: "hao_eq_enabled", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_eq_band_gains", kind: .doubleList, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_eq_preset", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_eq_custom_name", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_eq_preamp", kind: .double, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_eq_custom_presets", kind: .json, destination: .collectionFile("hao_eq_custom_presets")),
        MigrationKeyMapping(key: "hao_eq_autoeq_name", kind: .string, destination: .userDefaults),
    ]

    /// Key families that merge into one file instead of one key per
    /// file. A snapshot may hold any number of members.
    static let prefixRules: [MigrationPrefixRule] = [
        MigrationPrefixRule(prefix: "haoVodProg:", fileName: "haoVodProg", kind: .double),
        MigrationPrefixRule(prefix: "hao_daily_", fileName: "hao_daily", kind: .json),
        MigrationPrefixRule(prefix: "hao_listen_", fileName: "hao_listen", kind: .json),
    ]

    /// Key families that are deliberately not migrated. Play-URL
    /// cache entries carry a 1 hour TTL and signed CDN URLs, so by
    /// the time 2.0 first launches they are expired by construction.
    static let ignoredPrefixes: [String] = ["hao_play_url_cache:"]

    static func mapping(for key: String) -> MigrationKeyMapping? {
        mappings.first { $0.key == key }
    }

    static func prefixRule(for key: String) -> MigrationPrefixRule? {
        prefixRules.first { key.hasPrefix($0.prefix) }
    }

    static func isIgnored(_ key: String) -> Bool {
        ignoredPrefixes.contains { key.hasPrefix($0) }
    }

    // MARK: - State for the UI

    static func migrationState(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: stateKey) ?? stateNotAttempted
    }

    static func isMigrationDone(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: doneKey)
    }

    /// True when the My page should show the "no old data" notice:
    /// migration never completed and the user has not dismissed it.
    /// The notice is text only; the backup import itself lands in S6.
    static func migrationNoticeNeeded(defaults: UserDefaults = .standard) -> Bool {
        !isMigrationDone(defaults: defaults)
            && !defaults.bool(forKey: noticeDismissedKey)
    }

    static func dismissMigrationNotice(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: noticeDismissedKey)
    }

    // MARK: - Route A: snapshot on first launch

    /// Runs the snapshot migration once. Safe to call on every
    /// launch: after success it returns alreadyDone without work.
    /// The caller passes the Documents URL only in tests; production
    /// always uses the current container.
    static func runIfNeeded(
        documentsURL: URL? = nil,
        defaults: UserDefaults = .standard
    ) -> MigrationReport {
        if isMigrationDone(defaults: defaults) {
            return MigrationReport.empty(.alreadyDone, detail: "migration already done")
        }
        let docs = documentsURL ?? LocalStore.documentsDirectory()
        let snapshotURL = docs.appendingPathComponent(snapshotFileName)
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            // b49 sweep P1: no snapshot = fresh install, no old
            // data to migrate — the migration IS complete. Set
            // the done flag so the My page stops showing the
            // "旧版数据" notice on every launch; the state stays
            // noSnapshot (the truthful outcome), only the flag
            // the notice checks is set.
            defaults.set(true, forKey: doneKey)
            defaults.set(stateNoSnapshot, forKey: stateKey)
            return MigrationReport.empty(.noSnapshot, detail: "no snapshot file")
        }
        guard let rawData = try? Data(contentsOf: snapshotURL),
              let parsed = try? JSONSerialization.jsonObject(with: rawData, options: []),
              let root = parsed as? [String: Any]
        else {
            defaults.set(stateInvalidSnapshot, forKey: stateKey)
            return MigrationReport.empty(.invalidSnapshot, detail: "snapshot is not valid JSON")
        }
        guard let data = validatedData(from: root) else {
            defaults.set(stateInvalidSnapshot, forKey: stateKey)
            return MigrationReport.empty(.invalidSnapshot, detail: "snapshot envelope invalid")
        }
        let report = importData(data, documentsURL: docs, defaults: defaults, markDone: true)
        switch report.outcome {
        case .migrated, .alreadyDone:
            defaults.set(stateDone, forKey: stateKey)
        case .failed:
            defaults.set(stateFailed, forKey: stateKey)
        case .noSnapshot, .invalidSnapshot:
            defaults.set(stateInvalidSnapshot, forKey: stateKey)
        }
        return report
    }

    // MARK: - Route B: schema-1 backup JSON import (merge, not replace)

    /// Imports a backup JSON string with the Flutter envelope
    /// (schema, app, version, exportedAt, entries, data). Keys
    /// absent from the backup are kept, never deleted. Bad-typed
    /// keys are skipped, never fatal. Shares the engine with route A.
    static func importBackupJSON(
        _ jsonString: String,
        documentsURL: URL? = nil,
        defaults: UserDefaults = .standard
    ) -> MigrationReport {
        guard let rawData = jsonString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: rawData, options: []),
              let root = parsed as? [String: Any]
        else {
            return MigrationReport.empty(.invalidSnapshot, detail: "backup is not valid JSON")
        }
        guard let data = validatedData(from: root) else {
            return MigrationReport.empty(.invalidSnapshot, detail: "backup envelope invalid")
        }
        let docs = documentsURL ?? LocalStore.documentsDirectory()
        return importData(data, documentsURL: docs, defaults: defaults, markDone: true)
    }

    /// Envelope validation shared by both routes. Schema must be 1.
    /// appVersion, when present, must be a 1.x Flutter build; an
    /// absent version is accepted so an older snapshot writer still
    /// migrates. Data must be a non-empty dictionary.
    static func validatedData(from root: [String: Any]) -> [String: Any]? {
        guard let schemaNumber = root["schema"] as? NSNumber,
              CFGetTypeID(schemaNumber) != CFBooleanGetTypeID(),
              schemaNumber.intValue == snapshotSchemaVersion
        else {
            return nil
        }
        if let version = root["appVersion"] as? String, !version.hasPrefix("1.") {
            return nil
        }
        guard let data = root["data"] as? [String: Any], !data.isEmpty else {
            return nil
        }
        return data
    }

    // MARK: - Shared engine: plan, backup, apply, verify, roll back

    /// Applies one data dictionary. Returns failed without writing
    /// anything when the pre-write backup cannot be created.
    static func importData(
        _ data: [String: Any],
        documentsURL: URL,
        defaults: UserDefaults,
        markDone: Bool
    ) -> MigrationReport {
        // 1. Plan: coerce every key now, before touching storage.
        var defaultWrites: [(key: String, value: Any)] = []
        var fileWrites: [String: Any] = [:]
        var mergedFiles: [String: [String: Any]] = [:]
        var listenEntries: [[String: Any]] = []
        var embyConfig: [String: Any]?
        var embyApiKey: String?
        var embyTokenSkipped = false
        var skipped: [String] = []
        var unknown: [String: Any] = [:]

        for key in data.keys.sorted() {
            guard let rawValue = data[key] else { continue }
            if let entry = mapping(for: key) {
                guard let coerced = coerce(rawValue, as: entry.kind) else {
                    skipped.append(key)
                    continue
                }
                switch entry.destination {
                case .userDefaults:
                    defaultWrites.append((key: key, value: coerced))
                case .collectionFile(let name):
                    fileWrites[name] = coerced
                case .emby:
                    if let config = coerced as? [String: Any] {
                        embyConfig = config
                        embyApiKey = config["apiKey"] as? String
                    } else {
                        skipped.append(key)
                    }
                }
            } else if let rule = prefixRule(for: key) {
                guard let coerced = coerce(rawValue, as: rule.kind) else {
                    skipped.append(key)
                    continue
                }
                if rule.fileName == "hao_listen" {
                    if let list = coerced as? [[String: Any]] {
                        listenEntries.append(contentsOf: list)
                    } else if let single = coerced as? [String: Any] {
                        listenEntries.append(single)
                    } else {
                        skipped.append(key)
                    }
                } else {
                    var entries = mergedFiles[rule.fileName] ?? [:]
                    entries[key] = coerced
                    mergedFiles[rule.fileName] = entries
                }
            } else if isIgnored(key) {
                skipped.append(key)
            } else {
                unknown[key] = rawValue
            }
        }

        // 2. Backup: snapshot file plus every Swift value about to
        // change, copied under migration_backup with a timestamp.
        let backup = MigrationBackup(documentsURL: documentsURL, defaults: defaults)
        var backupFileNames: Set<String> = Set(fileWrites.keys)
        backupFileNames.formUnion(mergedFiles.keys)
        if !listenEntries.isEmpty {
            backupFileNames.insert("hao_listen")
        }
        if embyConfig != nil {
            backupFileNames.insert("hao_emby_config")
        }
        if !unknown.isEmpty {
            backupFileNames.insert(unknownKeysFileName)
        }
        guard backup.create(
            defaultKeys: defaultWrites.map { $0.key },
            fileNames: backupFileNames
        ) else {
            return failReport(
                total: data.count, migrated: 0, skipped: skipped,
                unknown: Array(unknown.keys), detail: "pre-write backup failed"
            )
        }

        // 3. Apply, journaling the prior value of everything written.
        var journal = MigrationJournal()
        var appliedDefaults: [String] = []
        var appliedFiles: [String] = []
        let priorEmbyApiKey: String? = KeychainStore.loadEmbyApiKey()
        var wroteEmbyKeychain = false

        for write in defaultWrites {
            if testFailOnKey == write.key {
                rollback(journal: journal, priorEmbyApiKey: priorEmbyApiKey,
                         wroteEmbyKeychain: wroteEmbyKeychain,
                         documentsURL: documentsURL, defaults: defaults)
                return failReport(
                    total: data.count, migrated: appliedDefaults.count + appliedFiles.count,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "write failed for \(write.key)"
                )
            }
            journal.recordDefault(key: write.key, defaults: defaults)
            defaults.set(write.value, forKey: write.key)
            appliedDefaults.append(write.key)
        }

        for name in fileWrites.keys.sorted() {
            guard let value = fileWrites[name] else { continue }
            if testFailOnKey == name {
                rollback(journal: journal, priorEmbyApiKey: priorEmbyApiKey,
                         wroteEmbyKeychain: wroteEmbyKeychain,
                         documentsURL: documentsURL, defaults: defaults)
                return failReport(
                    total: data.count, migrated: appliedDefaults.count + appliedFiles.count,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "write failed for \(name)"
                )
            }
            journal.recordFile(name: name, documentsURL: documentsURL)
            if !writeJSONFile(name: name, value: value, documentsURL: documentsURL) {
                rollback(journal: journal, priorEmbyApiKey: priorEmbyApiKey,
                         wroteEmbyKeychain: wroteEmbyKeychain,
                         documentsURL: documentsURL, defaults: defaults)
                return failReport(
                    total: data.count, migrated: appliedDefaults.count + appliedFiles.count,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "write failed for \(name)"
                )
            }
            appliedFiles.append(name)
        }

        for name in mergedFiles.keys.sorted() {
            guard let entries = mergedFiles[name] else { continue }
            journal.recordFile(name: name, documentsURL: documentsURL)
            let existing = readJSONDictionary(name: name, documentsURL: documentsURL)
            var merged = existing
            for entry in entries {
                merged[entry.key] = entry.value
            }
            if name == "haoVodProg" && merged.count > 200 {
                merged = Dictionary(uniqueKeysWithValues: Array(merged.prefix(200)))
            }
            if !writeJSONFile(name: name, value: merged, documentsURL: documentsURL) {
                rollback(journal: journal, priorEmbyApiKey: priorEmbyApiKey,
                         wroteEmbyKeychain: wroteEmbyKeychain,
                         documentsURL: documentsURL, defaults: defaults)
                return failReport(
                    total: data.count, migrated: appliedDefaults.count + appliedFiles.count,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "write failed for \(name)"
                )
            }
            appliedFiles.append(name)
        }

        if !listenEntries.isEmpty {
            journal.recordFile(name: "hao_listen", documentsURL: documentsURL)
            var existing = readJSONList(name: "hao_listen", documentsURL: documentsURL)
            existing.append(contentsOf: listenEntries)
            if existing.count > 3000 {
                existing = Array(existing.suffix(3000))
            }
            if !writeJSONFile(name: "hao_listen", value: existing, documentsURL: documentsURL) {
                rollback(journal: journal, priorEmbyApiKey: priorEmbyApiKey,
                         wroteEmbyKeychain: wroteEmbyKeychain,
                         documentsURL: documentsURL, defaults: defaults)
                return failReport(
                    total: data.count, migrated: appliedDefaults.count + appliedFiles.count,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "write failed for hao_listen"
                )
            }
            appliedFiles.append("hao_listen")
        }

        if let config = embyConfig {
            journal.recordFile(name: "hao_emby_config", documentsURL: documentsURL)
            var stored = config
            stored.removeValue(forKey: "apiKey")
            if !writeJSONFile(name: "hao_emby_config", value: stored, documentsURL: documentsURL) {
                rollback(journal: journal, priorEmbyApiKey: priorEmbyApiKey,
                         wroteEmbyKeychain: wroteEmbyKeychain,
                         documentsURL: documentsURL, defaults: defaults)
                return failReport(
                    total: data.count, migrated: appliedDefaults.count + appliedFiles.count,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "write failed for hao_emby_config"
                )
            }
            appliedFiles.append("hao_emby_config")
            if let apiKey = embyApiKey, !apiKey.isEmpty {
                if KeychainStore.saveEmbyApiKey(apiKey) {
                    wroteEmbyKeychain = true
                } else {
                    // One locked keychain must not fail the whole
                    // migration: the file part still migrates and the
                    // token can be re-entered in settings.
                    embyTokenSkipped = true
                }
            }
        }

        if !unknown.isEmpty {
            journal.recordFile(name: unknownKeysFileName, documentsURL: documentsURL)
            var existing = readJSONDictionary(name: unknownKeysFileName, documentsURL: documentsURL)
            for entry in unknown {
                existing[entry.key] = entry.value
            }
            if !writeJSONFile(name: unknownKeysFileName, value: existing, documentsURL: documentsURL) {
                rollback(journal: journal, priorEmbyApiKey: priorEmbyApiKey,
                         wroteEmbyKeychain: wroteEmbyKeychain,
                         documentsURL: documentsURL, defaults: defaults)
                return failReport(
                    total: data.count, migrated: appliedDefaults.count + appliedFiles.count,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "write failed for \(unknownKeysFileName)"
                )
            }
            appliedFiles.append(unknownKeysFileName)
        }

        // 4. Verify: every written value reads back in the right shape.
        var verifyFailures = 0
        for write in defaultWrites {
            if !verifyDefault(key: write.key, kind: kindForDefaultKey(write.key), defaults: defaults) {
                verifyFailures += 1
            }
        }
        for name in appliedFiles {
            if !verifyFile(name: name, documentsURL: documentsURL) {
                verifyFailures += 1
            }
        }
        if wroteEmbyKeychain, let apiKey = embyApiKey, !apiKey.isEmpty {
            if KeychainStore.loadEmbyApiKey() != apiKey {
                verifyFailures += 1
            }
        }
        if verifyFailures > 0 {
            rollback(journal: journal, priorEmbyApiKey: priorEmbyApiKey,
                     wroteEmbyKeychain: wroteEmbyKeychain,
                     documentsURL: documentsURL, defaults: defaults)
            return failReport(
                total: data.count, migrated: 0, skipped: skipped,
                unknown: Array(unknown.keys),
                detail: "verification failed for \(verifyFailures) value(s)"
            )
        }

        if markDone {
            defaults.set(true, forKey: doneKey)
        }
        let migrated = appliedDefaults.count + appliedFiles.count
        let detailSuffix = embyTokenSkipped ? "; emby apiKey not saved to keychain" : ""
        return MigrationReport(
            outcome: .migrated, totalKeys: data.count,
            migratedKeys: migrated, skippedKeys: skipped.count,
            unknownKeys: unknown.count, failedKeys: 0,
            skippedKeyNames: skipped.sorted(),
            unknownKeyNames: Array(unknown.keys).sorted(),
            detail: "migrated \(migrated) of \(data.count) keys\(detailSuffix)"
        )
    }

    // MARK: - Coercion (mirrors the Flutter getters: wrong type falls back)

    /// Coerces one snapshot value to the shape the mapping table
    /// promises. Returns nil for a bad-typed value, which the caller
    /// counts as skipped. JSON strings are parsed into values.
    static func coerce(_ value: Any, as kind: MigrationKeyKind) -> Any? {
        switch kind {
        case .string:
            return value as? String
        case .int:
            guard let number = numberValue(value) else { return nil }
            return number.intValue
        case .double:
            guard let number = numberValue(value) else { return nil }
            return number.doubleValue
        case .bool:
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID()
            else { return nil }
            return number.boolValue
        case .json:
            if let text = value as? String {
                guard let jsonData = text.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: jsonData, options: []),
                      parsed is [Any] || parsed is [String: Any]
                else { return nil }
                return parsed
            }
            if value is [Any] || value is [String: Any] {
                return value
            }
            return nil
        case .intList:
            guard let list = jsonList(value) else { return nil }
            var out: [Int] = []
            for item in list {
                guard let number = numberValue(item) else { return nil }
                out.append(number.intValue)
            }
            return out
        case .doubleList:
            guard let list = jsonList(value) else { return nil }
            var out: [Double] = []
            for item in list {
                guard let number = numberValue(item) else { return nil }
                out.append(number.doubleValue)
            }
            return out
        }
    }

    /// A JSON number that is not a boolean. JSONSerialization
    /// represents booleans as NSNumber too, so the type id check
    /// matters: a bool stored where an int belongs is a bad type.
    static func numberValue(_ value: Any) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number
    }

    /// A JSON array, either inline or encoded inside a string.
    static func jsonList(_ value: Any) -> [Any]? {
        if let list = value as? [Any] {
            return list
        }
        if let text = value as? String,
           let jsonData = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: jsonData, options: []),
           let list = parsed as? [Any] {
            return list
        }
        return nil
    }

    static func kindForDefaultKey(_ key: String) -> MigrationKeyKind {
        mapping(for: key)?.kind ?? .string
    }

    // MARK: - File helpers

    static func writeJSONFile(name: String, value: Any, documentsURL: URL) -> Bool {
        guard JSONSerialization.isValidJSONObject(value),
              let jsonData = try? JSONSerialization.data(withJSONObject: value, options: [])
        else { return false }
        let url = documentsURL.appendingPathComponent("\(name).json")
        do {
            try jsonData.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    static func readJSONDictionary(name: String, documentsURL: URL) -> [String: Any] {
        let url = documentsURL.appendingPathComponent("\(name).json")
        guard let rawData = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: rawData, options: []),
              let dict = parsed as? [String: Any]
        else { return [:] }
        return dict
    }

    static func readJSONList(name: String, documentsURL: URL) -> [[String: Any]] {
        let url = documentsURL.appendingPathComponent("\(name).json")
        guard let rawData = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: rawData, options: []),
              let list = parsed as? [[String: Any]]
        else { return [] }
        return list
    }

    static func verifyDefault(key: String, kind: MigrationKeyKind, defaults: UserDefaults) -> Bool {
        guard let value = defaults.object(forKey: key) else { return false }
        switch kind {
        case .string:
            return value is String
        case .int, .double:
            return numberValue(value) != nil
        case .bool:
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        case .intList:
            guard let list = value as? [Any] else { return false }
            return list.allSatisfy { numberValue($0) != nil }
        case .doubleList:
            guard let list = value as? [Any] else { return false }
            return list.allSatisfy { numberValue($0) != nil }
        case .json:
            return true
        }
    }

    static func verifyFile(name: String, documentsURL: URL) -> Bool {
        let url = documentsURL.appendingPathComponent("\(name).json")
        guard let rawData = try? Data(contentsOf: url) else { return false }
        return (try? JSONSerialization.jsonObject(with: rawData, options: [])) != nil
    }

    // MARK: - Rollback

    static func failReport(
        total: Int, migrated: Int, skipped: [String],
        unknown: [String], detail: String
    ) -> MigrationReport {
        MigrationReport(
            outcome: .failed, totalKeys: total, migratedKeys: migrated,
            skippedKeys: skipped.count, unknownKeys: unknown.count,
            failedKeys: total - migrated - skipped.count - unknown.count,
            skippedKeyNames: skipped.sorted(),
            unknownKeyNames: unknown.sorted(), detail: detail
        )
    }

    static func rollback(
        journal: MigrationJournal,
        priorEmbyApiKey: String?,
        wroteEmbyKeychain: Bool,
        documentsURL: URL,
        defaults: UserDefaults
    ) {
        journal.restore(documentsURL: documentsURL, defaults: defaults)
        if wroteEmbyKeychain {
            if let prior = priorEmbyApiKey {
                _ = KeychainStore.saveEmbyApiKey(prior)
            } else {
                _ = KeychainStore.deleteEmbyApiKey()
            }
        }
        defaults.set(false, forKey: doneKey)
    }
}

/// The prior value of one UserDefaults key, or nil when absent.
/// Stored separately from the value so "absent" survives the write.
struct PriorDefault {
    let key: String
    let value: Any?
}

/// Journal of everything one migration attempt changed, so a
/// failure can put every value back the way it was. Kept in memory
/// for the attempt; the durable copy lives in migration_backup.
struct MigrationJournal {
    var priorDefaults: [PriorDefault] = []
    var priorFiles: [String: Data?] = [:]

    mutating func recordDefault(key: String, defaults: UserDefaults) {
        if priorDefaults.contains(where: { $0.key == key }) { return }
        priorDefaults.append(PriorDefault(key: key, value: defaults.object(forKey: key)))
    }

    mutating func recordFile(name: String, documentsURL: URL) {
        if priorFiles[name] != nil { return }
        let url = documentsURL.appendingPathComponent("\(name).json")
        priorFiles[name] = try? Data(contentsOf: url)
    }

    func restore(documentsURL: URL, defaults: UserDefaults) {
        for prior in priorDefaults {
            if let value = prior.value {
                defaults.set(value, forKey: prior.key)
            } else {
                defaults.removeObject(forKey: prior.key)
            }
        }
        for entry in priorFiles {
            let url = documentsURL.appendingPathComponent("\(entry.key).json")
            if let priorData = entry.value {
                try? priorData.write(to: url, options: [.atomic])
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

/// The durable pre-write backup: a timestamped folder under
/// Documents/migration_backup holding the snapshot file, the prior
/// UserDefaults values for touched keys, and the prior collection
/// files about to be overwritten. Creation failure aborts the
/// migration before anything is written.
struct MigrationBackup {
    let documentsURL: URL
    let defaults: UserDefaults

    func create(defaultKeys: [String], fileNames: Set<String>) -> Bool {
        let stamp = MigrationBackup.timestamp()
        let dir = documentsURL
            .appendingPathComponent(MigrationStore.backupDirectoryName)
            .appendingPathComponent(stamp)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let snapshotURL = documentsURL.appendingPathComponent(MigrationStore.snapshotFileName)
            if fileManager.fileExists(atPath: snapshotURL.path) {
                try fileManager.copyItem(at: snapshotURL, to: dir.appendingPathComponent(MigrationStore.snapshotFileName))
            }
            var prior: [String: Any] = [:]
            for key in defaultKeys {
                if let value = defaults.object(forKey: key) {
                    prior[key] = value
                }
            }
            if JSONSerialization.isValidJSONObject(prior),
               let priorData = try? JSONSerialization.data(withJSONObject: prior, options: []) {
                try priorData.write(to: dir.appendingPathComponent("defaults-before.json"), options: [.atomic])
            }
            let collectionsDir = dir.appendingPathComponent("collections")
            try fileManager.createDirectory(at: collectionsDir, withIntermediateDirectories: true)
            for name in fileNames {
                let source = documentsURL.appendingPathComponent("\(name).json")
                if fileManager.fileExists(atPath: source.path) {
                    try fileManager.copyItem(at: source, to: collectionsDir.appendingPathComponent("\(name).json"))
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// Second-resolution alone is not unique: a failed attempt and
    /// its immediate retry land in the same second, and the second
    /// create() would die copying the snapshot onto the first
    /// attempt's file (copyItem refuses an existing destination) —
    /// the retry then reports "pre-write backup failed" and writes
    /// nothing. The UUID suffix makes every attempt's folder unique.
    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(8)
    }
}

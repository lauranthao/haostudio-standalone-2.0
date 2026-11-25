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
    /// Raw Data (b49fix2 P1-4): a UserDefaults Data value, e.g.
    /// `hao.currentPlayContext` (JSON-encoded PlayContext).
    /// It cannot sit in a JSON envelope as-is, so it travels
    /// base64: `coerce` encodes Data to its base64 string on
    /// export and decodes a base64 string back to Data on import.
    case data
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
    /// Serial queue for listen-log read-modify-write (b49fix15
    /// P2-1): the listen log has writers on two threads — the
    /// player's recordListenEvent (main thread, synchronous) and
    /// the backup import (workQueue / DispatchQueue.global).
    /// Deferring the import merge to apply time (see
    /// BackupEngineCore) closes the seconds-long plan→apply
    /// window, but the apply-time re-read → merge → write is
    /// still a read-modify-write: without this queue a
    /// completion landing between the re-read and the write is
    /// lost. The queue makes each read-modify-write atomic, so
    /// no lost update is left: a completion either lands before
    /// the import's re-read (merged in) or after its write (a
    /// fresh write on top). Readers (getListenLog)
    /// take no lock: writes are .atomic, so a reader always
    /// sees a complete old or new file, never a torn one. The
    /// queue is held only across file I/O (milliseconds) and is
    /// uncontended in normal playback; it is never taken
    /// re-entrantly and never held across a dispatch or await,
    /// so it cannot deadlock. Same shape as the pool's queue
    /// (b49fix17: saveDailyPool now takes dailyWriteQueue too,
    /// so the pool merge and the pool save serialise on one
    /// queue instead of two).
    static let listenLogWriteQueue = DispatchQueue(label: "com.haostudio.listenLog")

    /// Serial queue for daily-cache writes (b49fix16 P2-2):
    /// the same shape as listenLogWriteQueue above.
    /// saveDailyTracks is a read-modify-write of the whole
    /// hao_daily dict, called from the main thread
    /// (replaceDailySong, reloadDaily CAS) and from the backup
    /// import's background queues (Route A dict merge, Route B
    /// mergedFiles loop) — without one queue a replace landing
    /// between the import's re-read and write overwrites the
    /// import (or vice versa). The queue lives here, not in
    /// MusicLibraryStore: that file is not in the Package.swift
    /// AppCore sources, and BackupEngine (AppCore) must take
    /// the same queue. Held only across file I/O; never taken
    /// re-entrantly and never held across a dispatch or await,
    /// so it cannot deadlock.
    static let dailyWriteQueue = DispatchQueue(label: "com.haostudio.dailyTracks")

    /// Serial queue for recent-plays writes (b49fix17 P1-2):
    /// the same shape as listenLogWriteQueue — writeRecent is
    /// a read-modify-write of the whole hao_recent file, run
    /// on every song switch (addRecentAsync, songSwitchIOQueue)
    /// and from the backup import's merge, so the two must
    /// serialise on one queue or a switch landing between the
    /// import's re-read and write is lost (and a switch
    /// landing between the write and the verify used to fail
    /// the whole import at the 100 cap). Lives here for the
    /// same AppCore reason as dailyWriteQueue.
    static let recentWriteQueue = DispatchQueue(label: "com.haostudio.recent")

    /// Serial queue for resume-point writes (b49fix17 P1-4 /
    /// P2-2): saveResume is a read-modify-write (a checkpoint
    /// that read the old map before an import write and wrote
    /// back after it used to restore imported resume values
    /// to pre-import values), and clearResume deletes a key
    /// on natural completion. Both now run under this queue,
    /// the same one the import's resume merge takes, so the
    /// stale-write hole is closed rather than merely
    /// documented. Lives here for the same AppCore reason.
    static let resumeWriteQueue = DispatchQueue(label: "com.haostudio.resume")

    /// Serial queue for the playback-queue file (b49fix17
    /// P1-3): saveQueueAsync writes musicQueue on every song
    /// switch and every queue edit, and the import writes it
    /// too — without one queue a switch landing between the
    /// import's re-read and write is silently replaced by the
    /// backup queue (visible only on the next launch).
    static let musicQueueWriteQueue = DispatchQueue(label: "com.haostudio.musicQueue")

    /// Shared serial queue for the remaining music
    /// collections' read-modify-write (b49fix17 P2-6):
    /// hao_fav, hao_lists, hao_music_search_hist,
    /// hao_cover_cache, hao_lyrics, musicDownloads,
    /// hao_music_loudness_cache, hao_fav_playlists,
    /// hao_fav_albums, hao_fav_artists, fmDislikedIds.
    /// One queue for all of them (instead of one per file):
    /// each write is milliseconds of file I/O, the files are
    /// independent, and serialising unrelated writes against
    /// each other costs nothing — what matters is that each
    /// file's live writer and the import's merge take the SAME
    /// queue for that file. The video/live history files
    /// (hao_video_hist, hao_live_hist) also map here so the
    /// import side has a queue to take; their live writers
    /// live in Features/Video and Features/Live, outside
    /// this round's scope, so they do not take it yet (see
    /// writeQueue(forCollection:)).
    static let collectionWriteQueue = DispatchQueue(label: "com.haostudio.collections")

    /// The serial queue that serialises one collection's
    /// read-modify-write, or nil when the file has no queued
    /// writer yet (b49fix17 P2-6). The import (both routes)
    /// and the rollback take this queue for the file; a live
    /// writer that takes it too is atomic against the import.
    /// Files that return nil keep the whole-file write + byte
    /// verify, and their live writers are listed as known
    /// windows in BackupEngine's per-file table — the six-file
    /// set is not complete, and this function is the honest
    /// record of which files are actually serialised.
    static func writeQueue(forCollection name: String) -> DispatchQueue? {
        switch name {
        case "hao_listen":
            return listenLogWriteQueue
        case "hao_daily", "haoVodProg", "hao_daily_pool":
            return dailyWriteQueue
        case "hao_recent":
            return recentWriteQueue
        case "musicResume":
            return resumeWriteQueue
        case "musicQueue":
            return musicQueueWriteQueue
        case "hao_fav", "hao_lists", "hao_music_search_hist",
             "hao_cover_cache", "hao_lyrics", "musicDownloads",
             "hao_music_loudness_cache", "hao_fav_playlists",
             "hao_fav_albums", "hao_fav_artists", "fmDislikedIds",
             // Import side only: the Video/Live history writers
             // do not take this queue yet (their stores are
             // outside this round's scope), so a history write
             // landing inside the import merge's re-read → write
             // gap is still lost — a millisecond window, and the
             // subset verify still catches anything larger.
             "hao_video_hist", "hao_live_hist":
            return collectionWriteQueue
        default:
            return nil
        }
    }

    /// Resume keys a natural completion deleted while an
    /// import runs (b49fix17 P2-2): clearResume deletes a key
    /// when its song finishes, and a key deleted between the
    /// import's write and its verify would otherwise fail the
    /// key-only check and roll the whole import back. The
    /// record is cleared at each import's start and read at
    /// its verify, so exactly the keys deleted during this
    /// import are excused — never a key the write failed to
    /// land. Guarded by a lock: clearResume runs on the
    /// player's threads while the verify reads on the import
    /// queue. One import at a time is assumed (the UI already
    /// prevents concurrent imports); the set only ever holds
    /// a few keys.
    private static let resumeDeletionLock = NSLock()
    private static var resumeKeysDeletedDuringImport: Set<String> = []

    /// Clears the deletion record at an import's start.
    static func resetResumeDeletionRecord() {
        resumeDeletionLock.lock()
        resumeKeysDeletedDuringImport.removeAll()
        resumeDeletionLock.unlock()
    }

    /// Records one key clearResume deleted.
    static func noteResumeKeyDeleted(_ key: String) {
        resumeDeletionLock.lock()
        resumeKeysDeletedDuringImport.insert(key)
        resumeDeletionLock.unlock()
    }

    /// The keys deleted since the current import started.
    static func resumeDeletionRecord() -> Set<String> {
        resumeDeletionLock.lock()
        defer { resumeDeletionLock.unlock() }
        return resumeKeysDeletedDuringImport
    }

    static let snapshotFileName = "migration_snapshot.json"
    static let backupDirectoryName = "migration_backup"
    static let doneKey = "hao_migration_done_v1"
    static let stateKey = "hao_migration_state"
    static let noticeDismissedKey = "hao_migration_notice_dismissed"
    /// Failed-attempt backoff (b49fix2 P2-12): a migration that
    /// keeps failing retried every launch and grew
    /// migration_backup/ without bound. After this many failed
    /// attempts the launch path stops retrying; the My-page
    /// notice (migrationNoticeNeeded) is the one surfacing, and
    /// the user can still re-run the import by hand from a
    /// backup file. A success resets the count.
    static let failedAttemptsKey = "hao_migration_failed_attempts"
    static let lastFailedAtKey = "hao_migration_last_failed_at"
    static let maxFailedAttempts = 3
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

    // b49fix2 P1-3 removedMappings: 25 keys were deleted from
    // this table because the app migrates them but nothing ever
    // reads them (preferResolution, liveCrashStage,
    // engineSectionExpanded, playbackSectionExpanded,
    // hao_feature_cover_plaza, hao_feature_cover_charts,
    // hao_music_bookmarks, hao_music_sources,
    // hao_music_queue_memory, hao_sa_xh_device,
    // hao_wallpaper_v115_off_once, hao_tabbar_accent_presets,
    // hao_custom_font_family, hao_custom_font_name,
    // hao_custom_font_path, hao_vod_playback_rate,
    // hao_vod_sleep_custom_minutes, hao_vod_sleep_episode_count,
    // hao_vod_subtitle_delay, hao_vod_metadata_overrides,
    // hao_emby_home, hao_live_hist_retention_days,
    // hao_live_hidden_platforms, hao_live_clock_corner,
    // hao_live_volume_boost_pct). A key that arrives in a
    // snapshot without a mapping is NOT dropped: it is
    // isolated into migration_unknown_keys.json (see importData),
    // so the data survives and a future lane can re-add the
    // mapping the day it wires a real reader. hao_sa_xh_device
    // is not a UserDefaults key at all — the resolver reads
    // hao_sa_xh_device.json as a file — so deleting its row
    // loses nothing functional.

    static let mappings: [MigrationKeyMapping] = [
        // Playback / player preference.
        MigrationKeyMapping(key: "videoPlayerKey", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hapticsEnabled", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "audioMixWithOthers", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "autoResumeLastPlayback", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "skippedVersion", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "lastUpdateCheckAt", kind: .int, destination: .userDefaults),
        MigrationKeyMapping(key: "autoUpdateCheck", kind: .bool, destination: .userDefaults),
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
        MigrationKeyMapping(key: "hao_music_loudness_cache", kind: .json, destination: .collectionFile("hao_music_loudness_cache")),
        MigrationKeyMapping(key: "hao_local_music", kind: .json, destination: .collectionFile("hao_local_music")),
        MigrationKeyMapping(key: "hao_resolver_speed", kind: .json, destination: .collectionFile("hao_resolver_speed")),
        // Appearance.
        MigrationKeyMapping(key: "hao_wallpaper_enabled", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_wallpaper_paths", kind: .json, destination: .collectionFile("hao_wallpaper_paths")),
        MigrationKeyMapping(key: "hao_wallpaper_current", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_bgcolor_enabled", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_bgcolor_hex", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_tabbar_accent", kind: .int, destination: .userDefaults),
        // Video / VOD: scalars.
        MigrationKeyMapping(key: "hao_video_auto_next", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_double_tap_seconds", kind: .int, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_dialogue_boost", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_spoiler_hide_synopsis", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_spoiler_blur_unwatched", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_audio_only", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_video_fit", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_super_resolution", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_skip_intro_mode", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_interpolation", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_sdr_to_hdr", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_subtitle_font_size", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_subtitle_color", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_subtitle_position", kind: .string, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_danmaku_occlusion_avoidance", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_vod_dv_p8_downgrade", kind: .bool, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_low_memory_mode", kind: .string, destination: .userDefaults),
        // Video / VOD: collections.
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
        MigrationKeyMapping(key: "hao_sa_video_applied", kind: .json, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_emby_config", kind: .json, destination: .emby),
        MigrationKeyMapping(key: "hao_video_tab_mode", kind: .string, destination: .userDefaults),
        // Live.
        MigrationKeyMapping(key: "hao_live_sources", kind: .json, destination: .collectionFile("hao_live_sources")),
        MigrationKeyMapping(key: "hao_live_hist", kind: .json, destination: .collectionFile("hao_live_hist")),
        MigrationKeyMapping(key: "hao_live_hist_limit", kind: .int, destination: .userDefaults),
        MigrationKeyMapping(key: "hao_live_follows", kind: .json, destination: .collectionFile("hao_live_follows")),
        MigrationKeyMapping(key: "hao_live_search_hist", kind: .json, destination: .collectionFile("hao_live_search_hist")),
        MigrationKeyMapping(key: "hao_live_cellular_downgrade", kind: .bool, destination: .userDefaults),
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
        // b49fix2 P2-12: stop retrying a migration that has
        // already failed maxFailedAttempts times. Without this
        // every launch paid for a full attempt and left another
        // timestamped folder in migration_backup/.
        let failedAttempts = (defaults.object(forKey: failedAttemptsKey) as? NSNumber)?.intValue ?? 0
        if failedAttempts >= maxFailedAttempts {
            defaults.set(stateFailed, forKey: stateKey)
            return MigrationReport.empty(.failed, detail: "migration failed \(maxFailedAttempts) times; not retrying")
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
            defaults.set(0, forKey: failedAttemptsKey)
        case .failed:
            defaults.set(stateFailed, forKey: stateKey)
            let attempts = ((defaults.object(forKey: failedAttemptsKey) as? NSNumber)?.intValue ?? 0) + 1
            defaults.set(attempts, forKey: failedAttemptsKey)
            defaults.set(Date().timeIntervalSince1970, forKey: lastFailedAtKey)
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
    ///
    /// Import is a MERGE, not a replace (b49fix17 §6): live keys
    /// absent from the backup are kept, so an old backup cannot
    /// restore the exact backup-time state — the pre-import
    /// snapshot (migration_backup) and the rollback are what
    /// preserve the pre-import state. The settings UI says the
    /// same in the import preview.
    static func importData(
        _ data: [String: Any],
        documentsURL: URL,
        defaults: UserDefaults,
        markDone: Bool
    ) -> MigrationReport {
        // b49fix17 P2-2: clear the resume-deletion record — the
        // verify below excuses exactly the keys clearResume
        // deletes during THIS import.
        resetResumeDeletionRecord()
        // 1. Plan: coerce every key now, before touching storage.
        var defaultWrites: [(key: String, value: Any)] = []
        var fileWrites: [String: Any] = [:]
        var mergedFiles: [String: [String: Any]] = [:]
        var listenEntries: [[String: Any]] = []
        // b49fix17 P1-4: recent and resume merge like the listen
        // log — they are no longer whole-file writes. See the
        // collectionFile branches below for the shape judgment.
        var recentEntries: [[String: Any]] = []
        var resumeEntries: [String: Any] = [:]
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
                    if name == "hao_listen" {
                        // b49fix16 P2-1: the bare key takes the same
                        // merge road as the hao_listen_* shards — a
                        // whole-file write here would overwrite a
                        // completion recorded while this import runs
                        // (Route B's verify is shape-only, so the
                        // loss would be silent). A non-list value is
                        // corrupt: skip the key, do not write it.
                        if let list = coerced as? [[String: Any]] {
                            listenEntries.append(contentsOf: list)
                        } else {
                            skipped.append(key)
                        }
                    } else if name == "hao_recent" {
                        // b49fix17 P1-4: recent merges like the
                        // listen log — live first, backup after,
                        // dedupe by identityKey, truncate to 100
                        // (see mergedRecentEntries). A song switch
                        // landing before a whole-file write here
                        // used to vanish silently. A non-list
                        // value is corrupt: skip the key.
                        if let list = coerced as? [[String: Any]] {
                            recentEntries.append(contentsOf: list)
                        } else {
                            skipped.append(key)
                        }
                    } else if name == "musicResume" {
                        // b49fix17 P1-4: resume is a DICT
                        // {identityKey: seconds} — the project's
                        // own mapping doc says so
                        // (docs/storage-mapping.md:112 「斷點續播
                        // {identityKey: 秒}」), and 2.0's
                        // resumeMap() only reads a dict (a list
                        // shape would import as unreadable — the
                        // worse outcome). The only evidence for a
                        // list shape was the synthetic fixture
                        // (simulate_upgrade.py sampled
                        // [{"id":"x"}] for EVERY .json key, not a
                        // real Flutter shape), so the fixture now
                        // samples a dict instead. Merge is a dict
                        // overlay, same as hao_daily. A non-dict
                        // value is corrupt: skip the key.
                        if let dict = coerced as? [String: Any] {
                            for (resumeKey, value) in dict {
                                resumeEntries[resumeKey] = value
                            }
                        } else {
                            skipped.append(key)
                        }
                    } else {
                        fileWrites[name] = coerced
                    }
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
        // b49fix17 P1-4: the two new merge files are backed up
        // before they are merged, same as the listen log.
        if !recentEntries.isEmpty {
            backupFileNames.insert("hao_recent")
        }
        if !resumeEntries.isEmpty {
            backupFileNames.insert("musicResume")
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
        // b49fix17 P1-4: the merged values these two files were
        // written as — the verify below checks content subset
        // against them, not just shape.
        var expectedRecent: [[String: Any]]?
        var expectedResume: [String: Any]?
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
            // b49fix16 P2-2: the re-read → merge → cap → write
            // runs under dailyWriteQueue, the same queue
            // MusicLibraryStore.saveDailyTracks /
            // saveDailyTracksIfUnchanged use — a replace landing
            // between this re-read and write is serialised after
            // it instead of overwriting the import (or vice
            // versa). This loop only ever sees hao_daily and
            // haoVodProg — the only two non-listen prefix
            // families — and one queue for both dict merges keeps
            // the two import routes from drifting apart. The
            // write result is captured out of the closure because
            // the failure path returns from this function.
            let wroteMerged = dailyWriteQueue.sync { () -> Bool in
                let existing = readJSONDictionary(name: name, documentsURL: documentsURL)
                var merged = existing
                for entry in entries {
                    merged[entry.key] = entry.value
                }
                // b49fix17 P2-4: the import applies the same
                // 7-day prune live writes apply — a concurrent
                // saveDailyTracks pruning just-imported old-day
                // keys no longer fails the verify.
                if name == "hao_daily" {
                    merged = prunedDailyEntries(merged, keeping: nil)
                }
                // b49fix16 P2-6 / b49fix17 P2-1: deterministic
                // 200 cap (see cappedVodProgEntries — "newest"
                // is not recoverable from the data), and the
                // incoming keys always survive it.
                if name == "haoVodProg" {
                    merged = cappedVodProgEntries(merged, keeping: Set(entries.keys))
                }
                return writeJSONFile(name: name, value: merged, documentsURL: documentsURL)
            }
            if !wroteMerged {
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
            // b49fix15 P2-1: the re-read → merge → write runs
            // under listenLogWriteQueue, the same queue the
            // player's recordListenEvent uses — a completion
            // landing mid-merge is serialised after this write
            // instead of being overwritten by it. (Route B
            // already re-read at apply time; the queue closes
            // the remaining re-read → write gap. The write
            // result is captured out of the closure because the
            // failure path returns from this function.)
            let wroteListen = listenLogWriteQueue.sync { () -> Bool in
                var existing = readJSONList(name: "hao_listen", documentsURL: documentsURL)
                existing.append(contentsOf: listenEntries)
                // b49fix2 P2-11: a re-import of the same backup used to
                // double the history (append with no dedupe). Same
                // song at the same second is the same listen, not two.
                existing = dedupedListenEntries(existing)
                if existing.count > 3000 {
                    existing = Array(existing.suffix(3000))
                }
                return writeJSONFile(name: "hao_listen", value: existing, documentsURL: documentsURL)
            }
            if !wroteListen {
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

        // b49fix17 P1-4: recent merges under recentWriteQueue,
        // the same queue writeRecent uses — a song switch
        // landing mid-merge is serialised after this write
        // instead of being overwritten by it, and the merged
        // list is captured for the content-subset verify below.
        if !recentEntries.isEmpty {
            journal.recordFile(name: "hao_recent", documentsURL: documentsURL)
            var mergedRecent: [[String: Any]] = []
            let wroteRecent = recentWriteQueue.sync { () -> Bool in
                let existing = readJSONList(name: "hao_recent", documentsURL: documentsURL)
                mergedRecent = mergedRecentEntries(live: existing, incoming: recentEntries)
                return writeJSONFile(name: "hao_recent", value: mergedRecent, documentsURL: documentsURL)
            }
            if !wroteRecent {
                rollback(journal: journal, priorEmbyApiKey: priorEmbyApiKey,
                         wroteEmbyKeychain: wroteEmbyKeychain,
                         documentsURL: documentsURL, defaults: defaults)
                return failReport(
                    total: data.count, migrated: appliedDefaults.count + appliedFiles.count,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "write failed for hao_recent"
                )
            }
            expectedRecent = mergedRecent
            appliedFiles.append("hao_recent")
        }

        // b49fix17 P1-4: resume merges under resumeWriteQueue,
        // the same queue saveResume / clearResume use — a
        // checkpoint that read the old map before this write
        // cannot write back after it and restore imported
        // values to pre-import values (b49fix17 P2-2).
        if !resumeEntries.isEmpty {
            journal.recordFile(name: "musicResume", documentsURL: documentsURL)
            var mergedResume: [String: Any] = [:]
            let wroteResume = resumeWriteQueue.sync { () -> Bool in
                var existing = readJSONDictionary(name: "musicResume", documentsURL: documentsURL)
                for (key, value) in resumeEntries {
                    existing[key] = value
                }
                mergedResume = existing
                return writeJSONFile(name: "musicResume", value: existing, documentsURL: documentsURL)
            }
            if !wroteResume {
                rollback(journal: journal, priorEmbyApiKey: priorEmbyApiKey,
                         wroteEmbyKeychain: wroteEmbyKeychain,
                         documentsURL: documentsURL, defaults: defaults)
                return failReport(
                    total: data.count, migrated: appliedDefaults.count + appliedFiles.count,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "write failed for musicResume"
                )
            }
            expectedResume = mergedResume
            appliedFiles.append("musicResume")
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
            if name == "hao_recent", let expected = expectedRecent {
                // b49fix17 P1-4: content subset, not shape-only —
                // a switch that landed before the write and was
                // silently lost used to pass verifyFile. The
                // tolerant check excuses only tail entries a
                // concurrent switch displaced (see
                // recentContainsAll).
                let actual = readJSONList(name: "hao_recent", documentsURL: documentsURL)
                if !recentContainsAll(actual: actual, expected: expected) {
                    verifyFailures += 1
                }
            } else if name == "musicResume", let expected = expectedResume {
                // b49fix17 P1-4/P2-2: key-only subset — resume
                // seconds are progress markers — excusing keys
                // clearResume deleted during this import.
                if !resumeEntriesPresent(expected, documentsURL: documentsURL, toleratingDeleted: resumeDeletionRecord()) {
                    verifyFailures += 1
                }
            } else if !verifyFile(name: name, documentsURL: documentsURL) {
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
        case .data:
            // Bidirectional by construction: the export reads Data
            // out of UserDefaults and needs a JSON-safe string;
            // the import reads that string out of the envelope and
            // needs Data back. A base64 string that does not decode
            // is a bad type, never silently stored.
            if let data = value as? Data {
                return data.base64EncodedString()
            }
            if let text = value as? String,
               let data = Data(base64Encoded: text) {
                return data
            }
            return nil
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

    /// Dedupe key for one listen-history entry (b49fix2 P2-11):
    /// identity (platform + song id, or title + artist when the
    /// id is empty — the same fallback MusicSong.identityKey
    /// uses) + the play timestamp. A re-import of the same
    /// backup must not double the history.
    static func listenDedupeKey(for entry: [String: Any]) -> String {
        let platform = entry["platform"] as? String ?? ""
        let songId = entry["songId"] as? String ?? ""
        let at: String
        if let number = numberValue(entry["at"]) {
            at = "\(number.intValue)"
        } else if let text = entry["at"] as? String {
            at = text
        } else {
            at = ""
        }
        if !songId.isEmpty {
            return "\(platform)|\(songId)|\(at)"
        }
        let title = entry["title"] as? String ?? ""
        let artist = entry["artist"] as? String ?? ""
        return "\(platform)|\(title)|\(artist)|\(at)"
    }

    /// Drop duplicate listen entries (same identity + timestamp),
    /// keeping the first occurrence. Shared by MigrationStore's
    /// own import and BackupEngineCore.mergePrefixValue — one
    /// rule for both import paths.
    static func dedupedListenEntries(_ entries: [[String: Any]]) -> [[String: Any]] {
        var seen = Set<String>()
        var out: [[String: Any]] = []
        out.reserveCapacity(entries.count)
        for entry in entries {
            if seen.insert(listenDedupeKey(for: entry)).inserted {
                out.append(entry)
            }
        }
        return out
    }

    /// Caps a haoVodProg dict to 200 entries (b49fix16 P2-6,
    /// b49fix17 P2-1). The old code took the first 200 entries
    /// of the Dictionary's iteration order — which is
    /// hash-random, so it kept an arbitrary 200 resume
    /// positions, not the newest. Honest limit: "newest" is
    /// not recoverable from the data — the entries carry no
    /// timestamp (the value is resume seconds, the key is a
    /// platform-scoped video id) — so this makes the cap
    /// deterministic instead, and the comment says
    /// 「確定性 200」, never 「最新」. b49fix17 P2-1: the
    /// fix16 rule (last 200 by key sort) deterministically
    /// dropped a just-imported key whenever it sorted early,
    /// on every repeat import — so the INCOMING keys always
    /// survive the cap now, and the remaining slots fill by
    /// key sort. Callers pass the keys this import brought;
    /// a backup with more than 200 entries keeps them all
    /// (the cap yields to "never drop just-imported entries").
    /// Shared by Route A (BackupEngine) and Route B (this
    /// file's mergedFiles loop) so the two import routes
    /// cannot drift apart again.
    static func cappedVodProgEntries(_ dict: [String: Any], keeping incomingKeys: Set<String> = []) -> [String: Any] {
        guard dict.count > 200 else { return dict }
        var out: [String: Any] = [:]
        out.reserveCapacity(200)
        for key in incomingKeys.sorted() where dict[key] != nil {
            out[key] = dict[key]
        }
        for key in dict.keys.sorted() {
            if out.count >= 200 { break }
            if out[key] == nil { out[key] = dict[key] }
        }
        return out
    }

    /// Identity key of one song JSON dict (b49fix17 P1-2/P2-6):
    /// the same rule MusicSong.identityKey uses — platform +
    /// song id, falling back to title + artist + album when
    /// the id is empty — computed from the raw dict so the
    /// import merges can dedupe without MusicSong (AppCore
    /// cannot see Features types).
    static func songIdentityKey(for entry: [String: Any]) -> String {
        let platform = entry["platform"] as? String ?? ""
        let songId = entry["songId"] as? String ?? ""
        if !songId.isEmpty { return "\(platform)|\(songId)" }
        let title = entry["title"] as? String ?? ""
        let artist = entry["artist"] as? String ?? ""
        let album = entry["album"] as? String ?? ""
        return "\(platform)|\(title)|\(artist)|\(album)"
    }

    /// Dedupe key of one video-history JSON dict (b49fix17
    /// P2-6): VideoHistoryEntry.id is COMPUTED (title + year),
    /// so the stored JSON carries no "id" field — derive the
    /// same key from the stored item dict (VideoResumeKey:
    /// title, or "title-year" when the year is present).
    static func videoHistoryDedupeKey(for entry: [String: Any]) -> String {
        guard let item = entry["item"] as? [String: Any] else { return "" }
        let title = item["title"] as? String ?? ""
        let year = (item["year"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return year.isEmpty ? title : "\(title)-\(year)"
    }

    /// Merges incoming list entries into the live list
    /// (b49fix17 P2-6): live first, incoming after, dedupe by
    /// `keyFor` with live winning, optional cap keeping live
    /// first. The generic list merge — one rule for every
    /// list collection the import merges (hao_fav by "key",
    /// hao_lists by "id", albums/artists by id+name,
    /// downloads by the nested song's identity key, video
    /// history by title+year, live history by
    /// platform|roomId). An entry whose key is empty falls
    /// back to its canonical JSON bytes, so an unkeyed entry
    /// is never silently dropped. Shared by Route A; Route B
    /// uses the typed wrappers below for its two files.
    static func mergedListEntries(
        live: [[String: Any]], incoming: [[String: Any]],
        keyFor: ([String: Any]) -> String, cap: Int? = nil
    ) -> [[String: Any]] {
        var seen = Set<String>()
        var out: [[String: Any]] = []
        out.reserveCapacity(live.count + incoming.count)
        for entry in live + incoming {
            let rawKey = keyFor(entry)
            let key: String
            if rawKey.isEmpty {
                guard let bytes = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
                    // Unserialisable entry: keep it under a unique
                    // key rather than dropping a live entry on a
                    // serialisation guess (entries come from JSON
                    // parsing, so this never fires in practice).
                    out.append(entry)
                    continue
                }
                key = "bytes:" + bytes.base64EncodedString()
            } else {
                key = rawKey
            }
            if seen.insert(key).inserted { out.append(entry) }
        }
        if let cap = cap, out.count > cap { out = Array(out.prefix(cap)) }
        return out
    }

    /// Merges incoming string-list entries into the live list
    /// (b49fix17 P2-6): live first, incoming after, dedupe by
    /// the string itself, optional cap. For hao_music_search_hist
    /// (cap 20), hao_fav_playlists and fmDislikedIds.
    static func mergedStringList(live: [String], incoming: [String], cap: Int? = nil) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(live.count + incoming.count)
        for value in live + incoming {
            if seen.insert(value).inserted { out.append(value) }
        }
        if let cap = cap, out.count > cap { out = Array(out.prefix(cap)) }
        return out
    }

    /// Merges incoming recent entries into the live recent
    /// list (b49fix17 P1-2): live first, backup after, dedupe
    /// by identityKey with live winning, truncate to 100
    /// keeping live first. Same rule as hao_listen's merge,
    /// with the recent cap instead of 3000.
    static func mergedRecentEntries(
        live: [[String: Any]], incoming: [[String: Any]], cap: Int = 100
    ) -> [[String: Any]] {
        mergedListEntries(live: live, incoming: incoming, keyFor: songIdentityKey, cap: cap)
    }

    /// Shared 7-day prune for day-keyed dicts (b49fix17 P2-4):
    /// keys that parse as YYYY-MM-DD dates older than the
    /// cutoff go; an unparseable key is kept, never deleted
    /// on a guess; `keeping` is never pruned (the day a live
    /// save is writing — the import passes nil, it has no
    /// single day being saved). One rule for the live writes
    /// (saveDailyTracks, saveDailyPool) and both import
    /// merges, so a concurrent prune can no longer make the
    /// import's verify fail: the import prunes the same keys
    /// the live writer would.
    static func prunedDailyEntries(_ dict: [String: Any], keeping: String?, now: Date = Date()) -> [String: Any] {
        var out = dict
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let cutoff = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -7, to: now) ?? Date.distantPast)
        for key in out.keys where key != keeping {
            if let date = formatter.date(from: key), date < cutoff {
                out.removeValue(forKey: key)
            }
        }
        return out
    }

    /// Tolerant recent verify (b49fix17 P1-2): the merged
    /// recent list must still be in the file, except for tail
    /// entries a concurrent song switch legitimately displaced.
    /// Each writeRecent after the merge inserts one song at
    /// the front and truncates to 100, so it drops at most one
    /// tail entry: a new song (not in the merged list) or a
    /// re-add that moves a merged song to the front. The
    /// displacement budget is the count of such post-merge
    /// writes, derived from the data itself — new songs in the
    /// actual list plus merged songs that appear ahead of a
    /// merged song that precedes them in merged order — and
    /// every missing merged entry must sit within the last
    /// `budget` entries of the merged list. A plain multiset
    /// subset would fail the whole import on every song switch
    /// while recent is at its routine 100 cap. Residual,
    /// theoretical only: a write that failed silently at apply
    /// time plus exactly compensating concurrent inserts could
    /// pass — but an apply write failure is reported
    /// (.writeFailed → rollback), so the verify never has to
    /// carry that case alone.
    static func recentContainsAll(actual: [[String: Any]], expected: [[String: Any]]) -> Bool {
        let actualKeys = actual.map { songIdentityKey(for: $0) }
        let expectedKeys = expected.map { songIdentityKey(for: $0) }
        let actualSet = Set(actualKeys)
        let expectedSet = Set(expectedKeys)
        let missing = expectedKeys.filter { !actualSet.contains($0) }
        if missing.isEmpty { return true }
        let newCount = actualKeys.filter { !expectedSet.contains($0) }.count
        var expectedPos: [String: Int] = [:]
        for (index, key) in expectedKeys.enumerated() {
            if expectedPos[key] == nil { expectedPos[key] = index }
        }
        // Merged songs moved to the front by a re-add: scanning
        // the actual list from the end, an entry is moved when
        // a later entry has a smaller merged position.
        var movedCount = 0
        var minPosAfter = Int.max
        for key in actualKeys.reversed() {
            guard let pos = expectedPos[key] else { continue }
            if pos > minPosAfter {
                movedCount += 1
            } else {
                minPosAfter = pos
            }
        }
        let budget = newCount + movedCount
        guard budget > 0 else { return false }
        let tail = Set(expectedKeys.suffix(budget))
        return missing.allSatisfy { tail.contains($0) }
    }

    /// Content-subset check for musicResume in Route B
    /// (b49fix17 P1-4/P2-2): every expected key must still be
    /// present, except keys clearResume deleted during this
    /// import (a natural completion is a legitimate concurrent
    /// event, same class as a checkpoint advancing). Values are
    /// not compared — resume seconds are progress markers
    /// (see BackupEngine.collectionVerifies).
    static func resumeEntriesPresent(
        _ expected: [String: Any], documentsURL: URL, toleratingDeleted deletedKeys: Set<String>
    ) -> Bool {
        let actual = readJSONDictionary(name: "musicResume", documentsURL: documentsURL)
        for key in expected.keys {
            if deletedKeys.contains(key) { continue }
            guard actual[key] != nil else { return false }
        }
        return true
    }

    /// Reads a [String] JSON file (b49fix17 P2-6): the
    /// string-list collections (search history, fav
    /// playlists, FM dislikes) merge like the dict lists.
    /// A file that exists but does not decode is quarantined,
    /// same as readJSONList — returning [] and then merging
    /// would let the next write overwrite the user's data.
    static func readJSONStringList(name: String, documentsURL: URL) -> [String] {
        let url = documentsURL.appendingPathComponent("\(name).json")
        guard let rawData = try? Data(contentsOf: url) else { return [] }
        guard let parsed = try? JSONSerialization.jsonObject(with: rawData, options: []),
              let list = parsed as? [String]
        else {
            LocalStore.quarantineFile(at: url, name: name, reason: "decode failed", documentsURL: documentsURL)
            return []
        }
        return list
    }

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

    /// A file that exists but does not decode is quarantined
    /// (b49fix2 P0-1 — same shape as LocalStore.loadCollection):
    /// returning [:] and then merging would let the next write
    /// permanently overwrite the user's data with the merged
    /// result. The corrupt file moves aside; the merge starts
    /// from empty with the original preserved for recovery.
    static func readJSONDictionary(name: String, documentsURL: URL) -> [String: Any] {
        let url = documentsURL.appendingPathComponent("\(name).json")
        guard let rawData = try? Data(contentsOf: url) else { return [:] }
        guard let parsed = try? JSONSerialization.jsonObject(with: rawData, options: []),
              let dict = parsed as? [String: Any]
        else {
            LocalStore.quarantineFile(at: url, name: name, reason: "decode failed", documentsURL: documentsURL)
            return [:]
        }
        return dict
    }

    static func readJSONList(name: String, documentsURL: URL) -> [[String: Any]] {
        let url = documentsURL.appendingPathComponent("\(name).json")
        guard let rawData = try? Data(contentsOf: url) else { return [] }
        guard let parsed = try? JSONSerialization.jsonObject(with: rawData, options: []),
              let list = parsed as? [[String: Any]]
        else {
            LocalStore.quarantineFile(at: url, name: name, reason: "decode failed", documentsURL: documentsURL)
            return []
        }
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
        case .data:
            return value is Data
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
            // b49fix17 P2-3: the restore takes the file's queue
            // when it has one — a queued writer (recordListenEvent,
            // saveDailyTracks) landing between this restore's
            // read and write used to write back "imported content
            // + new event", cancelling the rollback for that
            // file. The rollback is never called while holding
            // one of these queues (every merge's sync block has
            // returned by the time a failure path runs), so
            // taking it here cannot deadlock. Files with no
            // queue restore bare (see writeQueue(forCollection:)).
            let restoreOne = {
                let url = documentsURL.appendingPathComponent("\(entry.key).json")
                if let priorData = entry.value {
                    try? priorData.write(to: url, options: [.atomic])
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            if let queue = MigrationStore.writeQueue(forCollection: entry.key) {
                queue.sync(execute: restoreOne)
            } else {
                restoreOne()
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
            // b49fix2 P2-12: every attempt leaves a folder; keep
            // only the newest 5 so a failing migration cannot grow
            // migration_backup/ without bound.
            MigrationBackup.pruneOldBackups(documentsURL: documentsURL)
            return true
        } catch {
            return false
        }
    }

    /// Delete all but the newest 5 attempt folders under
    /// migration_backup/. Folder names start with a
    /// yyyyMMdd-HHmmss stamp, so lexicographic order is
    /// chronological; the UUID suffix keeps same-second folders
    /// distinct without breaking the order.
    static func pruneOldBackups(documentsURL: URL) {
        let base = documentsURL.appendingPathComponent(MigrationStore.backupDirectoryName)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
        let dirs = names.sorted().filter { name in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: base.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
        }
        guard dirs.count > 5 else { return }
        for name in dirs.dropLast(5) {
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
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

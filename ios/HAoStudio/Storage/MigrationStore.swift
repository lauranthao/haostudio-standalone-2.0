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
    /// Warnings a successful import still owes the user
    /// (b49fix19 P1-5): tolerated recent displacement (D-5c),
    /// the soft vodProg cap (D-6), dropped history entries
    /// (P1-1). Route A already had warnings on its detail;
    /// Route B dropped them — the success message never used
    /// report.detail, so the warnings were invisible. The UI
    /// prints these on the success path; `detail` keeps the
    /// same strings inline for the log line.
    let warnings: [String] = []

    static func empty(_ outcome: MigrationOutcome, detail: String, warnings: [String] = []) -> MigrationReport {
        MigrationReport(
            outcome: outcome, totalKeys: 0, migratedKeys: 0,
            skippedKeys: 0, unknownKeys: 0, failedKeys: 0,
            skippedKeyNames: [], unknownKeyNames: [], detail: detail,
            warnings: warnings
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
             // b49fix18 D-7: the Video/Live history writers take
             // this queue now (VideoLibraryStore / LiveLibraryStore
             // saveHistory), and so do the resolver-speed writer
             // (ResolverCooldown.save) and the download-tasks
             // mirror (DownloadEngine.persistLocked) — a history /
             // speed / task write landing inside the import merge's
             // re-read → write gap, or the restore's remove →
             // copy gap, is serialised after it instead of
             // cancelling the merge / rollback.
             "hao_video_hist", "hao_live_hist",
             "hao_resolver_speed", "downloadTasks",
             // b49fix20 D22-2: the video favourite toggle
             // (toggleFavourite / saveFavourites) and the
             // video/live search-history writers take this queue
             // now — their bare read-modify-write used to race
             // the import's merge and overwrite imported rows
             // with a stale pre-import list.
             "hao_video_fav", "hao_video_search_hist",
             "hao_live_search_hist":
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
        // b49fix19 P2-1: the download-tasks mirror (DownloadEngine
        // persistLocked) had no mapping row — a Route B JSON
        // carrying it landed in unknown, never installed.
        MigrationKeyMapping(key: "downloadTasks", kind: .json, destination: .collectionFile("downloadTasks")),
        MigrationKeyMapping(key: "musicResume", kind: .json, destination: .collectionFile("musicResume")),
        MigrationKeyMapping(key: "fmDislikedIds", kind: .json, destination: .collectionFile("fmDislikedIds")),
        // b49fix19 P2-1: the three favourite collections
        // (playlists / albums / artists) had no mapping rows —
        // Route A merged them, Route B isolated them as unknown.
        MigrationKeyMapping(key: "hao_fav_playlists", kind: .json, destination: .collectionFile("hao_fav_playlists")),
        MigrationKeyMapping(key: "hao_fav_albums", kind: .json, destination: .collectionFile("hao_fav_albums")),
        MigrationKeyMapping(key: "hao_fav_artists", kind: .json, destination: .collectionFile("hao_fav_artists")),
        MigrationKeyMapping(key: "hao_music_loudness_cache", kind: .json, destination: .collectionFile("hao_music_loudness_cache")),
        MigrationKeyMapping(key: "hao_local_music", kind: .json, destination: .collectionFile("hao_local_music")),
        // b49fix19 P2-1: the daily recommendation pool (a dict
        // merge like hao_daily) had no mapping row.
        MigrationKeyMapping(key: "hao_daily_pool", kind: .json, destination: .collectionFile("hao_daily_pool")),
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
        // b49fix19 P1-7: clear the cache-eviction record — the
        // verify excuses exactly the keys a live eviction
        // removes during THIS import.
        resetCacheEvictionRecord()
        // b49fix20 D22-7: clear the daily-cap record — the
        // report counts exactly the incoming songs the cap
        // dropped during THIS import.
        resetDailyCapDroppedRecord()
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
        // b49fix19 P1-1: history entries dropped by the plan-time
        // normaliser, per file — warned in the report, never
        // silently installed as unreadable rows.
        var historyDropped: [String: Int] = [:]

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
                        // (docs/storage-mapping.md:105 「斷點續播
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
                    } else if let shape = expectedCollectionShape(for: name),
                              !shape.matches(coerced) {
                        // b49fix18 D-8: a backup value with the
                        // wrong top-level shape (a dict where
                        // the reader expects a list) is corrupt:
                        // skip the key, do not install it — the
                        // old code wrote it straight through and
                        // the next live write rewrote the file
                        // from an empty table. Files with no
                        // known shape (nil) keep the old
                        // behaviour; the apply-time merge casts
                        // below are the second line of defence.
                        skipped.append(key)
                    } else {
                        var installValue = coerced
                        // b49fix19 P1-1: history entries are
                        // normalised at PLAN time — ISO/ms dates
                        // to seconds, missing required fields
                        // filled, unusable entries dropped and
                        // counted. A raw entry straight into the
                        // merge would fail the live typed reader
                        // for the WHOLE file (loadCollection
                        // quarantines it) and the next live write
                        // would overwrite the imported history.
                        if (name == "hao_video_hist" || name == "hao_live_hist"),
                           let list = coerced as? [[String: Any]] {
                            let normalized = normalizedHistoryEntries(list, file: name)
                            if normalized.dropped > 0 {
                                historyDropped[name, default: 0] += normalized.dropped
                            }
                            installValue = normalized.kept
                        }
                        fileWrites[name] = installValue
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

        // b49fix20 D22-12: plan-time warnings (history entries
        // the plan-time normaliser dropped) are built HERE,
        // before any write — every failure path below passes
        // them to failReport, so a failed import no longer
        // hides the dropped entries.
        var planWarnings: [String] = []
        if let dropped = historyDropped["hao_video_hist"], dropped > 0 {
            planWarnings.append("影视历史有 \(dropped) 条记录格式不符，已跳过")
        }
        if let dropped = historyDropped["hao_live_hist"], dropped > 0 {
            planWarnings.append("直播历史有 \(dropped) 条记录格式不符，已跳过")
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
                unknown: Array(unknown.keys), detail: "pre-write backup failed",
                warnings: planWarnings
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
        // b49fix18 D-1: the merged / written values the
        // fileWrites loop wrote — the verify below checks
        // content subset (merge files) / content equality
        // (whole-file files) against them, not just shape.
        var expectedListen: [[String: Any]]?
        var expectedLists: [String: [[String: Any]]] = [:]
        var expectedDicts: [String: [String: Any]] = [:]
        var expectedStringLists: [String: [String]] = [:]
        var expectedWholeFiles: [String: Any] = [:]
        // b49fix20 D22-5: the queue dicts that landed via the
        // .queueShapeOnly disposition (musicQueue) — written
        // files for the rollback, but NOT part of
        // expectedWholeFiles: verifyFileNow must still see
        // musicQueue as shape-only (a song switch after the
        // write legitimately replaced it), and a byte-equality
        // check there would false-fail the final sweep.
        var expectedQueueShapeOnly: [String: [String: Any]] = [:]
        var shapeOnlyFiles: Set<String> = []
        // b49fix18 D-1: the merged dicts the mergedFiles loop
        // wrote (hao_daily / haoVodProg) — subset verify, same
        // as the fileWrites merge files.
        var expectedMergedFiles: [String: [String: Any]] = [:]
        // b49fix18 D-6: whether the haoVodProg incoming set
        // alone exceeded the 200 cap (soft cap — see
        // cappedVodProgEntries), for the report.
        var vodProgOverCap = false
        var vodProgIncomingCount = 0
        // b49fix18 D-5c: recent entries the passing verify
        // excused (see verifyFileNow) — declared here so the
        // nested verify can record it.
        var recentToleratedMissing = 0
        let priorEmbyApiKey: String? = KeychainStore.loadEmbyApiKey()
        var wroteEmbyKeychain = false
        // b49fix19 P2-4: the live-history cap the merge uses —
        // 0 in the setting means unlimited (nil), absent means
        // the 50 default. Threaded into applyRouteBFileWrite so
        // the merge never truncates a history the user set to
        // unlimited.
        let liveHistLimit = liveHistoryCap(defaults: defaults)

        // b49fix20 D22-1: per-file verify INSIDE the write's
        // critical section. The fix19 verifyFileNow ran after
        // each write returned — a live write landing in the
        // remaining apply could still replace the file between
        // the write and its verify, so a merged file's verify
        // compared against a file that no longer held the merge.
        // Each merge branch now re-reads and subset-checks
        // inside its own queue.sync (see applyRouteBFileWrite
        // and the mergedFiles / listen / recent / resume blocks
        // below); whole-file files verify inside writeWholeNow.
        // verifyFileNow survives for the two bare writes (emby
        // config, unknown keys) and for the final sweep at the
        // end of the apply (D22-2a), which re-verifies every
        // applied file after ALL writes landed. The verify is
        // identity-based (P1-2), so a live writer that re-reads
        // and round-trips the file still passes: it includes
        // the imported entries under the same keys. Captures
        // the expected* values as they stand at call time.
        func verifyFileNow(_ name: String) -> Bool {
            if name == "hao_recent", let expected = expectedRecent {
                let actual = readJSONList(name: "hao_recent", documentsURL: documentsURL)
                guard recentContainsAll(actual: actual, expected: expected) else { return false }
                // b49fix18 D-5c: a passing verify that still
                // excused missing entries warns in the report
                // (counted below).
                recentToleratedMissing = recentMissingKeys(actual: actual, expected: expected).count
                return true
            }
            if name == "hao_listen", let expected = expectedListen {
                let actual = readJSONList(name: "hao_listen", documentsURL: documentsURL)
                return listKeysContainAll(actual: actual, expected: expected, file: "hao_listen")
            }
            if name == "musicResume", let expected = expectedResume {
                return resumeEntriesPresent(expected, documentsURL: documentsURL, toleratingDeleted: resumeDeletionRecord())
            }
            if let expected = expectedMergedFiles[name] {
                let actual = readJSONDictionary(name: name, documentsURL: documentsURL)
                // b49fix20 D22-7: hao_daily verifies per day by
                // value, not key-only — a live saveDailyTracks
                // replacing a whole day's songs must fail loud,
                // not pass on key presence.
                if name == "hao_daily" {
                    return dailyDaysContainAll(actual: actual, expected: expected)
                }
                return BackupEngine.dictContainsAll(actual, expected, keyOnly: true, toleratingDeleted: cacheEvictionRecord(for: name))
            }
            if let expected = expectedLists[name] {
                let actual = readJSONList(name: name, documentsURL: documentsURL)
                return listKeysContainAll(actual: actual, expected: expected, file: name)
            }
            if let expected = expectedDicts[name] {
                let actual = readJSONDictionary(name: name, documentsURL: documentsURL)
                return BackupEngine.dictContainsAll(actual, expected, keyOnly: true, toleratingDeleted: cacheEvictionRecord(for: name))
            }
            if let expected = expectedStringLists[name] {
                let actual = readJSONStringList(name: name, documentsURL: documentsURL)
                return stringListContainsAll(actual: actual, expected: expected)
            }
            if let expected = expectedWholeFiles[name] {
                return fileContentEquals(name: name, expected: expected, documentsURL: documentsURL)
            }
            if shapeOnlyFiles.contains(name) {
                return verifyFile(name: name, documentsURL: documentsURL)
            }
            return verifyFile(name: name, documentsURL: documentsURL)
        }

        // b49fix19 P1-4: the values this attempt wrote, for the
        // preserving rollback — what the restore must treat as
        // "import content" (as opposed to live increments made
        // during the import, which the restore keeps).
        func writtenMap() -> [String: (kind: RestoreKind, data: Data)] {
            var map: [String: (kind: RestoreKind, data: Data)] = [:]
            if let expected = expectedListen, let data = canonicalJSONData(expected) {
                map["hao_listen"] = (.mergeList, data)
            }
            if let expected = expectedRecent, let data = canonicalJSONData(expected) {
                map["hao_recent"] = (.mergeList, data)
            }
            if let expected = expectedResume, let data = canonicalJSONData(expected) {
                map["musicResume"] = (.mergeDict, data)
            }
            for (name, expected) in expectedLists {
                if let data = canonicalJSONData(expected) { map[name] = (.mergeList, data) }
            }
            for (name, expected) in expectedDicts {
                if let data = canonicalJSONData(expected) { map[name] = (.mergeDict, data) }
            }
            for (name, expected) in expectedStringLists {
                if let data = canonicalJSONData(expected) { map[name] = (.mergeStringList, data) }
            }
            for (name, expected) in expectedMergedFiles {
                if let data = canonicalJSONData(expected) { map[name] = (.mergeDict, data) }
            }
            for (name, expected) in expectedWholeFiles {
                if let data = canonicalJSONData(expected) { map[name] = (.wholeFile, data) }
            }
            // b49fix20 D22-5: a landed musicQueue is a written
            // file — restore it as (.wholeFile, bytes), so a
            // later failure does not skip it as unwritten and
            // leave the imported queue in place.
            for (name, expected) in expectedQueueShapeOnly {
                if let data = canonicalJSONData(expected) { map[name] = (.wholeFile, data) }
            }
            return map
        }

        // b49fix19 P1-4/P2-3: the rollback, returning what it
        // could not restore and what live content it kept, so
        // the failure report can say so instead of letting the
        // user believe a full rollback happened.
        func rollbackNow() -> (failures: [String], keptLive: [String]) {
            MigrationStore.rollback(
                journal: journal, priorEmbyApiKey: priorEmbyApiKey,
                wroteEmbyKeychain: wroteEmbyKeychain,
                documentsURL: documentsURL, defaults: defaults,
                written: writtenMap()
            )
        }

        for write in defaultWrites {
            if testFailOnKey == write.key {
                let rb = rollbackNow()
                return failReport(
                    total: data.count, migrated: appliedDefaults.count + appliedFiles.count,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "write failed for \(write.key)", rollback: rb,
                warnings: planWarnings
                )
            }
            journal.recordDefault(key: write.key, defaults: defaults)
            defaults.set(write.value, forKey: write.key)
            // b49fix19 P1-4: verify this default now — a
            // settings write landing between the set and an
            // end-of-apply verify used to fail the whole import
            // the same way a file write did.
            if !verifyDefault(key: write.key, kind: kindForDefaultKey(write.key), defaults: defaults) {
                let rb = rollbackNow()
                return failReport(
                    total: data.count, migrated: appliedDefaults.count + appliedFiles.count,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "verification failed for \(write.key)", rollback: rb,
                warnings: planWarnings
                )
            }
            appliedDefaults.append(write.key)
        }

        for name in fileWrites.keys.sorted() {
            guard let value = fileWrites[name] else { continue }
            if testFailOnKey == name {
                let rb = rollbackNow()
                return failReport(
                    total: data.count, migrated: appliedDefaults.count + appliedFiles.count,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "write failed for \(name)", rollback: rb,
                warnings: planWarnings
                )
            }
            journal.recordFile(name: name, documentsURL: documentsURL)
            // b49fix18 D-1: no longer a bare whole-file write —
            // each file takes its Route A disposition (see
            // applyRouteBFileWrite), and the written value is
            // captured for the content verify below. A live-wins
            // skip (musicQueue) counts as skipped, not migrated.
            switch applyRouteBFileWrite(name: name, value: value, documentsURL: documentsURL, defaults: defaults, liveHistLimit: liveHistLimit) {
            case .mergedList(let merged):
                expectedLists[name] = merged
                appliedFiles.append(name)
            case .mergedDict(let merged):
                expectedDicts[name] = merged
                appliedFiles.append(name)
            case .mergedStringList(let merged):
                expectedStringLists[name] = merged
                appliedFiles.append(name)
            case .wholeFile(let written):
                expectedWholeFiles[name] = written
                appliedFiles.append(name)
            case .queueShapeOnly(let written):
                // b49fix20 D22-5: a landed queue IS a written
                // file — record it for the rollback (as
                // .wholeFile, see writtenMap) instead of
                // leaving it out of writtenMap as unwritten.
                expectedQueueShapeOnly[name] = written
                shapeOnlyFiles.insert(name)
                appliedFiles.append(name)
            case .skipped:
                skipped.append(name)
            case .failed:
                let rb = rollbackNow()
                return failReport(
                    total: data.count, migrated: appliedDefaults.count + appliedFiles.count,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "write failed for \(name)", rollback: rb,
                warnings: planWarnings
                )
            case .verifyFailed(let kind, let value):
                // b49fix20 D22-1: the write landed but the
                // in-section verify failed — record what was
                // written before failing, so the rollback
                // treats this file as written (otherwise it
                // would skip it and leave suspect content in
                // place).
                switch kind {
                case .mergeList:
                    if let list = value as? [[String: Any]] { expectedLists[name] = list }
                case .mergeDict:
                    if let dict = value as? [String: Any] { expectedDicts[name] = dict }
                case .mergeStringList:
                    if let list = value as? [String] { expectedStringLists[name] = list }
                case .wholeFile:
                    expectedWholeFiles[name] = value
                }
                let rb = rollbackNow()
                return failReport(
                    total: data.count, migrated: 0,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "verification failed for \(name)", rollback: rb,
                warnings: planWarnings
                )
            }
            // b49fix20 D22-1: no outer verify any more — every
            // branch above verified inside its own critical
            // section (merged files re-read + subset-check in
            // their queue.sync, whole-file files in
            // writeWholeNow, musicQueue by exact re-read). A
            // skipped file wrote nothing, so there is nothing
            // to verify. The final sweep at the end of the
            // apply re-verifies every applied file (D22-2a).
        }

        for name in mergedFiles.keys.sorted() {
            guard let entries = mergedFiles[name] else { continue }
            journal.recordFile(name: name, documentsURL: documentsURL)
            // b49fix18 D-6: the vodProg cap is a soft cap — when
            // the incoming set alone exceeds 200 the file
            // exceeds 200 (see cappedVodProgEntries). Record it
            // for the report's detail suffix.
            if name == "haoVodProg", entries.count > 200 {
                vodProgOverCap = true
                vodProgIncomingCount = entries.count
            }
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
            // b49fix20 D22-1: the verify runs INSIDE the same
            // dailyWriteQueue.sync as the write (see
            // mergeVerified) — the old verifyFileNow ran after
            // the return, with the remaining apply in between.
            var mergeVerified = true
            let wroteMerged = dailyWriteQueue.sync { () -> Bool in
                let existing = readJSONDictionary(name: name, documentsURL: documentsURL)
                var merged = existing
                for entry in entries {
                    // b49fix19 P2-7: hao_daily merges per song,
                    // not per day — the old dict overlay replaced
                    // the whole day's list with the backup's, so
                    // a live day was silently replaced by an old
                    // backup day. When both sides of a day are
                    // song lists they merge (live first, dedupe
                    // by identityKey); any other shape (the
                    // fixture's {"picks": […]} dict, a corrupt
                    // day) keeps the overlay.
                    if name == "hao_daily",
                       let liveDay = existing[entry.key] as? [[String: Any]],
                       let incomingDay = entry.value as? [[String: Any]] {
                        merged[entry.key] = mergedDailyDay(live: liveDay, incoming: incomingDay)
                    } else {
                        merged[entry.key] = entry.value
                    }
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
                // b49fix18 D-1: capture the merged dict for
                // the in-section verify below and the final
                // sweep (the old shape-only check passed a file
                // a concurrent daily save had already rewritten).
                expectedMergedFiles[name] = merged
                guard writeJSONFile(name: name, value: merged, documentsURL: documentsURL) else {
                    return false
                }
                // b49fix20 D22-1/D22-7: verify INSIDE the
                // critical section — hao_daily uses the per-day
                // value check, the other merged file the
                // key-only dict check.
                let reread = readJSONDictionary(name: name, documentsURL: documentsURL)
                if name == "hao_daily" {
                    mergeVerified = dailyDaysContainAll(actual: reread, expected: merged)
                } else {
                    mergeVerified = BackupEngine.dictContainsAll(reread, merged, keyOnly: true, toleratingDeleted: cacheEvictionRecord(for: name))
                }
                return true
            }
            if !wroteMerged {
                let rb = rollbackNow()
                return failReport(
                    total: data.count, migrated: appliedDefaults.count + appliedFiles.count,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "write failed for \(name)", rollback: rb,
                warnings: planWarnings
                )
            }
            appliedFiles.append(name)
            guard mergeVerified else {
                let rb = rollbackNow()
                return failReport(
                    total: data.count, migrated: 0,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "verification failed for \(name)", rollback: rb,
                warnings: planWarnings
                )
            }
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
            var mergedListen: [[String: Any]] = []
            var listenVerified = true
            let wroteListen = listenLogWriteQueue.sync { () -> Bool in
                var existing = readJSONList(name: "hao_listen", documentsURL: documentsURL)
                // b49fix19 P2-6: the split point is known here
                // (live entries first, incoming appended after),
                // so the secondary title+artist key dedupes only
                // incoming entries against live ones — the live
                // log itself is never rewritten by a dedupe.
                let liveCount = existing.count
                existing.append(contentsOf: listenEntries)
                // b49fix2 P2-11: a re-import of the same backup used to
                // double the history (append with no dedupe). Same
                // song at the same second is the same listen, not two.
                existing = dedupedListenEntries(existing, liveCount: liveCount)
                if existing.count > 3000 {
                    existing = Array(existing.suffix(3000))
                }
                // b49fix18 D-1: capture the merged list for the
                // in-section verify below and the final sweep
                // (Route A parity — the old shape-only check
                // passed a listen file a concurrent completion
                // had already rewritten).
                mergedListen = existing
                guard writeJSONFile(name: "hao_listen", value: existing, documentsURL: documentsURL) else {
                    return false
                }
                // b49fix20 D22-1: verify INSIDE the critical
                // section (see the mergedFiles block above).
                let reread = readJSONList(name: "hao_listen", documentsURL: documentsURL)
                listenVerified = listKeysContainAll(actual: reread, expected: existing, file: "hao_listen")
                return true
            }
            if !wroteListen {
                let rb = rollbackNow()
                return failReport(
                    total: data.count, migrated: appliedDefaults.count + appliedFiles.count,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "write failed for hao_listen", rollback: rb,
                warnings: planWarnings
                )
            }
            expectedListen = mergedListen
            appliedFiles.append("hao_listen")
            guard listenVerified else {
                let rb = rollbackNow()
                return failReport(
                    total: data.count, migrated: 0,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "verification failed for hao_listen", rollback: rb,
                warnings: planWarnings
                )
            }
        }

        // b49fix17 P1-4: recent merges under recentWriteQueue,
        // the same queue writeRecent uses — a song switch
        // landing mid-merge is serialised after this write
        // instead of being overwritten by it, and the merged
        // list is captured for the content-subset verify below.
        if !recentEntries.isEmpty {
            journal.recordFile(name: "hao_recent", documentsURL: documentsURL)
            var mergedRecent: [[String: Any]] = []
            var recentVerified = true
            let wroteRecent = recentWriteQueue.sync { () -> Bool in
                let existing = readJSONList(name: "hao_recent", documentsURL: documentsURL)
                mergedRecent = mergedRecentEntries(live: existing, incoming: recentEntries)
                guard writeJSONFile(name: "hao_recent", value: mergedRecent, documentsURL: documentsURL) else {
                    return false
                }
                // b49fix20 D22-1: verify INSIDE the critical
                // section (tolerant check) — and the
                // tolerated-missing count for the report is
                // computed here, from the same re-read, instead
                // of after the return.
                let reread = readJSONList(name: "hao_recent", documentsURL: documentsURL)
                recentVerified = recentContainsAll(actual: reread, expected: mergedRecent)
                recentToleratedMissing = recentMissingKeys(actual: reread, expected: mergedRecent).count
                return true
            }
            if !wroteRecent {
                let rb = rollbackNow()
                return failReport(
                    total: data.count, migrated: appliedDefaults.count + appliedFiles.count,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "write failed for hao_recent", rollback: rb,
                warnings: planWarnings
                )
            }
            expectedRecent = mergedRecent
            appliedFiles.append("hao_recent")
            guard recentVerified else {
                let rb = rollbackNow()
                return failReport(
                    total: data.count, migrated: 0,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "verification failed for hao_recent", rollback: rb,
                warnings: planWarnings
                )
            }
        }

        // b49fix17 P1-4: resume merges under resumeWriteQueue,
        // the same queue saveResume / clearResume use — a
        // checkpoint that read the old map before this write
        // cannot write back after it and restore imported
        // values to pre-import values (b49fix17 P2-2).
        if !resumeEntries.isEmpty {
            journal.recordFile(name: "musicResume", documentsURL: documentsURL)
            var mergedResume: [String: Any] = [:]
            var resumeVerified = true
            let wroteResume = resumeWriteQueue.sync { () -> Bool in
                var existing = readJSONDictionary(name: "musicResume", documentsURL: documentsURL)
                for (key, value) in resumeEntries {
                    existing[key] = value
                }
                mergedResume = existing
                guard writeJSONFile(name: "musicResume", value: existing, documentsURL: documentsURL) else {
                    return false
                }
                // b49fix20 D22-1: verify INSIDE the critical
                // section (see the mergedFiles block above).
                let reread = readJSONDictionary(name: "musicResume", documentsURL: documentsURL)
                resumeVerified = resumeEntriesPresent(existing, actual: reread, toleratingDeleted: resumeDeletionRecord())
                return true
            }
            if !wroteResume {
                let rb = rollbackNow()
                return failReport(
                    total: data.count, migrated: appliedDefaults.count + appliedFiles.count,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "write failed for musicResume", rollback: rb,
                warnings: planWarnings
                )
            }
            expectedResume = mergedResume
            appliedFiles.append("musicResume")
            guard resumeVerified else {
                let rb = rollbackNow()
                return failReport(
                    total: data.count, migrated: 0,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "verification failed for musicResume", rollback: rb,
                warnings: planWarnings
                )
            }
        }

        if let config = embyConfig {
            journal.recordFile(name: "hao_emby_config", documentsURL: documentsURL)
            var stored = config
            stored.removeValue(forKey: "apiKey")
            if !writeJSONFile(name: "hao_emby_config", value: stored, documentsURL: documentsURL) {
                let rb = rollbackNow()
                return failReport(
                    total: data.count, migrated: appliedDefaults.count + appliedFiles.count,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "write failed for hao_emby_config", rollback: rb,
                warnings: planWarnings
                )
            }
            // b49fix18 D-1: capture the written config for the
            // content verify below (whole-file write, no live
            // writer in 2.0 — a settings save landing between
            // the write and the verify fails loud).
            expectedWholeFiles["hao_emby_config"] = stored
            appliedFiles.append("hao_emby_config")
            // b49fix19 P1-4: verify this file now (see
            // verifyFileNow).
            guard verifyFileNow("hao_emby_config") else {
                let rb = rollbackNow()
                return failReport(
                    total: data.count, migrated: 0,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "verification failed for hao_emby_config", rollback: rb,
                warnings: planWarnings
                )
            }
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
            // b49fix19 P1-4: verify the keychain write now, not
            // at the end of the apply.
            if wroteEmbyKeychain, let apiKey = embyApiKey, !apiKey.isEmpty,
               KeychainStore.loadEmbyApiKey() != apiKey {
                let rb = rollbackNow()
                return failReport(
                    total: data.count, migrated: 0,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "verification failed for emby apiKey", rollback: rb,
                warnings: planWarnings
                )
            }
        }

        if !unknown.isEmpty {
            journal.recordFile(name: unknownKeysFileName, documentsURL: documentsURL)
            var existing = readJSONDictionary(name: unknownKeysFileName, documentsURL: documentsURL)
            for entry in unknown {
                existing[entry.key] = entry.value
            }
            if !writeJSONFile(name: unknownKeysFileName, value: existing, documentsURL: documentsURL) {
                let rb = rollbackNow()
                return failReport(
                    total: data.count, migrated: appliedDefaults.count + appliedFiles.count,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "write failed for \(unknownKeysFileName)", rollback: rb,
                warnings: planWarnings
                )
            }
            // b49fix18 D-1: capture the merged dict for the
            // subset verify below (import-only file — nothing
            // else writes it, so a subset check is exact).
            expectedDicts[unknownKeysFileName] = existing
            appliedFiles.append(unknownKeysFileName)
            // b49fix19 P1-4: verify this file now (see
            // verifyFileNow).
            guard verifyFileNow(unknownKeysFileName) else {
                let rb = rollbackNow()
                return failReport(
                    total: data.count, migrated: 0,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "verification failed for \(unknownKeysFileName)", rollback: rb,
                warnings: planWarnings
                )
            }
        }

        // b49fix20 D22-2(a): the final sweep — every file was
        // verified inside its own critical section at write
        // time (D22-1), but a stale-state writer
        // (ResolverCooldown.save, DownloadEngine.persistLocked,
        // saveDailyTracks' day overwrite) can still wipe
        // imported content AFTER its file verified, because
        // those writers re-read nothing. Re-verify every
        // applied collection file now, after ALL writes landed
        // and before the success report — a failure here is
        // loud (fail + preserving rollback), never silent.
        // Defaults are excluded: a live settings change is
        // legitimate, not import loss. musicQueue verifies by
        // shape only (a song switch after the write
        // legitimately replaced it).
        for name in appliedFiles.sorted() {
            guard verifyFileNow(name) else {
                let rb = rollbackNow()
                return failReport(
                    total: data.count, migrated: 0,
                    skipped: skipped, unknown: Array(unknown.keys),
                    detail: "final verification failed for \(name)", rollback: rb,
                    warnings: planWarnings
                )
            }
        }

        // b49fix20 D22-8: sweep both unknown-keys files
        // against the current mapping table and delete keys
        // that now have a mapping row — the unknown merge only
        // ever added, so the five P2-1 keys stayed in the old
        // files forever after they gained a mapping. Runs
        // AFTER the final sweep above (the sweep verifies the
        // unknown file against its pre-cleanup expected dict)
        // and only on success — a failed import rolls back, so
        // installed keys are not final.
        sweepUnknownKeysFiles(documentsURL: documentsURL)

        if markDone {
            defaults.set(true, forKey: doneKey)
        }
        let migrated = appliedDefaults.count + appliedFiles.count
        // b49fix19 P1-5: warnings a successful import still
        // owes the user — the success message prints them
        // (BackupUpdateViews), and `detail` keeps the same
        // strings inline for the log line. Starts from the
        // plan-time warnings (b49fix20 D22-12: dropped history
        // entries), which the failure paths also carry now.
        var warnings: [String] = planWarnings
        if embyTokenSkipped {
            warnings.append("emby apiKey 未保存到钥匙串")
        }
        // b49fix18 D-5c: a passing recent verify that still
        // excused missing entries says so — the displacement
        // is observable instead of silent.
        if recentToleratedMissing > 0 {
            warnings.append("最近播放有 \(recentToleratedMissing) 条记录在导入期间被替换，已按容忍规则通过校验")
        }
        // b49fix18 D-6: the vodProg cap is a soft cap — when
        // the incoming set alone exceeded 200 the file exceeds
        // 200 (see cappedVodProgEntries). Say so.
        if vodProgOverCap {
            warnings.append("点播续播记录超过 200 条上限（本次导入带入 \(vodProgIncomingCount) 条），已全部保留")
        }
        // b49fix20 D22-7: days that exceeded the 20-song cap
        // dropped incoming songs — counted, never silent.
        let dailyDropped = dailyCapDroppedDuringImport()
        if dailyDropped > 0 {
            warnings.append("每日推薦有 \(dailyDropped) 首匯入歌曲超出每日 20 首上限，已跳過")
        }
        let detailSuffix = warnings.map { "; " + $0 }.joined()
        return MigrationReport(
            outcome: .migrated, totalKeys: data.count,
            migratedKeys: migrated, skippedKeys: skipped.count,
            unknownKeys: unknown.count, failedKeys: 0,
            skippedKeyNames: skipped.sorted(),
            unknownKeyNames: Array(unknown.keys).sorted(),
            warnings: warnings,
            detail: "migrated \(migrated) of \(data.count) keys\(detailSuffix)"
        )
    }

    /// What one Route B fileWrite wrote (b49fix18 D-1): the
    /// verify material. The loop records one of these per
    /// file and the verify below checks it — no file is
    /// verified by shape alone any more, except musicQueue
    /// (whose live-wins rule makes any stronger check
    /// false-fail, Route A parity).
    private enum RouteBWrite {
        /// Merged list — identity-subset verify
        /// (listKeysContainAll).
        case mergedList([[String: Any]])
        /// Merged dict — subset verify (dictContainsAll).
        case mergedDict([String: Any])
        /// Merged string list — subset verify.
        case mergedStringList([String])
        /// Whole-file value — content verify
        /// (fileContentEquals).
        case wholeFile(Any)
        /// musicQueue landed — shape-only verify. Carries the
        /// written queue dict so writtenMap can record it
        /// (b49fix20 D22-5): a landed queue is a written file,
        /// and the rollback must restore it as (.wholeFile,
        /// bytes) instead of skipping it as unwritten.
        case queueShapeOnly([String: Any])
        /// Live wins (musicQueue non-empty) or wrong element
        /// shape — counts as skipped, not migrated.
        case skipped
        /// Write / serialisation failure.
        case failed
        /// The write landed but the immediate re-read inside
        /// the write's critical section did not match it
        /// (b49fix19 P1-4, b49fix20 D22-1): a live writer
        /// replaced the file between the write and its verify.
        /// The caller fails the import with a verification
        /// failure, not a write failure — the write itself
        /// succeeded. Carries the written value (and its
        /// restore kind) so the caller can record it in the
        /// expected* maps before failing: the rollback must
        /// treat this file as written, or it would skip it and
        /// leave suspect content in place.
        case verifyFailed(RestoreKind, Any)
    }

    /// Applies one Route B fileWrite (b49fix18 D-1): the
    /// fileWrites loop used to be a bare whole-file write with
    /// no queue — a song switch / favourite toggle / checkpoint
    /// landing before it was silently lost, and one landing
    /// after it passed the shape-only verify. Every file now
    /// takes the Route A disposition for the same file.
    ///
    /// Per-file dispositions (38 files — every
    /// .collectionFile destination except hao_listen /
    /// hao_recent / musicResume, which merge in their own
    /// blocks above; the merge rule itself is the shared
    /// helper, live first, dedupe, cap — see
    /// mergedListEntries / mergedStringList):
    ///
    /// MERGE, live-wins (musicQueue): live non-empty →
    /// skipped (the backup queue never replaces the queue
    /// being listened to); live empty → the backup queue
    /// lands, with an apply-time exact re-read (Route A
    /// mergeMusicQueue parity). Shape-only verify.
    ///
    /// MERGE, list, under collectionWriteQueue:
    /// - hao_fav — toggleFav, user tap — dedupe by the
    ///   normalised fav key (P1-3: the song's identityKey, or
    ///   the stored "key" with its platform prefix
    ///   normalised); the stored key is rewritten to it.
    /// - hao_lists — saveLists + playlist edits — dedupe
    ///   by "id".
    /// - hao_fav_albums / hao_fav_artists (P2-1) — dedupe
    ///   by id+name.
    /// - musicDownloads — saveDownloads / removeDownload —
    ///   dedupe by the nested song's identityKey.
    /// - hao_video_hist — VideoLibraryStore.saveHistory, every
    ///   VOD play — dedupe title+year, cap 20. (D-7: the
    ///   writer takes collectionWriteQueue now.)
    /// - hao_live_hist — LiveLibraryStore.saveHistory, every
    ///   room open — dedupe platform|roomId, cap from
    ///   historyLimit() (P2-4: 0 = unlimited, absent = 50).
    ///   (D-7: the writer takes collectionWriteQueue now.)
    ///
    /// MERGE, dict overlay (incoming wins on conflict),
    /// under collectionWriteQueue:
    /// - hao_cover_cache — saveCover, cover resolve.
    /// - hao_lyrics — putLyrics / read-path cleanup; the
    ///   merge writes imported keys into the lyrics order
    ///   file (P1-7) so they are not evicted first.
    /// - hao_music_loudness_cache — no 2.0 writer found
    ///   (belt-and-braces, same as Route A).
    /// - hao_daily_pool (P2-1) — saveDailyPool — dict merge
    ///   with the same 7-day prune live writes apply, under
    ///   dailyWriteQueue.
    ///
    /// MERGE, string list, under collectionWriteQueue:
    /// - fmDislikedIds — addFMDisliked, FM dislike tap.
    /// - hao_music_search_hist — saveSearchQuery — cap 20.
    /// - hao_fav_playlists (P2-1) — favourite playlist ids.
    ///
    /// WHOLE-FILE + CONTENT VERIFY (no queue — their live
    /// writers are bare user-action / background writes, so
    /// the import write is bare too; a live write landing
    /// between the write and the verify fails loud with a
    /// rollback, never silently):
    /// - hao_local_music — pruneLocalSongs / rescan, user
    ///   action.
    /// - hao_resolver_speed — ResolverCooldown.save, per
    ///   resolve (D-7: the writer takes collectionWriteQueue
    ///   now, so this write takes it too via writeQueue).
    /// - downloadTasks (P2-1) — DownloadEngine.persistLocked
    ///   (D-7: takes collectionWriteQueue now, same as the
    ///   resolver speed above).
    /// - hao_wallpaper_paths — wallpaper settings.
    /// - hao_video_fav — video favourite toggle.
    /// - hao_video_search_hist — video search history.
    /// - hao_video_home — video home cache.
    /// - hao_video_category_prefs — video category prefs.
    /// - hao_live_follows — live follows.
    /// - hao_live_search_hist — live search history.
    /// - hao_live_sources — live sources settings.
    /// - hao_danmaku_enabled — danmaku settings (dict).
    /// - hao_dm_block — danmaku block list.
    /// - hao_douban_detail — Douban detail cache.
    /// - hao_douban_idmap — Douban id map.
    /// - hao_sa_video — CMS video sources.
    /// - hao_vod_skip_intro_durations — VOD skip-intro prefs
    ///   (no 2.0 writer yet).
    /// - hao_lx_custom — LX custom scripts.
    /// - hao_lx_deleted_bundled — LX deleted bundled ids.
    /// - hao_lx_disabled — LX disabled script ids.
    /// - hao_lx_explicit_enabled — LX explicit enabled ids.
    /// - hao_lx_order — LX script order.
    /// - hao_eq_custom_presets — EQ custom presets.
    ///
    /// A file not listed above (a future mapping) takes the
    /// whole-file default, with its queue when writeQueue
    /// knows one — never a bare write for a file that has a
    /// queue.
    private static func applyRouteBFileWrite(
        name: String, value: Any, documentsURL: URL, defaults: UserDefaults, liveHistLimit: Int? = 50
    ) -> RouteBWrite {
        // musicQueue: live-wins (Route A mergeMusicQueue).
        if name == "musicQueue" {
            guard let dict = value as? [String: Any] else { return .skipped }
            return musicQueueWriteQueue.sync { () -> RouteBWrite in
                let live = readJSONDictionary(name: "musicQueue", documentsURL: documentsURL)
                let liveSongs = live["songs"] as? [[String: Any]] ?? []
                guard liveSongs.isEmpty else { return .skipped }
                guard writeJSONFile(name: name, value: dict, documentsURL: documentsURL) else {
                    return .failed
                }
                // Apply-time exact re-read (Route A parity):
                // proves the backup queue landed before the
                // caller counts it as applied. Canonical bytes,
                // not raw — writeJSONFile serialises dicts in
                // hash order.
                let url = documentsURL.appendingPathComponent("musicQueue.json")
                guard let reread = try? Data(contentsOf: url),
                      let parsed = try? JSONSerialization.jsonObject(with: reread, options: []),
                      let rereadDict = parsed as? [String: Any],
                      canonicalJSONData(rereadDict) == canonicalJSONData(dict)
                else { return .failed }
                return .queueShapeOnly(dict)
            }
        }
        // List merges (see the table above for keyFor / cap).
        if name == "hao_fav" || name == "hao_lists" || name == "musicDownloads"
            || name == "hao_video_hist" || name == "hao_live_hist"
            || name == "hao_fav_albums" || name == "hao_fav_artists" {
            guard let list = value as? [[String: Any]] else { return .skipped }
            let keyFor: ([String: Any]) -> String
            let secondaryKeyFor: (([String: Any]) -> String)?
            let mapEntry: (([String: Any]) -> [String: Any])?
            let cap: Int?
            if name == "hao_fav" {
                // b49fix19 P1-3: dedupe by the normalised fav
                // key (not the raw stored "key"), and rewrite
                // each stored key to it — otherwise an lx
                // favourite and a wy favourite are duplicate
                // rows and the lx row can never be unfavourited.
                // b49fix19 P2-6: the secondary title+artist key
                // dedupes a key-only legacy entry against the
                // same song that later gained a songId.
                keyFor = { favMergeKey(for: $0) }
                secondaryKeyFor = { song in
                    guard let songDict = song["song"] as? [String: Any] else { return "" }
                    return songTitleArtistKey(for: songDict)
                }
                mapEntry = { entry in
                    var entry = entry
                    // An entry with no song and no key has no
                    // identity to normalise to — leave it alone
                    // instead of stamping an empty "key" on it.
                    let key = favMergeKey(for: entry)
                    if !key.isEmpty { entry["key"] = key }
                    return entry
                }
                cap = nil
            } else if name == "hao_lists" {
                keyFor = { ($0["id"] as? String) ?? "" }; secondaryKeyFor = nil; mapEntry = nil; cap = nil
            } else if name == "musicDownloads" {
                keyFor = { guard let song = $0["song"] as? [String: Any] else { return "" }; return songIdentityKey(for: song) }
                secondaryKeyFor = { guard let song = $0["song"] as? [String: Any] else { return "" }; return songTitleArtistKey(for: song) }
                mapEntry = nil; cap = nil
            } else if name == "hao_fav_albums" || name == "hao_fav_artists" {
                keyFor = { (($0["id"] as? String) ?? "") + "|" + (($0["name"] as? String) ?? "") }; secondaryKeyFor = nil; mapEntry = nil; cap = nil
            } else if name == "hao_video_hist" {
                keyFor = { videoHistoryDedupeKey(for: $0) }; secondaryKeyFor = nil; mapEntry = nil; cap = 20
            } else {
                keyFor = { (($0["platform"] as? String) ?? "") + "|" + (($0["roomId"] as? String) ?? "") }
                secondaryKeyFor = nil; mapEntry = nil
                // b49fix19 P2-4: the cap comes from the user's
                // setting (nil = unlimited), not a hard-coded 50.
                cap = liveHistLimit
            }
            return collectionWriteQueue.sync { () -> RouteBWrite in
                let existing = readJSONList(name: name, documentsURL: documentsURL)
                let merged = mergedListEntries(live: existing, incoming: list, keyFor: keyFor, cap: cap, secondaryKeyFor: secondaryKeyFor, mapEntry: mapEntry)
                guard writeJSONFile(name: name, value: merged, documentsURL: documentsURL) else {
                    return .failed
                }
                // b49fix20 D22-1: verify INSIDE the critical
                // section — the re-read runs in the same
                // queue.sync as the write, so no queued writer
                // can land between them (the old outer
                // verifyFileNow ran after the return, with the
                // whole remaining apply in between).
                let reread = readJSONList(name: name, documentsURL: documentsURL)
                guard listKeysContainAll(actual: reread, expected: merged, file: name) else {
                    return .verifyFailed(.mergeList, merged)
                }
                return .mergedList(merged)
            }
        }
        // Dict-overlay merges.
        if name == "hao_cover_cache" || name == "hao_lyrics" || name == "hao_music_loudness_cache" {
            guard let dict = value as? [String: Any] else { return .skipped }
            return collectionWriteQueue.sync { () -> RouteBWrite in
                var existing = readJSONDictionary(name: name, documentsURL: documentsURL)
                for (key, incomingValue) in dict {
                    existing[key] = incomingValue
                }
                if name == "hao_lyrics" {
                    // b49fix19 P1-7: imported keys go into the
                    // order file (appended at the end, newest)
                    // so the next putLyrics does not treat them
                    // as unknown and evict them first. The
                    // import's defaults (the test suite in
                    // tests, .standard in production) — the live
                    // putLyrics reads the same store.
                    reconcileLyricsCacheOrder(
                        mergedKeys: Set(existing.keys),
                        importedKeys: Array(dict.keys),
                        defaults: defaults
                    )
                }
                if name == "hao_cover_cache" {
                    // b49fix20 D22-9: trim the merged cache to
                    // the live 500 cap (see trimmedCoverCache)
                    // — the merge used to grow the file past
                    // the cap the live writer enforces.
                    existing = trimmedCoverCache(merged: existing, incomingKeys: Set(dict.keys))
                }
                guard writeJSONFile(name: name, value: existing, documentsURL: documentsURL) else {
                    return .failed
                }
                // b49fix20 D22-1: verify INSIDE the critical
                // section (see the list branch above).
                let reread = readJSONDictionary(name: name, documentsURL: documentsURL)
                guard BackupEngine.dictContainsAll(reread, existing, keyOnly: true, toleratingDeleted: cacheEvictionRecord(for: name)) else {
                    return .verifyFailed(.mergeDict, existing)
                }
                return .mergedDict(existing)
            }
        }
        // Dict merge for the daily pool (b49fix19 P2-1): same
        // 7-day prune live writes apply, under dailyWriteQueue
        // (Route A mergeDictEntries parity).
        if name == "hao_daily_pool" {
            guard let dict = value as? [String: Any] else { return .skipped }
            return dailyWriteQueue.sync { () -> RouteBWrite in
                var existing = readJSONDictionary(name: name, documentsURL: documentsURL)
                for (key, incomingValue) in dict {
                    existing[key] = incomingValue
                }
                existing = prunedDailyEntries(existing, keeping: nil)
                guard writeJSONFile(name: name, value: existing, documentsURL: documentsURL) else {
                    return .failed
                }
                // b49fix20 D22-1: verify INSIDE the critical
                // section (see the list branch above).
                let reread = readJSONDictionary(name: name, documentsURL: documentsURL)
                guard BackupEngine.dictContainsAll(reread, existing, keyOnly: true, toleratingDeleted: cacheEvictionRecord(for: name)) else {
                    return .verifyFailed(.mergeDict, existing)
                }
                return .mergedDict(existing)
            }
        }
        // String-list merges.
        if name == "fmDislikedIds" || name == "hao_music_search_hist" || name == "hao_fav_playlists" {
            guard let list = value as? [String] else { return .skipped }
            let cap = name == "hao_music_search_hist" ? 20 : nil
            return collectionWriteQueue.sync { () -> RouteBWrite in
                let existing = readJSONStringList(name: name, documentsURL: documentsURL)
                let merged = mergedStringList(live: existing, incoming: list, cap: cap)
                guard writeJSONFile(name: name, value: merged, documentsURL: documentsURL) else {
                    return .failed
                }
                // b49fix20 D22-1: verify INSIDE the critical
                // section (see the list branch above).
                let reread = readJSONStringList(name: name, documentsURL: documentsURL)
                guard stringListContainsAll(actual: reread, expected: merged) else {
                    return .verifyFailed(.mergeStringList, merged)
                }
                return .mergedStringList(merged)
            }
        }
        // Whole-file default (see the table above): the write
        // takes the file's queue when it has one (D-7:
        // hao_resolver_speed's writer takes
        // collectionWriteQueue now), and is bare otherwise.
        // b49fix19 P1-4: the write and its immediate verify run
        // in one critical section when the file has a queue —
        // a queued writer (ResolverCooldown.save,
        // DownloadEngine.persistLocked) cannot land between
        // the write and the verify at all; a bare writer's
        // window is the microseconds between the two lines.
        // The verify is canonical (fileContentEquals), so a
        // live re-serialisation with a different key order
        // still passes.
        func writeWholeNow() -> RouteBWrite {
            guard writeJSONFile(name: name, value: value, documentsURL: documentsURL) else {
                return .failed
            }
            guard fileContentEquals(name: name, expected: value, documentsURL: documentsURL) else {
                return .verifyFailed(.wholeFile, value)
            }
            return .wholeFile(value)
        }
        if let queue = writeQueue(forCollection: name) {
            return queue.sync(execute: writeWholeNow)
        }
        return writeWholeNow()
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
    /// backup must not double the history. b49fix18 D-4: the
    /// platform is normalised through MusicPlatform.fromCode
    /// first (see songIdentityKey) — a backup listen entry with
    /// `platform: "lx:…"` and the live entry the typed layer
    /// already rewrote to `"wy"` are the same listen, not two.
    static func listenDedupeKey(for entry: [String: Any]) -> String {
        let platform = MusicPlatform.fromCode(entry["platform"] as? String).rawValue
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
    ///
    /// b49fix19 P2-6: `liveCount` is the number of entries that
    /// were already live when the merge ran (the caller appends
    /// the incoming entries after them). An incoming entry whose
    /// songId is empty in the backup but present live (or vice
    /// versa) shares platform + title + artist + timestamp with
    /// the live entry, so it dedupes on the secondary key too —
    /// without it the same listen becomes two rows. The
    /// secondary key is checked ONLY for incoming entries:
    /// two live entries that share it are both kept, the live
    /// log is never rewritten by a dedupe. Callers that do not
    /// know the split pass nil, and the secondary check applies
    /// to every entry after the first (the old single-array
    /// callers have no live data to preserve).
    static func dedupedListenEntries(
        _ entries: [[String: Any]], liveCount: Int? = nil
    ) -> [[String: Any]] {
        var seen = Set<String>()
        var seenSecondary = Set<String>()
        var out: [[String: Any]] = []
        out.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            let primary = listenDedupeKey(for: entry)
            if seen.contains(primary) { continue }
            let isIncoming = liveCount.map { index >= $0 } ?? true
            if isIncoming {
                let secondary = listenSecondaryKey(for: entry)
                if !secondary.isEmpty && seenSecondary.contains(secondary) { continue }
            }
            seen.insert(primary)
            let secondary = listenSecondaryKey(for: entry)
            if !secondary.isEmpty { seenSecondary.insert(secondary) }
            out.append(entry)
        }
        return out
    }

    /// Secondary dedupe key for one listen entry (b49fix19
    /// P2-6): platform + title + artist + timestamp — the same
    /// listen recorded once without a songId and once with it.
    /// Empty when both title and artist are empty: a key with
    /// no content matches nothing.
    static func listenSecondaryKey(for entry: [String: Any]) -> String {
        let title = entry["title"] as? String ?? ""
        let artist = entry["artist"] as? String ?? ""
        guard !title.isEmpty || !artist.isEmpty else { return "" }
        let platform = MusicPlatform.fromCode(entry["platform"] as? String).rawValue
        let at: String
        if let number = numberValue(entry["at"]) {
            at = "\(number.intValue)"
        } else if let text = entry["at"] as? String {
            at = text
        } else {
            at = ""
        }
        return "\(platform)|\(title)|\(artist)|\(at)"
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
    ///
    /// b49fix18 D-6 — the cap is a SOFT cap: when the incoming
    /// set ALONE exceeds 200, the file exceeds 200 (the first
    /// loop writes every incoming key, uncapped), and the file
    /// does not converge back below 200 on re-import of the
    /// same backup — haoVodProg has no live writer that would
    /// trim it, and the next import brings the same incoming
    /// batch. Truncating the incoming set instead would drop
    /// just-imported entries, against P2-1's intent, so the
    /// behaviour stays and the callers warn in the import
    /// report when the incoming set exceeds 200 (Route A:
    /// applyPlannedImport's commit; Route B: importData's
    /// detail suffix).
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

    /// Identity key of one song JSON dict (b49fix17 P1-2/P2-6,
    /// b49fix18 D-4): the same rule MusicSong.identityKey uses —
    /// platform + song id, falling back to title + artist +
    /// album when the id is empty — computed from the raw dict
    /// so the import merges can dedupe without MusicSong
    /// (AppCore cannot see Features types). The platform is
    /// normalised through MusicPlatform.fromCode FIRST: the
    /// typed layer rewrites any unknown code (an LX script id
    /// `lx:…`, an empty code) to `wy` on its first round-trip
    /// (MusicSong.init(json:) → toJSON()), so a key computed
    /// from the raw string would call the backup entry
    /// `lx:xxx|id` and the live entry `wy|id` two different
    /// songs — the merge would keep both (a duplicate pair)
    /// and the byte-subset verify would fail on the rewrite
    /// (a false rollback). Normalising here makes the merge
    /// layer's key identical to the typed layer's key.
    ///
    /// Three identityKey schemes exist in the codebase — do
    /// not "unify" them by hand, they answer different
    /// questions: (1) this function + MusicSong.identityKey,
    /// `platform|songId` with the platform normalised to a
    /// known code (`wy` for anything unknown) — the stored
    /// song's identity; (2) MusicTrack.identityKey,
    /// `sourceID|songId`, where sourceID keeps the raw LX
    /// script id (`lx:…|id`) — the resolver's identity, used
    /// for search/cache keys where the script matters;
    /// (3) listenDedupeKey, `platform|songId|at` (also
    /// normalised, D-4) — a listen event's identity, where the
    /// timestamp is part of the key. The live-write layer
    /// keeps the raw `sourceID` field verbatim (MusicSong
    /// preserves it), so no script identity is lost when the
    /// platform normalises — only the platform field changes.
    ///
    /// Residual (D-4, closed by b49fix19 P1-2/P1-3): this
    /// normalises the KEY, not the stored entry's `platform`
    /// field — a brand-new `lx:…` entry that survives the
    /// merge keeps its raw platform bytes in the merged file.
    /// That used to false-fail the byte-subset verify when a
    /// live round-trip rewrote those bytes to `wy` between the
    /// import write and its verify; the verify now compares
    /// identity keys (listKeysContainAll), and the fav merge
    /// rewrites the stored key field, so the rewrite no longer
    /// fails anything. The stored platform field itself stays
    /// raw (the D-4 ruling never approved rewriting it), and
    /// the next live round-trip normalises it in place.
    static func songIdentityKey(for entry: [String: Any]) -> String {
        let platform = MusicPlatform.fromCode(entry["platform"] as? String).rawValue
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
    /// b49fix19 P2-5: the year is loosely converted (an
    /// integer year in the backup is a string after this) —
    /// the old String-only cast degraded the key to
    /// title-only and merged same-title different-year films.
    static func videoHistoryDedupeKey(for entry: [String: Any]) -> String {
        guard let item = entry["item"] as? [String: Any] else { return "" }
        let title = looseString(item["title"])
        let year = looseString(item["year"]).trimmingCharacters(in: .whitespaces)
        return year.isEmpty ? title : "\(title)-\(year)"
    }

    /// Loose string coercion for raw backup dicts (b49fix19
    /// P1-1 / P2-5): a String stays, a JSON number becomes its
    /// plain string form (an integer year `2024` is the string
    /// "2024"), anything else is "". AppCore cannot see
    /// MusicDict, so the rule is restated here.
    static func looseString(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let number = numberValue(value) { return number.stringValue }
        return ""
    }

    /// One history date as seconds since 1970 (b49fix19 P1-1):
    /// the live typed readers decode Date from a seconds
    /// number ONLY (no dateDecodingStrategy anywhere), but a
    /// Flutter backup may carry the date as an ISO-8601 string
    /// (Dart jsonEncode(DateTime)) or a milliseconds integer.
    /// Accepts all three shapes; nil when unparseable (the
    /// caller substitutes now). Two-stage threshold (b49fix20
    /// D22-11): >1e14 is microseconds (/1e6), >1e11 is
    /// milliseconds (/1000), else seconds — the old single
    /// threshold divided microseconds (~1.7e15) by 1000 as if
    /// they were milliseconds, landing in year ~55,000 and
    /// never sorting right. A pure date ("2026-11-25") fails
    /// both ISO8601 formatters, so a yyyy-MM-dd fallback
    /// parses it as midnight GMT instead of the caller
    /// substituting now.
    static func historyDateSeconds(from value: Any?) -> TimeInterval? {
        if let number = numberValue(value) {
            let seconds = number.doubleValue
            if seconds > 1e14 { return seconds / 1_000_000 }
            if seconds > 1e11 { return seconds / 1000 }
            return seconds
        }
        if let text = value as? String {
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: text) { return date.timeIntervalSince1970 }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) { return date.timeIntervalSince1970 }
            let dayOnly = DateFormatter()
            dayOnly.locale = Locale(identifier: "en_US_POSIX")
            dayOnly.timeZone = TimeZone(secondsFromGMT: 0)
            dayOnly.dateFormat = "yyyy-MM-dd"
            if let date = dayOnly.date(from: text) { return date.timeIntervalSince1970 }
        }
        return nil
    }

    /// One video-history entry through the live typed shape
    /// (b49fix19 P1-1): VideoHistoryEntry has 7 non-optional
    /// fields (item.id/title, episodeName, episodeIndex,
    /// lineName, positionSeconds, durationSeconds, updatedAt)
    /// and VideoItem's coverURL must be a valid URL, its year
    /// a string, its sourceId an integer — a backup entry
    /// that violates any of these decodes the WHOLE file to
    /// failure (loadCollection quarantines it) and the next
    /// live write overwrites the imported history with one
    /// row. Returns nil for an entry with no usable identity
    /// (no item dict, or an empty title); fills every other
    /// missing field with its live default instead of dropping
    /// the row. The returned entry decodes under the default
    /// JSONDecoder, so the merged file is live-readable.
    static func normalizedVideoHistoryEntry(_ entry: [String: Any]) -> [String: Any]? {
        guard let item = entry["item"] as? [String: Any] else { return nil }
        let title = looseString(item["title"])
        guard !title.isEmpty else { return nil }
        var outItem: [String: Any] = [
            "id": looseString(item["id"]),
            "title": title,
        ]
        if let cover = item["coverURL"] as? String, !cover.isEmpty, URL(string: cover) != nil {
            outItem["coverURL"] = cover
        }
        let year = looseString(item["year"])
        if !year.isEmpty { outItem["year"] = year }
        if let typeName = item["typeName"] as? String { outItem["typeName"] = typeName }
        if let remarks = item["remarks"] as? String { outItem["remarks"] = remarks }
        if let sourceId = numberValue(item["sourceId"]) { outItem["sourceId"] = sourceId.intValue }
        var out: [String: Any] = ["item": outItem]
        out["episodeName"] = looseString(entry["episodeName"])
        out["episodeIndex"] = numberValue(entry["episodeIndex"])?.intValue ?? 0
        out["lineName"] = looseString(entry["lineName"])
        out["positionSeconds"] = numberValue(entry["positionSeconds"])?.doubleValue ?? 0
        out["durationSeconds"] = numberValue(entry["durationSeconds"])?.doubleValue ?? 0
        out["updatedAt"] = historyDateSeconds(from: entry["updatedAt"]) ?? Date().timeIntervalSince1970
        return out
    }

    /// One live-history entry through the live typed shape
    /// (b49fix19 P1-1): LiveHistoryEntry has 6 non-optional
    /// fields (platform, roomId, title, nick, cover,
    /// watchedAt) plus optional playUrlsJSON. Returns nil for
    /// an entry with no usable identity (empty platform or
    /// roomId); fills the rest with live defaults. Same
    /// guarantee as the video normaliser: the returned entry
    /// decodes under the default JSONDecoder.
    static func normalizedLiveHistoryEntry(_ entry: [String: Any]) -> [String: Any]? {
        let platform = looseString(entry["platform"])
        let roomId = looseString(entry["roomId"])
        guard !platform.isEmpty, !roomId.isEmpty else { return nil }
        var out: [String: Any] = [
            "platform": platform,
            "roomId": roomId,
            "title": looseString(entry["title"]),
            "nick": looseString(entry["nick"]),
            "cover": looseString(entry["cover"]),
            "watchedAt": historyDateSeconds(from: entry["watchedAt"]) ?? Date().timeIntervalSince1970,
        ]
        if let urls = entry["playUrlsJSON"] as? String { out["playUrlsJSON"] = urls }
        return out
    }

    /// Normalises a backup history list for the merge
    /// (b49fix19 P1-1): every entry through the live typed
    /// shape, unusable entries dropped and counted (the caller
    /// warns with the count). Callers run this at PLAN time,
    /// so the merge only ever sees live-readable entries —
    /// a backup that bypassed the plan would reintroduce the
    /// quarantine hole, so no merge path skips it.
    static func normalizedHistoryEntries(
        _ entries: [[String: Any]], file: String
    ) -> (kept: [[String: Any]], dropped: Int) {
        var kept: [[String: Any]] = []
        kept.reserveCapacity(entries.count)
        var dropped = 0
        for entry in entries {
            let normalized: [String: Any]?
            if file == "hao_video_hist" {
                normalized = normalizedVideoHistoryEntry(entry)
            } else if file == "hao_live_hist" {
                normalized = normalizedLiveHistoryEntry(entry)
            } else {
                normalized = entry
            }
            if let normalized = normalized {
                kept.append(normalized)
            } else {
                dropped += 1
            }
        }
        return (kept, dropped)
    }

    /// The merge key for one favourite entry (b49fix19 P1-3):
    /// the song's identityKey when the entry carries a song
    /// dict (the same key toggleFav / isFav use), otherwise
    /// the stored "key" with its platform prefix normalised
    /// ("lx:xxx|id" and "wy|id" are the same favourite — the
    /// D-4 normalisation never reached the fav merge, whose
    /// keyFor read the precomputed "key" verbatim, so an
    /// lx favourite and a wy favourite became duplicate rows
    /// and the lx row could never be unfavourited). The merge
    /// also REWRITES each entry's stored "key" to this value
    /// (see mergedListEntries' mapEntry) — normalising only
    /// the dedupe key would leave the stored "lx:…" key in
    /// the file, and toggleFav still could not remove it.
    static func favMergeKey(for entry: [String: Any]) -> String {
        if let song = entry["song"] as? [String: Any] {
            return songIdentityKey(for: song)
        }
        let raw = entry["key"] as? String ?? ""
        guard let pipe = raw.firstIndex(of: "|") else { return raw }
        let platform = MusicPlatform.fromCode(String(raw[..<pipe])).rawValue
        return platform + raw[pipe...]
    }

    /// Secondary dedupe key for one song JSON dict (b49fix19
    /// P2-6): platform + title + artist. Used when the
    /// primary identity key is unstable because the songId is
    /// empty in one copy and present in the other (a backup
    /// entry without a songId and the live entry that later
    /// gained one would otherwise dedupe to two rows). Empty
    /// when both title and artist are empty — a key with no
    /// content matches nothing.
    static func songTitleArtistKey(for entry: [String: Any]) -> String {
        let title = entry["title"] as? String ?? ""
        let artist = entry["artist"] as? String ?? ""
        guard !title.isEmpty || !artist.isEmpty else { return "" }
        let platform = MusicPlatform.fromCode(entry["platform"] as? String).rawValue
        return "\(platform)|\(title)|\(artist)"
    }

    /// The identity key of one entry in one merge file
    /// (b49fix19 P1-2): the same key the merge dedupes by, so
    /// the verify compares identities, not bytes. A live
    /// writer round-trips through its typed struct and rewrites
    /// the file (drops unknown fields, fills defaults,
    /// normalises platform codes) — the CONTENT is identical
    /// but the bytes change, so a byte-subset verify false-
    /// fails on every such write. Identity comparison is
    /// immune: the typed rewrite keeps every identity key.
    /// Files with no known key fall back to canonical bytes,
    /// the old byte behaviour.
    static func mergeIdentityKey(for entry: [String: Any], in file: String) -> String {
        let key: String
        switch file {
        case "hao_listen":
            key = listenDedupeKey(for: entry)
        case "hao_recent":
            key = songIdentityKey(for: entry)
        case "hao_fav":
            key = favMergeKey(for: entry)
        case "hao_lists":
            key = entry["id"] as? String ?? ""
        case "musicDownloads":
            guard let song = entry["song"] as? [String: Any] else { return "" }
            key = songIdentityKey(for: song)
        case "hao_video_hist":
            key = videoHistoryDedupeKey(for: entry)
        case "hao_live_hist":
            key = ((entry["platform"] as? String) ?? "") + "|" + ((entry["roomId"] as? String) ?? "")
        case "hao_fav_albums", "hao_fav_artists":
            key = ((entry["id"] as? String) ?? "") + "|" + ((entry["name"] as? String) ?? "")
        case "hao_daily":
            // b49fix20 D22-7: a day's songs identify by the
            // song identity key, so the per-day value check
            // (dailyDaysContainAll) tolerates a live typed
            // round-trip of the same songs.
            key = songIdentityKey(for: entry)
        default:
            key = ""
        }
        if !key.isEmpty { return key }
        guard let bytes = canonicalJSONData(entry) else { return "" }
        return "bytes:" + bytes.base64EncodedString()
    }

    /// Secondary identity key of one entry in one merge file
    /// (b49fix20 D22-6): platform + title + artist, for files
    /// whose entries carry a song. The merge dedupes by it
    /// (secondaryKeyFor) but the verify never used it — a live
    /// rewrite adding a songId changes the primary key, so the
    /// verify missed the entry and false-failed. hao_listen is
    /// excluded (its `at` is ms on both sides, so its primary
    /// key never rewrites) — do not add it here.
    static func mergeSecondaryKey(for entry: [String: Any], in file: String) -> String {
        switch file {
        case "hao_fav":
            guard let song = entry["song"] as? [String: Any] else { return "" }
            return songTitleArtistKey(for: song)
        case "musicDownloads":
            guard let song = entry["song"] as? [String: Any] else { return "" }
            return songTitleArtistKey(for: song)
        default:
            return ""
        }
    }

    /// Identity-subset check for merged list files (b49fix19
    /// P1-2, b49fix20 D22-6): every expected entry's merge
    /// identity key must still be in the actual file (multiset
    /// counts, so a duplicated key still counts twice) — or
    /// its secondary key, when the primary misses (a live
    /// rewrite that added a songId changes the primary key;
    /// the secondary title+artist key still matches the same
    /// song). The merged expected list never holds two rows
    /// sharing one secondary key (the merge dedupes by it),
    /// so one actual entry cannot satisfy two expected rows
    /// through the two keys. Replaces the byte multiset subset
    /// (listContainsAll) on the verify paths — the byte version
    /// false-failed whenever a live writer round-tripped the
    /// file between the import write and its verify.
    /// listContainsAll stays for the harness's retained
    /// behaviour cases; no verify path uses it any more.
    static func listKeysContainAll(
        actual: [[String: Any]], expected: [[String: Any]], file: String
    ) -> Bool {
        var counts: [String: Int] = [:]
        var secondaryCounts: [String: Int] = [:]
        counts.reserveCapacity(actual.count)
        for entry in actual {
            let key = mergeIdentityKey(for: entry, in: file)
            counts[key, default: 0] += 1
            let secondary = mergeSecondaryKey(for: entry, in: file)
            if !secondary.isEmpty { secondaryCounts[secondary, default: 0] += 1 }
        }
        for entry in expected {
            let key = mergeIdentityKey(for: entry, in: file)
            if let remaining = counts[key], remaining > 0 {
                counts[key] = remaining - 1
                continue
            }
            let secondary = mergeSecondaryKey(for: entry, in: file)
            guard !secondary.isEmpty,
                  let remaining = secondaryCounts[secondary], remaining > 0
            else { return false }
            secondaryCounts[secondary] = remaining - 1
        }
        return true
    }

    /// The live-history cap the import's merge must use
    /// (b49fix19 P2-4): LiveLibraryStore.historyLimit() reads
    /// this UserDefaults key — 0 means unlimited, absent means
    /// the 50 default. The import used to hard-code 50,
    /// silently truncating a live history the user set to
    /// unlimited. Returns nil for unlimited. AppCore cannot
    /// see LiveLibraryStore, so the rule is restated here —
    /// keep the two in sync (same key, same default, same 0
    /// rule). hao_video_hist keeps its fixed 20: it matches
    /// live's maxHistory 20, no setting exists for it.
    static func liveHistoryCap(defaults: UserDefaults) -> Int? {
        guard defaults.object(forKey: "hao_live_hist_limit") != nil else { return 50 }
        let limit = defaults.integer(forKey: "hao_live_hist_limit")
        return limit == 0 ? nil : limit
    }

    /// Cache keys a live eviction removed while an import runs
    /// (b49fix19 P1-7): putLyricsLocked / saveCover evict when
    /// the cache is at its cap, and an eviction landing
    /// between the import's merge and its verify used to fail
    /// the key-subset verify and roll the import back. The
    /// record is cleared at each import's start and read at
    /// its verify, so exactly the keys evicted during THIS
    /// import are excused — same shape as the resume-deletion
    /// record (b49fix17 P2-2). Guarded by a lock: the evictors
    /// run on the player's threads while the verify reads on
    /// the import queue. Keyed by file name, because the lyrics
    /// and cover caches share the same identity-key space.
    private static let cacheEvictionLock = NSLock()
    private static var cacheKeysEvictedDuringImport: [String: Set<String>] = [:]

    /// Clears the eviction record at an import's start.
    static func resetCacheEvictionRecord() {
        cacheEvictionLock.lock()
        cacheKeysEvictedDuringImport.removeAll()
        cacheEvictionLock.unlock()
    }

    /// Records one key a live eviction removed.
    static func noteCacheKeyEvicted(file: String, key: String) {
        cacheEvictionLock.lock()
        cacheKeysEvictedDuringImport[file, default: []].insert(key)
        cacheEvictionLock.unlock()
    }

    /// The keys evicted from one file since the current import
    /// started.
    static func cacheEvictionRecord(for file: String) -> Set<String> {
        cacheEvictionLock.lock()
        defer { cacheEvictionLock.unlock() }
        return cacheKeysEvictedDuringImport[file] ?? []
    }

    /// The lyrics order list (b49fix19 P1-7): imported keys
    /// must be written into the order file at merge time, or
    /// the next putLyrics treats them as unknown, sorts them
    /// to the FRONT of the order, and evicts them FIRST when
    /// the cache is full — the import's own keys are the ones
    /// the verify then misses. Appended at the end (newest),
    /// so they evict last; keys that left the cache are
    /// dropped from the order. The key name is restated here
    /// (MusicLibraryStore.lyricsCacheOrderKey) because AppCore
    /// cannot see it — keep the two in sync.
    static func reconcileLyricsCacheOrder(
        mergedKeys: Set<String>, importedKeys: [String], defaults: UserDefaults
    ) {
        let orderKey = "hao.lyricsCacheOrder"
        var order = defaults.stringArray(forKey: orderKey) ?? []
        order = order.filter { mergedKeys.contains($0) }
        for key in importedKeys where !order.contains(key) {
            order.append(key)
        }
        defaults.set(order, forKey: orderKey)
    }

    /// Trims a merged cover cache to the live 500 cap
    /// (b49fix20 D22-9): the import merge never trimmed, so
    /// the file grew past the cap the live writer enforces —
    /// and saveCover's eviction then removed an arbitrary
    /// Dictionary-order key. Incoming keys are kept first
    /// (sorted, deterministic), live keys fill the remaining
    /// slots (sorted); when the incoming set alone exceeds the
    /// cap, only its first `cap` sorted keys survive. Dropped
    /// covers are re-fetchable, same class as an eviction — no
    /// warning is threaded for the pathological case. Shared
    /// by both routes so they cannot drift.
    static func trimmedCoverCache(
        merged: [String: Any], incomingKeys: Set<String>, cap: Int = 500
    ) -> [String: Any] {
        guard merged.count > cap else { return merged }
        var kept = Set<String>()
        kept.reserveCapacity(cap)
        for key in merged.keys.filter({ incomingKeys.contains($0) }).sorted() {
            guard kept.count < cap else { break }
            kept.insert(key)
        }
        for key in merged.keys.filter({ !incomingKeys.contains($0) }).sorted() {
            guard kept.count < cap else { break }
            kept.insert(key)
        }
        return merged.filter { kept.contains($0.key) }
    }

    /// Songs a merged hao_daily day may hold (b49fix20 D22-7):
    /// the live cap — saveDailyTracks writes at most 20 picks
    /// per day.
    static let dailyDayCap = 20

    /// Incoming daily songs the day cap dropped during the
    /// current import (b49fix20 D22-7): the same record shape
    /// as resumeDeletionRecord / cacheEvictionRecord — cleared
    /// at each import's start, read at its report, so exactly
    /// the songs dropped by THIS import are warned about.
    private static let dailyCapLock = NSLock()
    private static var dailyCapDroppedCount = 0

    /// Clears the daily-cap record at an import's start.
    static func resetDailyCapDroppedRecord() {
        dailyCapLock.lock()
        dailyCapDroppedCount = 0
        dailyCapLock.unlock()
    }

    /// Records dropped incoming daily songs.
    static func noteDailyCapDropped(_ count: Int) {
        guard count > 0 else { return }
        dailyCapLock.lock()
        dailyCapDroppedCount += count
        dailyCapLock.unlock()
    }

    /// The incoming daily songs dropped by the cap since the
    /// current import started.
    static func dailyCapDroppedDuringImport() -> Int {
        dailyCapLock.lock()
        defer { dailyCapLock.unlock() }
        return dailyCapDroppedCount
    }

    /// Merges one day's song lists per song (b49fix19 P2-7,
    /// b49fix20 D22-7): live day first, incoming day after,
    /// dedupe by identityKey with live winning — the old dict
    /// overlay replaced the whole day's list with the backup's,
    /// so a live day was silently replaced by an old backup
    /// day, against the "import is a merge" wording. Capped at
    /// live's 20 (live first, so the excess is always
    /// incoming): the old "No cap" day could exceed 20, and
    /// the next saveDailyTracks overwrote it with 20 fresh
    /// songs, silently dropping the tail imported songs. The
    /// excess is counted for the report (see
    /// dailyCapDroppedDuringImport), never silently lost.
    /// Shared by both routes so they cannot drift.
    static func mergedDailyDay(
        live: [[String: Any]], incoming: [[String: Any]]
    ) -> [[String: Any]] {
        let merged = mergedListEntries(
            live: live, incoming: incoming,
            keyFor: songIdentityKey,
            secondaryKeyFor: songTitleArtistKey
        )
        guard merged.count > dailyDayCap else { return merged }
        noteDailyCapDropped(merged.count - dailyDayCap)
        return Array(merged.prefix(dailyDayCap))
    }

    /// Per-day value-subset check for hao_daily (b49fix20
    /// D22-7): every expected day's songs must still be
    /// present in the actual day (by song identity key — the
    /// same identity rule the other list verifies use, so a
    /// live typed round-trip of the same songs still passes);
    /// a day whose expected value is not a song list falls
    /// back to key presence, the old dict rule. The old
    /// key-only check passed while saveDailyTracks had replaced
    /// a whole day's songs with fresh picks — that is a loud
    /// failure now, not a silent pass.
    static func dailyDaysContainAll(actual: [String: Any], expected: [String: Any]) -> Bool {
        for (day, expectedValue) in expected {
            guard let actualValue = actual[day] else { return false }
            if let expectedDay = expectedValue as? [[String: Any]],
               let actualDay = actualValue as? [[String: Any]] {
                guard listKeysContainAll(actual: actualDay, expected: expectedDay, file: "hao_daily") else { return false }
            }
        }
        return true
    }

    /// How one file is restored when a rollback must preserve
    /// live increments made during the import (b49fix19 P1-4).
    enum RestoreKind {
        /// A merge file (list/dict/string-list): restored =
        /// prior entries + live entries added after the import
        /// wrote (entries in neither the prior nor the written
        /// value).
        case mergeList
        case mergeDict
        case mergeStringList
        /// A whole-file file: restored = prior bytes when the
        /// live file still holds the import's write; when a
        /// live writer replaced it after the write, the live
        /// file is kept and reported as kept-live.
        case wholeFile
    }

    /// What a preserving restore does with one file.
    enum RestoredFile {
        /// Write these bytes.
        case data(Data)
        /// Leave the current file alone (a live writer
        /// replaced the import's write after it landed).
        case keepCurrent
        /// Delete the file (it did not exist before the import
        /// and no live entries were added to it).
        case remove
    }

    /// Canonical equality of two JSON values (b49fix20 D22-4):
    /// values compare by wrapping them in an array first —
    /// data(withJSONObject:) on a top-level scalar raises an
    /// uncatchable NSException, so a bare Double or String must
    /// never be serialised directly. Unserialisable values
    /// compare unequal (the live value then wins in the
    /// restore, the safe direction).
    static func jsonValuesEqual(_ a: Any, _ b: Any) -> Bool {
        guard let aData = try? JSONSerialization.data(withJSONObject: [a], options: [.sortedKeys]),
              let bData = try? JSONSerialization.data(withJSONObject: [b], options: [.sortedKeys])
        else { return false }
        return aData == bData
    }

    /// Restores one file preserving live increments (b49fix19
    /// P1-4, b49fix20 D22-4): the old rollback wrote the prior
    /// bytes back whole, wiping every live write that landed
    /// during the import (a completion, a favourite toggle, a
    /// download state change) — a loud verify failure turning
    /// into silent live loss. For merge files the restored
    /// value is prior + live-added entries (current entries
    /// whose identity is in neither prior nor the import's
    /// written value); for whole-file files the prior bytes
    /// return only when the live file still holds the import's
    /// write, otherwise the live file is kept. A value that
    /// cannot be parsed falls back to the plain prior restore.
    /// D22-4: "prior + live-added" is not enough — a live
    /// DELETION of a prior entry (its key is in the written
    /// value but absent from current) must stay deleted, and a
    /// live CHANGE of a prior entry (same key, different value)
    /// takes the live value. Only entries the import never
    /// wrote (dropped by the merge's cap/prune) restore
    /// unconditionally.
    static func restoredPreservingLive(
        prior: Data?, written: Data?, current: Data?, file: String, kind: RestoreKind
    ) -> RestoredFile {
        switch kind {
        case .mergeList:
            let priorList = parsedList(prior)
            let writtenList = parsedList(written)
            let currentList = parsedList(current)
            let priorKeys = Set(priorList.map { mergeIdentityKey(for: $0, in: file) })
            let writtenKeys = Set(writtenList.map { mergeIdentityKey(for: $0, in: file) })
            var currentByKey: [String: [String: Any]] = [:]
            for entry in currentList {
                let key = mergeIdentityKey(for: entry, in: file)
                if currentByKey[key] == nil { currentByKey[key] = entry }
            }
            // b49fix20 D22-4: a prior entry the import wrote
            // but live DELETED (in writtenKeys, absent from
            // current) stays deleted — it must not resurrect.
            // A prior entry the import never wrote (dropped by
            // the merge's cap/prune) restores as before. An
            // entry present in current takes the CURRENT entry:
            // identical when unchanged, the live value when
            // live changed it.
            var restored: [[String: Any]] = []
            restored.reserveCapacity(priorList.count)
            for entry in priorList {
                let key = mergeIdentityKey(for: entry, in: file)
                if writtenKeys.contains(key) {
                    if let currentEntry = currentByKey[key] {
                        restored.append(currentEntry)
                    }
                } else {
                    restored.append(entry)
                }
            }
            let liveAdded = currentList.filter { entry in
                let key = mergeIdentityKey(for: entry, in: file)
                return !priorKeys.contains(key) && !writtenKeys.contains(key)
            }
            restored += liveAdded
            if prior == nil && liveAdded.isEmpty { return .remove }
            guard let bytes = try? JSONSerialization.data(withJSONObject: restored, options: []) else {
                if let prior = prior { return .data(prior) }
                return .remove
            }
            return .data(bytes)
        case .mergeDict:
            let priorDict = parsedDict(prior)
            let writtenDict = parsedDict(written)
            let currentDict = parsedDict(current)
            var restored = priorDict
            // b49fix20 D22-4: a key the import wrote but live
            // DELETED (in writtenDict, absent from currentDict)
            // stays deleted; a key live CHANGED (present in
            // current with a canonically different value) takes
            // the live value. Keys the import never wrote keep
            // the prior value; when current still equals the
            // written value, the prior value restores (the
            // import's overlay is rolled back).
            for (key, writtenValue) in writtenDict {
                guard priorDict[key] != nil else { continue }
                guard let currentValue = currentDict[key] else {
                    restored.removeValue(forKey: key)
                    continue
                }
                if !jsonValuesEqual(currentValue, writtenValue) {
                    restored[key] = currentValue
                }
            }
            for (key, value) in currentDict where priorDict[key] == nil && writtenDict[key] == nil {
                restored[key] = value
            }
            if prior == nil && restored.isEmpty { return .remove }
            guard let bytes = try? JSONSerialization.data(withJSONObject: restored, options: []) else {
                if let prior = prior { return .data(prior) }
                return .remove
            }
            return .data(bytes)
        case .mergeStringList:
            let priorList = parsedStringList(prior)
            let writtenList = parsedStringList(written)
            let currentList = parsedStringList(current)
            let priorSet = Set(priorList)
            let writtenSet = Set(writtenList)
            let currentSet = Set(currentList)
            // b49fix20 D22-4: a prior string the import wrote
            // but live deleted (in writtenSet, absent from
            // currentSet) stays deleted. A changed string is a
            // different string (delete + add), already covered
            // by the sets.
            let restored = priorList.filter { !(writtenSet.contains($0) && !currentSet.contains($0)) }
                + currentList.filter { !priorSet.contains($0) && !writtenSet.contains($0) }
            if prior == nil && restored.isEmpty { return .remove }
            guard let bytes = try? JSONSerialization.data(withJSONObject: restored, options: []) else {
                if let prior = prior { return .data(prior) }
                return .remove
            }
            return .data(bytes)
        case .wholeFile:
            // No written value (the file was journalled but the
            // write never landed) or the file is gone now: the
            // prior bytes are the only sane restore.
            guard let written = written, let current = current else {
                if let prior = prior { return .data(prior) }
                return .remove
            }
            guard let currentParsed = try? JSONSerialization.jsonObject(with: current, options: []),
                  let writtenParsed = try? JSONSerialization.jsonObject(with: written, options: []),
                  let currentBytes = canonicalJSONData(currentParsed),
                  let writtenBytes = canonicalJSONData(writtenParsed)
            else {
                if let prior = prior { return .data(prior) }
                return .remove
            }
            if currentBytes == writtenBytes {
                if let prior = prior { return .data(prior) }
                return .remove
            }
            return .keepCurrent
        }
    }

    private static func parsedList(_ data: Data?) -> [[String: Any]] {
        guard let data = data,
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let list = parsed as? [[String: Any]]
        else { return [] }
        return list
    }

    private static func parsedDict(_ data: Data?) -> [String: Any] {
        guard let data = data,
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = parsed as? [String: Any]
        else { return [:] }
        return dict
    }

    private static func parsedStringList(_ data: Data?) -> [String] {
        guard let data = data,
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let list = parsed as? [String]
        else { return [] }
        return list
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
    ///
    /// b49fix19 P2-6: `secondaryKeyFor` is a second dedupe
    /// key checked ONLY for incoming entries (live entries
    /// are never dropped by it — the live list is preserved
    /// exactly). It catches the same song recorded once
    /// without a songId and once with it, where the primary
    /// keys differ. b49fix19 P1-3: `mapEntry` rewrites every
    /// entry (live and incoming) before keying — the fav
    /// merge uses it to normalise the stored "key" field, so
    /// toggleFav can find the row afterwards.
    static func mergedListEntries(
        live: [[String: Any]], incoming: [[String: Any]],
        keyFor: ([String: Any]) -> String, cap: Int? = nil,
        secondaryKeyFor: (([String: Any]) -> String)? = nil,
        mapEntry: (([String: Any]) -> [String: Any])? = nil
    ) -> [[String: Any]] {
        var seenPrimary = Set<String>()
        var seenSecondary = Set<String>()
        var out: [[String: Any]] = []
        out.reserveCapacity(live.count + incoming.count)
        func insert(_ rawEntry: [String: Any], checkSecondary: Bool) {
            let entry = mapEntry?(rawEntry) ?? rawEntry
            let rawKey = keyFor(entry)
            let key: String
            if rawKey.isEmpty {
                guard let bytes = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
                    // Unserialisable entry: keep it under a unique
                    // key rather than dropping a live entry on a
                    // serialisation guess (entries come from JSON
                    // parsing, so this never fires in practice).
                    out.append(entry)
                    return
                }
                key = "bytes:" + bytes.base64EncodedString()
            } else {
                key = rawKey
            }
            if seenPrimary.contains(key) { return }
            if checkSecondary, let secondaryKeyFor = secondaryKeyFor {
                let secondary = secondaryKeyFor(entry)
                if !secondary.isEmpty && seenSecondary.contains(secondary) { return }
            }
            seenPrimary.insert(key)
            if let secondaryKeyFor = secondaryKeyFor {
                let secondary = secondaryKeyFor(entry)
                if !secondary.isEmpty { seenSecondary.insert(secondary) }
            }
            out.append(entry)
        }
        for entry in live { insert(entry, checkSecondary: false) }
        for entry in incoming { insert(entry, checkSecondary: true) }
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
    /// with the recent cap instead of 3000. b49fix19 P2-6:
    /// the secondary title+artist key also applies, so a
    /// backup entry without a songId dedupes against the live
    /// entry that later gained one.
    static func mergedRecentEntries(
        live: [[String: Any]], incoming: [[String: Any]], cap: Int = 100
    ) -> [[String: Any]] {
        mergedListEntries(
            live: live, incoming: incoming, keyFor: songIdentityKey, cap: cap,
            secondaryKeyFor: songTitleArtistKey
        )
    }

    /// Expected top-level JSON shape of one collection file
    /// (b49fix18 D-8). Derived from each file's 2.0 reader —
    /// the shape the reader decodes — never from the backup:
    /// a backup that carries a dict where the reader expects
    /// a list is corrupt, not a new shape.
    enum CollectionShape: Equatable {
        /// A JSON array (every list file in 2.0 holds dicts;
        /// the element shape is the merge guard's job, not
        /// this check's — this check catches list/dict
        /// confusion, the D-8 scenario).
        case list
        /// A JSON object.
        case dict
        /// A JSON array whose elements are all strings.
        case stringList

        /// Whether a parsed JSON value has this shape.
        func matches(_ value: Any) -> Bool {
            switch self {
            case .list: return value is [Any]
            case .dict: return value is [String: Any]
            case .stringList: return value is [String]
            }
        }

        /// Whether raw backup bytes parse to this shape.
        /// Unparseable bytes match nothing.
        func matches(bytes: Data) -> Bool {
            guard let parsed = try? JSONSerialization.jsonObject(with: bytes, options: []) else { return false }
            return matches(parsed)
        }
    }

    /// Expected shape per collection file (b49fix18 D-8), one
    /// row per file whose 2.0 reader is known. Files with no
    /// 2.0 reader return nil — their shape is unknown, so they
    /// are not shape-checked (a wrong-shape install there is
    /// inert in 2.0: nothing reads them — and the write is
    /// still content-verified). Shared by Route A (planImport
    /// + writeWholeCollectionBytes) and Route B (importData's
    /// plan loop) so the two routes cannot drift apart again.
    /// Readers: hao_local_music MusicLibraryStore:1033 (list
    /// of songs); hao_wallpaper_paths WallpaperStore:112
    /// ([String]); hao_video_fav / hao_video_home /
    /// hao_live_follows / hao_sa_video / hao_lx_custom /
    /// hao_eq_custom_presets / hao_dm_block loadCollection
    /// defaults (lists); hao_video_search_hist /
    /// hao_live_search_hist [String]; hao_video_category_prefs
    /// VideoCategoryPrefs (dict); hao_live_sources [String];
    /// hao_danmaku_enabled [String: Bool]; hao_douban_detail /
    /// hao_douban_idmap dicts; hao_vod_skip_intro_durations
    /// [String: Int]; hao_lx_* [String] except hao_lx_custom
    /// ([LxCustomScriptRecord]); hao_resolver_speed
    /// [String: ResolverSpeedRecord]; downloadTasks
    /// [DownloadTaskInfo]; hao_emby_config EmbyConfig (dict).
    static func expectedCollectionShape(for name: String) -> CollectionShape? {
        switch name {
        case "hao_listen", "hao_recent", "hao_fav", "hao_lists",
             "musicDownloads", "hao_video_hist", "hao_live_hist",
             "hao_local_music", "hao_video_fav", "hao_video_home",
             "hao_live_follows", "hao_sa_video", "hao_lx_custom",
             "hao_eq_custom_presets", "hao_dm_block", "downloadTasks",
             "hao_fav_albums", "hao_fav_artists":
            return .list
        case "hao_daily", "haoVodProg", "hao_daily_pool", "musicResume",
             "musicQueue", "hao_cover_cache", "hao_lyrics",
             "hao_music_loudness_cache", "hao_video_category_prefs",
             "hao_danmaku_enabled", "hao_douban_detail", "hao_douban_idmap",
             "hao_vod_skip_intro_durations", "hao_resolver_speed",
             // b49fix19 P2-2: the two unknown-keys files are
             // deliberately SPLIT, not one file under two names:
             // Route A isolates into backup_unknown_keys.json,
             // Route B into migration_unknown_keys.json. Each
             // route only ever reads its own file, so unifying
             // the name would orphan the other route's
             // already-isolated keys (a migration-behaviour
             // change needing old-file merging, not a rename).
             // Both rows exist here so a future mapping addition
             // checks both files before claiming a key is new.
             "hao_emby_config", "backup_unknown_keys",
             "migration_unknown_keys":
            return .dict
        case "hao_music_search_hist", "hao_video_search_hist",
             "hao_live_search_hist", "fmDislikedIds",
             "hao_wallpaper_paths", "hao_live_sources",
             "hao_lx_deleted_bundled", "hao_lx_disabled",
             "hao_lx_explicit_enabled", "hao_lx_order",
             "hao_fav_playlists":
            return .stringList
        default:
            // No 2.0 reader: hao_music_sources,
            // hao_music_bookmarks, hao_music_queue_memory,
            // hao_feature_cover_plaza, hao_feature_cover_charts,
            // hao_emby_home, hao_vod_metadata_overrides,
            // hao_live_hidden_platforms, cms_source_speed.
            return nil
        }
    }

    /// Canonical JSON bytes for content comparison (b49fix18
    /// D-1, b49fix19 P2-9d): sorted keys, so key order never
    /// matters. Nil when the value is not a top-level
    /// array/dict — isValidJSONObject guards the NSException
    /// that data(withJSONObject:) raises on a top-level String
    /// (see AGENTS.md). Both routes compare the same way now:
    /// list/dict subsets by identity or canonical value, and
    /// whole-file files by canonical bytes (Route A used raw
    /// byte equality for whole-file files until fix19, so the
    /// same live re-serialisation passed Route B and failed
    /// Route A — the fix18 comment claiming both routes
    /// compared the same way was only true for the subset
    /// branches).
    static func canonicalJSONData(_ value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    /// Deep content equality of one file against an expected
    /// value (b49fix18 D-1): the whole-file verify for Route B.
    /// Compares canonical bytes, not raw bytes — writeJSONFile
    /// serialises dicts in hash order, so a live writer
    /// re-serialising identical content with a different key
    /// order must not fail the import. A live write that
    /// changes content still fails loud.
    static func fileContentEquals(name: String, expected: Any, documentsURL: URL) -> Bool {
        let url = documentsURL.appendingPathComponent("\(name).json")
        guard let rawData = try? Data(contentsOf: url),
              let actual = try? JSONSerialization.jsonObject(with: rawData, options: []),
              let actualBytes = canonicalJSONData(actual),
              let expectedBytes = canonicalJSONData(expected)
        else { return false }
        return actualBytes == expectedBytes
    }

    /// Set subset for string-list files (b49fix18 D-1): every
    /// expected string must still be in the actual file. The
    /// merged list is deduped, so a set check is exact.
    static func stringListContainsAll(actual: [String], expected: [String]) -> Bool {
        let actualSet = Set(actual)
        return expected.allSatisfy { actualSet.contains($0) }
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

    /// Tolerant recent verify (b49fix17 P1-2, b49fix18 D-5,
    /// b49fix19 P1-6): the merged recent list must still be in
    /// the file, except for tail entries a concurrent song
    /// switch legitimately displaced. Each writeRecent after
    /// the merge inserts one song at the front and truncates
    /// to 100, so a NEW song (not in the merged list) drops at
    /// most one tail entry. A RE-ADD displaces NOTHING —
    /// writeRecent filters the old entry out first, then
    /// inserts at the front, so the length is unchanged and
    /// the truncation drops nothing — so re-adds give NO
    /// budget (b49fix18 D-5: the fix17 proof counted every
    /// re-add as a displacement, overestimating the budget by
    /// the re-add count in the window and letting a genuinely
    /// rewritten tail entry pass). The budget is therefore
    /// the new-song count only, CAPPED at 10: a payload-unpack
    /// window of tens of seconds could otherwise let N
    /// consecutive new songs displace the whole merged table
    /// and still pass (budget = N). Past the cap the import
    /// fails loud instead of passing silently. Every missing
    /// merged entry must sit within the last `budget` entries
    /// of the merged list. A plain multiset subset would fail
    /// the whole import on every song switch while recent is
    /// at its routine 100 cap.
    ///
    /// b49fix19 P1-6 (a defect in the D-5 fix itself, not a
    /// residual): the D-5 budget counted new songs only and
    /// never asked whether the list was FULL. Displacement
    /// only happens at the 100 cap: a merged list of 10 with
    /// 10 new songs inserted displaces NOTHING (writeRecent
    /// truncates only past 100), yet the old budget allowed 10
    /// tail entries to go missing — so clearRecent + replay
    /// ≥ that many new songs passed the verify with the whole
    /// imported recent table gone. The budget is now also
    /// bounded by the real displacement, `expected.count +
    /// newCount − 100` (only the overflow past 100 can push
    /// tail entries out). b49fix19 P2-9e: newCount is counted
    /// on the deduped SET difference, so a live list that
    /// itself holds duplicate keys (damaged old data) cannot
    /// inflate the budget.
    /// Residual, theoretical only: a write that failed
    /// silently at apply time plus exactly compensating
    /// concurrent inserts could pass — but an apply write
    /// failure is reported (.writeFailed → rollback), so the
    /// verify never has to carry that case alone.
    static func recentContainsAll(actual: [[String: Any]], expected: [[String: Any]]) -> Bool {
        let actualKeys = actual.map { songIdentityKey(for: $0) }
        let expectedKeys = expected.map { songIdentityKey(for: $0) }
        let actualSet = Set(actualKeys)
        let expectedSet = Set(expectedKeys)
        let missing = expectedSet.subtracting(actualSet)
        if missing.isEmpty { return true }
        let newCount = actualSet.subtracting(expectedSet).count
        // b49fix19 P1-6: displacement only exists past the
        // 100 cap — a list that was not full gives NO budget,
        // however many new songs arrived.
        let displacement = max(0, expected.count + newCount - 100)
        let budget = min(newCount, displacement, 10)
        guard budget > 0 else { return false }
        let tail = Set(expectedKeys.suffix(budget))
        return missing.isSubset(of: tail)
    }

    /// The merged recent entries no longer in the actual file
    /// (b49fix18 D-5c): the missing count, for the import
    /// report — a passing verify that still excused missing
    /// entries warns, so the displacement is observable
    /// instead of silent. Computed with the same normalised
    /// keys as recentContainsAll (after D-4, a platform
    /// rewrite no longer counts as missing).
    static func recentMissingKeys(actual: [[String: Any]], expected: [[String: Any]]) -> [String] {
        let actualSet = Set(actual.map { songIdentityKey(for: $0) })
        return expected.map { songIdentityKey(for: $0) }.filter { !actualSet.contains($0) }
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
        return resumeEntriesPresent(expected, actual: actual, toleratingDeleted: deletedKeys)
    }

    /// The same check against an already-read dict (b49fix20
    /// D22-1): the resume merge's in-section verify re-reads
    /// inside its queue.sync and compares without a second
    /// file read. The documentsURL form above reads, then
    /// calls this.
    static func resumeEntriesPresent(
        _ expected: [String: Any], actual: [String: Any], toleratingDeleted deletedKeys: Set<String>
    ) -> Bool {
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

    /// b49fix19 P2-3: `rollback` carries what the rollback
    /// could not restore and what live content it kept, so
    /// the failure report can say so — Route B used to report
    /// only "verification failed" and let the user believe a
    /// full rollback had happened.
    static func failReport(
        total: Int, migrated: Int, skipped: [String],
        unknown: [String], detail: String,
        rollback: (failures: [String], keptLive: [String])? = nil,
        warnings: [String] = []
    ) -> MigrationReport {
        var detail = detail
        if let rollback = rollback {
            if !rollback.failures.isEmpty {
                detail += "，回滚未完成，未恢复：" + rollback.failures.joined(separator: "、")
            }
            if !rollback.keptLive.isEmpty {
                // b49fix20 D22-4: the kept-live files may hold
                // live deletions and live value changes, not
                // just additions — say so, instead of letting
                // the user believe only additions were kept.
                detail += "；以下文件在导入期间被 live 改写（新增／删除／改值），已保留 live 版本未回滚：" + rollback.keptLive.joined(separator: "、")
            }
        }
        return MigrationReport(
            outcome: .failed, totalKeys: total, migratedKeys: migrated,
            skippedKeys: skipped.count, unknownKeys: unknown.count,
            failedKeys: total - migrated - skipped.count - unknown.count,
            skippedKeyNames: skipped.sorted(),
            unknownKeyNames: unknown.sorted(), detail: detail,
            warnings: warnings
        )
    }

    /// Removes keys that now have a mapping row from both
    /// unknown-keys files (b49fix20 D22-8): the unknown merge
    /// only ever ADDED, so the five P2-1 keys (downloadTasks,
    /// hao_fav_playlists, hao_fav_albums, hao_fav_artists,
    /// hao_daily_pool) stayed in the old files forever after
    /// they gained a mapping row. Runs after the final sweep
    /// (the sweep verifies the unknown file against its
    /// pre-cleanup expected dict) and only on success — a
    /// failed import rolls back, so installed keys are not
    /// final. Best-effort: a write failure leaves the old file
    /// in place (keys staying isolated is the pre-existing
    /// behaviour, never a reason to fail the import).
    static func sweepUnknownKeysFiles(documentsURL: URL) {
        for file in [unknownKeysFileName, BackupEngine.unknownKeysFileName] {
            var existing = readJSONDictionary(name: file, documentsURL: documentsURL)
            let known = existing.keys.filter { mapping(for: $0) != nil }
            guard !known.isEmpty else { continue }
            for key in known { existing.removeValue(forKey: key) }
            _ = writeJSONFile(name: file, value: existing, documentsURL: documentsURL)
        }
    }

    /// Rolls the attempt back and reports what it could not
    /// restore (b49fix19 P2-3) and what live content it kept
    /// (b49fix19 P1-4). `written` is what this attempt wrote
    /// (see importData's writtenMap) — the restore preserves
    /// live increments made during the import instead of
    /// writing the prior bytes back whole.
    static func rollback(
        journal: MigrationJournal,
        priorEmbyApiKey: String?,
        wroteEmbyKeychain: Bool,
        documentsURL: URL,
        defaults: UserDefaults,
        written: [String: (kind: RestoreKind, data: Data)] = [:]
    ) -> (failures: [String], keptLive: [String]) {
        let result = journal.restore(documentsURL: documentsURL, defaults: defaults, written: written)
        if wroteEmbyKeychain {
            if let prior = priorEmbyApiKey {
                _ = KeychainStore.saveEmbyApiKey(prior)
            } else {
                _ = KeychainStore.deleteEmbyApiKey()
            }
        }
        defaults.set(false, forKey: doneKey)
        return result
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

    /// Restores the journalled prior values. Returns the files
    /// it could NOT restore and the files whose live version it
    /// kept (b49fix19 P2-3/P1-4). `written` is what the attempt
    /// wrote, keyed by file — the restore preserves live
    /// increments made during the import (see
    /// MigrationStore.restoredPreservingLive) instead of
    /// writing the prior bytes back whole, which used to wipe
    /// every live write that landed during the import.
    func restore(
        documentsURL: URL, defaults: UserDefaults,
        written: [String: (kind: MigrationStore.RestoreKind, data: Data)] = [:]
    ) -> (failures: [String], keptLive: [String]) {
        for prior in priorDefaults {
            if let value = prior.value {
                defaults.set(value, forKey: prior.key)
            } else {
                defaults.removeObject(forKey: prior.key)
            }
        }
        var failures: [String] = []
        var keptLive: [String] = []
        for entry in priorFiles {
            // b49fix20 D22-5: a file the journal captured but
            // this attempt never wrote (a live-wins skip, a
            // fallback skip, or a file the import never reached
            // before failing) keeps its live content — it is
            // NOT prior-restored. Restoring it would wipe live
            // writes made during the import (the sharpest case:
            // the live musicQueue built by song-switching during
            // the import). Skipping is not a failure and not a
            // kept-live file: nothing was restored, nothing was
            // kept from a restore.
            guard written[entry.key] != nil else { continue }
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
            let restoreOne = { () -> (restored: Bool, kept: Bool) in
                let url = documentsURL.appendingPathComponent("\(entry.key).json")
                let current = try? Data(contentsOf: url)
                let writtenEntry = written[entry.key]
                let restored = MigrationStore.restoredPreservingLive(
                    prior: entry.value, written: writtenEntry?.data, current: current,
                    file: entry.key, kind: writtenEntry?.kind ?? .wholeFile
                )
                switch restored {
                case .data(let bytes):
                    do {
                        try bytes.write(to: url, options: [.atomic])
                        return (true, false)
                    } catch {
                        return (false, false)
                    }
                case .keepCurrent:
                    return (true, true)
                case .remove:
                    if FileManager.default.fileExists(atPath: url.path) {
                        do {
                            try FileManager.default.removeItem(at: url)
                        } catch {
                            return (false, false)
                        }
                    }
                    return (true, false)
                }
            }
            let outcome: (restored: Bool, kept: Bool)
            if let queue = MigrationStore.writeQueue(forCollection: entry.key) {
                outcome = queue.sync(execute: restoreOne)
            } else {
                outcome = restoreOne()
            }
            if !outcome.restored {
                failures.append(entry.key)
            } else if outcome.kept {
                keptLive.append(entry.key)
            }
        }
        return (failures, keptLive)
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
                    // b49fix19 P2-9b: the copy takes the file's
                    // queue when it has one — a live write
                    // landing between two files' copies used to
                    // give a mixed snapshot (some files pre-,
                    // some post-write), and a manual restore
                    // from it would resurrect an inconsistent
                    // state. Atomic writes make a torn single
                    // file impossible; the queue closes the
                    // cross-file gap. The snapshot is taken
                    // before any import write, so taking the
                    // queue here cannot deadlock.
                    // b49fix20 O-2: the queue serialises THIS
                    // file's copy against THIS file's writes —
                    // there is no global point across files, so
                    // a multi-file live operation can still land
                    // between two files' copies. Design
                    // limitation, documented, not fixed: the
                    // snapshot is a per-file point-in-time, not
                    // a cross-file one.
                    let copyOne = {
                        try fileManager.copyItem(at: source, to: collectionsDir.appendingPathComponent("\(name).json"))
                    }
                    if let queue = MigrationStore.writeQueue(forCollection: name) {
                        try queue.sync(execute: copyOne)
                    } else {
                        try copyOne()
                    }
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

// HAo Studio 2.0 — music library store (S2-C leg).
//
// Read/write access to the S1-migrated music data. Key names are the
// contract (docs/storage-mapping.md): UserDefaults keys keep the
// Flutter Hive names; JSON collections live in
// Documents/<key>.json and are read through LocalStore's collection
// path. Nothing here renames a key — a rename is data loss.
//
// Caps (Flutter MusicStore): recent 100, listen log 3000, search
// history 20, cover cache 500, lyrics cache 100, loudness cache 200,
// playlist 1000 tracks. Caps are enforced on write, newest first.
//
// The store is a plain value-access layer (no ObservableObject): view
// models own the published state and call reload() when they appear
// or after a mutation. That keeps the store unit-testable without a
// runloop and keeps every write explicit.

import Foundation

/// Favourite entry: {'key': identityKey, 'song': Song JSON?}.
/// Legacy entries are key-only; they resolve from recent / listen
/// history where possible (Flutter getFavSongs), never as blank rows.
struct MusicFavEntry {
    var key: String
    var song: MusicSong?

    init(key: String, song: MusicSong? = nil) {
        self.key = key
        self.song = song
    }

    init(json: [String: Any]) {
        self.key = MusicDict.string(json, "key")
        if let songJSON = json["song"] as? [String: Any] {
            self.song = MusicSong(json: songJSON)
        } else {
            self.song = nil
        }
    }

    func toJSON() -> [String: Any] {
        var dict: [String: Any] = ["key": key]
        if let song = song { dict["song"] = song.toJSON() }
        return dict
    }
}

enum MusicLibraryStore {
    // MARK: - UserDefaults keys (same names as the Flutter Hive keys)

    static let qualityKey = "musicQuality"               // 'hires' default
    static let plazaPlatformKey = "musicPlazaPf"         // 'wy' default
    static let searchPlatformKey = "musicSearchPlatform" // 'wy' default
    static let speedKey = "musicSpeed"                   // double 1.0, 0.6–2.0
    static let musicVolumeKey = "hao_music_volume"       // double 1.0, 0–1 (Now Playing slider)
    static let currentListIdKey = "curListId"
    static let playModeKey = "playMode"                  // 'seq' default
    static let playlistsExpandedKey = "musicPlaylistsExpanded"
    static let recentExpandedKey = "musicRecentExpanded"
    static let sleepCustomMinutesKey = "musicSleepCustomMinutes" // 30, 1–720
    static let normalizationEnabledKey = "hao_music_normalization_enabled"
    static let normalizationStrengthKey = "hao_music_normalization_strength" // 0–2
    static let fadeEnabledKey = "hao_music_fade_enabled"
    static let lyricOffsetMsKey = "hao_music_lyric_offset_ms" // ±5000
    static let lyricShowTranslationKey = "hao_music_lyric_show_translation"
    static let playbackCacheEnabledKey = "hao_music_playback_cache_enabled"
    static let hapticsEnabledKey = "hapticsEnabled"      // true default

    // MARK: - JSON collection names (Documents/<name>.json)

    static let listsCollection = "hao_lists"
    static let favCollection = "hao_fav"
    static let recentCollection = "hao_recent"
    static let listenCollection = "hao_listen"
    static let searchHistoryCollection = "hao_music_search_hist"
    static let coverCacheCollection = "hao_cover_cache"
    static let lyricsCacheCollection = "hao_lyrics"
    static let queueCollection = "musicQueue"
    static let downloadsCollection = "musicDownloads"
    static let resumeCollection = "musicResume"
    static let localMusicCollection = "hao_local_music"
    static let dailyCollection = "hao_daily"
    static let loudnessCacheCollection = "hao_music_loudness_cache"

    static let maxRecent = 100
    static let maxListenEvents = 3000
    static let maxSearchHistory = 20
    static let maxCoverCache = 500
    static let maxLyricsCache = 100
    static let maxLoudnessCache = 200

    // MARK: - Raw JSON file access

    private static func readArray(named name: String) -> [[String: Any]] {
        let url = LocalStore.collectionURL(named: name)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return MusicDict.objectArray(from: data)
    }

    private static func readObject(named name: String) -> [String: Any] {
        let url = LocalStore.collectionURL(named: name)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return MusicDict.object(from: data)
    }

    private static func readStringArray(named name: String) -> [String] {
        let url = LocalStore.collectionURL(named: name)
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let array = parsed as? [String] else { return [] }
        return array
    }

    private static func writeStringArray(named name: String, _ value: [String]) {
        let url = LocalStore.collectionURL(named: name)
        guard let data = MusicDict.data(forTopLevel: value) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private static func writeArray(named name: String, _ value: [[String: Any]]) {
        let url = LocalStore.collectionURL(named: name)
        guard let data = MusicDict.data(forTopLevel: value) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private static func writeObject(named name: String, _ value: [String: Any]) {
        let url = LocalStore.collectionURL(named: name)
        guard let data = MusicDict.data(forTopLevel: value) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    // MARK: - UserDefaults accessors

    private static func defaults(_ suite: UserDefaults = .standard) -> UserDefaults { suite }

    static func targetQualityCode(defaults: UserDefaults = .standard) -> String {
        return defaults.string(forKey: qualityKey) ?? "hires"
    }

    static func setTargetQualityCode(_ code: String, defaults: UserDefaults = .standard) {
        defaults.set(code, forKey: qualityKey)
    }

    /// The coordinator AudioQuality for a Flutter quality code.
    static func targetQuality(defaults: UserDefaults = .standard) -> AudioQuality {
        switch targetQualityCode(defaults: defaults) {
        case "master": return .master
        case "lossless": return .flac
        case "320k": return .high320
        case "128k": return .standard128
        case "hires": fallthrough
        default: return .hiRes
        }
    }

    /// Flutter quality code for a coordinator AudioQuality.
    static func code(for quality: AudioQuality) -> String {
        switch quality {
        case .master: return "master"
        case .hiRes: return "hires"
        case .flac: return "lossless"
        case .high320: return "320k"
        case .standard128: return "128k"
        }
    }

    /// Badge label for the tier actually playing (Flutter badgeLabel).
    /// Only a real Master URL satisfies Master — the badge shows the
    /// ACTUAL tier, never the target tier.
    static func badgeLabel(for quality: AudioQuality) -> String {
        switch quality {
        case .master: return "Master"
        case .hiRes: return "Hi-Res"
        case .flac: return "无损 FLAC"
        case .high320: return "320k"
        case .standard128: return "128k"
        }
    }

    static func speed(defaults: UserDefaults = .standard) -> Double {
        let value = defaults.object(forKey: speedKey) as? Double ?? 1.0
        return min(2.0, max(0.6, value))
    }

    static func setSpeed(_ value: Double, defaults: UserDefaults = .standard) {
        defaults.set(min(2.0, max(0.6, value)), forKey: speedKey)
    }

    /// Now Playing volume slider (0...1, default 1.0). The player
    /// reads the same key at init, so the slider position survives
    /// a relaunch; the view model is the only writer after that.
    static func musicVolume(defaults: UserDefaults = .standard) -> Double {
        let value = defaults.object(forKey: musicVolumeKey) as? Double ?? 1.0
        return min(1.0, max(0.0, value))
    }

    static func setMusicVolume(_ value: Double, defaults: UserDefaults = .standard) {
        defaults.set(min(1.0, max(0.0, value)), forKey: musicVolumeKey)
    }

    static func playModeCode(defaults: UserDefaults = .standard) -> String {
        return defaults.string(forKey: playModeKey) ?? "seq"
    }

    static func setPlayModeCode(_ code: String, defaults: UserDefaults = .standard) {
        defaults.set(code, forKey: playModeKey)
    }

    static func hapticsEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: hapticsEnabledKey) == nil { return true }
        return defaults.bool(forKey: hapticsEnabledKey)
    }

    static func setHapticsEnabled(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: hapticsEnabledKey)
    }

    static func lyricOffsetMs(defaults: UserDefaults = .standard) -> Int {
        let value = defaults.object(forKey: lyricOffsetMsKey) as? Int ?? 0
        return min(5000, max(-5000, value))
    }

    static func setLyricOffsetMs(_ value: Int, defaults: UserDefaults = .standard) {
        defaults.set(min(5000, max(-5000, value)), forKey: lyricOffsetMsKey)
    }

    static func lyricShowTranslation(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: lyricShowTranslationKey) == nil { return true }
        return defaults.bool(forKey: lyricShowTranslationKey)
    }

    /// E5: the setter the translation toggle needs (A11) — only
    /// the getter existed, so the setting could never change.
    static func setLyricShowTranslation(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: lyricShowTranslationKey)
    }

    static func normalizationEnabled(defaults: UserDefaults = .standard) -> Bool {
        return defaults.bool(forKey: normalizationEnabledKey)
    }

    static func setNormalizationEnabled(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: normalizationEnabledKey)
    }

    static func normalizationStrength(defaults: UserDefaults = .standard) -> Int {
        let value = defaults.object(forKey: normalizationStrengthKey) as? Int ?? 1
        return min(2, max(0, value))
    }

    static func sleepCustomMinutes(defaults: UserDefaults = .standard) -> Int {
        let value = defaults.object(forKey: sleepCustomMinutesKey) as? Int ?? 30
        return min(720, max(1, value))
    }

    static func setSleepCustomMinutes(_ value: Int, defaults: UserDefaults = .standard) {
        defaults.set(min(720, max(1, value)), forKey: sleepCustomMinutesKey)
    }

    static func plazaPlatform(defaults: UserDefaults = .standard) -> MusicPlatform {
        return MusicPlatform.fromCode(defaults.string(forKey: plazaPlatformKey))
    }

    static func setPlazaPlatform(_ platform: MusicPlatform, defaults: UserDefaults = .standard) {
        defaults.set(platform.rawValue, forKey: plazaPlatformKey)
    }

    static func playlistsExpanded(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: playlistsExpandedKey) == nil { return true }
        return defaults.bool(forKey: playlistsExpandedKey)
    }

    static func setPlaylistsExpanded(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: playlistsExpandedKey)
    }

    static func recentExpanded(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: recentExpandedKey) == nil { return true }
        return defaults.bool(forKey: recentExpandedKey)
    }

    static func setRecentExpanded(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: recentExpandedKey)
    }

    static func currentListId(defaults: UserDefaults = .standard) -> String {
        return defaults.string(forKey: currentListIdKey) ?? ""
    }

    // MARK: - Playlists

    static func getLists() -> [UserPlaylist] {
        return readArray(named: listsCollection).map(UserPlaylist.init(json:))
    }

    static func saveLists(_ lists: [UserPlaylist]) {
        writeArray(named: listsCollection, lists.map { $0.toJSON() })
    }

    static func createList(named name: String) -> UserPlaylist {
        var lists = getLists()
        let list = UserPlaylist(id: UUID().uuidString, name: name, tracks: [])
        lists.append(list)
        saveLists(lists)
        return list
    }

    static func deleteList(id: String) {
        saveLists(getLists().filter { $0.id != id })
    }

    static func updateList(_ updated: UserPlaylist) {
        var lists = getLists()
        if let index = lists.firstIndex(where: { $0.id == updated.id }) {
            lists[index] = updated
            saveLists(lists)
        }
    }

    // MARK: - Favourites

    static func favEntries() -> [MusicFavEntry] {
        return readArray(named: favCollection).map(MusicFavEntry.init(json:))
    }

    static func favIds() -> Set<String> {
        return Set(favEntries().map { $0.key }.filter { !$0.isEmpty })
    }

    /// Favourited songs, newest first. Key-only legacy entries resolve
    /// from recent plays / the listen log; entries that cannot be
    /// resolved to a real song are skipped (Flutter getFavSongs).
    static func favSongs() -> [MusicSong] {
        let entries = favEntries()
        guard !entries.isEmpty else { return [] }
        var byKey: [String: MusicSong] = [:]
        for song in getRecent() {
            if byKey[song.identityKey] == nil { byKey[song.identityKey] = song }
        }
        for event in getListenLog() {
            let key = "\(event.platform.rawValue)|\(event.songId)"
            if byKey[key] == nil {
                byKey[key] = MusicSong(
                    songId: event.songId, title: event.title, artist: event.artist,
                    cover: event.cover, platform: event.platform, dur: event.totalDur
                )
            }
        }
        var out: [MusicSong] = []
        var seen = Set<String>()
        for entry in entries {
            let key = entry.key
            if key.isEmpty || !seen.insert(key).inserted { continue }
            if let song = entry.song {
                out.append(song)
            } else if let resolved = byKey[key] {
                out.append(resolved)
            }
        }
        return out
    }

    /// Toggle favourite. New favourites store the full Song JSON at
    /// the front (newest first). Returns true when the song was added.
    @discardableResult
    static func toggleFav(_ song: MusicSong) -> Bool {
        var entries = favEntries()
        let key = song.identityKey
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries.remove(at: index)
            writeArray(named: favCollection, entries.map { $0.toJSON() })
            return false
        }
        entries.insert(MusicFavEntry(key: key, song: song), at: 0)
        writeArray(named: favCollection, entries.map { $0.toJSON() })
        return true
    }

    static func isFav(_ song: MusicSong) -> Bool {
        return favIds().contains(song.identityKey)
    }

    // MARK: - Recent plays

    static func getRecent() -> [MusicSong] {
        return readArray(named: recentCollection).map(MusicSong.init(json:))
    }

    static func addRecent(_ song: MusicSong) {
        var list = getRecent().filter { $0.identityKey != song.identityKey }
        list.insert(song, at: 0)
        writeArray(named: recentCollection, Array(list.prefix(maxRecent)).map { $0.toJSON() })
        NotificationCenter.default.post(name: .haoMusicRecentChanged, object: nil)
    }

    static func clearRecent() {
        writeArray(named: recentCollection, [])
        NotificationCenter.default.post(name: .haoMusicRecentChanged, object: nil)
    }

    // MARK: - Listen log

    static func getListenLog() -> [ListenEvent] {
        return readArray(named: listenCollection).map(ListenEvent.init(json:))
    }

    static func recordListenEvent(_ event: ListenEvent) {
        var log = getListenLog()
        log.append(event)
        if log.count > maxListenEvents {
            log.removeFirst(log.count - maxListenEvents)
        }
        writeArray(named: listenCollection, log.map { $0.toJSON() })
    }

    // MARK: - Search history

    static func getSearchHistory() -> [String] {
        return readStringArray(named: searchHistoryCollection)
    }

    static func saveSearchQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var history = getSearchHistory().filter { $0 != trimmed }
        history.insert(trimmed, at: 0)
        writeStringArray(named: searchHistoryCollection, Array(history.prefix(maxSearchHistory)))
    }

    static func clearSearchHistory() {
        writeStringArray(named: searchHistoryCollection, [])
    }

    static func removeSearchQuery(_ query: String) {
        writeStringArray(named: searchHistoryCollection, getSearchHistory().filter { $0 != query })
    }

    // MARK: - Cover cache

    static func coverCache() -> [String: String] {
        let dict = readObject(named: coverCacheCollection)
        var out: [String: String] = [:]
        for (key, value) in dict {
            if let url = value as? String, !url.isEmpty { out[key] = url }
        }
        return out
    }

    static func saveCover(key: String, url: String) {
        var cache = coverCache()
        cache[key] = url
        while cache.count > maxCoverCache {
            if let first = cache.keys.first { cache.removeValue(forKey: first) }
        }
        writeObject(named: coverCacheCollection, cache)
    }

    // MARK: - Lyrics cache

    static func cachedLyrics(for identityKey: String) -> [StoredLyricLine]? {
        let dict = readObject(named: lyricsCacheCollection)
        guard let raw = dict[identityKey] as? [[String: Any]] else { return nil }
        return raw.map(StoredLyricLine.init(json:))
    }

    static func putLyrics(_ lines: [StoredLyricLine], for identityKey: String) {
        var cache = readObject(named: lyricsCacheCollection)
        cache[identityKey] = lines.map { $0.toJSON() }
        while cache.count > maxLyricsCache {
            if let first = cache.keys.first { cache.removeValue(forKey: first) }
        }
        writeObject(named: lyricsCacheCollection, cache)
    }

    // MARK: - Queue persistence

    static func getQueue() -> MusicQueueData {
        return MusicQueueData(json: readObject(named: queueCollection))
    }

    static func saveQueue(_ queue: MusicQueueData) {
        writeObject(named: queueCollection, queue.toJSON())
    }

    // MARK: - Downloads

    static func getDownloads() -> [DownloadedSong] {
        return readArray(named: downloadsCollection).map(DownloadedSong.init(json:))
    }

    static func saveDownloads(_ downloads: [DownloadedSong]) {
        writeArray(named: downloadsCollection, downloads.map { $0.toJSON() })
    }

    static func removeDownload(key: String) {
        saveDownloads(getDownloads().filter { $0.key != key })
    }

    // MARK: - Local music index

    /// The local-music index is a list of full Song JSON objects
    /// (Flutter LocalMusicStore._readIndex maps Song.fromJson) whose
    /// `localPath` carries the file reference. Repair-then-prune via
    /// LocalFileIndex: a file found on disk under its basename is
    /// kept, never dropped on a stale index alone.
    static func localMusicSongs() -> [MusicSong] {
        let stored = readArray(named: localMusicCollection).map(MusicSong.init(json:))
        var kept: [MusicSong] = []
        var changed = false
        for song in stored {
            if song.localPath.isEmpty {
                changed = true
                continue
            }
            if let resolved = LocalFileIndex.resolve(song.localPath, subdir: "local_music") {
                var repaired = song
                repaired.localPath = resolved.path
                if repaired.localPath != song.localPath { changed = true }
                kept.append(repaired)
            } else {
                // Gone in every place we know — pruned.
                changed = true
            }
        }
        if changed {
            writeArray(named: localMusicCollection, kept.map { $0.toJSON() })
        }
        return kept
    }

    /// Stored relative names (`local_music/<file>`), repaired then
    /// pruned via LocalFileIndex.
    static func localMusicFiles() -> [String] {
        return localMusicSongs().map { song in
            "local_music/\(URL(fileURLWithPath: song.localPath).lastPathComponent)"
        }
    }

    /// Local songs built from the repaired index. Titles come from
    /// the stored Song JSON (Flutter wrote full Song objects); the
    /// file URL is carried in localPath for the player.
    static func localSongs() -> [MusicSong] {
        return localMusicSongs()
    }

    // MARK: - Daily cache

    /// Merged daily file: { "YYYY-MM-DD": [Song JSON] }.
    static func dailyTracks(for dayKey: String) -> [MusicSong]? {
        let dict = readObject(named: dailyCollection)
        guard let raw = dict[dayKey] as? [[String: Any]] else { return nil }
        return raw.map(MusicSong.init(json:))
    }

    static func saveDailyTracks(_ tracks: [MusicSong], for dayKey: String) {
        var dict = readObject(named: dailyCollection)
        dict[dayKey] = tracks.map { $0.toJSON() }
        writeObject(named: dailyCollection, dict)
    }

    // MARK: - FM disliked ids

    static func fmDislikedIds() -> Set<String> {
        let url = LocalStore.collectionURL(named: "fmDislikedIds")
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let array = parsed as? [String] else { return [] }
        return Set(array)
    }

    /// B4: store the identityKey (platform|id), not the bare song
    /// id — the same id on another platform must not be disliked
    /// along with it. Legacy bare-id entries keep working: fmQueue
    /// checks both forms.
    static func addFMDisliked(key: String) {
        var ids = fmDislikedIds()
        ids.insert(key)
        let url = LocalStore.collectionURL(named: "fmDislikedIds")
        guard let data = MusicDict.data(forTopLevel: Array(ids)) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    // MARK: - Resume map

    static func resumeMap() -> [String: Int] {
        let dict = readObject(named: resumeCollection)
        var out: [String: Int] = [:]
        for (key, value) in dict {
            if let seconds = value as? Int { out[key] = seconds }
            if let seconds = value as? Double { out[key] = Int(seconds) }
        }
        return out
    }

    static func resumeSeconds(for identityKey: String) -> Int {
        return resumeMap()[identityKey] ?? 0
    }

    static func saveResume(_ identityKey: String, seconds: Int) {
        var map = resumeMap()
        map[identityKey] = seconds
        writeObject(named: resumeCollection, map)
    }

    /// Drop the resume point for a track (natural completion):
    /// the next play starts from 0. No-op when there is no
    /// checkpoint, so it never rewrites the file needlessly.
    static func clearResume(_ identityKey: String) {
        var map = resumeMap()
        guard map.removeValue(forKey: identityKey) != nil else { return }
        writeObject(named: resumeCollection, map)
    }
}

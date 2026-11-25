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
        if let songJSON = json["song"] as? [String: Any] {
            self.song = MusicSong(json: songJSON)
        } else {
            self.song = nil
        }
        // b49fix19 P1-3: normalise the key on read — a backup
        // entry whose stored key is "lx:xxx|id" is the same
        // favourite as the live "wy|id" row; without this,
        // toggleFav / isFav (which use the normalised
        // identityKey) can never find or remove it, and the
        // star goes out while the row stays. The merge rewrites
        // the stored key the same way; this covers files that
        // never go through an import.
        self.key = MigrationStore.favMergeKey(for: json)
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
    /// Pinned ranking pool for the day (b49fix7 P2-3): the
    /// total-100 ranking, computed once per day and fixed to
    /// disk. The daily load draws its fills / spares from this
    /// pool, never from a fresh ranking — so a reload at noon
    /// (listenLog grown) cannot re-rank the day's picks. Same
    /// file shape as hao_daily ({ "YYYY-MM-DD": [Song JSON] }).
    static let dailyPoolCollection = "hao_daily_pool"
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
        // b49fix19 P2-9c: a file that exists but does not decode
        // is quarantined on the live read path too — the import
        // path already did this (MigrationStore.readJSONList),
        // but a live read that returned [] let the next live
        // write overwrite the corrupt bytes with no preservation.
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let array = parsed as? [[String: Any]]
        else {
            LocalStore.quarantineFile(at: url, name: name, reason: "decode failed")
            return []
        }
        return array
    }

    private static func readObject(named name: String) -> [String: Any] {
        let url = LocalStore.collectionURL(named: name)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        // b49fix19 P2-9c: see readArray.
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = parsed as? [String: Any]
        else {
            LocalStore.quarantineFile(at: url, name: name, reason: "decode failed")
            return [:]
        }
        return dict
    }

    private static func readStringArray(named name: String) -> [String] {
        let url = LocalStore.collectionURL(named: name)
        guard let data = try? Data(contentsOf: url) else { return [] }
        // b49fix19 P2-9c: see readArray.
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let array = parsed as? [String]
        else {
            LocalStore.quarantineFile(at: url, name: name, reason: "decode failed")
            return []
        }
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

    // MARK: - Background song-switch I/O (build 36, item 10)
    //
    // A song switch used to do four synchronous JSON file operations
    // on the main thread (fav read, lyrics-cache read, recent
    // read+write, queue write). The files are small, but the cost
    // grows with the favourites / recent lists and it ran on every
    // switch. These wrappers move the disk work onto one serial
    // background queue, so rapid switches keep write order and the
    // main thread never blocks on disk. Completions run on the main
    // thread; a failed write stays silent, exactly like the sync
    // versions (they already swallow errors with try?).
    //
    // DispatchWorkItem — not trailing .async closures — is deliberate:
    // Xcode 26 types DispatchQueue.async closures @Sendable, and the
    // captured MusicSong / completion values are not Sendable under
    // SWIFT_VERSION 5.0 (same trap AGENTS.md records for
    // DispatchQueue.main.async).

    /// Serial background queue for song-switch persistence.
    private static let songSwitchIOQueue = DispatchQueue(
        label: "studio.hao.musicLibraryStore.songSwitchIO", qos: .utility)

    /// Favourite check off the main thread; `completion` runs on main.
    static func isFavAsync(_ song: MusicSong, completion: @escaping (Bool) -> Void) {
        let work = DispatchWorkItem {
            let fav = isFav(song)
            let back = DispatchWorkItem { completion(fav) }
            DispatchQueue.main.async(execute: back)
        }
        songSwitchIOQueue.async(execute: work)
    }

    /// Lyrics-cache read off the main thread; `completion` runs on main.
    static func cachedLyricsAsync(for identityKey: String, completion: @escaping ([StoredLyricLine]?) -> Void) {
        let work = DispatchWorkItem {
            let cached = cachedLyrics(for: identityKey)
            let back = DispatchWorkItem { completion(cached) }
            DispatchQueue.main.async(execute: back)
        }
        songSwitchIOQueue.async(execute: work)
    }

    /// Lyrics-cache read with the entry's short-lived flag (b49fix2
    /// P2-42); `completion` runs on main. The view model needs the
    /// flag to skip its own truncation check for these entries.
    static func cachedLyricsInfoAsync(for identityKey: String, completion: @escaping ((lines: [StoredLyricLine], shortLived: Bool)?) -> Void) {
        let work = DispatchWorkItem {
            let cached = cachedLyricsInfo(for: identityKey)
            let back = DispatchWorkItem { completion(cached) }
            DispatchQueue.main.async(execute: back)
        }
        songSwitchIOQueue.async(execute: work)
    }

    /// Recent write off the main thread. The change notification is
    /// posted on main after the write lands, so observers that reload
    /// (getRecent) always read the new list.
    static func addRecentAsync(_ song: MusicSong) {
        let work = DispatchWorkItem {
            writeRecent(song)
            let back = DispatchWorkItem {
                NotificationCenter.default.post(name: .haoMusicRecentChanged, object: nil)
            }
            DispatchQueue.main.async(execute: back)
        }
        songSwitchIOQueue.async(execute: work)
    }

    /// Queue write off the main thread. Every queue write in the
    /// player view model goes through here so rapid switches and
    /// queue edits serialize in call order on the one queue — a
    /// later edit can never be overwritten by an earlier switch's
    /// still-pending write. b49fix18 D-3: the work runs directly
    /// on MigrationStore.musicQueueWriteQueue (not via
    /// songSwitchIOQueue) — the import's mergeMusicQueue reads
    /// the live queue under that same queue, so a switch that
    /// already happened is always visible to the import's
    /// live-empty check (FIFO: the import's sync runs after
    /// every previously-enqueued queue write, closing the
    /// TOCTOU that used to report the backup queue as imported
    /// while the queued save then overwrote it). A switch
    /// enqueued AFTER the import's read is a genuinely later
    /// event and still wins by design (live-wins). The queue
    /// edits' call-order guarantee is unchanged — it now
    /// holds on musicQueueWriteQueue instead.
    static func saveQueueAsync(_ queue: MusicQueueData) {
        let work = DispatchWorkItem { saveQueueLocked(queue) }
        MigrationStore.musicQueueWriteQueue.async(execute: work)
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
        // b49fix17 P2-6: the write runs under
        // MigrationStore.collectionWriteQueue, the same queue
        // the backup import's lists merge takes. Callers that
        // read-modify-write (createList, deleteList, updateList,
        // renameList, addTracksToList, removeTrackFromList) take
        // the queue once for the whole operation and call
        // saveListsLocked — taking it here as well would
        // deadlock (DispatchQueue.sync re-entry).
        MigrationStore.collectionWriteQueue.sync {
            saveListsLocked(lists)
        }
    }

    /// The saveLists body, assuming collectionWriteQueue is
    /// held. Split out so the atomic playlist operations can
    /// read, mutate and save under the same queue without
    /// re-entering it (same shape as writeDailyTracksLocked).
    private static func saveListsLocked(_ lists: [UserPlaylist]) {
        writeArray(named: listsCollection, lists.map { $0.toJSON() })
    }

    static func createList(named name: String) -> UserPlaylist {
        MigrationStore.collectionWriteQueue.sync {
            var lists = getLists()
            let list = UserPlaylist(id: UUID().uuidString, name: name, tracks: [])
            lists.append(list)
            saveListsLocked(lists)
            return list
        }
    }

    static func deleteList(id: String) {
        MigrationStore.collectionWriteQueue.sync {
            saveListsLocked(getLists().filter { $0.id != id })
        }
        // b49fix2 P2-28: the snapshot is the deleted list's ghost —
        // without this, 切歌 still plays it from the snapshot and
        // the detail page stays stuck on "歌单不存在".
        PlaylistSnapshotStore.delete(source: PlaySource(kind: .playlist, id: id))
        // A3: 我的's 歌单 count reloads on this — the pushed list
        // refreshes itself, the count did not.
        NotificationCenter.default.post(name: .haoMusicPlaylistChanged, object: nil)
    }

    static func updateList(_ updated: UserPlaylist) {
        MigrationStore.collectionWriteQueue.sync {
            var lists = getLists()
            if let index = lists.firstIndex(where: { $0.id == updated.id }) {
                lists[index] = updated
                saveListsLocked(lists)
            }
        }
    }

    /// Renames a playlist atomically (b49fix17 P2-6): the
    /// view-model rename used to read-modify-write outside the
    /// store, so a rename that read before an import merge and
    /// saved after it overwrote the imported lists with stale
    /// bytes. Returns false when the list does not exist.
    @discardableResult
    static func renameList(id: String, name: String) -> Bool {
        MigrationStore.collectionWriteQueue.sync { () -> Bool in
            var lists = getLists()
            guard let index = lists.firstIndex(where: { $0.id == id }) else { return false }
            lists[index].name = name
            saveListsLocked(lists)
            return true
        }
    }

    /// Adds songs to a playlist atomically (b49fix17 P2-6):
    /// same stale-write hole as renameList — the view-model
    /// add used to read the lists, mutate in memory, then save.
    /// Returns (added, dropped, dupes) like
    /// UserPlaylist.addTracks, or (0, 0, 0) when the list does
    /// not exist.
    static func addTracksToList(_ songs: [MusicSong], listId: String) -> (added: Int, dropped: Int, dupes: Int) {
        MigrationStore.collectionWriteQueue.sync { () -> (added: Int, dropped: Int, dupes: Int) in
            var lists = getLists()
            guard let index = lists.firstIndex(where: { $0.id == listId }) else {
                return (0, 0, 0)
            }
            let result = lists[index].addTracks(songs)
            saveListsLocked(lists)
            return result
        }
    }

    /// Removes one song from a playlist atomically (b49fix17
    /// P2-6): same stale-write hole as renameList. Returns
    /// false when the list does not exist.
    @discardableResult
    static func removeTrackFromList(song: MusicSong, listId: String) -> Bool {
        MigrationStore.collectionWriteQueue.sync { () -> Bool in
            var lists = getLists()
            guard let index = lists.firstIndex(where: { $0.id == listId }) else { return false }
            lists[index].tracks.removeAll(where: { $0.identityKey == song.identityKey })
            saveListsLocked(lists)
            return true
        }
    }

    // MARK: - Favourited playlists / albums / artists (b45-b)

    /// Coda §3.3/§3.4: "收藏的歌单 / 收藏的专辑 / 收藏的歌手"
    /// are local-only favourites (no login anywhere). Playlist
    /// favourites are a set of list ids; album/artist favourites
    /// are minimal JSON dicts (id/name/cover + artist/platform
    /// for albums, counts/alias for artists) in their own
    /// collections, so a favourited album/artist survives even
    /// when its songs are not in the local library.
    static let favPlaylistsCollection = "hao_fav_playlists"
    static let favAlbumsCollection = "hao_fav_albums"
    static let favArtistsCollection = "hao_fav_artists"

    static func favPlaylistIds() -> Set<String> {
        return Set(readStringArray(named: favPlaylistsCollection))
    }

    static func isFavPlaylist(id: String) -> Bool {
        return favPlaylistIds().contains(id)
    }

    @discardableResult
    static func toggleFavPlaylist(id: String) -> Bool {
        // b49fix17 P2-6: read-modify-write under
        // MigrationStore.collectionWriteQueue (same queue as the
        // import's merge); the notification posts after the
        // queue block returns.
        let added: Bool = MigrationStore.collectionWriteQueue.sync {
            var ids = favPlaylistIds()
            if ids.contains(id) {
                ids.remove(id)
                writeStringArray(named: favPlaylistsCollection, Array(ids))
                return false
            } else {
                ids.insert(id)
                writeStringArray(named: favPlaylistsCollection, Array(ids))
                return true
            }
        }
        NotificationCenter.default.post(name: .haoMusicPlaylistChanged, object: nil)
        return added
    }

    static func favAlbums() -> [AlbumSummary] {
        return readArray(named: favAlbumsCollection).compactMap { dict in
            let id = MusicDict.string(dict, "id")
            let name = MusicDict.string(dict, "name")
            guard !name.isEmpty else { return nil }
            return AlbumSummary(
                id: id, name: name, cover: MusicDict.string(dict, "cover"),
                artist: MusicDict.string(dict, "artist"),
                publishTime: MusicDict.int(dict, "publishTime"),
                songCount: MusicDict.int(dict, "songCount"),
                platform: MusicPlatform.fromCode(MusicDict.string(dict, "platform"))
            )
        }
    }

    static func isFavAlbum(id: String, name: String) -> Bool {
        return favAlbums().contains { $0.id == id && $0.name == name }
    }

    @discardableResult
    static func toggleFavAlbum(_ album: AlbumSummary) -> Bool {
        // b49fix17 P2-6: read-modify-write under
        // MigrationStore.collectionWriteQueue (same queue as the
        // import's merge).
        MigrationStore.collectionWriteQueue.sync { () -> Bool in
            var albums = favAlbums()
            if let index = albums.firstIndex(where: { $0.id == album.id && $0.name == album.name }) {
                albums.remove(at: index)
                writeArray(named: favAlbumsCollection, albums.map { albumDict($0) })
                return false
            }
            albums.append(album)
            writeArray(named: favAlbumsCollection, albums.map { albumDict($0) })
            return true
        }
    }

    private static func albumDict(_ album: AlbumSummary) -> [String: Any] {
        return [
            "id": album.id, "name": album.name, "cover": album.cover,
            "artist": album.artist, "publishTime": album.publishTime,
            "songCount": album.songCount, "platform": album.platform.rawValue,
        ]
    }

    static func favArtists() -> [ArtistSummary] {
        return readArray(named: favArtistsCollection).compactMap { dict in
            let name = MusicDict.string(dict, "name")
            guard !name.isEmpty else { return nil }
            return ArtistSummary(
                id: MusicDict.string(dict, "id"), name: name,
                cover: MusicDict.string(dict, "cover"),
                musicSize: MusicDict.int(dict, "musicSize"),
                albumSize: MusicDict.int(dict, "albumSize"),
                platform: MusicPlatform.fromCode(MusicDict.string(dict, "platform")),
                alias: MusicDict.string(dict, "alias")
            )
        }
    }

    static func isFavArtist(id: String, name: String) -> Bool {
        return favArtists().contains { $0.id == id && $0.name == name }
    }

    @discardableResult
    static func toggleFavArtist(_ artist: ArtistSummary) -> Bool {
        // b49fix17 P2-6: read-modify-write under
        // MigrationStore.collectionWriteQueue (same queue as the
        // import's merge).
        MigrationStore.collectionWriteQueue.sync { () -> Bool in
            var artists = favArtists()
            if let index = artists.firstIndex(where: { $0.id == artist.id && $0.name == artist.name }) {
                artists.remove(at: index)
                writeArray(named: favArtistsCollection, artists.map { artistDict($0) })
                return false
            }
            artists.append(artist)
            writeArray(named: favArtistsCollection, artists.map { artistDict($0) })
            return true
        }
    }

    private static func artistDict(_ artist: ArtistSummary) -> [String: Any] {
        return [
            "id": artist.id, "name": artist.name, "cover": artist.cover,
            "musicSize": artist.musicSize, "albumSize": artist.albumSize,
            "platform": artist.platform.rawValue, "alias": artist.alias,
        ]
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
        // b49fix17 P2-6: the read-modify-write runs under
        // MigrationStore.collectionWriteQueue, the same queue
        // the backup import's fav merge takes. The notification
        // posts after the queue block returns (an observer
        // calling back into the store must never run while the
        // queue is held).
        let added: Bool = MigrationStore.collectionWriteQueue.sync {
            var entries = favEntries()
            let key = song.identityKey
            if let index = entries.firstIndex(where: { $0.key == key }) {
                entries.remove(at: index)
                writeArray(named: favCollection, entries.map { $0.toJSON() })
                return false
            } else {
                entries.insert(MusicFavEntry(key: key, song: song), at: 0)
                writeArray(named: favCollection, entries.map { $0.toJSON() })
                return true
            }
        }
        // b49fix3 P2-22: the add/remove rides in the
        // notification object — MainTabView's backup nudge fires
        // on add only; the other listeners (star refresh, list
        // reloads) ignore the object, so they still fire on
        // remove as before.
        NotificationCenter.default.post(name: .haoMusicFavChanged, object: added)
        return added
    }

    static func isFav(_ song: MusicSong) -> Bool {
        return favIds().contains(song.identityKey)
    }

    // MARK: - Recent plays

    static func getRecent() -> [MusicSong] {
        return readArray(named: recentCollection).map(MusicSong.init(json:))
    }

    static func addRecent(_ song: MusicSong) {
        writeRecent(song)
        NotificationCenter.default.post(name: .haoMusicRecentChanged, object: nil)
    }

    /// File part of addRecent, without the notification: the
    /// background wrapper posts on the main thread after the write
    /// lands, so observers that reload always read the new list.
    /// b49fix17 P1-2: the whole read-modify-write runs under
    /// MigrationStore.recentWriteQueue, the same queue the backup
    /// import's recent merge takes — a switch landing between
    /// the import's re-read and write is serialised after it
    /// instead of being overwritten by it.
    private static func writeRecent(_ song: MusicSong) {
        MigrationStore.recentWriteQueue.sync {
            var list = getRecent().filter { $0.identityKey != song.identityKey }
            list.insert(song, at: 0)
            writeArray(named: recentCollection, Array(list.prefix(maxRecent)).map { $0.toJSON() })
        }
    }

    static func clearRecent() {
        MigrationStore.recentWriteQueue.sync {
            writeArray(named: recentCollection, [])
        }
        NotificationCenter.default.post(name: .haoMusicRecentChanged, object: nil)
    }

    // MARK: - Listen log

    static func getListenLog() -> [ListenEvent] {
        return readArray(named: listenCollection).map(ListenEvent.init(json:))
    }

    /// Read-modify-write under MigrationStore.listenLogWriteQueue
    /// (b49fix15 P2-1): the backup import also writes this file
    /// from a background queue, so the get → append → write must
    /// be atomic against the import's merge — otherwise a
    /// completion landing between the import's apply-time re-read
    /// and its write is overwritten and lost. The queue is held
    /// only across file I/O; readers (getListenLog) take no lock
    /// because writes are .atomic.
    static func recordListenEvent(_ event: ListenEvent) {
        MigrationStore.listenLogWriteQueue.sync {
            var log = getListenLog()
            log.append(event)
            if log.count > maxListenEvents {
                log.removeFirst(log.count - maxListenEvents)
            }
            writeArray(named: listenCollection, log.map { $0.toJSON() })
        }
    }

    // MARK: - Search history

    static func getSearchHistory() -> [String] {
        return readStringArray(named: searchHistoryCollection)
    }

    static func saveSearchQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // b49fix17 P2-6: read-modify-write under
        // MigrationStore.collectionWriteQueue (same queue as the
        // import's merge).
        MigrationStore.collectionWriteQueue.sync {
            var history = getSearchHistory().filter { $0 != trimmed }
            history.insert(trimmed, at: 0)
            writeStringArray(named: searchHistoryCollection, Array(history.prefix(maxSearchHistory)))
        }
    }

    static func clearSearchHistory() {
        MigrationStore.collectionWriteQueue.sync {
            writeStringArray(named: searchHistoryCollection, [])
        }
    }

    static func removeSearchQuery(_ query: String) {
        MigrationStore.collectionWriteQueue.sync {
            writeStringArray(named: searchHistoryCollection, getSearchHistory().filter { $0 != query })
        }
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
        // b49fix17 P2-6: read-modify-write under
        // MigrationStore.collectionWriteQueue (same queue as the
        // import's merge).
        MigrationStore.collectionWriteQueue.sync {
            var cache = coverCache()
            cache[key] = url
            while cache.count > maxCoverCache {
                guard let first = cache.keys.first else { break }
                cache.removeValue(forKey: first)
                // b49fix19 P1-7: record the eviction — a key
                // evicted between the import's merge and its
                // verify is excused there instead of failing
                // the whole import.
                MigrationStore.noteCacheKeyEvicted(file: coverCacheCollection, key: first)
            }
            writeObject(named: coverCacheCollection, cache)
        }
    }

    // MARK: - Lyrics cache

    /// Lyrics-cache schema version (b49): 1 = unversioned, no
    /// length check — an old fetch that only returned the first
    /// half of a song's lyrics stayed cached forever, and every
    /// later play hit it first and never re-fetched (chen build
    /// 48: "歌词到后面也不显示"). Version 2 invalidates all
    /// version-1 entries on first read; new entries are also
    /// length-checked at the call site (see loadLyrics), so a
    /// truncated fetch can never poison the cache again.
    static let lyricsCacheVersion = 2
    private static let lyricsCacheVersionKey = "hao.lyricsCacheVersion"
    /// Insertion order for the lyrics cache (b49sweep): a plain
    /// Dictionary has no order, so evicting `cache.keys.first`
    /// could drop the just-played song while keeping a stale
    /// entry. The order list (oldest first) lives in
    /// UserDefaults next to the version key; it is reconciled
    /// against the file on every write (unknown keys — legacy
    /// entries written before ordering — sort to the front so
    /// they evict first, the just-written key goes last).
    private static let lyricsCacheOrderKey = "hao.lyricsCacheOrder"

    private static func lyricsCacheOrder() -> [String] {
        UserDefaults.standard.stringArray(forKey: lyricsCacheOrderKey) ?? []
    }

    private static func saveLyricsCacheOrder(_ order: [String]) {
        UserDefaults.standard.set(order, forKey: lyricsCacheOrderKey)
    }

    /// Drops one lyrics-cache entry (expired short-lived marker
    /// or invalid entry) — the read path's write, under the same
    /// queue as putLyrics and the import's merge (b49fix17 P2-6):
    /// the entry is re-read inside the queue, so a drop landing
    /// after an import merge removes only its own key instead of
    /// writing back a stale pre-merge dict.
    private static func dropLyricsEntry(_ identityKey: String) {
        MigrationStore.collectionWriteQueue.sync {
            var dict = readObject(named: lyricsCacheCollection)
            guard dict.removeValue(forKey: identityKey) != nil else { return }
            writeObject(named: lyricsCacheCollection, dict)
            saveLyricsCacheOrder(lyricsCacheOrder().filter { $0 != identityKey })
            // b49fix19 P1-7: record the drop — same excuse as
            // an eviction (see saveCover).
            MigrationStore.noteCacheKeyEvicted(file: lyricsCacheCollection, key: identityKey)
        }
    }

    static func cachedLyrics(for identityKey: String) -> [StoredLyricLine]? {
        cachedLyricsInfo(for: identityKey)?.lines
    }

    /// Lyrics-cache read with the entry's short-lived flag (b49fix2
    /// P2-42): truncated fetches are cached under a 1 h marker
    /// instead of never being cached, so a song whose lyrics
    /// legitimately end early (long instrumental outro) does not
    /// re-fetch on every play.
    static func cachedLyricsInfo(for identityKey: String) -> (lines: [StoredLyricLine], shortLived: Bool)? {
        guard UserDefaults.standard.integer(forKey: lyricsCacheVersionKey) == lyricsCacheVersion else {
            // First read after the bump (or a fresh install with
            // no version stamped): drop the stale collection once
            // so truncated version-1 entries are never served.
            // b49fix17 P2-6: under collectionWriteQueue, like the
            // import's merge — a wipe landing after the merge
            // must not interleave with it.
            MigrationStore.collectionWriteQueue.sync {
                // b49fix20 D22-9: record every key the wipe
                // removes — the version-bump wipe used to clear
                // the cache with no eviction trace, so an
                // import's verify (which excuses only recorded
                // evictions) false-failed on a wipe that landed
                // mid-import. And clear the order file, so the
                // wiped keys do not linger as order entries for
                // keys that no longer exist.
                let wiped = readObject(named: lyricsCacheCollection)
                for key in wiped.keys {
                    MigrationStore.noteCacheKeyEvicted(file: lyricsCacheCollection, key: key)
                }
                writeObject(named: lyricsCacheCollection, [:])
                saveLyricsCacheOrder([])
                UserDefaults.standard.set(lyricsCacheVersion, forKey: lyricsCacheVersionKey)
            }
            return nil
        }
        // b49fix17 P2-6: `let` now — the entry drops below go
        // through dropLyricsEntry (re-read inside the queue),
        // so this local dict is never mutated here.
        let dict = readObject(named: lyricsCacheCollection)
        guard let raw = dict[identityKey] else { return nil }
        // v2 entry with per-entry metadata: {"v", "dur", "count",
        // "lines"}. "dur" is the song duration when the caller
        // knew it, else the last line's time; "count" is the
        // stored line count. A mismatched version / count, or a
        // last line far short of the stored duration, is a
        // truncated or corrupt entry — drop it so the caller
        // re-fetches instead of serving it forever.
        if let entry = raw as? [String: Any],
           let lineDicts = entry["lines"] as? [[String: Any]] {
            let version = MusicDict.int(entry, "v")
            let count = MusicDict.int(entry, "count")
            let duration = MusicDict.double(entry, "dur")
            let lines = lineDicts.map(StoredLyricLine.init(json:))
            let lastTime = lines.map(\.t).max() ?? 0
            // b49fix2 P2-42: a short-lived entry is a KNOWN-truncated
            // fetch cached under a 1 h marker — the 80% check must
            // not drop it (that is the whole point), but an expired
            // marker is dropped so the next play re-fetches.
            let shortLived = (entry["short"] as? Bool) == true
            if shortLived {
                let expiresAt = MusicDict.double(entry, "expiresAt")
                if expiresAt > 0, Date().timeIntervalSince1970 >= expiresAt {
                    dropLyricsEntry(identityKey)
                    return nil
                }
            }
            let invalid = version != lyricsCacheVersion
                || count != lineDicts.count
                || (!shortLived && duration > 0 && !lines.isEmpty && lastTime < duration * 0.8)
            if invalid {
                dropLyricsEntry(identityKey)
                return nil
            }
            return (lines, shortLived)
        }
        // Legacy b49 entry: a plain line array with no metadata.
        // Valid (the global version wipe above already cleared
        // version-1 entries); it gains metadata on its next put.
        guard let rawLines = raw as? [[String: Any]] else { return nil }
        return (rawLines.map(StoredLyricLine.init(json:)), false)
    }

    /// Stores lyrics with per-entry metadata (b49sweep): cache
    /// version + duration + line count, validated on read (see
    /// cachedLyrics). `duration` is the song's duration when the
    /// caller knows it (the player view model can pass
    /// song.dur); 0 falls back to the last line's time, in which
    /// case the read-side 80% check is a no-op and the b49
    /// call-site truncation guard stays the live check.
    /// Eviction is oldest-inserted first via the order list —
    /// never `cache.keys.first`.
    /// b49fix2 P2-42: `shortLived` caches a truncated fetch under
    /// a 1 h marker instead of not caching it at all — a song whose
    /// lyrics legitimately end early must not re-fetch on every play.
    static func putLyrics(_ lines: [StoredLyricLine], for identityKey: String, duration: TimeInterval = 0, shortLived: Bool = false) {
        // b49fix17 P2-6: the whole read-modify-write runs under
        // MigrationStore.collectionWriteQueue, the same queue
        // the backup import's lyrics merge takes — a fetch
        // landing between the import's re-read and write is
        // serialised after it instead of being overwritten by it.
        MigrationStore.collectionWriteQueue.sync {
            putLyricsLocked(lines, for: identityKey, duration: duration, shortLived: shortLived)
        }
    }

    /// The putLyrics body, assuming collectionWriteQueue is held
    /// (same shape as saveListsLocked).
    private static func putLyricsLocked(_ lines: [StoredLyricLine], for identityKey: String, duration: TimeInterval = 0, shortLived: Bool = false) {
        var cache = readObject(named: lyricsCacheCollection)
        let lastTime = lines.map(\.t).max() ?? 0
        var entry: [String: Any] = [
            "v": lyricsCacheVersion,
            "dur": duration > 0 ? duration : lastTime,
            "count": lines.count,
            "lines": lines.map { $0.toJSON() },
        ]
        if shortLived {
            entry["short"] = true
            entry["expiresAt"] = Date().timeIntervalSince1970 + 3600
        }
        cache[identityKey] = entry
        var order = lyricsCacheOrder().filter { cache[$0] != nil }
        order.removeAll(where: { $0 == identityKey })
        let unknown = cache.keys
            .filter { $0 != identityKey && !order.contains($0) }
            .sorted()
        order = unknown + order + [identityKey]
        while cache.count > maxLyricsCache {
            guard let oldest = order.first(where: { $0 != identityKey }) else { break }
            order.removeAll(where: { $0 == oldest })
            cache.removeValue(forKey: oldest)
            // b49fix19 P1-7: record the eviction — see saveCover.
            MigrationStore.noteCacheKeyEvicted(file: lyricsCacheCollection, key: oldest)
        }
        writeObject(named: lyricsCacheCollection, cache)
        saveLyricsCacheOrder(order)
        UserDefaults.standard.set(lyricsCacheVersion, forKey: lyricsCacheVersionKey)
    }

    // MARK: - Queue persistence

    static func getQueue() -> MusicQueueData {
        return MusicQueueData(json: readObject(named: queueCollection))
    }

    /// The queue write itself, assuming the caller's queue is
    /// held (b49fix18 D-3): saveQueueAsync dispatches here
    /// directly onto musicQueueWriteQueue, so the body must
    /// not sync on that queue again — that would deadlock.
    ///
    /// b49fix19 P2-8b: the sync `saveQueue` wrapper was deleted
    /// here — it had zero callers in the app and in ios/Tests,
    /// and the import's queue merge uses mergeMusicQueue, not
    /// it, so the "import-alignment entry" justification was
    /// false. saveQueueAsync + this function cover all paths.
    private static func saveQueueLocked(_ queue: MusicQueueData) {
        writeObject(named: queueCollection, queue.toJSON())
    }

    // MARK: - Downloads

    static func getDownloads() -> [DownloadedSong] {
        return readArray(named: downloadsCollection).map(DownloadedSong.init(json:))
    }

    static func saveDownloads(_ downloads: [DownloadedSong]) {
        // b49fix17 P2-6: the write runs under
        // MigrationStore.collectionWriteQueue, the same queue
        // the backup import's downloads merge takes.
        // removeDownload reads-modifies-writes through
        // saveDownloadsLocked so the whole operation holds the
        // queue once (no re-entry deadlock).
        MigrationStore.collectionWriteQueue.sync {
            saveDownloadsLocked(downloads)
        }
    }

    /// The saveDownloads body, assuming collectionWriteQueue
    /// is held (same shape as saveListsLocked).
    private static func saveDownloadsLocked(_ downloads: [DownloadedSong]) {
        writeArray(named: downloadsCollection, downloads.map { $0.toJSON() })
    }

    static func removeDownload(key: String) {
        MigrationStore.collectionWriteQueue.sync {
            saveDownloadsLocked(getDownloads().filter { $0.key != key })
        }
        // A3: 我的's 我的下载 count reloads on this — same
        // staleness as the playlist count above.
        NotificationCenter.default.post(name: .haoMusicDownloadChanged, object: nil)
    }

    // MARK: - Local music index

    /// The local-music index is a list of full Song JSON objects
    /// (Flutter LocalMusicStore._readIndex maps Song.fromJson) whose
    /// `localPath` carries the file reference. A plain read repairs
    /// each path via LocalFileIndex (in memory only) but never
    /// deletes: a song whose file fails to resolve is kept, so its
    /// row can still show the song and offer removal — a read must
    /// never permanently drop an entry (b49fix2 P2-9: the old read
    /// pruned + rewrote on every call, so a transiently
    /// unresolvable file vanished from the library for good).
    /// Pruning happens only on an explicit path (see
    /// pruneLocalSongs, called from delete / rescan).
    static func localMusicSongs() -> [MusicSong] {
        let stored = readArray(named: localMusicCollection).map(MusicSong.init(json:))
        return stored.compactMap { song in
            guard !song.localPath.isEmpty else { return nil }
            if let resolved = LocalFileIndex.resolve(song.localPath, subdir: "local_music") {
                var repaired = song
                repaired.localPath = resolved.path
                return repaired
            }
            // Unresolvable — kept with its stored path, so the row
            // can still show the song and offer removal instead of
            // the entry vanishing on a plain read.
            return song
        }
    }

    /// Explicit prune (b49fix2 P2-9): drop index entries whose
    /// files are gone in every place we know, and rewrite the
    /// index. Called only from delete / rescan paths — never from
    /// a plain read.
    @discardableResult
    static func pruneLocalSongs() -> [MusicSong] {
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

    /// Saves the daily list (b49fix5 P2-4): one atomic
    /// replace of the whole day key — a CAS guard above decides
    /// whether the save is safe; this function only writes.
    /// b49fix16 P2-2: the whole body runs under
    /// MigrationStore.dailyWriteQueue, the same queue the backup
    /// import's dict merges take — a replace landing between
    /// the import's re-read and write is serialised after it
    /// instead of overwriting the import (or vice versa).
    static func saveDailyTracks(_ tracks: [MusicSong], for dayKey: String) {
        MigrationStore.dailyWriteQueue.sync {
            writeDailyTracksLocked(tracks, for: dayKey)
        }
    }

    /// The saveDailyTracks body, assuming dailyWriteQueue is
    /// held. Split out so saveDailyTracksIfUnchanged can
    /// compare and save atomically under the same queue without
    /// re-entering it (DispatchQueue.sync on a serial queue from
    /// inside deadlocks).
    private static func writeDailyTracksLocked(_ tracks: [MusicSong], for dayKey: String) {
        var dict = readObject(named: dailyCollection)
        dict[dayKey] = tracks.map { $0.toJSON() }
        // b49sweep: prune day keys older than ~7 days on save —
        // nothing ever pruned them, so the file grew one key per
        // day forever. The rule lives in
        // MigrationStore.prunedDailyEntries (b49fix17 P2-4) —
        // one rule for the live writes and both import merges,
        // so a concurrent prune can no longer fail the import's
        // verify. (Load-side validity — only today's key
        // counts — lives in HomeViewModel.)
        dict = MigrationStore.prunedDailyEntries(dict, keeping: dayKey)
        writeObject(named: dailyCollection, dict)
    }

    /// Pure compare-and-swap decision for the daily cache
    /// (b49fix5 P2-4, unit-tested): a background reload's save
    /// writes only when the on-disk list is still the one the
    /// load read (a replaceDailySong — or a concurrent reload —
    /// that landed in between already left a complete newer list
    /// on disk, so overwriting it with this stale computation
    /// would undo the replacement). `force` (explicit refresh)
    /// always writes.
    static func shouldSaveDailyTracks(currentDiskKeys: [String], expectedKeys: [String], force: Bool) -> Bool {
        force || currentDiskKeys == expectedKeys
    }

    /// Compare-and-swap daily save (b49fix5 P2-4): writes
    /// `tracks` only when the on-disk list for `dayKey` is still
    /// the one the caller read (`expectedKeys`, identityKey
    /// order). Returns true when the write happened. The whole
    /// read-compare-write runs under
    /// MigrationStore.dailyWriteQueue (b49fix16 P2-2) — the
    /// same queue saveDailyTracks and the backup import's dict
    /// merges take — so it is atomic against replaceDailySong's
    /// save AND against a backup import writing hao_daily from
    /// a background queue. (Before fix16 the CAS only held
    /// against main-thread callers; the import interleaving was
    /// detected and refused, so callers MUST still honor the
    /// return value and publish the disk table on refusal —
    /// Discovery reloadDaily, b49fix15 P2-2; Home since
    /// b49fix6/7. A discarded `false` would leave the screen
    /// showing a list the disk does not have.)
    @discardableResult
    static func saveDailyTracksIfUnchanged(_ tracks: [MusicSong], for dayKey: String, expectedKeys: [String], force: Bool = false) -> Bool {
        MigrationStore.dailyWriteQueue.sync { () -> Bool in
            let current = dailyTracks(for: dayKey)?.map { $0.identityKey } ?? []
            guard shouldSaveDailyTracks(currentDiskKeys: current, expectedKeys: expectedKeys, force: force) else { return false }
            writeDailyTracksLocked(tracks, for: dayKey)
            return true
        }
    }

    /// Pinned ranking pool for the day (b49fix7 P2-3): the
    /// total-100 ranking, fixed to disk on the day's first
    /// load (once it reaches 40 — a thinner pool re-pins on
    /// every load, b49fix8 P2-3). Nil when no pool was ever
    /// pinned for the key.
    /// The pool is stored WITH the dislikes as of pin time
    /// excluded — pinnedRankingPool passes the pin-time
    /// disliked ids into MusicRadio.dailyPicks, whose scoring
    /// loop skips disliked songs — AND the load filters it by
    /// the CURRENT disliked ids at use time, so a song disliked
    /// after pinning still drops out. Both layers are required:
    /// do NOT remove the use-time filter as redundant (the
    /// old comment claimed the pool was stored UNFILTERED —
    /// wrong, b49fix8 P2-2 — and that claim would have invited
    /// exactly that deletion). A pool deeper than the 40-list
    /// is deliberate: the list holds 40, so a 40-deep pool
    /// would have almost no song the list does not already
    /// hold, and the fills would have nowhere to draw from
    /// once dislikes eat into it.
    static func dailyPool(for dayKey: String) -> [MusicSong]? {
        let dict = readObject(named: dailyPoolCollection)
        guard let raw = dict[dayKey] as? [[String: Any]] else { return nil }
        return raw.map(MusicSong.init(json:))
    }

    /// Save the day's pinned ranking pool. Same 7-day prune
    /// as saveDailyTracks (keys are YYYY-MM-DD dates; an
    /// unparseable key is kept, never deleted on a guess).
    /// b49fix17 P2-4/P2-6: the pool write runs under
    /// MigrationStore.dailyWriteQueue now, not its own
    /// dailyPoolQueue (b49fix8 P2-4) — the import's pool merge
    /// and the pool save must share ONE queue, or a pin
    /// landing between the merge's re-read and write is still
    /// lost. dailyPoolQueue is deleted; the midnight-race
    /// serialisation it provided now comes from dailyWriteQueue
    /// (same guarantee: the read-modify-write is atomic, a lost
    /// key would only cost one recompute anyway — the pool is a
    /// pure derived cache, no user data).
    static func saveDailyPool(_ tracks: [MusicSong], for dayKey: String) {
        MigrationStore.dailyWriteQueue.sync {
            var dict = readObject(named: dailyPoolCollection)
            dict[dayKey] = tracks.map { $0.toJSON() }
            dict = MigrationStore.prunedDailyEntries(dict, keeping: dayKey)
            writeObject(named: dailyPoolCollection, dict)
        }
    }

    // MARK: - FM disliked ids

    static func fmDislikedIds() -> Set<String> {
        let url = LocalStore.collectionURL(named: "fmDislikedIds")
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let array = parsed as? [String]
        else {
            // b49fix19 P2-9c: see readArray — quarantine on the
            // live read path instead of returning empty and
            // letting the next write overwrite corrupt bytes.
            LocalStore.quarantineFile(at: url, name: "fmDislikedIds", reason: "decode failed")
            return []
        }
        return Set(array)
    }

    /// B4: store the identityKey (platform|id), not the bare song
    /// id — the same id on another platform must not be disliked
    /// along with it. Legacy bare-id entries keep working: fmQueue
    /// checks both forms.
    static func addFMDisliked(key: String) {
        // b49fix17 P2-6: read-modify-write under
        // MigrationStore.collectionWriteQueue (same queue as the
        // import's merge).
        MigrationStore.collectionWriteQueue.sync {
            var ids = fmDislikedIds()
            ids.insert(key)
            let url = LocalStore.collectionURL(named: "fmDislikedIds")
            guard let data = MusicDict.data(forTopLevel: Array(ids)) else { return }
            try? data.write(to: url, options: [.atomic])
        }
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
        // b49fix17 P2-2: the whole read-modify-write runs under
        // MigrationStore.resumeWriteQueue, the same queue the
        // backup import's resume merge takes — a checkpoint that
        // read the old map before an import write can no longer
        // write back after it and restore imported resume values
        // to pre-import values. (The key-only verify tolerates a
        // checkpoint advancing the playing song's value; the
        // queue closes the stale-write hole itself.)
        MigrationStore.resumeWriteQueue.sync {
            var map = resumeMap()
            map[identityKey] = seconds
            writeObject(named: resumeCollection, map)
        }
    }

    /// Drop the resume point for a track (natural completion):
    /// the next play starts from 0. No-op when there is no
    /// checkpoint, so it never rewrites the file needlessly.
    /// b49fix17 P2-2: runs under resumeWriteQueue like
    /// saveResume, and records the deletion — a key deleted
    /// between the import's write and its verify is excused
    /// there (deleting a key is a legitimate concurrent event,
    /// same class as a checkpoint advancing).
    static func clearResume(_ identityKey: String) {
        MigrationStore.resumeWriteQueue.sync {
            var map = resumeMap()
            guard map.removeValue(forKey: identityKey) != nil else { return }
            MigrationStore.noteResumeKeyDeleted(identityKey)
            writeObject(named: resumeCollection, map)
        }
    }
}

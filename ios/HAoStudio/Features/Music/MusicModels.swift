// HAo Studio 2.0 — music models (S2-C leg).
//
// Swift equivalents of the Flutter 1.1.6 music JSON shapes
// (lib/services/music/music_models.dart, HEAD 2ef902b). Field names and
// key rules are copied exactly so the S1-migrated JSON files
// (Documents/hao_fav.json, hao_recent.json, …) read back without
// re-migration. Durations are ALWAYS seconds.
//
// Parsing is tolerant on purpose: a bad number type or a missing field
// yields a default, never a crash — a corrupt collection must never
// crash launch (same rule as LocalStore.loadCollection).
//
// Contract types used here (owned by the player / LX legs, NOT defined
// in this file): MusicTrack { id, title, artist, album, coverURL,
// duration, sourceID }.

import AVFoundation
import Foundation


/// Tolerant JSON field readers. Numbers may arrive as Int, Double or
/// numeric strings (Flutter wrote ints; the migration re-encoded via
/// JSONSerialization, which keeps numbers as NSNumber).
enum MusicDict {
    static func string(_ dict: [String: Any], _ key: String) -> String {
        if let value = dict[key] as? String { return value }
        if let value = dict[key] as? NSNumber { return value.stringValue }
        return ""
    }

    static func int(_ dict: [String: Any], _ key: String) -> Int {
        if let value = dict[key] as? Int { return value }
        if let value = dict[key] as? Double { return Int(value) }
        if let value = dict[key] as? NSNumber { return value.intValue }
        if let value = dict[key] as? String { return Int(value) ?? 0 }
        return 0
    }

    static func double(_ dict: [String: Any], _ key: String) -> Double {
        if let value = dict[key] as? Double { return value }
        if let value = dict[key] as? Int { return Double(value) }
        if let value = dict[key] as? NSNumber { return value.doubleValue }
        if let value = dict[key] as? String { return Double(value) ?? 0 }
        return 0
    }

    static func bool(_ dict: [String: Any], _ key: String, default defaultValue: Bool) -> Bool {
        if let value = dict[key] as? Bool { return value }
        if let value = dict[key] as? NSNumber { return value.boolValue }
        return defaultValue
    }

    static func array(_ dict: [String: Any], _ key: String) -> [[String: Any]] {
        guard let raw = dict[key] as? [[String: Any]] else { return [] }
        return raw
    }

    /// Parse a top-level JSON document that must be an array of objects.
    static func objectArray(from data: Data) -> [[String: Any]] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let array = parsed as? [[String: Any]] else { return [] }
        return array
    }

    /// Parse a top-level JSON document that must be an object.
    static func object(from data: Data) -> [String: Any] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = parsed as? [String: Any] else { return [:] }
        return dict
    }

    /// Encode a top-level Array/Dictionary to JSON data. NEVER call
    /// with a top-level String: JSONSerialization throws an NSException
    /// ("Invalid top-level type in JSON write") that Swift cannot catch
    /// and the app crashes. Callers here only ever pass arrays/dicts.
    static func data(forTopLevel value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [])
    }
}

/// One song (Flutter `Song`). JSON keys are the Flutter toJson keys.
struct MusicSong: Equatable, Identifiable {
    var songId: String
    var title: String
    var artist: String
    var album: String
    var cover: String
    var platform: MusicPlatform
    /// Duration in seconds.
    var dur: Int
    var albumYear: Int
    var reasonKey: String
    var reasonArg: String
    /// Stored path of a local audio file, empty for remote songs.
    var localPath: String
    /// Raw source id this song came from (`wy` / `tx` / `kg` /
    /// `kw` / `mg`, or an LX script id `lx:…`). The badge reads
    /// this, not `platform`: `platform` defaults unknown codes to
    /// wy for ordering/identity, which would lie on the badge for
    /// a script result (S3-C badge fix).
    var sourceID: String

    var id: String { identityKey }

    /// The platform the badge may show: the real platform when the
    /// source id names one, nil when the platform is unknown (an
    /// `lx:…` script result) — the row then hides the badge
    /// instead of showing 网易. An empty source id means the song
    /// was built directly with an explicit platform (favourites /
    /// recent / local), so the platform field itself is the answer.
    var badgePlatform: MusicPlatform? {
        if sourceID.isEmpty { return platform }
        return MusicPlatform.platformIfKnown(sourceID)
    }

    init(
        songId: String = "",
        title: String = "",
        artist: String = "",
        album: String = "",
        cover: String = "",
        platform: MusicPlatform = .wy,
        dur: Int = 0,
        albumYear: Int = 0,
        reasonKey: String = "",
        reasonArg: String = "",
        localPath: String = "",
        sourceID: String = ""
    ) {
        self.songId = songId
        self.title = title
        self.artist = artist
        self.album = album
        self.cover = cover
        self.platform = platform
        self.dur = dur
        self.albumYear = albumYear
        self.reasonKey = reasonKey
        self.reasonArg = reasonArg
        self.localPath = localPath
        self.sourceID = sourceID
    }

    init(json: [String: Any]) {
        // Old entries carry no sourceID: fall back to the stored
        // platform code so their badges survive the migration.
        let storedSourceID = MusicDict.string(json, "sourceID")
        self.init(
            songId: MusicDict.string(json, "songId"),
            title: MusicDict.string(json, "title"),
            artist: MusicDict.string(json, "artist"),
            album: MusicDict.string(json, "album"),
            cover: MusicDict.string(json, "cover"),
            platform: MusicPlatform.fromCode(json["platform"] as? String),
            dur: MusicDict.int(json, "dur"),
            albumYear: MusicDict.int(json, "albumYear"),
            reasonKey: MusicDict.string(json, "reasonKey"),
            reasonArg: MusicDict.string(json, "reasonArg"),
            localPath: MusicDict.string(json, "localPath"),
            sourceID: storedSourceID.isEmpty
                ? MusicDict.string(json, "platform") : storedSourceID
        )
    }

    func toJSON() -> [String: Any] {
        var dict: [String: Any] = [
            "songId": songId,
            "title": title,
            "artist": artist,
            "album": album,
            "cover": cover,
            "platform": platform.rawValue,
            "dur": dur,
            "albumYear": albumYear,
            "reasonKey": reasonKey,
            "reasonArg": reasonArg,
            "sourceID": sourceID,
        ]
        if !localPath.isEmpty { dict["localPath"] = localPath }
        return dict
    }

    /// Identity key for favourites / recent / listen log / resume.
    /// A song with an empty songId MUST NOT share a key with every
    /// other empty-id song on the same platform: empty ids fall back
    /// to title+artist+album (Flutter identityKey, verbatim).
    var identityKey: String {
        if !songId.isEmpty { return "\(platform.rawValue)|\(songId)" }
        return "\(platform.rawValue)|\(title)|\(artist)|\(album)"
    }

    /// Dedupe key for aggregated search: platform + songId; empty id
    /// falls back to title+artist (Flutter dedupeKey, verbatim).
    var dedupeKey: String {
        if !songId.isEmpty { return "\(platform.rawValue)|\(songId)" }
        return "\(platform.rawValue)||\(title)|\(artist)"
    }

    /// True for an imported local file (songId starts with 'local:'
    /// AND a path is stored — both must hold).
    var isLocal: Bool { !localPath.isEmpty && songId.hasPrefix("local:") }

    /// Convert a contract MusicTrack (LX leg) to a local song.
    /// Assumed MusicTrack field types (see the C-leg report):
    /// coverURL is a String, duration is Int seconds.
    /// The cover is upgraded http -> https at this boundary: ATS
    /// (NSAllowsArbitraryLoads = false) blocks http fetches, so a
    /// raw http cover would silently fail everywhere downstream.
    init(from track: MusicTrack) {
        self.init(
            songId: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            cover: MusicText.toHttps(track.coverURL?.absoluteString ?? ""),
            platform: MusicPlatform.fromSourceID(track.sourceID),
            dur: track.duration.map { Int($0) } ?? 0,
            sourceID: track.sourceID
        )
    }

    /// The playback item for this song (coordinator contract).
    /// The cover MUST travel with the item: the mini player and
    /// the Now Playing artwork chain read coverURL off this item
    /// only — dropping it here (as before) left both with no
    /// artwork at all, whatever the song carried. Upgraded
    /// http -> https for the same ATS reason as above.
    func toPlaybackItem() -> PlaybackItem {
        PlaybackItem(id: identityKey, kind: .music, title: title, artist: artist,
                     coverURL: cover.isEmpty ? nil : URL(string: MusicText.toHttps(cover)),
                     localFileURL: localPath.isEmpty ? nil : URL(fileURLWithPath: localPath))
    }
}

/// One user playlist (Flutter `UserPlaylist`).
struct UserPlaylist: Equatable, Identifiable {
    var id: String
    var name: String
    var tracks: [MusicSong]

    var trackCount: Int { tracks.count }
    var cover: String { tracks.first?.cover ?? "" }

    init(id: String = "", name: String = "", tracks: [MusicSong] = []) {
        self.id = id
        self.name = name
        self.tracks = tracks
    }

    init(json: [String: Any]) {
        self.init(
            id: MusicDict.string(json, "id"),
            name: MusicDict.string(json, "name"),
            tracks: MusicDict.array(json, "tracks").map(MusicSong.init(json:))
        )
    }

    func toJSON() -> [String: Any] {
        return ["id": id, "name": name, "tracks": tracks.map { $0.toJSON() }]
    }

    /// Add songs, skipping true duplicates (same identityKey) and
    /// stopping at 1000 tracks (Flutter addTracks / maxTracksPerList).
    /// Returns (added, dropped, dupes).
    mutating func addTracks(_ incoming: [MusicSong]) -> (added: Int, dropped: Int, dupes: Int) {
        var seen = Set(tracks.map { $0.identityKey })
        var added = 0
        var dropped = 0
        var dupes = 0
        for song in incoming {
            if !seen.insert(song.identityKey).inserted {
                dupes += 1
                continue
            }
            if tracks.count >= 1000 {
                dropped += 1
                continue
            }
            tracks.append(song)
            added += 1
        }
        return (added, dropped, dupes)
    }
}

/// One downloaded song (Flutter `DownloadedSong`).
struct DownloadedSong: Equatable {
    var song: MusicSong
    /// Stored file reference (relative name `music_downloads/<file>`
    /// or a legacy absolute path — resolved via LocalFileIndex).
    var filePath: String
    var sizeBytes: Int
    var downloadedAt: Int
    /// Quality code the file was downloaded at ('master' / 'hires' /
    /// 'lossless' / '320k' / '128k'). Pre-tier entries have no field:
    /// hires is the safe default — never over-claim Master.
    var qualityCode: String

    var key: String { song.identityKey }
    var fileName: String { URL(fileURLWithPath: filePath).lastPathComponent }

    /// The downloaded tier as a coordinator AudioQuality.
    var quality: AudioQuality {
        switch qualityCode {
        case "master": return .master
        case "lossless": return .flac
        case "320k": return .high320
        case "128k": return .standard128
        case "hires": fallthrough
        default: return .hiRes
        }
    }

    init(song: MusicSong, filePath: String, sizeBytes: Int, downloadedAt: Int, qualityCode: String) {
        self.song = song
        self.filePath = filePath
        self.sizeBytes = sizeBytes
        self.downloadedAt = downloadedAt
        self.qualityCode = qualityCode
    }

    init(json: [String: Any]) {
        let songJSON = json["song"] as? [String: Any] ?? [:]
        self.song = MusicSong(json: songJSON)
        self.filePath = MusicDict.string(json, "filePath")
        self.sizeBytes = MusicDict.int(json, "sizeBytes")
        self.downloadedAt = MusicDict.int(json, "downloadedAt")
        let code = MusicDict.string(json, "quality")
        self.qualityCode = code.isEmpty ? "hires" : code
    }

    func toJSON() -> [String: Any] {
        return [
            "song": song.toJSON(),
            "filePath": filePath,
            "sizeBytes": sizeBytes,
            "downloadedAt": downloadedAt,
            "quality": qualityCode,
        ]
    }
}

/// One listen event (Flutter `ListenEvent`, hao_listen).
/// `dur` is seconds actually heard; `totalDur` is the full song
/// length (0 = unknown); `at` is epoch milliseconds.
struct ListenEvent: Equatable {
    var songId: String
    var title: String
    var artist: String
    var platform: MusicPlatform
    var cover: String
    var dur: Int
    var totalDur: Int
    var at: Int

    init(json: [String: Any]) {
        self.songId = MusicDict.string(json, "songId")
        self.title = MusicDict.string(json, "title")
        self.artist = MusicDict.string(json, "artist")
        self.platform = MusicPlatform.fromCode(json["platform"] as? String)
        self.cover = MusicDict.string(json, "cover")
        self.dur = MusicDict.int(json, "dur")
        self.totalDur = MusicDict.int(json, "totalDur")
        self.at = MusicDict.int(json, "at")
    }

    func toJSON() -> [String: Any] {
        return [
            "songId": songId,
            "title": title,
            "artist": artist,
            "platform": platform.rawValue,
            "cover": cover,
            "dur": dur,
            "totalDur": totalDur,
            "at": at,
        ]
    }
}

/// One cached lyric line (Flutter `LyricLine` JSON: t / text /
/// translation). Kept separate from the LX leg's contract `LyricsLine`
/// (time / text) so the two shapes never collide; the player view
/// model converts stored lines to contract lines when showing them.
struct StoredLyricLine: Equatable {
    /// Time in seconds.
    var t: Double
    var text: String
    var translation: String?

    init(t: Double, text: String, translation: String? = nil) {
        self.t = t
        self.text = text
        self.translation = translation
    }

    init(json: [String: Any]) {
        self.t = MusicDict.double(json, "t")
        self.text = MusicDict.string(json, "text")
        let translation = MusicDict.string(json, "translation")
        self.translation = translation.isEmpty ? nil : translation
    }

    func toJSON() -> [String: Any] {
        var dict: [String: Any] = ["t": t, "text": text]
        if let translation = translation { dict["translation"] = translation }
        return dict
    }
}

/// Playback queue as stored in Documents/musicQueue.json
/// (`{songs, index}`, Flutter musicQueue).
struct MusicQueueData {
    var songs: [MusicSong]
    var index: Int

    init(songs: [MusicSong] = [], index: Int = 0) {
        self.songs = songs
        self.index = index
    }

    init(json: [String: Any]) {
        self.songs = MusicDict.array(json, "songs").map(MusicSong.init(json:))
        self.index = MusicDict.int(json, "index")
    }

    func toJSON() -> [String: Any] {
        return ["songs": songs.map { $0.toJSON() }, "index": index]
    }
}

/// `M月d日 星期X` date line for the music home (Flutter homeDateText).
func musicHomeDateText(_ now: Date) -> String {
    let calendar = Calendar.current
    let weekdays = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
    let weekday = calendar.component(.weekday, from: now)
    let month = calendar.component(.month, from: now)
    let day = calendar.component(.day, from: now)
    return "\(month)月\(day)日 \(weekdays[(weekday - 1) % 7])"
}

/// Day key `YYYY-MM-DD` (Flutter dayKeyOf).
func musicDayKey(of date: Date) -> String {
    let calendar = Calendar.current
    let year = calendar.component(.year, from: date)
    let month = calendar.component(.month, from: date)
    let day = calendar.component(.day, from: date)
    return String(format: "%04d-%02d-%02d", year, month, day)
}

/// FNV-1a + mulberry32, ported exactly from Flutter `SeededRandom`
/// (app.js dailySeeded). The same day string always yields the same
/// sequence — never use an unseeded random for daily picks.
struct MusicSeededRandom {
    private var state: UInt32

    init(seed: String) {
        var hash: UInt32 = 2166136261
        for unit in seed.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 16777619
        }
        state = hash
    }

    mutating func nextDouble() -> Double {
        state = state &+ 0x6D2B79F5
        var x = state
        x = (x ^ (x >> 15)) &* (x | 1)
        x ^= x &+ ((x ^ (x >> 7)) &* (x | 61))
        return Double((x ^ (x >> 14))) / 4294967296
    }

    /// Fisher–Yates with the seeded generator (Flutter dailyShuffle).
    mutating func shuffle<T>(_ input: [T]) -> [T] {
        var array = input
        guard array.count > 1 else { return array }
        for i in stride(from: array.count - 1, through: 1, by: -1) {
            let j = Int(nextDouble() * Double(i + 1))
            array.swapAt(i, j)
        }
        return array
    }
}

/// "m:ss" duration text. Durations are seconds, never milliseconds.
func musicDurationText(seconds: Int) -> String {
    let total = max(0, seconds)
    return "\(total / 60):\(String(format: "%02d", total % 60))"
}

// MARK: - Local-file quality (S7-A)
//
// The S2 honest limitation: a local file's player badge was nil —
// the resolver is bypassed for local files, so no tier was ever
// reported. The tier is now derived from the file itself.
//
// Master honesty gate, same as streaming: NOTHING here may return
// .master. A local file carries no Master provenance (no MQA /
// server-confirmed tier), so even a 192 kHz / 24-bit FLAC tops out
// at Hi-Res. Under-claiming is the rule: a file that proves no
// tier gets the honest "本地" label, never a guessed tier.
//
// Derivation (conservative, from measured properties only):
// - lossless container (FLAC / ALAC / PCM) + sample rate >= 96 kHz
//   or >= 24 bits per channel -> Hi-Res; other lossless -> FLAC.
// - lossy file with average bitrate >= 320 kbps -> 320k.
// - anything else (lossy below 320 kbps, unknown format, unreadable
//   file) -> nil, shown as "本地".

/// Measured properties of one local audio file. All optional: a
/// probe that cannot measure a property leaves it nil instead of
/// inventing a value.
struct LocalAudioProbe {
    var isLossless: Bool
    var sampleRate: Double?
    var bitsPerChannel: Int?
    var bitrateKbps: Double?
}

/// Pure tier mapping (unit-tested). Never returns .master — see the
/// honesty gate above.
func localFileQualityTier(isLossless: Bool, sampleRate: Double?, bitsPerChannel: Int?, bitrateKbps: Double?) -> AudioQuality? {
    if isLossless {
        if (sampleRate ?? 0) >= 96_000 || (bitsPerChannel ?? 0) >= 24 { return .hiRes }
        return .flac
    }
    if (bitrateKbps ?? 0) >= 320 { return .high320 }
    return nil
}

/// Badge label for a local file: the derived tier's label, or "本地"
/// when the file proves no tier. Never returns an empty string.
func localFileQualityLabel(for url: URL) -> String {
    guard let probe = probeLocalAudioFile(url),
          let tier = localFileQualityTier(
              isLossless: probe.isLossless,
              sampleRate: probe.sampleRate,
              bitsPerChannel: probe.bitsPerChannel,
              bitrateKbps: probe.bitrateKbps)
    else { return "本地" }
    return MusicLibraryStore.badgeLabel(for: tier)
}

/// Read a local audio file's properties with AVAudioFile. Fail-soft:
/// nil on any failure (missing / corrupt / unsupported file) — the
/// caller shows "本地", never a crash and never a guessed tier.
/// The bitrate is the file average (size / duration); it is only
/// used for the lossy >= 320 kbps step, never for lossless.
func probeLocalAudioFile(_ url: URL) -> LocalAudioProbe? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let format = file.fileFormat
    // Four-char format IDs (Core Audio OSTypes, written out so no
    // AudioToolbox import is needed): 'flac' / 'alac' / 'lpcm'.
    let formatID = format.streamDescription.pointee.mFormatID
    let isLossless = formatID == 0x666C_6163 || formatID == 0x616C_6163 || formatID == 0x6C70_636D
    let sampleRate = format.sampleRate > 0 ? format.sampleRate : nil
    let bits = format.streamDescription.pointee.mBitsPerChannel
    let bitsPerChannel = bits > 0 ? Int(bits) : nil
    var bitrateKbps: Double?
    if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
       file.length > 0,
       let rate = sampleRate, rate > 0 {
        let seconds = Double(file.length) / rate
        if seconds > 0 { bitrateKbps = Double(size) * 8 / seconds / 1000 }
    }
    return LocalAudioProbe(
        isLossless: isLossless,
        sampleRate: sampleRate,
        bitsPerChannel: bitsPerChannel,
        bitrateKbps: bitrateKbps
    )
}

// MusicLyricsAPI.swift
// Lyrics: fetch + LRC parse (+ translation matching).
//
// `fetchLyrics(for:completion:)` is the UI leg's entry point (name
// and signature are the contract — do not rename). It returns
// `Lyrics?` (nil = no lyrics for this song). Lyrics go BEHIND the
// cover (tap cover -> lyrics in the cover area; tap lyrics blank ->
// cover back; tap a lyric line -> seek) — the player leg owns that
// presentation; this module only fetches and parses.
//
// Sources (Flutter `MusicApi._fetchLyrics` parity):
// - wy: `/api/song/lyric` — `lrc.lyric` + `tlyric.lyric` (translation).
// - tx: `fcg_query_lyric_new.fcg` (nobase64=1).
// - kw: `m.kuwo.cn/newh5/singles/songinfoandlrc` (15 s) — the
//   `lrclist` (`time` seconds + `lineLyric`), sorted by time.
// - kg / mg: no lyrics endpoint — nil.
// - A song played again reuses its lyrics: an in-memory cache keyed
//   by `identityKey` (empty results are NOT cached). The cache is
//   in-memory only — no new persistent key is invented for it.
//
// LRC parse rules: `[mm:ss.xx]` lines only; metadata tags
// (`[ti:]`, `[ar:]`, `[al:]`, `[by:]`, `[offset:]`), `暂无歌词`
// and `纯音乐` lines are skipped; lines are sorted by time.
// Translation matching: translations are matched to main lines by
// timestamp (centisecond key, nearest within 0.5 s as fallback).

import Foundation

struct LyricsLine: Equatable {
    let time: TimeInterval
    let text: String
    let translation: String?

    init(time: TimeInterval, text: String, translation: String? = nil) {
        self.time = time
        self.text = text
        self.translation = translation
    }
}

struct Lyrics: Equatable {
    let lines: [LyricsLine]
}

final class MusicLyricsAPI {
    static let shared = MusicLyricsAPI()

    private let client: MusicAPIClient
    /// In-memory lyrics cache, keyed by `MusicTrack.identityKey`.
    private var cache: [String: Lyrics] = [:]
    private let cacheQueue = DispatchQueue(label: "com.haostudio.lyrics")

    init(client: MusicAPIClient = .shared) {
        self.client = client
    }

    // MARK: - Fetch (contract method)

    func fetchLyrics(for track: MusicTrack, completion: @escaping (Lyrics?) -> Void) {
        let key = track.identityKey
        let cached: Lyrics? = cacheQueue.sync { cache[key] }
        if let cached = cached {
            completion(cached)
            return
        }
        fetchLyricsUncached(for: track) { [weak self] lyrics in
            guard let self = self else {
                completion(lyrics)
                return
            }
            if let lyrics = lyrics, !lyrics.lines.isEmpty {
                self.cacheQueue.async { self.cache[key] = lyrics }
            }
            completion(lyrics)
        }
    }

    /// Whether this platform has a lyrics endpoint at all
    /// (task book §3.3 retry gate). Mirrors the switch in
    /// `fetchLyricsUncached`: wy / tx / kw fetch, kg / mg
    /// return nil immediately. The view model shows the retry
    /// affordance only where a retry could return anything —
    /// a Kugou / Migu song with no lyrics is an honest empty
    /// state, not a failed load.
    static func hasLyricsEndpoint(_ platform: MusicPlatform) -> Bool {
        switch platform {
        case .wy, .tx, .kw: return true
        default: return false
        }
    }

    private func fetchLyricsUncached(for track: MusicTrack, completion: @escaping (Lyrics?) -> Void) {
        switch track.platform {
        case .wy:
            client.getJson(
                "https://music.163.com/api/song/lyric?os=pc&id=\(track.id)&lv=-1&kv=-1&tv=-1",
                headers: ["User-Agent": MusicUA.value]
            ) { json in
                guard let json = json else { completion(nil); return }
                let lrc = MusicAPIJSON.asMap(json["lrc"])
                let tlyric = MusicAPIJSON.asMap(json["tlyric"])
                let rawLrc = MusicAPIJSON.asString(lrc?["lyric"])
                let lines = MusicLyricsAPI.parseLrcWithTranslation(
                    rawLrc,
                    translation: MusicAPIJSON.asString(tlyric?["lyric"]))
                guard !lines.isEmpty else { completion(nil); return }
                let gated = MusicLyricsAPI.gateLyrics(
                    lines,
                    candidate: MusicLyricsAPI.lyricIdentityFromLrc(rawLrc),
                    song: track)
                completion(Lyrics(lines: gated))
            }
        case .tx:
            client.getJson(
                "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg",
                query: [
                    "songmid": track.id, "format": "json",
                    "nobase64": "1", "g_tk": "5381",
                ],
                headers: ["Referer": "https://y.qq.com/", "User-Agent": MusicUA.value]
            ) { json in
                guard let json = json else { completion(nil); return }
                let rawLyric = MusicAPIJSON.asString(json["lyric"])
                let lines = MusicLyricsAPI.parseLrc(rawLyric)
                guard !lines.isEmpty else { completion(nil); return }
                let gated = MusicLyricsAPI.gateLyrics(
                    lines,
                    candidate: MusicLyricsAPI.lyricIdentityFromLrc(rawLyric),
                    song: track)
                completion(Lyrics(lines: gated))
            }
        case .kw:
            client.getJson(
                "https://m.kuwo.cn/newh5/singles/songinfoandlrc",
                query: ["musicId": track.id],
                headers: ["User-Agent": MusicUA.value],
                timeout: 15
            ) { json in
                guard let json = json else { completion(nil); return }
                let data = MusicAPIJSON.asMap(json["data"]) ?? [:]
                var lines = MusicAPIJSON.asList(data["lrclist"]).compactMap { x -> LyricsLine? in
                    let text = MusicAPIJSON.asString(x["lineLyric"]).trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return nil }
                    return LyricsLine(time: MusicAPIJSON.asDouble(x["time"]), text: text)
                }
                // The LRC path sorts after parsing; this one never
                // did — an out-of-order server list misaligned
                // highlight and tap-to-seek. Sort by time the same way.
                lines.sort { $0.time < $1.time }
                completion(lines.isEmpty ? nil : Lyrics(lines: lines))
            }
        default:
            // kg / mg: no lyrics endpoint.
            completion(nil)
        }
    }

    // MARK: - Identity gate (b45-h, P8 #2, §9.1)
    //
    // The b45-a helpers (MusicLyrics.lyricsIdentityMatches)
    // shipped with no caller — the view model cannot run the gate
    // because Lyrics carries no candidate title/artist. The gate
    // runs HERE: NetEase / QQ LRC text usually declares its own
    // [ti:] / [ar:] tags, and those are the candidate identity.
    // Both tags must be present to gate (a lone title is too weak
    // to reject on); when either is missing the id-scoped fetch
    // stands as-is. A failed gate returns an EMPTY Lyrics, not
    // nil — the player then shows an honest "暂无歌词" instead of
    // the retry affordance, and the empty result is cached
    // nowhere (fetch + disk layers both skip empties), so a later
    // retry re-fetches. Pure-music LRCs never reach the gate: the
    // parser drops "纯音乐" lines first, so a pure-music lyric
    // parses to no lines; isInstrumental is therefore always
    // false here. Kuwo stays ungated: its lrclist JSON carries no
    // [ti:]/[ar:], and its song-name fields are not part of the
    // verified contract, so no gate is guessed from them.

    /// Declared `[ti:]` / `[ar:]` identity of an LRC text, if
    /// both are present. Only the first of each is read; the tags
    /// may sit anywhere in the text.
    static func lyricIdentityFromLrc(_ text: String) -> (title: String, artist: String)? {
        var title: String?
        var artist: String?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if title == nil, trimmed.hasPrefix("[ti:") {
                title = lyricIdentityTagValue(trimmed, key: "ti")
            }
            if artist == nil, trimmed.hasPrefix("[ar:") {
                artist = lyricIdentityTagValue(trimmed, key: "ar")
            }
            if title != nil && artist != nil { break }
        }
        guard let title = title, !title.isEmpty,
              let artist = artist, !artist.isEmpty else { return nil }
        return (title, artist)
    }

    /// Value of one `[key:value]` tag line (up to the closing `]`).
    private static func lyricIdentityTagValue(_ line: String, key: String) -> String? {
        let prefix = "[\(key):"
        guard line.hasPrefix(prefix), let close = line.firstIndex(of: "]") else { return nil }
        let value = String(line[line.index(line.startIndex, offsetBy: prefix.count)..<close])
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Gate parsed lines against the song: nil identity in the
    /// candidate means "cannot check, keep as-is"; a failed check
    /// means empty (no matching lyrics for this song).
    static func gateLyrics(_ lines: [LyricsLine], candidate: (title: String, artist: String)?, song: MusicTrack) -> [LyricsLine] {
        guard let candidate = candidate else { return lines }
        let matches = MusicLyrics.lyricsIdentityMatches(
            songTitle: song.title, songArtist: song.artist, songDurationSeconds: song.duration ?? 0,
            lyricTitle: candidate.title, lyricArtist: candidate.artist, lyricDurationSeconds: nil,
            isInstrumental: false)
        return matches ? lines : []
    }

    // MARK: - LRC parsing (pure, unit-tested)

    /// Parse LRC text into lines. `[mm:ss.xx]` only; metadata tags,
    /// `暂无歌词` and `纯音乐` lines are skipped; sorted by time.
    /// B6: a line may carry several time tags
    /// (`[00:10.00][00:20.00]text`) — one line is emitted per tag,
    /// not just the first. Only the time tags are stripped: the old
    /// blanket `\[.*?\]` removal also ate bracketed lyric text
    /// (e.g. a word in [brackets]). A leading bracketed segment is
    /// dropped only when it is a section label (chorus / verse /
    /// 副歌 …), never lyric content.
    static func parseLrc(_ text: String) -> [LyricsLine] {
        var out: [LyricsLine] = []
        guard let timePattern = try? NSRegularExpression(pattern: "\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]") else {
            return []
        }
        let fullRange = { (s: String) in NSRange(s.startIndex..., in: s) }
        for line in text.components(separatedBy: "\n") {
            let matches = timePattern.matches(in: line, range: fullRange(line))
            guard !matches.isEmpty else { continue }
            // Text = the line with only its time tags removed.
            var stripped = timePattern.stringByReplacingMatches(
                in: line, range: fullRange(line), withTemplate: "")
            // Strip leading section labels ("[Chorus]", "[副歌]"):
            // they are structure, not lyrics.
            stripped = stripLeadingSectionLabel(stripped)
            // Strip leading metadata tags ("[ti:...]", "[ar:...]"):
            // B6 stopped stripping every bracket group so bracketed
            // lyric text survives, but a line that is only metadata
            // must still be skipped, not shown as a lyric line.
            stripped = stripLeadingMetadataTags(stripped)
            let text = stripped.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let lower = text.lowercased()
            if lower.hasPrefix("ti:") || lower.hasPrefix("ar:") || lower.hasPrefix("al:")
                || lower.hasPrefix("by:") || lower.hasPrefix("offset:") {
                continue
            }
            if text.hasPrefix("暂无歌词") || text.hasPrefix("纯音乐") { continue }
            for match in matches {
                guard let minRange = Range(match.range(at: 1), in: line),
                      let secRange = Range(match.range(at: 2), in: line),
                      let minutes = Int(line[minRange]),
                      let seconds = Double(line[secRange])
                else { continue }
                out.append(LyricsLine(time: Double(minutes * 60) + seconds, text: text))
            }
        }
        out.sort { $0.time < $1.time }
        return out
    }

    /// Drop leading "[...]" segments whose content is a section
    /// label rather than lyric text. Anything else (including a
    /// bracketed lyric word) is kept.
    private static func stripLeadingSectionLabel(_ text: String) -> String {
        let labels: Set<String> = [
            "chorus", "verse", "bridge", "intro", "outro", "pre-chorus",
            "post-chorus", "hook", "interlude", "instrumental", "refrain",
            "副歌", "主歌", "前奏", "间奏", "尾奏", "桥段", "合唱", "独白", "对白",
        ]
        var rest = text
        while rest.hasPrefix("["),
              let close = rest.firstIndex(of: "]") {
            let content = String(rest[rest.index(after: rest.startIndex)..<close])
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard labels.contains(content) else { break }
            rest = String(rest[rest.index(after: close)...])
        }
        return rest
    }

    /// Drop leading "[key:value]" metadata tags (ti/ar/al/au/by/
    /// offset/re/ve/length). Only known LRC metadata keys are
    /// stripped, so bracketed lyric text ("[you]", "[笑]") and
    /// anything with an unknown key is kept.
    private static func stripLeadingMetadataTags(_ text: String) -> String {
        let keys: Set<String> = [
            "ti", "ar", "al", "au", "by", "offset", "re", "ve", "length",
        ]
        var rest = text
        while rest.hasPrefix("["),
              let close = rest.firstIndex(of: "]") {
            let content = String(rest[rest.index(after: rest.startIndex)..<close])
            guard let colon = content.firstIndex(of: ":") else { break }
            let key = String(content[..<colon])
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard keys.contains(key) else { break }
            rest = String(rest[rest.index(after: close)...])
        }
        return rest
    }

    /// Parse LRC with an optional translation track (NetEase
    /// `tlyric`): translations are matched to main lines by
    /// timestamp (centisecond key, nearest within 0.5 s as fallback).
    /// Lines without a match keep `translation == nil`.
    static func parseLrcWithTranslation(_ text: String, translation translationText: String?) -> [LyricsLine] {
        let main = parseLrc(text)
        guard let translationText = translationText, !translationText.isEmpty, !main.isEmpty else {
            return main
        }
        let trans = parseLrc(translationText)
        guard !trans.isEmpty else { return main }
        var byTime: [Int: String] = [:]
        for line in trans {
            byTime[Int((line.time * 100).rounded())] = line.text
        }
        func nearest(_ time: TimeInterval) -> String? {
            var best: String?
            var bestDiff = 0.5
            for line in trans {
                let diff = abs(line.time - time)
                if diff < bestDiff {
                    bestDiff = diff
                    best = line.text
                }
            }
            return best
        }
        return main.map { line in
            let translation = byTime[Int((line.time * 100).rounded())] ?? nearest(line.time)
            guard let translation = translation, !translation.isEmpty else { return line }
            return LyricsLine(time: line.time, text: line.text, translation: translation)
        }
    }
}

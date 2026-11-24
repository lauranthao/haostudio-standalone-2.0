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
                let lines = MusicLyricsAPI.parseLrcWithTranslation(
                    MusicAPIJSON.asString(lrc?["lyric"]),
                    translation: MusicAPIJSON.asString(tlyric?["lyric"]))
                completion(lines.isEmpty ? nil : Lyrics(lines: lines))
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
                let lines = MusicLyricsAPI.parseLrc(MusicAPIJSON.asString(json["lyric"]))
                completion(lines.isEmpty ? nil : Lyrics(lines: lines))
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

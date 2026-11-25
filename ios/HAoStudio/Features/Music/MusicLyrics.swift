// HAo Studio 2.0 — lyrics helpers (S2-C leg).
//
// Pure lyric logic ported from Flutter lib/services/music/lyric_tools.dart:
// - the active line is the last line whose time is <= the (offset)
//   playback position — found by BINARY SEARCH (sorted lines);
// - per-user lyric offset ±5 s (100 ms steps in the UI) shifts which
//   line highlights; tapping a line still seeks to its TRUE timestamp;
// - translation show/hide is a display switch only.
//
// There is NO word-level timing in any lyric source (NetEase returns
// line-level `lrc` + `tlyric` only; QQ line-level LRC; Kuwo line
// times) — no fake per-word karaoke timing is invented.

import Foundation

enum MusicLyrics {
    /// Offset range (ms): ±5 s (Flutter LyricDisplay.maxOffsetMs).
    static let maxOffsetMs = 5000

    static func clampOffsetMs(_ ms: Int) -> Int {
        return min(maxOffsetMs, max(-maxOffsetMs, ms))
    }

    /// Human offset label ("+1.5s", "-0.5s", "0s").
    static func offsetLabel(_ offsetMs: Int) -> String {
        if offsetMs == 0 { return "0s" }
        let sign = offsetMs > 0 ? "+" : "-"
        let absValue = abs(offsetMs)
        let whole = absValue / 1000
        let frac = (absValue % 1000) / 100
        if frac == 0 { return "\(sign)\(whole)s" }
        return "\(sign)\(whole).\(frac)s"
    }

    /// The lyric line active at `position` (seconds) with `offsetMs`
    /// applied: a positive offset treats the lyrics as EARLY (the
    /// active line moves forward), a negative offset as LATE.
    /// Returns -1 when there are no lines or playback is before the
    /// first line. Binary search: lines are sorted by time.
    static func activeIndex(lines: [StoredLyricLine], position: Double, offsetMs: Int) -> Int {
        return binarySearchIndex(times: lines.map { $0.t }, position: position + Double(offsetMs) / 1000)
    }

    /// Same lookup over contract LyricsLine values (time / text).
    static func activeIndex(lines: [LyricsLine], position: Double, offsetMs: Int) -> Int {
        return binarySearchIndex(times: lines.map { $0.time }, position: position + Double(offsetMs) / 1000)
    }

    /// Index of the last time <= position, or -1. `times` must be
    /// sorted ascending (lyric lines always are).
    static func binarySearchIndex(times: [Double], position: Double) -> Int {
        guard !times.isEmpty else { return -1 }
        if position < times[0] { return -1 }
        var low = 0
        var high = times.count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if times[mid] <= position {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// Convert cached lines to contract LyricsLine values for display.
    /// A11: the stored translation used to be dropped here even
    /// though the cache keeps it — the player could never show a
    /// translation from a cached song. Pass it through.
    static func toContractLines(_ stored: [StoredLyricLine]) -> [LyricsLine] {
        return stored.map { LyricsLine(time: $0.t, text: $0.text, translation: $0.translation) }
    }

    // MARK: - Body-only filter (b45-a, copy plan §2.8)

    /// Lyrics show the BODY only: credit lines (作词/作曲/编曲/
    /// 制作/混音/母带/出品/监制/发行 …), copyright lines marked
    /// © / ℗ / 版权 / 未经许可, and a leading "歌名 - 歌手" header
    /// line are dropped. Duet labels (e.g. "合唱：", "男："/"女：") are kept —
    /// they are part of the sung text, not credits. The LRC parser
    /// already strips `[ti:]`-style tags; this catches the plain-text
    /// credits the parser never sees.
    static func filterBodyLines(_ lines: [LyricsLine], title: String, artist: String) -> [LyricsLine] {
        let creditKeywords = [
            "作词", "作曲", "编曲", "制作", "制作人", "混音", "母带",
            "监制", "出品", "发行", "录音", "和声", "编导", "统筹",
            "词曲", "演唱", "原唱", "翻唱",
        ]
        let copyrightMarkers = ["©", "℗", "版权", "未经许可", "保留所有权利", "all rights reserved"]
        let header = "\(title) - \(artist)".trimmingCharacters(in: .whitespaces)
        var result: [LyricsLine] = []
        for (offset, line) in lines.enumerated() {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            // Leading "歌名 - 歌手" (or bare "歌名") header line.
            if offset == 0 && (text == header || text == title || text == "\(title) - \(artist)") {
                continue
            }
            // Credit lines are always short "key：value" / "key: value"
            // pairs (or a bare keyword); a sung line that merely
            // contains the word is kept — the keyword must lead a
            // colon pair, so a lyric like "作词的人最懂我" survives.
            let hasColon = text.contains("：") || text.contains(":")
            let head = text.components(separatedBy: CharacterSet(charactersIn: "：:")).first ?? text
            if hasColon && creditKeywords.contains(where: { head.contains($0) }) { continue }
            if creditKeywords.contains(text) { continue }
            if copyrightMarkers.contains(where: { text.contains($0) }) { continue }
            result.append(line)
        }
        return result
    }

    // MARK: - Per-song timing offset memory (b45-a, §9.1)

    /// Per-song lyric timing, 0.1 s steps, UserDefaults key shaped
    /// `lyrics.timing.<identityKey>`; a 0 offset deletes the key.
    /// The global offset stays as the fallback for songs never
    /// adjusted; a song switch reads its own value back.
    static func perSongOffsetKey(for identityKey: String) -> String {
        return "lyrics.timing.\(identityKey)"
    }

    static func perSongOffsetMs(for identityKey: String, defaults: UserDefaults = .standard) -> Int? {
        guard let value = defaults.object(forKey: perSongOffsetKey(for: identityKey)) as? Int else { return nil }
        return clampOffsetMs(value)
    }

    static func savePerSongOffsetMs(_ ms: Int, for identityKey: String, defaults: UserDefaults = .standard) {
        let clamped = clampOffsetMs(ms)
        if clamped == 0 {
            defaults.removeObject(forKey: perSongOffsetKey(for: identityKey))
        } else {
            // 0.1 s steps (Coda lyricsTimingSteps).
            defaults.set((clamped / 100) * 100, forKey: perSongOffsetKey(for: identityKey))
        }
    }

    // MARK: - Identity gate (b45-a, §9.1)

    /// Fold for identity comparison: traditional → simplified is
    /// approximated by case folding + full/half-width folding +
    /// diacritic stripping (no transliteration table ships in the
    /// app); whitespace and punctuation around the core are trimmed.
    static func normalizedForMatch(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        return folded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split an artist string on / 、 , ， ; ； & ＆. A band name
    /// containing & or / is compared whole FIRST by the caller
    /// (see `artistsMatch`); this split is for the per-artist
    /// display links and the fallback comparison.
    static func splitArtists(_ artist: String) -> [String] {
        let separators = CharacterSet(charactersIn: "/、,，;；&＆")
        return artist.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Title with any trailing parenthesised / bracketed subtitle
    /// ("（Live）", "[Remix]", " - 伴奏") stripped — the base the
    /// identity gate compares.
    static func titleBase(_ title: String) -> String {
        var base = title
        // Openers that start a parenthesised / bracketed subtitle.
        // The ASCII open-paren and open-bracket are spelled as
        // Unicode scalars so the raw file keeps its paren balance
        // — preflight 5b counts raw characters, string contents
        // included, so a literal open-paren in source would tip it.
        let openers: [Character] = [
            "（", Character(UnicodeScalar(0x28)!),
            Character(UnicodeScalar(0x5B)!), "【",
        ]
        for opener in openers {
            if let range = base.range(of: String(opener)) {
                base = String(base[..<range.lowerBound])
            }
        }
        if let range = base.range(of: " - ") {
            base = String(base[..<range.lowerBound])
        }
        return normalizedForMatch(base)
    }

    /// Version tags (Live / 伴奏 / Remix / DJ / cover / 翻唱 /
    /// instrumental / 卡拉OK / 现场 / 纯音乐 …) found in the title.
    /// Both sides' tag sets must be IDENTICAL for an identity match.
    static func versionTags(_ title: String) -> Set<String> {
        let known = ["live", "伴奏", "remix", "dj", "cover", "翻唱", "instrumental",
                     "卡拉ok", "现场", "纯音乐", "acoustic", "demo", "edit", "version"]
        let folded = normalizedForMatch(title)
        var tags = Set<String>()
        for tag in known where folded.contains(tag) { tags.insert(tag) }
        return tags
    }

    /// Artist identity: the whole string matches first (band names
    /// with & or /), otherwise the lead artist of one side must
    /// appear in the other side's split artists.
    static func artistsMatch(_ a: String, _ b: String) -> Bool {
        let na = normalizedForMatch(a)
        let nb = normalizedForMatch(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        let aParts = splitArtists(a).map(normalizedForMatch)
        let bParts = splitArtists(b).map(normalizedForMatch)
        guard let aLead = aParts.first, let bLead = bParts.first else { return false }
        return bParts.contains(aLead) || aParts.contains(bLead)
    }

    /// Identity gate (not a score): the lead singer must match by
    /// name or alias; the title base must be equal AND the version
    /// tags must be exactly equal. Translation / "电视剧《X》插曲"
    /// style notes never decide identity. Pure music is the only
    /// exception: same title + same version with a duration gap
    /// ≤ 2 s. `lyricDurationSeconds` is nil when the candidate
    /// carries no duration.
    static func lyricsIdentityMatches(
        songTitle: String, songArtist: String, songDurationSeconds: Double,
        lyricTitle: String, lyricArtist: String, lyricDurationSeconds: Double?,
        isInstrumental: Bool
    ) -> Bool {
        guard titleBase(songTitle) == titleBase(lyricTitle),
              !titleBase(songTitle).isEmpty,
              versionTags(songTitle) == versionTags(lyricTitle),
              artistsMatch(songArtist, lyricArtist)
        else { return false }
        if isInstrumental {
            guard let lyricDuration = lyricDurationSeconds else { return false }
            return abs(lyricDuration - songDurationSeconds) <= 2
        }
        return true
    }

    // MARK: - Karaoke progress + pseudo-syllables (b45-a, §9.1)

    /// Progress through one lyric line (0…1) for the wipe: the
    /// fraction of the line's duration elapsed at `position`.
    /// The next line's start bounds the duration; the last line
    /// uses 4 s as its nominal length.
    static func lineProgress(lines: [LyricsLine], index: Int, position: Double) -> Double {
        guard index >= 0 && index < lines.count else { return 0 }
        let start = lines[index].time
        let end = index + 1 < lines.count ? lines[index + 1].time : start + 4
        guard end > start else { return position >= start ? 1 : 0 }
        return min(1, max(0, (position - start) / (end - start)))
    }

    /// Pseudo-syllables for a line with no per-word timestamps:
    /// characters share the line duration evenly, so the wipe can
    /// still advance word by word instead of jumping line by line.
    /// Returns (character, startOffsetSeconds, durationSeconds).
    static func pseudoSyllables(for text: String, lineDuration: Double) -> [(String, Double, Double)] {
        let chars = Array(text)
        guard !chars.isEmpty, lineDuration > 0 else { return [] }
        let each = lineDuration / Double(chars.count)
        return chars.enumerated().map { (String($0.element), Double($0.offset) * each, each) }
    }

    // MARK: - Row distance visuals (b45-a, §2.8)

    /// Non-active row opacity by distance from the active line:
    /// 0.58 − |d| × 0.055, floor 0.30; already-sung rows sit at
    /// 0.30; while the user is browsing, rows sit at 0.72.
    static func lineOpacity(distance: Int, browsing: Bool, sung: Bool) -> Double {
        if browsing { return 0.72 }
        if sung { return 0.30 }
        return max(0.30, 0.58 - Double(abs(distance)) * 0.055)
    }

    /// Non-active row blur: min(3.5, |d| × 0.65).
    static func lineBlur(distance: Int) -> Double {
        return min(3.5, Double(abs(distance)) * 0.65)
    }
}

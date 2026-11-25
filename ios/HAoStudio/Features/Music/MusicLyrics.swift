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
// b47-player refs check (verified 2026-11-25, live): real word
// timing DOES exist — NetEase `klyric`/`yrc` (Lyricify YrcParser),
// Kugou KRC, QQ QRC — but none of it reaches us: the plain
// `/api/song/lyric` endpoint our app uses returns `klyric` EMPTY
// for every song tested (21 songs incl. 晴天) and no `yrc` field
// at all; the word-timed fields only come from the encrypted
// weapi/eapi endpoints, and KRC/QRC need vendor decryption keys.
// We copy no keys (iron rule), so the even pseudo-syllable split
// stays — it is an approximation, disclosed as one, not a fake
// timing claim.

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
        return stored.map { LyricsLine(time: $0.t, text: $0.text, translation: $0.translation, romaji: $0.romaji) }
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

    // MARK: - Identity gate (moved, b45-fix)

    // The identity-gate helpers (normalizedForMatch / titleBase /
    // versionTags / artistsMatch / lyricsIdentityMatches) moved to
    // MusicLyricsAPI.swift: `swift test` builds AppCore from
    // Package.swift's sources list, which does not include this
    // file (it needs StoredLyricLine from MusicModels.swift, which
    // imports AVFoundation). Only splitArtists stays callable here
    // — MusicPlayerView uses it for per-artist display links — as
    // a one-line forwarder to the single implementation.
    static func splitArtists(_ artist: String) -> [String] {
        MusicLyricsAPI.splitArtists(artist)
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

    // MARK: - Karaoke wipe render values (b45-h, P8 #1, §9.1)
    //
    // Coda's KaraokeGlyphRenderer: the sung part is bright, the
    // unsung part sits at 0.28, the char being sung glows, and a
    // long note swells the char it sits on (up to +7.5% scale,
    // lifted). The b45-a first cut only did a line-level gradient
    // wipe; these values drive the per-character render in
    // LyricWipeText, where each char's own progress comes from
    // the even pseudo-syllable split above — no word timing
    // exists in any lyric source, so no fake per-word timing is
    // invented. The wipe edge is feathered by the smoothstep in
    // karaokeCharOpacity (a soft edge one char wide) instead of
    // a gradient stop, so no separate feather width is kept.
    // RTL lines are not mirrored (Coda supports RTL; our lyric
    // sources are CJK / Latin — noted, not faked).

    /// Unsung chars sit at 0.28 opacity.
    static let karaokeUnsungOpacity = 0.28
    /// Glow opacity of the char being sung.
    static let karaokeGlowOpacity = 0.65

    /// Glow blur of the char being sung: fontSize x 0.24.
    static func karaokeGlowRadius(fontSize: Double) -> Double {
        return fontSize * 0.24
    }

    /// Progress of one char inside its line (0...1): chars share
    /// the line duration evenly. A zero-length line counts as
    /// fully sung once playback has reached it.
    static func karaokeCharProgress(lineDuration: Double, charIndex: Int, charCount: Int, positionInLine: Double) -> Double {
        guard charCount > 0 else { return 0 }
        guard lineDuration > 0 else { return positionInLine >= 0 ? 1 : 0 }
        let each = lineDuration / Double(charCount)
        let start = Double(charIndex) * each
        return min(1, max(0, (positionInLine - start) / each))
    }

    /// Char opacity: unsung 0.28, sung 1.0, with a smoothstep
    /// feather across the char being sung.
    static func karaokeCharOpacity(charProgress: Double) -> Double {
        let t = min(1, max(0, charProgress))
        let smooth = t * t * (3 - 2 * t)
        return karaokeUnsungOpacity + (1 - karaokeUnsungOpacity) * smooth
    }

    /// Long-note swell: the char being sung grows to +14% at
    /// its midpoint and settles back. Chars progress one after
    /// another, so the swell is naturally staggered down the
    /// line and the last char only peaks after the first has
    /// passed its peak. b47-player refs check: MeloX
    /// (AppleMusicLyricsMotionProfile.emphasisScaleRange) and
    /// BetterLyrics (LyricsAnimator auto char scale) both put
    /// the peak at 1.14–1.15 — the old +7.5% was our own
    /// under-reading, not Coda's value (Coda's long-tone
    /// emphasis is a positional spread, not a scale). The lift
    /// below stays: 0.065 × fontSize peaks at 1.8pt on our 28pt
    /// lines, i.e. MeloX's 2pt syllableLift.
    static func karaokeSwellScale(charProgress: Double) -> Double {
        let t = min(1, max(0, charProgress))
        return 1 + 0.14 * sin(Double.pi * t)
    }

    /// Long-note lift: the sung char floats up to fontSize x 0.065.
    static func karaokeLift(fontSize: Double, charProgress: Double) -> Double {
        let t = min(1, max(0, charProgress))
        return -fontSize * 0.065 * sin(Double.pi * t)
    }

    // MARK: - Row distance visuals (b45-a, §2.8)

    /// Non-active row opacity by distance from the active line
    /// (b46-player, Coda lyrics): neighbours stay READABLE —
    /// 0.72 − |d| × 0.035, floor 0.45; already-sung rows sit at
    /// 0.45; while the user is browsing, rows sit at 0.75. The
    /// old floor (0.30) + steep falloff left every line below the
    /// current one nearly invisible on chen's phone.
    static func lineOpacity(distance: Int, browsing: Bool, sung: Bool) -> Double {
        if browsing { return 0.75 }
        if sung { return 0.45 }
        return max(0.45, 0.72 - Double(abs(distance)) * 0.035)
    }

    /// Non-active row blur (b46-player, b47-player refs check):
    /// min(2.0, |d| × 0.3). MeloX (AppleMusicLyricsMotionProfile)
    /// uses 3pt non-focused / 4pt max and BetterLyrics
    /// (LyricsAnimator) up to 5 × distanceFactor — but those rows
    /// are 36pt, ours are 20pt, so the values are scaled by
    /// font size (3 × 20/36 ≈ 1.7, 4 × 20/36 ≈ 2.2): the cap
    /// lands at 2.0. The b46 cap of 1.0 was too faint to read as
    /// a depth cue at all; the old 3.5 cap (unscaled) blurred
    /// 20pt lines into illegibility.
    static func lineBlur(distance: Int) -> Double {
        return min(2.0, Double(abs(distance)) * 0.3)
    }
}

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
}

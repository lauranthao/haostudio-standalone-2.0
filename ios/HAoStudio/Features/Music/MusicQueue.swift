// HAo Studio 2.0 — music queue math (S2-C leg).
//
// Pure queue logic ported from Flutter lib/services/music/play_mode.dart
// (nextTrackIndex / prevTrackIndex / cycle order / stored codes).
// No player, no UI, no randomness source of its own: shuffle takes an
// injected random-index closure so tests are deterministic.
//
// The contract `MusicPlayMode` (player leg) is NOT redefined here.
// This file's `MusicQueueMode` is the C leg's internal enum; the player
// view model maps the contract mode to it (see MusicPlayerViewModel).

import Foundation

/// The five playback modes. Stored codes (UserDefaults `playMode`):
/// 'seq' | 'loop' | 'one' | 'shuffle' | 'once'. Unknown codes read
/// back as sequential, never crash (Flutter PlayModeX.fromCode).
enum MusicQueueMode: Equatable {
    case sequential
    case listLoop
    case singleLoop
    case shuffle
    case single

    /// Cycle order for the mode button: sequential -> list loop ->
    /// single loop -> shuffle -> single play -> sequential.
    static let cycleOrder: [MusicQueueMode] = [
        .sequential, .listLoop, .singleLoop, .shuffle, .single,
    ]

    var code: String {
        switch self {
        case .sequential: return "seq"
        case .listLoop: return "loop"
        case .singleLoop: return "one"
        case .shuffle: return "shuffle"
        case .single: return "once"
        }
    }

    var label: String {
        switch self {
        case .sequential: return "顺序播放"
        case .listLoop: return "列表循环"
        case .singleLoop: return "单曲循环"
        case .shuffle: return "随机播放"
        case .single: return "单曲播放"
        }
    }

    /// SF Symbol for the mode button.
    var icon: String {
        switch self {
        case .sequential: return "arrow.right"
        case .listLoop: return "repeat"
        case .singleLoop: return "repeat.1"
        case .shuffle: return "shuffle"
        case .single: return "arrow.right.to.line"
        }
    }

    var next: MusicQueueMode {
        guard let index = MusicQueueMode.cycleOrder.firstIndex(of: self) else {
            return .sequential
        }
        return MusicQueueMode.cycleOrder[(index + 1) % MusicQueueMode.cycleOrder.count]
    }

    static func fromCode(_ code: String?) -> MusicQueueMode {
        switch code {
        case "loop": return .listLoop
        case "one": return .singleLoop
        case "shuffle": return .shuffle
        case "once": return .single
        case "seq": fallthrough
        default: return .sequential
        }
    }

    /// Map a contract MusicPlayMode (player leg) to this enum.
    /// Assumed contract case names (see the C-leg report):
    /// sequential / listLoop / singleLoop / shuffle / single.
    static func fromContract(_ mode: MusicPlayMode) -> MusicQueueMode {
        switch mode {
        case .sequential: return .sequential
        case .listLoop: return .listLoop
        case .singleLoop: return .singleLoop
        case .shuffle: return .shuffle
        case .single: return .single
        }
    }

    /// Map this enum back to a contract MusicPlayMode.
    func toContract() -> MusicPlayMode {
        switch self {
        case .sequential: return .sequential
        case .listLoop: return .listLoop
        case .singleLoop: return .singleLoop
        case .shuffle: return .shuffle
        case .single: return .single
        }
    }
}

/// Pure queue math — unit-tested, no player involved.
///
/// Returns the index of the next track, or -1 when playback must STOP
/// (end of queue reached in a non-looping mode).
///
/// `auto` is true for automatic advance on track completion, false for
/// an explicit user tap on next. They differ in two modes:
/// - single loop: auto replays the same track; a manual tap advances.
/// - single play: auto stops after the current song; a manual tap still
///   advances to the next track (the user asked for it).
func musicNextTrackIndex(
    mode: MusicQueueMode,
    current: Int,
    length: Int,
    auto: Bool,
    randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
) -> Int {
    if length <= 0 || current < 0 || current >= length { return -1 }
    switch mode {
    case .sequential:
        return current + 1 < length ? current + 1 : -1
    case .listLoop:
        return (current + 1) % length
    case .singleLoop:
        if auto { return current }
        return (current + 1) % length
    case .shuffle:
        if length == 1 { return current }
        // B1: bounded retries — a degenerate random source that
        // always returns the current index used to spin forever.
        // Fall back to the next index after `length` tries.
        var next = current
        for _ in 0..<length {
            next = randomIndex(length)
            if next != current { return next }
        }
        return (current + 1) % length
    case .single:
        if auto { return -1 }
        return current + 1 < length ? current + 1 : -1
    }
}

/// Previous-track index. Manual only (there is no auto-previous).
/// Shuffle picks a random other track. Loop modes wrap at the start;
/// sequential and single-play stop at the first track.
func musicPrevTrackIndex(
    mode: MusicQueueMode,
    current: Int,
    length: Int,
    randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
) -> Int {
    if length <= 0 || current < 0 || current >= length { return -1 }
    if mode == .shuffle {
        if length == 1 { return current }
        // B1: bounded retries — same degenerate-source guard.
        var prev = current
        for _ in 0..<length {
            prev = randomIndex(length)
            if prev != current { return prev }
        }
        return (current - 1 + length) % length
    }
    switch mode {
    case .sequential, .single:
        return current == 0 ? -1 : current - 1
    case .listLoop, .singleLoop:
        return (current - 1 + length) % length
    case .shuffle:
        // Unreachable: shuffle returns above. Exhaustiveness only.
        return current
    }
}

/// The playback queue: an ordered list plus the current index.
/// The player owns actual advancing; this struct is what the queue
/// view shows and what the view model uses to predict the next track
/// (sleep-timer queue-end, "next up" display) with the same math.
struct MusicQueue {
    var tracks: [MusicSong]
    var index: Int

    var current: MusicSong? {
        guard index >= 0 && index < tracks.count else { return nil }
        return tracks[index]
    }

    var isEmpty: Bool { tracks.isEmpty }

    /// True when tapping `song` must NOT restart playback: it is the
    /// track already loaded. A paused same-track tap resumes instead.
    func isCurrentTrack(_ song: MusicSong) -> Bool {
        guard let current = current else { return false }
        return current.identityKey == song.identityKey
    }

    func nextIndex(mode: MusicQueueMode, auto: Bool) -> Int {
        return musicNextTrackIndex(mode: mode, current: index, length: tracks.count, auto: auto)
    }

    func prevIndex(mode: MusicQueueMode) -> Int {
        return musicPrevTrackIndex(mode: mode, current: index, length: tracks.count)
    }

    /// Whether natural playback ends after the current track in this
    /// mode (used by the sleep timer's "到歌单结束" check).
    func endsAfterCurrent(mode: MusicQueueMode) -> Bool {
        return nextIndex(mode: mode, auto: true) == -1
    }

    mutating func remove(at removalIndex: Int) {
        guard removalIndex >= 0 && removalIndex < tracks.count else { return }
        tracks.remove(at: removalIndex)
        if removalIndex < index {
            index -= 1
        } else if removalIndex == index && index >= tracks.count {
            index = max(0, tracks.count - 1)
        }
    }

    /// Insert `song` at `position`, moving it there when it is
    /// already queued so it never appears twice (play-next
    /// dedupe). The current track never moves: inserting the
    /// playing song is a no-op, and inserting at or before the
    /// current index shifts the index so the same song stays
    /// current. Inserting into an empty queue leaves the index
    /// at 0, on the new song.
    mutating func insert(_ song: MusicSong, at position: Int) {
        let wasEmpty = tracks.isEmpty
        var target = position
        if let existing = tracks.firstIndex(where: { $0.identityKey == song.identityKey }) {
            if existing == index { return }
            tracks.remove(at: existing)
            if existing < index { index -= 1 }
            if existing < target { target -= 1 }
        }
        target = min(max(0, target), tracks.count)
        tracks.insert(song, at: target)
        if !wasEmpty && target <= index { index += 1 }
    }

    mutating func clear() {
        tracks.removeAll()
        index = 0
    }

    func toPlaybackItems() -> [PlaybackItem] {
        return tracks.map { $0.toPlaybackItem() }
    }

    func toQueueData() -> MusicQueueData {
        return MusicQueueData(songs: tracks, index: index)
    }

    static func fromQueueData(_ data: MusicQueueData) -> MusicQueue {
        let clamped = min(max(0, data.index), max(0, data.songs.count - 1))
        return MusicQueue(tracks: data.songs, index: data.songs.isEmpty ? 0 : clamped)
    }
}

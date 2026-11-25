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

/// What a MANUAL next / previous tap must do (b41, chen 2026-11-25:
/// the lock-screen / Dynamic Island / Control Center buttons did
/// nothing). `.play(index)` when a next / previous song exists;
/// `.restartCurrent` when the queue holds a song but there is no
/// next / previous one — a 1-song queue in any mode, or the ends in
/// sequential / single mode; `.nothing` only when the queue is
/// empty. A computed index that IS the current song (a 1-song
/// queue in a looping / shuffle mode) normalises to
/// `.restartCurrent` too: reopening the same song would re-resolve
/// its URL over the network, while a restart seeks to 0 instantly.
/// Auto-advance is NOT this function: it still stops at the
/// ends (musicNextTrackIndex auto: true returns -1). A manual tap
/// always answers: with no next / previous song it restarts the
/// current song from the beginning (the iOS-standard prev-at-start
/// behaviour, extended to next-at-end and 1-song queues).
enum MusicManualStep: Equatable {
    case play(Int)
    case restartCurrent
    case nothing
}

/// Manual-next resolution: the next index to play, or restart the
/// current song when there is none, or nothing when the queue is
/// empty. `current` outside the queue is nothing (no song to
/// restart); `randomIndex` is the shuffle source (injectable so
/// tests are deterministic).
func manualNextStep(
    mode: MusicQueueMode,
    current: Int,
    length: Int,
    randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
) -> MusicManualStep {
    guard length > 0, current >= 0, current < length else { return .nothing }
    let next = musicNextTrackIndex(mode: mode, current: current, length: length, auto: false, randomIndex: randomIndex)
    if next < 0 || next == current { return .restartCurrent }
    return .play(next)
}

/// Manual-previous resolution: same contract as manualNextStep.
func manualPrevStep(
    mode: MusicQueueMode,
    current: Int,
    length: Int,
    randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
) -> MusicManualStep {
    guard length > 0, current >= 0, current < length else { return .nothing }
    let prev = musicPrevTrackIndex(mode: mode, current: current, length: length, randomIndex: randomIndex)
    if prev < 0 || prev == current { return .restartCurrent }
    return .play(prev)
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

    /// Manual next / previous resolution for this queue (b41):
    /// what a tap must do — play a neighbour, restart the current
    /// song, or nothing when the queue is empty.
    func nextStep(mode: MusicQueueMode) -> MusicManualStep {
        return manualNextStep(mode: mode, current: index, length: tracks.count)
    }

    func prevStep(mode: MusicQueueMode) -> MusicManualStep {
        return manualPrevStep(mode: mode, current: index, length: tracks.count)
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

// MARK: - b45-F: queue plan (plan §9.2, Coda PlaybackQueuePlan)
//
// Next order = 插队 → 队列 → (looping) queue head. FM is
// separate (its own queue). Previous ALWAYS changes track
// (never a "restart because you just started" rule): at the
// head in a looping mode it wraps to the tail; at the head in a
// non-looping mode there is no previous (the player keeps its
// b41 restart-there behaviour for that case). Drag-reordering
// the upcoming list merges the priority items into the ordinary
// queue.

struct PlaybackQueuePlan {
    /// Play-next items, in order (highest priority).
    var priority: [MusicSong]
    /// The ordinary queue (current track included).
    var queue: [MusicSong]
    /// Index of the current track in `queue`.
    var currentIndex: Int
    /// True when the queue loops (list loop / single loop /
    /// shuffle wrap).
    var isLooping: Bool
    /// True when this is an FM queue (no priority, no loop).
    var isFM: Bool = false

    /// The upcoming tracks in play order: priority first, then
    /// the rest of the queue, then (when looping) the head.
    var upcoming: [MusicSong] {
        guard !queue.isEmpty, currentIndex >= 0, currentIndex < queue.count else {
            return priority + queue
        }
        var rest: [MusicSong] = priority
        if currentIndex + 1 < queue.count {
            rest.append(contentsOf: queue[(currentIndex + 1)...])
        }
        if isLooping, !isFM {
            rest.append(contentsOf: queue[0...currentIndex])
        }
        return rest
    }

    /// Index of the next track to play (into a combined
    /// priority+queue view), or nil when playback must stop.
    /// Returns `.priority(Int)` / `.queue(Int)` so the caller
    /// knows which list to advance.
    enum NextTarget: Equatable {
        case priority(Int)
        case queue(Int)
    }

    func nextTarget() -> NextTarget? {
        if !priority.isEmpty { return .priority(0) }
        guard !queue.isEmpty, currentIndex >= 0, currentIndex < queue.count else { return nil }
        if currentIndex + 1 < queue.count { return .queue(currentIndex + 1) }
        if isLooping, !isFM { return .queue(0) }
        return nil
    }

    /// Previous-track index into `queue`, or nil when there is
    /// none (head of a non-looping queue). Never returns the
    /// current index: previous always changes track.
    func previousIndex() -> Int? {
        guard !queue.isEmpty, currentIndex >= 0, currentIndex < queue.count else { return nil }
        if currentIndex > 0 { return currentIndex - 1 }
        if isLooping, !isFM { return queue.count - 1 }
        return nil
    }

    /// Drag-reordering the upcoming list merges the priority
    /// items into the ordinary queue: the new order is
    /// current-track-first + the reordered upcoming songs.
    /// Returns the rebuilt (priority, queue, currentIndex).
    func reorderingUpcoming(_ newOrder: [MusicSong]) -> PlaybackQueuePlan {
        guard !queue.isEmpty, currentIndex >= 0, currentIndex < queue.count else {
            return PlaybackQueuePlan(priority: [], queue: newOrder, currentIndex: 0, isLooping: isLooping, isFM: isFM)
        }
        var rebuilt = Array(queue[0...currentIndex])
        var seen = Set(rebuilt.map { $0.identityKey })
        for song in newOrder where seen.insert(song.identityKey).inserted {
            rebuilt.append(song)
        }
        return PlaybackQueuePlan(priority: [], queue: rebuilt, currentIndex: currentIndex, isLooping: isLooping, isFM: isFM)
    }
}

// MARK: - b45-F: offline queue selector (plan §9.2/§9.3)
//
// Offline, playback jumps to the first locally available track
// (download or audio cache) and counts how many were skipped.
// No local track at all → the caller shows the offline alert.

enum OfflineQueueSelector {
    /// Index-based core (shared by the MusicSong plan below and
    /// by the player, which holds PlaybackItems): walk the queue
    /// tail from `currentIndex + 1`, then — when looping — the
    /// head. Returns the first available index + skipped count.
    static func firstAvailableIndex(
        itemCount: Int,
        currentIndex: Int,
        isLooping: Bool,
        isFM: Bool,
        isAvailable: (Int) -> Bool
    ) -> (index: Int, skipped: Int)? {
        guard itemCount > 0, currentIndex >= 0, currentIndex < itemCount else { return nil }
        var skipped = 0
        for index in (currentIndex + 1)..<itemCount {
            if isAvailable(index) { return (index, skipped) }
            skipped += 1
        }
        if isLooping, !isFM {
            for index in 0...currentIndex {
                if isAvailable(index) { return (index, skipped) }
                skipped += 1
            }
        }
        return nil
    }

    /// First locally available upcoming track (searching the
    /// plan's upcoming order: priority → queue tail → loop head),
    /// plus the skipped count. Nil when nothing is available
    /// offline.
    static func firstAvailable(
        plan: PlaybackQueuePlan,
        isAvailable: (MusicSong) -> Bool
    ) -> (target: PlaybackQueuePlan.NextTarget, skipped: Int)? {
        var skipped = 0
        for (index, song) in plan.priority.enumerated() {
            if isAvailable(song) { return (.priority(index), skipped) }
            skipped += 1
        }
        guard let found = firstAvailableIndex(
            itemCount: plan.queue.count, currentIndex: plan.currentIndex,
            isLooping: plan.isLooping, isFM: plan.isFM,
            isAvailable: { isAvailable(plan.queue[$0]) })
        else { return nil }
        return (.queue(found.index), skipped + found.skipped)
    }
}

// MARK: - b45-F: play source / context (plan §9.2, Coda PlaySource)
//
// A playlist / album / artist / daily / recent / heartbeat / FM
// list is a reloadable "place". Identity is kind + id ONLY: a
// rename never changes the identity, so a renamed playlist
// still resumes the same context. The recent-contexts list can
// be replayed with one tap.

enum PlaySourceKind: String, Codable, CaseIterable {
    case playlist
    case album
    case artist
    case daily
    case recent
    case heartbeat
    case fm
    /// Our extension beyond Coda's seven (b45): our app has a
    /// favourites list and chart lists that are real reloadable
    /// places too. Adding cases is backward compatible — old
    /// snapshots simply never contain them.
    case favourites
    case chart
    /// b46: search results and transient home/discovery lists
    /// are reloadable places too — their snapshot (saved at play
    /// time) is the reload source. Local files are a stable
    /// place, read live from the store.
    case search
    case discover
    case local
    /// b46: explicit downloads, read live from the store.
    case downloads
}

struct PlaySource: Codable, Hashable {
    let kind: PlaySourceKind
    let id: String

    // Identity is kind + id only — the display name is not part
    // of equality (a rename must not change the identity).
    static func == (lhs: PlaySource, rhs: PlaySource) -> Bool {
        lhs.kind == rhs.kind && lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(id)
    }
}

struct PlayContext: Codable {
    let source: PlaySource
    /// Display name (renameable — not part of identity).
    var displayName: String
    /// Song identity keys, in play order.
    var songKeys: [String]
    /// When this context was last played (epoch seconds).
    var lastPlayedAt: TimeInterval

    /// Two contexts are the same place when their sources match
    /// — even after a rename.
    func isSamePlace(as other: PlayContext) -> Bool {
        source == other.source
    }
}

/// A most-recent-first list of play contexts, capped, with
/// one-tap replay (the newest context replays its song list).
enum RecentPlayContexts {
    static let maxContexts = 20

    static func replayed(_ contexts: [PlayContext], _ context: PlayContext) -> [PlayContext] {
        var rest = contexts.filter { $0.source != context.source }
        var updated = context
        updated.lastPlayedAt = Date().timeIntervalSince1970
        rest.insert(updated, at: 0)
        return Array(rest.prefix(maxContexts))
    }
}

// MARK: - b45-F: offline context resolution (plan §9.3)
//
// Offline-first: read local (playlist snapshot / downloads)
// first, then ask the network; a network failure falls back to
// local. Snapshots let a playlist be browsed offline.

/// One song inside a playlist snapshot. `MusicSong` itself is
/// not Codable (it round-trips through `toJSON()` / `init(json:)`),
/// so the snapshot stores this flat Codable record and rebuilds
/// `MusicSong` on load.
struct SnapshotSong: Codable, Equatable {
    let songId: String
    let title: String
    let artist: String
    let album: String
    let cover: String
    let platform: String
    let dur: Int

    init(_ song: MusicSong) {
        songId = song.songId
        title = song.title
        artist = song.artist
        album = song.album
        cover = song.cover
        platform = song.platform.rawValue
        dur = song.dur
    }

    func toMusicSong() -> MusicSong {
        MusicSong(songId: songId, title: title, artist: artist, album: album,
                  cover: cover, platform: MusicPlatform(code: platform) ?? .wy, dur: dur)
    }
}

struct PlaylistSnapshot: Codable, Equatable {
    let source: PlaySource
    let displayName: String
    let songs: [SnapshotSong]
    let savedAt: Date

    init(source: PlaySource, displayName: String, songs: [MusicSong], savedAt: Date = Date()) {
        self.source = source
        self.displayName = displayName
        self.songs = songs.map(SnapshotSong.init)
        self.savedAt = savedAt
    }

    /// The snapshot's songs as playable `MusicSong` values.
    var musicSongs: [MusicSong] { songs.map { $0.toMusicSong() } }
}

enum OfflineContextResolver {
    /// Resolve a playlist's songs: local snapshot first (returned
    /// immediately when present), then the network fetch; a
    /// network failure falls back to the snapshot, and with no
    /// snapshot at all the result is nil (offline empty state).
    static func resolve(
        snapshot: PlaylistSnapshot?,
        fetchRemote: (@escaping ([MusicSong]?) -> Void) -> Void,
        completion: @escaping ([MusicSong]?) -> Void
    ) {
        if let snapshot = snapshot, !snapshot.songs.isEmpty {
            completion(snapshot.musicSongs)
            return
        }
        fetchRemote { remote in
            completion(remote ?? snapshot?.musicSongs)
        }
    }
}

enum PlaylistSnapshotStore {
    static let subdir = "hao_playlist_snapshots"

    static func fileURL(source: PlaySource, documentsURL: URL? = nil) -> URL {
        let docs = documentsURL ?? LocalStore.documentsDirectory()
        let dir = docs.appendingPathComponent(subdir)
        let safeID = source.id.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(source.kind.rawValue)-\(safeID).json")
    }

    static func save(_ snapshot: PlaylistSnapshot, documentsURL: URL? = nil) {
        let url = fileURL(source: snapshot.source, documentsURL: documentsURL)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    static func load(source: PlaySource, documentsURL: URL? = nil) -> PlaylistSnapshot? {
        guard let data = try? Data(contentsOf: fileURL(source: source, documentsURL: documentsURL)) else { return nil }
        return try? JSONDecoder().decode(PlaylistSnapshot.self, from: data)
    }

    /// All snapshots, newest first (offline browsing).
    static func all(documentsURL: URL? = nil) -> [PlaylistSnapshot] {
        let docs = documentsURL ?? LocalStore.documentsDirectory()
        let dir = docs.appendingPathComponent(subdir)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var out: [PlaylistSnapshot] = []
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let snap = try? JSONDecoder().decode(PlaylistSnapshot.self, from: data)
            else { continue }
            out.append(snap)
        }
        return out.sorted { $0.savedAt > $1.savedAt }
    }
}

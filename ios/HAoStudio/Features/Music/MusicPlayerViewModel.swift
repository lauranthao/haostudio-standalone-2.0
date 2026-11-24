// HAo Studio 2.0 — music player view model (S2-C leg).
//
// Owns the music queue, the player-page state and the wiring between
// the UI and the contract engines:
//
// - playback: queue -> NativeMusicPlayer.setQueue + coordinator
//   .requestPlay (the player leg's resolver resolves the first
//   playable URL serially, fastest first). This leg NEVER calls
//   player.open directly and never resolves URLs itself.
// - same-track tap does NOT replay: playing + same track = no-op,
//   paused + same track = resume.
// - state mirror: isPlaying / position / duration / playMode /
//   playbackSpeed / actualQuality are read from the player's
//   @Published state (Combine), never invented locally.
// - seek failure rolls the progress bar back to the player's actual
//   position and shows a toast (P0-05: seek must never silently lie).
// - sleep timer: wall-clock modes pause via the timer; completion
//   modes (current-track-end / queue-end / after-N-tracks) are
//   detected from track-change + position-wrap signals (see below).
// - lyrics: cache first (hao_lyrics.json), then MusicLyricsAPI;
//   the active line follows the position with the user's offset.
//
// Completion detection (no completion hook exists in the contract):
// a natural completion is observed as (a) currentItem changing to a
// DIFFERENT track that this view model did not ask for, (b) the
// position wrapping backwards while the track stays the same
// (single-loop replay), or (c) playback stopping at the end of the
// track. Manual actions set `expectedItemId` first, so they are not
// mistaken for completions. A 2 s dedupe window keeps one completion
// from being counted twice. This is best-effort: if the player leg
// later adds a completion callback, these heuristics should be
// replaced by it (see the C-leg report).

import Combine
import SwiftUI
import UIKit

@MainActor
final class MusicPlayerViewModel: ObservableObject {
    // MARK: - Queue + current track

    @Published private(set) var queue = MusicQueue(tracks: [], index: 0)
    @Published private(set) var currentSong: MusicSong?

    /// The music song the mini player falls back to when the
    /// coordinator has no current item. The full player keeps
    /// showing the loaded song after its URL failed to resolve or
    /// playback was stopped (handleCurrentItemChanged ignores a nil
    /// currentItem, so currentSong survives); the mini must show
    /// the same song, or the two disagree about "what is playing".
    /// Only music songs qualify — a VOD episode / live room that
    /// flowed through currentSong must never surface in the mini
    /// as a song (wrong transport buttons, wrong full player).
    /// Nil exactly when the queue is truly empty (clearQueue /
    /// the last track removed) or another kind took over.
    @Published private(set) var miniFallbackSong: MusicSong?

    // MARK: - Playback state (mirrored from the player)

    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var playMode: MusicQueueMode = .sequential
    @Published private(set) var playbackSpeed: Double = 1.0
    /// Now Playing volume slider (0...1). Mirrors the player's
    /// userVolume; the view is the only writer (setVolume).
    @Published private(set) var volume: Double = 1.0
    /// The tier ACTUALLY playing, or nil before the first report.
    /// The badge shows this, never the target tier (Master honesty).
    @Published private(set) var actualQuality: AudioQuality?
    /// Local-file badge text (S7-A): the player reports no tier for
    /// local files (the resolver is bypassed), so the tier is derived
    /// from the file itself — "本地" when the file proves no tier.
    /// Nil for remote songs and when there is nothing honest to show.
    @Published private(set) var localQualityLabel: String?

    /// Badge text under the cover: the ACTUAL tier when the player
    /// reports one, else the local-file derivation. The view reads
    /// this (not actualQuality) so a local file never shows a blank.
    var qualityBadgeLabel: String? {
        if let actual = actualQuality { return MusicLibraryStore.badgeLabel(for: actual) }
        return localQualityLabel
    }

    // MARK: - Lyrics

    @Published private(set) var showLyrics = false
    @Published private(set) var lyrics: [LyricsLine] = []
    @Published private(set) var lyricsLoaded = false
    @Published private(set) var activeLyricIndex = -1
    @Published var lyricOffsetMs: Int {
        didSet {
            MusicLibraryStore.setLyricOffsetMs(lyricOffsetMs)
            updateActiveLyric()
        }
    }

    /// A11/E5: show the matched translation under each lyric line.
    /// Default on; toggled from the player "更多" sheet, same
    /// section as the lyric offset.
    @Published var showLyricTranslation: Bool {
        didSet {
            MusicLibraryStore.setLyricShowTranslation(showLyricTranslation)
        }
    }

    // MARK: - Sleep timer

    @Published private(set) var sleepActive = false
    @Published private(set) var sleepRemainingText = ""
    let sleepTimer: MusicSleepTimer

    // MARK: - Seek + toast

    /// Scrub position in seconds while the user drags the bar;
    /// nil when not dragging. While set, the bar fill and the
    /// elapsed label follow the finger instead of the player's
    /// position stream (which would fight the drag), and the seek
    /// itself fires once on drag end.
    @Published var scrubSeconds: Double?
    @Published private(set) var toast: String?

    // MARK: - Favourite

    @Published private(set) var isCurrentFav = false

    private let player = NativeMusicPlayer.shared
    private let coordinator: PlaybackCoordinator
    private var cancellables = Set<AnyCancellable>()
    private var toastTimer: Timer?
    private var expectedItemId: String?
    private var lastPosition: Double = 0
    private var wasPlaying = false
    private var lastCompletionKey = ""
    private var lastCompletionAt = Date.distantPast
    private var heardSeconds: Double = 0
    private var heardTrackKey = ""

    // MARK: - Auto-resume checkpoints (chen 2026-11-23:
    // save every 10 s while playing + on entering background,
    // local only — iOS has no reliable kill callback).
    /// Launch-time resume seek, applied once the player
    /// reports a duration. Nil when there is no checkpoint
    /// or after it has been applied / dropped.
    private var pendingResume: (key: String, seconds: Int)?
    /// Last checkpoint actually written to the resume file.
    private var lastResumeSaveAt: Date?
    private var lastResumeSavedKey: String?
    private var lastResumeSavedSeconds: Int = 0

    init(coordinator: PlaybackCoordinator) {
        self.coordinator = coordinator
        self.lyricOffsetMs = MusicLibraryStore.lyricOffsetMs()
        self.showLyricTranslation = MusicLibraryStore.lyricShowTranslation()
        self.playMode = MusicQueueMode.fromCode(MusicLibraryStore.playModeCode())
        self.playbackSpeed = MusicLibraryStore.speed()
        // Volume slider: restore the persisted position and push
        // it into the player (the player also reads the key at
        // init, so this is a no-op repeat on a fresh launch — but
        // the view model is recreated per app launch too, and the
        // slider must show the stored value, not 1.0).
        self.volume = MusicLibraryStore.musicVolume()
        player.setUserVolume(volume)
        // Handlers are attached AFTER the timer exists: capturing
        // self inside its own initializer is a compile error
        // (self.sleepTimer is not initialized yet at that point).
        self.sleepTimer = MusicSleepTimer(onFire: {})
        sleepTimer.onFire = { [weak self] in
            guard let self = self else { return }
            self.player.pause()
            self.sleepActive = false
            self.sleepRemainingText = ""
        }
        sleepTimer.onChanged = { [weak self] in
            guard let self = self else { return }
            self.sleepActive = self.sleepTimer.isActive
            self.sleepRemainingText = self.sleepTimer.remainingText
        }
        // Restore the persisted queue (the player restores playback
        // state itself; this only restores the queue list + index).
        // Lyrics are NOT fetched here: only the cache is read, so
        // launch does no network for a restored song.
        let saved = MusicLibraryStore.getQueue()
        if !saved.songs.isEmpty {
            queue = MusicQueue.fromQueueData(saved)
            currentSong = queue.current
            miniFallbackSong = queue.current
            if let song = currentSong {
                isCurrentFav = MusicLibraryStore.isFav(song)
                loadLyrics(for: song, fetchIfMissing: false)
            }
        }
        // Auto-resume (wiring leg B; Flutter
        // music_player_controller onInit): when the "启动时自动播放
        // 上次歌曲" switch is on, start the restored queue at its
        // restored index once per launch. Deferred to the next
        // runloop turn (Flutter's post-frame callback) so init
        // finishes before playback starts.
        //
        // Resume POSITION (autoresume leg): the stored checkpoint
        // for the restored song, if any. The player has no
        // start-position parameter, so the seek happens once the
        // player reports a duration (see the duration sink).
        // An invalid checkpoint starts from 0.
        if AutoResumeDecision.resumeIndex(
            autoResumeEnabled: UserDefaults.standard.bool(forKey: SettingsStore.autoResumeKey),
            queueCount: queue.tracks.count,
            currentIndex: queue.index) != nil,
           let song = currentSong {
            let stored = MusicLibraryStore.resumeSeconds(for: song.identityKey)
            if stored > 0 {
                pendingResume = (key: song.identityKey, seconds: stored)
            }
            DispatchQueue.main.async { [weak self] in
                self?.startPlayback()
            }
        }
        observePlayer()
        observeCoordinator()
        // Sleep wall-clock deadline, second net (S7-A): the 1 s
        // ticker can stall while the app is backgrounded (runloop
        // suspended). Position updates keep flowing while audio
        // plays (see observePlayer), and this fires when the app
        // returns to the foreground with playback paused — both
        // re-check the deadline, so a timer never sleeps past its
        // stop time. The view model lives for the app lifetime, so
        // the observer is never removed; the closure holds self
        // weakly and checkFire is a no-op without a deadline.
        _ = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleepTimer.checkFire()
        }
    }

    // MARK: - Observation

    private func observePlayer() {
        player.$isPlaying.sink { [weak self] value in
            guard let self = self else { return }
            let was = self.wasPlaying
            self.isPlaying = value
            self.wasPlaying = value
            // Playback stopped at the end of the track (not a user
            // pause mid-track): a natural completion.
            if was && !value && self.duration > 0 && self.position >= self.duration - 1.0 {
                if let song = self.currentSong { self.noteNaturalCompletion(completed: song) }
            } else if was && !value {
                // User paused (or playback stopped mid-track):
                // capture the position now — the app can be killed
                // without any further callback.
                self.saveResumeNow()
            }
        }.store(in: &cancellables)
        player.$position.sink { [weak self] value in
            guard let self = self else { return }
            // Sleep wall-clock deadline (S7-A): the 1 s ticker can
            // stall while the app is backgrounded, but position
            // updates keep flowing while audio plays — re-check the
            // deadline here so a timer never sleeps past its stop
            // time. checkFire is a no-op without a deadline.
            self.sleepTimer.checkFire()
            // Position wrapped backwards by > 5 s on the same track:
            // a natural completion (single-loop replay).
            if value < self.lastPosition - 5 {
                if let song = self.currentSong { self.noteNaturalCompletion(completed: song) }
            }
            self.lastPosition = value
            // Auto-resume checkpoint: while playing, save the
            // position every 10 s. The gate in MusicResumeLogic
            // skips writes that have not moved, so the resume
            // file is rewritten at most ~6 times a minute.
            // `value` is the fresh player position (self.position
            // freezes while scrubbing).
            self.saveResumeCheckpointIfDue(position: value)
            if self.scrubSeconds == nil {
                self.position = value
                if let song = self.currentSong {
                    if self.heardTrackKey != song.identityKey {
                        self.heardTrackKey = song.identityKey
                        self.heardSeconds = 0
                    }
                    self.heardSeconds = value
                }
            }
            self.updateActiveLyric()
        }.store(in: &cancellables)
        player.$duration.sink { [weak self] value in
            self?.duration = value
            self?.applyPendingResumeSeek()
        }.store(in: &cancellables)
        player.$playMode.sink { [weak self] mode in
            guard let self = self else { return }
            self.playMode = MusicQueueMode.fromContract(mode)
        }.store(in: &cancellables)
        player.$playbackSpeed.sink { [weak self] value in
            self?.playbackSpeed = value
        }.store(in: &cancellables)
        player.$actualQuality.sink { [weak self] value in
            guard let self = self else { return }
            self.actualQuality = value
            self.refreshLocalQualityBadge()
        }.store(in: &cancellables)
    }

    private func observeCoordinator() {
        coordinator.$currentItem.sink { [weak self] item in
            self?.handleCurrentItemChanged(item)
        }.store(in: &cancellables)
    }

    private func handleCurrentItemChanged(_ item: PlaybackItem?) {
        guard let item = item else { return }
        // F: a non-music item (VOD / live) must never become a music
        // song — the old code built a fake MusicSong for it and
        // fired a lyrics fetch that could never return anything.
        // The mini fallback clears alongside (it is music-only).
        // Note this also skips the natural-completion count: the
        // music track was interrupted by the user opening a video
        // or a room, not completed.
        guard item.kind == .music else {
            expectedItemId = nil
            miniFallbackSong = nil
            return
        }
        // Same track (e.g. a replay): nothing to re-sync.
        if let current = currentSong,
           current.songId == item.id || current.identityKey == item.id {
            expectedItemId = nil
            return
        }
        // A change to a track this view model did not ask for is a
        // natural completion of the previous track — unless that
        // track failed (A13): a failure-driven advance must never
        // count toward the sleep timer's "after N tracks".
        if expectedItemId != item.id, let previous = currentSong,
           !player.didTrackFail(id: previous.identityKey),
           !player.didTrackFail(id: previous.songId) {
            noteNaturalCompletion(completed: previous)
        }
        expectedItemId = nil
        if let index = queue.tracks.firstIndex(where: { $0.songId == item.id || $0.identityKey == item.id }) {
            queue.index = index
        }
        if let song = queue.current, song.songId == item.id || song.identityKey == item.id {
            setCurrentSong(song)
        } else {
            // The player is playing something outside this queue
            // (another leg started it): show it, do not rewrite the
            // queue. The cover travels with the item: without it the
            // player page would show no artwork for an outside song.
            let song = MusicSong(songId: item.id, title: item.title, artist: item.artist ?? "",
                                 cover: item.coverURL?.absoluteString ?? "")
            setCurrentSong(song)
        }
        // The mini player's fallback follows the same song — but
        // only for music. A VOD / live item must never become a
        // mini "song" (see miniFallbackSong).
        miniFallbackSong = item.kind == .music ? currentSong : nil
    }

    private func setCurrentSong(_ song: MusicSong) {
        currentSong = song
        isCurrentFav = MusicLibraryStore.isFav(song)
        loadLyrics(for: song)
        heardTrackKey = song.identityKey
        heardSeconds = 0
        refreshLocalQualityBadge()
    }

    /// Derive the player badge for a local file (S7-A). Remote songs
    /// report their tier through the player; local files never do
    /// (the resolver is bypassed), so the label comes from the file
    /// itself — probe off the main thread, publish on it, and drop
    /// the result if the track changed meanwhile. A reported tier
    /// always wins over the derivation.
    private func refreshLocalQualityBadge() {
        guard actualQuality == nil,
              let song = currentSong, !song.localPath.isEmpty
        else {
            localQualityLabel = nil
            return
        }
        let path = song.localPath
        let key = song.identityKey
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let label = localFileQualityLabel(for: URL(fileURLWithPath: path))
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard self.actualQuality == nil,
                      self.currentSong?.identityKey == key,
                      self.currentSong?.localPath == path
                else { return }
                self.localQualityLabel = label
            }
        }
    }

    // MARK: - Playback actions

    /// Play `song`. When `tracks` is given it becomes the queue and
    /// `song` plays from its position in it; otherwise the queue is
    /// just this song. A same-track tap does NOT replay: playing +
    /// same track = no-op, paused + same track = resume — but only
    /// when the engine actually holds that track. If the engine
    /// never loaded it (resolve failed / stopped), the tap falls
    /// through and re-requests the song instead of resuming
    /// nothing (A2: the old shortcut called player.play(), which
    /// no-ops with no currentTrack, leaving a dead tap).
    func play(song: MusicSong, in tracks: [MusicSong]? = nil, startAt: Int? = nil) {
        if queue.isCurrentTrack(song),
           let track = player.currentTrack,
           track.id == song.identityKey || track.id == song.songId {
            if !isPlaying { player.play() }
            return
        }
        if let tracks = tracks {
            let start = startAt ?? tracks.firstIndex(where: { $0.identityKey == song.identityKey }) ?? 0
            queue = MusicQueue(tracks: tracks, index: min(max(0, start), max(0, tracks.count - 1)))
        } else {
            queue = MusicQueue(tracks: [song], index: 0)
        }
        expectedItemId = song.identityKey
        startPlayback()
        hapticTick()
    }

    /// Play a whole list from the top (e.g. 播放全部).
    func playAll(_ tracks: [MusicSong]) {
        guard let first = tracks.first else { return }
        play(song: first, in: tracks, startAt: 0)
    }

    /// Play a downloaded / local song. The resolver (player leg)
    /// looks the file up by song id in the downloads / local index;
    /// this leg passes the same setQueue + requestPlay as remote.
    /// Play a downloaded / local file. `fileURL` is the resolved
    /// local file (downloads carry their path on the wrapper, not on
    /// the song); it is stored on the queued copy's localPath so the
    /// playback item carries a file URL and the resolver is bypassed.
    /// Local-library songs already carry localPath.
    func playLocal(song: MusicSong, fileURL: URL? = nil) {
        var song = song
        if let fileURL = fileURL { song.localPath = fileURL.path }
        // B8: the same song is currently playing from a remote
        // stream — the play() shortcut below would just resume
        // that stream. Stop it first so the local file loads.
        // (After the stop, play() falls through to startPlayback
        // because the engine holds no track — see its A2 note.)
        if !song.localPath.isEmpty, queue.isCurrentTrack(song),
           let current = player.currentTrack,
           (current.id == song.identityKey || current.id == song.songId),
           current.localFileURL == nil {
            player.stop()
            coordinator.stop()
        }
        play(song: song, in: [song], startAt: 0)
    }

    private func startPlayback() {
        guard let current = queue.current else { return }
        // A1: set the queue WITHOUT playing — requestPlay below is
        // the only play call, so one tap resolves exactly once.
        player.setQueueOnly(queue.toPlaybackItems(), startAt: queue.index)
        coordinator.requestPlay(current.toPlaybackItem())
        setCurrentSong(current)
        miniFallbackSong = current
        MusicLibraryStore.addRecent(current)
        MusicLibraryStore.saveQueue(queue.toQueueData())
    }

    // MARK: - Auto-resume checkpoints

    /// Periodic checkpoint, called from the position sink.
    /// Writes at most once per 10 s of playback, only when
    /// the position has moved since the last write.
    private func saveResumeCheckpointIfDue(position value: Double) {
        guard let song = currentSong else { return }
        guard MusicResumeLogic.shouldSaveCheckpoint(
            isPlaying: isPlaying,
            position: value,
            now: Date(),
            lastSavedAt: lastResumeSaveAt,
            lastSavedKey: lastResumeSavedKey,
            lastSavedSeconds: lastResumeSavedSeconds,
            currentKey: song.identityKey
        ) else { return }
        writeResumeCheckpoint(song: song, seconds: Int(value))
    }

    /// Immediate checkpoint: pause + entering background.
    /// Captures the latest position; skips only an identical
    /// checkpoint. Called from the app's scenePhase handler,
    /// so it must stay internal (not private).
    func saveResumeNow() {
        guard let song = currentSong else { return }
        guard MusicResumeLogic.shouldSaveNow(
            position: position,
            lastSavedKey: lastResumeSavedKey,
            lastSavedSeconds: lastResumeSavedSeconds,
            currentKey: song.identityKey
        ) else { return }
        writeResumeCheckpoint(song: song, seconds: Int(position))
    }

    private func writeResumeCheckpoint(song: MusicSong, seconds: Int) {
        // Never checkpoint the end of a track: a finished
        // song resumes from 0 (its checkpoint is cleared by
        // noteNaturalCompletion, and the restore validator
        // rejects end positions too). B9: the margin must match
        // the validator's endMarginSeconds (5 s) — the old 1 s
        // tail wrote checkpoints the validator then rejected.
        if duration > 0, Double(seconds) >= duration - MusicResumeLogic.endMarginSeconds { return }
        MusicLibraryStore.saveResume(song.identityKey, seconds: seconds)
        lastResumeSaveAt = Date()
        lastResumeSavedKey = song.identityKey
        lastResumeSavedSeconds = seconds
    }

    /// One-shot launch-time resume seek, applied once the
    /// restored track has loaded (duration > 0). Drops the
    /// checkpoint when the song changed, the load failed, or
    /// the stored position is past the end.
    private func applyPendingResumeSeek() {
        guard let pending = pendingResume else { return }
        guard let song = currentSong, song.identityKey == pending.key else {
            pendingResume = nil
            return
        }
        guard duration > 0 else { return }
        pendingResume = nil
        guard let target = MusicResumeLogic.validatedResumeSeconds(
            stored: pending.seconds, duration: duration) else { return }
        player.seek(to: Double(target)) { _ in }
    }

    /// Play/pause for the full player. Same retry behaviour as the
    /// mini player (A2): when the engine never loaded the current
    /// song — its URL failed to resolve, or playback was stopped —
    /// a plain toggle is a dead button, so the tap re-requests the
    /// song instead.
    func togglePlayPause() {
        togglePlayPauseOrRetry()
    }

    /// Mini-player play/pause. While playing this is a plain pause;
    /// paused with the song loaded in the engine it is a plain
    /// resume. But when the engine never loaded the current song —
    /// its URL failed to resolve, or playback was stopped —
    /// toggle() is a no-op (resume() guards on an engine item that
    /// does not exist), so a tap re-requests the song instead of
    /// leaving a dead button. The retry goes through the same
    /// startPlayback / play path as a fresh tap, so it re-resolves
    /// serially, fastest first, like any other play request.
    func togglePlayPauseOrRetry() {
        if isPlaying {
            player.toggle()
            hapticTick()
            return
        }
        if let song = currentSong,
           let track = player.currentTrack,
           track.id == song.identityKey || track.id == song.songId {
            player.toggle()
            hapticTick()
            return
        }
        guard let song = currentSong else { return }
        if queue.isCurrentTrack(song) {
            expectedItemId = song.identityKey
            startPlayback()
        } else {
            play(song: song)
        }
        hapticTick()
    }

    func next() {
        let nextIndex = queue.nextIndex(mode: playMode, auto: false)
        if nextIndex >= 0 {
            let nextSong = queue.tracks[nextIndex]
            expectedItemId = nextSong.identityKey
            // The engine never loaded a track (the first song failed
            // to resolve): player.next() guards on currentTrack and
            // would no-op, leaving a dead button. Drive the next
            // queue song directly; the normal path below is
            // untouched.
            if player.currentTrack == nil {
                playFromQueue(at: nextIndex)
                hapticTick()
                return
            }
        }
        player.next()
        hapticTick()
    }

    func previous() {
        let prevIndex = queue.prevIndex(mode: playMode)
        if prevIndex >= 0 {
            let prevSong = queue.tracks[prevIndex]
            expectedItemId = prevSong.identityKey
            // A8: same fallback as next() — the engine never loaded
            // a track (the first song failed to resolve), so
            // player.previous() would no-op on its currentTrack
            // guard and leave a dead button. Drive the previous
            // queue song directly.
            if player.currentTrack == nil {
                playFromQueue(at: prevIndex)
                hapticTick()
                return
            }
        }
        player.previous()
        hapticTick()
    }

    func cycleMode() {
        let next = playMode.next
        playMode = next
        MusicLibraryStore.setPlayModeCode(next.code)
        player.setPlayMode(next.toContract())
        hapticTick()
    }

    func setSpeed(_ value: Double) {
        let clamped = min(2.0, max(0.6, value))
        playbackSpeed = clamped
        MusicLibraryStore.setSpeed(clamped)
        player.setSpeed(clamped)
    }

    /// Now Playing volume slider: clamp, persist, push to the
    /// player. Live on every drag tick (like Apple Music) — no
    /// commit-on-release, no rollback: volume has no failure mode
    /// to roll back from, and the slider must track the finger.
    func setVolume(_ value: Double) {
        let clamped = min(1.0, max(0.0, value))
        volume = clamped
        MusicLibraryStore.setMusicVolume(clamped)
        player.setUserVolume(clamped)
    }

    func setTargetQuality(_ quality: AudioQuality) {
        coordinator.targetQuality = quality
        MusicLibraryStore.setTargetQualityCode(MusicLibraryStore.code(for: quality))
    }

    /// Seek to an absolute position (seconds). On failure the bar
    /// rolls back to the player's actual position + a toast.
    /// The scrub value is held until the seek's completion lands:
    /// clearing it up front let the 0.5 s position stream push the
    /// bar back to the pre-seek position mid-seek, so a drag looked
    /// like it did nothing. The completion clears it only when the
    /// scrub value is still the one this seek started from — a
    /// newer drag in flight keeps its own value.
    func seek(to seconds: Double) {
        // A14: no loaded track (a failed song has duration 0) —
        // a drag is a no-op, not a failed seek. Never toast here.
        guard duration > 0, player.currentTrack != nil else {
            scrubSeconds = nil
            return
        }
        let target = min(max(0, seconds), max(0, duration))
        // A manual seek wins over a pending launch-time
        // resume seek: the user just chose where to listen.
        pendingResume = nil
        let scrubbed = scrubSeconds
        player.seek(to: target) { [weak self] ok in
            guard let self = self else { return }
            if self.scrubSeconds == scrubbed { self.scrubSeconds = nil }
            if !ok { self.handleSeekFailed() }
        }
    }

    private func handleSeekFailed() {
        position = player.position
        showToast("seek 失败，已回到实际位置")
    }

    func showToast(_ text: String) {
        toast = text
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            self?.toast = nil
        }
    }

    func toggleFavourite() {
        guard let song = currentSong else { return }
        isCurrentFav = MusicLibraryStore.toggleFav(song)
        hapticTick()
    }

    /// Download the current song (more sheet "下载" button, S3).
    /// Resolves the playable URL at the target quality — the URL
    /// cache makes this cheap while the song is playing — then
    /// enqueues it on the shared DownloadEngine. On completion the
    /// file is registered in the existing downloads index; the
    /// engine itself never touches MusicLibraryStore. The quality
    /// recorded is the tier actually resolved (Master honesty
    /// gate), never just the target.
    func downloadCurrent() {
        guard let song = currentSong else { return }
        if MusicLibraryStore.getDownloads().contains(where: { $0.key == song.identityKey }) {
            showToast("已下载")
            return
        }
        guard let resolver = coordinator.resolver else {
            showToast("下载失败：无法解析播放地址")
            return
        }
        let target = coordinator.targetQuality
        resolver.resolveFirstPlayable(for: song.toPlaybackItem(), targetQuality: target, excluding: []) { [weak self] url in
            // Read the resolved tier HERE (this closure is plain
            // @escaping): `resolver` is a bare SourceResolver
            // existential, not Sendable, so it must not be captured
            // by the main-queue hop below.
            let actualQuality = (resolver as? TierReportingResolver)?.lastResolvedTier ?? target
            // A DispatchWorkItem, not a trailing closure on the main
            // queue: Xcode 26 marks that closure @Sendable, and
            // this body captures `song` / `actualQuality` — our own
            // value types with no Sendable conformance under
            // SWIFT_VERSION 5.0 — so the compiler resolves the call
            // to the DispatchWorkItem overload and fails the build.
            // A work item's block is plain @escaping, so it takes
            // any capture.
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard let url = url else {
                    self.showToast("下载失败：找不到可播放的地址")
                    return
                }
                let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
                let request = DownloadRequest(
                    key: song.identityKey,
                    title: "\(song.title) - \(song.artist)",
                    sourceURL: url,
                    fileName: "\(song.title) - \(song.artist).\(ext)",
                    kind: .music,
                    qualityCode: MusicLibraryStore.code(for: actualQuality)
                )
                DownloadEngine.shared.enqueue(request: request, completion: { info in
                    switch info.state {
                    case .completed:
                        var downloads = MusicLibraryStore.getDownloads()
                        downloads.removeAll { $0.key == song.identityKey }
                        downloads.append(DownloadedSong(
                            song: song,
                            filePath: info.localRelativePath ?? "",
                            sizeBytes: Int(info.downloadedBytes),
                            downloadedAt: Int(Date().timeIntervalSince1970),
                            qualityCode: MusicLibraryStore.code(for: actualQuality)
                        ))
                        MusicLibraryStore.saveDownloads(downloads)
                        self.showToast("下载完成")
                    case .failed:
                        self.showToast("下载失败：\(info.errorMessage ?? "未知错误")")
                    default:
                        break
                    }
                })
                self.showToast("已加入下载")
            }
            DispatchQueue.main.async(execute: work)
        }
    }

    func toggleLyrics() {
        showLyrics.toggle()
        hapticTick()
    }

    // MARK: - Lyrics

    private func loadLyrics(for song: MusicSong, fetchIfMissing: Bool = true) {
        lyricsLoaded = false
        lyrics = []
        activeLyricIndex = -1
        if let cached = MusicLibraryStore.cachedLyrics(for: song.identityKey) {
            lyrics = MusicLyrics.toContractLines(cached)
            lyricsLoaded = true
            updateActiveLyric()
            return
        }
        guard fetchIfMissing else {
            lyricsLoaded = true
            return
        }
        let track = MusicTrack(
            id: song.songId, title: song.title, artist: song.artist,
            album: song.album, coverURL: URL(string: song.cover), duration: TimeInterval(song.dur),
            sourceID: song.platform.rawValue
        )
        MusicLyricsAPI.shared.fetchLyrics(for: track) { [weak self] result in
            guard let self = self else { return }
            guard let result = result else {
                self.lyricsLoaded = true
                return
            }
            // Only keep the result if the song is still current.
            guard self.currentSong?.identityKey == song.identityKey else { return }
            self.lyrics = result.lines
            self.lyricsLoaded = true
            // A11: keep the translation in the cache too — the old
            // mapping dropped it, so a cached song never showed one.
            let stored = result.lines.map { StoredLyricLine(t: $0.time, text: $0.text, translation: $0.translation) }
            MusicLibraryStore.putLyrics(stored, for: song.identityKey)
            self.updateActiveLyric()
        }
    }

    private func updateActiveLyric() {
        guard !lyrics.isEmpty else {
            activeLyricIndex = -1
            return
        }
        activeLyricIndex = MusicLyrics.activeIndex(
            lines: lyrics, position: position, offsetMs: lyricOffsetMs
        )
    }

    // MARK: - Sleep timer + completion bookkeeping

    /// One naturally-completed track: listen log (heard >= 5 s) +
    /// sleep completion modes. Deduplicated per track within 2 s.
    private func noteNaturalCompletion(completed: MusicSong) {
        let key = completed.identityKey
        let now = Date()
        if key == lastCompletionKey && now.timeIntervalSince(lastCompletionAt) < 2 {
            return
        }
        lastCompletionKey = key
        lastCompletionAt = now
        // A finished track leaves no resume point: the next
        // play of this song starts from 0 (and a pending
        // launch-time seek for it is dropped too).
        if pendingResume?.key == key { pendingResume = nil }
        MusicLibraryStore.clearResume(key)
        if heardTrackKey == key && heardSeconds >= 5 {
            MusicLibraryStore.recordListenEvent(ListenEvent(
                json: [
                    "songId": completed.songId,
                    "title": completed.title,
                    "artist": completed.artist,
                    "platform": completed.platform.rawValue,
                    "cover": completed.cover,
                    "dur": Int(heardSeconds),
                    "totalDur": completed.dur,
                    "at": Int(Date().timeIntervalSince1970 * 1000),
                ]
            ))
        }
        if sleepTimer.noteTrackCompleted() {
            player.pause()
            sleepTimer.cancel()
            return
        }
        if sleepTimer.isCurrentTrackEnd {
            player.pause()
            sleepTimer.cancel()
            return
        }
        if sleepTimer.isQueueEnd {
            let index = queue.tracks.firstIndex(where: { $0.identityKey == key }) ?? queue.index
            if musicNextTrackIndex(mode: playMode, current: index, length: queue.tracks.count, auto: true) == -1 {
                player.pause()
                sleepTimer.cancel()
                return
            }
        }
    }

    // MARK: - Queue management (queue sheet)

    func playFromQueue(at index: Int) {
        guard index >= 0 && index < queue.tracks.count else { return }
        let song = queue.tracks[index]
        queue.index = index
        expectedItemId = song.identityKey
        startPlayback()
    }

    func removeFromQueue(at index: Int) {
        let wasCurrent = index == queue.index
        queue.remove(at: index)
        MusicLibraryStore.saveQueue(queue.toQueueData())
        if wasCurrent {
            player.pause()
            coordinator.stop()
            // A7: route through setCurrentSong (or a full clear) —
            // assigning currentSong directly left the lyrics, the
            // favourite star and the quality badge on the deleted
            // song.
            if let next = queue.current {
                setCurrentSong(next)
            } else {
                clearCurrentSongState()
            }
            miniFallbackSong = queue.current
        }
    }

    func clearQueue() {
        queue.clear()
        MusicLibraryStore.saveQueue(queue.toQueueData())
        player.pause()
        coordinator.stop()
        // A7: same as above — clearing the queue must also clear
        // the lyrics and the favourite star, not just the song.
        clearCurrentSongState()
        miniFallbackSong = nil
    }

    /// Clear every piece of state that belongs to the current song
    /// (used when the queue empties). setCurrentSong covers the
    /// has-a-song case; this covers the has-no-song case.
    private func clearCurrentSongState() {
        currentSong = nil
        lyrics = []
        lyricsLoaded = true
        activeLyricIndex = -1
        isCurrentFav = false
        localQualityLabel = nil
        heardTrackKey = ""
        heardSeconds = 0
    }

    // MARK: - Haptics

    /// Light tap feedback, only when the `hapticsEnabled` switch is on.
    func hapticTick() {
        guard MusicLibraryStore.hapticsEnabled() else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

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

    /// The reloadable "place" the current queue came from (b45,
    /// Coda PlaySource/PlayContext approach, our rewrite): the
    /// playlist / album / artist / chart / daily / recent list
    /// the user tapped, by kind + id. The in-memory queue is
    /// the only copy until this is set — when it is lost (the
    /// retry/toggle single-song fallback rebuilt it to one song,
    /// or an outside item replaced the current song), next() /
    /// previous() reload the list from this source instead of
    /// answering "nothing". Nil for one-off plays (search rows
    /// without a list, play-next inserts): those have no place
    /// to reload from, and the old behaviour stands.
    @Published private(set) var currentPlayContext: PlayContext?

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
    /// The tier ACTUALLY playing, or nil before the first report.
    /// The badge shows this, never the target tier (Master honesty).
    @Published private(set) var actualQuality: AudioQuality?
    /// Local-file badge text (S7-A): the player reports no tier for
    /// local files (the resolver is bypassed), so the tier is derived
    /// from the file itself — "本地" when the file proves no tier.
    /// Nil for remote songs and when there is nothing honest to show.
    @Published private(set) var localQualityLabel: String?

    /// True when the current song's manual play request failed and
    /// there was no next song to advance to (b38, item 1): the
    /// player shows a persistent "无法播放" state with a retry
    /// button instead of sitting silently at 0:00. Cleared by any
    /// new play attempt and by a track that really starts.
    @Published private(set) var loadFailed = false

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
    /// True when the lyrics fetch returned nothing for a song on
    /// a platform that HAS a lyrics endpoint (task book §3.3):
    /// the view offers a retry instead of the plain "暂无歌词".
    /// False for cached hits, for successful fetches, and for
    /// platforms with no endpoint (kg / mg) — those are honest
    /// empty states, not failed loads. `fetchLyrics` returns nil
    /// both when the network fails and when no lyrics exist, so
    /// the view's wording stays neutral ("未能加载歌词").
    @Published private(set) var lyricsLoadFailed = false
    @Published private(set) var activeLyricIndex = -1
    /// Lyric-source override for the current song (b49fix2 #16):
    /// the platform the lyrics were fetched from. Nil = the song's
    /// own platform ("跟随歌曲"). The menu in the player's more
    /// sheet sets it; the choice is remembered per song (see
    /// lyricSourceOverrides below) so it survives relaunch.
    @Published private(set) var lyricSourceOverride: MusicPlatform?
    /// Per-song lyric-source overrides, persisted (UserDefaults
    /// dict identityKey -> platform code). Loaded in init.
    private var lyricSourceOverrides: [String: String] = [:]
    private static let lyricSourceOverridesKey = "hao.lyricSourceOverrideBySong"
    @Published var lyricOffsetMs: Int {
        didSet {
            // b45-a: the offset is remembered PER SONG (0.1 s steps,
            // key `lyrics.timing.<identityKey>`, 0 deletes the key).
            // Suppressed while a song switch loads its own value —
            // otherwise every switch would stamp the new song's
            // value onto the GLOBAL offset (and the next
            // never-adjusted song would inherit it) and onto the
            // new song as if the user had adjusted it. The global
            // offset only moves on a real user edit.
            if !applyingPerSongOffset {
                MusicLibraryStore.setLyricOffsetMs(lyricOffsetMs)
                if let song = currentSong {
                    MusicLyrics.savePerSongOffsetMs(lyricOffsetMs, for: song.identityKey)
                }
            }
            updateActiveLyric()
        }
    }

    /// True while setCurrentSong loads the new song's own offset,
    /// so the didSet above does not write it back as a user edit.
    private var applyingPerSongOffset = false

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

    /// Generation counter for in-flight background favourite checks
    /// (b36-item10): a check started for song A must not overwrite
    /// the star after the user toggled it, after another song
    /// started, or after the queue was cleared. Bumped on every
    /// toggle / fav-change notification / clear, and per new check.
    private var favCheckGeneration = 0

    private let player = NativeMusicPlayer.shared
    private let coordinator: PlaybackCoordinator
    private var cancellables = Set<AnyCancellable>()
    /// b49fix2 P1-30: NotificationCenter tokens — the token's
    /// lifetime controls the observation, not the VM's. The old
    /// `_ = addObserver(...)` discards dropped the foreground +
    /// favourite observers on arrival (the favourite star never
    /// refreshed; the foreground sleep-timer check never ran).
    /// Removed in deinit.
    private var foregroundObserver: NSObjectProtocol?
    private var favChangedObserver: NSObjectProtocol?
    /// b49fix2 P1-2: backup-import observer (reload queue +
    /// favourites after an import replaces the store).
    private var backupImportedObserver: NSObjectProtocol?
    private var toastTimer: Timer?
    private var expectedItemId: String?
    /// Consecutive failure-driven skips (b38, item 1): bounds the
    /// auto-advance on a failed manual request to one pass over
    /// the queue, so a list of all-dead songs (or a looping mode)
    /// stops on the persistent error instead of cycling forever.
    /// Reset whenever a track really starts (duration > 0) and
    /// when the pass is exhausted.
    private var consecutiveFailureSkips = 0
    /// Quality-change rollback (b49sweep P2-12): the old quality
    /// + position, armed when a playing song is re-resolved at a
    /// new target quality. The failure sink consumes it — a
    /// failed re-resolve restores the old quality and retries
    /// once instead of leaving the song dead. Cleared when the
    /// track really starts (duration > 0). 30 s validity: a
    /// failure long after the switch is a new failure, not the
    /// re-resolve's.
    private var qualityRollback: (quality: AudioQuality, key: String, seconds: Int, armedAt: Date)?
    /// FM / heartbeat refill batch counter (b49sweep P1-6): the
    /// refill seed is the day key + this counter, so each
    /// mid-session batch differs from the day-seeded first
    /// queue. Reset on every new play context (recordPlayContext)
    /// — a new session starts a new counter; the refill itself
    /// never calls recordPlayContext, so the counter survives
    /// across refills within one session.
    private var fmRefillBatch = 0
    private var lastPosition: Double = 0
    // D3: guards for the position-wrap heuristic below — a
    // backward jump is only a natural completion when it lands
    // near 0, no VM seek just fired, and the position belonged
    // to this same track.
    private var lastSeekAt = Date.distantPast
    private var lastPositionTrackKey: String?
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
        // b49fix2 #16: remembered per-song lyric sources.
        self.lyricSourceOverrides = UserDefaults.standard.dictionary(forKey: Self.lyricSourceOverridesKey) as? [String: String] ?? [:]
        self.playMode = MusicQueueMode.fromCode(MusicLibraryStore.playModeCode())
        self.playbackSpeed = MusicLibraryStore.speed()
        // Handlers are attached AFTER the timer exists: capturing
        // self inside its own initializer is a compile error
        // (self.sleepTimer is not initialized yet at that point).
        self.sleepTimer = MusicSleepTimer(onFire: {})
        sleepTimer.onFire = { [weak self] in
            guard let self = self else { return }
            // b49fix2 P2-23: the timer stops whatever is playing —
            // a live room or a VOD keeps sounding if only the music
            // player is paused. coordinator.stop() stops all three
            // drivers and clears the current item; player.pause()
            // stays for the case where the coordinator has nothing
            // to stop.
            self.coordinator.stop()
            self.player.pause()
            self.sleepActive = false
            self.sleepRemainingText = ""
        }
        sleepTimer.onChanged = { [weak self] in
            guard let self = self else { return }
            self.sleepActive = self.sleepTimer.isActive
            self.sleepRemainingText = self.sleepTimer.remainingText
            // b49sweep P2-11: a completion-mode timer arms the
            // player's hard cut — the crossfade's 2.5 s ramp would
            // otherwise make the timer pause ~2.5 s into the next
            // song. Wall-clock timers fire via onFire directly
            // and never arm it; cancelling the timer clears it.
            self.player.sleepCompletionArmed = self.sleepTimer.isCurrentTrackEnd
                || self.sleepTimer.isAfterNTracks
                || self.sleepTimer.isQueueEnd
        }
        // b49fix2 P1-7: restore the persisted sleep timer BEFORE
        // the auto-resume decision below — a wall-clock timer that
        // fired while the app was dead means the user asked for
        // silence, not a surprise resume on launch.
        let sleepFiredWhileDead = sleepTimer.restore()
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
                // b45-a: the restored song reads its own remembered
                // lyric offset back, same as a live song switch.
                // b49fix2 P2-1: the restore assignment runs with
                // the guard up — without it, the restored song's
                // per-song offset leaks into the global offset
                // (the didSet on lyricOffsetMs saves it).
                applyingPerSongOffset = true
                lyricOffsetMs = MusicLyrics.perSongOffsetMs(for: song.identityKey)
                    ?? MusicLibraryStore.lyricOffsetMs()
                applyingPerSongOffset = false
                // b49fix2 #16: and its remembered lyric source.
                lyricSourceOverride = lyricSourceOverrides[song.identityKey].flatMap { MusicPlatform(code: $0) }
                loadLyrics(for: song, fetchIfMissing: false)
            }
        }
        // b46: restore the persisted play context alongside the
        // queue, so track switching can still reload the playlist
        // after a relaunch.
        restorePersistedPlayContext()
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
        if !sleepFiredWhileDead,
           AutoResumeDecision.resumeIndex(
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
        // stop time.
        // b49fix2 P1-30: the token is stored — the old `_ =`
        // discard dropped this observer on arrival, so the
        // foreground sleep-timer check never ran.
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleepTimer.checkFire()
        }
        // Favourite sync (build 36, item 12): a toggle from any
        // row or card posts haoMusicFavChanged — refresh the
        // current song's star so the full player never shows a
        // stale favourite state while the song is playing.
        // b49fix2 P1-30: same token fix — the star never refreshed
        // because this observer died on arrival too.
        favChangedObserver = NotificationCenter.default.addObserver(forName: .haoMusicFavChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, let song = self.currentSong else { return }
            // b36-item10: invalidate any in-flight background fav
            // check — its result predates this toggle.
            self.favCheckGeneration += 1
            self.isCurrentFav = MusicLibraryStore.isFav(song)
            self.syncNowPlayingLike()
        }
        // b49fix2 P1-2: a backup import replaces the store files
        // under the queue — the live queue, the current song's
        // favourite star and the mini fallback must re-read, or
        // the player keeps serving the pre-import list and the
        // next 切歌 writes the old list back over the import.
        // (The double-post itself was fixed by the Shell lane;
        // this is the view-model observation.)
        backupImportedObserver = NotificationCenter.default.addObserver(forName: .haoBackupImported, object: nil, queue: .main) { [weak self] _ in
            self?.reloadAfterBackupImport()
        }
        // b49fix2 P1-1: install the player's local-audio lookup —
        // the downloaded file or audio-cache file for an item, or
        // nil. It drives the manual crossfade, the offline
        // selector and the prefetch "already cached" check, none
        // of which ever had a lookup (the closure was declared
        // and never assigned).
        player.localAudioURL = { item in
            MusicPlayerViewModel.localAudioURL(for: item)
        }
        // b41: remote next / previous (Dynamic Island / Control
        // Center / lock screen) run the SAME path as the in-app
        // buttons below — this view model's live queue — instead
        // of the player's own queue, which goes stale after
        // play-next inserts / removals and has no
        // currentTrack-nil fallback. This view model lives for the
        // app lifetime, so the closures never go stale; the player
        // falls back to its own next() / previous() when unset.
        player.onRemoteNext = { [weak self] in self?.next() }
        player.onRemotePrevious = { [weak self] in self?.previous() }
        // b45-a: Control Center like command (NowPlayingManager):
        // a long-press like in Control Center toggles the same
        // favourite as the in-app heart, and likeCommand.isActive
        // follows the current song (see syncNowPlayingLike).
        player.onRemoteLike = { [weak self] in self?.toggleFavourite() }
    }

    deinit {
        // b49fix2 P1-30: the observers live exactly as long as the
        // tokens — remove them here (the VM lives for the app
        // lifetime in practice, but a leaked observer is a stale
        // favourite star waiting to happen).
        if let token = foregroundObserver { NotificationCenter.default.removeObserver(token) }
        if let token = favChangedObserver { NotificationCenter.default.removeObserver(token) }
        if let token = backupImportedObserver { NotificationCenter.default.removeObserver(token) }
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
            // D5: the previous position, captured before the wrap
            // branch below overwrites lastPosition — heardSeconds
            // accumulates only the time actually heard, not the
            // absolute position (a forward seek used to inflate
            // the listen log by the whole jump).
            let prevPosition = self.lastPosition
            // Sleep wall-clock deadline (S7-A): the 1 s ticker can
            // stall while the app is backgrounded, but position
            // updates keep flowing while audio plays — re-check the
            // deadline here so a timer never sleeps past its stop
            // time. checkFire is a no-op without a deadline.
            self.sleepTimer.checkFire()
            // Position wrapped backwards by > 5 s: a natural
            // completion (single-loop replay) ONLY when all three
            // guards hold — (a) the wrap lands near 0 (a backward
            // seek lands mid-song); (b) no VM-issued seek just
            // fired (lyric-line tap, progress-bar drag); (c) the
            // position belonged to this same track (a 0-tick
            // arriving after a track change is suppressed because
            // handleCurrentItemChanged already counted the old
            // track; one arriving before it counts the old track
            // once, deduped by the 2 s window). Without the guards,
            // tapping an earlier lyric line or dragging the bar
            // back counted as "one song finished": the sleep timer
            // could pause mid-song and the resume checkpoint was
            // wiped. Residual: a remote skip-back (Control Center
            // / lock screen, bypasses the VM) landing within 5 s
            // of 0:00 still counts once — rare and harmless.
            if value < 5 && value < self.lastPosition - 5
                && Date().timeIntervalSince(self.lastSeekAt) > 1.5
                && self.lastPositionTrackKey == self.currentSong?.identityKey {
                if let song = self.currentSong { self.noteNaturalCompletion(completed: song) }
            }
            self.lastPosition = value
            self.lastPositionTrackKey = self.currentSong?.identityKey
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
                    // D5: accumulate the time actually heard.
                    // Backward seeks / track changes contribute 0;
                    // a forward seek contributes 0 (the jump itself
                    // is not heard time) — only real playback ticks
                    // add up.
                    self.heardSeconds += max(0, value - prevPosition)
                }
            }
            self.updateActiveLyric()
        }.store(in: &cancellables)
        player.$duration.sink { [weak self] value in
            guard let self = self else { return }
            self.duration = value
            if value > 0 {
                self.loadFailed = false
                self.consecutiveFailureSkips = 0
                // b49sweep P2-12: the track really started — a
                // quality-change re-resolve succeeded, so its
                // rollback is dead.
                self.qualityRollback = nil
            }
            self.applyPendingResumeSeek()
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
        // F1 (build 36, item 8): a manual play request that fails
        // to resolve/open used to do nothing visible — no toast, no
        // advance, the song just sat there paused. The engine
        // publishes each failure (counter, so the same song failing
        // twice surfaces twice); when the failed id is the song
        // showing now, say so instead of leaving a dead tap.
        player.$failedRequestCount.sink { [weak self] _ in
            guard let self = self else { return }
            guard let id = self.player.lastFailedRequestId,
                  let song = self.currentSong,
                  id == song.identityKey || id == song.songId else { return }
            // b49sweep P2-12: a quality-change re-resolve failed —
            // restore the old quality and retry once instead of
            // advancing. The retry's own failure has no rollback
            // left, so it falls through to the normal advance
            // below. A stale rollback (other song / > 30 s) is
            // cleared and ignored.
            if let rollback = self.qualityRollback,
               rollback.key == song.identityKey,
               Date().timeIntervalSince(rollback.armedAt) < 30 {
                self.qualityRollback = nil
                self.applyTargetQuality(rollback.quality)
                self.clearResolveFailure(for: song)
                self.player.stop()
                self.coordinator.stop()
                self.pendingResume = (key: song.identityKey, seconds: rollback.seconds)
                self.expectedItemId = song.identityKey
                self.showToast("该音质暂不可用，已恢复之前的音质")
                self.startPlayback()
                return
            }
            self.qualityRollback = nil
            self.handleCurrentSongFailed(song: song)
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
            // item.id is the identityKey `platform|songId` — split
            // it back, or the rebuilt song's identityKey comes out
            // as `wy|wy|…` and corrupts favourites / resume keys.
            let idParts = item.id.split(separator: "|", maxSplits: 1)
            let song = MusicSong(
                songId: idParts.count == 2 ? String(idParts[1]) : item.id,
                title: item.title, artist: item.artist ?? "",
                cover: item.coverURL?.absoluteString ?? "",
                platform: idParts.count == 2
                    ? MusicPlatform.fromCode(String(idParts[0])) : .wy)
            setCurrentSong(song)
        }
        // The mini player's fallback follows the same song — but
        // only for music. A VOD / live item must never become a
        // mini "song" (see miniFallbackSong).
        miniFallbackSong = item.kind == .music ? currentSong : nil
        // b49sweep P1-6: FM / heartbeat refill — the choke point
        // for every track change, manual or auto.
        extendFMQueueIfNeeded()
    }

    /// FM / heartbeat mid-session refill (b49sweep P1-6): the
    /// player plays the view model's snapshot copy, and the old
    /// refill only ran when the FM view's own queue was empty —
    /// so a 50-song FM session simply ended. When the context is
    /// FM or heartbeat and ≤3 songs remain after the current
    /// one, append a fresh seeded batch (a new seed each time,
    /// so the batch differs from the day-seeded first queue),
    /// deduped against everything already queued, and push the
    /// grown queue into the player + the snapshot + the persisted
    /// context. An empty filtered batch means the pool is
    /// exhausted — the session honestly ends. The refill never
    /// calls recordPlayContext: that would reset the batch
    /// counter (a new session starts a new counter).
    private func extendFMQueueIfNeeded() {
        guard let context = currentPlayContext,
              context.source.kind == .fm || context.source.kind == .heartbeat,
              let current = currentSong,
              let currentInQueue = queue.current,
              (currentInQueue.songId == current.songId || currentInQueue.identityKey == current.identityKey),
              queue.tracks.count - queue.index <= 3 else { return }
        let mode: MusicFMMode = context.source.kind == .heartbeat ? .heartbeat : .fm
        fmRefillBatch += 1
        let seed = musicDayKey(of: Date()) + "-refill-\(fmRefillBatch)"
        let existing = Set(queue.tracks.map { $0.identityKey })
        let fresh = MusicFMViewModel.queueFor(mode: mode, seed: seed)
            .filter { !existing.contains($0.identityKey) }
        guard !fresh.isEmpty else { return }
        queue.tracks.append(contentsOf: fresh)
        if var updated = currentPlayContext {
            updated.songKeys.append(contentsOf: fresh.map { $0.identityKey })
            updated.lastPlayedAt = Date().timeIntervalSince1970
            currentPlayContext = updated
        }
        PlaylistSnapshotStore.save(PlaylistSnapshot(
            source: context.source, displayName: context.displayName, songs: queue.tracks))
        persistPlayContext()
        player.setQueueOnly(queue.toPlaybackItems(), startAt: queue.index)
    }

    private func setCurrentSong(_ song: MusicSong) {
        currentSong = song
        // b45-a: a song switch reads its own remembered lyric
        // offset back (0.1 s steps); a song never adjusted falls
        // back to the global offset.
        applyingPerSongOffset = true
        lyricOffsetMs = MusicLyrics.perSongOffsetMs(for: song.identityKey)
            ?? MusicLibraryStore.lyricOffsetMs()
        applyingPerSongOffset = false
        // b49fix2 #16: a song switch reads its remembered lyric
        // source back (nil = the song's own platform).
        lyricSourceOverride = lyricSourceOverrides[song.identityKey].flatMap { MusicPlatform(code: $0) }
        // b36-item10: the star keeps the previous song's state until
        // the background fav read lands — never flash a wrong state,
        // never block the switch on disk I/O.
        refreshCurrentFav(for: song)
        loadLyrics(for: song)
        heardTrackKey = song.identityKey
        heardSeconds = 0
        refreshLocalQualityBadge()
        // b45-a: a song change restores the control bar (the lyrics
        // auto-hide / scroll-hide must never survive a track switch).
        syncNowPlayingLike()
    }

    /// Favourite state for `song`, read off the main thread. Applies
    /// only when this check is still the newest one and the song is
    /// still current — a toggle or a newer switch in between wins.
    private func refreshCurrentFav(for song: MusicSong) {
        favCheckGeneration += 1
        let generation = favCheckGeneration
        let key = song.identityKey
        MusicLibraryStore.isFavAsync(song) { [weak self] fav in
            guard let self = self else { return }
            guard self.favCheckGeneration == generation,
                  self.currentSong?.identityKey == key else { return }
            self.isCurrentFav = fav
            self.syncNowPlayingLike()
        }
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
            // b49fix2 #21: resolve FIRST — a relative stored path
            // is not a file URL (URL(fileURLWithPath:) would point
            // at the process's working directory, not the file).
            guard let url = LocalFileIndex.resolve(path, subdir: "local_music")
                    ?? LocalFileIndex.resolve(path, subdir: DownloadEngine.downloadSubdir)
            else { return }
            let label = localFileQualityLabel(for: url)
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
    ///
    /// `resumeFrom`: the home "继续听" tap passes the stored
    /// checkpoint here (H1, build 36 follow-up); every other
    /// caller leaves it nil and plays from 0. A positive value
    /// arms the one-shot resume seek before startPlayback — it
    /// lands once the player reports a duration, through the
    /// same applyPendingResumeSeek as the launch-time resume.
    /// A same-track tap takes the shortcut above and does not
    /// re-seek: a paused track resumes where it stopped, which
    /// is the checkpoint itself (pause writes it), and a playing
    /// track is already past it.
    ///
    /// `source` / `sourceDisplayName` (b45): the reloadable
    /// "place" this list came from — a playlist detail passes
    /// its list, an album detail its album, and so on. Recorded
    /// as the current play context (and snapshotted to disk for
    /// remote lists), so a later 切歌 can reload the list when
    /// the in-memory queue is gone. Nil = one-off play, no
    /// place to reload from; the context is cleared then.
    /// b46: a manual play re-asks every source for that song.
    /// A failure remembered from an earlier attempt (a slow
    /// network timeout, a transient error) must not make the
    /// song unplayable for 10 minutes when the user explicitly
    /// asks for it now. Automatic skips (handleCurrentSongFailed)
    /// do NOT call this: a dead song is skipped past quickly
    /// there, and the memory is what makes that skip instant.
    private func clearResolveFailure(for song: MusicSong) {
        // b49fix24 D26-5: the resolver keys on the second segment
        // of identityKey, not the raw songId — an empty-id song
        // must clear "title|artist|album", or the clear misses
        // the recorded failure entirely.
        coordinator.clearResolveFailureMemory(forSongId: song.resolveSongId)
    }

    func play(song: MusicSong, in tracks: [MusicSong]? = nil, startAt: Int? = nil, resumeFrom: Double? = nil, source: PlaySource? = nil, sourceDisplayName: String? = nil) {
        // b49fix2 P1-1: a downloaded song played from any list
        // (playlist, recent, search) must play its file, not
        // re-resolve over the network — attach the download's file
        // before the queue is built, so the playback item carries
        // a local file URL and the coordinator returns it first.
        let song = Self.withLocalFile(song)
        if queue.isCurrentTrack(song),
           let track = player.currentTrack,
           track.id == song.identityKey || track.id == song.songId {
            // M3b (b45): the old shortcut resumed the player
            // directly, bypassing the coordinator — a live room /
            // VOD episode kept sounding under the resumed song.
            // Route through requestPlay: its same-track branch
            // stops vod/live first, then resumes (or no-ops when
            // already playing). No re-seek either way: a paused
            // track resumes where it stopped, which is the
            // checkpoint itself (pause writes it).
            coordinator.requestPlay(song.toPlaybackItem())
            return
        }
        if let tracks = tracks {
            // b49: dedupe by identityKey at the entry — a merged
            // search result or a playlist can list the same song
            // twice, and the twin makes next() target the current
            // song (switching equals no switching, silently).
            let deduped = MusicQueue.deduped(tracks)
            let start: Int
            if let startAt = startAt, startAt >= 0, startAt < tracks.count {
                // startAt indexes the caller's list: re-resolve it
                // by identity in the deduped list.
                let key = tracks[startAt].identityKey
                start = deduped.firstIndex(where: { $0.identityKey == key }) ?? 0
            } else {
                start = deduped.firstIndex(where: { $0.identityKey == song.identityKey }) ?? 0
            }
            queue = MusicQueue(tracks: deduped, index: min(max(0, start), max(0, deduped.count - 1)))
            recordPlayContext(source: source, displayName: sourceDisplayName, tracks: deduped)
        } else {
            // b49: a no-tracks play must NEVER clear the context /
            // queue. The 0.0.2 collapse: the retry/recover fallback
            // fell here, set queue = [song], context = nil and
            // deleted the persisted context from disk — after that
            // next() could never rebuild, across restarts. Keep
            // the existing queue and context; find the song in it.
            if let index = queue.tracks.firstIndex(where: { $0.identityKey == song.identityKey }) {
                // Replace the queued copy with the incoming one:
                // it may carry fresher info (playLocal's localPath),
                // while the identity — and the list — stay the same.
                // (playLocal's with-tracks branch does the same.)
                queue.tracks[index] = song
                queue.index = index
            } else if rebuildQueueFromContext(),
                      let index = queue.tracks.firstIndex(where: { $0.identityKey == song.identityKey }) {
                queue.tracks[index] = song
                queue.index = index
            } else {
                // The song is in no list we know: keep the queue
                // intact and insert the song after the current one
                // instead of replacing the queue with one song.
                // (Empty queue: insert at 0 — the same single song,
                // with nothing to preserve.)
                var tracks = queue.tracks
                let at = min(queue.index + 1, tracks.count)
                tracks.insert(song, at: at)
                queue = MusicQueue(tracks: tracks, index: at)
            }
            // currentPlayContext is deliberately untouched here.
        }
        expectedItemId = song.identityKey
        // H1: arm the resume seek (if any) BEFORE startPlayback.
        // A plain play clears an armed seek for a DIFFERENT song:
        // the user chose a song from the start, so a stale armed
        // seek (e.g. the launch resume) must not jump it forward
        // when its duration later arrives. The same song keeps its
        // armed seek — re-tapping the auto-resuming song before it
        // loads must not silently drop the launch resume.
        if let seconds = MusicResumeLogic.resumeSecondsToArm(requested: resumeFrom) {
            pendingResume = (key: song.identityKey, seconds: seconds)
        } else if pendingResume?.key != song.identityKey {
            pendingResume = nil
        }
        clearResolveFailure(for: song)
        startPlayback()
        hapticTick()
    }

    /// Play a whole list from the top (e.g. 播放全部). `source`
    /// is the list's reloadable place (b45) — same contract as
    /// play(song:in:source:).
    func playAll(_ tracks: [MusicSong], source: PlaySource? = nil, sourceDisplayName: String? = nil) {
        guard let first = tracks.first else { return }
        play(song: first, in: tracks, startAt: 0, source: source, sourceDisplayName: sourceDisplayName)
    }

    /// Attach a downloaded file to a song that has none (b49fix2
    /// P1-1): the copy's localPath makes toPlaybackItem() carry a
    /// file URL, so the coordinator returns the file first and
    /// offline playback works from any list — not just the
    /// downloads page. Local-library songs already carry localPath
    /// and pass through untouched.
    private static func withLocalFile(_ song: MusicSong) -> MusicSong {
        guard song.localPath.isEmpty else { return song }
        guard let download = MusicLibraryStore.getDownloads().first(where: { $0.key == song.identityKey }),
              let url = LocalFileIndex.resolve(download.filePath, subdir: DownloadEngine.downloadSubdir)
        else { return song }
        var copy = song
        copy.localPath = url.path
        return copy
    }

    /// Play a downloaded / local song. The resolver (player leg)
    /// looks the file up by song id in the downloads / local index;
    /// this leg passes the same setQueue + requestPlay as remote.
    /// Play a downloaded / local file. `fileURL` is the resolved
    /// local file (downloads carry their path on the wrapper, not on
    /// the song); it is stored on the queued copy's localPath so the
    /// playback item carries a file URL and the resolver is bypassed.
    /// Local-library songs already carry localPath.
    /// b46: `tracks` + `source` keep the list reloadable for
    /// track switching, exactly like play(song:in:source:). The
    /// tapped song's localPath-carrying copy replaces its slot
    /// in the queued list, so the file (not a network resolve)
    /// is what plays for it.
    func playLocal(song: MusicSong, fileURL: URL? = nil, in tracks: [MusicSong]? = nil, startAt: Int? = nil, source: PlaySource? = nil, sourceDisplayName: String? = nil) {
        var song = song
        if let fileURL = fileURL {
            song.localPath = fileURL.path
        } else if !song.localPath.isEmpty {
            // b49fix2 #21: resolve FIRST — a stored relative path
            // (or a stale absolute one from before a container
            // move) must become a real file URL before the item is
            // built. Local files live under local_music, downloads
            // under music_downloads; a path that resolves nowhere
            // stays as-is (the player then fails honestly, as
            // before).
            let url = LocalFileIndex.resolve(song.localPath, subdir: "local_music")
                ?? LocalFileIndex.resolve(song.localPath, subdir: DownloadEngine.downloadSubdir)
            if let url = url { song.localPath = url.path }
        }
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
        if let tracks = tracks {
            let start = startAt ?? tracks.firstIndex(where: { $0.identityKey == song.identityKey }) ?? 0
            var queueTracks = tracks
            if start >= 0 && start < queueTracks.count { queueTracks[start] = song }
            play(song: song, in: queueTracks, startAt: start, source: source, sourceDisplayName: sourceDisplayName)
        } else {
            // b49: no list was given — route through the no-tracks
            // play, which preserves the queue/context and inserts
            // the local copy after the current song. The old
            // one-song list (source nil) cleared the context.
            play(song: song)
        }
    }

    private func startPlayback() {
        guard let current = queue.current else { return }
        // b38, item 1: a new attempt clears the persistent
        // "无法播放" state — it belongs to the previous attempt.
        loadFailed = false
        // A1: set the queue WITHOUT playing — requestPlay below is
        // the only play call, so one tap resolves exactly once.
        player.setQueueOnly(queue.toPlaybackItems(), startAt: queue.index)
        coordinator.requestPlay(current.toPlaybackItem())
        setCurrentSong(current)
        miniFallbackSong = current
        // b36-item10: recent + queue persistence runs on the store's
        // serial background queue — the switch no longer blocks on
        // disk I/O. Writes keep call order; the recent-change
        // notification fires on main after the write lands.
        MusicLibraryStore.addRecentAsync(current)
        MusicLibraryStore.saveQueueAsync(queue.toQueueData())
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

    /// One-shot resume seek, applied once the track has loaded
    /// (duration > 0). Shared by the launch-time resume (armed in
    /// init) and the home "继续听" tap (armed in play(resumeFrom:),
    /// H1). Drops the checkpoint when the song changed, the load
    /// failed, or the stored position is past the end.
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
        // b46: manual retry — re-ask every source for this song.
        clearResolveFailure(for: song)
        if queue.isCurrentTrack(song) {
            expectedItemId = song.identityKey
            startPlayback()
        } else if rebuildQueueFromContext() {
            // b45: the queue lost the playlist (the current song
            // is not in it) — the context rebuild above restored
            // it, so play from the restored queue instead of
            // collapsing to a single song.
            expectedItemId = song.identityKey
            startPlayback()
        } else {
            // b49fix2 P1-29: the queue lost the song and the
            // context cannot rebuild it — but the song itself is
            // right here, so play it as a single instead of
            // leaving a dead button with only a toast. The
            // single insert never touches the persisted context.
            playSinglePreservingContext(song)
        }
        hapticTick()
    }

    /// A manual play request for the current song failed (b38,
    /// item 1): the old behaviour left the player sitting on the
    /// dead song at 0:00 with only a 2 s toast. Instead, advance
    /// to the next queue song — the same skip the engine already
    /// does for auto-advance failures — bounded to one pass over
    /// the queue; with no next song (or the pass exhausted) show
    /// a persistent "无法播放" state with a retry button.
    private func handleCurrentSongFailed(song: MusicSong) {
        // b49sweep P1-3: same rebuild-first as next() / toggle /
        // retry — a collapsed queue has no next song to advance
        // to, while the recorded play context still holds the
        // full list. Rebuild before computing the step.
        if !queueCanServeSwitch || queueLostSongs {
            rebuildQueueFromContext()
        }
        let nextIndex = queue.nextIndex(mode: playMode, auto: false)
        if nextIndex >= 0, nextIndex != queue.index,
           consecutiveFailureSkips < max(1, queue.tracks.count) {
            consecutiveFailureSkips += 1
            loadFailed = false
            showToast("这首歌无法播放，已跳到下一首")
            playFromQueue(at: nextIndex)
            return
        }
        consecutiveFailureSkips = 0
        loadFailed = true
        showToast("无法播放：找不到可播放的地址")
    }

    /// Retry the current song from the player's "无法播放" state
    /// (b38, item 1): forces a fresh request through the same
    /// path as a fresh tap, so a transient failure recovers
    /// without leaving the player. (A plain toggle would no-op
    /// here: the engine holds no item after a failed open.)
    func retryCurrentSong() {
        guard let song = currentSong else { return }
        loadFailed = false
        // b46: manual retry — re-ask every source for this song.
        clearResolveFailure(for: song)
        if queue.isCurrentTrack(song) {
            expectedItemId = song.identityKey
            startPlayback()
        } else if rebuildQueueFromContext() {
            // b45: same context rebuild as togglePlayPauseOrRetry
            // — do not collapse the queue to one song when the
            // playlist can still be reloaded.
            expectedItemId = song.identityKey
            startPlayback()
        } else {
            // b49fix2 P1-29: same as togglePlayPauseOrRetry — play
            // the song as a single, never a dead button + toast.
            playSinglePreservingContext(song)
        }
        hapticTick()
    }

    /// Play one song as a single without touching the persisted
    /// context (b49fix2 P1-29): the song is inserted after the
    /// current one and played from there. The queue's other songs
    /// stay, the context stays — a one-off play must never clear
    /// or overwrite the playlist the user was in. The caller keeps
    /// its own haptic + failure-clearing.
    private func playSinglePreservingContext(_ song: MusicSong) {
        var tracks = queue.tracks
        let at = min(queue.index + 1, tracks.count)
        tracks.insert(song, at: at)
        queue = MusicQueue(tracks: tracks, index: at)
        expectedItemId = song.identityKey
        startPlayback()
    }

    func next() {
        // b41: the view-model queue is the source of truth — drive
        // the next song through it directly (playFromQueue re-syncs
        // the player's queue), so a play-next insert / removal can
        // never leave the button playing the player's stale next
        // song. The old path fell through to player.next() here,
        // which reads the player's queue. The dead end restarts
        // the current song (see restartCurrentSong): a manual tap
        // always answers.
        // b45: if the queue lost the playlist (single-song rebuild
        // or an outside item), reload it from the play context
        // first — a collapsed queue still "serves" a restart, so
        // the reload must run before the step, not only on .nothing.
        // b49: remember whether a rebuild was needed — a failed
        // rebuild below must show, not silently restart.
        let needsRebuild = !queueCanServeSwitch || queueLostSongs
        if needsRebuild {
            rebuildQueueFromContext()
        }
        // b48 (Control Center next, second failure — 0.0.1): the
        // gate above only fires when the current song is MISSING
        // from the queue. A collapsed 1-song queue — or the current
        // song sitting last in sequential / single mode — passes
        // it (queueCanServeSwitch is true: the queue contains the
        // current song), and nextStep then answers .restartCurrent
        // / .nothing while the recorded play context still holds
        // the full source list with a real next song. The tap
        // restarts the same song or silently does nothing. Retry
        // from the context before falling back to restart / no-op:
        // a rebuilt queue puts the current song back at its place
        // in its own list, so the step can find the successor.
        // When the context is gone or the song really is last,
        // the fallback below is unchanged.
        var step = queue.nextStep(mode: playMode)
        if step == .restartCurrent || step == .nothing {
            if rebuildQueueFromContext() {
                step = queue.nextStep(mode: playMode)
            }
        }
        if (step == .restartCurrent || step == .nothing),
           needsRebuild,
           (!queueCanServeSwitch || queueLostSongs) {
            // b49: the playlist data is gone — a rebuild was
            // needed but the context cannot reload the list
            // (snapshot missing, or the song is not in it). Say
            // so instead of silently restarting the same song
            // or doing nothing. A genuine end-of-list restart
            // (needsRebuild false) is unchanged.
            showToast("歌单数据找不到了")
            hapticTick()
            return
        }
        switch step {
        case .play(let index):
            // b46: manual switch — re-ask every source for the
            // target song (see clearResolveFailure).
            clearResolveFailure(for: queue.tracks[index])
            playFromQueue(at: index)
        case .restartCurrent:
            restartCurrentSong()
        case .nothing:
            break
        }
        hapticTick()
    }

    func previous() {
        // b41: same contract as next() — the live queue drives,
        // the dead end restarts the current song.
        // b45: same context reload as next().
        // b49: same visible state as next() when the rebuild fails.
        let needsRebuild = !queueCanServeSwitch || queueLostSongs
        if needsRebuild {
            rebuildQueueFromContext()
        }
        // b49sweep P0-2: same retry as next() (b48) — a collapsed
        // 1-song queue, or the current song sitting first in
        // sequential / single mode, passes the gate above
        // (queueCanServeSwitch is true: the queue contains the
        // current song), and prevStep then answers .restartCurrent
        // / .nothing while the recorded play context still holds
        // the full source list with a real previous song. Retry
        // from the context before falling back to restart / no-op.
        var step = queue.prevStep(mode: playMode)
        if step == .restartCurrent || step == .nothing {
            if rebuildQueueFromContext() {
                step = queue.prevStep(mode: playMode)
            }
        }
        if (step == .restartCurrent || step == .nothing),
           needsRebuild,
           (!queueCanServeSwitch || queueLostSongs) {
            showToast("歌单数据找不到了")
            hapticTick()
            return
        }
        switch step {
        case .play(let index):
            // b46: manual switch — re-ask every source for the
            // target song (see clearResolveFailure).
            clearResolveFailure(for: queue.tracks[index])
            playFromQueue(at: index)
        case .restartCurrent:
            restartCurrentSong()
        case .nothing:
            break
        }
        hapticTick()
    }

    /// Restart the current queue song from the beginning (b41
    /// manual next / previous dead end: a 1-song queue, or the
    /// ends in sequential / single mode). The engine never loaded
    /// a track: reopen the queue song (the old currentTrack-nil
    /// fallback). Otherwise seek to 0 and resume — no re-resolve,
    /// no queue change. Empty queue: nothing to restart.
    private func restartCurrentSong() {
        guard queue.current != nil else { return }
        if player.currentTrack == nil {
            playFromQueue(at: queue.index)
        } else {
            player.restartCurrentTrack()
        }
    }

    func cycleMode() {
        let next = playMode.next
        playMode = next
        MusicLibraryStore.setPlayModeCode(next.code)
        player.setPlayMode(next.toContract())
        hapticTick()
    }

    /// Transport shuffle button (b45-a, Coda 5-part transport):
    /// toggles shuffle on/off; turning it off returns to sequential.
    var isShuffleActive: Bool { playMode == .shuffle }

    func toggleShuffle() {
        let next: MusicQueueMode = playMode == .shuffle ? .sequential : .shuffle
        playMode = next
        MusicLibraryStore.setPlayModeCode(next.code)
        player.setPlayMode(next.toContract())
        hapticTick()
    }

    /// Transport repeat button (b45-a): cycles off → list loop →
    /// single loop → off. The shuffle state is untouched — the two
    /// buttons are independent, unlike the single cycleMode order.
    var repeatIcon: String {
        switch playMode {
        case .singleLoop: return "repeat.1"
        default: return "repeat"
        }
    }

    var isRepeatActive: Bool { playMode == .listLoop || playMode == .singleLoop }

    func cycleRepeat() {
        let next: MusicQueueMode
        switch playMode {
        case .listLoop: next = .singleLoop
        case .singleLoop: next = .sequential
        default: next = .listLoop
        }
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

    /// Set the target quality, factored out of setTargetQuality
    /// so the rollback path can restore the old quality without
    /// re-entering the re-resolve.
    private func applyTargetQuality(_ quality: AudioQuality) {
        coordinator.targetQuality = quality
        MusicLibraryStore.setTargetQualityCode(MusicLibraryStore.code(for: quality))
        // b45-a: after a quality switch the lyrics re-align to the
        // actual playback position (Coda §2.8).
        realignLyrics()
    }

    func setTargetQuality(_ quality: AudioQuality) {
        // b49sweep P2-12: a quality change used to do nothing to
        // the current song (next track only, footer text only).
        // When a song is playing, re-resolve it at the new target
        // now: save the position + old quality, stop first (the
        // playLocal B8 pattern — after the stop the engine holds
        // no track, so requestPlay takes the new-request path
        // instead of the same-track resume branch that returns
        // without re-resolving), then restart with the position
        // armed as a pending resume seek. A failed re-resolve
        // rolls back (see the failure sink). Paused / nothing
        // loaded: no re-resolve — the new target applies from
        // the next track, and the sheet says so.
        guard isPlaying, player.currentTrack != nil, let song = currentSong else {
            applyTargetQuality(quality)
            if currentSong != nil {
                showToast("下一首起生效")
            }
            return
        }
        let oldQuality = coordinator.targetQuality
        let positionSeconds = Int(position)
        applyTargetQuality(quality)
        qualityRollback = (quality: oldQuality, key: song.identityKey, seconds: positionSeconds, armedAt: Date())
        // b46: manual re-resolve — re-ask every source for this song.
        clearResolveFailure(for: song)
        player.stop()
        coordinator.stop()
        pendingResume = (key: song.identityKey, seconds: positionSeconds)
        expectedItemId = song.identityKey
        startPlayback()
    }

    /// Re-align the lyrics to the actual playback position after a
    /// scrub, an offset change, a source switch or a quality switch
    /// (Coda §2.8) — the active line is recomputed from the live
    /// position instead of waiting for the next position tick.
    func realignLyrics() {
        updateActiveLyric()
    }

    /// Lyric timing ±0.2 s quick step (Coda §2.8: adjustLyricsTiming
    /// by ±2 steps of 0.1 s). The Slider (±5000 ms, 100 ms steps)
    /// stays; these buttons are the quick path next to it.
    func adjustLyricOffset(byMs delta: Int) {
        lyricOffsetMs = MusicLyrics.clampOffsetMs(lyricOffsetMs + delta)
    }

    /// Restore the lyric timing to 0 for the current song (and
    /// delete its remembered per-song key).
    func resetLyricOffset() {
        lyricOffsetMs = 0
    }

    /// Share text for the current song (more-sheet ShareLink):
    /// "title - artist". No URL is invented — the app has no public
    /// song pages.
    var shareText: String {
        guard let song = currentSong else { return "HAo Studio" }
        if song.artist.isEmpty { return song.title }
        return "\(song.title) - \(song.artist)"
    }

    /// Heartbeat mode (b45-a, Coda §2.9 / §8.5): pick a random
    /// liked song as the seed, build the local heartbeat queue
    /// from the liked songs, and play it IN THIS player — no new
    /// page, no push. Toasts "已开启心动模式"; with no liked songs
    /// at all the mode is unavailable: "心动模式暂时不可用".
    func startHeartbeatMode() {
        let favourites = MusicLibraryStore.favSongs()
        guard !favourites.isEmpty, let seed = favourites.randomElement() else {
            showToast("心动模式暂时不可用")
            return
        }
        var list = MusicRadio.heartbeatQueue(favourites: favourites, seed: seed.identityKey)
        if let seedIndex = list.firstIndex(where: { $0.identityKey == seed.identityKey }) {
            list.remove(at: seedIndex)
        }
        list.insert(seed, at: 0)
        playFromQueue(at: 0, in: list)
        showToast("已开启心动模式")
    }

    /// Play from a queue supplied by the caller (heartbeat mode):
    /// same as playFromQueue(at:) but the queue itself is replaced
    /// first, so the seed song plays at its position in the new
    /// list instead of in the old queue. The generated list is a
    /// reloadable place too (b45): record the heartbeat context
    /// so a later 切歌 can rebuild it from the snapshot.
    private func playFromQueue(at index: Int, in tracks: [MusicSong]) {
        guard index >= 0 && index < tracks.count else { return }
        queue = MusicQueue(tracks: tracks, index: index)
        recordPlayContext(
            source: PlaySource(kind: .heartbeat, id: "heartbeat"),
            displayName: "心动模式", tracks: tracks)
        // b49sweep P1-4: a heartbeat start is a manual tap — the
        // seed song is re-asked of every source, like any other
        // manual play entry.
        playFromQueue(at: index, manual: true)
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
        // D3: stamp the seek so the position sink does not read
        // the jump that follows as a natural completion (lyric
        // taps and progress-bar drags both come through here).
        lastSeekAt = Date()
        player.seek(to: target) { [weak self] ok in
            guard let self = self else { return }
            if self.scrubSeconds == scrubbed { self.scrubSeconds = nil }
            if !ok { self.handleSeekFailed() }
            // b45-a: after a scrub the lyrics re-align to the actual
            // playback position (Coda §2.8).
            self.realignLyrics()
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
        // b36-item10: invalidate any in-flight background fav check
        // — its result predates this toggle.
        favCheckGeneration += 1
        isCurrentFav = MusicLibraryStore.toggleFav(song)
        syncNowPlayingLike()
        hapticTick()
    }

    /// Push the current favourite state to the Control Center like
    /// command (b45-a, §9.2): likeCommand.isActive follows whether
    /// the current song is liked, in both directions — the in-app
    /// heart and the Control Center like stay the same state.
    func syncNowPlayingLike() {
        player.refreshLikeCommand(isLiked: isCurrentFav)
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
        download(song: song)
    }

    /// Download any song (row menu "下载", build 36 item 12).
    /// Same body as downloadCurrent, parameterised so a row can
    /// download a song that isn't playing.
    func download(song: MusicSong) {
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
                        // b49fix3 P2-5: the downloaded file's path
                        // goes on the SONG too, not just the
                        // wrapper's filePath — toPlaybackItem()
                        // builds localFileURL from song.localPath,
                        // so a bare download.song.toPlaybackItem()
                        // used to come back nil and play over the
                        // network. Resolved (not just stored
                        // relative) to match withLocalFile() /
                        // playLocal(): the load side re-resolves a
                        // stale absolute path after a container
                        // move, and the wrapper filePath stays the
                        // repair source of truth.
                        var storedSong = song
                        if let relative = info.localRelativePath,
                           let url = LocalFileIndex.resolve(relative, subdir: DownloadEngine.downloadSubdir) {
                            storedSong.localPath = url.path
                        }
                        downloads.append(DownloadedSong(
                            song: storedSong,
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

    /// Retry the lyrics fetch (task book §3.3): the empty-lyrics
    /// view offers this when the fetch returned nothing on a
    /// platform that has a lyrics endpoint. A no-op without a
    /// current song; re-runs the same cache-then-fetch path, so
    /// a lyric cached since the failure loads without network.
    func retryLyrics() {
        guard let song = currentSong else { return }
        loadLyrics(for: song)
    }

    // MARK: - Lyrics

    /// The lyric source for a song (b49fix2 #16): the remembered
    /// override, or the song's own platform.
    func lyricSource(for song: MusicSong) -> MusicPlatform {
        if let code = lyricSourceOverrides[song.identityKey],
           let platform = MusicPlatform(code: code) {
            return platform
        }
        return song.platform
    }

    /// Disk-cache key for a song's lyrics (b49fix2 #16): the plain
    /// identityKey for the song's own platform (back-compatible
    /// with every entry cached before the switch existed), a
    /// suffixed key for an override source — otherwise switching
    /// sources would keep serving the first source's cached copy.
    private func lyricCacheKey(for song: MusicSong) -> String {
        let source = lyricSource(for: song)
        guard source != song.platform else { return song.identityKey }
        return song.identityKey + "|lyrics:" + source.rawValue
    }

    /// Switch the lyric source for the current song (b49fix2 #16):
    /// nil = follow the song ("跟随歌曲"). The choice is remembered
    /// per song, and the lyrics reload from the new source right
    /// away. A failed switch lands on the existing failed state
    /// with its retry (the view's "未能加载歌词"), never a silent
    /// blank screen.
    func setLyricSource(_ platform: MusicPlatform?) {
        guard let song = currentSong else { return }
        if let platform = platform {
            lyricSourceOverrides[song.identityKey] = platform.rawValue
        } else {
            lyricSourceOverrides.removeValue(forKey: song.identityKey)
        }
        UserDefaults.standard.set(lyricSourceOverrides, forKey: Self.lyricSourceOverridesKey)
        lyricSourceOverride = platform
        loadLyrics(for: song)
    }

    private func loadLyrics(for song: MusicSong, fetchIfMissing: Bool = true) {
        lyricsLoaded = false
        lyricsLoadFailed = false
        lyrics = []
        activeLyricIndex = -1
        // b36-item10: the lyrics-cache read used to run synchronously
        // on the main thread on every song switch; it now runs on
        // the store's serial background queue and publishes on main.
        // The network fetch below is unchanged, still guarded on
        // the song still being current.
        // b49fix2 #16: the cache key follows the lyric source —
        // an override source has its own cache entry, or the
        // switch would keep serving the first source's copy.
        let key = lyricCacheKey(for: song)
        let source = lyricSource(for: song)
        MusicLibraryStore.cachedLyricsInfoAsync(for: key) { [weak self] cached in
            guard let self = self else { return }
            guard self.currentSong?.identityKey == song.identityKey else { return }
            if let cached = cached {
                // b45-a: lyrics show the body only — credits /
                // copyright / a leading "title - artist" header are
                // filtered at display time (cached copies predate
                // the filter, so it runs here, not only on fetch).
                let body = MusicLyrics.filterBodyLines(
                    MusicLyrics.toContractLines(cached.lines),
                    title: song.title, artist: song.artist)
                // b49: a cached copy whose last body line is far
                // short of the song is a truncated fetch (an old
                // request that only returned the first half) — it
                // must NOT be served, or the later lyrics never
                // show (chen build 48). Fall through to a fresh
                // fetch instead. Duration unknown (0) skips the
                // check; empty lyrics stay "暂无歌词" without a
                // fetch, as before.
                // b49fix2 P2-42: a short-lived entry is a
                // KNOWN-truncated fetch (long instrumental outro)
                // — serve it, don't re-fetch on every play.
                let truncated: Bool = {
                    guard !cached.shortLived, !body.isEmpty, song.dur > 0,
                          let lastTime = body.map(\.time).max() else { return false }
                    return lastTime < Double(song.dur) * 0.8
                }()
                if !truncated {
                    self.lyrics = body
                    self.lyricsLoaded = true
                    self.updateActiveLyric()
                    return
                }
                // Truncated cache: fall through to fetch below.
            }
            guard fetchIfMissing else {
                self.lyricsLoaded = true
                return
            }
            let track = MusicTrack(
                id: song.songId, title: song.title, artist: song.artist,
                album: song.album, coverURL: URL(string: song.cover), duration: TimeInterval(song.dur),
                sourceID: song.platform.rawValue
            )
            // b49fix2 #16: the fetch follows the lyric source —
            // the song's own platform fetches by id, any other
            // platform searches it by title/artist first.
            let handleFetch: (Lyrics?) -> Void = { [weak self] result in
                guard let self = self else { return }
                guard let result = result else {
                    // b49fix2 P2-2: the nil branch had no
                    // current-song guard while the non-nil branch
                    // does — a stale fetch for song A arriving after
                    // the switch to song B set B's load state
                    // (failed / loaded) from A's empty answer.
                    guard self.currentSong?.identityKey == song.identityKey else { return }
                    // §3.3 retry: nothing came back. Only a
                    // platform with a lyrics endpoint counts as
                    // a failed load — kg / mg have no endpoint,
                    // so their empty state stays "暂无歌词".
                    // b49fix2 #16: the endpoint check follows the
                    // lyric SOURCE, not the song's platform — a
                    // Kugou song with a NetEase source that fails
                    // is a failed load, not an honest empty state.
                    self.lyricsLoadFailed = MusicLyricsAPI.hasLyricsEndpoint(source)
                    self.lyricsLoaded = true
                    return
                }
                // Only keep the result if the song is still current.
                guard self.currentSong?.identityKey == song.identityKey else { return }
                // b45-a: body-only filter (see the cached path above).
                // The identity gate runs in the API layer
                // (MusicLyricsAPI.gateLyrics, b45-h): the LRC's own
                // [ti:] / [ar:] tags are checked against this song
                // before the lines ever reach here — a mismatched
                // lyric arrives as an empty Lyrics, which shows an
                // honest "暂无歌词" below.
                let body = MusicLyrics.filterBodyLines(
                    result.lines, title: song.title, artist: song.artist)
                self.lyrics = body
                self.lyricsLoaded = true
                // A11: keep the translation in the cache too — the old
                // mapping dropped it, so a cached song never showed one.
                // b49fix2 P2-42: a truncated fetch is still cached —
                // under a 1 h short-lived marker — instead of being
                // re-fetched on every play (this supersedes the b49
                // no-cache rule: the marker, not the absence, is what
                // keeps a genuinely truncated fetch from poisoning
                // the cache — it expires, and the next play
                // re-fetches). The truncated lines still display.
                let truncated: Bool = {
                    guard !body.isEmpty, song.dur > 0,
                          let lastTime = body.map(\.time).max() else { return false }
                    return lastTime < Double(song.dur) * 0.8
                }()
                let stored = result.lines.map { StoredLyricLine(t: $0.time, text: $0.text, translation: $0.translation, romaji: $0.romaji) }
                MusicLibraryStore.putLyrics(stored, for: key, duration: TimeInterval(song.dur), shortLived: truncated)
                self.updateActiveLyric()
            }
            if source == song.platform {
                MusicLyricsAPI.shared.fetchLyrics(for: track, completion: handleFetch)
            } else {
                MusicLyricsAPI.shared.fetchLyricsFromPlatform(source, for: track, completion: handleFetch)
            }
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

    /// Play `song` right after the current track (row menu
    /// "下一首播放", build 36 item 12). Empty queue: play it now.
    /// Otherwise dedupe by identityKey and insert at the current
    /// index + 1, persist, toast. The native player's queue is
    /// driven track-by-track from this queue (see startPlayback),
    /// so no setQueueOnly call is needed here — same as
    /// removeFromQueue.
    func playNext(song: MusicSong) {
        if queue.isEmpty {
            play(song: song)
            return
        }
        if queue.isCurrentTrack(song) {
            showToast("正在播放")
            return
        }
        queue.insert(song, at: queue.index + 1)
        // b36-item10 (b49fix19 P2-8a: corrected — the queues
        // are NOT one queue any more): the queue write goes to
        // musicQueueWriteQueue while the switch path's recent
        // write goes to songSwitchIOQueue, so cross-file order
        // between them is not guaranteed. Queue writes still
        // serialise with each other — a switch's queue write
        // also lands on musicQueueWriteQueue — so this edit
        // can never be overwritten by a switch's still-pending
        // queue write. No consumer depends on the recent-vs-
        // queue order.
        MusicLibraryStore.saveQueueAsync(queue.toQueueData())
        // b49fix44 S33-P1-1: the context is the queue's mirror — an
        // insert it never sees is dropped by the next rebuild.
        syncPlayContextToQueue()
        // b47-playlogic: the player's flat queue is what
        // auto-advance reads — without a re-sync the inserted
        // song is invisible to it (Coda consumes its play-next
        // list first in advanceToNext; AudioStreaming inserts
        // into the same queue the player advances through).
        player.setQueueOnly(queue.toPlaybackItems(), startAt: queue.index)
        showToast("下一首播放")
    }

    /// Play the queue song at `index`. `manual` is true only for
    /// a deliberate tap — a queue-sheet row or a heartbeat start
    /// (b49sweep P1-4): like every other manual entry it clears
    /// the song's failure memory first, so a previously failed
    /// song is re-asked of every source. Auto-advance (and the
    /// failure-skip path) must NOT clear — the memory is what
    /// makes an auto-skip past a dead song instant (see
    /// clearResolveFailure).
    func playFromQueue(at index: Int, manual: Bool = false) {
        guard index >= 0 && index < queue.tracks.count else { return }
        let song = queue.tracks[index]
        if manual {
            clearResolveFailure(for: song)
        }
        queue.index = index
        expectedItemId = song.identityKey
        startPlayback()
    }

    // MARK: - Play context reload (b45: 切歌读歌单数据)

    /// Record the reloadable place a list play came from, and
    /// snapshot remote lists to disk (b45-F §9.3). Local lists
    /// (playlist / recent / favourites) reload live from the
    /// store, so their snapshot is only a fallback; remote lists
    /// (album / artist / chart / plaza / daily) have no store
    /// copy — without the snapshot the reload would have nothing
    /// to read once the owning view is gone. A nil source clears
    /// the context: a one-off play has no place.
    /// b46: the play context is persisted to disk (b45 kept it
    /// in memory only, so a relaunch lost the playlist and the
    /// next tap could only restart the same song). The snapshot
    /// already lives on disk; only the context itself was missing.
    private static let persistedContextKey = "hao.currentPlayContext"

    private func persistPlayContext() {
        guard let context = currentPlayContext,
              let data = try? JSONEncoder().encode(context) else {
            UserDefaults.standard.removeObject(forKey: Self.persistedContextKey)
            return
        }
        UserDefaults.standard.set(data, forKey: Self.persistedContextKey)
    }

    private func restorePersistedPlayContext() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistedContextKey),
              let context = try? JSONDecoder().decode(PlayContext.self, from: data),
              !context.songKeys.isEmpty else { return }
        currentPlayContext = context
    }

    /// Re-read the queue + favourites after a backup import
    /// replaced the store (b49fix2 P1-2). The imported queue
    /// becomes the live queue; the current song's star re-reads;
    /// the mini fallback follows. The player itself is left
    /// alone — if it was playing, the coordinator keeps the
    /// current item; the next 切歌 rebuilds from the imported
    /// context (the import restores the persisted context key
    /// too — the backup covers all UserDefaults values).
    private func reloadAfterBackupImport() {
        let saved = MusicLibraryStore.getQueue()
        if !saved.songs.isEmpty {
            queue = MusicQueue.fromQueueData(saved)
            currentSong = queue.current
            miniFallbackSong = queue.current
            if let song = currentSong {
                isCurrentFav = MusicLibraryStore.isFav(song)
            }
        } else {
            // The import had no queue: clear the stale one rather
            // than serving pre-import songs after the import.
            queue = MusicQueue(tracks: [], index: 0)
            currentSong = nil
            miniFallbackSong = nil
            isCurrentFav = false
        }
        restorePersistedPlayContext()
        player.setQueueOnly(queue.toPlaybackItems(), startAt: queue.index)
    }

    /// Local file for a playback item: the item's own file first,
    /// then the explicit download, then the audio cache (b49fix2
    /// P1-1). Pure lookup — no network, no resolve. The item id
    /// is the identityKey (`platform|songId`). The cache lookup
    /// accepts any served tier (the prefetch pattern — the
    /// requested tier is unknown here, and a wrong-tier hit is
    /// still a playable file whose badge reports the actual tier
    /// on open).
    static func localAudioURL(for item: PlaybackItem) -> URL? {
        if let fileURL = item.localFileURL { return fileURL }
        if let download = MusicLibraryStore.getDownloads().first(where: { $0.key == item.id }),
           let url = LocalFileIndex.resolve(download.filePath, subdir: DownloadEngine.downloadSubdir) {
            return url
        }
        guard let entry = HaoAudioCache.entry(trackID: item.id, requestedQuality: "", sourceIsNetease: false)
        else { return nil }
        return HaoAudioCache.localURL(for: entry)
    }

    private func recordPlayContext(source: PlaySource?, displayName: String?, tracks: [MusicSong]) {
        // b49sweep P1-6: a new play context starts a new FM /
        // heartbeat refill counter.
        fmRefillBatch = 0
        guard let source = source else {
            currentPlayContext = nil
            persistPlayContext()
            return
        }
        currentPlayContext = PlayContext(
            source: source,
            displayName: displayName ?? source.id,
            songKeys: tracks.map { $0.identityKey },
            lastPlayedAt: Date().timeIntervalSince1970)
        PlaylistSnapshotStore.save(PlaylistSnapshot(
            source: source, displayName: displayName ?? source.id, songs: tracks))
        persistPlayContext()
    }

    /// Keep the play context in step with the queue after a user edit
    /// (b49fix44 S33-P1-1): a remove / move / insert / clear that leaves
    /// the context stale is undone by the next rebuild — the removed
    /// song comes back, the insert is dropped, the reorder is reverted.
    /// Same three writes as `extendFMQueueIfNeeded` (keys + snapshot +
    /// persisted context); `recordPlayContext` is NOT used here — it
    /// resets the FM/heartbeat refill counter, which an edit must not
    /// do. No-op when there is no context (a one-off play never
    /// creates one).
    private func syncPlayContextToQueue() {
        guard var updated = currentPlayContext else { return }
        updated.songKeys = queue.tracks.map { $0.identityKey }
        updated.lastPlayedAt = Date().timeIntervalSince1970
        currentPlayContext = updated
        PlaylistSnapshotStore.save(PlaylistSnapshot(
            source: updated.source, displayName: updated.displayName, songs: queue.tracks))
        persistPlayContext()
    }

    /// The current context's songs, re-read from wherever that
    /// place lives now. Local lists read the live store (a rename
    /// or an edit is picked up); everything else reads the
    /// snapshot saved at play time. Nil when there is no context
    /// or the place has no songs left to read.
    private func reloadSongsFromContext() -> [MusicSong]? {
        guard let context = currentPlayContext else { return nil }
        switch context.source.kind {
        case .playlist:
            if let list = MusicLibraryStore.getLists().first(where: { $0.id == context.source.id }),
               !list.tracks.isEmpty {
                return list.tracks
            }
            return PlaylistSnapshotStore.load(source: context.source)?.musicSongs
        case .recent:
            let recent = MusicLibraryStore.getRecent()
            return recent.isEmpty ? nil : recent
        case .favourites:
            let favs = MusicLibraryStore.favSongs()
            return favs.isEmpty ? nil : favs
        case .local:
            // b46: local files are read live from the store — a
            // deleted file must not come back from the snapshot.
            let local = MusicLibraryStore.localSongs()
            return local.isEmpty ? nil : local
        case .downloads:
            // b46: explicit downloads, read live from the store.
            // b49fix2 P1-1: attach each file, so a rebuilt queue
            // plays from disk instead of re-resolving over the
            // network.
            let downloaded = MusicLibraryStore.getDownloads().map { Self.withLocalFile($0.song) }
            return downloaded.isEmpty ? nil : downloaded
        case .album, .artist, .chart, .daily, .heartbeat, .fm, .search, .discover:
            return PlaylistSnapshotStore.load(source: context.source)?.musicSongs
        }
    }

    /// Rebuild the in-memory queue from the current play context,
    /// keeping the playing song current. Returns false when there
    /// is no context, nothing to reload, or the playing song is
    /// not in the reloaded list — the caller then keeps the old
    /// behaviour (restart / nothing). The rebuild is a pure queue
    /// swap: no playback call, no resolve — the caller re-runs
    /// its step against the rebuilt queue.
    @discardableResult
    private func rebuildQueueFromContext() -> Bool {
        guard var songs = reloadSongsFromContext(), !songs.isEmpty,
              let song = currentSong ?? queue.current
        else { return false }
        // b49: same entry dedupe as play() — a reloaded list can
        // carry the same song twice (merged results / playlist).
        songs = MusicQueue.deduped(songs)
        // b49fix44 S33-P1-1: the context's keys are the queue's
        // mirror — every user edit (remove / move / insert / clear)
        // syncs them (see syncPlayContextToQueue) — so filter +
        // order the reloaded songs by the keys. Without this, a
        // live-store source (playlist / recent / favourites /
        // local / downloads) reloads the whole list and a removed
        // song comes back on the next 切歌; a play-next insert (in
        // the keys + snapshot, not in the list) is dropped the same
        // way. The snapshot is the lookup for keyed songs the live
        // list no longer has (the live list wins on conflict — it
        // carries fresher info). Songs the keys name but no source
        // has any more fall out; songs added to the list
        // mid-playback do not join the queue — the queue is the
        // source of truth once playback starts, same as the
        // snapshot kinds already froze it at play time.
        if let context = currentPlayContext {
            let snapshotSongs = PlaylistSnapshotStore.load(source: context.source)?.musicSongs ?? []
            var byKey: [String: MusicSong] = [:]
            for song in snapshotSongs + songs { byKey[song.identityKey] = song }
            songs = context.songKeys.compactMap { byKey[$0] }
            guard !songs.isEmpty else { return false }
        }
        guard let index = songs.firstIndex(where: { $0.identityKey == song.identityKey })
        else { return false }
        queue = MusicQueue(tracks: songs, index: index)
        // b49fix2 P2-45: the rebuild deduped the list — re-record
        // the deduped keys (and the snapshot) so the context agrees
        // with the queue, or the counts stay mismatched forever and
        // every next()/previous() at the list's end shows a false
        // "歌单数据找不到了". recordPlayContext is NOT used here:
        // it resets the FM/heartbeat refill counter, which a
        // rebuild must not do (see extendFMQueueIfNeeded above).
        if var updated = currentPlayContext {
            updated.songKeys = songs.map { $0.identityKey }
            updated.lastPlayedAt = Date().timeIntervalSince1970
            currentPlayContext = updated
        }
        if let context = currentPlayContext {
            PlaylistSnapshotStore.save(PlaylistSnapshot(
                source: context.source, displayName: context.displayName, songs: songs))
        }
        persistPlayContext()
        return true
    }

    /// True when the queue can serve a manual switch right now:
    /// it holds songs, has a current song, and the playing song
    /// is actually in it. False is the "切歌读不到歌单数据"
    /// state — the queue was rebuilt to one song, or an outside
    /// item replaced the current song without rewriting it.
    private var queueCanServeSwitch: Bool {
        guard !queue.isEmpty, queue.current != nil else { return false }
        guard let song = currentSong ?? queue.current else { return false }
        return queue.tracks.contains(where: { $0.identityKey == song.identityKey })
    }

    /// True when the queue holds fewer songs than the play
    /// context promises — the queue was collapsed to one song
    /// (the retry/toggle fallback) while the playlist still has
    /// more. A collapsed queue still "serves" a restart, so
    /// queueCanServeSwitch alone cannot catch it; this is the
    /// check that does. A queue the user edited (insert/remove)
    /// can also read short; a reload then re-syncs to the
    /// playlist, which is the source of truth.
    private var queueLostSongs: Bool {
        guard let context = currentPlayContext else { return false }
        return queue.tracks.count < context.songKeys.count
    }

    /// Drag-reorder the queue (b45-a, Coda §2.9: List + .onMove,
    /// constant-active edit mode). The current song keeps its
    /// index by identity, so a reorder never retargets playback;
    /// the player is driven track-by-track from this queue, so no
    /// player re-sync is needed for a reorder of upcoming songs.
    func moveQueue(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty else { return }
        let currentKey = queue.current?.identityKey
        var tracks = queue.tracks
        let moving = source.map { tracks[$0] }
        for index in source.sorted(by: >) {
            tracks.remove(at: index)
        }
        let dest = min(max(0, destination), tracks.count)
        tracks.insert(contentsOf: moving, at: dest)
        let newIndex = currentKey.flatMap { key in
            tracks.firstIndex(where: { $0.identityKey == key })
        } ?? queue.index
        queue = MusicQueue(tracks: tracks, index: min(newIndex, max(0, tracks.count - 1)))
        MusicLibraryStore.saveQueueAsync(queue.toQueueData())
        // b49fix44 S33-P1-1: the context is the queue's mirror — a
        // reorder it never sees is reverted by the next rebuild.
        syncPlayContextToQueue()
        // b47-playlogic: same re-sync as playNext — a reorder
        // the player never sees leaves auto-advance following
        // the old order.
        player.setQueueOnly(queue.toPlaybackItems(), startAt: queue.index)
    }

    func removeFromQueue(at index: Int) {
        let wasCurrent = index == queue.index
        queue.remove(at: index)
        MusicLibraryStore.saveQueueAsync(queue.toQueueData())
        // b49fix44 S33-P1-1: the context is the queue's mirror — a
        // removal it never sees is undone by the next rebuild and
        // the deleted song comes back on the next 切歌.
        syncPlayContextToQueue()
        if wasCurrent {
            // L1 (build 36, item 8): deleting the playing song
            // used to stop playback and only DISPLAY the next song
            // — the queue moved on but the music stopped. Play the
            // song now at the index instead (after the removal the
            // index points at the next song, or the previous one
            // when the last song was deleted); only an emptied
            // queue stops and clears the state.
            if queue.current != nil {
                playFromQueue(at: queue.index)
            } else {
                player.pause()
                coordinator.stop()
                // A7: route through a full clear — assigning
                // currentSong directly left the lyrics, the
                // favourite star and the quality badge on the
                // deleted song.
                clearCurrentSongState()
            }
            miniFallbackSong = queue.current
        } else {
            // b47-playlogic: same re-sync as playNext — the
            // removed song must leave the player's flat queue
            // too, or auto-advance plays a song the user deleted.
            player.setQueueOnly(queue.toPlaybackItems(), startAt: queue.index)
        }
    }

    func clearQueue() {
        queue.clear()
        MusicLibraryStore.saveQueueAsync(queue.toQueueData())
        // b49fix44 S33-P1-1: the context is the queue's mirror — a
        // clear it never sees is undone by the next rebuild (and by
        // the relaunch restore). Empty keys persist; the restore
        // ignores them, so the cleared list stays cleared.
        syncPlayContextToQueue()
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
        lyricsLoadFailed = false
        activeLyricIndex = -1
        // b36-item10: drop any in-flight background fav check for
        // the removed song — it must not re-light the star.
        favCheckGeneration += 1
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

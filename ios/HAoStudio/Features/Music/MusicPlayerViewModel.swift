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
    private var toastTimer: Timer?
    private var expectedItemId: String?
    /// Consecutive failure-driven skips (b38, item 1): bounds the
    /// auto-advance on a failed manual request to one pass over
    /// the queue, so a list of all-dead songs (or a looping mode)
    /// stops on the persistent error instead of cycling forever.
    /// Reset whenever a track really starts (duration > 0) and
    /// when the pass is exhausted.
    private var consecutiveFailureSkips = 0
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
        self.playMode = MusicQueueMode.fromCode(MusicLibraryStore.playModeCode())
        self.playbackSpeed = MusicLibraryStore.speed()
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
                // b45-a: the restored song reads its own remembered
                // lyric offset back, same as a live song switch.
                lyricOffsetMs = MusicLyrics.perSongOffsetMs(for: song.identityKey)
                    ?? MusicLibraryStore.lyricOffsetMs()
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
        // Favourite sync (build 36, item 12): a toggle from any
        // row or card posts haoMusicFavChanged — refresh the
        // current song's star so the full player never shows a
        // stale favourite state while the song is playing.
        _ = NotificationCenter.default.addObserver(forName: .haoMusicFavChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, let song = self.currentSong else { return }
            // b36-item10: invalidate any in-flight background fav
            // check — its result predates this toggle.
            self.favCheckGeneration += 1
            self.isCurrentFav = MusicLibraryStore.isFav(song)
            self.syncNowPlayingLike()
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
    func play(song: MusicSong, in tracks: [MusicSong]? = nil, startAt: Int? = nil, resumeFrom: Double? = nil, source: PlaySource? = nil, sourceDisplayName: String? = nil) {
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
            let start = startAt ?? tracks.firstIndex(where: { $0.identityKey == song.identityKey }) ?? 0
            queue = MusicQueue(tracks: tracks, index: min(max(0, start), max(0, tracks.count - 1)))
            recordPlayContext(source: source, displayName: sourceDisplayName, tracks: tracks)
        } else {
            queue = MusicQueue(tracks: [song], index: 0)
            currentPlayContext = nil
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
            play(song: song)
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
            play(song: song)
        }
        hapticTick()
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
        if !queueCanServeSwitch || queueLostSongs {
            rebuildQueueFromContext()
        }
        switch queue.nextStep(mode: playMode) {
        case .play(let index):
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
        if !queueCanServeSwitch || queueLostSongs {
            rebuildQueueFromContext()
        }
        switch queue.prevStep(mode: playMode) {
        case .play(let index):
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

    func setTargetQuality(_ quality: AudioQuality) {
        coordinator.targetQuality = quality
        MusicLibraryStore.setTargetQualityCode(MusicLibraryStore.code(for: quality))
        // b45-a: after a quality switch the lyrics re-align to the
        // actual playback position (Coda §2.8).
        realignLyrics()
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
        playFromQueue(at: index)
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
        let key = song.identityKey
        MusicLibraryStore.cachedLyricsAsync(for: key) { [weak self] cached in
            guard let self = self else { return }
            guard self.currentSong?.identityKey == key else { return }
            if let cached = cached {
                // b45-a: lyrics show the body only — credits /
                // copyright / a leading "title - artist" header are
                // filtered at display time (cached copies predate
                // the filter, so it runs here, not only on fetch).
                self.lyrics = MusicLyrics.filterBodyLines(
                    MusicLyrics.toContractLines(cached),
                    title: song.title, artist: song.artist)
                self.lyricsLoaded = true
                self.updateActiveLyric()
                return
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
            MusicLyricsAPI.shared.fetchLyrics(for: track) { [weak self] result in
                guard let self = self else { return }
                guard let result = result else {
                    // §3.3 retry: nothing came back. Only a
                    // platform with a lyrics endpoint counts as
                    // a failed load — kg / mg have no endpoint,
                    // so their empty state stays "暂无歌词".
                    self.lyricsLoadFailed = MusicLyricsAPI.hasLyricsEndpoint(song.platform)
                    self.lyricsLoaded = true
                    return
                }
                // Only keep the result if the song is still current.
                guard self.currentSong?.identityKey == song.identityKey else { return }
                // b45-a: body-only filter (see the cached path above).
                // The identity gate itself (MusicLyrics
                // .lyricsIdentityMatches) cannot run here: Lyrics
                // carries no candidate title/artist/duration, so the
                // fetch-side check belongs to the API layer — the
                // helpers ship in MusicLyrics.swift for that layer.
                self.lyrics = MusicLyrics.filterBodyLines(
                    result.lines, title: song.title, artist: song.artist)
                self.lyricsLoaded = true
                // A11: keep the translation in the cache too — the old
                // mapping dropped it, so a cached song never showed one.
                let stored = result.lines.map { StoredLyricLine(t: $0.time, text: $0.text, translation: $0.translation) }
                MusicLibraryStore.putLyrics(stored, for: song.identityKey)
                self.updateActiveLyric()
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
        // b36-item10: same serial background queue as the switch
        // path, so this edit can never be overwritten by a switch's
        // still-pending queue write.
        MusicLibraryStore.saveQueueAsync(queue.toQueueData())
        showToast("下一首播放")
    }

    func playFromQueue(at index: Int) {
        guard index >= 0 && index < queue.tracks.count else { return }
        let song = queue.tracks[index]
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
    private func recordPlayContext(source: PlaySource?, displayName: String?, tracks: [MusicSong]) {
        guard let source = source else {
            currentPlayContext = nil
            return
        }
        currentPlayContext = PlayContext(
            source: source,
            displayName: displayName ?? source.id,
            songKeys: tracks.map { $0.identityKey },
            lastPlayedAt: Date().timeIntervalSince1970)
        PlaylistSnapshotStore.save(PlaylistSnapshot(
            source: source, displayName: displayName ?? source.id, songs: tracks))
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
        case .album, .artist, .chart, .daily, .heartbeat, .fm:
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
        guard let songs = reloadSongsFromContext(), !songs.isEmpty,
              let song = currentSong ?? queue.current,
              let index = songs.firstIndex(where: { $0.identityKey == song.identityKey })
        else { return false }
        queue = MusicQueue(tracks: songs, index: index)
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
    }

    func removeFromQueue(at index: Int) {
        let wasCurrent = index == queue.index
        queue.remove(at: index)
        MusicLibraryStore.saveQueueAsync(queue.toQueueData())
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
        }
    }

    func clearQueue() {
        queue.clear()
        MusicLibraryStore.saveQueueAsync(queue.toQueueData())
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

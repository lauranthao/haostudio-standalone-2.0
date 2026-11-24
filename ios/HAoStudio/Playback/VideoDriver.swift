// HAo Studio 2.0 — VOD driver (S3, leg A).
//
// Implements `VideoPlaybackDriver` (see PlaybackCoordinator):
// episode/line state, serial URL resolution, the engine ladder
// (MPV / IJK / AVPlayer via PlayerKernel), verified seek, the
// position watchdog (4 s warn / 12 s fail), the software-decode
// fallback (4K HEVC / Dolby Vision -> AVPlayer, same position),
// and a release path that never drops the breakpoint.
//
// URL resolution lives HERE, never in the coordinator: the driver
// owns `playURLResolver` (C leg injects B leg's CmsClient in
// HAoStudioApp) and `resolveURL` closes over the current
// detail/line/episode + that resolver. The coordinator only owns
// mutual exclusion (music stops when VOD starts) and current-item
// bookkeeping.
//
// Rules carried from the music player (same numbers, same shape):
// - Open timeout, per attempt (build 36, item 14, G-J; was 10 s
//   for the whole ladder, P0-04): each ladder attempt gets its
//   own 10 s budget, the whole open is capped at 25 s. A timeout
//   is a stream error, the load is dropped and the driver falls
//   to the next candidate.
// - Seek uses completion + read-back verification; a failed seek
//   reports false and the driver republishes the real position so
//   the UI rolls the progress bar back (never a lie).
// - Watchdog 4 s warn / 12 s fail (P0-06). A track frozen at its
//   own end advances instead of failing.
// - One fallback re-resolution per request (at most 2 URLs): the
//   failed URL goes into `excluding` and is never tried again.
// - VOD has NO quality selector (rule 3): one play URL per
//   episode, no quality tiers, no fake button. Any quality UI in
//   the VOD page is a bug, not a feature.
//
// Release (P0-08): the view calls `release(completion:)` on exit
// — timers cancelled, breakpoint saved, backend shut down, and
// the completion fires only after the shutdown returns. `deinit`
// shuts down synchronously as a safety net but cannot wait; the
// view MUST call release first, or the breakpoint can be lost.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation
import AVFoundation
import SwiftUI
import UIKit

// MARK: - Stall watchdog

/// Position watchdog (P0-06, VOD twin of MusicStallWatchdog).
/// Pure logic with an injectable clock so tests never wait real
/// seconds. The driver ticks it every 0.5 s with the visible
/// position/duration: any movement restarts the clock. Warns once
/// per stall episode at 4 s, fails at 12 s. An episode frozen at
/// its own end (missed completion event) reports `.atEnd` instead
/// of `.failed`, so the driver advances instead of treating it as
/// a failure.
final class VodStallWatchdog {
    enum Event: Equatable {
        case none
        case warn
        case failed
        case atEnd
    }

    static let warnAfter: TimeInterval = 4
    static let failAfter: TimeInterval = 12

    /// Injectable clock. Production uses the wall clock; tests drive it.
    var now: () -> Date = { Date() }

    private var lastProgressAt: Date?
    private var lastPosition: TimeInterval = 0
    private var lastDuration: TimeInterval = 0
    private var progressSeen = false
    private var warned = false

    func resetForNewEpisode() {
        lastProgressAt = now()
        lastPosition = 0
        lastDuration = 0
        progressSeen = false
        warned = false
    }

    func noteBaseline() {
        lastProgressAt = now()
    }

    func tick(position: TimeInterval, duration: TimeInterval, isPlaying: Bool) -> Event {
        if position != lastPosition || duration != lastDuration {
            lastPosition = position
            lastDuration = duration
            lastProgressAt = now()
            if position > 0 || duration > 0 { progressSeen = true }
            warned = false
            return .none
        }
        guard isPlaying, let since = lastProgressAt else { return .none }
        let stalledFor = now().timeIntervalSince(since)
        if stalledFor >= VodStallWatchdog.failAfter {
            lastProgressAt = nil
            if duration > 0 && position >= duration {
                return .atEnd
            }
            return .failed
        }
        if stalledFor >= VodStallWatchdog.warnAfter && !warned {
            warned = true
            return .warn
        }
        return .none
    }
}

// MARK: - VOD driver

/// VOD driver: one episode at a time, engines behind
/// VideoPlayerBackend, resolution through `playURLResolver`.
final class VideoDriver: NSObject, ObservableObject, VideoPlaybackDriver {
    // Published state. Names are fixed: the UI leg reads these.
    @Published private(set) var currentEpisode: PlaybackItem?
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentEngine: VideoEngine?
    @Published private(set) var diagnostics: VideoPlaybackDiagnostics = .empty
    @Published private(set) var stallWarning: Bool = false
    @Published private(set) var isLoading: Bool = false
    /// True when the most recent open request failed outright (no
    /// playable URL, open timeout, watchdog stall, backend error).
    /// The player page shows the failure + a retry from this; a
    /// new open request clears it. Never set by stop(): the
    /// failure callbacks below run after stop() and set it there.
    @Published private(set) var lastOpenFailed: Bool = false
    /// The specific reason the most recent open failed (build 36,
    /// item 14, G-K) — the failure card shows `lastFailure?`.
    /// displayLine instead of a generic "加载失败". Nil while
    /// nothing has failed (or while a new open is in flight).
    @Published private(set) var lastFailure: VideoPlaybackFailure?
    /// Audio / subtitle tracks of the running backend (build 36,
    /// item 14, G-F): published when the backend reports its
    /// track list; the settings sheet pickers read these. Empty
    /// until the backend publishes (IJK never publishes — it has
    /// no track API — so the rows stay hidden there).
    @Published private(set) var audioTracks: [VodTrackInfo] = []
    @Published private(set) var subtitleTracks: [VodTrackInfo] = []
    /// Selected track, as a position in the published list (-1 =
    /// default/auto for audio, -1 = no explicit pick for
    /// subtitles — the backend's auto-select is left alone until
    /// the user picks). The view model pushes the stored picks
    /// here; the driver re-applies them at every open.
    private(set) var currentAudioTrackIndex: Int = -1
    private(set) var currentSubtitleTrackIndex: Int = -1

    // Driver wiring, set by the coordinator (callbacks) and by
    // HAoStudioApp (resolver, C leg).
    var resolveURL: ((PlaybackItem, [URL], @escaping (URL?) -> Void) -> Void)?
    var onEpisodeStarted: ((PlaybackItem) -> Void)?
    var onEpisodeFailed: ((PlaybackItem, MusicPlayerError) -> Void)?
    /// Fired when an episode plays to its end and there is no next
    /// episode (auto-advance found nothing to play).
    var onEpisodeEnded: ((PlaybackItem) -> Void)?
    /// Fired with the breakpoint whenever playback stops (pause is
    /// not a stop — only stop / release / failure save one), so
    /// VideoLibraryStore (C leg) can persist resume. Never nil when
    /// an episode was playing: a missing breakpoint is a lost
    /// resume, not an empty state.
    var onBreakpointSaved: ((ResumeInfo) -> Void)?

    /// The URL resolver (B leg's CmsClient). Injected by
    /// HAoStudioApp; nil until then, and playback refuses without
    /// it (no resolver -> no URL -> no fake playback).
    var playURLResolver: VideoPlayURLResolver?

    /// Per-attempt budget / whole-open cap factor, shared with
    /// LiveDriver through OpenTimeoutPolicy (build 36, item 8,
    /// smell 1): one home for the numbers, so a cap change never
    /// needs a lockstep edit in two drivers. The statics stay so
    /// existing call sites keep their names; the values live in
    /// the policy. A healthy first engine still opens in ~1 s;
    /// the cap only binds when engines hang.
    static let openTimeout: TimeInterval = OpenTimeoutPolicy.perAttemptTimeout
    static let openTotalTimeoutFactor: Double = OpenTimeoutPolicy.totalTimeoutFactor
    static let seekTolerance: TimeInterval = 2.0

    /// Test seam: open timeout seconds. Production is 10; tests set
    /// a short value so the timeout path runs without waiting.
    var openTimeoutInterval: TimeInterval = VideoDriver.openTimeout

    /// Test seam: backend factory. Production builds real engines;
    /// tests inject a fake backend.
    var makeBackend: (VideoEngine) -> VideoPlayerBackend = { PlayerKernel.makeBackend(engine: $0) }

    /// Auto-advance to the next episode in the same line when one
    /// ends. Default on (Flutter behaviour); C leg binds it to the
    /// setting when the settings UI lands.
    var autoAdvanceToNextEpisode = true

    /// DV-P8 downgrade switch (SettingsStore.dvP8Downgrade,
    /// default true). The view model pushes the live setting
    /// before each open; `open()` reads it at candidate time, so
    /// a mid-play toggle only takes effect through
    /// `reopenAtCurrentPosition` (AVPlayer-backed P8 streams).
    var dvP8Downgrade: Bool = true

    /// Emby playback reporting (build 36, item 13): start /
    /// progress / stop + played to the configured Emby server.
    /// A no-op for non-Emby URLs and when no server is
    /// configured. Injectable so tests can substitute a
    /// recording reporter.
    var embyReporter = EmbyPlaybackReporter()

    /// Token for the Emby-config-change observer (init). Removed
    /// in deinit.
    private var embyConfigChangedObserver: NSObjectProtocol?

    /// Settings storage for the "与其他音频同时播放" switch
    /// (test seam: tests point this at an isolated suite;
    /// production is `.standard`). The switch reads through the
    /// SettingsStore key — no second key. The audio session is
    /// global: an open used to reset the category with no
    /// options, wiping the music player's mix flag (Flutter's
    /// just_audio never resets the category, so it never had
    /// this bug). The open now re-applies the stored switch.
    var defaults: UserDefaults = .standard

    /// Audio-only state (SettingsStore.audioOnlyBackground,
    /// applied on background only). Remembered across backend
    /// swaps, so an auto-advance while backgrounded stays
    /// audio-only; cleared on stop / release. A backend without
    /// the capability (AVPlayer/IJK) no-ops — their audio keeps
    /// playing in background natively.
    private(set) var isAudioOnly: Bool = false

    /// Resolved enhancement branch, kept for the next open.
    /// Applied live to the running backend and re-applied after
    /// every open (ladder swap / reopen), so a toggle never waits
    /// for the next episode. Nil = no branch (mpv defaults).
    private(set) var currentEnhancement: VodEnhancementBranch?

    /// Dialogue boost switch, kept for the next open. Same live
    /// + re-apply discipline as the enhancement branch: the
    /// view model pushes the live setting, the driver forwards
    /// it to a capable backend (MPV only), and a toggle made
    /// before the backend existed lands at open instead of
    /// waiting for the next episode.
    private(set) var currentDialogueBoost: Bool = false

    /// Resolved subtitle appearance, kept for the next open.
    /// Same live + re-apply discipline as the enhancement branch.
    private(set) var currentSubtitleAppearance: VodSubtitleAppearance = .default

    let watchdog = VodStallWatchdog()

    /// Current detail/line/episode context. Set by `configure`
    /// (C leg) before `play(item:)`; `resolveURL` closes over it.
    private(set) var currentDetail: VideoDetail?
    private(set) var currentLine: PlayLine?
    private(set) var currentEpisodeIndex: Int = 0
    /// Position to resume from on the next open (seconds, 0 = start).
    private(set) var startPosition: Double = 0

    private var backend: VideoPlayerBackend?
    private var currentURL: URL?
    private var currentRate: Double?
    /// Last picture fit pushed (F2, build 36 item 9 — mirrors
    /// currentRate): a fresh backend starts at .resizeAspect,
    /// so a ladder swap / reopen must re-apply the fit or it
    /// silently resets to 适应 even though the sheet state
    /// still holds the user's pick.
    private var currentFit: VideoFit?
    /// The ladder for the open in flight. A ladder is a local in
    /// `open()` — without this strong hold nothing would retain it
    /// once `open()` returns (its attempt completion captures it
    /// weakly), the run would never complete, and the open would
    /// hang until the 10 s timeout. Cleared when the run finishes
    /// or a newer open supersedes it.
    private var activeLadder: VideoRecoveryLadder?
    private var generation: Int = 0
    private var pendingItem: PlaybackItem?
    private var playRequested: Bool = false
    private var stallFailed: Bool = false
    private var fellBackForSoftwareDecode = false

    private var openTimeoutWork: DispatchWorkItem?
    private var positionTimer: Timer?
    private var fpsSampler = VideoFpsSampler()
    private var lastFps: Double = 0
    private var lastDroppedFrames: Int = 0
    /// (Build 36, item 14, G-E) Mid-play fallback state: whether
    /// the next-engine retry was already used for this episode,
    /// whether the running backend ever prepared (only a prepared
    /// backend's failure is a mid-play failure — open-time
    /// failures belong to the ladder), and which engines already
    /// failed (never retried for this episode). Reset on a new
    /// episode and after 30 s of healthy playback.
    private var midPlayFallbackUsed = false
    private var preparedSeenForEpisode = false
    private var failedEnginesForEpisode: [VideoEngine] = []
    /// Healthy-playback accumulation for the 30 s reset above:
    /// seconds of continuous position progress (0.5 s per tick
    /// that advances). Any stall resets it to 0.
    private var healthyPlaybackAccumulated: Double = 0
    private var lastHealthyPosition: Double = 0
    /// (Build 36, item 14, G-H) Whether the Emby transcode last
    /// resort was already tried for this request (one attempt).
    private var transcodeAttemptedForRequest = false
    /// (Build 36, item 14, G-J) Whether any ladder attempt of the
    /// open in flight timed out on its own budget (a hanging
    /// backend) — the open then reports `.timeout`, not
    /// `.loadFailed`.
    private var openAttemptTimedOut = false
    /// Engines the open ladder attempted, in try order (G-K:
    /// recorded into the failure + diagnostics).
    private var lastAttemptedEngines: [VideoEngine] = []

    override init() {
        super.init()
        // Resolution lives inside this driver: the closure reads
        // the CURRENT detail/line/episode (set by configure) and
        // asks playURLResolver, passing `excluding` straight
        // through — a failed URL is never handed out twice.
        resolveURL = { [weak self] item, excluding, completion in
            guard let self = self else {
                completion(nil)
                return
            }
            guard let resolver = self.playURLResolver,
                  let detail = self.currentDetail,
                  let line = self.currentLine,
                  let episode = line.episode(at: self.currentEpisodeIndex) else {
                completion(nil)
                return
            }
            // The item must be the episode this context describes;
            // a stale resolve for a previous episode answers nil
            // instead of opening the wrong episode's URL.
            guard item.id == VideoResumeKey.episodeId(
                title: detail.item.title,
                year: detail.item.year,
                episodeName: episode.name
            ) else {
                completion(nil)
                return
            }
            resolver.resolvePlayURL(detail: detail, episode: episode, line: line, excluding: excluding) { url in
                DispatchQueue.main.async { completion(url) }
            }
        }
        fpsSampler.onSample = { [weak self] fps, dropped in
            guard let self = self else { return }
            self.lastFps = fps
            self.lastDroppedFrames = dropped
            self.updateDiagnostics()
        }
        // An Emby server change (saved / cleared in Settings)
        // ends any open reporter session: the reporter holds a
        // client built from the old config and would keep
        // reporting progress to the old server. noteStopped is a
        // no-op with no session, so this is safe when idle.
        embyConfigChangedObserver = NotificationCenter.default.addObserver(
            forName: .haoEmbyConfigChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.embyReporter.noteStopped(positionSeconds: self.position)
        }
    }

    deinit {
        positionTimer?.invalidate()
        openTimeoutWork?.cancel()
        fpsSampler.stop()
        backend?.shutdown()
        if let observer = embyConfigChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Helpers

    private func ensureMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    /// Recompute the published playing flag from real backend state.
    /// True only while video is really playing, or while a play was
    /// requested and an item is loaded but still buffering. False
    /// the moment the watchdog fails, the item fails, or playback
    /// is paused or stopped: never report playing for a dead stream.
    private func recomputePlayingState() {
        let sounding = backend?.isPlaying ?? false
        let buffering = playRequested && backend != nil && !stallFailed
        isPlaying = (sounding || buffering) && !stallFailed && currentEpisode != nil
    }

    private func updateDiagnostics() {
        guard let backend = backend, let engine = currentEngine else { return }
        diagnostics = VideoPlaybackDiagnostics(
            engine: engine,
            hardwareDecode: backend.hardwareDecode,
            rejectedOptionNames: backend.rejectedOptionNames,
            fps: lastFps,
            droppedFrames: lastDroppedFrames,
            facts: currentURLFacts(),
            fellBackForSoftwareDecode: fellBackForSoftwareDecode,
            attemptedEngines: lastAttemptedEngines
        )
    }

    /// Human format summary for a failure, e.g. "MKV · AV1 ·
    /// TrueHD" — unknown parts omitted, "" when nothing is
    /// known (build 36, item 14, G-K).
    private func formatDescriptionForFailure() -> String {
        guard let url = currentURL else { return "" }
        var parts: [String] = []
        let format = videoFormatOf(url: url, declaredFormat: nil)
        if format != .unknown { parts.append(format.rawValue.uppercased()) }
        if let facts = currentURLFacts() {
            if let vcodec = facts.videoCodec, !vcodec.isEmpty { parts.append(vcodec.uppercased()) }
            if let acodec = facts.audioCodec, !acodec.isEmpty { parts.append(acodec.uppercased()) }
        }
        return parts.joined(separator: " · ")
    }

    /// Record the specific failure for the card + diagnostics.
    /// `hadURL` is false only when no URL could be resolved at
    /// all (`.noPlayableURL`); the format description is then
    /// empty (a stale URL from a previous episode must never
    /// leak into this episode's failure).
    private func recordFailure(error: MusicPlayerError, hadURL: Bool) {
        lastOpenFailed = true
        let timedOut = error == .timeout
        let candidatesEmpty: Bool
        if let url = currentURL {
            candidatesEmpty = PlayerKernel.candidatesFor(url: url, dvDowngradeToHdr: dvP8Downgrade).isEmpty
        } else {
            candidatesEmpty = false
        }
        let description = hadURL ? formatDescriptionForFailure() : ""
        lastFailure = VideoPlaybackFailure(
            reason: VideoPlaybackFailure.reason(
                candidatesWereEmpty: candidatesEmpty, timedOut: timedOut,
                hadURL: hadURL, formatDescription: description),
            attemptedEngines: lastAttemptedEngines,
            formatDescription: description)
    }

    /// The Emby HLS transcode URL for the episode now playing, or
    /// nil when the current URL is not an Emby direct stream
    /// (build 36, item 14, G-H).
    private func transcodeURLForCurrentEpisode() -> URL? {
        guard let url = currentURL else { return nil }
        return EmbyClient.transcodedHlsUrl(fromStreamUrl: url.absoluteString)
    }

    /// Stream facts for the current URL, when it carries them
    /// (Emby `hao_*` markers). Nil for plain CMS URLs.
    private func currentURLFacts() -> VideoStreamFacts? {
        guard let url = currentURL else { return nil }
        return VideoStreamFacts.parse(url: url)
    }

    /// The Emby item id for the stream now playing, or nil when
    /// the URL is not an Emby playback URL — direct stream or
    /// transcode master playlist (CMS lines, strm-direct
    /// remotes). The id comes from the stream URL itself, so no
    /// source flag has to travel through the player — and a
    /// non-Emby URL can never report by accident.
    private func currentEmbyItemId() -> String? {
        guard let url = currentURL else { return nil }
        return EmbyClient.episodeIdFromEmbyPlaybackUrl(url.absoluteString)
    }

    /// The video surface for the player page to embed. Nil until
    /// the first backend opens.
    var videoView: UIView? { backend?.view }

    // MARK: - Context

    /// Set the episode context (C leg calls this before asking the
    /// coordinator to play). `resumeFrom` is the breakpoint
    /// position in seconds (0 = start from the beginning).
    func configure(detail: VideoDetail, line: PlayLine, episode: PlayEpisode, resumeFrom: Double = 0) {
        currentDetail = detail
        currentLine = line
        currentEpisodeIndex = episode.index
        startPosition = max(0, resumeFrom)
    }

    /// Build the PlaybackItem for an episode (id is the stable
    /// resume key: title + year + episode name — never the CMS
    /// vod_id, which drifts on reseed).
    static func playbackItem(detail: VideoDetail, episode: PlayEpisode) -> PlaybackItem {
        return PlaybackItem(
            id: VideoResumeKey.episodeId(title: detail.item.title, year: detail.item.year, episodeName: episode.name),
            kind: .vod,
            title: detail.item.title,
            artist: episode.name
        )
    }

    /// Play one episode directly (C leg convenience): configure
    /// the context and start playback.
    func playEpisode(detail: VideoDetail, line: PlayLine, episode: PlayEpisode, resumeFrom: Double = 0) {
        configure(detail: detail, line: line, episode: episode, resumeFrom: resumeFrom)
        play(item: VideoDriver.playbackItem(detail: detail, episode: episode))
    }

    /// Switch to another line, keeping the episode index and the
    /// current position (line switching never restarts the episode
    /// from the beginning). Goes through `startNewPlayback`
    /// directly, NOT `play(item:)`: the episode id is the same on
    /// the new line (same title + year + episode name), so `play`
    /// would mistake this for "tapped the episode already playing"
    /// and return without switching.
    func switchLine(to line: PlayLine) {
        guard let detail = currentDetail, let item = currentEpisode else { return }
        let resumeAt = position
        guard let episode = line.episode(at: currentEpisodeIndex) else { return }
        configure(detail: detail, line: line, episode: episode, resumeFrom: resumeAt)
        ensureMain { self.startNewPlayback(item: item) }
    }

    /// Re-open the current episode at its current position, on the
    /// same line (wiring leg B; Flutter
    /// native_video_player_page._reopenAtCurrentPosition). The mpv
    /// property set — including the low-memory mode — is fixed at
    /// open, so a mode change while playing only reaches the
    /// running episode via a re-open. Same shape as switchLine,
    /// minus the line switch, so the same-item guard in play()
    /// cannot swallow it. No-op when nothing is open (stop() clears
    /// currentEpisode).
    ///
    /// Name note: A leg already owns `reopenAtCurrentPosition()
    /// -> Bool` on this driver (DV-P8 routing only — it reopens
    /// nothing on a non-P8 stream). This method is the unconditional
    /// position reopen, so it carries its own name; the coordinator
    /// may unify the two into one Flutter-parity reopen (gate at
    /// the DV-P8 call site, not inside).
    func reopenEpisodeAtCurrentPosition() {
        guard let detail = currentDetail, let item = currentEpisode,
              let line = currentLine,
              let episode = line.episode(at: currentEpisodeIndex) else { return }
        let resumeAt = position
        configure(detail: detail, line: line, episode: episode, resumeFrom: resumeAt)
        ensureMain { self.startNewPlayback(item: item) }
    }

    /// Play the episode at `index` in the current line, from the
    /// start. Returns false when the index is out of range.
    @discardableResult
    func playEpisode(at index: Int) -> Bool {
        guard let detail = currentDetail, let line = currentLine,
              let episode = line.episode(at: index) else { return false }
        playEpisode(detail: detail, line: line, episode: episode, resumeFrom: 0)
        return true
    }

    // MARK: - Play / open

    /// Play an item: stop what this driver is doing, resolve the
    /// first playable URL serially (via `resolveURL`), open it on
    /// the first capable engine, and on open failure consume
    /// exactly one fallback candidate before giving up. Tapping
    /// the episode that is already playing does not restart it.
    func play(item: PlaybackItem) {
        ensureMain {
            if let current = self.currentEpisode, current.id == item.id, self.backend != nil {
                if self.isPlaying { return }
                self.resume()
                return
            }
            self.startNewPlayback(item: item)
        }
    }

    /// Start playback of a new episode (no same-episode check —
    /// callers that already decided this is a new request use
    /// this directly, e.g. `switchLine`, where the id is
    /// unchanged but the line is new).
    private func startNewPlayback(item: PlaybackItem) {
        self.stopBackendForNewRequest()
        self.pendingItem = item
        self.stallFailed = false
        self.lastOpenFailed = false
        self.lastFailure = nil
        self.midPlayFallbackUsed = false
        self.preparedSeenForEpisode = false
        self.failedEnginesForEpisode = []
        self.healthyPlaybackAccumulated = 0
        self.lastHealthyPosition = 0
        self.transcodeAttemptedForRequest = false
        self.lastAttemptedEngines = []
        self.isLoading = true
        self.resolveURL?(item, []) { [weak self] url in
            guard let self = self else { return }
            self.ensureMain {
                guard self.pendingItem?.id == item.id else { return }
                guard let url = url else {
                    self.isLoading = false
                    self.pendingItem = nil
                    self.recordFailure(error: .noPlayableURL, hadURL: false)
                    self.onEpisodeFailed?(item, .noPlayableURL)
                    return
                }
                self.attemptOpen(item: item, url: url, tried: [url])
            }
        }
        if self.resolveURL == nil {
            self.isLoading = false
            self.pendingItem = nil
            self.recordFailure(error: .noPlayableURL, hadURL: false)
            self.onEpisodeFailed?(item, .noPlayableURL)
        }
    }

    /// One open attempt plus at most one fallback re-resolution.
    /// `tried` lists the URLs already consumed for this request, so
    /// the fallback consumes exactly one more candidate, never a
    /// fan-out and never an unbounded retry loop — and never the
    /// same URL twice (`excluding` is passed through).
    private func attemptOpen(item: PlaybackItem, url: URL, tried: [URL]) {
        open(item: item, url: url) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                return
            case .failure(let error):
                guard tried.count < 2 else {
                    self.failOrTranscode(item: item, error: error)
                    return
                }
                self.resolveURL?(item, tried) { [weak self] nextURL in
                    guard let self = self else { return }
                    self.ensureMain {
                        guard self.pendingItem?.id == item.id else { return }
                        guard let nextURL = nextURL else {
                            self.failOrTranscode(item: item, error: error)
                            return
                        }
                        self.attemptOpen(item: item, url: nextURL, tried: tried + [nextURL])
                    }
                }
                if self.resolveURL == nil {
                    self.failOrTranscode(item: item, error: error)
                }
            }
        }
    }

    /// Terminal failure for one request: the Emby transcode last
    /// resort first (build 36, item 14, G-H), the specific
    /// failure otherwise. The transcode is tried once, after the
    /// direct URL failed on every engine and the fallback
    /// re-resolution is spent (or empty) — never for playable
    /// files, and never twice.
    private func failOrTranscode(item: PlaybackItem, error: MusicPlayerError) {
        if !transcodeAttemptedForRequest,
           let transcodeURL = transcodeURLForCurrentEpisode() {
            transcodeAttemptedForRequest = true
            open(item: item, url: transcodeURL) { [weak self] transcodeResult in
                guard let self = self else { return }
                switch transcodeResult {
                case .success:
                    return
                case .failure(let transcodeError):
                    self.isLoading = false
                    self.pendingItem = nil
                    self.recordFailure(error: transcodeError, hadURL: true)
                    self.onEpisodeFailed?(item, transcodeError)
                }
            }
            return
        }
        isLoading = false
        pendingItem = nil
        recordFailure(error: error, hadURL: true)
        onEpisodeFailed?(item, error)
    }

    /// Open a URL on the first capable engine, falling down the
    /// ladder (MPV / IJK / AVPlayer in capability order) on
    /// failure. (Build 36, item 14, G-J) Timeouts are per
    /// attempt now, not per open: each ladder attempt gets its
    /// own `openTimeoutInterval` budget (10 s in production), and
    /// the whole open is capped at 2.5x that (25 s). A slow first
    /// engine can no longer starve the rest of the ladder; a
    /// timeout is a stream error and the driver falls to the next
    /// candidate. The completion fires exactly once for the live
    /// attempt; a newer open supersedes this one (its completion
    /// is then dropped, never double-reported).
    /// `excludingEngines` removes engines that already failed for
    /// this episode (G-E mid-play fallback): the retry never
    /// loops back to the engine that just failed.
    /// Protocol witness for `VideoPlaybackDriver.open(item:url:completion:)`:
    /// the ladder entry below carries an extra `excludingEngines`
    /// parameter (defaulted), which does NOT satisfy the protocol
    /// requirement — the witness must match the protocol signature
    /// exactly. Forwards with no exclusions.
    func open(item: PlaybackItem, url: URL, completion: @escaping (Result<Void, MusicPlayerError>) -> Void) {
        open(item: item, url: url, excludingEngines: [], completion: completion)
    }

    func open(item: PlaybackItem, url: URL, excludingEngines: [VideoEngine] = [], completion: @escaping (Result<Void, MusicPlayerError>) -> Void) {
        ensureMain {
            let gen = self.nextGeneration()
            self.stopBackendForNewRequest()
            self.pendingItem = item
            self.openTimeoutWork?.cancel()
            self.openTimeoutWork = nil
            self.currentURL = url
            // (b37 D1) DV profile 5 / unknown-profile has no HDR10
            // base layer: every bundled ffmpeg kernel renders its
            // IPTPQc2 values as HDR10 and the picture comes out
            // green, and AVPlayer has no MKV demuxer. If AVPlayer is
            // not among the candidates (MKV container, TrueHD/DTS
            // audio, ASS subtitles — any of them), the direct stream
            // is unplayable-as-is: go to the Emby server transcode
            // (H.264 HLS, correct colour, SDR) instead of letting
            // MPV "succeed" green. P7/P8 keep their HDR10 base layer
            // on the ffmpeg kernels and never reach here. The
            // transcode URL carries no hao_* markers, so the
            // recursive open cannot loop back into this branch, and
            // the flag stops failOrTranscode transcoding twice.
            // CMS URLs carry no markers, so facts is nil there and
            // this branch never fires for them (honest limit: CMS DV
            // P5 in MKV has no detection and no transcode server).
            if !transcodeAttemptedForRequest,
               let facts = VideoStreamFacts.parse(url: url),
               facts.dolbyVision, facts.dvProfile != 7, facts.dvProfile != 8,
               !PlayerKernel.candidatesFor(url: url, dvDowngradeToHdr: self.dvP8Downgrade).contains(.avplayer),
               let transcodeURL = EmbyClient.transcodedHlsUrl(fromStreamUrl: url.absoluteString) {
                transcodeAttemptedForRequest = true
                NSLog("[HAoStudio][VOD] DV P\(facts.dvProfile ?? -1) MKV: no AVPlayer candidate, redirecting to Emby transcode")
                open(item: item, url: transcodeURL, completion: completion)
                return
            }
            var completed = false
            let finish: (Result<Void, MusicPlayerError>) -> Void = { [weak self] result in
                guard let self = self, !completed else { return }
                completed = true
                self.openTimeoutWork?.cancel()
                self.openTimeoutWork = nil
                completion(result)
            }
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard gen == self.generation, !completed else { return }
                // Invalidate the generation FIRST: a ladder attempt
                // that completes after this timeout must see the
                // stale gen and shut its backend down (mpv /
                // AVPlayer start on open — without the bump a late
                // success would keep playing with no owner, no UI,
                // and a dead play button). The fallback re-resolve
                // in attemptOpen calls open() again, which takes a
                // fresh generation, so this bump cannot strand it.
                _ = self.nextGeneration()
                // #1: kill the ladder BEFORE shutting the backend
                // down — shutdown fires finishOpen(false)
                // synchronously, and a live ladder would advance
                // to the next engine, open backend2 (autoplay) and
                // then have it orphaned by `self.backend = nil`
                // below. Nil-ing activeLadder deallocates the
                // ladder (its attempt completion holds it weakly),
                // so the advance never happens. Mirrors
                // stopBackendForNewRequest.
                self.activeLadder = nil
                self.backend?.shutdown()
                self.backend = nil
                // #1: stop the position timer too, so
                // handleTimeUpdate cannot recompute isPlaying = true
                // from the sounding orphan after the failure was
                // already reported.
                self.positionTimer?.invalidate()
                self.positionTimer = nil
                self.playRequested = false
                self.isLoading = false
                self.recomputePlayingState()
                finish(.failure(.timeout))
            }
            self.openTimeoutWork = timeoutWork
            DispatchQueue.main.asyncAfter(deadline: .now() + self.openTimeoutInterval * VideoDriver.openTotalTimeoutFactor, execute: timeoutWork)
            // (G-B) The ASS / multi-track / external-subtitle
            // flags finally reach the candidate list: the facts
            // ride the URL as `hao_*` markers (Emby), and the
            // routing rule (ASS/multi-track/external -> MPV) was
            // dead code until this call passed them.
            let facts = self.currentURLFacts()
            let engines = PlayerKernel.candidatesFor(
                url: url,
                hasAssSubtitles: facts?.hasAssSubtitles ?? false,
                hasMultipleAudioTracks: facts?.hasMultipleAudioTracks ?? false,
                hasExternalSubtitles: facts?.hasExternalSubtitles ?? false,
                dvDowngradeToHdr: self.dvP8Downgrade,
                excluding: excludingEngines)
            // Accumulate across the opens of one episode (original
            // open + mid-play retry / transcode), so the failure +
            // diagnostics name every engine that was tried — not
            // just the last open's list. startNewPlayback resets it.
            for engine in engines where !self.lastAttemptedEngines.contains(engine) {
                self.lastAttemptedEngines.append(engine)
            }
            self.openAttemptTimedOut = false
            let ladder = VideoRecoveryLadder(engines: engines, urls: [url], attempt: { [weak self] engine, attemptURL, attemptCompletion in
                guard let self = self else {
                    attemptCompletion(false)
                    return
                }
                // (G-J) Per-attempt timeout, shared with LiveDriver
                // via OpenAttemptTimeoutGuard (build 36, item 8,
                // smell 1): a hanging attempt fails like a stream
                // error after its own budget, and the ladder moves
                // to the next engine. The guard's `settled` state
                // makes the completion fire exactly once — a late
                // backend answer after the timeout is dropped (and
                // its backend shut down) instead of
                // double-reporting or sounding behind the engine
                // the ladder moved on to.
                let attemptGuard = OpenAttemptTimeoutGuard(timeout: self.openTimeoutInterval) { [weak self] in
                    guard let self = self else { return }
                    self.ensureMain {
                        self.openAttemptTimedOut = true
                        if let current = self.backend, current.engine == engine {
                            current.shutdown()
                            if self.backend === current { self.backend = nil }
                        }
                        attemptCompletion(false)
                    }
                }
                self.openOnEngine(engine, url: attemptURL, gen: gen) { [weak self] ok in
                    guard let self = self else { return }
                    self.ensureMain {
                        guard attemptGuard.complete(ok: ok, attemptCompletion: attemptCompletion) else {
                            // Late answer after the per-attempt
                            // timeout: shut this attempt's backend
                            // down so it cannot sound behind the
                            // next engine (the timeout handler
                            // already shut it down when it was
                            // still current — shutdown is
                            // idempotent — this covers the case
                            // where the ladder already moved on).
                            if let attemptBackend = attemptGuard.backend, self.backend !== attemptBackend {
                                attemptBackend.shutdown()
                            }
                            return
                        }
                    }
                }
                attemptGuard.noteBackend(self.backend)
            }, onAttempt: { [weak self] engine, _ in
                self?.currentEngine = engine
            })
            self.activeLadder = ladder
            ladder.run { [weak self] winner in
                guard let self = self else { return }
                self.ensureMain {
                    self.activeLadder = nil
                    guard gen == self.generation, !completed else { return }
                    guard winner != nil, let backend = self.backend else {
                        self.playRequested = false
                        self.isLoading = false
                        self.recomputePlayingState()
                        // (G-J) The ladder exhausted because every
                        // attempt timed out on its own budget (a
                        // hanging backend), not because engines
                        // failed fast: report a timeout, exactly
                        // like the overall cap.
                        finish(.failure(self.openAttemptTimedOut ? .timeout : .loadFailed))
                        return
                    }
                    self.startPlaybackAfterLoad(item: item, backend: backend, gen: gen, finish: finish)
                }
            }
        }
    }

    /// One ladder attempt: build the backend for `engine`, wire
    /// its events, and open the URL. The completion reports
    /// whether the engine is really prepared and playing.
    private func openOnEngine(
        _ engine: VideoEngine,
        url: URL,
        gen: Int,
        completion: @escaping (Bool) -> Void
    ) {
        // #1 belt-and-braces: an attempt that starts after its
        // request was superseded (timeout / new open) must not
        // install a backend at all — the open completion's gen
        // guard would tear it down, but only after it was assigned
        // and opened.
        guard gen == generation else {
            completion(false)
            return
        }
        let backend = makeBackend(engine)
        backend.onEvent = { [weak self] event in self?.handleBackendEvent(event) }
        backend.onVideoSize = { [weak self] _ in self?.updateDiagnostics() }
        // (G-F) The backend publishes its track list when the
        // file's tracks are known. A stale publish from a
        // superseded backend must not overwrite the current one,
        // so the handler checks identity before publishing.
        if let capable = backend as? VodTrackListCapable {
            capable.onTracksChanged = { [weak self] audio, subtitles in
                guard let self = self else { return }
                self.ensureMain {
                    guard self.backend === backend else { return }
                    self.audioTracks = audio
                    self.subtitleTracks = subtitles
                    self.applyStoredTrackPicks(to: backend)
                    self.updateDiagnostics()
                }
            }
        }
        self.backend = backend
        self.currentEngine = engine
        backend.open(url: url, headers: PlayerKernel.httpHeaders(platform: nil)) { [weak self] ok in
            guard let self = self else {
                completion(false)
                return
            }
            self.ensureMain {
                guard gen == self.generation else {
                    // Superseded by a newer open: tear this backend
                    // down so it cannot sound behind the new one.
                    if self.backend === backend {
                        backend.shutdown()
                        self.backend = nil
                    }
                    completion(false)
                    return
                }
                if !ok {
                    if self.backend === backend {
                        backend.shutdown()
                        self.backend = nil
                    }
                }
                completion(ok)
            }
        }
    }

    /// Shared tail of a successful load: verify the hard-decode
    /// state (soft 4K HEVC / Dolby Vision -> AVPlayer, same
    /// position), seek to the resume position, start the watchdog
    /// and the FPS sampler, publish state.
    private func startPlaybackAfterLoad(
        item: PlaybackItem,
        backend: VideoPlayerBackend,
        gen: Int,
        finish: @escaping (Result<Void, MusicPlayerError>) -> Void
    ) {
        guard gen == generation else { return }
        // Software-decode fallback (plan §四 4.2): verified soft
        // decode on a 4K HEVC / Dolby Vision stream switches to
        // AVPlayer and reopens at the same position. Anything else
        // stays put and is labelled "软解中" — never silent.
        if backend.hardwareDecode.isSoftware,
           videoNeedsHardwareDecode(facts: currentURLFacts()),
           backend.engine != .avplayer,
           let url = currentURL,
           videoEngineCanPlay(.avplayer, format: videoFormatOf(url: url, declaredFormat: nil)) {
            fellBackForSoftwareDecode = true
            reopenOnAVPlayer(item: item, url: url, gen: gen, finish: finish)
            return
        }
        finishStartPlayback(item: item, backend: backend, gen: gen, finish: finish)
    }

    private func reopenOnAVPlayer(
        item: PlaybackItem,
        url: URL,
        gen: Int,
        finish: @escaping (Result<Void, MusicPlayerError>) -> Void
    ) {
        let resumeAt = max(0, startPosition)
        backend?.shutdown()
        backend = nil
        let avBackend = makeBackend(.avplayer)
        avBackend.onEvent = { [weak self] event in self?.handleBackendEvent(event) }
        avBackend.onVideoSize = { [weak self] _ in self?.updateDiagnostics() }
        backend = avBackend
        currentEngine = .avplayer
        avBackend.open(url: url, headers: PlayerKernel.httpHeaders(platform: nil)) { [weak self] ok in
            guard let self = self else { return }
            self.ensureMain {
                guard gen == self.generation else { return }
                guard ok else {
                    // AVPlayer could not open it either: stay failed
                    // rather than looping back to the soft engine.
                    self.playRequested = false
                    self.isLoading = false
                    self.recomputePlayingState()
                    finish(.failure(.loadFailed))
                    return
                }
                self.startPosition = resumeAt
                self.finishStartPlayback(item: item, backend: avBackend, gen: gen, finish: finish)
            }
        }
    }

    private func finishStartPlayback(
        item: PlaybackItem,
        backend: VideoPlayerBackend,
        gen: Int,
        finish: @escaping (Result<Void, MusicPlayerError>) -> Void
    ) {
        guard gen == generation else { return }
        // The resume position this open seeks to — captured now,
        // because the seek block below consumes startPosition.
        // Reported to Emby as the playback-start position.
        let reportedStartPosition = startPosition
        playRequested = true
        stallFailed = false
        stallWarning = false
        isLoading = false
        backend.play()
        if let rate = currentRate { backend.playbackRate = rate }
        // F2: re-apply the stored picture fit to the backend
        // that just opened (same pattern as the rate above).
        // A fresh backend defaults to .resizeAspect, so without
        // this a ladder swap / reopen silently resets the fit
        // the user picked mid-playback.
        if let fit = currentFit { backend.setVideoFit(fit) }
        // S7 wiring: re-apply the stored VOD settings to the
        // backend that just opened. A toggle made before the
        // backend existed lands here, and a ladder swap / reopen
        // re-applies instead of silently resetting to defaults.
        // Audio-only is re-applied so an auto-advance while
        // backgrounded stays audio-only.
        if isAudioOnly, let capable = backend as? LiveAudioOnlyCapable {
            capable.setAudioOnly(true)
        }
        if let branch = currentEnhancement, let capable = backend as? VodEnhancementCapable {
            capable.setVodEnhancement(branch)
        }
        if currentDialogueBoost, let capable = backend as? DialogueBoostCapable {
            capable.setDialogueBoost(true)
        }
        if let capable = backend as? VodSubtitleAppearanceCapable {
            capable.setSubtitleAppearance(fontSize: currentSubtitleAppearance.fontSize, color: currentSubtitleAppearance.color, position: currentSubtitleAppearance.position)
        }
        // (G-F) The stored track picks land through the
        // onTracksChanged handler (wired in openOnEngine before
        // open() runs, so it always sees the publish) — no second
        // apply here, or `aid` / `sid` would be set twice.
        // (G-G) Load external subtitles on MPV.
        loadExternalSubtitlesIfNeeded()
        do {
            let mix = defaults.bool(forKey: SettingsStore.mixWithOthersKey)
            let options: AVAudioSession.CategoryOptions = mix ? [.mixWithOthers] : []
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: options)
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            // Audio session failure must not fail playback: the
            // video still plays, just without the session guarantee.
            NSLog("[HAoStudio][VOD] audio session failed: %@", error.localizedDescription)
        }
        currentEpisode = item
        pendingItem = nil
        position = 0
        duration = backend.duration.isFinite ? backend.duration : 0
        watchdog.resetForNewEpisode()
        healthyPlaybackAccumulated = 0
        lastHealthyPosition = 0
        startPositionTimerIfNeeded()
        fpsSampler.start()
        updateDiagnostics()
        // Resume position: seek after the engine is playing (the
        // old player did the same on prepared). A failed resume
        // seek starts from 0 rather than failing the episode.
        if startPosition > 0 {
            let target = startPosition
            startPosition = 0
            backend.seek(to: target) { [weak self] _ in
                guard let self = self else { return }
                self.ensureMain { self.position = self.backend?.currentTime ?? 0 }
            }
        }
        recomputePlayingState()
        finish(.success(()))
        onEpisodeStarted?(item)
        // Emby (build 36, item 13): report playback start to the
        // server. Only an Emby stream URL yields an id — CMS
        // lines no-op here. An engine swap re-opening the same
        // item dedupes inside the reporter.
        if let embyId = currentEmbyItemId() {
            embyReporter.noteStarted(itemId: embyId, positionSeconds: reportedStartPosition)
        }
        // S5-A: the open verified playback on this engine — record
        // it once, here, as the last-used engine. (The AVPlayer
        // reopen path also lands here, so a soft-decode fallback
        // records AVPlayer, not the engine that failed.)
        VideoEngineReporter.shared.noteUsed(backend.engine)
    }

    private func stopBackendForNewRequest() {
        // Emby (build 36, item 13): a new request ends the
        // previous episode's server session (final progress +
        // stopped). No session active (first play) = no-op. An
        // engine swap for the SAME episode never passes through
        // here (reopenOnAVPlayer shuts down directly), so its
        // session correctly survives.
        embyReporter.noteStopped(positionSeconds: position)
        activeLadder = nil
        openTimeoutWork?.cancel()
        openTimeoutWork = nil
        playRequested = false
        backend?.pause()
        backend?.shutdown()
        backend = nil
        positionTimer?.invalidate()
        positionTimer = nil
        fpsSampler.stop()
    }

    // MARK: - Transport

    func resume() {
        ensureMain {
            guard self.currentEpisode != nil, self.backend != nil else { return }
            if self.isPlaying { return }
            self.playRequested = true
            self.stallFailed = false
            self.stallWarning = false
            self.backend?.play()
            if let rate = self.currentRate { self.backend?.playbackRate = rate }
            self.watchdog.noteBaseline()
            self.recomputePlayingState()
        }
    }

    func pause() {
        ensureMain {
            guard self.currentEpisode != nil else { return }
            self.playRequested = false
            self.backend?.pause()
            self.recomputePlayingState()
            // Emby (build 36, item 13): a pause reports progress
            // with IsPaused immediately (state change, not the
            // 15 s throttle) so the server's breakpoint is fresh
            // even when the user pauses and walks away.
            self.embyReporter.noteProgress(
                positionSeconds: self.position, durationSeconds: self.duration, isPaused: true)
        }
    }

    /// Set playback speed (VOD only — live is real-time and cannot
    /// be sped up). 0.5-2.0, applied live to the backend.
    func setSpeed(_ speed: Double) {
        ensureMain {
            let clamped = min(2.0, max(0.5, speed))
            self.currentRate = clamped
            if self.playRequested {
                self.backend?.playbackRate = clamped
            }
        }
    }

    /// Set picture fit (适应 / 裁剪 / 拉伸), applied live to the
    /// backend and kept for the next open.
    func setVideoFit(_ fit: VideoFit) {
        ensureMain {
            self.currentFit = fit
            self.backend?.setVideoFit(fit)
        }
    }

    /// Drop to audio-only / restore video (S7 wiring: the
    /// `audioOnlyBackground` switch, applied on background and
    /// restored on foreground). The flag is remembered and
    /// re-applied after a ladder backend swap; a backend without
    /// the capability (AVPlayer/IJK) no-ops — the audio keeps
    /// playing in background natively there.
    func setAudioOnly(_ audioOnly: Bool) {
        ensureMain {
            self.isAudioOnly = audioOnly
            if let capable = self.backend as? LiveAudioOnlyCapable {
                capable.setAudioOnly(audioOnly)
            }
        }
    }

    /// Apply one resolved enhancement branch, live to the running
    /// backend and stored for the next open. Nil restores the mpv
    /// defaults on the running backend.
    func applyVodEnhancement(_ branch: VodEnhancementBranch?) {
        ensureMain {
            self.currentEnhancement = branch
            if let backend = self.backend, let capable = backend as? VodEnhancementCapable {
                capable.setVodEnhancement(branch)
            }
        }
    }

    /// Set dialogue boost (MPV only, VOD only), live to the
    /// running backend and stored for the next open. A backend
    /// without the capability no-ops — the choice is still
    /// remembered, so a later capable backend picks it up.
    func setDialogueBoost(_ enabled: Bool) {
        ensureMain {
            self.currentDialogueBoost = enabled
            if let backend = self.backend, let capable = backend as? DialogueBoostCapable {
                capable.setDialogueBoost(enabled)
            }
        }
    }

    /// Apply the resolved subtitle appearance, live to the running
    /// backend and stored for the next open.
    func setSubtitleAppearance(_ appearance: VodSubtitleAppearance) {
        ensureMain {
            self.currentSubtitleAppearance = appearance
            if let backend = self.backend, let capable = backend as? VodSubtitleAppearanceCapable {
                capable.setSubtitleAppearance(fontSize: appearance.fontSize, color: appearance.color, position: appearance.position)
            }
        }
    }

    // MARK: - Audio / subtitle tracks (build 36, item 14, G-F)

    /// Select the audio track by list position (-1 = default /
    /// auto). The pick is stored and forwarded live when the
    /// backend can switch; when the list is not published yet it
    /// is applied when it lands (see `applyStoredTrackPicks`).
    /// The `index` is a POSITION in `audioTracks`, translated to
    /// the engine-native id (`VodTrackInfo.index`) here.
    func selectAudioTrack(index: Int) {
        ensureMain {
            self.currentAudioTrackIndex = index
            guard let backend = self.backend, let capable = backend as? VodTrackListCapable else { return }
            if index < 0 {
                capable.selectAudioTrack(index: -1)
                return
            }
            guard self.audioTracks.indices.contains(index) else { return }
            capable.selectAudioTrack(index: self.audioTracks[index].index)
        }
    }

    /// Select the subtitle track by list position (-1 = no
    /// subtitles). Same stored + live discipline as audio. Note
    /// the asymmetry with `applyStoredTrackPicks`: a stored -1 is
    /// never forced at open (the backend's auto-select is left
    /// alone until the user picks) — only an explicit live pick
    /// of -1 turns subtitles off.
    func selectSubtitleTrack(index: Int) {
        ensureMain {
            self.currentSubtitleTrackIndex = index
            guard let backend = self.backend, let capable = backend as? VodTrackListCapable else { return }
            if index < 0 {
                capable.selectSubtitleTrack(index: -1)
                return
            }
            guard self.subtitleTracks.indices.contains(index) else { return }
            capable.selectSubtitleTrack(index: self.subtitleTracks[index].index)
        }
    }

    /// Apply the stored track picks to a backend whose list is
    /// already published. Only explicit picks (index >= 0) are
    /// applied: a stored -1 means "never picked", and forcing it
    /// would turn off the backend's auto-selected subtitles.
    private func applyStoredTrackPicks(to backend: VideoPlayerBackend) {
        guard let capable = backend as? VodTrackListCapable else { return }
        if currentAudioTrackIndex >= 0, audioTracks.indices.contains(currentAudioTrackIndex) {
            capable.selectAudioTrack(index: audioTracks[currentAudioTrackIndex].index)
        }
        if currentSubtitleTrackIndex >= 0, subtitleTracks.indices.contains(currentSubtitleTrackIndex) {
            capable.selectSubtitleTrack(index: subtitleTracks[currentSubtitleTrackIndex].index)
        }
    }

    // MARK: - External subtitles (build 36, item 14, G-G)

    /// Load external subtitles on a capable backend (MPV only).
    /// Emby external streams come from the URL facts (indexes +
    /// media-source id; the URL is built from the stream URL
    /// itself — the driver has no EmbyClient). Local sidecar files
    /// next to a local file use mpv's `sub-auto=exact` semantics
    /// (same basename, `.srt` / `.ass` / `.vtt`). AVPlayer / IJK
    /// do not conform, so they never reach here — external subs
    /// route to MPV (see the `hasExternalSubtitles` routing flag).
    private func loadExternalSubtitlesIfNeeded() {
        guard let backend = backend, let capable = backend as? VodExternalSubtitleCapable,
              let url = currentURL else { return }
        if let facts = currentURLFacts(), !facts.externalSubtitles.isEmpty,
           let mediaSourceId = facts.mediaSourceId, !mediaSourceId.isEmpty {
            for ref in facts.externalSubtitles {
                if let subURL = EmbyClient.subtitleUrl(fromStreamUrl: url.absoluteString, mediaSourceId: mediaSourceId, index: ref.index) {
                    capable.addSubtitle(url: subURL, language: ref.language)
                }
            }
        }
        if url.isFileURL {
            let base = url.deletingPathExtension()
            for ext in ["srt", "ass", "vtt"] {
                let sidecar = base.appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    capable.addSubtitle(url: sidecar, language: nil)
                }
            }
        }
    }

    // MARK: - Mid-play engine fallback (build 36, item 14, G-E)

    /// Try the next engine after a mid-play failure, once per
    /// failure episode. Re-opens the same URL at the saved
    /// position with the failed engines excluded (the ladder
    /// never loops back to the engine that just failed). Returns
    /// false when no retry is available — the caller then fails
    /// outright with the specific reason. Only a backend that
    /// already prepared can fail mid-play; an open-time failure
    /// never reaches here (the open ladder owns those).
    @discardableResult
    private func tryNextEngineAfterFailure() -> Bool {
        guard let item = currentEpisode, let url = currentURL else { return false }
        guard !midPlayFallbackUsed, preparedSeenForEpisode else { return false }
        let facts = currentURLFacts()
        let failed = failedEnginesForEpisode + (currentEngine.map { [$0] } ?? [])
        let remaining = PlayerKernel.candidatesFor(
            url: url,
            hasAssSubtitles: facts?.hasAssSubtitles ?? false,
            hasMultipleAudioTracks: facts?.hasMultipleAudioTracks ?? false,
            hasExternalSubtitles: facts?.hasExternalSubtitles ?? false,
            dvDowngradeToHdr: dvP8Downgrade,
            excluding: failed)
        guard !remaining.isEmpty else { return false }
        midPlayFallbackUsed = true
        failedEnginesForEpisode = failed
        startPosition = max(0, position)
        // A fresh open on the same URL with the failed engines
        // excluded; finishStartPlayback seeks to the saved
        // position. This is NOT attemptOpen — there is no
        // re-resolution loop. On failure the open's own failure
        // path reports it (specific reason + onEpisodeFailed).
        open(item: item, url: url, excludingEngines: failed) { [weak self] result in
            guard let self = self else { return }
            if case .failure(let error) = result {
                self.recordFailure(error: error, hadURL: true)
                self.onEpisodeFailed?(item, error)
            }
        }
        return true
    }

    /// Reopen the current episode at the current position — the
    /// mechanism for settings that only take effect at open (DV P8
    /// routing; Flutter `_reopenAtCurrentPosition` parity). Only
    /// an AVPlayer-backed Dolby Vision profile 8 stream can change
    /// engines mid-playback; on any other stream the switch
    /// changes no routing, so this returns false and reopens
    /// nothing. A failed reopen stops playback (this driver tears
    /// the backend down before resolving, unlike Flutter's
    /// swap-on-first-frame) — the caller only uses it for a
    /// settings toggle the user just made, never silently.
    @discardableResult
    func reopenAtCurrentPosition() -> Bool {
        guard currentEngine == .avplayer,
              let item = currentEpisode,
              let facts = currentURLFacts(),
              facts.dolbyVision, facts.dvProfile == 8 else {
            return false
        }
        startPosition = max(0, position)
        ensureMain { self.startNewPlayback(item: item) }
        return true
    }

    /// Stop everything and clear the current episode. Saves the
    /// breakpoint first (a stop is never a lost resume). The
    /// coordinator clears `currentItem` alongside; this driver
    /// never leaves a ghost engine sounding after stop.
    func stop() {
        ensureMain {
            self.nextGeneration()
            self.saveBreakpoint()
            // Emby (build 36, item 13): end the server session
            // (final progress + stopped) before the position is
            // cleared below.
            self.embyReporter.noteStopped(positionSeconds: self.position)
            self.activeLadder = nil
            self.openTimeoutWork?.cancel()
            self.openTimeoutWork = nil
            self.positionTimer?.invalidate()
            self.positionTimer = nil
            self.fpsSampler.stop()
            self.playRequested = false
            self.stallFailed = false
            self.stallWarning = false
            self.isAudioOnly = false
            self.pendingItem = nil
            self.backend?.pause()
            self.backend?.shutdown()
            self.backend = nil
            self.currentEpisode = nil
            self.currentEngine = nil
            self.position = 0
            self.duration = 0
            self.isLoading = false
            self.fellBackForSoftwareDecode = false
            self.midPlayFallbackUsed = false
            self.preparedSeenForEpisode = false
            self.failedEnginesForEpisode = []
            self.healthyPlaybackAccumulated = 0
            self.lastHealthyPosition = 0
            self.audioTracks = []
            self.subtitleTracks = []
            self.lastFps = 0
            self.lastDroppedFrames = 0
            self.diagnostics = .empty
            self.recomputePlayingState()
        }
    }

    /// Release on exit (P0-08): cancel timers, save the
    /// breakpoint, shut the backend down, THEN call completion.
    /// The player page calls this before dismissing, so the
    /// breakpoint is persisted before the view goes away. Unlike
    /// `stop()`, this also clears the episode context (detail /
    /// line) — the next open starts from a fresh configure.
    func release(completion: @escaping () -> Void) {
        ensureMain {
            self.nextGeneration()
            self.saveBreakpoint()
            // Emby (build 36, item 13): same session end as
            // stop() — the player page calls this on exit.
            self.embyReporter.noteStopped(positionSeconds: self.position)
            self.activeLadder = nil
            self.openTimeoutWork?.cancel()
            self.openTimeoutWork = nil
            self.positionTimer?.invalidate()
            self.positionTimer = nil
            self.fpsSampler.stop()
            self.playRequested = false
            self.stallFailed = false
            self.isAudioOnly = false
            self.pendingItem = nil
            self.backend?.pause()
            self.backend?.shutdown()
            self.backend = nil
            self.currentEpisode = nil
            self.currentEngine = nil
            self.currentDetail = nil
            self.currentLine = nil
            self.currentEpisodeIndex = 0
            self.startPosition = 0
            self.position = 0
            self.duration = 0
            self.isLoading = false
            self.fellBackForSoftwareDecode = false
            self.midPlayFallbackUsed = false
            self.preparedSeenForEpisode = false
            self.failedEnginesForEpisode = []
            self.healthyPlaybackAccumulated = 0
            self.lastHealthyPosition = 0
            self.audioTracks = []
            self.subtitleTracks = []
            self.diagnostics = .empty
            self.recomputePlayingState()
            completion()
        }
    }

    /// Seek with read-back verification. The backend reports
    /// whether the playhead landed; the driver re-reads the real
    /// position and publishes it, so on failure the UI rolls the
    /// progress bar back to where playback actually is. The
    /// completion reports success — false means "seek did not
    /// land, UI already rolled back".
    func seek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        ensureMain {
            guard let backend = self.backend, self.currentEpisode != nil else {
                completion(false)
                return
            }
            let target = min(max(0, seconds), self.duration > 0 ? self.duration : seconds)
            backend.seek(to: target) { [weak self] ok in
                guard let self = self else {
                    completion(false)
                    return
                }
                self.ensureMain {
                    // Read back the real position after the seek.
                    let actual = backend.currentTime
                    self.position = actual
                    self.watchdog.noteBaseline()
                    if ok && abs(actual - target) <= VideoDriver.seekTolerance {
                        completion(true)
                    } else {
                        completion(false)
                    }
                }
            }
        }
    }

    // MARK: - Breakpoint

    /// Build the resume bookmark for the current episode and hand
    /// it to `onBreakpointSaved`, and write the local playback
    /// record (b37 E1). No-op when nothing is playing
    /// (nothing to resume) or when the position is 0 and no
    /// episode was ever started.
    private func saveBreakpoint() {
        guard let detail = currentDetail,
              let line = currentLine,
              let episode = line.episode(at: currentEpisodeIndex),
              currentEpisode != nil,
              position > 0 else { return }
        let info = ResumeInfo(
            key: VideoResumeKey.key(title: detail.item.title, year: detail.item.year),
            episodeName: episode.name,
            episodeIndex: currentEpisodeIndex,
            positionSeconds: position,
            durationSeconds: duration,
            updatedAt: Date()
        )
        // (b37 E1) The local playback record. The Emby reporter only
        // syncs to the server, and this callback had no assignee in
        // the app, so Emby watches left no local history at all.
        // savePosition accepts any VideoItem (no source filter), so
        // the same write covers CMS and Emby; it fires from stop()
        // and release() — ✕-close, swipe-dismiss, natural end —
        // and its own >= 5 s guard applies on top of this one.
        VideoLibraryStore.savePosition(
            item: detail.item, episodeName: episode.name, episodeIndex: currentEpisodeIndex,
            lineName: line.name, positionSeconds: position, durationSeconds: duration)
        onBreakpointSaved?(info)
    }

    // MARK: - Backend events + position timer

    private func handleBackendEvent(_ event: VideoBackendEvent) {
        ensureMain {
            switch event {
            case .prepared:
                self.preparedSeenForEpisode = true
                self.isLoading = false
                self.updateDiagnostics()
            case .firstFrame:
                self.isLoading = false
                self.updateDiagnostics()
            case .playing:
                self.recomputePlayingState()
            case .paused:
                self.recomputePlayingState()
            case .stalled:
                // Pre-start only: the watchdog owns stalls after start.
                if self.position <= 0 { self.isLoading = true }
            case .finished(let reason):
                switch reason {
                case .ended:
                    self.handleEpisodeEnded()
                case .error:
                    if let item = self.currentEpisode {
                        // (G-E) Mid-play failure on an engine that
                        // had already prepared: try the next engine
                        // once at the same position instead of
                        // failing outright (live already recovers
                        // this way; VOD never did). An open-time
                        // failure never reaches here — the open
                        // ladder owns those — so the `prepared`
                        // gate above is what makes this mid-play.
                        if self.tryNextEngineAfterFailure() { break }
                        self.stop()
                        self.recordFailure(error: .loadFailed, hadURL: true)
                        self.onEpisodeFailed?(item, .loadFailed)
                    }
                }
            }
        }
    }

    private func handleEpisodeEnded() {
        guard let item = currentEpisode else { return }
        // Emby (build 36, item 13): natural end — final
        // progress + played + session end, BEFORE the
        // auto-advance below (which starts a new session for
        // the next episode). The played marking here is
        // belt-and-braces: the progress tick already marks
        // played at the end margin, and the reporter dedupes.
        embyReporter.noteEnded(positionSeconds: position)
        // Advance within the same line when there is a next episode.
        // The stored `hao_video_auto_next` preference gates this
        // path too: the settings toggle used to stop only the view
        // model's poll-tick advance, while a natural end
        // (.finished) still advanced here regardless of the switch.
        let autoNextEnabled = defaults.object(forKey: SettingsStore.autoNextEpisodeKey) as? Bool ?? true
        if autoAdvanceToNextEpisode, autoNextEnabled,
           let line = currentLine,
           line.episode(at: currentEpisodeIndex + 1) != nil {
            _ = playEpisode(at: currentEpisodeIndex + 1)
            return
        }
        stop()
        onEpisodeEnded?(item)
    }

    private func startPositionTimerIfNeeded() {
        guard positionTimer == nil else { return }
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.handleTimeUpdate()
        }
    }

    private func handleTimeUpdate() {
        guard let backend = backend, currentEpisode != nil else { return }
        let pos = backend.currentTime
        let dur = backend.duration
        position = pos
        if dur.isFinite, dur > 0 { duration = dur }
        recomputePlayingState()
        // (G-E) Healthy-playback clock for the mid-play retry
        // reset: 30 s of continuous position progress re-arms the
        // one retry per failure episode. Any stall resets it.
        if pos > lastHealthyPosition {
            healthyPlaybackAccumulated += 0.5
            lastHealthyPosition = pos
            if healthyPlaybackAccumulated >= 30 {
                healthyPlaybackAccumulated = 0
                midPlayFallbackUsed = false
                failedEnginesForEpisode = []
            }
        } else {
            healthyPlaybackAccumulated = 0
            lastHealthyPosition = pos
        }
        // Emby (build 36, item 13): periodic progress, throttled
        // to one report per 15 s inside the reporter, plus the
        // played marking at the end margin.
        embyReporter.noteProgress(positionSeconds: pos, durationSeconds: duration, isPaused: !isPlaying)
        switch watchdog.tick(position: pos, duration: duration, isPlaying: isPlaying) {
        case .none:
            break
        case .warn:
            stallWarning = true
        case .failed:
            stallFailed = true
            stallWarning = false
            if let item = currentEpisode {
                // (G-E) A stall after a successful open tries the
                // next engine once before failing (same retry as
                // a mid-play error). Pre-start stalls keep the
                // current behaviour — the open ladder owns those.
                if preparedSeenForEpisode, tryNextEngineAfterFailure() {
                    stallFailed = false
                    break
                }
                stop()
                recordFailure(error: .timeout, hadURL: true)
                onEpisodeFailed?(item, .timeout)
            }
        case .atEnd:
            handleEpisodeEnded()
        }
    }
}

// MARK: - VideoPlayerEngine (C-leg player page seam)
//
// The player page (Features/Video) talks to the driver only
// through this protocol. Every member already exists on the
// driver; this extension only names the conformance and adapts
// the two play entry points to the page's (detail, lineIndex,
// episodeIndex, startPosition) shape.
extension VideoDriver: VideoPlayerEngine {
    var positionSeconds: Double { position }
    var durationSeconds: Double { duration }

    func play(detail: VideoDetail, lineIndex: Int, episodeIndex: Int, startPositionSeconds: Double) {
        guard detail.lines.indices.contains(lineIndex) else { return }
        let line = detail.lines[lineIndex]
        guard let episode = line.episode(at: episodeIndex) else { return }
        playEpisode(detail: detail, line: line, episode: episode, resumeFrom: startPositionSeconds)
    }

    func playEpisode(lineIndex: Int, episodeIndex: Int, startPositionSeconds: Double) {
        guard let detail = currentDetail,
              detail.lines.indices.contains(lineIndex) else { return }
        let line = detail.lines[lineIndex]
        guard let episode = line.episode(at: episodeIndex) else { return }
        playEpisode(detail: detail, line: line, episode: episode, resumeFrom: startPositionSeconds)
    }
}

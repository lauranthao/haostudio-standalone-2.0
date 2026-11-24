// HAo Studio 2.0 — VOD player page (S3-C leg).
//
// VOD rules (chen 2026-11-16, coordinator rule 3):
// - Tap play goes DIRECTLY landscape fullscreen; the page locks
//   landscape on appear and restores portrait on dismiss. A [ ]
//   button in the bottom controls toggles landscape / portrait
//   by hand (Bilibili standard, live parity): only the button
//   changes orientation — turning the phone never does.
// - NO quality selector on VOD — one play URL per episode, no
//   quality tiers, so a fake quality button must never appear.
// - Long-press 2x speed is VOD ONLY (live is real-time).
// - Brightness / volume live ONLY in this player (sun button in
//   the top bar): brightness writes the screen only from an
//   explicit user drag, and leaving the player never restores or
//   overrides the brightness the user set; volume is the system
//   MPVolumeView slider (public API).
// - The progress bar exists from the start of playback; drag
//   changes local state only, seek fires once on release, and a
//   failed seek rolls the bar back to the real position (P0-05).
// - Switching lines keeps the episode and resumes at the same
//   position; switching episodes starts the new episode at 0.
// - Auto-advance to the next episode follows the stored
//   `hao_video_auto_next` preference (default on, Flutter parity).
//
// A-leg engine — VideoPlayerEngine:
// The player CORE (MPV / IJK / AVPlayer via PlayerKernel,
// episode/line state, resume, hard-decode verification) is A
// leg's VideoDriver, conformed to VideoPlayerEngine at merge
// (extension in Playback/VideoDriver.swift). This page talks to
// it ONLY through the protocol below. The coordinator path
// (requestVodPlay / driver seek) remains as the fallback when the
// engine is not attached, and the driver is configured before
// every such call — its resolver reads the context from
// configure, so an unconfigured request plays nothing. No fake
// position is ever shown. The native video SURFACE embeds the
// driver's video view (VideoDriverSurfaceView below); the danmaku
// overlay (A-leg layer, B-leg client) and the settings sheet
// (A-leg VodSettingsSheet) are wired in this file.

import SwiftUI
import MediaPlayer
import UIKit

/// What the video player UI needs from the A-leg player core.
/// Position / duration are the driver's live values; play calls
/// carry the resume position so a line switch resumes at the same
/// spot and an episode switch starts clean. `videoView` is the
/// native surface the page embeds; `currentEngine` + `diagnostics`
/// feed the settings sheet; `setVideoFit` applies the sheet's
/// picture-fit choice.
protocol VideoPlayerEngine: AnyObject {
    var positionSeconds: Double { get }
    var durationSeconds: Double { get }
    var isPlaying: Bool { get }
    /// True while an open is in flight (resolve + ladder); the
    /// page shows a spinner from this, never a bare black frame.
    var isLoading: Bool { get }
    /// True when the most recent open failed outright; the page
    /// shows the failure + a retry from this.
    var lastOpenFailed: Bool { get }
    /// The specific failure, when the most recent open failed
    /// (build 36, item 14, G-K) — the card shows its specific
    /// line instead of a generic "加载失败".
    var lastFailure: VideoPlaybackFailure? { get }
    /// Audio / subtitle tracks of the running backend (build 36,
    /// item 14, G-F) — the settings sheet pickers read these.
    var audioTracks: [VodTrackInfo] { get }
    var subtitleTracks: [VodTrackInfo] { get }
    var videoView: UIView? { get }
    var currentEngine: VideoEngine? { get }
    var diagnostics: VideoPlaybackDiagnostics { get }
    func play(detail: VideoDetail, lineIndex: Int, episodeIndex: Int, startPositionSeconds: Double)
    func playEpisode(lineIndex: Int, episodeIndex: Int, startPositionSeconds: Double)
    func setSpeed(_ speed: Double)
    func setVideoFit(_ fit: VideoFit)
    /// Select an audio / subtitle track by list position (-1 =
    /// default/auto for audio, -1 = no subtitles). The driver
    /// stores the pick and forwards it live when the backend can
    /// switch (build 36, item 14, G-F).
    func selectAudioTrack(index: Int)
    func selectSubtitleTrack(index: Int)
    func seek(to seconds: Double, completion: @escaping (Bool) -> Void)
    func pause()
    func resume()
    func stop()
    /// S7 wiring: the 影视播放器 settings the core applies.
    /// Enhancement / subtitle appearance / dialogue boost take
    /// effect live and are kept for the next open; `setAudioOnly`
    /// drops the video track (MPV only — other engines no-op);
    /// `reopenAtCurrentPosition` reopens a DV-P8 stream at its
    /// position when the downgrade switch flipped (false when
    /// nothing changed routing, so the caller reopens nothing).
    func applyVodEnhancement(_ branch: VodEnhancementBranch?)
    func setSubtitleAppearance(_ appearance: VodSubtitleAppearance)
    func setDialogueBoost(_ enabled: Bool)
    func setAudioOnly(_ audioOnly: Bool)
    @discardableResult
    func reopenAtCurrentPosition() -> Bool
    /// Re-open the current episode at its current position (the
    /// low-memory mode change path — the mpv property set is fixed
    /// at open). No-op when nothing is open. (Named
    /// `reopenEpisodeAtCurrentPosition`, not
    /// `reopenAtCurrentPosition`: A leg owns the latter name on the
    /// driver for DV-P8 routing only.)
    func reopenEpisodeAtCurrentPosition()
}

@MainActor
final class VideoPlayerViewModel: ObservableObject {
    @Published private(set) var detail: VideoDetail?
    @Published private(set) var lineIndex = 0
    @Published private(set) var episodeIndex = 0
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isDoubleSpeed = false
    @Published private(set) var seekFailed = false
    /// Loading / failure state, synced from the engine on every
    /// poll tick (the driver owns the truth; the page only mirrors
    /// it). The page shows a spinner while loading and a retry
    /// when the open failed — a failed open used to leave a black
    /// frame with a dead play button and no way back.
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    /// Specific failure line, synced from the engine on every poll
    /// tick (build 36, item 14, G-K). Nil while nothing failed.
    @Published private(set) var failureDetail: String?
    /// Track display names for the settings sheet pickers, synced
    /// from the engine on every poll tick (G-F). Empty until the
    /// backend publishes its track list; external subtitles carry
    /// the "（外挂）" source mark (G-G).
    @Published private(set) var audioTrackNames: [String] = []
    @Published private(set) var subtitleTrackNames: [String] = []
    /// Last track picks pushed to the driver (change guard, G-F):
    /// the stored -1 default must never be pushed as an explicit
    /// "turn subtitles off" — only a real change, or a stored
    /// non-default pick on the first push, is pushed.
    private var lastPushedAudioTrackIndex: Int?
    private var lastPushedSubtitleTrackIndex: Int?
    @Published var dragPosition: Double?
    /// Player settings (picture fit / speed / danmaku), persisted
    /// by VodSettingsState. Applied to the engine on attach and on
    /// every change (see applySettings).
    @Published var settings = VodSettingsState.load()
    /// Danmaku overlay state (A leg). Loaded per episode from the
    /// B-leg client; empty until then, never fake rows.
    let danmaku = VodDanmakuLayerState()
    private var danmakuProvider: VodDanmakuProvider?

    /// The A-leg engine, attached by the player view from
    /// `coordinator.vodDriver` (cast to VideoPlayerEngine at merge).
    weak var engine: VideoPlayerEngine?

    private let coordinator: PlaybackCoordinator
    private var pollTimer: Timer?
    private var didAutoAdvance = false
    private var lastSavedPosition = 0.0

    /// Skip-intro state (S7 wiring). The pill label is published
    /// for the view; the pure state machine owns the countdown and
    /// the once-per-episode auto flags.
    private var skipState = VodSkipIntroState()
    private var skipEpisodeIdentity: String?
    @Published private(set) var skipIntroPill: String?
    @Published private(set) var skipCreditsPill = false

    /// The shared settings store (S7 wiring). Nil in tests that
    /// construct the view model without one — every read below
    /// falls back to the Flutter default, so behaviour is
    /// identical with or without it.
    private let appSettings: SettingsStore?

    /// The driver behind the engine (or the coordinator's when
    /// the engine is not attached yet — same object).
    private var vodDriver: VideoDriver? {
        (engine as? VideoDriver) ?? (coordinator.vodDriver as? VideoDriver)
    }

    init(coordinator: PlaybackCoordinator, settings: SettingsStore? = nil) {
        self.coordinator = coordinator
        self.appSettings = settings
    }

    deinit {
        pollTimer?.invalidate()
    }

    var currentLine: PlayLine? {
        guard let detail = detail, detail.lines.indices.contains(lineIndex) else { return nil }
        return detail.lines[lineIndex]
    }

    var currentEpisode: PlayEpisode? { currentLine?.episode(at: episodeIndex) }

    var hasNextEpisode: Bool {
        guard let line = currentLine else { return false }
        return episodeIndex + 1 < line.episodes.count
    }

    var isEngineAttached: Bool { engine != nil }

    /// Engine + diagnostics for the settings sheet (nil / .empty
    /// until the engine attaches).
    var currentEngine: VideoEngine? { engine?.currentEngine }
    var diagnostics: VideoPlaybackDiagnostics { engine?.diagnostics ?? .empty }

    /// Push the settings to the engine + danmaku layer and persist
    /// them. Called on engine attach and on every settings change.
    /// Audio / subtitle track picks are pushed to the driver,
    /// which stores them and forwards them live to a capable
    /// backend (MPV `aid` / `sid`, AVPlayer media selection —
    /// build 36, item 14, G-F).
    func applySettings() {
        settings.persist()
        pushVodSettingsToDriver()
        guard let engine = engine else { return }
        engine.setSpeed(settings.playbackSpeed)
        engine.setVideoFit(settings.videoFit)
        danmaku.isEnabled = settings.danmakuEnabled
        danmaku.opacity = settings.danmakuOpacity
    }

    /// Push the 影视播放器 settings into the driver (S7 wiring).
    /// Called on engine attach (via applySettings) and on open, so
    /// a value changed while the player was closed still lands
    /// before the first frame. The driver stores them and applies
    /// to the backend live + at every open.
    func pushVodSettingsToDriver() {
        pushDvP8ToDriver()
        pushEnhancementToDriver()
        pushSubtitleAppearanceToDriver()
        pushDialogueBoostToDriver()
        pushTrackPicksToDriver()
    }

    /// Push the audio / subtitle track picks into the driver
    /// (build 36, item 14, G-F). Only a CHANGED pick is pushed,
    /// and on the first push only a stored non-default pick: the
    /// stored -1 default is "never picked", and pushing it would
    /// force the backend's auto-selected subtitles off. The
    /// driver stores the pick and re-applies it at every open, so
    /// a pick made before the backend existed still lands.
    private func pushTrackPicksToDriver() {
        if let last = lastPushedAudioTrackIndex {
            if settings.audioTrackIndex != last {
                lastPushedAudioTrackIndex = settings.audioTrackIndex
                vodDriver?.selectAudioTrack(index: settings.audioTrackIndex)
            }
        } else {
            lastPushedAudioTrackIndex = settings.audioTrackIndex
            if settings.audioTrackIndex >= 0 {
                vodDriver?.selectAudioTrack(index: settings.audioTrackIndex)
            }
        }
        if let last = lastPushedSubtitleTrackIndex {
            if settings.subtitleTrackIndex != last {
                lastPushedSubtitleTrackIndex = settings.subtitleTrackIndex
                vodDriver?.selectSubtitleTrack(index: settings.subtitleTrackIndex)
            }
        } else {
            lastPushedSubtitleTrackIndex = settings.subtitleTrackIndex
            if settings.subtitleTrackIndex >= 0 {
                vodDriver?.selectSubtitleTrack(index: settings.subtitleTrackIndex)
            }
        }
    }

    private func pushDvP8ToDriver() {
        let value = appSettings?.dvP8Downgrade ?? true
        lastAppliedDvP8Downgrade = value
        vodDriver?.dvP8Downgrade = value
    }

    private func pushEnhancementToDriver() {
        let branch = resolveVodEnhancement(
            superResolution: appSettings?.superResolution ?? false,
            interpolation: appSettings?.interpolation ?? false,
            sdrToHdr: appSettings?.sdrToHDR ?? false
        )
        vodDriver?.applyVodEnhancement(branch)
    }

    private func pushSubtitleAppearanceToDriver() {
        let appearance = VodSubtitleAppearance.forTiers(
            fontSize: appSettings?.subtitleFontSize ?? "medium",
            color: appSettings?.subtitleColor ?? "white",
            position: appSettings?.subtitlePosition ?? "bottom"
        )
        vodDriver?.setSubtitleAppearance(appearance)
    }

    /// Push the dialogue-boost switch into the driver (wiring
    /// follow-up: the 17th dead key). The source is the sheet
    /// state, not the settings store — the sheet and the
    /// settings page share one UserDefaults key, and the sheet
    /// state is the one the player just changed; the view syncs
    /// it from the settings store when the page-side switch
    /// flips while the player is open (see the onChange below).
    /// The driver stores it and applies it live + at every
    /// open; a backend without the capability (AVPlayer/IJK)
    /// no-ops.
    private func pushDialogueBoostToDriver() {
        vodDriver?.setDialogueBoost(settings.dialogueBoostEnabled)
    }

    /// Last DV-P8 value pushed to the driver. The settings page
    /// can flip it while the player is open; the view calls this
    /// on change (Flutter `_onPlaybackSettingsChanged` parity:
    /// only an AVPlayer-backed P8 stream reopens — on MPV/IJK the
    /// switch changes no decode parameter, so no re-open).
    private var lastAppliedDvP8Downgrade = true

    func applyDvP8DowngradeIfChanged() {
        let current = appSettings?.dvP8Downgrade ?? true
        guard current != lastAppliedDvP8Downgrade else { return }
        lastAppliedDvP8Downgrade = current
        vodDriver?.dvP8Downgrade = current
        _ = vodDriver?.reopenAtCurrentPosition()
    }

    /// Double-tap seek (S7 wiring): left third back, right third
    /// forward by the persisted step; middle third is not a seek.
    /// The step comes from the caller (the view reads the live
    /// setting), so a settings change applies to the next
    /// double-tap without reattaching the engine.
    func doubleTapSeek(atX x: CGFloat, width: CGFloat, seconds: Int) {
        let delta = VodGestureMath.seekDelta(x: x, width: width, seconds: Double(seconds))
        guard delta != 0 else { return }
        let target = resolveDoubleTapSeek(position: position, duration: duration, forward: delta > 0, seconds: abs(delta))
        seek(to: target)
    }

    /// Re-open the current episode at its position (low-memory mode
    /// change while playing — Flutter
    /// native_video_player_page._reopenAtCurrentPosition). The
    /// engine path re-opens through the driver; the seam path (no
    /// engine attached) goes through the driver's own reopen, whose
    /// context was set by open(). No-op when no episode is open.
    func reopenEpisodeAtCurrentPosition() {
        guard detail != nil, currentEpisode != nil else { return }
        if let engine = engine {
            engine.reopenEpisodeAtCurrentPosition()
        } else {
            (coordinator.vodDriver as? VideoDriver)?.reopenEpisodeAtCurrentPosition()
        }
    }

    /// Seam path only (engine not attached): the driver's resolver
    /// reads its context from `configure` — a requestVodPlay without
    /// it resolves to nil and plays nothing. The engine path never
    /// needs this (its play calls carry detail/line/episode).
    private func configureDriver(detail: VideoDetail, line: PlayLine, episode: PlayEpisode, resumeFrom: Double) {
        (coordinator.vodDriver as? VideoDriver)?.configure(
            detail: detail, line: line, episode: episode, resumeFrom: resumeFrom)
    }

    /// PlaybackItem id for the current episode (resume key —
    /// the coordinator, history and resume all use this string).
    private func playbackItem(for detail: VideoDetail, episode: PlayEpisode) -> PlaybackItem {
        PlaybackItem(
            id: VideoResumeKey.episodeId(
                title: detail.item.title, year: detail.item.year, episodeName: episode.name),
            kind: .vod,
            title: detail.item.title,
            artist: episode.name,
            coverURL: detail.item.coverURL)
    }

    /// Open a title at one episode. Called by the detail page.
    /// The resume position comes from the library store; the
    /// engine (or the driver's own resume read) seeks to it.
    /// Re-opening the episode that is already playing does not
    /// restart it.
    func open(detail: VideoDetail, lineIndex: Int, episodeIndex: Int) {
        if self.detail?.item.title == detail.item.title,
           self.detail?.item.year == detail.item.year,
           self.lineIndex == lineIndex, self.episodeIndex == episodeIndex,
           isPlaying {
            return
        }
        self.detail = detail
        self.lineIndex = lineIndex
        self.episodeIndex = episodeIndex
        didAutoAdvance = false
        lastSavedPosition = 0
        guard let episode = currentEpisode else { return }
        let resume = VideoLibraryStore.resumeInfo(title: detail.item.title, year: detail.item.year)
        let startPosition: Double
        if let resume = resume, resume.episodeName == episode.name {
            startPosition = resume.positionSeconds
        } else {
            startPosition = 0
        }
        position = startPosition
        // The stored duration belongs to the resume episode only:
        // a tap on another episode used to display the old
        // episode's duration until the first poll tick corrected
        // it. Any other episode starts at an unknown duration (0).
        duration = (resume?.episodeName == episode.name) ? (resume?.durationSeconds ?? 0) : 0
        recordHistory(position: startPosition)
        // Danmaku for this title (B-leg client, read-only). The
        // layer no-ops on a re-load of the same episode.
        danmakuProvider = VodDanmakuClient(title: detail.item.title, year: detail.item.year ?? "")
        danmaku.load(for: episode, provider: danmakuProvider)
        // S7 wiring: the 影视播放器 settings land before the first
        // frame (the driver stores them and applies at open).
        pushVodSettingsToDriver()
        skipIntroPill = nil
        skipCreditsPill = false
        skipEpisodeIdentity = nil
        if let engine = engine {
            engine.play(
                detail: detail, lineIndex: lineIndex, episodeIndex: episodeIndex,
                startPositionSeconds: startPosition)
        } else {
            guard let line = currentLine else { return }
            configureDriver(detail: detail, line: line, episode: episode, resumeFrom: startPosition)
            coordinator.requestVodPlay(playbackItem(for: detail, episode: episode))
        }
        startPolling()
    }

    /// Attach the A-leg engine (called by the player view on
    /// appear). Attaching never restarts playback — it only starts
    /// the position poll.
    func attachEngine(_ newEngine: VideoPlayerEngine?) {
        engine = newEngine
        if newEngine != nil {
            applySettings()
            startPolling()
        }
    }

    /// Switch episodes (starts at 0). The previous episode's
    /// position is saved first.
    func selectEpisode(_ index: Int) {
        guard let detail = detail, currentLine?.episode(at: index) != nil else { return }
        saveCurrentPosition()
        // The periodic resume save keys off this value: leaving
        // the old episode's position here stalled all saves for
        // the new episode until its position passed the old one
        // (+15 s), so a kill in that window lost the new resume.
        lastSavedPosition = 0
        episodeIndex = index
        didAutoAdvance = false
        position = 0
        skipIntroPill = nil
        skipCreditsPill = false
        if let engine = engine {
            engine.playEpisode(lineIndex: lineIndex, episodeIndex: index, startPositionSeconds: 0)
        } else if let episode = currentEpisode, let line = currentLine {
            configureDriver(detail: detail, line: line, episode: episode, resumeFrom: 0)
            coordinator.requestVodPlay(playbackItem(for: detail, episode: episode))
        }
        if let episode = currentEpisode {
            danmaku.load(for: episode, provider: danmakuProvider)
        }
        recordHistory(position: 0)
    }

    /// Switch lines, keeping the episode and resuming at the same
    /// position (the driver owns the resume; the position is passed
    /// explicitly so a switch never restarts from 0).
    func selectLine(_ index: Int) {
        guard let detail = detail, detail.lines.indices.contains(index) else { return }
        let line = detail.lines[index]
        guard !line.episodes.isEmpty else { return }
        saveCurrentPosition()
        // Same periodic-save reset as selectEpisode (see there).
        lastSavedPosition = 0
        // A shorter line may not carry this episode: clamp to its
        // last episode (from 0) instead of silently ignoring the
        // tap — a tap that does nothing is a dead end.
        let previousEpisode = episodeIndex
        let targetEpisode = min(episodeIndex, line.episodes.count - 1)
        let resumePosition = targetEpisode == previousEpisode ? position : 0
        lineIndex = index
        episodeIndex = targetEpisode
        didAutoAdvance = false
        if targetEpisode != previousEpisode {
            position = 0
            skipIntroPill = nil
            skipCreditsPill = false
        }
        if let engine = engine {
            engine.playEpisode(
                lineIndex: index, episodeIndex: targetEpisode,
                startPositionSeconds: resumePosition)
        } else if let episode = line.episode(at: targetEpisode) {
            configureDriver(detail: detail, line: line, episode: episode, resumeFrom: resumePosition)
            coordinator.requestVodPlay(playbackItem(for: detail, episode: episode))
        }
        if targetEpisode != previousEpisode, let episode = currentEpisode {
            danmaku.load(for: episode, provider: danmakuProvider)
        }
        recordHistory(position: resumePosition)
    }

    func playNextEpisode() {
        guard hasNextEpisode else { return }
        selectEpisode(episodeIndex + 1)
    }

    func togglePlayPause() {
        if let engine = engine {
            if engine.isPlaying { engine.pause() } else { engine.resume() }
            isPlaying = engine.isPlaying
            return
        }
        // Seam path (no engine): pause = stop the driver (it saves
        // the resume), resume = request the same episode again.
        if isPlaying {
            coordinator.vodDriver?.stop()
            isPlaying = false
            saveCurrentPosition()
        } else if let detail = detail, let episode = currentEpisode {
            coordinator.requestVodPlay(playbackItem(for: detail, episode: episode))
            isPlaying = true
        }
    }

    /// Seek once (on drag release). On failure the bar rolls back
    /// to the real position and a toast shows (P0-05).
    func seek(to seconds: Double) {
        let target = min(max(0, seconds), max(0, duration))
        dragPosition = nil
        seekFailed = false
        if let engine = engine {
            engine.seek(to: target) { [weak self] ok in
                guard let self = self else { return }
                if ok {
                    self.position = target
                } else {
                    self.seekFailed = true
                    self.position = engine.positionSeconds
                }
            }
            return
        }
        coordinator.vodDriver?.seek(to: target) { [weak self] ok in
            guard let self = self else { return }
            if ok {
                self.position = target
            } else {
                self.seekFailed = true
                // Same rollback as the engine path: the driver
                // republishes the real position on a failed seek,
                // so read it back instead of leaving the bar on
                // the target that never landed.
                self.position = (self.coordinator.vodDriver as? VideoDriver)?.position ?? self.position
            }
        }
    }

    func clearSeekFailed() {
        seekFailed = false
    }

    /// Retry the current episode after a failed open: re-open it
    /// through open(), which re-reads the saved resume (the failed
    /// attempt saved the breakpoint on stop) and clears the failure
    /// flag on the next request. No-op when nothing is open.
    func retry() {
        guard let detail = detail else { return }
        loadFailed = false
        open(detail: detail, lineIndex: lineIndex, episodeIndex: episodeIndex)
    }

    /// Long-press 2x (VOD only). Only the engine can change speed;
    /// without one the gesture does nothing and shows no badge.
    /// Releasing restores the speed the user picked in settings,
    /// not a hardcoded 1.0 (a 1.5x user must not drop to 1.0
    /// because they long-pressed once).
    func setDoubleSpeed(_ on: Bool) {
        guard let engine = engine else { return }
        isDoubleSpeed = on
        engine.setSpeed(on ? 2.0 : settings.playbackSpeed)
    }

    // MARK: - Brightness (player-only, never restored on exit)

    /// Brightness level (0...1) the brightness sheet shows while
    /// dragging. Written to the screen only from an explicit user
    /// drag (see setBrightness); entering / leaving the player
    /// never writes it.
    @Published private(set) var brightnessLevel: Double = 0.5

    /// System brightness as it was when the player was entered.
    /// Recorded, never written back: leaving the player does not
    /// restore or override the brightness the user set (iron law —
    /// the app never changes system brightness by itself).
    private var entryBrightness: Double?

    /// Whether brightness writes are armed (only while the player
    /// is open).
    private var brightnessArmed = false

    /// Call when the player appears: remember the system
    /// brightness as it is NOW and arm brightness writes. Nothing
    /// is written to the screen here.
    func notePlayerEntry() {
        entryBrightness = Double(UIScreen.main.brightness)
        brightnessLevel = entryBrightness ?? 0.5
        brightnessArmed = true
    }

    /// Apply a brightness level from an explicit user drag. Only
    /// while the player is active: outside the entry/exit window
    /// the state still updates (so the UI never lies about the
    /// drag) but the screen is not touched. On exit the level is
    /// deliberately left as the user set it — never restored.
    func setBrightness(_ level: Double) {
        let clamped = min(1, max(0, level))
        brightnessLevel = clamped
        guard brightnessArmed else {
            return
        }
        UIScreen.main.brightness = CGFloat(clamped)
    }

    /// Disarm brightness writes when the player closes. No screen
    /// write happens here.
    func disarmBrightness() {
        brightnessArmed = false
        entryBrightness = nil
    }

    /// Close the player: save the position and stop playback.
    /// VOD has no background-audio path (live only), so closing
    /// stops the driver and clears the current item.
    func close() {
        saveCurrentPosition()
        danmaku.clear()
        pollTimer?.invalidate()
        pollTimer = nil
        if let engine = engine {
            engine.stop()
        }
        coordinator.stop()
        isPlaying = false
    }

    // MARK: - Position poll

    private func startPolling() {
        pollTimer?.invalidate()
        // The timer is scheduled on the main runloop, so its block
        // already runs on the main thread; the async hop keeps the
        // @MainActor call explicit (no Swift 5.5+ Task anywhere).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.pollTick()
            }
        }
    }

    private func pollTick() {
        guard let engine = engine else { return }
        position = engine.positionSeconds
        duration = engine.durationSeconds
        isPlaying = engine.isPlaying
        // Loading / failure mirror (see the published flags): the
        // driver owns the truth, the page only shows it.
        isLoading = engine.isLoading
        loadFailed = engine.lastOpenFailed
        // (Build 36, item 14, G-K/G-F) Specific failure line and
        // track lists, mirrored from the engine on every tick.
        failureDetail = engine.lastFailure?.displayLine
        audioTrackNames = engine.audioTracks.map { $0.displayName + ($0.isExternal ? "（外挂）" : "") }
        subtitleTrackNames = engine.subtitleTracks.map { $0.displayName + ($0.isExternal ? "（外挂）" : "") }
        // Resume save: once the position crosses 5 s, then every
        // ~15 s of playback.
        if isPlaying && position >= VideoLibraryStore.minSaveSeconds
            && (lastSavedPosition < VideoLibraryStore.minSaveSeconds
                || position - lastSavedPosition >= 15) {
            saveCurrentPosition()
        }
        // Auto-advance at the end (once per episode).
        if isPlaying && duration > 0 && position >= duration - 1.0 && !didAutoAdvance {
            didAutoAdvance = true
            let autoNext = UserDefaults.standard.object(forKey: "hao_video_auto_next") as? Bool ?? true
            if autoNext && hasNextEpisode {
                playNextEpisode()
            }
        }
        // Skip-intro / skip-credits check (S7 wiring, every tick).
        checkSkipPoints()
    }

    /// One skip check, driven by the position poll (every 0.5 s).
    /// The mode is read live from SettingsStore, so a settings
    /// change applies to the episode already playing. The window
    /// resolves once per episode (Emby chapter markers, else the
    /// per-episode custom seconds).
    private func checkSkipPoints() {
        guard let episode = currentEpisode, let detail = detail else {
            skipIntroPill = nil
            skipCreditsPill = false
            return
        }
        let identity = "\(lineIndex)-\(episodeIndex)-\(episode.name)"
        if identity != skipEpisodeIdentity {
            skipEpisodeIdentity = identity
            skipState.resetForEpisode(window: skipWindow(for: detail, episode: episode), creditsStart: episode.creditsStart)
        }
        let mode = VodSkipIntroMode.fromStored(appSettings?.skipIntroMode ?? "off")
        let action = skipState.check(position: position, duration: duration, mode: mode, isPlaying: isPlaying, elapsed: 0.5)
        switch action {
        case .none:
            skipIntroPill = nil
            skipCreditsPill = false
        case .showIntroPill(let countdown):
            if let countdown = countdown {
                skipIntroPill = "跳过片头 \(countdown)s"
            } else {
                skipIntroPill = "跳过片头"
            }
            skipCreditsPill = false
        case .skipIntro(let target):
            skipIntroPill = nil
            skipCreditsPill = false
            seek(to: target)
        case .showCreditsPill:
            skipCreditsPill = true
        case .advanceNextEpisode:
            skipIntroPill = nil
            skipCreditsPill = false
            advanceToNextEpisodeForCredits()
        }
    }

    /// Resolve one episode's intro window: Emby chapter markers
    /// first, else the per-episode custom seconds (CMS).
    private func skipWindow(for detail: VideoDetail, episode: PlayEpisode) -> VodSkipWindow? {
        let custom = VodSkipIntroDurations.customSeconds(title: detail.item.title, episodeName: episode.name)
        return resolveIntroWindow(introStart: episode.introStart, introEnd: episode.introEnd, customSeconds: custom)
    }

    /// The intro pill tap: seek to the end of the intro window now.
    func skipIntroNow() {
        guard let episode = currentEpisode, let detail = detail,
              let window = skipWindow(for: detail, episode: episode) else { return }
        skipIntroPill = nil
        seek(to: window.end)
    }

    /// The credits pill tap: advance when there is a next episode,
    /// else let the episode play out to its natural end (no end
    /// card is forced here).
    func skipCreditsNow() {
        skipCreditsPill = false
        advanceToNextEpisodeForCredits()
    }

    private func advanceToNextEpisodeForCredits() {
        guard hasNextEpisode else { return }
        playNextEpisode()
    }

    /// App backgrounded (S7 wiring, Flutter lifecycle parity):
    /// audio-only on → drop to audio-only and keep playing; off →
    /// pause (and stay paused on return — never surprise audio,
    /// never background data burn). No engine attached, no-op.
    func handleBackground() {
        guard let engine = engine else { return }
        if appSettings?.audioOnlyBackground ?? false {
            engine.setAudioOnly(true)
            return
        }
        if isPlaying {
            engine.pause()
            isPlaying = false
        }
    }

    /// App foregrounded: restore the video track when the
    /// audio-only switch is on (playback never stopped); when it
    /// is off and the background paused us, stay paused — the user
    /// resumes with the play button.
    func handleForeground() {
        guard let engine = engine else { return }
        if appSettings?.audioOnlyBackground ?? false {
            engine.setAudioOnly(false)
        }
    }

    private func saveCurrentPosition() {
        guard let detail = detail, let episode = currentEpisode else { return }
        lastSavedPosition = position
        VideoLibraryStore.savePosition(
            item: detail.item, episodeName: episode.name, episodeIndex: episodeIndex,
            lineName: currentLine?.name ?? "", positionSeconds: position,
            durationSeconds: duration)
    }

    private func recordHistory(position: Double) {
        guard let detail = detail, let episode = currentEpisode else { return }
        VideoLibraryStore.savePosition(
            item: detail.item, episodeName: episode.name, episodeIndex: episodeIndex,
            lineName: currentLine?.name ?? "", positionSeconds: position,
            durationSeconds: duration)
    }
}

/// Fullscreen VOD player. Landscape from the moment it appears.
struct VideoPlayerView: View {
    @EnvironmentObject private var videoPlayer: VideoPlayerViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.haoTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var controlsVisible = true
    @State private var showingMore = false
    /// A seek drag is in progress: the auto-hide timer is paused
    /// until release (the bar must not vanish mid-drag).
    @State private var isSeekDragging = false
    @State private var autoHideWork: DispatchWorkItem?
    /// Single/double-tap disambiguation (build 36, item 9): every
    /// tap-up feeds `tapDisambiguator`; the first tap waits
    /// `doubleTapWindowSeconds` for a second tap (pending work
    /// below), the second tap fires the double-tap at once. The
    /// single tap therefore lags ≤0.28 s — the price of a
    /// double-tap that never flashes the controls.
    @State private var tapDisambiguator = VodTapDisambiguator()
    @State private var pendingSingleTapWork: DispatchWorkItem?
    /// Middle double-tap feedback: a brief centre pause/play icon
    /// (white on the same black 0.45 scrim as the top-bar buttons
    /// — no new style, no new colour). `pauseFlashShowsPause`
    /// picks the icon for the NEW state after the toggle.
    @State private var pauseFlashVisible = false
    @State private var pauseFlashShowsPause = true
    @State private var pauseFlashWork: DispatchWorkItem?
    /// Landscape state. Only the [ ] button changes it — turning
    /// the phone never does (live parity: LiveRoomView
    /// isFullscreen). Starts true: tap-play enters landscape.
    @State private var isLandscape = true

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            VideoPlayerSurface()
            // Danmaku overlay (A-leg layer, B-leg client). Above
            // the video, below the chrome; never intercepts taps.
            VodDanmakuLayer(state: videoPlayer.danmaku, position: videoPlayer.position)
            // Gesture layer, UNDER the chrome: a tap toggles the
            // controls, a long press is 2x (VOD only). Chrome buttons
            // sit above it and keep their own taps.
            //
            // Build 36, item 9 — single vs double tap: the tap-up
            // goes through VodTapDisambiguator instead of a bare
            // onTapGesture, because the old pair (onTapGesture +
            // simultaneous double-tap) fired the single-tap toggle
            // on EVERY tap of a double-tap — the controls flipped
            // twice and flashed. Now the first tap waits 0.28 s
            // for a second tap; a double-tap fires at once (middle
            // third = play/pause, sides = ±seek by the live
            // SettingsStore step) and the pending single is
            // dropped, so the controls never move on a double-tap.
            // Long-press 2x is untouched: a double-tap's two quick
            // presses never reach the 0.5 s threshold.
            Color.clear
                .contentShape(Rectangle())
                .simultaneousGesture(
                    SpatialTapGesture(count: 1).onEnded { value in
                        handleVideoTap(at: value.location)
                    }
                )
                .onLongPressGesture(minimumDuration: VodGestureConfig.longPressMinimumDuration, pressing: { pressing in
                    videoPlayer.setDoubleSpeed(pressing)
                }, perform: {})
            if controlsVisible {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomControls
                }
            }
            if videoPlayer.isDoubleSpeed {
                Text("2x")
                    .font(.haoSubheadStrong)
                    .foregroundStyle(haoOnAccentFor(theme.accentOnVideo))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme.accentOnVideo, in: Capsule())
            }
            // Build 36, item 9: middle double-tap feedback — a
            // brief centre pause/play icon for the new state.
            // Same white-on-black-scrim treatment as the top-bar
            // buttons; fades out after 0.7 s.
            if pauseFlashVisible {
                Image(systemName: pauseFlashShowsPause ? "pause.fill" : "play.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 96, height: 96)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            if videoPlayer.seekFailed {
                VStack {
                    Spacer()
                    Text("定位失败，已回到实际位置")
                        .font(.haoFootnoteMedium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.7), in: Capsule())
                        .padding(.bottom, 120)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                videoPlayer.clearSeekFailed()
                            }
                        }
                }
            }
            // Loading / failure state (B3): a spinner while the
            // open is in flight, and a failure card with a retry
            // when it failed outright — never a bare black frame
            // with a dead play button. The stack is content-sized
            // and centred, so taps outside it still reach the
            // gesture layer underneath.
            if videoPlayer.loadFailed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.8))
                    Text("加载失败")
                        .font(.haoCalloutStrong)
                        .foregroundStyle(.white)
                    Text(videoPlayer.failureDetail ?? "该集暂时无法播放，换个线路或重试。")
                        .font(.haoFootnote)
                        .foregroundStyle(.white.opacity(0.72))
                    Button("重试") { videoPlayer.retry() }
                        .font(.haoSubheadStrong)
                        .foregroundStyle(haoOnAccentFor(theme.accentOnVideo))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(theme.accentOnVideo, in: Capsule())
                        .buttonStyle(.plain)
                }
            } else if videoPlayer.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text("正在加载…")
                        .font(.haoDenseBody)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            // S7 wiring: skip-intro / skip-credits pills. Shown
            // regardless of controlsVisible — the auto3s countdown
            // is time-sensitive, and a tap seeks at once.
            if videoPlayer.skipIntroPill != nil || videoPlayer.skipCreditsPill {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        if let pill = videoPlayer.skipIntroPill {
                            Button(pill) { videoPlayer.skipIntroNow() }
                                .font(.haoDenseTitle)
                                .foregroundStyle(haoOnAccentFor(theme.accentOnVideo))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(theme.accentOnVideo, in: Capsule())
                                .buttonStyle(.plain)
                        }
                        if videoPlayer.skipCreditsPill {
                            Button("跳过片尾") { videoPlayer.skipCreditsNow() }
                                .font(.haoDenseTitle)
                                .foregroundStyle(haoOnAccentFor(theme.accentOnVideo))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(theme.accentOnVideo, in: Capsule())
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 120)
                }
            }
        }
        .onAppear {
            VideoOrientation.lockLandscape()
            isLandscape = true
            videoPlayer.notePlayerEntry()
            videoPlayer.attachEngine(coordinator.vodDriver as? VideoPlayerEngine)
            showControlsTemporarily()
        }
        .onDisappear {
            autoHideWork?.cancel()
            pendingSingleTapWork?.cancel()
            pauseFlashWork?.cancel()
            videoPlayer.disarmBrightness()
            VideoOrientation.unlockPortrait()
        }
        .onChange(of: isLandscape) { _, landscape in
            if landscape {
                VideoOrientation.lockLandscape()
            } else {
                VideoOrientation.unlockPortrait()
            }
        }
        .onChange(of: videoPlayer.isPlaying) { _, playing in
            if playing {
                showControlsTemporarily()
            } else {
                autoHideWork?.cancel()
            }
        }
        .onChange(of: showingMore) { _, showing in
            if !showing {
                showControlsTemporarily()
            }
        }
        .sheet(isPresented: $showingMore) {
            VodSettingsSheet(
                state: $videoPlayer.settings,
                engine: videoPlayer.currentEngine ?? .avplayer,
                diagnostics: videoPlayer.diagnostics,
                audioTracks: videoPlayer.audioTrackNames,
                subtitleTracks: videoPlayer.subtitleTrackNames,
                brightness: Binding(
                    get: { videoPlayer.brightnessLevel },
                    set: { videoPlayer.setBrightness($0) }
                ),
                danmaku: videoPlayer.danmaku,
                detail: videoPlayer.detail,
                lineIndex: videoPlayer.lineIndex,
                episodeIndex: videoPlayer.episodeIndex,
                onSelectLine: { videoPlayer.selectLine($0) },
                onSelectEpisode: { videoPlayer.selectEpisode($0) }
            )
        }
        .onChange(of: videoPlayer.settings) { _, _ in
            videoPlayer.applySettings()
        }
        // S7 wiring: the 影视播放器 settings apply live to the
        // episode already playing (no restart, no re-open —
        // except the DV-P8 switch, which reopens an
        // AVPlayer-backed P8 stream at its position).
        .onChange(of: settingsStore.subtitleFontSize) { _, _ in
            videoPlayer.applySettings()
        }
        .onChange(of: settingsStore.subtitleColor) { _, _ in
            videoPlayer.applySettings()
        }
        .onChange(of: settingsStore.subtitlePosition) { _, _ in
            videoPlayer.applySettings()
        }
        .onChange(of: settingsStore.superResolution) { _, _ in
            videoPlayer.applySettings()
        }
        .onChange(of: settingsStore.interpolation) { _, _ in
            videoPlayer.applySettings()
        }
        .onChange(of: settingsStore.sdrToHDR) { _, _ in
            videoPlayer.applySettings()
        }
        .onChange(of: settingsStore.dialogueBoost) { _, newValue in
            // Wiring follow-up: the settings page and the
            // in-player sheet share one key. Sync the sheet
            // state first — applySettings persists the sheet
            // state, so pushing the stale one would clobber the
            // switch the user just flipped. The sync itself
            // triggers the settings onChange above, so this
            // applySettings is the belt to the same braces.
            videoPlayer.settings.dialogueBoostEnabled = newValue
            videoPlayer.applySettings()
        }
        .onChange(of: settingsStore.dvP8Downgrade) { _, _ in
            videoPlayer.applyDvP8DowngradeIfChanged()
        }
        .onChange(of: settingsStore.lowMemoryMode) { _, _ in
            // Wiring leg B: the mpv property set is fixed at open,
            // so a mode change while an episode is playing re-opens
            // it at its position (Flutter's player-page listener).
            // Fires only while this view is mounted; a change made
            // while no episode is open applies at the next open.
            videoPlayer.reopenEpisodeAtCurrentPosition()
        }
        .statusBarHidden(true)
    }

    // MARK: - Chrome (on-video white on a dark scrim — the same
    // forced-dark treatment as the S2 immersive music player: the
    // video frame is the background, not the theme scaffold).

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: {
                videoPlayer.close()
                dismiss()
            }) {
                Image(systemName: "xmark")
                    .font(.haoBodyStrong)
                    .foregroundStyle(theme.accentOnVideo)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(videoPlayer.detail?.item.title ?? "")
                    .font(.haoCalloutStrong)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(videoPlayer.currentEpisode?.displayName ?? "")
                    .font(.haoFootnote)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            Spacer()
            // The single "更多" entry: brightness / volume, speed
            // (VOD only), danmaku switch, episode picker all live
            // in one sheet — no button pile-up on the bar. No
            // quality button anywhere on VOD (iron law: one play
            // URL per episode, no quality tiers).
            Button(action: { showingMore = true }) {
                Image(systemName: "ellipsis")
                    .font(.haoBodyStrong)
                    .foregroundStyle(theme.accentOnVideo)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
                startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - Controls auto-hide (3 s while playing, live parity)

    /// Show the controls and hide them again 3 s later while
    /// playing. Paused playback keeps the controls up; a seek drag
    /// pauses the timer until release (the bar must not vanish
    /// mid-drag). A no-op when the player is paused.
    private func showControlsTemporarily() {
        autoHideWork?.cancel()
        controlsVisible = true
        guard videoPlayer.isPlaying, !isSeekDragging else { return }
        let work = DispatchWorkItem { [self] in
            guard self.videoPlayer.isPlaying, !self.isSeekDragging else { return }
            self.controlsVisible = false
        }
        autoHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func hideControls() {
        autoHideWork?.cancel()
        controlsVisible = false
    }

    // MARK: - Tap disambiguation (build 36, item 9)

    /// One tap-up from the gesture layer. The disambiguator
    /// decides: first tap → wait for a possible second tap (the
    /// single-tap toggle fires only when the window expires);
    /// second tap inside the window → the double-tap for its zone
    /// at once, pending single dropped. `.singleTap` never arrives
    /// here (the expiry work item handles it).
    private func handleVideoTap(at location: CGPoint) {
        let outcome = tapDisambiguator.tap(
            at: Date().timeIntervalSinceReferenceDate,
            x: location.x,
            width: UIScreen.main.bounds.width
        )
        switch outcome {
        case .wait:
            pendingSingleTapWork?.cancel()
            let work = DispatchWorkItem { [self] in
                guard self.tapDisambiguator.expirePending(
                    at: Date().timeIntervalSinceReferenceDate
                ) == .singleTap else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    if self.controlsVisible {
                        self.hideControls()
                    } else {
                        self.showControlsTemporarily()
                    }
                }
            }
            pendingSingleTapWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + VodGestureConfig.doubleTapWindowSeconds,
                execute: work
            )
        case .singleTap:
            break
        case .doubleTap(let zone):
            pendingSingleTapWork?.cancel()
            handleDoubleTap(zone: zone, x: location.x)
        }
    }

    /// A double-tap, by zone. Sides keep their ±seek (step read
    /// live from SettingsStore, `doubleTapSeconds` untouched);
    /// the middle reuses the bottom play button's toggle — no
    /// second playback state machine — then keeps the controls up
    /// (paused playback never auto-hides: `showControlsTemporarily`
    /// is a no-op for the timer while paused, and the
    /// `isPlaying` onChange cancels any pending hide) and flashes
    /// the pause/play icon for the new state.
    private func handleDoubleTap(zone: VodDoubleTapZone, x: CGFloat) {
        switch zone {
        case .seekBack, .seekForward:
            videoPlayer.doubleTapSeek(
                atX: x,
                width: UIScreen.main.bounds.width,
                seconds: settingsStore.doubleTapSeconds
            )
        case .togglePlayPause:
            videoPlayer.togglePlayPause()
            pauseFlashShowsPause = !videoPlayer.isPlaying
            showPauseFlash()
            showControlsTemporarily()
        }
    }

    /// Show the centre pause/play flash for 0.7 s.
    private func showPauseFlash() {
        pauseFlashWork?.cancel()
        pauseFlashVisible = true
        let work = DispatchWorkItem { [self] in
            self.pauseFlashVisible = false
        }
        pauseFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            VideoSeekBar(
                position: videoPlayer.dragPosition ?? videoPlayer.position,
                duration: videoPlayer.duration,
                onDrag: { value in videoPlayer.dragPosition = value },
                onSeek: { value in videoPlayer.seek(to: value) },
                onDraggingChanged: { dragging in
                    isSeekDragging = dragging
                    if dragging {
                        autoHideWork?.cancel()
                    } else {
                        showControlsTemporarily()
                    }
                }
            )
            HStack(spacing: 24) {
                Text(videoTimeText(seconds: videoPlayer.dragPosition ?? videoPlayer.position))
                    .font(.haoCaptionMedium)
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text(videoRemainingText(position: videoPlayer.position, duration: videoPlayer.duration))
                    .font(.haoCaptionMedium)
                    .foregroundStyle(.white.opacity(0.72))
                    .monospacedDigit()
                Spacer()
                if videoPlayer.hasNextEpisode {
                    Button("下一集") { videoPlayer.playNextEpisode() }
                        .font(.haoDenseTitle)
                        .foregroundStyle(theme.accentOnVideo)
                        .buttonStyle(.plain)
                }
                Button(action: { videoPlayer.togglePlayPause() }) {
                    Image(systemName: videoPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(theme.accentOnVideo)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                Button(action: { isLandscape.toggle() }) {
                    Image(systemName: isLandscape
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(theme.accentOnVideo)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 16)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.55)],
                startPoint: .top, endPoint: .bottom)
        )
    }
}

/// Remaining time as "-mm:ss" (Flutter player parity).
func videoRemainingText(position: Double, duration: Double) -> String {
    guard duration > 0 else { return "-0:00" }
    return "-\(videoTimeText(seconds: max(0, duration - position)))"
}

/// Pure seek-bar math (see VideoSeekBar): position from a touch
/// x, fill width from a position, and the preview bubble's centre
/// — all clamped, all testable without a view.
enum VideoSeekBarMath {
    /// Target seconds for a touch at `x` in a bar `totalWidth`
    /// wide, clamped to [0, duration]. Zero width / duration is
    /// 0, never NaN.
    static func position(forX x: CGFloat, totalWidth: CGFloat, duration: Double) -> Double {
        guard totalWidth > 0, duration > 0 else { return 0 }
        return max(0, min(duration, duration * Double(x / totalWidth)))
    }

    /// Fill width for `position` in a bar `totalWidth` wide.
    static func fillWidth(position: Double, duration: Double, totalWidth: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return max(0, min(totalWidth, totalWidth * CGFloat(position / duration)))
    }

    /// Bubble centre for a knob at `knobX`: the bubble stays
    /// fully inside the bar (its centre never closer to an edge
    /// than half its width). A bar narrower than the bubble
    /// centres it.
    static func previewCenterX(knobX: CGFloat, totalWidth: CGFloat, bubbleWidth: CGFloat) -> CGFloat {
        let half = bubbleWidth / 2
        guard totalWidth > bubbleWidth else { return totalWidth / 2 }
        return min(max(knobX, half), totalWidth - half)
    }
}

/// Thin progress bar, present from the start of playback. Drag
/// changes local state only; seek fires once on release.
/// Touch area is 44pt (the visual bar stays 4/6pt): the old 20pt
/// strip was too thin to grab in fullscreen, so a finger landing
/// just off it hit the tap-to-hide gesture instead and the bar
/// vanished. The drag is high-priority, so it outranks the
/// full-screen tap / long-press / double-tap layer underneath.
/// While dragging, a time bubble previews the target and the
/// controls auto-hide timer is paused (see onDraggingChanged).
struct VideoSeekBar: View {
    var position: Double
    var duration: Double
    var onDrag: (Double) -> Void
    var onSeek: (Double) -> Void
    var onDraggingChanged: (Bool) -> Void

    @State private var dragging = false

    @Environment(\.haoTheme) private var theme

    var body: some View {
        GeometryReader { geometry in
            let fill = VideoSeekBarMath.fillWidth(
                position: position, duration: duration, totalWidth: geometry.size.width)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(height: dragging ? 6 : 4)
                Capsule()
                    .fill(theme.accentOnVideo)
                    .frame(width: fill, height: dragging ? 6 : 4)
                Circle()
                    .fill(theme.accentOnVideo)
                    .frame(width: dragging ? 18 : 16, height: dragging ? 18 : 16)
                    .offset(x: max(0, fill - (dragging ? 9 : 8)))
            }
            .frame(height: 44)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            onDraggingChanged(true)
                        }
                        onDrag(VideoSeekBarMath.position(
                            forX: value.location.x,
                            totalWidth: geometry.size.width,
                            duration: duration))
                    }
                    .onEnded { value in
                        dragging = false
                        onDraggingChanged(false)
                        onSeek(VideoSeekBarMath.position(
                            forX: value.location.x,
                            totalWidth: geometry.size.width,
                            duration: duration))
                    }
            )
            if dragging {
                Text(videoTimeText(seconds: position))
                    .font(.haoCaptionStrong)
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.7), in: Capsule())
                    .position(
                        x: VideoSeekBarMath.previewCenterX(
                            knobX: fill, totalWidth: geometry.size.width, bubbleWidth: 72),
                        y: 6)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 20)
    }
}

// MARK: - Video surface (A-leg mount point)

/// The video frame. The A-leg driver's native surface
/// (MPV / IJK / AVPlayer view) is embedded here; before the first
/// open the episode cover rides dimmed as the backdrop and the
/// page states there is no picture yet — never a fake frame.
struct VideoPlayerSurface: View {
    @EnvironmentObject private var videoPlayer: VideoPlayerViewModel

    var body: some View {
        ZStack {
            Color.black
            if let videoView = videoPlayer.engine?.videoView {
                VideoDriverSurfaceView(view: videoView)
            } else if let url = videoPlayer.detail?.item.coverURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                            .opacity(0.35)
                    }
                }
            }
            if !videoPlayer.isEngineAttached {
                VStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("暂无画面")
                        .font(.haoDenseBody)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Hosts the driver's UIView (MPV / IJK / AVPlayer surface) in
/// SwiftUI. The view is owned by the backend; this wrapper only
/// embeds it and resizes it to the container. The backend may swap
/// its view on an engine change, so updateUIView re-syncs the
/// subview instead of assuming makeUIView ran with the new view.
private struct VideoDriverSurfaceView: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if uiView.subviews.first !== view {
            uiView.subviews.forEach { $0.removeFromSuperview() }
            view.frame = uiView.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            uiView.addSubview(view)
        }
    }
}

// MARK: - Orientation

enum VideoOrientation {
    /// VOD tap-play goes directly landscape fullscreen (iron law).
    /// Info.plist already lists both landscape orientations.
    ///
    /// Rotation uses UIDevice orientation + a window-scene geometry
    /// request. The preflight "no old controller file" check bans
    /// the old player controller's class name outright (it guards
    /// the deleted controller file), so the rotation nudge goes
    /// through the scene API instead — same effect, no banned name.
    static func lockLandscape() {
        setDeviceOrientation(.landscapeRight)
        requestSceneOrientation(.landscapeRight)
    }

    static func unlockPortrait() {
        setDeviceOrientation(.portrait)
        requestSceneOrientation(.portrait)
    }

    private static func setDeviceOrientation(_ orientation: UIInterfaceOrientation) {
        UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
    }

    private static func requestSceneOrientation(_ orientation: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientation)
        scene.requestGeometryUpdate(preferences) { _ in }
    }
}

/// Brightness + volume rows — the ONE implementation both
/// players share (the live room's LiveBrightnessVolumeSheet and
/// the VOD "更多" sheet use these rows: "同一套"). Brightness is
/// a user-driven slider: it reads the system value when the
/// player opens and writes it only while the user drags; leaving
/// the player never restores or overrides it. Volume is the
/// system MPVolumeView slider (public API) — the sheet never
/// invents a volume value. The notes name the player, so each
/// call site passes its own wording.
struct PlayerBrightnessVolumeRows: View {
    @Binding var brightness: Double
    var brightnessNote: String
    var volumeNote: String

    @Environment(\.haoTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "sun.max")
                        .foregroundStyle(theme.textSecondary)
                    Text("亮度")
                        .font(.haoSubheadStrong)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text("\(Int(brightness * 100))%")
                        .font(.haoDenseBody)
                        .foregroundStyle(theme.textSecondary)
                }
                Slider(value: $brightness, in: 0...1)
                    .tint(theme.accent)
                Text(brightnessNote)
                    .font(.haoCaption)
                    .foregroundStyle(theme.textMuted)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "speaker.wave.2")
                        .foregroundStyle(theme.textSecondary)
                    Text("音量")
                        .font(.haoSubheadStrong)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                }
                PlayerVolumeSliderView()
                    .frame(height: 30)
                Text(volumeNote)
                    .font(.haoCaption)
                    .foregroundStyle(theme.textMuted)
            }
        }
    }
}

/// The system volume slider (MPVolumeView, public API). It
/// reflects the device volume and changes it when dragged —
/// there is no app-side volume value to keep in sync. Tinted
/// with the theme accent (build 36, item 15) — device-gated: if
/// the tint does not visibly colour the slider on a real phone,
/// revert the tint and leave the system slider untinted rather
/// than building a custom volume control.
struct PlayerVolumeSliderView: UIViewRepresentable {
    @Environment(\.haoTheme) private var theme

    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView()
        volumeView.showsRouteButton = false
        volumeView.showsVolumeSlider = true
        volumeView.tintColor = UIColor(theme.accent)
        return volumeView
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        uiView.tintColor = UIColor(theme.accent)
    }
}

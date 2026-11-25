// HAo Studio 2.0 — live driver (S4, leg A).
//
// Implements `LivePlaybackDriver` (see PlaybackCoordinator): one
// room at a time, engines behind VideoPlayerBackend via the SAME
// PlayerKernel capability split as VOD (HEVC / Dolby Vision / HLS /
// MP4 -> AVPlayer; FLV / MKV / ASS / multi-track -> MPV; IJK third
// choice; FLV / MKV NEVER go to AVPlayer), the engine ladder, the
// 10 s open timeout, the 4 s warn / 12 s fail watchdog, and the
// live recovery loop (held plan -> fresh re-parse -> next line,
// bounded by the session budget).
//
// VOD and live are DIFFERENT players (coordinator rule 3):
// - VOD never drops frames; LIVE drops late frames to stay live.
//   The driver never waits on a dead live URL: a stall goes to
//   recovery instead of buffering. (Engine-level framedrop — MPV
//   `framedrop=vo` / IJK framedrop — is not exposed by any
//   VideoPlayerBackend today, so there is no engine knob to set
//   here; the drop is the recovery itself. See the
//   LiveAudioOnlyCapable seam note below for the same shape.)
// - Live has NO seek (real-time, cannot be sped up or re-watched):
//   `seek` always completes false and the UI never shows a scrub
//   bar for live. Live has NO speed control and NO breakpoint: a
//   live room has nothing to resume.
// - Quality selection is LIVE ONLY and lives in the session
//   (`LiveRoomSession.requestQualityChange`, P0-09 rollback); the
//   driver only opens the URL the session hands it.
// - Background audio is LIVE ONLY: `setAudioOnly(true)` drops the
//   video track and keeps the audio flowing; VOD never takes this
//   path.
//
// URL resolution lives in the SESSION (B leg's LiveSiteResolver),
// never in the coordinator: the driver owns `resolveURL` closing
// over the session's current lines (same shape as VideoDriver).
//
// Release: the room page calls `release(completion:)` on exit —
// timers cancelled, backend shut down, session exited, and the
// completion fires only after the shutdown returns. `deinit` shuts
// down synchronously as a safety net but cannot wait.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

// MARK: - Audio-only seam

/// Backend capability for live background audio-only mode
/// (Flutter `setAudioOnly`: drop the video track, keep the audio).
/// MPV implements it (S7-C: `video=no` / `video=auto`); AVPlayer
/// and IJK do not yet, so the driver calls it opportunistically
/// (`as?` cast) and records `isAudioOnly` regardless. Until the
/// AVPlayer/IJK equivalents land, the `.playback` audio session
/// still keeps live AUDIO alive in background on those engines,
/// but a core whose video output is suspended may stall the whole
/// stream (the Flutter root cause this mode exists to fix). The
/// state machine, the flag and the foreground restore are
/// implemented here and tested; the missing engine call is the
/// open seam, not a silent no-op.
protocol LiveAudioOnlyCapable: AnyObject {
    func setAudioOnly(_ audioOnly: Bool)
}

// MARK: - Live driver

/// Live driver: one room at a time, engines behind
/// VideoPlayerBackend, resolution through `LiveRoomSession`.
final class LiveDriver: NSObject, ObservableObject, LivePlaybackDriver {
    // Published state. Names are fixed: the UI leg reads these.
    @Published private(set) var currentRoom: PlaybackItem?
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var currentEngine: VideoEngine?
    @Published private(set) var diagnostics: VideoPlaybackDiagnostics = .empty
    @Published private(set) var stallWarning: Bool = false
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var currentLineIndex: Int = 0
    @Published private(set) var currentQuality: LiveQuality?
    @Published private(set) var isAudioOnly: Bool = false
    /// The last open failure for the current room, if the open
    /// exhausted every resolved line (D2) or the resolve returned
    /// nothing: the room page renders it under the placeholder
    /// with a retry button. Nil while loading or playing, and
    /// cleared on success / configure / stop / release — it
    /// always names the CURRENT room's failure, never a stale one.
    @Published private(set) var openFailure: MusicPlayerError?

    // Driver wiring, set by the coordinator (callbacks) and by the
    // room page / app entry (room + resolver via `configure`).
    var resolveURL: ((PlaybackItem, [URL], @escaping (URL?) -> Void) -> Void)?
    var onRoomStarted: ((PlaybackItem) -> Void)?
    var onRoomFailed: ((PlaybackItem, MusicPlayerError) -> Void)?
    /// The item whose open failed (for retryCurrentRoom): the
    /// driver drops currentItem/pendingItem on failure, so the
    /// retry needs its own handle. Cleared with openFailure.
    private var lastFailedItem: PlaybackItem?

    /// The room session: state machine + fetch-and-hold recovery.
    /// Owned here (one driver, one room); the room page configures
    /// it with `configure(room:resolver:)` before play.
    let session = LiveRoomSession()

    /// The B-leg room currently configured (nil until `configure`).
    var room: LiveRoom? {
        return session.room
    }

    /// The lines of the current resolution, in platform order
    /// (for the line picker). Empty until the first resolution.
    var lines: [LiveLine] {
        return session.recovery?.lines ?? []
    }

    /// The qualities the room offers, from the last resolution.
    /// Empty until the first resolution.
    var qualities: [LiveQuality] {
        return session.recovery?.qualities ?? []
    }

    /// Per-attempt budget / whole-open cap factor, shared with
    /// VideoDriver through OpenTimeoutPolicy (build 36, item 8,
    /// smell 1): one home for the numbers, so a cap change never
    /// needs a lockstep edit in two drivers. The statics stay so
    /// existing call sites keep their names; the values live in
    /// the policy. Live routing, quality selection and recovery
    /// are otherwise untouched by this item.
    static let openTimeout: TimeInterval = OpenTimeoutPolicy.perAttemptTimeout
    static let openTotalTimeoutFactor: Double = OpenTimeoutPolicy.totalTimeoutFactor

    /// Test seam: open timeout seconds. Production is 10; tests set
    /// a short value so the timeout path runs without waiting.
    var openTimeoutInterval: TimeInterval = LiveDriver.openTimeout

    /// Test seam: backend factory. Production builds real engines;
    /// tests inject a fake backend.
    var makeBackend: (VideoEngine) -> VideoPlayerBackend = { PlayerKernel.makeBackend(engine: $0) }

    private var backend: VideoPlayerBackend?
    private var currentURL: URL?
    /// The ladder for the open in flight. A ladder is a local in
    /// `open()` — without this strong hold nothing would retain it
    /// once `open()` returns, the run would never complete, and the
    /// open would hang until the 10 s timeout. Cleared when the run
    /// finishes or a newer open supersedes it.
    private var activeLadder: VideoRecoveryLadder?
    private var generation: Int = 0
    /// attemptOpen token (build 35 #11): bumped by every
    /// attemptOpen, including retries. A superseded attempt's
    /// completion must not clear the new attempt's state or retry
    /// the stale item — the token (not just the room id) tells a
    /// stale failure apart, because a line/quality switch opens
    /// the SAME room id again.
    private var openAttemptToken = 0
    /// Wall-clock budget for one attemptOpen chain (b49 sweep
    /// #12, reshaped b49fix2 P1-3): every open() in the chain
    /// already gets its own whole-open cap (25 s), so the chain
    /// budget must exceed ONE open's cap — one whole-open cap
    /// per line the walk may visit. A budget equal to a single
    /// cap let a first line whose ladder hangs spend the whole
    /// budget, and the chain failed with .timeout without ever
    /// trying line 2. Armed lazily by attemptOpen and reset by
    /// beginAttemptChain() at each new chain entry (new room,
    /// line/quality switch, stall recovery).
    private var attemptChainDeadline: Date?
    private var attemptChainArmed = false
    /// Background task spanning one attemptOpen chain (b49fix2
    /// P1-32): without it iOS may suspend a backgrounded app
    /// mid-resolve/open and the main-queue open timeout then
    /// fires the instant the app returns, killing a healthy
    /// open. Same shape as NativeMusicPlayer's switch task:
    /// begun when the chain arms, ended when it clears or fails.
    private var chainBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var pendingItem: PlaybackItem?
    private var playRequested: Bool = false
    // #6: the backend paused itself (interruption / stall /
    // background pause) without the driver asking. playRequested
    // stays true — the user still wants playback — but the
    // buffering branch of recomputePlayingState must not keep
    // reporting playing for a paused backend. Set on .paused,
    // cleared on .playing and on every resume / new request.
    private var backendPaused: Bool = false
    private var stallFailed: Bool = false
    private var fellBackForSoftwareDecode = false
    /// Audio-session interruption observer token (b49fix2 P1-6 /
    /// P1-33): the token — not the driver — owns the observation,
    /// so it must be stored, never discarded (the music view
    /// model dropped its tokens and its observers died on
    /// arrival). Removed in deinit.
    private var interruptionObserver: NSObjectProtocol?
    /// Whether the room was playing when an interruption began
    /// (b49fix2 P1-33): only a room that was playing resumes
    /// when the interruption ends with .shouldResume.
    private var wasPlayingBeforeInterruption: Bool = false

    private var openTimeoutWork: DispatchWorkItem?
    private var positionTimer: Timer?
    private var fpsSampler = VideoFpsSampler()
    private var lastFps: Double = 0
    private var lastDroppedFrames: Int = 0
    /// (Build 36, item 14, G-J) Whether any ladder attempt of the
    /// open in flight timed out on its own budget, and the engines
    /// the ladder attempted (recorded into diagnostics).
    private var openAttemptTimedOut = false
    private var lastAttemptedEngines: [VideoEngine] = []

    /// Settings storage for the cellular-downgrade switch (test
    /// seam: tests point this at an isolated suite; production is
    /// `.standard`). The switch reads through the SettingsStore key
    /// — no second key.
    var defaults: UserDefaults = .standard

    override init() {
        super.init()
        // Resolution lives inside this driver: the closure hands out
        // the first URL the session has not already failed on for
        // this request — a failed URL is never handed out twice.
        resolveURL = { [weak self] item, excluding, completion in
            guard let self = self, let recovery = self.session.recovery else {
                completion(nil)
                return
            }
            guard self.currentRoom?.id == item.id || self.pendingItem?.id == item.id else {
                completion(nil)
                return
            }
            let candidates = recovery.urls.filter { !excluding.contains($0) }
            completion(candidates.first)
        }
        fpsSampler.onSample = { [weak self] fps, dropped in
            guard let self = self else {
                return
            }
            self.lastFps = fps
            self.lastDroppedFrames = dropped
            self.updateDiagnostics()
        }
        // (b49fix2 P1-6 / P1-33) Phone call / Siri / alarm: the
        // music player was the only domain observing
        // interruptionNotification — live stayed paused (or, on
        // MPV/IJK, kept sounding through the call) and never
        // resumed. Stored token, removed in deinit.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in self?.handleInterruption(note) }
    }

    deinit {
        positionTimer?.invalidate()
        openTimeoutWork?.cancel()
        endChainBackgroundTask()
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o) }
        fpsSampler.stop()
        backend?.shutdown()
    }

    // MARK: - Helpers

    private func ensureMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    /// Recompute the published playing flag from real backend state.
    /// True only while video is really playing, or while a play was
    /// requested and a room is loaded but still buffering. False
    /// the moment the watchdog fails, the room fails, or playback
    /// is paused or stopped: never report playing for a dead stream.
    private func recomputePlayingState() {
        let sounding = backend?.isPlaying ?? false
        // #6: a backend that paused itself is not buffering — see
        // VideoDriver.
        let buffering = playRequested && backend != nil && !stallFailed && !backendPaused
        isPlaying = (sounding || buffering) && !stallFailed && currentRoom != nil
    }

    private func updateDiagnostics() {
        guard let backend = backend, let engine = currentEngine else {
            return
        }
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

    /// Stream facts for the current URL, when it carries them
    /// (Emby `hao_*` markers). Nil for plain live URLs.
    private func currentURLFacts() -> VideoStreamFacts? {
        guard let url = currentURL else {
            return nil
        }
        return VideoStreamFacts.parse(url: url)
    }

    /// The video surface for the room page to embed. Nil until the
    /// first backend opens.
    var videoView: UIView? {
        return backend?.view
    }

    /// Declared format for a URL, from the session's per-line facts
    /// (a refresh can turn a TX FLV line into TX HLS — the engine
    /// must be told the new fact, not guess from the URL).
    private func declaredFormat(for url: URL) -> String? {
        guard let recovery = session.recovery else {
            return nil
        }
        guard let index = recovery.urls.firstIndex(of: url) else {
            return nil
        }
        return recovery.factsFor(index: index)
    }

    // MARK: - Context

    /// Set the room context (room page calls this before asking the
    /// coordinator to play). The resolver is B leg's
    /// LiveSiteResolver for this room's platform.
    /// Build 37 (D11): the published room state is reset here —
    /// the driver's own `currentQuality` was never cleared on
    /// entering a room (only the session's was), so the footer
    /// kept showing the previous room's tier and the quality
    /// sheet highlighted a tier never resolved for this room.
    /// The failure state goes with it: a new room never inherits
    /// the old room's failure card.
    func configure(room: LiveRoom, resolver: LiveSiteResolver) {
        currentQuality = nil
        currentLineIndex = 0
        isLoading = false
        openFailure = nil
        lastFailedItem = nil
        session.enterRoom(room: room, resolver: resolver)
    }

    /// Build the PlaybackItem for a room (id is platform + roomId:
    /// a bare roomId can collide across platforms).
    static func playbackItem(room: LiveRoom) -> PlaybackItem {
        return PlaybackItem(
            id: "\(room.platform.rawValue):\(room.roomId)",
            kind: .live,
            title: room.title,
            artist: room.streamer,
            coverURL: URL(string: room.cover)
        )
    }

    /// Play a room directly (room page convenience): configure the
    /// context and start playback.
    func playRoom(room: LiveRoom, resolver: LiveSiteResolver) {
        configure(room: room, resolver: resolver)
        play(item: LiveDriver.playbackItem(room: room))
    }

    /// Switch to another line, keeping the current quality. Goes
    /// through `startNewRoomPlayback` directly, NOT `play(item:)`:
    /// the room id is the same on the new line, so `play` would
    /// mistake this for "tapped the room already playing" and
    /// return without switching.
    @discardableResult
    func switchLine(to index: Int) -> Bool {
        guard let recovery = session.recovery, let item = currentRoom else {
            return false
        }
        guard index >= 0 && index < recovery.urls.count else {
            return false
        }
        recovery.currentLineIndex = index
        currentLineIndex = index
        let url = recovery.urls[index]
        ensureMain {
            // (b49fix2 P1-8) Show "加载中…" while the switch
            // opens: open() tears the backend down at once, and
            // without this the placeholder flashes "暂无画面 /
            // 房间未开播" on every line switch.
            self.isLoading = true
            self.beginAttemptChain()
            self.attemptOpen(item: item, url: url, tried: [url], freshRounds: 2)
        }
        return true
    }

    /// Switch quality (P0-09): the session re-parses and only
    /// commits when the returned resolution is for the requested
    /// quality; on failure the room keeps playing at the old
    /// quality and the completion reports false. On success the
    /// driver opens the new quality's matched line, and the pick
    /// is persisted as the preferred quality for the platform
    /// (b49 sweep #14) so the next room entry re-opens at it.
    func switchQuality(to quality: LiveQuality, completion: @escaping (Bool) -> Void) {
        ensureMain {
            guard let item = self.currentRoom else {
                completion(false)
                return
            }
            self.session.requestQualityChange(to: quality) { [weak self] ok in
                guard let self = self else {
                    completion(false)
                    return
                }
                self.ensureMain {
                    guard ok else {
                        completion(false)
                        return
                    }
                    self.currentQuality = quality
                    if let platform = self.session.room?.platform {
                        // (b49fix2 P2-55) Persist the ACKED tier,
                        // not the requested one: the session's
                        // committed tier is what actually plays
                        // (the sheet already derives its highlight
                        // from it), and persisting the request
                        // would re-ask for a tier the server just
                        // refused on every next room entry.
                        let ackedId = self.session.currentQuality?.id ?? quality.id
                        LivePreferredQuality.savePreferredQualityId(ackedId, for: platform, defaults: self.defaults)
                    }
                    if let url = self.session.recovery?.currentUrl {
                        // (b49fix2 P1-8) Same loading flag as
                        // switchLine: the switch tears the backend
                        // down at once.
                        self.isLoading = true
                        self.beginAttemptChain()
                        self.attemptOpen(item: item, url: url, tried: [url], freshRounds: 2)
                    }
                    completion(true)
                }
            }
        }
    }

    // MARK: - Cellular downgrade (wiring leg B)

    /// The switch's stored value (Flutter default ON: a fresh
    /// install downgrades on cellular until the user turns it off).
    private var cellularDowngradeEnabled: Bool {
        if defaults.object(forKey: SettingsStore.cellularDowngradeKey) == nil { return true }
        return defaults.bool(forKey: SettingsStore.cellularDowngradeKey)
    }

    /// Entry-quality target for an initial resolution: the index
    /// into `resolution.qualities` to open instead of the resolved
    /// (best) tier, or nil when the resolved tier already applies.
    /// (b49 sweep #14) The user's persisted preferred quality wins
    /// over the best tier — the preference is read from
    /// LivePreferredQuality (per platform) and requested through
    /// the session like the cellular cap. The cellular ceiling then
    /// caps that entry tier (Wi-Fi / unknown and a switched-off
    /// downgrade leave the preferred tier untouched).
    private func entryQualityTarget(resolution: LivePlayUrlResolution) -> Int? {
        guard let applied = resolution.quality,
              let appliedIndex = resolution.qualities.firstIndex(where: { $0.id == applied.id }) else { return nil }
        var target = appliedIndex
        if let platform = session.room?.platform,
           let preferred = LivePreferredQuality.entryQualityIndex(
               qualities: resolution.qualities,
               preferredId: LivePreferredQuality.preferredQualityId(for: platform, defaults: defaults)) {
            target = preferred
        }
        if cellularDowngradeEnabled, LiveDriver.detectNetworkType() == .cellular {
            // The ceiling is the best tier allowed on cellular
            // (index 0 = best, so the ceiling is a lower bound on
            // the index): a preferred tier better than the ceiling
            // drops to it, a preferred tier already at or below
            // the ceiling stays — the cap never switches UP.
            let names = resolution.qualities.map { $0.name }
            let ceiling = LiveCellularDowngrade.entryQualityIndex(
                qualityNames: names, preferredIndex: appliedIndex, network: .cellular)
            if target < ceiling {
                target = ceiling
            }
        }
        return target == appliedIndex ? nil : target
    }

    /// Current transport from the OS interface list (Flutter
    /// `detectNetworkType`: en0 = Wi-Fi, pdp_ip0 = cellular).
    /// `interfaceNames` is a test seam: production passes nothing
    /// and the names come from getifaddrs.
    static func detectNetworkType(interfaceNames: [String]? = nil) -> LiveNetworkType {
        let names = interfaceNames ?? LiveDriver.interfaceNames()
        return LiveCellularDowngrade.classifyInterfaces(names)
    }

    /// Interface names from getifaddrs. Empty (never a downgrade)
    /// when the list cannot be read.
    private static func interfaceNames() -> [String] {
        var names: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            names.append(String(cString: current.pointee.ifa_name))
            cursor = current.pointee.ifa_next
        }
        return names
    }

    // MARK: - Play / open

    /// Play a room: stop what this driver is doing, resolve the
    /// first playable URL serially (via the session's initial
    /// resolve), open it on the first capable engine, and on open
    /// failure consume exactly one fallback candidate before
    /// giving up. Tapping the room that is already playing does
    /// not restart it.
    func play(item: PlaybackItem) {
        ensureMain {
            if let current = self.currentRoom, current.id == item.id, self.backend != nil {
                if self.isPlaying {
                    return
                }
                self.resume()
                return
            }
            self.startNewRoomPlayback(item: item)
        }
    }

    /// Re-open the room whose open failed (the room page's retry
    /// button, and the play button after a failure — see
    /// LivePlayerViewModel.togglePlayPause): re-runs the resolve
    /// + open walk from scratch. No-op when nothing failed.
    /// `resolveInitial` re-parses directly (it does not go
    /// through the throttled fetchFresh), so a retry gets fresh
    /// URLs even inside the 60 s recovery throttle.
    func retryCurrentRoom() {
        ensureMain {
            guard let item = self.lastFailedItem else {
                return
            }
            self.lastFailedItem = nil
            self.openFailure = nil
            self.play(item: item)
        }
    }

    /// Public refresh entry (b49 sweep #29 — the landscape bar's
    /// 刷新 button): re-resolve + re-open the room currently
    /// playing (or the last failed one), from scratch, keeping
    /// the current quality. Unlike `retryCurrentRoom` this needs
    /// no failure: a healthy room can be refreshed too. Goes
    /// through `startNewRoomPlayback` directly, not `play(item:)`,
    /// so a playing room is actually restarted instead of
    /// no-op'd by play's same-room check.
    func refreshCurrentRoom() {
        ensureMain {
            guard let item = self.currentRoom ?? self.lastFailedItem else {
                return
            }
            self.lastFailedItem = nil
            self.openFailure = nil
            self.startNewRoomPlayback(item: item)
        }
    }

    /// Start playback of a new room (no same-room check — callers
    /// that already decided this is a new request use this
    /// directly, e.g. `switchLine`, where the id is unchanged but
    /// the line is new).
    private func startNewRoomPlayback(item: PlaybackItem) {
        self.beginAttemptChain()
        self.stopBackendForNewRequest()
        self.pendingItem = item
        self.stallFailed = false
        self.lastAttemptedEngines = []
        self.isLoading = true
        // B36 item 5: the resolve answers later, on another
        // callback — capture the attempt token now and require
        // it to still match when the resolve answers. A
        // back-out bumps the token (release()/stop()), so a
        // late resolve from the exited room cannot open against
        // the fresh session: a re-entry for the SAME room
        // re-sets pendingItem to the same id, so the id check
        // alone cannot tell it apart.
        let token = openAttemptToken
        self.session.resolveInitial { [weak self] resolution in
            guard let self = self else {
                return
            }
            self.ensureMain {
                guard token == self.openAttemptToken, self.pendingItem?.id == item.id else {
                    return
                }
                guard let resolution = resolution, let url = resolution.appliedUrls.compactMap({ URL(string: $0) }).first else {
                    // b39: an off-air room is not a missing address —
                    // the room page said so (LiveError.offline), so
                    // say "房间未开播" instead of "没有可播放的地址"
                    // (chen 2026-11-25: cxy0714 was off air and the
                    // generic text misled him). Retry stays: the room
                    // may go live.
                    let failure: MusicPlayerError = self.session.lastResolveWasOffline ? .offline : .noPlayableURL
                    self.isLoading = false
                    self.pendingItem = nil
                    self.openFailure = failure
                    self.lastFailedItem = item
                    self.onRoomFailed?(item, failure)
                    return
                }
                // Preferred quality (b49 sweep #14) + cellular
                // downgrade (wiring leg B; Flutter live_room_page
                // _loadRoom): the persisted preferred tier is
                // requested first, capped at the cellular ceiling
                // on mobile data with the switch on. The tier is
                // requested through the session (a failed request
                // rolls back and the original URL still opens).
                if let target = self.entryQualityTarget(resolution: resolution) {
                    self.session.requestQualityChange(to: resolution.qualities[target]) { [weak self] ok in
                        guard let self = self else { return }
                        self.ensureMain {
                            guard token == self.openAttemptToken, self.pendingItem?.id == item.id else { return }
                            if ok {
                                self.currentQuality = self.session.currentQuality
                            } else {
                                self.currentQuality = resolution.quality
                            }
                            self.currentLineIndex = 0
                            let openURL = self.session.recovery?.currentUrl ?? url
                            self.attemptOpen(item: item, url: openURL, tried: [openURL], freshRounds: 2)
                        }
                    }
                    return
                }
                self.currentQuality = resolution.quality
                self.currentLineIndex = 0
                self.attemptOpen(item: item, url: url, tried: [url], freshRounds: 2)
            }
        }
    }

    /// One open attempt plus at most one fallback re-resolution.
    /// `tried` lists the URLs already consumed for this request, so
    /// the fallback consumes exactly one more candidate, never a
    /// fan-out and never an unbounded retry loop — and never the
    /// same URL twice (`excluding` is passed through). `freshRounds`
    /// bounds the fresh-URL recursion inside `open` (at most 2
    /// fresh re-parses per open). The whole chain shares one
    /// wall-clock budget of one whole-open cap per line (b49fix2
    /// P1-3): when it is spent the chain fails fast instead of
    /// walking every line at 25 s each.
    private func attemptOpen(item: PlaybackItem, url: URL, tried: [URL], freshRounds: Int) {
        if !attemptChainArmed {
            attemptChainArmed = true
            // (b49fix2 P1-3) One whole-open cap per line the
            // walk may visit (see the property comment): a
            // budget equal to a single cap let a hanging first
            // line spend it all before line 2 was tried.
            let lines = max(2, session.recovery?.urls.count ?? 0)
            attemptChainDeadline = Date().addingTimeInterval(
                openTimeoutInterval * LiveDriver.openTotalTimeoutFactor * Double(lines))
        }
        openAttemptToken += 1
        let token = openAttemptToken
        open(item: item, url: url, freshRounds: freshRounds) { [weak self] result in
            guard let self = self else {
                return
            }
            // A newer attempt superseded this one (line/quality
            // switch, re-entry): its failure belongs to the old
            // attempt and must not clear the new attempt's loading
            // state, report the old room as failed, or retry the
            // stale item. The new attempt owns the state now.
            guard token == self.openAttemptToken, self.pendingItem?.id == item.id else {
                return
            }
            switch result {
            case .success:
                self.clearAttemptChain()
                return
            case .failure(let error):
                // Unsupported format (b49 sweep #28): no fresh
                // re-parse — re-parsing a format problem cannot
                // fix it. But lines carry PER-LINE formats (Huya
                // FLV vs HLS), so line 1 can be unplayable while
                // line 2 plays: only fast-fail when NO untried
                // line has a capable engine (b49fix2 P2-57);
                // otherwise fall through to the walk below.
                if error == .unsupportedFormat {
                    let remaining = (self.session.recovery?.urls ?? []).filter { !tried.contains($0) }
                    let anyPlayable = remaining.contains { url in
                        !videoCandidatesFor(url: url, declaredFormat: self.declaredFormat(for: url)).isEmpty
                    }
                    if !anyPlayable {
                        self.failAttemptChain(item: item, error: error)
                        return
                    }
                }
                // Shared chain budget spent (b49 sweep #12): fail
                // fast to the card instead of opening the next line
                // for another whole-open cap.
                if let deadline = self.attemptChainDeadline, Date() >= deadline {
                    self.failAttemptChain(item: item, error: .timeout)
                    return
                }
                // Build 37 (D2): walk EVERY resolved line before
                // giving up — the session holds all of them
                // (recovery.urls) and the first one is often a
                // dead CDN / expired anti-code while another line
                // plays. The old cap (2 tries) failed rooms that
                // had a playable line. The walk is bounded by the
                // resolved list itself (resolveURL hands out only
                // URLs the session holds and never repeats one),
                // and fresh re-parses are bounded by the session's
                // 60 s fetchFresh throttle (a throttled fetch
                // returns nil at once, no request).
                let maxTries = max(2, self.session.recovery?.urls.count ?? 0)
                guard tried.count < maxTries else {
                    self.failAttemptChain(item: item, error: error)
                    return
                }
                self.resolveURL?(item, tried) { [weak self] nextURL in
                    guard let self = self else {
                        return
                    }
                    self.ensureMain {
                        guard token == self.openAttemptToken, self.pendingItem?.id == item.id else {
                            return
                        }
                        guard let nextURL = nextURL else {
                            self.failAttemptChain(item: item, error: error)
                            return
                        }
                        // Build 35 sweep S2: the fallback opens a
                        // different line than the one requested, so
                        // the recovery's line index must follow the
                        // URL actually opened — otherwise the
                        // picker highlight (and `currentLineIndex`)
                        // keeps naming the failed line while
                        // another line plays.
                        if let index = self.session.recovery?.urls.firstIndex(of: nextURL) {
                            self.session.recovery?.currentLineIndex = index
                        }
                        self.attemptOpen(item: item, url: nextURL, tried: tried + [nextURL], freshRounds: freshRounds)
                    }
                }
                if self.resolveURL == nil {
                    self.failAttemptChain(item: item, error: error)
                }
            }
        }
    }

    /// Start a fresh attemptOpen chain (new room, line/quality
    /// switch, stall recovery): the next attemptOpen arms a new
    /// shared budget instead of inheriting the old chain's
    /// (possibly spent) deadline.
    private func beginAttemptChain() {
        attemptChainArmed = false
        attemptChainDeadline = nil
        // (b49fix2 P1-32) The task spans the whole chain — resolve
        // + open + recovery — so a backgrounded chain keeps
        // running instead of freezing its main-queue timers.
        beginChainBackgroundTask()
    }

    /// Begin the background task that keeps a backgrounded chain's
    /// resolve + open alive (b49fix2 P1-32). Ends any previous
    /// task first (one chain at a time). No-op when tasks are
    /// unavailable (beginBackgroundTask returns .invalid) — the
    /// chain budget below still converts a stall into a reported
    /// failure. Called on main (every chain entry runs in
    /// ensureMain).
    private func beginChainBackgroundTask() {
        endChainBackgroundTask()
        chainBackgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endChainBackgroundTask()
        }
    }

    private func endChainBackgroundTask() {
        guard chainBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(chainBackgroundTask)
        chainBackgroundTask = .invalid
    }

    /// A chain ended in success: drop its budget and its
    /// background task.
    private func clearAttemptChain() {
        attemptChainArmed = false
        attemptChainDeadline = nil
        endChainBackgroundTask()
    }

    /// A chain ended in failure: drop its budget and its
    /// background task, and report the failure the way the old
    /// inline sites did (loading off, failure card on, retry
    /// item kept).
    private func failAttemptChain(item: PlaybackItem, error: MusicPlayerError) {
        attemptChainArmed = false
        attemptChainDeadline = nil
        endChainBackgroundTask()
        isLoading = false
        pendingItem = nil
        openFailure = error
        lastFailedItem = item
        onRoomFailed?(item, error)
    }

    /// Open a URL on the first capable engine, falling down the
    /// ladder (capability order from PlayerKernel) on failure.
    /// (Build 36, item 14, G-J) Timeouts are per attempt now, not
    /// per open — the same edit as VideoDriver: each ladder
    /// attempt gets its own `openTimeoutInterval` budget, the
    /// whole open is capped at 2.5x that (25 s in production).
    /// Ladder exhausted + live + fresh rounds left: the fresh-URL
    /// path (held plan first, then a live re-parse), never a
    /// dead-end error on the same URL. Bounded by `freshRounds`.
    /// The completion fires exactly once for the live attempt; a
    /// newer open supersedes this one (its completion is then
    /// dropped, never double-reported).
    func open(item: PlaybackItem, url: URL, completion: @escaping (Result<Void, MusicPlayerError>) -> Void) {
        open(item: item, url: url, freshRounds: 2, completion: completion)
    }

    private func open(item: PlaybackItem, url: URL, freshRounds: Int, completion: @escaping (Result<Void, MusicPlayerError>) -> Void) {
        ensureMain {
            let gen = self.nextGeneration()
            self.stopBackendForNewRequest()
            self.pendingItem = item
            self.openTimeoutWork?.cancel()
            self.openTimeoutWork = nil
            self.currentURL = url
            var completed = false
            let finish: (Result<Void, MusicPlayerError>) -> Void = { [weak self] result in
                guard let self = self, !completed else {
                    return
                }
                completed = true
                self.openTimeoutWork?.cancel()
                self.openTimeoutWork = nil
                completion(result)
            }
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard let self = self else {
                    return
                }
                guard gen == self.generation, !completed else {
                    return
                }
                // #1: bump the generation (same as VideoDriver),
                // kill the ladder BEFORE shutting the backend down,
                // and stop the position timer. shutdown fires
                // finishOpen(false) synchronously; a live ladder
                // would advance to the next engine and open a second
                // backend (autoplay), which `self.backend = nil`
                // below would then orphan — for live it keeps
                // playing its infinite stream forever, unstoppable
                // by any later open. Nil-ing activeLadder
                // deallocates the ladder (its attempt completion
                // holds it weakly), so the advance never happens;
                // the generation bump makes any late completion for
                // this request see a stale gen and shut its backend
                // down instead of playing. The timer stop keeps
                // handleTimeUpdate from recomputing isPlaying = true
                // from the sounding orphan after the failure was
                // already reported.
                _ = self.nextGeneration()
                self.activeLadder = nil
                self.backend?.shutdown()
                self.backend = nil
                self.positionTimer?.invalidate()
                self.positionTimer = nil
                self.playRequested = false
                self.isLoading = false
                self.recomputePlayingState()
                finish(.failure(.timeout))
            }
            self.openTimeoutWork = timeoutWork
            DispatchQueue.main.asyncAfter(deadline: .now() + self.openTimeoutInterval * LiveDriver.openTotalTimeoutFactor, execute: timeoutWork)
            // (b49fix2 P1-26) Live calls videoCandidatesFor with
            // preferred: nil directly: PlayerKernel.candidatesFor
            // injects the STORED video preference, and the picker
            // lives in the 影视播放 section — a VOD pick must not
            // reorder live engine selection (an HLS live room
            // would lose AVPlayer hardware decode to an MPV pick).
            // Live has no own preference; the capability split
            // decides.
            let engines = videoCandidatesFor(url: url, declaredFormat: self.declaredFormat(for: url), preferred: nil)
            // (b49 sweep #28) No capable engine for this format:
            // the same failure VOD reports as unsupportedFormat —
            // fail at once with that reason instead of running the
            // ladder (which would exhaust and spend fresh rounds
            // re-parsing a format problem re-parsing cannot fix).
            // attemptOpen then fails straight to the card without
            // walking the other lines, which share the format.
            guard !engines.isEmpty else {
                finish(.failure(.unsupportedFormat))
                return
            }
            // Accumulate across the opens of one room (original
            // open + fresh rounds), so the diagnostics name every
            // engine that was tried. (Same discipline as
            // VideoDriver's per-episode accumulation.)
            for engine in engines where !self.lastAttemptedEngines.contains(engine) {
                self.lastAttemptedEngines.append(engine)
            }
            self.openAttemptTimedOut = false
            let ladder = VideoRecoveryLadder(engines: engines, urls: [url], attempt: { [weak self] engine, attemptURL, attemptCompletion in
                guard let self = self else {
                    attemptCompletion(false)
                    return
                }
                // (G-J) Per-attempt timeout, shared with
                // VideoDriver via OpenAttemptTimeoutGuard (build
                // 36, item 8, smell 1): a hanging attempt fails
                // like a stream error after its own budget, and
                // the ladder moves to the next engine. The guard's
                // `settled` state makes the completion fire
                // exactly once.
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
                guard let self = self else {
                    return
                }
                self.ensureMain {
                    self.activeLadder = nil
                    guard gen == self.generation, !completed else {
                        // Superseded by a newer open: the attempt
                        // must still settle its completion as
                        // failed, or attemptOpen's completion is
                        // dropped and `isLoading` stays true
                        // forever (build 35 #11). finish() is a
                        // no-op if it already fired; attemptOpen
                        // ignores the stale failure via its token.
                        finish(.failure(.loadFailed))
                        return
                    }
                    guard winner != nil, let backend = self.backend else {
                        self.playRequested = false
                        self.isLoading = false
                        self.recomputePlayingState()
                        // (G-J) The ladder exhausted because every
                        // attempt timed out on its own budget (a
                        // hanging backend): report a timeout, like
                        // the overall cap — and do NOT spend fresh
                        // rounds re-parsing a line whose engines
                        // all hang.
                        if self.openAttemptTimedOut {
                            finish(.failure(.timeout))
                            return
                        }
                        if freshRounds > 0 {
                            self.openFresh(item: item, failedURL: url, freshRounds: freshRounds, finish: finish)
                            return
                        }
                        finish(.failure(.loadFailed))
                        return
                    }
                    self.startPlaybackAfterLoad(item: item, backend: backend, gen: gen, finish: finish)
                }
            }
        }
    }

    /// Fresh-URL path (Flutter `playback_session.open` fix 3):
    /// held prefetched plan first, then a live re-parse — never
    /// the dead URL. Opens the fresh first URL when it differs
    /// from the failed one; anything else finishes failed.
    private func openFresh(item: PlaybackItem, failedURL: URL, freshRounds: Int, finish: @escaping (Result<Void, MusicPlayerError>) -> Void) {
        // #2: capture the generation + attempt token at entry.
        // refreshURLs is an async network re-parse; between ladder
        // exhaustion and the fresh answer arriving, the user can
        // stop()/release() (bumps both) or switch rooms (attemptOpen
        // bumps the token, a new open bumps the generation). The
        // completion must re-check all three before opening —
        // recoverFromStall's own fetchFresh does exactly this, and
        // openFresh was the one unguarded async open in the
        // codebase. On a stale answer, return WITHOUT calling
        // finish: firing a failure into the dead request could
        // clear the new room's loading state (the B36 item 5 hole
        // release()'s comment describes).
        let gen = generation
        let token = openAttemptToken
        refreshURLs { [weak self] fresh in
            guard let self = self else {
                return
            }
            self.ensureMain {
                guard gen == self.generation, token == self.openAttemptToken,
                      self.pendingItem?.id == item.id else {
                    return
                }
                guard let fresh = fresh, let first = fresh.first, first != failedURL else {
                    finish(.failure(.loadFailed))
                    return
                }
                self.open(item: item, url: first, freshRounds: freshRounds - 1, completion: finish)
            }
        }
    }

    /// Fresh URLs for recovery: the held prefetched plan first
    /// (no request, no throttle), else a live re-parse. The
    /// currently playing line goes first so recovery resumes the
    /// same line instead of line 0.
    private func refreshURLs(completion: @escaping ([URL]?) -> Void) {
        if let held = session.recovery?.takeHeld() {
            completion(session.matchedFirst(urls: held.appliedUrls.compactMap({ URL(string: $0) })))
            return
        }
        session.recovery?.fetchFresh(completion: { [weak self] resolution in
            guard let self = self else {
                completion(nil)
                return
            }
            guard let resolution = resolution, !resolution.appliedUrls.isEmpty else {
                completion(nil)
                return
            }
            completion(self.session.matchedFirst(urls: resolution.appliedUrls.compactMap({ URL(string: $0) })))
        })
        if session.recovery == nil {
            completion(nil)
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
        // #4: a stale backend's event must not act on the current
        // room — AVPlayer/MPV emit to main async, so an event
        // queued before a shutdown/switch can land after the new
        // backend is installed. Capture the backend weakly (a
        // strong capture would cycle: backend retains onEvent,
        // onEvent would retain backend) and check identity before
        // handling, same as VideoDriver's track-list handler.
        backend.onEvent = { [weak self, weak backend] event in
            guard let self = self, let backend = backend, self.backend === backend else { return }
            self.handleBackendEvent(event)
        }
        backend.onVideoSize = { [weak self] _ in
            self?.updateDiagnostics()
        }
        self.backend = backend
        self.currentEngine = engine
        backend.open(url: url, headers: PlayerKernel.httpHeaders(platform: session.room?.platform.rawValue)) { [weak self] ok in
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
    /// state (soft 4K HEVC / Dolby Vision -> AVPlayer), start the
    /// watchdog and the FPS sampler, publish state.
    private func startPlaybackAfterLoad(
        item: PlaybackItem,
        backend: VideoPlayerBackend,
        gen: Int,
        finish: @escaping (Result<Void, MusicPlayerError>) -> Void
    ) {
        guard gen == generation else {
            // Superseded: settle the attempt as failed so the
            // completion is not dropped (build 35 #11).
            finish(.failure(.loadFailed))
            return
        }
        // Software-decode fallback (plan §四 4.2, same as VOD):
        // verified soft decode on a 4K HEVC / Dolby Vision stream
        // switches to AVPlayer and reopens. Anything else stays put
        // and is labelled "软解中" — never silent. Live has no
        // resume position to preserve: the reopen joins the live
        // edge again.
        if backend.hardwareDecode.isSoftware,
           videoNeedsHardwareDecode(facts: currentURLFacts()),
           backend.engine != .avplayer,
           let url = currentURL,
           videoEngineCanPlay(.avplayer, format: videoFormatOf(url: url, declaredFormat: declaredFormat(for: url))) {
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
        backend?.shutdown()
        backend = nil
        let avBackend = makeBackend(.avplayer)
        // #4: same identity check as openOnEngine above — a stale
        // AVPlayer backend's event must not stop/fail the room
        // that replaced it.
        avBackend.onEvent = { [weak self, weak avBackend] event in
            guard let self = self, let avBackend = avBackend, self.backend === avBackend else { return }
            self.handleBackendEvent(event)
        }
        avBackend.onVideoSize = { [weak self] _ in
            self?.updateDiagnostics()
        }
        backend = avBackend
        currentEngine = .avplayer
        avBackend.open(url: url, headers: PlayerKernel.httpHeaders(platform: session.room?.platform.rawValue)) { [weak self] ok in
            guard let self = self else {
                return
            }
            self.ensureMain {
                guard gen == self.generation else {
                    // Superseded: settle the attempt as failed so
                    // the completion is not dropped (build 35 #11).
                    finish(.failure(.loadFailed))
                    return
                }
                guard ok else {
                    // AVPlayer could not open it either: stay failed
                    // rather than looping back to the soft engine.
                    self.playRequested = false
                    self.isLoading = false
                    self.recomputePlayingState()
                    finish(.failure(.loadFailed))
                    return
                }
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
        guard gen == generation else {
            // Superseded: settle the attempt as failed so the
            // completion is not dropped (build 35 #11).
            finish(.failure(.loadFailed))
            return
        }
        playRequested = true
        stallFailed = false
        stallWarning = false
        isLoading = false
        backend.play()
        // (b49fix2 P1-31) Re-apply audio-only to the fresh
        // backend: a stall recovery / line switch / reopen while
        // backgrounded installs a new backend with video back
        // on, silently breaking the audio-only contract. Mirror
        // of VideoDriver.finishStartPlayback (which also lands
        // here via reopenOnAVPlayer).
        if isAudioOnly, let capable = backend as? LiveAudioOnlyCapable {
            capable.setAudioOnly(true)
        }
        do {
            // The audio session is global: an open used to reset
            // the category with no options, wiping the music
            // player's mix flag (Flutter's just_audio never resets
            // the category). Re-apply the stored switch instead.
            let mix = defaults.bool(forKey: SettingsStore.mixWithOthersKey)
            let options: AVAudioSession.CategoryOptions = mix ? [.mixWithOthers] : []
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: options)
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            // Audio session failure must not fail playback: the
            // video still plays, just without the session guarantee.
            NSLog("[HAoStudio][Live] audio session failed: %@", error.localizedDescription)
        }
        currentRoom = item
        pendingItem = nil
        position = 0
        currentLineIndex = session.recovery?.currentLineIndex ?? 0
        currentQuality = session.currentQuality
        // The open succeeded: any earlier failure for this room
        // is stale (a retry that landed, or a quality/line switch
        // after a failure) — the failure card must go.
        openFailure = nil
        lastFailedItem = nil
        session.stallWatchdog.reset()
        session.notePlaybackStarted()
        startPositionTimerIfNeeded()
        fpsSampler.start()
        updateDiagnostics()
        recomputePlayingState()
        finish(.success(()))
        onRoomStarted?(item)
        // S5-A: the open verified playback on this engine — record
        // it once, here, as the last-used engine. (The AVPlayer
        // reopen path also lands here, so a soft-decode fallback
        // records AVPlayer, not the engine that failed.)
        VideoEngineReporter.shared.noteUsed(backend.engine)
    }

    private func stopBackendForNewRequest() {
        activeLadder = nil
        openTimeoutWork?.cancel()
        openTimeoutWork = nil
        playRequested = false
        // #6: a new request starts un-paused — see VideoDriver.
        backendPaused = false
        backend?.pause()
        backend?.shutdown()
        backend = nil
        positionTimer?.invalidate()
        positionTimer = nil
        fpsSampler.stop()
        // #5: same as VideoDriver — a room switch must not keep
        // reporting the OLD room as playing for the whole resolve
        // + open.
        self.recomputePlayingState()
    }

    // MARK: - Transport

    func resume() {
        ensureMain {
            guard self.currentRoom != nil, self.backend != nil else {
                return
            }
            if self.isPlaying {
                return
            }
            self.playRequested = true
            self.stallFailed = false
            self.stallWarning = false
            // #6: resume intends playback — clear a stale
            // backend-paused flag (see VideoDriver).
            self.backendPaused = false
            self.backend?.play()
            self.session.stallWatchdog.noteBaseline()
            self.session.noteResumed()
            self.recomputePlayingState()
            self.updateNowPlayingInfo()
        }
    }

    func pause() {
        ensureMain {
            guard self.currentRoom != nil else {
                return
            }
            self.playRequested = false
            self.backend?.pause()
            self.session.notePlaybackPaused()
            self.recomputePlayingState()
            self.updateNowPlayingInfo()
        }
    }

    // MARK: - Interruption (b49fix2 P1-6 / P1-33)

    /// Phone call / Siri / alarm: pause on .began (remembering
    /// whether the room was playing — MPV/IJK do not auto-pause,
    /// so the driver pauses explicitly through backend.pause(),
    /// which works on every engine), resume on .ended when the
    /// system says it should. Same shape as
    /// NativeMusicPlayer.handleInterruption.
    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            guard isPlaying else { return }
            wasPlayingBeforeInterruption = true
            pause()
        case .ended:
            guard wasPlayingBeforeInterruption else { return }
            wasPlayingBeforeInterruption = false
            if let optionsRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                if options.contains(.shouldResume) { resume() }
            }
        @unknown default:
            break
        }
    }

    // MARK: - Now Playing and remote commands (b45 M2)

    /// Whether this driver currently owns the single Now Playing
    /// slot (registered commands + info). The coordinator switches
    /// the slot between domains — music / VOD / live — so only
    /// one driver is registered at a time.
    private var nowPlayingActive = false

    /// Publish this driver's Now Playing registration + info.
    /// Called by the coordinator when a room really starts
    /// (onRoomStarted), after clearing the other domains.
    /// Registers play/pause/toggle ONLY — live has no tracks
    /// (no next/previous) and is real-time (no seek).
    func publishNowPlaying() {
        ensureMain {
            guard self.currentRoom != nil else { return }
            if self.nowPlayingActive {
                self.updateNowPlayingInfo()
                return
            }
            self.nowPlayingActive = true
            let center = MPRemoteCommandCenter.shared()
            center.playCommand.addTarget(self, action: #selector(self.remotePlay))
            center.pauseCommand.addTarget(self, action: #selector(self.remotePause))
            center.togglePlayPauseCommand.addTarget(self, action: #selector(self.remoteToggle))
            self.updateNowPlayingInfo()
        }
    }

    /// Clear this driver's Now Playing registration + info.
    /// Called by stop() / release() and by the coordinator when
    /// another domain takes the slot. Idempotent.
    func clearNowPlaying() {
        ensureMain {
            guard self.nowPlayingActive else { return }
            self.nowPlayingActive = false
            let center = MPRemoteCommandCenter.shared()
            center.playCommand.removeTarget(self)
            center.pauseCommand.removeTarget(self)
            center.togglePlayPauseCommand.removeTarget(self)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    private func updateNowPlayingInfo() {
        ensureMain {
            guard self.nowPlayingActive, let room = self.currentRoom else { return }
            var info: [String: Any] = [:]
            info[MPMediaItemPropertyTitle] = room.title
            info[MPMediaItemPropertyArtist] = room.artist ?? ""
            // Live is real-time: no duration, no elapsed time.
            info[MPNowPlayingInfoPropertyPlaybackRate] = self.isPlaying ? 1.0 : 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    @objc private func remotePlay() -> MPRemoteCommandHandlerStatus {
        resume()
        return .success
    }

    @objc private func remotePause() -> MPRemoteCommandHandlerStatus {
        pause()
        return .success
    }

    @objc private func remoteToggle() -> MPRemoteCommandHandlerStatus {
        if isPlaying { pause() } else { resume() }
        return .success
    }

    /// Set picture fit (适应 / 裁剪 / 拉伸), applied live to the
    /// backend. Same control as VOD.
    func setVideoFit(_ fit: VideoFit) {
        ensureMain {
            self.backend?.setVideoFit(fit)
        }
    }

    /// Live has NO seek: a live stream is real-time and cannot be
    /// sped up, rewound or re-watched. Always completes false so
    /// the UI never pretends a seek landed.
    func seek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        completion(false)
    }

    /// Stop everything and clear the current room. Live has no
    /// breakpoint to save. The coordinator clears `currentItem`
    /// alongside; this driver never leaves a ghost engine sounding
    /// after stop.
    func stop() {
        ensureMain {
            self.nextGeneration()
            // B36 item 5: invalidate in-flight attemptOpen
            // completions too (see release() — same hole).
            self.openAttemptToken += 1
            self.activeLadder = nil
            self.openTimeoutWork?.cancel()
            self.openTimeoutWork = nil
            self.endChainBackgroundTask()
            self.positionTimer?.invalidate()
            self.positionTimer = nil
            self.fpsSampler.stop()
            self.playRequested = false
            self.stallFailed = false
            self.stallWarning = false
            self.pendingItem = nil
            self.backend?.pause()
            self.backend?.shutdown()
            self.backend = nil
            self.currentRoom = nil
            self.currentEngine = nil
            self.position = 0
            self.isLoading = false
            self.isAudioOnly = false
            self.fellBackForSoftwareDecode = false
            self.lastFps = 0
            // D11: the published room state is reset on exit too,
            // so a stale tier / failure never survives into the
            // next room even if configure is not reached first.
            self.currentQuality = nil
            self.currentLineIndex = 0
            self.openFailure = nil
            self.lastFailedItem = nil
            self.lastDroppedFrames = 0
            self.diagnostics = .empty
            self.recomputePlayingState()
            // b45 M2: a stopped room owns no Now Playing slot.
            self.clearNowPlaying()
        }
    }

    /// Release on exit: cancel timers, shut the backend down, exit
    /// the session (which cancels the prefetch timer and drops the
    /// room), THEN call completion. The room page calls this before
    /// dismissing. Unlike `stop()`, this also clears the room
    /// context — the next open starts from a fresh `configure`.
    func release(completion: @escaping () -> Void) {
        ensureMain {
            self.nextGeneration()
            // B36 item 5: invalidate in-flight attemptOpen
            // completions. stop()/release() already bump the
            // generation, but the attempt token is the guard
            // attemptOpen's completion checks — and a re-entry
            // for the SAME room re-sets pendingItem to the same
            // id, so without this a late failure from the
            // exited room's open passes both guards and runs
            // its fallback against the fresh session: it
            // reports the re-entered room failed (and clears
            // its pendingItem) before the new resolve answers.
            self.openAttemptToken += 1
            self.activeLadder = nil
            self.openTimeoutWork?.cancel()
            self.openTimeoutWork = nil
            self.endChainBackgroundTask()
            self.positionTimer?.invalidate()
            self.positionTimer = nil
            self.fpsSampler.stop()
            self.playRequested = false
            self.stallFailed = false
            // #9: release() must clear the stall warning too —
            // stop() does, release() did not.
            self.stallWarning = false
            self.pendingItem = nil
            self.backend?.pause()
            self.backend?.shutdown()
            self.backend = nil
            self.currentRoom = nil
            self.currentEngine = nil
            self.position = 0
            self.isLoading = false
            self.isAudioOnly = false
            self.fellBackForSoftwareDecode = false
            self.diagnostics = .empty
            self.session.exit()
            // D11: same reset as stop() — the room is gone, so
            // its tier / failure must not survive the exit.
            self.currentQuality = nil
            self.currentLineIndex = 0
            self.openFailure = nil
            self.lastFailedItem = nil
            self.recomputePlayingState()
            // b45 M2: exiting releases the Now Playing slot.
            self.clearNowPlaying()
            completion()
        }
    }

    // MARK: - Background audio (live only)

    /// Drop to audio-only (Flutter `setAudioOnly(true)`): stop the
    /// video track, keep the audio flowing. Records the flag and
    /// calls the backend seam when the backend implements it.
    /// VOD never takes this path.
    func setAudioOnly(_ audioOnly: Bool) {
        ensureMain {
            self.isAudioOnly = audioOnly
            if let capable = self.backend as? LiveAudioOnlyCapable {
                capable.setAudioOnly(audioOnly)
            }
        }
    }

    /// App backgrounded: the session decides whether this room is
    /// actually playing; when it is, drop to audio-only.
    @discardableResult
    func enterBackground() -> Bool {
        guard session.enterBackground() else {
            return false
        }
        setAudioOnly(true)
        return true
    }

    /// App foregrounded: restore the video track, and resume if the
    /// engine paused natively anyway (play() on an already-playing
    /// player is a no-op).
    @discardableResult
    func enterForeground() -> Bool {
        guard session.enterForeground() else {
            return false
        }
        setAudioOnly(false)
        // (b49fix2 P1-34) Resume only when the session is
        // actually playing: a room the user paused from the lock
        // screen / Control Center while backgrounded must stay
        // paused on return, not restart by itself. (The video
        // track is still restored above — the flag, not the
        // pause, owns that.)
        if backend != nil, session.state == .playing {
            resume()
        }
        return true
    }

    // MARK: - Backend events + position timer

    private func handleBackendEvent(_ event: VideoBackendEvent) {
        ensureMain {
            switch event {
            case .prepared:
                self.isLoading = false
                self.updateDiagnostics()
            case .firstFrame:
                self.isLoading = false
                self.updateDiagnostics()
            case .playing:
                self.backendPaused = false
                self.recomputePlayingState()
            case .paused:
                // #6: the engine paused itself — report not-playing
                // at once instead of letting the buffering branch
                // mask it until the next tick.
                self.backendPaused = true
                self.recomputePlayingState()
            case .stalled:
                // Pre-start only: the watchdog owns stalls after start.
                if self.position <= 0 {
                    self.isLoading = true
                }
            case .finished(let reason):
                switch reason {
                case .ended:
                    // A clean EOF on a live stream means the room
                    // ended: fail visibly, no recovery loop — there
                    // is no next episode and re-parsing a finished
                    // room only burns the budget. (b49 sweep #31:
                    // this used to call stop() + onRoomFailed with
                    // no openFailure, so the page kept its generic
                    // placeholder with no retry.) Set after stop(),
                    // which clears the failure state, and keep the
                    // item so the card's retry re-opens the room.
                    if let item = self.currentRoom {
                        self.stop()
                        self.openFailure = .offline
                        self.lastFailedItem = item
                        self.onRoomFailed?(item, .offline)
                    }
                case .error:
                    self.recoverFromStall()
                }
            }
        }
    }

    /// One stall failure: ask the session for the next recovery
    /// step and run it. The budget lives in the session — when it
    /// is spent the step is `.exhausted` and the room fails
    /// visibly instead of retrying forever.
    private func recoverFromStall() {
        guard let item = currentRoom else {
            return
        }
        // A stall recovery is a fresh open chain (b49 sweep #12):
        // it gets its own 25 s budget, never the entry chain's
        // (possibly spent) deadline.
        beginAttemptChain()
        // B36 item 5: same token rule as the entry resolve — a
        // back-out bumps the token, so a late re-parse from the
        // exited room cannot reopen against a fresh re-entry
        // for the same room id.
        let token = openAttemptToken
        stallFailed = true
        stallWarning = false
        // #6: a stall means not playing — report it synchronously
        // instead of leaving isPlaying stale-true for up to one
        // 0.5 s tick (or until the recovery open recomputes).
        self.recomputePlayingState()
        let step = session.noteFailure()
        switch step {
        case .useHeld:
            // Spend the held plan (adopts it: new lines + lease)
            // and open its matched line.
            if session.recovery?.takeHeld() != nil, let url = session.recovery?.currentUrl {
                attemptOpen(item: item, url: url, tried: [url], freshRounds: 2)
            } else {
                stop()
                // (b49fix2 P1-6) The stall walk is spent: the
                // room failed, and the page must show why with a
                // retry (D10) — set after stop(), which clears
                // the failure state, like .exhausted does.
                self.openFailure = .timeout
                self.lastFailedItem = item
                onRoomFailed?(item, .timeout)
            }
        case .fetchFresh:
            session.recovery?.fetchFresh(completion: { [weak self] resolution in
                guard let self = self else {
                    return
                }
                self.ensureMain {
                    guard token == self.openAttemptToken, self.currentRoom?.id == item.id else {
                        return
                    }
                    if let resolution = resolution, let url = self.session.recovery?.currentUrl, !resolution.appliedUrls.isEmpty {
                        self.stallFailed = false
                        self.attemptOpen(item: item, url: url, tried: [url], freshRounds: 2)
                        return
                    }
                    // Live re-parse gave nothing (throttled /
                    // failed): fall through to the next line once,
                    // never the dead URL.
                    if let next = self.session.recovery?.nextLineUrl {
                        self.stallFailed = false
                        self.attemptOpen(item: item, url: next, tried: [next], freshRounds: 2)
                        return
                    }
                    self.stop()
                    // (b49fix2 P1-6) Same failure-card rule as
                    // .exhausted: set after stop().
                    self.openFailure = .timeout
                    self.lastFailedItem = item
                    self.onRoomFailed?(item, .timeout)
                }
            })
            if session.recovery == nil {
                stop()
                // (b49fix2 P1-6) Same failure-card rule as
                // .exhausted: set after stop().
                self.openFailure = .timeout
                self.lastFailedItem = item
                onRoomFailed?(item, .timeout)
            }
        case .nextLine(let url):
            stallFailed = false
            // Build 35 sweep S2: `nextLineUrl` is computed from
            // the current index but never advances it, so the
            // recovery opened the next line while the index (and
            // the picker highlight) still named the dead one.
            // Point the index at the URL actually opened, like
            // the attemptOpen fallback does.
            if let index = session.recovery?.urls.firstIndex(of: url) {
                session.recovery?.currentLineIndex = index
            }
            attemptOpen(item: item, url: url, tried: [url], freshRounds: 2)
        case .exhausted:
            stop()
            // The stall walk is spent: the room failed, and the
            // page must show why with a retry (D10) — set after
            // stop(), which clears the failure state.
            self.openFailure = .timeout
            self.lastFailedItem = item
            onRoomFailed?(item, .timeout)
        }
    }

    private func startPositionTimerIfNeeded() {
        guard positionTimer == nil else {
            return
        }
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else {
                return
            }
            self.handleTimeUpdate()
        }
    }

    private func handleTimeUpdate() {
        guard let backend = backend, currentRoom != nil else {
            return
        }
        let pos = backend.currentTime
        position = pos
        recomputePlayingState()
        switch session.tickWatchdog(position: pos, isPlaying: isPlaying) {
        case .none:
            break
        case .warn:
            stallWarning = true
        case .failed:
            recoverFromStall()
        }
    }
}

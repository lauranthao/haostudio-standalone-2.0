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

    // Driver wiring, set by the coordinator (callbacks) and by the
    // room page / app entry (room + resolver via `configure`).
    var resolveURL: ((PlaybackItem, [URL], @escaping (URL?) -> Void) -> Void)?
    var onRoomStarted: ((PlaybackItem) -> Void)?
    var onRoomFailed: ((PlaybackItem, MusicPlayerError) -> Void)?

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

    static let openTimeout: TimeInterval = 10

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
    private var pendingItem: PlaybackItem?
    private var playRequested: Bool = false
    private var stallFailed: Bool = false
    private var fellBackForSoftwareDecode = false

    private var openTimeoutWork: DispatchWorkItem?
    private var positionTimer: Timer?
    private var fpsSampler = VideoFpsSampler()
    private var lastFps: Double = 0
    private var lastDroppedFrames: Int = 0

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
    }

    deinit {
        positionTimer?.invalidate()
        openTimeoutWork?.cancel()
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
        let buffering = playRequested && backend != nil && !stallFailed
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
            fellBackForSoftwareDecode: fellBackForSoftwareDecode
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
    func configure(room: LiveRoom, resolver: LiveSiteResolver) {
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
            self.attemptOpen(item: item, url: url, tried: [url], freshRounds: 2)
        }
        return true
    }

    /// Switch quality (P0-09): the session re-parses and only
    /// commits when the returned resolution is for the requested
    /// quality; on failure the room keeps playing at the old
    /// quality and the completion reports false. On success the
    /// driver opens the new quality's matched line.
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
                    if let url = self.session.recovery?.currentUrl {
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
    /// "Preferred" is the resolved tier: Swift never persisted a
    /// preferred quality (`preferResolution` has no reader), so the
    /// best tier is the preference the ceiling caps. Wi-Fi /
    /// unknown and a switched-off downgrade both return nil.
    private func cellularDowngradeTarget(resolution: LivePlayUrlResolution) -> Int? {
        guard cellularDowngradeEnabled else { return nil }
        guard LiveDriver.detectNetworkType() == .cellular else { return nil }
        let names = resolution.qualities.map { $0.name }
        guard let applied = resolution.quality,
              let appliedIndex = resolution.qualities.firstIndex(where: { $0.id == applied.id }) else { return nil }
        let target = LiveCellularDowngrade.entryQualityIndex(
            qualityNames: names, preferredIndex: appliedIndex, network: .cellular)
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

    /// Start playback of a new room (no same-room check — callers
    /// that already decided this is a new request use this
    /// directly, e.g. `switchLine`, where the id is unchanged but
    /// the line is new).
    private func startNewRoomPlayback(item: PlaybackItem) {
        self.stopBackendForNewRequest()
        self.pendingItem = item
        self.stallFailed = false
        self.isLoading = true
        self.session.resolveInitial { [weak self] resolution in
            guard let self = self else {
                return
            }
            self.ensureMain {
                guard self.pendingItem?.id == item.id else {
                    return
                }
                guard let resolution = resolution, let url = resolution.appliedUrls.compactMap({ URL(string: $0) }).first else {
                    self.isLoading = false
                    self.pendingItem = nil
                    self.onRoomFailed?(item, .noPlayableURL)
                    return
                }
                // Cellular downgrade (wiring leg B; Flutter
                // live_room_page _loadRoom): on mobile data with the
                // switch on, cap the entry quality at the cellular
                // ceiling （超清及以下） before opening. The capped
                // tier is requested through the session (a failed
                // cap rolls back and the original URL still opens).
                if let target = self.cellularDowngradeTarget(resolution: resolution) {
                    self.session.requestQualityChange(to: resolution.qualities[target]) { [weak self] ok in
                        guard let self = self else { return }
                        self.ensureMain {
                            guard self.pendingItem?.id == item.id else { return }
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
    /// fresh re-parses per open).
    private func attemptOpen(item: PlaybackItem, url: URL, tried: [URL], freshRounds: Int) {
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
                return
            case .failure(let error):
                guard tried.count < 2 else {
                    self.isLoading = false
                    self.pendingItem = nil
                    self.onRoomFailed?(item, error)
                    return
                }
                self.resolveURL?(item, tried) { [weak self] nextURL in
                    guard let self = self else {
                        return
                    }
                    self.ensureMain {
                        guard self.pendingItem?.id == item.id else {
                            return
                        }
                        guard let nextURL = nextURL else {
                            self.isLoading = false
                            self.pendingItem = nil
                            self.onRoomFailed?(item, error)
                            return
                        }
                        self.attemptOpen(item: item, url: nextURL, tried: tried + [nextURL], freshRounds: freshRounds)
                    }
                }
                if self.resolveURL == nil {
                    self.isLoading = false
                    self.pendingItem = nil
                    self.onRoomFailed?(item, error)
                }
            }
        }
    }

    /// Open a URL on the first capable engine, falling down the
    /// ladder (capability order from PlayerKernel) on failure.
    /// 10 s open timeout (P0-04): a timeout is a stream error, the
    /// load is dropped and the driver falls to the next candidate.
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
                self.backend?.shutdown()
                self.backend = nil
                self.playRequested = false
                self.isLoading = false
                self.recomputePlayingState()
                finish(.failure(.timeout))
            }
            self.openTimeoutWork = timeoutWork
            DispatchQueue.main.asyncAfter(deadline: .now() + self.openTimeoutInterval, execute: timeoutWork)
            let engines = PlayerKernel.candidatesFor(url: url, declaredFormat: self.declaredFormat(for: url))
            let ladder = VideoRecoveryLadder(engines: engines, urls: [url], attempt: { [weak self] engine, attemptURL, attemptCompletion in
                guard let self = self else {
                    attemptCompletion(false)
                    return
                }
                self.openOnEngine(engine, url: attemptURL, gen: gen, completion: attemptCompletion)
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
        refreshURLs { [weak self] fresh in
            guard let self = self else {
                return
            }
            self.ensureMain {
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
        let backend = makeBackend(engine)
        backend.onEvent = { [weak self] event in
            self?.handleBackendEvent(event)
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
        avBackend.onEvent = { [weak self] event in
            self?.handleBackendEvent(event)
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
            guard self.currentRoom != nil, self.backend != nil else {
                return
            }
            if self.isPlaying {
                return
            }
            self.playRequested = true
            self.stallFailed = false
            self.stallWarning = false
            self.backend?.play()
            self.session.stallWatchdog.noteBaseline()
            self.session.noteResumed()
            self.recomputePlayingState()
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
        }
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
            self.activeLadder = nil
            self.openTimeoutWork?.cancel()
            self.openTimeoutWork = nil
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
            self.lastDroppedFrames = 0
            self.diagnostics = .empty
            self.recomputePlayingState()
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
            self.activeLadder = nil
            self.openTimeoutWork?.cancel()
            self.openTimeoutWork = nil
            self.positionTimer?.invalidate()
            self.positionTimer = nil
            self.fpsSampler.stop()
            self.playRequested = false
            self.stallFailed = false
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
            self.recomputePlayingState()
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
        if backend != nil {
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
                self.recomputePlayingState()
            case .paused:
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
                    // room only burns the budget.
                    if let item = self.currentRoom {
                        self.stop()
                        self.onRoomFailed?(item, .loadFailed)
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
        stallFailed = true
        stallWarning = false
        let step = session.noteFailure()
        switch step {
        case .useHeld:
            // Spend the held plan (adopts it: new lines + lease)
            // and open its matched line.
            if session.recovery?.takeHeld() != nil, let url = session.recovery?.currentUrl {
                attemptOpen(item: item, url: url, tried: [url], freshRounds: 2)
            } else {
                stop()
                onRoomFailed?(item, .timeout)
            }
        case .fetchFresh:
            session.recovery?.fetchFresh(completion: { [weak self] resolution in
                guard let self = self else {
                    return
                }
                self.ensureMain {
                    guard self.currentRoom?.id == item.id else {
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
                    self.onRoomFailed?(item, .timeout)
                }
            })
            if session.recovery == nil {
                stop()
                onRoomFailed?(item, .timeout)
            }
        case .nextLine(let url):
            stallFailed = false
            attemptOpen(item: item, url: url, tried: [url], freshRounds: 2)
        case .exhausted:
            stop()
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

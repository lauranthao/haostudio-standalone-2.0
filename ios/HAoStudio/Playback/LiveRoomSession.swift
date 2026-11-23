// HAo Studio 2.0 — live room session (S4, leg A).
//
// Foundation-only room state machine + fetch-and-hold recovery, so
// the SwiftPM `VideoServicesTests` target can drive it without any
// engine, view or network. The driver (LiveDriver) owns engines;
// this file owns decisions: when to hold a fresh lease, when to
// spend it, when to re-parse, when to try the next line, when to
// give up, and what happens to quality / background audio.
//
// Behaviour baseline: Flutter `lib/features/live/live_recovery.dart`
// (fetch-and-hold) + `lib/domains/live/presentation/playback/
// live_room_page.dart` (recovery order + budget + background
// audio-only) + `lib/features/player/playback_session.dart`
// (4 s warn / 12 s fail watchdog). Differences from Flutter are
// called out where they exist.
//
// B-LEG CONTRACT (merged 2026-11-23): the room / line / quality /
// danmaku / resolver types live in `Services/LiveSites/
// LiveModels.swift` (B leg, canonical). This file only ever calls
// the resolver through the single `fetchFromResolver` path.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

// MARK: - Stall watchdog (live twin of VodStallWatchdog)

/// Position watchdog (Flutter `playback_session.dart`
/// `_startHealthWatch`): 4 s of no position movement only shows
/// "重新连接"; 12 s of no movement fails into recovery. Live has
/// no duration and no end-of-stream position, so there is no
/// `.atEnd` case — a live position never legitimately parks at an
/// end. Pure logic with an injectable clock so tests never wait
/// real seconds.
final class LiveStallWatchdog {
    enum Event: Equatable {
        case none
        case warn
        case failed
    }

    static let warnAfter: TimeInterval = 4
    static let failAfter: TimeInterval = 12

    /// Injectable clock. Production uses the wall clock; tests drive it.
    var now: () -> Date = { Date() }

    private var lastProgressAt: Date?
    private var lastPosition: Double = 0
    private var progressSeen = false
    private var warned = false

    func reset() {
        lastProgressAt = now()
        lastPosition = 0
        progressSeen = false
        warned = false
    }

    func noteBaseline() {
        lastProgressAt = now()
    }

    func tick(position: Double, isPlaying: Bool) -> Event {
        if position != lastPosition {
            lastPosition = position
            lastProgressAt = now()
            if position > 0 {
                progressSeen = true
            }
            // The clock restarts, but the warn does not: one warn
            // per stall episode, and a movement is not a new
            // episode — otherwise a stalled stream would warn again
            // 4 s after every position jump.
            return .none
        }
        guard isPlaying, let since = lastProgressAt else {
            return .none
        }
        let stalledFor = now().timeIntervalSince(since)
        if stalledFor >= LiveStallWatchdog.failAfter {
            lastProgressAt = nil
            return .failed
        }
        if stalledFor >= LiveStallWatchdog.warnAfter && !warned {
            warned = true
            return .warn
        }
        return .none
    }
}

// MARK: - Fetch-and-hold recovery (Flutter LiveRecovery)

/// Lease recovery (Flutter `lib/features/live/live_recovery.dart`).
/// Live play URLs expire: Huya's anti-code is shared across ALL
/// lines of a room and expires ~100-130 s after issue — so NEVER
/// retry the same URL. Fixed order on failure: (1) the held
/// prefetched plan (costs no request); (2) a live re-parse
/// (`fetchFresh`, throttled to once per 60 s, 10 s timeout);
/// (3) the next CDN line. A held plan past its hard expiry is
/// never served. Lines are identified by URL (CDN + path +
/// credential family), NOT by index — a refresh can turn a TX FLV
/// line into TX HLS.
final class LiveRecovery {
    static let freshFetchThrottle: TimeInterval = 60
    static let freshFetchTimeout: TimeInterval = 10
    static let prefetchAfterIssue: TimeInterval = 100
    static let hardExpiryAfterIssue: TimeInterval = 125
    static let refreshRetry: TimeInterval = 10

    let roomId: String
    var resolver: LiveSiteResolver?
    /// The quality the current lines were resolved for. Mutable on
    /// purpose: every fresh re-parse (prefetch / recovery / manual
    /// retry) must use the CURRENT quality.
    var quality: LiveQuality?

    /// Injectable clock. Production uses the wall clock; tests drive it.
    var now: () -> Date = { Date() }

    /// Test seam: re-parse timeout seconds. Production is 10.
    var timeoutInterval: TimeInterval = LiveRecovery.freshFetchTimeout

    /// Current resolved lines, in platform order.
    private(set) var lines: [LiveLine] = []
    /// Declared format per flattened URL, same order as `urls`
    /// (the line's own format, repeated per URL on that line).
    /// Computed from `urlFacts` together with `urls`, so the two
    /// can never drift apart when a URL string fails to parse.
    var formats: [String] {
        return urlFacts.map { $0.format }
    }
    /// Qualities the room offers, from the last resolution.
    private(set) var qualities: [LiveQuality] = []
    /// Index of the line currently playing (indexes `urls`).
    var currentLineIndex: Int = 0
    /// When the current resolution was issued (for 100 s / 125 s math).
    private(set) var issuedAt: Date?
    /// Lease deadlines of the CURRENT resolution, when the platform
    /// reports them (Huya/Douyu do; Douyin leaves them nil — no
    /// lease, no prefetch, exactly like Pure Live's `lease == null`
    /// early-out).
    private(set) var refreshAt: Date?
    private(set) var invalidAt: Date?

    /// The held prefetched resolution: fetched at refreshAt, spent
    /// by the next recovery, never opened on its own.
    private var held: LivePlayUrlResolution?
    private var lastFreshFetchAt: Date?
    private var prefetchTimer: Timer?
    private var disposed = false

    init(roomId: String, resolver: LiveSiteResolver?, quality: LiveQuality? = nil, now: @escaping () -> Date = { Date() }) {
        self.roomId = roomId
        self.resolver = resolver
        self.quality = quality
        self.now = now
    }

    deinit {
        prefetchTimer?.invalidate()
    }

    /// (URL, format) pairs, one per playable URL string, in line
    /// order. B leg's `LiveLine.urls` are strings, so a string that
    /// is not a valid URL is dropped here — together with its
    /// format — which keeps `urls` and `formats` aligned.
    var urlFacts: [(url: URL, format: String)] {
        return lines.flatMap { line in
            line.urls.compactMap { raw -> (URL, String)? in
                guard let url = URL(string: raw) else { return nil }
                return (url, line.format)
            }
        }
    }

    /// All stream URLs, flattened from `lines` in platform order.
    var urls: [URL] {
        return urlFacts.map { $0.url }
    }

    var currentUrl: URL? {
        guard !urls.isEmpty else {
            return nil
        }
        return urls[currentLineIndex % urls.count]
    }

    /// The next line, wrapping around. Nil when there is only one URL.
    var nextLineUrl: URL? {
        guard urls.count >= 2 else {
            return nil
        }
        return urls[(currentLineIndex + 1) % urls.count]
    }

    /// Advance to the next line WITHOUT a network request. Returns
    /// the URL to open, or nil when there is no other line.
    @discardableResult
    func advanceLine() -> URL? {
        guard let next = nextLineUrl else {
            return nil
        }
        currentLineIndex = (currentLineIndex + 1) % urls.count
        return next
    }

    /// Declared format for one flattened URL index ("other" when
    /// the platform declared nothing for that line).
    func factsFor(index: Int) -> String {
        guard index >= 0 && index < formats.count else {
            return "other"
        }
        return formats[index]
    }

    /// True when a `fetchFresh` right now would be throttled.
    var isFetchFreshThrottled: Bool {
        guard let last = lastFreshFetchAt else {
            return false
        }
        return now().timeIntervalSince(last) < LiveRecovery.freshFetchThrottle
    }

    /// Install a resolution as the current lines: replaces lines /
    /// formats / lease, matches the previously playing line by URL
    /// identity (not by index), and re-arms the hold timer at the
    /// new resolution's refreshAt.
    func adopt(resolution: LivePlayUrlResolution, previousUrl: URL?) {
        let previous = previousUrl ?? currentUrl
        lines = resolution.lines
        qualities = resolution.qualities
        quality = resolution.quality
        issuedAt = resolution.issuedAt
        refreshAt = resolution.refreshAt
        invalidAt = resolution.invalidAt
        currentLineIndex = matchLineIndex(urls: urls, previousUrl: previous)
        schedulePrefetch()
    }

    /// The initial resolve for a room. NOT throttled (the happy path
    /// never goes through `fetchFresh`) and NOT a recovery fetch:
    /// it adopts the resolution and arms the lease prefetch, so the
    /// hold timer exists on the happy path too — without this the URL
    /// would die at its ~125 s hard expiry with nothing held.
    func resolveInitial(completion: @escaping (LivePlayUrlResolution?) -> Void) {
        fetchFromResolver { [weak self] resolution in
            guard let self = self else {
                completion(nil)
                return
            }
            guard let resolution = resolution, !resolution.appliedUrls.isEmpty else {
                completion(nil)
                return
            }
            self.adopt(resolution: resolution, previousUrl: nil)
            completion(resolution)
        }
    }

    /// Re-parse a FRESH resolution from the platform. Never returns
    /// the old URLs: recovery must RE-PARSE, never retry the same
    /// URL. Returns nil when throttled, timed out, or the room is
    /// offline / parse failed. A null result means: show the failure
    /// card (or try the next line), do not loop. With `adopting`
    /// false the resolution is returned WITHOUT installing it, so a
    /// quality switch can inspect it first and roll back on a
    /// mismatch without ever touching the playing lines.
    func fetchFresh(adopting: Bool = true, completion: @escaping (LivePlayUrlResolution?) -> Void) {
        let current = now()
        if let last = lastFreshFetchAt, current.timeIntervalSince(last) < LiveRecovery.freshFetchThrottle {
            completion(nil)
            return
        }
        lastFreshFetchAt = current
        fetchFromResolver { [weak self] resolution in
            guard let self = self else {
                completion(nil)
                return
            }
            guard let resolution = resolution, !resolution.appliedUrls.isEmpty else {
                completion(nil)
                return
            }
            if adopting {
                self.adopt(resolution: resolution, previousUrl: nil)
            }
            completion(resolution)
        }
    }

    /// Fetch a fresh resolution and HOLD it (Pure Live `_prefetch`).
    /// Never touches the playing transport, the current lines, or
    /// the recovery throttle stamp: holding costs no stream switch,
    /// so it must not block a later recovery fetch. On success the
    /// hold is replaced and the next hold chains at the HELD plan's
    /// refreshAt (else its issuedAt + 100 s); on failure — or an
    /// empty plan — retry after `refreshRetry`. Past hard expiry
    /// there is nothing worth holding: the stall watchdog owns
    /// recovery from there.
    func performPrefetch() {
        guard !disposed, !isExpired else {
            return
        }
        fetchFromResolver { [weak self] resolution in
            guard let self = self else {
                return
            }
            guard !self.disposed else {
                return
            }
            guard let resolution = resolution, !resolution.appliedUrls.isEmpty else {
                self.schedulePrefetch(at: self.now().addingTimeInterval(LiveRecovery.refreshRetry))
                return
            }
            self.held = resolution
            let next = resolution.refreshAt ?? resolution.issuedAt.addingTimeInterval(LiveRecovery.prefetchAfterIssue)
            self.schedulePrefetch(at: next ?? self.now().addingTimeInterval(LiveRecovery.refreshRetry))
        }
    }

    /// Take the held prefetched resolution for recovery (first
    /// refresh attempt): one-shot — clears the hold — and only when
    /// its hard expiry is still in the future. Installing it
    /// replaces the current lines/facts/lease exactly like
    /// `fetchFresh` does, and re-arms the hold timer at the new
    /// resolution's refreshAt. Costs no request and no throttle
    /// stamp: the hold was fetched earlier, taking it is free.
    func takeHeld() -> LivePlayUrlResolution? {
        guard let held = peekHeld() else {
            return nil
        }
        self.held = nil
        let previousUrl = currentUrl
        adopt(resolution: held, previousUrl: previousUrl)
        return held
    }

    /// Look at the held plan WITHOUT spending it. Nil when nothing
    /// usable is held (nothing held, empty, or past hard expiry).
    func peekHeld() -> LivePlayUrlResolution? {
        guard let held = held, !held.appliedUrls.isEmpty else {
            return nil
        }
        if let invalid = held.invalidAt, invalid <= now() {
            return nil
        }
        return held
    }

    /// Drop the held plan (a NEW resolution was adopted — initial
    /// resolve or quality switch — and a hold fetched for the old
    /// quality must never be served for the new one).
    func discardHeld() {
        held = nil
    }

    /// Arm the lease prefetch (Pure Live `_schedulePrefetch`): at
    /// `target` — default the CURRENT resolution's refreshAt —
    /// fetch a fresh resolution and HOLD it. No lease deadline
    /// (`refreshAt` nil, e.g. Douyin) means no prefetch at all. A
    /// deadline already past fires in 1 s instead of never firing.
    func schedulePrefetch(at target: Date? = nil) {
        prefetchTimer?.invalidate()
        prefetchTimer = nil
        guard !disposed else {
            return
        }
        guard let delay = prefetchDelay(at: target ?? refreshAt, from: now()) else {
            return
        }
        prefetchTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.performPrefetch()
        }
    }

    /// Pure prefetch timing: seconds until `target`, clamped to a
    /// 1 s minimum; nil when there is no lease deadline at all.
    /// Kept pure so tests can drive it without waiting on a Timer.
    func prefetchDelay(at target: Date?, from nowDate: Date) -> TimeInterval? {
        guard let target = target else {
            return nil
        }
        let remaining = target.timeIntervalSince(nowDate)
        if remaining > 1 {
            return remaining
        }
        return 1
    }

    /// True when the current URL is past its hard expiry (~125 s).
    var isExpired: Bool {
        if let invalid = invalidAt {
            return now() > invalid
        }
        guard let issued = issuedAt else {
            return false
        }
        return now() > issued.addingTimeInterval(LiveRecovery.hardExpiryAfterIssue)
    }

    func dispose() {
        disposed = true
        prefetchTimer?.invalidate()
        prefetchTimer = nil
    }

    // MARK: - Private

    /// The single resolver call site. Passes the session's current
    /// quality (nil = default/best) and maps a resolver failure to
    /// nil — the caller falls through to the next line or the
    /// failure card, never a retry of the same call. 10 s timeout:
    /// a timeout is a stream error, exactly like a failed parse.
    private func fetchFromResolver(completion: @escaping (LivePlayUrlResolution?) -> Void) {
        guard let resolver = resolver else {
            completion(nil)
            return
        }
        var completed = false
        var timeoutWork: DispatchWorkItem?
        let finish: (LivePlayUrlResolution?) -> Void = { result in
            guard !completed else {
                return
            }
            completed = true
            timeoutWork?.cancel()
            completion(result)
        }
        timeoutWork = DispatchWorkItem {
            finish(nil)
        }
        if let work = timeoutWork {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutInterval, execute: work)
        }
        resolver.resolve(roomId: roomId, quality: quality) { result in
            switch result {
            case .success(let resolution):
                finish(resolution)
            case .failure:
                finish(nil)
            }
        }
    }

    /// Match a previously playing URL in a refreshed list by CDN +
    /// media path, ignoring signature query changes. Falls back to
    /// line 0. Two passes: exact host + path first; then CDN token +
    /// media id (the second pass matters when a refresh changes a
    /// line's FORMAT: TX FLV -> TX HLS changes the host and the
    /// path suffix, but the CDN token + media id still identify it).
    func matchLineIndex(urls: [URL], previousUrl: URL?) -> Int {
        guard let previous = previousUrl, !urls.isEmpty else {
            return 0
        }
        for (index, candidate) in urls.enumerated() {
            if candidate.host == previous.host && candidate.path == previous.path {
                return index
            }
        }
        for (index, candidate) in urls.enumerated() {
            if cdnToken(candidate.host) == cdnToken(previous.host) && mediaId(candidate.path) == mediaId(previous.path) {
                return index
            }
        }
        return 0
    }

    /// First host label: the CDN token (tx / al / hs …).
    private func cdnToken(_ host: String?) -> String? {
        guard let host = host else {
            return nil
        }
        return host.split(separator: ".").first.map { String($0) }
    }

    /// Last path segment minus its format extension (1.flv / 1.m3u8 -> 1).
    private func mediaId(_ path: String) -> String {
        let last = path.split(separator: "/").last.map { String($0) } ?? ""
        return URL(fileURLWithPath: last).deletingPathExtension().lastPathComponent
    }

}

// MARK: - Room state machine

/// Room state machine (Foundation-only). The driver owns engines;
/// this owns the room's state, the consecutive-failure budget, the
/// quality rollback (P0-09) and the background-audio flag. It never
/// touches music: exiting a room does NOT resume music (music has
/// its own background logic) — the session simply stops being a
/// room.
final class LiveRoomSession {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case buffering
        case reconnecting
        case paused
        case failed(String)
        case exited
    }

    /// One recovery decision. `.useHeld` carries the held URLs
    /// (the driver still spends them through `takeHeld`, which is
    /// what adopts them); `.fetchFresh` means "live re-parse now";
    /// `.nextLine` is the next CDN line, no request needed.
    enum RecoveryStep: Equatable {
        case useHeld([URL])
        case fetchFresh
        case nextLine(URL)
        case exhausted
    }

    /// Injectable clock, propagated to the watchdog and the
    /// recovery. Production uses the wall clock; tests drive it.
    var now: () -> Date = { Date() } {
        didSet {
            stallWatchdog.now = now
            recovery?.now = now
        }
    }

    private(set) var state: State = .idle
    private(set) var room: LiveRoom?
    private(set) var currentQuality: LiveQuality?
    private(set) var consecutiveFailures: Int = 0
    private(set) var isBackgroundAudioOnly: Bool = false
    private(set) var stallWarning: Bool = false

    private(set) var recovery: LiveRecovery?
    let stallWatchdog = LiveStallWatchdog()

    private var resolver: LiveSiteResolver?
    private var pendingQuality: LiveQuality?
    private var previousQuality: LiveQuality?

    init() {
        stallWatchdog.now = now
    }

    // MARK: - Auto-recovery budget (Flutter LiveRoomPage)

    /// How many recovery attempts run before the failure card.
    /// Multi-line rooms keep the old bound (one attempt per extra
    /// line: `lineCount - 1`). A single-line room (Kuaishou by
    /// design, Douyin often 1-2 lines) gets the session ladder's
    /// fresh budget (`freshRounds = 2`): without it the FIRST error
    /// showed the failure card and recovery never ran.
    static func autoRecoveryBudget(lineCount: Int) -> Int {
        if lineCount == 1 {
            return 2
        }
        return max(0, lineCount - 1)
    }

    // MARK: - Room lifecycle

    /// Enter a room: reset all counters, build the recovery for
    /// this room, and go to `.loading` (the driver resolves and
    /// opens from here).
    func enterRoom(room: LiveRoom, resolver: LiveSiteResolver) {
        self.room = room
        self.resolver = resolver
        self.consecutiveFailures = 0
        self.isBackgroundAudioOnly = false
        self.stallWarning = false
        self.currentQuality = nil
        self.pendingQuality = nil
        self.previousQuality = nil
        let recovery = LiveRecovery(roomId: room.roomId, resolver: resolver, quality: nil, now: now)
        self.recovery = recovery
        stallWatchdog.reset()
        state = .loading
    }

    /// The initial resolve for the room (not throttled — the happy
    /// path never goes through `fetchFresh`). Adopts the resolution
    /// and arms the lease prefetch.
    func resolveInitial(completion: @escaping (LivePlayUrlResolution?) -> Void) {
        guard let recovery = recovery else {
            completion(nil)
            return
        }
        recovery.resolveInitial { [weak self] resolution in
            guard let self = self else {
                completion(nil)
                return
            }
            if let resolution = resolution {
                self.currentQuality = resolution.quality
            }
            completion(resolution)
        }
    }

    /// Adopt a resolution the driver (or the room page) resolved
    /// another way — e.g. the initial resolve done outside this
    /// session. Keeps `currentQuality` in sync with the lines.
    func adoptResolution(_ resolution: LivePlayUrlResolution) {
        recovery?.adopt(resolution: resolution, previousUrl: nil)
        currentQuality = resolution.quality
    }

    /// Healthy playback started (or resumed after a recovery):
    /// the consecutive-failure budget resets, so the bound covers
    /// one episode of consecutive failures only.
    func notePlaybackStarted() {
        consecutiveFailures = 0
        stallWarning = false
        state = .playing
    }

    func notePlaybackPaused() {
        if state == .playing {
            state = .paused
        }
    }

    func noteResumed() {
        if state == .paused {
            state = .playing
        }
    }

    /// One watchdog tick (the driver ticks every 0.5 s with the
    /// backend position). Warn sets the "重新连接" flag; failed is
    /// the caller's cue to run `noteFailure`.
    func tickWatchdog(position: Double, isPlaying: Bool) -> LiveStallWatchdog.Event {
        let event = stallWatchdog.tick(position: position, isPlaying: isPlaying)
        switch event {
        case .warn:
            stallWarning = true
        case .failed:
            stallWarning = false
        case .none:
            break
        }
        return event
    }

    // MARK: - Failure + recovery

    /// One failure (stall watchdog 12 s, open error, backend
    /// error): consume one unit of the auto-recovery budget. While
    /// budget remains, go to `.reconnecting` and return the next
    /// recovery step; when the budget is spent, go to `.failed` and
    /// return `.exhausted` — the room then shows the failure card
    /// instead of retrying lines forever.
    func noteFailure() -> RecoveryStep {
        consecutiveFailures += 1
        let lineCount = recovery?.urls.count ?? 0
        if consecutiveFailures > LiveRoomSession.autoRecoveryBudget(lineCount: lineCount) {
            state = .failed("播放失败，请检查网络后重试")
            return .exhausted
        }
        state = .reconnecting
        return nextRecoveryStep()
    }

    /// The next recovery step, in Flutter's order: the held plan
    /// first (no request), then a live re-parse, then the next line.
    /// The budget check lives in `noteFailure`, never here.
    func nextRecoveryStep() -> RecoveryStep {
        guard let recovery = recovery else {
            return .exhausted
        }
        if let held = recovery.peekHeld() {
            return .useHeld(matchedFirst(urls: held.appliedUrls.compactMap { URL(string: $0) }))
        }
        if !recovery.isFetchFreshThrottled {
            return .fetchFresh
        }
        if let next = recovery.nextLineUrl {
            return .nextLine(next)
        }
        return .exhausted
    }

    /// The given URLs with the currently playing line moved to the
    /// front (the line `takeHeld` / `fetchFresh` already matched by
    /// URL identity). The driver opens `first`, so this is what
    /// makes recovery resume the same line instead of line 0.
    func matchedFirst(urls: [URL]) -> [URL] {
        guard !urls.isEmpty, let recovery = recovery else {
            return urls
        }
        let index = recovery.currentLineIndex % urls.count
        if index == 0 {
            return urls
        }
        var reordered = urls
        let line = reordered.remove(at: index)
        reordered.insert(line, at: 0)
        return reordered
    }

    // MARK: - Quality (P0-09: failure rolls back)

    /// Switch quality: re-parse and adopt the new quality's lines
    /// ONLY when the returned resolution is actually for the
    /// requested quality; anything else (mismatch, empty, error,
    /// timeout) rolls back to the previous quality and reports
    /// false. The playing lines are never touched on a failed
    /// switch — the room keeps playing at the old quality.
    func requestQualityChange(to quality: LiveQuality, completion: @escaping (Bool) -> Void) {
        guard let recovery = recovery, room != nil else {
            completion(false)
            return
        }
        guard quality.id != currentQuality?.id else {
            completion(true)
            return
        }
        previousQuality = currentQuality
        pendingQuality = quality
        recovery.quality = quality
        recovery.fetchFresh(adopting: false) { [weak self] resolution in
            guard let self = self else {
                completion(false)
                return
            }
            guard let resolution = resolution, resolution.quality?.id == quality.id else {
                self.rollbackQuality()
                completion(false)
                return
            }
            self.recovery?.adopt(resolution: resolution, previousUrl: nil)
            self.recovery?.discardHeld()
            self.currentQuality = quality
            self.pendingQuality = nil
            self.previousQuality = nil
            completion(true)
        }
    }

    private func rollbackQuality() {
        recovery?.quality = previousQuality
        pendingQuality = nil
        previousQuality = nil
    }

    // MARK: - Background audio (live only)

    /// App backgrounded. Only when the room is actually trying to
    /// play (playing / buffering / opening); a user-paused room
    /// stays paused, and an error room has nothing to keep alive.
    /// Returns true when the driver should drop to audio-only.
    func enterBackground() -> Bool {
        switch state {
        case .playing, .buffering, .loading:
            isBackgroundAudioOnly = true
            return true
        case .idle, .paused, .reconnecting, .failed, .exited:
            return false
        }
    }

    /// App foregrounded. Returns true when audio-only was active
    /// and the driver should restore the video track (and resume if
    /// the engine paused natively anyway).
    func enterForeground() -> Bool {
        guard isBackgroundAudioOnly else {
            return false
        }
        isBackgroundAudioOnly = false
        return true
    }

    // MARK: - Exit

    /// Leave the room. Cancels the prefetch timer, drops the
    /// recovery and the room, and goes to `.exited`. Deliberately
    /// does NOT resume music: exiting a room never auto-resumes
    /// music (music has its own background logic).
    func exit() {
        recovery?.dispose()
        recovery = nil
        room = nil
        resolver = nil
        currentQuality = nil
        pendingQuality = nil
        previousQuality = nil
        consecutiveFailures = 0
        isBackgroundAudioOnly = false
        stallWarning = false
        state = .exited
    }
}

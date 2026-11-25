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
    /// Warns issued before the first position movement (slow
    /// start, b49fix2 P2-46): the pre-progress warn is a
    /// different episode from a genuine stall warn, so it gets
    /// its own flag — sharing `warned` let a slow-starting room
    /// warn once at 12 s and then never show the "加载缓慢…"
    /// pill for a later genuine stall.
    private var preProgressWarned = false

    func reset() {
        lastProgressAt = now()
        lastPosition = 0
        progressSeen = false
        warned = false
        preProgressWarned = false
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
            // Fail leg arms only after the first position movement
            // (b49 sweep #15): before the first frame the position
            // is legitimately static (slow start, backend prepared
            // but no frame yet), so a healthy-but-slow stream must
            // never fail here — warn-only until `progressSeen`
            // proves the stream can move at all. `progressSeen`
            // was set but never read before this fix.
            guard progressSeen else {
                if !preProgressWarned {
                    preProgressWarned = true
                    return .warn
                }
                return .none
            }
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

// MARK: - Preferred live quality (b49 sweep #14)
//
// The quality the user last picked, persisted per platform so the
// next room entry re-opens at that tier instead of the server best
// tier (the cellular downgrade then caps it, never re-applies as
// the choice itself). Stored in UserDefaults as one
// `[platformRawValue: qualityId]` dict under
// `hao_live_preferred_quality`. Foundation-only, so the harness
// can drive it without the driver. Only a user-initiated switch
// writes it (LiveDriver.switchQuality); entry / cellular caps
// never do.
enum LivePreferredQuality {
    static let defaultsKey = "hao_live_preferred_quality"

    /// The persisted quality id for this platform, or nil when the
    /// user never picked one (entry then opens at the best tier).
    static func preferredQualityId(for platform: LivePlatform, defaults: UserDefaults = .standard) -> String? {
        guard let stored = defaults.dictionary(forKey: defaultsKey) else {
            return nil
        }
        return stored[platform.rawValue] as? String
    }

    /// Persist (or clear, with nil) the user's picked tier for
    /// this platform.
    static func savePreferredQualityId(_ id: String?, for platform: LivePlatform, defaults: UserDefaults = .standard) {
        var stored = (defaults.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        if let id = id {
            stored[platform.rawValue] = id
        } else {
            stored.removeValue(forKey: platform.rawValue)
        }
        defaults.set(stored, forKey: defaultsKey)
    }

    /// Index of the preferred tier in the resolved quality list,
    /// or nil when there is no preference or it is not offered
    /// for this room (entry then falls back to the best tier).
    static func entryQualityIndex(qualities: [LiveQuality], preferredId: String?) -> Int? {
        guard let preferredId = preferredId else {
            return nil
        }
        return qualities.firstIndex(where: { $0.id == preferredId })
    }
}

// MARK: - Fetch-and-hold recovery (Flutter LiveRecovery)

/// Lease recovery (Flutter `lib/features/live/live_recovery.dart`).
/// Live play URLs expire: Huya's anti-code is shared across ALL
/// lines of a room and expires ~100-130 s after issue — so NEVER
/// retry the same URL. Fixed order on failure: (1) the held
/// prefetched plan (costs no request); (2) a live re-parse
/// (`fetchFresh`, throttled to once per 60 s, 20 s timeout);
/// (3) the next CDN line. A held plan past its hard expiry is
/// never served. Lines are identified by URL (CDN + path +
/// credential family), NOT by index — a refresh can turn a TX FLV
/// line into TX HLS.
final class LiveRecovery {
    static let freshFetchThrottle: TimeInterval = 60
    static let freshFetchTimeout: TimeInterval = 20
    static let prefetchAfterIssue: TimeInterval = 100
    static let hardExpiryAfterIssue: TimeInterval = 125
    static let refreshRetry: TimeInterval = 10

    let roomId: String
    var resolver: LiveSiteResolver?
    /// The room the session entered with (the list-feed room):
    /// its `data` may already hold signed stream URLs, which the
    /// resolver can use when the network re-parse fails (see
    /// `fetchFromResolver`). Nil for sessions built without a room.
    var sourceRoom: LiveRoom?
    /// The quality the current lines were resolved for. Mutable on
    /// purpose: every fresh re-parse (prefetch / recovery / manual
    /// retry) must use the CURRENT quality.
    ///
    /// Locked accessor (see `stateLock`): the quality is read on
    /// the resolver callback thread and written from the room
    /// session, while the driver reads it on main.
    private var _quality: LiveQuality?
    var quality: LiveQuality? {
        get { locked { _quality } }
        set { locked { _quality = newValue } }
    }
    /// Whether the most recent `fetchFromResolver` fetch failed
    /// with a definitive `LiveError.offline` — the room is not
    /// live. Set on EVERY fetch (see `finish`), so the driver can
    /// tell an off-air room ("房间未开播") from a generic resolve
    /// failure ("没有可播放的地址"). b39: chen 2026-11-25 saw the
    /// generic text on cxy0714 while the room was simply off air.
    /// Locked accessor (same pattern as `quality`).
    private var _lastResolveWasOffline = false
    var lastResolveWasOffline: Bool {
        get { locked { _lastResolveWasOffline } }
        set { locked { _lastResolveWasOffline = newValue } }
    }

    /// Injectable clock. Production uses the wall clock; tests drive it.
    var now: () -> Date = { Date() }

    /// Test seam: re-parse timeout seconds. Production is 20 — the
    /// Huya serial chain alone runs ~9–12 s on a slow link (room page
    /// + 3 serial WUP calls + anonymous login), so 10 s cut off
    /// successes that arrived just after the timeout.
    var timeoutInterval: TimeInterval = LiveRecovery.freshFetchTimeout

    /// Serialises every read/write of the resolution state below.
    /// Resolver callbacks arrive on URLSession background threads
    /// (`adopt` / the held plan run there) while the driver reads
    /// the same lines/qualities/index on main — unguarded that is
    /// a data race on the stored arrays. The lock is only ever
    /// held for the state touch, never across a network call or a
    /// completion; and a locked block never calls another locked
    /// accessor (backing vars are used inside — see `facts(for:)`).
    private let stateLock = NSLock()
    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// Current resolved lines, in platform order.
    private var _lines: [LiveLine] = []
    private(set) var lines: [LiveLine] {
        get { locked { _lines } }
        set { locked { _lines = newValue } }
    }
    /// Declared format per flattened URL, same order as `urls`
    /// (the line's own format, repeated per URL on that line).
    /// Computed from `urlFacts` together with `urls`, so the two
    /// can never drift apart when a URL string fails to parse.
    var formats: [String] {
        return urlFacts.map { $0.format }
    }
    /// Qualities the room offers, from the last resolution.
    private var _qualities: [LiveQuality] = []
    private(set) var qualities: [LiveQuality] {
        get { locked { _qualities } }
        set { locked { _qualities = newValue } }
    }
    /// Index of the line currently playing (indexes `urls`).
    private var _currentLineIndex: Int = 0
    var currentLineIndex: Int {
        get { locked { _currentLineIndex } }
        set { locked { _currentLineIndex = newValue } }
    }
    /// When the current resolution was issued (for 100 s / 125 s math).
    private var _issuedAt: Date?
    private(set) var issuedAt: Date? {
        get { locked { _issuedAt } }
        set { locked { _issuedAt = newValue } }
    }
    /// Lease deadlines of the CURRENT resolution, when the platform
    /// reports them (Huya/Douyu do; Douyin leaves them nil — no
    /// lease, no prefetch, exactly like Pure Live's `lease == null`
    /// early-out).
    private var _refreshAt: Date?
    private(set) var refreshAt: Date? {
        get { locked { _refreshAt } }
        set { locked { _refreshAt = newValue } }
    }
    private var _invalidAt: Date?
    private(set) var invalidAt: Date? {
        get { locked { _invalidAt } }
        set { locked { _invalidAt = newValue } }
    }

    /// The held prefetched resolution: fetched at refreshAt, spent
    /// by the next recovery, never opened on its own.
    private var held: LivePlayUrlResolution?
    private var lastFreshFetchAt: Date?
    private var prefetchTimer: Timer?
    private var disposed = false
    /// Bumps on every `schedulePrefetch` (inside the lock): a
    /// main-queued timer creation whose generation is stale was
    /// superseded by a newer schedule and must not create a timer.
    private var prefetchGeneration = 0

    init(roomId: String, resolver: LiveSiteResolver?, quality: LiveQuality? = nil, now: @escaping () -> Date = { Date() }) {
        self.roomId = roomId
        self.resolver = resolver
        self.quality = quality
        self.now = now
    }

    deinit {
        // B36 item 5: the timer lives on the main run loop, so
        // it must be invalidated on the main thread. dispose()
        // (the exit path) already runs there, but deinit can
        // land on a URLSession callback thread when an
        // in-flight resolve outlives the session — invalidating
        // a main-run-loop timer from that thread is undefined
        // behaviour. Hop to main; the timer's closure holds a
        // weak self, so a fire in between is a no-op.
        let timer = locked { prefetchTimer }
        if Thread.isMainThread {
            timer?.invalidate()
        } else if let timer = timer {
            DispatchQueue.main.async { timer.invalidate() }
        }
    }

    /// (URL, format) pairs for the given lines — the pure core of
    /// `urlFacts`. Takes the lines as a parameter so locked blocks
    /// can compute from the stored `_lines` without re-entering
    /// the lock through the `urlFacts` accessor.
    private static func facts(for lines: [LiveLine]) -> [(url: URL, format: String)] {
        return lines.flatMap { line in
            line.urls.compactMap { raw -> (URL, String)? in
                guard let url = URL(string: raw) else { return nil }
                return (url, line.format)
            }
        }
    }

    /// (URL, format) pairs, one per playable URL string, in line
    /// order. B leg's `LiveLine.urls` are strings, so a string that
    /// is not a valid URL is dropped here — together with its
    /// format — which keeps `urls` and `formats` aligned.
    var urlFacts: [(url: URL, format: String)] {
        return locked { LiveRecovery.facts(for: _lines) }
    }

    /// All stream URLs, flattened from `lines` in platform order.
    var urls: [URL] {
        return urlFacts.map { $0.url }
    }

    var currentUrl: URL? {
        return locked {
            let facts = LiveRecovery.facts(for: _lines)
            guard !facts.isEmpty else {
                return nil
            }
            return facts[_currentLineIndex % facts.count].url
        }
    }

    /// The next line, wrapping around. Nil when there is only one URL.
    var nextLineUrl: URL? {
        return locked {
            let facts = LiveRecovery.facts(for: _lines)
            guard facts.count >= 2 else {
                return nil
            }
            return facts[(_currentLineIndex + 1) % facts.count].url
        }
    }

    /// Advance to the next line WITHOUT a network request. Returns
    /// the URL to open, or nil when there is no other line.
    @discardableResult
    func advanceLine() -> URL? {
        return locked {
            let facts = LiveRecovery.facts(for: _lines)
            guard facts.count >= 2 else {
                return nil
            }
            _currentLineIndex = (_currentLineIndex + 1) % facts.count
            return facts[_currentLineIndex].url
        }
    }

    /// Declared format for one flattened URL index ("other" when
    /// the platform declared nothing for that line).
    func factsFor(index: Int) -> String {
        return locked {
            let formats = LiveRecovery.facts(for: _lines).map { $0.format }
            guard index >= 0 && index < formats.count else {
                return "other"
            }
            return formats[index]
        }
    }

    /// True when a `fetchFresh` right now would be throttled.
    var isFetchFreshThrottled: Bool {
        return locked {
            guard let last = lastFreshFetchAt else {
                return false
            }
            return now().timeIntervalSince(last) < LiveRecovery.freshFetchThrottle
        }
    }

    /// Install a resolution as the current lines: replaces lines /
    /// formats / lease, matches the previously playing line by URL
    /// identity (not by index), and re-arms the hold timer at the
    /// new resolution's refreshAt.
    func adopt(resolution: LivePlayUrlResolution, previousUrl: URL?) {
        // One locked install: the resolver callback thread writes
        // while the driver reads on main. The prefetch target is
        // captured here and the timer is armed after the lock is
        // released (schedulePrefetch hops to main on its own).
        let target: Date? = locked {
            let facts = LiveRecovery.facts(for: _lines)
            let previous = previousUrl ?? (facts.isEmpty ? nil : facts[_currentLineIndex % facts.count].url)
            _lines = resolution.lines
            _qualities = resolution.qualities
            _quality = resolution.quality
            _issuedAt = resolution.issuedAt
            _refreshAt = resolution.refreshAt
            _invalidAt = resolution.invalidAt
            let freshFacts = LiveRecovery.facts(for: _lines)
            _currentLineIndex = matchLineIndex(urls: freshFacts.map { $0.url }, previousUrl: previous)
            return _refreshAt
        }
        schedulePrefetch(at: target)
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
    ///
    /// Throttle (b49 sweep #11): the 60 s stamp is taken ONLY on a
    /// successful fetch — a failed fetch, a stall recovery or a
    /// prior switch must not block the next fetch for 60 s. With
    /// `bypassThrottle` (user-initiated quality switches only) the
    /// call neither checks nor stamps the recovery throttle: a
    /// switch the user asked for is never blocked by a recovery
    /// fetch, and a successful switch never blocks a later
    /// recovery fetch.
    func fetchFresh(adopting: Bool = true, bypassThrottle: Bool = false, completion: @escaping (LivePlayUrlResolution?) -> Void) {
        let current = now()
        if !bypassThrottle {
            let throttled = locked {
                guard let last = lastFreshFetchAt else {
                    return false
                }
                return current.timeIntervalSince(last) < LiveRecovery.freshFetchThrottle
            }
            if throttled {
                completion(nil)
                return
            }
        }
        fetchFromResolver { [weak self] resolution in
            guard let self = self else {
                completion(nil)
                return
            }
            guard let resolution = resolution, !resolution.appliedUrls.isEmpty else {
                completion(nil)
                return
            }
            if !bypassThrottle {
                self.locked { self.lastFreshFetchAt = current }
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
        guard !isDisposed, !isExpired else {
            return
        }
        fetchFromResolver { [weak self] resolution in
            guard let self = self else {
                return
            }
            guard !self.isDisposed else {
                return
            }
            guard let resolution = resolution, !resolution.appliedUrls.isEmpty else {
                self.schedulePrefetch(at: self.now().addingTimeInterval(LiveRecovery.refreshRetry))
                return
            }
            let next = self.locked {
                self.held = resolution
                return resolution.refreshAt ?? resolution.issuedAt.addingTimeInterval(LiveRecovery.prefetchAfterIssue)
            }
            self.schedulePrefetch(at: next ?? self.now().addingTimeInterval(LiveRecovery.refreshRetry))
        }
    }

    /// The held plan when it is usable (the state lock is already
    /// held by the caller — never call the locked `peekHeld`
    /// from inside a locked block).
    private func heldIfUsable() -> LivePlayUrlResolution? {
        guard let held = held, !held.appliedUrls.isEmpty else {
            return nil
        }
        if let invalid = held.invalidAt, invalid <= now() {
            return nil
        }
        return held
    }

    /// Take the held prefetched resolution for recovery (first
    /// refresh attempt): one-shot — clears the hold — and only when
    /// its hard expiry is still in the future. Installing it
    /// replaces the current lines/facts/lease exactly like
    /// `fetchFresh` does, and re-arms the hold timer at the new
    /// resolution's refreshAt. Costs no request and no throttle
    /// stamp: the hold was fetched earlier, taking it is free.
    func takeHeld() -> LivePlayUrlResolution? {
        // Peek + clear + adopt in one locked step, so a concurrent
        // prefetch cannot replace the hold between the peek and
        // the adopt; the adopt itself runs after the lock is out.
        let heldPlan: LivePlayUrlResolution? = locked {
            guard let held = heldIfUsable() else {
                return nil
            }
            self.held = nil
            return held
        }
        guard let heldPlan = heldPlan else {
            return nil
        }
        let previousUrl = currentUrl
        adopt(resolution: heldPlan, previousUrl: previousUrl)
        return heldPlan
    }

    /// Look at the held plan WITHOUT spending it. Nil when nothing
    /// usable is held (nothing held, empty, or past hard expiry).
    func peekHeld() -> LivePlayUrlResolution? {
        return locked { heldIfUsable() }
    }

    /// Drop the held plan (a NEW resolution was adopted — initial
    /// resolve or quality switch — and a hold fetched for the old
    /// quality must never be served for the new one).
    func discardHeld() {
        locked { held = nil }
    }

    /// Locked read of `disposed` for the prefetch guards (the
    /// stored flag itself is only ever touched inside `locked`
    /// blocks).
    private var isDisposed: Bool {
        return locked { disposed }
    }

    /// Arm the lease prefetch (Pure Live `_schedulePrefetch`): at
    /// `target` — default the CURRENT resolution's refreshAt —
    /// fetch a fresh resolution and HOLD it. No lease deadline
    /// (`refreshAt` nil, e.g. Douyin) means no prefetch at all. A
    /// deadline already past fires in 1 s instead of never firing.
    func schedulePrefetch(at target: Date? = nil) {
        // The delay is computed under the lock (disposed + the
        // current refreshAt), but the Timer itself is created on
        // the main queue: Timer.scheduledTimer on a URLSession
        // background thread (where adopt/prefetch run) schedules
        // onto a runloop that never runs, so the prefetch never
        // fired. The generation drops a creation already queued
        // when a newer schedule (or dispose) superseded it.
        let (delay, generation): (TimeInterval?, Int) = locked {
            // Always drop the previous timer first (old behaviour):
            // a new resolution without a lease must not leave the
            // previous resolution's prefetch armed.
            prefetchTimer?.invalidate()
            prefetchTimer = nil
            guard !disposed else {
                return (nil, prefetchGeneration)
            }
            prefetchGeneration += 1
            return (prefetchDelay(at: target ?? _refreshAt, from: now()), prefetchGeneration)
        }
        guard let delay = delay else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.locked {
                guard !self.disposed, generation == self.prefetchGeneration else { return }
                self.prefetchTimer?.invalidate()
                self.prefetchTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    self?.performPrefetch()
                }
            }
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
        return locked {
            if let invalid = _invalidAt {
                return now() > invalid
            }
            guard let issued = _issuedAt else {
                return false
            }
            return now() > issued.addingTimeInterval(LiveRecovery.hardExpiryAfterIssue)
        }
    }

    func dispose() {
        locked {
            disposed = true
            prefetchTimer?.invalidate()
            prefetchTimer = nil
        }
    }

    // MARK: - Private

    /// The single resolver call site. Passes the session's current
    /// quality (nil = default/best) and maps a resolver failure to
    /// nil — the caller falls through to the next line or the
    /// failure card, never a retry of the same call. 10 s timeout:
    /// a timeout is a stream error, exactly like a failed parse.
    private func fetchFromResolver(completion: @escaping (LivePlayUrlResolution?) -> Void) {
        guard let resolver = resolver else {
            lastResolveWasOffline = false
            completion(nil)
            return
        }
        // `finish` is reached from two threads — the resolver
        // callback (URLSession background) and the timeout work
        // item (main) — so exactly-once needs a lock, not a bare
        // Bool. The lock guards only the flag; the completion
        // itself runs outside it. `finish` also records whether
        // this fetch failed with a definitive offline (b39): the
        // flag is set by the winning finish only, before the
        // completion runs, so the driver can read it when the
        // resolve returns nothing.
        let finishLock = NSLock()
        var completed = false
        var timeoutWork: DispatchWorkItem?
        let finish: (LivePlayUrlResolution?, Bool) -> Void = { [weak self] result, wasOffline in
            let shouldRun: Bool = {
                finishLock.lock()
                defer { finishLock.unlock() }
                guard !completed else { return false }
                completed = true
                return true
            }()
            guard shouldRun else {
                return
            }
            self?.lastResolveWasOffline = wasOffline
            timeoutWork?.cancel()
            completion(result)
        }
        timeoutWork = DispatchWorkItem {
            finish(nil, false)
        }
        if let work = timeoutWork {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutInterval, execute: work)
        }
        // The quality in force for this fetch, read once: the
        // fallback below must ask for the same tier the network
        // resolve was asked for.
        let requestedQuality = quality
        resolver.resolve(roomId: roomId, quality: requestedQuality) { [weak self] result in
            switch result {
            case .success(let resolution):
                finish(resolution, false)
            case .failure(let error):
                // A definitive offline stays a failure: stale list
                // URLs must never resurrect an ended room. Any
                // other failure (rate-limit, network, parse) falls
                // back to stream URLs the app already holds from
                // the list feed, when the resolver offers them —
                // the first playable source plays instead of the
                // failure card.
                if let liveError = error as? LiveError, case .offline = liveError {
                    finish(nil, true)
                    return
                }
                if let self = self,
                   let room = self.sourceRoom,
                   let fallback = resolver.resolutionFromRoom(room, quality: requestedQuality),
                   !fallback.appliedUrls.isEmpty {
                    finish(fallback, false)
                    return
                }
                finish(nil, false)
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

    /// Serialises every read/write of the session state below.
    /// The initial resolve / quality switch complete on URLSession
    /// background threads while the driver reads the same state on
    /// main — unguarded that is a data race on the stored values.
    /// The lock is only ever held for the state touch, never
    /// across a network call or a completion; a locked block never
    /// calls another locked accessor of THIS class (backing vars
    /// are used inside). Lock order, where a block also touches
    /// the recovery: session lock first, recovery lock second.
    private let stateLock = NSLock()
    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private var _state: State = .idle
    private(set) var state: State {
        get { locked { _state } }
        set { locked { _state = newValue } }
    }
    private var _room: LiveRoom?
    private(set) var room: LiveRoom? {
        get { locked { _room } }
        set { locked { _room = newValue } }
    }
    private var _currentQuality: LiveQuality?
    private(set) var currentQuality: LiveQuality? {
        get { locked { _currentQuality } }
        set { locked { _currentQuality = newValue } }
    }
    private var _consecutiveFailures: Int = 0
    private(set) var consecutiveFailures: Int {
        get { locked { _consecutiveFailures } }
        set { locked { _consecutiveFailures = newValue } }
    }
    private var _isBackgroundAudioOnly: Bool = false
    private(set) var isBackgroundAudioOnly: Bool {
        get { locked { _isBackgroundAudioOnly } }
        set { locked { _isBackgroundAudioOnly = newValue } }
    }
    private var _stallWarning: Bool = false
    private(set) var stallWarning: Bool {
        get { locked { _stallWarning } }
        set { locked { _stallWarning = newValue } }
    }

    private var _recovery: LiveRecovery?
    private(set) var recovery: LiveRecovery? {
        get { locked { _recovery } }
        set { locked { _recovery = newValue } }
    }
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
        locked {
            _room = room
            self.resolver = resolver
            _consecutiveFailures = 0
            _isBackgroundAudioOnly = false
            _stallWarning = false
            _currentQuality = nil
            pendingQuality = nil
            previousQuality = nil
            let recovery = LiveRecovery(roomId: room.roomId, resolver: resolver, quality: nil, now: now)
            recovery.sourceRoom = room
            _recovery = recovery
            _state = .loading
        }
        stallWatchdog.reset()
    }

    /// Whether the room's last resolve failed because the room is
    /// not live (forwards to the recovery's flag; false when there
    /// is no recovery yet). The driver reads this when the initial
    /// resolve returns nothing, to show "房间未开播" instead of
    /// "没有可播放的地址" (b39).
    var lastResolveWasOffline: Bool {
        recovery?.lastResolveWasOffline ?? false
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
        locked {
            _consecutiveFailures = 0
            _stallWarning = false
            _state = .playing
        }
    }

    func notePlaybackPaused() {
        locked {
            if _state == .playing {
                _state = .paused
            }
        }
    }

    func noteResumed() {
        locked {
            if _state == .paused {
                _state = .playing
            }
        }
    }

    /// One watchdog tick (the driver ticks every 0.5 s with the
    /// backend position). Warn sets the "重新连接" flag; failed is
    /// the caller's cue to run `noteFailure`.
    func tickWatchdog(position: Double, isPlaying: Bool) -> LiveStallWatchdog.Event {
        let event = stallWatchdog.tick(position: position, isPlaying: isPlaying)
        switch event {
        case .warn:
            locked { _stallWarning = true }
        case .failed:
            locked { _stallWarning = false }
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
        let lineCount = recovery?.urls.count ?? 0
        let exceeded = locked {
            _consecutiveFailures += 1
            return _consecutiveFailures > LiveRoomSession.autoRecoveryBudget(lineCount: lineCount)
        }
        if exceeded {
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
        locked {
            previousQuality = _currentQuality
            pendingQuality = quality
        }
        recovery.quality = quality
        // User-initiated switch: exempt from the recovery throttle
        // (b49 sweep #11) — a stall recovery must never block the
        // user's own switch for 60 s, and this switch must not
        // stamp the throttle a later recovery would hit.
        recovery.fetchFresh(adopting: false, bypassThrottle: true) { [weak self] resolution in
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
            self.locked {
                self._currentQuality = quality
                self.pendingQuality = nil
                self.previousQuality = nil
            }
            completion(true)
        }
    }

    private func rollbackQuality() {
        locked {
            _recovery?.quality = previousQuality
            pendingQuality = nil
            previousQuality = nil
        }
    }

    // MARK: - Background audio (live only)

    /// App backgrounded. Only when the room is actually trying to
    /// play (playing / buffering / opening); a user-paused room
    /// stays paused, and an error room has nothing to keep alive.
    /// Returns true when the driver should drop to audio-only.
    func enterBackground() -> Bool {
        return locked {
            switch _state {
            case .playing, .buffering, .loading:
                _isBackgroundAudioOnly = true
                return true
            case .idle, .paused, .reconnecting, .failed, .exited:
                return false
            }
        }
    }

    /// App foregrounded. Returns true when audio-only was active
    /// and the driver should restore the video track (and resume if
    /// the engine paused natively anyway).
    func enterForeground() -> Bool {
        return locked {
            guard _isBackgroundAudioOnly else {
                return false
            }
            _isBackgroundAudioOnly = false
            return true
        }
    }

    // MARK: - Exit

    /// Leave the room. Cancels the prefetch timer, drops the
    /// recovery and the room, and goes to `.exited`. Deliberately
    /// does NOT resume music: exiting a room never auto-resumes
    /// music (music has its own background logic).
    func exit() {
        locked {
            _recovery?.dispose()
            _recovery = nil
            _room = nil
            resolver = nil
            _currentQuality = nil
            pendingQuality = nil
            previousQuality = nil
            _consecutiveFailures = 0
            _isBackgroundAudioOnly = false
            _stallWarning = false
            _state = .exited
        }
    }
}

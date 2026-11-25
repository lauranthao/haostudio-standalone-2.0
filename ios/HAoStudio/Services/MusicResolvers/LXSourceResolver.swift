// LXSourceResolver.swift
// Serial fastest-first source resolution (implements the
// `SourceResolver` protocol from `PlaybackCoordinator.swift`).
//
// Flutter parity (`music_resolvers.dart`, 1.1.6+32):
// - Jobs are asked ONE AT A TIME, in measured-speed order; the FIRST
//   playable URL plays immediately — never ask all sources, never
//   wait for a higher tier once a playable URL exists (chen
//   2026-11-17 铁律). A below-target URL plays now as a per-song
//   downgrade (the target tier persists to the next track), labelled
//   with its REAL tier.
// - 8 built-in resolvers (`huibq` disabled — its service returns
//   503 "Service Suspended" since 2026-11-16; `oiapi_kw` deleted
//   2026-11-24 — its oiapi.net Kuwo endpoint answers code -2
//   "歌曲搜索失败" while the same host's NetEase leg still works,
//   so the endpoint is dead, not the host; Kuwo is still served by
//   xinghai / zddyr_kw / wwwweb + the LX scripts; `tang` deleted
//   2026-11-24 — tang.api.s01s.cn never answers (connection
//   timeout, 0 bytes, 4 consecutive failures across 2 probe rounds
//   and 2 HTTP clients while 7 sibling resolvers answer through the
//   same egress; build-35真播放重验); `lzm` deleted 2026-11-24
//   (item 7) — its endpoint now answers 401
//   {"code":-1,"error":"NEED_PASS"} (2 probes), replaced by
//   `meting` (Meting API, wy) and `vkeys_tx` (落月 v3 song/link,
//   tx — the first built-in QQ resolver; the v2 geturl leg 503s
//   "系统运行错误！"). Both replacements verified with real audio
//   bytes 2026-11-24 (see item7-sources-report.md). QQ/TX playback
//   still has LX script cover too (stellarwave verified PLAYABLE
//   2026-11-24 — the only QQ success in the item-7 probe)) + LX
//   script jobs. b47-qq (2026-11-25): QQ still unplayable on device
//   — vkeys hiRes leg 110001s on songs with no hiRes file, and the
//   LX script QQ chains all time out at the 3 s job cap, starving
//   the 8 s resolve budget before vkeys is ever asked; vkeys_tx now
//   falls back through lower tiers inside the job and ranks first
//   (order 1) among tx jobs.
// - Per-job 3 s timeout, whole resolve 8 s (P0-16: first tier pass
//   capped at 5 s, 3 s reserved for lower tiers, later passes at
//   most 2 s each — see `ResolverBudget`).
// - 3 consecutive failures cool a job for 5 min; a single timeout
//   cools it immediately for 2 min; an empty answer is not a
//   failure. Speed EMA + cooldown persist under `hao_resolver_speed`.
// - Play-URL cache: 1 h TTL, 200-entry cap, key
//   `songId|platform|quality`; an URL that fails at playback is
//   evicted explicitly.
// - Master honesty gate: only `zddyr` / `xinghai` (LX APIs with a
//   verified real Master path) may claim Master, and only when the
//   response reports `quality == 'master'` with no
//   `quality_fallback`; LX scripts keep Master only when they return
//   a `{url, quality: 'master'}` map; every other resolver caps at
//   hires (see `MusicQualityGate`).
// - 30 s preview (build 36 item 3): a trial/preview URL is NEVER a
//   successful resolve. Resolver JSON is checked for trial flags
//   (`freeTrialInfo` et al) and every returned URL passes
//   `PreviewAudioClassifier.isPreviewURL` (QQ `RS0` trial files,
//   NetEase outer URL on trial-only tracks); a preview falls
//   through to the next source exactly like an empty answer, the
//   job is skipped at the lower tiers of the same resolve, and it
//   is never cached. A fallback re-resolve can also pass
//   `excluding` URLs (failed at playback, or proved to be previews
//   by asset duration) that no job may return again.
// - Kugou signing: the Kugou signature secret was removed from
//   source (P0-15); there is no `kugouSign` here and no hardcoded
//   secret anywhere. Kugou shared-playlist import (the only place
//   that needed the signature) fails explicitly instead — see
//   `MusicPlaylistImportAPI`.
//
// `PlaybackItem.id` is parsed as `platform|songId` (the Flutter
// `identityKey` convention); an id without a platform separator
// resolves to nil. `lastResolvedTier` is the tier actually played
// (the player leg reads it for the quality badge); it is set on the
// main queue just before `completion` fires.

import Foundation

/// What one resolver job returned.
enum LXResolverOutcome {
    /// A URL, plus the tier the job actually served (nil = the
    /// declared label applies — see `MusicQualityGate.declaredTier`).
    case url(String, AudioQuality?)
    /// No stock at this tier (not a failure — the job may serve a
    /// lower tier).
    case empty
    /// The job errored (network / bad response / unplayable URL).
    case error
}

/// One candidate source for one resolve.
struct LXResolverJob {
    let key: String
    let name: String
    let order: Int
    let platforms: [MusicPlatform]
    /// Prerequisite that waits OUTSIDE the per-job timeout (xinghai's
    /// token fetch). Calls back when the prerequisite is ready — or
    /// when it failed fast; the job's own function re-checks.
    let warmup: ((@escaping () -> Void) -> Void)?
    let run: (LXCancelToken, @escaping (LXResolverOutcome) -> Void) -> Void
}

/// One resolved play URL: the URL, the tier actually played, and the
/// job that served it (for settings/debugging).
struct PlayUrlResult {
    let url: String
    let quality: AudioQuality
    let via: String
}

final class LXSourceResolver: SourceResolver {
    /// User agent for the resolver's direct API calls (shared with
    /// the music API modules — see `MusicUA`).
    static let musicUserAgent = MusicUA.value

    private let engine: LXEngine
    private let httpClient: MusicHTTPClient
    private let cooldown: ResolverCooldown
    /// Retained for source compatibility only. Play URLs are
    /// NEVER cached (plan §7.4: signatures are short-lived —
    /// every playback re-resolves). Nothing reads or writes this
    /// cache any more; `evictPlayUrl` is a no-op for the same
    /// reason (the `excluding` set already drops failed URLs).
    private let cache: PlayURLCache
    /// 10-minute per-source+song failure memory (plan §7.4): a
    /// source that just failed for a song is not re-asked for
    /// that song until the memory expires. Never deletes a source.
    private let failureMemory: ResolveFailureMemory
    private let scriptStore: LXScriptStore
    private let documentsDirectory: URL
    private let workQueue = DispatchQueue(label: "com.haostudio.lxresolver")

    /// Budget overrides (production defaults are `ResolverBudget`).
    /// Tests inject short budgets so a timeout test never waits real
    /// seconds.
    private let perJobTimeout: TimeInterval
    private let totalBudget: TimeInterval
    private let firstPassCap: TimeInterval
    private let laterPassCap: TimeInterval
    /// Test seam: when set, the job list comes from this provider
    /// instead of the built-in resolvers + LX scripts, so tests can
    /// run fake jobs without network. Production passes nil.
    private let jobListProvider: ((MusicPlatform, AudioQuality, String, String, String) -> [LXResolverJob])?

    /// The tier actually played by the last successful resolve (the
    /// player leg reads it for the quality badge). Set on the main
    /// queue just before `completion` fires; nil when the last
    /// resolve found nothing.
    private(set) var lastResolvedTier: AudioQuality?

    /// True when the most recent resolve that returned nil ran out
    /// of budget with jobs still untried, so "no source" would be a
    /// lie. False when every available job was tried and answered
    /// empty, when a URL was found, or when the song had no id.
    private(set) var lastResolveTruncated = false

    // Xinghai token state (4-min cache, single-flight).
    private var xhToken: String?
    private var xhTokenAt: Date?
    private var xhTokenInFlight = false
    private var xhTokenWaiters: [(String) -> Void] = []

    init(
        engine: LXEngine = .shared,
        httpClient: MusicHTTPClient = URLSessionMusicHTTPClient(),
        cooldown: ResolverCooldown? = nil,
        cache: PlayURLCache? = nil,
        failureMemory: ResolveFailureMemory? = nil,
        scriptStore: LXScriptStore = LXScriptStore(),
        documentsDirectory: URL? = nil,
        perJobTimeout: TimeInterval = ResolverBudget.perJob,
        totalBudget: TimeInterval = ResolverBudget.total,
        firstPassCap: TimeInterval = ResolverBudget.firstPassCap,
        laterPassCap: TimeInterval = ResolverBudget.laterPassCap,
        jobListProvider: ((MusicPlatform, AudioQuality, String, String, String) -> [LXResolverJob])? = nil
    ) {
        self.engine = engine
        self.httpClient = httpClient
        self.documentsDirectory = documentsDirectory ?? LocalStore.documentsDirectory()
        self.cooldown = cooldown ?? ResolverCooldown(documentsDirectory: self.documentsDirectory)
        self.cache = cache ?? PlayURLCache()
        self.failureMemory = failureMemory ?? ResolveFailureMemory()
        self.scriptStore = scriptStore
        self.perJobTimeout = perJobTimeout
        self.totalBudget = totalBudget
        self.firstPassCap = firstPassCap
        self.laterPassCap = laterPassCap
        self.jobListProvider = jobListProvider
    }

    // MARK: - SourceResolver protocol

    func resolveFirstPlayable(
        for item: PlaybackItem,
        targetQuality: AudioQuality?,
        excluding: [URL] = [],
        completion: @escaping (URL?) -> Void
    ) {
        // A fresh resolve starts with no tier; finishResolve sets it
        // just before completion fires, so the wiring never reads a
        // stale tier from the previous track.
        lastResolvedTier = nil
        // `PlaybackItem.id` is `platform|songId` (Flutter identityKey).
        let parts = item.id.split(separator: "|", maxSplits: 1)
        guard parts.count == 2,
              let platform = MusicPlatform(code: String(parts[0]))
        else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        resolve(
            songId: String(parts[1]),
            platform: platform,
            title: item.title,
            artist: item.artist ?? "",
            quality: targetQuality ?? .hiRes,
            trialOnly: item.trialOnly,
            excluding: excluding
        ) { result in
            completion(result.flatMap { URL(string: $0.url) })
        }
    }

    /// Typed convenience for the music UI leg.
    func resolve(
        track: MusicTrack,
        targetQuality: AudioQuality?,
        completion: @escaping (URL?) -> Void
    ) {
        guard let platform = track.platform else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        resolve(
            songId: track.id,
            platform: platform,
            title: track.title,
            artist: track.artist,
            quality: targetQuality ?? .hiRes,
            trialOnly: track.trialOnly
        ) { result in
            completion(result.flatMap { URL(string: $0.url) })
        }
    }

    /// Drop a cached play URL (e.g. it failed at playback): the next
    /// resolve for this song re-asks the sources.
    /// b45-F: play URLs are never cached any more (plan §7.4), so
    /// there is nothing to evict — the `excluding` set on the
    /// resolve call already drops the failed URL. Kept because the
    /// `PlayURLEvictingResolver` protocol requires it.
    func evictPlayUrl(songId: String, platform: MusicPlatform, quality: AudioQuality) {
        // No-op by design: no play-URL cache exists.
    }

    /// b46: manual-play bypass — forget every failure recorded
    /// for one song, so the next resolve re-asks every source.
    /// b49fix22 D24-3: the whole body runs on the resolver's
    /// serial work queue, not the caller's thread. The caller
    /// (PlaybackCoordinator.clearResolveFailureMemory) runs on
    /// the main thread, and the old direct call mutated
    /// ResolverCooldown's dicts (cooledUntil/fails, then the
    /// saveLocked backfill) on main while a resolve callback on
    /// the work queue could concurrently run record() on the
    /// same plain Swift dictionaries — a write/write race the
    /// fix21 backfill made real (before it, saveLocked only
    /// read them). Enqueuing here is safe and order-preserving:
    /// resolve() itself enqueues on the same queue, and a
    /// manual play always resolves after clearing, so the
    /// clear runs first. Never sync here — a work-queue caller
    /// would deadlock on itself.
    func clearFailureMemory(forSongId songId: String) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            // b49sweep P1-5: a manual "re-ask every source" was only
            // half-kept — the failure memory cleared, but the cooldown
            // (5 min after 3 hard errors, persisted to disk) kept the
            // sources deprioritised. Clear both for the same keys.
            let keys = self.failureMemory.sourceKeys(forSongId: songId)
            self.failureMemory.clear(songId: songId)
            self.cooldown.clear(keys: keys)
        }
    }

    /// A completed download for this song, resolved to its file,
    /// or nil. The record's qualityCode is the tier actually
    /// downloaded (b49fix2 P1-1).
    private func localDownloadURL(identityKey: String) -> (url: URL, quality: AudioQuality)? {
        guard let info = DownloadEngine.shared.taskInfo(for: identityKey),
              info.state == .completed,
              let relative = info.localRelativePath,
              let url = LocalFileIndex.resolve(relative, subdir: DownloadEngine.downloadSubdir)
        else { return nil }
        let quality = AudioQuality(lxCode: info.request.qualityCode) ?? .standard128
        return (url, quality)
    }

    // MARK: - Main entry

    /// Per-resolve mutable state, owned by the work queue.
    private final class ResolveState {
        let tiers: [AudioQuality]
        let requestedQuality: AudioQuality
        var tierIndex = 0
        var passIndex = 0
        var truncated = false
        let skipTimedOut = NSMutableSet()
        /// Jobs that answered this song with a 30 s preview (build
        /// 36 item 3): a trial at one tier is a trial at every tier,
        /// so later tier passes in this resolve skip them instead of
        /// burning budget re-asking for the same clip.
        let skipPreviewed = NSMutableSet()
        /// Search-time VIP-only flag for this track (drives the
        /// preview-URL check: a NetEase outer URL is only a trial
        /// when the track is paywalled).
        let trialOnly: Bool
        /// URLs already failed — or proved to be previews — for this
        /// request (player fallback `excluding`): never served again
        /// in this resolve, from cache or from any job.
        let excluding: Set<String>
        let totalDeadline: Date
        let background: Bool
        /// When this resolve started: the failure memory only
        /// skips sources that failed BEFORE this resolve — a
        /// source that fails mid-resolve is still tried at the
        /// lower tiers of the same resolve.
        let startedAt: Date

        init(tiers: [AudioQuality], requestedQuality: AudioQuality, totalDeadline: Date, background: Bool,
             trialOnly: Bool = false, excluding: Set<String> = []) {
            self.tiers = tiers
            self.requestedQuality = requestedQuality
            self.totalDeadline = totalDeadline
            self.background = background
            self.trialOnly = trialOnly
            self.excluding = excluding
            self.startedAt = Date()
        }
    }

    func resolve(
        songId: String,
        platform: MusicPlatform,
        title: String,
        artist: String,
        quality: AudioQuality,
        background: Bool = false,
        trialOnly: Bool = false,
        excluding: [URL] = [],
        completion: @escaping (PlayUrlResult?) -> Void
    ) {
        workQueue.async {
            guard !songId.isEmpty else {
                self.finishResolve(result: nil, truncated: false, completion: completion)
                return
            }
            // b49fix2 P1-1: a downloaded song never needs the
            // network — serve its file straight away, at the
            // quality it was downloaded at. (The coordinator's
            // resolve closure already returns item.localFileURL
            // first; this is the safety net for items built
            // without a local path, e.g. a queue restored at
            // launch.) DownloadEngine + LocalFileIndex are
            // AppCore, so this lookup is safe on the work queue.
            if let local = self.localDownloadURL(identityKey: "\(platform.rawValue)|\(songId)") {
                self.finishResolve(
                    result: PlayUrlResult(url: local.url.absoluteString, quality: local.quality, via: "download"),
                    truncated: false, completion: completion)
                return
            }
            let excludedURLs = Set(excluding.map { $0.absoluteString })
            // b45-F (plan §7.4): play URLs are NEVER cached —
            // signatures are short-lived, so every playback
            // re-resolves. (The old 1 h PlayURLCache read lived
            // here; it is gone, and the put in runTierPasses too.)
            // LX script jobs appear once the engine has loaded; kick
            // off the load on first use (the first resolve after
            // launch may predate them — later resolves include them).
            // b49fix2 P1-5: the old fire-and-forget above meant the
            // first resolve after launch ran its tier passes before
            // any script was loaded — musicUrlSources only returns
            // loaded scripts, so a script-only song failed on the
            // first tap and worked on the second. Wait for the
            // engine here, bounded to ~2 s: an already-initialized
            // engine answers immediately (its completion is a
            // main-queue hop, and this runs on the resolver work
            // queue, so the wait cannot deadlock); a slow first
            // load still proceeds after the bound instead of
            // hanging the resolve.
            let initSemaphore = DispatchSemaphore(value: 0)
            self.engine.ensureInitialized { _ in initSemaphore.signal() }
            _ = initSemaphore.wait(timeout: .now() + 2)
            // Warm the xinghai token in parallel: its first fetch can
            // take seconds, and the sequential pass must not stall on it.
            if self.applicableResolvers(platform).contains(where: { $0.key == "xinghai" }) {
                self.getXhToken(cancelToken: nil) { _ in }
            }
            let state = ResolveState(
                tiers: AudioQuality.chain(from: quality),
                requestedQuality: quality,
                totalDeadline: Date().addingTimeInterval(self.totalBudget),
                background: background,
                trialOnly: trialOnly,
                excluding: excludedURLs)
            self.runTierPasses(
                state: state, songId: songId, platform: platform,
                title: title, artist: artist, completion: completion)
        }
    }

    private func finishResolve(
        result: PlayUrlResult?,
        truncated: Bool,
        completion: @escaping (PlayUrlResult?) -> Void
    ) {
        lastResolveTruncated = truncated
        cooldown.saveNow()
        let tier = result?.quality
        DispatchQueue.main.async {
            self.lastResolvedTier = tier
            completion(result)
        }
    }

    /// Walk the quality chain, fastest-first per tier. A whole
    /// resolve is bounded by one global deadline. The FIRST playable
    /// URL wins, at any tier — a below-target URL plays now as a
    /// per-song downgrade; the chain only advances when NO source
    /// returns anything at this tier.
    private func runTierPasses(
        state: ResolveState,
        songId: String,
        platform: MusicPlatform,
        title: String,
        artist: String,
        completion: @escaping (PlayUrlResult?) -> Void
    ) {
        guard state.tierIndex < state.tiers.count else {
            finishResolve(result: nil, truncated: state.truncated, completion: completion)
            return
        }
        let remaining = state.totalDeadline.timeIntervalSince(Date())
        guard remaining > 0 else {
            finishResolve(result: nil, truncated: state.truncated, completion: completion)
            return
        }
        let tier = state.tiers[state.tierIndex]
        state.tierIndex += 1
        // P0-16: first tier pass capped at `firstPassCap`, later passes
        // at `laterPassCap`, so the first tier can never eat the whole
        // budget. Production: 5 s / 2 s of the 8 s total.
        let cap = state.passIndex == 0 ? firstPassCap : laterPassCap
        let budget = min(cap, remaining)
        state.passIndex += 1
        runPass(
            tier: tier, songId: songId, platform: platform, title: title, artist: artist,
            budget: budget, skipTimedOut: state.skipTimedOut, skipPreviewed: state.skipPreviewed,
            trialOnly: state.trialOnly, excluding: state.excluding, background: state.background,
            failuresBefore: state.startedAt
        ) { [weak self] passResult, incomplete in
            guard let self = self else { return }
            state.truncated = state.truncated || incomplete
            if let result = passResult {
                // b45-F: the result is NOT cached (plan §7.4).
                self.finishResolve(result: result, truncated: false, completion: completion)
                return
            }
            self.workQueue.async {
                self.runTierPasses(
                    state: state, songId: songId, platform: platform,
                    title: title, artist: artist, completion: completion)
            }
        }
    }
}

// MARK: - One pass at a single quality

extension LXSourceResolver {
    /// One pass at a single quality: try jobs in measured-speed
    /// order, one at a time, until a playable URL is found. Returns
    /// `(nil, true)` when the budget died with jobs still untried;
    /// `(nil, false)` when every available job was tried. Jobs that
    /// time out are added to `skipTimedOut` so later tiers in the
    /// same resolve don't waste budget re-asking a source that
    /// doesn't answer; jobs that answered with a 30 s preview are
    /// added to `skipPreviewed` for the same reason (a trial at one
    /// tier is a trial at every tier); a definitive empty answer is
    /// retried at lower tiers, which may serve the song.
    private func runPass(
        tier: AudioQuality,
        songId: String,
        platform: MusicPlatform,
        title: String,
        artist: String,
        budget: TimeInterval,
        skipTimedOut: NSMutableSet,
        skipPreviewed: NSMutableSet,
        trialOnly: Bool,
        excluding: Set<String>,
        background: Bool,
        failuresBefore: Date,
        completion: @escaping (PlayUrlResult?, Bool) -> Void
    ) {
        let jobs = rankedJobs(platform: platform, tier: tier, songId: songId, title: title, artist: artist, failuresBefore: failuresBefore)
        guard !jobs.isEmpty else {
            completion(nil, false)
            return
        }
        let deadline = Date().addingTimeInterval(budget)
        runJobAt(
            jobs: jobs, index: 0, tier: tier, songId: songId, platform: platform,
            title: title, artist: artist, deadline: deadline,
            skipTimedOut: skipTimedOut, skipPreviewed: skipPreviewed,
            trialOnly: trialOnly, excluding: excluding,
            background: background, completion: completion)
    }

    private func runJobAt(
        jobs: [LXResolverJob],
        index: Int,
        tier: AudioQuality,
        songId: String,
        platform: MusicPlatform,
        title: String,
        artist: String,
        deadline: Date,
        skipTimedOut: NSMutableSet,
        skipPreviewed: NSMutableSet,
        trialOnly: Bool,
        excluding: Set<String>,
        background: Bool,
        completion: @escaping (PlayUrlResult?, Bool) -> Void
    ) {
        guard index < jobs.count else {
            completion(nil, false)
            return
        }
        let job = jobs[index]
        // Jobs still untried from `index` on (skipped-by-timeout and
        // previewed jobs do not count: they were attempted).
        func untriedFrom(_ i: Int) -> Bool {
            jobs[i...].contains { !skipTimedOut.contains($0.key) && !skipPreviewed.contains($0.key) }
        }
        if skipTimedOut.contains(job.key) || skipPreviewed.contains(job.key) {
            runJobAt(jobs: jobs, index: index + 1, tier: tier, songId: songId,
                     platform: platform, title: title, artist: artist,
                     deadline: deadline, skipTimedOut: skipTimedOut,
                     skipPreviewed: skipPreviewed, trialOnly: trialOnly,
                     excluding: excluding,
                     background: background, completion: completion)
            return
        }
        // A job prerequisite (xinghai's token) waits OUTSIDE the
        // per-job timeout — the clock starts only once the token is
        // in hand. Bounded by the pass budget.
        if let warmup = job.warmup {
            let warmRemaining = deadline.timeIntervalSince(Date())
            guard warmRemaining > 0 else {
                completion(nil, untriedFrom(index))
                return
            }
            var warmed = false
            let warmTimeout = DispatchWorkItem { [weak self] in
                guard let self = self, !warmed else { return }
                warmed = true
                // Budget died waiting for the prerequisite: the source
                // itself was never asked — not a job timeout, so no
                // cooldown and no skipTimedOut.
                self.workQueue.async {
                    self.runJobAt(jobs: jobs, index: index + 1, tier: tier, songId: songId,
                                  platform: platform, title: title, artist: artist,
                                  deadline: deadline, skipTimedOut: skipTimedOut,
                                  skipPreviewed: skipPreviewed, trialOnly: trialOnly,
                                  excluding: excluding,
                                  background: background, completion: completion)
                }
            }
            workQueue.asyncAfter(deadline: .now() + warmRemaining, execute: warmTimeout)
            warmup {
                guard !warmed else { return }
                warmed = true
                warmTimeout.cancel()
                self.workQueue.async {
                    self.runJobWithTimeout(
                        job: job, jobs: jobs, index: index, tier: tier, songId: songId,
                        platform: platform, title: title, artist: artist,
                        deadline: deadline, skipTimedOut: skipTimedOut,
                        skipPreviewed: skipPreviewed, trialOnly: trialOnly,
                        excluding: excluding,
                        background: background, completion: completion)
                }
            }
            return
        }
        runJobWithTimeout(
            job: job, jobs: jobs, index: index, tier: tier, songId: songId,
            platform: platform, title: title, artist: artist,
            deadline: deadline, skipTimedOut: skipTimedOut,
            skipPreviewed: skipPreviewed, trialOnly: trialOnly,
            excluding: excluding,
            background: background, completion: completion)
    }

    private func runJobWithTimeout(
        job: LXResolverJob,
        jobs: [LXResolverJob],
        index: Int,
        tier: AudioQuality,
        songId: String,
        platform: MusicPlatform,
        title: String,
        artist: String,
        deadline: Date,
        skipTimedOut: NSMutableSet,
        skipPreviewed: NSMutableSet,
        trialOnly: Bool,
        excluding: Set<String>,
        background: Bool,
        completion: @escaping (PlayUrlResult?, Bool) -> Void
    ) {
        let remaining = deadline.timeIntervalSince(Date())
        guard remaining > 0 else {
            let untried = jobs[index...].contains { !skipTimedOut.contains($0.key) && !skipPreviewed.contains($0.key) }
            completion(nil, untried)
            return
        }
        let timeout = min(perJobTimeout, remaining)
        let token = LXCancelToken()
        let started = Date()
        var finished = false
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self, !finished else { return }
            finished = true
            token.cancel()
            if !background {
                // b46: a timeout is "slow", not "dead" — it only
                // cools the source down (deprioritised). It must
                // NOT enter the 10-minute failure memory, or one
                // slow attempt makes the song unplayable for
                // 10 minutes even when the user taps it again.
                self.cooldown.record(job.key, outcome: .timeout,
                                     milliseconds: Int(timeout * 1000))
            }
            skipTimedOut.add(job.key)
            self.workQueue.async {
                self.runJobAt(jobs: jobs, index: index + 1, tier: tier, songId: songId,
                              platform: platform, title: title, artist: artist,
                              deadline: deadline, skipTimedOut: skipTimedOut,
                              skipPreviewed: skipPreviewed, trialOnly: trialOnly,
                              excluding: excluding,
                              background: background, completion: completion)
            }
        }
        workQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        job.run(token) { [weak self] outcome in
            guard let self = self else { return }
            self.workQueue.async {
                guard !finished else { return }
                finished = true
                timeoutWork.cancel()
                let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
                switch outcome {
                case .empty:
                    if !background {
                        self.cooldown.record(job.key, outcome: .empty, milliseconds: elapsedMs)
                    }
                    self.runJobAt(jobs: jobs, index: index + 1, tier: tier, songId: songId,
                                  platform: platform, title: title, artist: artist,
                                  deadline: deadline, skipTimedOut: skipTimedOut,
                                  skipPreviewed: skipPreviewed, trialOnly: trialOnly,
                                  excluding: excluding,
                                  background: background, completion: completion)
                case .error:
                    if !background {
                        self.cooldown.record(job.key, outcome: .error, milliseconds: elapsedMs)
                        // b45-F: remember the failure for this song
                        // (10 min). The source is not deleted.
                        self.failureMemory.record(sourceKey: job.key, songId: songId)
                    }
                    self.runJobAt(jobs: jobs, index: index + 1, tier: tier, songId: songId,
                                  platform: platform, title: title, artist: artist,
                                  deadline: deadline, skipTimedOut: skipTimedOut,
                                  skipPreviewed: skipPreviewed, trialOnly: trialOnly,
                                  excluding: excluding,
                                  background: background, completion: completion)
                case .url(let rawUrl, let servedTier):
                    let url = MusicText.toHttps(rawUrl)
                    // A URL NSURL rejects kills the process the moment
                    // it reaches AVURLAsset: treat it as a failed
                    // source and try the next one.
                    guard !url.isEmpty, MusicText.isPlayableURL(url) else {
                        if !background {
                            self.cooldown.record(job.key, outcome: .error, milliseconds: elapsedMs)
                        }
                        self.runJobAt(jobs: jobs, index: index + 1, tier: tier, songId: songId,
                                      platform: platform, title: title, artist: artist,
                                      deadline: deadline, skipTimedOut: skipTimedOut,
                                      skipPreviewed: skipPreviewed, trialOnly: trialOnly,
                                      excluding: excluding,
                                      background: background, completion: completion)
                        return
                    }
                    // Build 36 item 3: a 30 s trial/preview URL is
                    // NEVER a successful resolve. It falls through
                    // to the next source exactly like an empty
                    // answer — no cooldown (the job is healthy;
                    // this song is just trial-only there), and the
                    // job is skipped at the lower tiers of this
                    // resolve too. This is the single choke point
                    // for every job, built-in and LX script alike.
                    if PreviewAudioClassifier.isPreviewURL(url, trialOnly: trialOnly) {
                        if !background {
                            self.cooldown.record(job.key, outcome: .empty, milliseconds: elapsedMs)
                        }
                        skipPreviewed.add(job.key)
                        self.runJobAt(jobs: jobs, index: index + 1, tier: tier, songId: songId,
                                      platform: platform, title: title, artist: artist,
                                      deadline: deadline, skipTimedOut: skipTimedOut,
                                      skipPreviewed: skipPreviewed, trialOnly: trialOnly,
                                      excluding: excluding,
                                      background: background, completion: completion)
                        return
                    }
                    // An explicitly excluded URL (already failed, or
                    // proved to be a preview at playback) is skipped
                    // the same way: the fallback resolve must hand
                    // out the NEXT candidate, never the same URL
                    // again — two aggregators can return the
                    // identical trial URL, so the job is not
                    // skipped, only this URL.
                    if excluding.contains(url) {
                        if !background {
                            self.cooldown.record(job.key, outcome: .empty, milliseconds: elapsedMs)
                        }
                        self.runJobAt(jobs: jobs, index: index + 1, tier: tier, songId: songId,
                                      platform: platform, title: title, artist: artist,
                                      deadline: deadline, skipTimedOut: skipTimedOut,
                                      skipPreviewed: skipPreviewed, trialOnly: trialOnly,
                                      excluding: excluding,
                                      background: background, completion: completion)
                        return
                    }
                    self.cooldown.record(job.key, outcome: .success, milliseconds: elapsedMs)
                    // b45-F: a success clears the failure memory
                    // for this source + song.
                    self.failureMemory.clear(sourceKey: job.key, songId: songId)
                    // A resolver that reports the tier it actually
                    // served is held to it; otherwise the declared label.
                    let tier = servedTier ?? MusicQualityGate.declaredTier(resolverKey: job.key, requested: tier)
                    completion(PlayUrlResult(url: url, quality: tier, via: job.name), false)
                }
            }
        }
    }
}

// MARK: - Job ranking

extension LXSourceResolver {
    /// Jobs for this platform in fastest-first order: cooled-down
    /// jobs last, then by measured latency (unknown = middle), then
    /// by declared order — except between two LX script jobs, where
    /// the user's manual drag order wins over measured speed. Script
    /// vs built-in is still by speed.
    private func rankedJobs(
        platform: MusicPlatform,
        tier: AudioQuality,
        songId: String,
        title: String,
        artist: String,
        failuresBefore: Date
    ) -> [LXResolverJob] {
        // Test seam: a `jobListProvider` replaces the built-in +
        // script jobs; the ranking rules below still apply.
        var jobs: [LXResolverJob]
        if let provider = jobListProvider {
            jobs = provider(platform, tier, songId, title, artist)
        } else {
            jobs = applicableResolvers(platform).map { resolver in
                makeJob(resolver, tier: tier, songId: songId, platform: platform, title: title, artist: artist)
            }
            for source in engine.musicUrlSources(platform: platform.rawValue, quality: tier) {
                let track = MusicTrack(id: songId, title: title, artist: artist, sourceID: platform.rawValue)
                let scriptID = source.scriptID
                let scriptName = source.scriptName
                jobs.append(LXResolverJob(
                    key: "lx:\(scriptID)",
                    name: scriptName,
                    order: 2,
                    platforms: [platform],
                    warmup: nil,
                    run: { [weak self] token, done in
                        guard let self = self else { done(.empty); return }
                        self.engine.getMusicUrl(
                            scriptID: scriptID, platform: platform.rawValue,
                            track: track, quality: tier, cancelToken: token
                        ) { result in
                            guard let result = result else { done(.empty); return }
                            done(.url(result.url, result.actualQuality))
                        }
                    }))
            }
        }
        let manualOrder = scriptStore.scriptOrder()
        var manualIndex: [String: Int] = [:]
        for (i, id) in manualOrder.enumerated() { manualIndex[id] = i }
        let unlistedScriptIndex = 1 << 30
        // b45-F: drop jobs whose source failed for THIS song in an
        // earlier resolve (10-minute failure memory). The source
        // stays in the list — the memory only expires; a failure
        // recorded during this resolve (at >= failuresBefore) does
        // not skip the lower tiers of the same resolve.
        jobs.removeAll { failureMemory.isFailed(sourceKey: $0.key, songId: songId, before: failuresBefore) }
        jobs.sort { a, b in
            let aCool = cooldown.isCoolingDown(a.key)
            let bCool = cooldown.isCoolingDown(b.key)
            if aCool != bCool { return !aCool }
            if a.key.hasPrefix("lx:"), b.key.hasPrefix("lx:") {
                let ai = manualIndex[String(a.key.dropFirst(3))] ?? unlistedScriptIndex
                let bi = manualIndex[String(b.key.dropFirst(3))] ?? unlistedScriptIndex
                if ai != bi { return ai < bi }
            }
            let aMs = cooldown.averageMs(a.key)
            let bMs = cooldown.averageMs(b.key)
            if aMs != bMs { return aMs < bMs }
            // b47-playlogic (Coda §7.1: native platform URL first,
            // unblock only after it fails — same order as music-lib
            // QQ `requestQualityURLs` and QQMusicApi
            // `vkey.GetVkeyServer` before any mirror): on a speed
            // tie — the cold start, where every job reads unknown
            // 500 ms — the built-in (direct HTTP endpoint) is asked
            // before the LX script jobs. A script that measured
            // faster still wins on speed above; a hanging built-in
            // still cools down (2 min) and sorts last next time.
            let aScript = a.key.hasPrefix("lx:")
            let bScript = b.key.hasPrefix("lx:")
            if aScript != bScript { return !aScript }
            return a.order < b.order
        }
        return jobs
    }

    private func makeJob(
        _ resolver: BuiltInResolver,
        tier: AudioQuality,
        songId: String,
        platform: MusicPlatform,
        title: String,
        artist: String
    ) -> LXResolverJob {
        LXResolverJob(
            key: resolver.key,
            name: resolver.name,
            order: resolver.order,
            platforms: resolver.platforms,
            warmup: resolver.key == "xinghai" ? { [weak self] done in
                self?.getXhToken(cancelToken: nil) { _ in done() }
            } : nil,
            run: { [weak self] token, done in
                guard let self = self else { done(.error); return }
                resolver.run(self, songId, platform, tier, title, artist, token, done)
            })
    }
}


// MARK: - Built-in resolvers

/// One built-in (non-script) resolver. `run` receives the resolver
/// instance (for `_fetchJson`), the song, the tier being tried, and
/// the job's cancel token.
struct BuiltInResolver {
    let key: String
    let name: String
    let order: Int
    let platforms: [MusicPlatform]
    let run: (LXSourceResolver, String, MusicPlatform, AudioQuality, String, String, LXCancelToken, @escaping (LXResolverOutcome) -> Void) -> Void
}

extension LXSourceResolver {
    /// The built-in resolvers in declaration order. `huibq` is
    /// DISABLED (its service returns 503 "Service Suspended" since
    /// 2026-11-16) — the order-1 resolver was dead, and its key fetch
    /// ran before every first call. Re-enable only if the service
    /// revives.
    private func applicableResolvers(_ platform: MusicPlatform) -> [BuiltInResolver] {
        allResolvers.filter { $0.platforms.contains(platform) }
    }

    private var allResolvers: [BuiltInResolver] {
        [
            BuiltInResolver(key: "zddyr", name: "zddyr", order: 25, platforms: [.wy]) { resolver, songId, _, tier, _, _, token, done in
                let urlString = "https://yy.zddyr.top/lx/api/?source=wy&songmid=\(resolver.urlEncode(songId))&quality=\(tier.lxCode)"
                resolver.fetchJson(urlString, headers: ["User-Agent": Self.musicUserAgent], cancelToken: token) { json in
                    guard let json = json, (json["code"] as? Int) == 200,
                          !PreviewAudioClassifier.isPreviewResponse(json) else {
                        done(.empty)
                        return
                    }
                    let url = (json["url"] as? String) ?? ""
                    guard !url.isEmpty else { done(.empty); return }
                    // Master gate: verify the tier the API actually
                    // served — a master request answered with a
                    // fallback stream is hires, never master.
                    done(.url(url, MusicQualityGate.lxApiServedTier(response: json, requested: tier)))
                }
            },
            BuiltInResolver(key: "zddyr_mg", name: "zddyr 咪咕", order: 25, platforms: [.mg]) { resolver, songId, _, tier, _, _, token, done in
                // b49fix2 P1-10: 咪咕 had no built-in resolver at
                // all (allResolvers covered wy/tx/kg/kw only). The
                // oiapi search leg hands us its contentId as the
                // song id, and zddyr's migu API answers it.
                // Verified live 2026-11-25: the API returns code
                // 200 + a real Migu mp3 URL for EVERY quality
                // parameter (flac / master / hires / 128k all serve
                // the same MP3_128_16_Stero file), so the honest
                // served tier is always .standard128 — never the
                // requested tier (P1-15).
                let urlString = "https://yy.zddyr.top/lx/api/?source=mg&songmid=\(resolver.urlEncode(songId))&quality=\(tier.lxCode)"
                resolver.fetchJson(urlString, headers: ["User-Agent": Self.musicUserAgent], cancelToken: token) { json in
                    guard let json = json, (json["code"] as? Int) == 200,
                          !PreviewAudioClassifier.isPreviewResponse(json) else {
                        done(.empty)
                        return
                    }
                    let url = (json["url"] as? String) ?? ""
                    guard !url.isEmpty else { done(.empty); return }
                    done(.url(url, .standard128))
                }
            },
            BuiltInResolver(key: "gd", name: "GD Studio", order: 30, platforms: [.wy]) { resolver, songId, _, tier, _, _, token, done in
                let br: Int
                switch tier {
                case .master, .hiRes, .flac: br = 999
                case .high320: br = 320
                case .standard128: br = 128
                }
                let urlString = "https://music-api.gdstudio.xyz/api.php?types=url&id=\(resolver.urlEncode(songId))&source=netease&br=\(br)"
                resolver.fetchJson(urlString, headers: ["User-Agent": Self.musicUserAgent], cancelToken: token) { json in
                    // Build 36 item 3: a response that marks the
                    // audio as a trial is an empty answer, not a URL.
                    if let json = json, PreviewAudioClassifier.isPreviewResponse(json) {
                        done(.empty)
                        return
                    }
                    let url = (json?["url"] as? String) ?? ""
                    done(url.isEmpty ? .empty : .url(url, nil))
                }
            },
            BuiltInResolver(key: "xinghai", name: "星海", order: 40, platforms: [.wy, .kg, .kw, .mg]) { resolver, songId, platform, tier, _, _, token, done in
                resolver.getXhToken(cancelToken: token) { tk in
                    guard !tk.isEmpty else { done(.empty); return }
                    let sourceCode: String
                    switch platform {
                    case .wy: sourceCode = "wy"
                    case .tx: sourceCode = "qq"
                    case .kg: sourceCode = "kg"
                    case .kw: sourceCode = "kw"
                    case .mg: sourceCode = "mg"
                    }
                    var urlString = "https://yy1.zddyr.top/lx/api/?source=\(sourceCode)&songmid=\(resolver.urlEncode(songId))&quality=\(tier.lxCode)"
                    if platform == .kg {
                        urlString += "&mainHash=\(resolver.urlEncode(songId))"
                    }
                    resolver.fetchJson(urlString, headers: [
                        "User-Agent": "lx-music",
                        "X-Client": "XingHaiMusicSource/v3.2.19 (Linux)",
                        "X-Token": tk,
                    ], cancelToken: token) { json in
                        guard let json = json, (json["code"] as? Int) == 200,
                              !PreviewAudioClassifier.isPreviewResponse(json) else {
                            done(.empty)
                            return
                        }
                        let url = (json["url"] as? String) ?? ""
                        guard !url.isEmpty else { done(.empty); return }
                        // b49fix2 P1-10: 咪咕 via this API serves the
                        // same 128k mp3 at every quality (same
                        // zddyr migu backend as zddyr_mg) — label
                        // what it actually serves, never the
                        // requested tier (P1-15).
                        let served: AudioQuality? = platform == .mg
                            ? .standard128
                            : MusicQualityGate.lxApiServedTier(response: json, requested: tier)
                        done(.url(url, served))
                    }
                }
            },
            BuiltInResolver(key: "vkeys_tx", name: "落月QQ", order: 1, platforms: [.tx]) { resolver, songId, _, tier, _, _, token, done in
                // 落月 v3 song/link (api.vkeys.cn, no key): the first
                // built-in QQ resolver — and the ONLY built-in for
                // [.tx]. The v2 geturl leg answers 503
                // "系统运行错误！" as of 2026-11-24, so only v3 is
                // used. Verified 2026-11-24 (item 7): code 0 ->
                // ws.stream.qqmusic.qq.com mp3, range GET 206,
                // 65536 bytes. Trial guard (b37 M1-b, same as the
                // stellarwave script's isTrialTxUrl): RS0 URLs and
                // 音乐试听/付费 answers are previews, never URLs.
                // b47-qq: two defects made QQ unplayable on device.
                // (1) The vkeys hiRes leg answers code 110001
                // ("cookie异常：账号被风控无法获取") for songs with
                // no hiRes file (e.g. 偷心 004IShrs2AZZIL — q11
                // and q6 both 110001 while q10/q8 serve code 0),
                // so a single-quality job returns empty at the
                // default hiRes target. (2) The resolve then burns
                // its 8 s budget on the LX script jobs, whose QQ
                // chains are long sequential lists of mostly-dead
                // backends (v2 503, 海棠 APP_UPGRADE_REQUIRED,
                // 103.79.184.97 hangs ~8-10 s, a.aa.cab dead,
                // yy.zddyr.top 403 auth-required) — every script
                // job times out at the 3 s cap, and timeouts never
                // record a speed (averageMs stays unknown 500 ms),
                // so the scripts keep outranking vkeys by order
                // (2 < 50) and vkeys is never asked in any tier
                // pass. Fix: fall back through the lower tiers
                // INSIDE this job (first tier that serves a real
                // URL wins, labelled with the tier actually
                // served), and order 1 so the only built-in QQ
                // path is asked before the script jobs on ties.
                let tiers = AudioQuality.chain(from: tier)
                var index = 0
                func qualityInt(_ t: AudioQuality) -> Int {
                    switch t {
                    case .master: return 14
                    case .hiRes: return 11
                    case .flac: return 10
                    case .high320: return 8
                    case .standard128: return 6
                    }
                }
                func tryNext() {
                    guard !token.isCancelled else { done(.empty); return }
                    guard index < tiers.count else { done(.empty); return }
                    let t = tiers[index]
                    index += 1
                    let urlString = "https://api.vkeys.cn/music/tencent/song/link?mid=\(resolver.urlEncode(songId))&quality=\(qualityInt(t))"
                    resolver.fetchJson(urlString, headers: ["User-Agent": Self.musicUserAgent, "Accept": "application/json"], cancelToken: token) { json in
                        guard !token.isCancelled else { done(.empty); return }
                        if let json = json, (json["code"] as? Int) == 0,
                           let data = json["data"] as? [String: Any] {
                            let url = (data["url"] as? String) ?? ""
                            let trial = PreviewAudioClassifier.isPreviewURL(url)
                                || (data["quality"] as? String) == "音乐试听"
                                || (data["pay"] as? String) == "付费"
                            if !url.isEmpty, !trial {
                                // Master honesty gate: vkeys is not
                                // an allowlisted Master source — a
                                // q14 hit is labelled hires, never
                                // master (same as declaredTier).
                                let served: AudioQuality = (t == .master) ? .hiRes : t
                                done(.url(url, served))
                                return
                            }
                        }
                        tryNext()
                    }
                }
                tryNext()
            },
            BuiltInResolver(key: "oiapi_wy", name: "oiapi-网易", order: 60, platforms: [.wy]) { resolver, songId, _, _, _, _, token, done in
                let urlString = "https://oiapi.net/api/Music_163?id=\(resolver.urlEncode(songId))"
                resolver.fetchJson(urlString, headers: ["User-Agent": Self.musicUserAgent], cancelToken: token) { json in
                    guard let json = json, (json["code"] as? Int) == 0,
                          !PreviewAudioClassifier.isPreviewResponse(json) else {
                        done(.empty)
                        return
                    }
                    // The live API returns data as a Map
                    // {items: [{url, ...}]}; the old shape was a bare
                    // List. Accept both.
                    var first: [String: Any]?
                    if let list = json["data"] as? [Any], !list.isEmpty {
                        first = list.first as? [String: Any]
                    } else if let map = json["data"] as? [String: Any],
                              let items = map["items"] as? [Any], !items.isEmpty {
                        first = items.first as? [String: Any]
                    }
                    let url = (first?["url"] as? String) ?? ""
                    done(url.isEmpty ? .empty : .url(url, nil))
                }
            },
            BuiltInResolver(key: "meting", name: "Meting", order: 70, platforms: [.wy]) { resolver, songId, _, tier, _, _, token, done in
                // Meting API (api.qijieya.cn, no key) — the `lzm`
                // replacement (item 7): GET
                // ?server=netease&type=url&br=<128|320>&id=<songId>
                // answers 302 to the real mp3. URLSession follows
                // the redirect, so the playable URL is the final
                // response.url (Location header as fallback); a
                // Range request keeps the body to 1 byte, so no
                // audio is downloaded during resolve. Verified
                // 2026-11-24: 302 -> m701.music.126.net mp3, full
                // file 4,332,717 bytes. Ordered late (70): VM
                // latency is 6-9 s, the phone will be faster.
                let br = tier == .standard128 ? 128 : 320
                guard let url = URL(string: "https://api.qijieya.cn/meting/?server=netease&type=url&br=\(br)&id=\(resolver.urlEncode(songId))") else {
                    done(.empty)
                    return
                }
                resolver.httpClient.request(
                    url: url, method: "GET",
                    headers: ["User-Agent": Self.musicUserAgent, "Range": "bytes=0-0"],
                    body: nil, timeout: 5
                ) { _, response, error in
                    if token.isCancelled { done(.empty); return }
                    guard error == nil,
                          let httpResponse = response as? HTTPURLResponse,
                          (200...206).contains(httpResponse.statusCode) || httpResponse.statusCode == 302 else {
                        done(.empty)
                        return
                    }
                    var final = httpResponse.url?.absoluteString ?? ""
                    if final == url.absoluteString || final.isEmpty {
                        final = (httpResponse.allHeaderFields["Location"] as? String)
                            ?? (httpResponse.allHeaderFields["location"] as? String) ?? ""
                    }
                    guard !final.isEmpty, final != url.absoluteString, final.hasPrefix("http") else {
                        done(.empty)
                        return
                    }
                    done(.url(final, nil))
                }
            },
            BuiltInResolver(key: "wwwweb", name: "wwwweb", order: 120, platforms: [.wy, .kw]) { resolver, songId, platform, tier, _, _, token, done in
                let quality = LXSourceResolver.wwwwebQuality(tier, platform: platform)
                let body = MusicJSON.string(from: [
                    "source": platform.rawValue,
                    "musicId": songId,
                    "quality": quality,
                ])
                resolver.fetchJson(
                    "https://c.wwwweb.top/music/url",
                    method: "POST",
                    headers: [
                        "User-Agent": "lx-music-desktop/2.10.1",
                        "Content-Type": "application/json",
                        // De-keyed: the API key header is empty in the
                        // Flutter baseline too (no key is bundled).
                        "X-Api-Key": "",
                    ],
                    body: body?.data(using: .utf8),
                    cancelToken: token
                ) { json in
                    guard let json = json, (json["code"] as? Int) == 200,
                          !PreviewAudioClassifier.isPreviewResponse(json) else {
                        done(.empty)
                        return
                    }
                    let url = (json["url"] as? String) ?? ""
                    done(url.isEmpty ? .empty : .url(url, nil))
                }
            },
            BuiltInResolver(key: "zddyr_kw", name: "星海酷我", order: 130, platforms: [.kw]) { resolver, songId, _, tier, title, _, token, done in
                guard !title.isEmpty else { done(.empty); return }
                // Refuses master/hires/lossless outright (returns
                // empty -> downgrade).
                guard tier == .high320 || tier == .standard128 else { done(.empty); return }
                let urlString = "https://yy.zddyr.top/lx/api/?source=kw&name=\(resolver.urlEncode(title))&singer=&songmid=\(resolver.urlEncode(songId))&interval=&albumName=&quality=\(tier.lxCode)"
                resolver.fetchJson(urlString, headers: ["User-Agent": Self.musicUserAgent], cancelToken: token) { json in
                    guard let json = json, (json["code"] as? Int) == 200,
                          !PreviewAudioClassifier.isPreviewResponse(json) else {
                        done(.empty)
                        return
                    }
                    let url = (json["url"] as? String) ?? ""
                    done(url.isEmpty ? .empty : .url(url, nil))
                }
            },
        ]
    }

    // MARK: - Quality helpers (per-resolver parameters)

    /// wwwweb's quality parameter: master maps to its best known
    /// value `flac`; Kuwo hires/lossless map to `320k`.
    static func wwwwebQuality(_ quality: AudioQuality, platform: MusicPlatform) -> String {
        if quality == .master { return "flac" }
        if platform == .kw {
            return (quality == .hiRes || quality == .flac) ? "320k" : quality.lxCode
        }
        return (quality == .hiRes || quality == .flac) ? "flac" : quality.lxCode
    }

    func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

// MARK: - HTTP + token plumbing

extension LXSourceResolver {
    /// Fetch a JSON object. Nil on network error, non-200 status, or
    /// an unparseable body. An empty answer is NOT a failure — the
    /// caller's job records it as `.empty`.
    func fetchJson(
        _ urlString: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 5,
        cancelToken: LXCancelToken?,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }
        httpClient.request(
            url: url, method: method, headers: headers, body: body, timeout: timeout
        ) { data, response, error in
            if let token = cancelToken, token.isCancelled {
                completion(nil)
                return
            }
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data, !data.isEmpty
            else {
                completion(nil)
                return
            }
            if let dict = MusicJSON.object(from: String(data: data, encoding: .utf8) ?? "") as? [String: Any] {
                completion(dict)
                return
            }
            completion(nil)
        }
        // NOTE: the in-flight request is not cancelled here: the
        // job-timeout work item cancels the token, the fetch
        // completion sees it and discards the result, and the
        // request itself is bounded by its own `timeout`. Cancelling
        // the URLSession task would need the task handle plumbed
        // through every resolver; the observable behaviour (the
        // caller moves on at the job timeout) is identical.
    }

    /// Xinghai token, cached 4 minutes, single-flight: concurrent
    /// callers share one fetch. Empty string when the token endpoint
    /// is unreachable (the job then answers empty fast).
    func getXhToken(
        cancelToken: LXCancelToken?,
        completion: @escaping (String) -> Void
    ) {
        workQueue.async {
            if let token = self.xhToken,
               let at = self.xhTokenAt,
               Date().timeIntervalSince(at) < 4 * 60 {
                completion(token)
                return
            }
            self.xhTokenWaiters.append(completion)
            guard !self.xhTokenInFlight else { return }
            self.xhTokenInFlight = true
            let deviceId = self.xhDeviceId()
            let urlString = "https://yy1.zddyr.top/lx/api/token.php?device_id=\(self.urlEncode(deviceId))"
            self.fetchJson(urlString, headers: ["User-Agent": "lx-music"], timeout: 6, cancelToken: cancelToken) { json in
                self.workQueue.async {
                    self.xhTokenInFlight = false
                    let waiters = self.xhTokenWaiters
                    self.xhTokenWaiters = []
                    let token = ((json?["data"] as? [String: Any])?["token"] as? String) ?? ""
                    if !token.isEmpty {
                        self.xhToken = token
                        self.xhTokenAt = Date()
                    }
                    for waiter in waiters { waiter(token) }
                }
            }
        }
    }

    /// Stable per-install device id for the xinghai token endpoint,
    /// persisted as a JSON string under `hao_sa_xh_device` (same key
    /// name as the Flutter Hive entry). Not a secret — just an
    /// install identifier the token endpoint expects.
    private func xhDeviceId() -> String {
        let url = documentsDirectory.appendingPathComponent("hao_sa_xh_device.json")
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(String.self, from: data),
           !stored.isEmpty {
            return stored
        }
        let micros = Date().timeIntervalSince1970 * 1_000_000
        let hex = String(Int(micros), radix: 16)
        let suffix = String(hex.suffix(8))
        let millis = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let id = "lx-sa-\(suffix)\(millis)"
        if let data = try? JSONEncoder().encode(id) {
            try? data.write(to: url, options: [.atomic])
        }
        return id
    }
}

// MARK: - Tier reporting (Master honesty gate)

extension LXSourceResolver: TierReportingResolver {}

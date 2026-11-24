// HAo Studio 2.0 — live room session tests (S4, leg A).
//
// SwiftPM style, same shape as S3's VideoCapabilityTests: pure
// logic only (Foundation), no network, no engine — every URL is
// built inline and every clock is fake, so no test waits real
// 4 s / 12 s / 60 s / 10 s.
//
// WIRING NOTE: this target (`VideoServicesTests`) can only see
// `LiveRoomSession.swift` once AppCore lists it — AppCore's
// `sources` currently name only `Playback/PlaybackCoordinator.swift`
// from Playback/, so one Package.swift line is still needed at
// merge (`"Playback/LiveRoomSession.swift"` next to the coordinator
// line). This leg does not edit Package.swift, so the tests below
// are written but NOT yet wired to run — same treatment as S3's
// `VideoPlayerTests` (unwired until S7). Do not "fix" this by
// moving the session file: one file, one target.
//
// What is covered: the fetch-and-hold lease (throttle 60 s,
// timeout 10 s, held plan one-shot + expired-held rejection,
// prefetch timing, line matching by URL identity across a format
// change, hard expiry), the stall watchdog (4 s warn / 12 s fail),
// the recovery budget (single-line 2, multi-line lineCount - 1,
// healthy playback resets it), the quality rollback (P0-09), the
// background-audio gate, and exit.

import Foundation
import XCTest

@testable import AppCore

// MARK: - Fakes

/// Controllable stand-in for LiveSiteResolver. Resolutions are a
/// queue: each resolve pops the next entry, so a test can say
/// "first resolve returns the room, the re-parse returns a
/// mismatched quality".
/// No-op transport stand-in (session tests never start danmaku).
final class FakeDanmakuTransport: LiveDanmakuTransport {
    var isConnected: Bool { false }
    var onMessage: ((DanmakuMessage) -> Void)?
    var onReady: (() -> Void)?
    var onClose: (() -> Void)?
    var onReconnect: (() -> Void)?

    func start(danmakuData: [String: Any]) {}
    func heartbeat() {}
    func stop() {}
}

final class FakeLiveSiteResolver: LiveSiteResolver {
    var platform: LivePlatform { .huya }
    var resolutionsToReturn: [LivePlayUrlResolution?] = []
    /// Resolution offered through `resolutionFromRoom` (list-feed
    /// fallback), when set.
    var roomResolutionToReturn: LivePlayUrlResolution?
    /// Error `resolve` fails with when `resolutionsToReturn` is empty.
    var resolveError: Error = LiveError.emptyResponse
    var resolveCount = 0
    var receivedRoomIds: [String] = []
    var receivedQualities: [LiveQuality?] = []

    func roomInfo(roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        completion(.failure(LiveError.unsupported("test fake has no room info")))
    }

    func resolve(roomId: String, quality: LiveQuality?, completion: @escaping (Result<LivePlayUrlResolution, Error>) -> Void) {
        resolveCount += 1
        receivedRoomIds.append(roomId)
        receivedQualities.append(quality)
        let resolution = resolutionsToReturn.isEmpty ? nil : resolutionsToReturn.removeFirst()
        if let resolution = resolution {
            completion(.success(resolution))
        } else {
            completion(.failure(resolveError))
        }
    }

    func resolutionFromRoom(_ room: LiveRoom, quality: LiveQuality?) -> LivePlayUrlResolution? {
        roomResolutionToReturn
    }

    func makeDanmakuTransport() -> LiveDanmakuTransport {
        FakeDanmakuTransport()
    }
}

/// A resolver that never answers (for the 10 s timeout path).
final class HangingLiveSiteResolver: LiveSiteResolver {
    var platform: LivePlatform { .huya }
    var resolveCount = 0

    func roomInfo(roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
    }

    func resolve(roomId: String, quality: LiveQuality?, completion: @escaping (Result<LivePlayUrlResolution, Error>) -> Void) {
        resolveCount += 1
    }

    func makeDanmakuTransport() -> LiveDanmakuTransport {
        FakeDanmakuTransport()
    }
}

// MARK: - Builders

private func makeRoom() -> LiveRoom {
    return LiveRoom(roomId: "123", platform: .huya, title: "测试直播间", streamer: "主播", onlineCount: 100, isLive: true)
}

private func makeResolution(urls: [URL], quality: LiveQuality? = nil, issuedAt: Date = Date(), refreshAt: Date? = nil, invalidAt: Date? = nil) -> LivePlayUrlResolution {
    let lines = urls.enumerated().map { index, url in
        LiveLine(name: "线路\(index + 1)", urls: [url.absoluteString])
    }
    return LivePlayUrlResolution(lines: lines, formats: [], qualities: [], quality: quality, issuedAt: issuedAt, refreshAt: refreshAt, invalidAt: invalidAt)
}

private func flvURL(_ host: String = "tx.flv.huya.com") -> URL {
    return URL(string: "https://\(host)/room/1.flv")!
}

private func hlsURL(_ host: String = "tx.hls.huya.com") -> URL {
    return URL(string: "https://\(host)/room/1.m3u8")!
}

// MARK: - Recovery: throttle + timeout

final class LiveRecoveryThrottleTests: XCTestCase {
    func testFetchFreshThrottledToOncePer60s() {
        var fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let resolver = FakeLiveSiteResolver()
        let resolution = makeResolution(urls: [flvURL()])
        resolver.resolutionsToReturn = [resolution, resolution, resolution]
        let recovery = LiveRecovery(roomId: "123", resolver: resolver, now: { fakeNow })
        var first: LivePlayUrlResolution?
        recovery.fetchFresh { first = $0 }
        XCTAssertNotNil(first)
        XCTAssertEqual(resolver.resolveCount, 1)
        // 30 s later: throttled, no second request.
        fakeNow = fakeNow.addingTimeInterval(30)
        var secondCalls = 0
        var secondValue: LivePlayUrlResolution?
        recovery.fetchFresh { value in
            secondValue = value
            secondCalls += 1
        }
        XCTAssertEqual(secondCalls, 1)
        XCTAssertNil(secondValue)
        XCTAssertEqual(resolver.resolveCount, 1)
        // 61 s after the first fetch: allowed again.
        fakeNow = fakeNow.addingTimeInterval(31)
        var third: LivePlayUrlResolution?
        recovery.fetchFresh { third = $0 }
        XCTAssertNotNil(third)
        XCTAssertEqual(resolver.resolveCount, 2)
        recovery.dispose()
    }

    func testFetchFreshTimeout() {
        let recovery = LiveRecovery(roomId: "123", resolver: HangingLiveSiteResolver())
        recovery.timeoutInterval = 0.2
        let timedOut = expectation(description: "fetchFresh times out")
        recovery.fetchFresh { resolution in
            XCTAssertNil(resolution)
            timedOut.fulfill()
        }
        waitForExpectations(timeout: 2)
        recovery.dispose()
    }

    func testFetchFreshEmptyResolutionIsNil() {
        let resolver = FakeLiveSiteResolver()
        resolver.resolutionsToReturn = [makeResolution(urls: [])]
        let recovery = LiveRecovery(roomId: "123", resolver: resolver)
        var fetchCalls = 0
        var fetchValue: LivePlayUrlResolution?
        recovery.fetchFresh { value in
            fetchValue = value
            fetchCalls += 1
        }
        XCTAssertEqual(fetchCalls, 1)
        XCTAssertNil(fetchValue)
        recovery.dispose()
    }

    /// b39: a resolve that fails with a definitive offline records
    /// it — the driver shows "房间未开播" for that room instead of
    /// the generic "没有可播放的地址" (chen 2026-11-25: cxy0714
    /// was off air).
    func testResolveInitialOfflineSetsFlag() {
        let resolver = FakeLiveSiteResolver()
        resolver.resolveError = LiveError.offline
        let recovery = LiveRecovery(roomId: "123", resolver: resolver)
        var initialValue: LivePlayUrlResolution?
        recovery.resolveInitial { value in initialValue = value }
        XCTAssertNil(initialValue)
        XCTAssertTrue(recovery.lastResolveWasOffline)
        recovery.dispose()
    }

    /// The flag is per-fetch, not sticky: a generic failure
    /// (empty response here) leaves it false, so a room that
    /// fails for another reason still gets the generic text.
    func testResolveInitialGenericFailureClearsFlag() {
        let resolver = FakeLiveSiteResolver()
        let recovery = LiveRecovery(roomId: "123", resolver: resolver)
        var initialValue: LivePlayUrlResolution?
        recovery.resolveInitial { value in initialValue = value }
        XCTAssertNil(initialValue)
        XCTAssertFalse(recovery.lastResolveWasOffline)
        recovery.dispose()
    }
}

// MARK: - Recovery: held plan + prefetch + expiry

final class LiveRecoveryHoldTests: XCTestCase {
    func testTakeHeldIsOneShot() {
        var fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let resolver = FakeLiveSiteResolver()
        let held = makeResolution(urls: [flvURL()], issuedAt: fakeNow, refreshAt: fakeNow.addingTimeInterval(100), invalidAt: fakeNow.addingTimeInterval(125))
        resolver.resolutionsToReturn = [held]
        let recovery = LiveRecovery(roomId: "123", resolver: resolver, now: { fakeNow })
        recovery.performPrefetch()
        XCTAssertNotNil(recovery.peekHeld())
        let taken = recovery.takeHeld()
        XCTAssertNotNil(taken)
        XCTAssertNil(recovery.peekHeld())
        XCTAssertNil(recovery.takeHeld())
        recovery.dispose()
    }

    func testExpiredHeldPlanIsNeverServed() {
        let fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let resolver = FakeLiveSiteResolver()
        // Hard expiry already past when the hold is taken.
        let held = makeResolution(urls: [flvURL()], issuedAt: fakeNow.addingTimeInterval(-130), refreshAt: fakeNow.addingTimeInterval(-30), invalidAt: fakeNow.addingTimeInterval(-5))
        resolver.resolutionsToReturn = [held]
        let recovery = LiveRecovery(roomId: "123", resolver: resolver, now: { fakeNow })
        recovery.performPrefetch()
        XCTAssertNil(recovery.peekHeld())
        XCTAssertNil(recovery.takeHeld())
        recovery.dispose()
    }

    func testPrefetchDelayNeedsLease() {
        let recovery = LiveRecovery(roomId: "123", resolver: nil)
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(recovery.prefetchDelay(at: nil, from: now))
        XCTAssertEqual(recovery.prefetchDelay(at: now.addingTimeInterval(100), from: now), 100)
        // A deadline already past fires in 1 s, never never.
        XCTAssertEqual(recovery.prefetchDelay(at: now.addingTimeInterval(-50), from: now), 1)
        recovery.dispose()
    }

    func testIsExpired() {
        var fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let recovery = LiveRecovery(roomId: "123", resolver: nil, now: { fakeNow })
        XCTAssertFalse(recovery.isExpired)
        recovery.adopt(resolution: makeResolution(urls: [flvURL()], issuedAt: fakeNow, invalidAt: fakeNow.addingTimeInterval(125)), previousUrl: nil)
        XCTAssertFalse(recovery.isExpired)
        fakeNow = fakeNow.addingTimeInterval(126)
        XCTAssertTrue(recovery.isExpired)
        recovery.dispose()
    }

    func testDiscardHeld() {
        let fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let resolver = FakeLiveSiteResolver()
        resolver.resolutionsToReturn = [makeResolution(urls: [flvURL()], issuedAt: fakeNow, refreshAt: fakeNow.addingTimeInterval(100), invalidAt: fakeNow.addingTimeInterval(125))]
        let recovery = LiveRecovery(roomId: "123", resolver: resolver, now: { fakeNow })
        recovery.performPrefetch()
        XCTAssertNotNil(recovery.peekHeld())
        recovery.discardHeld()
        XCTAssertNil(recovery.peekHeld())
        recovery.dispose()
    }
}

// MARK: - Recovery: line identity + advance

final class LiveRecoveryLinesTests: XCTestCase {
    func testAdvanceLineWrapsAndSingleLineIsNil() {
        let recovery = LiveRecovery(roomId: "123", resolver: nil)
        recovery.adopt(resolution: makeResolution(urls: [flvURL(), hlsURL()]), previousUrl: nil)
        XCTAssertEqual(recovery.advanceLine(), hlsURL())
        XCTAssertEqual(recovery.advanceLine(), flvURL())
        let single = LiveRecovery(roomId: "123", resolver: nil)
        single.adopt(resolution: makeResolution(urls: [flvURL()]), previousUrl: nil)
        XCTAssertNil(single.nextLineUrl)
        XCTAssertNil(single.advanceLine())
        recovery.dispose()
        single.dispose()
    }

    func testMatchLineSurvivesFormatChange() {
        // A refresh turns TX FLV into TX HLS: host and path suffix
        // both change, but the CDN token (tx) + media id (1) still
        // identify the same line — index must follow the line, not
        // fall back to line 0.
        let recovery = LiveRecovery(roomId: "123", resolver: nil)
        recovery.adopt(resolution: makeResolution(urls: [flvURL(), hlsURL()]), previousUrl: nil)
        recovery.currentLineIndex = 1
        // The playing line was TX FLV; the refresh turned it into
        // TX HLS, so exact host+path matching misses — the CDN
        // token (tx) + media id (1) still identify it.
        let previous = flvURL()
        let refreshed = [URL(string: "https://al.flv.huya.com/room/2.flv")!, URL(string: "https://tx.hls.huya.com/room/1.m3u8")!]
        XCTAssertEqual(recovery.matchLineIndex(urls: refreshed, previousUrl: previous), 1)
        // No match at all: line 0.
        XCTAssertEqual(recovery.matchLineIndex(urls: [URL(string: "https://other.cdn.com/x/9.flv")!], previousUrl: previous), 0)
        recovery.dispose()
    }

    func testAdoptKeepsPlayingLineByURL() {
        let recovery = LiveRecovery(roomId: "123", resolver: nil)
        recovery.adopt(resolution: makeResolution(urls: [flvURL(), hlsURL()]), previousUrl: nil)
        recovery.currentLineIndex = 1
        let playing = hlsURL()
        recovery.adopt(resolution: makeResolution(urls: [URL(string: "https://al.flv.huya.com/room/2.flv")!, hlsURL()]), previousUrl: playing)
        XCTAssertEqual(recovery.currentLineIndex, 1)
        XCTAssertEqual(recovery.currentUrl, hlsURL())
        recovery.dispose()
    }
}

// MARK: - Watchdog

final class LiveStallWatchdogTests: XCTestCase {
    func testWarnAt4FailAt12() {
        var fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let watchdog = LiveStallWatchdog()
        watchdog.now = { fakeNow }
        watchdog.reset()
        XCTAssertEqual(watchdog.tick(position: 0, isPlaying: true), .none)
        fakeNow = fakeNow.addingTimeInterval(4)
        XCTAssertEqual(watchdog.tick(position: 0, isPlaying: true), .warn)
        // Warn fires once per stall episode.
        fakeNow = fakeNow.addingTimeInterval(1)
        XCTAssertEqual(watchdog.tick(position: 0, isPlaying: true), .none)
        fakeNow = fakeNow.addingTimeInterval(7)
        XCTAssertEqual(watchdog.tick(position: 0, isPlaying: true), .failed)
    }

    func testMovementResetsClock() {
        var fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let watchdog = LiveStallWatchdog()
        watchdog.now = { fakeNow }
        watchdog.reset()
        fakeNow = fakeNow.addingTimeInterval(4)
        XCTAssertEqual(watchdog.tick(position: 0, isPlaying: true), .warn)
        // Position moved: the clock restarts, no failure at 12 s
        // from the original baseline.
        XCTAssertEqual(watchdog.tick(position: 10, isPlaying: true), .none)
        fakeNow = fakeNow.addingTimeInterval(11)
        XCTAssertEqual(watchdog.tick(position: 10, isPlaying: true), .none)
        fakeNow = fakeNow.addingTimeInterval(1)
        XCTAssertEqual(watchdog.tick(position: 10, isPlaying: true), .failed)
    }

    func testPausedNeverWarnsOrFails() {
        var fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let watchdog = LiveStallWatchdog()
        watchdog.now = { fakeNow }
        watchdog.reset()
        fakeNow = fakeNow.addingTimeInterval(30)
        XCTAssertEqual(watchdog.tick(position: 0, isPlaying: false), .none)
    }
}

// MARK: - Session: budget + quality + background + exit

final class LiveRoomSessionTests: XCTestCase {
    private func makeSession(urls: [URL], quality: LiveQuality? = nil) -> (LiveRoomSession, FakeLiveSiteResolver) {
        let session = LiveRoomSession()
        let resolver = FakeLiveSiteResolver()
        resolver.resolutionsToReturn = [makeResolution(urls: urls, quality: quality)]
        session.enterRoom(room: makeRoom(), resolver: resolver)
        var adopted: LivePlayUrlResolution?
        session.resolveInitial { adopted = $0 }
        XCTAssertNotNil(adopted)
        session.notePlaybackStarted()
        return (session, resolver)
    }

    func testAutoRecoveryBudget() {
        XCTAssertEqual(LiveRoomSession.autoRecoveryBudget(lineCount: 1), 2)
        XCTAssertEqual(LiveRoomSession.autoRecoveryBudget(lineCount: 2), 1)
        XCTAssertEqual(LiveRoomSession.autoRecoveryBudget(lineCount: 3), 2)
        XCTAssertEqual(LiveRoomSession.autoRecoveryBudget(lineCount: 0), 0)
    }

    /// When the network resolve fails with a non-offline error
    /// (e.g. Kuaishou's room page rate-limited), the initial
    /// resolve falls back to the list-feed URLs the entered room
    /// already carries instead of failing the room.
    func testResolveInitialFallsBackToListRoomUrlsWhenResolveFails() {
        let session = LiveRoomSession()
        let resolver = FakeLiveSiteResolver()
        resolver.roomResolutionToReturn = makeResolution(urls: [flvURL()])
        session.enterRoom(room: makeRoom(), resolver: resolver)
        var adopted: LivePlayUrlResolution?
        session.resolveInitial { adopted = $0 }
        XCTAssertNotNil(adopted)
        XCTAssertEqual(adopted?.appliedUrls, [flvURL().absoluteString])
    }

    /// …but a definitive offline never falls back: stale list URLs
    /// must not resurrect an ended room.
    func testResolveInitialDoesNotFallBackWhenRoomIsOffline() {
        let session = LiveRoomSession()
        let resolver = FakeLiveSiteResolver()
        resolver.resolveError = LiveError.offline
        resolver.roomResolutionToReturn = makeResolution(urls: [flvURL()])
        session.enterRoom(room: makeRoom(), resolver: resolver)
        var adopted: LivePlayUrlResolution?
        session.resolveInitial { adopted = $0 }
        XCTAssertNil(adopted)
    }

    func testSingleLineRoomGetsTwoRecoveriesThenFails() {
        let (session, _) = makeSession(urls: [flvURL()])
        // Budget 2: two recovery steps, the third failure shows
        // the failure card (P1-8 — the old bound was 0, so the
        // FIRST error showed the card and recovery never ran).
        XCTAssertEqual(session.noteFailure(), .fetchFresh)
        XCTAssertEqual(session.noteFailure(), .fetchFresh)
        XCTAssertEqual(session.noteFailure(), .exhausted)
        if case .failed = session.state {
        } else {
            XCTFail("expected .failed state, got \(session.state)")
        }
    }

    func testMultiLineRoomBudgetIsExtraLines() {
        let (session, _) = makeSession(urls: [flvURL(), hlsURL(), URL(string: "https://al.flv.huya.com/room/2.flv")!])
        XCTAssertEqual(session.noteFailure(), .fetchFresh)
        XCTAssertEqual(session.noteFailure(), .fetchFresh)
        XCTAssertEqual(session.noteFailure(), .exhausted)
    }

    func testHealthyPlaybackResetsBudget() {
        let (session, _) = makeSession(urls: [flvURL()])
        XCTAssertEqual(session.noteFailure(), .fetchFresh)
        XCTAssertEqual(session.consecutiveFailures, 1)
        session.notePlaybackStarted()
        XCTAssertEqual(session.consecutiveFailures, 0)
        XCTAssertEqual(session.noteFailure(), .fetchFresh)
        XCTAssertEqual(session.noteFailure(), .fetchFresh)
        XCTAssertEqual(session.noteFailure(), .exhausted)
    }

    func testThrottledFreshFallsThroughToNextLine() {
        let (session, resolver) = makeSession(urls: [flvURL(), hlsURL()])
        // Spend the 60 s throttle with a real fetch first.
        var fetched: LivePlayUrlResolution?
        resolver.resolutionsToReturn = [makeResolution(urls: [flvURL(), hlsURL()])]
        session.recovery?.fetchFresh { fetched = $0 }
        XCTAssertNotNil(fetched)
        // Held: none. Fresh: throttled. Next line: the HLS URL.
        XCTAssertEqual(session.noteFailure(), .nextLine(hlsURL()))
    }

    func testHeldPlanIsSpentBeforeFreshFetch() {
        let fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let session = LiveRoomSession()
        session.now = { fakeNow }
        let resolver = FakeLiveSiteResolver()
        let initial = makeResolution(urls: [flvURL()], issuedAt: fakeNow, refreshAt: fakeNow.addingTimeInterval(100), invalidAt: fakeNow.addingTimeInterval(125))
        resolver.resolutionsToReturn = [initial]
        session.enterRoom(room: makeRoom(), resolver: resolver)
        var adopted: LivePlayUrlResolution?
        session.resolveInitial { adopted = $0 }
        XCTAssertNotNil(adopted)
        session.notePlaybackStarted()
        // A hold fetched at refreshAt, for a different host.
        let held = makeResolution(urls: [URL(string: "https://al.flv.huya.com/room/1.flv")!], issuedAt: fakeNow, refreshAt: fakeNow.addingTimeInterval(200), invalidAt: fakeNow.addingTimeInterval(225))
        resolver.resolutionsToReturn = [held]
        session.recovery?.performPrefetch()
        XCTAssertNotNil(session.recovery?.peekHeld())
        let step = session.noteFailure()
        XCTAssertEqual(step, .useHeld([URL(string: "https://al.flv.huya.com/room/1.flv")!]))
        // The step only decided; spending it is the driver's job.
        XCTAssertNotNil(session.recovery?.peekHeld())
        session.exit()
    }

    func testQualitySwitchFailureRollsBack() {
        let hd = LiveQuality(id: "1080p", name: "蓝光")
        let sd = LiveQuality(id: "720p", name: "高清")
        let (session, resolver) = makeSession(urls: [flvURL()], quality: hd)
        XCTAssertEqual(session.currentQuality, hd)
        // The re-parse comes back for the OLD quality: rollback.
        resolver.resolutionsToReturn = [makeResolution(urls: [flvURL()], quality: hd)]
        var switched = true
        session.requestQualityChange(to: sd) { switched = $0 }
        XCTAssertFalse(switched)
        XCTAssertEqual(session.currentQuality, hd)
        XCTAssertEqual(session.recovery?.urls, [flvURL()])
    }

    func testQualitySwitchSuccessCommits() {
        let hd = LiveQuality(id: "1080p", name: "蓝光")
        let sd = LiveQuality(id: "720p", name: "高清")
        let (session, resolver) = makeSession(urls: [flvURL()], quality: hd)
        resolver.resolutionsToReturn = [makeResolution(urls: [hlsURL()], quality: sd)]
        var switched = false
        session.requestQualityChange(to: sd) { switched = $0 }
        XCTAssertTrue(switched)
        XCTAssertEqual(session.currentQuality, sd)
        XCTAssertEqual(session.recovery?.urls, [hlsURL()])
    }

    func testQualitySwitchToSameQualityIsNoop() {
        let hd = LiveQuality(id: "1080p", name: "蓝光")
        let (session, resolver) = makeSession(urls: [flvURL()], quality: hd)
        let countBefore = resolver.resolveCount
        var switched = false
        session.requestQualityChange(to: hd) { switched = $0 }
        XCTAssertTrue(switched)
        XCTAssertEqual(resolver.resolveCount, countBefore)
    }

    func testBackgroundOnlyWhenPlaying() {
        let (session, _) = makeSession(urls: [flvURL()])
        XCTAssertTrue(session.enterBackground())
        XCTAssertTrue(session.isBackgroundAudioOnly)
        XCTAssertTrue(session.enterForeground())
        XCTAssertFalse(session.isBackgroundAudioOnly)
        // A user-paused room stays paused in background.
        session.notePlaybackPaused()
        XCTAssertFalse(session.enterBackground())
        XCTAssertFalse(session.isBackgroundAudioOnly)
    }

    func testExitClearsRoomAndNeverTouchesMusic() {
        let (session, _) = makeSession(urls: [flvURL()])
        session.exit()
        XCTAssertEqual(session.state, .exited)
        XCTAssertNil(session.room)
        XCTAssertNil(session.recovery)
        XCTAssertFalse(session.isBackgroundAudioOnly)
    }

    func testMatchedFirstMovesPlayingLineToFront() {
        let (session, _) = makeSession(urls: [flvURL(), hlsURL(), URL(string: "https://al.flv.huya.com/room/2.flv")!])
        session.recovery?.currentLineIndex = 2
        let urls = [flvURL(), hlsURL(), URL(string: "https://al.flv.huya.com/room/2.flv")!]
        XCTAssertEqual(session.matchedFirst(urls: urls), [URL(string: "https://al.flv.huya.com/room/2.flv")!, flvURL(), hlsURL()])
    }
}

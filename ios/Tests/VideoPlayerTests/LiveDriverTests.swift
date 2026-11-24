// HAo Studio 2.0 — live driver tests (S4, leg A).
//
// iOS-only, same treatment as S3's VideoPlayerTests: NOT wired
// into `ios/Package.swift` (this leg does not edit it). S7 wired
// the `HAoStudioTests` Xcode test target (run with `xcodebuild
// test` against an iOS simulator destination — `swift test` on a
// macOS runner cannot compile this target: UIKit / AVFoundation).
// The target has the app as its host and the tests
// `@testable import HAoStudio` for the Playback / Services types.
//
// The driver is driven through a fake backend (shared with
// VideoPlayerTests.swift: FakeVideoBackend / FakeBackendFactory —
// NOT redefined here) and a fake resolver, never real engines: the
// open timeout uses a short injected interval, and no test waits
// real 4 s / 12 s / 10 s. The stall watchdog itself is covered by
// LiveRoomSessionTests (Foundation-only); these tests cover the
// driver around it: engine selection, ladder fallback, the fresh
// path, the no-seek rule, audio-only flag, and stop.

import Foundation
import XCTest

@testable import HAoStudio

// MARK: - Fakes

/// Controllable stand-in for LiveSiteResolver. Resolutions are a
/// queue: each resolve pops the next entry.
/// No-op transport stand-in (driver tests never start danmaku).
final class LiveDriverFakeTransport: LiveDanmakuTransport {
    var isConnected: Bool { false }
    var onMessage: ((DanmakuMessage) -> Void)?
    var onReady: (() -> Void)?
    var onClose: (() -> Void)?
    var onReconnect: (() -> Void)?

    func start(danmakuData: [String: Any]) {}
    func heartbeat() {}
    func stop() {}
}

final class LiveDriverFakeResolver: LiveSiteResolver {
    var platform: LivePlatform { .huya }
    var resolutionsToReturn: [LivePlayUrlResolution?] = []
    var resolveCount = 0
    /// Hold resolve completions instead of answering them (b36
    /// item 5: the stale-resolve test leaves the first resolve
    /// pending, releases the driver, re-enters, and only then
    /// answers the stale resolve — the re-entry's resolve must
    /// still be pending when the stale answer lands).
    var deferResolve = false
    var deferredResolveCompletions: [(Result<LivePlayUrlResolution, Error>) -> Void] = []

    func roomInfo(roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        completion(.failure(LiveError.unsupported("test fake has no room info")))
    }

    func resolve(roomId: String, quality: LiveQuality?, completion: @escaping (Result<LivePlayUrlResolution, Error>) -> Void) {
        resolveCount += 1
        if deferResolve {
            deferredResolveCompletions.append(completion)
            return
        }
        let resolution = resolutionsToReturn.isEmpty ? nil : resolutionsToReturn.removeFirst()
        if let resolution = resolution {
            completion(.success(resolution))
        } else {
            completion(.failure(LiveError.emptyResponse))
        }
    }

    func makeDanmakuTransport() -> LiveDanmakuTransport {
        LiveDriverFakeTransport()
    }
}

/// A backend whose open never answers (for the 10 s timeout path).
final class HangingLiveBackend: VideoPlayerBackend {
    let engine: VideoEngine
    var onEvent: ((VideoBackendEvent) -> Void)?
    var onVideoSize: ((CGSize) -> Void)?

    var isPlaying: Bool = false
    var currentTime: Double = 0
    var duration: Double = 0
    var isPrepared: Bool = false
    var playbackRate: Double = 1
    var hardwareDecode: VideoHardwareDecodeState = .unknown

    init(engine: VideoEngine) {
        self.engine = engine
    }

    var view: UIView {
        return UIView()
    }

    func setVideoFit(_ fit: VideoFit) {}

    func open(url: URL, headers: [String: String], completion: @escaping (Bool) -> Void) {}

    func play() {}

    func pause() {}

    func seek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        completion(false)
    }

    func shutdown() {}
}

// MARK: - Driver tests

final class LiveDriverTests: XCTestCase {
    private func makeRoom() -> LiveRoom {
        return LiveRoom(roomId: "123", platform: .huya, title: "测试直播间", streamer: "主播", onlineCount: 100, isLive: true)
    }

    private func makeResolution(urls: [URL], quality: LiveQuality? = nil) -> LivePlayUrlResolution {
        let lines = urls.enumerated().map { index, url in
            LiveLine(name: "线路\(index + 1)", urls: [url.absoluteString])
        }
        return LivePlayUrlResolution(lines: lines, formats: [], qualities: [], quality: quality, refreshAt: nil, invalidAt: nil)
    }

    private func makeDriver(factory: FakeBackendFactory, resolver: LiveDriverFakeResolver) -> LiveDriver {
        let driver = LiveDriver()
        driver.makeBackend = { factory.makeBackend(engine: $0) }
        driver.openTimeoutInterval = 5
        driver.configure(room: makeRoom(), resolver: resolver)
        return driver
    }

    private func playRoom(driver: LiveDriver, started: XCTestExpectation) {
        driver.onRoomStarted = { _ in started.fulfill() }
        driver.play(item: LiveDriver.playbackItem(room: makeRoom()))
    }

    func testPlayOpensFlvOnMpvNeverAvPlayer() {
        // FLV: candidates are MPV, IJK — AVPlayer has no FLV
        // demuxer and must never appear in the candidate list, let
        // alone be opened.
        let factory = FakeBackendFactory()
        let mpv = FakeVideoBackend(engine: .mpv)
        let ijk = FakeVideoBackend(engine: .ijk)
        let avplayer = FakeVideoBackend(engine: .avplayer)
        factory.fakes = [.mpv: [mpv], .ijk: [ijk], .avplayer: [avplayer]]
        let resolver = LiveDriverFakeResolver()
        resolver.resolutionsToReturn = [makeResolution(urls: [URL(string: "https://tx.flv.huya.com/room/1.flv")!])]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "room started")
        playRoom(driver: driver, started: started)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentEngine, .mpv)
        XCTAssertEqual(mpv.openCount, 1)
        XCTAssertEqual(avplayer.openCount, 0)
        XCTAssertEqual(ijk.openCount, 0)
        XCTAssertTrue(driver.isPlaying)
        XCTAssertEqual(driver.currentRoom?.kind, .live)
    }

    func testPlayOpensHlsOnAvPlayer() {
        // HLS: the capability split puts AVPlayer first
        // (VideoToolbox hard decode).
        let factory = FakeBackendFactory()
        let avplayer = FakeVideoBackend(engine: .avplayer)
        let mpv = FakeVideoBackend(engine: .mpv)
        factory.fakes = [.avplayer: [avplayer], .mpv: [mpv]]
        let resolver = LiveDriverFakeResolver()
        resolver.resolutionsToReturn = [makeResolution(urls: [URL(string: "https://tx.hls.huya.com/room/1.m3u8")!])]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "room started")
        playRoom(driver: driver, started: started)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentEngine, .avplayer)
        XCTAssertEqual(avplayer.openCount, 1)
        XCTAssertEqual(mpv.openCount, 0)
    }

    func testEngineFallbackOnOpenFailure() {
        // FLV: MPV fails, IJK succeeds — the driver plays on IJK,
        // never an error, never AVPlayer.
        let factory = FakeBackendFactory()
        let failingMPV = FakeVideoBackend(engine: .mpv)
        failingMPV.openResults = [false]
        let goodIJK = FakeVideoBackend(engine: .ijk)
        let avplayer = FakeVideoBackend(engine: .avplayer)
        factory.fakes = [.mpv: [failingMPV], .ijk: [goodIJK], .avplayer: [avplayer]]
        let resolver = LiveDriverFakeResolver()
        resolver.resolutionsToReturn = [makeResolution(urls: [URL(string: "https://tx.flv.huya.com/room/1.flv")!])]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "room started on IJK")
        playRoom(driver: driver, started: started)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentEngine, .ijk)
        XCTAssertEqual(failingMPV.openCount, 1)
        XCTAssertEqual(goodIJK.openCount, 1)
        XCTAssertEqual(failingMPV.shutdownCount, 1)
        XCTAssertEqual(avplayer.openCount, 0)
    }

    func testPlayWithoutResolutionFails() {
        let factory = FakeBackendFactory()
        let resolver = LiveDriverFakeResolver()
        resolver.resolutionsToReturn = [nil]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let failed = expectation(description: "room failed")
        var failure: MusicPlayerError?
        driver.onRoomFailed = { _, error in
            failure = error
            failed.fulfill()
        }
        driver.play(item: LiveDriver.playbackItem(room: makeRoom()))
        waitForExpectations(timeout: 2)
        XCTAssertEqual(failure, .noPlayableURL)
        XCTAssertNil(driver.currentRoom)
    }

    func testPlayWithoutConfigureFails() {
        let driver = LiveDriver()
        driver.openTimeoutInterval = 5
        let failed = expectation(description: "room failed")
        var failure: MusicPlayerError?
        driver.onRoomFailed = { _, error in
            failure = error
            failed.fulfill()
        }
        driver.play(item: LiveDriver.playbackItem(room: makeRoom()))
        waitForExpectations(timeout: 2)
        XCTAssertEqual(failure, .noPlayableURL)
    }

    func testOpenTimeoutIsAStreamError() {
        // Every capable engine hangs: the 10 s open timeout (here
        // 0.2 s) must fire exactly like a stream error, and the
        // fallback resolve must get the dead URL in `excluding` and
        // have nothing else to hand out.
        let factory = FakeBackendFactory()
        factory.fakes = [
            .mpv: [HangingLiveBackend(engine: .mpv)],
            .ijk: [HangingLiveBackend(engine: .ijk)],
        ]
        let resolver = LiveDriverFakeResolver()
        resolver.resolutionsToReturn = [makeResolution(urls: [URL(string: "https://tx.flv.huya.com/room/1.flv")!])]
        let driver = makeDriver(factory: factory, resolver: resolver)
        driver.openTimeoutInterval = 0.2
        let failed = expectation(description: "room failed on timeout")
        var failure: MusicPlayerError?
        driver.onRoomFailed = { _, error in
            failure = error
            failed.fulfill()
        }
        driver.play(item: LiveDriver.playbackItem(room: makeRoom()))
        waitForExpectations(timeout: 2)
        XCTAssertEqual(failure, .timeout)
        XCTAssertNil(driver.currentRoom)
    }

    func testLiveSeekAlwaysFails() {
        // Live is real-time: there is nothing to seek to, and the
        // driver must say so instead of pretending a seek landed.
        let driver = LiveDriver()
        var result: Bool?
        driver.seek(to: 60) { result = $0 }
        XCTAssertEqual(result, false)
    }

    func testSetAudioOnlyRecordsFlag() {
        let driver = LiveDriver()
        driver.setAudioOnly(true)
        XCTAssertTrue(driver.isAudioOnly)
        driver.setAudioOnly(false)
        XCTAssertFalse(driver.isAudioOnly)
    }

    func testLineSwitchOpensNewLine() {
        let factory = FakeBackendFactory()
        let resolver = LiveDriverFakeResolver()
        let firstURL = URL(string: "https://tx.flv.huya.com/room/1.flv")!
        let secondURL = URL(string: "https://al.flv.huya.com/room/1.flv")!
        resolver.resolutionsToReturn = [makeResolution(urls: [firstURL, secondURL])]
        let driver = makeDriver(factory: factory, resolver: resolver)
        var startCount = 0
        let startedOnce = expectation(description: "room started")
        driver.onRoomStarted = { _ in
            startCount += 1
            if startCount == 1 {
                startedOnce.fulfill()
            }
        }
        driver.play(item: LiveDriver.playbackItem(room: makeRoom()))
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentLineIndex, 0)
        let startedTwice = expectation(description: "room restarted on new line")
        driver.onRoomStarted = { _ in
            startCount += 1
            if startCount == 2 {
                startedTwice.fulfill()
            }
        }
        XCTAssertTrue(driver.switchLine(to: 1))
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentLineIndex, 1)
        XCTAssertFalse(driver.switchLine(to: 5))
    }

    func testQualitySwitchMismatchKeepsOldQuality() {
        // P0-09: the re-parse comes back for the OLD quality, so
        // the switch rolls back and the room keeps playing.
        let factory = FakeBackendFactory()
        let hd = LiveQuality(id: "1080p", name: "蓝光")
        let sd = LiveQuality(id: "720p", name: "高清")
        let resolver = LiveDriverFakeResolver()
        resolver.resolutionsToReturn = [
            makeResolution(urls: [URL(string: "https://tx.flv.huya.com/room/1.flv")!], quality: hd),
            makeResolution(urls: [URL(string: "https://tx.flv.huya.com/room/1.flv")!], quality: hd),
        ]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "room started")
        playRoom(driver: driver, started: started)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentQuality, hd)
        let switched = expectation(description: "quality switch answered")
        var switchResult: Bool?
        driver.switchQuality(to: sd) { ok in
            switchResult = ok
            switched.fulfill()
        }
        waitForExpectations(timeout: 2)
        XCTAssertEqual(switchResult, false)
        XCTAssertEqual(driver.currentQuality, hd)
    }

    func testStopClearsRoom() {
        let factory = FakeBackendFactory()
        let resolver = LiveDriverFakeResolver()
        resolver.resolutionsToReturn = [makeResolution(urls: [URL(string: "https://tx.flv.huya.com/room/1.flv")!])]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "room started")
        playRoom(driver: driver, started: started)
        waitForExpectations(timeout: 2)
        XCTAssertTrue(driver.isPlaying)
        driver.stop()
        XCTAssertNil(driver.currentRoom)
        XCTAssertFalse(driver.isPlaying)
        XCTAssertFalse(driver.isAudioOnly)
    }

    func testStaleResolveAfterReleaseDoesNotOpenAgainstReentry() {
        // B36 item 5 (live back-out crash): backing out of a
        // room releases the driver while its initial resolve is
        // still in flight; a late resolve from the exited room
        // must not open against the fresh re-entry. Without the
        // release() attempt-token bump (and the token check on
        // the resolve completion), the stale resolve passes the
        // pendingItem check — the re-entry re-set pendingItem
        // to the same room id — and opens the old URL, racing
        // the new resolve and churning backends mid-flight.
        let factory = FakeBackendFactory()
        let deferredMPV = FakeVideoBackend(engine: .mpv)
        deferredMPV.deferOpenCompletion = true
        factory.fakes = [.mpv: [deferredMPV]]
        let resolver = LiveDriverFakeResolver()
        resolver.deferResolve = true
        let driver = makeDriver(factory: factory, resolver: resolver)
        var failedError: MusicPlayerError?
        driver.onRoomFailed = { _, error in failedError = error }
        let started = expectation(description: "re-entered room started")
        driver.onRoomStarted = { _ in started.fulfill() }

        let room = makeRoom()
        let item = LiveDriver.playbackItem(room: room)
        let urls = [
            URL(string: "https://tx.flv.huya.com/room/1.flv")!,
            URL(string: "https://tx2.flv.huya.com/room/1.flv")!
        ]
        let resolution = makeResolution(urls: urls)

        // First entry: the resolve is still in flight.
        driver.play(item: item)
        XCTAssertEqual(resolver.deferredResolveCompletions.count, 1)

        // Back out mid-resolve (release is idempotent — the room
        // page's onDisappear path calls stop() then release()),
        // then immediately re-enter the same room; the
        // re-entry's resolve is still pending too.
        driver.release {}
        driver.release {}
        driver.configure(room: room, resolver: resolver)
        driver.play(item: item)
        XCTAssertEqual(resolver.deferredResolveCompletions.count, 2)

        // The exited room's resolve finally answers: it must be
        // ignored — no backend opens for it.
        resolver.deferredResolveCompletions.removeFirst()(.success(resolution))
        XCTAssertNil(failedError)
        XCTAssertNil(driver.currentRoom)
        XCTAssertEqual(deferredMPV.openCount, 0)

        // The re-entry's resolve answers and the room starts on
        // the (only) deferred backend.
        resolver.deferredResolveCompletions.removeFirst()(.success(resolution))
        XCTAssertEqual(deferredMPV.openCount, 1)
        XCTAssertNotNil(deferredMPV.deferredOpenCompletion)
        deferredMPV.deferredOpenCompletion?(true)
        waitForExpectations(timeout: 2)
        XCTAssertNil(failedError)
        XCTAssertTrue(driver.isPlaying)
        XCTAssertEqual(driver.currentRoom?.id, item.id)
    }

    // MARK: - Build 37 (D2 / D10 / D11)

    func testOpenWalksEveryResolvedLineBeforeFailing() {
        // D2: a room whose first two lines are dead but whose
        // third plays must PLAY — the old cap (2 tries) failed
        // it after the second line. FLV candidates are MPV then
        // IJK, so each dead line costs one MPV + one IJK attempt;
        // the third line opens on MPV.
        let factory = FakeBackendFactory()
        let mpvFail1 = FakeVideoBackend(engine: .mpv)
        mpvFail1.openResults = [false]
        let mpvFail2 = FakeVideoBackend(engine: .mpv)
        mpvFail2.openResults = [false]
        let mpvGood = FakeVideoBackend(engine: .mpv)
        let ijkFail1 = FakeVideoBackend(engine: .ijk)
        ijkFail1.openResults = [false]
        let ijkFail2 = FakeVideoBackend(engine: .ijk)
        ijkFail2.openResults = [false]
        factory.fakes = [
            .mpv: [mpvFail1, mpvFail2, mpvGood],
            .ijk: [ijkFail1, ijkFail2],
        ]
        let resolver = LiveDriverFakeResolver()
        resolver.resolutionsToReturn = [makeResolution(urls: [
            URL(string: "https://tx1.flv.huya.com/room/1.flv")!,
            URL(string: "https://tx2.flv.huya.com/room/1.flv")!,
            URL(string: "https://tx3.flv.huya.com/room/1.flv")!,
        ])]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "room started on third line")
        playRoom(driver: driver, started: started)
        waitForExpectations(timeout: 2)
        XCTAssertTrue(driver.isPlaying)
        XCTAssertEqual(mpvGood.openCount, 1)
        XCTAssertEqual(mpvGood.openedURLs, [URL(string: "https://tx3.flv.huya.com/room/1.flv")!])
        XCTAssertNil(driver.openFailure)
    }

    func testOpenFailureIsPublishedAndRetryReopens() {
        // D10: every line dead — the driver must publish the
        // failure (the room page renders it with a retry button)
        // instead of failing silently, and the retry must
        // re-open the room from a fresh resolve.
        let factory = FakeBackendFactory()
        let mpvFail = FakeVideoBackend(engine: .mpv)
        mpvFail.openResults = [false]
        let mpvGood = FakeVideoBackend(engine: .mpv)
        let ijkFail = FakeVideoBackend(engine: .ijk)
        ijkFail.openResults = [false]
        factory.fakes = [.mpv: [mpvFail, mpvGood], .ijk: [ijkFail]]
        let resolver = LiveDriverFakeResolver()
        let deadURL = URL(string: "https://tx.flv.huya.com/room/1.flv")!
        resolver.resolutionsToReturn = [
            makeResolution(urls: [deadURL]),
            makeResolution(urls: [deadURL]),
            makeResolution(urls: [deadURL]),
        ]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let failed = expectation(description: "room failed")
        var failure: MusicPlayerError?
        driver.onRoomFailed = { _, error in
            failure = error
            failed.fulfill()
        }
        driver.play(item: LiveDriver.playbackItem(room: makeRoom()))
        waitForExpectations(timeout: 2)
        XCTAssertEqual(failure, .loadFailed)
        XCTAssertEqual(driver.openFailure, .loadFailed)
        XCTAssertEqual(driver.openFailure?.localizedDescription, "播放失败，请检查网络后重试")
        XCTAssertNil(driver.currentRoom)
        // Retry: a fresh resolve answers and the room starts.
        let started = expectation(description: "room started on retry")
        driver.onRoomStarted = { _ in started.fulfill() }
        driver.retryCurrentRoom()
        waitForExpectations(timeout: 2)
        XCTAssertTrue(driver.isPlaying)
        XCTAssertNil(driver.openFailure)
        XCTAssertEqual(mpvGood.openCount, 1)
    }

    func testConfigureResetsQualityAndLine() {
        // D11: entering a room must clear the previous room's
        // tier — the footer showed the old room's quality and
        // the sheet highlighted a tier never resolved for the
        // new room.
        let factory = FakeBackendFactory()
        let mpv = FakeVideoBackend(engine: .mpv)
        factory.fakes = [.mpv: [mpv]]
        let resolver = LiveDriverFakeResolver()
        let quality = LiveQuality(id: "1000", name: "超清")
        resolver.resolutionsToReturn = [makeResolution(
            urls: [URL(string: "https://tx.flv.huya.com/room/1.flv")!],
            quality: quality
        )]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "room A started")
        playRoom(driver: driver, started: started)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentQuality?.id, "1000")
        XCTAssertEqual(driver.currentLineIndex, 0)
        driver.configure(
            room: LiveRoom(roomId: "456", platform: .huya, title: "B", streamer: "主播", onlineCount: 1, isLive: true),
            resolver: resolver
        )
        XCTAssertNil(driver.currentQuality)
        XCTAssertEqual(driver.currentLineIndex, 0)
        XCTAssertNil(driver.openFailure)
    }
}

// HAo Studio 2.0 — video player tests (S3, leg A).
//
// iOS-only, same treatment as S2's MusicPlayerTests: NOT wired
// into `ios/Package.swift` (this leg does not edit it). S7 wired
// the `HAoStudioTests` Xcode test target (run with `xcodebuild
// test` against an iOS simulator destination, or an equivalent
// iOS-capable run — `swift test` on a macOS runner cannot compile
// this target: UIKit / AVFoundation). The target has the app as
// its host and the tests `@testable import HAoStudio` for the
// Playback / Services types (Leg B added Services/Video to
// AppCore; no separate VideoServices target).
//
// The driver is driven through a fake backend and a fake
// resolver, never real engines: the open timeout uses a short
// injected interval, the watchdog uses an injected clock, and no
// test waits real 4 s / 12 s / 10 s.

import Foundation
import XCTest

@testable import HAoStudio

// MARK: - Fakes

/// Controllable stand-in for a VideoPlayerBackend. Open/seek
/// behaviour is a queue: each open pops the next entry, so a test
/// can say "AVPlayer fails, MPV succeeds".
final class FakeVideoBackend: VideoPlayerBackend {
    let engine: VideoEngine
    var onEvent: ((VideoBackendEvent) -> Void)?
    var onVideoSize: ((CGSize) -> Void)?

    var isPlaying: Bool = false
    var currentTime: Double = 0
    var duration: Double = 100
    var isPrepared: Bool = false
    var playbackRate: Double = 1
    var hardwareDecode: VideoHardwareDecodeState = .unknown
    var rejectedOptionNames: [String] = []

    var openResults: [Bool] = [true]
    var openedURLs: [URL] = []
    var openCount = 0
    var shutdownCount = 0
    /// Hold the open completion instead of calling it (timeout
    /// tests): the test fires `deferredOpenCompletion` later to
    /// simulate a backend that answers after the open timed out.
    var deferOpenCompletion = false
    var deferredOpenCompletion: ((Bool) -> Void)?
    var seekCalls: [Double] = []
    /// What the seek completion reports.
    var seekSucceeds: Bool = true
    /// Where the playhead lands after a seek (nil: the target).
    var seekLandsAt: Double?

    init(engine: VideoEngine) {
        self.engine = engine
    }

    var view: UIView { UIView() }

    func setVideoFit(_ fit: VideoFit) {}

    func open(url: URL, headers: [String: String], completion: @escaping (Bool) -> Void) {
        openedURLs.append(url)
        openCount += 1
        if deferOpenCompletion {
            deferredOpenCompletion = completion
            return
        }
        let ok = openResults.isEmpty ? true : openResults.removeFirst()
        isPrepared = ok
        isPlaying = ok
        if ok { onEvent?(.prepared) }
        completion(ok)
    }

    func play() { isPlaying = true }
    func pause() { isPlaying = false }

    func seek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        seekCalls.append(seconds)
        if seekSucceeds {
            currentTime = seekLandsAt ?? seconds
        }
        completion(seekSucceeds)
    }

    func shutdown() {
        shutdownCount += 1
        isPlaying = false
        isPrepared = false
    }
}

/// One fake backend per engine, in order: each `makeBackend`
/// call pops the next fake for that engine, so a test can say
/// "the first AVPlayer open fails, the second succeeds".
final class FakeBackendFactory {
    var fakes: [VideoEngine: [FakeVideoBackend]] = [:]

    func makeBackend(engine: VideoEngine) -> VideoPlayerBackend {
        if var queue = fakes[engine], !queue.isEmpty {
            let fake = queue.removeFirst()
            fakes[engine] = queue
            return fake
        }
        return FakeVideoBackend(engine: engine)
    }
}

/// Controllable stand-in for VideoPlayURLResolver.
final class FakeVideoResolver: VideoPlayURLResolver {
    var urlsToReturn: [URL?] = []
    var receivedExcluding: [[URL]] = []

    func resolvePlayURL(
        detail: VideoDetail,
        episode: PlayEpisode,
        line: PlayLine,
        excluding: [URL],
        completion: @escaping (URL?) -> Void
    ) {
        receivedExcluding.append(excluding)
        let url = urlsToReturn.isEmpty ? nil : urlsToReturn.removeFirst()
        completion(url)
    }
}

// MARK: - Shared fixtures

func makeTestDetail() -> (detail: VideoDetail, line: PlayLine, episode: PlayEpisode) {
    let item = VideoItem(id: "1", title: "Test Movie", coverURL: nil, year: "2024", typeName: nil, remarks: nil, sourceId: nil)
    let episode1 = PlayEpisode(name: "第01集", url: nil, index: 0)
    let episode2 = PlayEpisode(name: "第02集", url: nil, index: 1)
    let line = PlayLine(name: "线路1", episodes: [episode1, episode2])
    let detail = VideoDetail(item: item, lines: [line], meta: nil)
    return (detail, line, episode1)
}

// MARK: - Watchdog

final class VodStallWatchdogTests: XCTestCase {
    func testWarnAt4FailAt12() {
        let watchdog = VodStallWatchdog()
        var now = Date()
        watchdog.now = { now }
        watchdog.resetForNewEpisode()
        XCTAssertEqual(watchdog.tick(position: 0, duration: 100, isPlaying: true), .none)
        now = now.addingTimeInterval(3)
        XCTAssertEqual(watchdog.tick(position: 0, duration: 100, isPlaying: true), .none)
        now = now.addingTimeInterval(2)
        XCTAssertEqual(watchdog.tick(position: 0, duration: 100, isPlaying: true), .warn)
        // Warn fires once per stall episode.
        now = now.addingTimeInterval(1)
        XCTAssertEqual(watchdog.tick(position: 0, duration: 100, isPlaying: true), .none)
        now = now.addingTimeInterval(7)
        XCTAssertEqual(watchdog.tick(position: 0, duration: 100, isPlaying: true), .failed)
    }

    func testMovementResetsClock() {
        let watchdog = VodStallWatchdog()
        var now = Date()
        watchdog.now = { now }
        watchdog.resetForNewEpisode()
        now = now.addingTimeInterval(5)
        XCTAssertEqual(watchdog.tick(position: 0, duration: 100, isPlaying: true), .warn)
        XCTAssertEqual(watchdog.tick(position: 1, duration: 100, isPlaying: true), .none)
        now = now.addingTimeInterval(5)
        XCTAssertEqual(watchdog.tick(position: 1, duration: 100, isPlaying: true), .warn)
    }

    func testFrozenAtEndAdvancesInsteadOfFailing() {
        let watchdog = VodStallWatchdog()
        var now = Date()
        watchdog.now = { now }
        watchdog.resetForNewEpisode()
        _ = watchdog.tick(position: 100, duration: 100, isPlaying: true)
        now = now.addingTimeInterval(13)
        XCTAssertEqual(watchdog.tick(position: 100, duration: 100, isPlaying: true), .atEnd)
    }

    func testPausedNeverWarns() {
        let watchdog = VodStallWatchdog()
        var now = Date()
        watchdog.now = { now }
        watchdog.resetForNewEpisode()
        now = now.addingTimeInterval(20)
        XCTAssertEqual(watchdog.tick(position: 0, duration: 100, isPlaying: false), .none)
    }
}

// MARK: - Recovery ladder

final class VideoRecoveryLadderTests: XCTestCase {
    func testFirstSuccessWins() {
        let callsBox = CallsBox()
        let ladder = VideoRecoveryLadder(
            engines: [.mpv, .avplayer],
            urls: [URL(string: "https://a.b/1.mp4")!],
            attempt: { engine, url, completion in
                callsBox.calls.append((engine, url))
                completion(engine == .avplayer)
            }
        )
        let exp = expectation(description: "ladder completes")
        ladder.run { winner in
            XCTAssertEqual(winner?.0, .avplayer)
            XCTAssertEqual(callsBox.calls.count, 2)
            XCTAssertEqual(ladder.status, .completed)
            exp.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    func testEachPairTriedOnceThenExhausted() {
        let callsBox = CallsBox()
        let ladder = VideoRecoveryLadder(
            engines: [.mpv, .ijk],
            urls: [URL(string: "https://a.b/1.mp4")!, URL(string: "https://a.b/2.mp4")!],
            attempt: { engine, url, completion in
                callsBox.calls.append((engine, url))
                completion(false)
            }
        )
        let exp = expectation(description: "ladder exhausts")
        ladder.run { winner in
            XCTAssertNil(winner)
            XCTAssertEqual(callsBox.calls.count, 4)
            XCTAssertEqual(ladder.status, .exhausted)
            exp.fulfill()
        }
        waitForExpectations(timeout: 2)
        // A second run tries nothing: every pair is already spent.
        let exp2 = expectation(description: "second run exhausts at once")
        ladder.run { winner in
            XCTAssertNil(winner)
            XCTAssertEqual(callsBox.calls.count, 4)
            exp2.fulfill()
        }
        waitForExpectations(timeout: 2)
        // Healthy playback resets the budget: pairs are tryable again.
        ladder.resetBudget()
        let exp3 = expectation(description: "run after reset retries")
        ladder.run { winner in
            XCTAssertNil(winner)
            XCTAssertEqual(callsBox.calls.count, 8)
            exp3.fulfill()
        }
        waitForExpectations(timeout: 2)
    }
}

private final class CallsBox {
    var calls: [(VideoEngine, URL)] = []
}

// MARK: - Gesture math + FPS math + diagnostics

final class VodGestureMathTests: XCTestCase {
    func testDoubleTapSeekSides() {
        XCTAssertEqual(VodGestureMath.seekDelta(x: 10, width: 300), -10)
        XCTAssertEqual(VodGestureMath.seekDelta(x: 290, width: 300), 10)
        XCTAssertEqual(VodGestureMath.seekDelta(x: 150, width: 300), 0)
        XCTAssertEqual(VodGestureMath.seekDelta(x: 10, width: 0), 0)
    }

    func testLongPressSpeedIsVodOnly() {
        XCTAssertEqual(VodGestureMath.longPressSpeed(isPressing: true, isVod: true), 2.0)
        XCTAssertNil(VodGestureMath.longPressSpeed(isPressing: true, isVod: false))
        XCTAssertNil(VodGestureMath.longPressSpeed(isPressing: false, isVod: true))
    }

    func testGestureStateGatesLive() {
        let state = VodGestureState()
        state.isVod = false
        var changed: [Bool] = []
        state.onLongPressSpeedChanged = { changed.append($0) }
        state.longPressBegan()
        XCTAssertFalse(state.isLongPressSpeeding)
        XCTAssertTrue(changed.isEmpty)
        state.isVod = true
        state.longPressBegan()
        XCTAssertTrue(state.isLongPressSpeeding)
        XCTAssertEqual(changed, [true])
        state.longPressEnded()
        XCTAssertFalse(state.isLongPressSpeeding)
        XCTAssertEqual(changed, [true, false])
    }
}

final class VideoFpsMathTests: XCTestCase {
    func testFps() {
        XCTAssertEqual(VideoFpsMath.fps(frameCount: 60, over: 1.0), 60)
        XCTAssertEqual(VideoFpsMath.fps(frameCount: 30, over: 0.5), 60)
        XCTAssertEqual(VideoFpsMath.fps(frameCount: 0, over: 0), 0)
    }

    func testDroppedFrames() {
        // 60 fps expected interval is 1/60; an interval over 1.5x
        // counts as a dropped frame.
        XCTAssertEqual(VideoFpsMath.droppedFrames(intervals: [1.0 / 60, 1.0 / 60], expectedInterval: 1.0 / 60), 0)
        XCTAssertEqual(VideoFpsMath.droppedFrames(intervals: [1.0 / 60, 0.05], expectedInterval: 1.0 / 60), 1)
    }
}

final class VideoDiagnosticsTests: XCTestCase {
    func testHardwareDecodeLabels() {
        XCTAssertEqual(VideoHardwareDecodeState.software.label, "软解中")
        XCTAssertTrue(VideoHardwareDecodeState.software.isSoftware)
        XCTAssertFalse(VideoHardwareDecodeState.hardware(decoder: "videotoolbox").isSoftware)
        XCTAssertTrue(VideoHardwareDecodeState.hardware(decoder: "videotoolbox").isVerifiedHardware)
        XCTAssertFalse(VideoHardwareDecodeState.assumedHardware(decoder: "videotoolbox").isVerifiedHardware)
        XCTAssertTrue(VideoHardwareDecodeState.assumedHardware(decoder: "videotoolbox").label.contains("未验证"))
    }

    func testSummarySpellsOutSoftwareDecode() {
        let diag = VideoPlaybackDiagnostics(
            engine: .mpv, hardwareDecode: .software, rejectedOptionNames: ["framedrop"],
            fps: 24, droppedFrames: 2, facts: nil, fellBackForSoftwareDecode: false
        )
        XCTAssertTrue(diag.summaryLine.contains("软解中"))
        XCTAssertTrue(diag.detailLines.contains { $0.contains("被拒属性") })
        let fellBack = VideoPlaybackDiagnostics(
            engine: .avplayer, hardwareDecode: .hardware(decoder: "VideoToolbox"),
            rejectedOptionNames: [], fps: 60, droppedFrames: 0, facts: nil, fellBackForSoftwareDecode: true
        )
        XCTAssertTrue(fellBack.summaryLine.contains("已切系统播放器"))
    }

    func testDanmakuColorParsing() {
        // Color has no Equatable conformance, so this is a smoke
        // test: every input (empty, malformed, valid) must parse
        // without crashing and return a colour.
        _ = Color.danmakuColor(hex: "")
        _ = Color.danmakuColor(hex: "zzz")
        _ = Color.danmakuColor(hex: "ff0000")
        _ = Color.danmakuColor(hex: "00ff00")
    }
}

// MARK: - Danmaku layer state

/// Controllable stand-in for VodDanmakuProvider.
final class FakeDanmakuProvider: VodDanmakuProvider {
    var items: [DanmakuItem]

    init(items: [DanmakuItem]) {
        self.items = items
    }

    func fetchDanmaku(for episode: PlayEpisode, completion: @escaping ([DanmakuItem]) -> Void) {
        completion(items)
    }
}

final class VodDanmakuLayerStateTests: XCTestCase {
    func testLoadWithNilProviderLeavesEmpty() {
        let state = VodDanmakuLayerState()
        state.load(for: PlayEpisode(name: "第01集", url: nil, index: 0), provider: nil)
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertTrue(state.visibleItems(at: 10).isEmpty)
    }

    func testVisibleWindow() {
        let state = VodDanmakuLayerState()
        let provider = FakeDanmakuProvider(items: [
            DanmakuItem(text: "scrolling fresh", timeSeconds: 10, colorHex: "", isTop: false),
            DanmakuItem(text: "scrolling stale", timeSeconds: 2, colorHex: "", isTop: false),
            DanmakuItem(text: "top fresh", timeSeconds: 10, colorHex: "", isTop: true),
            DanmakuItem(text: "top stale", timeSeconds: 5, colorHex: "", isTop: true),
        ])
        state.load(for: PlayEpisode(name: "第01集", url: nil, index: 0), provider: provider)
        let checked = expectation(description: "items loaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let visible = state.visibleItems(at: 12).map { $0.item.text }
            XCTAssertTrue(visible.contains("scrolling fresh"))
            XCTAssertFalse(visible.contains("scrolling stale"))
            XCTAssertTrue(visible.contains("top fresh"))
            XCTAssertFalse(visible.contains("top stale"))
            checked.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    func testReloadingSameEpisodeIsNoop() {
        let state = VodDanmakuLayerState()
        let provider = FakeDanmakuProvider(items: [
            DanmakuItem(text: "one", timeSeconds: 1, colorHex: "", isTop: false),
        ])
        let episode = PlayEpisode(name: "第01集", url: nil, index: 0)
        state.load(for: episode, provider: provider)
        state.load(for: episode, provider: provider)
        let checked = expectation(description: "items loaded once")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(state.items.count, 1)
            checked.fulfill()
        }
        waitForExpectations(timeout: 2)
    }
}

// MARK: - Driver with fakes

final class VideoDriverTests: XCTestCase {
    private func makeDriver(
        factory: FakeBackendFactory,
        resolver: FakeVideoResolver
    ) -> VideoDriver {
        let driver = VideoDriver()
        driver.makeBackend = { factory.makeBackend(engine: $0) }
        driver.playURLResolver = resolver
        driver.openTimeoutInterval = 5
        return driver
    }

    func testPlayStartsEpisode() {
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let resolver = FakeVideoResolver()
        let url = URL(string: "https://a.b/movie.mp4")!
        resolver.urlsToReturn = [url]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "episode started")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentEpisode?.id, VideoResumeKey.episodeId(title: "Test Movie", year: "2024", episodeName: "第01集"))
        XCTAssertEqual(driver.currentEngine, .avplayer)
        XCTAssertTrue(driver.isPlaying)
    }

    func testEngineFallbackOnOpenFailure() {
        // MP4: candidates are AVPlayer, MPV, IJK. AVPlayer fails,
        // MPV succeeds — the driver plays on MPV, never an error.
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let failingAV = FakeVideoBackend(engine: .avplayer)
        failingAV.openResults = [false]
        let goodMPV = FakeVideoBackend(engine: .mpv)
        factory.fakes = [.avplayer: [failingAV], .mpv: [goodMPV]]
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [URL(string: "https://a.b/movie.mp4")!]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "episode started on MPV")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentEngine, .mpv)
        XCTAssertEqual(failingAV.openCount, 1)
        XCTAssertEqual(goodMPV.openCount, 1)
        XCTAssertEqual(goodMPV.shutdownCount, 0)
        XCTAssertEqual(failingAV.shutdownCount, 1)
    }

    func testFailedURLIsNeverRetried() {
        // The first URL fails on every engine; the fallback resolve
        // must receive it in `excluding` and hand out a fresh URL.
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let deadURL = URL(string: "https://a.b/dead.mp4")!
        let freshURL = URL(string: "https://a.b/fresh.mp4")!
        // Every backend fails the dead URL (all three engines).
        for engine in VideoEngine.allCases {
            let fake = FakeVideoBackend(engine: engine)
            fake.openResults = [false]
            factory.fakes[engine] = [fake]
        }
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [deadURL, freshURL]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "episode started on fresh URL")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(resolver.receivedExcluding.count, 2)
        XCTAssertEqual(resolver.receivedExcluding[1], [deadURL])
    }

    func testSoftwareDecodeFallsBackToAVPlayer() {
        // 4K HEVC MP4: AVPlayer fails transiently, MPV opens but
        // reads back software decode -> the driver reopens on
        // AVPlayer at the same position.
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let failingAV = FakeVideoBackend(engine: .avplayer)
        failingAV.openResults = [false]
        let softMPV = FakeVideoBackend(engine: .mpv)
        softMPV.hardwareDecode = .software
        let goodAV = FakeVideoBackend(engine: .avplayer)
        factory.fakes = [.avplayer: [failingAV, goodAV], .mpv: [softMPV]]
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [URL(string: "https://a.b/movie.mp4?hao_container=mp4&hao_vcodec=hevc&hao_width=3840&hao_height=2160")!]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "episode started on AVPlayer after fallback")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentEngine, .avplayer)
        XCTAssertTrue(driver.diagnostics.fellBackForSoftwareDecode)
        XCTAssertEqual(goodAV.openCount, 1)
        XCTAssertEqual(softMPV.shutdownCount, 1)
    }

    func testSoftwareDecodeOfMkvStaysPutAndIsLabelled() {
        // 4K HEVC MKV: MPV opens soft, but AVPlayer cannot play
        // MKV — the driver stays on MPV and labels it "软解中".
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let softMPV = FakeVideoBackend(engine: .mpv)
        softMPV.hardwareDecode = .software
        factory.fakes = [.mpv: [softMPV]]
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [URL(string: "https://a.b/movie.mkv?hao_container=mkv&hao_vcodec=hevc&hao_width=3840&hao_height=2160")!]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "episode started on MPV")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentEngine, .mpv)
        XCTAssertFalse(driver.diagnostics.fellBackForSoftwareDecode)
        XCTAssertTrue(driver.diagnostics.hardwareDecode.isSoftware)
        XCTAssertTrue(driver.diagnostics.summaryLine.contains("软解中"))
    }

    func testSeekFailureRollsBackToActualPosition() {
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let backend = FakeVideoBackend(engine: .avplayer)
        factory.fakes = [.avplayer: [backend]]
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [URL(string: "https://a.b/movie.mp4")!]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "episode started")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        backend.currentTime = 5
        backend.seekSucceeds = false
        let seekDone = expectation(description: "seek reports failure")
        driver.seek(to: 30) { ok in
            XCTAssertFalse(ok)
            seekDone.fulfill()
        }
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.position, 5)
    }

    func testStopSavesBreakpoint() {
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let backend = FakeVideoBackend(engine: .avplayer)
        factory.fakes = [.avplayer: [backend]]
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [URL(string: "https://a.b/movie.mp4")!]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "episode started")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        // Simulate playback progress through the position timer.
        backend.currentTime = 120
        let saved = expectation(description: "breakpoint saved")
        driver.onBreakpointSaved = { info in
            XCTAssertEqual(info.episodeName, "第01集")
            XCTAssertEqual(info.episodeIndex, 0)
            XCTAssertEqual(info.positionSeconds, 120, accuracy: 1)
            XCTAssertEqual(info.key, "Test Movie-2024")
            saved.fulfill()
        }
        // The 0.5 s position timer publishes the backend position.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            driver.stop()
        }
        waitForExpectations(timeout: 3)
        XCTAssertNil(driver.currentEpisode)
    }

    func testLineSwitchKeepsPosition() {
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let backend = FakeVideoBackend(engine: .avplayer)
        factory.fakes = [.avplayer: [backend]]
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [
            URL(string: "https://a.b/movie.mp4")!,
            URL(string: "https://a.b/movie-line2.mp4")!,
        ]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "episode started")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        // Move to 60 s (seek succeeds on the fake), then switch line:
        // the new open must resume at 60, not from 0.
        let sought = expectation(description: "seek landed")
        driver.seek(to: 60) { ok in
            XCTAssertTrue(ok)
            sought.fulfill()
        }
        waitForExpectations(timeout: 2)
        let line2 = PlayLine(name: "线路2", episodes: line.episodes)
        driver.switchLine(to: line2)
        // The resume seek on the new backend targets ~60.
        let resumed = expectation(description: "resumed on new line")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertTrue(backend.seekCalls.contains { abs($0 - 60) <= 2.0 })
            resumed.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    func testAutoNextOffStopsAdvanceOnNaturalEnd() {
        // b35 sweep: the stored hao_video_auto_next switch used to
        // gate only the view model's poll-tick advance; a natural
        // end (.finished) still advanced in the driver.
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let backend = FakeVideoBackend(engine: .avplayer)
        factory.fakes = [.avplayer: [backend]]
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [
            URL(string: "https://a.b/movie.mp4")!,
            URL(string: "https://a.b/movie2.mp4")!,
        ]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let suite = UserDefaults(suiteName: "hao.test.b35.autonext")!
        suite.removePersistentDomain(forName: "hao.test.b35.autonext")
        suite.set(false, forKey: SettingsStore.autoNextEpisodeKey)
        driver.defaults = suite
        let started = expectation(description: "episode started")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        let ended = expectation(description: "episode ended without advancing")
        driver.onEpisodeEnded = { _ in ended.fulfill() }
        backend.onEvent?(.finished(.ended))
        waitForExpectations(timeout: 2)
        XCTAssertNil(driver.currentEpisode)
        XCTAssertEqual(backend.openCount, 1)
        suite.removePersistentDomain(forName: "hao.test.b35.autonext")
    }

    func testAutoNextOnAdvancesOnNaturalEnd() {
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let backend = FakeVideoBackend(engine: .avplayer)
        factory.fakes = [.avplayer: [backend]]
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [
            URL(string: "https://a.b/movie.mp4")!,
            URL(string: "https://a.b/movie2.mp4")!,
        ]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let suite = UserDefaults(suiteName: "hao.test.b35.autonext")!
        suite.removePersistentDomain(forName: "hao.test.b35.autonext")
        driver.defaults = suite
        let started = expectation(description: "episode started")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        let advanced = expectation(description: "advanced to episode 2")
        driver.onEpisodeStarted = { item in
            if item.id == VideoResumeKey.episodeId(title: "Test Movie", year: "2024", episodeName: "第02集") {
                advanced.fulfill()
            }
        }
        backend.onEvent?(.finished(.ended))
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentEpisode?.id, VideoResumeKey.episodeId(title: "Test Movie", year: "2024", episodeName: "第02集"))
        suite.removePersistentDomain(forName: "hao.test.b35.autonext")
    }

    func testFailedOpenSetsAndClearsLoadFailedFlag() {
        // b35 sweep: the player page shows the failure + retry
        // from this flag; a fresh open clears it.
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [nil]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let failed = expectation(description: "episode failed")
        driver.onEpisodeFailed = { _, _ in failed.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertTrue(driver.lastOpenFailed)
        resolver.urlsToReturn = [URL(string: "https://a.b/movie.mp4")!]
        let started = expectation(description: "episode started on retry")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertFalse(driver.lastOpenFailed)
    }

    func testTimeoutInvalidatesLateReopen() {
        // b35 sweep: the soft-decode reopen (reopenOnAVPlayer)
        // only checked the generation, not the open's completed
        // flag - a backend that answered after the 10 s open
        // timeout still ran finishStartPlayback (play + publish),
        // so the player showed "load failed" while the video
        // actually played behind it. The timeout now bumps the
        // generation, so the late reopen returns early instead.
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let failingAV = FakeVideoBackend(engine: .avplayer)
        failingAV.openResults = [false]
        let softMPV = FakeVideoBackend(engine: .mpv)
        softMPV.hardwareDecode = .software
        let goodAV = FakeVideoBackend(engine: .avplayer)
        goodAV.deferOpenCompletion = true
        factory.fakes = [.avplayer: [failingAV, goodAV], .mpv: [softMPV]]
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [URL(string: "https://a.b/movie.mp4?hao_container=mp4&hao_vcodec=hevc&hao_width=3840&hao_height=2160")!]
        let driver = makeDriver(factory: factory, resolver: resolver)
        driver.openTimeoutInterval = 0.1
        let failed = expectation(description: "open timed out")
        driver.onEpisodeFailed = { _, error in
            XCTAssertEqual(error, .timeout)
            failed.fulfill()
        }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertTrue(driver.lastOpenFailed)
        XCTAssertNil(driver.currentEpisode)
        // The AVPlayer reopen answers late with success: it must
        // be ignored, never played or published.
        goodAV.deferredOpenCompletion?(true)
        let checked = expectation(description: "late reopen handled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertFalse(goodAV.isPlaying)
            XCTAssertNil(driver.currentEpisode)
            XCTAssertFalse(driver.isPlaying)
            checked.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

}

// MARK: - S7 wiring: VOD settings (leg A)

/// Controllable stand-in for a backend WITH the VOD wiring
/// capabilities (the MPV shape): records subtitle appearance,
/// enhancement branch, dialogue boost and audio-only calls so
/// the driver tests can assert forwarding without a real engine.
/// (Build 36, item 14, G-F/G-G) Also stands in for the track
/// list + external subtitles: it publishes the configured track
/// lists on open and records `aid` / `sid` selections and
/// `sub-add` calls.
final class CapableFakeBackend: VideoPlayerBackend, VodSubtitleAppearanceCapable, VodEnhancementCapable, DialogueBoostCapable, LiveAudioOnlyCapable, VodTrackListCapable, VodExternalSubtitleCapable {
    let engine: VideoEngine
    var onEvent: ((VideoBackendEvent) -> Void)?
    var onVideoSize: ((CGSize) -> Void)?

    var isPlaying: Bool = false
    var currentTime: Double = 0
    var duration: Double = 100
    var isPrepared: Bool = false
    var playbackRate: Double = 1
    var hardwareDecode: VideoHardwareDecodeState = .unknown
    var rejectedOptionNames: [String] = []

    var subtitleCalls: [VodSubtitleAppearance] = []
    var enhancementCalls: [VodEnhancementBranch?] = []
    var dialogueBoostCalls: [Bool] = []
    var audioOnlyCalls: [Bool] = []
    var audioTracksToPublish: [VodTrackInfo] = []
    var subtitleTracksToPublish: [VodTrackInfo] = []
    var onTracksChanged: (([VodTrackInfo], [VodTrackInfo]) -> Void)?
    var selectAudioCalls: [Int] = []
    var selectSubtitleCalls: [Int] = []
    var addedSubtitles: [URL] = []

    var audioTracks: [VodTrackInfo] { audioTracksToPublish }
    var subtitleTracks: [VodTrackInfo] { subtitleTracksToPublish }

    init(engine: VideoEngine) {
        self.engine = engine
    }

    var view: UIView { UIView() }

    func setVideoFit(_ fit: VideoFit) {}

    func open(url: URL, headers: [String: String], completion: @escaping (Bool) -> Void) {
        isPrepared = true
        isPlaying = true
        onEvent?(.prepared)
        onTracksChanged?(audioTracksToPublish, subtitleTracksToPublish)
        completion(true)
    }

    func play() { isPlaying = true }
    func pause() { isPlaying = false }

    func seek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        currentTime = seconds
        completion(true)
    }

    func shutdown() {
        isPlaying = false
        isPrepared = false
    }

    func setSubtitleAppearance(fontSize: Int, color: String, position: Double) {
        subtitleCalls.append(VodSubtitleAppearance(fontSize: fontSize, color: color, position: position))
    }

    func setVodEnhancement(_ branch: VodEnhancementBranch?) {
        enhancementCalls.append(branch)
    }

    func setDialogueBoost(_ enabled: Bool) {
        dialogueBoostCalls.append(enabled)
    }

    func setAudioOnly(_ audioOnly: Bool) {
        audioOnlyCalls.append(audioOnly)
    }

    func selectAudioTrack(index: Int) {
        selectAudioCalls.append(index)
    }

    func selectSubtitleTrack(index: Int) {
        selectSubtitleCalls.append(index)
    }

    func addSubtitle(url: URL, language: String?) {
        addedSubtitles.append(url)
    }
}

final class VodWiringDriverTests: XCTestCase {
    private func makeDriver(
        factory: FakeBackendFactory,
        resolver: FakeVideoResolver
    ) -> VideoDriver {
        let driver = VideoDriver()
        driver.makeBackend = { factory.makeBackend(engine: $0) }
        driver.playURLResolver = resolver
        driver.openTimeoutInterval = 5
        return driver
    }

    /// Dolby Vision profile 8 in an Apple container (Emby
    /// `hao_*` markers), the only stream the DV-P8 switch routes.
    private func p8URL() -> URL {
        URL(string: "https://a.b/movie.mp4?hao_container=mp4&hao_dv=1&hao_dvprofile=8")!
    }

    func testDvP8DowngradeOnAdmitsAVPlayerForP8() {
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [p8URL()]
        let driver = makeDriver(factory: factory, resolver: resolver)
        driver.dvP8Downgrade = true
        var attempted: [VideoEngine] = []
        let previousMake = driver.makeBackend
        driver.makeBackend = { engine in
            attempted.append(engine)
            return previousMake(engine)
        }
        let started = expectation(description: "episode started")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(attempted.first, .avplayer)
        XCTAssertEqual(driver.currentEngine, .avplayer)
    }

    func testDvP8DowngradeOffKeepsP8OnFfmpeg() {
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [p8URL()]
        let driver = makeDriver(factory: factory, resolver: resolver)
        driver.dvP8Downgrade = false
        var attempted: [VideoEngine] = []
        let previousMake = driver.makeBackend
        driver.makeBackend = { engine in
            attempted.append(engine)
            return previousMake(engine)
        }
        let started = expectation(description: "episode started")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(attempted.first, .mpv)
        XCTAssertEqual(driver.currentEngine, .mpv)
    }

    func testDvP8ReopenSwitchesP8ToMpv() {
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [p8URL(), p8URL()]
        let driver = makeDriver(factory: factory, resolver: resolver)
        driver.dvP8Downgrade = true
        let startedTwice = expectation(description: "episode started twice")
        startedTwice.expectedFulfillmentCount = 2
        var starts = 0
        driver.onEpisodeStarted = { _ in
            starts += 1
            if starts == 1 {
                driver.dvP8Downgrade = false
                XCTAssertTrue(driver.reopenAtCurrentPosition())
            }
            startedTwice.fulfill()
        }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(driver.currentEngine, .mpv)
    }

    func testReopenAtCurrentPositionNoopsForNonP8() {
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let backend = FakeVideoBackend(engine: .avplayer)
        factory.fakes = [.avplayer: [backend]]
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [URL(string: "https://a.b/movie.mp4")!]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "episode started")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertFalse(driver.reopenAtCurrentPosition())
        XCTAssertEqual(backend.openCount, 1)
    }

    func testSubtitleAndEnhancementAppliedAtOpenAndLive() {
        let (detail, line, episode) = makeTestDetail()
        let backend = CapableFakeBackend(engine: .avplayer)
        let driver = VideoDriver()
        driver.makeBackend = { _ in backend }
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [URL(string: "https://a.b/movie.mp4")!]
        driver.playURLResolver = resolver
        driver.openTimeoutInterval = 5
        // Set before the backend exists: stored, applied at open.
        driver.applyVodEnhancement(.interpolation)
        driver.setSubtitleAppearance(VodSubtitleAppearance(fontSize: 70, color: "#FFFF00", position: 50.0))
        XCTAssertEqual(driver.currentEnhancement, .interpolation)
        XCTAssertEqual(driver.currentSubtitleAppearance, VodSubtitleAppearance(fontSize: 70, color: "#FFFF00", position: 50.0))
        let started = expectation(description: "episode started")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(backend.enhancementCalls, [.interpolation])
        XCTAssertEqual(backend.subtitleCalls, [VodSubtitleAppearance(fontSize: 70, color: "#FFFF00", position: 50.0)])
        // Live toggle: applied at once, no reopen.
        driver.applyVodEnhancement(nil)
        driver.setSubtitleAppearance(.default)
        XCTAssertEqual(backend.enhancementCalls, [.interpolation, nil])
        XCTAssertEqual(backend.subtitleCalls, [VodSubtitleAppearance(fontSize: 70, color: "#FFFF00", position: 50.0), .default])
    }

    func testAudioOnlyForwardedToCapableBackend() {
        let (detail, line, episode) = makeTestDetail()
        let backend = CapableFakeBackend(engine: .mpv)
        let driver = VideoDriver()
        driver.makeBackend = { _ in backend }
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [URL(string: "https://a.b/movie.mp4")!]
        driver.playURLResolver = resolver
        driver.openTimeoutInterval = 5
        let started = expectation(description: "episode started")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        driver.setAudioOnly(true)
        XCTAssertTrue(driver.isAudioOnly)
        XCTAssertEqual(backend.audioOnlyCalls, [true])
        driver.setAudioOnly(false)
        XCTAssertFalse(driver.isAudioOnly)
        XCTAssertEqual(backend.audioOnlyCalls, [true, false])
    }

    func testAudioOnlyNoopsOnIncapableBackend() {
        // The AVPlayer/IJK shape: no capability, the flag is still
        // stored and nothing crashes (their audio keeps playing in
        // background natively).
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let backend = FakeVideoBackend(engine: .avplayer)
        factory.fakes = [.avplayer: [backend]]
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [URL(string: "https://a.b/movie.mp4")!]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "episode started")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        driver.setAudioOnly(true)
        XCTAssertTrue(driver.isAudioOnly)
    }
}

final class VodGestureStepTests: XCTestCase {
    func testDoubleTapSeekUsesConfiguredStep() {
        XCTAssertEqual(VodGestureMath.seekDelta(x: 10, width: 300, seconds: 30), -30)
        XCTAssertEqual(VodGestureMath.seekDelta(x: 290, width: 300, seconds: 30), 30)
        XCTAssertEqual(VodGestureMath.seekDelta(x: 150, width: 300, seconds: 30), 0)
        // The default is still the 10 s step (existing callers).
        XCTAssertEqual(VodGestureMath.seekDelta(x: 10, width: 300), -10)
    }
}

// MARK: - Player controls round (2026-11-24, chen build-33 report
// items 3/4/5/9): seek-bar math, danmaku availability, danmaku
// layer loading flags, live overlay backlog cap, 2x speed restore.

final class VideoSeekBarMathTests: XCTestCase {
    func testPositionFromTouch() {
        XCTAssertEqual(VideoSeekBarMath.position(forX: 0, totalWidth: 300, duration: 100), 0)
        XCTAssertEqual(VideoSeekBarMath.position(forX: 150, totalWidth: 300, duration: 100), 50)
        XCTAssertEqual(VideoSeekBarMath.position(forX: 300, totalWidth: 300, duration: 100), 100)
        // Off either end clamps, never overshoots.
        XCTAssertEqual(VideoSeekBarMath.position(forX: 400, totalWidth: 300, duration: 100), 100)
        XCTAssertEqual(VideoSeekBarMath.position(forX: -10, totalWidth: 300, duration: 100), 0)
        // Degenerate inputs are 0, never NaN.
        XCTAssertEqual(VideoSeekBarMath.position(forX: 150, totalWidth: 0, duration: 100), 0)
        XCTAssertEqual(VideoSeekBarMath.position(forX: 150, totalWidth: 300, duration: 0), 0)
    }

    func testFillWidth() {
        XCTAssertEqual(VideoSeekBarMath.fillWidth(position: 50, duration: 100, totalWidth: 300), 150)
        XCTAssertEqual(VideoSeekBarMath.fillWidth(position: 0, duration: 100, totalWidth: 300), 0)
        XCTAssertEqual(VideoSeekBarMath.fillWidth(position: 100, duration: 100, totalWidth: 300), 300)
        XCTAssertEqual(VideoSeekBarMath.fillWidth(position: 150, duration: 100, totalWidth: 300), 300)
        XCTAssertEqual(VideoSeekBarMath.fillWidth(position: 50, duration: 0, totalWidth: 300), 0)
    }

    func testPreviewBubbleStaysInside() {
        XCTAssertEqual(VideoSeekBarMath.previewCenterX(knobX: 150, totalWidth: 300, bubbleWidth: 72), 150)
        // Left edge: centre never closer than half the bubble.
        XCTAssertEqual(VideoSeekBarMath.previewCenterX(knobX: 0, totalWidth: 300, bubbleWidth: 72), 36)
        // Right edge: same clamp on the other side.
        XCTAssertEqual(VideoSeekBarMath.previewCenterX(knobX: 300, totalWidth: 300, bubbleWidth: 72), 264)
        // Bar narrower than the bubble: centre it.
        XCTAssertEqual(VideoSeekBarMath.previewCenterX(knobX: 150, totalWidth: 60, bubbleWidth: 72), 30)
    }
}

final class VodDanmakuAvailabilityTests: XCTestCase {
    func testResolve() {
        XCTAssertEqual(
            VodDanmakuAvailability.resolve(isLoading: true, didLoad: false, itemCount: 0), .loading)
        XCTAssertEqual(
            VodDanmakuAvailability.resolve(isLoading: false, didLoad: false, itemCount: 0), .loading)
        XCTAssertEqual(
            VodDanmakuAvailability.resolve(isLoading: false, didLoad: true, itemCount: 0), .unavailable)
        XCTAssertEqual(
            VodDanmakuAvailability.resolve(isLoading: false, didLoad: true, itemCount: 3), .available)
        // Items win over loading: a non-empty layer is switchable.
        XCTAssertEqual(
            VodDanmakuAvailability.resolve(isLoading: true, didLoad: true, itemCount: 2), .available)
    }
}

final class VodDanmakuLayerLoadingTests: XCTestCase {
    func testNilProviderMarksLoadedWithNoItems() {
        let state = VodDanmakuLayerState()
        state.load(for: PlayEpisode(name: "第01集", url: nil, index: 0), provider: nil)
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.didLoad)
        XCTAssertEqual(
            VodDanmakuAvailability.resolve(
                isLoading: state.isLoading, didLoad: state.didLoad, itemCount: state.items.count),
            .unavailable)
    }

    func testProviderLoadPassesThroughLoading() {
        let state = VodDanmakuLayerState()
        let provider = FakeDanmakuProvider(items: [
            DanmakuItem(text: "one", timeSeconds: 1, colorHex: "", isTop: false),
        ])
        state.load(for: PlayEpisode(name: "第01集", url: nil, index: 0), provider: provider)
        // The fetch completion lands on the main queue, so right
        // after load() the layer is still loading.
        XCTAssertTrue(state.isLoading)
        XCTAssertFalse(state.didLoad)
        let checked = expectation(description: "items loaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertFalse(state.isLoading)
            XCTAssertTrue(state.didLoad)
            XCTAssertEqual(state.items.count, 1)
            checked.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    func testEpisodeChangeResetsLoadingState() {
        let state = VodDanmakuLayerState()
        let provider = FakeDanmakuProvider(items: [
            DanmakuItem(text: "one", timeSeconds: 1, colorHex: "", isTop: false),
        ])
        state.load(for: PlayEpisode(name: "第01集", url: nil, index: 0), provider: provider)
        let checked = expectation(description: "second episode reloads")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(state.items.count, 1)
            state.load(for: PlayEpisode(name: "第02集", url: nil, index: 1), provider: provider)
            XCTAssertTrue(state.items.isEmpty)
            XCTAssertTrue(state.isLoading)
            XCTAssertFalse(state.didLoad)
            checked.fulfill()
        }
        waitForExpectations(timeout: 2)
    }
}

final class LiveDanmakuOverlayBacklogTests: XCTestCase {
    func testFreshMountSkipsBacklog() {
        XCTAssertEqual(
            LiveDanmakuOverlayView.startIndexForFreshMount(messageCount: 200, maxBacklog: 20), 180)
        XCTAssertEqual(
            LiveDanmakuOverlayView.startIndexForFreshMount(messageCount: 10, maxBacklog: 20), 0)
        XCTAssertEqual(
            LiveDanmakuOverlayView.startIndexForFreshMount(messageCount: 0, maxBacklog: 20), 0)
        XCTAssertEqual(
            LiveDanmakuOverlayView.startIndexForFreshMount(messageCount: 20, maxBacklog: 20), 0)
    }
}

// MARK: - 2x speed restore (VOD only)

/// Controllable stand-in for a VideoPlayerEngine: records speed
/// changes so the long-press 2x restore rule can be asserted
/// without a real backend.
final class FakePlayerEngine: VideoPlayerEngine {
    var positionSeconds: Double = 0
    var durationSeconds: Double = 100
    var isPlaying: Bool = false
    var isLoading: Bool = false
    var lastOpenFailed: Bool = false
    var lastFailure: VideoPlaybackFailure? = nil
    var audioTracks: [VodTrackInfo] = []
    var subtitleTracks: [VodTrackInfo] = []
    var videoView: UIView? = nil
    var currentEngine: VideoEngine? = .avplayer
    var diagnostics: VideoPlaybackDiagnostics = .empty
    var speeds: [Double] = []
    var selectedAudioTrack: Int?
    var selectedSubtitleTrack: Int?

    func play(detail: VideoDetail, lineIndex: Int, episodeIndex: Int, startPositionSeconds: Double) {}
    func playEpisode(lineIndex: Int, episodeIndex: Int, startPositionSeconds: Double) {}
    func setSpeed(_ speed: Double) { speeds.append(speed) }
    func setVideoFit(_ fit: VideoFit) {}
    func selectAudioTrack(index: Int) { selectedAudioTrack = index }
    func selectSubtitleTrack(index: Int) { selectedSubtitleTrack = index }
    func seek(to seconds: Double, completion: @escaping (Bool) -> Void) { completion(true) }
    func pause() { isPlaying = false }
    func resume() { isPlaying = true }
    func stop() { isPlaying = false }
    func applyVodEnhancement(_ branch: VodEnhancementBranch?) {}
    func setSubtitleAppearance(_ appearance: VodSubtitleAppearance) {}
    func setDialogueBoost(_ enabled: Bool) {}
    func setAudioOnly(_ audioOnly: Bool) {}
    @discardableResult
    func reopenAtCurrentPosition() -> Bool { false }
    func reopenEpisodeAtCurrentPosition() {}
}

final class VideoPlayerSpeedTests: XCTestCase {
    @MainActor
    func testDoubleSpeedRestoresUserSpeed() {
        let viewModel = VideoPlayerViewModel(coordinator: PlaybackCoordinator())
        let engine = FakePlayerEngine()
        viewModel.settings.playbackSpeed = 1.5
        viewModel.attachEngine(engine)
        // Attach pushes the user's speed to the engine.
        XCTAssertEqual(engine.speeds.last, 1.5)
        viewModel.setDoubleSpeed(true)
        XCTAssertTrue(viewModel.isDoubleSpeed)
        XCTAssertEqual(engine.speeds.last, 2.0)
        // Release restores the USER speed (1.5), not a hardcoded 1.0.
        viewModel.setDoubleSpeed(false)
        XCTAssertFalse(viewModel.isDoubleSpeed)
        XCTAssertEqual(engine.speeds.last, 1.5)
    }

    @MainActor
    func testDoubleSpeedWithoutEngineIsNoop() {
        let viewModel = VideoPlayerViewModel(coordinator: PlaybackCoordinator())
        viewModel.setDoubleSpeed(true)
        XCTAssertFalse(viewModel.isDoubleSpeed)
    }

    @MainActor
    func testDoubleSpeedReleaseAfterEngineDetachedClearsBadge() {
        // Build 36, item 9: the view model is app-level, so a 2x
        // badge left over from a hold that ended with the engine
        // detached must not survive into the next play. Before the
        // fix, the release no-op'd on the nil engine and the badge
        // stuck on.
        let viewModel = VideoPlayerViewModel(coordinator: PlaybackCoordinator())
        let engine = FakePlayerEngine()
        viewModel.attachEngine(engine)
        viewModel.setDoubleSpeed(true)
        XCTAssertTrue(viewModel.isDoubleSpeed)
        viewModel.attachEngine(nil)
        viewModel.setDoubleSpeed(false)
        XCTAssertFalse(viewModel.isDoubleSpeed)
    }

    @MainActor
    func testCloseClearsDoubleSpeedBadge() {
        // Build 36, item 9: closing mid-hold must not leave the
        // 2x badge behind for the next play.
        let viewModel = VideoPlayerViewModel(coordinator: PlaybackCoordinator())
        let engine = FakePlayerEngine()
        viewModel.attachEngine(engine)
        viewModel.setDoubleSpeed(true)
        XCTAssertTrue(viewModel.isDoubleSpeed)
        viewModel.close()
        XCTAssertFalse(viewModel.isDoubleSpeed)
    }
}

// MARK: - Build 36, item 14: format support (G-E / G-F / G-G / G-H / G-J)

/// Driver tests for the "play everything" round: mid-play engine
/// fallback, track pickers, external subtitles, the Emby
/// transcode last resort, and the per-attempt timeout. Same fake
/// seams as the classes above (fake backends + fake resolver, no
/// real engines, no network).
final class VideoDriverItem14Tests: XCTestCase {
    private func makeDriver(
        factory: FakeBackendFactory,
        resolver: FakeVideoResolver
    ) -> VideoDriver {
        let driver = VideoDriver()
        driver.makeBackend = { factory.makeBackend(engine: $0) }
        driver.playURLResolver = resolver
        driver.openTimeoutInterval = 5
        return driver
    }

    private func mp4URL() -> URL {
        URL(string: "https://a.b/movie.mp4")!
    }

    func testMidPlayErrorRetriesNextEngineAtSamePosition() {
        // MP4: AVPlayer first. It plays, then fails mid-play — the
        // driver must try MPV once at the same position instead of
        // failing outright (live already recovers this way).
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let avFake = FakeVideoBackend(engine: .avplayer)
        avFake.currentTime = 42
        let mpvFake = FakeVideoBackend(engine: .mpv)
        factory.fakes = [.avplayer: [avFake], .mpv: [mpvFake]]
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [mp4URL()]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "episode started on AVPlayer")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentEngine, .avplayer)
        // Let the position timer publish the playhead once.
        let positioned = expectation(description: "position published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { positioned.fulfill() }
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.position, 42, accuracy: 0.01)
        let restarted = expectation(description: "episode restarted on MPV")
        driver.onEpisodeStarted = { _ in restarted.fulfill() }
        avFake.onEvent?(.finished(.error))
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentEngine, .mpv)
        XCTAssertEqual(mpvFake.openCount, 1)
        XCTAssertEqual(mpvFake.openedURLs, [mp4URL()])
        // Resume at the saved position, not from 0.
        XCTAssertEqual(mpvFake.seekCalls.first, 42)
        XCTAssertFalse(driver.lastOpenFailed)
        XCTAssertNil(driver.lastFailure)
    }

    func testMidPlayErrorWithAllEnginesExcludedFailsWithReason() {
        // MKV: MPV first, IJK second. MPV plays, then fails
        // mid-play; the retry on IJK fails its open — the episode
        // fails with the specific reason, and MPV is never
        // re-attempted for this episode.
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let mpvFake = FakeVideoBackend(engine: .mpv)
        let ijkFake = FakeVideoBackend(engine: .ijk)
        ijkFake.openResults = [false]
        factory.fakes = [.mpv: [mpvFake], .ijk: [ijkFake]]
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [URL(string: "https://a.b/movie.mkv")!]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "episode started on MPV")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentEngine, .mpv)
        let failed = expectation(description: "episode failed")
        var failure: MusicPlayerError?
        driver.onEpisodeFailed = { _, error in
            failure = error
            failed.fulfill()
        }
        mpvFake.onEvent?(.finished(.error))
        waitForExpectations(timeout: 2)
        XCTAssertEqual(failure, .loadFailed)
        XCTAssertTrue(driver.lastOpenFailed)
        XCTAssertEqual(driver.lastFailure?.reason, .allEnginesFailed)
        XCTAssertTrue(driver.lastFailure?.formatDescription.contains("MKV") ?? false)
        XCTAssertEqual(mpvFake.openCount, 1)
        XCTAssertEqual(ijkFake.openCount, 1)
    }

    func testMidPlayRetryUsedAtMostOncePerEpisode() {
        // MP4: AVPlayer fails mid-play -> MPV; MPV fails mid-play
        // too -> the retry is spent, so IJK is never attempted and
        // the episode fails.
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let avFake = FakeVideoBackend(engine: .avplayer)
        let mpvFake = FakeVideoBackend(engine: .mpv)
        let ijkFake = FakeVideoBackend(engine: .ijk)
        factory.fakes = [.avplayer: [avFake], .mpv: [mpvFake], .ijk: [ijkFake]]
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [mp4URL()]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "episode started on AVPlayer")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        let restarted = expectation(description: "episode restarted on MPV")
        driver.onEpisodeStarted = { _ in restarted.fulfill() }
        avFake.onEvent?(.finished(.error))
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentEngine, .mpv)
        let failed = expectation(description: "episode failed")
        driver.onEpisodeFailed = { _, _ in failed.fulfill() }
        mpvFake.onEvent?(.finished(.error))
        waitForExpectations(timeout: 2)
        XCTAssertTrue(driver.lastOpenFailed)
        XCTAssertEqual(ijkFake.openCount, 0)
        XCTAssertEqual(mpvFake.openCount, 1)
    }

    func testTrackPicksAppliedAtOpenAndLive() {
        // A capable (MPV-shape) backend publishes 3 audio tracks
        // and 1 subtitle track on open. A pick stored before the
        // backend existed lands at open (translated to the native
        // track id); a live pick forwards at once.
        let (detail, line, episode) = makeTestDetail()
        let backend = CapableFakeBackend(engine: .mpv)
        backend.audioTracksToPublish = [
            VodTrackInfo(index: 11, displayName: "English", language: "eng", isDefault: true, isExternal: false),
            VodTrackInfo(index: 12, displayName: "国语", language: "zho", isDefault: false, isExternal: false),
            VodTrackInfo(index: 13, displayName: "粤语", language: "yue", isDefault: false, isExternal: false),
        ]
        backend.subtitleTracksToPublish = [
            VodTrackInfo(index: 21, displayName: "简体中文", language: "zho", isDefault: false, isExternal: false),
        ]
        let driver = VideoDriver()
        driver.makeBackend = { _ in backend }
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [URL(string: "https://a.b/movie.mkv")!]
        driver.playURLResolver = resolver
        driver.openTimeoutInterval = 5
        driver.selectAudioTrack(index: 1)
        XCTAssertEqual(driver.currentAudioTrackIndex, 1)
        let started = expectation(description: "episode started")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.audioTracks.count, 3)
        XCTAssertEqual(driver.subtitleTracks.count, 1)
        // Stored pick (list position 1) -> native id 12, once.
        XCTAssertEqual(backend.selectAudioCalls, [12])
        // Live pick: subtitle list position 0 -> native id 21.
        driver.selectSubtitleTrack(index: 0)
        XCTAssertEqual(backend.selectSubtitleCalls, [21])
        // Explicit "off" forwards -1.
        driver.selectSubtitleTrack(index: -1)
        XCTAssertEqual(backend.selectSubtitleCalls, [21, -1])
    }

    func testExternalSubtitleAddedOnMpvOpen() {
        // Emby MKV with one external subtitle stream: the driver
        // builds its URL from the stream URL and sub-adds it on
        // the MPV-shape backend at open.
        let (detail, line, episode) = makeTestDetail()
        let backend = CapableFakeBackend(engine: .mpv)
        let driver = VideoDriver()
        driver.makeBackend = { _ in backend }
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [URL(string: "https://emby.local:8096/emby/Videos/abc/stream?static=true&api_key=k&hao_container=mkv&hao_extsub=2:srt:en&hao_msrc=ms1")!]
        driver.playURLResolver = resolver
        driver.openTimeoutInterval = 5
        let started = expectation(description: "episode started")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(backend.addedSubtitles, [URL(string: "https://emby.local:8096/emby/Videos/abc/ms1/Subtitles/2?api_key=k")!])
    }

    func testTranscodeFallbackPlaysEmbyWhenDirectFails() {
        // Emby MKV: the direct URL fails on every ffmpeg engine
        // and there is no second line — the driver tries the
        // server HLS transcode once, and it plays on AVPlayer.
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let mpvFake = FakeVideoBackend(engine: .mpv)
        mpvFake.openResults = [false]
        let ijkFake = FakeVideoBackend(engine: .ijk)
        ijkFake.openResults = [false]
        let avFake = FakeVideoBackend(engine: .avplayer)
        factory.fakes = [.mpv: [mpvFake], .ijk: [ijkFake], .avplayer: [avFake]]
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [URL(string: "https://emby.local:8096/emby/Videos/abc/stream?static=true&api_key=k&hao_container=mkv")!]
        let driver = makeDriver(factory: factory, resolver: resolver)
        let started = expectation(description: "episode started on transcode")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentEngine, .avplayer)
        XCTAssertEqual(avFake.openedURLs, [URL(string: "https://emby.local:8096/emby/Videos/abc/master.m3u8?static=true&api_key=k")!])
        XCTAssertFalse(driver.lastOpenFailed)
    }

    func testPerAttemptTimeoutLetsNextEngineRun() {
        // MP4: AVPlayer hangs (never answers) — the per-attempt
        // timeout must fail that attempt after its own budget and
        // let MPV run, instead of the whole open hanging until
        // the overall cap.
        let (detail, line, episode) = makeTestDetail()
        let factory = FakeBackendFactory()
        let hangingAV = FakeVideoBackend(engine: .avplayer)
        hangingAV.deferOpenCompletion = true
        let goodMPV = FakeVideoBackend(engine: .mpv)
        factory.fakes = [.avplayer: [hangingAV], .mpv: [goodMPV]]
        let resolver = FakeVideoResolver()
        resolver.urlsToReturn = [mp4URL()]
        let driver = makeDriver(factory: factory, resolver: resolver)
        driver.openTimeoutInterval = 0.2
        let started = expectation(description: "episode started on MPV")
        driver.onEpisodeStarted = { _ in started.fulfill() }
        driver.playEpisode(detail: detail, line: line, episode: episode)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentEngine, .mpv)
        XCTAssertEqual(goodMPV.openCount, 1)
        // The hanging backend was shut down by the attempt timeout.
        XCTAssertEqual(hangingAV.shutdownCount, 1)
        // A late answer from it must not resurrect it.
        hangingAV.deferredOpenCompletion?(true)
        let checked = expectation(description: "late answer handled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertFalse(hangingAV.isPlaying)
            XCTAssertEqual(driver.currentEngine, .mpv)
            checked.fulfill()
        }
        waitForExpectations(timeout: 2)
    }
}

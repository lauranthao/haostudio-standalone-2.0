// HAo Studio 2.0 — build 35 live-crash landing tests (#11, D1, D2).
//
// iOS-only, same treatment as LiveDriverTests: NOT wired into
// `ios/Package.swift`. S7 wired the `HAoStudioTests` Xcode test
// target (run with `xcodebuild test` against an iOS simulator
// destination — `swift test` on a macOS runner cannot compile this
// target: UIKit / AVFoundation). The target has the app as its host
// and the tests `@testable import HAoStudio`.
//
// #11: a superseded open must still settle its completion as failed
// (a dropped completion leaves `isLoading` true forever).
// D1: a late roomInfo callback must not revive a transport for the
// wrong/closed room, and starting a transport must stop the old one.
// D2: `danmakuSequence` must keep counting past the 200-message cap
// (the views observe it, because `messages.count` stops changing
// once the window is full).

import Foundation
import XCTest

@testable import HAoStudio

// MARK: - Fakes (local to this file)

/// Backend whose open completion is held until shutdown, like the
/// real backends (finishOpen(false) on shutdown).
final class HeldOpenFakeBackend: VideoPlayerBackend {
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

    var view: UIView { UIView() }
    var openCount = 0
    var shutdownCount = 0
    private var heldCompletion: ((Bool) -> Void)?

    init(engine: VideoEngine) {
        self.engine = engine
    }

    func setVideoFit(_ fit: VideoFit) {}

    func open(url: URL, headers: [String: String], completion: @escaping (Bool) -> Void) {
        openCount += 1
        heldCompletion = completion
    }

    func play() { isPlaying = true }
    func pause() { isPlaying = false }

    func seek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        completion(true)
    }

    func shutdown() {
        shutdownCount += 1
        isPlaying = false
        isPrepared = false
        heldCompletion?(false)
        heldCompletion = nil
    }
}

/// Transport that records start/stop, never connects anywhere.
final class RecordingDanmakuTransport: LiveDanmakuTransport {
    var isConnected: Bool { started }
    var onMessage: ((DanmakuMessage) -> Void)?
    var onReady: (() -> Void)?
    var onClose: (() -> Void)?
    var onReconnect: (() -> Void)?

    private(set) var started = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(danmakuData: [String: Any]) {
        started = true
        startCount += 1
    }

    func heartbeat() {}

    func stop() {
        started = false
        stopCount += 1
    }
}

/// Resolver with deferred roomInfo (the test delivers answers by
/// hand) and recording transports.
final class DeferredRoomInfoResolver: LiveSiteResolver {
    var platform: LivePlatform { .huya }
    var roomInfoCompletions: [String: (Result<LiveRoom, Error>) -> Void] = [:]
    var transports: [RecordingDanmakuTransport] = []

    func roomInfo(roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        roomInfoCompletions[roomId] = completion
    }

    func resolve(roomId: String, quality: LiveQuality?, completion: @escaping (Result<LivePlayUrlResolution, Error>) -> Void) {
        completion(.failure(LiveError.emptyResponse))
    }

    func makeDanmakuTransport() -> LiveDanmakuTransport {
        let transport = RecordingDanmakuTransport()
        transports.append(transport)
        return transport
    }
}

// MARK: - Tests

final class LiveCrashB35Tests: XCTestCase {
    // #11: open A stalls on a held backend; open B supersedes it.
    // A's completion must still fire (as failure), exactly once —
    // without the fix it never fires and attemptOpen hangs.
    func testSupersededOpenSettlesCompletionAsFailure() {
        let driver = LiveDriver()
        driver.openTimeoutInterval = 5
        driver.configure(
            room: LiveRoom(roomId: "123", platform: .huya),
            resolver: LiveDriverFakeResolver()
        )
        let held = HeldOpenFakeBackend(engine: .mpv)
        var backendCalls = 0
        driver.makeBackend = { engine in
            backendCalls += 1
            if backendCalls == 1 { return held }
            let fake = FakeVideoBackend(engine: engine)
            fake.openResults = [false]
            return fake
        }
        let url = URL(string: "https://example.com/live.flv")!
        var resultsA: [Result<Void, MusicPlayerError>] = []
        let settledA = expectation(description: "superseded open A settles")
        driver.open(item: LiveDriver.playbackItem(room: LiveRoom(roomId: "123", platform: .huya)), url: url) { result in
            resultsA.append(result)
            settledA.fulfill()
        }
        driver.open(item: LiveDriver.playbackItem(room: LiveRoom(roomId: "456", platform: .huya)), url: url) { _ in }
        waitForExpectations(timeout: 3)
        XCTAssertEqual(resultsA.count, 1, "superseded completion must fire exactly once")
        guard let first = resultsA.first else { return }
        if case .failure = first {
            // Expected: the superseded attempt settles as failed.
        } else {
            XCTFail("superseded open should settle as failure, got \(first)")
        }
    }

    // D1: A's roomInfo answers late, after B already started — the
    // stale callback must not start a transport for A.
    func testLateRoomInfoAfterSwitchDoesNotStartOldTransport() {
        let viewModel = LivePlayerViewModel(driver: LiveDriver())
        let resolver = DeferredRoomInfoResolver()
        let roomA = LiveRoom(roomId: "a", platform: .huya)
        let roomB = LiveRoom(roomId: "b", platform: .huya)
        viewModel.startDanmaku(room: roomA, resolver: resolver)
        viewModel.startDanmaku(room: roomB, resolver: resolver)
        resolver.roomInfoCompletions["a"]?(.success(
            LiveRoom(roomId: "a", platform: .huya, danmakuData: ["k": "v"])
        ))
        let drain = expectation(description: "drain main queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { drain.fulfill() }
        waitForExpectations(timeout: 2)
        XCTAssertTrue(
            resolver.transports.isEmpty,
            "late roomInfo for A must not start a transport"
        )
        resolver.roomInfoCompletions["b"]?(.success(
            LiveRoom(roomId: "b", platform: .huya, danmakuData: ["k": "v"])
        ))
        let drain2 = expectation(description: "drain main queue 2")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { drain2.fulfill() }
        waitForExpectations(timeout: 2)
        XCTAssertEqual(resolver.transports.count, 1)
        XCTAssertEqual(resolver.transports.first?.startCount, 1)
    }

    // D1: starting danmaku for B stops A's transport first.
    func testStartDanmakuStopsPreviousTransport() {
        let viewModel = LivePlayerViewModel(driver: LiveDriver())
        let resolver = DeferredRoomInfoResolver()
        let roomA = LiveRoom(roomId: "a", platform: .huya, danmakuData: ["k": "v"])
        let roomB = LiveRoom(roomId: "b", platform: .huya, danmakuData: ["k": "v"])
        viewModel.startDanmaku(room: roomA, resolver: resolver)
        XCTAssertEqual(resolver.transports.count, 1)
        XCTAssertEqual(resolver.transports[0].startCount, 1)
        viewModel.startDanmaku(room: roomB, resolver: resolver)
        XCTAssertEqual(resolver.transports.count, 2)
        XCTAssertEqual(resolver.transports[0].stopCount, 1, "old transport must be stopped on switch")
        XCTAssertEqual(resolver.transports[1].startCount, 1)
    }

    // D2: the append counter keeps counting past the 200-message
    // cap, so the views' sequence observation keeps firing.
    func testAppendDanmakuSequenceKeepsCountingPastCap() {
        let viewModel = LivePlayerViewModel(driver: LiveDriver())
        for i in 0..<250 {
            viewModel.appendDanmaku(DanmakuMessage(text: "m\(i)"))
        }
        XCTAssertEqual(viewModel.messages.count, 200, "window stays capped at 200")
        XCTAssertEqual(viewModel.danmakuSequence, 250, "sequence counts every append")
        XCTAssertEqual(viewModel.messages.first?.text, "m50")
        XCTAssertEqual(viewModel.messages.last?.text, "m249")
    }
}

// HAo Studio 2.0 — build 35 live sweep landing tests (item 11).
//
// iOS-only, same treatment as LiveCrashB35Tests: NOT wired into
// `ios/Package.swift`. The macOS gate runs them via the S7 Xcode
// test target (`xcodebuild test` — `swift test` on Linux cannot
// compile this target: UIKit / AVFoundation).
//
// S1: switching rooms clears the old room's danmaku (and a stale
// transport message queued before the stop never lands after the
// clear); re-entering after an exit starts clean; a bare restart
// for the room already showing keeps the visible chat.
// S2: a line-switch fallback and a stall recovery to the next line
// both report the line actually opened (the index used to keep
// naming the failed line).
// S3: `release()` exits the session (the room page now calls it on
// disappear — the prefetch timer must not survive the exit).
// S4: a stale platform answer never overwrites the new platform's
// grid, and returning to the tab does not wipe the loaded grid.
// S7: room info refreshes the live status for history / follow /
// mini entries (stored `isLive: false`).
// S8: the portrait chat list caps at the `maxCount` setting.

import Foundation
import XCTest

@testable import HAoStudio

// MARK: - S1 / S7: view-model danmaku + live status

final class LiveSweepDanmakuTests: XCTestCase {
    private func makeViewModel() -> LivePlayerViewModel {
        LivePlayerViewModel(driver: LiveDriver())
    }

    // S1: A -> B switch drops A's chat; the sequence stays
    // monotonic (D2 contract — it is never reset).
    func testRoomSwitchClearsPreviousRoomDanmaku() {
        let viewModel = makeViewModel()
        let resolver = DeferredRoomInfoResolver()
        let roomA = LiveRoom(roomId: "a", platform: .huya, danmakuData: ["k": "v"])
        let roomB = LiveRoom(roomId: "b", platform: .huya, danmakuData: ["k": "v"])
        viewModel.startDanmaku(room: roomA, resolver: resolver)
        viewModel.appendDanmaku(DanmakuMessage(text: "from A"))
        XCTAssertEqual(viewModel.messages.count, 1)
        let sequenceBefore = viewModel.danmakuSequence
        viewModel.startDanmaku(room: roomB, resolver: resolver)
        XCTAssertTrue(viewModel.messages.isEmpty, "new room must not show the old room's chat")
        XCTAssertEqual(viewModel.danmakuSequence, sequenceBefore, "sequence stays monotonic (D2)")
        viewModel.appendDanmaku(DanmakuMessage(text: "from B"))
        XCTAssertEqual(viewModel.messages.map { $0.text }, ["from B"])
    }

    // S1: a bare restart for the room already showing keeps the
    // visible chat (no intervening stop).
    func testSameRoomRestartKeepsMessages() {
        let viewModel = makeViewModel()
        let resolver = DeferredRoomInfoResolver()
        let room = LiveRoom(roomId: "a", platform: .huya, danmakuData: ["k": "v"])
        viewModel.startDanmaku(room: room, resolver: resolver)
        viewModel.appendDanmaku(DanmakuMessage(text: "hi"))
        viewModel.startDanmaku(room: room, resolver: resolver)
        XCTAssertEqual(viewModel.messages.map { $0.text }, ["hi"])
    }

    // S1: re-entering the same room after an exit starts clean —
    // the list showing is from the previous visit, minutes old.
    func testReentryAfterStopClearsMessages() {
        let viewModel = makeViewModel()
        let resolver = DeferredRoomInfoResolver()
        let room = LiveRoom(roomId: "a", platform: .huya, danmakuData: ["k": "v"])
        viewModel.startDanmaku(room: room, resolver: resolver)
        viewModel.appendDanmaku(DanmakuMessage(text: "old visit"))
        viewModel.stopDanmaku()
        viewModel.startDanmaku(room: room, resolver: resolver)
        XCTAssertTrue(viewModel.messages.isEmpty, "re-entry after exit must start from a clean list")
    }

    // S1: a message queued on the main hop before the stop must
    // not land after the new room's list was cleared.
    func testStaleTransportMessageDroppedAfterStop() {
        let viewModel = makeViewModel()
        let resolver = DeferredRoomInfoResolver()
        let roomA = LiveRoom(roomId: "a", platform: .huya, danmakuData: ["k": "v"])
        let roomB = LiveRoom(roomId: "b", platform: .huya, danmakuData: ["k": "v"])
        viewModel.startDanmaku(room: roomA, resolver: resolver)
        let transportA = resolver.transports[0]
        // Queue an append from A's transport, then switch rooms
        // before the main queue runs it.
        transportA.onMessage?(DanmakuMessage(text: "stale A"))
        viewModel.startDanmaku(room: roomB, resolver: resolver)
        let drain = expectation(description: "drain main queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { drain.fulfill() }
        waitForExpectations(timeout: 2)
        XCTAssertTrue(
            viewModel.messages.isEmpty,
            "a pre-stop append must not land in the new room's list"
        )
    }

    // S7: room info refreshes the live status — history / follow /
    // mini entries arrive with stored `isLive: false`.
    func testRoomInfoRefreshesLiveStatus() {
        let viewModel = makeViewModel()
        let resolver = DeferredRoomInfoResolver()
        let stored = LiveRoom(roomId: "a", platform: .huya, isLive: false)
        viewModel.startDanmaku(room: stored, resolver: resolver)
        XCTAssertNil(viewModel.roomIsLive, "no room info yet — the card's value stands")
        resolver.roomInfoCompletions["a"]?(.success(
            LiveRoom(roomId: "a", platform: .huya, isLive: true, onlineCount: 42, danmakuData: ["k": "v"])
        ))
        let drain = expectation(description: "drain main queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { drain.fulfill() }
        waitForExpectations(timeout: 2)
        XCTAssertEqual(viewModel.roomIsLive, Optional(true))
        XCTAssertEqual(viewModel.watching, 42)
    }
}

// MARK: - S2 / S3: driver line index + release

final class LiveSweepDriverTests: XCTestCase {
    private func makeRoom() -> LiveRoom {
        LiveRoom(roomId: "123", platform: .huya, title: "测试直播间", streamer: "主播", onlineCount: 100, isLive: true)
    }

    private func makeResolution(urls: [URL], quality: LiveQuality? = nil) -> LivePlayUrlResolution {
        let lines = urls.enumerated().map { index, url in
            LiveLine(name: "线路\(index + 1)", urls: [url.absoluteString])
        }
        return LivePlayUrlResolution(lines: lines, formats: [], qualities: [], quality: quality, refreshAt: nil, invalidAt: nil)
    }

    private func makeDriver(resolver: LiveDriverFakeResolver) -> LiveDriver {
        let driver = LiveDriver()
        driver.openTimeoutInterval = 5
        driver.configure(room: makeRoom(), resolver: resolver)
        return driver
    }

    // S2: switch to line 1, its open fails on every engine, the
    // fallback opens line 0 — the index must say 0 afterwards
    // (pre-fix it still said 1 while line 0 played).
    func testLineSwitchFallbackKeepsLineIndexHonest() {
        let firstURL = URL(string: "https://tx.flv.huya.com/room/1.flv")!
        let secondURL = URL(string: "https://al.flv.huya.com/room/1.flv")!
        let resolver = LiveDriverFakeResolver()
        resolver.resolutionsToReturn = [makeResolution(urls: [firstURL, secondURL])]
        let driver = makeDriver(resolver: resolver)
        // One shared fake, scripted per open call: initial open ok,
        // line-1 open fails on both engines (MPV, IJK), fallback ok.
        let fake = FakeVideoBackend(engine: .mpv)
        fake.openResults = [true, false, false, true]
        driver.makeBackend = { _ in fake }
        var startCount = 0
        let startedOnce = expectation(description: "room started")
        driver.onRoomStarted = { _ in
            startCount += 1
            if startCount == 1 { startedOnce.fulfill() }
        }
        driver.play(item: LiveDriver.playbackItem(room: makeRoom()))
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentLineIndex, 0)
        let startedTwice = expectation(description: "room restarted on fallback line")
        driver.onRoomStarted = { _ in
            startCount += 1
            if startCount == 2 { startedTwice.fulfill() }
        }
        XCTAssertTrue(driver.switchLine(to: 1))
        waitForExpectations(timeout: 2)
        XCTAssertEqual(fake.openedURLs.last, firstURL, "fallback must open line 0's URL")
        XCTAssertEqual(driver.currentLineIndex, 0, "index must name the line actually playing")
    }

    // S2: a stall recovers to the next line (re-parse comes back
    // empty, so recovery falls through to it) — the index must
    // advance with it (pre-fix it stayed 0 while line 1 played).
    func testStallRecoveryToNextLineUpdatesIndex() {
        let firstURL = URL(string: "https://tx.flv.huya.com/room/1.flv")!
        let secondURL = URL(string: "https://al.flv.huya.com/room/1.flv")!
        let resolver = LiveDriverFakeResolver()
        resolver.resolutionsToReturn = [makeResolution(urls: [firstURL, secondURL])]
        let driver = makeDriver(resolver: resolver)
        let fake = FakeVideoBackend(engine: .mpv)
        driver.makeBackend = { _ in fake }
        var startCount = 0
        let startedOnce = expectation(description: "room started")
        driver.onRoomStarted = { _ in
            startCount += 1
            if startCount == 1 { startedOnce.fulfill() }
        }
        driver.play(item: LiveDriver.playbackItem(room: makeRoom()))
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.currentLineIndex, 0)
        let startedTwice = expectation(description: "room restarted on next line")
        driver.onRoomStarted = { _ in
            startCount += 1
            if startCount == 2 { startedTwice.fulfill() }
        }
        fake.onEvent?(.finished(.error))
        waitForExpectations(timeout: 2)
        XCTAssertEqual(fake.openedURLs.last, secondURL, "recovery must open the next line's URL")
        XCTAssertEqual(driver.currentLineIndex, 1, "index must advance to the line actually playing")
    }

    // S3: release() exits the session — the exit path the room
    // page now calls on disappear, so the lease prefetch timer
    // cannot survive the exit.
    func testReleaseExitsSession() {
        let resolver = LiveDriverFakeResolver()
        resolver.resolutionsToReturn = [makeResolution(urls: [URL(string: "https://tx.flv.huya.com/room/1.flv")!])]
        let driver = makeDriver(resolver: resolver)
        driver.makeBackend = { FakeVideoBackend(engine: $0) }
        let started = expectation(description: "room started")
        driver.onRoomStarted = { _ in started.fulfill() }
        driver.play(item: LiveDriver.playbackItem(room: makeRoom()))
        waitForExpectations(timeout: 2)
        XCTAssertNotNil(driver.session.recovery)
        let released = expectation(description: "release completes")
        driver.release { released.fulfill() }
        waitForExpectations(timeout: 2)
        XCTAssertEqual(driver.session.state, .exited)
        XCTAssertNil(driver.session.recovery, "recovery (and its prefetch timer) must be dropped")
        XCTAssertNil(driver.currentRoom)
    }
}

// MARK: - S4: tab view model generation + load-if-needed

/// Gateway with hand-delivered recommend answers.
final class DeferredLiveGateway: LiveDataGateway {
    struct PendingRecommended {
        let platform: String
        let area: String?
        let page: Int
        let completion: (LiveRoomPage) -> Void
    }

    private(set) var pendingRecommended: [PendingRecommended] = []
    private(set) var fetchRecommendedCalls: [(platform: String, area: String?, page: Int)] = []

    func fetchRecommended(platform: String, area: String?, page: Int, completion: @escaping (LiveRoomPage) -> Void) {
        fetchRecommendedCalls.append((platform, area, page))
        pendingRecommended.append(PendingRecommended(platform: platform, area: area, page: page, completion: completion))
    }

    func answerRecommended(at index: Int, rooms: [LiveRoom], hasMore: Bool) {
        pendingRecommended[index].completion(LiveRoomPage(rooms: rooms, hasMore: hasMore))
    }

    func fetchCategories(platform: String, completion: @escaping ([String]) -> Void) {}

    func searchRooms(query: String, platform: String, completion: @escaping ([LiveRoom]) -> Void) {
        completion([])
    }

    func fetchRoomDetail(room: LiveRoom, completion: @escaping (LiveRoom?) -> Void) {
        completion(nil)
    }
}

@MainActor
final class LiveSweepTabTests: XCTestCase {
    // S4: switch platforms while Bilibili's load is in flight —
    // the late Bilibili answer must not land under Douyu.
    func testStalePlatformAnswerDropped() {
        let gateway = DeferredLiveGateway()
        let viewModel = LiveTabViewModel(gateway: gateway)
        viewModel.reload()
        XCTAssertEqual(gateway.fetchRecommendedCalls.count, 1)
        viewModel.selectPlatform(.douyu)
        XCTAssertEqual(gateway.fetchRecommendedCalls.count, 2, "reload during a load must still start a fetch")
        gateway.answerRecommended(at: 0, rooms: [LiveRoom(roomId: "b1", platform: .bilibili, title: "B")], hasMore: false)
        XCTAssertTrue(viewModel.rooms.isEmpty, "stale bilibili answer must not land under douyu")
        XCTAssertTrue(viewModel.isLoading, "the current douyu load still owns the spinner")
        gateway.answerRecommended(at: 1, rooms: [LiveRoom(roomId: "d1", platform: .douyu, title: "D")], hasMore: false)
        XCTAssertEqual(viewModel.rooms.map { $0.roomId }, ["d1"])
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.loadFailed)
    }

    // S4: returning to the tab (onAppear) keeps the loaded grid
    // and fires no refetch.
    func testLoadIfNeededKeepsRooms() {
        let gateway = DeferredLiveGateway()
        let viewModel = LiveTabViewModel(gateway: gateway)
        viewModel.reload()
        gateway.answerRecommended(at: 0, rooms: [LiveRoom(roomId: "b1", platform: .bilibili, title: "B")], hasMore: false)
        XCTAssertEqual(viewModel.rooms.count, 1)
        let callsBefore = gateway.fetchRecommendedCalls.count
        viewModel.loadIfNeeded()
        XCTAssertEqual(viewModel.rooms.count, 1, "returning to the tab must not wipe the grid")
        XCTAssertEqual(gateway.fetchRecommendedCalls.count, callsBefore, "no refetch when rooms are loaded")
    }
}

// MARK: - S8: chat-list cap

final class LiveSweepDanmakuCapTests: XCTestCase {
    // S8: the visible list caps at `maxCount`, oldest first out.
    func testCappedListKeepsNewest() {
        let shown = (0..<100).map { DanmakuMessage(text: "m\($0)") }
        let capped = LiveDanmakuListView.capped(shown, to: 80)
        XCTAssertEqual(capped.count, 80)
        XCTAssertEqual(capped.first?.text, "m20")
        XCTAssertEqual(capped.last?.text, "m99")
        XCTAssertEqual(LiveDanmakuListView.capped(shown, to: 200).count, 100, "under the cap, nothing is dropped")
    }
}

// MARK: - Build 36 item 8: search platform switch

@MainActor
final class LiveSweepSearchPlatformTests: XCTestCase {
    // Switching platform while a search is showing re-runs the
    // same query on the new platform instead of leaving the old
    // platform's rooms under the new tab; with an empty field
    // there is nothing to re-run, so the view drops back to
    // history.
    func testSelectPlatformRerunsQueryOrClearsToHistory() {
        let viewModel = LiveSearchViewModel(gateway: DeferredLiveGateway())
        viewModel.search(query: "b36-test")
        XCTAssertTrue(viewModel.hasSearched)
        viewModel.selectPlatform(.douyu, query: "b36-test")
        XCTAssertEqual(viewModel.platform, .douyu)
        XCTAssertTrue(viewModel.hasSearched, "re-running the query keeps the results view")
        viewModel.selectPlatform(.huya, query: "")
        XCTAssertEqual(viewModel.platform, .huya)
        XCTAssertFalse(viewModel.hasSearched, "empty field drops back to the history view")
        XCTAssertTrue(viewModel.results.isEmpty)
        viewModel.selectPlatform(.huya, query: "")
        XCTAssertEqual(viewModel.platform, .huya, "same-platform switch is a no-op")
        LiveLibraryStore.removeSearchHistory(term: "b36-test")
    }
}

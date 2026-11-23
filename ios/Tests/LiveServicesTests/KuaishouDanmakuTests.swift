// HAo Studio 2.0 — Kuaishou danmaku tests (S4 leg B).
//
// Feed payload (incl. double-encoded JSON), comment filter,
// pull-cycle clamp, and one live poll via a stub fetcher.
// No network. Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class KuaishouDanmakuTests: XCTestCase {
    private var feedJSON: String {
        """
        {"result":1,"cursor":"c2","pullCycleSeconds":3,"liveStreamFeeds":[{"type":"comment","content":"你好","author":{"userName":"快手老铁"}},{"type":"gift","content":"礼物"},{"type":"Comment","content":"第二条","author":{}}]}
        """
    }

    func testParseFeedPayload() throws {
        let batch = try KuaishouDanmaku.parseFeedPayload(jsonObject(feedJSON))
        XCTAssertEqual(batch.cursor, "c2")
        XCTAssertEqual(batch.pullDelaySeconds, 3)
        XCTAssertEqual(batch.messages.count, 2)
        XCTAssertEqual(batch.messages[0].text, "你好")
        XCTAssertEqual(batch.messages[0].userName, "快手老铁")
        XCTAssertEqual(batch.messages[1].text, "第二条")
        XCTAssertEqual(batch.messages[1].userName, "快手用户")
    }

    func testParseFeedPayloadUnwrapsDoubleEncodedJson() throws {
        // JSONSerialization cannot encode a top-level String (it
        // throws an uncatchable NSException); JSONEncoder can.
        let doubleEncoded = String(
            data: try JSONEncoder().encode(feedJSON),
            encoding: .utf8
        ) ?? ""
        let batch = try KuaishouDanmaku.parseFeedPayload(doubleEncoded)
        XCTAssertEqual(batch.cursor, "c2")
        XCTAssertEqual(batch.messages.count, 2)
    }

    func testParseFeedPayloadUnwrapsDataEnvelope() throws {
        let encoded = String(data: try JSONSerialization.data(withJSONObject: ["data": jsonObject(feedJSON)], options: []), encoding: .utf8) ?? ""
        let batch = try KuaishouDanmaku.parseFeedPayload(encoded)
        XCTAssertEqual(batch.cursor, "c2")
        XCTAssertEqual(batch.messages.count, 2)
    }

    func testParseFeedPayloadRejectsNonOneResult() {
        XCTAssertThrowsError(try KuaishouDanmaku.parseFeedPayload(jsonObject("{\"result\":0,\"cursor\":\"\"}")))
        XCTAssertThrowsError(try KuaishouDanmaku.parseFeedPayload(jsonObject("{}")))
        XCTAssertThrowsError(try KuaishouDanmaku.parseFeedPayload(nil))
    }

    func testParseFeedPayloadClampsPullCycle() throws {
        let low = try KuaishouDanmaku.parseFeedPayload(jsonObject("{\"result\":1,\"pullCycleSeconds\":0,\"liveStreamFeeds\":[]}"))
        XCTAssertEqual(low.pullDelaySeconds, 1)
        let high = try KuaishouDanmaku.parseFeedPayload(jsonObject("{\"result\":1,\"pullCycleSeconds\":99,\"liveStreamFeeds\":[]}"))
        XCTAssertEqual(high.pullDelaySeconds, 10)
        let missing = try KuaishouDanmaku.parseFeedPayload(jsonObject("{\"result\":1,\"liveStreamFeeds\":[]}"))
        XCTAssertEqual(missing.pullDelaySeconds, 3)
    }

    func testStartPollsFeedAndEmitsComments() {
        let transport = KuaishouDanmaku(fetcher: stubFetcher(data: jsonData(feedJSON), status: 200))
        var received: [DanmakuMessage] = []
        var ready = false
        transport.onReady = { ready = true }
        let expectation = self.expectation(description: "first poll")
        transport.onMessage = { message in
            received.append(message)
            if received.count == 2 {
                expectation.fulfill()
            }
        }
        transport.start(danmakuData: ["liveStreamId": "LS123"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(ready)
        XCTAssertTrue(transport.isConnected)
        XCTAssertEqual(received.map { $0.text }, ["你好", "第二条"])
        transport.stop()
        XCTAssertFalse(transport.isConnected)
    }

    func testStartWithoutLiveStreamIdAndRoomIdCloses() {
        let transport = KuaishouDanmaku(fetcher: stubFetcher(data: nil, status: 404))
        var closed = false
        transport.onClose = { closed = true }
        transport.start(danmakuData: [:])
        XCTAssertTrue(closed)
    }

    func testRepeatedFeedFailureCloses() {
        let transport = KuaishouDanmaku(fetcher: stubFetcher(data: nil, status: 500))
        let expectation = self.expectation(description: "close after retries")
        transport.onClose = { expectation.fulfill() }
        transport.start(danmakuData: ["liveStreamId": "LS123"])
        waitForExpectations(timeout: 5)
    }

    func testHeartbeatIsNoop() {
        let transport = KuaishouDanmaku(fetcher: stubFetcher(data: nil, status: 404))
        transport.heartbeat()
        XCTAssertFalse(transport.isConnected)
    }
}

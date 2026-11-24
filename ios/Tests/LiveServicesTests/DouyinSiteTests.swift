// HAo Studio 2.0 — Douyin site tests (S4 leg B).
//
// Stream qualities (joined by sdk_key), audience units, live
// status, render-data HTML parse, anonymous id shape.
// No network. Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class DouyinSiteTests: XCTestCase {
    private var streamUrlJSON: String {
        """
        {"live_core_sdk_data":{"pull_data":{"options":{"qualities":[{"sdk_key":"ORIGIN","name":"原画","level":6,"v_bit_rate":6000000},{"sdk_key":"HD1","name":"超清","level":4,"v_bit_rate":4000000},{"sdk_key":"SD1","name":"标清","level":2,"v_bit_rate":2000000},{"sdk_key":"ao","name":"音频","level":1}]},"stream_data":"{\\"data\\":{\\"ORIGIN\\":{\\"main\\":{\\"flv\\":\\"https://pull.douyin.com/origin.flv\\",\\"hls\\":\\"https://pull.douyin.com/origin.m3u8\\"}},\\"HD1\\":{\\"main\\":{\\"flv\\":\\"https://pull.douyin.com/hd.flv\\"}},\\"SD1\\":{\\"main\\":{\\"flv\\":\\"https://pull.douyin.com/sd.flv\\"}},\\"ao\\":{\\"main\\":{\\"flv\\":\\"https://pull.douyin.com/ao.flv?only_audio=1\\"}}}}"}},"flv_pull_url":{"ORIGIN":"https://pull.douyin.com/origin2.flv"},"hls_pull_url_map":{},"resolution_name":{}}
        """
        }

        // MARK: - Stream qualities

        func testParseStreamQualitiesJoinedByKey() {
        let qualities = DouyinLiveSite.parseStreamQualities(jsonObject(streamUrlJSON))
        XCTAssertEqual(qualities.map { $0.id }, ["origin", "hd1", "sd1"])
        XCTAssertEqual(qualities.map { $0.name }, ["原画", "超清", "标清"])
        XCTAssertEqual(qualities.map { $0.sort }, [6000000, 4000000, 2000000])
        XCTAssertEqual(qualities[0].lines.map { $0.format }, ["flv", "hls", "flv"])
        XCTAssertEqual(qualities[0].lines.map { $0.urls[0] }, [
        "https://pull.douyin.com/origin.flv",
        "https://pull.douyin.com/origin.m3u8",
        "https://pull.douyin.com/origin2.flv"
        ])
        XCTAssertEqual(qualities[1].lines.count, 1)
        XCTAssertEqual(qualities[1].lines[0].format, "flv")
        }

        func testParseStreamQualitiesSkipsAudioOnly() {
        let qualities = DouyinLiveSite.parseStreamQualities(jsonObject(streamUrlJSON))
        XCTAssertFalse(qualities.contains { $0.id == "ao" })
        }

        func testParseStreamQualitiesEmpty() {
        XCTAssertTrue(DouyinLiveSite.parseStreamQualities(nil).isEmpty)
        XCTAssertTrue(DouyinLiveSite.parseStreamQualities(jsonObject("{}")).isEmpty)
        }

        func testQualityLabelTokenMap() {
        XCTAssertEqual(
        DouyinLiveSite.douyinQualityLabel(key: "FULL_HD1", configuredName: "", resolutionName: "", resolution: nil, bitrate: nil),
        "蓝光"
        )
        XCTAssertEqual(
        DouyinLiveSite.douyinQualityLabel(key: "unknown", configuredName: "", resolutionName: "", resolution: "1920x1080", bitrate: nil),
        "1080P 高清"
        )
        XCTAssertEqual(
        DouyinLiveSite.douyinQualityLabel(key: "unknown", configuredName: "", resolutionName: "", resolution: nil, bitrate: 1500000),
        "1.5M"
        )
        }

        // MARK: - Audience

        func testParseAudienceUnits() {
        XCTAssertEqual(DouyinLiveSite.parseAudience("1.2万"), 12000)
        XCTAssertEqual(DouyinLiveSite.parseAudience("3.5亿"), 350000000)
        XCTAssertEqual(DouyinLiveSite.parseAudience("1.5千"), 1500)
        XCTAssertEqual(DouyinLiveSite.parseAudience("500"), 500)
        XCTAssertEqual(DouyinLiveSite.parseAudience("1,234"), 1234)
        XCTAssertEqual(DouyinLiveSite.parseAudience(""), 0)
        XCTAssertEqual(DouyinLiveSite.parseAudience("abc"), 0)
        }

        func testDouyinWatchingPrefersConcurrent() {
        XCTAssertEqual(DouyinLiveSite.douyinWatching(["user_count": 1234]), 1234)
        XCTAssertEqual(DouyinLiveSite.douyinWatching(["user_count_str": "1.2万"]), 12000)
        XCTAssertEqual(DouyinLiveSite.douyinWatching(["total_user": 5000]), 5000)
        XCTAssertEqual(DouyinLiveSite.douyinWatching(["user_count": 100, "total_user": 0]), 100)
        XCTAssertEqual(DouyinLiveSite.douyinWatching([:]), 0)
        }

        // MARK: - Live status / helpers

        func testDouyinIsLive() {
        XCTAssertTrue(DouyinLiveSite.douyinIsLive(room: ["status": 2], envelope: nil))
        XCTAssertFalse(DouyinLiveSite.douyinIsLive(room: ["status": 1], envelope: nil))
        XCTAssertTrue(DouyinLiveSite.douyinIsLive(room: [:], envelope: ["room_status": 0]))
        XCTAssertFalse(DouyinLiveSite.douyinIsLive(room: [:], envelope: ["room_status": 1]))
        XCTAssertFalse(DouyinLiveSite.douyinIsLive(room: [:], envelope: nil))
        }

        func testFirstTextAndImage() {
        XCTAssertEqual(DouyinLiveSite.firstText([nil, "", "null", "hello"]), "hello")
        XCTAssertEqual(DouyinLiveSite.firstText([["nested"]]), "")
        XCTAssertEqual(
        DouyinLiveSite.firstImageUrl([["https://a/1.jpg", "https://a/2.jpg"]]),
        "https://a/1.jpg"
        )
        XCTAssertEqual(DouyinLiveSite.firstImageUrl(["", "https://a/b.png"]), "https://a/b.png")
        XCTAssertEqual(DouyinLiveSite.firstImageUrl([]), "")
        }

        func testFormatOfUrl() {
        XCTAssertEqual(DouyinLiveSite.formatOfUrl("https://cdn/x.flv"), "flv")
        XCTAssertEqual(DouyinLiveSite.formatOfUrl("https://cdn/x.m3u8"), "hls")
        XCTAssertEqual(DouyinLiveSite.formatOfUrl("https://cdn/x"), "other")
        }

        func testGenerateAnonymousUserUniqueIdShape() {
        let id = DouyinLiveSite.generateAnonymousUserUniqueId(randomDigit: { _ in 5 })
        XCTAssertEqual(id, "7855555555555555555")
        XCTAssertEqual(id.count, 19)
        let random = DouyinLiveSite.generateAnonymousUserUniqueId()
        XCTAssertEqual(random.count, 19)
        XCTAssertTrue(random.hasPrefix("7"))
        }

        func testUnsignedRequestUrlAddsMsToken() {
        let url = DouyinUtils.unsignedRequestUrl(
        baseUrl: "https://live.douyin.com/webcast/room/web/enter/",
        params: ["aid": "6383", "web_rid": "abc"]
        )
        XCTAssertTrue(url.contains("aid=6383"))
        XCTAssertTrue(url.contains("web_rid=abc"))
        XCTAssertTrue(url.contains("msToken="))
        }

        // MARK: - Render data

        func testParseRenderData() throws {
        let html = """
        <html><script>window.RENDER_DATA = {\\"state\\":{\\"appStore\\":{\\"roomInfo\\":{\\"room\\":{\\"id\\":123456,\\"title\\":\\"测试\\",\\"status\\":2}}}}}]\\n</script></html>
        """
        let state = try DouyinLiveSite.parseRenderData(html)
        let appStore = LiveJSON.asMap(state["appStore"])
        let roomInfo = LiveJSON.asMap(appStore?["roomInfo"])
        let room = LiveJSON.asMap(roomInfo?["room"])
        XCTAssertEqual(LiveJSON.asInt(room?["id"]), 123456)
        XCTAssertEqual(LiveJSON.asString(room?["title"]), "测试")
        XCTAssertEqual(LiveJSON.asInt(room?["status"]), 2)
    }

    func testParseRenderDataThrowsWithoutState() {
        XCTAssertThrowsError(try DouyinLiveSite.parseRenderData("<html></html>"))
    }

    /// roomInfo reports a transient failure as a failure (build
    /// 36 item 8 — same reason as Bilibili: the disguise hid
    /// the LIVE badge, zeroed the watching count and discarded
    /// the card's danmaku credentials).
    func testRoomInfoReportsTransientFailure() {
        let site = DouyinLiveSite(fetcher: stubFetcher(data: nil, status: 404))
        let expectation = self.expectation(description: "roomInfo failure")
        site.roomInfo(roomId: "123456") { result in
            if case .failure = result {
                // Expected.
            } else {
                XCTFail("expected failure, got \(result)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - Room-detail dedup (build 36 item 10 leg 4)

    /// `room/web/enter` answer for room "123456": a live room
    /// carrying the `streamUrlJSON` qualities above.
    private var enterJSON: String {
        "{\"data\":{\"data\":[{\"id_str\":\"123456\",\"title\":\"测试\",\"status\":2,\"owner\":{\"nickname\":\"主播\",\"avatar_thumb\":[\"https://a/avatar.jpg\"]},\"cover\":[\"https://a/cover.jpg\"],\"user_count\":100,\"stream_url\":\(streamUrlJSON)}],\"user\":{\"nickname\":\"主播\",\"avatar_thumb\":[]}}}"
    }

    /// Entering a room fires `roomInfo` (danmaku) and `resolve`
    /// (playback) at once on the same resolver; both used to fetch
    /// the room detail separately. They now share one in-flight
    /// load: one `room/web/enter`, and both callers still complete
    /// successfully. Timeout is 10 s: the anonymous-cookie warmup
    /// runs on URLSession.shared (pre-existing, not the injectable
    /// fetcher) and can take a few seconds when it must fail.
    func testConcurrentRoomInfoAndResolveShareOneRoomDetailLoad() {
        let fetcher = CountingRoutingFetcher([
            ("room/web/enter", jsonData(enterJSON), 200)
        ])
        let site = DouyinLiveSite(fetcher: fetcher.fetcher)
        let roomInfoExpectation = expectation(description: "roomInfo")
        let resolveExpectation = expectation(description: "resolve")
        var roomInfoOK = false
        var resolveOK = false
        site.roomInfo(roomId: "123456") { result in
            if case .success(let room) = result, room.isLive {
                roomInfoOK = true
            }
            roomInfoExpectation.fulfill()
        }
        site.resolve(roomId: "123456", quality: nil) { result in
            if case .success(let resolution) = result, !resolution.appliedUrls.isEmpty {
                resolveOK = true
            }
            resolveExpectation.fulfill()
        }
        waitForExpectations(timeout: 10)
        XCTAssertTrue(roomInfoOK)
        XCTAssertTrue(resolveOK)
        XCTAssertEqual(fetcher.count(containing: "room/web/enter"), 1)
    }

    /// The shared load fails the same way for both paths: each
    /// gets a transient failure (never a disguised offline), and
    /// the `room/web/enter` request goes out once, not twice
    /// (the HTML fallback also fails, but it is a different URL).
    func testConcurrentRoomInfoAndResolveShareOneFailedLoad() {
        let fetcher = CountingRoutingFetcher([])
        let site = DouyinLiveSite(fetcher: fetcher.fetcher)
        let roomInfoExpectation = expectation(description: "roomInfo failure")
        let resolveExpectation = expectation(description: "resolve failure")
        var roomInfoTransient = false
        var resolveFailed = false
        site.roomInfo(roomId: "123456") { result in
            if case .failure(let error as LiveError) = result, case .offline = error {
                // Disguised offline: wrong.
            } else if case .failure = result {
                roomInfoTransient = true
            }
            roomInfoExpectation.fulfill()
        }
        site.resolve(roomId: "123456", quality: nil) { result in
            if case .failure = result {
                resolveFailed = true
            }
            resolveExpectation.fulfill()
        }
        waitForExpectations(timeout: 10)
        XCTAssertTrue(roomInfoTransient)
        XCTAssertTrue(resolveFailed)
        XCTAssertEqual(fetcher.count(containing: "room/web/enter"), 1)
    }
}

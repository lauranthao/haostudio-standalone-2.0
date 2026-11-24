// HAo Studio 2.0 — Kuaishou site tests (S4 leg B).
//
// Initial-state extraction, room page (author.id rule, poster
// .jpg rule), play qualities (codec rank, merge, labels), and
// one end-to-end resolve via a stub fetcher. No network.
// Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class KuaishouSiteTests: XCTestCase {
    private var roomPageHTML: String {
        """
        <html><head></head><body><script>
        window.__INITIAL_STATE__ = {"liveroom":{"playList":[{"author":{"id":"ks123","name":"主播","description":"测试\\n直播","avatar":"https://a/avatar.jpg"},"liveStream":{"id":"LS123","poster":"https://a/cover","playUrls":{"h264":{"adaptationSet":{"representation":[{"url":"https://cdn1/x.m3u8","name":"超清","level":3,"bitrate":3000000},{"url":"https://cdn1/y.flv","name":"高清","level":2,"bitrate":2000000}]}}}},"gameInfo":{"watchingCount":555},"isLiving":true}]}};
        </script></body></html>
        """
        }

        // MARK: - Initial state

        func testExtractInitialState() throws {
        let state = try KuaishouLiveSite.extractKuaishouInitialState(html: roomPageHTML)
        XCTAssertNotNil(state["liveroom"])
        }

        func testExtractInitialStateConvertsUndefinedToNull() throws {
        let html = "<script>window.__INITIAL_STATE__ = {\"a\": undefined, \"b\": 1};</script>"
        let state = try KuaishouLiveSite.extractKuaishouInitialState(html: html)
        XCTAssertTrue(state["a"] is NSNull)
        XCTAssertEqual(LiveJSON.asInt(state["b"]), 1)
        }

        func testExtractInitialStateThrowsWithoutMarker() {
        XCTAssertThrowsError(try KuaishouLiveSite.extractKuaishouInitialState(html: "<html></html>"))
        }

        // MARK: - Room page

        func testParseRoomPageLive() throws {
        let room = try KuaishouLiveSite.parseKuaishouRoomPage(html: roomPageHTML, roomId: "ks123")
        XCTAssertEqual(room.roomId, "ks123")
        XCTAssertEqual(room.platform, .kuaishou)
        XCTAssertEqual(room.title, "测试 直播")
        XCTAssertEqual(room.streamer, "主播")
        XCTAssertEqual(room.avatar, "https://a/avatar.jpg")
        XCTAssertEqual(room.cover, "https://a/cover.jpg")
        XCTAssertEqual(room.onlineCount, 555)
        XCTAssertTrue(room.isLive)
        XCTAssertEqual(room.link, "LS123")
        XCTAssertEqual(room.danmakuData?["liveStreamId"] as? String, "LS123")
        XCTAssertNotNil(room.data?["playUrls"])
        }

        func testParseRoomPageOfflineHasZeroWatching() throws {
        let html = roomPageHTML.replacingOccurrences(of: "\"isLiving\":true", with: "\"isLiving\":false")
        let room = try KuaishouLiveSite.parseKuaishouRoomPage(html: html, roomId: "ks123")
        XCTAssertFalse(room.isLive)
        XCTAssertEqual(room.onlineCount, 0)
        XCTAssertEqual(room.title, "测试 直播")
        }

        func testParseRoomPageThrowsWithoutRoomMetadata() {
        let html = "<script>window.__INITIAL_STATE__ = {\"liveroom\":{}};</script>"
        XCTAssertThrowsError(try KuaishouLiveSite.parseKuaishouRoomPage(html: html, roomId: "ks123"))
        }

        func testParseRoomPageFallsBackToTopLevelRoom() throws {
        let html = "<script>window.__INITIAL_STATE__ = {\"room\":{\"author\":{\"id\":\"ks999\",\"name\":\"替补\"},\"liveStream\":{\"id\":\"LS999\",\"poster\":\"https://a/p.png\"},\"isLiving\":1}};</script>"
        let room = try KuaishouLiveSite.parseKuaishouRoomPage(html: html, roomId: "ks999")
        XCTAssertEqual(room.roomId, "ks999")
        XCTAssertEqual(room.streamer, "替补")
        XCTAssertTrue(room.isLive)
        XCTAssertEqual(room.cover, "https://a/p.png")
        }

        // MARK: - Play qualities

        private var playUrlsJSON: String {
        """
        {"h264":{"adaptationSet":{"representation":[{"url":"https://cdn1/x.m3u8","name":"超清","level":3,"bitrate":3000000},{"url":"https://cdn1/y.flv","name":"高清","level":2,"bitrate":2000000}]}},"hevc":{"adaptationSet":{"representation":[{"url":"https://cdn2/x.m3u8","name":"超清","level":3,"bitrate":3000000}]}}}
        """
        }

        func testParsePlayQualitiesCodecRankThenSort() {
        let qualities = KuaishouLiveSite.parseKuaishouPlayQualities(jsonObject(playUrlsJSON))
        XCTAssertEqual(qualities.map { $0.name }, ["超清", "高清", "超清 · H.265"])
        XCTAssertEqual(qualities.map { $0.sort }, [3, 2, 3])
        XCTAssertEqual(qualities[0].lines[0].format, "hls")
        XCTAssertEqual(qualities[1].lines[0].format, "flv")
        XCTAssertEqual(qualities[0].id, "超清\0" + "3")
        }

        func testParsePlayQualitiesMergesSameQualityAcrossCdns() {
        let raw = jsonObject("""
        {"h264":{"adaptationSet":{"representation":[{"url":"https://cdn1/x.m3u8","name":"超清","level":3},{"url":"https://cdn2/x.m3u8","name":"超清","level":3}]}}}
        """)
        let qualities = KuaishouLiveSite.parseKuaishouPlayQualities(raw)
        XCTAssertEqual(qualities.count, 1)
        XCTAssertEqual(qualities[0].lines.count, 2)
        XCTAssertEqual(qualities[0].lines.map { $0.name }, ["cdn1", "cdn2"])
    }

    func testParsePlayQualitiesEmpty() {
        XCTAssertTrue(KuaishouLiveSite.parseKuaishouPlayQualities(nil).isEmpty)
        XCTAssertTrue(KuaishouLiveSite.parseKuaishouPlayQualities(jsonObject("{}")).isEmpty)
    }

    // MARK: - Labels / format / poster

    func testNormalizeQualityLabel() {
        XCTAssertEqual(KuaishouLiveSite.normalizeKuaishouQualityLabel("original"), "原画")
        XCTAssertEqual(KuaishouLiveSite.normalizeKuaishouQualityLabel("blue"), "蓝光")
        XCTAssertEqual(KuaishouLiveSite.normalizeKuaishouQualityLabel("uhd"), "超清")
        XCTAssertEqual(KuaishouLiveSite.normalizeKuaishouQualityLabel("hd"), "高清")
        XCTAssertEqual(KuaishouLiveSite.normalizeKuaishouQualityLabel("sd"), "标清")
        XCTAssertEqual(KuaishouLiveSite.normalizeKuaishouQualityLabel("low"), "流畅")
        XCTAssertEqual(KuaishouLiveSite.normalizeKuaishouQualityLabel("蓝光 4M"), "蓝光 4M")
        XCTAssertEqual(KuaishouLiveSite.normalizeKuaishouQualityLabel(""), "默认")
    }

    func testStreamFormatAndPoster() {
        XCTAssertEqual(KuaishouLiveSite.kuaishouStreamFormat("https://cdn/x.m3u8?tx=1"), "hls")
        XCTAssertEqual(KuaishouLiveSite.kuaishouStreamFormat("https://cdn/x.flv"), "flv")
        XCTAssertEqual(KuaishouLiveSite.kuaishouStreamFormat("https://cdn/x"), "other")
        XCTAssertEqual(KuaishouLiveSite.posterUrl("https://a/cover"), "https://a/cover.jpg")
        XCTAssertEqual(KuaishouLiveSite.posterUrl("https://a/cover.png"), "https://a/cover.png")
        XCTAssertEqual(KuaishouLiveSite.posterUrl(""), "")
    }

    // MARK: - Resolve end to end

    func testResolveReturnsFirstQuality() {
        let site = KuaishouLiveSite(fetcher: stubFetcher(data: jsonData(roomPageHTML), status: 200))
        let expectation = self.expectation(description: "resolve")
        site.resolve(roomId: "ks123", quality: nil) { result in
            if case .success(let resolution) = result {
                XCTAssertEqual(resolution.quality?.name, "超清")
                XCTAssertEqual(resolution.appliedUrls, ["https://cdn1/x.m3u8"])
                XCTAssertNil(resolution.refreshAt)
                XCTAssertNil(resolution.invalidAt)
            } else {
                XCTFail("expected success, got \(result)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testResolveOfflineRoomFailsOffline() {
        let html = roomPageHTML.replacingOccurrences(of: "\"isLiving\":true", with: "\"isLiving\":false")
        let site = KuaishouLiveSite(fetcher: stubFetcher(data: jsonData(html), status: 200))
        let expectation = self.expectation(description: "offline")
        site.resolve(roomId: "ks123", quality: nil) { result in
            if case .failure(let error as LiveError) = result {
                if case .offline = error {
                    // Expected.
                } else {
                    XCTFail("expected LiveError.offline, got \(error)")
                }
            } else {
                XCTFail("expected LiveError.offline, got \(result)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - Rate-limit card (live probe 2026-11-24)

    /// A room page carrying the `errorType` rate-limit card is a
    /// transient platform refusal, NOT an offline room: it must
    /// throw `apiRejected` (code 2) so callers can fall back to
    /// data they already hold instead of showing "暂无画面".
    func testParseRoomPageThrowsApiRejectedOnRateLimitCard() {
        let html = "<script>window.__INITIAL_STATE__ = {\"liveroom\":{\"playList\":[{\"author\":{},\"liveStream\":{},\"gameInfo\":{},\"isLiving\":false,\"errorType\":{\"type\":2,\"title\":\"请求过快，请稍后重试\",\"content\":\"浏览其他内容\",\"url\":\"/\"}}]}};</script>"
        XCTAssertThrowsError(try KuaishouLiveSite.parseKuaishouRoomPage(html: html, roomId: "ks123")) { error in
            guard let liveError = error as? LiveError, case .apiRejected(let code, let message) = liveError else {
                XCTFail("expected LiveError.apiRejected, got \(error)")
                return
            }
            XCTAssertEqual(code, 2)
            XCTAssertEqual(message, "请求过快，请稍后重试")
        }
    }

    /// The feeds' `living` flag is dead (verified 2026-11-24:
    /// 48/48 home/list items and 20/20 gameboard items carry
    /// `living: false` while their signed playUrls stream live
    /// FLV): an item with playable URLs is live despite the flag.
    func testRecommendRoomsLivingFalseWithPlayUrlsIsLive() {
        let json = jsonObject("""
        {"data":{"list":[{"gameLiveInfo":[{"liveInfo":[{"id":"LS1","poster":"https://a/p","caption":"cap","watchingCount":"18","living":false,"playUrls":[{"adaptationSet":{"representation":[{"url":"https://cdn1/x.flv","name":"超清","level":3,"bitrate":3000000}]}}],"author":{"id":"ks1","name":"主播","avatar":"https://a/av.jpg","description":"d"}}]}]}]}}
        """)
        let rooms = KuaishouLiveSite.parseRecommendRooms(json)
        XCTAssertEqual(rooms?.count, 1)
        XCTAssertTrue(rooms?[0].isLive ?? false)
        XCTAssertEqual(rooms?[0].onlineCount, 18)
        XCTAssertEqual(rooms?[0].danmakuData?["liveStreamId"] as? String, "LS1")
        XCTAssertNotNil(rooms?[0].data?["playUrls"])
    }

    /// …and an item with the flag false and NO stream URLs is
    /// genuinely offline.
    func testRecommendRoomsLivingFalseWithoutPlayUrlsIsOffline() {
        let json = jsonObject("""
        {"data":{"list":[{"gameLiveInfo":[{"liveInfo":[{"id":"LS1","poster":"https://a/p","caption":"cap","watchingCount":"0","living":false,"author":{"id":"ks1","name":"主播","avatar":"https://a/av.jpg","description":"d"}}]}]}]}}
        """)
        let rooms = KuaishouLiveSite.parseRecommendRooms(json)
        XCTAssertEqual(rooms?.count, 1)
        XCTAssertFalse(rooms?[0].isLive ?? true)
        XCTAssertNil(rooms?[0].data)
    }

    // MARK: - resolutionFromRoom (list-feed fallback)

    func testResolutionFromRoomUsesListPlayUrls() {
        let site = KuaishouLiveSite()
        let room = LiveRoom(roomId: "ks1", platform: .kuaishou, isLive: true, data: ["playUrls": jsonObject(playUrlsJSON)])
        let resolution = site.resolutionFromRoom(room, quality: nil)
        XCTAssertEqual(resolution?.quality?.name, "超清")
        XCTAssertEqual(resolution?.appliedUrls, ["https://cdn1/x.m3u8"])
        XCTAssertEqual(resolution?.qualities.count, 3)
    }

    func testResolutionFromRoomReturnsNilWithoutPlayUrls() {
        let site = KuaishouLiveSite()
        XCTAssertNil(site.resolutionFromRoom(LiveRoom(roomId: "ks1", platform: .kuaishou), quality: nil))
        XCTAssertNil(site.resolutionFromRoom(LiveRoom(roomId: "ks1", platform: .kuaishou, data: ["playUrls": jsonObject("{}")]), quality: nil))
    }

    func testResolutionFromRoomReturnsNilForOtherPlatforms() {
        let site = KuaishouLiveSite()
        let room = LiveRoom(roomId: "1", platform: .huya, isLive: true, data: ["playUrls": jsonObject(playUrlsJSON)])
        XCTAssertNil(site.resolutionFromRoom(room, quality: nil))
    }

    /// roomInfo reports a transient failure as a failure (build
    /// 36 item 8 — same reason as Bilibili: the disguise hid
    /// the LIVE badge, zeroed the watching count and discarded
    /// the card's danmaku credentials — the feed rooms carry
    /// liveStreamId, so a rate-limited roomInfo used to kill
    /// danmaku outright).
    func testRoomInfoReportsTransientFailure() {
        let site = KuaishouLiveSite(fetcher: stubFetcher(data: nil, status: 404))
        let expectation = self.expectation(description: "roomInfo failure")
        site.roomInfo(roomId: "ks123") { result in
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

    /// Entering a room fires `roomInfo` (danmaku) and `resolve`
    /// (playback) at once on the same resolver; both used to fetch
    /// the room page separately. They now share one in-flight load:
    /// one room-page request, and both callers still complete
    /// successfully.
    func testConcurrentRoomInfoAndResolveShareOneRoomDetailLoad() {
        let fetcher = CountingRoutingFetcher([
            ("live.kuaishou.com/u/ks123", jsonData(roomPageHTML), 200)
        ])
        let site = KuaishouLiveSite(fetcher: fetcher.fetcher)
        let roomInfoExpectation = expectation(description: "roomInfo")
        let resolveExpectation = expectation(description: "resolve")
        var roomInfoOK = false
        var resolveOK = false
        site.roomInfo(roomId: "ks123") { result in
            if case .success(let room) = result, room.isLive {
                roomInfoOK = true
            }
            roomInfoExpectation.fulfill()
        }
        site.resolve(roomId: "ks123", quality: nil) { result in
            if case .success(let resolution) = result, !resolution.appliedUrls.isEmpty {
                resolveOK = true
            }
            resolveExpectation.fulfill()
        }
        waitForExpectations(timeout: 5)
        XCTAssertTrue(roomInfoOK)
        XCTAssertTrue(resolveOK)
        XCTAssertEqual(fetcher.count(containing: "live.kuaishou.com/u/ks123"), 1)
    }

    /// The shared load fails the same way for both paths: each
    /// gets a transient failure (never a disguised offline), and
    /// the room-page request goes out once, not twice.
    func testConcurrentRoomInfoAndResolveShareOneFailedLoad() {
        let fetcher = CountingRoutingFetcher([])
        let site = KuaishouLiveSite(fetcher: fetcher.fetcher)
        let roomInfoExpectation = expectation(description: "roomInfo failure")
        let resolveExpectation = expectation(description: "resolve failure")
        var roomInfoTransient = false
        var resolveFailed = false
        site.roomInfo(roomId: "ks123") { result in
            if case .failure(let error as LiveError) = result, case .offline = error {
                // Disguised offline: wrong.
            } else if case .failure = result {
                roomInfoTransient = true
            }
            roomInfoExpectation.fulfill()
        }
        site.resolve(roomId: "ks123", quality: nil) { result in
            if case .failure = result {
                resolveFailed = true
            }
            resolveExpectation.fulfill()
        }
        waitForExpectations(timeout: 5)
        XCTAssertTrue(roomInfoTransient)
        XCTAssertTrue(resolveFailed)
        XCTAssertEqual(fetcher.count(containing: "live.kuaishou.com/u/ks123"), 1)
    }
}

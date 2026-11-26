// HAo Studio 2.0 — Bilibili site tests (S4 leg B).
//
// Room info, danmaku args, play qualities, play-url resolution
// (requested-vs-applied echo), and one end-to-end resolve via a
// routing stub fetcher. No network.
// Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class BilibiliSiteTests: XCTestCase {
    private var roomInfoJSON: String {
        """
        {"code":0,"data":{"room_info":{"room_id":6,"title":"测试直播","live_status":1,"cover":"https://a/cover.jpg","online":1234},"anchor_info":{"base_info":{"uname":"主播","face":"https://a/face.jpg"}}}}
        """
        }

        private var playInfoJSON: String {
        """
        {"code":0,"data":{"playurl_info":{"playurl":{"g_qn_desc":[{"qn":10000,"desc":"原画"},{"qn":400,"desc":"蓝光"},{"qn":250,"desc":"超清"}],"stream":[{"protocol_name":"http_stream","format":[{"format_name":"flv","codec":[{"codec_name":"avc","current_qn":250,"accept_qn":[10000,400,250],"base_url":"/live-bvc/xxx.flv?x=1","url_info":[{"host":"https://cn-gd-ct-01-01.live-play.acgvideo.com","extra":""}]}]}]}]}}}}
        """
        }

        private var navJSON: String {
        """
        {"code":0,"data":{"wbi_img":{"img_url":"https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9420b84077c.png","sub_url":"https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f011814e06a491.png"}}}
        """
        }

        // MARK: - Room info

        func testParseRoomInfoAndBuildRoom() throws {
        let data = try BilibiliLiveSite.parseRoomInfoResponse(jsonObject(roomInfoJSON))
        let room = BilibiliLiveSite.buildRoom(roomInfo: data, roomId: "6", realRoomId: "6", danmakuData: nil)
        XCTAssertEqual(room.roomId, "6")
        XCTAssertEqual(room.platform, .bilibili)
        XCTAssertEqual(room.title, "测试直播")
        XCTAssertEqual(room.streamer, "主播")
        XCTAssertEqual(room.avatar, "https://a/face.jpg@100w.jpg")
        XCTAssertEqual(room.cover, "https://a/cover.jpg")
        XCTAssertEqual(room.onlineCount, 1234)
        XCTAssertTrue(room.isLive)
        XCTAssertEqual(room.link, "https://live.bilibili.com/6")
        }

        func testCarouselRoomCountsAsPlayable() throws {
        // b49fix2 P2-19 (c1e18cf): live_status 2 (carousel, a
        // watchable looping video) counts as playable, like the
        // Flutter port (started at the loop start) — it no longer
        // reports offline. The old testCarouselRoomIsNotLive
        // encoded the pre-fix "report offline" decision and was
        // never updated with it.
        let json = jsonObject(roomInfoJSON.replacingOccurrences(of: "\"live_status\":1", with: "\"live_status\":2"))
        let data = try BilibiliLiveSite.parseRoomInfoResponse(json)
        let room = BilibiliLiveSite.buildRoom(roomInfo: data, roomId: "6", realRoomId: "6", danmakuData: nil)
        XCTAssertTrue(room.isLive)
        }

        func testParseRoomInfoRejectsNonZeroCode() {
        XCTAssertThrowsError(try BilibiliLiveSite.parseRoomInfoResponse(jsonObject("{\"code\":-404,\"message\":\"啥都没有\"}")))
        }

        func testParseRoomInfoThrowsWithoutAnchorInfo() {
        XCTAssertThrowsError(try BilibiliLiveSite.parseRoomInfoResponse(jsonObject("{\"code\":0,\"data\":{\"room_info\":{}}}")))
        }

        // MARK: - Danmaku args

        func testParseDanmakuArgsOfficialFallbackFirst() {
        let data = jsonObject("""
        {"token":"tok","host_list":[{"host":"tx-gz-live-comet-01.chat.bilibili.com","wss_port":443},{"host":"h2.chat.bilibili.com","wss_port":2245}]}
        """)
        let args = BilibiliLiveSite.parseDanmakuArgs(data: data, realRoomId: 6, buvid: "B123")
        XCTAssertEqual(args.roomId, 6)
        XCTAssertEqual(args.token, "tok")
        XCTAssertEqual(args.buvid, "B123")
        XCTAssertEqual(args.serverUrls, [
            "wss://broadcastlv.chat.bilibili.com/sub",
            "wss://tx-gz-live-comet-01.chat.bilibili.com/sub",
            "wss://h2.chat.bilibili.com:2245/sub"
        ])
    }

    // MARK: - Play qualities / resolution

    func testParsePlayQualitiesSortedDesc() throws {
        let qualities = try BilibiliLiveSite.parsePlayQualities(jsonObject(playInfoJSON))
        XCTAssertEqual(qualities.map { $0.id }, ["10000", "400", "250"])
        XCTAssertEqual(qualities.map { $0.name }, ["原画", "蓝光", "超清"])
        XCTAssertEqual(qualities.map { $0.sort }, [10000, 400, 250])
    }

    func testParsePlayUrlResolutionDowngradeEchoesAppliedTier() throws {
        let resolution = try BilibiliLiveSite.parsePlayUrlResolution(jsonObject(playInfoJSON), requestedQualityId: "400")
        XCTAssertEqual(resolution.quality?.id, "250")
        XCTAssertEqual(resolution.appliedUrls, ["https://cn-gd-ct-01-01.live-play.acgvideo.com/live-bvc/xxx.flv?x=1"])
        XCTAssertEqual(resolution.lines.count, 1)
        XCTAssertEqual(resolution.lines[0].format, "flv")
    }

    func testParsePlayUrlResolutionPrefersRequestedTier() throws {
        let json = jsonObject(playInfoJSON.replacingOccurrences(
            of: "\"codec_name\":\"avc\",\"current_qn\":250",
            with: "\"codec_name\":\"avc\",\"current_qn\":400"
        ))
        let resolution = try BilibiliLiveSite.parsePlayUrlResolution(json, requestedQualityId: "400")
        XCTAssertEqual(resolution.quality?.id, "400")
    }

    func testParsePlayUrlResolutionThrowsWithNoCandidates() {
        let json = jsonObject("{\"code\":0,\"data\":{\"playurl_info\":{\"playurl\":{\"g_qn_desc\":[],\"stream\":[]}}}}")
        XCTAssertThrowsError(try BilibiliLiveSite.parsePlayUrlResolution(json, requestedQualityId: nil))
    }

    func testMergeResolutionAttachesLinesToAdvertisedQuality() throws {
        let json = jsonObject(playInfoJSON)
        let qualities = try BilibiliLiveSite.parsePlayQualities(json)
        let parsed = try BilibiliLiveSite.parsePlayUrlResolution(json, requestedQualityId: "400")
        let merged = BilibiliLiveSite.mergeResolution(parsed, into: qualities)
        XCTAssertEqual(merged.quality?.id, "250")
        XCTAssertEqual(merged.quality?.name, "超清")
        XCTAssertFalse(merged.appliedUrls.isEmpty)
        XCTAssertEqual(merged.qualities.map { $0.id }, ["10000", "400", "250"])
        XCTAssertEqual(merged.qualities[2].lines.count, 1)
    }

    // MARK: - Resolve end to end (stub fetcher)

    func testResolveEchoesDowngradedTier() {
        let fetcher = routingFetcher([
            ("getInfoByRoom", jsonData(roomInfoJSON), 200),
            ("getRoomPlayInfo", jsonData(playInfoJSON), 200),
            ("getDanmuInfo", jsonData("{\"code\":0,\"data\":{\"token\":\"tok\",\"host_list\":[]}}"), 200),
            ("nav", jsonData(navJSON), 200)
        ])
        let site = BilibiliLiveSite(fetcher: fetcher)
        let expectation = self.expectation(description: "resolve")
        site.resolve(roomId: "6", quality: LiveQuality(id: "400", name: "蓝光", sort: 400, lines: [])) { result in
            if case .success(let resolution) = result {
                XCTAssertEqual(resolution.quality?.id, "250")
                XCTAssertEqual(resolution.quality?.name, "超清")
                XCTAssertFalse(resolution.appliedUrls.isEmpty)
                XCTAssertEqual(resolution.qualities.map { $0.id }, ["10000", "400", "250"])
            } else {
                XCTFail("expected success, got \(result)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testResolveOfflineRoomFailsOffline() {
        let offline = roomInfoJSON.replacingOccurrences(of: "\"live_status\":1", with: "\"live_status\":0")
        let fetcher = routingFetcher([
            ("getInfoByRoom", jsonData(offline), 200),
            ("nav", jsonData(navJSON), 200)
        ])
        let site = BilibiliLiveSite(fetcher: fetcher)
        let expectation = self.expectation(description: "offline")
        site.resolve(roomId: "6", quality: nil) { result in
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

    /// roomInfo reports a transient failure as a failure (build
    /// 36 item 8): it used to disguise any failure as an offline
    /// room, which hid the LIVE badge the card knew, zeroed the
    /// watching count, and discarded the card's danmaku
    /// credentials — so a rate-limited roomInfo also killed
    /// danmaku for the whole visit. The callers keep the card's
    /// values on failure.
    func testRoomInfoReportsTransientFailure() {
        let site = BilibiliLiveSite(fetcher: stubFetcher(data: nil, status: 404))
        let expectation = self.expectation(description: "roomInfo failure")
        site.roomInfo(roomId: "6") { result in
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
    /// (playback) at once on the same resolver; both used to issue
    /// their own room-info + danmaku-info requests (5 HTTP per
    /// entry). They now share one in-flight load: one
    /// getInfoByRoom + one getDanmuInfo, and both callers still
    /// complete successfully.
    func testConcurrentRoomInfoAndResolveShareOneRoomDetailLoad() {
        let fetcher = CountingRoutingFetcher([
            ("getInfoByRoom", jsonData(roomInfoJSON), 200),
            ("getRoomPlayInfo", jsonData(playInfoJSON), 200),
            ("getDanmuInfo", jsonData("{\"code\":0,\"data\":{\"token\":\"tok\",\"host_list\":[]}}"), 200),
            ("nav", jsonData(navJSON), 200)
        ])
        let site = BilibiliLiveSite(fetcher: fetcher.fetcher)
        let roomInfoExpectation = expectation(description: "roomInfo")
        let resolveExpectation = expectation(description: "resolve")
        var roomInfoOK = false
        var resolveOK = false
        site.roomInfo(roomId: "6") { result in
            if case .success(let room) = result, room.isLive {
                roomInfoOK = true
            }
            roomInfoExpectation.fulfill()
        }
        site.resolve(roomId: "6", quality: nil) { result in
            if case .success(let resolution) = result, !resolution.appliedUrls.isEmpty {
                resolveOK = true
            }
            resolveExpectation.fulfill()
        }
        waitForExpectations(timeout: 5)
        XCTAssertTrue(roomInfoOK)
        XCTAssertTrue(resolveOK)
        XCTAssertEqual(fetcher.count(containing: "getInfoByRoom"), 1)
        XCTAssertEqual(fetcher.count(containing: "getDanmuInfo"), 1)
    }

    /// The shared load fails the same way for both paths: each
    /// gets a transient failure (never a disguised offline), and
    /// the room-info request goes out twice — one shared load plus
    /// its built-in 180 ms retry — not four times.
    func testConcurrentRoomInfoAndResolveShareOneFailedLoad() {
        let fetcher = CountingRoutingFetcher([
            ("getInfoByRoom", nil, 404),
            ("nav", jsonData(navJSON), 200)
        ])
        let site = BilibiliLiveSite(fetcher: fetcher.fetcher)
        let roomInfoExpectation = expectation(description: "roomInfo failure")
        let resolveExpectation = expectation(description: "resolve failure")
        var roomInfoTransient = false
        var resolveFailed = false
        site.roomInfo(roomId: "6") { result in
            if case .failure(let error as LiveError) = result, case .offline = error {
                // Disguised offline: wrong.
            } else if case .failure = result {
                roomInfoTransient = true
            }
            roomInfoExpectation.fulfill()
        }
        site.resolve(roomId: "6", quality: nil) { result in
            if case .failure = result {
                resolveFailed = true
            }
            resolveExpectation.fulfill()
        }
        waitForExpectations(timeout: 5)
        XCTAssertTrue(roomInfoTransient)
        XCTAssertTrue(resolveFailed)
        XCTAssertEqual(fetcher.count(containing: "getInfoByRoom"), 2)
    }
}

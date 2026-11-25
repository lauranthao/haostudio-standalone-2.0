// HAo Studio 2.0 — Douyu site tests (S4 leg B).
//
// Room detail, CDN order (scdn* last, Pure Live comparator),
// play-URL variants, signing fixture, confirmed rate, and one
// end-to-end resolve via a routing stub fetcher. No network.
// Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class DouyuSiteTests: XCTestCase {
    private var liveRoomInfo: [String: Any] {
        [
            "room_id": "123456",
            "room_name": "测试直播",
            "owner_name": "主播",
            "owner_avatar": "https://a/avatar.jpg",
            "room_pic": "https://a/cover.jpg",
            "show_status": 1,
            "videoLoop": 0,
            "room_biz_all": ["hot": 98765]
        ]
    }

    // MARK: - Room detail

    func testParseRoomDetailLive() {
        let room = DouyuLiveSite.parseRoomDetail(liveRoomInfo, roomId: "123456")
        XCTAssertEqual(room.roomId, "123456")
        XCTAssertEqual(room.platform,.douyu)
        XCTAssertEqual(room.title, "测试直播")
        XCTAssertEqual(room.streamer, "主播")
        XCTAssertEqual(room.avatar, "https://a/avatar.jpg")
        XCTAssertEqual(room.cover, "https://a/cover.jpg")
        XCTAssertEqual(room.onlineCount, 98765)
        XCTAssertTrue(room.isLive)
        XCTAssertEqual(room.link, "https://www.douyu.com/123456")
        XCTAssertEqual(room.danmakuData?["roomId"] as? String, "123456")
    }

    func testIsLiveRoomPayloadRules() {
        XCTAssertTrue(DouyuLiveSite.isLiveRoomPayload(liveRoomInfo))
        var replay = liveRoomInfo
        replay["room_name"] = "【回放】测试直播"
        XCTAssertFalse(DouyuLiveSite.isLiveRoomPayload(replay))
        var loop = liveRoomInfo
        loop["videoLoop"] = 1
        XCTAssertFalse(DouyuLiveSite.isLiveRoomPayload(loop))
        var offline = liveRoomInfo
        offline["show_status"] = 0
        XCTAssertFalse(DouyuLiveSite.isLiveRoomPayload(offline))
    }

    // MARK: - Play response / CDN codes

    func testParsePlayResponseRejectsError() {
        XCTAssertThrowsError(try DouyuLiveSite.parsePlayResponse(jsonObject("{\"error\":1,\"msg\":\"房间不存在\"}")))
        let data = try? DouyuLiveSite.parsePlayResponse(jsonObject("{\"error\":0,\"data\":{\"rate\":0}}"))
        XCTAssertEqual(data?["rate"] as? Int, 0)
    }

    func testParseCdnCodesCurrentFirstDeduped() {
        let data = jsonObject("""
        {"cdnsWithName":[{"cdn":"tx"},{"cdn":"ws"},{"cdn":"tx"}],"rtmp_cdn":"ws"}
        """)
        XCTAssertEqual(DouyuLiveSite.parseCdnCodes(data), ["ws", "tx"])
        XCTAssertEqual(DouyuLiveSite.parseCdnCodes(jsonObject("{}")), [""])
        }

        func testParsePlayQualitiesKeepsServerOrder() {
        let playData = jsonObject("""
        {"multirates":[{"rate":0,"name":"原画"},{"rate":1,"name":"超清"},{"rate":2,"name":"高清"}],"rate":0}
        """)
        let qualities = DouyuLiveSite.parsePlayQualities(playData, cdns: ["tx", "ws"])
        XCTAssertEqual(qualities.map { $0.id}, ["0", "1", "2"])
        XCTAssertEqual(qualities.map { $0.name}, ["原画", "超清", "高清"])
        XCTAssertEqual(qualities.map { $0.sort}, [3, 2, 1])
        XCTAssertEqual(qualities[0].lines.map { $0.name}, ["tx", "ws"])
        }

        func testParsePlayQualitiesEmptyFallsBackToDefault() {
        let qualities = DouyuLiveSite.parsePlayQualities(jsonObject("{\"rate\":0}"), cdns: [""])
        XCTAssertEqual(qualities.count, 1)
        XCTAssertEqual(qualities[0].id, "0")
        XCTAssertEqual(qualities[0].name, "默认")
        XCTAssertEqual(qualities[0].lines[0].name, "默认线路")
        }

        // MARK: - Play URL variants

        func testParsePlayUrlCompleteLiveWins() throws {
        let url = try DouyuLiveSite.parsePlayUrl(jsonObject("""
        {"rtmp_live":"https://cdn.douyucdn.cn/live/123456.flv?wsSecret=x","rtmp_url":"https://tx.douyucdn.cn/live/"}
        """))
        XCTAssertEqual(url, "https://cdn.douyucdn.cn/live/123456.flv?wsSecret=x")
        }

        func testParsePlayUrlJoinsBaseAndLive() throws {
        let url = try DouyuLiveSite.parsePlayUrl(jsonObject("""
        {"rtmp_live":"123456.flv?wsSecret=x","rtmp_url":"https://tx.douyucdn.cn/live/"}
        """))
        XCTAssertEqual(url, "https://tx.douyucdn.cn/live/123456.flv?wsSecret=x")
        }

        func testParsePlayUrlFallsBackToPlayerOne() throws {
        let url = try DouyuLiveSite.parsePlayUrl(jsonObject("""
        {"rtmp_live":"","player_1":"https://ws.douyucdn.cn/live/123456.flv"}
        """))
        XCTAssertEqual(url, "https://ws.douyucdn.cn/live/123456.flv")
        }

        func testParsePlayUrlUnescapesEntities() throws {
        let url = try DouyuLiveSite.parsePlayUrl(jsonObject("""
        {"rtmp_live":"https://cdn.douyucdn.cn/live/123456.flv?wsSecret=x&amp;y=1"}
        """))
        XCTAssertEqual(url, "https://cdn.douyucdn.cn/live/123456.flv?wsSecret=x&y=1")
    }

    func testParsePlayUrlThrowsWithNoUrl() {
        XCTAssertThrowsError(try DouyuLiveSite.parsePlayUrl(jsonObject("{\"rtmp_live\":\"\"}")))
    }

    // MARK: - Confirmed rate / format

    func testConfirmedRateRejectsFractions() {
        XCTAssertNil(DouyuLiveSite.confirmedRate(NSNumber(value: 0.5)))
        XCTAssertEqual(DouyuLiveSite.confirmedRate(NSNumber(value: 2)), 2)
        XCTAssertEqual(DouyuLiveSite.confirmedRate("1"), 1)
        XCTAssertNil(DouyuLiveSite.confirmedRate("abc"))
    }

    func testStreamFormat() {
        XCTAssertEqual(DouyuLiveSite.streamFormat("https://cdn/x.m3u8"), "hls")
        XCTAssertEqual(DouyuLiveSite.streamFormat("https://cdn/x.flv"), "flv")
        XCTAssertEqual(DouyuLiveSite.streamFormat("https://cdn/x"), "flv")
    }

    // MARK: - Signing

    func testBuildSignedDataMatchesFixture() throws {
        let key: [String: Any] = [
            "key": "testkey123",
            "rand_str": "RANDSTR9",
            "enc_time": 2,
            "enc_data": "enc",
            "expire_at": 1700003600,
            "is_special": 0
        ]
        let body = try DouyuUtils.buildSignedData(
            encryptionKey: key, roomId: "123456", timestampSeconds: 1700000000
        )
        XCTAssertTrue(body.hasPrefix("enc_data=enc&tt=1700000000&did="))
        XCTAssertTrue(body.contains("auth=aa4c255066d3e2555afe488ddcd781f5"))
        XCTAssertTrue(body.contains("ver=Douyu_new"))
    }

    func testBuildSignedDataThrowsOnExpiredDescriptor() {
        let key: [String: Any] = [
            "key": "testkey123", "rand_str": "RANDSTR9", "enc_time": 2,
            "enc_data": "enc", "expire_at": 1700000000, "is_special": 0
        ]
        XCTAssertThrowsError(try DouyuUtils.buildSignedData(
            encryptionKey: key, roomId: "123456", timestampSeconds: 1700000000
        ))
    }

    // MARK: - Resolve end to end (stub fetcher)

    /// New contract (b49fix2 T2 — first-line early delivery,
    /// deliberate sweep-1 fix, NOT reverted): the first
    /// completion carries only the first playable line, so the
    /// driver opens it at once; the walk banks the full
    /// resolution, and a re-resolve (recovery / line fallback)
    /// returns every line, scdn last, without another chain.
    func testResolveSortsScdnLastAndEchoesConfirmedRate() {
        let fetcher = routingFetcher([
            ("getEncryption", jsonData("{\"code\":0,\"data\":{\"key\":\"testkey123\",\"rand_str\":\"RANDSTR9\",\"enc_time\":2,\"enc_data\":\"enc\",\"expire_at\":9999999999}}"), 200),
            ("getH5PlayV1", jsonData("{\"error\":0,\"data\":{\"rtmp_live\":\"https://cdn.douyucdn.cn/live/123456.flv?wsSecret=x\",\"cdnsWithName\":[{\"cdn\":\"tx\"},{\"cdn\":\"scdn-tx\"},{\"cdn\":\"ws\"}],\"rtmp_cdn\":\"tx\",\"multirates\":[{\"rate\":0,\"name\":\"原画\"},{\"rate\":1,\"name\":\"超清\"}],\"rate\":0}}"), 200)
        ])
        let site = DouyuLiveSite(fetcher: fetcher)
        let firstLine = self.expectation(description: "resolve first line")
        site.resolve(roomId: "123456", quality: nil) { result in
            if case.success(let resolution) = result {
                XCTAssertEqual(resolution.quality?.id, "0")
                XCTAssertEqual(resolution.quality?.name, "原画")
                XCTAssertEqual(resolution.quality?.lines.map { $0.name}, ["tx"])
                XCTAssertEqual(resolution.appliedUrls, ["https://cdn.douyucdn.cn/live/123456.flv?wsSecret=x"])
            } else {
                XCTFail("expected success, got \(result)")
            }
            firstLine.fulfill()
        }
        waitForExpectations(timeout: 5)
        let bankedFull = self.expectation(description: "resolve banked full")
        site.resolve(roomId: "123456", quality: nil) { result in
            if case .success(let resolution) = result {
                XCTAssertEqual(resolution.quality?.lines.map { $0.name}, ["tx", "ws", "scdn-tx"])
                XCTAssertEqual(resolution.appliedUrls, ["https://cdn.douyucdn.cn/live/123456.flv?wsSecret=x"])
            } else {
                XCTFail("expected success, got \(result)")
            }
            bankedFull.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    /// roomInfo reports a transient failure as a failure (build
    /// 36 item 8 — same reason as Bilibili: the disguise hid
    /// the LIVE badge, zeroed the watching count and discarded
    /// the card's danmaku credentials).
    func testRoomInfoReportsTransientFailure() {
        let site = DouyuLiveSite(fetcher: stubFetcher(data: nil, status: 404))
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

    // MARK: - Room-detail dedup (build 36 item 10 leg 4, control)

    /// Douyu is the control: `resolve` never calls `roomInfo`
    /// (it goes straight to play data), so there is nothing to
    /// dedup — the betard request still goes out exactly once
    /// while a resolve runs concurrently, and both callers still
    /// complete successfully.
    func testConcurrentRoomInfoAndResolveFetchRoomInfoOnce() {
        let fetcher = CountingRoutingFetcher([
            ("betard/123456", jsonData("{\"room\":{\"room_id\":\"123456\",\"room_name\":\"测试直播\",\"owner_name\":\"主播\",\"owner_avatar\":\"https://a/avatar.jpg\",\"room_pic\":\"https://a/cover.jpg\",\"room_biz_all\":{\"hot\":999},\"show_status\":1}}"), 200),
            ("getEncryption", jsonData("{\"code\":0,\"data\":{\"key\":\"testkey123\",\"rand_str\":\"RANDSTR9\",\"enc_time\":2,\"enc_data\":\"enc\",\"expire_at\":9999999999}}"), 200),
            ("getH5PlayV1", jsonData("{\"error\":0,\"data\":{\"rtmp_live\":\"https://cdn.douyucdn.cn/live/123456.flv?wsSecret=x\",\"cdnsWithName\":[{\"cdn\":\"tx\"},{\"cdn\":\"scdn-tx\"},{\"cdn\":\"ws\"}],\"rtmp_cdn\":\"tx\",\"multirates\":[{\"rate\":0,\"name\":\"原画\"},{\"rate\":1,\"name\":\"超清\"}],\"rate\":0}}"), 200)
        ])
        let site = DouyuLiveSite(fetcher: fetcher.fetcher)
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
        waitForExpectations(timeout: 5)
        XCTAssertTrue(roomInfoOK)
        XCTAssertTrue(resolveOK)
        XCTAssertEqual(fetcher.count(containing: "betard/123456"), 1)
    }
}

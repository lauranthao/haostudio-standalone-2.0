// HAo Studio 2.0 — Huya site tests (S4 leg B).
//
// Room-page fixture (TT_ROOM_DATA + stream:), quality menu,
// static play URLs, end-to-end resolve via a stub fetcher.
// No network. Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class HuyaSiteTests: XCTestCase {
    private var roomPageHTML: String {
        """
        <html><head><script>var TT_ROOM_DATA = {"state":"ON","isReplay":false};</script></head><body><script>
        stream: {"data":[{"gameLiveInfo":{"introduction":"测试直播","nick":"主播名","avatar180":"https://a/avatar.jpg","screenshot":"https://a/cover.jpg","totalCount":"1234567","userCount":"999","uid":98765,"gid":1},"gameStreamInfoList":[{"lChannelId":111,"lSubChannelId":222,"sFlvUrl":"https://al.huya.com","sHlsUrl":"https://al.huya.com","sFlvAntiCode":"wsSecret=s&wsTime=6553f5a0","sHlsAntiCode":"wsSecret=h&wsTime=6553f5a0&ratio=1000","sStreamName":"stream-1","sCdnType":"AL","presenterUid":98765}]}],"vMultiStreamInfo":[{"sDisplayName":"原画","iBitRate":0},{"sDisplayName":"蓝光","iBitRate":2000},{"sDisplayName":"4K","iBitRate":8000},{"sDisplayName":"超清","iBitRate":1000},{"sDisplayName":"蓝光HDR","iBitRate":3000}]
        }
        </script></body></html>
        """
    }

    // MARK: - Room page

    func testParseRoomPageLive() throws {
        let room = try HuyaLiveSite.parseHuyaRoomPage(html: roomPageHTML, roomId: "123456")
        XCTAssertEqual(room.roomId, "123456")
        XCTAssertEqual(room.platform, .huya)
        XCTAssertEqual(room.title, "测试直播")
        XCTAssertEqual(room.streamer, "主播名")
        XCTAssertEqual(room.avatar, "https://a/avatar.jpg")
        XCTAssertEqual(room.cover, "https://a/cover.jpg")
        XCTAssertEqual(room.onlineCount, 1234567)
        XCTAssertTrue(room.isLive)
        XCTAssertEqual(room.link, "https://www.huya.com/123456")
        let danmaku = room.danmakuData
        XCTAssertEqual(danmaku?["uid"] as? Int, 98765)
        XCTAssertEqual(danmaku?["topSid"] as? Int, 111)
        XCTAssertEqual(danmaku?["subSid"] as? Int, 222)
        let urlData = HuyaUrlData.fromDataMap(room.data)
        XCTAssertNotNil(urlData)
        XCTAssertEqual(urlData?.lines.count, 2)
        XCTAssertEqual(urlData?.lines[0].lineType, .flv)
        XCTAssertEqual(urlData?.lines[1].lineType, .hls)
        XCTAssertEqual(urlData?.lines[0].streamName, "stream-1")
        // 4K excluded, HDR names skipped by the room parser.
        XCTAssertEqual(urlData?.bitRates.map { $0.bitRate }, [0, 2000, 1000])
        XCTAssertEqual(urlData?.isXingxiu, false)
    }

    func testParseRoomPageOfflineStillReturnsRoom() throws {
        let html = roomPageHTML
            .replacingOccurrences(of: "\"state\":\"ON\"", with: "\"state\":\"OFF\"")
        let room = try HuyaLiveSite.parseHuyaRoomPage(html: html, roomId: "123456")
        XCTAssertFalse(room.isLive)
        XCTAssertEqual(room.title, "测试直播")
        XCTAssertEqual(room.onlineCount, 1234567)
    }

    func testParseRoomPageThrowsWithoutMetadata() {
        XCTAssertThrowsError(try HuyaLiveSite.parseHuyaRoomPage(html: "<html></html>", roomId: "1"))
    }

    func testParseRoomPagePrefersTotalCountForPopularity() throws {
        let html = roomPageHTML
            .replacingOccurrences(of: "\"totalCount\":\"1234567\"", with: "\"totalCount\":\"\"")
        let room = try HuyaLiveSite.parseHuyaRoomPage(html: html, roomId: "123456")
        XCTAssertEqual(room.onlineCount, 999)
    }

    // b38: real Huya room pages carry 65 CRLF in the header before
    // any JSON. NSRegularExpression ranges are UTF-16 offsets; the
    // old extractJsonObject counted them as Character offsets and
    // landed inside the JSON, returning a nested object with no
    // `state` / `data` — every room failed with "虎牙房间流数据不可用".
    // A CRLF-heavy header must parse exactly like the plain fixture.
    func testParseRoomPageWithCRLFHeader() throws {
        let padding = String(repeating: "<!-- pad -->\r\n", count: 80)
        let room = try HuyaLiveSite.parseHuyaRoomPage(html: padding + roomPageHTML, roomId: "123456")
        XCTAssertEqual(room.roomId, "123456")
        XCTAssertEqual(room.title, "测试直播")
        XCTAssertEqual(room.streamer, "主播名")
        XCTAssertTrue(room.isLive)
        XCTAssertEqual(room.onlineCount, 1234567)
        XCTAssertEqual(HuyaUrlData.fromDataMap(room.data)?.lines.count, 2)
    }

    func testExtractJsonObjectWithCRLFBeforeMatch() {
        let text = String(repeating: "x\r\n", count: 65)
            + "var TT_ROOM_DATA = {\"state\":\"ON\",\"profileRoom\":770714};"
        let object = HuyaLiveSite.extractJsonObject(text, pattern: "var\\s+TT_ROOM_DATA\\s*=\\s*(\\{[\\s\\S]*?\\})")
        XCTAssertEqual(object?["state"] as? String, "ON")
        XCTAssertEqual(object?["profileRoom"] as? Int, 770714)
    }

    // MARK: - Native FLV credential (ctype allowlist)

    // b38: WUP tokens carry the requesting SDK as ctype — huya_ios /
    // tv_huya_nftv / huya_adr / huya_pc_exe, all with t=100 (real
    // probe URLs). Only huya_pc_exe was accepted before, so ~3/4 of
    // native tokens were misjudged as short-lease and refreshed early.
    func testHasNativeFlvCredentialAcceptsAllSdkClientTypes() {
        for ctype in ["huya_pc_exe", "huya_ios", "tv_huya_nftv", "huya_adr"] {
            let url = "https://al.flv.huya.com/src/stream-1.flv?wsSecret=x&wsTime=6b05a576&ctype=\(ctype)&ver=1&fs=gctex&t=100"
            XCTAssertTrue(HuyaLiveSite.hasNativeFlvCredential(url), ctype)
        }
        XCTAssertFalse(HuyaLiveSite.hasNativeFlvCredential("https://al.flv.huya.com/src/stream-1.flv?wsSecret=x&wsTime=6b05a576&ctype=huya_webh5&ver=1&fs=gctex&t=100"))
        XCTAssertFalse(HuyaLiveSite.hasNativeFlvCredential("https://al.flv.huya.com/src/stream-1.flv?wsSecret=x&wsTime=6b05a576&ctype=huya_ios&ver=1&fs=gctex&t=200"))
        XCTAssertFalse(HuyaLiveSite.hasNativeFlvCredential("https://al.flv.example.com/src/stream-1.flv?ctype=huya_ios&t=100"))
        XCTAssertFalse(HuyaLiveSite.hasNativeFlvCredential("https://al.huya.com/stream-1.m3u8?ctype=huya_ios&t=100"))
    }

    // MARK: - Quality menu

    func testParsePlayQualitiesExcludes4KAndSortsSourceFirst() {
        let lines = [
            HuyaLine(baseUrl: "https://al.huya.com", lineType: .flv, cdnType: "AL"),
            HuyaLine(baseUrl: "https://al.huya.com", lineType: .hls, cdnType: "AL")
        ]
        let rates = [
            HuyaBitRate(bitRate: 1000, name: "超清"),
            HuyaBitRate(bitRate: 8000, name: "4K"),
            HuyaBitRate(bitRate: 2000, name: "蓝光"),
            HuyaBitRate(bitRate: 0, name: "原画"),
            HuyaBitRate(bitRate: 2000, name: "蓝光")
        ]
        let qualities = HuyaLiveSite.parseHuyaPlayQualities(lines: lines, bitRates: rates)
        XCTAssertEqual(qualities.map { $0.id }, ["0", "2000", "1000"])
        XCTAssertEqual(qualities.map { $0.name }, ["原画", "蓝光", "超清"])
        XCTAssertEqual(qualities[0].sort, 1 << 30)
        XCTAssertEqual(qualities[0].lines.count, 2)
        XCTAssertEqual(qualities[0].lines[0].format, "flv")
        XCTAssertEqual(qualities[0].lines[1].format, "hls")
    }

    func testParsePlayQualitiesEmptyRatesBecomeSingleSource() {
        let lines = [HuyaLine(baseUrl: "https://al.huya.com", lineType: .flv, cdnType: "AL")]
        let qualities = HuyaLiveSite.parseHuyaPlayQualities(lines: lines, bitRates: [])
        XCTAssertEqual(qualities.count, 1)
        XCTAssertEqual(qualities[0].id, "0")
        XCTAssertEqual(qualities[0].name, "原画")
    }

    // MARK: - Play URLs (static anti-codes, no signing)

    func testGetPlayUrlHlsAppendsCodecAndKeepsRatio() {
        let site = HuyaLiveSite(fetcher: stubFetcher(data: nil, status: 404))
        let line = HuyaLine(
            baseUrl: "https://al.huya.com", lineType: .hls,
            hlsAntiCode: "wsSecret=h&wsTime=6553f5a0&ratio=1000",
            streamName: "stream-1", cdnType: "AL"
        )
        let expectation = self.expectation(description: "hls url")
        site.getPlayUrl(line: line, bitRate: 1000) { result in
            if case .success(let url) = result {
                XCTAssertEqual(url, "https://al.huya.com/stream-1.m3u8?wsSecret=h&wsTime=6553f5a0&ratio=1000&codec=264")
            } else {
                XCTFail("expected success, got \(result)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testGetPlayUrlFlvStaticFallsBackFromFailedWup() {
        let site = HuyaLiveSite(fetcher: stubFetcher(data: nil, status: 404))
        let line = HuyaLine(
            baseUrl: "https://al.huya.com", lineType: .flv,
            flvAntiCode: "wsSecret=s&wsTime=6553f5a0",
            streamName: "stream-1", cdnType: "AL", presenterUid: 98765
        )
        let expectation = self.expectation(description: "flv url")
        site.getPlayUrl(line: line, bitRate: 0) { result in
            if case .success(let url) = result {
                XCTAssertEqual(url, "https://al.huya.com/stream-1.flv?wsSecret=s&wsTime=6553f5a0&codec=264")
            } else {
                XCTFail("expected success, got \(result)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testGetPlayUrlFailsWithEmptyAntiCode() {
        let site = HuyaLiveSite(fetcher: stubFetcher(data: nil, status: 404))
        let line = HuyaLine(baseUrl: "https://al.huya.com", lineType: .hls, streamName: "stream-1", cdnType: "AL")
        let expectation = self.expectation(description: "empty anti-code")
        site.getPlayUrl(line: line, bitRate: 0) { result in
            if case .failure = result {
                // Expected: no HLS anti-code at all.
            } else {
                XCTFail("expected failure, got \(result)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - Resolve end to end

    func testResolveReturnsSourceQualityWithBothLines() {
        let site = HuyaLiveSite(fetcher: stubFetcher(data: jsonData(roomPageHTML), status: 200))
        let expectation = self.expectation(description: "resolve")
        site.resolve(roomId: "123456", quality: nil) { result in
            if case .success(let resolution) = result {
                XCTAssertEqual(resolution.quality?.id, "0")
                XCTAssertEqual(resolution.quality?.name, "原画")
                XCTAssertEqual(resolution.appliedUrls.count, 2)
                XCTAssertTrue(resolution.appliedUrls[0].contains(".flv?"))
                XCTAssertTrue(resolution.appliedUrls[1].contains(".m3u8?"))
                XCTAssertEqual(resolution.qualities.map { $0.id }, ["0", "2000", "1000"])
                XCTAssertNotNil(resolution.refreshAt)
                XCTAssertNotNil(resolution.invalidAt)
            } else {
                XCTFail("expected success, got \(result)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testResolveRequestedQualityEchoesItsId() {
        let site = HuyaLiveSite(fetcher: stubFetcher(data: jsonData(roomPageHTML), status: 200))
        let expectation = self.expectation(description: "resolve 2000")
        site.resolve(roomId: "123456", quality: LiveQuality(id: "2000", name: "蓝光", sort: 2000, lines: [])) { result in
            if case .success(let resolution) = result {
                XCTAssertEqual(resolution.quality?.id, "2000")
                XCTAssertEqual(resolution.quality?.name, "蓝光")
                XCTAssertTrue(resolution.appliedUrls[0].contains("ratio=2000"))
            } else {
                XCTFail("expected success, got \(result)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testResolveOfflineRoomFailsOffline() {
        let html = roomPageHTML.replacingOccurrences(of: "\"state\":\"ON\"", with: "\"state\":\"OFF\"")
        let site = HuyaLiveSite(fetcher: stubFetcher(data: jsonData(html), status: 200))
        let expectation = self.expectation(description: "offline")
        site.resolve(roomId: "123456", quality: nil) { result in
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
    /// 36 item 8 — same reason as Bilibili: the disguise hid
    /// the LIVE badge, zeroed the watching count and discarded
    /// the card's danmaku credentials).
    func testRoomInfoReportsTransientFailure() {
        let site = HuyaLiveSite(fetcher: stubFetcher(data: nil, status: 404))
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

    /// Entering a room fires `roomInfo` (danmaku) and `resolve`
    /// (playback) at once on the same resolver; both used to fetch
    /// the room page separately. They now share one in-flight load:
    /// one room-page request, and both callers still complete
    /// successfully. Unmatched requests (the WUP token calls)
    /// answer with the room page, like the blanket stub fetcher
    /// in the resolve tests — the WUP parse fails and the
    /// web-template anti-code is used instead.
    func testConcurrentRoomInfoAndResolveShareOneRoomDetailLoad() {
        let fetcher = CountingRoutingFetcher(
            [("www.huya.com/123456", jsonData(roomPageHTML), 200)],
            fallback: (jsonData(roomPageHTML), 200))
        let site = HuyaLiveSite(fetcher: fetcher.fetcher)
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
        XCTAssertEqual(fetcher.count(containing: "www.huya.com/123456"), 1)
    }

    /// The shared load fails the same way for both paths: each
    /// gets a transient failure (never a disguised offline), and
    /// the room-page request goes out once, not twice.
    func testConcurrentRoomInfoAndResolveShareOneFailedLoad() {
        let fetcher = CountingRoutingFetcher([])
        let site = HuyaLiveSite(fetcher: fetcher.fetcher)
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
        waitForExpectations(timeout: 5)
        XCTAssertTrue(roomInfoTransient)
        XCTAssertTrue(resolveFailed)
        XCTAssertEqual(fetcher.count(containing: "www.huya.com/123456"), 1)
    }
}

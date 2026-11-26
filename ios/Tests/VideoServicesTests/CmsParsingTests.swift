// HAo Studio 2.0 — CMS parsing tests (S3 leg B).
//
// No network: every case feeds recorded JSON / strings into the
// pure parsers in CmsClient.swift. Swift 5.0: no async/await,
// no `any`.

import XCTest
@testable import AppCore

final class CmsParsingTests: XCTestCase {
    private func source() -> VideoSource {
        VideoSource(id: 1, name: "测试源", apiUrl: "https://example.com/api.php/provide/vod/", kind: "play", enabled: true, sort: 1)
    }

    // MARK: - Play lines

    func testParsePlayLinesM3u8FirstAndNeverDropped() {
        let lines = CmsClient.parsePlayLines(
            playUrl: "第01集$http://x/a.mp4#第02集$http://x/b.mp4$$$第01集$http://y/c.m3u8",
            playFrom: "线路1$$$线路2"
        )
        XCTAssertEqual(lines.count, 2)
        // The m3u8 line sorts first …
        XCTAssertTrue(lines[0].episodes.contains { $0.url?.absoluteString.contains(".m3u8") == true })
        // … and the mp4 line is kept after it, never dropped.
        XCTAssertTrue(lines[1].episodes.contains { $0.url?.absoluteString.contains(".mp4") == true })
        XCTAssertEqual(lines[1].episodes.count, 2)
    }

    func testParsePlayLinesEmptyNameBecomesZhengPianAndNonCjkLineName() {
        let lines = CmsClient.parsePlayLines(
            playUrl: "$http://x/a.m3u8",
            playFrom: "xyz"
        )
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].name, "线路1")
        XCTAssertEqual(lines[0].episodes[0].name, "正片")
        XCTAssertEqual(lines[0].episodes[0].index, 0)
    }

    func testParsePlayLinesSkipsEpisodesWithoutUrl() {
        let lines = CmsClient.parsePlayLines(
            playUrl: "第01集$#第02集$http://x/b.m3u8",
            playFrom: "线路"
        )
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].episodes.count, 1)
        XCTAssertEqual(lines[0].episodes[0].name, "第02集")
    }

    // MARK: - Content fallback

    func testContentFallbackPrefersM3u8OverMp4() {
        let lines = CmsClient.parsePlayLinesWithContentFallback(
            playUrl: "",
            playFrom: "",
            content: "watch <a href=\"http://x/f.mp4\">mp4</a> then http://y/g.m3u8 here"
        )
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].name, "直链")
        XCTAssertEqual(lines[0].episodes[0].name, "正片")
        XCTAssertTrue(lines[0].episodes[0].url?.absoluteString.contains(".m3u8") == true)
    }

    func testContentFallbackReturnsEmptyWhenNoDirectLink() {
        let lines = CmsClient.parsePlayLinesWithContentFallback(
            playUrl: "",
            playFrom: "",
            content: "nothing playable here, just text"
        )
        XCTAssertTrue(lines.isEmpty)
    }

    func testContentFallbackDoesNotOverrideParsedLines() {
        let lines = CmsClient.parsePlayLinesWithContentFallback(
            playUrl: "第01集$http://x/a.m3u8",
            playFrom: "线路",
            content: "http://y/other.mp4"
        )
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].episodes[0].url?.absoluteString.contains("x/a.m3u8") == true)
    }

    // MARK: - Detail

    func testParseCmsDetailRecordedFixture() {
        let json: [String: Any] = [
            "code": 1,
            "list": [[
                "vod_id": "123",
                "vod_name": "狂飙",
                "vod_pic": "http://example.com/pic.jpg",
                "vod_year": "2023",
                "type_name": "国产剧",
                "vod_remarks": "更新至第39集",
                "vod_actor": "张译, 张颂文",
                "vod_score": "8.5",
                "vod_content": "<p>京海市的刑警安欣。</p>",
                "vod_play_from": "线路1",
                "vod_play_url": "第01集$http://x/1.m3u8#第02集$http://x/2.m3u8",
            ]],
        ]
        guard let detail = CmsClient.parseCmsDetail(source: source(), vodId: "123", json: json) else {
            XCTFail("detail should parse")
            return
        }
        XCTAssertEqual(detail.item.title, "狂飙")
        XCTAssertEqual(detail.item.year, "2023")
        XCTAssertEqual(detail.lines.count, 1)
        XCTAssertEqual(detail.lines[0].episodes.count, 2)
        XCTAssertEqual(detail.meta?.cast, ["张译", "张颂文"])
        XCTAssertEqual(detail.meta?.rating, 8.5)
        XCTAssertEqual(detail.meta?.synopsis, "京海市的刑警安欣。")
    }

    func testParseCmsDetailEmptyLinesWhenNoLines() {
        // b49fix5 P2-1 (e58a77b): a title whose play URL yields
        // no lines is NOT nil — it returns a detail with empty
        // lines, so the VM shows "暂无可播剧集" instead of
        // pinning a retry that can never succeed. The old
        // testParseCmsDetailNilWhenNoLines encoded the pre-fix
        // contract (guard !lines.isEmpty -> nil) and was never
        // updated with it.
        let json: [String: Any] = [
            "list": [[
                "vod_id": "123",
                "vod_name": "无源片",
                "vod_play_from": "",
                "vod_play_url": "",
                "vod_content": "",
            ]],
        ]
        guard let detail = CmsClient.parseCmsDetail(source: source(), vodId: "123", json: json) else {
            XCTFail("detail should parse (empty lines, not nil)")
            return
        }
        XCTAssertEqual(detail.item.title, "无源片")
        XCTAssertTrue(detail.lines.isEmpty)
    }

    // MARK: - Probe / dedupe

    func testIsProbeOk() {
        // b49fix2 sweep-4 P2-17 (ae57752): only a NON-EMPTY
        // list[] or class[] counts — a source answering "ok,
        // nothing" (code 0 with an empty list) used to count as
        // healthy and ranked above dead sources. The old
        // assertions below encoded the pre-fix contract
        // (code 0 -> true, empty list/class -> true) and were
        // never updated with it.
        XCTAssertFalse(CmsClient.isProbeOk(["code": 0]))
        XCTAssertFalse(CmsClient.isProbeOk(["list": []]))
        XCTAssertFalse(CmsClient.isProbeOk(["class": []]))
        XCTAssertTrue(CmsClient.isProbeOk(["list": [["vod_id": "1"]]]))
        XCTAssertTrue(CmsClient.isProbeOk(["class": [["type_id": 1]]]))
        XCTAssertFalse(CmsClient.isProbeOk([:]))
        XCTAssertFalse(CmsClient.isProbeOk(["code": 1]))
    }

    func testDedupeAndRankSearchCollapsesSameTitleAndYear() {
        func row(_ id: String, _ title: String, _ sourceId: Int) -> CmsSearchRow {
            CmsSearchRow(
                item: VideoItem(id: id, title: title, coverURL: nil, year: "2023", typeName: nil, remarks: nil, sourceId: sourceId),
                score: 0, hits: 0, area: ""
            )
        }
        let ranked = CmsClient.dedupeAndRankSearch(
            [row("1", "狂飙", 1), row("2", "狂飙", 2), row("3", "狂飙前传", 1)],
            query: "狂飙"
        )
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked[0].title, "狂飙")
    }

    func testDedupeAndRankSearchCapsAtForty() {
        let rows = (0..<50).map { i in
            CmsSearchRow(
                item: VideoItem(id: "\(i)", title: "片名\(i)", coverURL: nil, year: nil, typeName: nil, remarks: nil, sourceId: 1),
                score: 0, hits: 0, area: ""
            )
        }
        XCTAssertEqual(CmsClient.dedupeAndRankSearch(rows, query: "片名").count, 40)
    }

    // MARK: - By-type filters (build 36 item 18)

    private func filterRow(_ title: String, area: String, year: String? = "2024", score: Double = 0, hits: Int = 0) -> CmsSearchRow {
        CmsSearchRow(
            item: VideoItem(id: title, title: title, coverURL: nil, year: year, typeName: "电影", remarks: nil, sourceId: 1),
            score: score, hits: hits, area: area
        )
    }

    func testFilterByTypeItemsAreaAlias() {
        let rows = [
            filterRow("A", area: "中国大陆"),
            filterRow("B", area: "内地"),
            filterRow("C", area: "大陆"),
            filterRow("D", area: "香港"),
            filterRow("E", area: "美国"),
        ]
        XCTAssertEqual(
            CmsClient.filterByTypeItems(rows, area: "大陆", year: "all", by: "").map { $0.title },
            ["A", "B", "C"])
    }

    func testFilterByTypeItemsOtherExcludesKnownAreas() {
        let rows = [
            filterRow("A", area: "中国大陆"),
            filterRow("B", area: "香港"),
            filterRow("C", area: "法国"),
        ]
        XCTAssertEqual(
            CmsClient.filterByTypeItems(rows, area: "other", year: "all", by: "").map { $0.title },
            ["C"])
    }

    func testFilterByTypeItemsEarlierKeeps2021AndBefore() {
        let rows = [
            filterRow("A", area: "大陆", year: "2019"),
            filterRow("B", area: "大陆", year: "2021"),
            filterRow("C", area: "大陆", year: "2022"),
            filterRow("D", area: "大陆", year: nil),
        ]
        XCTAssertEqual(
            CmsClient.filterByTypeItems(rows, area: "all", year: "earlier", by: "").map { $0.title },
            ["A", "B"])
    }

    func testFilterByTypeItemsYearExact() {
        let rows = [
            filterRow("A", area: "大陆", year: "2024"),
            filterRow("B", area: "大陆", year: "2023"),
        ]
        XCTAssertEqual(
            CmsClient.filterByTypeItems(rows, area: "all", year: "2024", by: "").map { $0.title },
            ["A"])
    }

    func testFilterByTypeItemsSortHitsAndScore() {
        let rows = [
            filterRow("A", area: "大陆", score: 7.5, hits: 5),
            filterRow("B", area: "大陆", score: 9.0, hits: 50),
            filterRow("C", area: "大陆", score: 8.0, hits: 20),
        ]
        XCTAssertEqual(
            CmsClient.filterByTypeItems(rows, area: "all", year: "all", by: "hits").map { $0.title },
            ["B", "C", "A"])
        XCTAssertEqual(
            CmsClient.filterByTypeItems(rows, area: "all", year: "all", by: "score").map { $0.title },
            ["B", "C", "A"])
    }

    // MARK: - By-type paging (build 36 item 18)

    /// The filtered byType overload had no callers and its page
    /// math fetched CMS pages -9...0 for logical page 0. These
    /// cases pin the 0-based contract: logical page 0 fetches CMS
    /// page 1 (unfiltered) or the 1...10 window (filtered), and
    /// logical page 1 fetches the 11...20 window.
    func testByTypePageZeroFetchesFirstCmsPages() {
        var requestedPages: [Int] = []
        let fetcher: VideoJSONFetcher = { url, _, completion in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value }
            if value("ac") == "list" {
                completion(["class": [["type_name": "电影", "type_id": "1", "type_pid": "0"]]])
                return
            }
            if let pg = value("pg").flatMap(Int.init) { requestedPages.append(pg) }
            completion([
                "total": 100, "pagecount": 30,
                "list": [[
                    "vod_id": "11", "vod_name": "测试片", "vod_pic": "http://x/a.jpg",
                    "vod_year": "2024", "type_name": "电影", "vod_area": "香港",
                    "vod_score": 8.0, "vod_hits": 10,
                ]],
            ])
        }
        let client = CmsClient(sources: [source()], fetcher: fetcher)

        let unfiltered = expectation(description: "unfiltered page 0")
        client.byType(name: "电影", page: 0) { result in
            XCTAssertEqual(requestedPages, [1])
            XCTAssertEqual(result?.page, 0)
            XCTAssertEqual(result?.pagecount, 30)
            XCTAssertEqual(result?.items.count, 1)
            unfiltered.fulfill()
        }
        waitForExpectations(timeout: 5)

        requestedPages = []
        let filtered = expectation(description: "filtered page 0")
        client.byType(name: "电影", page: 0, area: "香港", year: "all", by: "") { result in
            XCTAssertEqual(requestedPages.sorted(), Array(1...10))
            XCTAssertEqual(result?.page, 0)
            XCTAssertEqual(result?.pagecount, 3)
            XCTAssertEqual(result?.items.count, 10)
            filtered.fulfill()
        }
        waitForExpectations(timeout: 5)

        requestedPages = []
        let filteredPageOne = expectation(description: "filtered page 1")
        client.byType(name: "电影", page: 1, area: "香港", year: "all", by: "") { result in
            XCTAssertEqual(requestedPages.sorted(), Array(11...20))
            XCTAssertEqual(result?.page, 1)
            XCTAssertEqual(result?.pagecount, 3)
            filteredPageOne.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - Play-page second-level fetch (b38 item 7 §4)

    /// Recorded play-page bodies (live probe 2026-11-24): id 1
    /// embeds an absolute .m3u8, id 14 a root-relative one. The
    /// embedded URLs were verified to return real #EXTM3U
    /// playlists the same day.
    private var hongniuPage: String {
        """
        <head><script src="https://s2.pstatp.com/cdn/expire-1-M/hls.js/1.1.5/hls.min.js"></script></head>
        <body><div id="dplayer"></div><script>
        const vid = 'https://hn.bfvvs.com/play/epY9nPma/index.m3u8';
        </script></body>
        """
    }

    private var changzhangPage: String {
        """
        <!DOCTYPE html><html><head>
        <script nonce="x">
        const vid = "305/e1";
        const url = "/play/305/e1/index.m3u8";
        </script></head><body></body></html>
        """
    }

    func testExtractEmbeddedStreamURLAbsolute() {
        let page = URL(string: "https://hn.bfvvs.com/play/epY9nPma")!
        XCTAssertEqual(
            CmsClient.extractEmbeddedStreamURL(html: hongniuPage, pageURL: page)?.absoluteString,
            "https://hn.bfvvs.com/play/epY9nPma/index.m3u8")
    }

    func testExtractEmbeddedStreamURLRootRelative() {
        let page = URL(string: "https://svip.czzyplay.com/share/305/e1")!
        XCTAssertEqual(
            CmsClient.extractEmbeddedStreamURL(html: changzhangPage, pageURL: page)?.absoluteString,
            "https://svip.czzyplay.com/play/305/e1/index.m3u8")
    }

    func testExtractEmbeddedStreamURLNilWhenNoStream() {
        let page = URL(string: "https://x/play/abc")!
        XCTAssertNil(CmsClient.extractEmbeddedStreamURL(html: "<html><body>error</body></html>", pageURL: page))
        XCTAssertNil(CmsClient.extractEmbeddedStreamURL(html: "", pageURL: page))
    }

    func testIsDirectStreamURL() {
        XCTAssertTrue(CmsClient.isDirectStreamURL(URL(string: "https://x/a.m3u8")!))
        XCTAssertTrue(CmsClient.isDirectStreamURL(URL(string: "https://x/a.MP4?token=1")!))
        XCTAssertTrue(CmsClient.isDirectStreamURL(URL(string: "https://x/a.flv")!))
        XCTAssertFalse(CmsClient.isDirectStreamURL(URL(string: "https://x/play/abc")!))
        XCTAssertFalse(CmsClient.isDirectStreamURL(URL(string: "https://x/share/305/e1")!))
        XCTAssertFalse(CmsClient.isDirectStreamURL(URL(string: "https://x/play/abc.html")!))
    }

    private func playDetail(episodes: [PlayEpisode], lineName: String = "线路1") -> (VideoDetail, PlayLine) {
        let line = PlayLine(name: lineName, episodes: episodes)
        let detail = VideoDetail(
            item: VideoItem(id: "1", title: "片", coverURL: nil, year: nil, typeName: nil, remarks: nil, sourceId: 1),
            lines: [line], meta: nil)
        return (detail, line)
    }

    func testResolvePlayURLPassesDirectStreamWithoutFetching() {
        var fetched: [URL] = []
        let textStub: VideoTextFetcher = { url, _, _, completion in
            fetched.append(url)
            completion(200, "<html></html>")
        }
        let client = CmsClient(sources: [source()], fetcher: { _, _, completion in completion(nil) }, textFetcher: textStub)
        let episode = PlayEpisode(name: "第01集", url: URL(string: "https://x/a.m3u8"), index: 0)
        let (detail, line) = playDetail(episodes: [episode])
        let done = expectation(description: "direct resolves")
        client.resolvePlayURL(detail: detail, episode: episode, line: line, excluding: []) { url in
            XCTAssertEqual(url?.absoluteString, "https://x/a.m3u8")
            XCTAssertTrue(fetched.isEmpty, "direct streams must not trigger a page fetch")
            done.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testResolvePlayURLFetchesPageAndExtractsStream() {
        let textStub: VideoTextFetcher = { _, _, _, completion in
            completion(200, self.hongniuPage)
        }
        let client = CmsClient(sources: [source()], fetcher: { _, _, completion in completion(nil) }, textFetcher: textStub)
        let episode = PlayEpisode(name: "第01集", url: URL(string: "https://hn.bfvvs.com/play/epY9nPma"), index: 0)
        let (detail, line) = playDetail(episodes: [episode])
        let done = expectation(description: "page resolves to embedded m3u8")
        client.resolvePlayURL(detail: detail, episode: episode, line: line, excluding: []) { url in
            XCTAssertEqual(url?.absoluteString, "https://hn.bfvvs.com/play/epY9nPma/index.m3u8")
            done.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testResolvePlayURLFallsThroughWhenPageHasNoStream() {
        let textStub: VideoTextFetcher = { _, _, _, completion in
            completion(200, "<html><body>gone</body></html>")
        }
        let client = CmsClient(sources: [source()], fetcher: { _, _, completion in completion(nil) }, textFetcher: textStub)
        let pageEpisode = PlayEpisode(name: "第01集", url: URL(string: "https://x/play/dead"), index: 0)
        let directEpisode = PlayEpisode(name: "第01集", url: URL(string: "https://y/b.m3u8"), index: 0)
        let line1 = PlayLine(name: "线路1", episodes: [pageEpisode])
        let line2 = PlayLine(name: "线路2", episodes: [directEpisode])
        let detail = VideoDetail(
            item: VideoItem(id: "1", title: "片", coverURL: nil, year: nil, typeName: nil, remarks: nil, sourceId: 1),
            lines: [line1, line2], meta: nil)
        let done = expectation(description: "falls through to the direct line")
        client.resolvePlayURL(detail: detail, episode: pageEpisode, line: line1, excluding: []) { url in
            XCTAssertEqual(url?.absoluteString, "https://y/b.m3u8")
            done.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testResolvePlayURLNilWhenNothingResolves() {
        let textStub: VideoTextFetcher = { _, _, _, completion in
            completion(nil, nil)
        }
        let client = CmsClient(sources: [source()], fetcher: { _, _, completion in completion(nil) }, textFetcher: textStub)
        let episode = PlayEpisode(name: "第01集", url: URL(string: "https://x/play/dead"), index: 0)
        let (detail, line) = playDetail(episodes: [episode])
        let done = expectation(description: "nil when nothing resolves")
        client.resolvePlayURL(detail: detail, episode: episode, line: line, excluding: []) { url in
            // The HTML page itself is never handed out: a native
            // player cannot play text/html.
            XCTAssertNil(url)
            done.fulfill()
        }
        waitForExpectations(timeout: 5)
    }
}

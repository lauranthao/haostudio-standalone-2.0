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

    func testParseCmsDetailNilWhenNoLines() {
        let json: [String: Any] = [
            "list": [[
                "vod_id": "123",
                "vod_name": "无源片",
                "vod_play_from": "",
                "vod_play_url": "",
                "vod_content": "",
            ]],
        ]
        XCTAssertNil(CmsClient.parseCmsDetail(source: source(), vodId: "123", json: json))
    }

    // MARK: - Probe / dedupe

    func testIsProbeOk() {
        XCTAssertTrue(CmsClient.isProbeOk(["code": 0]))
        XCTAssertTrue(CmsClient.isProbeOk(["list": []]))
        XCTAssertTrue(CmsClient.isProbeOk(["class": []]))
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
}

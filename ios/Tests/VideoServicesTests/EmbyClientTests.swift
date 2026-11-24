// HAo Studio 2.0 — Emby client tests (b35 sweep).
//
// Regression tests for the build-35 Emby sweep: the API-prefix
// memory (a root-only server worked in the Settings probe but
// failed every data call, because the prefix lived only in the
// probe's short-lived client), the one-shot 404 prefix retry,
// the empty/failed-season dead lines in series detail, and the
// strict query-value encoding of the stream token. Pure
// functions + canned fetchers, no network. Swift 5.0.

import XCTest
@testable import AppCore

final class EmbyClientTests: XCTestCase {
    private let baseUrl = "http://emby.local:8096"

    private func client(useEmbyPrefix: Bool = true, fetcher: @escaping EmbyFetcher) -> EmbyClient {
        let config = EmbyServerConfig(baseUrl: baseUrl, apiKey: "k", userId: "u1", useEmbyPrefix: useEmbyPrefix)
        return EmbyClient(config: config, fetcher: fetcher)
    }

    // MARK: - API prefix

    func testRootOnlyServerLibrariesSucceedViaRetry() {
        var requestCount = 0
        let fetcher: EmbyFetcher = { url, _, _, completion in
            requestCount += 1
            if url.path.hasPrefix("/emby/") {
                completion(EmbyResponse(statusCode: 404, json: nil))
                return
            }
            completion(EmbyResponse(statusCode: 200, json: [
                "Items": [["Id": "lib1", "Name": "电影", "CollectionType": "movies"]],
            ]))
        }
        let client = client(fetcher: fetcher)
        var result: Result<[EmbyLibrary], EmbyError>?
        client.libraries { result = $0 }
        guard case .success(let libs) = result else {
            return XCTFail("expected libraries success, got \(String(describing: result))")
        }
        XCTAssertEqual(libs.count, 1)
        XCTAssertEqual(libs[0].name, "电影")
        // One 404 on /emby, one success on the root.
        XCTAssertEqual(requestCount, 2)
    }

    func testEmbyPrefixServerUsesOneRequest() {
        var requestCount = 0
        let fetcher: EmbyFetcher = { url, _, _, completion in
            requestCount += 1
            XCTAssertTrue(url.path.hasPrefix("/emby/"), "first request should use /emby, got \(url.path)")
            completion(EmbyResponse(statusCode: 200, json: [
                "Items": [["Id": "lib1", "Name": "电影", "CollectionType": "movies"]],
            ]))
        }
        let client = client(fetcher: fetcher)
        client.libraries { _ in }
        XCTAssertEqual(requestCount, 1)
    }

    func testGenuine404StaysNotFound() {
        var requestCount = 0
        let fetcher: EmbyFetcher = { _, _, _, completion in
            requestCount += 1
            completion(EmbyResponse(statusCode: 404, json: nil))
        }
        let client = client(fetcher: fetcher)
        var result: Result<[EmbyLibrary], EmbyError>?
        client.libraries { result = $0 }
        guard case .failure(let error) = result else {
            return XCTFail("expected failure, got \(String(describing: result))")
        }
        XCTAssertEqual(error.kind, .notFound)
        // Both prefixes tried, no more.
        XCTAssertEqual(requestCount, 2)
    }

    func testStoredRootPrefixIsUsedFirst() {
        var firstPath: String?
        var requestCount = 0
        let fetcher: EmbyFetcher = { url, _, _, completion in
            requestCount += 1
            if firstPath == nil { firstPath = url.path }
            completion(EmbyResponse(statusCode: 200, json: [
                "Items": [["Id": "lib1", "Name": "电影", "CollectionType": "movies"]],
            ]))
        }
        let client = client(useEmbyPrefix: false, fetcher: fetcher)
        client.libraries { _ in }
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(firstPath, "/Users/u1/Views")
    }

    func testProbeReportsWorkingPrefix() {
        var requestCount = 0
        let fetcher: EmbyFetcher = { url, _, _, completion in
            requestCount += 1
            if url.path.contains("System/Info") {
                if url.path.hasPrefix("/emby/") {
                    completion(EmbyResponse(statusCode: 404, json: nil))
                } else {
                    completion(EmbyResponse(statusCode: 200, json: ["ServerName": "E", "Version": "4.8"]))
                }
                return
            }
            completion(EmbyResponse(statusCode: 200, json: [] as [Any]))
        }
        let client = client(fetcher: fetcher)
        var probeResult: EmbyProbeResult?
        client.probe { probeResult = $0 }
        XCTAssertEqual(probeResult?.ok, true)
        XCTAssertEqual(probeResult?.useEmbyPrefix, false)
        XCTAssertEqual(probeResult?.workingBaseUrl, baseUrl)
        // The same client now starts data calls on the root: one
        // request, no 404 + retry.
        requestCount = 0
        client.libraries { _ in }
        XCTAssertEqual(requestCount, 1)
    }

    // MARK: - Series detail

    func testDetailSkipsEmptyAndFailedSeasons() {
        let fetcher: EmbyFetcher = { url, _, _, completion in
            let path = url.path
            if path.contains("/Episodes") {
                let seasonId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "seasonId" })?.value
                switch seasonId {
                case "s1":
                    completion(EmbyResponse(statusCode: 200, json: [
                        "Items": [
                            ["Id": "e1", "Name": "第1集", "Type": "Episode", "IndexNumber": 1],
                            ["Id": "e2", "Name": "第2集", "Type": "Episode", "IndexNumber": 2],
                        ],
                    ]))
                case "s2":
                    completion(EmbyResponse(statusCode: 200, json: ["Items": [] as [Any]]))
                default:
                    completion(EmbyResponse(statusCode: 500, json: nil))
                }
                return
            }
            if path.contains("/Seasons") {
                completion(EmbyResponse(statusCode: 200, json: [
                    "Items": [
                        ["Id": "s1", "Name": "Season 1", "Type": "Season", "IndexNumber": 1],
                        ["Id": "s2", "Name": "Season 2", "Type": "Season", "IndexNumber": 2],
                        ["Id": "s3", "Name": "Season 3", "Type": "Season", "IndexNumber": 3],
                    ],
                ]))
                return
            }
            completion(EmbyResponse(statusCode: 200, json: [
                "Id": "series-1", "Name": "剧", "Type": "Series",
                "ProductionYear": 2024, "Genres": [] as [Any],
                "Overview": "", "People": [] as [Any],
            ]))
        }
        let client = client(fetcher: fetcher)
        var result: Result<VideoDetail, EmbyError>?
        client.detail(itemId: "series-1") { result = $0 }
        guard case .success(let detail) = result else {
            return XCTFail("expected detail success, got \(String(describing: result))")
        }
        // Only the season with episodes survives — no dead empty
        // lines for the empty season or the failed one.
        XCTAssertEqual(detail.lines.count, 1)
        XCTAssertEqual(detail.lines[0].name, "第 1 季")
        XCTAssertEqual(detail.lines[0].episodes.count, 2)
    }

    // MARK: - Stream URL

    func testStreamUrlEncodesTokenStrictly() {
        let config = EmbyServerConfig(baseUrl: baseUrl, apiKey: "a&b=c+d e")
        let client = EmbyClient(config: config)
        let url = client.streamUrl(itemId: "x")
        XCTAssertTrue(url.contains("api_key=a%26b%3Dc%2Bd%20e"), "token must not split the query: \(url)")
        XCTAssertFalse(url.contains("api_key=a&b"), "raw & must not appear in the token")
    }

    // MARK: - Search (build 36, item 17)

    func testSearchSendsSearchTermAndFiltersTrailer() {
        var requestCount = 0
        let fetcher: EmbyFetcher = { url, _, _, completion in
            requestCount += 1
            XCTAssertEqual(url.path, "/emby/Users/u1/Items")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? {
                query.first(where: { $0.name == name })?.value
            }
            XCTAssertEqual(value("searchTerm"), "731")
            XCTAssertEqual(value("IncludeItemTypes"), "Movie,Series,Episode,Video")
            XCTAssertEqual(value("Recursive"), "true")
            completion(EmbyResponse(statusCode: 200, json: [
                "Items": [
                    ["Id": "m1", "Name": "731", "Type": "Movie"],
                    ["Id": "s1", "Name": "剧", "Type": "Series"],
                    ["Id": "e1", "Name": "第1集", "Type": "Episode"],
                    ["Id": "t1", "Name": "预告", "Type": "Trailer"],
                ],
                "TotalRecordCount": 4,
            ]))
        }
        let client = client(fetcher: fetcher)
        var result: Result<EmbyItemsPage, EmbyError>?
        client.search(query: "731") { result = $0 }
        XCTAssertEqual(requestCount, 1)
        guard case .success(let page) = result else {
            return XCTFail("expected search success, got \(String(describing: result))")
        }
        // Trailer is dropped by pageFromJSON; the server's total
        // still counts it.
        XCTAssertEqual(page.items.count, 3)
        XCTAssertEqual(page.items.map { $0.title }, ["731", "剧", "第1集"])
        XCTAssertEqual(page.totalCount, 4)
    }

    func testSearchEmptyReturnsEmptyPage() {
        let fetcher: EmbyFetcher = { _, _, _, completion in
            completion(EmbyResponse(statusCode: 200, json: [
                "Items": [] as [Any],
                "TotalRecordCount": 0,
            ]))
        }
        let client = client(fetcher: fetcher)
        var result: Result<EmbyItemsPage, EmbyError>?
        client.search(query: "nonsense") { result = $0 }
        guard case .success(let page) = result else {
            return XCTFail("expected search success, got \(String(describing: result))")
        }
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(page.totalCount, 0)
    }

    func testSearchFailureMapsToError() {
        // 401 (wrong key) -> unauthorized; transport failure
        // (status 0) -> unreachable. Neither is swallowed to [].
        let unauthorizedFetcher: EmbyFetcher = { _, _, _, completion in
            completion(EmbyResponse(statusCode: 401, json: nil))
        }
        var result: Result<EmbyItemsPage, EmbyError>?
        client(fetcher: unauthorizedFetcher).search(query: "731") { result = $0 }
        guard case .failure(let error) = result else {
            return XCTFail("expected 401 failure, got \(String(describing: result))")
        }
        XCTAssertEqual(error.kind, .unauthorized)

        let unreachableFetcher: EmbyFetcher = { _, _, _, completion in
            completion(EmbyResponse(statusCode: 0, json: nil))
        }
        result = nil
        client(fetcher: unreachableFetcher).search(query: "731") { result = $0 }
        guard case .failure(let unreachableError) = result else {
            return XCTFail("expected status-0 failure, got \(String(describing: result))")
        }
        XCTAssertEqual(unreachableError.kind, .unreachable)
    }

    func testSearchEpisodeResultPlaysAsSingleEpisode() {
        let fetcher: EmbyFetcher = { url, _, _, completion in
            if url.path.contains("ep1") {
                completion(EmbyResponse(statusCode: 200, json: [
                    "Id": "ep1", "Name": "第5集", "Type": "Episode",
                ]))
                return
            }
            completion(EmbyResponse(statusCode: 200, json: [
                "Id": "mov1", "Name": "731", "Type": "Movie",
            ]))
        }
        let client = client(fetcher: fetcher)
        // An episode hit plays that episode directly: one line,
        // one episode, named after the episode itself.
        var episodeResult: Result<VideoDetail, EmbyError>?
        client.detail(itemId: "ep1") { episodeResult = $0 }
        guard case .success(let episodeDetail) = episodeResult else {
            return XCTFail("expected episode detail success, got \(String(describing: episodeResult))")
        }
        XCTAssertEqual(episodeDetail.lines.count, 1)
        XCTAssertEqual(episodeDetail.lines[0].episodes.count, 1)
        XCTAssertEqual(episodeDetail.lines[0].episodes[0].name, "第5集")
        // A movie hit: one line ("直链") + one episode ("正片").
        var movieResult: Result<VideoDetail, EmbyError>?
        client.detail(itemId: "mov1") { movieResult = $0 }
        guard case .success(let movieDetail) = movieResult else {
            return XCTFail("expected movie detail success, got \(String(describing: movieResult))")
        }
        XCTAssertEqual(movieDetail.lines.count, 1)
        XCTAssertEqual(movieDetail.lines[0].name, "直链")
        XCTAssertEqual(movieDetail.lines[0].episodes.count, 1)
        XCTAssertEqual(movieDetail.lines[0].episodes[0].name, "正片")
    }

    func testSearchUsesStoredRootPrefix() {
        var firstPath: String?
        var requestCount = 0
        let fetcher: EmbyFetcher = { url, _, _, completion in
            requestCount += 1
            if firstPath == nil { firstPath = url.path }
            completion(EmbyResponse(statusCode: 200, json: [
                "Items": [["Id": "m1", "Name": "731", "Type": "Movie"]],
                "TotalRecordCount": 1,
            ]))
        }
        let client = client(useEmbyPrefix: false, fetcher: fetcher)
        var result: Result<EmbyItemsPage, EmbyError>?
        client.search(query: "731") { result = $0 }
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(firstPath, "/Users/u1/Items")
        guard case .success(let page) = result else {
            return XCTFail("expected search success, got \(String(describing: result))")
        }
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].title, "731")
    }
    // MARK: - Build 36, item 14: subtitle / track facts (G-B)

    func testEmbyFactsParseSubtitleStreams() {
        let mediaSources: [[String: Any]] = [[
            "Id": "ms1",
            "Container": "mkv",
            "MediaStreams": [
                ["Type": "Video", "Codec": "hevc", "Width": 3840, "Height": 2160],
                ["Type": "Audio", "Codec": "aac", "IsDefault": true],
                ["Type": "Audio", "Codec": "ac3"],
                ["Type": "Subtitle", "Codec": "ass", "Language": "zho", "IsDefault": true],
                ["Type": "Subtitle", "Codec": "srt", "Language": "eng", "IsExternal": true, "Index": 2],
            ],
        ]]
        let facts = EmbyStreamFacts.fromMediaSources(mediaSources)
        XCTAssertTrue(facts.hasAssSubtitles)
        XCTAssertTrue(facts.hasSubtitleTracks)
        XCTAssertTrue(facts.hasMultipleAudioTracks)
        XCTAssertEqual(facts.audioTrackCount, 2)
        XCTAssertEqual(facts.externalSubtitles.count, 1)
        XCTAssertEqual(facts.externalSubtitles.first?.index, 2)
        XCTAssertEqual(facts.externalSubtitles.first?.codec, "srt")
        XCTAssertEqual(facts.mediaSourceId, "ms1")
        let params = facts.toQueryParams()
        XCTAssertEqual(params["hao_sub"], "ass")
        XCTAssertEqual(params["hao_atracks"], "2")
        XCTAssertEqual(params["hao_extsub"], "2:srt:eng")
        XCTAssertEqual(params["hao_msrc"], "ms1")
    }

    func testEmbyFactsWithoutSubtitlesHasNoMarkers() {
        let mediaSources: [[String: Any]] = [[
            "Container": "mp4",
            "MediaStreams": [
                ["Type": "Video", "Codec": "h264"],
                ["Type": "Audio", "Codec": "aac", "IsDefault": true],
            ],
        ]]
        let facts = EmbyStreamFacts.fromMediaSources(mediaSources)
        XCTAssertFalse(facts.hasAssSubtitles)
        XCTAssertFalse(facts.hasSubtitleTracks)
        XCTAssertFalse(facts.hasMultipleAudioTracks)
        XCTAssertNil(facts.toQueryParams()["hao_sub"])
        // One audio track still rides the marker (count 1); only
        // >= 2 sets hasMultipleAudioTracks.
        XCTAssertEqual(facts.toQueryParams()["hao_atracks"], "1")
    }

    func testStreamUrlCarriesSubtitleMarkers() {
        let mediaSources: [[String: Any]] = [[
            "Id": "ms1",
            "Container": "mp4",
            "MediaStreams": [
                ["Type": "Video", "Codec": "h264"],
                ["Type": "Audio", "Codec": "aac", "IsDefault": true],
                ["Type": "Audio", "Codec": "ac3"],
                ["Type": "Subtitle", "Codec": "ass", "Language": "zho"],
            ],
        ]]
        let facts = EmbyStreamFacts.fromMediaSources(mediaSources)
        let config = EmbyServerConfig(baseUrl: baseUrl, apiKey: "k", userId: "u1")
        let client = EmbyClient(config: config)
        let url = client.streamUrl(itemId: "x", facts: facts)
        XCTAssertTrue(url.contains("hao_sub=ass"), url)
        XCTAssertTrue(url.contains("hao_atracks=2"), url)
    }

    // MARK: - Build 36, item 14: subtitle + transcode URLs (G-G / G-H)

    func testSubtitleUrlBuilder() {
        let config = EmbyServerConfig(baseUrl: baseUrl, apiKey: "k", userId: "u1", useEmbyPrefix: true)
        let client = EmbyClient(config: config)
        XCTAssertEqual(
            client.subtitleUrl(itemId: "abc", mediaSourceId: "ms1", index: 2),
            "http://emby.local:8096/emby/Videos/abc/ms1/Subtitles/2?api_key=k")
        XCTAssertEqual(
            client.transcodedHlsUrl(itemId: "abc"),
            "http://emby.local:8096/emby/Videos/abc/master.m3u8?static=true&api_key=k")
    }

    func testStaticSubtitleAndTranscodeUrlsFromStreamUrl() {
        let stream = "http://emby.local:8096/emby/Videos/abc/stream?static=true&api_key=k&hao_container=mkv"
        XCTAssertEqual(
            EmbyClient.subtitleUrl(fromStreamUrl: stream, mediaSourceId: "ms1", index: 2)?.absoluteString,
            "http://emby.local:8096/emby/Videos/abc/ms1/Subtitles/2?api_key=k")
        XCTAssertEqual(
            EmbyClient.transcodedHlsUrl(fromStreamUrl: stream)?.absoluteString,
            "http://emby.local:8096/emby/Videos/abc/master.m3u8?static=true&api_key=k")
        XCTAssertNil(EmbyClient.transcodedHlsUrl(fromStreamUrl: "https://a.b/movie.mp4"))
        XCTAssertNil(EmbyClient.subtitleUrl(fromStreamUrl: "https://a.b/movie.mp4", mediaSourceId: "ms1", index: 0))
    }

    // MARK: - Build 38: server continue watching (Resume)

    /// Resume fixture: one in-progress film, one in-progress
    /// episode, one finished film (position 0 — dropped), one
    /// item with no UserData at all (dropped).
    private func resumeFixture() -> [String: Any] {
        [
            "Items": [
                [
                    "Id": "mov1", "Name": "731", "Type": "Movie",
                    "ProductionYear": 2025,
                    "RunTimeTicks": 72_000_000_000,
                    "UserData": ["PlaybackPositionTicks": 6_000_000_000, "Played": false],
                ],
                [
                    "Id": "ep9", "Name": "第2集", "Type": "Episode",
                    "ProductionYear": 2024,
                    "RunTimeTicks": 27_000_000_000,
                    "UserData": ["PlaybackPositionTicks": 3_000_000_000, "Played": false],
                ],
                [
                    "Id": "mov2", "Name": "看完的", "Type": "Movie",
                    "RunTimeTicks": 60_000_000_000,
                    "UserData": ["PlaybackPositionTicks": 0, "Played": true],
                ],
                [
                    "Id": "mov3", "Name": "没数据", "Type": "Movie",
                    "RunTimeTicks": 60_000_000_000,
                ],
            ],
            "TotalRecordCount": 4,
        ]
    }

    func testResumeItemsKeepsOnlyInProgressWithPositions() {
        let fixture = resumeFixture()
        let fetcher: EmbyFetcher = { _, _, _, completion in
            completion(EmbyResponse(statusCode: 200, json: fixture))
        }
        let client = client(fetcher: fetcher)
        var result: Result<[EmbyResumeItem], EmbyError>?
        client.resumeItems { result = $0 }
        guard case .success(let items) = result else {
            return XCTFail("expected resume success, got \(String(describing: result))")
        }
        XCTAssertEqual(items.count, 2)
        // Film: "正片", 600s of 7200s.
        XCTAssertEqual(items[0].item.id, "mov1")
        XCTAssertEqual(items[0].episodeName, "正片")
        XCTAssertEqual(items[0].positionSeconds, 600)
        XCTAssertEqual(items[0].durationSeconds, 7200)
        XCTAssertEqual(items[0].progress, 600.0 / 7200.0, accuracy: 0.001)
        // Episode: keeps its own display name, 300s of 2700s.
        XCTAssertEqual(items[1].item.id, "ep9")
        XCTAssertEqual(items[1].episodeName, "第2集")
        XCTAssertEqual(items[1].positionSeconds, 300)
        XCTAssertEqual(items[1].durationSeconds, 2700)
    }

    func testResumeItemsFailureMapsToError() {
        let fetcher: EmbyFetcher = { _, _, _, completion in
            completion(EmbyResponse(statusCode: 401, json: nil))
        }
        let client = client(fetcher: fetcher)
        var result: Result<[EmbyResumeItem], EmbyError>?
        client.resumeItems { result = $0 }
        guard case .failure(let error) = result else {
            return XCTFail("expected resume failure, got \(String(describing: result))")
        }
        XCTAssertEqual(error.kind, .unauthorized)
    }
}

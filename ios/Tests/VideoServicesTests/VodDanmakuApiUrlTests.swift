// HAo Studio 2.0 — VOD danmaku API URL tests (b36 item 11).
//
// No network: every case feeds strings into the pure assembly /
// validation functions in VodDanmakuApiConfig, or drives
// fetchCandidates with a stub fetcher that captures the URL.
// Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class VodDanmakuApiUrlTests: XCTestCase {
    private let suiteName = "com.haostudio.test.voddanmakuapi"

    override func tearDown() {
        if let suite = UserDefaults(suiteName: suiteName) {
            suite.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    // MARK: - hop-1 assembly

    func testHop1EmptyBaseFallsBackToDefault() {
        let url = VodDanmakuApiConfig.hop1Url(baseUrl: "", token: "", title: "狂飙", episode: "第1集")
        XCTAssertEqual(url?.host, "danmu-api-production-60e143e3.up.railway.app")
        XCTAssertEqual(url?.path, "/api/v2/fongmi/danmaku")
        XCTAssertEqual(url?.query?.contains("name="), true)
    }

    func testHop1TrailingSlashesStripped() {
        let url = VodDanmakuApiConfig.hop1Url(baseUrl: "https://example.com///", token: "", title: "狂飙", episode: "第1集")
        XCTAssertEqual(url?.absoluteString.hasPrefix("https://example.com/api/v2/fongmi/danmaku?"), true)
    }

    func testHop1ProxyPathKept() {
        let url = VodDanmakuApiConfig.hop1Url(baseUrl: "https://example.com/danmu", token: "", title: "狂飙", episode: "第1集")
        XCTAssertEqual(url?.path, "/danmu/api/v2/fongmi/danmaku")
        XCTAssertEqual(url?.host, "example.com")
    }

    func testHop1ProxyPathWithTrailingSlashAndPort() {
        let url = VodDanmakuApiConfig.hop1Url(baseUrl: "https://example.com:8080/danmu/", token: "", title: "狂飙", episode: "第1集")
        XCTAssertEqual(url?.path, "/danmu/api/v2/fongmi/danmaku")
        XCTAssertEqual(url?.port, 8080)
    }

    func testHop1TokenGoesBetweenHostAndApiPath() {
        let url = VodDanmakuApiConfig.hop1Url(baseUrl: "https://example.com", token: "abc123", title: "狂飙", episode: "第1集")
        XCTAssertEqual(url?.path, "/abc123/api/v2/fongmi/danmaku")
    }

    func testHop1TokenOnProxyPath() {
        let url = VodDanmakuApiConfig.hop1Url(baseUrl: "https://example.com/danmu", token: "tok9", title: "狂飙", episode: "第1集")
        XCTAssertEqual(url?.path, "/danmu/tok9/api/v2/fongmi/danmaku")
    }

    func testHop1TokenSlashIsEncodedNotSplit() {
        let url = VodDanmakuApiConfig.hop1Url(baseUrl: "https://example.com", token: "ab/cd", title: "狂飙", episode: "第1集")
        XCTAssertEqual(url?.absoluteString.contains("/ab%2Fcd/api/v2/fongmi/danmaku"), true)
        XCTAssertEqual(url?.absoluteString.contains("/ab/cd/"), false)
    }

    func testHop1TokenQuestionAndHashAreEncoded() {
        let q = VodDanmakuApiConfig.hop1Url(baseUrl: "https://example.com", token: "a?b", title: "狂飙", episode: "第1集")
        XCTAssertEqual(q?.absoluteString.contains("/a%3Fb/api/v2/fongmi/danmaku"), true)
        let h = VodDanmakuApiConfig.hop1Url(baseUrl: "https://example.com", token: "a#b", title: "狂飙", episode: "第1集")
        XCTAssertEqual(h?.absoluteString.contains("/a%23b/api/v2/fongmi/danmaku"), true)
    }

    func testHop1QueryCarriesTitleAndEpisode() {
        let url = VodDanmakuApiConfig.hop1Url(baseUrl: "https://example.com", token: "", title: "狂飙", episode: "第1集")
        let query = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "name" })?.value, "狂飙")
        XCTAssertEqual(query?.first(where: { $0.name == "episode" })?.value, "第1集")
    }

    func testHop1InvalidBaseReturnsNil() {
        XCTAssertNil(VodDanmakuApiConfig.hop1Url(baseUrl: "example.com", token: "", title: "狂飙", episode: "第1集"))
        XCTAssertNil(VodDanmakuApiConfig.hop1Url(baseUrl: "ftp://example.com", token: "", title: "狂飙", episode: "第1集"))
        XCTAssertNil(VodDanmakuApiConfig.hop1Url(baseUrl: "https://", token: "", title: "狂飙", episode: "第1集"))
    }

    // MARK: - Client wiring (stub fetcher captures the URL)

    func testFetchCandidatesUsesTokenPrefix() {
        var captured: URL?
        let fetcher: VodDanmakuFetcher = { url, _, completion in
            captured = url
            completion(VodDanmakuHTTPResult(
                body: "[{\"name\":\"狂飙(2023)from iqiyi - 狂飙第1集\",\"url\":\"https://example.com/api/v2/comment/1?format=xml\"}]",
                statusCode: 200, retryAfterSeconds: nil))
        }
        let client = VodDanmakuClient(
            title: "狂飙", year: "2023",
            baseUrl: "https://example.com/danmu", token: "tok9", fetcher: fetcher)
        let exp = expectation(description: "candidates")
        client.fetchCandidates(title: "狂飙", episode: "第1集") { candidates in
            XCTAssertEqual(candidates?.count, 1)
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
        XCTAssertEqual(captured?.path, "/danmu/tok9/api/v2/fongmi/danmaku")
    }

    func testFetchCandidatesDefaultBaseHasNoPrefix() {
        var captured: URL?
        let fetcher: VodDanmakuFetcher = { url, _, completion in
            captured = url
            completion(VodDanmakuHTTPResult(body: "[]", statusCode: 200, retryAfterSeconds: nil))
        }
        // Empty list retries once after 2 s, then completes nil.
        let client = VodDanmakuClient(title: "狂飙", year: "2023", fetcher: fetcher)
        let exp = expectation(description: "candidates")
        client.fetchCandidates(title: "狂飙", episode: "第1集") { _ in exp.fulfill() }
        waitForExpectations(timeout: 10)
        XCTAssertEqual(captured?.host, "danmu-api-production-60e143e3.up.railway.app")
        XCTAssertEqual(captured?.path, "/api/v2/fongmi/danmaku")
    }

    // MARK: - Effective base + normalization

    func testEffectiveBaseUrlEmptyMeansDefault() {
        XCTAssertEqual(VodDanmakuApiConfig().effectiveBaseUrl, VodDanmakuClient.defaultBaseUrl)
        XCTAssertEqual(VodDanmakuApiConfig(apiUrl: "   ", apiToken: "").effectiveBaseUrl, VodDanmakuClient.defaultBaseUrl)
    }

    func testEffectiveBaseUrlTrimsAndStripsSlash() {
        XCTAssertEqual(
            VodDanmakuApiConfig(apiUrl: "  https://example.com/danmu/ ", apiToken: "").effectiveBaseUrl,
            "https://example.com/danmu")
    }

    func testNormalizedTrimsTokenAndStripsAddressSlash() {
        let norm = VodDanmakuApiConfig(apiUrl: "https://example.com/", apiToken: "  tok9  ").normalized()
        XCTAssertEqual(norm.apiUrl, "https://example.com")
        XCTAssertEqual(norm.apiToken, "tok9")
    }

    func testDisplayHostOnlyForCustomAddress() {
        XCTAssertNil(VodDanmakuApiConfig().displayHost)
        XCTAssertEqual(
            VodDanmakuApiConfig(apiUrl: "https://example.com/danmu", apiToken: "tok9").displayHost,
            "example.com")
    }

    // MARK: - Validation

    func testValidationEmptyIsDefault() {
        XCTAssertNil(VodDanmakuApiConfig.validationError(apiUrl: "", apiToken: ""))
        XCTAssertNil(VodDanmakuApiConfig.validationError(apiUrl: "   ", apiToken: "  "))
    }

    func testValidationTokenAloneIsAllowed() {
        XCTAssertNil(VodDanmakuApiConfig.validationError(apiUrl: "", apiToken: "tok9"))
    }

    func testValidationAcceptsHttpAndHttpsWithPath() {
        XCTAssertNil(VodDanmakuApiConfig.validationError(apiUrl: "https://example.com", apiToken: ""))
        XCTAssertNil(VodDanmakuApiConfig.validationError(apiUrl: "http://192.168.1.2:8080/danmu", apiToken: ""))
    }

    func testValidationRejectsBadAddress() {
        XCTAssertNotNil(VodDanmakuApiConfig.validationError(apiUrl: "example.com", apiToken: ""))
        XCTAssertNotNil(VodDanmakuApiConfig.validationError(apiUrl: "ftp://example.com", apiToken: ""))
        XCTAssertNotNil(VodDanmakuApiConfig.validationError(apiUrl: "https://", apiToken: ""))
        XCTAssertEqual(
            VodDanmakuApiConfig.validationError(apiUrl: "example.com", apiToken: ""),
            "地址格式不对，要以 http:// 或 https:// 开头")
    }

    func testValidationRejectsTokenWithSlashQuestionHash() {
        XCTAssertEqual(
            VodDanmakuApiConfig.validationError(apiUrl: "", apiToken: "a/b"),
            "密钥不能含 / ? #")
        XCTAssertEqual(
            VodDanmakuApiConfig.validationError(apiUrl: "", apiToken: "a?b"),
            "密钥不能含 / ? #")
        XCTAssertEqual(
            VodDanmakuApiConfig.validationError(apiUrl: "", apiToken: "a#b"),
            "密钥不能含 / ? #")
    }

    // MARK: - Load / save round-trip (dedicated suite, never .standard)

    func testLoadSaveRoundTrip() {
        let suite = UserDefaults(suiteName: suiteName)!
        VodDanmakuApiConfig(apiUrl: "https://example.com/danmu/", apiToken: "  tok9 ").save(defaults: suite)
        let loaded = VodDanmakuApiConfig.load(defaults: suite)
        XCTAssertEqual(loaded.apiUrl, "https://example.com/danmu")
        XCTAssertEqual(loaded.apiToken, "tok9")
        XCTAssertEqual(loaded.effectiveBaseUrl, "https://example.com/danmu")
    }

    func testLoadDefaultsToEmpty() {
        let suite = UserDefaults(suiteName: suiteName)!
        let loaded = VodDanmakuApiConfig.load(defaults: suite)
        XCTAssertEqual(loaded.apiUrl, "")
        XCTAssertEqual(loaded.apiToken, "")
        XCTAssertEqual(loaded.effectiveBaseUrl, VodDanmakuClient.defaultBaseUrl)
    }

    // MARK: - Hop-2 regression (absolute URL never re-prefixed)

    func testRewriteAbsoluteHop2KeepsTokenPrefix() {
        let rewritten = VodDanmakuParsers.rewriteCommentUrlToJson(
            "https://example.com/tok9/api/v2/comment/11479?format=xml",
            baseUrl: "https://example.com/danmu")
        XCTAssertEqual(
            rewritten?.absoluteString,
            "https://example.com/tok9/api/v2/comment/11479?format=json")
    }

    func testRewriteRelativeHop2StillResolvesAgainstBase() {
        let rewritten = VodDanmakuParsers.rewriteCommentUrlToJson(
            "api/v2/comment/1?format=xml",
            baseUrl: "https://example.com")
        XCTAssertEqual(
            rewritten?.absoluteString,
            "https://example.com/api/v2/comment/1?format=json")
    }

    // MARK: - Candidate selection regression (assembly must not leak)

    func testCandidatePassesTitleAndYearGate() {
        let candidate = VodDanmakuCandidate(
            name: "狂飙(2023)from iqiyi - 狂飙第1集", url: "https://example.com/api/v2/comment/1?format=xml")
        XCTAssertTrue(VodDanmakuParsers.candidatePasses(candidate, queryTitle: "狂飙", year: "2023"))
        XCTAssertFalse(VodDanmakuParsers.candidatePasses(candidate, queryTitle: "狂飙", year: "2024"))
        XCTAssertFalse(VodDanmakuParsers.candidatePasses(candidate, queryTitle: "漫长的季节", year: "2023"))
    }

    func testSelectCandidatePicksFirstPassing() {
        let wrong = VodDanmakuCandidate(name: "漫长的季节(2023) - 第1集", url: "https://example.com/1")
        let right = VodDanmakuCandidate(name: "狂飙(2023)from iqiyi - 狂飙第1集", url: "https://example.com/2")
        XCTAssertEqual(
            VodDanmakuParsers.selectCandidate([wrong, right], queryTitle: "狂飙", year: "2023"),
            right)
    }
}

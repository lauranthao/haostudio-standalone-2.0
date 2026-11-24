// HAo Studio 2.0 — Douyin signer tests (build 37, D1).
//
// Mirrors the Pure Live vectors in
// `packages/live_core/test/sites/douyin_site_test.dart` (group
// "signing", vectors computed with the 3.x code): same inputs,
// same expected outputs. No network. Swift 5.0: no async/await,
// no `any`.
//
// NOTE: `swift test` on Linux cannot run these — AppCore fails to
// build there on the missing JavaScriptCore module (known
// platform gap, not a code error). The same vectors also pass in
// the standalone swiftc harness
// (`~/workspace/.tmp/douyin-sign-harness/`, DouyinSigner.swift +
// main.swift), which is the real verification for this port.

import XCTest
@testable import AppCore

final class DouyinSignerTests: XCTestCase {
    /// Hands out scripted values (the random draws of a signature),
    /// mirroring Pure Live's `_Scripted`.
    private final class ScriptedRandom {
        var values: [Int]
        var index = 0
        init(_ values: [Int]) { self.values = values }
        func next(_ max: Int) -> Int {
            let value = values[index % values.count]
            index += 1
            return value
        }
    }

    private final class ScriptedClock {
        var values: [Int64]
        var index = 0
        init(_ values: [Int64]) { self.values = values }
        func now() -> Int64 {
            let value = values[index % values.count]
            index += 1
            return value
        }
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func signer(fingerprint: String, clock: [Int64], seeds: [Int]) -> DouyinSigner {
        let random = ScriptedRandom(seeds)
        let clock = ScriptedClock(clock)
        return DouyinSigner(
            userAgent: DouyinSigner.defaultUserAgent,
            fingerprint: fingerprint,
            nowMilliseconds: { clock.now() },
            randomInt: { random.next($0) }
        )
    }

    // MARK: - SM3 (GB/T 32905-2016 examples)

    func testSM3MatchesStandardExamples() {
        XCTAssertEqual(
            hex(DouyinSigner.sm3(Array("abc".utf8))),
            "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0"
        )
        XCTAssertEqual(
            hex(DouyinSigner.sm3(Array(String(repeating: "abcd", count: 16).utf8))),
            "debe9ff92275b8a138604889c18e5a4d6fdb70e5387e5765293dcba39c0c5732"
        )
    }

    // MARK: - MD5 (RFC 1321)

    func testMD5MatchesStandardExamples() {
        XCTAssertEqual(hex(DouyinSigner.md5([])), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(hex(DouyinSigner.md5(Array("abc".utf8))), "900150983cd24fb0d6963f7d28e17f72")
    }

    // MARK: - a_bogus (vectors from the 3.x code)

    func testABogusEquals3x() {
        let vectors: [(query: String, fingerprint: String, clock: [Int64], seeds: [Int], expected: String)] = [
            (
                query: "",
                fingerprint: "1536|747|1560|835|0|30|0|0|1920|1040|1920|1040|1536|747|24|24|Win32",
                clock: [1790506922004, 1790506922008],
                seeds: [1104, 4190, 3186],
                expected: "DXmhBDzIk3EN6Eyu5I5LfY3q6fe3YmZy0SVkMD2fvx3ziL39HMY69exoUUJv3TujZsmfIFEjy4hbT3ohrQ2y8qwf9W4x/25gsfSkKl12so0j53intL6mE0hN5kb3SFlm5XNAEOk0y75CFRJ0l2CymhK4bfebY7Y6i6trHD=="
            ),
            (
                query: "a=1",
                fingerprint: "1920|1080|1944|1165|0|0|0|0|1024|768|1280|800|1920|1080|24|24|Win32",
                clock: [1790506922020, 1790506922021],
                seeds: [2655, 8703, 7770],
                expected: "d7WMQQz1sVLB6ESS5I5LfY3q6fB3YmZy0SVkMD2fYd3ziL39HMYL9exoUUJv3ORjZsmfIFEjy4hbO3xprQAjM36UHWwoWdQ2m66gKl5Q5xSSs1feeLWQnsJL5iR3SFrd5XN1EOfkqwcGFuRDA9/rmhK4bfebY7Y6i6tr/E=="
            ),
            (
                query: "app_name=douyin_web&enter_from=web_live&live_id=1&web_rid=547977714661&is_need_double_stream=false&aid=6383&compress=gzip&device_platform=web&browser_language=zh-CN&browser_platform=Win32&browser_name=Edge&browser_version=125.0.0.0&msToken=AAAAbbbb%3D%3D",
                fingerprint: "1280|720|1308|805|0|30|0|0|1600|900|1600|860|1280|720|24|24|Win32",
                clock: [1790506922022, 1790506922023],
                seeds: [497, 9689, 1428],
                expected: "YX8hQRw3sV9khE6z5I5LfY3q6AP3YmZy0SVkMD2fRx3ziL39HMYo9exoUUJv3OfjZsmfIFYjy4hbYNQprQ2n01wfHSkO/25ZsfSkKl12so0j53inC6WmE0wN-hsAtlaQsvr4EKi8qXCaSYypAnAJ5kIlO62-zo0/9lW="
            ),
            (
                query: "keyword=%E5%92%8C%E5%B9%B3+x&offset=0",
                fingerprint: "1111|888|1140|970|0|0|0|0|1500|999|1700|1000|1111|888|24|24|Win32",
                clock: [1790506922024, 1790506922024],
                seeds: [2390, 6381, 5510],
                expected: "D7R0Q5wZp3xpkE6t5I5LfY3q6R-3YmZy0SVkMD2fqx3ziL39HMYY9exoUUJv3OujZsmfIFYjy4hbY3KdrQcbM1wfHWvx/2ADmDSkKl5Q5xSSs1X9eyUgJUwOmktRSec25k3lEKi8qw5cSYmsWnAJ5kIlO62-zo0/9IR="
            ),
        ]
        for vector in vectors {
            let value = signer(fingerprint: vector.fingerprint, clock: vector.clock, seeds: vector.seeds)
                .aBogus(query: vector.query)
            XCTAssertEqual(value, vector.expected, vector.query)
        }
    }

    func testEverySignatureStartsFromInitialCipherTable() {
        let shared = signer(
            fingerprint: "1280|720|1308|805|0|30|0|0|1600|900|1600|860|1280|720|24|24|Win32",
            clock: [1790506922022, 1790506922023],
            seeds: [497, 9689, 1428]
        )
        let query = "app_name=douyin_web&enter_from=web_live&live_id=1&web_rid=547977714661&is_need_double_stream=false&aid=6383&compress=gzip&device_platform=web&browser_language=zh-CN&browser_platform=Win32&browser_name=Edge&browser_version=125.0.0.0&msToken=AAAAbbbb%3D%3D"
        let expected = "YX8hQRw3sV9khE6z5I5LfY3q6AP3YmZy0SVkMD2fRx3ziL39HMYo9exoUUJv3OfjZsmfIFYjy4hbYNQprQ2n01wfHSkO/25ZsfSkKl12so0j53inC6WmE0wN-hsAtlaQsvr4EKi8qXCaSYypAnAJ5kIlO62-zo0/9lW="
        XCTAssertEqual(shared.aBogus(query: query), expected)
        XCTAssertEqual(shared.aBogus(query: query), expected)
    }

    // MARK: - signedUrl (3.x's buildRequestUrl)

    func testSignedUrlsEqual3xBuildRequestUrl() {
        let enter = signer(
            fingerprint: "1440|810|1466|895|0|30|0|0|1440|900|1440|860|1440|810|24|24|Win32",
            clock: [1790502760100, 1790502760103],
            seeds: [7, 9999, 4321]
        ).signedUrl(baseUrl: "https://live.douyin.com/webcast/room/web/enter/", orderedParams: [
            ("app_name", "douyin_web"), ("enter_from", "web_live"), ("live_id", "1"),
            ("web_rid", "547977714661"), ("is_need_double_stream", "false"), ("msToken", "fixed+token="),
        ])
        XCTAssertEqual(
            enter,
            "https://live.douyin.com/webcast/room/web/enter/?app_name=douyin_web&enter_from=web_live&live_id=1"
                + "&web_rid=547977714661&is_need_double_stream=false&msToken=fixed%2Btoken%3D&aid=6383&compress=gzip"
                + "&device_platform=web&browser_language=zh-CN&browser_platform=Win32&browser_name=Edge"
                + "&browser_version=125.0.0.0&a_bogus=DjWhQDuZsn9ifj6b5I5LfY3q6AH3Ymgy0SVkMD2fpn3z2g39HMOL9exoUvJvydfjZsmfIFYjy"
                + "4hbTpcprQcJ01wf984L/25/sfSkKl12so0j53inCy8mE0wN-hsAtePQsvr4EKi8o7/aSYmDAnAJ5kIlO62-zo0/94S="
        )
        let partition = signer(
            fingerprint: "1024|768|1050|850|0|0|0|0|1024|768|1280|800|1024|768|24|24|Win32",
            clock: [1790502760000],
            seeds: [0, 1, 2]
        ).signedUrl(baseUrl: "https://live.douyin.com/webcast/web/partition/detail/room/v2/?existing=1", orderedParams: [
            ("aid", "6383"), ("count", "15"), ("offset", "15"),
            ("partition", "1"), ("partition_type", "1"), ("msToken", "M"),
        ])
        XCTAssertEqual(
            partition,
            "https://live.douyin.com/webcast/web/partition/detail/room/v2/?existing=1&aid=6383&count=15&offset=15"
                + "&partition=1&partition_type=1&msToken=M&compress=gzip&device_platform=web&browser_language=zh-CN"
                + "&browser_platform=Win32&browser_name=Edge&browser_version=125.0.0.0&a_bogus=DfmhQDgpkVEpDE6Y5I5LfY3q6We3Ymgy"
                + "0SVkMD2ffd3z2g39HMTD9exoUvJvy88jZsmfIFujy4hbYpxZrQ29M1wfH8Xx/25dmDSkKl5Q5xSSs1Xre60gnt4PmktUCec2Rv3lrOX0qXMH"
                + "KRjs09oHmhK4bIOwu3GM4j=="
        )
    }

    func testSignedUrlForcesBrowserFieldsAndPutsABogusLast() {
        let signer = DouyinSigner(
            userAgent: DouyinSigner.defaultUserAgent,
            fingerprint: "1440|810|1466|895|0|30|0|0|1440|900|1440|860|1440|810|24|24|Win32",
            nowMilliseconds: { 1790502760100 },
            randomInt: { Int.random(in: 0..<$0) }
        )
        let base = "https://live.douyin.com/webcast/room/web/enter/?live_id=1"
        let first = signer.signedUrl(baseUrl: base, orderedParams: [("web_rid", "1"), ("aid", "1")])
        let second = signer.signedUrl(baseUrl: base, orderedParams: [("web_rid", "1"), ("aid", "1")])
        guard let first = first, let second = second else {
            XCTFail("signedUrl returned nil for a valid base URL")
            return
        }
        let query = String(first.split(separator: "?", maxSplits: 1).last ?? "")
        let keys = query.split(separator: "&").map { String($0.split(separator: "=").first ?? "") }
        XCTAssertEqual(keys, [
            "live_id", "web_rid", "aid", "compress", "device_platform", "browser_language",
            "browser_platform", "browser_name", "browser_version", "msToken", "a_bogus",
        ])
        XCTAssertEqual(queryValue(first, "aid"), "6383")
        let firstToken = queryValue(first, "msToken") ?? ""
        let secondToken = queryValue(second, "msToken") ?? ""
        XCTAssertEqual(firstToken.count, 184)
        XCTAssertTrue(firstToken.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789=".contains($0) })
        XCTAssertNotEqual(firstToken, secondToken)
        XCTAssertTrue(first.hasSuffix("&a_bogus=" + (queryValue(first, "a_bogus") ?? "")))
    }

    func testSignedUrlDictFormIsSortedAndDeterministic() {
        let first = DouyinSigner.shared.signedUrl(
            baseUrl: "https://live.douyin.com/webcast/feed/",
            params: ["b": "2", "a": "1", "msToken": "M"]
        )
        let second = DouyinSigner.shared.signedUrl(
            baseUrl: "https://live.douyin.com/webcast/feed/",
            params: ["a": "1", "b": "2", "msToken": "M"]
        )
        guard let first = first, let second = second else {
            XCTFail("signedUrl returned nil for a valid base URL")
            return
        }
        // Params first (sorted keys), then the forced browser fields, a_bogus last.
        XCTAssertTrue(first.hasPrefix("https://live.douyin.com/webcast/feed/?a=1&b=2&msToken=M&aid=6383&compress=gzip&"))
        XCTAssertTrue(first.contains("&a_bogus="))
        let firstQuery = String(first.split(separator: "&a_bogus=").first ?? "")
        let secondQuery = String(second.split(separator: "&a_bogus=").first ?? "")
        XCTAssertEqual(firstQuery, secondQuery)
    }

    func testSignedUrlBadBaseReturnsNil() {
        XCTAssertNil(DouyinSigner.shared.signedUrl(baseUrl: "not a url", params: [:]))
    }

    func testSignedUrlABogusMatchesQueryBeforeIt() {
        let subject = signer(
            fingerprint: "1440|810|1466|895|0|30|0|0|1440|900|1440|860|1440|810|24|24|Win32",
            clock: [1790502760100, 1790502760103],
            seeds: [7, 9999, 4321]
        )
        guard let url = subject.signedUrl(baseUrl: "https://live.douyin.com/webcast/room/web/enter/", orderedParams: [
            ("app_name", "douyin_web"), ("web_rid", "547977714661"), ("msToken", "fixed+token="),
        ]) else {
            XCTFail("signedUrl returned nil for a valid base URL")
            return
        }
        guard let question = url.firstIndex(of: "?"),
              let bogusRange = url.range(of: "&a_bogus=")
        else {
            XCTFail("signed URL has no query/a_bogus: \(url)")
            return
        }
        let query = String(url[url.index(after: question)..<bogusRange.lowerBound])
        let embedded = String(url[bogusRange.upperBound...])
        let recomputed = signer(
            fingerprint: "1440|810|1466|895|0|30|0|0|1440|900|1440|860|1440|810|24|24|Win32",
            clock: [1790502760100, 1790502760103],
            seeds: [7, 9999, 4321]
        ).aBogus(query: query)
        XCTAssertEqual(recomputed, embedded)
    }

    // MARK: - danmaku signature / X-Bogus (3.x's X-Bogus)

    func testDanmakuSignatureEquals3xXBogus() {
        let vectors: [(roomId: String, user: String, r1: Int, r2: Int, expected: String)] = [
            ("7687741736843512602", "7312345678901234567", 0, 0, "fDpl4KiMGENF3YOy"),
            ("7687741736843512602", "7312345678901234567", 255, 254, "1eVnhJc1lIUrcoJk"),
            ("7382735338101328680", "7273033021933946427", 31, 100, "19wv2GETf0Rijd7D"),
            ("1", "7300000000000000000", 200, 17, "wk407jV2/WLa1rdA"),
        ]
        for vector in vectors {
            let random = ScriptedRandom([vector.r1, vector.r2])
            let signer = DouyinSigner(
                userAgent: DouyinSigner.defaultUserAgent,
                fingerprint: "x",
                randomInt: { random.next($0) }
            )
            XCTAssertEqual(
                signer.danmakuSignature(roomId: vector.roomId, userUniqueId: vector.user),
                vector.expected,
                "\(vector.r1) \(vector.r2)"
            )
        }
        let random = ScriptedRandom([5, 77])
        let signer = DouyinSigner(
            userAgent: DouyinSigner.defaultUserAgent,
            fingerprint: "x",
            randomInt: { random.next($0) }
        )
        XCTAssertEqual(signer.xBogus(msStub: "d41d8cd98f00b204e9800998ecf8427e", counter: 2), "v6ytTiUdP8gEsplH")
        XCTAssertNil(signer.xBogus(msStub: "not md5"))
    }

    // MARK: - fingerprint / msToken / visitor id

    func testFingerprintShapeAndMsTokenLengths() {
        let fingerprint = DouyinSigner.browserFingerprint(random: { Int.random(in: 0..<$0) })
        let parts = fingerprint.split(separator: "|")
        XCTAssertEqual(parts.count, 17)
        XCTAssertEqual(parts.last, "Win32")
        let signer = DouyinSigner(userAgent: DouyinSigner.defaultUserAgent)
        XCTAssertEqual(signer.msToken(length: 256).count, 256)
        XCTAssertTrue(signer.msToken().allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789=".contains($0) })
    }

    func testVisitorIdShape() {
        let visitor = DouyinSigner.visitorId(random: { Int.random(in: 0..<$0) })
        XCTAssertEqual(visitor.count, 19)
        XCTAssertTrue(visitor.hasPrefix("7"))
        XCTAssertTrue("3456789".contains(visitor[visitor.index(visitor.startIndex, offsetBy: 1)]))
        XCTAssertTrue(visitor.allSatisfy { $0.isNumber })
    }

    // MARK: - Helpers

    private func queryValue(_ url: String, _ key: String) -> String? {
        guard let query = url.split(separator: "?", maxSplits: 1).last else { return nil }
        for part in query.split(separator: "&") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 && pair[0] == key {
                return String(pair[1]).removingPercentEncoding ?? String(pair[1])
            }
        }
        return nil
    }
}

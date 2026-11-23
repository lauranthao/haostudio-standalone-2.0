// HAo Studio 2.0 — Huya anti-code tests (S4 leg B).
//
// Fixtures recomputed in Python from the Swift implementation
// (uid 1400000012345, now 1700000000s, wsTime hex 6553f5a0,
// stream "test-stream", fm template "$0_$1_$2_$3"):
//   rotated uid 1398026549750, seqid 3100000012345,
//   wsSecret 059cccda3b9a534db8ca3b3c59487e5f.
// No network. Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class HuyaAntiCodeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1700000000)
    private let antiCode = "fm=JDBfJDFfJDJfJDM=&wsTime=6553f5a0&ctype=huya_webh5&t=100&fs=bgct&u=1&uid=2&uuid=3&wsSecret=old&seqid=9&ver=0&extra=keep"

    func testRotateViewerUid32OnlyRotatesLowLane() {
        XCTAssertEqual(HuyaAntiCode.rotateViewerUid32(1400000012345), 1398026549750)
        XCTAssertEqual(HuyaAntiCode.unrotateViewerUid32(1398026549750), 1400000012345)
        XCTAssertEqual(HuyaAntiCode.rotateViewerUid32(0), 0)
        // High lane preserved: 0x1_00000001 -> low 1 rotates to 256.
        XCTAssertEqual(HuyaAntiCode.rotateViewerUid32(0x1_00000001), 0x1_00000100)
        for uid in [1, 123456789, 1400000012345, 0x7FFF_FFFF] {
            XCTAssertEqual(HuyaAntiCode.unrotateViewerUid32(HuyaAntiCode.rotateViewerUid32(uid)), uid)
        }
    }

    func testBuildSignsWebAntiCode() throws {
        let signed = try HuyaAntiCode.build(
            stream: "test-stream", viewerUid: 1400000012345,
            antiCode: antiCode, now: now, randomDouble: { 0.5 }
        )
        XCTAssertEqual(
            signed,
            "extra=keep&wsSecret=059cccda3b9a534db8ca3b3c59487e5f&wsTime=6553f5a0&seqid=3100000012345&ctype=huya_webh5&ver=1&fs=bgct&t=100&u=1398026549750"
        )
    }

    func testBuildRemovesReplacedKeysExactlyOnce() throws {
        let signed = try HuyaAntiCode.build(
            stream: "test-stream", viewerUid: 1400000012345,
            antiCode: antiCode, now: now, randomDouble: { 0.5 }
        )
        // Every key the signer sets appears exactly once (the old
        // Dart addAll replaced in place; a naive append would emit
        // wsSecret/wsTime/seqid/ctype/ver/fs/t/u twice).
        for key in ["wsSecret", "wsTime", "seqid", "ctype", "ver", "fs", "t", "u"] {
            let occurrences = signed.components(separatedBy: "&").filter { $0.hasPrefix("\(key)=") }.count
            XCTAssertEqual(occurrences, 1, "key \(key) appears \(occurrences)x in \(signed)")
        }
        XCTAssertFalse(signed.contains("fm="))
    }

    func testBuildWithoutFmReturnsAntiCodeUnchanged() throws {
        let plain = "wsTime=6553f5a0&ctype=huya_webh5&t=100"
        XCTAssertEqual(
            try HuyaAntiCode.build(stream: "s", viewerUid: 1, antiCode: plain, now: now),
            plain
        )
    }

    func testBuildThrowsOnMissingOrInvalidWsTime() {
        XCTAssertThrowsError(try HuyaAntiCode.build(stream: "s", viewerUid: 1, antiCode: "fm=JDBfJDFfJDJfJDM=&ctype=x&t=100", now: now)) { error in
            XCTAssertEqual(error as? HuyaAntiCodeError, .missingWsTime)
        }
        XCTAssertThrowsError(try HuyaAntiCode.build(stream: "s", viewerUid: 1, antiCode: "fm=JDBfJDFfJDJfJDM=&wsTime=zzz&ctype=x&t=100", now: now)) { error in
            XCTAssertEqual(error as? HuyaAntiCodeError, .missingWsTime)
        }
    }

    func testBuildThrowsWhenLeaseExpired() {
        let expired = Date(timeIntervalSince1970: 1700001184 + 301)
        XCTAssertThrowsError(try HuyaAntiCode.build(stream: "s", viewerUid: 1, antiCode: antiCode, now: expired)) { error in
            XCTAssertEqual(error as? HuyaAntiCodeError, .leaseExpired)
        }
    }

    func testBuildThrowsOnBadTemplate() {
        XCTAssertThrowsError(try HuyaAntiCode.build(stream: "s", viewerUid: 1, antiCode: "fm=!!!&wsTime=6553f5a0&t=100", now: now)) { error in
            XCTAssertEqual(error as? HuyaAntiCodeError, .invalidBase64)
        }
        let noPlaceholders = Data("hello".utf8).base64EncodedString()
        XCTAssertThrowsError(try HuyaAntiCode.build(stream: "s", viewerUid: 1, antiCode: "fm=\(noPlaceholders)&wsTime=6553f5a0&t=100", now: now)) { error in
            XCTAssertEqual(error as? HuyaAntiCodeError, .templateIncomplete)
        }
    }

    func testBuildFallsBackToViewerUidZero() throws {
        // viewerUid 0 -> fallbackViewerUid is used for seqid/u.
        let signed = try HuyaAntiCode.build(
            stream: "test-stream", viewerUid: 0, antiCode: antiCode,
            now: now, fallbackViewerUid: 1400000012345, randomDouble: { 0.5 }
        )
        XCTAssertTrue(signed.contains("seqid=3100000012345"))
        XCTAssertTrue(signed.contains("u=1398026549750"))
    }

    func testReplaceQueryParameter() {
        XCTAssertEqual(
            HuyaAntiCode.replaceQueryParameter("a=1&b=2&a=3", key: "b", value: "9"),
            "a=1&b=9&a=3"
        )
        XCTAssertEqual(
            HuyaAntiCode.replaceQueryParameter("a=1&b=2&a=3", key: "b", value: nil),
            "a=1&a=3"
        )
        XCTAssertEqual(
            HuyaAntiCode.replaceQueryParameter("a=1", key: "c", value: "5"),
            "a=1&c=5"
        )
    }

    func testSecureCdnBaseOnlyUpgradesHuyaHosts() {
        XCTAssertEqual(HuyaAntiCode.secureCdnBase("http://al.huya.com/x.flv"), "https://al.huya.com/x.flv")
        XCTAssertEqual(HuyaAntiCode.secureCdnBase("http://www.huya.com/x"), "https://www.huya.com/x")
        XCTAssertEqual(HuyaAntiCode.secureCdnBase("https://al.huya.com/x.flv"), "https://al.huya.com/x.flv")
        XCTAssertEqual(HuyaAntiCode.secureCdnBase("http://example.com/x"), "http://example.com/x")
    }

    func testSignedUrlInvalidAtIsWsTimePlusFiveMinutes() {
        let url = "https://al.huya.com/test-stream.flv?wsSecret=x&wsTime=6553f5a0"
        XCTAssertEqual(
            HuyaAntiCode.signedUrlInvalidAt(url),
            Date(timeIntervalSince1970: 1700001184 + 300)
        )
        XCTAssertNil(HuyaAntiCode.signedUrlInvalidAt("https://al.huya.com/x.flv"))
        XCTAssertNil(HuyaAntiCode.signedUrlInvalidAt("https://al.huya.com/x.flv?wsTime=zzz"))
    }

    func testSignedSequenceIssuedAtDerivesFromSeqidAndUid() {
        let url = "https://al.huya.com/s.flv?seqid=3100000012345&u=1398026549750&t=100"
        XCTAssertEqual(
            HuyaAntiCode.signedSequenceIssuedAt(url),
            Date(timeIntervalSince1970: 1700000000)
        )
        XCTAssertNil(HuyaAntiCode.signedSequenceIssuedAt("https://al.huya.com/s.flv?seqid=1"))
    }
}

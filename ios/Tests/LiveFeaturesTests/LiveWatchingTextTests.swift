// HAo Studio 2.0 — watching-count text tests (fix 2026-11-24, build 35).
//
// liveWatchingText (LiveDataGateway.swift, AppCore) formats the
// "N人在看" count. The room hides the whole line when it returns
// "" — 0 means "count unavailable", never a number to invent — so
// the 0 boundary is the one that matters: build 34 rendered a
// dangling " 人在看" label for it. Pure function, no network.

import XCTest
@testable import AppCore

final class LiveWatchingTextTests: XCTestCase {
    func testZeroMeansUnavailable() {
        XCTAssertEqual(liveWatchingText(0), "")
        XCTAssertEqual(liveWatchingText(-1), "")
    }

    func testSmallCountsAreRaw() {
        XCTAssertEqual(liveWatchingText(1), "1")
        XCTAssertEqual(liveWatchingText(9999), "9999")
    }

    func testTenThousandFormatsAsWan() {
        // b36 follow-up: the ".0" tail is stripped — 10000 reads
        // "1万", never "1.0万". 10500 stays "1.1万" (1.05 rounds
        // up at one decimal), 100000 reads "10万".
        XCTAssertEqual(liveWatchingText(10000), "1万")
        XCTAssertEqual(liveWatchingText(10499), "1万")
        XCTAssertEqual(liveWatchingText(10500), "1.1万")
        XCTAssertEqual(liveWatchingText(12345), "1.2万")
        XCTAssertEqual(liveWatchingText(99999), "10万")
        XCTAssertEqual(liveWatchingText(100000), "10万")
        XCTAssertEqual(liveWatchingText(999999), "100万")
        XCTAssertEqual(liveWatchingText(1000000), "100万")
    }
}

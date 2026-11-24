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
        XCTAssertEqual(liveWatchingText(10000), "1.0万")
        XCTAssertEqual(liveWatchingText(12345), "1.2万")
        XCTAssertEqual(liveWatchingText(1000000), "100万")
    }
}

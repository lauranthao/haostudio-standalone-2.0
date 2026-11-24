// HAo Studio 2.0 — music player layout tests (fix 2026-11-24, build 35).
//
// Build 34 on chen's phone rendered the player ~2x wider than the
// screen (prev/next at the edges, close/title/progress pushed
// off-screen, dead gap from the invisible rows). The view now pins
// its stack to the screen width and sizes everything from
// MusicPlayerLayout, so the regression guard is arithmetic here:
// every row against the screen width on every shipping iPhone
// width. Pure math, no SwiftUI, no network.
//
// NOTE: like the rest of Tests/MusicFeaturesTests, this target is
// unwired until the S7 Xcode test target exists — it runs with
// `xcodebuild test` against an iOS Simulator destination, not
// `swift test` on Linux.

import XCTest
@testable import HAoStudio

final class MusicPlayerLayoutTests: XCTestCase {
    private let widths: [CGFloat] = [320, 360, 375, 390, 393, 402, 414, 420, 430]
    private let screens: [(w: CGFloat, h: CGFloat)] = [
        (375, 667), (360, 780), (375, 812), (390, 844), (393, 852),
        (414, 896), (420, 912), (430, 932),
    ]

    func testContentWidthIsScreenMinusSidePadding() {
        for w in widths {
            XCTAssertEqual(MusicPlayerLayout.contentWidth(screenWidth: w), w - 48)
        }
    }

    func testCoverSizeIsCappedAndBounded() {
        for (w, h) in screens {
            let size = MusicPlayerLayout.coverSize(screenWidth: w, screenHeight: h)
            XCTAssertLessThanOrEqual(size, 340, "\(w)x\(h)")
            XCTAssertGreaterThanOrEqual(size, 180, "\(w)x\(h)")
            XCTAssertLessThanOrEqual(size, w - 48, "\(w)x\(h)")
        }
        XCTAssertEqual(MusicPlayerLayout.coverSize(screenWidth: 393, screenHeight: 852), 340)
        XCTAssertEqual(MusicPlayerLayout.coverSize(screenWidth: 375, screenHeight: 667), 207)
    }

    func testWholePlayerFitsOneScreen() {
        for (w, h) in screens {
            XCTAssertTrue(
                MusicPlayerLayout.fitsOneScreen(screenWidth: w, screenHeight: h),
                "\(w)x\(h)")
        }
    }

    func testTransportButtonsStayInsideTheScreen() {
        // The build-34 failure: prev/next at the screen edges.
        for w in widths {
            let c = MusicPlayerLayout.transportCentres(screenWidth: w)
            XCTAssertGreaterThan(c.prev, 0, "prev off-screen left at \(w)")
            XCTAssertLessThan(c.next, w, "next off-screen right at \(w)")
            XCTAssertEqual(c.play, w / 2, accuracy: 0.001, "play not centred at \(w)")
            XCTAssertEqual(c.next, w - c.prev, accuracy: 0.001, "not symmetric at \(w)")
        }
    }

    func testModeRowFitsNarrowestPhone() {
        XCTAssertTrue(MusicPlayerLayout.modeRowFits(screenWidth: 320))
        for w in widths {
            XCTAssertTrue(MusicPlayerLayout.modeRowFits(screenWidth: w), "mode row overflows at \(w)")
        }
    }
}

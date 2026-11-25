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
        // b47-player: the badge leaves its own row for the time
        // row (budget 418 → 396), so the shortest phone's cover
        // grows back 249 → 271. b47-player Coda check: the control
        // gaps are Coda's 24/36, not 6/0 (budget 396 → 450), so
        // the shortest phone's cover shrinks back 271 → 217.
        XCTAssertEqual(MusicPlayerLayout.coverSize(screenWidth: 375, screenHeight: 667), 217)
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

    // MARK: - Landscape (build 36 item 2)

    /// Safe sizes (screen minus safe-area insets): notched phones
    /// lose ~44pt each side and ~21pt at the bottom in landscape;
    /// the SE has no insets.
    private let landscapeScreens: [(w: CGFloat, h: CGFloat)] = [
        (764, 372), // iPhone 16 Pro landscape
        (692, 339), // 780x360 landscape (shortest modern)
        (667, 375), // iPhone SE landscape (no notch)
        (756, 369), // 844x390 landscape
        (568, 320), // iPhone SE 1st gen landscape
    ]

    func testLandscapeCoverSizeIsBounded() {
        for (w, h) in landscapeScreens {
            let size = MusicPlayerLayout.landscapeCoverSize(safeWidth: w, safeHeight: h)
            XCTAssertLessThanOrEqual(size, 340, "\(w)x\(h)")
            XCTAssertGreaterThan(size, 0, "\(w)x\(h)")
            XCTAssertLessThanOrEqual(size, w * 0.42 + 0.001, "\(w)x\(h)")
        }
        XCTAssertEqual(MusicPlayerLayout.landscapeCoverSize(safeWidth: 764, safeHeight: 372), 276)
        XCTAssertEqual(MusicPlayerLayout.landscapeCoverSize(safeWidth: 692, safeHeight: 339), 243)
        XCTAssertEqual(MusicPlayerLayout.landscapeCoverSize(safeWidth: 667, safeHeight: 375), 279)
    }

    func testLandscapeRightColumnBudgetIsMeasured() {
        // b49fix4 P1-9: the right-column budget is the measured
        // worst case, not the old 291 — topBar 40 + gap 8 +
        // titleRow 50 (two 20pt lines + 2 spacing) + gap 8 +
        // progressSection 49 + gap 4 + transportRow 82 +
        // toolbarRow 50 + bottom 4 = 295, plus 8 for the sleep
        // pill (its 46pt content spills 6pt out of the 40pt
        // topBar when active) = 303. The vertical padding is 8,
        // so the SE 1st gen (568x320, no insets) fits at
        // 303 + 16 = 319, 1pt of slack.
        XCTAssertEqual(MusicPlayerLayout.landscapeRightColumnHeight, 303)
        XCTAssertEqual(MusicPlayerLayout.landscapeVerticalPadding, 8)
    }

    func testLandscapePlayerFitsOneScreen() {
        // Build 35 left the landscape player overflowing (the
        // portrait column cannot fit ~390pt of height). Both
        // landscape columns must fit the safe height.
        for (w, h) in landscapeScreens {
            XCTAssertTrue(
                MusicPlayerLayout.landscapeFitsOneScreen(safeWidth: w, safeHeight: h),
                "\(w)x\(h)")
        }
    }

    func testLandscapeRightColumnLeavesRoomForTransport() {
        // The right column (all controls) must be wider than the
        // transport row — the widest fixed-width row now that the
        // mode row is gone (build 37): 132pt of glyphs + 16pt
        // side padding on each side = 164pt.
        for (w, h) in landscapeScreens {
            let cover = MusicPlayerLayout.landscapeCoverSize(safeWidth: w, safeHeight: h)
            let rightWidth = w - 48 - cover - 24
            XCTAssertGreaterThan(rightWidth, 164, "\(w)x\(h): transport would not fit")
        }
    }
}

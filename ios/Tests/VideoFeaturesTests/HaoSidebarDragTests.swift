// HAo Studio 2.0 — sidebar drag math tests (build 36, item 19).
//
// Pure rules only (no UI, no network): tap-vs-drag, flick-vs-
// position settle, rubber-band bounds, progress, sidebar width.
// The SwiftUI side (`HaoDragSidebar`) is thin glue over these
// functions — if the math holds, the gesture cannot stick, jump,
// or swallow a tap. Runs under `swift test` on macOS CI
// (AppCore); Linux `swift test` can never go green for this repo
// (Apple-only modules absent — parse + CI-gate reasoning only).

import XCTest

@testable import AppCore

final class HaoSidebarDragTests: XCTestCase {
    // MARK: - Tap vs drag
    func testStillFingerIsTap() {
        XCTAssertTrue(HaoSidebarDragMath.isTap(totalMovement: 0))
        XCTAssertTrue(HaoSidebarDragMath.isTap(totalMovement: 10))
    }

    func testMovedFingerIsNotTap() {
        XCTAssertFalse(HaoSidebarDragMath.isTap(totalMovement: 10.1))
        XCTAssertFalse(HaoSidebarDragMath.isTap(totalMovement: 60))
    }

    // MARK: - Settle: position rule
    func testPastHalfOpensWithoutFlick() {
        XCTAssertTrue(HaoSidebarDragMath.shouldOpen(currentOffset: 140, velocity: 0, width: 280))
        XCTAssertTrue(HaoSidebarDragMath.shouldOpen(currentOffset: 200, velocity: 0, width: 280))
    }

    func testBeforeHalfClosesWithoutFlick() {
        XCTAssertFalse(HaoSidebarDragMath.shouldOpen(currentOffset: 139, velocity: 0, width: 280))
        XCTAssertFalse(HaoSidebarDragMath.shouldOpen(currentOffset: 0, velocity: 0, width: 280))
    }

    // MARK: - Settle: flick wins over position
    func testFastFlickRightOpensFromClosed() {
        XCTAssertTrue(HaoSidebarDragMath.shouldOpen(currentOffset: 20, velocity: 800, width: 280))
    }

    func testFastFlickLeftClosesFromOpen() {
        XCTAssertFalse(HaoSidebarDragMath.shouldOpen(currentOffset: 260, velocity: -800, width: 280))
    }

    func testSlowDragDoesNotFlick() {
        XCTAssertFalse(HaoSidebarDragMath.shouldOpen(currentOffset: 20, velocity: 499, width: 280))
        XCTAssertTrue(HaoSidebarDragMath.shouldOpen(currentOffset: 260, velocity: -499, width: 280))
    }

    // MARK: - Rubber band: never past the bounds, follows 1:1 inside
    func testInsideBoundsFollowsFinger() {
        XCTAssertEqual(HaoSidebarDragMath.clampedOffset(raw: 120, min: 0, max: 280), 120)
    }

    func testPastOpenEndLags() {
        // 20pt past the end: 280 + 20 * 0.3 = 286, never 300.
        XCTAssertEqual(HaoSidebarDragMath.clampedOffset(raw: 300, min: 0, max: 280), 286)
    }

    func testPastClosedEndLags() {
        XCTAssertEqual(HaoSidebarDragMath.clampedOffset(raw: -20, min: 0, max: 280), -6)
    }

    // MARK: - Progress + width
    func testProgress() {
        XCTAssertEqual(HaoSidebarDragMath.progress(offset: 0, width: 280), 0)
        XCTAssertEqual(HaoSidebarDragMath.progress(offset: 140, width: 280), 0.5)
        XCTAssertEqual(HaoSidebarDragMath.progress(offset: 280, width: 280), 1)
        XCTAssertEqual(HaoSidebarDragMath.progress(offset: 999, width: 280), 1)
        XCTAssertEqual(HaoSidebarDragMath.progress(offset: 10, width: 0), 0)
    }

    func testSidebarWidth() {
        XCTAssertEqual(HaoSidebarDragMath.sidebarWidth(screenWidth: 390), 280)
        XCTAssertEqual(HaoSidebarDragMath.sidebarWidth(screenWidth: 320), 272)
    }
}

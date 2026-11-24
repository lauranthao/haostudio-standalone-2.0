// Live picture gestures (build 37, L3) — pure-math harness.
// Same pattern as the VOD gesture tests: no view, no player,
// only LiveGestureMath + the shared tap disambiguator.

import XCTest

@testable import AppCore

final class LiveGesturesTests: XCTestCase {
    // MARK: - Drag zone (left half brightness, right half volume)

    func testDragKindLeftHalfIsBrightness() {
        XCTAssertEqual(LiveGestureMath.dragKind(x: 0, width: 390), .brightness)
        XCTAssertEqual(LiveGestureMath.dragKind(x: 194, width: 390), .brightness)
    }

    func testDragKindRightHalfIsVolume() {
        XCTAssertEqual(LiveGestureMath.dragKind(x: 195, width: 390), .volume)
        XCTAssertEqual(LiveGestureMath.dragKind(x: 389, width: 390), .volume)
    }

    func testDragKindZeroWidthDefaultsToBrightness() {
        XCTAssertEqual(LiveGestureMath.dragKind(x: 0, width: 0), .brightness)
        XCTAssertEqual(LiveGestureMath.dragKind(x: 10, width: -5), .brightness)
    }

    // MARK: - Drag delta (full height = 1.2 levels, up increases)

    func testDragDeltaFullHeightUpIsPlus1Point2() {
        XCTAssertEqual(LiveGestureMath.dragDelta(dy: -390, height: 390), 1.2, accuracy: 0.0001)
    }

    func testDragDeltaHalfHeightDownIsMinus0Point6() {
        XCTAssertEqual(LiveGestureMath.dragDelta(dy: 195, height: 390), -0.6, accuracy: 0.0001)
    }

    func testDragDeltaZeroHeightHoldsLevel() {
        XCTAssertEqual(LiveGestureMath.dragDelta(dy: 100, height: 0), 0)
    }

    // MARK: - Drag level (clamped 0...1)

    func testDragLevelClampsAtBothEnds() {
        XCTAssertEqual(LiveGestureMath.dragLevel(baseline: 0.5, delta: 0.6), 1.0, accuracy: 0.0001)
        XCTAssertEqual(LiveGestureMath.dragLevel(baseline: 0.5, delta: -0.7), 0.0, accuracy: 0.0001)
        XCTAssertEqual(LiveGestureMath.dragLevel(baseline: 0.3, delta: 0.1), 0.4, accuracy: 0.0001)
    }

    // MARK: - Pill icon (Pure Live gestureLevelIcon thresholds)

    func testIconNameVolumeThresholds() {
        XCTAssertEqual(LiveGestureMath.iconName(kind: .volume, level: 0), "speaker.slash")
        XCTAssertEqual(LiveGestureMath.iconName(kind: .volume, level: 0.3), "speaker.wave.1")
        XCTAssertEqual(LiveGestureMath.iconName(kind: .volume, level: 0.9), "speaker.wave.3")
    }

    func testIconNameBrightnessThresholds() {
        XCTAssertEqual(LiveGestureMath.iconName(kind: .brightness, level: 0), "sun.min")
        XCTAssertEqual(LiveGestureMath.iconName(kind: .brightness, level: 0.3), "sun.max")
        XCTAssertEqual(LiveGestureMath.iconName(kind: .brightness, level: 0.9), "sun.max.fill")
    }

    // MARK: - Double-tap (any zone = fullscreen; the view ignores the zone)

    func testDoubleTapFiresFromAnyZone() {
        var disambiguator = VodTapDisambiguator()
        XCTAssertEqual(
            disambiguator.tap(at: 0, x: 10, width: 390),
            .wait
        )
        // Left third double-tap: still a double-tap (fullscreen),
        // not a seek — live has no seek.
        if case .doubleTap = disambiguator.tap(at: 0.1, x: 10, width: 390) {
            // Expected.
        } else {
            XCTFail("second tap inside the window must be a double-tap")
        }
    }

    func testSingleTapExpiresAfterWindow() {
        var disambiguator = VodTapDisambiguator()
        XCTAssertEqual(
            disambiguator.tap(at: 0, x: 200, width: 390),
            .wait
        )
        XCTAssertEqual(
            disambiguator.expirePending(at: 0.28),
            .singleTap
        )
    }
}

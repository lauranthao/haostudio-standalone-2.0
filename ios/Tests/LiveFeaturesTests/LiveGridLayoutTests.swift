// HAo Studio 2.0 — live grid layout tests (fix 2026-11-24).
//
// Build 33 on chen's phone showed the recommend grid unaligned:
// right column past the screen edge, title overlapping the
// watching count, rows overlapping. The grid metrics live in
// LiveGridLayout (LiveDataGateway.swift, AppCore) so the math is
// testable here without SwiftUI; the card/grid fixes are the
// SwiftUI half and need a real device to see. No network.

import XCTest
@testable import AppCore

final class LiveGridLayoutTests: XCTestCase {
    // MARK: - Cell width: (container - 2*24 margin - 12 gap) / 2

    func testCellWidthIPhoneWidths() {
        // (width - 60) / 2 for every shipping iPhone width.
        let cases: [(container: Double, cell: Double)] = [
            (320, 130), (375, 157.5), (390, 165), (414, 177), (430, 185),
        ]
        for item in cases {
            XCTAssertEqual(
                LiveGridLayout.cellWidth(containerWidth: item.container),
                item.cell, accuracy: 0.001,
                "container \(item.container)")
        }
    }

    func testCellsPlusGapPlusMarginsFillContainer() {
        // Two cells + one 12 pt gap + two 24 pt margins == the
        // container width exactly: the grid cannot overflow it.
        for width in [320.0, 375.0, 390.0, 414.0, 430.0] {
            XCTAssertTrue(LiveGridLayout.fills(containerWidth: width), "width \(width)")
        }
    }

    func testTooNarrowContainerDoesNotFill() {
        // A container narrower than margins + gap has no room
        // for a cell at all — fills() says so instead of
        // returning a negative width.
        XCTAssertEqual(LiveGridLayout.cellWidth(containerWidth: 50), 0, accuracy: 0.001)
        XCTAssertFalse(LiveGridLayout.fills(containerWidth: 50))
    }

    // MARK: - Cover height: 16:10 of the cell width

    func testCoverHeightIsSixteenToTen() {
        XCTAssertEqual(LiveGridLayout.coverHeight(cellWidth: 165), 103.125, accuracy: 0.001)
        XCTAssertEqual(
            LiveGridLayout.coverHeight(cellWidth: 200) / 200, 10.0 / 16.0, accuracy: 0.001)
    }

    // MARK: - Dedupe: platform + room id is the identity

    private func room(_ id: String, platform: LivePlatform = .bilibili, title: String = "") -> LiveRoom {
        LiveRoom(roomId: id, platform: platform, title: title)
    }

    func testDedupeDropsSameRoomOnSamePlatformKeepsFirst() {
        let rooms = [room("1", title: "first"), room("2"), room("1", title: "repeat")]
        let kept = deduplicatedLiveRooms(rooms)
        XCTAssertEqual(kept.map { $0.roomId }, ["1", "2"])
        XCTAssertEqual(kept[0].title, "first")
    }

    func testDedupeKeepsSameRoomIdOnDifferentPlatforms() {
        // Bilibili room 1 and Douyu room 1 are different rooms.
        let rooms = [room("1", platform: .bilibili), room("1", platform: .douyu)]
        XCTAssertEqual(deduplicatedLiveRooms(rooms).count, 2)
    }

    func testDedupePreservesOrderAndEmpty() {
        XCTAssertEqual(deduplicatedLiveRooms([]).count, 0)
        let rooms = [room("3"), room("1"), room("2"), room("1")]
        XCTAssertEqual(deduplicatedLiveRooms(rooms).map { $0.roomId }, ["3", "1", "2"])
    }

    // MARK: - Identity: why the grid uses id: \.self

    func testRoomIdentityIsPlatformPlusRoomId() {
        // Same room re-fetched with a fresh title / count is
        // still the same room — the grid updates the cell in
        // place instead of treating it as a new cell.
        let a = room("7", title: "old")
        var b = room("7", title: "new")
        b.onlineCount = 999
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        // ...but the same room id on another platform is not.
        XCTAssertNotEqual(a, room("7", platform: .douyu))
    }
}

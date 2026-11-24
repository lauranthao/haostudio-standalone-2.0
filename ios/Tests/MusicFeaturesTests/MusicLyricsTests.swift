// HAo Studio 2.0 — lyrics binary-search tests (S2-C leg).
//
// The active line is the last line whose time is <= the (offset)
// playback position. Lines are sorted by time; the lookup is a
// binary search, not a linear scan.

import XCTest

@testable import HAoStudio

final class MusicLyricsTests: XCTestCase {
    private var lines: [StoredLyricLine] {
        return [
            StoredLyricLine(t: 0, text: "first"),
            StoredLyricLine(t: 10, text: "second"),
            StoredLyricLine(t: 20, text: "third"),
            StoredLyricLine(t: 30, text: "fourth"),
        ]
    }

    func testBinarySearchEmpty() {
        XCTAssertEqual(MusicLyrics.binarySearchIndex(times: [], position: 5), -1)
    }

    func testBinarySearchBeforeFirst() {
        XCTAssertEqual(MusicLyrics.binarySearchIndex(times: [10, 20, 30], position: 5), -1)
    }

    func testBinarySearchExactHits() {
        let times = [0.0, 10.0, 20.0, 30.0]
        XCTAssertEqual(MusicLyrics.binarySearchIndex(times: times, position: 0), 0)
        XCTAssertEqual(MusicLyrics.binarySearchIndex(times: times, position: 10), 1)
        XCTAssertEqual(MusicLyrics.binarySearchIndex(times: times, position: 30), 3)
    }

    func testBinarySearchBetweenLines() {
        let times = [0.0, 10.0, 20.0, 30.0]
        XCTAssertEqual(MusicLyrics.binarySearchIndex(times: times, position: 9.9), 0)
        XCTAssertEqual(MusicLyrics.binarySearchIndex(times: times, position: 15), 1)
        XCTAssertEqual(MusicLyrics.binarySearchIndex(times: times, position: 29.9), 2)
    }

    func testBinarySearchAfterLast() {
        XCTAssertEqual(MusicLyrics.binarySearchIndex(times: [0.0, 10.0, 20.0], position: 999), 2)
    }

    func testBinarySearchLargeList() {
        // 1000 lines: the search must land exactly, not drift.
        let times = (0..<1000).map { Double($0) * 2 }
        XCTAssertEqual(MusicLyrics.binarySearchIndex(times: times, position: 1234), 617)
        XCTAssertEqual(MusicLyrics.binarySearchIndex(times: times, position: 1998), 999)
        XCTAssertEqual(MusicLyrics.binarySearchIndex(times: times, position: 0), 0)
    }

    func testActiveIndexFollowsPosition() {
        XCTAssertEqual(MusicLyrics.activeIndex(lines: lines, position: 0, offsetMs: 0), 0)
        XCTAssertEqual(MusicLyrics.activeIndex(lines: lines, position: 19.9, offsetMs: 0), 1)
        XCTAssertEqual(MusicLyrics.activeIndex(lines: lines, position: 20, offsetMs: 0), 2)
    }

    func testActiveIndexPositiveOffsetMovesEarly() {
        // +5 s offset: at 5 s the lyrics behave as if at 10 s.
        XCTAssertEqual(MusicLyrics.activeIndex(lines: lines, position: 5, offsetMs: 5000), 1)
        XCTAssertEqual(MusicLyrics.activeIndex(lines: lines, position: 4.9, offsetMs: 5000), 0)
    }

    func testActiveIndexNegativeOffsetMovesLate() {
        // -5 s offset: at 10 s the lyrics behave as if at 5 s.
        XCTAssertEqual(MusicLyrics.activeIndex(lines: lines, position: 10, offsetMs: -5000), 0)
        XCTAssertEqual(MusicLyrics.activeIndex(lines: lines, position: 15, offsetMs: -5000), 1)
    }

    func testActiveIndexEmptyLines() {
        XCTAssertEqual(MusicLyrics.activeIndex(lines: [], position: 10, offsetMs: 0), -1)
    }

    func testOffsetClamp() {
        XCTAssertEqual(MusicLyrics.clampOffsetMs(6000), 5000)
        XCTAssertEqual(MusicLyrics.clampOffsetMs(-6000), -5000)
        XCTAssertEqual(MusicLyrics.clampOffsetMs(1500), 1500)
    }

    func testOffsetLabel() {
        XCTAssertEqual(MusicLyrics.offsetLabel(0), "0s")
        XCTAssertEqual(MusicLyrics.offsetLabel(1500), "+1.5s")
        XCTAssertEqual(MusicLyrics.offsetLabel(-500), "-0.5s")
        XCTAssertEqual(MusicLyrics.offsetLabel(2000), "+2s")
        XCTAssertEqual(MusicLyrics.offsetLabel(-2000), "-2s")
    }

    // MARK: - LRC parsing (B6)

    func testParseLrcMultiTimestampEmitsOneLinePerTag() {
        let lines = MusicLyricsAPI.parseLrc("[00:10.00][00:20.00]hello\n[00:30.00]world")
        XCTAssertEqual(lines.map { $0.time }, [10, 20, 30])
        XCTAssertEqual(lines.map { $0.text }, ["hello", "hello", "world"])
    }

    func testParseLrcKeepsBracketedLyricText() {
        let lines = MusicLyricsAPI.parseLrc("[00:10.00]love [you] so much")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.text, "love [you] so much")
    }

    func testParseLrcStripsSectionLabelOnly() {
        let lines = MusicLyricsAPI.parseLrc("[00:10.00][副歌]sing now")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.text, "sing now")
    }

    // MARK: - Translation passthrough (A11)

    func testToContractLinesKeepsTranslation() {
        let stored = [StoredLyricLine(t: 5, text: "hello", translation: "你好")]
        let contract = MusicLyrics.toContractLines(stored)
        XCTAssertEqual(contract.count, 1)
        XCTAssertEqual(contract.first?.text, "hello")
        XCTAssertEqual(contract.first?.translation, "你好")
    }

    func testParseLrcWithTranslationMatchesByTime() {
        let lines = MusicLyricsAPI.parseLrcWithTranslation(
            "[00:10.00]hello\n[00:20.00]world",
            translation: "[00:10.00]你好\n[00:20.00]世界")
        XCTAssertEqual(lines.map { $0.translation }, ["你好", "世界"])
    }
}

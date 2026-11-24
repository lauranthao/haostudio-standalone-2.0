// HAo Studio 2.0 — music queue tests (S2-C leg).
//
// Queue math + same-track detection. Pure logic, no player, no UI.
// Shuffle takes an injected random-index closure so tests are
// deterministic.

import XCTest

@testable import HAoStudio

final class MusicQueueTests: XCTestCase {
    private func song(_ id: String, title: String = "Song") -> MusicSong {
        return MusicSong(songId: id, title: title, artist: "Artist", platform: .wy, dur: 200)
    }

    // MARK: - Same-track detection (no replay on same tap)

    func testSameTrackDetectedByIdentityKey() {
        var queue = MusicQueue(tracks: [song("1"), song("2"), song("3")], index: 1)
        XCTAssertTrue(queue.isCurrentTrack(song("2")))
        XCTAssertFalse(queue.isCurrentTrack(song("1")))
        XCTAssertFalse(queue.isCurrentTrack(song("3")))
        XCTAssertFalse(queue.isCurrentTrack(song("9")))
    }

    func testEmptyIdSongsDoNotCollapse() {
        // Two id-less songs must NOT share an identity: tapping the
        // second must not be treated as "the first already loaded".
        let first = MusicSong(songId: "", title: "Alpha", artist: "A", platform: .wy)
        let second = MusicSong(songId: "", title: "Beta", artist: "B", platform: .wy)
        let queue = MusicQueue(tracks: [first], index: 0)
        XCTAssertFalse(queue.isCurrentTrack(second))
        XCTAssertTrue(queue.isCurrentTrack(MusicSong(songId: "", title: "Alpha", artist: "A", platform: .wy)))
    }

    func testEmptyQueueHasNoCurrentTrack() {
        let queue = MusicQueue(tracks: [], index: 0)
        XCTAssertNil(queue.current)
        XCTAssertFalse(queue.isCurrentTrack(song("1")))
    }

    // MARK: - Mode cycle + codes

    func testModeCycleOrder() {
        XCTAssertEqual(MusicQueueMode.sequential.next, .listLoop)
        XCTAssertEqual(MusicQueueMode.listLoop.next, .singleLoop)
        XCTAssertEqual(MusicQueueMode.singleLoop.next, .shuffle)
        XCTAssertEqual(MusicQueueMode.shuffle.next, .single)
        XCTAssertEqual(MusicQueueMode.single.next, .sequential)
    }

    func testModeCodesRoundTrip() {
        for mode in MusicQueueMode.cycleOrder {
            XCTAssertEqual(MusicQueueMode.fromCode(mode.code), mode)
        }
        XCTAssertEqual(MusicQueueMode.fromCode("bogus"), .sequential)
        XCTAssertEqual(MusicQueueMode.fromCode(nil), .sequential)
    }

    func testModeLabels() {
        XCTAssertEqual(MusicQueueMode.sequential.label, "顺序播放")
        XCTAssertEqual(MusicQueueMode.listLoop.label, "列表循环")
        XCTAssertEqual(MusicQueueMode.singleLoop.label, "单曲循环")
        XCTAssertEqual(MusicQueueMode.shuffle.label, "随机播放")
        XCTAssertEqual(MusicQueueMode.single.label, "单曲播放")
    }

    // MARK: - Next index

    func testNextSequentialStopsAtEnd() {
        XCTAssertEqual(musicNextTrackIndex(mode: .sequential, current: 0, length: 3, auto: true), 1)
        XCTAssertEqual(musicNextTrackIndex(mode: .sequential, current: 2, length: 3, auto: true), -1)
        XCTAssertEqual(musicNextTrackIndex(mode: .sequential, current: 2, length: 3, auto: false), -1)
    }

    func testNextListLoopWraps() {
        XCTAssertEqual(musicNextTrackIndex(mode: .listLoop, current: 2, length: 3, auto: true), 0)
        XCTAssertEqual(musicNextTrackIndex(mode: .listLoop, current: 0, length: 3, auto: false), 1)
    }

    func testNextSingleLoopAutoReplaysManualAdvances() {
        XCTAssertEqual(musicNextTrackIndex(mode: .singleLoop, current: 1, length: 3, auto: true), 1)
        XCTAssertEqual(musicNextTrackIndex(mode: .singleLoop, current: 1, length: 3, auto: false), 2)
        XCTAssertEqual(musicNextTrackIndex(mode: .singleLoop, current: 2, length: 3, auto: false), 0)
    }

    func testNextSingleAutoStopsManualAdvances() {
        XCTAssertEqual(musicNextTrackIndex(mode: .single, current: 1, length: 3, auto: true), -1)
        XCTAssertEqual(musicNextTrackIndex(mode: .single, current: 1, length: 3, auto: false), 2)
        XCTAssertEqual(musicNextTrackIndex(mode: .single, current: 2, length: 3, auto: false), -1)
    }

    func testNextShufflePicksOtherTrack() {
        // Deterministic "random": always the next index (mod length).
        let pickNext: (Int) -> Int = { length in 1 }
        XCTAssertEqual(
            musicNextTrackIndex(mode: .shuffle, current: 0, length: 3, auto: true, randomIndex: pickNext),
            1
        )
        // Single-track queue: shuffle stays.
        XCTAssertEqual(musicNextTrackIndex(mode: .shuffle, current: 0, length: 1, auto: true), 0)
    }

    func testNextInvalidInputsReturnStop() {
        XCTAssertEqual(musicNextTrackIndex(mode: .sequential, current: -1, length: 3, auto: true), -1)
        XCTAssertEqual(musicNextTrackIndex(mode: .sequential, current: 3, length: 3, auto: true), -1)
        XCTAssertEqual(musicNextTrackIndex(mode: .sequential, current: 0, length: 0, auto: true), -1)
    }

    // MARK: - Previous index

    func testPrevSequentialStopsAtStart() {
        XCTAssertEqual(musicPrevTrackIndex(mode: .sequential, current: 0, length: 3), -1)
        XCTAssertEqual(musicPrevTrackIndex(mode: .sequential, current: 2, length: 3), 1)
    }

    func testPrevLoopModesWrap() {
        XCTAssertEqual(musicPrevTrackIndex(mode: .listLoop, current: 0, length: 3), 2)
        XCTAssertEqual(musicPrevTrackIndex(mode: .singleLoop, current: 0, length: 3), 2)
        XCTAssertEqual(musicPrevTrackIndex(mode: .single, current: 0, length: 3), -1)
    }

    // MARK: - Queue mutation + queue-end prediction

    func testEndsAfterCurrent() {
        let queue = MusicQueue(tracks: [song("1"), song("2")], index: 1)
        XCTAssertTrue(queue.endsAfterCurrent(mode: .sequential))
        XCTAssertTrue(queue.endsAfterCurrent(mode: .single))
        XCTAssertFalse(queue.endsAfterCurrent(mode: .listLoop))
        XCTAssertFalse(queue.endsAfterCurrent(mode: .singleLoop))
    }

    func testRemoveBeforeIndexShiftsIndex() {
        var queue = MusicQueue(tracks: [song("1"), song("2"), song("3")], index: 2)
        queue.remove(at: 0)
        XCTAssertEqual(queue.tracks.map { $0.songId }, ["2", "3"])
        XCTAssertEqual(queue.index, 1)
        XCTAssertEqual(queue.current?.songId, "3")
    }

    func testRemoveCurrentAtEndClamps() {
        var queue = MusicQueue(tracks: [song("1"), song("2")], index: 1)
        queue.remove(at: 1)
        XCTAssertEqual(queue.tracks.map { $0.songId }, ["1"])
        XCTAssertEqual(queue.index, 0)
        XCTAssertEqual(queue.current?.songId, "1")
    }

    func testClearEmptiesQueue() {
        var queue = MusicQueue(tracks: [song("1")], index: 0)
        queue.clear()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.index, 0)
    }

    func testQueueDataRoundTrip() {
        let queue = MusicQueue(tracks: [song("1"), song("2")], index: 1)
        let restored = MusicQueue.fromQueueData(queue.toQueueData())
        XCTAssertEqual(restored.tracks.map { $0.songId }, ["1", "2"])
        XCTAssertEqual(restored.index, 1)
    }

    func testQueueDataClampsOutOfRangeIndex() {
        let restored = MusicQueue.fromQueueData(MusicQueueData(songs: [song("1")], index: 9))
        XCTAssertEqual(restored.index, 0)
    }

    // MARK: - Shuffle bounded retries (B1)

    func testShuffleNextDegenerateRandomFallsBack() {
        // A random source that always returns the current index
        // used to spin the old `while` loop forever. The bounded
        // version must return the next index instead.
        let next = musicNextTrackIndex(mode: .shuffle, current: 1, length: 3, auto: true,
                                       randomIndex: { _ in 1 })
        XCTAssertEqual(next, 2)
    }

    func testShufflePrevDegenerateRandomFallsBack() {
        let prev = musicPrevTrackIndex(mode: .shuffle, current: 1, length: 3,
                                       randomIndex: { _ in 1 })
        XCTAssertEqual(prev, 0)
    }

    func testShuffleNextHonoursRandomWhenItDiffers() {
        let next = musicNextTrackIndex(mode: .shuffle, current: 1, length: 3, auto: true,
                                       randomIndex: { _ in 2 })
        XCTAssertEqual(next, 2)
    }
}

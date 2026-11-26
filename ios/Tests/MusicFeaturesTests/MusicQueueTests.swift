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
        XCTAssertEqual(musicNextTrackIndex(mode: MusicQueueMode.sequential, current: 0, length: 3, auto: true), 1)
        XCTAssertEqual(musicNextTrackIndex(mode: MusicQueueMode.sequential, current: 2, length: 3, auto: true), -1)
        XCTAssertEqual(musicNextTrackIndex(mode: MusicQueueMode.sequential, current: 2, length: 3, auto: false), -1)
    }

    func testNextListLoopWraps() {
        XCTAssertEqual(musicNextTrackIndex(mode: MusicQueueMode.listLoop, current: 2, length: 3, auto: true), 0)
        XCTAssertEqual(musicNextTrackIndex(mode: MusicQueueMode.listLoop, current: 0, length: 3, auto: false), 1)
    }

    func testNextSingleLoopAutoReplaysManualAdvances() {
        XCTAssertEqual(musicNextTrackIndex(mode: MusicQueueMode.singleLoop, current: 1, length: 3, auto: true), 1)
        XCTAssertEqual(musicNextTrackIndex(mode: MusicQueueMode.singleLoop, current: 1, length: 3, auto: false), 2)
        XCTAssertEqual(musicNextTrackIndex(mode: MusicQueueMode.singleLoop, current: 2, length: 3, auto: false), 0)
    }

    func testNextSingleAutoStopsManualAdvances() {
        XCTAssertEqual(musicNextTrackIndex(mode: MusicQueueMode.single, current: 1, length: 3, auto: true), -1)
        XCTAssertEqual(musicNextTrackIndex(mode: MusicQueueMode.single, current: 1, length: 3, auto: false), 2)
        XCTAssertEqual(musicNextTrackIndex(mode: MusicQueueMode.single, current: 2, length: 3, auto: false), -1)
    }

    func testNextShufflePicksOtherTrack() {
        // Deterministic "random": always the next index (mod length).
        let pickNext: (Int) -> Int = { length in 1 }
        XCTAssertEqual(
            musicNextTrackIndex(mode: .shuffle, current: 0, length: 3, auto: true, randomIndex: pickNext),
            1
        )
        // Single-track queue: shuffle stays.
        XCTAssertEqual(musicNextTrackIndex(mode: MusicQueueMode.shuffle, current: 0, length: 1, auto: true), 0)
    }

    func testNextInvalidInputsReturnStop() {
        XCTAssertEqual(musicNextTrackIndex(mode: MusicQueueMode.sequential, current: -1, length: 3, auto: true), -1)
        XCTAssertEqual(musicNextTrackIndex(mode: MusicQueueMode.sequential, current: 3, length: 3, auto: true), -1)
        XCTAssertEqual(musicNextTrackIndex(mode: MusicQueueMode.sequential, current: 0, length: 0, auto: true), -1)
    }

    // MARK: - Previous index

    func testPrevSequentialStopsAtStart() {
        XCTAssertEqual(musicPrevTrackIndex(mode: MusicQueueMode.sequential, current: 0, length: 3), -1)
        XCTAssertEqual(musicPrevTrackIndex(mode: MusicQueueMode.sequential, current: 2, length: 3), 1)
    }

    func testPrevLoopModesWrap() {
        XCTAssertEqual(musicPrevTrackIndex(mode: MusicQueueMode.listLoop, current: 0, length: 3), 2)
        XCTAssertEqual(musicPrevTrackIndex(mode: MusicQueueMode.singleLoop, current: 0, length: 3), 2)
        XCTAssertEqual(musicPrevTrackIndex(mode: MusicQueueMode.single, current: 0, length: 3), -1)
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

    // MARK: - Manual next / previous step (b41)

    func testManualStepOneSongQueueRestartsInEveryMode() {
        // A 1-song queue has no next or previous song in any mode:
        // a manual tap restarts the current song, never nothing.
        for mode in MusicQueueMode.cycleOrder {
            XCTAssertEqual(manualNextStep(mode: mode, current: 0, length: 1), .restartCurrent)
            XCTAssertEqual(manualPrevStep(mode: mode, current: 0, length: 1), .restartCurrent)
        }
    }

    func testManualStepEndsRestartInNonLoopingModes() {
        // Sequential / single: end-of-queue next and start-of-queue
        // previous restart the current song.
        XCTAssertEqual(manualNextStep(mode: .sequential, current: 2, length: 3), .restartCurrent)
        XCTAssertEqual(manualPrevStep(mode: .sequential, current: 0, length: 3), .restartCurrent)
        XCTAssertEqual(manualNextStep(mode: .single, current: 2, length: 3), .restartCurrent)
        XCTAssertEqual(manualPrevStep(mode: .single, current: 0, length: 3), .restartCurrent)
        // Mid-queue still plays the neighbour.
        XCTAssertEqual(manualNextStep(mode: .sequential, current: 0, length: 3), .play(1))
        XCTAssertEqual(manualPrevStep(mode: .sequential, current: 2, length: 3), .play(1))
        XCTAssertEqual(manualNextStep(mode: .single, current: 1, length: 3), .play(2))
        XCTAssertEqual(manualPrevStep(mode: .single, current: 1, length: 3), .play(0))
    }

    func testManualStepLoopModesWrapNeverRestart() {
        XCTAssertEqual(manualNextStep(mode: .listLoop, current: 2, length: 3), .play(0))
        XCTAssertEqual(manualPrevStep(mode: .listLoop, current: 0, length: 3), .play(2))
        XCTAssertEqual(manualNextStep(mode: .singleLoop, current: 2, length: 3), .play(0))
        XCTAssertEqual(manualPrevStep(mode: .singleLoop, current: 0, length: 3), .play(2))
    }

    func testManualStepShufflePlaysAnotherSongOrRestarts() {
        // Multi-song shuffle plays a different song (deterministic
        // source here); 1-song shuffle restarts.
        XCTAssertEqual(manualNextStep(mode: .shuffle, current: 1, length: 3, randomIndex: { _ in 2 }), .play(2))
        XCTAssertEqual(manualPrevStep(mode: .shuffle, current: 1, length: 3, randomIndex: { _ in 0 }), .play(0))
        XCTAssertEqual(manualNextStep(mode: .shuffle, current: 0, length: 1), .restartCurrent)
        XCTAssertEqual(manualPrevStep(mode: .shuffle, current: 0, length: 1), .restartCurrent)
    }

    func testManualStepEmptyQueueIsNothing() {
        XCTAssertEqual(manualNextStep(mode: .sequential, current: 0, length: 0), .nothing)
        XCTAssertEqual(manualPrevStep(mode: .sequential, current: 0, length: 0), .nothing)
        XCTAssertEqual(manualNextStep(mode: .listLoop, current: 0, length: 0), .nothing)
    }

    func testManualStepOutOfRangeCurrentIsNothing() {
        XCTAssertEqual(manualNextStep(mode: .sequential, current: 5, length: 3), .nothing)
        XCTAssertEqual(manualPrevStep(mode: .sequential, current: -1, length: 3), .nothing)
    }

    func testQueueNextPrevStepFollowCurrentIndex() {
        let queue = MusicQueue(tracks: [song("1")], index: 0)
        XCTAssertEqual(queue.nextStep(mode: .sequential), .restartCurrent)
        XCTAssertEqual(queue.prevStep(mode: .sequential), .restartCurrent)
        let list = MusicQueue(tracks: [song("1"), song("2"), song("3")], index: 1)
        XCTAssertEqual(list.nextStep(mode: .sequential), .play(2))
        XCTAssertEqual(list.prevStep(mode: .sequential), .play(0))
        let ended = MusicQueue(tracks: [song("1"), song("2"), song("3")], index: 2)
        XCTAssertEqual(ended.nextStep(mode: .sequential), .restartCurrent)
    }
}

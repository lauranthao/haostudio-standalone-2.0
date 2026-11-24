// HAo Studio 2.0 — song row actions tests (build 36, item 12).
//
// The shared song menu (MusicSongRow "…" button + long-press):
// MusicQueue.insert for play-next, the haoMusicFavChanged
// notification on favourite toggle, and the pure menu
// availability (download / view-artist / view-album). Uses a
// unique test song id and removes it afterwards, so no real
// favourite is touched.
//
// NOTE: like the rest of Tests/MusicFeaturesTests, this target is
// unwired until the S7 Xcode test target exists — it runs with
// `xcodebuild test` against an iOS Simulator destination, not
// `swift test` on Linux.

import XCTest
@testable import HAoStudio

final class MusicSongActionsTests: XCTestCase {
    private func song(_ id: String, title: String = "Song") -> MusicSong {
        return MusicSong(songId: id, title: title, artist: "Artist", platform: .wy, dur: 200)
    }

    private func testSong() -> MusicSong {
        MusicSong(json: [
            "platform": "wy",
            "songId": "b36-actions-test-\(UUID().uuidString)",
            "title": "B36 Actions Test",
            "artist": "HAo Test",
            "album": "Test Album",
            "cover": "",
            "dur": 0,
        ])
    }

    // MARK: - MusicQueue.insert (play next)

    func testInsertAfterCurrentKeepsCurrent() {
        var queue = MusicQueue(tracks: [song("1"), song("2"), song("3")], index: 1)
        queue.insert(song("9"), at: 2)
        XCTAssertEqual(queue.tracks.map { $0.songId }, ["1", "2", "9", "3"])
        XCTAssertEqual(queue.index, 1)
        XCTAssertEqual(queue.current?.songId, "2")
    }

    func testInsertBeforeCurrentShiftsIndex() {
        var queue = MusicQueue(tracks: [song("1"), song("2"), song("3")], index: 2)
        queue.insert(song("9"), at: 0)
        XCTAssertEqual(queue.tracks.map { $0.songId }, ["9", "1", "2", "3"])
        XCTAssertEqual(queue.index, 3)
        XCTAssertEqual(queue.current?.songId, "3")
    }

    func testInsertDedupeMovesSongBeforeCurrentToNext() {
        // Play-next a song queued before the current track: it
        // moves to right after the current track, never duplicates.
        var queue = MusicQueue(tracks: [song("1"), song("2"), song("3"), song("4")], index: 2)
        queue.insert(song("2"), at: 3)
        XCTAssertEqual(queue.tracks.map { $0.songId }, ["1", "3", "2", "4"])
        XCTAssertEqual(queue.index, 1)
        XCTAssertEqual(queue.current?.songId, "3")
    }

    func testInsertDedupeMovesSongAfterCurrentToNext() {
        var queue = MusicQueue(tracks: [song("1"), song("2"), song("3"), song("4")], index: 1)
        queue.insert(song("4"), at: 2)
        XCTAssertEqual(queue.tracks.map { $0.songId }, ["1", "2", "4", "3"])
        XCTAssertEqual(queue.index, 1)
        XCTAssertEqual(queue.current?.songId, "2")
    }

    func testInsertCurrentSongIsNoop() {
        var queue = MusicQueue(tracks: [song("1"), song("2"), song("3")], index: 1)
        queue.insert(song("2"), at: 2)
        XCTAssertEqual(queue.tracks.map { $0.songId }, ["1", "2", "3"])
        XCTAssertEqual(queue.index, 1)
    }

    func testInsertIntoEmptyQueue() {
        var queue = MusicQueue(tracks: [], index: 0)
        queue.insert(song("1"), at: 1)
        XCTAssertEqual(queue.tracks.map { $0.songId }, ["1"])
        XCTAssertEqual(queue.index, 0)
        XCTAssertEqual(queue.current?.songId, "1")
    }

    func testInsertClampsOutOfRangePosition() {
        var queue = MusicQueue(tracks: [song("1"), song("2")], index: 0)
        queue.insert(song("9"), at: 99)
        XCTAssertEqual(queue.tracks.map { $0.songId }, ["1", "2", "9"])
        XCTAssertEqual(queue.index, 0)
    }

    // MARK: - Favourite toggle posts haoMusicFavChanged

    func testToggleFavPostsFavChangedNotification() {
        let song = testSong()
        XCTAssertFalse(MusicLibraryStore.isFav(song), "test song must start unfavourited")
        let posted = expectation(forNotification: .haoMusicFavChanged, object: nil)
        XCTAssertTrue(MusicLibraryStore.toggleFav(song), "first toggle adds")
        waitForExpectations(timeout: 2)
        XCTAssertNotNil(posted, "toggle posts haoMusicFavChanged")
        XCTAssertFalse(MusicLibraryStore.toggleFav(song), "cleanup: second toggle removes")
        XCTAssertFalse(MusicLibraryStore.isFav(song))
    }

    // MARK: - Menu availability

    func testDownloadHiddenForLocalSong() {
        let local = MusicSong(
            songId: "local:abc", title: "Local", artist: "A",
            platform: .wy, localPath: "/tmp/local.mp3")
        XCTAssertTrue(local.isLocal)
        XCTAssertFalse(MusicSongMenuAvailability.canDownload(song: local))
    }

    func testDownloadAvailableForRemoteSong() {
        XCTAssertTrue(MusicSongMenuAvailability.canDownload(song: song("1")))
        // A remote song that merely carries a stale localPath is
        // not local: isLocal needs the local: id prefix too.
        let remote = MusicSong(
            songId: "123", title: "Remote", artist: "A",
            platform: .wy, localPath: "/tmp/stale.mp3")
        XCTAssertFalse(remote.isLocal)
        XCTAssertTrue(MusicSongMenuAvailability.canDownload(song: remote))
    }

    func testViewAlbumHiddenWhenAlbumEmpty() {
        XCTAssertFalse(MusicSongMenuAvailability.canViewAlbum(song: song("1")))
        let withAlbum = MusicSong(
            songId: "1", title: "T", artist: "A", album: "Some Album", platform: .wy)
        XCTAssertTrue(MusicSongMenuAvailability.canViewAlbum(song: withAlbum))
    }

    func testViewArtistHiddenWhenArtistEmpty() {
        let noArtist = MusicSong(songId: "1", title: "T", artist: "  ", platform: .wy)
        XCTAssertFalse(MusicSongMenuAvailability.canViewArtist(song: noArtist))
        XCTAssertTrue(MusicSongMenuAvailability.canViewArtist(song: song("1")))
    }

    func testShareTextUsesRealSongData() {
        let shared = MusicSongMenuAvailability.shareText(song: song("1", title: "夜曲"))
        XCTAssertEqual(shared, "《夜曲》 - Artist（网易）")
    }
}

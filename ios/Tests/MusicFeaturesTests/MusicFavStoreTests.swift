// HAo Studio 2.0 — music favourite store tests (fix 2026-11-24, build 35).
//
// The title-row star wires MusicPlayerViewModel.toggleFavourite()
// -> MusicLibraryStore.toggleFav/isFav (local file hao_fav.json).
// This proves the round-trip persists: toggle on, a fresh read
// sees it; toggle off, it is gone. Uses a unique test song id and
// removes it afterwards, so no real favourite is touched.
//
// NOTE: like the rest of Tests/MusicFeaturesTests, this target is
// unwired until the S7 Xcode test target exists — it runs with
// `xcodebuild test` against an iOS Simulator destination, not
// `swift test` on Linux.

import XCTest
@testable import HAoStudio

final class MusicFavStoreTests: XCTestCase {
    private func testSong() -> MusicSong {
        MusicSong(json: [
            "platform": "wy",
            "songId": "b35-fav-test-\(UUID().uuidString)",
            "title": "B35 Fav Test",
            "artist": "HAo Test",
            "album": "",
            "cover": "",
            "dur": 0,
        ])
    }

    func testToggleFavPersistsAcrossReads() {
        let song = testSong()
        XCTAssertFalse(MusicLibraryStore.isFav(song), "test song must start unfavourited")
        XCTAssertTrue(MusicLibraryStore.toggleFav(song), "first toggle adds")
        XCTAssertTrue(MusicLibraryStore.isFav(song), "fresh read sees the favourite")
        XCTAssertTrue(
            MusicLibraryStore.favSongs().contains(where: { $0.identityKey == song.identityKey }),
            "favourite list contains the song")
        XCTAssertFalse(MusicLibraryStore.toggleFav(song), "second toggle removes")
        XCTAssertFalse(MusicLibraryStore.isFav(song), "fresh read sees the removal")
    }

    func testToggleFavDoesNotTouchOtherSongs() {
        let first = testSong()
        let second = testSong()
        XCTAssertTrue(MusicLibraryStore.toggleFav(first))
        XCTAssertFalse(MusicLibraryStore.isFav(second))
        XCTAssertFalse(MusicLibraryStore.toggleFav(first), "cleanup: second toggle removes")
        XCTAssertFalse(MusicLibraryStore.isFav(first))
    }
}

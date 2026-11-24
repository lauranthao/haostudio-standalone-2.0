// HAo Studio 2.0 — music audit tests (build-33 fix round).
//
// Covers this round's feature-layer fixes: the playback item
// carries its cover (mini player + Now Playing artwork), the
// mini player renders at the Beans height, and 最近播放 reloads
// the moment the store changes.
//
// NOTE: like the rest of Tests/MusicFeaturesTests, this target is
// unwired until the S7 Xcode test target exists (see Package.swift
// header) — `swift test` does not run it yet. It runs with
// `xcodebuild test` against an iOS Simulator destination. The
// mini-height test assumes that target compiles App/Glass.swift
// alongside the music features (as MiniPlayerBar itself does);
// the recent test writes one recent entry and clears it again,
// so the store is left as it was found.

import Combine
import XCTest

@testable import HAoStudio

final class MusicAuditTests: XCTestCase {

    // MARK: - Playback item carries its cover (mini + Now Playing)

    func testToPlaybackItemCarriesCoverAndUpgradesHttp() {
        let song = MusicSong(
            songId: "1", title: "认了吧", artist: "陈奕迅", album: "认了吧",
            cover: "http://p1.music.126.net/abc", platform: .wy, dur: 200
        )
        let item = song.toPlaybackItem()
        XCTAssertEqual(item.id, song.identityKey)
        XCTAssertEqual(item.coverURL?.absoluteString, "https://p1.music.126.net/abc")
    }

    func testToPlaybackItemKeepsHttpsCover() {
        let song = MusicSong(
            songId: "2", title: "歌", artist: "歌手",
            cover: "https://y.gtimg.cn/cover.jpg", platform: .tx, dur: 180
        )
        XCTAssertEqual(
            song.toPlaybackItem().coverURL?.absoluteString,
            "https://y.gtimg.cn/cover.jpg"
        )
    }

    func testToPlaybackItemHasNoCoverWhenSongHasNone() {
        let song = MusicSong(title: "无封面", artist: "歌手")
        XCTAssertNil(song.toPlaybackItem().coverURL)
    }

    // MARK: - Mini player height (Beans MiniPlayerView: 50pt)

    func testMiniPlayerHeightMatchesBeans() {
        XCTAssertEqual(HaoLayout.miniPlayerHeight, 50)
    }

    // MARK: - 最近播放 reloads on store change (real-time)

    func testRecentChangeNotificationReloadsHome() {
        let song = MusicSong(
            songId: "r1", title: "最近", artist: "歌手",
            cover: "", platform: .wy, dur: 180
        )
        MusicLibraryStore.clearRecent()
        defer { MusicLibraryStore.clearRecent() }
        let homeVM = MusicHomeViewModel()
        XCTAssertTrue(homeVM.recent.isEmpty)
        let reloaded = expectation(description: "home reloads on recent change")
        var token: AnyCancellable?
        token = homeVM.$recent.sink { recent in
            if recent.contains(where: { $0.identityKey == song.identityKey }) {
                reloaded.fulfill()
            }
        }
        MusicLibraryStore.addRecent(song)
        waitForExpectations(timeout: 2)
        token?.cancel()
    }
}

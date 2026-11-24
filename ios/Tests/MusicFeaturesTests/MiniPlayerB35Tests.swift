// HAo Studio 2.0 — mini player build-35 fix tests.
//
// Covers the b35 mini leg: the strip keeps showing the loaded music
// song when the coordinator has no current item (its URL failed to
// resolve, or playback was stopped), exactly like the full player
// does — and hides only when the queue is truly empty. Plus the
// geometry contract against the tab bar (same width, same corner
// radius, same vertical spacing, ~6pt above the home indicator).
//
// NOTE: like the rest of Tests/MusicFeaturesTests, this target is
// unwired until the S7 Xcode test target exists (see Package.swift
// header) — `swift test` does not run it yet. It runs with
// `xcodebuild test` against an iOS Simulator destination. The
// geometry tests assume that target compiles App/Glass.swift
// alongside the music features (as MiniPlayerBar itself does).

import Combine
import XCTest

@testable import HAoStudio

/// Stand-in music driver: the test fires started / failed through
/// the callbacks the coordinator wires in `musicDriver.didSet`.
private final class StubMusicDriver: MusicPlaybackDriver {
    var currentTrack: PlaybackItem?
    var isPlaying = false
    var resolveURL: ((PlaybackItem, [URL], @escaping (URL?, AudioQuality?) -> Void) -> Void)?
    var onTrackStarted: ((PlaybackItem) -> Void)?
    var onTrackFailed: ((PlaybackItem, MusicPlayerError) -> Void)?
    func play(item: PlaybackItem) {}
    func open(item: PlaybackItem, url: URL, completion: @escaping (Result<Void, MusicPlayerError>) -> Void) {}
    func stop() {}
    func resume() {}
}

final class MiniPlayerB35Tests: XCTestCase {

    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - Geometry: mini == tab bar (shared HaoLayout constants)

    /// Both the mini and the tab bar sit in MainTabView with the
    /// same 12pt side margins, so both are screen − 24 on every
    /// width — iPhone SE (320) through Pro Max (430).
    func testMiniAndTabBarShareWidth() {
        for width: CGFloat in [320, 360, 375, 390, 393, 402, 428, 430] {
            let chromeWidth = width - 2 * HaoLayout.tabBarHorizontalMargin
            XCTAssertEqual(chromeWidth, width - 24, "screen width \(width)")
        }
    }

    /// The mini is the row directly above the bar: VStack spacing
    /// 8pt, so the mini's bottom edge is the tab bar's top edge.
    func testMiniSitsDirectlyAboveTabBar() {
        XCTAssertEqual(HaoLayout.floatingStackSpacing, 8)
        XCTAssertEqual(
            HaoLayout.floatingStackClearance(miniPlayerVisible: true),
            HaoLayout.tabBarBottomMargin + HaoLayout.tabBarTotalHeight
                + HaoLayout.floatingStackSpacing + HaoLayout.miniPlayerHeight
        )
    }

    /// The visible bar sits ~6pt above the home-indicator zone:
    /// 2pt bottom margin + 4pt inner inset.
    func testTabBarSitsNearHomeIndicator() {
        XCTAssertEqual(
            HaoLayout.tabBarBottomMargin + HaoLayout.tabBarInnerInset, 6)
    }

    /// One shape, one radius: the mini is a rounded rectangle at
    /// the shared floating-chrome radius (12), not a capsule; its
    /// content padding is symmetric (12 both sides).
    func testMiniCornerRadiusAndPadding() {
        XCTAssertEqual(HaoLayout.floatingChromeCornerRadius, 12)
        XCTAssertEqual(HaoLayout.miniPlayerContentPadding, 12)
        XCTAssertEqual(HaoLayout.miniPlayerHeight, 50)
    }

    /// Bottom clearance for scroll content under the stack: 66pt
    /// idle, 124pt while the mini is showing (58pt taller).
    func testFloatingStackClearance() {
        XCTAssertEqual(HaoLayout.floatingStackClearance(miniPlayerVisible: false), 66)
        XCTAssertEqual(HaoLayout.floatingStackClearance(miniPlayerVisible: true), 124)
    }

    // MARK: - Fallback: failed / stopped track keeps the mini visible

    /// A track whose URL fails to resolve: the coordinator clears
    /// the current item, but the mini must keep showing the song —
    /// exactly like the full player (currentSong) does. stop()
    /// behaves the same. Only a truly empty queue hides the mini.
    func testFailedTrackKeepsMiniVisibleAndMatchesFullPlayer() {
        let coordinator = PlaybackCoordinator(
            defaults: UserDefaults(suiteName: "MiniPlayerB35Tests") ?? .standard)
        let driver = StubMusicDriver()
        coordinator.musicDriver = driver
        let viewModel = MusicPlayerViewModel(coordinator: coordinator)
        // Normalise: a host with a saved queue would restore a song
        // into currentSong before the test starts.
        viewModel.clearQueue()

        let song = PlaybackItem(
            id: "wy|123", kind: .music, title: "认了吧", artist: "陈奕迅",
            coverURL: URL(string: "https://p1.music.126.net/abc"))
        // Keep loadLyrics offline: the fallback song is built with
        // the default platform, so its identity key is "wy|wy|123".
        MusicLibraryStore.putLyrics([], for: "wy|wy|123")

        // Track starts: the mini fallback and the full player's
        // current song land on it together.
        let started = expectation(description: "fallback song appears")
        viewModel.$miniFallbackSong.sink { if $0 != nil { started.fulfill() } }
            .store(in: &cancellables)
        driver.onTrackStarted?(song)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(coordinator.currentItem?.id, "wy|123")
        XCTAssertEqual(viewModel.miniFallbackSong?.title, "认了吧")
        XCTAssertEqual(viewModel.currentSong?.title, "认了吧")

        // The URL fails to resolve: the coordinator clears the
        // current item, but the mini keeps the song — the same song
        // the full player keeps showing.
        let cleared = expectation(description: "current item clears")
        coordinator.$currentItem.sink { if $0 == nil { cleared.fulfill() } }
            .store(in: &cancellables)
        driver.onTrackFailed?(song, .noPlayableURL)
        waitForExpectations(timeout: 2)
        XCTAssertNil(coordinator.currentItem)
        XCTAssertEqual(viewModel.miniFallbackSong?.title, "认了吧")
        XCTAssertEqual(viewModel.currentSong?.title, "认了吧")

        // stop() clears the current item only: the loaded song
        // stays, so the mini stays.
        coordinator.stop()
        XCTAssertNil(coordinator.currentItem)
        XCTAssertEqual(viewModel.miniFallbackSong?.title, "认了吧")

        // Only a truly empty queue hides the mini.
        viewModel.clearQueue()
        XCTAssertNil(viewModel.miniFallbackSong)
        XCTAssertNil(viewModel.currentSong)
    }

    /// A VOD episode / live room must never become a mini "song":
    /// the fallback is music-only, so a failed episode hides the
    /// mini instead of surfacing with music transport buttons.
    func testNonMusicItemNeverBecomesMiniFallback() {
        let coordinator = PlaybackCoordinator(
            defaults: UserDefaults(suiteName: "MiniPlayerB35Tests") ?? .standard)
        let driver = StubMusicDriver()
        coordinator.musicDriver = driver
        let viewModel = MusicPlayerViewModel(coordinator: coordinator)
        viewModel.clearQueue()

        let episode = PlaybackItem(
            id: "vod-episode-1", kind: .vod, title: "第01集", artist: "剧集")
        // Keep loadLyrics offline here too: the episode is converted
        // to a song with the default platform, key "wy|vod-episode-1".
        MusicLibraryStore.putLyrics([], for: "wy|vod-episode-1")
        let started = expectation(description: "current item appears")
        coordinator.$currentItem.sink { if $0 != nil { started.fulfill() } }
            .store(in: &cancellables)
        driver.onTrackStarted?(episode)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(coordinator.currentItem?.kind, .vod)
        XCTAssertNil(viewModel.miniFallbackSong)

        let cleared = expectation(description: "current item clears")
        coordinator.$currentItem.sink { if $0 == nil { cleared.fulfill() } }
            .store(in: &cancellables)
        driver.onTrackFailed?(episode, .loadFailed)
        waitForExpectations(timeout: 2)
        XCTAssertNil(coordinator.currentItem)
        XCTAssertNil(viewModel.miniFallbackSong)
    }
}

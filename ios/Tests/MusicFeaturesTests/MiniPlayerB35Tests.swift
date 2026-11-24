// HAo Studio 2.0 — mini player build-35 fix tests.
//
// Covers the b35 mini leg: the strip keeps showing the loaded music
// song when the coordinator has no current item (its URL failed to
// resolve, or playback was stopped), exactly like the full player
// does — and hides only when the queue is truly empty. Plus the
// geometry contract against the tab bar (same width, same corner
// radius, one connected unit with no gap, bottom edge 8pt above the
// screen edge — b38, chen 2026-11-24 "你看布局啊" / "菜单可以往底下
// 挪一下" / "mini 播放器做短一点").
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
    var pauseCalled = false
    var resolveURL: ((PlaybackItem, [URL], @escaping (URL?, AudioQuality?) -> Void) -> Void)?
    var onTrackStarted: ((PlaybackItem) -> Void)?
    var onTrackFailed: ((PlaybackItem, MusicPlayerError) -> Void)?
    func play(item: PlaybackItem) {}
    func open(item: PlaybackItem, url: URL, completion: @escaping (Result<Void, MusicPlayerError>) -> Void) {}
    func pause() { pauseCalled = true }
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

    /// The mini is the row directly above the bar — and in b38 the
    /// two touch: VStack spacing 0, so the mini's bottom edge IS
    /// the tab bar's top edge (one connected unit, no seam).
    func testMiniSitsDirectlyAboveTabBar() {
        XCTAssertEqual(HaoLayout.floatingStackSpacing, 0)
        XCTAssertEqual(
            HaoLayout.floatingStackClearance(miniPlayerVisible: true),
            HaoLayout.tabBarBottomMargin + HaoLayout.tabBarTotalHeight
                + HaoLayout.floatingStackSpacing + HaoLayout.miniPlayerHeight
        )
    }

    /// The whole unit is dropped so its bottom edge sits 8pt above
    /// the screen edge (chromeBottomGap — the home indicator's own
    /// space). The drop is the bottom safe inset minus that gap:
    /// 26pt on a 34pt Face ID device, 12pt on a 20pt device, 0
    /// where there is no bottom safe area. The bar itself has no
    /// bottom margin any more (the old 2pt + 4pt inner inset left
    /// it floating 6pt above the home-indicator zone).
    func testTabBarSitsNearHomeIndicator() {
        XCTAssertEqual(HaoLayout.tabBarBottomMargin, 0)
        XCTAssertEqual(HaoLayout.chromeBottomGap, 8)
        XCTAssertEqual(HaoLayout.bottomOffset(forSafeBottom: 34), 26)
        XCTAssertEqual(HaoLayout.bottomOffset(forSafeBottom: 20), 12)
        XCTAssertEqual(HaoLayout.bottomOffset(forSafeBottom: 0), 0)
    }

    /// One shape, one radius: the mini is a rounded rectangle at
    /// the shared floating-chrome radius (24, b35 polish), not a
    /// content padding is symmetric (12 both sides). The strip is
    /// 40pt in b38 (Kumone total — cover 32 + 2 x 4pt padding),
    /// down from 44: chen 2026-11-24 "mini 播放器做短一点".
    func testMiniCornerRadiusAndPadding() {
        XCTAssertEqual(HaoLayout.floatingChromeCornerRadius, 24)
        XCTAssertEqual(HaoLayout.miniPlayerContentPadding, 12)
        XCTAssertEqual(HaoLayout.miniPlayerHeight, 40)
    }

    /// Bottom clearance for scroll content under the stack: 64pt
    /// idle, 104pt while the mini is showing (40pt taller).
    func testFloatingStackClearance() {
        XCTAssertEqual(HaoLayout.floatingStackClearance(miniPlayerVisible: false), 64)
        XCTAssertEqual(HaoLayout.floatingStackClearance(miniPlayerVisible: true), 104)
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

// MARK: - b35 tab-bar link: morph contract (minimize reverted, build 37)

/// Covers the b35 tab-bar link leg's SURVIVING contract: the
/// cover-morph constants (mini 32 -> full player up to 340, one
/// shared matchedGeometryEffect id) and the floating-stack
/// clearance (64 idle / 104 playing). The scroll-driven minimize
/// itself is REVERTED in build 37 (chen 2026-11-24: "菜单恢复原样"
/// — the menu stays the original full glass tab bar, no narrowed
/// capsule form): the state-machine tests, the minimized-row
/// geometry tests and the inline-mini (32) constant are deleted
/// with it. The morph animation itself is device-only: no
/// simulator runs here, so it is listed as "needs device
/// confirmation", not asserted.
@MainActor
final class BottomChromeB35Tests: XCTestCase {

    // MARK: - Clearance: follows the mini player, never shrinks

    /// Clearance is 104pt while the mini is showing and 64pt
    /// idle — it no longer shrinks to 64 when minimized, because
    /// there is no minimized form any more.
    func testClearanceFollowsMiniPlayer() {
        XCTAssertEqual(
            HaoLayout.floatingStackClearance(miniPlayerVisible: true), 104)
        XCTAssertEqual(
            HaoLayout.floatingStackClearance(miniPlayerVisible: false), 64)
    }

    // MARK: - Morph contract: one cover, one id, known sizes

    /// The morph endpoints are constants, not literals scattered in
    /// the views: mini cover 32 (b38, Kumone), full-player cover
    /// capped at 340 (MusicPlayerView.coverSize), one shared id.
    func testCoverMorphEndpoints() {
        XCTAssertEqual(HaoLayout.miniCoverSize, 32)
        XCTAssertFalse(HaoLayout.playerCoverMorphID.isEmpty)
    }
}

// MARK: - b36-1: rest-offset calibration (large-title tabs)

/// b36-1: the anchor's rest offset is NOT 0 — every tab uses a
/// large navigation title, so the anchor rests ~+100. isAtTop is
/// relative to the learned rest offset (16pt band). Build 37: the
/// minimize state machine these tests used to drive is gone (menu
/// revert), so the tests assert isAtTop — the surviving behaviour
/// the rest-offset learning feeds (reselect scroll-to-top guard).
@MainActor
final class BottomChromeB36Tests: XCTestCase {

    /// Rest +100 (large title): isAtTop stays true within 16pt
    /// of the rest, false once clearly below it. The old absolute
    /// threshold (minY >= -16) would have read "at top" until
    /// ~116pt of scrolling from a +100 rest.
    func testLargeTitleRestCalibratesIsAtTop() {
        let state = BottomChromeState()
        state.noteScrollOffset(100)
        XCTAssertTrue(state.isAtTop)
        // 16pt down: still at the top (inside the band).
        state.noteScrollOffset(84)
        XCTAssertTrue(state.isAtTop)
        // 40pt down: below the top.
        for offset in [80, 76, 72, 68, 64, 60] as [CGFloat] {
            state.noteScrollOffset(offset)
        }
        XCTAssertFalse(state.isAtTop)
    }

    /// Scroll back up to within 16pt of the rest offset restores
    /// isAtTop.
    func testScrollUpRestoresToCalibratedTop() {
        let state = BottomChromeState()
        state.noteScrollOffset(100)
        state.noteScrollOffset(36)
        XCTAssertFalse(state.isAtTop)
        for offset in [40, 44, 48, 52, 56, 60, 64, 68, 72, 76, 80, 84] as [CGFloat] {
            state.noteScrollOffset(offset)
        }
        XCTAssertTrue(state.isAtTop)
    }

    /// Tab switch resets the learned rest: a tab whose top is
    /// lower than the previous tab's must not read "at top" from
    /// the old rest — and must read "at top" at its own top.
    func testTabSwitchResetsRestOffset() {
        let state = BottomChromeState()
        state.noteScrollOffset(140)
        state.noteScrollOffset(76)
        XCTAssertFalse(state.isAtTop)
        state.resetRest()
        // New tab at its own top (+56): at the top.
        state.noteScrollOffset(56)
        XCTAssertTrue(state.isAtTop)
        // ...and 64pt down from ITS top: below the top.
        state.noteScrollOffset(-8)
        XCTAssertFalse(state.isAtTop)
    }

    /// First report mid-scroll (tab restored scrolled down)
    /// reads below the top from the absolute fallback, as before.
    func testFirstReportMidScrollIsNotAtTop() {
        let state = BottomChromeState()
        state.noteScrollOffset(-200)
        XCTAssertFalse(state.isAtTop)
    }

    /// b36-8: a pull-to-refresh / overscroll bounce at the top
    /// must not raise the learned rest offset. The anchor's minY
    /// briefly rises above the true top during the bounce; the old
    /// running-max learning adopted it, and isAtTop then stayed
    /// true while scrolled down. The rest is learned once, from
    /// the first report after a reset — later upward moves are
    /// bounce.
    func testBounceOvershootDoesNotRaiseRest() {
        let state = BottomChromeState()
        state.noteScrollOffset(100)
        XCTAssertTrue(state.isAtTop)
        // Pull down past the top (bounce to +180) and spring back.
        for offset in [130, 160, 180, 160, 130, 110, 100] as [CGFloat] {
            state.noteScrollOffset(offset)
            XCTAssertTrue(state.isAtTop, "offset \(offset)")
        }
        // Still at the top — and scrolling down from the true top
        // still reads below the top after 64pt.
        for offset in [96, 92, 88, 84, 80, 76, 72, 68, 64, 60, 56, 52, 48, 44, 40, 36] as [CGFloat] {
            state.noteScrollOffset(offset)
        }
        XCTAssertFalse(state.isAtTop)
    }

    // MARK: - Headphone unplug (§6.3, Phase 5): pausePlaying()

    /// A playing driver is paused; the item is NOT stopped or
    /// cleared — pausePlaying never touches currentItem, so the
    /// mini player stays and one tap resumes.
    func testPausePlayingPausesPlayingDriver() {
        let coordinator = PlaybackCoordinator(
            defaults: UserDefaults(suiteName: "MiniPlayerB35Tests") ?? .standard)
        let driver = StubMusicDriver()
        driver.isPlaying = true
        driver.currentTrack = PlaybackItem(
            id: "wy|123", kind: .music, title: "认了吧", artist: "陈奕迅",
            coverURL: nil)
        coordinator.musicDriver = driver
        coordinator.pausePlaying()
        XCTAssertTrue(driver.pauseCalled)
    }

    /// Nothing playing: pausePlaying is a no-op and never calls
    /// pause on an idle driver (no state churn, no Now Playing
    /// refresh for a route change that needs no action).
    func testPausePlayingIsNoopWhenNothingPlaying() {
        let coordinator = PlaybackCoordinator(
            defaults: UserDefaults(suiteName: "MiniPlayerB35Tests") ?? .standard)
        let driver = StubMusicDriver()
        driver.isPlaying = false
        coordinator.musicDriver = driver
        coordinator.pausePlaying()
        XCTAssertFalse(driver.pauseCalled)
    }
}

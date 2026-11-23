// HAo Studio 2.0 — VOD playback-settings wiring tests (S7 wiring, leg A).
//
// Pure-logic tests only (AppCore, `swift test`): the enhancement
// trio, subtitle tier maps, double-tap seek, skip-intro window +
// state machine, spoiler helpers, per-episode custom intro
// seconds. No network, no real data. The custom-durations test
// uses a temp documents directory (injected); nothing here
// touches the real Documents directory or the standard defaults.
//
// Driver / backend wiring (DV-P8 candidate routing, subtitle +
// enhancement + audio-only forwarding) lives in
// Tests/VideoPlayerTests/VideoPlayerTests.swift (HAoStudioTests
// Xcode target) — those types are iOS-only and cannot compile
// under `swift test`.

import Foundation
import XCTest

@testable import AppCore

final class VodPlaybackSettingsTests: XCTestCase {
    // MARK: - Enhancement trio

    func testTrioAllOffResolvesNil() {
        XCTAssertNil(resolveVodEnhancement(superResolution: false, interpolation: false, sdrToHdr: false))
    }

    func testTrioEachBranchAlone() {
        XCTAssertEqual(resolveVodEnhancement(superResolution: true, interpolation: false, sdrToHdr: false), .superResolution)
        XCTAssertEqual(resolveVodEnhancement(superResolution: false, interpolation: true, sdrToHdr: false), .interpolation)
        XCTAssertEqual(resolveVodEnhancement(superResolution: false, interpolation: false, sdrToHdr: true), .sdrToHdr)
    }

    func testTrioFirstBranchWins() {
        // Super-res beats both; interpolation beats SDR→HDR; a
        // switch turned on while another is on cannot take effect.
        XCTAssertEqual(resolveVodEnhancement(superResolution: true, interpolation: true, sdrToHdr: true), .superResolution)
        XCTAssertEqual(resolveVodEnhancement(superResolution: false, interpolation: true, sdrToHdr: true), .interpolation)
    }

    // MARK: - Subtitle appearance tiers

    func testSubtitleTiersMatchFlutterValues() {
        XCTAssertEqual(VodSubtitleAppearance.forTiers(fontSize: "small", color: "white", position: "bottom"), VodSubtitleAppearance(fontSize: 42, color: "#FFFFFF", position: 100.0))
        XCTAssertEqual(VodSubtitleAppearance.forTiers(fontSize: "medium", color: "yellow", position: "middle"), VodSubtitleAppearance(fontSize: 55, color: "#FFFF00", position: 50.0))
        XCTAssertEqual(VodSubtitleAppearance.forTiers(fontSize: "large", color: "cyan", position: "top"), VodSubtitleAppearance(fontSize: 70, color: "#00FFFF", position: 8.0))
    }

    func testSubtitleUnknownTierReadsAsDefault() {
        XCTAssertEqual(VodSubtitleAppearance.forTiers(fontSize: "huge", color: "pink", position: "side"), .default)
        XCTAssertEqual(VodSubtitleAppearance.default, VodSubtitleAppearance(fontSize: 55, color: "#FFFFFF", position: 100.0))
    }

    // MARK: - Double-tap seek

    func testDoubleTapSeekForwardAndBack() {
        XCTAssertEqual(resolveDoubleTapSeek(position: 100, duration: 1000, forward: true, seconds: 10), 110)
        XCTAssertEqual(resolveDoubleTapSeek(position: 100, duration: 1000, forward: false, seconds: 30), 70)
    }

    func testDoubleTapSeekClampsToDurationAndZero() {
        XCTAssertEqual(resolveDoubleTapSeek(position: 995, duration: 1000, forward: true, seconds: 30), 1000)
        XCTAssertEqual(resolveDoubleTapSeek(position: 5, duration: 1000, forward: false, seconds: 30), 0)
    }

    func testDoubleTapSeekWithUnknownDurationGoesNowhere() {
        XCTAssertEqual(resolveDoubleTapSeek(position: 40, duration: 0, forward: true, seconds: 10), 40)
    }

    // MARK: - Skip-intro window

    func testIntroWindowPrefersMarkerEndOverCustom() {
        XCTAssertEqual(resolveIntroWindow(introStart: 2, introEnd: 90, customSeconds: 60), VodSkipWindow(start: 2, end: 90))
    }

    func testIntroWindowFallsBackToCustomSeconds() {
        XCTAssertEqual(resolveIntroWindow(introStart: nil, introEnd: nil, customSeconds: 60), VodSkipWindow(start: 0, end: 60))
    }

    func testIntroWindowNilWhenNothingToSkipTo() {
        XCTAssertNil(resolveIntroWindow(introStart: nil, introEnd: nil, customSeconds: 0))
        XCTAssertNil(resolveIntroWindow(introStart: nil, introEnd: 0, customSeconds: 0))
        XCTAssertNil(resolveIntroWindow(introStart: 90, introEnd: 90, customSeconds: 0))
        XCTAssertNil(resolveIntroWindow(introStart: 100, introEnd: 90, customSeconds: 0))
    }

    // MARK: - Skip-intro state machine

    private func windowedState() -> VodSkipIntroState {
        var state = VodSkipIntroState()
        state.resetForEpisode(window: VodSkipWindow(start: 0, end: 90), creditsStart: 3000)
        return state
    }

    func testSkipOffDoesNothing() {
        var state = windowedState()
        XCTAssertEqual(state.check(position: 10, duration: 3600, mode: .off, isPlaying: true, elapsed: 0.5), .none)
    }

    func testSkipManualShowsPillInWindowOnly() {
        var state = windowedState()
        XCTAssertEqual(state.check(position: 10, duration: 3600, mode: .manual, isPlaying: true, elapsed: 0.5), .showIntroPill(countdown: nil))
        XCTAssertEqual(state.check(position: 100, duration: 3600, mode: .manual, isPlaying: true, elapsed: 0.5), .none)
    }

    func testSkipAutoNowSeeksOnceThenShowsPillOnSeekBack() {
        var state = windowedState()
        XCTAssertEqual(state.check(position: 10, duration: 3600, mode: .autoNow, isPlaying: true, elapsed: 0.5), .skipIntro(to: 90))
        // Still in the window (the seek has not landed yet in the
        // test's eyes): no second auto seek, the manual pill shows.
        XCTAssertEqual(state.check(position: 10, duration: 3600, mode: .autoNow, isPlaying: true, elapsed: 0.5), .showIntroPill(countdown: nil))
    }

    func testSkipAutoNowDoesNotSeekWhilePaused() {
        var state = windowedState()
        XCTAssertEqual(state.check(position: 10, duration: 3600, mode: .autoNow, isPlaying: false, elapsed: 0.5), .showIntroPill(countdown: nil))
        // Resuming inside the window still auto-skips once.
        XCTAssertEqual(state.check(position: 10, duration: 3600, mode: .autoNow, isPlaying: true, elapsed: 0.5), .skipIntro(to: 90))
    }

    func testSkipAuto3sCountsDownThenSeeks() {
        var state = windowedState()
        // 0.5 s ticks: 3, 2, 2, 1, 1, then the seek on the 6th.
        XCTAssertEqual(state.check(position: 10, duration: 3600, mode: .auto3s, isPlaying: true, elapsed: 0.5), .showIntroPill(countdown: 3))
        XCTAssertEqual(state.check(position: 10, duration: 3600, mode: .auto3s, isPlaying: true, elapsed: 0.5), .showIntroPill(countdown: 2))
        XCTAssertEqual(state.check(position: 10, duration: 3600, mode: .auto3s, isPlaying: true, elapsed: 0.5), .showIntroPill(countdown: 2))
        XCTAssertEqual(state.check(position: 10, duration: 3600, mode: .auto3s, isPlaying: true, elapsed: 0.5), .showIntroPill(countdown: 1))
        XCTAssertEqual(state.check(position: 10, duration: 3600, mode: .auto3s, isPlaying: true, elapsed: 0.5), .showIntroPill(countdown: 1))
        XCTAssertEqual(state.check(position: 10, duration: 3600, mode: .auto3s, isPlaying: true, elapsed: 0.5), .skipIntro(to: 90))
    }

    func testSkipAuto3sLeavingWindowCancelsCountdown() {
        var state = windowedState()
        XCTAssertEqual(state.check(position: 10, duration: 3600, mode: .auto3s, isPlaying: true, elapsed: 0.5), .showIntroPill(countdown: 3))
        // Seeking out of the window cancels; coming back restarts
        // the full 3 s countdown.
        XCTAssertEqual(state.check(position: 100, duration: 3600, mode: .auto3s, isPlaying: true, elapsed: 0.5), .none)
        XCTAssertEqual(state.check(position: 10, duration: 3600, mode: .auto3s, isPlaying: true, elapsed: 0.5), .showIntroPill(countdown: 3))
    }

    func testSkipCreditsManualShowsPillAutoAdvancesOnce() {
        var manual = windowedState()
        XCTAssertEqual(manual.check(position: 3050, duration: 3600, mode: .manual, isPlaying: true, elapsed: 0.5), .showCreditsPill)
        var auto = windowedState()
        XCTAssertEqual(auto.check(position: 3050, duration: 3600, mode: .autoNow, isPlaying: true, elapsed: 0.5), .advanceNextEpisode)
        // The advance fires once per episode.
        XCTAssertEqual(auto.check(position: 3050, duration: 3600, mode: .autoNow, isPlaying: true, elapsed: 0.5), .none)
    }

    func testSkipCreditsMarkerNearTheEndIsNotUsable() {
        var state = VodSkipIntroState()
        state.resetForEpisode(window: nil, creditsStart: 3598)
        XCTAssertEqual(state.check(position: 3599, duration: 3600, mode: .autoNow, isPlaying: true, elapsed: 0.5), .none)
    }

    func testSkipModeFromStoredFallsBackToOff() {
        XCTAssertEqual(VodSkipIntroMode.fromStored("bogus"), .off)
        XCTAssertEqual(VodSkipIntroMode.fromStored("auto3s"), .auto3s)
    }

    // MARK: - Spoiler guards

    func testSpoilerSynopsisHidden() {
        XCTAssertTrue(spoilerSynopsisHidden(hideSynopsis: true, revealed: false))
        XCTAssertFalse(spoilerSynopsisHidden(hideSynopsis: true, revealed: true))
        XCTAssertFalse(spoilerSynopsisHidden(hideSynopsis: false, revealed: false))
    }

    func testSpoilerCoverBlurredOnlyWhenUnwatched() {
        XCTAssertTrue(spoilerCoverBlurred(blurUnwatched: true, watched: false, revealed: false))
        XCTAssertFalse(spoilerCoverBlurred(blurUnwatched: true, watched: true, revealed: false))
        XCTAssertFalse(spoilerCoverBlurred(blurUnwatched: true, watched: false, revealed: true))
        XCTAssertFalse(spoilerCoverBlurred(blurUnwatched: false, watched: false, revealed: false))
    }

    // MARK: - Per-episode custom intro seconds

    func testCustomIntroSecondsRoundTrip() throws {
        let docs = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-vod-skip-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: docs) }
        // Key normalises the title ("狂飙 (2023)" -> "狂飙", "Other"
        // -> "other"): stored keys are normalised, like the writer
        // produces.
        let stored: [String: Int] = ["狂飙|第01集": 90, "other|第02集": 400]
        let url = docs.appendingPathComponent("\(VodSkipIntroDurations.collectionName).json")
        try JSONEncoder().encode(stored).write(to: url, options: [.atomic])
        XCTAssertEqual(VodSkipIntroDurations.customSeconds(title: "狂飙 (2023)", episodeName: "第01集", documentsDirectory: docs), 90)
        XCTAssertEqual(VodSkipIntroDurations.customSeconds(title: "Other", episodeName: "第02集", documentsDirectory: docs), 300)
        XCTAssertEqual(VodSkipIntroDurations.customSeconds(title: "Missing", episodeName: "第01集", documentsDirectory: docs), 0)
    }

    func testCustomIntroSecondsMissingFileReadsEmpty() {
        let docs = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-vod-skip-empty-\(UUID().uuidString)")
        XCTAssertEqual(VodSkipIntroDurations.customSeconds(title: "狂飙", episodeName: "第01集", documentsDirectory: docs), 0)
    }
}

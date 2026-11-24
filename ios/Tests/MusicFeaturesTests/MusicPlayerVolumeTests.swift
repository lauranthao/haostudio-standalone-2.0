// HAo Studio 2.0 — music player volume tests (build 36 item 2).
//
// The Now Playing volume slider drives the player's userVolume,
// which MULTIPLIES the track gain at every engine.volume write
// (NativeMusicPlayer.appliedVolume) — it never replaces the gain,
// so normalisation and the crossfade / fade-in ramps keep working
// and a drag at full slider sounds exactly like before the slider
// existed. These are pure-function tests (no engine, no audio).
//
// NOTE: like the rest of Tests/MusicFeaturesTests, this target is
// unwired until the S7 Xcode test target exists — it runs with
// `xcodebuild test` against an iOS Simulator destination, not
// `swift test` on Linux.

import XCTest
@testable import HAoStudio

final class MusicPlayerVolumeTests: XCTestCase {
    func testClampVolumeKeepsRange() {
        XCTAssertEqual(NativeMusicPlayer.clampVolume(1.0), 1.0)
        XCTAssertEqual(NativeMusicPlayer.clampVolume(0.0), 0.0)
        XCTAssertEqual(NativeMusicPlayer.clampVolume(0.5), 0.5)
        XCTAssertEqual(NativeMusicPlayer.clampVolume(1.5), 1.0)
        XCTAssertEqual(NativeMusicPlayer.clampVolume(-0.5), 0.0)
    }

    func testAppliedVolumeIsUserVolumeTimesGain() {
        // Full slider: the sound is exactly the gain (no change
        // from before the slider existed).
        XCTAssertEqual(NativeMusicPlayer.appliedVolume(userVolume: 1.0, gain: 0.8), 0.8)
        // Half slider: half the gain, not half of full volume.
        XCTAssertEqual(NativeMusicPlayer.appliedVolume(userVolume: 0.5, gain: 0.8), 0.4)
        // Muted slider: silence whatever the gain is.
        XCTAssertEqual(NativeMusicPlayer.appliedVolume(userVolume: 0.0, gain: 0.8), 0.0)
        // Normalisation gain above 1.0 is still scaled, never
        // clipped by the slider math itself (AVPlayer clamps).
        XCTAssertEqual(NativeMusicPlayer.appliedVolume(userVolume: 0.5, gain: 1.2), 0.6)
    }

    func testMusicVolumePersistenceClamps() {
        let defaults = UserDefaults(suiteName: "hao.musicVolumeTests")!
        defaults.removeObject(forKey: MusicLibraryStore.musicVolumeKey)
        // Absent key reads as the 1.0 default, not 0.0.
        XCTAssertEqual(MusicLibraryStore.musicVolume(defaults: defaults), 1.0)
        MusicLibraryStore.setMusicVolume(0.42, defaults: defaults)
        XCTAssertEqual(MusicLibraryStore.musicVolume(defaults: defaults), 0.42, accuracy: 0.001)
        MusicLibraryStore.setMusicVolume(2.0, defaults: defaults)
        XCTAssertEqual(MusicLibraryStore.musicVolume(defaults: defaults), 1.0)
        MusicLibraryStore.setMusicVolume(-1.0, defaults: defaults)
        XCTAssertEqual(MusicLibraryStore.musicVolume(defaults: defaults), 0.0)
        defaults.removeObject(forKey: MusicLibraryStore.musicVolumeKey)
    }
}

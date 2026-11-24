// HAo Studio 2.0 — music player tests (S2, leg A).
//
// SwiftPM style, same shape as S1's MigrationCoreTests: the
// coordinator adds a `MusicCore` target over `HAoStudio/Playback`
// and a `MusicPlayerTests` test target over this directory in
// `ios/Package.swift` (not edited by this leg).
//
// The player is driven through a fake engine and a fake resolver,
// never real audio: the open timeout uses a short injected
// interval, the watchdog uses an injected clock, and no test waits
// real 4 s / 12 s / 10 s.
//
// NOTE on where these run: the Playback sources import MediaPlayer,
// AVKit and AVAudioSession, which exist only on iOS. `swift test`
// on a macOS runner cannot compile this target (S1's Storage-only
// target could). Run these with `xcodebuild test` against an iOS
// simulator destination, or an equivalent iOS-capable SwiftPM run.

import Foundation
import XCTest

@testable import MusicCore

// MARK: - Fakes

/// Controllable stand-in for AVPlayerEngine. Load behaviour is a
/// queue: each load pops the next entry, so a test can say "the
/// first load never completes, the second succeeds".
final class FakeEngine: MusicPlayerEngine {
    enum LoadBehavior {
        case succeed
        case fail
        case never
    }

    var isPlaying: Bool = false
    var rate: Float = 0
    var volume: Float = 1
    var currentTimeSeconds: Double = 0
    var durationSeconds: Double = 0
    var hasItem: Bool = false
    var equalizer: MusicEqualizer?
    var onEnded: (() -> Void)?
    var onFailed: (() -> Void)?
    var onTimeUpdate: ((Double, Double) -> Void)?

    var loadBehaviors: [LoadBehavior] = [.succeed]
    var loadedURLs: [URL] = []
    var loadedIdentityKeys: [String] = []
    var playCount = 0
    var pauseCount = 0
    var unloadCount = 0
    var seekCalls: [Double] = []
    /// What the seek completion reports.
    var seekSucceeds: Bool = true
    /// Where the playhead lands after a seek (nil: the target).
    var seekLandsAt: Double?
    /// Hold seek completions until the test releases them: the
    /// playhead stays frozen while a seek is in flight, which is
    /// what a slow network seek looks like to the watchdog.
    var deferSeek = false
    private var pendingSeekCompletion: ((Bool) -> Void)?

    func load(url: URL, headers: [String: String]?, identityKey: String, completion: @escaping (Bool) -> Void) {
        loadedURLs.append(url)
        loadedIdentityKeys.append(identityKey)
        let behavior = loadBehaviors.isEmpty ? .succeed : loadBehaviors.removeFirst()
        switch behavior {
        case .succeed:
            hasItem = true
            completion(true)
        case .fail:
            hasItem = false
            completion(false)
        case .never:
            break
        }
    }

    func play() {
        playCount += 1
        isPlaying = true
    }

    func pause() {
        pauseCount += 1
        isPlaying = false
    }

    func seek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        seekCalls.append(seconds)
        if deferSeek {
            pendingSeekCompletion = { [weak self] finished in
                if finished { self?.currentTimeSeconds = self?.seekLandsAt ?? seconds }
                completion(finished)
            }
            return
        }
        currentTimeSeconds = seekLandsAt ?? seconds
        completion(seekSucceeds)
    }

    /// Release a deferred seek completion (test only).
    func completePendingSeek(_ finished: Bool) {
        let completion = pendingSeekCompletion
        pendingSeekCompletion = nil
        completion?(finished)
    }

    func unload() {
        unloadCount += 1
        hasItem = false
        isPlaying = false
    }

    func fireTimeUpdate() {
        onTimeUpdate?(currentTimeSeconds, durationSeconds)
    }

    func fireEnded() {
        onEnded?()
    }

    func fireFailed() {
        onFailed?()
    }
}

/// Stand-in for the coordinator-wired resolver. Returns the queued
/// URLs in order and records every call, including the `excluding`
/// list the player passes on a fallback.
final class FakeResolver {
    var urls: [URL?]
    var calls: [(item: PlaybackItem, excluding: [URL])] = []
    var tier: AudioQuality? = .hiRes
    private var index = 0

    init(urls: [URL?]) {
        self.urls = urls
    }

    func resolve(item: PlaybackItem, excluding: [URL], completion: @escaping (URL?, AudioQuality?) -> Void) {
        calls.append((item, excluding))
        let url = index < urls.count ? urls[index] : nil
        index += 1
        completion(url, tier)
    }
}

final class FakeSourceResolver: SourceResolver {
    var urls: [URL?]
    var calls = 0
    private var index = 0

    init(urls: [URL?]) {
        self.urls = urls
    }

    func resolveFirstPlayable(for item: PlaybackItem, targetQuality: AudioQuality?, excluding: [URL] = [], completion: @escaping (URL?) -> Void) {
        calls += 1
        let url = index < urls.count ? urls[index] : nil
        index += 1
        completion(url)
    }
}

// MARK: - Tests

final class MusicPlayerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.haostudio.music.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        if let suiteName = suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    private func item(_ id: String) -> PlaybackItem {
        return PlaybackItem(id: id, kind: .music, title: "Song \(id)", artist: "Artist")
    }

    private func makePlayer(fakes: [FakeEngine]) -> NativeMusicPlayer {
        var index = 0
        let player = NativeMusicPlayer(makeEngine: {
            let fake = fakes[index % fakes.count]
            index += 1
            return fake
        }, defaults: defaults)
        player.openTimeoutInterval = 0.05
        return player
    }

    private func wire(_ player: NativeMusicPlayer, _ resolver: FakeResolver) {
        player.resolveURL = { item, excluding, completion in
            resolver.resolve(item: item, excluding: excluding, completion: completion)
        }
    }

    // MARK: Play modes (Flutter play_mode.dart behaviour)

    func testPlayModeQueueMath() {
        // Sequential: stops at the end, stops at the start.
        XCTAssertEqual(musicNextTrackIndex(mode: .sequential, current: 0, length: 3, auto: true), 1)
        XCTAssertEqual(musicNextTrackIndex(mode: .sequential, current: 2, length: 3, auto: true), -1)
        XCTAssertEqual(musicPrevTrackIndex(mode: .sequential, current: 0, length: 3), -1)
        // List loop: wraps both ways.
        XCTAssertEqual(musicNextTrackIndex(mode: .listLoop, current: 2, length: 3, auto: true), 0)
        XCTAssertEqual(musicPrevTrackIndex(mode: .listLoop, current: 0, length: 3), 2)
        // Single loop: auto replays, manual advances.
        XCTAssertEqual(musicNextTrackIndex(mode: .singleLoop, current: 1, length: 3, auto: true), 1)
        XCTAssertEqual(musicNextTrackIndex(mode: .singleLoop, current: 1, length: 3, auto: false), 2)
        XCTAssertEqual(musicPrevTrackIndex(mode: .singleLoop, current: 0, length: 3), 2)
        // Shuffle: never returns the current track (length > 1).
        for _ in 0..<20 {
            let n = musicNextTrackIndex(mode: .shuffle, current: 1, length: 3, auto: true)
            XCTAssertNotEqual(n, 1)
            XCTAssertTrue((0..<3).contains(n))
        }
        // Single play: auto stops, manual advances, prev stops at 0.
        XCTAssertEqual(musicNextTrackIndex(mode: .single, current: 1, length: 3, auto: true), -1)
        XCTAssertEqual(musicNextTrackIndex(mode: .single, current: 1, length: 3, auto: false), 2)
        XCTAssertEqual(musicPrevTrackIndex(mode: .single, current: 0, length: 3), -1)
        // Codes round-trip (Hive `playMode`).
        XCTAssertEqual(MusicPlayMode.fromCode("loop"), .listLoop)
        XCTAssertEqual(MusicPlayMode.fromCode("one"), .singleLoop)
        XCTAssertEqual(MusicPlayMode.fromCode("once"), .single)
        XCTAssertEqual(MusicPlayMode.fromCode("shuffle"), .shuffle)
        XCTAssertEqual(MusicPlayMode.fromCode("bogus"), .sequential)
        XCTAssertEqual(MusicPlayMode.sequential.code, "seq")
        // Cycle order: seq -> loop -> one -> shuffle -> once -> seq.
        XCTAssertEqual(MusicPlayMode.sequential.next, .listLoop)
        XCTAssertEqual(MusicPlayMode.single.next, .sequential)
    }

    // MARK: Speed

    func testSpeedClampsToRange() {
        let player = makePlayer(fakes: [FakeEngine()])
        player.setSpeed(0.1)
        XCTAssertEqual(player.playbackSpeed, 0.6)
        player.setSpeed(3.0)
        XCTAssertEqual(player.playbackSpeed, 2.0)
        player.setSpeed(1.25)
        XCTAssertEqual(player.playbackSpeed, 1.25)
        XCTAssertEqual(defaults.double(forKey: "musicSpeed"), 1.25)
    }

    // MARK: Speed floor (A12)

    func testMinSpeedIsZeroPointSix() {
        // The 0.5 floor used to sit below the documented 0.6–2.0
        // range and below what the speed slider offered.
        XCTAssertEqual(NativeMusicPlayer.minSpeed, 0.6, accuracy: 0.0001)
        let player = makePlayer(fakes: [FakeEngine()])
        player.setSpeed(0.55)
        XCTAssertEqual(player.playbackSpeed, 0.6)
    }

    // MARK: Queue-only without play (A1)

    func testSetQueueOnlyDoesNotPlayOrResolve() {
        let engine = FakeEngine()
        let player = makePlayer(fakes: [engine])
        let resolver = FakeResolver(urls: [URL(string: "https://example.com/a.mp3")!])
        wire(player, resolver)
        player.setQueueOnly([item("a"), item("b")], startAt: 1)
        XCTAssertNil(player.currentTrack)
        XCTAssertEqual(resolver.calls.count, 0)
        XCTAssertEqual(engine.loadedURLs.count, 0)
        // A later play() resolves exactly once — no double resolve
        // from the earlier queue-only call.
        player.play(item: item("a"))
        XCTAssertEqual(player.currentTrack?.id, "a")
        XCTAssertEqual(resolver.calls.count, 1)
    }

    // MARK: Failed track is not a natural completion (A13)

    func testFailedTrackFlaggedAfterAdvance() {
        let engineA = FakeEngine()
        let engineB = FakeEngine()
        engineA.durationSeconds = 200
        engineA.currentTimeSeconds = 200 // outgoing "done": the
        engineB.durationSeconds = 180   // crossfade finishes at once
        let player = makePlayer(fakes: [engineA, engineB])
        // 1st resolve: a plays. 2nd: recovery finds nothing.
        // 3rd: b resolves and advances.
        let resolver = FakeResolver(urls: [
            URL(string: "https://example.com/a.mp3")!,
            nil,
            URL(string: "https://example.com/b.mp3")!,
        ])
        wire(player, resolver)
        player.setQueue([item("a"), item("b")], startAt: 0)
        XCTAssertEqual(player.currentTrack?.id, "a")
        engineA.fireFailed()
        XCTAssertEqual(player.currentTrack?.id, "b")
        XCTAssertTrue(player.didTrackFail(id: "a"))
        XCTAssertFalse(player.didTrackFail(id: "b"))
    }

    // MARK: Open success and state

    func testOpenSuccessPublishesState() {
        let engine = FakeEngine()
        engine.durationSeconds = 200
        let player = makePlayer(fakes: [engine])
        let resolver = FakeResolver(urls: [URL(string: "https://example.com/a.mp3")!])
        wire(player, resolver)
        let started = expectation(description: "track started")
        player.onTrackStarted = { _ in started.fulfill() }
        player.play(item: item("a"))
        waitForExpectations(timeout: 2)
        XCTAssertEqual(player.currentTrack?.id, "a")
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.actualQuality, .hiRes)
        XCTAssertEqual(engine.loadedURLs.count, 1)
        XCTAssertEqual(engine.loadedIdentityKeys, ["a"])
    }

    // MARK: Open timeout -> one fallback candidate (P0-04)

    func testOpenTimeoutFallsBackAndConsumesExactlyOneCandidate() {
        let engine = FakeEngine()
        engine.durationSeconds = 200
        engine.loadBehaviors = [.never, .succeed]
        let player = makePlayer(fakes: [engine])
        let url1 = URL(string: "https://example.com/a1.mp3")!
        let url2 = URL(string: "https://example.com/a2.mp3")!
        let resolver = FakeResolver(urls: [url1, url2])
        wire(player, resolver)
        let started = expectation(description: "track started on fallback")
        player.onTrackStarted = { _ in started.fulfill() }
        player.play(item: item("a"))
        waitForExpectations(timeout: 2)
        XCTAssertEqual(resolver.calls.count, 2)
        XCTAssertEqual(resolver.calls[1].excluding, [url1])
        XCTAssertEqual(engine.loadedURLs, [url1, url2])
        XCTAssertEqual(player.currentTrack?.id, "a")
        XCTAssertTrue(player.isPlaying)
    }

    func testOpenLoadFailureFallsBackOnceThenReports() {
        let engine = FakeEngine()
        engine.loadBehaviors = [.fail, .fail]
        let player = makePlayer(fakes: [engine])
        let resolver = FakeResolver(urls: [
            URL(string: "https://example.com/a1.mp3")!,
            URL(string: "https://example.com/a2.mp3")!,
        ])
        wire(player, resolver)
        let failed = expectation(description: "track failed")
        player.onTrackFailed = { _, error in
            XCTAssertEqual(error, .loadFailed)
            failed.fulfill()
        }
        player.play(item: item("a"))
        waitForExpectations(timeout: 2)
        XCTAssertEqual(resolver.calls.count, 2)
        XCTAssertEqual(engine.loadedURLs.count, 2)
        XCTAssertNil(player.currentTrack)
    }

    // MARK: Manual play failure is published (build 36, item 8, F1)

    func testManualPlayFailurePublishesFailedRequest() {
        // No resolver wired: resolveURL is nil, so the manual play
        // fails at once. The UI leg needs a published signal for
        // its toast, not just the onTrackFailed callback.
        let player = makePlayer(fakes: [FakeEngine()])
        var reported: [(PlaybackItem, MusicPlayerError)] = []
        player.onTrackFailed = { item, error in reported.append((item, error)) }
        player.play(item: item("a"))
        XCTAssertEqual(player.failedRequestCount, 1)
        XCTAssertEqual(player.lastFailedRequestId, "a")
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.1, .noPlayableURL)
        // The same song failing again surfaces again: the counter
        // (not the id) is what the UI observes.
        player.play(item: item("a"))
        XCTAssertEqual(player.failedRequestCount, 2)
        XCTAssertEqual(player.lastFailedRequestId, "a")
        XCTAssertEqual(reported.count, 2)
    }

    func testManualPlayFailureWhenResolverReturnsNothing() {
        // Resolver answers nil (no playable URL anywhere): same
        // published signal, still a manual failure.
        let player = makePlayer(fakes: [FakeEngine()])
        wire(player, FakeResolver(urls: [nil]))
        player.play(item: item("a"))
        XCTAssertEqual(player.failedRequestCount, 1)
        XCTAssertEqual(player.lastFailedRequestId, "a")
        XCTAssertNil(player.currentTrack)
    }

    // MARK: Seek rollback (P0-05)

    func testSeekFailureRollsBackAndNotifies() {
        let engine = FakeEngine()
        engine.durationSeconds = 200
        engine.currentTimeSeconds = 30
        let player = makePlayer(fakes: [engine])
        let resolver = FakeResolver(urls: [URL(string: "https://example.com/a.mp3")!])
        wire(player, resolver)
        let started = expectation(description: "started")
        player.onTrackStarted = { _ in started.fulfill() }
        player.play(item: item("a"))
        waitForExpectations(timeout: 2)
        engine.currentTimeSeconds = 30
        engine.seekSucceeds = false
        engine.seekLandsAt = 30
        let notified = expectation(description: "seek failed notification")
        var observedPosition: Double?
        let token = NotificationCenter.default.addObserver(
            forName: .haoMusicSeekFailed, object: player, queue: .main
        ) { note in
            observedPosition = note.userInfo?[MusicNotificationKeys.actualPosition] as? Double
            notified.fulfill()
        }
        let done = expectation(description: "seek completion")
        player.seek(to: 120) { ok in
            XCTAssertFalse(ok)
            done.fulfill()
        }
        waitForExpectations(timeout: 2)
        NotificationCenter.default.removeObserver(token)
        XCTAssertEqual(player.position, 30)
        XCTAssertEqual(observedPosition, 30)
    }

    func testSeekSuccessLands() {
        let engine = FakeEngine()
        engine.durationSeconds = 200
        engine.currentTimeSeconds = 30
        let player = makePlayer(fakes: [engine])
        let resolver = FakeResolver(urls: [URL(string: "https://example.com/a.mp3")!])
        wire(player, resolver)
        let started = expectation(description: "started")
        player.onTrackStarted = { _ in started.fulfill() }
        player.play(item: item("a"))
        waitForExpectations(timeout: 2)
        let done = expectation(description: "seek completion")
        player.seek(to: 120) { ok in
            XCTAssertTrue(ok)
            done.fulfill()
        }
        waitForExpectations(timeout: 2)
        XCTAssertEqual(player.position, 120)
    }

    // MARK: Expired crossfade pauses incoming (P0-07)

    func testExpiredCrossfadePausesIncoming() {
        let engineA = FakeEngine()
        let engineB = FakeEngine()
        engineA.durationSeconds = 200
        engineB.durationSeconds = 180
        let player = makePlayer(fakes: [engineA, engineB])
        let resolver = FakeResolver(urls: [
            URL(string: "https://example.com/a.mp3")!,
            URL(string: "https://example.com/b.mp3")!,
            URL(string: "https://example.com/c.mp3")!,
        ])
        wire(player, resolver)
        player.setQueue([item("a"), item("b"), item("c")], startAt: 0)
        XCTAssertEqual(player.currentTrack?.id, "a")
        XCTAssertTrue(engineA.isPlaying)
        // Track A ends: auto-advance starts a 2.5 s crossfade onto B
        // on the standby engine.
        engineA.fireEnded()
        XCTAssertEqual(engineB.loadedURLs.count, 1)
        XCTAssertTrue(engineB.isPlaying)
        // Manual next mid-crossfade: the expired crossfade must not
        // leave B sounding (ghost playback).
        player.next()
        XCTAssertEqual(player.currentTrack?.id, "c")
        XCTAssertFalse(engineB.isPlaying)
        XCTAssertGreaterThanOrEqual(engineB.pauseCount, 1)
        XCTAssertTrue(engineA.isPlaying)
    }

    func testManualNextHasNoCrossfade() {
        let engineA = FakeEngine()
        let engineB = FakeEngine()
        engineA.durationSeconds = 200
        engineB.durationSeconds = 180
        let player = makePlayer(fakes: [engineA, engineB])
        let resolver = FakeResolver(urls: [
            URL(string: "https://example.com/a.mp3")!,
            URL(string: "https://example.com/b.mp3")!,
        ])
        wire(player, resolver)
        player.setQueue([item("a"), item("b")], startAt: 0)
        player.next()
        XCTAssertEqual(player.currentTrack?.id, "b")
        XCTAssertEqual(engineB.loadedURLs.count, 0)
        XCTAssertEqual(engineA.loadedURLs.count, 2)
    }

    func testRapidManualNextLeavesOneSound() {
        let engineA = FakeEngine()
        let engineB = FakeEngine()
        engineA.durationSeconds = 200
        engineB.durationSeconds = 180
        let player = makePlayer(fakes: [engineA, engineB])
        let resolver = FakeResolver(urls: (0..<8).map { URL(string: "https://example.com/s\($0).mp3")! })
        wire(player, resolver)
        player.setQueue((0..<8).map { item("s\($0)") }, startAt: 0)
        for _ in 0..<5 { player.next() }
        XCTAssertEqual(player.currentTrack?.id, "s5")
        let sounding = [engineA.isPlaying, engineB.isPlaying].filter { $0 }.count
        XCTAssertEqual(sounding, 1)
    }

    // MARK: Watchdog 4 s / 12 s (P0-06), fake clock, no real waits

    func testWatchdogWarnsAt4sAndFailsAt12s() {
        let engine = FakeEngine()
        engine.durationSeconds = 200
        engine.currentTimeSeconds = 10
        let player = makePlayer(fakes: [engine])
        let resolver = FakeResolver(urls: [URL(string: "https://example.com/a.mp3")!])
        wire(player, resolver)
        var fakeNow = Date()
        player.watchdog.now = { fakeNow }
        let started = expectation(description: "started")
        player.onTrackStarted = { _ in started.fulfill() }
        player.play(item: item("a"))
        waitForExpectations(timeout: 2)
        XCTAssertTrue(player.isPlaying)
        let warned = expectation(description: "stall warning")
        let warnToken = NotificationCenter.default.addObserver(
            forName: .haoMusicStallWarning, object: player, queue: .main
        ) { _ in warned.fulfill() }
        // Position frozen at 10 s the whole time.
        fakeNow = fakeNow.addingTimeInterval(3.9)
        player.testTickWatchdog()
        // No warning yet at 3.9 s; warn once at 4 s.
        fakeNow = fakeNow.addingTimeInterval(0.2)
        player.testTickWatchdog()
        waitForExpectations(timeout: 2)
        // Still only a warning at 11 s; failure at 12 s.
        fakeNow = fakeNow.addingTimeInterval(6.9)
        player.testTickWatchdog()
        XCTAssertTrue(player.isPlaying)
        let failed = expectation(description: "stall failed")
        let failToken = NotificationCenter.default.addObserver(
            forName: .haoMusicStallFailed, object: player, queue: .main
        ) { _ in failed.fulfill() }
        fakeNow = fakeNow.addingTimeInterval(1.1)
        player.testTickWatchdog()
        waitForExpectations(timeout: 2)
        NotificationCenter.default.removeObserver(warnToken)
        NotificationCenter.default.removeObserver(failToken)
        XCTAssertFalse(player.isPlaying)
    }

    func testWatchdogMovementRestartsClock() {
        let engine = FakeEngine()
        engine.durationSeconds = 200
        engine.currentTimeSeconds = 10
        let player = makePlayer(fakes: [engine])
        let resolver = FakeResolver(urls: [URL(string: "https://example.com/a.mp3")!])
        wire(player, resolver)
        var fakeNow = Date()
        player.watchdog.now = { fakeNow }
        let started = expectation(description: "started")
        player.onTrackStarted = { _ in started.fulfill() }
        player.play(item: item("a"))
        waitForExpectations(timeout: 2)
        fakeNow = fakeNow.addingTimeInterval(3.9)
        engine.currentTimeSeconds = 11
        player.testTickWatchdog()
        fakeNow = fakeNow.addingTimeInterval(3.9)
        player.testTickWatchdog()
        XCTAssertTrue(player.isPlaying)
    }

    // MARK: Loudness attribution (P0-19)

    func testLoudnessAttributionUsesItemSnapshot() {
        let player = makePlayer(fakes: [FakeEngine()])
        player.setNormalizationEnabled(true)
        player.setNormalizationStrength(1)
        player.noteMeasuredLoudness("song-a", -8.0)
        player.noteMeasuredLoudness("song-b", -20.0)
        // Louder than -14: attenuated towards target, max cut 6 dB.
        let gainA = player.normalizationGain(for: item("song-a"))
        XCTAssertEqual(gainA, pow(10.0, -6.0 / 20.0), accuracy: 0.001)
        // Quieter than target: never boosted.
        XCTAssertEqual(player.normalizationGain(for: item("song-b")), 1.0)
        // Never measured: 1.0, and a report for another key does not
        // leak onto this track.
        XCTAssertEqual(player.normalizationGain(for: item("song-c")), 1.0)
    }

    func testNormalizationGainMath() {
        XCTAssertEqual(MusicNormalization.gainLinear(lufs: -14.0, strength: 1), 1.0)
        XCTAssertEqual(MusicNormalization.gainLinear(lufs: -20.0, strength: 2), 1.0)
        XCTAssertEqual(MusicNormalization.gainLinear(lufs: -8.0, strength: 0), pow(10.0, -3.0 / 20.0), accuracy: 0.001)
        XCTAssertEqual(MusicNormalization.gainLinear(lufs: -2.0, strength: 2), pow(10.0, -12.0 / 20.0), accuracy: 0.001)
        XCTAssertEqual(MusicNormalization.gainLinear(lufs: Double.nan, strength: 1), 1.0)
    }

    func testLoudnessCacheParseDropsJunk() {
        let parsed = MusicNormalization.parseLoudnessCache([
            "good": -9.5,
            "too-loud": 5.0,
            "too-quiet": -80.0,
            "": -10.0,
            "nan": Double.nan,
        ])
        XCTAssertEqual(parsed["good"], -9.5)
        XCTAssertEqual(parsed["too-loud"], 0.0)
        XCTAssertEqual(parsed["too-quiet"], -70.0)
        XCTAssertNil(parsed[""])
        XCTAssertNil(parsed["nan"])
    }

    // MARK: EQ presets (Beans values, 1:1 from Flutter build 31)

    func testEqualizerPresetGains() {
        XCTAssertEqual(EqualizerPreset.flat.gains, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(EqualizerPreset.bass.gains, [6, 5, 3, 1, 0, 0, -1, -1, 0, 0])
        XCTAssertEqual(EqualizerPreset.vocal.gains, [-2, -1, 0, 2, 4, 4, 3, 2, 0, -1])
        XCTAssertEqual(EqualizerPreset.pop.gains, [2, 2, 1, 0, 2, 3, 2, 1, 2, 2])
        XCTAssertEqual(EqualizerPreset.rock.gains, [5, 4, 2, -1, -2, 1, 3, 4, 5, 4])
        XCTAssertEqual(EqualizerPreset.classical.gains, [3, 2, 1, 0, 0, 1, 2, 3, 4, 4])
        XCTAssertEqual(EqualizerPreset.jazz.gains, [3, 2, 1, 2, -1, -1, 0, 2, 3, 3])
        XCTAssertEqual(EqualizerPreset.electronic.gains, [5, 4, 1, -2, -1, 2, 4, 3, 5, 4])
        XCTAssertEqual(EqualizerPreset.bandFrequencies, [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000])
        XCTAssertEqual(EqualizerPreset.normalizeGain(13.3), 12.0)
        XCTAssertEqual(EqualizerPreset.normalizeGain(2.26), 2.5)
        XCTAssertEqual(EqualizerPreset.fromId("bogus"), .flat)
    }

    func testBiquadFlatIsIdentity() {
        let flat = EqualizerBiquad.peaking(frequency: 1000, gainDb: 0, sampleRate: 44100)
        var filter = flat
        var last: Float = 0
        for _ in 0..<1000 {
            last = filter.process(0.5)
        }
        XCTAssertEqual(Double(last), 0.5, accuracy: 0.0001)
        // A +6 dB peaking section is not unity: its coefficients
        // differ from flat, so the curve actually does something.
        let boosted = EqualizerBiquad.peaking(frequency: 100, gainDb: 6, sampleRate: 44100)
        XCTAssertGreaterThan(boosted.b0, 1.0)
        let cut = EqualizerBiquad.peaking(frequency: 100, gainDb: -6, sampleRate: 44100)
        XCTAssertLessThan(cut.b0, 1.0)
    }

    // MARK: Same song does not restart

    func testSameSongDoesNotRestart() {
        let engine = FakeEngine()
        engine.durationSeconds = 200
        let player = makePlayer(fakes: [engine])
        let resolver = FakeResolver(urls: [URL(string: "https://example.com/a.mp3")!])
        wire(player, resolver)
        let started = expectation(description: "started")
        player.onTrackStarted = { _ in started.fulfill() }
        player.play(item: item("a"))
        waitForExpectations(timeout: 2)
        let loadsBefore = engine.loadedURLs.count
        let playsBefore = engine.playCount
        player.play(item: item("a"))
        XCTAssertEqual(engine.loadedURLs.count, loadsBefore)
        XCTAssertEqual(engine.playCount, playsBefore)
    }

    // MARK: Coordinator wiring (stop first, resolve, open, set item)

    func testCoordinatorRequestPlayAndStop() {
        let engine = FakeEngine()
        engine.durationSeconds = 200
        let player = makePlayer(fakes: [engine])
        let coordinator = PlaybackCoordinator(defaults: defaults)
        let sourceResolver = FakeSourceResolver(urls: [
            URL(string: "https://example.com/a.mp3")!,
            URL(string: "https://example.com/b.mp3")!,
        ])
        coordinator.resolver = sourceResolver
        coordinator.musicDriver = player
        // Chain onto the coordinator's onTrackStarted hook instead of
        // replacing it: the hook is what sets `currentItem`.
        var startedIds: [String] = []
        let installedStarted = player.onTrackStarted
        let startedA = expectation(description: "A started")
        var startedB: XCTestExpectation?
        player.onTrackStarted = { item in
            installedStarted?(item)
            startedIds.append(item.id)
            if item.id == "a" { startedA.fulfill() }
            if item.id == "b" { startedB?.fulfill() }
        }
        coordinator.requestPlay(item("a"))
        waitForExpectations(timeout: 2)
        drainMain()
        XCTAssertEqual(coordinator.currentItem?.id, "a")
        XCTAssertEqual(sourceResolver.calls, 1)
        // Same song while playing: no restart, no new resolution.
        coordinator.requestPlay(item("a"))
        drainMain()
        XCTAssertEqual(sourceResolver.calls, 1)
        XCTAssertEqual(engine.loadedURLs.count, 1)
        // New song: stops the old one first, then plays.
        startedB = expectation(description: "B started")
        coordinator.requestPlay(item("b"))
        waitForExpectations(timeout: 2)
        drainMain()
        XCTAssertEqual(coordinator.currentItem?.id, "b")
        XCTAssertEqual(engine.loadedURLs.count, 2)
        XCTAssertEqual(startedIds, ["a", "b"])
        coordinator.stop()
        XCTAssertNil(coordinator.currentItem)
        XCTAssertNil(player.currentTrack)
        XCTAssertFalse(player.isPlaying)
    }

    /// Let main-queue work posted by the coordinator's callbacks run.
    private func drainMain() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    func testCoordinatorRefusesWithoutResolver() {
        let engine = FakeEngine()
        let player = makePlayer(fakes: [engine])
        let coordinator = PlaybackCoordinator(defaults: defaults)
        coordinator.musicDriver = player
        coordinator.requestPlay(item("a"))
        XCTAssertNil(coordinator.currentItem)
        XCTAssertEqual(engine.loadedURLs.count, 0)
    }

    // MARK: Actual quality is the real tier, never the target

    func testActualQualityReportsRealTierNotTarget() {
        let engine = FakeEngine()
        engine.durationSeconds = 200
        let player = makePlayer(fakes: [engine])
        let resolver = FakeResolver(urls: [URL(string: "https://example.com/a.mp3")!])
        resolver.tier = .standard128
        wire(player, resolver)
        let started = expectation(description: "started")
        player.onTrackStarted = { _ in started.fulfill() }
        player.play(item: item("a"))
        waitForExpectations(timeout: 2)
        XCTAssertEqual(player.actualQuality, .standard128)
        XCTAssertNotEqual(player.actualQuality, .master)
    }
}

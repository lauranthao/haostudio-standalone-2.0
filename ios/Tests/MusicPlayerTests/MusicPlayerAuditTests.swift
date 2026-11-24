// HAo Studio 2.0 — music player audit tests (build-33 fix round).
//
// Covers this round's native-layer fixes; same harness as
// MusicPlayerTests.swift (FakeEngine / FakeResolver, injected
// clock, no real audio, no waiting real seconds).
//
// NOTE: like the rest of Tests/MusicPlayerTests, this target is
// unwired until the S7 Xcode test target exists (see Package.swift
// header) — `swift test` does not run it yet. It runs with
// `xcodebuild test` against an iOS Simulator destination.

import CoreMedia
import Foundation
import XCTest

@testable import MusicCore

final class MusicPlayerAuditTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.haostudio.music.audit.tests.\(UUID().uuidString)"
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

    private func playStarted(_ player: NativeMusicPlayer) {
        let resolver = FakeResolver(urls: [URL(string: "https://example.com/a.mp3")!])
        wire(player, resolver)
        let started = expectation(description: "started")
        player.onTrackStarted = { _ in started.fulfill() }
        player.play(item: item("a"))
        waitForExpectations(timeout: 2)
    }

    // MARK: - Seek tolerance (build-30 drag-seek stall)

    func testSeekToleranceIsLenientForNetworkExactForFiles() {
        XCTAssertEqual(
            AVPlayerEngine.seekTolerance(for: URL(fileURLWithPath: "/tmp/a.mp3")),
            .zero
        )
        XCTAssertEqual(
            AVPlayerEngine.seekTolerance(for: URL(string: "https://example.com/a.mp3")!),
            CMTime(seconds: 0.5, preferredTimescale: 600)
        )
        XCTAssertEqual(
            AVPlayerEngine.seekTolerance(for: URL(string: "http://example.com/a.mp3")!),
            CMTime(seconds: 0.5, preferredTimescale: 600)
        )
        XCTAssertEqual(
            AVPlayerEngine.seekTolerance(for: nil),
            CMTime(seconds: 0.5, preferredTimescale: 600)
        )
    }

    // MARK: - Watchdog ignores a frozen position during a seek

    func testWatchdogIgnoresFrozenPositionDuringSeek() {
        let engine = FakeEngine()
        engine.durationSeconds = 200
        engine.currentTimeSeconds = 30
        let player = makePlayer(fakes: [engine])
        var fakeNow = Date()
        player.watchdog.now = { fakeNow }
        playStarted(player)
        XCTAssertTrue(player.isPlaying)

        // Start a seek and hold its completion: the playhead stays
        // frozen at 30 s while the seek is in flight.
        engine.deferSeek = true
        var seekDone = false
        player.seek(to: 120) { ok in
            XCTAssertTrue(ok)
            seekDone = true
        }
        XCTAssertEqual(engine.seekCalls, [120])

        // 15 s of frozen position must NOT warn or fail while the
        // seek is still running (the old code failed at 12 s and
        // reopened the track at the pre-seek position).
        let failed = expectation(description: "no stall failure during seek")
        failed.isInverted = true
        let failToken = NotificationCenter.default.addObserver(
            forName: .haoMusicStallFailed, object: player, queue: .main
        ) { _ in failed.fulfill() }
        let warned = expectation(description: "no stall warning during seek")
        warned.isInverted = true
        let warnToken = NotificationCenter.default.addObserver(
            forName: .haoMusicStallWarning, object: player, queue: .main
        ) { _ in warned.fulfill() }
        fakeNow = fakeNow.addingTimeInterval(15)
        player.testTickWatchdog()
        waitForExpectations(timeout: 1)
        NotificationCenter.default.removeObserver(failToken)
        NotificationCenter.default.removeObserver(warnToken)
        XCTAssertTrue(player.isPlaying)
        XCTAssertFalse(seekDone)

        // Release the seek: it lands at the target and the
        // watchdog clock restarts from the new position.
        engine.completePendingSeek(true)
        XCTAssertTrue(seekDone)
        XCTAssertEqual(player.position, 120)
    }

    // MARK: - Now Playing artwork URL + retry schedule

    func testNowPlayingArtworkURLUpgradesHttp() {
        XCTAssertEqual(
            NativeMusicPlayer.upgradedArtworkURL(URL(string: "http://example.com/c.jpg"))?.absoluteString,
            "https://example.com/c.jpg"
        )
        XCTAssertEqual(
            NativeMusicPlayer.upgradedArtworkURL(URL(string: "https://example.com/c.jpg"))?.absoluteString,
            "https://example.com/c.jpg"
        )
        XCTAssertNil(NativeMusicPlayer.upgradedArtworkURL(nil))
    }

    func testNowPlayingArtworkRetrySchedule() {
        XCTAssertEqual(NativeMusicPlayer.nowPlayingArtworkMaxAttempts, 3)
        XCTAssertEqual(NativeMusicPlayer.nowPlayingArtworkRetryDelay(forAttempt: 1), 1.0)
        XCTAssertEqual(NativeMusicPlayer.nowPlayingArtworkRetryDelay(forAttempt: 2), 3.0)
        XCTAssertEqual(NativeMusicPlayer.nowPlayingArtworkRetryDelay(forAttempt: 3), 0)
    }
}

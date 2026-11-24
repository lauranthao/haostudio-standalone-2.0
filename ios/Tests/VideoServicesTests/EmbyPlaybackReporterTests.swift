// HAo Studio 2.0 — Emby playback reporter tests (build 36, item 13).
//
// The reporter wires EmbyClient's server-sync calls into the VOD
// lifecycle. These tests drive it against a recording mutator —
// no network — and assert the exact requests (method, path,
// PositionTicks) plus the throttle / played / session rules.
// Pure Foundation + AppCore, Swift 5.0.

import XCTest
@testable import AppCore

final class EmbyPlaybackReporterTests: XCTestCase {
    private struct RecordedCall {
        let method: String
        let url: URL
        var path: String { url.path }
        var query: [String: String] {
            guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
            var out: [String: String] = [:]
            for item in items { if let value = item.value { out[item.name] = value } }
            return out
        }
    }

    private var calls: [RecordedCall] = []
    private var fakeNow = Date(timeIntervalSince1970: 1_000_000)

    private func client(reportProgress: Bool = true) -> EmbyClient {
        let config = EmbyServerConfig(
            baseUrl: "http://emby.local:8096", apiKey: "k", userId: "u1",
            reportProgress: reportProgress)
        let mutator: EmbyMutator = { [weak self] method, url, _, _, _, completion in
            self?.calls.append(RecordedCall(method: method, url: url))
            completion(EmbyResponse(statusCode: 200, json: nil))
        }
        return EmbyClient(config: config, mutator: mutator)
    }

    private func reporter(reportProgress: Bool = true) -> EmbyPlaybackReporter {
        let made = client(reportProgress: reportProgress)
        let reporter = EmbyPlaybackReporter(clientProvider: { made })
        reporter.now = { [weak self] in self?.fakeNow ?? Date() }
        return reporter
    }

    private func playingCalls() -> [RecordedCall] {
        calls.filter { $0.path.contains("/PlayingItems/") }
    }

    private func playedCalls() -> [RecordedCall] {
        calls.filter { $0.path.contains("/PlayedItems/") }
    }

    // MARK: - Ticks + id extraction (the units the server speaks)

    func testTicksFromSeconds() {
        XCTAssertEqual(EmbyClient.ticksFromSeconds(0), 0)
        XCTAssertEqual(EmbyClient.ticksFromSeconds(90), 900_000_000)
        XCTAssertEqual(EmbyClient.ticksFromSeconds(90.5), 905_000_000)
    }

    func testEpisodeIdFromStreamUrl() {
        let url = "http://emby.local:8096/emby/Videos/abc123/stream?static=true&api_key=k&hao_dv=1"
        XCTAssertEqual(EmbyClient.episodeIdFromStreamUrl(url), "abc123")
        XCTAssertNil(EmbyClient.episodeIdFromStreamUrl("https://cms.invalid/play/1.m3u8"))
        XCTAssertNil(EmbyClient.episodeIdFromStreamUrl("https://remote.invalid/movie.mkv"))
    }

    // MARK: - Start

    func testStartReportsPositionTicks() {
        let reporter = reporter()
        reporter.noteStarted(itemId: "item1", positionSeconds: 90)
        XCTAssertEqual(playingCalls().count, 1)
        let call = playingCalls()[0]
        XCTAssertEqual(call.method, "POST")
        XCTAssertTrue(call.path.hasSuffix("/Users/u1/PlayingItems/item1"), call.path)
        XCTAssertEqual(call.query["PositionTicks"], "900000000")
        XCTAssertEqual(reporter.currentItemId, "item1")
    }

    func testStartDedupesSameItem() {
        let reporter = reporter()
        reporter.noteStarted(itemId: "item1", positionSeconds: 0)
        reporter.noteStarted(itemId: "item1", positionSeconds: 30)
        XCTAssertEqual(playingCalls().count, 1)
    }

    func testStartOfNewItemEndsOldSessionFirst() {
        let reporter = reporter()
        reporter.noteStarted(itemId: "item1", positionSeconds: 0)
        reporter.noteStarted(itemId: "item2", positionSeconds: 0)
        let stops = calls.filter { $0.method == "DELETE" && $0.path.contains("/PlayingItems/item1") }
        XCTAssertEqual(stops.count, 1)
        XCTAssertTrue(playingCalls().contains { $0.path.hasSuffix("/PlayingItems/item2") })
        XCTAssertEqual(reporter.currentItemId, "item2")
    }

    func testEmptyItemIdAndNoClientAreSilent() {
        let reporter = reporter()
        reporter.noteStarted(itemId: "", positionSeconds: 0)
        XCTAssertTrue(calls.isEmpty)
        let noClient = EmbyPlaybackReporter(clientProvider: { nil })
        noClient.noteStarted(itemId: "item1", positionSeconds: 0)
        noClient.noteProgress(positionSeconds: 10, durationSeconds: 100, isPaused: false)
        noClient.noteStopped(positionSeconds: 10)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertNil(noClient.currentItemId)
    }

    // MARK: - Progress throttle

    func testProgressThrottledToFifteenSeconds() {
        let reporter = reporter()
        reporter.noteStarted(itemId: "item1", positionSeconds: 0)
        // +5 s of wall time and playhead: no report.
        fakeNow = fakeNow.addingTimeInterval(5)
        reporter.noteProgress(positionSeconds: 5, durationSeconds: 600, isPaused: false)
        XCTAssertEqual(playingCalls().count, 1)
        // +16 s wall: one report at the new position.
        fakeNow = fakeNow.addingTimeInterval(11)
        reporter.noteProgress(positionSeconds: 16, durationSeconds: 600, isPaused: false)
        XCTAssertEqual(playingCalls().count, 2)
        XCTAssertEqual(playingCalls()[1].query["PositionTicks"], "160000000")
        // A 20 s forward jump reports immediately, inside the window.
        reporter.noteProgress(positionSeconds: 40, durationSeconds: 600, isPaused: false)
        XCTAssertEqual(playingCalls().count, 3)
        XCTAssertEqual(playingCalls()[2].query["PositionTicks"], "400000000")
    }

    func testPauseReportsImmediatelyThenStaysQuiet() {
        let reporter = reporter()
        reporter.noteStarted(itemId: "item1", positionSeconds: 0)
        fakeNow = fakeNow.addingTimeInterval(2)
        reporter.noteProgress(positionSeconds: 2, durationSeconds: 600, isPaused: true)
        XCTAssertEqual(playingCalls().count, 2)
        XCTAssertEqual(playingCalls()[1].query["IsPaused"], "true")
        // More paused ticks: no further reports.
        fakeNow = fakeNow.addingTimeInterval(30)
        reporter.noteProgress(positionSeconds: 2, durationSeconds: 600, isPaused: true)
        XCTAssertEqual(playingCalls().count, 2)
        // Resume: immediate report with IsPaused=false.
        reporter.noteProgress(positionSeconds: 2, durationSeconds: 600, isPaused: false)
        XCTAssertEqual(playingCalls().count, 3)
        XCTAssertEqual(playingCalls()[2].query["IsPaused"], "false")
    }

    // MARK: - Played + stop + end

    func testPlayedMarkedOnceAtEndMargin() {
        let reporter = reporter()
        reporter.noteStarted(itemId: "item1", positionSeconds: 0)
        reporter.noteProgress(positionSeconds: 599, durationSeconds: 600, isPaused: false)
        XCTAssertEqual(playedCalls().count, 1)
        XCTAssertEqual(playedCalls()[0].method, "POST")
        XCTAssertTrue(playedCalls()[0].path.hasSuffix("/Users/u1/PlayedItems/item1"))
        // A later tick at the same spot must not mark played twice.
        reporter.noteProgress(positionSeconds: 599.5, durationSeconds: 600, isPaused: false)
        XCTAssertEqual(playedCalls().count, 1)
    }

    func testStoppedSendsFinalProgressThenDelete() {
        let reporter = reporter()
        reporter.noteStarted(itemId: "item1", positionSeconds: 0)
        fakeNow = fakeNow.addingTimeInterval(20)
        reporter.noteStopped(positionSeconds: 120)
        // Final progress (moved 120 s since the start report) …
        XCTAssertTrue(playingCalls().contains {
            $0.method == "POST" && $0.path.contains("/Progress") && $0.query["PositionTicks"] == "1200000000"
        })
        // … then the session end.
        let stops = calls.filter { $0.method == "DELETE" && $0.path.hasSuffix("/Users/u1/PlayingItems/item1") }
        XCTAssertEqual(stops.count, 1)
        XCTAssertNil(reporter.currentItemId)
        // Later ticks are no-ops once the session cleared.
        reporter.noteProgress(positionSeconds: 130, durationSeconds: 600, isPaused: false)
        XCTAssertEqual(calls.filter { $0.method == "DELETE" }.count, 1)
    }

    func testEndedMarksPlayedAndStops() {
        let reporter = reporter()
        reporter.noteStarted(itemId: "item1", positionSeconds: 0)
        reporter.noteEnded(positionSeconds: 600)
        XCTAssertEqual(playedCalls().count, 1)
        XCTAssertEqual(calls.filter { $0.method == "DELETE" }.count, 1)
        XCTAssertNil(reporter.currentItemId)
    }

    // MARK: - Report switch off = no network at all

    func testReportSwitchOffSendsNothing() {
        let reporter = reporter(reportProgress: false)
        reporter.noteStarted(itemId: "item1", positionSeconds: 0)
        reporter.noteProgress(positionSeconds: 599, durationSeconds: 600, isPaused: false)
        reporter.noteEnded(positionSeconds: 600)
        XCTAssertTrue(calls.isEmpty)
    }
}

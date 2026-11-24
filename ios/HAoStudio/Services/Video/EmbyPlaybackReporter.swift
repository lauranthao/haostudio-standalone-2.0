// HAo Studio 2.0 — Emby playback reporter (build 36, item 13).
//
// Wires the EmbyClient server-sync calls (report start /
// progress / stopped, mark played) into the VOD playback
// lifecycle. The client methods existed since S3 but had NO
// caller anywhere — watching an Emby title left no record on
// the server at all (no watch history, no resume breakpoint),
// which is what chen reported ("Emby 看完没有浏览记录").
//
// Session shape (one reporter per VideoDriver, one session per
// episode):
// - noteStarted: after a verified open (driver
//   finishStartPlayback), once per item — an engine swap
//   (soft-decode fallback to AVPlayer) re-opens the SAME item
//   and must not re-send start. A different item ends the old
//   session first.
// - noteProgress: driver 0.5 s tick. Throttled to one report
//   per 15 s of playback (wall clock OR 15 s of forward
//   playhead, whichever comes first) + an immediate report on a
//   pause/resume change; nothing while paused after the first
//   paused report. Marks the item played once the playhead
//   reaches 1 s from the end (the same margin the player uses
//   for auto-advance), so a ViewModel auto-advance that fires
//   before the backend's natural-end event still marks played.
// - noteStopped: close / episode switch / error — a final
//   progress when the playhead moved since the last report,
//   then the server-side session end.
// - noteEnded: natural end — final progress + played + stopped.
//
// All calls are fire-and-forget (EmbyClient completions are
// swallowed): a dead server must never stall or fail playback,
// and the 数据上报 switch (`reportProgress`, default on) gates
// every call inside EmbyClient — off means no request at all.
// Positions are sent as Emby PlaybackPositionTicks (100-ns
// ticks); the conversion lives in EmbyClient.ticksFromSeconds.
//
// Item identity: the driver derives the Emby item id from the
// playback URL (`EmbyClient.episodeIdFromEmbyPlaybackUrl`) —
// only Emby direct streams and the transcode master playlist
// match, so CMS lines never report, and no source flag has
// to travel through the player. strm-direct streams (remote
// http(s) target, no Emby URL) cannot be reported this way
// and are skipped, never faked.
//
// The reporter never logs anything: the auth token rides inside
// the client, and no id, position or URL is ever printed.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

/// Reports one VOD session to the configured Emby server.
final class EmbyPlaybackReporter {
    /// Progress cadence: one report per 15 s of playback.
    static let progressIntervalSeconds: Double = 15
    /// Played when the playhead reaches this far from the end.
    static let playedEndMarginSeconds: Double = 1

    /// Injectable clock (tests drive time without sleeping).
    var now: () -> Date = { Date() }

    private let clientProvider: () -> EmbyClient?
    private var client: EmbyClient?
    private var itemId: String?
    private var lastReportedPosition: Double = 0
    private var lastReportAt: Date?
    private var lastReportedPaused: Bool?
    private var playedMarked = false

    /// Current session's item id, nil when nothing is playing.
    var currentItemId: String? { itemId }

    /// `clientProvider` builds one client per session from the
    /// stored config (default). Tests inject a client built on a
    /// recording mutator instead — no network either way.
    init(clientProvider: (() -> EmbyClient?)? = nil) {
        self.clientProvider = clientProvider ?? {
            guard let config = EmbyConfigStore.load(), config.isConfigured else { return nil }
            return EmbyClient(config: config)
        }
    }

    /// Playback of `itemId` started at `positionSeconds` (the
    /// resume position the open seeks to, 0 for a fresh start).
    /// No-op for an empty id, for a repeat start of the same
    /// item, and when no server is configured.
    func noteStarted(itemId: String, positionSeconds: Double) {
        guard !itemId.isEmpty else { return }
        if self.itemId == itemId { return }
        if self.itemId != nil {
            noteStopped(positionSeconds: lastReportedPosition)
        }
        guard let client = clientProvider() else { return }
        self.client = client
        self.itemId = itemId
        lastReportedPosition = max(0, positionSeconds)
        lastReportAt = now()
        lastReportedPaused = false
        playedMarked = false
        client.reportPlaybackStart(itemId: itemId, positionSeconds: max(0, positionSeconds)) { _ in }
    }

    /// Periodic progress from the driver's position tick.
    /// Throttled (see header); marks played at the end margin.
    func noteProgress(positionSeconds: Double, durationSeconds: Double, isPaused: Bool) {
        guard let client = client, let itemId = itemId else { return }
        let position = max(0, positionSeconds)
        if !playedMarked, durationSeconds > 0,
           position >= durationSeconds - Self.playedEndMarginSeconds {
            playedMarked = true
            client.reportPlaybackProgress(itemId: itemId, positionSeconds: position, isPaused: isPaused) { _ in }
            lastReportedPosition = position
            lastReportAt = now()
            lastReportedPaused = isPaused
            client.markPlayed(itemId: itemId) { _ in }
            return
        }
        if let lastPaused = lastReportedPaused, lastPaused == isPaused {
            // Same pause state as the last report: nothing while
            // paused; while playing, one report per 15 s (wall
            // clock or forward playhead).
            if isPaused { return }
            if let lastAt = lastReportAt,
               now().timeIntervalSince(lastAt) < Self.progressIntervalSeconds,
               position - lastReportedPosition < Self.progressIntervalSeconds {
                return
            }
        }
        client.reportPlaybackProgress(itemId: itemId, positionSeconds: position, isPaused: isPaused) { _ in }
        lastReportedPosition = position
        lastReportAt = now()
        lastReportedPaused = isPaused
    }

    /// Playback stopped (close / episode switch / error): final
    /// progress when the playhead moved since the last report,
    /// then the server-side session end. Clears the session.
    func noteStopped(positionSeconds: Double) {
        guard let client = client, let itemId = itemId else { return }
        let position = max(0, positionSeconds)
        if position - lastReportedPosition >= 1 {
            client.reportPlaybackProgress(
                itemId: itemId, positionSeconds: position,
                isPaused: lastReportedPaused ?? false) { _ in }
        }
        client.reportPlaybackStopped(itemId: itemId) { _ in }
        clearSession()
    }

    /// Natural end: final progress, played marking, session end.
    func noteEnded(positionSeconds: Double) {
        guard let client = client, let itemId = itemId else { return }
        let position = max(0, positionSeconds)
        if position - lastReportedPosition >= 1 {
            client.reportPlaybackProgress(itemId: itemId, positionSeconds: position, isPaused: false) { _ in }
        }
        if !playedMarked {
            playedMarked = true
            client.markPlayed(itemId: itemId) { _ in }
        }
        client.reportPlaybackStopped(itemId: itemId) { _ in }
        clearSession()
    }

    private func clearSession() {
        client = nil
        itemId = nil
        lastReportedPosition = 0
        lastReportAt = nil
        lastReportedPaused = nil
        playedMarked = false
    }
}

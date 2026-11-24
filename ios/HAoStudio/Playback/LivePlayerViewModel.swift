// HAo Studio 2.0 — live player view model (S4, leg A).
//
// One piece of the live room: this file owns ONLY the room page's
// UI state + the coordination between the driver, the gesture layer
// and fullscreen / brightness / volume. The gesture layer
// (VodGestures) and the danmaku layer each own their own state;
// this file never reaches into theirs, and they never reach into
// this one — they talk through the small method calls below.
//
// Mirroring follows VodPlayerViewModel: driver state is mirrored
// into @Published properties through Combine sinks, never read off
// the driver in the view body (the view reads this view model, the
// view model reads the driver).
//
// Live differences from VOD (coordinator rule 3 — enforced here,
// not in comments):
// - NO seek UI: live is real-time, so there is no scrub bar, no
//   double-tap seek and no long-press 2x. The gesture state is
//   created with `isVod = false`, which is the gate that kills
//   long-press 2x in VodGestures; double-tap seek is simply never
//   wired (there is nothing to seek to).
// - NO speed control, NO quality UI on VOD — quality is live-only
//   and this view model is where the live quality picker talks to
//   the driver (with P0-09 rollback: a failed switch keeps the old
//   quality and shows a toast).
// - Brightness / volume ONLY in the live player (chen 2026-11-20):
//   the app never changes system brightness on entering or leaving
//   a page, never restores on exit or on backgrounding, and never
//   re-applies a room brightness on foreground return. The slider
//   only ever writes while the user drags it in the player; the
//   value the user picks anywhere else (Control Center, system
//   settings, the slider itself) is left exactly as it is when
//   the room closes or the app backgrounds.
// - Fullscreen ONLY from the [ ] button (live enters portrait):
//   the rotation itself reuses S3 VOD's VideoOrientation mechanism
//   (device orientation + window-scene geometry request), which
//   rotates the WHOLE app and works with the orientation lock on.
//   Turning the phone does NOT rotate anything — there is no
//   rotation observer here on purpose.
//
// S3 honesty note: VOD never landed a brightness/volume mechanism
// in Swift (VodPlayerViewModel / VodGestures have no brightness or
// volume code at all — Flutter drove them through MethodChannels).
// This file therefore does NOT copy a mechanism that does not
// exist; it holds the state the way VodPlayerViewModel holds its
// settings state, applies brightness through UIScreen only under
// the rules above, and applies volume through the `volumeApplier`
// hook — which is nil by default, so this file NEVER touches the
// system volume on its own. The room page wires the hook
// (LiveRoomView's hidden MPVolumeView) when the room lands.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Combine
import Foundation
import SwiftUI
import UIKit

/// Live room page view model: UI state + coordination. The driver
/// owns engines, room state and recovery; this owns what the page
/// shows.
final class LivePlayerViewModel: ObservableObject {
    /// The driver this page plays through (owned by the app, passed
    /// in — this view model never creates or owns a driver).
    let driver: LiveDriver

    // Mirrored driver state (Combine sinks, set up in init).
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var currentEngine: VideoEngine?
    @Published private(set) var diagnostics: VideoPlaybackDiagnostics = .empty
    @Published private(set) var stallWarning = false
    @Published private(set) var isLoading = false
    @Published private(set) var currentRoom: PlaybackItem?
    @Published private(set) var currentLineIndex: Int = 0
    @Published private(set) var currentQuality: LiveQuality?
    @Published private(set) var isAudioOnly = false
    /// Watching count, mirrored from the session room (0 until the
    /// first room info arrives; the B leg refreshes it).
    @Published private(set) var watching: Int = 0
    /// Live status refreshed from `roomInfo` (build 35 sweep S7):
    /// nil until the first room info answers for this room — the
    /// view falls back to the card's `isLive` until then. Rooms
    /// opened from history / follows / the mini player carry
    /// stored values (`isLive: false`, count 0), so without this
    /// the LIVE badge never appears even while the room is live.
    /// Only set on a successful room info; a failed fetch leaves
    /// the card's value in place.
    @Published private(set) var roomIsLive: Bool?
    /// Danmaku messages for the room page, newest last. Fed by the
    /// B-leg transports via `appendDanmaku` (the seam); capped so a
    /// busy room cannot grow the list without bound.
    @Published private(set) var messages: [DanmakuMessage] = []
    /// Monotonic append counter (build 35 D2): `messages` is capped
    /// at 200, so its count stops changing once full and the views'
    /// `onChange(of: messages.count)` never fires again — danmaku
    /// freezes. The views observe this sequence instead and take
    /// the newest `appended` messages as a suffix. Never reset.
    @Published private(set) var danmakuSequence = 0

    /// Lines of the current resolution, from the driver (re-read on
    /// every render driven by currentQuality / currentLineIndex).
    var lines: [LiveLine] { driver.lines }
    /// Qualities the room offers, from the driver.
    var qualities: [LiveQuality] { driver.qualities }
    /// The video surface for the room page to embed. Nil until the
    /// first backend opens.
    var videoView: UIView? { driver.videoView }

    /// Append one received danmaku message (B-leg transports call
    /// this; the room page only reads `messages`). Main thread
    /// only — the batch flush below is the only caller on the
    /// transport path.
    func appendDanmaku(_ message: DanmakuMessage) {
        appendDanmakuBatch([message])
    }

    /// Append a whole batch in ONE `@Published` write (b36
    /// item 10 D-2): one zlib packet's N messages used to cost N
    /// main dispatches + N `@Published` writes. `danmakuSequence`
    /// grows by the batch size, not by 1 — the views derive the
    /// fresh suffix from the sequence delta (`suffix(appended)`),
    /// so a +1 here would make them ingest only the last message
    /// of each batch. Main thread only.
    func appendDanmakuBatch(_ batch: [DanmakuMessage]) {
        guard !batch.isEmpty else { return }
        messages.append(contentsOf: batch)
        if messages.count > 200 { messages.removeFirst(messages.count - 200) }
        danmakuSequence += batch.count
    }

    /// Batch window (b36 item 10 D-2, audit open choice B):
    /// 0.15 s — short enough that the delay is below what a
    /// viewer can perceive as danmaku lag, long enough that one
    /// zlib packet's burst (tens of messages in one tick) lands
    /// as a single main-thread flush. Only messages arriving
    /// inside the same window are merged; a steady 5/s stream
    /// (0.2 s apart) still flushes one by one, no worse than
    /// before.
    static let danmakuBatchWindowSeconds: TimeInterval = 0.15
    /// Messages received since the last flush, waiting out the
    /// batch window. Written from the transport (background)
    /// thread, drained on the main thread — guarded by
    /// `danmakuBatchLock`, never touched bare.
    private var pendingDanmaku: [DanmakuMessage] = []
    private let danmakuBatchLock = NSLock()
    /// The scheduled flush, if any; cancelled + cleared by
    /// `stopDanmaku` so no stale batch lands after a room switch
    /// or exit.
    private var danmakuFlushWork: DispatchWorkItem?
    private var danmakuFlushScheduled = false

    /// Enqueue one transport message for batched delivery (any
    /// thread — called directly from the transport's
    /// `onMessage`, no per-message main hop any more). The first
    /// message in a window schedules one flush 0.15 s out;
    /// later arrivals in the same window join that flush.
    func enqueueDanmaku(_ message: DanmakuMessage, generation: Int) {
        danmakuBatchLock.lock()
        pendingDanmaku.append(message)
        let shouldSchedule = !danmakuFlushScheduled
        if shouldSchedule { danmakuFlushScheduled = true }
        danmakuBatchLock.unlock()
        guard shouldSchedule else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.flushDanmakuBatch(generation: generation)
        }
        danmakuBatchLock.lock()
        danmakuFlushWork = work
        danmakuBatchLock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.danmakuBatchWindowSeconds, execute: work)
    }

    /// Drain the pending batch in one `@Published` write (main
    /// thread — scheduled by `enqueueDanmaku`). A flush from a
    /// superseded generation (room switched / exited while the
    /// window was open) drops its batch instead of appending to
    /// the new room's list.
    private func flushDanmakuBatch(generation: Int) {
        danmakuBatchLock.lock()
        let batch = pendingDanmaku
        pendingDanmaku = []
        danmakuFlushScheduled = false
        danmakuFlushWork = nil
        danmakuBatchLock.unlock()
        guard !batch.isEmpty, generation == danmakuGeneration else { return }
        appendDanmakuBatch(batch)
    }

    /// Receive-only danmaku transport for the current room (B leg).
    /// Started by the room page after playback begins, stopped
    /// when the room closes (or when switching rooms — start stops
    /// the old transport first). The room page never owns a
    /// transport directly: this view model owns it, so the
    /// background-queue transport callbacks can be batched into
    /// `enqueueDanmaku` and flushed to `appendDanmakuBatch` on
    /// the main queue (b36 item 10 D-2).
    private var danmakuTransport: LiveDanmakuTransport?
    /// Danmaku start generation (build 35 D1): bumped by every
    /// start/stop, so a late `roomInfo` callback from a previous
    /// room (or from after the room closed) cannot revive a
    /// transport for the wrong room.
    private var danmakuGeneration = 0
    /// Key of the room the danmaku list currently shows
    /// (build 35 sweep S1): `messages` is cleared only when this
    /// changes, so a spurious second `startDanmaku` for the room
    /// already showing never wipes the visible chat.
    private var danmakuRoomKey: String?
    /// True after `stopDanmaku` until the next start (build 35
    /// sweep S1): the room was exited in between, so a restart
    /// for the SAME room still starts from a clean list — the
    /// messages showing are from the previous visit, minutes old.
    private var danmakuWasStopped = false

    func startDanmaku(room: LiveRoom, resolver: LiveSiteResolver) {
        // Build 35 sweep S1: the list belonged to the previous
        // room until now — `messages` was never cleared on a room
        // switch, so the new room opened showing the old room's
        // chat (and the views' "count drops" reset never fired,
        // because the count only ever grew). Clear on a real room
        // change, or after an exit (`stopDanmaku` in between);
        // a bare restart for the room already showing keeps the
        // visible chat. The monotonic `danmakuSequence` is NOT
        // reset (D2 contract — the views derive the fresh suffix
        // from it, and the count-drop branch resets their lists).
        let key = "\(room.platform.rawValue)|\(room.roomId)"
        let isNewRoom = key != danmakuRoomKey
        let resumeAfterExit = danmakuWasStopped
        danmakuRoomKey = key
        stopDanmaku()
        danmakuWasStopped = false
        if isNewRoom || resumeAfterExit {
            messages = []
            roomIsLive = nil
        }
        let generation = danmakuGeneration
        if let data = room.danmakuData, !data.isEmpty {
            startTransport(with: data, resolver: resolver)
            return
        }
        // The card room usually has no transport credentials yet:
        // `roomInfo` supplies them (and a fresh watching count).
        resolver.roomInfo(roomId: room.roomId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, generation == self.danmakuGeneration else { return }
                let fullRoom: LiveRoom
                switch result {
                case .success(let info):
                    fullRoom = info
                    // S7: the room info is the fresh live status —
                    // history / follow / mini entries carry a
                    // stored `isLive: false`, so the badge would
                    // otherwise never appear while live.
                    self.roomIsLive = info.isLive
                case .failure:
                    fullRoom = room
                }
                self.watching = fullRoom.onlineCount
                guard let data = fullRoom.danmakuData, !data.isEmpty else { return }
                self.startTransport(with: data, resolver: resolver)
            }
        }
    }

    func stopDanmaku() {
        // Invalidate any in-flight roomInfo callback: a late
        // answer must not start a transport after the room closed.
        danmakuGeneration += 1
        // Build 35 sweep S1: record the stop, so the next start
        // knows the room was exited in between and clears the
        // list (a restart without an intervening stop keeps it).
        // `startDanmaku` resets this right after its own stop.
        danmakuWasStopped = true
        danmakuTransport?.stop()
        danmakuTransport = nil
        // Drop any batch still inside its 0.15 s window and
        // cancel its flush: without this a burst that arrived
        // just before the exit would land on the next room's
        // (cleared) list after `startDanmaku` ran.
        danmakuBatchLock.lock()
        pendingDanmaku = []
        danmakuFlushScheduled = false
        let flushWork = danmakuFlushWork
        danmakuFlushWork = nil
        danmakuBatchLock.unlock()
        flushWork?.cancel()
    }

    private func startTransport(with data: [String: Any], resolver: LiveSiteResolver) {
        // A start stops the old transport first (header contract):
        // without this, a fast A->B switch left both sockets alive
        // and the wrong room's danmaku kept feeding `messages`.
        danmakuTransport?.stop()
        // Build 35 sweep S1: the old transport's `onMessage`
        // forwards through a main-queue hop, so an append queued
        // before `stopDanmaku` could land AFTER the new room's
        // list was cleared. Capture this start's generation and
        // drop appends from a superseded one — the same guard D1
        // puts on the roomInfo callback, extended to the message
        // path itself.
        let generation = danmakuGeneration
        let transport = resolver.makeDanmakuTransport()
        transport.onMessage = { [weak self] message in
            // Batched (b36 item 10 D-2): no per-message main hop
            // any more — the message joins the 0.15 s window and
            // the flush appends the whole batch in one write.
            // The generation guard lives in the flush, so a
            // batch from a superseded start is dropped there.
            self?.enqueueDanmaku(message, generation: generation)
        }
        danmakuTransport = transport
        transport.start(danmakuData: data)
    }

    // Own UI state.
    /// Controls overlay visible. Auto-hides 3 s after the last
    /// interaction while playing.
    @Published private(set) var controlsVisible = true
    /// One-shot toast (line switched, quality switch failed, ...).
    /// The view clears it after showing.
    @Published private(set) var toast: String?
    /// Fullscreen (landscape) state. Only the [ ] button changes
    /// it — turning the phone never does.
    @Published private(set) var isFullscreen = false
    /// Quality picker presented (live only).
    @Published var showQualityPicker = false
    /// Line picker presented.
    @Published var showLinePicker = false

    /// Brightness level (0...1) the UI shows while dragging.
    /// The value is only ever WRITTEN to the screen from
    /// `setBrightness` while the player is active (see below).
    @Published private(set) var brightnessLevel: Double = 0.5
    /// Volume level (0...1) the UI shows while dragging. The
    /// system volume is only ever touched through `volumeApplier`
    /// (nil by default — see header).
    @Published private(set) var volumeLevel: Double = 1.0

    /// The system volume writer, wired by the room page
    /// (LiveRoomView's hidden MPVolumeView) when the room lands.
    /// Nil until then: volume drags update state only and never
    /// touch the system.
    var volumeApplier: ((Double) -> Void)?

    /// Gesture state (VodGestures owns the object; this view model
    /// holds the reference so the page wires one object).
    /// `isVod = false`: the long-press 2x gate stays shut for live.
    let gestures = VodGestureState()

    private var cancellables = Set<AnyCancellable>()
    private var autoHideWork: DispatchWorkItem?
    /// True only between `notePlayerEntry` and `disarmBrightness`:
    /// brightness writes outside that window are dropped, never
    /// applied. Nothing is ever written back on exit: the system
    /// value stays exactly as the user left it.
    private var brightnessArmed = false

    init(driver: LiveDriver) {
        self.driver = driver
        driver.$isPlaying.sink { [weak self] value in
            self?.isPlaying = value
            if value {
                self?.scheduleControlsAutoHide()
            }
        }.store(in: &cancellables)
        driver.$position.sink { [weak self] value in
            self?.position = value
        }.store(in: &cancellables)
        driver.$currentEngine.sink { [weak self] value in
            self?.currentEngine = value
        }.store(in: &cancellables)
        driver.$diagnostics.sink { [weak self] value in
            self?.diagnostics = value
        }.store(in: &cancellables)
        driver.$stallWarning.sink { [weak self] value in
            self?.stallWarning = value
        }.store(in: &cancellables)
        driver.$isLoading.sink { [weak self] value in
            self?.isLoading = value
        }.store(in: &cancellables)
        driver.$currentRoom.sink { [weak self] value in
            self?.currentRoom = value
            self?.watching = driver.session.room?.onlineCount ?? 0
        }.store(in: &cancellables)
        driver.$currentLineIndex.sink { [weak self] value in
            self?.currentLineIndex = value
        }.store(in: &cancellables)
        driver.$currentQuality.sink { [weak self] value in
            self?.currentQuality = value
        }.store(in: &cancellables)
        driver.$isAudioOnly.sink { [weak self] value in
            self?.isAudioOnly = value
        }.store(in: &cancellables)
        gestures.isVod = false
        gestures.onSingleTap = { [weak self] in
            self?.toggleControls()
        }
        // Deliberately NOT wired: onLongPressSpeedChanged (live is
        // real-time — the VodGestures gate already kills it for
        // isVod == false) and onDoubleTapSeek (live has no seek).
    }

    deinit {
        autoHideWork?.cancel()
        danmakuFlushWork?.cancel()
    }

    // MARK: - Transport

    func togglePlayPause() {
        if isPlaying {
            driver.pause()
        } else {
            driver.resume()
        }
        scheduleControlsAutoHide()
    }

    // MARK: - Controls visibility

    func toggleControls() {
        controlsVisible.toggle()
        if controlsVisible {
            scheduleControlsAutoHide()
        }
    }

    func showControls() {
        controlsVisible = true
        scheduleControlsAutoHide()
    }

    private func scheduleControlsAutoHide() {
        autoHideWork?.cancel()
        guard isPlaying else {
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isPlaying else {
                return
            }
            self.controlsVisible = false
        }
        autoHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: - Fullscreen (only the [ ] button)

    /// Enter landscape fullscreen: rotates the WHOLE app via S3
    /// VOD's VideoOrientation mechanism (works with the
    /// orientation lock on). Live enters portrait and only this
    /// call takes it landscape.
    func requestFullscreen() {
        VideoOrientation.lockLandscape()
        isFullscreen = true
        showControls()
    }

    /// Back to portrait (room dismiss also goes through here via
    /// the page's dismiss path).
    func exitFullscreen() {
        VideoOrientation.unlockPortrait()
        isFullscreen = false
        showControls()
    }

    // MARK: - Lines / quality (live only)

    /// Switch to another CDN line. The driver opens the new line;
    /// the toast names the line the room is now on — "线路 N"
    /// only (build 35 sweep S6): the line's `name` is a CDN host /
    /// CDN type (Bilibili host, Huya cdnType), and the toast used
    /// to print it, leaking CDN names the sheet never shows.
    func switchLine(to index: Int) {
        guard driver.lines.indices.contains(index) else {
            return
        }
        if driver.switchLine(to: index) {
            showLinePicker = false
            toast = "已切换到线路 \(index + 1)"
        }
    }

    /// Switch quality (live only — VOD has no quality selector).
    /// On failure the session has already rolled back to the old
    /// quality, so this only adds the toast (P0-09).
    func switchQuality(to quality: LiveQuality) {
        driver.switchQuality(to: quality) { [weak self] ok in
            guard let self = self else {
                return
            }
            if ok {
                self.showQualityPicker = false
            } else {
                self.toast = "切换失败，已回到原画质"
            }
        }
    }

    // MARK: - Brightness (player-only, never restored)

    /// Call when the room page appears: seed the slider from the
    /// system brightness as it is NOW and arm brightness writes.
    /// Nothing is written to the screen here, and nothing is
    /// remembered to write back: exit never restores.
    func notePlayerEntry() {
        brightnessLevel = Double(UIScreen.main.brightness)
        brightnessArmed = true
    }

    /// Apply a brightness level from an explicit user drag (left
    /// half vertical drag, Flutter parity). Only while the player
    /// is active: outside the entry/exit window the state still
    /// updates (so the UI never lies about the drag) but the
    /// screen is not touched.
    func setBrightness(_ level: Double) {
        let clamped = min(1, max(0, level))
        brightnessLevel = clamped
        guard brightnessArmed else {
            return
        }
        UIScreen.main.brightness = CGFloat(clamped)
    }

    /// Stop accepting brightness writes. Called on room exit AND
    /// on backgrounding. Deliberately writes NOTHING back: the
    /// system brightness stays exactly as the user left it —
    /// restoring the entry value here would overwrite a value
    /// the user picked in the player or in Control Center
    /// (chen 2026-11-20: exit never restores, never overwrites
    /// what the user set in the system).
    func disarmBrightness() {
        brightnessArmed = false
    }

    // MARK: - Volume (player-only, hook-gated)

    /// Apply a volume level from an explicit user drag (right half
    /// vertical drag, Flutter parity). The system volume is only
    /// touched when the room page has wired `volumeApplier`; until
    /// then this updates state only.
    func setVolume(_ level: Double) {
        let clamped = min(1, max(0, level))
        volumeLevel = clamped
        volumeApplier?(clamped)
    }

    // MARK: - App lifecycle (live background audio)

    /// App backgrounded: stop accepting brightness writes (the
    /// system value is left as the user left it — no restore),
    /// then let the driver drop to audio-only (live only — VOD
    /// never takes this path).
    func handleBackground() {
        disarmBrightness()
        _ = driver.enterBackground()
    }

    /// App foregrounded: restore the video track. Deliberately
    /// does NOT re-apply any brightness (see `disarmBrightness`).
    func handleForeground() {
        _ = driver.enterForeground()
    }

    func clearToast() {
        toast = nil
    }
}

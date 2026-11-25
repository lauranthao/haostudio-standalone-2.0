// HAo Studio 2.0 — sleep timer (S2-C leg).
//
// Wall-clock countdown, not per-song — ported from Flutter
// lib/services/music/sleep_timer.dart. The timer survives track
// changes because it is a plain countdown owned by the player view
// model, not by any single track. When it fires it pauses playback
// and clears itself.
//
// Completion modes never start a clock: the player view model checks
// them when a track completes and stops there instead.
// - 到歌单结束: stop when the queue ends (queue math decides).
// - 播完本首后停止: stop when the current track completes (beats
//   single-loop: the check runs before the single-loop replay).
// - 播完 N 首后停止: only natural completions count; manual next/prev,
//   taps and failed skips never count.
//
// Testability: the clock is injectable (`now` closure) and firing is
// checked explicitly via `checkFire()`; production drives it with a
// 1 s Foundation Timer. No runloop is needed to test the logic.

import Foundation

/// Sleep-timer option. The custom minutes / N target live on the
/// timer, not on the enum — the enum is only the selection.
enum SleepTimerOption: Equatable {
    case off
    case min5
    case min15
    case min30
    case min45
    case min60
    case min90
    case queueEnd
    case currentTrackEnd
    case afterNTracks
    case custom

    /// Wall-clock duration, or nil for off / queue-end / completion
    /// modes / custom (custom reads `customMinutes`).
    var duration: TimeInterval? {
        switch self {
        case .min5: return 5 * 60
        case .min15: return 15 * 60
        case .min30: return 30 * 60
        case .min45: return 45 * 60
        case .min60: return 60 * 60
        case .min90: return 90 * 60
        case .off, .queueEnd, .currentTrackEnd, .afterNTracks, .custom:
            return nil
        }
    }

    var label: String {
        switch self {
        case .off: return "关闭"
        case .min5: return "5 分钟"
        case .min15: return "15 分钟"
        case .min30: return "30 分钟"
        case .min45: return "45 分钟"
        case .min60: return "60 分钟"
        case .min90: return "90 分钟"
        case .queueEnd: return "到歌单结束"
        case .currentTrackEnd: return "播完本首后停止"
        case .afterNTracks: return "播完 N 首后停止"
        case .custom: return "自定义"
        }
    }

    /// All selectable options, in sheet order (Beans sleep ladder,
    /// custom last before off).
    static let all: [SleepTimerOption] = [
        .min5, .min15, .min30, .min45, .min60, .min90,
        .queueEnd, .currentTrackEnd, .afterNTracks, .custom, .off,
    ]
}

/// Beans `SleepTimerSheet` clamp: 1..720 minutes, bad input falls
/// back to 30. Copied exactly, including the 30 fallback.
func clampSleepCustomMinutes(_ minutes: Int?) -> Int {
    return min(720, max(1, minutes ?? 30))
}

/// Beans clamp for the "播完 N 首" count: 1..10 songs, bad input
/// falls back to 3.
func clampSleepTrackCount(_ count: Int?) -> Int {
    return min(10, max(1, count ?? 3))
}

/// "m:ss" remaining-time text.
func sleepRemainingText(_ remaining: TimeInterval) -> String {
    let total = max(0, Int(remaining))
    return "\(total / 60):\(String(format: "%02d", total % 60))"
}

/// Status line for the sleep sheet footer (S7-A). Wall-clock modes
/// show the live remaining time; completion modes show what they
/// wait for (and, for after-N-tracks, how many have finished).
/// Before S7-A the footer printed "正在倒计时：" with an empty
/// remaining time for completion modes — they have no clock.
/// `remainingText` is only read for wall-clock options. Pure
/// function (unit-tested).
func sleepStatusText(option: SleepTimerOption, remainingText: String, tracksCompleted: Int, trackTarget: Int) -> String {
    switch option {
    case .off:
        return ""
    case .queueEnd:
        return "到歌单结束时停止。"
    case .currentTrackEnd:
        return "播完本首后停止。"
    case .afterNTracks:
        return "播完 \(trackTarget) 首后停止（已播完 \(tracksCompleted) 首）。"
    case .min5, .min15, .min30, .min45, .min60, .min90, .custom:
        return "正在倒计时：\(remainingText)。到时暂停播放。"
    }
}

final class MusicSleepTimer {
    /// Called once when a wall-clock timer reaches zero. The timer
    /// has already cleared itself by then.
    var onFire: () -> Void
    /// Called on start / cancel / every tick so the UI can show the
    /// remaining time honestly.
    var onChanged: (() -> Void)?

    /// Injectable clock (production: Date(); tests: a fake clock).
    var now: () -> Date

    private(set) var option: SleepTimerOption = .off
    private(set) var customMinutes: Int = 30
    private(set) var trackTarget: Int = 3
    private(set) var tracksCompleted: Int = 0

    private var deadline: Date?
    private var ticker: Timer?
    /// Generation guard (b45-a, Coda SleepTimer): every start /
    /// cancel bumps the generation, and the 1 s ticker only fires
    /// when its captured generation is still current — a stale
    /// ticker from a replaced timer can never pause playback.
    private var generation = 0

    var isActive: Bool { option != .off }
    var isQueueEnd: Bool { option == .queueEnd }
    var isCurrentTrackEnd: Bool { option == .currentTrackEnd }
    var isAfterNTracks: Bool { option == .afterNTracks }

    /// Remaining wall-clock time, or nil when off / queue-end /
    /// completion modes (they have no clock).
    var remaining: TimeInterval? {
        guard let deadline = deadline else { return nil }
        return max(0, deadline.timeIntervalSince(now()))
    }

    var remainingText: String {
        guard let remaining = remaining else { return "" }
        return sleepRemainingText(remaining)
    }

    init(onFire: @escaping () -> Void, onChanged: (() -> Void)? = nil, now: @escaping () -> Date = { Date() }) {
        self.onFire = onFire
        self.onChanged = onChanged
        self.now = now
    }

    func startCustom(minutes: Int) {
        customMinutes = clampSleepCustomMinutes(minutes)
        start(.custom)
    }

    func startAfterNTracks(count: Int) {
        trackTarget = clampSleepTrackCount(count)
        start(.afterNTracks)
    }

    /// Change the N target. When an `afterNTracks` run is active the
    /// count restarts from zero ("改 N 从当下重计"); when no run is
    /// active the target is just remembered for the next run.
    func setTrackTarget(_ count: Int) {
        trackTarget = clampSleepTrackCount(count)
        if isAfterNTracks { tracksCompleted = 0 }
        onChanged?()
    }

    /// Record one naturally-completed track. Call ONLY from the
    /// player view model's track-completed path: manual next/prev,
    /// taps and failed skips never reach it, so they never count.
    /// Returns true when the target is reached (the caller stops
    /// playback there). No-op returning false when the mode is not
    /// `afterNTracks`.
    @discardableResult
    func noteTrackCompleted() -> Bool {
        guard isAfterNTracks else { return false }
        tracksCompleted += 1
        onChanged?()
        return tracksCompleted >= trackTarget
    }

    func start(_ option: SleepTimerOption) {
        cancel(silent: true)
        generation += 1
        let capturedGeneration = generation
        self.option = option
        let duration: TimeInterval?
        if option == .custom {
            duration = TimeInterval(customMinutes * 60)
        } else {
            duration = option.duration
        }
        if let duration = duration {
            deadline = now().addingTimeInterval(duration)
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.checkFire(generation: capturedGeneration)
            }
        }
        onChanged?()
    }

    /// Check whether the deadline passed; fire once if so. Called by
    /// the 1 s ticker in production and directly by tests with a
    /// fake clock.
    func checkFire() {
        checkFire(generation: generation)
    }

    /// Generation-checked fire: a ticker captured by an older
    /// start is a no-op once a newer start / cancel bumped the
    /// generation.
    func checkFire(generation: Int) {
        guard generation == self.generation else { return }
        guard let deadline = deadline else { return }
        if now() >= deadline {
            cancel(silent: true)
            onFire()
            return
        }
        onChanged?()
    }

    func cancel(silent: Bool = false) {
        ticker?.invalidate()
        ticker = nil
        generation += 1
        option = .off
        deadline = nil
        tracksCompleted = 0
        if !silent { onChanged?() }
    }
}

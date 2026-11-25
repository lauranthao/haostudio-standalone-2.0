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

    /// Stable code for persistence (b49fix2 P1-7). Never reorder.
    var code: Int {
        switch self {
        case .off: return 0
        case .min5: return 1
        case .min15: return 2
        case .min30: return 3
        case .min45: return 4
        case .min60: return 5
        case .min90: return 6
        case .queueEnd: return 7
        case .currentTrackEnd: return 8
        case .afterNTracks: return 9
        case .custom: return 10
        }
    }

    init?(code: Int) {
        switch code {
        case 0: self = .off
        case 1: self = .min5
        case 2: self = .min15
        case 3: self = .min30
        case 4: self = .min45
        case 5: self = .min60
        case 6: self = .min90
        case 7: self = .queueEnd
        case 8: self = .currentTrackEnd
        case 9: self = .afterNTracks
        case 10: self = .custom
        default: return nil
        }
    }
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
        persist()
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
        persist()
        onChanged?()
        return tracksCompleted >= trackTarget
    }

    // MARK: - Persistence (b49fix2 P1-7)

    /// The timer survives a relaunch: wall-clock modes store the
    /// deadline, completion modes store the option + counters.
    /// A wall-clock deadline that passed while the app was dead
    /// counts as fired (see restore()).
    private static let persistedOptionKey = "hao.sleepTimer.option"
    private static let persistedDeadlineKey = "hao.sleepTimer.deadline"
    private static let persistedCustomMinutesKey = "hao.sleepTimer.customMinutes"
    private static let persistedTrackTargetKey = "hao.sleepTimer.trackTarget"
    private static let persistedTracksCompletedKey = "hao.sleepTimer.tracksCompleted"

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(option.code, forKey: Self.persistedOptionKey)
        if let deadline = deadline {
            defaults.set(deadline.timeIntervalSince1970, forKey: Self.persistedDeadlineKey)
        } else {
            defaults.removeObject(forKey: Self.persistedDeadlineKey)
        }
        defaults.set(customMinutes, forKey: Self.persistedCustomMinutesKey)
        defaults.set(trackTarget, forKey: Self.persistedTrackTargetKey)
        defaults.set(tracksCompleted, forKey: Self.persistedTracksCompletedKey)
    }

    private func clearPersisted() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.persistedOptionKey)
        defaults.removeObject(forKey: Self.persistedDeadlineKey)
        defaults.removeObject(forKey: Self.persistedCustomMinutesKey)
        defaults.removeObject(forKey: Self.persistedTrackTargetKey)
        defaults.removeObject(forKey: Self.persistedTracksCompletedKey)
    }

    /// Restore a persisted timer, called once by the view model
    /// in init (after onFire / onChanged are wired). Returns true
    /// when a wall-clock timer fired while the app was dead — the
    /// caller must NOT auto-play on launch in that case (the user
    /// asked for silence, not a surprise resume). A still-running
    /// wall-clock timer is re-armed; completion modes resume
    /// their counters.
    @discardableResult
    func restore() -> Bool {
        let defaults = UserDefaults.standard
        guard let option = SleepTimerOption(code: defaults.integer(forKey: Self.persistedOptionKey)),
              option != .off else {
            clearPersisted()
            return false
        }
        customMinutes = clampSleepCustomMinutes(defaults.integer(forKey: Self.persistedCustomMinutesKey))
        trackTarget = clampSleepTrackCount(defaults.integer(forKey: Self.persistedTrackTargetKey))
        tracksCompleted = defaults.integer(forKey: Self.persistedTracksCompletedKey)
        let duration: TimeInterval?
        if option == .custom {
            duration = TimeInterval(customMinutes * 60)
        } else {
            duration = option.duration
        }
        if duration != nil {
            // Wall-clock mode: the deadline is the truth, not the
            // duration — a relaunch must not restart the countdown.
            let deadlineValue = defaults.double(forKey: Self.persistedDeadlineKey)
            guard deadlineValue > 0 else { clearPersisted(); return false }
            let deadline = Date(timeIntervalSince1970: deadlineValue)
            if now() >= deadline {
                clearPersisted()
                return true
            }
            self.option = option
            self.deadline = deadline
            armTicker()
            onChanged?()
            return false
        }
        // Completion mode: no clock — restore the option + counters.
        self.option = option
        self.deadline = nil
        onChanged?()
        return false
    }

    /// (Re)start the 1 s ticker for the current deadline. The
    /// generation guard is shared with start() — a stale ticker
    /// from a replaced timer can never pause playback.
    private func armTicker() {
        generation += 1
        let capturedGeneration = generation
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkFire(generation: capturedGeneration)
        }
    }

    func start(_ option: SleepTimerOption) {
        cancel(silent: true)
        self.option = option
        let duration: TimeInterval?
        if option == .custom {
            duration = TimeInterval(customMinutes * 60)
        } else {
            duration = option.duration
        }
        if let duration = duration {
            deadline = now().addingTimeInterval(duration)
            armTicker()
        }
        persist()
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
        clearPersisted()
        if !silent { onChanged?() }
    }
}

// HAo Studio 2.0 — pure gesture math (build 37 fix).
//
// Moved here from VodGestures.swift (VOD) and LiveGestures.swift
// (live) so the SwiftPM test target can see it: AppCore claims
// this file, and the Xcode app target compiles it too — one file,
// two build systems, same as HaoSidebarDragMath.swift and
// LiveRoomSession.swift. The view files keep only the SwiftUI /
// MediaPlayer wiring; everything testable lives here and imports
// Foundation only, so `swift test` on macOS can compile it.
//
// Bitrise #9 failed because LiveGesturesTests (a wired test
// target) references LiveGestureMath + VodTapDisambiguator, which
// lived in the app target only — invisible to `swift test`.
// `swiftc -parse` and the preflight cannot catch scope errors;
// only xcodebuild / `swift test` can.

import Foundation

// MARK: - Config + pure math

/// Gesture constants (Flutter `vod_features.dart` parity: double
/// tap seeks 10 s; long-press 2x engages after a short hold so a
/// normal tap never triggers it).
enum VodGestureConfig {
    /// Double-tap seeks this many seconds (left = back, right = forward).
    static let doubleTapSeekSeconds: Double = 10
    /// Long-press must be held this long before 2x engages.
    static let longPressMinimumDuration: Double = 0.5
    /// Speed while long-pressing (VOD only).
    static let longPressSpeed: Double = 2.0
    /// Horizontal third of the screen: taps in the left third seek
    /// back, right third seek forward, middle toggles controls.
    static let sideTapFraction: CGFloat = 1.0 / 3.0
    /// Single/double-tap disambiguation window (build 36, item 9):
    /// a second tap arriving within this long after the first is
    /// a double-tap; otherwise the first tap fires as a single
    /// tap when the window expires. 0.28 s is deliberately
    /// SHORTER than `longPressMinimumDuration` (0.5 s), so a
    /// double-tap — two quick presses — can never hold one press
    /// long enough to engage 2x. The cost is a ≤0.28 s delay on
    /// the single-tap controls toggle; the double-tap itself fires
    /// the instant the second tap lands (no extra delay).
    static let doubleTapWindowSeconds: Double = 0.28
}

/// Which third of the screen a double-tap landed in (build 36,
/// item 9): the sides keep their ±seek, the middle toggles
/// play/pause. The middle is the zone the old code left a no-op.
enum VodDoubleTapZone: Equatable {
    case seekBack
    case seekForward
    case togglePlayPause
}

/// Pure gesture math, so tests can drive it without a view.
/// `seekDelta` is the signed seek for a double-tap at `x` in a
/// view of `width`: left third -N s, right third +N s, middle 0
/// (middle double-tap is not a seek — it falls through to the
/// single-tap control toggle). N is the persisted double-tap step
/// (SettingsStore.doubleTapSeconds, default 10 — Flutter
/// `vodDoubleTapSeekSeconds`). `longPressSpeed` is 2.0 only when
/// the press is held AND the player is VOD; anything else is nil
/// (no speed change).
enum VodGestureMath {
    /// Which third `x` falls in. Zero / negative width has no
    /// thirds, so it reads as the middle (same as `seekDelta`
    /// returning 0 there).
    static func doubleTapZone(x: CGFloat, width: CGFloat) -> VodDoubleTapZone {
        guard width > 0 else { return .togglePlayPause }
        if x < width * VodGestureConfig.sideTapFraction {
            return .seekBack
        }
        if x > width * (1 - VodGestureConfig.sideTapFraction) {
            return .seekForward
        }
        return .togglePlayPause
    }

    static func seekDelta(x: CGFloat, width: CGFloat, seconds: Double = VodGestureConfig.doubleTapSeekSeconds) -> Double {
        switch doubleTapZone(x: x, width: width) {
        case .seekBack: return -seconds
        case .seekForward: return seconds
        case .togglePlayPause: return 0
        }
    }

    static func longPressSpeed(isPressing: Bool, isVod: Bool) -> Double? {
        guard isPressing, isVod else { return nil }
        return VodGestureConfig.longPressSpeed
    }

    // MARK: - Full-screen horizontal drag seek (build 36, item 9,
    // leg 3). VOD ONLY — live is a real-time stream and has no
    // position to drag to; the live room never calls these.

    /// One full-width sweep covers this many seconds of the
    /// episode — NOT the whole duration. Full-width = full-duration
    /// is far too twitchy on a long film (a 2 h film on an ~800 pt
    /// landscape screen would be ~9 s per point, so a 10 pt
    /// finger wobble jumps 90 s). The sweep is 1/8 of the
    /// duration, clamped to [60, 300] s: a 2 h film sweeps 5 min
    /// per full width (~0.4 s/pt), a 30 min episode 225 s, a
    /// 3 min short 60 s. Coarse jumps stay on the progress bar /
    /// double-tap; the drag is for fine scrubbing, Bilibili-style.
    static let dragSeekMinSweepSeconds: Double = 60
    static let dragSeekMaxSweepSeconds: Double = 300
    /// A drag only becomes a seek past this much movement, so an
    /// ordinary tap / hold never starts one.
    static let dragSeekActivationDistance: CGFloat = 10

    /// Sweep seconds for a `duration`: duration / 8, clamped to
    /// [60, 300]. Zero / negative duration is the minimum (the
    /// view guards duration > 0 before dragging, so this is only
    /// a never-NaN fallback).
    static func dragSeekSweepSeconds(duration: Double) -> Double {
        guard duration > 0 else { return dragSeekMinSweepSeconds }
        return min(
            dragSeekMaxSweepSeconds,
            max(dragSeekMinSweepSeconds, duration / 8))
    }

    /// Target seconds for a horizontal drag of `translationX`
    /// points in a view `width` wide, measured from the playhead
    /// `anchor` where the drag started (the playhead keeps
    /// advancing underneath while playing, so the target must not
    /// drift with it). Right = forward, left = back, clamped to
    /// [0, duration]. Zero width / duration holds the anchor
    /// (clamped), never NaN.
    static func dragSeekTarget(
        anchor: Double, translationX: CGFloat, width: CGFloat, duration: Double
    ) -> Double {
        let clampedAnchor = min(max(0, anchor), max(0, duration))
        guard width > 0, duration > 0 else { return clampedAnchor }
        let sweep = dragSeekSweepSeconds(duration: duration)
        let target = clampedAnchor + Double(translationX / width) * sweep
        return min(max(0, target), duration)
    }

    /// Whether a drag is horizontal-dominant: a mostly-vertical
    /// drag is not a seek (there is no vertical gesture on the
    /// VOD picture today, but a vertical swipe must never become
    /// a seek just because it drifted sideways).
    static func isHorizontalDrag(translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height)
    }
}

/// Single/double-tap disambiguation, pure and time-injected so
/// the harness can drive it without a view (build 36, item 9).
///
/// Why an explicit window instead of SwiftUI's
/// `TapGesture(count: 2).exclusively(before: TapGesture(count: 1))`:
/// the exclusive combo hides the same delay inside the system
/// (the single tap only fires once the double-tap fails, on the
/// system's own timeout) and the window is neither controllable
/// nor testable. This state machine makes the trade-off explicit
/// and provable: one tap → `.wait`, and the caller fires the
/// single tap when `expirePending` returns `.singleTap` after
/// `doubleTapWindowSeconds`; a second tap inside the window →
/// `.doubleTap(zone)` at once, and the pending single is dropped.
/// The view owns the timer (a DispatchWorkItem); this struct only
/// owns the decision, so a late expiry after a double-tap returns
/// `.wait`, never a stray single tap.
struct VodTapDisambiguator {
    enum Outcome: Equatable {
        case wait
        case singleTap
        case doubleTap(VodDoubleTapZone)
    }

    private var pendingTapTime: Double?

    /// Feed one tap-up at `time` (seconds, any clock, as long as
    /// the caller uses the same one for `expirePending`).
    mutating func tap(at time: Double, x: CGFloat, width: CGFloat) -> Outcome {
        if let pending = pendingTapTime,
           time - pending < VodGestureConfig.doubleTapWindowSeconds {
            pendingTapTime = nil
            return .doubleTap(VodGestureMath.doubleTapZone(x: x, width: width))
        }
        pendingTapTime = time
        return .wait
    }

    /// Called when the window expires. `.singleTap` only when a
    /// tap is still pending and the window has actually elapsed;
    /// anything else is `.wait` (no pending tap, or the window
    /// has not elapsed yet — e.g. a second tap already consumed
    /// the pending one).
    mutating func expirePending(at time: Double) -> Outcome {
        guard let pending = pendingTapTime else { return .wait }
        guard time - pending >= VodGestureConfig.doubleTapWindowSeconds else { return .wait }
        pendingTapTime = nil
        return .singleTap
    }
}

/// Which half of the picture a vertical drag controls.
enum LiveDragKind {
    case brightness
    case volume
}

/// Pure live-gesture math, so tests can drive it without a view.
enum LiveGestureMath {
    /// Full-height drag change (Pure Live player_gestures.dart:
    /// delta = -dy / height * 1.2 — up increases, down decreases).
    static let fullHeightDragLevels: Double = 1.2

    /// Brightness (left half) or volume (right half) for a drag
    /// starting at `x` in a view `width` wide. A zero-width view
    /// has no halves — brightness is the safe default.
    static func dragKind(x: CGFloat, width: CGFloat) -> LiveDragKind {
        guard width > 0 else { return .brightness }
        return x < width / 2 ? .brightness : .volume
    }

    /// Signed level change for a vertical drag of `dy` points in
    /// a view `height` tall. Up (negative dy) is positive.
    /// Zero height holds the level (never NaN).
    static func dragDelta(dy: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        return -Double(dy / height) * fullHeightDragLevels
    }

    /// Level after applying `delta` to `baseline`, clamped 0...1.
    static func dragLevel(baseline: Double, delta: Double) -> Double {
        min(1, max(0, baseline + delta))
    }

    /// SF Symbol for the drag pill, by kind + level (Pure Live
    /// gestureLevelIcon: volume <= 0 mute, < 0.5 down, else up;
    /// brightness <= 0 low, < 0.5 medium, else high).
    static func iconName(kind: LiveDragKind, level: Double) -> String {
        switch kind {
        case .volume:
            if level <= 0 { return "speaker.slash" }
            if level < 0.5 { return "speaker.wave.1" }
            return "speaker.wave.3"
        case .brightness:
            if level <= 0 { return "sun.min" }
            if level < 0.5 { return "sun.max" }
            return "sun.max.fill"
        }
    }
}

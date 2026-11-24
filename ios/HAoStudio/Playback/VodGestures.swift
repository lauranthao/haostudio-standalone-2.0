// HAo Studio 2.0 — VOD gestures (S3, leg A).
//
// One of the four independent VOD pieces (P0-08): this file owns
// ONLY the gesture layer — long-press 2x, double-tap seek, single
// tap to toggle controls. It knows nothing about the driver, the
// settings sheet or danmaku; it reports gesture events through
// callbacks and the view model acts on them.
//
// VOD ONLY (rule 3): long-press 2x speed exists on VOD because a
// VOD file can be sped up; live is real-time and cannot be sped
// up, so the long-press path is gated on `isVod` and does nothing
// for live. The same file is reused by the live room in S4 with
// `isVod: false` — the gate is the enforcement, not a comment.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation
import SwiftUI

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
    static func seekDelta(x: CGFloat, width: CGFloat, seconds: Double = VodGestureConfig.doubleTapSeekSeconds) -> Double {
        guard width > 0 else { return 0 }
        if x < width * VodGestureConfig.sideTapFraction {
            return -seconds
        }
        if x > width * (1 - VodGestureConfig.sideTapFraction) {
            return seconds
        }
        return 0
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

// MARK: - Gesture state

/// Mutable gesture state, owned by the player page (via the view
/// model). The view drives it from SwiftUI gestures; the view
/// model subscribes to the callbacks. No driver reference here.
final class VodGestureState: ObservableObject {
    /// Long-press is currently held (2x active when VOD).
    @Published private(set) var isLongPressSpeeding = false
    /// Last double-tap side, for the seek-direction flash in the UI.
    @Published private(set) var lastDoubleTapDelta: Double = 0

    /// Whether this player is VOD. Set by the page (always true in
    /// S3; the live room in S4 sets false so long-press 2x is dead
    /// there). The gate lives here, not in the view.
    var isVod: Bool = true

    /// Fired when long-press 2x engages / releases (true = 2x on).
    var onLongPressSpeedChanged: ((Bool) -> Void)?
    /// Fired on double-tap with the signed seek seconds.
    var onDoubleTapSeek: ((Double) -> Void)?
    /// Fired on a single tap (toggle controls).
    var onSingleTap: (() -> Void)?

    /// Called by the long-press gesture when the press starts.
    /// VOD only: a live player ignores the press entirely.
    func longPressBegan() {
        guard isVod, !isLongPressSpeeding else { return }
        isLongPressSpeeding = true
        onLongPressSpeedChanged?(true)
    }

    /// Called by the long-press gesture when the press ends (or is
    /// cancelled). Always restores normal speed, even if the press
    /// never engaged (no-op then).
    func longPressEnded() {
        guard isLongPressSpeeding else { return }
        isLongPressSpeeding = false
        onLongPressSpeedChanged?(false)
    }

    /// Called by the double-tap gesture at `x` in a view of
    /// `width`. Middle double-taps are not seeks.
    func doubleTapped(atX x: CGFloat, width: CGFloat) {
        let delta = VodGestureMath.seekDelta(x: x, width: width)
        guard delta != 0 else { return }
        lastDoubleTapDelta = delta
        onDoubleTapSeek?(delta)
    }

    /// Called by the single-tap gesture.
    func singleTapped() {
        onSingleTap?()
    }
}

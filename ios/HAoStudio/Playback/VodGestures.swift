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
    /// WARNING — do not wire this to SwiftUI's `pressing`
    /// callback (`.onLongPressGesture(pressing:)`): `pressing`
    /// fires true on touch-down and false the moment
    /// minimumDuration elapses, while the finger is still down.
    /// That wiring engaged 2x on every tap and dropped it 0.5 s
    /// into a real hold (build 36, item 9). The VOD view uses a
    /// LongPressGesture sequenced before a zero-distance
    /// DragGesture instead, and calls began/ended from the
    /// sequence's `.second` phase only.
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

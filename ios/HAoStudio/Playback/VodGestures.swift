// HAo Studio 2.0 — VOD gestures (S3, leg A; build 36 item 9:
// middle double-tap toggles play/pause).
//
// One of the four independent VOD pieces (P0-08): this file owns
// ONLY the gesture layer — long-press 2x, double-tap seek /
// play-pause, single tap to toggle controls. It knows nothing
// about the driver, the settings sheet or danmaku; it reports
// gesture events through callbacks and the view model acts on
// them.
//
// VOD ONLY (rule 3): long-press 2x speed exists on VOD because a
// VOD file can be sped up; live is real-time and cannot be sped
// up, so the long-press path is gated on `isVod` and does nothing
// for live. The same file is reused by the live room in S4 with
// `isVod: false` — the gate is the enforcement, not a comment.
// The middle double-tap play/pause below is gated the same way:
// live never pauses (and the live view model never wires the
// callback — the gate here is the second lock).
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
    /// Fired on a middle-third double-tap (VOD only — see
    /// `doubleTapped`). The view model wires this to its existing
    /// play/pause toggle; the state never owns playback itself.
    var onDoubleTapTogglePlayPause: (() -> Void)?
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
    /// `width`. Side thirds seek by `seconds` (the persisted
    /// step); the middle third toggles play/pause — VOD only.
    /// Live (`isVod == false`) fires nothing for a middle
    /// double-tap: a live stream cannot pause, and the live view
    /// model never wires the toggle callback either.
    func doubleTapped(atX x: CGFloat, width: CGFloat, seconds: Double = VodGestureConfig.doubleTapSeekSeconds) {
        switch VodGestureMath.doubleTapZone(x: x, width: width) {
        case .seekBack, .seekForward:
            let delta = VodGestureMath.seekDelta(x: x, width: width, seconds: seconds)
            lastDoubleTapDelta = delta
            onDoubleTapSeek?(delta)
        case .togglePlayPause:
            guard isVod else { return }
            onDoubleTapTogglePlayPause?()
        }
    }

    /// Called by the single-tap gesture.
    func singleTapped() {
        onSingleTap?()
    }
}

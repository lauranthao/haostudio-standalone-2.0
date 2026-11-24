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

// Pure gesture math moved to GestureMath.swift (AppCore) —
// build 37 fix: the SwiftPM test target cannot see the app
// target, so LiveGesturesTests needs these types in AppCore.

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

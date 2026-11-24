// HAo Studio 2.0 — live-room picture gestures (build 37, L3).
//
// Pure Live parity (player_gestures.dart / room_layout.dart):
// vertical drag on the live picture — left half brightness,
// right half volume; one full-height drag = 1.2 levels. A
// centred pill shows the kind + level and hides 1 s after the
// last update. Double-tap anywhere on the picture toggles
// fullscreen. Horizontal drag does nothing: live is real-time
// and has no position to seek — no 2x, no scrub, ever. The
// brightness restore Pure Live does on page dispose is
// deliberately NOT copied: chen 2026-11-20 — exit never
// restores or overwrites the system brightness.
//
// Pure math lives in LiveGestureMath (testable without a view,
// same as VodGestureMath); the view owns the gesture wiring.
// The hidden MPVolumeView below is the volume writer: the
// system volume has no public setter, so the drag writes
// through the slider of a 1x1 offscreen MPVolumeView (Pure
// Live PlayerDeviceControls technique) — no volume HUD, no
// visible slider.

import MediaPlayer
import SwiftUI
import UIKit

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

/// Hidden system-volume driver: a 1x1 MPVolumeView placed
/// offscreen. Its UISlider changes the system volume without
/// showing the iOS volume HUD and without a visible slider in
/// the room. `showsVolumeSlider` stays true — the slider
/// subview is only created when the slider is shown — the view
/// itself is offscreen, so nothing is ever visible.
/// The slider is created lazily at layout; if it is not there
/// yet, layout is forced once and searched again.
struct HiddenMPVolumeView: UIViewRepresentable {
    /// Called once with the slider the first time it is found.
    var onSlider: (UISlider) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var reportedSlider: UISlider?
    }

    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView()
        volumeView.showsRouteButton = false
        volumeView.showsVolumeSlider = true
        return volumeView
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        var slider = uiView.subviews.compactMap { $0 as? UISlider }.first
        if slider == nil {
            uiView.setNeedsLayout()
            uiView.layoutIfNeeded()
            slider = uiView.subviews.compactMap { $0 as? UISlider }.first
        }
        guard let slider, context.coordinator.reportedSlider !== slider else { return }
        context.coordinator.reportedSlider = slider
        onSlider(slider)
    }
}

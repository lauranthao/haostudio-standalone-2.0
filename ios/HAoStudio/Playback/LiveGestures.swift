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

// Pure gesture math moved to GestureMath.swift (AppCore) —
// see the note in VodGestures.swift.

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

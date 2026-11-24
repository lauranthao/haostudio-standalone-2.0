// HAo Studio 2.0 — immersive-page bottom-chrome state.
//
// The app shell's bottom chrome (mini player + glass tab bar) lives
// in MainTabView's bottom safe-area inset, so it stays on screen for
// every page pushed inside a tab — including the live room, whose
// own bottom control bar then lands underneath it (chen 2026-11-24:
// Kuaishou room screenshot, play + fullscreen buttons half hidden
// behind the tab bar). There is no system tab bar here, so no
// hide-on-push modifier exists; the room reports its own
// presentation instead and MainTabView hides the chrome while it
// is up, then shows it again on exit. The glass itself is untouched
// — hidden, never restyled — and tab pages keep the chrome as before.
//
// Presentation state, NOT playback state: a room whose stream never
// starts (no picture yet) still needs the chrome hidden, and the
// coordinator's current item stays nil until the driver reports a
// start — so this flag must never be derived from currentItem.
// A plain Bool: appear / disappear set it directly, so a repeated
// appear can never wedge the chrome hidden.

import SwiftUI

/// Whether an immersive page is currently on screen.
@MainActor
final class ImmersiveChromeState: ObservableObject {
    /// True while a live room (or any other immersive page) is
    /// presented. MainTabView hides the bottom chrome while true.
    @Published private(set) var isImmersive = false

    /// An immersive page appeared.
    func enterImmersive() {
        isImmersive = true
    }

    /// The immersive page disappeared; the chrome comes back.
    func exitImmersive() {
        isImmersive = false
    }
}

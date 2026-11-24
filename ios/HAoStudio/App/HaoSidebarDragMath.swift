// HAo Studio 2.0 — sidebar drag math (build 36, item 19).
//
// Pure functions for the browse-page sidebar drag (chen 2026-11-24:
// Emby-style sidebar under the poster wall, follow-finger +
// spring). Foundation-only (Double, no SwiftUI) so it lives in
// AppCore and is covered by `swift test` like the other pure
// rules in this target. The SwiftUI side converts CGFloat <-> Double
// at the boundary; no logic lives in the view.

import Foundation

/// Pure drag math for the browse-page sidebar (item 19).
/// All lengths in points, all velocities in points/second.
enum HaoSidebarDragMath {
    /// A touch that moved no more than this is a tap, not a drag.
    /// The card's Button still fires: a drag past this distance
    /// cancels the button tap by the system's own tap slop, so the
    /// sidebar drag never swallows a tap-to-detail.
    static let tapMaxDistance: Double = 10
    /// A flick faster than this opens / closes regardless of
    /// position (Apple's swipe-to-dismiss rule of thumb).
    static let velocityThreshold: Double = 500
    /// Without a flick, release past this fraction of the sidebar
    /// width opens; before it, springs closed.
    static let openFraction: Double = 0.5
    /// Rubber-band resistance past the bounds (iOS standard ~0.3:
    /// the panel follows the finger but lags past the end).
    static let rubberBandFactor: Double = 0.3
    /// Sidebar width cap (iOS sidebar on iPhone is ~280pt).
    static let maxSidebarWidth: Double = 280

    /// Sidebar width for a screen width: 280pt, never more than
    /// 85% of the screen.
    static func sidebarWidth(screenWidth: Double) -> Double {
        min(maxSidebarWidth, screenWidth * 0.85)
    }

    /// True when the total finger movement is a tap, not a drag.
    static func isTap(totalMovement: Double) -> Bool {
        totalMovement <= tapMaxDistance
    }

    /// Settle target after release: open (true) or closed (false).
    /// A fast flick wins over position; otherwise the half-width
    /// line decides. No state is kept here — the caller owns
    /// isOpen and animates to the returned side.
    static func shouldOpen(currentOffset: Double, velocity: Double, width: Double) -> Bool {
        if velocity > velocityThreshold { return true }
        if velocity < -velocityThreshold { return false }
        return currentOffset >= width * openFraction
    }

    /// Finger-following offset with rubber-banding past the ends:
    /// inside [min, max] the finger is followed 1:1; past either
    /// end the panel lags (excess * 0.3), so it can never be
    /// dragged off-screen or left stuck past the bounds.
    static func clampedOffset(raw: Double, min: Double, max: Double) -> Double {
        if raw < min { return min + (raw - min) * rubberBandFactor }
        if raw > max { return max + (raw - max) * rubberBandFactor }
        return raw
    }

    /// Open progress 0...1 for the dim / corner radius / shadow.
    static func progress(offset: Double, width: Double) -> Double {
        guard width > 0 else { return 0 }
        return min(max(offset / width, 0), 1)
    }
}

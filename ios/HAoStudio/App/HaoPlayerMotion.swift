// HAo Studio 2.0 — player motion values.
//
// Split out of Glass.swift in b49phase1 P6. Pure move —
// no symbol renamed, no value changed.

import SwiftUI

/// Player motion values (b45-a, copy plan §8.1/§8.3). Animation /
/// token helpers ONLY — no HaoLayout chrome geometry is touched
/// here (tabBarTotalHeight, floatingStackSpacing, miniPlayerHeight
/// etc. belong to package E). Coda's CoverZoomMotion springs plus
/// the lyrics-follow spring, so the player and the lyrics share
/// one set of numbers instead of each inventing its own.
///
/// b49phase1 P2 — the animation split: this enum owns PLAYER-
/// specific motion only. General UI motion (quick / standard /
/// smooth / spring / bouncy / snappy / stagger) lives in
/// HaoDesignTokens (HaoTheme.swift). No value moved in either
/// system; `settleSpring` stays in HaoLayout (chrome transitions:
/// full-player fade, sidebar, rows).
enum HaoPlayerMotion {
    /// Player open spring (CoverZoomMotion.open).
    static let playerOpen = Animation.spring(response: 0.5, dampingFraction: 0.94)
    /// Player close spring (CoverZoomMotion.close).
    static let playerClose = Animation.spring(response: 0.42, dampingFraction: 1.0)
    /// Spring back after a cancelled close drag.
    static let playerSpringBack = Animation.spring(response: 0.38, dampingFraction: 0.86)
    /// Lyrics auto-scroll to the current line (Panels.swift).
    static let lyricsFollow = Animation.spring(response: 0.7, dampingFraction: 0.85)
    /// Control-layer fade in/out (portraitInterfaceAnimation).
    static let controlFade = Animation.easeInOut(duration: 0.34)
    /// Cover play bounce-back: after the 1.055 easeOut overshoot,
    /// Coda's spring(0.42, bounce 0.24) — dampingFraction 0.76.
    static let coverBounceBack = Animation.spring(response: 0.42, dampingFraction: 0.76)
    /// Icon-button press: scale 0.9 + opacity 0.7, easeOut 0.10
    /// on press / 0.24 on release (ButtonStyles.swift).
    static func pressAnimation(isPressed: Bool) -> Animation {
        .easeOut(duration: isPressed ? 0.10 : 0.24)
    }
}

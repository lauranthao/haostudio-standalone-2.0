// HAo Studio 2.0 — floating-chrome geometry + visual-alignment tokens.
//
// Split out of Glass.swift in b49phase1 P6: the glass
// modifiers stay there; this file owns only the shared
// dimensions (HaoLayout). Pure move — no symbol renamed,
// no value changed.

import SwiftUI

/// Shared dimensions for the floating bottom stack (tab bar, and the
/// mini player that sits above it). Content bottom insets are derived
/// from these in one place so the bar and the mini player can never
/// overlap each other or the content.
enum HaoLayout {
    /// Glass tab bar content height (56, Coda §6.2: the bar's
    /// content is 56pt with a 4pt inset top and bottom, so the
    /// laid-out total is 64).
    static let tabBarContentHeight: CGFloat = 56
    /// Total height of the glass tab bar as laid out in the
    /// floating stack: 64pt (b46-chrome, Coda §6.2 whole set —
    /// 64/52/8/6, chen 2026-11-25 14:36 ordered the Coda menu +
    /// mini sizes). The b43 set was 56/13/40, device-verified on
    /// build 43 — it is the rollback if this set fails the device
    /// check. b47: the visible pill is the SwiftUI glass
    /// (haoGlassRoundedRect, same as the mini) — the system
    /// UITabBar underneath is transparent, so there is no system
    /// glass overhang any more and the visual gap to the mini is
    /// exactly the 8pt frame spacing: two separate pills, as in
    /// Coda's screenshot — not the one touching block b43 made
    /// (there the 13pt frame gap was a glass compensation: the
    /// bar's system glass top sat ~13pt above a 56pt frame, and
    /// the gap put the mini's glass bottom back on it; with a
    /// 64pt frame the overhang was ~4pt, so the compensation must
    /// not survive — the whole set replaces it).
    static let tabBarTotalHeight: CGFloat = tabBarContentHeight + 8
    /// Distance from the safe-area bottom edge: 6 (b46-chrome,
    /// Coda §6.2 — the bottom margin is 6, inside the safe area).
    /// The bar sits 6pt above the safe-area boundary — fully
    /// inside the hit-testable safe area, never dropped below it
    /// (b39: the b38 chromeBottomOffset drop pushed the bar 26pt
    /// below the safe-area edge on Face ID iPhones and taps fell
    /// through). The gap to the screen edge is the home-indicator
    /// zone itself.
    static let tabBarBottomMargin: CGFloat = 6
    /// Horizontal margin of the floating chrome (b49fix2 A28:
    /// Coda §6.2 reads 12 from Coda's source — the b46 brief
    /// value was 16 from the screenshot, one constant to revert
    /// if the device check says the chrome reads too narrow
    /// next to Coda).
    static let tabBarHorizontalMargin: CGFloat = 12
    /// Mini player strip height: 52 (b46-chrome, Coda §6.2/§2.10:
    /// cover 40 + 2 x 6pt vertical padding; the transport buttons'
    /// 36pt hit targets sit inside it). The b43 40pt strip (chen
    /// 2026-11-24 "mini 播放器做短一点", 44 -> 40) is the rollback
    /// with the 56/13 set if the Coda geometry fails the device
    /// check. 52 is the floor with the Coda controls: the 40 cover
    /// + 6pt padding each side, and the 36pt buttons.
    static let miniPlayerHeight: CGFloat = 52
    /// Corner radius of the floating chrome (mini player + tab bar):
    /// a rounded rectangle, NOT a capsule. chen's Apple Music
    /// reference (2026-11-24 build 34): the mini and the bar share
    /// one shape, one width, stacked with an 8pt gap. 26pt (b46-chrome,
    /// Coda §6.2: the mini is a capsule — 26 is half the 52pt strip,
    /// the capsule-equivalent radius): the iOS 26 reference measures
    /// the mini and the floating tab bar at ~20–28pt — near half the
    /// strip height, almost a capsule — so 12 read square next to
    /// the system bar, whose radius is Apple's own (~20–30pt). One
    /// constant: if the two still read as different shapes on device,
    /// this is the single place to adjust — never a second hand-written
    /// number in the mini. True-device confirmation still pending
    /// (chen's phone is the judge: "看着像同一套").
    static let floatingChromeCornerRadius: CGFloat = 26
    /// Horizontal content padding inside the mini player strip,
    /// symmetric both sides (was 10 leading / 6 trailing — the
    /// strip read lopsided). Same 12pt step as Coda's mini side
    /// padding (§6.2), so the cover's left edge and the buttons'
    /// right edge sit on the same rhythm as the bar.
    static let miniPlayerContentPadding: CGFloat = 12
    /// Gap between the mini player strip and the tab bar: 8
    /// (b46-chrome, Coda §6.2). The two are separate floating
    /// pills with an 8pt frame gap between them — NOT one touching
    /// block (b43's look, where a 13pt glass compensation made the
    /// glasses touch). The 13pt compensation is deleted with this
    /// set: it was a patch for the 56pt frame's ~13pt glass
    /// overhang, and Coda's 64/52/6/12 set is self-consistent
    /// without it. If the device check shows overlap or a gap
    /// that reads wrong, the rollback is the whole b43 set
    /// (56/13/40), never a single-number tweak.
    static let floatingStackSpacing: CGFloat = 8
    /// Name of the coordinate space a tab root's scroll view publishes
    /// for the chrome scroll anchor (HaoChromeScrollAnchor): the
    /// anchor reports its top offset in this space, 0 at the top,
    /// negative while the content is scrolled down.
    static let chromeScrollSpace = "haoChromeScroll"
    /// Cover size in the mini player (b46-chrome, Coda §2.10:
    /// 40x40 r6 — up from 32 for the 40pt strip, so the 52pt strip
    /// keeps Coda's 6pt vertical padding).
    static let miniCoverSize: CGFloat = 40
    /// matchedGeometryEffect id shared by the mini cover and the full
    /// player cover: tapping the mini morphs this one cover from 40
    /// to the full player's cover (up to 340).
    static let playerCoverMorphID = "haoPlayerCover"
    /// Breathing room between the floating stack and the scroll
    /// content (b46-chrome, Coda §6.2 extraPadding 12 — counted in
    /// the content clearance only, never in the chrome's own height):
    /// the last row stops 12pt above the chrome instead of touching it.
    static let contentBreathingRoom: CGFloat = 12
    /// Height of the floating stack above the safe-area bottom edge,
    /// plus the breathing room: bottom margin + tab bar + (gap +
    /// mini player while one is showing) + 12. This is the clearance
    /// a scroll page under the stack must add so its last row can
    /// scroll fully above the stack — 82pt idle, 142pt while playing
    /// (Coda §6.2: 64+6+12 / 52+8+64+6+12).
    /// The stack is never dropped below the safe-area edge, so the
    /// clearance is the full stack height — nothing is subtracted.
    /// See haoBottomChromePadding(). (Build 37: the scroll-minimize
    /// behaviour is gone — chen 2026-11-24 had the menu restored
    /// to its original full tab bar, so there is no minimized form
    /// and no isMinimized parameter any more.)
    static func floatingStackClearance(miniPlayerVisible: Bool) -> CGFloat {
        return tabBarBottomMargin + tabBarTotalHeight
            + (miniPlayerVisible ? floatingStackSpacing + miniPlayerHeight : 0)
            + contentBreathingRoom
    }
    /// Settle spring for chrome transitions (full-player fade,
    /// sidebar, rows).
    static let settleSpring = Animation.spring(response: 0.35, dampingFraction: 0.82)

    // MARK: - Visual-alignment tokens (sweep 5, b49fix3)
    //
    // One place for the page geometry every tab root and pushed
    // page shares (sweep-5 Lens 3 found 24 / 20 / 16 margins,
    // 48 / 40 / 36 search heights, 12 / 16 / 32 section tops).
    // HaoDesignTokens (HaoTheme.swift) keeps only animation +
    // heartRed now (b49fix4 P2-28 deleted its spacing/corner
    // members); the values below are the single source of truth
    // for geometry — do not add a second value for the same role.
    // Font roles live in HaoTheme.swift (.haoScreenTitle etc.)
    // and are NOT repeated here.
    /// Tab-root horizontal margin (all five roots).
    static let pageMargin: CGFloat = 24
    /// Pushed-page horizontal margin (detail / list pages).
    static let pushedPageMargin: CGFloat = 20
    /// Page-top search-field height.
    static let searchFieldHeight: CGFloat = 48
    /// In-detail capsule search height (playlist detail, recent plays).
    static let detailSearchHeight: CGFloat = 44
    /// Default top spacing of a section under the previous one.
    static let sectionTopSpacing: CGFloat = 16
    /// Top spacing of a true discovery section only.
    static let discoverySectionTopSpacing: CGFloat = 32
    /// Tab-bar icon size (Coda §6.2: 23pt semibold).
    static let tabIconSize: CGFloat = 23
    /// Standard icon-button glyph size (mini player, live room, player).
    static let iconSize: CGFloat = 20
    /// Corner-radius scale (sweep 5 P2-42): 8 / 12 / 16 / 20 / 22,
    /// for cards and sheets. Rectangular selection cells are NOT
    /// on this scale — they use selectionCellCornerRadius (10,
    /// sweep 5 P2-41); small chips use chipCornerRadius (10,
    /// sweep 7 P2-38) — same VALUE as the selection cell, a
    /// different ROLE, so the two tokens must never be swapped;
    /// pill chips stay Capsule.
    /// b49fix4 P2-27: every literal `cornerRadius:` in the repo is
    /// either wired to a token above or deliberately literal —
    /// a purpose-named token must not be used for unrelated UI:
    /// 0 square posters; 1/2/3/5 hairline dots and dividers; 4
    /// chips and badges; 6 small covers (48pt song-row,
    /// 40pt mini) + the 28pt settings swatch; 10 non-selection
    /// (toasts, covers, skeletons, badges, clips); 18 geometric,
    /// always half of 36 (tab pill, 36pt avatar); 24 equalizer
    /// cards only; 36/40/64 circles, always half of the size.
    /// A 24pt avatar's r12 is likewise half-of-size, not a scale step
    /// (sweep 7 P2-39). The one off-scale wiring is deliberate:
    /// 14 -> cornerMedium (nearest below, so compact cards do
    /// not grow); 18 is geometric only — there is no 18pt
    /// surface card any more, do not wire one to 18.
    /// b49phase1 P4 audit (2026-11-26): all 41 numeric literals
    /// verified one by one against this list — every one maps to
    /// a documented category; the single r12 is the 24pt avatar
    /// (half-of-size, NOT cornerMedium); the six r24 are all
    /// equalizer cards (MusicEqualizerView).
    static let cornerSmall: CGFloat = 8
    static let cornerMedium: CGFloat = 12
    static let cornerLarge: CGFloat = 16
    static let cornerXLarge: CGFloat = 20
    static let cornerXXLarge: CGFloat = 22
    /// Rectangular selection-cell corner radius (quality / line /
    /// episode grids, sweep 5 P2-41).
    static let selectionCellCornerRadius: CGFloat = 10
    /// Small-chip corner radius (sweep 7 P2-38): 10 — the same
    /// value as selectionCellCornerRadius, a different role
    /// (mini bar, live cards, discovery cards, small covers).
    /// Never use selectionCellCornerRadius for a chip.
    static let chipCornerRadius: CGFloat = 10
    /// Player content horizontal margin (music player already 24;
    /// video player 20 -> 24, sweep 5 P2-44).
    static let playerHorizontalMargin: CGFloat = 24
    /// Toast bottom offset above the safe area (sweep 5 P2-37:
    /// music 90, live room 96 -> 90).
    static let toastBottomOffset: CGFloat = 90
    /// Sheet horizontal padding.
    static let sheetHorizontalPadding: CGFloat = 24
    /// Sheet top padding.
    static let sheetTopPadding: CGFloat = 16
    /// Sheet content main-stack spacing (b49-sweep13 alignment
    /// P2-1): the root VStack of sheet content — ImportPreview /
    /// UpdateStatus / UpdatePrompt sheets used 22, DisclaimerView
    /// used 18, same role, both unregistered. Unified on 22 (the
    /// majority value); all four sheet root stacks wire here.
    static let sheetStackSpacing: CGFloat = 22

    // Retry-button variants (sweep 7 P2-24 / P2-27, sweep 8
    // P2-16): deliberate exceptions to the standard retry
    // capsule (15 semibold, 24/12, filled accent):
    // - Soft capsule (MusicCapsuleButton): 13 semibold,
    //   accentSoft fill, 12/7, top 6 — the EMPTY-STATE /
    //   secondary variant (MusicEmptyState, VideoTabView CMS
    //   empty state, HomeView homeEmptyCTA). A full standard
    //   capsule is too heavy inside an empty state.
    // - White capsule on video (LiveRoomView failure card):
    //   16 semibold, white fill, 20/8 — readable on a video
    //   frame, where the accent fill would vanish.
    // - Secondary-action capsule (EmbyTabView "重新登录"):
    //   15 semibold, 24/12, surface fill + hairline border —
    //   a SECONDARY action, not a retry, so it does not take
    //   the accent fill; the fill is what marks it secondary.
    // Anything else showing a "重试" uses the standard capsule.
}

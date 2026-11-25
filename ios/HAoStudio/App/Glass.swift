// HAo Studio 2.0 — shared glass + floating-layout constants.
//
// Native liquid glass: iOS 26+ uses `.glassEffect`; iOS 17–25 falls back
// to the regular frosted-glass material (`.ultraThinMaterial` / UIBlurEffect
// equivalent). The fallback is a real material, not a solid colour, so the
// app still reads as frosted glass on older systems.
//
// Sizing / spring values (spring response 0.35, dampingFraction 0.82;
// stroke white 0.22 light / 0.08 dark, 0.5pt; shadow black 0.10 / 0.28,
// radius 12, y 4; bottomMargin 6; content height 56 + 4pt inset).

import SwiftUI
import UIKit

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
}

/// Player motion values (b45-a, copy plan §8.1/§8.3). Animation /
/// token helpers ONLY — no HaoLayout chrome geometry is touched
/// here (tabBarTotalHeight, floatingStackSpacing, miniPlayerHeight
/// etc. belong to package E). Coda's CoverZoomMotion springs plus
/// the lyrics-follow spring, so the player and the lyrics share
/// one set of numbers instead of each inventing its own.
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

/// Scroll-offset tracking for the bottom chrome — build 37: the
/// b35 scroll-driven minimize is REVERTED (chen 2026-11-24:
/// "菜单恢复原样"), the menu stays the original full glass tab bar
/// and never narrows into a capsule. What remains is the anchor
/// offset bookkeeping the reselect scroll-to-top (chrome O1) needs:
/// the tab's rest offset and whether the visible tab is at its top.
/// - The rest offset is learned from the first anchor report after
///   a reset (b36-1: every tab uses a large navigation title, so
///   the anchor rests ~+100, not 0 — absolute thresholds needed
///   ~165pt of scrolling to fire, or never fired on shorter tabs).
/// - The state is driven by the visible tab's scroll offset only;
///   pushed pages carry no anchor, so scrolling a pushed page leaves
///   the tracking exactly as it was (known gap, see the anchor docs).
@MainActor
final class BottomChromeState: ObservableObject {
    /// Last offset the anchor reported. isAtTop reads this against
    /// the rest offset; it is not published — the reselect handler
    /// reads it synchronously, and nothing observes it.
    private var lastOffset: CGFloat?

    /// The anchor's offset with the content at the top, for the
    /// current tab (b36-1: the old code assumed 0, but every tab
    /// uses a large navigation title, so the anchor rests ~+100,
    /// not 0 — and the absolute -16 threshold needed ~116pt of
    /// scrolling to fire, or never fired on shorter tabs). Learned
    /// from the FIRST report after a reset (b36-8: learning it as
    /// a running max let a pull-to-refresh / overscroll bounce at
    /// the top inflate it — the anchor's minY briefly rises above
    /// the true top — and isAtTop then stayed true while scrolled
    /// down. A later upward move is a bounce, never a new rest:
    /// the rest only changes on a tab switch, which resets it. A
    /// mid-scroll first report still behaves as before: max(0,
    /// minY) keeps the 0 seed, so the absolute fallback is
    /// unchanged).
    private var restOffset: CGFloat = 0

    /// Whether the rest offset has been learned for the current
    /// tab. False after init / resetRest, until the first anchor
    /// report arrives.
    private var restLearned = false

    /// At or above this far below the rest offset the content is
    /// at the top.
    private static let expandTravel: CGFloat = 16

    /// The tab changed: forget the previous tab's rest offset so
    /// the next anchor report calibrates the new tab from scratch.
    /// Called from MainTabView's selection change. Also forgets
    /// the last offset (the cross-tab delta is meaningless) — the
    /// next report re-derives the state from position alone.
    func resetRest() {
        restOffset = 0
        restLearned = false
        lastOffset = nil
    }

    /// True when the visible tab's content is at its top: the last
    /// anchor report is inside the expand band (the same 16pt the
    /// chrome used to decide "at the top"). A reselect
    /// scroll-to-top reads this first — already at the top means
    /// nothing to do: no scroll, no reload, no flash. True before
    /// any anchor report (a fresh tab starts at the top, and a tab
    /// switch clears the last offset).
    var isAtTop: Bool {
        guard let lastOffset else { return true }
        return lastOffset >= restOffset - Self.expandTravel
    }

    /// Feed the anchor's top offset (rest offset at the top,
    /// decreasing while scrolled down). Records the offset and
    /// learns the rest offset once, from the first report after a
    /// reset: the tab's view starts at the top, so that report
    /// IS the rest offset. Later upward moves are overscroll
    /// bounce (pull-to-refresh, rubber-banding), never a new
    /// rest — adopting them wedged the chrome at the top (b36-8).
    /// A mid-scroll first report keeps the 0 seed (max), so the
    /// absolute fallback is unchanged. Nothing is published: the
    /// minimize state machine this used to drive is gone (build
    /// 37 revert — chen: menu back to its original full tab bar),
    /// and isAtTop is read synchronously by the reselect handler.
    func noteScrollOffset(_ minY: CGFloat) {
        lastOffset = minY
        if !restLearned {
            restOffset = max(restOffset, minY)
            restLearned = true
        }
    }
}

/// Preference key carrying the scroll anchor's top offset up to the
/// scroll view that owns the coordinate space.
private struct HaoChromeScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

/// The offset-reporting GeometryReader, shared by
/// HaoChromeScrollAnchor and by roots that cannot spare a row for
/// it. A GeometryReader used as a `.background` fills its parent's
/// frame, so the offset it reports is the parent's top edge — the
/// same value the anchor row reports.
struct HaoChromeScrollOffsetReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: HaoChromeScrollOffsetKey.self,
                value: proxy.frame(in: .named(HaoLayout.chromeScrollSpace)).minY
            )
        }
    }
}

/// Zero-height view placed as the FIRST child of a tab root's
/// vertical scroll content (ScrollView or List). It reports its top
/// offset in the scroll view's coordinate space — 0 at the top,
/// negative while the content is scrolled down — and
/// BottomChromeState turns that into the rest offset / isAtTop
/// (reselect scroll-to-top). Invisible
/// (clear, zero height, hidden from VoiceOver) and outside the tab's
/// content spacing, so it never shifts a row by a point.
///
/// b42 (chen 2026-11-25 build 41, My tab: ~370px of nothing
/// between the "我的" large title and the first section): the
/// anchor used to BE a GeometryReader, and a GeometryReader as
/// a List row does not collapse to zero height — the List falls
/// back to a default row height (~44pt) for it, and with the
/// insetGrouped first-section spacing the My tab opened with a
/// ~73pt hole above its first card. The anchor's root is now a
/// plain Color.clear with an explicit zero frame (which a List
/// row honours), and the GeometryReader lives in its background
/// — background content never sizes its parent, but it still
/// sits at the content's top edge, so the offset it reports is
/// exactly the same. ScrollView roots are unaffected (a zero
/// frame was already zero there); the List root is fixed.
///
/// b44 (chen 2026-11-25 build 43, My tab: the gap was STILL
/// ~85pt after b42): the b42 reshape did not remove the gap on
/// device — a List row costs row height in ANY form, and the
/// anchor row was ~44pt of the gap. The My tab no longer carries
/// an anchor row at all: the title moved ABOVE the List in b45
/// (a List keeps ~44pt of nav-bar reserve in its content inset
/// even with the bar hidden), and the first section header
/// carries HaoChromeScrollOffsetReader in its background
/// instead. Only the four ScrollView tab roots
/// (Home/Music/Live/Video) still carry an anchor row. A page
/// pushed inside a tab has no anchor: scrolling it leaves the
/// chrome as it was when the page was pushed, and the state
/// self-corrects from the root anchor when the user pops back.
/// Wiring every pushed scroll page is a later pass, not this
/// leg.
struct HaoChromeScrollAnchor: View {
    var body: some View {
        Color.clear
            .frame(height: 0)
            .background { HaoChromeScrollOffsetReader() }
            .accessibilityHidden(true)
    }
}

private struct HaoChromeScrollTracking: ViewModifier {
    @EnvironmentObject private var bottomChrome: BottomChromeState

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: HaoLayout.chromeScrollSpace)
            .onPreferenceChange(HaoChromeScrollOffsetKey.self) { minY in
                guard let minY else { return }
                bottomChrome.noteScrollOffset(minY)
            }
    }
}

extension View {
    /// Watch this scroll view's content offset and feed the bottom
    /// chrome's rest-offset / isAtTop tracking. Apply to the tab root's
    /// ScrollView / List (which must contain a HaoChromeScrollAnchor
    /// as its first content child). Horizontal inner scroll views are
    /// untouched — only vertical content offset moves the anchor.
    func haoChromeScrollTracking() -> some View {
        modifier(HaoChromeScrollTracking())
    }
}

// MARK: - Reselect scroll-to-top (build 36 follow-up, chrome O1)

extension Notification.Name {
    /// Posted by MainTabView when the already-selected tab is tapped
    /// again (reselect). `object` is the HaoTab. Each tab root scrolls
    /// only its own list to the top; nothing else listens.
    static let haoTabReselected = Notification.Name("haoTabReselected")
    /// Posted by HAoStudioApp after the splash when the stored
    /// disclaimer version is not current (b45-h, 包 C leftover b).
    /// MainTabView listens and presents the first-launch
    /// disclaimer gate; nothing else listens.
    static let haoShowDisclaimerGate = Notification.Name("haoShowDisclaimerGate")
    /// Posted by Home empty-state CTA buttons (b49fix2 B1).
    /// `object` is the HaoTab to switch to. MainTabView listens
    /// and selects the tab; nothing else listens.
    static let haoSwitchTab = Notification.Name("haoSwitchTab")
    /// Posted by LocalStore when a corrupt collection file is
    /// quarantined (b49fix2 P0-1). `object` is the collection
    /// name. MainTabView listens and shows a one-time notice.
    static let haoStoreQuarantined = Notification.Name("haoStoreQuarantined")
    /// Posted by LocalStore when a collection save fails
    /// (b49fix2 P1-13 — most often a full disk). `object` is
    /// the collection name. At most once per collection per
    /// launch. MainTabView listens and shows a one-time notice.
    static let haoStoreSaveFailed = Notification.Name("haoStoreSaveFailed")
    /// Posted by DownloadEngine when a download reaches
    /// `.completed` (b49fix2 B5). `object` is the task key.
    /// MainTabView listens for the first-run backup nudge.
    static let haoDownloadCompleted = Notification.Name("haoDownloadCompleted")
}

/// Scroll-to-top anchor id for a tab root's vertical scroll content.
/// The tab root gives its HaoChromeScrollAnchor this id inside a
/// ScrollViewReader; a reselect scrolls the proxy to it.
enum HaoTabScrollTop {
    static func id(for tab: HaoTab) -> String { "hao-scroll-top-\(tab.rawValue)" }
}

private struct HaoReselectScrollToTop: ViewModifier {
    @EnvironmentObject private var bottomChrome: BottomChromeState
    let tab: HaoTab
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .haoTabReselected)) { note in
            guard (note.object as? HaoTab) == tab else { return }
            // Already at the top: nothing to do — no scroll, no
            // reload, no flash. The guard reads the same "at top"
            // BottomChromeState itself uses for the chrome.
            guard !bottomChrome.isAtTop else { return }
            // Scroll-to-top only. It never pops the tab's navigation
            // stack and never touches playback: a live room pushed
            // inside the tab keeps playing, and the scroll happens
            // on the list underneath it.
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(HaoTabScrollTop.id(for: tab), anchor: .top)
            }
        }
    }
}

extension View {
    /// Reselect scroll-to-top for one tab root. Apply inside the tab
    /// root's ScrollViewReader, on the vertical ScrollView / List
    /// whose first child is the HaoChromeScrollAnchor carrying this
    /// tab's HaoTabScrollTop id. Fires only for this tab's reselect.
    func haoReselectScrollToTop(tab: HaoTab, proxy: ScrollViewProxy) -> some View {
        modifier(HaoReselectScrollToTop(tab: tab, proxy: proxy))
    }
}

// MARK: - Haptics switch gate (build 36 follow-up, chrome O6)

/// `.sensoryFeedback`, gated by the 触感反馈 switch (Settings →
/// 触感反馈; UserDefaults key `hapticsEnabled`, default true — the
/// same key the music player already reads through
/// MusicLibraryStore.hapticsEnabled(), mirrored live by
/// SettingsStore.hapticsEnabled; no second copy of the key). Off =
/// this feedback never fires; on = the platform behaviour is
/// unchanged. The gate reads the live SettingsStore, so flipping
/// the switch takes effect without remounting.
private struct HaoGatedSensoryFeedback<V: Equatable>: ViewModifier {
    @EnvironmentObject private var settings: SettingsStore
    let feedback: SensoryFeedback
    let trigger: V

    func body(content: Content) -> some View {
        if settings.hapticsEnabled {
            content.sensoryFeedback(feedback, trigger: trigger)
        } else {
            content
        }
    }
}

extension View {
    /// `.sensoryFeedback` that obeys the 触感反馈 switch. Use this
    /// for every selection/tap haptic in the app; the raw
    /// `.sensoryFeedback` must not be called from app views (the
    /// music player's programmatic hapticTick is the only other
    /// haptic path and is already gated the same way).
    func haoSensoryFeedback<V: Equatable>(_ feedback: SensoryFeedback, trigger: V) -> some View {
        modifier(HaoGatedSensoryFeedback(feedback: feedback, trigger: trigger))
    }
}

/// A capsule with native liquid glass on iOS 26+, regular frosted glass
/// below. Stroke + shadow are shared by both paths so the two look like
/// the same component, not two different bars.
struct HaoGlassCapsule: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: Capsule())
            } else {
                // iOS 17–25: no .glassEffect — regular material is the
                // Apple-native frosted-glass fallback.
                content.background(.ultraThinMaterial, in: Capsule())
            }
        }
        .overlay {
            Capsule().strokeBorder(
                .white.opacity(colorScheme == .dark ? 0.08 : 0.22),
                lineWidth: 0.5
            )
        }
        .clipShape(Capsule())
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.28 : 0.10),
            radius: 12, y: 4
        )
    }
}

/// A rounded rectangle with the same glass treatment as the capsule,
/// at the shared floating-chrome corner radius (HaoLayout
/// .floatingChromeCornerRadius). The mini player uses this: chen's
/// Apple Music reference has the mini and the tab bar as the same
/// rounded rectangle, not a capsule. Same stroke + shadow values as
/// the capsule (and HaoGlassCircle) — keep them in sync.
/// A separate struct, not a generic shape: the shape APIs take a
/// concrete shape, and a generic would only be verifiable on the
/// macOS build gate.
struct HaoGlassRoundedRectangle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: HaoLayout.floatingChromeCornerRadius,
            style: .continuous
        )
    }

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                // iOS 17–25: no .glassEffect — regular material is the
                // Apple-native frosted-glass fallback.
                content.background(.ultraThinMaterial, in: shape)
            }
        }
        .overlay {
            shape.strokeBorder(
                .white.opacity(colorScheme == .dark ? 0.08 : 0.22),
                lineWidth: 0.5
            )
        }
        .clipShape(shape)
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.28 : 0.10),
            radius: 12, y: 4
        )
    }
}

extension View {
    /// Apply the shared floating-capsule glass treatment.
    func haoGlassCapsule() -> some View {
        modifier(HaoGlassCapsule())
    }

    /// Apply the shared floating rounded-rectangle glass treatment
    /// (mini player shape).
    func haoGlassRoundedRect() -> some View {
        modifier(HaoGlassRoundedRectangle())
    }

    /// Bottom clearance for scroll content under the floating stack.
    ///
    /// The floating stack (mini player + glass tab bar) lives in a
    /// bottom safeAreaInset on MainTabView, but that inset does NOT
    /// reach ScrollView / List content inside a NavigationStack —
    /// the UIKit navigation controller owns the safe area there, so
    /// on device (chen 2026-11-24 build 33) the last rows slid under
    /// the bar and could not be dragged into view. Every vertical
    /// scroll page under the stack therefore adds this clearance
    /// itself, as safeAreaPadding on the scroll view: the value is
    /// the stack height above the safe-area bottom edge (the system
    /// safe area itself already covers the home indicator). The
    /// stack is never dropped below the safe-area edge, so the
    /// clearance is the full stack height — nothing is subtracted
    /// (b39: the b38 subtraction of chromeBottomOffset left the
    /// last rows 26pt under the bar on Face ID iPhones). It tracks
    /// the mini player — 60pt taller while something is playing
    /// (8 spacing + 52 mini), so there is no dead gap while idle.
    /// One source of truth: HaoLayout.floatingStackClearance.
    /// NOTE (b40): the five tab roots no longer use this — their
    /// clearance moved INSIDE the scroll content
    /// (haoBottomChromeContentPadding), because safeAreaPadding on
    /// the ScrollView never reached the content inside a
    /// NavigationStack and the last row stayed under the chrome
    /// (chen 2026-11-25 build 39: "最近播放" half hidden). Pushed
    /// pages keep this one (not reported broken; scope stays
    /// narrow).
    func haoBottomChromePadding() -> some View {
        modifier(HaoBottomChromePadding())
    }

    /// Bottom clearance INSIDE a tab root's scroll content (b40).
    ///
    /// Same value and same mini-visibility rule as
    /// haoBottomChromePadding — only the placement differs:
    /// `.padding(.bottom, …)` on the content VStack itself (or a
    /// trailing clear row in a List), so the clearance is part of
    /// the scrollable area and the last row can actually be
    /// scrolled fully above the chrome. Apply to the tab root's
    /// content, and remove haoBottomChromePadding from that root's
    /// ScrollView / List — keeping both would double the gap
    /// (142 + 142).
    func haoBottomChromeContentPadding() -> some View {
        modifier(HaoBottomChromeContentPadding())
    }
}

/// The modifier behind haoBottomChromePadding(). Reads the shared
/// PlaybackCoordinator and MusicPlayerViewModel from the environment
/// (both injected at the app root), so the clearance follows the
/// mini player's visibility exactly: the mini shows while the
/// coordinator has a current item OR a music song is still loaded
/// (MusicPlayerViewModel.miniFallbackSong — a failed / stopped track
/// the full player keeps showing). Using only `currentItem` here
/// would leave 82pt of clearance under a visible 142pt stack.
private struct HaoBottomChromePadding: ViewModifier {
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var musicPlayer: MusicPlayerViewModel

    func body(content: Content) -> some View {
        content.safeAreaPadding(
            .bottom,
            HaoLayout.floatingStackClearance(
                miniPlayerVisible: coordinator.currentItem != nil
                    || musicPlayer.miniFallbackSong != nil
            )
        )
    }
}

/// The modifier behind haoBottomChromeContentPadding() (b40).
/// Same mini-visibility rule and same single source of truth
/// (HaoLayout.floatingStackClearance) as HaoBottomChromePadding —
/// only the placement differs: `.padding(.bottom, …)` inside the
/// scroll content, so the clearance is part of the scrollable area
/// and the last row can actually be scrolled fully above the
/// chrome. safeAreaPadding on the ScrollView never reached the
/// content inside a NavigationStack (the UIKit nav controller owns
/// the safe area there), so the last row stayed under the bar
/// (chen 2026-11-25 build 39: "最近播放" half hidden under the
/// mini). Tab roots only; pushed pages keep safeAreaPadding.
private struct HaoBottomChromeContentPadding: ViewModifier {
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var musicPlayer: MusicPlayerViewModel

    func body(content: Content) -> some View {
        content.padding(
            .bottom,
            HaoLayout.floatingStackClearance(
                miniPlayerVisible: coordinator.currentItem != nil
                    || musicPlayer.miniFallbackSong != nil
            )
        )
    }
}

// MARK: - Tab-root backdrop (b41)

/// What a tab root draws behind its own content (b41, chen
/// 2026-11-25 build 40: the wallpaper still did not show and the
/// menu bar was pushed off the screen).
///
/// b40 drew the wallpaper in MainTabView, BEHIND the tab roots —
/// but every tab root is a NavigationStack, and the stack's
/// underlying UINavigationController paints its own opaque system
/// background, so the picture was always covered no matter what
/// the roots' `.background(Color.clear)` did: that modifier only
/// clears the ScrollView / List itself, never the stack behind
/// it. The b40 wallpaper image also sat as a direct child of
/// MainTabView's ZStack — the same ZStack that carries the
/// `.safeAreaInset` bottom chrome — and with the wallpaper on,
/// the chrome sat one stack height too low on device (mini at the
/// bottom edge, tab bar gone), while it is fine with the wallpaper
/// off. The b40 frame pin did not change the on-device result.
///
/// The backdrop therefore lives INSIDE each tab root now, as the
/// root's background (haoBackdropLayer): above the NavigationStack's
/// background, so it is always visible, and nowhere near
/// MainTabView's ZStack, so no image can size the chrome's layout
/// in any way. The custom background colour had the same defect
/// (it was drawn behind the stack too), so it rides the same layer.
/// MainTabView resolves the backdrop once from
/// MyBackgroundColor.kind and passes it down; the five tab roots
/// only draw it.
///
/// b43 (chen 2026-11-25 build 42: "字会往上移"): the backdrop
/// used to be a ZStack WRAPPING the root's scroll content — the
/// wrapper's ignoresSafeArea image sized the ZStack to full
/// screen, the ScrollView / VStack then started at y=0, and with
/// the wallpaper on every title moved up ~59pt (the Video tab's
/// GeometryReader + top padding only patched that one root). A
/// background never sizes its parent, so the wallpaper-on layout
/// is now pixel-identical to wallpaper-off; the background's
/// ignoresSafeArea still paints it full-bleed.
enum HaoBackdrop {
    case wallpaper(UIImage)
    case color(Color)
    case theme

    /// Resolve the backdrop from the raw inputs (b41): the same
    /// priority as MyBackgroundColor.kind — wallpaper (enabled +
    /// image loaded) > background colour (enabled + valid #RRGGBB)
    /// > theme scaffold. A layer that is off or unusable falls
    /// through; nothing here invents a colour.
    static func resolve(
        wallpaperEnabled: Bool,
        wallpaperImage: UIImage?,
        bgColorEnabled: Bool,
        bgColorHex: String
    ) -> HaoBackdrop {
        switch MyBackgroundColor.kind(
            wallpaperEnabled: wallpaperEnabled,
            wallpaperAvailable: wallpaperImage != nil,
            bgColorEnabled: bgColorEnabled,
            bgColorHex: bgColorHex
        ) {
        case .wallpaper:
            if let image = wallpaperImage { return .wallpaper(image) }
            return .theme
        case .color:
            if let color = MyBackgroundColor.color(fromHex: bgColorHex) { return .color(color) }
            return .theme
        case .theme:
            return .theme
        }
    }

    var isWallpaper: Bool {
        if case .wallpaper = self { return true }
        return false
    }

    var isColor: Bool {
        if case .color = self { return true }
        return false
    }

    var isTheme: Bool {
        if case .theme = self { return true }
        return false
    }
}

private struct HaoBackdropKey: EnvironmentKey {
    static let defaultValue = HaoBackdrop.theme
}

extension EnvironmentValues {
    var haoBackdrop: HaoBackdrop {
        get { self[HaoBackdropKey.self] }
        set { self[HaoBackdropKey.self] = newValue }
    }
}

/// The backdrop layer (b41): the wallpaper photo or the custom
/// background colour, drawn full-bleed as the tab root's
/// background — above the NavigationStack's opaque background, so
/// it can never be covered by it. A background never sizes its
/// parent (b43: the old ZStack wrapper's ignoresSafeArea image
/// sized the ZStack to full screen, the ScrollView / VStack then
/// started at y=0, and with the wallpaper on every title moved
/// up ~59pt — chen 2026-11-25 build 42 "字会往上移"), so the
/// wallpaper-on layout is pixel-identical to wallpaper-off: the
/// wallpaper only changes the background, never the layout. The
/// background's ignoresSafeArea still paints it full-bleed
/// (behind the status bar and the home indicator), and it does
/// not scroll with the content. Use on the five tab roots only,
/// next to haoTabBackground.
///
/// b42 (chen 2026-11-25 build 41, wallpaper on): black section
/// titles and 0.55-alpha cards drawn straight on a busy photo
/// are unreadable — the photo shows through the cards and the
/// grey subtitle text washes out. The wallpaper case therefore
/// carries a legibility veil: a scaffold-coloured gradient over
/// the photo (behind the content), strong enough at the top
/// that the large titles read on any photo, lighter toward the
/// bottom so the photo still shows. One treatment, in this one
/// shared layer, so all five roots read the same — no per-page
/// scrims, no extra labels, no redesign. The solid-colour
/// backdrop needs no veil (a flat colour already reads), and
/// the theme backdrop has nothing behind the content.
private struct HaoBackdropLayer: ViewModifier {
    @Environment(\.haoBackdrop) private var backdrop
    @Environment(\.haoTheme) private var theme

    func body(content: Content) -> some View {
        // b43: background, not a ZStack wrapper — a background
        // never sizes its parent (see the doc above), and its
        // ignoresSafeArea content still paints full-bleed.
        content.background { backdropView }
    }

    @ViewBuilder
    private var backdropView: some View {
        switch backdrop {
        case .wallpaper(let image):
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .ignoresSafeArea()
                // Legibility veil (b42, strengthened b49fix2 #34):
                // scaffold colour (near-white light mode, black
                // dark mode) as a top-to-bottom gradient — the
                // titles at the top get the strongest veil, the
                // cards below get a lighter one. The b42 values
                // (0.55 / 0.42) still washed song rows out on busy
                // photos (chen build 42: grey subtitle text unreadable);
                // the stronger veil keeps rows legible while the
                // photo still shows through everywhere. The text
                // and the semi-transparent cards just stop fighting it.
                LinearGradient(
                    colors: [
                        theme.scaffoldBackground.opacity(0.72),
                        theme.scaffoldBackground.opacity(0.58),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        case .color(let color):
            color.ignoresSafeArea()
        case .theme:
            EmptyView()
        }
    }
}

extension View {
    /// Draw this tab root's backdrop (wallpaper / background
    /// colour) behind its content. No-op for the theme backdrop.
    func haoBackdropLayer() -> some View {
        modifier(HaoBackdropLayer())
    }
}

/// Tab-root background (b41, chen 2026-11-25: 壁纸导入之后用了
/// 也不显示): the backdrop layer above already paints the
/// wallpaper / colour behind the content, so the root background
/// only needs to be opaque when there is no backdrop at all
/// (theme): then it paints the opaque theme scaffold exactly as
/// before. Pushed pages keep their opaque scaffold (they are
/// transient; the backdrop is back when you pop).
private struct HaoTabBackground: ViewModifier {
    @Environment(\.haoTheme) private var theme
    @Environment(\.haoBackdrop) private var backdrop

    func body(content: Content) -> some View {
        content.background(backdrop.isTheme ? theme.scaffoldBackground : Color.clear)
    }
}

extension View {
    /// Tab-root background that lets an active backdrop show
    /// through (clear), or paints the opaque theme scaffold when
    /// there is no backdrop. Use on the five tab roots only.
    func haoTabBackground() -> some View {
        modifier(HaoTabBackground())
    }
}

/// A circle with native liquid glass on iOS 26+, regular frosted
/// glass below. Same stroke as the capsule (white 0.22 light /
/// 0.08 dark, 0.5pt) so round controls read as the same component
/// family. Used for the full-player top-bar buttons (Beans
/// PlayerView: 38pt glass circle + white 0.22 hairline; ours is
/// 40pt so the hit target is closer to Apple's 44pt minimum).
struct HaoGlassCircle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: Circle())
            } else {
                content.background(.ultraThinMaterial, in: Circle())
            }
        }
        .overlay {
            Circle().strokeBorder(
                .white.opacity(colorScheme == .dark ? 0.08 : 0.22),
                lineWidth: 0.5
            )
        }
        .clipShape(Circle())
    }
}

extension View {
    /// Apply the shared round-control glass treatment.
    func haoGlassCircle() -> some View {
        modifier(HaoGlassCircle())
    }
}

/// Dark liquid glass for small floating pills that carry white
/// text over any content (toasts, HUDs, badges, poster pills):
/// white text stays readable in light and dark mode because the
/// glass is tinted dark — plain .regular glass would wash white
/// text out on a light page (the old black 0.7 fills existed for
/// exactly this reason; see the music-player toast comment).
/// iOS 26+: glassEffect(.regular.tint(black)) in the shape;
/// below: the old flat dark fill at the same opacity, so the
/// fallback is pixel-identical to before. No stroke/shadow here
/// — the call site keeps its own (toasts carry their Coda
/// shadow); the shape and the darkness are the only things this
/// helper owns.
struct HaoDarkGlassCapsule: ViewModifier {
    var darkness: Double = 0.7

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular.tint(.black.opacity(darkness)), in: Capsule())
            } else {
                content.background(Color.black.opacity(darkness), in: Capsule())
            }
        }
    }
}

/// Same dark glass as HaoDarkGlassCapsule, for the rounded-rect
/// toasts / HUDs (corner radius 10, Coda §8.6).
struct HaoDarkGlassRoundedRectangle: ViewModifier {
    var cornerRadius: CGFloat = 10
    var darkness: Double = 0.7

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                content.glassEffect(
                    .regular.tint(.black.opacity(darkness)),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            } else {
                content.background(
                    Color.black.opacity(darkness),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            }
        }
    }
}

extension View {
    /// Apply the shared dark-glass capsule treatment (white text
    /// over any content). `darkness` is the tint strength on
    /// iOS 26+ and the flat fill opacity below — pass the site's
    /// old black opacity so the fallback does not move.
    func haoDarkGlassCapsule(darkness: Double = 0.7) -> some View {
        modifier(HaoDarkGlassCapsule(darkness: darkness))
    }

    /// Apply the shared dark-glass rounded-rectangle treatment
    /// (toasts / HUDs).
    func haoDarkGlassRoundedRect(cornerRadius: CGFloat = 10, darkness: Double = 0.7) -> some View {
        modifier(HaoDarkGlassRoundedRectangle(cornerRadius: cornerRadius, darkness: darkness))
    }
}

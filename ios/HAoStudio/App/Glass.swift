// HAo Studio 2.0 — shared glass + floating-layout constants.
//
// Native liquid glass: iOS 26+ uses `.glassEffect`; iOS 17–25 falls back
// to the regular frosted-glass material (`.ultraThinMaterial` / UIBlurEffect
// equivalent). The fallback is a real material, not a solid colour, so the
// app still reads as frosted glass on older systems.
//
// Sizing / spring values (spring response 0.35, dampingFraction 0.82;
// stroke white 0.22 light / 0.08 dark, 0.5pt; shadow black 0.10 / 0.28,
// radius 12, y 4; bottomMargin 0; content height 56 + 4pt inset).

import SwiftUI
import UIKit

/// Shared dimensions for the floating bottom stack (tab bar, and the
/// mini player that sits above it). Content bottom insets are derived
/// from these in one place so the bar and the mini player can never
/// overlap each other or the content.
enum HaoLayout {
    /// Glass tab bar content height (56).
    static let tabBarContentHeight: CGFloat = 56
    /// Total height of the glass tab bar as laid out in the
    /// floating stack: 56pt — exactly the system UITabBar's own
    /// glass height (tabBarContentHeight). b43 CORRECTS b42 (chen
    /// 2026-11-25 build 42: the mini still overlaps the bar, the
    /// singer line under "爱情转移" sliced): the b42 theory — "the
    /// frame must equal the rendered glass, so the mini's bottom
    /// edge IS the bar's top edge at spacing 0" — is DISPROVEN on
    /// device. The bar's glass top is frame-independent: it sits
    /// at ~2420 on chen's 11:51 build-42 screenshot whether the
    /// frame is 64 (build 41: glass top ~2423) or 56 (build 42:
    /// glass top ~2420), while the frame top moved 24px. The
    /// 64 -> 56 change therefore moved the mini DOWN 23px (the
    /// stack is bottom-anchored) and the overlap grew from ~4pt
    /// to ~13pt. The overlap is fixed by floatingStackSpacing
    /// (13), not by the frame. The frame stays 56 (the system
    /// bar's content height) and the 4pt inset stays deleted (it
    /// was only ever the b40 arithmetic, never a real inset).
    static let tabBarTotalHeight: CGFloat = tabBarContentHeight
    /// Distance from the safe-area bottom edge: 2. The bar sits
    /// 2pt above the safe-area boundary — fully inside the
    /// hit-testable safe area, never dropped below it (b39: the
    /// b38 chromeBottomOffset drop pushed the bar 26pt below the
    /// safe-area edge on Face ID iPhones and taps fell through).
    /// The gap to the screen edge is the home-indicator zone
    /// itself.
    static let tabBarBottomMargin: CGFloat = 2
    /// Horizontal margin of the floating capsule.
    static let tabBarHorizontalMargin: CGFloat = 12
    /// Mini player strip height (Kumone MiniPlayerView: cover 32 +
    /// 2 x 4pt vertical padding = 40pt rendered; buttons 40 x 40,
    /// title 13 semibold, subtitle 10). Build 38, chen 2026-11-24:
    /// "mini 播放器做短一点" — the strip is shortened 44 -> 40pt
    /// (HEIGHT, not width: the width stays screen − 24, equal to
    /// the tab bar's). The b37 44pt was 6pt under the b36 50pt and
    /// invisible to him; 40pt with the 32 cover, 13/11 text and
    /// 40pt buttons reads clearly slimmer. 40 is the floor with
    /// the current controls: the 32 cover + 4pt padding each side,
    /// and the 40pt play / pause hit targets fill the strip
    /// exactly.
    static let miniPlayerHeight: CGFloat = 40
    /// Corner radius of the floating chrome (mini player + tab bar):
    /// a rounded rectangle, NOT a capsule. chen's Apple Music
    /// reference (2026-11-24 build 34): the mini and the bar share
    /// one shape, one width, stacked with an 8pt gap. 24pt, on the
    /// 4pt grid (raised from 12 in the build-35 polish pass): the
    /// iOS 26 reference measures the mini and the floating tab bar
    /// at ~20–28pt — near half the 44pt strip height, almost a
    /// capsule — so 12 read square next to the system bar, whose
    /// radius is Apple's own (~20–30pt). One constant: if the two
    /// still read as different shapes on device, this is the
    /// single place to adjust — never a second hand-written number
    /// in the mini. True-device confirmation still pending (chen's
    /// phone is the judge: "看着像同一套").
    static let floatingChromeCornerRadius: CGFloat = 24
    /// Horizontal content padding inside the mini player strip,
    /// symmetric both sides (was 10 leading / 6 trailing — the
    /// strip read lopsided). Same 12pt step as the tab bar's side
    /// margins, so the cover's left edge and the buttons' right
    /// edge sit on the same rhythm as the bar.
    static let miniPlayerContentPadding: CGFloat = 12
    /// Gap between the mini player strip and the tab bar: 13 (b43).
    /// The two are ONE connected floating unit — the mini's GLASS
    /// bottom edge touches the bar's GLASS top edge, no seam, no
    /// overlap, same width, same margins (chen 2026-11-24: "你看布局啊"
    /// — Apple Music's mini and bar read as a single block). The
    /// gap is a GLASS compensation, not a frame gap: the system
    /// tab bar's Liquid Glass renders ~13pt ABOVE its SwiftUI
    /// frame's top edge (measured on chen's build-42 screenshot,
    /// 1260x2736: mini glass bottom ~2459, bar glass top ~2420 —
    /// the singer line under "爱情转移" is sliced at the glass
    /// top, and a 638px-wide specular band sits at 2420-2422),
    /// so the glass top is frame-independent. b42's frame change
    /// (64 -> 56) therefore did NOT move the glass — it moved the
    /// mini DOWN 23px (the stack is bottom-anchored) and the
    /// overlap grew from ~4pt to ~13pt. The 13pt frame gap puts
    /// the mini's glass bottom back on the bar's glass top. Was 0
    /// (b38-b42), 8 before that: two separate capsules with a gap,
    /// each floating on its own.
    static let floatingStackSpacing: CGFloat = 13
    /// Name of the coordinate space a tab root's scroll view publishes
    /// for the chrome scroll anchor (HaoChromeScrollAnchor): the
    /// anchor reports its top offset in this space, 0 at the top,
    /// negative while the content is scrolled down.
    static let chromeScrollSpace = "haoChromeScroll"
    /// Cover size in the mini player (Kumone MiniPlayerView: 32,
    /// radius 6 — b38, down from Beans' 36 so the 40pt strip reads
    /// visibly slimmer).
    static let miniCoverSize: CGFloat = 32
    /// matchedGeometryEffect id shared by the mini cover and the full
    /// player cover: tapping the mini morphs this one cover from 32
    /// to the full player's cover (up to 340).
    static let playerCoverMorphID = "haoPlayerCover"
    /// Height of the floating stack above the safe-area bottom edge:
    /// bottom margin + tab bar + (gap + mini player while one is
    /// showing). This is the clearance a scroll page under the stack
    /// must add so its last row can scroll fully above the stack —
    /// 58pt idle, 111pt while playing (b43: the 13pt glass-
    /// compensation spacing joins the stack while playing).
    /// The stack is never dropped below the safe-area edge, so the
    /// clearance is the full stack height — nothing is subtracted.
    /// See haoBottomChromePadding(). (Build 37: the scroll-minimize
    /// behaviour is gone — chen 2026-11-24 had the menu restored
    /// to its original full tab bar, so there is no minimized form
    /// and no isMinimized parameter any more.)
    static func floatingStackClearance(miniPlayerVisible: Bool) -> CGFloat {
        return tabBarBottomMargin + tabBarTotalHeight
            + (miniPlayerVisible ? floatingStackSpacing + miniPlayerHeight : 0)
    }
    /// Settle spring for chrome transitions (full-player fade,
    /// sidebar, rows).
    static let settleSpring = Animation.spring(response: 0.35, dampingFraction: 0.82)
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
/// Only the five tab roots carry one. A page pushed inside a tab has
/// no anchor: scrolling it leaves the chrome as it was when the page
/// was pushed, and the state self-corrects from the root anchor when
/// the user pops back. Wiring every pushed scroll page is a later
/// pass, not this leg.
struct HaoChromeScrollAnchor: View {
    var body: some View {
        Color.clear
            .frame(height: 0)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: HaoChromeScrollOffsetKey.self,
                        value: proxy.frame(in: .named(HaoLayout.chromeScrollSpace)).minY
                    )
                }
            }
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
    /// the mini player — 40pt taller while something is playing,
    /// so there is no dead gap while idle.
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
    /// (111 + 111).
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
/// would leave 58pt of clearance under a visible 111pt stack.
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
                // Legibility veil (b42): scaffold colour (near-white
                // light mode, black dark mode) as a top-to-bottom
                // gradient — the titles at the top get the strongest
                // veil, the cards below get a lighter one. The photo
                // still shows through everywhere; the text and the
                // semi-transparent cards just stop fighting it.
                LinearGradient(
                    colors: [
                        theme.scaffoldBackground.opacity(0.55),
                        theme.scaffoldBackground.opacity(0.42),
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

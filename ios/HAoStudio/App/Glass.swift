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
    /// Vertical breathing room inside the tab bar's 64pt frame
    /// (4 top / 4 bottom; total 64pt). b40: this is NOT SwiftUI
    /// padding any more — GlassTabBar used to wrap the bar in
    /// `.padding(.vertical, 4)`, which left a transparent band
    /// above the bar (the system UITabBar only paints glass over
    /// its own 56pt frame) and read as a seam between the mini
    /// and the bar (chen 2026-11-25 build 39). The bar now fills
    /// the full 64pt frame; the 4pt survives only as the
    /// arithmetic that sizes the frame (content 56 centred in
    /// 64). Horizontal padding was never here: the system tab bar
    /// paints its background over its own frame, so horizontal
    /// padding would shrink the visible bar 4pt per side and it
    /// would read 8pt narrower than the mini player above it
    /// (chen 2026-11-24 build 33: mini must be exactly as wide
    /// as the bar). The visible bar spans exactly the mini
    /// player's width (screen minus the shared 12pt side margins
    /// in MainTabView).
    static let tabBarInnerInset: CGFloat = 4
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
    /// Gap between the mini player strip and the tab bar: 0 (b38).
    /// The two are ONE connected floating unit — the mini's bottom
    /// edge touches the bar's top edge, no seam, same width, same
    /// margins (chen 2026-11-24: "你看布局啊" — Apple Music's mini
    /// and bar read as a single block). Was 8: two separate
    /// capsules with a gap, each floating on its own.
    static let floatingStackSpacing: CGFloat = 0
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
    /// Total height of the glass tab bar as laid out in the floating
    /// stack: content 56 + 4pt inset top and bottom (64). The bar
    /// fills this whole height (b40: no SwiftUI vertical padding —
    /// the glass must run edge to edge so it touches the mini
    /// above it with no seam).
    static let tabBarTotalHeight: CGFloat = tabBarContentHeight + tabBarInnerInset * 2
    /// Height of the floating stack above the safe-area bottom edge:
    /// bottom margin + tab bar + (gap + mini player while one is
    /// showing). This is the clearance a scroll page under the stack
    /// must add so its last row can scroll fully above the stack —
    /// 66pt idle, 106pt while playing (b39: margin restored to 2).
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
/// Only the five tab roots carry one. A page pushed inside a tab has
/// no anchor: scrolling it leaves the chrome as it was when the page
/// was pushed, and the state self-corrects from the root anchor when
/// the user pops back. Wiring every pushed scroll page is a later
/// pass, not this leg.
struct HaoChromeScrollAnchor: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: HaoChromeScrollOffsetKey.self,
                value: proxy.frame(in: .named(HaoLayout.chromeScrollSpace)).minY
            )
        }
        .frame(height: 0)
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
    /// (106 + 106).
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
/// would leave 64pt of clearance under a visible 104pt stack.
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

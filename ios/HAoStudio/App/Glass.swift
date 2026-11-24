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

/// Shared dimensions for the floating bottom stack (tab bar, and the
/// mini player that sits above it). Content bottom insets are derived
/// from these in one place so the bar and the mini player can never
/// overlap each other or the content.
enum HaoLayout {
    /// Glass tab bar content height (56).
    static let tabBarContentHeight: CGFloat = 56
    /// Inner inset around the tab bar content, top and bottom only
    /// (4; total 64pt). It used to be all-sides padding, but a
    /// system UITabBar paints its background over its own frame, so
    /// horizontal padding shrank the visible bar 4pt per side and it
    /// read 8pt narrower than the mini player above it (chen
    /// 2026-11-24 build 33). Beans can pad all sides because its
    /// capsule background is painted OVER the padded area; the
    /// system bar has no such background. Vertical only now: the
    /// visible bar spans exactly the mini player's width.
    static let tabBarInnerInset: CGFloat = 4
    /// Distance from the safe-area bottom edge (bottomMargin 2 —
    /// chen 2026-11-24 build 33: the bar floated too high; 2pt here
    /// plus the 4pt inner inset leaves the visible glass 6pt above
    /// the home-indicator zone, the minimum visual gap).
    static let tabBarBottomMargin: CGFloat = 2
    /// Horizontal margin of the floating capsule.
    static let tabBarHorizontalMargin: CGFloat = 12
    /// Mini player strip height (Beans MiniPlayerView: 42pt content
    /// + 2 x 4pt vertical padding = 50pt rendered; cover 36,
    /// control 32, title 12 semibold, subtitle 10).
    static let miniPlayerHeight: CGFloat = 50
    /// Corner radius of the floating chrome (mini player + tab bar):
    /// a rounded rectangle, NOT a capsule. chen's Apple Music
    /// reference (2026-11-24 build 34): the mini and the bar share
    /// one shape, one width, stacked with an 8pt gap. 24pt, on the
    /// 4pt grid (raised from 12 in the build-35 polish pass): the
    /// iOS 26 reference measures the mini and the floating tab bar
    /// at ~20–28pt — near half the 50pt strip height, almost a
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
    /// Gap between the mini player strip and the tab bar.
    static let floatingStackSpacing: CGFloat = 8
    /// Name of the coordinate space a tab root's scroll view publishes
    /// for the chrome scroll anchor (HaoChromeScrollAnchor): the
    /// anchor reports its top offset in this space, 0 at the top,
    /// negative while the content is scrolled down.
    static let chromeScrollSpace = "haoChromeScroll"
    /// Cover size in the expanded mini player (Beans MiniPlayerView: 36).
    static let miniCoverSize: CGFloat = 36
    /// Cover size in the inline (minimized) mini player: the iOS 26
    /// NowPlayingTray recipe uses 32 — the tray drops the artist line
    /// and the next button, and the smaller cover leaves room for the
    /// title in the narrowed strip.
    static let miniInlineCoverSize: CGFloat = 32
    /// matchedGeometryEffect id shared by the mini cover and the full
    /// player cover: tapping the mini morphs this one cover from 36
    /// (or 32 inline) to the full player's cover (up to 340).
    static let playerCoverMorphID = "haoPlayerCover"
    /// Long-press dwell before the minimized capsule starts
    /// tab-dragging (Apple: long-press the minimized bar, then slide
    /// to switch tabs).
    static let minimizedCapsuleLongPressDuration: TimeInterval = 0.3
    /// Horizontal drag per tab while switching tabs on the minimized
    /// capsule.
    static let minimizedCapsuleTabStep: CGFloat = 64
    /// Total height of the glass tab bar as laid out in the floating
    /// stack: content 56 + 4pt inner inset top and bottom (64).
    static let tabBarTotalHeight: CGFloat = tabBarContentHeight + tabBarInnerInset * 2
    /// Height of the floating stack above the safe-area bottom edge:
    /// bottom margin + tab bar + (gap + mini player while one is
    /// showing). This is the clearance a scroll page under the stack
    /// must add so its last row can scroll fully above the stack —
    /// 66pt idle, 124pt while playing. Minimized, the stack is a
    /// single tab-bar slot (capsule + inline mini side by side),
    /// so the clearance is 66pt whatever the mini is doing — the
    /// reclaimed space is the point of minimizing. See
    /// haoBottomChromePadding().
    static func floatingStackClearance(miniPlayerVisible: Bool, isMinimized: Bool = false) -> CGFloat {
        if isMinimized {
            return tabBarBottomMargin + tabBarTotalHeight
        }
        return tabBarBottomMargin + tabBarTotalHeight
            + (miniPlayerVisible ? floatingStackSpacing + miniPlayerHeight : 0)
    }
    /// Settle spring for the tab-bar selection pill.
    static let settleSpring = Animation.spring(response: 0.35, dampingFraction: 0.82)
}

/// Scroll-driven minimize state for the bottom chrome (b35 tab-bar
/// link — Apple Music / iOS 26 behaviour, hand-rolled).
///
/// iOS 26 ships this as `.tabBarMinimizeBehavior(.onScrollDown)` +
/// `.tabViewBottomAccessory`, but those modifiers belong to a stock
/// TabView: this app has no TabView (custom UITabBar + @State content
/// switch in MainTabView) and the deployment target is iOS 17, so the
/// system behaviour is reimplemented here from a scroll anchor. The
/// payoff is that it runs on iOS 17–27 with one code path.
///
/// Behaviour (matches the iOS 26 Music shell):
/// - Scroll down: the tab bar tucks into one small glass capsule
///   showing only the current tab, and the mini player slides down
///   beside it, narrower, without its artist line or next button.
/// - Scroll up (or back to the top): both spring back — the full
///   tab bar and the wide mini above it.
/// - Thresholds are relative to the tab's own rest offset (b36-1):
///   every tab uses a large navigation title, so the anchor rests
///   ~+100, not 0 — absolute thresholds needed ~165pt of scrolling
///   to fire, or never fired on shorter tabs.
/// - The state is driven by the visible tab's scroll offset only;
///   pushed pages carry no anchor, so scrolling a pushed page leaves
///   the chrome exactly as it was (known gap, see the anchor docs).
@MainActor
final class BottomChromeState: ObservableObject {
    /// True while the chrome is in its minimized (single-row) form.
    @Published private(set) var isMinimized = false

    /// Last offset the anchor reported. The hysteresis band below
    /// only follows the scroll DIRECTION, so a slow drag near the
    /// boundary never flickers the chrome.
    private var lastOffset: CGFloat?

    /// The anchor's offset with the content at the top, for the
    /// current tab (b36-1: the old code assumed 0, but every tab
    /// uses a large navigation title, so the anchor rests ~+100,
    /// not 0 — and the absolute -16 / -64 thresholds needed
    /// ~165pt of scrolling to fire, or never fired on shorter
    /// tabs). Learned from the FIRST report after a reset (b36-8:
    /// learning it as a running max let a pull-to-refresh /
    /// overscroll bounce at the top inflate it — the anchor's minY
    /// briefly rises above the true top — and the chrome then
    /// wedged minimized at the top, because minY could never
    /// reach the inflated rest offset - 16 again. A later upward
    /// move is a bounce, never a new rest: the rest only changes
    /// on a tab switch, which resets it. A mid-scroll first
    /// report still behaves as before: max(0, minY) keeps the 0
    /// seed, so the absolute fallback is unchanged).
    private var restOffset: CGFloat = 0

    /// Whether the rest offset has been learned for the current
    /// tab. False after init / resetRest, until the first anchor
    /// report arrives.
    private var restLearned = false

    /// At or above this far below the rest offset the content is
    /// at the top: always expanded.
    private static let expandTravel: CGFloat = 16
    /// At or below this far below the rest offset the content is
    /// clearly scrolled down: always minimized.
    private static let minimizeTravel: CGFloat = 64
    /// Inside the band, a downward move of this much minimizes…
    private static let minimizeStep: CGFloat = 6
    /// …and an upward move of this much expands.
    private static let expandStep: CGFloat = 10

    /// The tab changed: forget the previous tab's rest offset so
    /// the next anchor report calibrates the new tab from scratch.
    /// Called from MainTabView's selection change. Also forgets
    /// the last offset (the cross-tab delta is meaningless) — the
    /// next report re-derives the state from position alone.
    /// Never touches isMinimized itself — the next report
    /// re-derives it.
    func resetRest() {
        restOffset = 0
        restLearned = false
        lastOffset = nil
    }

    /// Feed the anchor's top offset (rest offset at the top,
    /// decreasing while scrolled down). Only publishes when the
    /// minimized flag actually flips, so a scroll drag does not
    /// re-render the chrome every frame.
    func noteScrollOffset(_ minY: CGFloat) {
        let previous = lastOffset
        lastOffset = minY
        // Learn the top once, from the first report after a
        // reset: the tab's view starts at the top, so that report
        // IS the rest offset. Later upward moves are overscroll
        // bounce (pull-to-refresh, rubber-banding), never a new
        // rest — adopting them wedged the chrome minimized at
        // the top (b36-8). A mid-scroll first report keeps the 0
        // seed (max), so the absolute fallback is unchanged.
        if !restLearned {
            restOffset = max(restOffset, minY)
            restLearned = true
        }
        let target: Bool?
        if minY >= restOffset - Self.expandTravel {
            target = false
        } else if minY <= restOffset - Self.minimizeTravel {
            target = true
        } else if let previous {
            let delta = minY - previous
            if delta <= -Self.minimizeStep {
                target = true
            } else if delta >= Self.expandStep {
                target = false
            } else {
                target = nil
            }
        } else {
            target = nil
        }
        guard let target, target != isMinimized else { return }
        withAnimation(HaoLayout.settleSpring) {
            isMinimized = target
        }
    }

    /// Expand the chrome (tap on the minimized capsule). No-op when
    /// already expanded, so a stray tap can never wedge it.
    func expand() {
        guard isMinimized else { return }
        withAnimation(HaoLayout.settleSpring) {
            isMinimized = false
        }
    }

    /// Minimize the chrome (explicit callers; scrolling normally
    /// drives this through noteScrollOffset).
    func minimize() {
        guard !isMinimized else { return }
        withAnimation(HaoLayout.settleSpring) {
            isMinimized = true
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
/// BottomChromeState turns that into minimize / restore. Invisible
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
    /// Watch this scroll view's content offset and drive the bottom
    /// chrome's minimize / restore state. Apply to the tab root's
    /// ScrollView / List (which must contain a HaoChromeScrollAnchor
    /// as its first content child). Horizontal inner scroll views are
    /// untouched — only vertical content offset moves the anchor.
    func haoChromeScrollTracking() -> some View {
        modifier(HaoChromeScrollTracking())
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
    /// safe area itself already covers the home indicator), and it
    /// tracks the mini player — 58pt taller while something is
    /// playing, so there is no dead gap while idle. One source of
    /// truth: HaoLayout.floatingStackClearance.
    func haoBottomChromePadding() -> some View {
        modifier(HaoBottomChromePadding())
    }
}

/// The modifier behind haoBottomChromePadding(). Reads the shared
/// PlaybackCoordinator and MusicPlayerViewModel from the environment
/// (both injected at the app root), so the clearance follows the
/// mini player's visibility exactly: the mini shows while the
/// coordinator has a current item OR a music song is still loaded
/// (MusicPlayerViewModel.miniFallbackSong — a failed / stopped track
/// the full player keeps showing). Using only `currentItem` here
/// would leave 66pt of clearance under a visible 124pt stack.
/// It also reads BottomChromeState: minimized, the stack is one
/// tab-bar slot tall (66pt) whatever the mini is doing, so the
/// clearance shrinks with the chrome and the reclaimed space is real.
private struct HaoBottomChromePadding: ViewModifier {
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var musicPlayer: MusicPlayerViewModel
    @EnvironmentObject private var bottomChrome: BottomChromeState

    func body(content: Content) -> some View {
        content.safeAreaPadding(
            .bottom,
            HaoLayout.floatingStackClearance(
                miniPlayerVisible: coordinator.currentItem != nil
                    || musicPlayer.miniFallbackSong != nil,
                isMinimized: bottomChrome.isMinimized
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

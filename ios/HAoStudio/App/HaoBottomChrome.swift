// HAo Studio 2.0 — bottom-chrome state, scroll anchors + bottom clearance.
//
// Split out of Glass.swift in b49phase1 P6: BottomChromeState,
// the scroll-anchor / reselect machinery, and the bottom-
// clearance padding (modifiers + View methods). Pure move —
// no symbol renamed, no value changed.

import SwiftUI
import Combine

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
    // NOTE (b49fix26): haoStoreQuarantined / haoStoreSaveFailed /
    // haoDownloadCompleted used to be defined here, but LocalStore
    // and DownloadEngine (both AppCore sources) post them, so the
    // definitions live in Storage/LocalStore.swift now — Glass.swift
    // is app-target-only and `swift test` could not see them.
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

extension View {
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

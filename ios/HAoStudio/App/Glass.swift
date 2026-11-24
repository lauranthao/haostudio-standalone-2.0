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
    /// Gap between the mini player strip and the tab bar.
    static let floatingStackSpacing: CGFloat = 8
    /// Total height of the glass tab bar as laid out in the floating
    /// stack: content 56 + 4pt inner inset top and bottom (64).
    static let tabBarTotalHeight: CGFloat = tabBarContentHeight + tabBarInnerInset * 2
    /// Height of the floating stack above the safe-area bottom edge:
    /// bottom margin + tab bar + (gap + mini player while one is
    /// showing). This is the clearance a scroll page under the stack
    /// must add so its last row can scroll fully above the stack —
    /// 66pt idle, 124pt while playing. See haoBottomChromePadding().
    static func floatingStackClearance(miniPlayerVisible: Bool) -> CGFloat {
        tabBarBottomMargin + tabBarTotalHeight
            + (miniPlayerVisible ? floatingStackSpacing + miniPlayerHeight : 0)
    }
    /// Settle spring for the tab-bar selection pill.
    static let settleSpring = Animation.spring(response: 0.35, dampingFraction: 0.82)
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

extension View {
    /// Apply the shared floating-capsule glass treatment.
    func haoGlassCapsule() -> some View {
        modifier(HaoGlassCapsule())
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
/// PlaybackCoordinator from the environment (injected at the app
/// root), so the clearance follows the mini player's visibility.
private struct HaoBottomChromePadding: ViewModifier {
    @EnvironmentObject private var coordinator: PlaybackCoordinator

    func body(content: Content) -> some View {
        content.safeAreaPadding(
            .bottom,
            HaoLayout.floatingStackClearance(miniPlayerVisible: coordinator.currentItem != nil)
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

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
    /// Inner inset around the tab bar content (4; total 64pt).
    static let tabBarInnerInset: CGFloat = 4
    /// Distance from the safe-area bottom edge (bottomMargin 6).
    static let tabBarBottomMargin: CGFloat = 6
    /// Horizontal margin of the floating capsule.
    static let tabBarHorizontalMargin: CGFloat = 12
    /// Mini player strip height (Beans MiniPlayerView: 42pt content
    /// + 2 x 4pt vertical padding = 50pt rendered; cover 36,
    /// control 32, title 12 semibold, subtitle 10).
    static let miniPlayerHeight: CGFloat = 50
    /// Gap between the mini player strip and the tab bar.
    static let floatingStackSpacing: CGFloat = 8
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
}

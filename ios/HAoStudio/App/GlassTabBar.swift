// HAo Studio 2.0 — bottom tab bar.
//
// b49 (chen 2026-11-25 build 48: "菜单也没修好"): this is now a
// PURE SwiftUI bar — an HStack of buttons drawn with the same
// haoGlassRoundedRect as the mini player, so the single glass
// layer is CONSTRUCTED, not hidden. The UITabBar version is gone:
// its Liquid Glass could not be killed on iOS 27 —
// configureWithTransparentBackground + empty background image +
// backgroundColor .clear + clipsToBounds still left the system
// pill, and the b48 hideSystemBackground never shipped at all
// (the 0.0.2 binary contains no "BarBackground" literal — the
// helper never ran on device; and the mechanism was flawed
// anyway: updateUIView can run before UIKit creates
// _UIBarBackground, it only scans direct subviews, and iOS 27
// glass may be the bar's backgroundEffect, not a subview). Do
// NOT go back to hiding the system background.
//
// Layout contract (unchanged from the UITabBar version, Coda
// §6.2 — 64/52/8/16/6): the bar sits in the same VStack as the
// mini player in MainTabView's bottom safe-area inset, 16pt side
// margins, 6pt bottom margin, 8pt gap to the mini — the mini and
// the bar are TWO SEPARATE equal-width pills. The 5 tabs come
// from HaoTab.allCases in MainTabView's order:
// 首页/音乐/影视/直播/我的. Tab content switching stays in
// MainTabView (@State selection + content swap); this file owns
// only the bar itself. No TabView is used: the built-in tab bar
// cannot be replaced by a floating capsule.
//
// Selection (same values as the old selectionIndicatorImage):
// solid #E4E4E4 in light mode, solid #3A3A3C in dark mode, a
// 60×36 rounded pill behind the selected item. Selected icon +
// label: theme.tabSelected (black / white) or the user's chosen
// tab accent from Settings. Unselected: primary at 80%.
// No selection haptic: the UITabBar had none, so the bar keeps
// none (the full-player expand tick lives on the stack in
// MainTabView, untouched). Reselect (tap the already-selected
// tab) reports through onReselect, exactly as before.

import SwiftUI

/// One tab in the bar.
struct GlassTabBarItem: Identifiable {
    let tab: HaoTab
    let title: String
    let icon: String

    var id: HaoTab { tab }
}

struct GlassTabBar: View {
    let items: [GlassTabBarItem]
    @Binding var selection: HaoTab
    /// Called when the already-selected tab is tapped again.
    /// MainTabView posts `.haoTabReselected`; each tab root scrolls
    /// only its own list to the top.
    var onReselect: (HaoTab) -> Void = { _ in }
    /// Selected-tab colour override (S5-C): the user's chosen tab
    /// accent from Settings; nil keeps the theme default.
    var tabAccent: Color? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.haoTheme) private var theme

    /// The selected-item pill: solid #E4E4E4 (light) / #3A3A3C
    /// (dark), 60×36 — the old selectionIndicatorImage values.
    private var selectionPillColor: Color {
        colorScheme == .dark
            ? Color(red: 0x3A / 255, green: 0x3A / 255, blue: 0x3C / 255)
            : Color(red: 0xE4 / 255, green: 0xE4 / 255, blue: 0xE4 / 255)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let isSelected = item.tab == selection
                Button {
                    if isSelected {
                        onReselect(item.tab)
                    } else {
                        selection = item.tab
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: item.icon)
                            .font(.system(size: 22, weight: .regular))
                            .accessibilityHidden(true)
                        Text(item.title)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    }
                    .foregroundStyle(
                        isSelected
                            ? haoTabTint(tabAccent, scheme: colorScheme, fallback: theme.tabSelected)
                            : Color.primary.opacity(0.8)
                    )
                    // Selected pill behind the whole item (icon +
                    // label), 60×36 — the old indicator image size.
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(selectionPillColor)
                                .frame(width: 60, height: 36)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityLabel(item.title)
            }
        }
        .frame(height: HaoLayout.tabBarTotalHeight)
        .haoGlassRoundedRect()
    }
}

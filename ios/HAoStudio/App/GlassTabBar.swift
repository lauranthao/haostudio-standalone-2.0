// HAo Studio 2.0 — bottom tab bar.
//
// A SwiftUI glass bar (b38), NOT a system UITabBar any more. The
// system bar's default background rendered as a solid slab over the
// settings list (chen 2026-11-24: "实心白条" — the mini pure white,
// the menu light-grey solid), and its selection pill was a solid
// #E4E4E4 grey. The SwiftUI bar paints its own glass
// (HaoGlassCapsule: .glassEffect .regular on iOS 26+,
// .ultraThinMaterial below — the same treatment as the mini player),
// so content scrolled behind it blurs through, and the selection
// pill is the Apple Music pink, sliding between tabs on the
// settle spring.
//
// Layout contract (MainTabView.swift): this view sits in the bottom
// safe-area inset, in the same VStack as the mini player — spacing 0,
// so the mini's bottom edge touches the bar's top edge: one connected
// floating unit, same width, same margins (chen 2026-11-24 "你看布局
// 啊"). The 5 tabs come from HaoTab.allCases in MainTabView's order:
// 首页/音乐/影视/直播/我的. Tab content switching stays in MainTabView
// (@State selection + content swap); this file owns only the bar
// itself.
//
// Values copied from UnionTabView (MIT,
// github.com/unionst/union-tab-view — GlassTabBar.swift /
// AdaptiveTabBar.swift): capsule glass with 4pt inner padding
// INSIDE the glass, icon .title3, label 10pt medium, item content
// VStack spacing 4, sliding selection pill (here:
// matchedGeometryEffect + the settle spring; UnionTabView drives a
// UISegmentedControl track). iOS 26+ glassEffect / iOS 17–25 material
// fallback is the dual-track the R1 report records for Muzify /
// Kumone (the app's deployment target is iOS 17.0).
//
// Selection pill colour (chen 2026-11-24, via the Apple Music ref
// screenshot 0BB2AEAD): the selected tab is a PINK pill (#FA2D48,
// Apple Music red) with a BLUE glyph (#007AFF system blue) — that
// is literally what the reference renders; the old #E4E4E4 grey is
// gone, never purple. A custom tab accent from Settings overrides
// the pill (through the haoTabTint guard — a near-invisible pick
// falls back to the theme accent instead of vanishing) and the
// glyph on it is haoOnAccentFor (white on dark accents, near-black
// on light ones). Unselected tabs are theme.textSecondary.

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
    @Namespace private var selectionPill

    /// Apple Music's selection treatment, copied from chen's
    /// reference screenshot (0BB2AEAD): a pink pill (#FA2D48)
    /// with a blue glyph (#007AFF). This is the default — a custom
    /// tab accent from Settings overrides the pill (guarded by
    /// haoTabTint so a near-invisible pick falls back to the theme
    /// accent instead of vanishing).
    private static let appleMusicPill = Color(red: 0.98, green: 0.18, blue: 0.28)
    private static let appleMusicGlyph = Color(red: 0.0, green: 0.48, blue: 1.0)

    /// The selection pill fill: Apple Music pink by default; the
    /// user's custom tab accent when one is set.
    private var pillColor: Color {
        guard let tabAccent else { return Self.appleMusicPill }
        return haoTabTint(tabAccent, scheme: colorScheme, fallback: theme.accent)
    }

    /// The glyph colour on the pill: Apple Music blue by default;
    /// on a custom accent, the legible on-accent colour.
    private var selectedGlyphColor: Color {
        guard tabAccent != nil else { return Self.appleMusicGlyph }
        return haoOnAccentFor(pillColor)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                tabButton(item)
            }
        }
        .frame(height: HaoLayout.tabBarContentHeight)
        // UnionTabView: the 4pt inner padding is INSIDE the glass —
        // the padding is part of the capsule, not dead space below
        // it (the old system bar padded outside the clip, which
        // left 4pt of nothing under the visible bar and pushed it
        // 6pt above the home-indicator zone).
        .padding(.vertical, HaoLayout.tabBarInnerInset)
        .padding(.horizontal, HaoLayout.tabBarInnerInset)
        .haoGlassCapsule()
        // The pill slides on the settle spring when the selection
        // changes; the haptic is the bar's own (the old system bar
        // emitted none).
        .animation(HaoLayout.settleSpring, value: selection)
        .haoSensoryFeedback(.selection, trigger: selection)
    }

    /// One tab: icon (.title3) over label (10pt medium), UnionTabView
    /// sizes. The selected tab carries the accent pill behind its
    /// content; tapping the selected tab reselected instead of
    /// switching (chrome O1: scroll-to-top).
    private func tabButton(_ item: GlassTabBarItem) -> some View {
        let isSelected = item.tab == selection
        return Button {
            if isSelected {
                onReselect(item.tab)
            } else {
                selection = item.tab
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: item.icon)
                    .font(.title3)
                Text(item.title)
                    .font(.haoTabLabel)
            }
            .foregroundStyle(
                isSelected ? selectedGlyphColor : theme.textSecondary
            )
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background {
                if isSelected {
                    Capsule()
                        .fill(pillColor)
                        .matchedGeometryEffect(id: "haoTabSelectionPill", in: selectionPill)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

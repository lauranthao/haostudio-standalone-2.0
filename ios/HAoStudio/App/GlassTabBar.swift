// HAo Studio 2.0 — bottom tab bar.
//
// This is a REAL system UITabBar (UIKit), hosted in SwiftUI through a
// UIViewRepresentable. It is NOT a hand-drawn capsule: there is no
// floating glass capsule, no sliding pill view, no drag-to-switch-tabs,
// no settle spring. Tab switching, selection state, VoiceOver and
// haptics are all the system's own behaviour.
//
// Layout contract (MainTabView.swift, untouched): this view sits in the
// bottom safe-area inset, in the same VStack as the mini player — the
// mini player is the row above the bar, so the two can never overlap
// and the mini player never appears twice. The 5 tabs come from
// HaoTab.allCases in MainTabView's order: 首页/音乐/影视/直播/我的.
// Tab content switching stays in MainTabView (@State selection +
// content swap); this file owns only the bar itself.
//
// Glass:
// - iOS 26+: the system tab bar is Liquid Glass from its default
//   background (configureWithDefaultBackground()). No effect is assigned
//   explicitly: UITabBarAppearance.backgroundEffect only accepts
//   UIBlurEffect, so a glass effect cannot go there. No custom opaque
//   background is painted over it: a custom background would overlay
//   and kill the glass (Apple: "Any custom backgrounds and appearances
//   you use in these elements might overlay or interfere with Liquid
//   Glass"). isTranslucent stays true for the same reason.
// - iOS 17–25: configureWithDefaultBackground() — the classic
//   translucent frosted-glass bar. Deployment target is 17.0.
//
// Selection pill (UITabBar.selectionIndicatorImage):
// - Solid #E4E4E4 in light mode, solid #3A3A3C in dark mode.
//   Never black, never faint.
// - Selected icon + label: theme.tabSelected — BLACK (light) / white
//   (dark) in all four themes. Never red, never the theme accent.
// - Unselected: primary at 80%, as before.

import SwiftUI
import UIKit

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
    /// Called when the already-selected tab is tapped again. Foundation:
    /// no-op (placeholder pages have nothing to scroll to top yet).
    var onReselect: (HaoTab) -> Void = { _ in }
    /// Selected-tab colour override (S5-C): the user's chosen tab
    /// accent from Settings; nil keeps the theme default.
    var tabAccent: Color? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.haoTheme) private var theme

    var body: some View {
        SystemTabBar(
            items: items,
            selection: $selection,
            onReselect: onReselect,
            theme: theme,
            colorScheme: colorScheme,
            tabAccent: tabAccent
        )
        .frame(height: HaoLayout.tabBarContentHeight)
        // Vertical inner inset only (4 top / 4 bottom; total 64pt).
        // Horizontal padding used to be here too, but the system
        // tab bar paints its background over its own frame, so it
        // shrank the visible bar 4pt per side — the bar read 8pt
        // narrower than the mini player above it (chen 2026-11-24
        // build 33: mini must be exactly as wide as the bar).
        // Beans pads all sides only because its capsule background
        // is painted OVER the padded area. The visible bar now spans
        // exactly the mini player's width (screen minus the shared
        // 12pt side margins in MainTabView).
        .padding(.vertical, HaoLayout.tabBarInnerInset)
    }
}

/// The minimized tab bar: one small glass capsule showing only the
/// current tab (iOS 26 Music: scroll down and the bar tucks into a
/// capsule while the mini tray slides down beside it). Same glass,
/// same 12pt radius and same side margins as the full bar, so the
/// minimized row reads as the same unit, not a different component.
/// The selected colour is the same as the full bar's (the user's tab
/// accent from Settings, else theme.tabSelected — never red, never
/// the theme accent by default).
///
/// Interaction (Apple's minimized-bar behaviour, hand-rolled):
/// - Quick tap: expand the full tab bar again (scrolling up does
///   the same — the capsule is never a dead end).
/// - Long-press, then drag horizontally: switch tabs, one tab per
///   64pt of drag, with a selection tick per step. The drag and the
///   tap share ONE sequenced gesture, so a long-press can never
///   also fire a tap on release: a touch that ends before the dwell
///   is the tap, a held touch is the start of a drag.
struct MinimizedTabCapsule: View {
    @Binding var selection: HaoTab
    /// Selected-tab colour override (S5-C): the user's chosen tab
    /// accent from Settings; nil keeps the theme default.
    var tabAccent: Color? = nil

    @EnvironmentObject private var bottomChrome: BottomChromeState
    @Environment(\.haoTheme) private var theme

    /// Index the tab drag started from (nil = not dragging).
    @State private var dragBaseIndex: Int? = nil

    private var selectedColor: Color {
        tabAccent ?? theme.tabSelected
    }

    var body: some View {
        let tab = selection
        HStack(spacing: 6) {
            Image(systemName: tab.icon)
                .font(.haoSectionTitle)
            Text(tab.title)
                .font(.haoFootnoteStrong)
                .lineLimit(1)
        }
        .foregroundStyle(selectedColor)
        .frame(height: HaoLayout.tabBarContentHeight)
        .padding(.horizontal, 16)
        .haoGlassRoundedRect()
        .scaleEffect(dragBaseIndex != nil ? 0.96 : 1)
        .animation(HaoLayout.settleSpring, value: dragBaseIndex != nil)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityLabel("当前标签：\(tab.title)，点按展开菜单栏，长按滑动切换标签")
        .gesture(
            LongPressGesture(minimumDuration: HaoLayout.minimizedCapsuleLongPressDuration)
                .sequenced(before: DragGesture(minimumDistance: 4, coordinateSpace: .local))
                .onChanged { value in
                    switch value {
                    case .first(true):
                        // Long-press recognised: the drag starts here.
                        dragBaseIndex = HaoTab.allCases.firstIndex(of: selection)
                    case .second(true, let drag):
                        guard let base = dragBaseIndex,
                              let drag else { return }
                        let step = Int((drag.translation.width / HaoLayout.minimizedCapsuleTabStep).rounded())
                        let next = min(max(base + step, 0), HaoTab.allCases.count - 1)
                        if let current = HaoTab.allCases.firstIndex(of: selection),
                           next != current {
                            selection = HaoTab.allCases[next]
                        }
                    default:
                        break
                    }
                }
                .onEnded { value in
                    // A touch that ends before the long-press dwell is
                    // a tap: expand the bar again. A held long-press
                    // without dragging, or a finished drag, ends here
                    // without expanding.
                    if case .first(false) = value {
                        bottomChrome.expand()
                    }
                    dragBaseIndex = nil
                }
        )
    }
}

/// The system UITabBar, bridged into SwiftUI.
///
/// A bare UITabBar (not a UITabBarController): MainTabView owns the tab
/// content and switches it by @State, so no view-controller ownership
/// is needed here — the bar is a control, not a container.
private struct SystemTabBar: UIViewRepresentable {
    let items: [GlassTabBarItem]
    @Binding var selection: HaoTab
    var onReselect: (HaoTab) -> Void
    let theme: HaoThemePalette
    let colorScheme: ColorScheme
    var tabAccent: Color? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITabBar {
        let tabBar = UITabBar()
        tabBar.delegate = context.coordinator
        // Translucent: the glass (iOS 26) / blur (iOS 17–25) must show
        // the content behind the bar. Setting this false would turn the
        // bar into a flat opaque slab.
        tabBar.isTranslucent = true
        return tabBar
    }

    func updateUIView(_ tabBar: UITabBar, context: Context) {
        // Keep the coordinator's copy fresh: it is created once, and the
        // struct snapshot it was born with goes stale after the first
        // selection change.
        context.coordinator.items = items
        context.coordinator.selection = $selection
        context.coordinator.onReselect = onReselect

        // Items, in the order MainTabView defines them. Titles + SF
        // Symbols come from HaoTab, so the bar can never drift from the
        // tab definitions.
        tabBar.items = items.enumerated().map { offset, item in
            UITabBarItem(
                title: item.title,
                image: UIImage(systemName: item.icon),
                tag: offset
            )
        }

        // Selected item follows the SwiftUI binding. Setting selectedItem
        // directly does not call the delegate, so this cannot loop.
        if let index = items.firstIndex(where: { $0.tab == selection }) {
            tabBar.selectedItem = tabBar.items?[index]
        }

        // Selected icon + label: theme.tabSelected (black / white).
        // Never red, never the theme accent.
        tabBar.tintColor = tabAccent.map(UIColor.init) ?? UIColor(theme.tabSelected)
        // Unselected: primary at 80%.
        tabBar.unselectedItemTintColor = UIColor.label.withAlphaComponent(0.8)

        // Selection pill: solid #E4E4E4 (light) / #3A3A3C (dark).
        // Never black, never faint.
        tabBar.selectionIndicatorImage = Self.selectionPillImage(for: colorScheme)

        Self.configureAppearance(for: tabBar)
    }

    /// Bar background: glass on iOS 26, classic blur below.
    ///
    /// No explicit effect is assigned: `UITabBarAppearance.backgroundEffect`
    /// only accepts `UIBlurEffect` (assigning `UIGlassEffect()` fails to
    /// compile), and the system tab bar on iOS 26 already renders with
    /// Liquid Glass from its default background. No backgroundColor and
    /// no backgroundImage are set — either would paint over the glass.
    private static func configureAppearance(for tabBar: UITabBar) {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
    }

    /// Stretchable solid pill for the selected tab.
    ///
    /// #E4E4E4 in light mode, #3A3A3C in dark mode — opaque, solid.
    /// Never black, never faint (the old capsule used black @ 7.5% /
    /// white @ 10%, which read as a smudge, not a selection).
    /// Cap insets keep the semicircular ends intact while the middle
    /// stretches to the tab's width.
    private static func selectionPillImage(for colorScheme: ColorScheme) -> UIImage {
        let color: UIColor
        if colorScheme == .dark {
            // #3A3A3C, opaque.
            color = UIColor(red: 0x3A / 255, green: 0x3A / 255, blue: 0x3C / 255, alpha: 1)
        } else {
            // #E4E4E4, opaque.
            color = UIColor(red: 0xE4 / 255, green: 0xE4 / 255, blue: 0xE4 / 255, alpha: 1)
        }
        let size = CGSize(width: 60, height: 36)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let path = UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: size),
                cornerRadius: size.height / 2
            )
            color.setFill()
            path.fill()
        }
        let inset = UIEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        return image.resizableImage(withCapInsets: inset, resizingMode: .stretch)
    }

    /// UITabBarDelegate: taps go back to the SwiftUI binding. Tapping
    /// the already-selected tab reports a reselect instead of a switch.
    final class Coordinator: NSObject, UITabBarDelegate {
        var items: [GlassTabBarItem] = []
        var selection: Binding<HaoTab> = .constant(.home)
        var onReselect: (HaoTab) -> Void = { _ in }

        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
            guard let index = tabBar.items?.firstIndex(where: { $0 === item }),
                  index < items.count
            else { return }
            let tab = items[index].tab
            if tab == selection.wrappedValue {
                onReselect(tab)
            } else {
                selection.wrappedValue = tab
            }
        }
    }
}

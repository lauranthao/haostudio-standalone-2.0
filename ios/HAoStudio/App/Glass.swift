// HAo Studio 2.0 — shared glass system.
//
// Native liquid glass: iOS 26+ uses `.glassEffect`; iOS 17–25 falls back
// to the regular frosted-glass material (`.ultraThinMaterial` / UIBlurEffect
// equivalent). The fallback is a real material, not a solid colour, so the
// app still reads as frosted glass on older systems.
//
// Sizing / spring values (spring response 0.35, dampingFraction 0.82;
// stroke white 0.22 light / 0.08 dark, 0.5pt; shadow black 0.10 / 0.28,
// radius 12, y 4; bottomMargin 6; content height 56 + 4pt inset).
//
// b49phase1 P6: the non-glass helpers that used to live here
// (HaoLayout, HaoPlayerMotion, BottomChromeState + scroll
// anchors, SettingsDeepLink, the haptics gate) moved to their
// own files in this directory — same target, same names,
// same visibility. This file keeps only the glass system
// (modifiers, shadow scale, backdrop, dark glass).

import SwiftUI
import Combine
import UIKit

/// One shadow scale (b49phase1 P3): every floating shadow in the
/// app is one of these three, or a documented deliberate exception
/// at its site. The VALUES are the pre-existing ones — only their
/// provenance changed, never their appearance:
/// - floating: the shared glass shadow (black 0.10 light / 0.28
///   dark, radius 12, y 4) — the glass pills (tab bar, mini).
/// - card: black 0.15, radius 8, y 4 — floating cards / toasts.
/// - small: black 0.15, radius 4, y 1 — small floating elements.
/// Deliberate exceptions (each carries its reason at its site):
/// drag-progress shadows (HaoDragSidebar), danmaku text outlines
/// (LiveDanmakuView, VodDanmakuLayer), the player cover's
/// state shadow + scrubber knob + karaoke glow (MusicPlayerView),
/// the radio hero / accent glows (MusicRadio), the large-cover
/// shadow (MusicRowViews).
enum HaoShadow {
    case floating
    case card
    case small
}

private struct HaoShadowModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var style: HaoShadow

    func body(content: Content) -> some View {
        switch style {
        case .floating:
            content.shadow(
                color: .black.opacity(colorScheme == .dark ? 0.28 : 0.10),
                radius: 12, y: 4
            )
        case .card:
            content.shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        case .small:
            content.shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        }
    }
}

extension View {
    /// Apply one of the three shared shadows (b49phase1 P3).
    /// Same position as a plain `.shadow(...)` — order preserved.
    func haoShadow(_ style: HaoShadow) -> some View {
        modifier(HaoShadowModifier(style: style))
    }
}

/// A capsule with native liquid glass on iOS 26+, regular frosted glass
/// below. Stroke + shadow are shared by both paths so the two look like
/// the same component, not two different bars.
/// b49phase1 P1: on iOS 26+ the glass takes `.regular.tint(theme.glassTint)`
/// — the Settings glass-intensity slider now drives the pill itself
/// (white 0 at 1.0 = today's glass, 0.35 at 0.3). iOS 17–25 keeps the
/// material fallback; the slider there moves surface / surfaceStrong only.
struct HaoGlassCapsule: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.haoTheme) private var theme

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular.tint(theme.glassTint), in: Capsule())
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
        .haoShadow(.floating)
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
/// b49phase1 P1: same intensity tint as the capsule
/// (`.regular.tint(theme.glassTint)` on iOS 26+).
struct HaoGlassRoundedRectangle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.haoTheme) private var theme

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: HaoLayout.floatingChromeCornerRadius,
            style: .continuous
        )
    }

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular.tint(theme.glassTint), in: shape)
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
        .haoShadow(.floating)
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

    /// b49fix3 B12: veil strength by scheme (see the note at the
    /// gradient). Dark needs the strong veil for AA on a white
    /// wallpaper; light already passes at the b49fix2 values.
    private var veilTop: CGFloat { theme.colorScheme == .dark ? 0.92 : 0.72 }
    private var veilBottom: CGFloat { theme.colorScheme == .dark ? 0.90 : 0.58 }

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
                // Legibility veil (b42, strengthened b49fix2 #34,
                // b49fix3 B12): scaffold colour (near-white light
                // mode, black dark mode) as a top-to-bottom gradient
                // — the titles at the top get the strongest veil,
                // the cards below get a lighter one. The b42 values
                // (0.55 / 0.42) still washed song rows out on busy
                // photos (chen build 42: grey subtitle text unreadable);
                // the stronger veil keeps rows legible while the
                // photo still shows through everywhere. The text
                // and the semi-transparent cards just stop fighting it.
                //
                // b49fix3 B12: the dark veil is scheme-dependent.
                // Light mode keeps 0.72 / 0.58 — all four light
                // themes already pass AA 4.5:1 on a pure-white
                // wallpaper. Dark mode needs 0.92 / 0.90: the exact
                // WCAG computation (harness b12-contrast.py) shows
                // the dimmest dark muted (gold #9A8B6B) needs >=
                // 0.895 at the bottom to clear 4.5:1 on white —
                // 0.88 leaves it at 4.00. The wallpaper still shows
                // through (8-10%). The muted text that used to sit
                // below AA on the translucent white cards (the
                // three search-entry placeholders, 3.6-4.1:1) is
                // fixed by ROLE, not by a stronger veil — no veil
                // can fix those, the white card lift dominates:
                // b49fix4 moved the placeholder texts to
                // textSecondary and b49phase1 P5 moved the three
                // entry magnifier icons (plus Emby's) to
                // textSecondary too (7.4:1+ everywhere on the
                // entry background). No text value was changed here.
                LinearGradient(
                    colors: [
                        theme.scaffoldBackground.opacity(veilTop),
                        theme.scaffoldBackground.opacity(veilBottom),
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
/// b49phase1 P1: same intensity tint as the capsule
/// (`.regular.tint(theme.glassTint)` on iOS 26+).
struct HaoGlassCircle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.haoTheme) private var theme

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular.tint(theme.glassTint), in: Circle())
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

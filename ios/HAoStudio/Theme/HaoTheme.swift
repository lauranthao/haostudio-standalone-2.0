// HAo Studio 2.0 — theme system (Swift native).
//
// 4 themes x light/dark = 8 combinations. Colour VALUES are copied from the
// Flutter build-31 baseline (lib/core/theme/hao_themes.dart, HEAD 2ef902b,
// 1.1.6+31); the STRUCTURE is Swift-native (a plain value type + an
// EnvironmentKey), not a translation of the Flutter ThemeExtension.
// S0 fixed the four light-mode textMuted values to the build-31 WCAG
// contrast values (the scaffold had copied the pre-fix baseline).
//
// Standing rules (chen 2026-11-16, iron law):
// - No hardcoded colours at call sites: every view reads the palette from
//   the environment (`.haoTheme`), never a literal Color.
// - NO purple anywhere in any theme.
// - Red appears ONLY where it truly means something: the LIVE badge and
//   the recording dot (`liveRed`). Buttons / active states use `accent`,
//   never saturated red. On-video buttons use `accentOnVideo` (the accent,
//   white fallback on black — a black accent is invisible on video).
// - Blue accents are black (chen 2026-11-18): the two blue/cyan accents
//   (appleGlass, polarIce) are black in light mode and dark grey #76767A
//   in dark mode (black-on-black would be invisible). Gold and mint
//   accents are not blue and are unchanged.
// - Higher transparency: glass surfaces are low-alpha + strong blur;
//   readability comes from blur, never from darkening the background.

import SwiftUI
import UIKit

/// The four HAo Studio themes.
enum HaoThemeID: String, CaseIterable, Identifiable {
    case appleGlass
    case darkGold
    case freshMint
    case polarIce

    var id: String { rawValue }

    /// Display name (matches the Flutter baseline).
    var displayName: String {
        switch self {
        case .appleGlass: return "苹果毛玻璃"
        case .darkGold: return "暗夜鎏金"
        case .freshMint: return "清新薄荷"
        case .polarIce: return "极夜冰蓝"
        }
    }
}

/// Frosted-glass + semantic colours for one theme/mode combination.
/// (No Equatable: SwiftUI Color is not Equatable, and nothing compares
/// palettes — the store republishes instead.)
struct HaoThemePalette {
    /// Sophisticated theme accent for buttons / active states (never red).
    let accent: Color
    /// Foreground on a filled accent surface.
    let onAccent: Color
    /// Low-alpha accent wash (selected rows, progress fill background).
    let accentSoft: Color
    /// Frosted-glass surface: LOW alpha + strong blur.
    let surface: Color
    /// Slightly less transparent glass (sheets, player).
    let surfaceStrong: Color
    /// Opaque surface for places glass cannot be used.
    let surfaceSolid: Color
    /// Hairline divider / border colour.
    let hairline: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    /// The ONLY red in the app: LIVE badge + recording dot.
    let liveRed: Color
    /// Backdrop blur sigma for frosted glass.
    let glassBlurSigma: CGFloat
    let scaffoldBackground: Color
    let colorScheme: ColorScheme
    /// Tab-bar selected-item colour. Chen's rule: selected is BLACK, not
    /// red and not the theme accent. In dark mode black on dark
    /// glass is invisible, so the dark counterpart is white — the same
    /// readability reasoning the Flutter baseline uses for its dark
    /// accents (#76767A instead of black).
    let tabSelected: Color

    /// Accent as rendered on black video: the accent itself, or white
    /// when the accent is black / near-black (invisible on video).
    /// On-video buttons use this; on-scaffold controls use `accent`.
    var accentOnVideo: Color { haoAccentOnBlack(accent) }

    /// S5-A: apply the settings-owned overrides on top of a resolved
    /// base palette, without touching the base values:
    /// - glassIntensity scales the glass: `surface` / `surfaceStrong`
    ///   alpha (Color.opacity multiplies the existing alpha) and
    ///   `glassBlurSigma`. 1.0 = today's full glass.
    /// - accentOverride replaces `accent` (both modes); `accentSoft`
    ///   is the override at 0.14 alpha and `onAccent` follows the
    ///   Flutter `_onAccentFor` rule (white on dark accents,
    ///   near-black on light ones). liveRed, text colours and
    ///   surfaces never move — only accent-role usages do (same
    ///   rule as Flutter `HaoThemes.of(accentOverride:)`).
    func applying(glassIntensity: Double, accentOverride: Color?) -> HaoThemePalette {
        let intensity = min(1.0, max(0.3, glassIntensity))
        let accent = accentOverride ?? self.accent
        let onAccent = accentOverride == nil ? self.onAccent : haoOnAccentFor(accent)
        return HaoThemePalette(
            accent: accent,
            onAccent: onAccent,
            accentSoft: accent.opacity(0.14),
            surface: surface.opacity(intensity),
            surfaceStrong: surfaceStrong.opacity(intensity),
            surfaceSolid: surfaceSolid,
            hairline: hairline,
            textPrimary: textPrimary,
            textSecondary: textSecondary,
            textMuted: textMuted,
            liveRed: liveRed,
            glassBlurSigma: glassBlurSigma * CGFloat(intensity),
            scaffoldBackground: scaffoldBackground,
            colorScheme: colorScheme,
            tabSelected: tabSelected
        )
    }

    /// All four themes, each with light + dark. No purple anywhere.
    static func palette(for id: HaoThemeID, scheme: ColorScheme) -> HaoThemePalette {
        let liveRed = Color(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255)
        switch (id, scheme) {
        case (.appleGlass, .light):
            return HaoThemePalette(
                accent: .black, onAccent: .white,
                accentSoft: Color.black.opacity(0.14),
                surface: Color.white.opacity(0.55),
                surfaceStrong: Color.white.opacity(0.68),
                surfaceSolid: .white,
                hairline: Color.black.opacity(0.08),
                textPrimary: Color(hex: 0x1C1C1E), textSecondary: Color(hex: 0x3A3A3C),
                textMuted: Color(hex: 0x6B6B70),
                liveRed: liveRed, glassBlurSigma: 24,
                scaffoldBackground: Color(hex: 0xF2F2F7),
                colorScheme: .light, tabSelected: .black)
        case (.appleGlass, .dark):
            return HaoThemePalette(
                accent: Color(hex: 0x76767A), onAccent: .white,
                accentSoft: Color(hex: 0x76767A).opacity(0.14),
                surface: Color.white.opacity(0.10),
                surfaceStrong: Color.white.opacity(0.16),
                surfaceSolid: Color(hex: 0x1C1C1E),
                hairline: Color.white.opacity(0.12),
                textPrimary: Color(hex: 0xF5F5F7), textSecondary: Color(hex: 0xD1D1D6),
                textMuted: Color(hex: 0x98989D),
                liveRed: liveRed, glassBlurSigma: 24,
                scaffoldBackground: .black,
                colorScheme: .dark, tabSelected: .white)
        case (.darkGold, .light):
            return HaoThemePalette(
                accent: Color(hex: 0x9A7B1E), onAccent: .white,
                accentSoft: Color(hex: 0x9A7B1E).opacity(0.14),
                surface: Color.white.opacity(0.55),
                surfaceStrong: Color.white.opacity(0.68),
                surfaceSolid: Color(hex: 0xFFFDF5),
                hairline: Color(hex: 0x9A7B1E).opacity(0.18),
                textPrimary: Color(hex: 0x2A2113), textSecondary: Color(hex: 0x5C4F33),
                textMuted: Color(hex: 0x7A6C4E),
                liveRed: liveRed, glassBlurSigma: 24,
                scaffoldBackground: Color(hex: 0xFAF6EC),
                colorScheme: .light, tabSelected: .black)
        case (.darkGold, .dark):
            return HaoThemePalette(
                accent: Color(hex: 0xD4AF37), onAccent: Color(hex: 0x0B0B0F),
                accentSoft: Color(hex: 0xD4AF37).opacity(0.14),
                surface: Color.white.opacity(0.08),
                surfaceStrong: Color.white.opacity(0.14),
                surfaceSolid: Color(hex: 0x1D1A14),
                hairline: Color(hex: 0xD4AF37).opacity(0.22),
                textPrimary: Color(hex: 0xF5EDD6), textSecondary: Color(hex: 0xD8C9A3),
                textMuted: Color(hex: 0x9A8B6B),
                liveRed: liveRed, glassBlurSigma: 24,
                scaffoldBackground: Color(hex: 0x0D0B08),
                colorScheme: .dark, tabSelected: .white)
        case (.freshMint, .light):
            return HaoThemePalette(
                accent: Color(hex: 0x00897B), onAccent: .white,
                accentSoft: Color(hex: 0x00897B).opacity(0.14),
                surface: Color.white.opacity(0.55),
                surfaceStrong: Color.white.opacity(0.68),
                surfaceSolid: .white,
                hairline: Color(hex: 0x00897B).opacity(0.14),
                textPrimary: Color(hex: 0x122E29), textSecondary: Color(hex: 0x3D5A54),
                textMuted: Color(hex: 0x58746D),
                liveRed: liveRed, glassBlurSigma: 24,
                scaffoldBackground: Color(hex: 0xEFFAF6),
                colorScheme: .light, tabSelected: .black)
        case (.freshMint, .dark):
            return HaoThemePalette(
                accent: Color(hex: 0x4DD0C4), onAccent: Color(hex: 0x0B0B0F),
                accentSoft: Color(hex: 0x4DD0C4).opacity(0.14),
                surface: Color.white.opacity(0.09),
                surfaceStrong: Color.white.opacity(0.15),
                surfaceSolid: Color(hex: 0x122622),
                hairline: Color.white.opacity(0.12),
                textPrimary: Color(hex: 0xE6F7F3), textSecondary: Color(hex: 0xB9D9D2),
                textMuted: Color(hex: 0x7FA39B),
                liveRed: liveRed, glassBlurSigma: 24,
                scaffoldBackground: Color(hex: 0x07110F),
                colorScheme: .dark, tabSelected: .white)
        case (.polarIce, .light):
            return HaoThemePalette(
                accent: .black, onAccent: .white,
                accentSoft: Color.black.opacity(0.14),
                surface: Color.white.opacity(0.55),
                surfaceStrong: Color.white.opacity(0.68),
                surfaceSolid: .white,
                hairline: Color.black.opacity(0.14),
                textPrimary: Color(hex: 0x0F2436), textSecondary: Color(hex: 0x3A5568),
                textMuted: Color(hex: 0x4F6E84),
                liveRed: liveRed, glassBlurSigma: 24,
                scaffoldBackground: Color(hex: 0xEEF6FB),
                colorScheme: .light, tabSelected: .black)
        case (.polarIce, .dark):
            return HaoThemePalette(
                accent: Color(hex: 0x76767A), onAccent: .white,
                accentSoft: Color(hex: 0x76767A).opacity(0.14),
                surface: Color.white.opacity(0.08),
                surfaceStrong: Color.white.opacity(0.14),
                surfaceSolid: Color(hex: 0x0E1E2E),
                hairline: Color.white.opacity(0.20),
                textPrimary: Color(hex: 0xE8F4FC), textSecondary: Color(hex: 0xB4D2E6),
                textMuted: Color(hex: 0x7D9BB0),
                liveRed: liveRed, glassBlurSigma: 24,
                scaffoldBackground: Color(hex: 0x050B12),
                colorScheme: .dark, tabSelected: .white)
        default:
            // Unreachable in practice — ColorScheme is a struct, so the
            // compiler cannot prove the 8 cases exhaustive. Fall back to
            // the appleGlass light palette.
            return HaoThemePalette(
                accent: .black, onAccent: .white,
                accentSoft: Color.black.opacity(0.14),
                surface: Color.white.opacity(0.55),
                surfaceStrong: Color.white.opacity(0.68),
                surfaceSolid: .white,
                hairline: Color.black.opacity(0.08),
                textPrimary: Color(hex: 0x1C1C1E), textSecondary: Color(hex: 0x3A3A3C),
                textMuted: Color(hex: 0x6B6B70),
                liveRed: liveRed, glassBlurSigma: 24,
                scaffoldBackground: Color(hex: 0xF2F2F7),
                colorScheme: .light, tabSelected: .black)
        }
    }
}

extension Color {
    /// Opaque 0xRRGGBB (alpha 1.0), matching the Flutter `Color(0xFF......)` literals.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// ARGB 0xAARRGGBB, matching the Flutter `Color(int)` value the
    /// settings sheet stores under `hao_tabbar_accent` (the pick
    /// keeps its opacity; the theme takes the opaque form).
    init(argb: UInt32) {
        self.init(
            red: Double((argb >> 16) & 0xFF) / 255,
            green: Double((argb >> 8) & 0xFF) / 255,
            blue: Double(argb & 0xFF) / 255,
            opacity: Double((argb >> 24) & 0xFF) / 255
        )
    }

    /// The opaque form of this colour (alpha forced to 0xFF), the
    /// form the theme accent uses. Only valid for colours built
    /// from an ARGB int; other colours keep their components.
    var opaqueARGB: UInt32 {
        let ui = UIColor(self)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = UInt32((r * 255).rounded())
        let gi = UInt32((g * 255).rounded())
        let bi = UInt32((b * 255).rounded())
        return (0xFF << 24) | (ri << 16) | (gi << 8) | bi
    }
}

/// Hue guard (Flutter `clampAccentHue`, P1-U6): no purple/magenta
/// custom accent. Hues in the 260°–320° band clamp to the 260° blue
/// boundary — the blue side (the 320° side is magenta-pink, so it
/// is not a landing spot). Applied wherever a custom accent is
/// stored or loaded, so a stored purple is corrected on next launch.
func haoClampAccentHue(_ color: Color) -> Color {
    let ui = UIColor(color)
    var h: CGFloat = 0
    var s: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return color }
    let degrees = h * 360
    if degrees > 260 && degrees < 320 {
        return Color(UIColor(hue: 260.0 / 360.0, saturation: s, brightness: b, alpha: a))
    }
    return color
}

/// ARGB form of the hue guard: same correction as
/// `haoClampAccentHue`, but the stored ALPHA is preserved — the
/// sheet stores the pick with its opacity, only the hue is wrong.
/// Returns the input unchanged when no correction applies.
func haoClampedAccentARGB(_ argb: UInt32) -> UInt32 {
    let clamped = haoClampAccentHue(Color(argb: argb))
    if clamped.opaqueARGB == Color(argb: argb).opaqueARGB { return argb }
    let alpha = argb & 0xFF000000
    return alpha | (clamped.opaqueARGB & 0x00FFFFFF)
}

/// Relative luminance of an sRGB colour (linearised sRGB, WCAG
/// weights) — the single source of truth for both helpers below.
/// Pure doubles, no UIKit: testable without a view.
func haoRelativeLuminance(red: Double, green: Double, blue: Double) -> Double {
    func linearised(_ c: Double) -> Double {
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linearised(red) + 0.7152 * linearised(green) + 0.0722 * linearised(blue)
}

/// Text/icon colour on top of a custom accent (Flutter
/// `_onAccentFor`): white on dark accents, near-black on light
/// ones. The light/dark split is Flutter's
/// `ThemeData.estimateBrightnessForColor` — relative luminance L
/// (linearised sRGB) with (L + 0.05)^2 > 0.15 meaning light.
func haoOnAccentFor(_ accent: Color) -> Color {
    let ui = UIColor(accent)
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return .white }
    let luminance = haoRelativeLuminance(red: Double(r), green: Double(g), blue: Double(b))
    let light = (luminance + 0.05) * (luminance + 0.05) > 0.15
    return light ? Color(hex: 0x0B0B0F) : .white
}

/// On-video accent (build 36, item 15): the theme accent, unless
/// it is invisible on black video. WCAG contrast of the accent vs
/// black >= 3:1 (large-text / non-text bar) -> the accent itself;
/// otherwise white. Only black / near-black accents fall back —
/// in the default theme (appleGlass light, accent = black) and
/// polarIce light the on-video buttons stay white, which IS the
/// legible rendering; the fix is visible in darkGold / freshMint
/// (both modes), in dark mode (grey), and with any custom accent
/// pick. A custom pick flows through the same `theme.accent`, so a
/// near-black pick also falls back to white automatically.
func haoAccentOnBlack(_ accent: Color) -> Color {
    let ui = UIColor(accent)
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return .white }
    let luminance = haoRelativeLuminance(red: Double(r), green: Double(g), blue: Double(b))
    let contrastVsBlack = (luminance + 0.05) / 0.05
    return contrastVsBlack >= 3 ? accent : .white
}

/// Tab-bar selected-item tint guard (build 36, item 8): a custom
/// tab accent is used as-is unless it is near-invisible on the
/// bar — near-white in light mode, near-black in dark mode. The
/// bar is translucent glass, so it is judged against white
/// (light) / black (dark). The bar is 1.5:1, deliberately lower
/// than the 3:1 on-video bar: it only rescues invisible picks,
/// never overrides a visible deliberate one — every preset
/// clears it (light: cyan 1.72 is the lowest; dark: grey 4.64
/// is the lowest), while pure white in light (1.00) and pure
/// black in dark (1.00) fall back to the theme's tabSelected
/// (black light / white dark). Nil accent (no custom pick) also
/// falls back.
func haoTabTint(_ accent: Color?, scheme: ColorScheme, fallback: Color) -> Color {
    guard let accent else { return fallback }
    let ui = UIColor(accent)
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return fallback }
    let luminance = haoRelativeLuminance(red: Double(r), green: Double(g), blue: Double(b))
    let contrast: Double
    if scheme == .dark {
        contrast = (luminance + 0.05) / 0.05
    } else {
        contrast = 1.05 / (luminance + 0.05)
    }
    return contrast >= 1.5 ? accent : fallback
}

// MARK: - Type scale (build 36, item 4)
//
// ONE type scale for the whole app. chen (2026-11-24): "app很多字体大小
// 都不一致" — the audit found 17 distinct point sizes (9–52pt) used
// ad hoc across 412 `.font(.system(size:))` call sites, with the same
// role set to different sizes on sibling screens (e.g. section headers
// at 18 / 20 / 22pt, row titles at 14 / 15 / 16pt, subtitles at
// 12 / 13 / 14pt).
//
// Source: the iOS 27.2.1 system Dynamic Type ramp, verified against
// Apple HIG (largeTitle 34, title1 28, title2 22, title3 20,
// headline 17 semibold, body 17, callout 16, subheadline 15,
// footnote 13, caption1 12, caption2 11). iOS 27 adds
// extraLargeTitle styles but leaves this ramp unchanged. Reference
// apps: 影视 VidHub (detail title 22, section 20), 音乐 Apple Music
// (row title 17 semibold, subtitle 13, mini 14/12), 直播 Pure Live
// (room title 17 semibold, dense lists 14), 设置 iOS system settings
// (row 17, group footer 13).
//
// Two deliberate off-ramp sizes, both pre-existing compromises kept
// on purpose:
// - 14pt (rowSubtitle / denseTitle / denseBody): the dominant subtitle
//   size in the app and the build-35 mini-player compromise (14/12 in
//   the 50pt strip, Apple Music's mini is 15/13 in a 64pt bar).
// - 10pt bold (badge): LIVE / quality badges and the live-room battery
//   readout only; the old 9pt battery text was bumped up to this floor.
//   Nothing else may use 10pt.
//
// The roles are FIXED sizes (`.system(size:weight:)`), matching the
// app's existing behaviour: every call site used fixed sizes, so no
// screen currently reflows for Dynamic Type. Switching the roles to
// SwiftUI text styles (`.headline`, `.body`, …) would newly scale text
// up to 3x at AX sizes and break fixed-height rows (56pt song rows,
// 50pt mini player, tab bar). That is a separate layout-hardening job
// — see the item-4 report — not something to smuggle into a size
// unification. Colours are untouched: every role still takes its
// colour from the theme palette (4 themes x light/dark).
//
// Rule for new code: never write `.font(.system(size:))` at a call
// site again — pick the role whose meaning matches the text.

extension Font {
    /// Screen hero / large title (iOS largeTitle 34). Live-room big
    /// play glyph and empty-state art use a literal size, not this.
    static let haoScreenTitle = Font.system(size: 34, weight: .bold)
    /// Navigation / page title (title1 28).
    static let haoPageTitle = Font.system(size: 28, weight: .bold)
    /// Album / artist / video-detail hero title (title2 22).
    static let haoDetailTitle = Font.system(size: 22, weight: .bold)
    /// Section header on every tab (title3 20). Was 18 / 20 / 22.
    static let haoSectionTitle = Font.system(size: 20, weight: .semibold)
    /// Emphasised body (headline 17 semibold): live-room title, quality
    /// / line sheet titles, "搜索历史" headers, the video play-button
    /// label. Song-row titles deliberately stay one step down at
    /// haoCalloutStrong (16 semibold — Apple Music's row value, see
    /// MusicRowViews) instead of this, so there is no separate
    /// 17-semibold card-title role.
    static let haoBodyStrong = Font.system(size: 17, weight: .semibold)
    /// Body text: Settings rows, paragraphs, Emby fields (body 17).
    static let haoBody = Font.system(size: 17)
    /// Primary action / chip label (callout 16 semibold).
    static let haoCalloutStrong = Font.system(size: 16, weight: .semibold)
    /// Secondary body (callout 16).
    static let haoCallout = Font.system(size: 16)
    /// Secondary title (subheadline 15 semibold).
    static let haoSubheadStrong = Font.system(size: 15, weight: .semibold)
    /// Secondary title, medium weight (subheadline 15 medium).
    /// Kept for segment / dense-list labels that were already medium.
    static let haoSubheadMedium = Font.system(size: 15, weight: .medium)
    /// Secondary body (subheadline 15).
    static let haoSubhead = Font.system(size: 15)
    /// Dense-list row title: live-room rows, player sheets, video
    /// player lists (14 semibold — the off-ramp size, see header).
    static let haoDenseTitle = Font.system(size: 14, weight: .semibold)
    /// Dense-list secondary / segment label (14 medium).
    static let haoDenseBody = Font.system(size: 14, weight: .medium)
    /// Row subtitle: song artist, video meta, splash / empty-state
    /// note (14 — the off-ramp size, see header). Was 12 / 13 / 14.
    static let haoRowSubtitle = Font.system(size: 14)
    /// Footnote label (footnote 13 semibold).
    static let haoFootnoteStrong = Font.system(size: 13, weight: .semibold)
    /// Footnote label, medium weight (13 medium).
    static let haoFootnoteMedium = Font.system(size: 13, weight: .medium)
    /// Footnote / secondary text (footnote 13). Was 12 / 13 / 14.
    static let haoFootnote = Font.system(size: 13)
    /// Caption label (caption1 12 semibold).
    static let haoCaptionStrong = Font.system(size: 12, weight: .semibold)
    /// Caption label, medium weight (12 medium).
    static let haoCaptionMedium = Font.system(size: 12, weight: .medium)
    /// Caption / metadata (caption1 12). Mini-player subtitle
    /// (build-35 compromise 14/12) lives here.
    static let haoCaption = Font.system(size: 12)
    /// Small label (caption2 11 semibold): quality badge, chart rank.
    static let haoCaption2Strong = Font.system(size: 11, weight: .semibold)
    /// Small metadata (caption2 11).
    static let haoCaption2 = Font.system(size: 11)
    /// Badge only: LIVE / quality badges, live-room battery readout
    /// (10 bold — the app's minimum; the old 9pt text was raised here).
    static let haoBadge = Font.system(size: 10, weight: .bold)
}

// MARK: - Environment

private struct HaoThemeKey: EnvironmentKey {
    // Default before the store loads: appleGlass light (same default as
    // the Flutter ThemeController).
    static let defaultValue = HaoThemePalette.palette(for: .appleGlass, scheme: .light)
}

extension EnvironmentValues {
    var haoTheme: HaoThemePalette {
        get { self[HaoThemeKey.self] }
        set { self[HaoThemeKey.self] = newValue }
    }
}

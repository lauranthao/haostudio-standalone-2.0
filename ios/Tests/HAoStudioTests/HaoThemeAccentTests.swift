// HAo Studio 2.0 — accent-on-video tests (build 36, item 15)
// + accent-as-text / LIVE-badge contrast tests (build 36
// follow-up D3).
//
// Drives haoAccentOnBlack / HaoThemePalette.accentOnVideo through
// all 8 theme/mode combinations plus custom picks, and checks the
// haoOnAccentFor text pairing for the pill fills. Pure colour
// math, no views, no network. Xcode test target HAoStudioTests,
// host app, @testable import HAoStudio.
//
// D3 note: the contrast math itself (`haoRelativeLuminance`,
// `haoContrastRatio`, `haoTextRGB`) is also run on Linux — the
// harness at ~/workspace/.tmp/b36fix/d3_harness.py extracts the
// PURE-CONTRAST block from HaoTheme.swift verbatim and asserts
// all 8 combinations there, because `swift test` cannot run on
// Linux (missing Apple-only modules) and these tests need macOS.

import SwiftUI
import XCTest

@testable import HAoStudio

final class HaoThemeAccentTests: XCTestCase {
    /// Opaque ARGB of a colour, for exact comparison (Color is not Equatable).
    private func argb(_ color: Color) -> UInt32 { color.opaqueARGB }

    /// WCAG contrast ratio between two colours, via the same
    /// `haoRelativeLuminance` the production code uses.
    private func contrast(_ fg: Color, _ bg: Color) -> Double {
        func lum(_ color: Color) -> Double {
            let ui = UIColor(color)
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
            return haoRelativeLuminance(red: Double(r), green: Double(g), blue: Double(b))
        }
        return haoContrastRatio(luminanceA: lum(fg), luminanceB: lum(bg))
    }

    /// All 8 theme/mode accents through accentOnVideo: black
    /// accents (appleGlass light, polarIce light) fall back to
    /// white — invisible on black video — the other six return
    /// the accent unchanged.
    func testAllEightAccentsThroughAccentOnVideo() {
        let cases: [(HaoThemeID, ColorScheme, UInt32, UInt32)] = [
            (.appleGlass, .light, 0xFF000000, 0xFFFFFFFF),
            (.appleGlass, .dark, 0xFF76767A, 0xFF76767A),
            (.darkGold, .light, 0xFF9A7B1E, 0xFF9A7B1E),
            (.darkGold, .dark, 0xFFD4AF37, 0xFFD4AF37),
            (.freshMint, .light, 0xFF00897B, 0xFF00897B),
            (.freshMint, .dark, 0xFF4DD0C4, 0xFF4DD0C4),
            (.polarIce, .light, 0xFF000000, 0xFFFFFFFF),
            (.polarIce, .dark, 0xFF76767A, 0xFF76767A),
        ]
        for (id, scheme, accentHex, videoHex) in cases {
            let palette = HaoThemePalette.palette(for: id, scheme: scheme)
            XCTAssertEqual(argb(palette.accent), accentHex, "\(id) \(scheme) accent")
            XCTAssertEqual(argb(palette.accentOnVideo), videoHex, "\(id) \(scheme) accentOnVideo")
        }
    }

    /// A near-black custom pick falls back to white, like the
    /// black per-theme accents.
    func testNearBlackCustomPickFallsBackToWhite() {
        XCTAssertEqual(argb(haoAccentOnBlack(Color(hex: 0x0A0A0A))), 0xFFFFFFFF)
    }

    /// A saturated custom pick keeps itself.
    func testSaturatedCustomPickKeepsItself() {
        XCTAssertEqual(argb(haoAccentOnBlack(Color(hex: 0x0A84FF))), 0xFF0A84FF)
    }

    /// A custom pick flows through the same theme.accent path the
    /// players read: applying(accentOverride:) + accentOnVideo.
    func testAccentOverrideFlowsThroughAccentOnVideo() {
        let base = HaoThemePalette.palette(for: .appleGlass, scheme: .light)
        let nearBlack = base.applying(glassIntensity: 1.0, accentOverride: Color(hex: 0x0A0A0A))
        XCTAssertEqual(argb(nearBlack.accentOnVideo), 0xFFFFFFFF)
        let saturated = base.applying(glassIntensity: 1.0, accentOverride: Color(hex: 0x0A84FF))
        XCTAssertEqual(argb(saturated.accentOnVideo), 0xFF0A84FF)
    }

    /// haoOnAccentFor text pairing for every pill fill: the
    /// helper must agree with the onAccent each palette stores.
    /// (Two light accents pair with near-black text — darkGold
    /// dark #D4AF37 and freshMint dark #4DD0C4 — the other six
    /// pair with white.)
    func testOnAccentForMatchesStoredOnAccentForAllEight() {
        for id in HaoThemeID.allCases {
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                let palette = HaoThemePalette.palette(for: id, scheme: scheme)
                XCTAssertEqual(
                    argb(haoOnAccentFor(palette.accent)), argb(palette.onAccent),
                    "\(id) \(scheme) onAccent")
            }
        }
        XCTAssertEqual(argb(haoOnAccentFor(Color(hex: 0xD4AF37))), 0xFF0B0B0F)
        XCTAssertEqual(argb(haoOnAccentFor(Color(hex: 0x4DD0C4))), 0xFF0B0B0F)
        XCTAssertEqual(argb(haoOnAccentFor(Color(hex: 0x00897B))), 0xFFFFFFFF)
    }

    /// The shared luminance math underneath both helpers.
    func testRelativeLuminance() {
        XCTAssertEqual(haoRelativeLuminance(red: 0, green: 0, blue: 0), 0, accuracy: 0.001)
        XCTAssertEqual(haoRelativeLuminance(red: 1, green: 1, blue: 1), 1, accuracy: 0.001)
        XCTAssertEqual(
            haoRelativeLuminance(
                red: Double(0x76) / 255, green: Double(0x76) / 255, blue: Double(0x7A) / 255),
            0.182, accuracy: 0.005)
        XCTAssertEqual(
            haoRelativeLuminance(
                red: Double(0xD4) / 255, green: Double(0xAF) / 255, blue: Double(0x37) / 255),
            0.449, accuracy: 0.005)
    }

    // MARK: - D3: accent as text + LIVE badge

    /// The four combinations whose accent already cleared 4.5:1
    /// keep the accent itself as text — no visual change where
    /// nothing was broken.
    func testAccentTextUnchangedWhereAccentAlreadyPasses() {
        let cases: [(HaoThemeID, ColorScheme)] = [
            (.appleGlass, .light), (.darkGold, .dark),
            (.freshMint, .dark), (.polarIce, .light),
        ]
        for (id, scheme) in cases {
            let palette = HaoThemePalette.palette(for: id, scheme: scheme)
            XCTAssertEqual(argb(palette.accentText), argb(palette.accent), "\(id) \(scheme)")
        }
    }

    /// Every combination's accent-as-text clears WCAG AA 4.5:1
    /// against BOTH opaque backgrounds text sits on (scaffold and
    /// solid). The four failing combinations move to the exact
    /// darker / lighter variant the harness computed (same hue,
    /// minimal move); the other four are covered by the test
    /// above.
    func testAccentTextMeetsWCAG45ForAllEight() {
        let adjusted: [(HaoThemeID, ColorScheme, UInt32)] = [
            (.appleGlass, .dark, 0xFF858589),
            (.darkGold, .light, 0xFF886C1A),
            (.freshMint, .light, 0xFF007E71),
            (.polarIce, .dark, 0xFF86868A),
        ]
        for (id, scheme, textHex) in adjusted {
            let palette = HaoThemePalette.palette(for: id, scheme: scheme)
            XCTAssertEqual(argb(palette.accentText), textHex, "\(id) \(scheme) accentText")
        }
        for id in HaoThemeID.allCases {
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                let palette = HaoThemePalette.palette(for: id, scheme: scheme)
                XCTAssertGreaterThanOrEqual(
                    contrast(palette.accentText, palette.scaffoldBackground), 4.5,
                    "\(id) \(scheme) accentText vs scaffold")
                XCTAssertGreaterThanOrEqual(
                    contrast(palette.accentText, palette.surfaceSolid), 4.5,
                    "\(id) \(scheme) accentText vs solid")
            }
        }
    }

    /// The LIVE badge: white text on liveRed. The red was
    /// darkened #E5484D -> #CE4145 (white was 3.91:1, now 4.70:1).
    func testLiveRedWhiteTextMeetsWCAG45() {
        let palette = HaoThemePalette.palette(for: .appleGlass, scheme: .light)
        XCTAssertEqual(argb(palette.liveRed), 0xFFCE4145)
        XCTAssertGreaterThanOrEqual(contrast(.white, palette.liveRed), 4.5)
    }

    /// A custom accent pick flows through `applying(...)` and its
    /// text variant follows: a failing pick is darkened to clear
    /// 4.5:1, a passing pick is kept as-is. (The failing pick
    /// lands on #846A1A here — appleGlass light's scaffold is
    /// slightly darker than darkGold's, so it darkens one step
    /// further than the #886C1A the darkGold palette itself uses.)
    func testAccentTextFollowsAccentOverride() {
        let base = HaoThemePalette.palette(for: .appleGlass, scheme: .light)
        let failing = base.applying(glassIntensity: 1.0, accentOverride: Color(hex: 0x9A7B1E))
        XCTAssertGreaterThanOrEqual(
            contrast(failing.accentText, failing.scaffoldBackground), 4.5)
        XCTAssertEqual(argb(failing.accentText), 0xFF846A1A)
        let passing = base.applying(glassIntensity: 1.0, accentOverride: Color(hex: 0x00695C))
        XCTAssertEqual(argb(passing.accentText), argb(passing.accent))
    }

    /// Item-15 acceptance numbers, unchanged by D3: accent vs
    /// black (black 1.00, grey 4.64, gold-light 5.23, gold-dark
    /// 9.99, teal-light 4.86, teal-dark 11.14), plus the tab-tint
    /// guard's rescue behaviour at the 1.5:1 bar.
    func testItem15AccentVsBlackNumbersUnchanged() {
        let cases: [(HaoThemeID, ColorScheme, Double)] = [
            (.appleGlass, .light, 1.00), (.appleGlass, .dark, 4.64),
            (.darkGold, .light, 5.23), (.darkGold, .dark, 9.99),
            (.freshMint, .light, 4.86), (.freshMint, .dark, 11.14),
            (.polarIce, .light, 1.00), (.polarIce, .dark, 4.64),
        ]
        for (id, scheme, expected) in cases {
            let palette = HaoThemePalette.palette(for: id, scheme: scheme)
            XCTAssertEqual(
                contrast(palette.accent, .black), expected, accuracy: 0.02,
                "\(id) \(scheme) accent vs black")
        }
        XCTAssertEqual(
            argb(haoTabTint(.black, scheme: .light, fallback: .black)), 0xFF000000)
        XCTAssertEqual(
            argb(haoTabTint(.white, scheme: .light, fallback: .black)), 0xFF000000)
        XCTAssertEqual(
            argb(haoTabTint(Color(hex: 0x76767A), scheme: .dark, fallback: .white)),
            0xFF76767A)
        XCTAssertEqual(
            argb(haoTabTint(.black, scheme: .dark, fallback: .white)), 0xFFFFFFFF)
    }
}

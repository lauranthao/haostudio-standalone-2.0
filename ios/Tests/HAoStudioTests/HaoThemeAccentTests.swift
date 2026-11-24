// HAo Studio 2.0 — accent-on-video tests (build 36, item 15).
//
// Drives haoAccentOnBlack / HaoThemePalette.accentOnVideo through
// all 8 theme/mode combinations plus custom picks, and checks the
// haoOnAccentFor text pairing for the pill fills. Pure colour
// math, no views, no network. Xcode test target HAoStudioTests,
// host app, @testable import HAoStudio.

import SwiftUI
import XCTest

@testable import HAoStudio

final class HaoThemeAccentTests: XCTestCase {
    /// Opaque ARGB of a colour, for exact comparison (Color is not Equatable).
    private func argb(_ color: Color) -> UInt32 { color.opaqueARGB }

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
}

// HAo Studio 2.0 — equalizer data tests (S2-C leg).
//
// Gain normalisation (clamp ±12 dB, 0.5 dB steps), Beans preset
// tables (10 bands each), frequency labels.

import XCTest

@testable import HAoStudio

final class MusicEqualizerTests: XCTestCase {
    func testNormalizeGainClamps() {
        XCTAssertEqual(MusicEqualizer.normalizeGain(20), 12)
        XCTAssertEqual(MusicEqualizer.normalizeGain(-20), -12)
        XCTAssertEqual(MusicEqualizer.normalizeGain(0), 0)
    }

    func testNormalizeGainRoundsToHalfDb() {
        XCTAssertEqual(MusicEqualizer.normalizeGain(1.3), 1.5)
        XCTAssertEqual(MusicEqualizer.normalizeGain(1.2), 1.0)
        XCTAssertEqual(MusicEqualizer.normalizeGain(-2.7), -2.5)
        XCTAssertEqual(MusicEqualizer.normalizeGain(0.26), 0.5)
        XCTAssertEqual(MusicEqualizer.normalizeGain(0.24), 0.0)
    }

    func testNormalizeGainsPadsAndTruncates() {
        XCTAssertEqual(MusicEqualizer.normalizeGains([1, 2]), [1, 2, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(MusicEqualizer.normalizeGains(Array(repeating: 1, count: 12)).count, 10)
    }

    func testEveryPresetHasTenBands() {
        for preset in MusicEqualizerPreset.allCases {
            XCTAssertEqual(preset.gains.count, 10, "\(preset.rawValue) must have 10 bands")
        }
    }

    func testBeansPresetTables() {
        XCTAssertEqual(MusicEqualizerPreset.flat.gains, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(MusicEqualizerPreset.bass.gains, [6, 5, 3, 1, 0, 0, -1, -1, 0, 0])
        XCTAssertEqual(MusicEqualizerPreset.vocal.gains, [-2, -1, 0, 2, 4, 4, 3, 2, 0, -1])
        XCTAssertEqual(MusicEqualizerPreset.rock.gains, [5, 4, 2, -1, -2, 1, 3, 4, 5, 4])
    }

    func testPresetFromId() {
        XCTAssertEqual(MusicEqualizerPreset.fromId("bass"), .bass)
        XCTAssertEqual(MusicEqualizerPreset.fromId("electronic"), .electronic)
        XCTAssertEqual(MusicEqualizerPreset.fromId("bogus"), .flat)
        XCTAssertEqual(MusicEqualizerPreset.fromId(nil), .flat)
    }

    func testFrequencyLabels() {
        XCTAssertEqual(MusicEqualizer.frequencyLabel(31), "31 Hz")
        XCTAssertEqual(MusicEqualizer.frequencyLabel(500), "500 Hz")
        XCTAssertEqual(MusicEqualizer.frequencyLabel(1000), "1 kHz")
        XCTAssertEqual(MusicEqualizer.frequencyLabel(2000), "2 kHz")
        XCTAssertEqual(MusicEqualizer.frequencyLabel(16000), "16 kHz")
    }

    func testBandFrequencies() {
        XCTAssertEqual(
            MusicEqualizer.bandFrequencies,
            [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        )
    }

    func testPreviewAddsPreamp() {
        let preview = MusicEqualizer.previewGains(gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], preamp: 10)
        XCTAssertEqual(preview, Array(repeating: 3.5, count: 10))
    }

    func testAutoEqPresetsHaveTenBands() {
        XCTAssertEqual(MusicAutoEqPreset.all.count, 8)
        for preset in MusicAutoEqPreset.all {
            XCTAssertEqual(preset.gains.count, 10, "\(preset.name) must have 10 bands")
        }
    }

    // MARK: Preset display name (build 36, item 8, E1)

    func testDisplayPresetNameShowsBuiltinPreset() {
        XCTAssertEqual(
            MusicEqualizerViewModel.displayPresetName(
                isCustom: false, customName: "", autoEqName: "", preset: .rock),
            MusicEqualizerPreset.rock.displayName)
    }

    func testDisplayPresetNameShowsNamedCustomPreset() {
        XCTAssertEqual(
            MusicEqualizerViewModel.displayPresetName(
                isCustom: true, customName: "我的低音", autoEqName: "", preset: .rock),
            "我的低音")
    }

    func testDisplayPresetNameShowsCustomWhenUnnamed() {
        // A hand-tuned band after a preset must not keep showing
        // the preset it started from.
        XCTAssertEqual(
            MusicEqualizerViewModel.displayPresetName(
                isCustom: true, customName: "", autoEqName: "", preset: .rock),
            "自定义")
    }

    func testDisplayPresetNamePrefersAutoEq() {
        // An applied AutoEq preset wins over the built-in preset
        // (and over a custom name — it is what is sounding).
        XCTAssertEqual(
            MusicEqualizerViewModel.displayPresetName(
                isCustom: false, customName: "", autoEqName: "HD 600", preset: .flat),
            "HD 600")
    }
}

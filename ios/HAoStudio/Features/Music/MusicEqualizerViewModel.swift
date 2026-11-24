// HAo Studio 2.0 — equalizer view model (S2-C leg).
//
// 10-band EQ bound to the player's EqualizerSettings (contract type,
// player leg): enabled + gains[10] + presetName. Persistence uses
// the S1 keys (hao_eq_enabled / hao_eq_band_gains / hao_eq_preset /
// hao_eq_custom_name / hao_eq_preamp / hao_eq_autoeq_name) and
// Documents/hao_eq_custom_presets.json for custom presets.
//
// Normalisation gate (plan §七.3): loudness can only be measured
// while the equalizer is on, so the normalisation switch is disabled
// unless EQ is enabled — with the reason shown, never a silent dead
// switch. Turning EQ off never silently clears the stored
// normalisation value.

import SwiftUI

@MainActor
final class MusicEqualizerViewModel: ObservableObject {
    @Published var enabled: Bool = false {
        didSet { persistAndApply() }
    }
    @Published var gains: [Double] = Array(repeating: 0, count: 10) {
        didSet { persistAndApply() }
    }
    @Published var preamp: Double = 0 {
        didSet { persistAndApply() }
    }
    @Published private(set) var selectedPreset: MusicEqualizerPreset = .flat
    @Published private(set) var isCustom = false
    @Published private(set) var selectedCustomName = ""
    @Published private(set) var customPresets: [MusicEqualizerCustomPreset] = []
    @Published private(set) var selectedAutoEqName = ""
    @Published var normalizationEnabled: Bool = false {
        didSet {
            MusicLibraryStore.setNormalizationEnabled(normalizationEnabled)
            // A4: persist alone is not enough — the player only
            // read this at init, so a mid-session flip did nothing
            // until relaunch. Notify the player now.
            player.setNormalizationEnabled(normalizationEnabled)
        }
    }
    @Published var normalizationStrength: Int = 1 {
        didSet {
            defaults.set(min(2, max(0, normalizationStrength)), forKey: "hao_music_normalization_strength")
            // A4: same as above — push the new strength live.
            player.setNormalizationStrength(normalizationStrength)
        }
    }

    /// Display name of the current preset (custom name wins, then the
    /// built-in display name — Flutter EqualizerStore.currentPresetName).
    var currentPresetName: String {
        Self.displayPresetName(
            isCustom: isCustom, customName: selectedCustomName,
            autoEqName: selectedAutoEqName, preset: selectedPreset)
    }

    /// Pure preset-name decision (unit-tested). A hand-tuned band
    /// after a preset, or an AutoEq preset, used to keep showing
    /// the old preset's name — the header lied about what was
    /// sounding. AutoEq wins when one is applied; an unnamed
    /// hand-tuned set is "自定义", never the preset it started from.
    static func displayPresetName(
        isCustom: Bool, customName: String, autoEqName: String,
        preset: MusicEqualizerPreset
    ) -> String {
        if !autoEqName.isEmpty { return autoEqName }
        if isCustom { return customName.isEmpty ? "自定义" : customName }
        return preset.displayName
    }

    /// Preview curve = gains + preamp*0.35, clamped ±12.
    var previewGains: [Double] {
        return MusicEQMath.previewGains(gains: gains, preamp: preamp)
    }

    /// Normalisation can only measure loudness while EQ is on.
    var normalizationAvailable: Bool { enabled }

    private let player = NativeMusicPlayer.shared
    private let defaults: UserDefaults
    private var loading = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        normalizationEnabled = MusicLibraryStore.normalizationEnabled(defaults: defaults)
        normalizationStrength = MusicLibraryStore.normalizationStrength(defaults: defaults)
    }

    private func load() {
        loading = true
        defer { loading = false }
        enabled = defaults.bool(forKey: "hao_eq_enabled")
        if let stored = defaults.array(forKey: "hao_eq_band_gains") as? [Double] {
            gains = MusicEQMath.normalizeGains(stored)
        } else if let stored = defaults.array(forKey: "hao_eq_band_gains") as? [NSNumber] {
            gains = MusicEQMath.normalizeGains(stored.map { $0.doubleValue })
        }
        selectedPreset = MusicEqualizerPreset.fromId(defaults.string(forKey: "hao_eq_preset"))
        selectedCustomName = defaults.string(forKey: "hao_eq_custom_name") ?? ""
        isCustom = defaults.string(forKey: "hao_eq_preset") == "custom"
        preamp = MusicEQMath.normalizeGain(defaults.double(forKey: "hao_eq_preamp"))
        selectedAutoEqName = defaults.string(forKey: "hao_eq_autoeq_name") ?? ""
        customPresets = readCustomPresets()
    }

    private func persistAndApply() {
        if loading { return }
        defaults.set(enabled, forKey: "hao_eq_enabled")
        defaults.set(gains, forKey: "hao_eq_band_gains")
        defaults.set(isCustom ? "custom" : selectedPreset.rawValue, forKey: "hao_eq_preset")
        defaults.set(selectedCustomName, forKey: "hao_eq_custom_name")
        defaults.set(preamp, forKey: "hao_eq_preamp")
        defaults.set(selectedAutoEqName, forKey: "hao_eq_autoeq_name")
        applyToPlayer()
    }

    /// Push the current settings to the player.
    func applyToPlayer() {
        let settings = EqualizerSettings(
            enabled: enabled,
            gains: gains,
            presetName: currentPresetName,
            // A3: preamp was dropped here — the tap's preampLinear
            // stayed 1.0 no matter where the slider was. Pass it.
            preamp: preamp
        )
        player.applyEqualizer(settings)
    }

    func applyPreset(_ preset: MusicEqualizerPreset) {
        selectedPreset = preset
        isCustom = false
        selectedCustomName = ""
        selectedAutoEqName = ""
        gains = preset.gains
        preamp = 0
    }

    func applyCustomPreset(_ preset: MusicEqualizerCustomPreset) {
        selectedCustomName = preset.name
        isCustom = true
        selectedAutoEqName = ""
        gains = preset.gains
        preamp = preset.preamp
    }

    func applyAutoEq(_ preset: MusicAutoEqPreset) {
        selectedAutoEqName = preset.name
        isCustom = false
        selectedCustomName = ""
        gains = preset.gains
    }

    /// A hand-tuned band clears the AutoEq selection (Flutter:
    /// a hand-tuned band or a built-in preset clears AutoEq).
    func setGain(band: Int, value: Double) {
        guard band >= 0 && band < gains.count else { return }
        selectedAutoEqName = ""
        if isCustom == false && selectedPreset != .flat {
            // Manual edit after a preset = custom from here on.
            isCustom = true
            selectedCustomName = ""
        }
        gains[band] = MusicEQMath.normalizeGain(value)
    }

    func setPreamp(_ value: Double) {
        selectedAutoEqName = ""
        preamp = MusicEQMath.normalizeGain(value)
    }

    func resetToFlat() {
        applyPreset(.flat)
    }

    // MARK: - Custom presets

    private func readCustomPresets() -> [MusicEqualizerCustomPreset] {
        let url = LocalStore.collectionURL(named: "hao_eq_custom_presets")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return MusicDict.objectArray(from: data).map(MusicEqualizerCustomPreset.init(json:))
    }

    private func writeCustomPresets() {
        let url = LocalStore.collectionURL(named: "hao_eq_custom_presets")
        let value = customPresets.map { $0.toJSON() }
        guard let data = MusicDict.data(forTopLevel: value) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    func saveCurrentAsCustomPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        customPresets.removeAll(where: { $0.name == trimmed })
        let preset = MusicEqualizerCustomPreset(name: trimmed, gains: gains, preamp: preamp)
        customPresets.append(preset)
        writeCustomPresets()
        selectedCustomName = trimmed
        isCustom = true
        selectedAutoEqName = ""
        persistAndApply()
    }

    func deleteCustomPreset(_ preset: MusicEqualizerCustomPreset) {
        customPresets.removeAll(where: { $0.name == preset.name })
        writeCustomPresets()
        if selectedCustomName == preset.name {
            selectedCustomName = ""
            isCustom = false
            selectedPreset = .flat
            gains = MusicEqualizerPreset.flat.gains
            preamp = 0
        }
    }
}

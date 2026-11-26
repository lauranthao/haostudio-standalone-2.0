// HAo Studio 2.0 — theme store.
//
// Swift-native equivalent of the Flutter ThemeController: the chosen theme
// and light/dark/system mode persist in UserDefaults and a change takes
// effect immediately everywhere (the palette is re-resolved from the
// @Published values and pushed through the environment — no restart, no
// stale cached colours).
//
// Persistence keys keep the Flutter Hive key NAMES (`haoThemeId`,
// `haoThemeMode`, box `app_settings`) so the mapping in
// docs/storage-mapping.md is one-to-one; only the storage mechanism
// changes (Hive -> UserDefaults, per the foundation storage rules).
//
// S5-A: this store is the ONLY owner of theme-related @Published state.
// SettingsStore forwards glassIntensity / tabAccent / accentOverride
// here instead of holding a second copy of the same keys — two
// @Published vars over one UserDefaults key would fight each other
// (each didSet overwriting the other's value).
//
// Accent-key decision (S5-A, verified against the Flutter baseline
// `standalone-app-merge23`):
// - Flutter has NO separate Hive key for the custom accent. The
//   settings sheet stores the pick (with its opacity) under the
//   shared key `hao_tabbar_accent`
//   (`lib/core/theme/tab_bar_accent.dart`, `HiveKeys.tabBarAccentColor`)
//   and ThemeController only holds the opaque in-memory view of the
//   SAME key. So the brief's fallback key `hao_accent_override` is
//   NOT introduced: `accentOverrideHex` is the opaque view of
//   `tabAccentHex`, not a second stored key. One stored int, two
//   views — the tab bar reads the stored opacity, the theme accent
//   reads the opaque form. A fresh install stores nothing (nil =
//   "use the per-theme accent"), never a fake red default.
// - The purple hue guard (`clampAccentHue`, P1-U6) runs on every
//   write and on load, so a stored purple is corrected on next launch.

import SwiftUI

/// Light / dark / follow-system. Same three modes as Flutter `ThemeMode`.
enum HaoAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// `nil` = follow the system (SwiftUI `.preferredColorScheme(nil)`).
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
final class ThemeStore: ObservableObject {
    /// UserDefaults keys — same names as the Flutter Hive keys.
    static let themeKey = "haoThemeId"
    static let modeKey = "haoThemeMode"
    /// New Swift key (S5-A): Flutter stored glass intensity under
    /// `haoGlassIntensity`, but that key was never in the S1
    /// migration table, so no migrated value exists to bridge —
    /// this key starts fresh at 1.0 (full glass). If a future
    /// migration maps `haoGlassIntensity`, bridge it here the same
    /// way SettingsStore bridges `videoPlayerKey` (see
    /// SettingsStore.swift).
    static let glassIntensityKey = "hao_glass_intensity"
    /// Shared custom-accent key (see the header note): the stored
    /// int is ARGB with opacity, exactly as Flutter stored it.
    static let tabAccentKey = "hao_tabbar_accent"

    @Published var themeID: HaoThemeID {
        didSet { defaults.set(themeID.rawValue, forKey: Self.themeKey) }
    }

    @Published var appearance: HaoAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Self.modeKey) }
    }

    /// Liquid-glass intensity (chen 2026-11-21, Settings → 外观):
    /// 1.0 = today's full glass, 0.3 = faintest glass allowed.
    /// Clamped to 0.3...1.0 on every write and on load.
    /// b49phase1: the legibility veil (HaoBackdropLayer) does
    /// NOT follow this value — readability first, the veil stays
    /// at its WCAG-verified strengths (0.72 / 0.58 light,
    /// 0.92 / 0.90 dark) whatever the slider says. No switch for
    /// it exists; if one is ever added it defaults OFF.
    @Published var glassIntensity: Double {
        didSet {
            let clamped = min(1.0, max(0.3, glassIntensity))
            if clamped != glassIntensity {
                glassIntensity = clamped
                return
            }
            defaults.set(glassIntensity, forKey: Self.glassIntensityKey)
        }
    }

    /// The stored custom accent (ARGB int with opacity), or nil
    /// when nothing was ever picked (or after "恢复默认"): the
    /// per-theme accent is in effect then. 0 is treated as
    /// "not set" (Flutter: a stored 0 is transparent black, never
    /// a real pick). The purple hue guard runs on write.
    @Published var tabAccentHex: Int? {
        didSet {
            guard let value = tabAccentHex, value != 0 else {
                if tabAccentHex != nil { tabAccentHex = nil }
                defaults.removeObject(forKey: Self.tabAccentKey)
                return
            }
            let clamped = Int(haoClampedAccentARGB(UInt32(truncatingIfNeeded: value)))
            if clamped != value {
                // Only the hue is corrected; the stored alpha is kept.
                tabAccentHex = clamped
                return
            }
            defaults.set(value, forKey: Self.tabAccentKey)
        }
    }

    /// The custom accent override for the theme: the OPAQUE form
    /// of `tabAccentHex` (alpha forced to 0xFF), or nil when no
    /// custom accent is stored. Computed, not stored — it shares
    /// the `hao_tabbar_accent` key with `tabAccentHex` (see the
    /// header note), so there is exactly one source of truth.
    /// The setter writes through `tabAccentHex` (opaque).
    var accentOverrideHex: Int? {
        get {
            guard let stored = tabAccentHex, stored != 0 else { return nil }
            return Int(Color(argb: UInt32(truncatingIfNeeded: stored)).opaqueARGB)
        }
        set {
            if let value = newValue, value != 0 {
                tabAccentHex = Int(Color(argb: UInt32(truncatingIfNeeded: value)).opaqueARGB)
            } else {
                tabAccentHex = nil
            }
        }
    }

    /// The stored custom accent as a Color (with its stored
    /// opacity), or nil when nothing is stored. The tab bar /
    /// picker read this; the theme accent reads
    /// `accentOverrideHex` (opaque).
    var tabAccentColor: Color? {
        guard let stored = tabAccentHex, stored != 0 else { return nil }
        return Color(argb: UInt32(truncatingIfNeeded: stored))
    }

    private let defaults: UserDefaults

    /// Observer for post-import re-read (S6): same contract as
    /// SettingsStore.reloadFromDefaults — the backup engine posts
    /// `.haoBackupImported` after a successful import.
    private var backupImportedObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedTheme = defaults.string(forKey: Self.themeKey)
        self.themeID = HaoThemeID(rawValue: savedTheme ?? "") ?? .appleGlass
        let savedMode = defaults.string(forKey: Self.modeKey)
        self.appearance = HaoAppearance(rawValue: savedMode ?? "") ?? .system
        if let savedIntensity = defaults.object(forKey: Self.glassIntensityKey) as? NSNumber {
            self.glassIntensity = min(1.0, max(0.3, savedIntensity.doubleValue))
        } else {
            self.glassIntensity = 1.0
        }
        if let savedAccent = defaults.object(forKey: Self.tabAccentKey) as? NSNumber {
            let raw = savedAccent.intValue
            if raw == 0 {
                self.tabAccentHex = nil
            } else {
                let clamped = Int(haoClampedAccentARGB(UInt32(truncatingIfNeeded: raw)))
                self.tabAccentHex = clamped
                if clamped != raw {
                    defaults.set(clamped, forKey: Self.tabAccentKey)
                }
            }
        } else {
            self.tabAccentHex = nil
        }
        // S6: re-read after a backup import (see reloadFromDefaults).
        backupImportedObserver = NotificationCenter.default.addObserver(
            forName: .haoBackupImported, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadFromDefaults()
        }
    }

    /// Re-read theme state from UserDefaults (S6). Called after a
    /// backup import posts `.haoBackupImported`. This mirrors the
    /// reads in init — keep the two in sync (the reads stay inline
    /// in init because the @Published vars have no default values
    /// and Swift forbids calling a method before they are assigned).
    /// Each didSet writes the same value back, so re-reading is
    /// idempotent.
    func reloadFromDefaults() {
        let savedTheme = defaults.string(forKey: Self.themeKey)
        themeID = HaoThemeID(rawValue: savedTheme ?? "") ?? .appleGlass
        let savedMode = defaults.string(forKey: Self.modeKey)
        appearance = HaoAppearance(rawValue: savedMode ?? "") ?? .system
        if let savedIntensity = defaults.object(forKey: Self.glassIntensityKey) as? NSNumber {
            glassIntensity = min(1.0, max(0.3, savedIntensity.doubleValue))
        } else {
            glassIntensity = 1.0
        }
        if let savedAccent = defaults.object(forKey: Self.tabAccentKey) as? NSNumber {
            let raw = savedAccent.intValue
            if raw == 0 {
                tabAccentHex = nil
            } else {
                let clamped = Int(haoClampedAccentARGB(UInt32(truncatingIfNeeded: raw)))
                tabAccentHex = clamped
                if clamped != raw {
                    defaults.set(clamped, forKey: Self.tabAccentKey)
                }
            }
        } else {
            tabAccentHex = nil
        }
    }

    /// The palette for the EFFECTIVE colour scheme (after the system /
    /// override resolution SwiftUI already performed). Call sites read
    /// the palette from the environment; this is only the resolver.
    /// S5-A: the base palette is resolved first, then the settings
    /// overrides (glass intensity + custom accent) are applied on
    /// top — the base palette logic itself is untouched.
    func palette(for effectiveScheme: ColorScheme) -> HaoThemePalette {
        let base = HaoThemePalette.palette(for: themeID, scheme: effectiveScheme)
        let override = accentOverrideHex.map { Color(argb: UInt32(truncatingIfNeeded: $0)) }
        return base.applying(glassIntensity: glassIntensity, accentOverride: override)
    }

    func setTheme(_ id: HaoThemeID) {
        themeID = id
    }

    func setAppearance(_ mode: HaoAppearance) {
        appearance = mode
    }

    func setGlassIntensity(_ value: Double) {
        glassIntensity = value
    }

    /// Apply a custom accent colour immediately everywhere (nil
    /// clears the override and restores the per-theme accent).
    /// Persists through `tabAccentHex` (shared key, stored opaque).
    func setCustomAccent(_ hex: Int?) {
        accentOverrideHex = hex
    }

    /// Clear the custom accent and delete the stored key, so the
    /// theme accent returns to the per-theme default.
    func clearCustomAccent() {
        tabAccentHex = nil
    }
}

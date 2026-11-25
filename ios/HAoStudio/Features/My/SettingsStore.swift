// HAo Studio 2.0 — settings store (S5, leg A: engine only, no UI).
//
// The single source of truth for every Settings switch / picker the
// B-leg UI binds to. Every @Published value writes straight to
// UserDefaults (injected `defaults`, `.standard` in production, an
// isolated suite in tests) under the key the S1 migration table
// (`Storage/MigrationStore.swift`) already promises — no key is
// invented here for a value the migration already owns.
//
// Key rules:
// - MigrationStore-mapped keys are used verbatim. New keys are only
//   `hao_glass_intensity` (owned by ThemeStore, forwarded here),
//   `hao_video_last_engine` (owned by VideoEngineReporter) and
//   `settingsSectionExpanded_<id>`.
//   （chen 2026-11-24: 个人资料/会员已删，`hao_profile_nickname` 不再是
//   新键——见 init 里的旧值清理。）
// - Theme-owned state lives ONLY in ThemeStore (see its header):
//   `glassIntensity` and `tabAccentHex` are computed forwards
//   to the ThemeStore this store is built with.
//   HAoStudioApp creates the ThemeStore first, then
//   `SettingsStore(themeStore:)` with it.
// - Defaults are the Flutter `settings_tab_page.dart` /
//   `VideoPlaybackSettings` defaults where one was found
//   (mixWithOthers false, autoResume false, autoUpdateCheck true,
//   lowMemoryMode "auto", dvP8Downgrade true, autoNextEpisode true,
//   skipIntroMode "off"); the rest are documented at each property.
//
// Engine-key bridge (S5-A decision): the Flutter migration table
// calls the engine preference `videoPlayerKey`, but the Swift
// kernel (`Playback/PlayerKernel.swift`) reads
// `hao_video_player_key` and the two were never bridged. On first
// read, when the Swift key is absent and a migrated `videoPlayerKey`
// value exists, the migrated value is adopted once (written into
// the Swift key). From then on only the Swift key is read.
// `enginePreference` reads/writes the Swift key through the
// injected `defaults`; in production (`defaults == .standard`)
// that IS `PlayerKernel.preferred`'s storage, so the drivers see
// the same value.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import SwiftUI

@MainActor
final class SettingsStore: ObservableObject {
    // MARK: - Keys (verbatim from the S1 migration table)

    static let musicQualityKey = "musicQuality"
    static let mixWithOthersKey = "audioMixWithOthers"
    static let autoResumeKey = "autoResumeLastPlayback"
    /// The Swift engine-preference key (PlayerKernel).
    static let enginePreferenceKey = "hao_video_player_key"
    /// The Flutter/migrated engine-preference key. Read once, see
    /// the header note; never written after the first adoption.
    static let legacyEngineKey = "videoPlayerKey"
    static let autoNextEpisodeKey = "hao_video_auto_next"
    static let doubleTapSecondsKey = "hao_vod_double_tap_seconds"
    static let dialogueBoostKey = "hao_vod_dialogue_boost"
    static let hideSynopsisKey = "hao_vod_spoiler_hide_synopsis"
    static let blurUnwatchedPostersKey = "hao_vod_spoiler_blur_unwatched"
    static let audioOnlyBackgroundKey = "hao_vod_audio_only"
    static let videoFitKey = "hao_vod_video_fit"
    static let superResolutionKey = "hao_vod_super_resolution"
    static let interpolationKey = "hao_vod_interpolation"
    static let sdrToHDRKey = "hao_vod_sdr_to_hdr"
    static let dvP8DowngradeKey = "hao_vod_dv_p8_downgrade"
    static let skipIntroModeKey = "hao_vod_skip_intro_mode"
    static let subtitleFontSizeKey = "hao_vod_subtitle_font_size"
    static let subtitleColorKey = "hao_vod_subtitle_color"
    static let subtitlePositionKey = "hao_vod_subtitle_position"
    static let lowMemoryModeKey = "hao_low_memory_mode"
    static let cellularDowngradeKey = "hao_live_cellular_downgrade"
    /// Song-cache switch + cap (b45-coda 包 C, §4.4). These ARE
    /// the audio cache engine's keys (HaoAudioCache.enabledKey /
    /// limitMBKey, CacheManager.swift:134-135) — the earlier
    /// hao_song_cache_* keys were never read by the engine, so
    /// the toggle + picker were dead (b49 sweep P0). 0 MB = 自动.
    static let audioCacheEnabledKey = "hao_audio_cache_enabled"
    static let audioCacheLimitMBKey = "hao_audio_cache_limit_mb"
    /// Legacy song-cache keys, written by 0.0.2 and earlier.
    /// Migrated once into the hao_audio_cache_* keys on first
    /// read (migrateLegacySongCacheKeys), then removed — no code
    /// reads them after the migration.
    static let legacySongCacheEnabledKey = "hao_song_cache_enabled"
    static let legacySongCacheLimitMBKey = "hao_song_cache_limit_mb"
    /// Accepted disclaimer version (b45-coda 包 C, §4.3). Must
    /// equal DisclaimerGate.currentVersion (5) to count.
    static let disclaimerAcceptedVersionKey = "hao_disclaimer_accepted_version"
    static let wallpaperEnabledKey = "hao_wallpaper_enabled"
    static let wallpaperCurrentKey = "hao_wallpaper_current"
    static let bgColorEnabledKey = "hao_bgcolor_enabled"
    static let bgColorHexKey = "hao_bgcolor_hex"
    /// Legacy key for the deleted profile feature （chen 2026-11-24:
    /// 个人资料/会员已删）。No code reads it any more; init removes
    /// any value an old install left behind so no orphan key stays.
    static let legacyNicknameKey = "hao_profile_nickname"
    static let sectionExpandedKeyPrefix = "settingsSectionExpanded_"

    /// Skip-intro modes, copied verbatim from Flutter
    /// `settings_tab_page.dart` (`_skipIntroOrder` /
    /// `_skipIntroLabels`): stored value -> label.
    static let skipIntroModes = ["off", "manual", "auto3s", "autoNow"]
    static let skipIntroLabels: [String: String] = [
        "off": "关",
        "manual": "手动",
        "auto3s": "自动延时 3 秒",
        "autoNow": "自动立即",
    ]

    // MARK: - Music

    /// Target audio-quality tier. Default `.hiRes` — the same
    /// default S2's PlaybackCoordinator uses when nothing is
    /// stored (a migrated Flutter "hires" string does not match
    /// the Swift raw value "hiRes" and also falls back to hiRes).
    @Published var musicQuality: AudioQuality {
        didSet { defaults.set(musicQuality.rawValue, forKey: Self.musicQualityKey) }
    }

    /// Haptics on/off. Stored through MusicLibraryStore (key
    /// `hapticsEnabled`, default true) — no second copy of the key.
    @Published var hapticsEnabled: Bool {
        didSet { MusicLibraryStore.setHapticsEnabled(hapticsEnabled, defaults: defaults) }
    }

    /// Mix this app's audio with other apps' audio (Flutter
    /// default false).
    @Published var mixWithOthers: Bool {
        didSet { defaults.set(mixWithOthers, forKey: Self.mixWithOthersKey) }
    }

    /// Resume the last playback on launch (Flutter default false).
    @Published var autoResume: Bool {
        didSet { defaults.set(autoResume, forKey: Self.autoResumeKey) }
    }

    /// Automatic update check on launch (Flutter default true).
    /// Only the switch lives here — the check itself is S6's.
    /// b49fix2 P2-70: the key is DefaultUpdateChecker
    /// .autoUpdateCheckKey — one shared constant. It used to be
    /// declared here too, and if the two strings ever drifted,
    /// the Settings switch and the checker would silently
    /// disagree.
    @Published var autoUpdateCheck: Bool {
        didSet { defaults.set(autoUpdateCheck, forKey: DefaultUpdateChecker.autoUpdateCheckKey) }
    }

    // MARK: - Video engine (VOD + live)

    /// Preferred video engine (MPV / IJK / AVPlayer). A preference,
    /// not a command: the kernel's capability gate still wins per
    /// stream. See the header note for the `videoPlayerKey` bridge.
    @Published var enginePreference: VideoEngine {
        didSet { defaults.set(enginePreference.rawValue, forKey: Self.enginePreferenceKey) }
    }

    /// Auto-advance to the next episode when one ends. Default true.
    @Published var autoNextEpisode: Bool {
        didSet { defaults.set(autoNextEpisode, forKey: Self.autoNextEpisodeKey) }
    }

    /// Double-tap seek step in seconds (5...30). Default 10.
    @Published var doubleTapSeconds: Int {
        didSet {
            let clamped = min(30, max(5, doubleTapSeconds))
            if clamped != doubleTapSeconds {
                doubleTapSeconds = clamped
                return
            }
            defaults.set(doubleTapSeconds, forKey: Self.doubleTapSecondsKey)
        }
    }

    /// Dialogue boost (centre-channel lift on MPV).
    @Published var dialogueBoost: Bool {
        didSet { defaults.set(dialogueBoost, forKey: Self.dialogueBoostKey) }
    }

    /// Hide the synopsis (spoiler guard).
    @Published var hideSynopsis: Bool {
        didSet { defaults.set(hideSynopsis, forKey: Self.hideSynopsisKey) }
    }

    /// Blur posters of unwatched titles (spoiler guard).
    @Published var blurUnwatchedPosters: Bool {
        didSet { defaults.set(blurUnwatchedPosters, forKey: Self.blurUnwatchedPostersKey) }
    }

    /// Keep audio playing with video off (VOD background audio).
    @Published var audioOnlyBackground: Bool {
        didSet { defaults.set(audioOnlyBackground, forKey: Self.audioOnlyBackgroundKey) }
    }

    /// Picture fit (适应 / 裁剪 / 拉伸). Default `.aspectFit`
    /// (Flutter `VideoFitMode.auto` = contain).
    @Published var videoFit: VideoFit {
        didSet { defaults.set(videoFit.rawValue, forKey: Self.videoFitKey) }
    }

    /// MPV super-resolution upscaling.
    @Published var superResolution: Bool {
        didSet { defaults.set(superResolution, forKey: Self.superResolutionKey) }
    }

    /// MPV frame interpolation.
    @Published var interpolation: Bool {
        didSet { defaults.set(interpolation, forKey: Self.interpolationKey) }
    }

    /// SDR → HDR tone mapping.
    @Published var sdrToHDR: Bool {
        didSet { defaults.set(sdrToHDR, forKey: Self.sdrToHDRKey) }
    }

    /// Dolby Vision profile 8 downgrade to HDR (AVPlayer can play
    /// the base layer). Default true (Flutter, decided 2026-11-22).
    @Published var dvP8Downgrade: Bool {
        didSet { defaults.set(dvP8Downgrade, forKey: Self.dvP8DowngradeKey) }
    }

    /// Skip-intro mode: one of `skipIntroModes` ("off" / "manual" /
    /// "auto3s" / "autoNow"). Unknown stored values fall back to
    /// "off". Default "off".
    @Published var skipIntroMode: String {
        didSet {
            if !Self.skipIntroModes.contains(skipIntroMode) {
                skipIntroMode = "off"
                return
            }
            defaults.set(skipIntroMode, forKey: Self.skipIntroModeKey)
        }
    }

    /// Subtitle font size / colour / position. Raw strings, cycled
    /// by the settings UI; no single Flutter default constant was
    /// found, so the Swift defaults are "medium" / "white" /
    /// "bottom" (the position default matches Flutter's
    /// `_subPositionOrder` first entry).
    @Published var subtitleFontSize: String {
        didSet { defaults.set(subtitleFontSize, forKey: Self.subtitleFontSizeKey) }
    }

    @Published var subtitleColor: String {
        didSet { defaults.set(subtitleColor, forKey: Self.subtitleColorKey) }
    }

    @Published var subtitlePosition: String {
        didSet { defaults.set(subtitlePosition, forKey: Self.subtitlePositionKey) }
    }

    /// Low-memory mode: "auto" / "always" / "never" (Flutter
    /// `LowMemoryMode`, default "auto").
    @Published var lowMemoryMode: String {
        didSet { defaults.set(lowMemoryMode, forKey: Self.lowMemoryModeKey) }
    }

    // MARK: - Live

    /// Drop to a lower line on cellular (live).
    @Published var cellularDowngrade: Bool {
        didSet { defaults.set(cellularDowngrade, forKey: Self.cellularDowngradeKey) }
    }

    // MARK: - Song cache (b45-coda 包 C, §4.4)

    /// Song cache on/off. Default true. Storage-only: the audio
    /// cache engine (包 F) reads this key to enforce it.
    @Published var songCacheEnabled: Bool {
        didSet { defaults.set(songCacheEnabled, forKey: Self.audioCacheEnabledKey) }
    }

    /// Song cache cap in MB. 0 = 自动. Unknown stored values fall
    /// back to 0 (自动) instead of showing a blank picker row.
    @Published var songCacheLimitMB: Int {
        didSet {
            if !SongCacheLimitOptions.isValid(songCacheLimitMB) {
                songCacheLimitMB = 0
                return
            }
            defaults.set(songCacheLimitMB, forKey: Self.audioCacheLimitMBKey)
        }
    }

    /// Accepted disclaimer version (DisclaimerGate.currentVersion
    /// = 5). 0 = never accepted.
    @Published var disclaimerAcceptedVersion: Int {
        didSet { defaults.set(disclaimerAcceptedVersion, forKey: Self.disclaimerAcceptedVersionKey) }
    }

    // MARK: - Appearance (wallpaper / background colour)

    @Published var wallpaperEnabled: Bool {
        didSet { defaults.set(wallpaperEnabled, forKey: Self.wallpaperEnabledKey) }
    }

    /// Relative wallpaper name (`wallpapers/<file>` or a bare
    /// file name), "" = none. The file list itself lives in the
    /// `hao_wallpaper_paths` collection via WallpaperStore.
    @Published var wallpaperCurrent: String {
        didSet { defaults.set(wallpaperCurrent, forKey: Self.wallpaperCurrentKey) }
    }

    /// Wallpaper file list, mirrored from WallpaperStore. Kept in
    /// sync by `reloadWallpapers()` after an import/delete done
    /// through WallpaperStore directly.
    @Published var wallpaperPaths: [String] {
        didSet { WallpaperStore.saveList(wallpaperPaths, documentsURL: documentsURL) }
    }

    /// The wallpaper image to show behind the UI, or nil when the
    /// switch is off, no wallpaper is picked, or the file is gone.
    var wallpaperBackgroundURL: URL? {
        guard wallpaperEnabled, !wallpaperCurrent.isEmpty else { return nil }
        return WallpaperStore.fileURL(for: wallpaperCurrent, documentsURL: documentsURL)
    }

    @Published var bgColorEnabled: Bool {
        didSet { defaults.set(bgColorEnabled, forKey: Self.bgColorEnabledKey) }
    }

    /// Custom background colour as a hex string ("#RRGGBB"), "" =
    /// none. Empty by default; the switch decides whether it applies.
    @Published var bgColorHex: String {
        didSet { defaults.set(bgColorHex, forKey: Self.bgColorHexKey) }
    }

    // MARK: - Theme-owned state (forwarded to ThemeStore)

    /// The ThemeStore this store forwards theme state to. Owned by
    /// HAoStudioApp and created before this store — never nil, and
    /// never a second ThemeStore (two stores over the same keys
    /// would fight).
    let themeStore: ThemeStore

    /// Liquid-glass intensity, forwarded to ThemeStore (the only
    /// @Published copy). 1.0 = full glass, 0.3 = faintest.
    var glassIntensity: Double {
        get { themeStore.glassIntensity }
        set {
            objectWillChange.send()
            themeStore.glassIntensity = newValue
        }
    }

    /// Tab-bar accent (stored ARGB int with opacity), or nil for
    /// the default. Forwarded to ThemeStore.
    var tabAccentHex: Int? {
        get { themeStore.tabAccentHex }
        set {
            objectWillChange.send()
            themeStore.tabAccentHex = newValue
        }
    }

    /// The stored custom accent as a Color, or nil for the default.
    /// The tab-bar palette reads this and writes through it (the
    /// setter stores the opaque ARGB form under the shared
    /// `hao_tabbar_accent` key — same single source of truth as
    /// `tabAccentHex`). Coordinator addition (S5 merge): the B-leg
    /// UI assigns this, and the A-leg file only had a getter.
    var tabAccentColor: Color? {
        get { themeStore.tabAccentColor }
        set {
            objectWillChange.send()
            if let color = newValue {
                themeStore.tabAccentHex = Int(color.opaqueARGB)
            } else {
                themeStore.tabAccentHex = nil
            }
        }
    }

    // MARK: - Storage

    private let defaults: UserDefaults
    /// Test seam: Documents override for wallpaper files. Nil in
    /// production (the real container). LocalStore itself has no
    /// directory injection, so the wallpaper/profile stores take
    /// the override through here instead.
    private let documentsURL: URL?

    /// Observer for post-import re-read (S6): the backup engine posts
    /// `.haoBackupImported` after a successful import; this store
    /// re-reads every setting so the UI updates without a restart
    /// (plan §7.2). Held so the observation lives as long as the store.
    private var backupImportedObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, themeStore: ThemeStore, documentsURL: URL? = nil) {
        self.defaults = defaults
        self.themeStore = themeStore
        self.documentsURL = documentsURL

        let savedQuality = defaults.string(forKey: Self.musicQualityKey)
        self.musicQuality = AudioQuality(rawValue: savedQuality ?? "") ?? .hiRes
        self.hapticsEnabled = MusicLibraryStore.hapticsEnabled(defaults: defaults)
        self.mixWithOthers = SettingsStore.boolValue(defaults, key: Self.mixWithOthersKey, default: false)
        self.autoResume = SettingsStore.boolValue(defaults, key: Self.autoResumeKey, default: false)
        self.autoUpdateCheck = SettingsStore.boolValue(defaults, key: DefaultUpdateChecker.autoUpdateCheckKey, default: true)

        // Engine preference, with the one-time `videoPlayerKey` bridge.
        if defaults.object(forKey: Self.enginePreferenceKey) == nil,
           let migrated = defaults.string(forKey: Self.legacyEngineKey) {
            let engine = VideoEngine.from(raw: migrated)
            self.enginePreference = engine
            defaults.set(engine.rawValue, forKey: Self.enginePreferenceKey)
        } else {
            self.enginePreference = VideoEngine.from(raw: defaults.string(forKey: Self.enginePreferenceKey))
        }
        self.autoNextEpisode = SettingsStore.boolValue(defaults, key: Self.autoNextEpisodeKey, default: true)
        self.doubleTapSeconds = SettingsStore.intValue(defaults, key: Self.doubleTapSecondsKey, default: 10, range: 5...30)
        self.dialogueBoost = SettingsStore.boolValue(defaults, key: Self.dialogueBoostKey, default: false)
        self.hideSynopsis = SettingsStore.boolValue(defaults, key: Self.hideSynopsisKey, default: false)
        self.blurUnwatchedPosters = SettingsStore.boolValue(defaults, key: Self.blurUnwatchedPostersKey, default: false)
        self.audioOnlyBackground = SettingsStore.boolValue(defaults, key: Self.audioOnlyBackgroundKey, default: false)
        let savedFit = defaults.string(forKey: Self.videoFitKey)
        self.videoFit = VideoFit(rawValue: savedFit ?? "") ?? .aspectFit
        Self.clearOrphanedSuperResolution(defaults: defaults)
        self.superResolution = SettingsStore.boolValue(defaults, key: Self.superResolutionKey, default: false)
        self.interpolation = SettingsStore.boolValue(defaults, key: Self.interpolationKey, default: false)
        self.sdrToHDR = SettingsStore.boolValue(defaults, key: Self.sdrToHDRKey, default: false)
        self.dvP8Downgrade = SettingsStore.boolValue(defaults, key: Self.dvP8DowngradeKey, default: true)
        let savedSkip = defaults.string(forKey: Self.skipIntroModeKey) ?? "off"
        self.skipIntroMode = Self.skipIntroModes.contains(savedSkip) ? savedSkip : "off"
        self.subtitleFontSize = defaults.string(forKey: Self.subtitleFontSizeKey) ?? "medium"
        self.subtitleColor = defaults.string(forKey: Self.subtitleColorKey) ?? "white"
        self.subtitlePosition = defaults.string(forKey: Self.subtitlePositionKey) ?? "bottom"
        self.lowMemoryMode = defaults.string(forKey: Self.lowMemoryModeKey) ?? "auto"

        self.cellularDowngrade = SettingsStore.boolValue(defaults, key: Self.cellularDowngradeKey, default: true)

        // b49 sweep P0: adopt any stored hao_song_cache_* values
        // into the hao_audio_cache_* keys the engine reads, once.
        Self.migrateLegacySongCacheKeys(defaults: defaults)
        self.songCacheEnabled = SettingsStore.boolValue(defaults, key: Self.audioCacheEnabledKey, default: true)
        let savedLimit = defaults.object(forKey: Self.audioCacheLimitMBKey) as? NSNumber
        self.songCacheLimitMB = SongCacheLimitOptions.isValid(savedLimit?.intValue ?? 0) ? (savedLimit?.intValue ?? 0) : 0
        self.disclaimerAcceptedVersion = (defaults.object(forKey: Self.disclaimerAcceptedVersionKey) as? NSNumber)?.intValue ?? 0

        self.wallpaperEnabled = SettingsStore.boolValue(defaults, key: Self.wallpaperEnabledKey, default: false)
        self.wallpaperCurrent = defaults.string(forKey: Self.wallpaperCurrentKey) ?? ""
        self.wallpaperPaths = WallpaperStore.list(documentsURL: documentsURL)
        self.bgColorEnabled = SettingsStore.boolValue(defaults, key: Self.bgColorEnabledKey, default: false)
        self.bgColorHex = defaults.string(forKey: Self.bgColorHexKey) ?? ""

        // b47: section folding state — the @Published source of
        // truth, loaded from the stored settingsSectionExpanded_<id>
        // keys (see the section-expansion MARK).
        self.collapsedSections = Self.loadCollapsedSections(from: defaults)

        // chen 2026-11-24: 个人资料/会员已删。清掉旧安装留下的昵称值
        // 与头像文件（`Documents/profile/avatar.jpg`），不留读不到
        // 的孤儿 key / 孤儿文件。值不存在时两步都是 no-op。
        if defaults.object(forKey: Self.legacyNicknameKey) != nil {
            defaults.removeObject(forKey: Self.legacyNicknameKey)
        }
        let legacyAvatar = (documentsURL ?? LocalStore.documentsDirectory())
            .appendingPathComponent("profile/avatar.jpg")
        if FileManager.default.fileExists(atPath: legacyAvatar.path) {
            try? FileManager.default.removeItem(at: legacyAvatar)
        }

        // S6: re-read after a backup import (see reloadFromDefaults).
        backupImportedObserver = NotificationCenter.default.addObserver(
            forName: .haoBackupImported, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadFromDefaults()
        }
    }

    /// Re-read every setting from UserDefaults (S6). Called after a
    /// backup import posts `.haoBackupImported` so the UI updates
    /// without a restart (plan §7.2: 导入后全部设置项重读). This
    /// mirrors the reads in init — keep the two in sync when a
    /// setting is added. Each didSet writes the same value back,
    /// so re-reading is idempotent.
    func reloadFromDefaults() {
        let savedQuality = defaults.string(forKey: Self.musicQualityKey)
        musicQuality = AudioQuality(rawValue: savedQuality ?? "") ?? .hiRes
        hapticsEnabled = MusicLibraryStore.hapticsEnabled(defaults: defaults)
        mixWithOthers = SettingsStore.boolValue(defaults, key: Self.mixWithOthersKey, default: false)
        autoResume = SettingsStore.boolValue(defaults, key: Self.autoResumeKey, default: false)
        autoUpdateCheck = SettingsStore.boolValue(defaults, key: DefaultUpdateChecker.autoUpdateCheckKey, default: true)

        // Engine preference, with the one-time `videoPlayerKey` bridge.
        // b49fix2 P1-27: only assign when a key exists. The old
        // else-branch called VideoEngine.from(raw: nil), which
        // returns .mpv — and the didSet then WROTE
        // hao_video_player_key, fabricating an MPV preference for
        // a user who never touched the picker (a backup import
        // of a pre-2.0 backup silently pinned the engine to MPV).
        // No key anywhere = leave the current preference alone
        // (unset = capability-based default, not MPV).
        if defaults.object(forKey: Self.enginePreferenceKey) == nil,
           let migrated = defaults.string(forKey: Self.legacyEngineKey) {
            let engine = VideoEngine.from(raw: migrated)
            enginePreference = engine
            defaults.set(engine.rawValue, forKey: Self.enginePreferenceKey)
        } else if defaults.object(forKey: Self.enginePreferenceKey) != nil {
            enginePreference = VideoEngine.from(raw: defaults.string(forKey: Self.enginePreferenceKey))
        }
        autoNextEpisode = SettingsStore.boolValue(defaults, key: Self.autoNextEpisodeKey, default: true)
        doubleTapSeconds = SettingsStore.intValue(defaults, key: Self.doubleTapSecondsKey, default: 10, range: 5...30)
        dialogueBoost = SettingsStore.boolValue(defaults, key: Self.dialogueBoostKey, default: false)
        hideSynopsis = SettingsStore.boolValue(defaults, key: Self.hideSynopsisKey, default: false)
        blurUnwatchedPosters = SettingsStore.boolValue(defaults, key: Self.blurUnwatchedPostersKey, default: false)
        audioOnlyBackground = SettingsStore.boolValue(defaults, key: Self.audioOnlyBackgroundKey, default: false)
        let savedFit = defaults.string(forKey: Self.videoFitKey)
        videoFit = VideoFit(rawValue: savedFit ?? "") ?? .aspectFit
        Self.clearOrphanedSuperResolution(defaults: defaults)
        superResolution = SettingsStore.boolValue(defaults, key: Self.superResolutionKey, default: false)
        interpolation = SettingsStore.boolValue(defaults, key: Self.interpolationKey, default: false)
        sdrToHDR = SettingsStore.boolValue(defaults, key: Self.sdrToHDRKey, default: false)
        dvP8Downgrade = SettingsStore.boolValue(defaults, key: Self.dvP8DowngradeKey, default: true)
        let savedSkip = defaults.string(forKey: Self.skipIntroModeKey) ?? "off"
        skipIntroMode = Self.skipIntroModes.contains(savedSkip) ? savedSkip : "off"
        subtitleFontSize = defaults.string(forKey: Self.subtitleFontSizeKey) ?? "medium"
        subtitleColor = defaults.string(forKey: Self.subtitleColorKey) ?? "white"
        subtitlePosition = defaults.string(forKey: Self.subtitlePositionKey) ?? "bottom"
        lowMemoryMode = defaults.string(forKey: Self.lowMemoryModeKey) ?? "auto"

        cellularDowngrade = SettingsStore.boolValue(defaults, key: Self.cellularDowngradeKey, default: true)

        Self.migrateLegacySongCacheKeys(defaults: defaults)
        songCacheEnabled = SettingsStore.boolValue(defaults, key: Self.audioCacheEnabledKey, default: true)
        let savedLimit = defaults.object(forKey: Self.audioCacheLimitMBKey) as? NSNumber
        songCacheLimitMB = SongCacheLimitOptions.isValid(savedLimit?.intValue ?? 0) ? (savedLimit?.intValue ?? 0) : 0
        disclaimerAcceptedVersion = (defaults.object(forKey: Self.disclaimerAcceptedVersionKey) as? NSNumber)?.intValue ?? 0

        wallpaperEnabled = SettingsStore.boolValue(defaults, key: Self.wallpaperEnabledKey, default: false)
        wallpaperCurrent = defaults.string(forKey: Self.wallpaperCurrentKey) ?? ""
        wallpaperPaths = WallpaperStore.list(documentsURL: documentsURL)
        bgColorEnabled = SettingsStore.boolValue(defaults, key: Self.bgColorEnabledKey, default: false)
        bgColorHex = defaults.string(forKey: Self.bgColorHexKey) ?? ""
        // b47: backup import re-reads the folding state too.
        collapsedSections = Self.loadCollapsedSections(from: defaults)
    }

    // MARK: - Helpers

    /// One-time migration of the legacy hao_song_cache_* values
    /// into the hao_audio_cache_* keys the audio cache engine
    /// reads (b49 sweep P0: the old keys were never read, so the
    /// 歌曲缓存 toggle + 上限 picker were dead). The new key wins
    /// when both exist; the legacy key is removed either way, so
    /// a second call is a no-op. Called from init and from
    /// reloadFromDefaults (a backup import can restore legacy
    /// keys) — same shape as the `videoPlayerKey` bridge above.
    static func migrateLegacySongCacheKeys(defaults: UserDefaults) {
        if defaults.object(forKey: Self.audioCacheEnabledKey) == nil,
           let legacy = defaults.object(forKey: Self.legacySongCacheEnabledKey) as? NSNumber {
            defaults.set(legacy.boolValue, forKey: Self.audioCacheEnabledKey)
        }
        if defaults.object(forKey: Self.audioCacheLimitMBKey) == nil,
           let legacy = defaults.object(forKey: Self.legacySongCacheLimitMBKey) as? NSNumber {
            defaults.set(legacy.intValue, forKey: Self.audioCacheLimitMBKey)
        }
        if defaults.object(forKey: Self.legacySongCacheEnabledKey) != nil {
            defaults.removeObject(forKey: Self.legacySongCacheEnabledKey)
        }
        if defaults.object(forKey: Self.legacySongCacheLimitMBKey) != nil {
            defaults.removeObject(forKey: Self.legacySongCacheLimitMBKey)
        }
    }

    /// One-time clear of a stored Anime4K 超分 = true (b49 sweep
    /// P2: the row is removed — the shaders never shipped and the
    /// branch is a documented no-op — so a stored true would keep
    /// resolving to the no-op branch with no UI left to turn it
    /// off). Absent key = no-op. No playback code changes: the
    /// driver still reads the same key, it just never sees true.
    static func clearOrphanedSuperResolution(defaults: UserDefaults) {
        if defaults.object(forKey: Self.superResolutionKey) != nil {
            defaults.removeObject(forKey: Self.superResolutionKey)
        }
    }

    private static func boolValue(_ defaults: UserDefaults, key: String, default defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private static func intValue(_ defaults: UserDefaults, key: String, default defaultValue: Int, range: ClosedRange<Int>) -> Int {
        guard let number = defaults.object(forKey: key) as? NSNumber else { return defaultValue }
        return min(range.upperBound, max(range.lowerBound, number.intValue))
    }

    // MARK: - Section expansion (B leg)

    /// Ids of the settings sections currently folded (collapsed).
    ///
    /// b47 (chen 2026-11-25 build 46: 设置里面的主题也不能收放):
    /// the 11-24 fix wrote UserDefaults + a manual
    /// `objectWillChange.send()` — and the section STILL did not
    /// fold on device. A manual send is the fragile path: it is
    /// easy to drop across the List's hoisted section content,
    /// while every working toggle in Settings flows through a
    /// @Published property. The collapsed set IS the @Published
    /// source of truth now; the `settingsSectionExpanded_<id>`
    /// UserDefaults keys stay the persisted copy (same keys, same
    /// defaults — expanded unless an explicit false is stored —
    /// and BackupEngine still exports/imports those keys directly,
    /// so `setSectionExpanded` keeps writing them).
    @Published var collapsedSections: Set<String> = []

    /// Collapsed section ids from the stored
    /// `settingsSectionExpanded_<id>` keys: an id is collapsed
    /// only when its key exists AND is false (a missing key means
    /// expanded — the default). Scans the stored keys rather than
    /// a fixed list, so ids from older builds migrate too.
    static func loadCollapsedSections(from defaults: UserDefaults) -> Set<String> {
        var collapsed: Set<String> = []
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(sectionExpandedKeyPrefix) {
            guard defaults.object(forKey: key) != nil,
                  defaults.bool(forKey: key) == false
            else { continue }
            collapsed.insert(String(key.dropFirst(sectionExpandedKeyPrefix.count)))
        }
        return collapsed
    }

    /// Whether a settings section is expanded. Default true.
    /// Stored per section under `settingsSectionExpanded_<id>`.
    func sectionExpanded(_ id: String) -> Bool {
        !collapsedSections.contains(id)
    }

    func setSectionExpanded(_ expanded: Bool, for id: String) {
        // b47: mutate the @Published set — the @Published wrapper
        // sends objectWillChange through the standard pipeline, the
        // same mechanism as every working Settings toggle. The
        // UserDefaults write stays: it is the persisted copy and
        // the backup export reads these keys directly.
        if expanded {
            collapsedSections.remove(id)
        } else {
            collapsedSections.insert(id)
        }
        defaults.set(expanded, forKey: Self.sectionExpandedKeyPrefix + id)
    }

    /// Re-read the wallpaper list from WallpaperStore (after an
    /// import/delete done through WallpaperStore directly).
    func reloadWallpapers() {
        wallpaperPaths = WallpaperStore.list(documentsURL: documentsURL)
    }

    /// The display label for the current skip-intro mode.
    var skipIntroLabel: String {
        Self.skipIntroLabels[skipIntroMode] ?? "关"
    }
}

// HAo Studio 2.0 — settings tests (S5, leg A).
//
// iOS-only, same treatment as S3's VideoPlayerTests: NOT wired
// into `ios/Package.swift` (this leg does not edit it). SettingsStore
// / ThemeStore are @MainActor ObservableObjects with SwiftUI
// (Color) and UIKit state, so `swift test` on a macOS runner
// cannot compile this target. S7 wired the `HAoStudioTests` Xcode
// test target (run with `xcodebuild test` against an iOS simulator
// destination); the target has the app as its host and the tests
// `@testable import HAoStudio` for the storage / player types.
//
// Isolation (same pattern as MigrationStoreTests): every test
// uses a fresh UserDefaults suite (UUID) and a fresh temporary
// Documents directory; nothing touches the real defaults, the
// real Documents dir, or the real Keychain.

import Combine
import Foundation
import UIKit
import XCTest

@testable import HAoStudio

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var docs: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var themeStore: ThemeStore!
    private var settings: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "com.haostudio.settings.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        docs = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-settings-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        themeStore = ThemeStore(defaults: defaults)
        settings = SettingsStore(defaults: defaults, themeStore: themeStore, documentsURL: docs)
    }

    override func tearDown() {
        if let docs = docs {
            try? FileManager.default.removeItem(at: docs)
        }
        if let suiteName = suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    // MARK: - Defaults (Flutter baseline)

    func testDefaultsMatchFlutterBaseline() {
        XCTAssertEqual(settings.musicQuality, .hiRes)
        XCTAssertTrue(settings.hapticsEnabled)
        XCTAssertFalse(settings.mixWithOthers)
        XCTAssertFalse(settings.autoResume)
        XCTAssertTrue(settings.autoUpdateCheck)
        XCTAssertTrue(settings.autoNextEpisode)
        XCTAssertEqual(settings.doubleTapSeconds, 10)
        XCTAssertFalse(settings.dialogueBoost)
        XCTAssertFalse(settings.hideSynopsis)
        XCTAssertFalse(settings.blurUnwatchedPosters)
        XCTAssertFalse(settings.audioOnlyBackground)
        XCTAssertEqual(settings.videoFit, .aspectFit)
        XCTAssertFalse(settings.interpolation)
        XCTAssertFalse(settings.sdrToHDR)
        XCTAssertTrue(settings.dvP8Downgrade)
        XCTAssertEqual(settings.skipIntroMode, "off")
        XCTAssertEqual(settings.skipIntroLabel, "关")
        XCTAssertEqual(settings.subtitleFontSize, "medium")
        XCTAssertEqual(settings.subtitleColor, "white")
        XCTAssertEqual(settings.subtitlePosition, "bottom")
        XCTAssertEqual(settings.lowMemoryMode, "auto")
        // Flutter default is ON (liveCellularDowngradeEnabled
        // defaults true); the Swift default was false before the
        // wiring leg — fixed here.
        XCTAssertTrue(settings.cellularDowngrade)
        XCTAssertFalse(settings.normalizationEnabled)
        XCTAssertEqual(settings.normalizationStrength, 1)
        XCTAssertFalse(settings.wallpaperEnabled)
        XCTAssertEqual(settings.wallpaperCurrent, "")
        XCTAssertTrue(settings.wallpaperPaths.isEmpty)
        XCTAssertNil(settings.wallpaperBackgroundURL)
        XCTAssertFalse(settings.bgColorEnabled)
        XCTAssertEqual(settings.bgColorHex, "")
        XCTAssertEqual(settings.glassIntensity, 1.0)
        XCTAssertNil(settings.tabAccentHex)
        XCTAssertNil(settings.accentOverrideHex)
        XCTAssertTrue(settings.sectionExpanded("engine"))
    }

    // MARK: - Persistence round-trip

    func testMusicQualityPersistsAndReloads() {
        settings.musicQuality = .flac
        XCTAssertEqual(defaults.string(forKey: "musicQuality"), "flac")
        let reloaded = SettingsStore(defaults: defaults, themeStore: themeStore, documentsURL: docs)
        XCTAssertEqual(reloaded.musicQuality, .flac)
    }

    func testHapticsGoesThroughMusicLibraryStore() {
        settings.hapticsEnabled = false
        XCTAssertFalse(MusicLibraryStore.hapticsEnabled(defaults: defaults))
        XCTAssertFalse(defaults.bool(forKey: "hapticsEnabled"))
        let reloaded = SettingsStore(defaults: defaults, themeStore: themeStore, documentsURL: docs)
        XCTAssertFalse(reloaded.hapticsEnabled)
    }

    /// chen 2026-11-24: 个人资料/会员已删——旧昵称值由 init 清掉，
    /// 不留孤儿 key。写一个旧值再建 store，旧值必须被清除。
    func testLegacyNicknameValueIsCleanedUpOnInit() {
        defaults.set("旧昵称", forKey: "hao_profile_nickname")
        let fresh = SettingsStore(defaults: defaults, themeStore: themeStore, documentsURL: docs)
        _ = fresh
        XCTAssertNil(defaults.object(forKey: "hao_profile_nickname"))
    }

    /// chen 2026-11-24 报：设置分组点标题收不起来。根因是
    /// setSectionExpanded 只写 UserDefaults、不发变更通知，
    /// SwiftUI 不重算 body。点标题必须发 objectWillChange。
    func testSectionExpandedNotifiesObservers() {
        var notified = false
        let cancellable = settings.objectWillChange.sink { _ in notified = true }
        settings.setSectionExpanded(false, for: "engine")
        XCTAssertTrue(notified, "setSectionExpanded must publish so the section collapses")
        XCTAssertFalse(settings.sectionExpanded("engine"))
        _ = cancellable
    }

    func testSectionExpandedPersistsPerSection() {
        settings.setSectionExpanded(false, for: "engine")
        XCTAssertFalse(settings.sectionExpanded("engine"))
        XCTAssertTrue(settings.sectionExpanded("playback"))
        XCTAssertFalse(defaults.bool(forKey: "settingsSectionExpanded_engine"))
    }

    func testSectionExpandedPersistsForMySection() {
        // The 我的 entry section folds on the same store keys as the
        // 7 settings groups; default expanded, persists per section.
        XCTAssertTrue(settings.sectionExpanded(SettingsSection.my.rawValue))
        settings.setSectionExpanded(false, for: SettingsSection.my.rawValue)
        XCTAssertFalse(settings.sectionExpanded(SettingsSection.my.rawValue))
        XCTAssertFalse(defaults.bool(forKey: "settingsSectionExpanded_my"))
        XCTAssertTrue(settings.sectionExpanded(SettingsSection.appearance.rawValue))
    }

    // MARK: - Clamps and fallbacks

    func testNormalizationStrengthClampsToZeroTwo() {
        settings.normalizationStrength = 5
        XCTAssertEqual(settings.normalizationStrength, 2)
        XCTAssertEqual(defaults.integer(forKey: "hao_music_normalization_strength"), 2)
        settings.normalizationStrength = -1
        XCTAssertEqual(settings.normalizationStrength, 0)
    }

    func testDoubleTapSecondsClampsToFiveThirty() {
        settings.doubleTapSeconds = 100
        XCTAssertEqual(settings.doubleTapSeconds, 30)
        settings.doubleTapSeconds = 1
        XCTAssertEqual(settings.doubleTapSeconds, 5)
    }

    func testUnknownSkipIntroModeFallsBackToOff() {
        settings.skipIntroMode = "bogus"
        XCTAssertEqual(settings.skipIntroMode, "off")
        defaults.set("bogus", forKey: "hao_vod_skip_intro_mode")
        let reloaded = SettingsStore(defaults: defaults, themeStore: themeStore, documentsURL: docs)
        XCTAssertEqual(reloaded.skipIntroMode, "off")
    }

    func testUnknownStoredQualityFallsBackToHiRes() {
        defaults.set("bogus", forKey: "musicQuality")
        let reloaded = SettingsStore(defaults: defaults, themeStore: themeStore, documentsURL: docs)
        XCTAssertEqual(reloaded.musicQuality, .hiRes)
    }

    func testSkipIntroLabelsMatchFlutter() {
        XCTAssertEqual(SettingsStore.skipIntroLabels["off"], "关")
        XCTAssertEqual(SettingsStore.skipIntroLabels["manual"], "手动")
        XCTAssertEqual(SettingsStore.skipIntroLabels["auto3s"], "自动延时 3 秒")
        XCTAssertEqual(SettingsStore.skipIntroLabels["autoNow"], "自动立即")
    }

    // MARK: - Engine-key bridge (videoPlayerKey -> hao_video_player_key)

    func testLegacyVideoPlayerKeyAdoptedOnce() {
        defaults.set("ijk", forKey: "videoPlayerKey")
        XCTAssertNil(defaults.object(forKey: "hao_video_player_key"))
        let bridged = SettingsStore(defaults: defaults, themeStore: themeStore, documentsURL: docs)
        XCTAssertEqual(bridged.enginePreference, .ijk)
        // Adopted into the Swift key, exactly once.
        XCTAssertEqual(defaults.string(forKey: "hao_video_player_key"), "ijk")
        let again = SettingsStore(defaults: defaults, themeStore: themeStore, documentsURL: docs)
        XCTAssertEqual(again.enginePreference, .ijk)
    }

    func testSwiftEngineKeyWinsOverLegacy() {
        defaults.set("avplayer", forKey: "hao_video_player_key")
        defaults.set("ijk", forKey: "videoPlayerKey")
        let store = SettingsStore(defaults: defaults, themeStore: themeStore, documentsURL: docs)
        XCTAssertEqual(store.enginePreference, .avplayer)
        XCTAssertEqual(defaults.string(forKey: "hao_video_player_key"), "avplayer")
    }

    func testEnginePreferencePersistsToSwiftKey() {
        settings.enginePreference = .mpv
        XCTAssertEqual(defaults.string(forKey: "hao_video_player_key"), "mpv")
        XCTAssertNil(defaults.object(forKey: "videoPlayerKey"))
    }

    // MARK: - Theme forwarding (one owner: ThemeStore)

    func testGlassIntensityForwardsToThemeStore() {
        settings.glassIntensity = 0.5
        XCTAssertEqual(themeStore.glassIntensity, 0.5)
        XCTAssertEqual(defaults.double(forKey: "hao_glass_intensity"), 0.5)
        themeStore.glassIntensity = 0.8
        XCTAssertEqual(settings.glassIntensity, 0.8)
    }

    func testGlassIntensityClampsToPointThreeOne() {
        settings.glassIntensity = 0.1
        XCTAssertEqual(themeStore.glassIntensity, 0.3)
        settings.glassIntensity = 2.0
        XCTAssertEqual(themeStore.glassIntensity, 1.0)
    }

    func testTabAccentAndOverrideShareOneKey() {
        // Stored with opacity (0x80 red); the theme override is
        // the opaque form of the same stored int — no second key.
        settings.tabAccentHex = Int(0x80FF0000)
        XCTAssertEqual(themeStore.tabAccentHex, Int(0x80FF0000))
        XCTAssertEqual(defaults.integer(forKey: "hao_tabbar_accent"), Int(0x80FF0000))
        XCTAssertNil(defaults.object(forKey: "hao_accent_override"))
        XCTAssertEqual(settings.accentOverrideHex, Int(0xFFFF0000))
        XCTAssertNotNil(settings.tabAccentColor)
    }

    func testClearingAccentRestoresDefault() {
        settings.tabAccentHex = Int(0xFF000000)
        XCTAssertNotNil(settings.accentOverrideHex)
        settings.tabAccentHex = nil
        XCTAssertNil(settings.accentOverrideHex)
        XCTAssertNil(defaults.object(forKey: "hao_tabbar_accent"))
    }

    // MARK: - Wallpaper background URL

    func testWallpaperBackgroundURLNeedsEnabledCurrentAndFile() {
        let data = SettingsTestImages.pngData()
        let name = WallpaperStore.importImage(data: data, documentsURL: docs)
        XCTAssertNotNil(name)
        settings.reloadWallpapers()
        XCTAssertEqual(settings.wallpaperPaths.count, 1)
        settings.wallpaperCurrent = name ?? ""
        // Switch off: no background.
        XCTAssertNil(settings.wallpaperBackgroundURL)
        settings.wallpaperEnabled = true
        let url = settings.wallpaperBackgroundURL
        XCTAssertNotNil(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path))
        // Missing file: no background.
        settings.wallpaperCurrent = "wallpapers/gone.jpg"
        XCTAssertNil(settings.wallpaperBackgroundURL)
    }

    /// b40 (chen 2026-11-25: 壁纸导入之后用了也不显示): the
    /// import -> save -> resolve chain round-trips the exact bytes,
    /// survives a fresh store (kill + relaunch: same defaults suite
    /// + Documents dir, new SettingsStore instance), and deleting
    /// the wallpaper returns the background to nil (default).
    /// The render half of the bug (opaque tab backgrounds covering
    /// the picture) is fixed in MainTabView / haoTabBackground and
    /// is device-only to see.
    func testWallpaperImportRoundTripsAndDeleteRestoresDefault() {
        let data = SettingsTestImages.pngData()
        let name = WallpaperStore.importImage(data: data, documentsURL: docs)
        XCTAssertNotNil(name)
        settings.wallpaperCurrent = name ?? ""
        settings.wallpaperEnabled = true
        let url = settings.wallpaperBackgroundURL
        XCTAssertNotNil(url)
        XCTAssertEqual(try? Data(contentsOf: url!), data)

        // Kill + relaunch: a fresh store over the same suite/dir
        // still resolves the same wallpaper.
        let relaunched = SettingsStore(defaults: defaults, themeStore: themeStore, documentsURL: docs)
        XCTAssertEqual(relaunched.wallpaperCurrent, name)
        XCTAssertTrue(relaunched.wallpaperEnabled)
        XCTAssertEqual(relaunched.wallpaperBackgroundURL, url)

        // Delete: back to default (no background, empty list).
        WallpaperStore.delete(name ?? "", documentsURL: docs)
        settings.wallpaperCurrent = ""
        settings.reloadWallpapers()
        XCTAssertTrue(settings.wallpaperPaths.isEmpty)
        XCTAssertNil(settings.wallpaperBackgroundURL)
    }

    /// b41 (chen 2026-11-25: the wallpaper still did not show on
    /// build 40): the backdrop decision — wallpaper (enabled +
    /// image loaded) > background colour (enabled + valid hex) >
    /// theme. A layer that is off or unusable falls through;
    /// nothing here invents a colour. The render half (the
    /// backdrop drawn inside the tab roots, above the
    /// NavigationStack's opaque background) is device-only to see.
    func testBackdropResolutionPriority() {
        let image = UIImage(data: SettingsTestImages.pngData())
        XCTAssertNotNil(image)
        // Wallpaper on + image loaded wins over the colour.
        XCTAssertTrue(HaoBackdrop.resolve(
            wallpaperEnabled: true, wallpaperImage: image,
            bgColorEnabled: true, bgColorHex: "#112233"
        ).isWallpaper)
        // Wallpaper on but the image failed to load → theme (the
        // colour was not the chosen layer, so it is not invented).
        XCTAssertTrue(HaoBackdrop.resolve(
            wallpaperEnabled: true, wallpaperImage: nil,
            bgColorEnabled: false, bgColorHex: ""
        ).isTheme)
        // Wallpaper off → valid colour.
        XCTAssertTrue(HaoBackdrop.resolve(
            wallpaperEnabled: false, wallpaperImage: image,
            bgColorEnabled: true, bgColorHex: "#112233"
        ).isColor)
        // Wallpaper off, invalid hex → theme.
        XCTAssertTrue(HaoBackdrop.resolve(
            wallpaperEnabled: false, wallpaperImage: nil,
            bgColorEnabled: true, bgColorHex: "nope"
        ).isTheme)
        // Everything off → theme.
        XCTAssertTrue(HaoBackdrop.resolve(
            wallpaperEnabled: false, wallpaperImage: nil,
            bgColorEnabled: false, bgColorHex: ""
        ).isTheme)
        // The resolved wallpaper carries the loaded image.
        if case .wallpaper(let resolved) = HaoBackdrop.resolve(
            wallpaperEnabled: true, wallpaperImage: image,
            bgColorEnabled: false, bgColorHex: ""
        ) {
            XCTAssertTrue(resolved === image)
        } else {
            XCTFail("expected the wallpaper backdrop")
        }
    }
}

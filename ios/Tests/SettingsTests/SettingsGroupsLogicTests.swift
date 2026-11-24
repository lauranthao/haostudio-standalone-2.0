// HAo Studio 2.0 — settings logic tests (S5-B leg).
//
// Pure-logic tests only: section ids, accent hex conversion,
// skip-intro / subtitle option validation, the "keep at least
// one" guard, live-platform prefs and LX list ordering. No
// network, no real data. Persistence tests use a temp
// documents directory (injected, like LXScriptStore) and an
// isolated UserDefaults suite (UUID), mirroring
// MigrationStoreTests — nothing here touches the real
// Documents directory or the standard defaults.
//
// NOTE FOR THE COORDINATOR: these tests import SettingsLogic
// through AppCore, so Package.swift must add
// `Features/My/SettingsLogic.swift` to the AppCore sources and
// register this directory as a `SettingsTests` test target.
// That registration is not part of this leg (Package.swift is
// coordinator-owned). The tests are written, not run.

import Foundation
import XCTest

@testable import AppCore

final class SettingsGroupsLogicTests: XCTestCase {
    private var docs: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.haostudio.settings.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        docs = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-settings-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
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

    // MARK: - Section ids

    func testSectionIDsInOrder() {
        XCTAssertEqual(
            SettingsSection.allCases.map { $0.rawValue },
            ["my", "appearance", "music", "live", "video", "sources", "data", "about"]
        )
    }

    func testSectionTitlesCopyFlutter() {
        XCTAssertEqual(SettingsSection.my.title, "我的")
        XCTAssertEqual(SettingsSection.appearance.title, "外观")
        XCTAssertEqual(SettingsSection.music.title, "音乐播放")
        XCTAssertEqual(SettingsSection.live.title, "直播")
        XCTAssertEqual(SettingsSection.video.title, "影视播放")
        XCTAssertEqual(SettingsSection.sources.title, "源管理")
        XCTAssertEqual(SettingsSection.data.title, "数据")
        XCTAssertEqual(SettingsSection.about.title, "关于")
    }

    // MARK: - Accent hex conversion

    func testHexParsesValidRRGGBB() {
        let parsed = HexRGB.parse("#1A2B3C")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.red, 0x1A)
        XCTAssertEqual(parsed?.green, 0x2B)
        XCTAssertEqual(parsed?.blue, 0x3C)
        XCTAssertTrue(HexRGB.isValid("#FF9F0A"))
        XCTAssertTrue(HexRGB.isValid("#000000"))
        XCTAssertTrue(HexRGB.isValid("#ffffff"))
    }

    func testHexRejectsInvalidDrafts() {
        XCTAssertNil(HexRGB.parse("1A2B3C"))
        XCTAssertNil(HexRGB.parse("#1A2B3"))
        XCTAssertNil(HexRGB.parse("#1A2B3C4"))
        XCTAssertNil(HexRGB.parse("#GGGGGG"))
        XCTAssertNil(HexRGB.parse(""))
        XCTAssertNil(HexRGB.parse("#"))
        XCTAssertFalse(HexRGB.isValid("red"))
        XCTAssertFalse(HexRGB.isValid("#12 456"))
    }

    func testHexRoundTrip() {
        XCTAssertEqual(HexRGB.string(red: 0x1A, green: 0x2B, blue: 0x3C), "#1A2B3C")
        let parsed = HexRGB.parse("#0A84FF")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(
            HexRGB.string(red: parsed!.red, green: parsed!.green, blue: parsed!.blue),
            "#0A84FF"
        )
    }

    // MARK: - Skip-intro / subtitle / low-memory options

    func testSkipIntroOptionsAreTheFlutterValues() {
        XCTAssertTrue(SettingsOptionLists.isValidSkipIntroMode("off"))
        XCTAssertTrue(SettingsOptionLists.isValidSkipIntroMode("manual"))
        XCTAssertTrue(SettingsOptionLists.isValidSkipIntroMode("auto3s"))
        XCTAssertTrue(SettingsOptionLists.isValidSkipIntroMode("autoNow"))
        XCTAssertFalse(SettingsOptionLists.isValidSkipIntroMode("auto"))
        XCTAssertFalse(SettingsOptionLists.isValidSkipIntroMode(""))
        XCTAssertEqual(
            SettingsOptionLists.label(
                for: "auto3s",
                in: SettingsOptionLists.skipIntroOptions,
                default: SettingsOptionLists.skipIntroDefault
            ),
            "自动延时 3 秒"
        )
        XCTAssertEqual(
            SettingsOptionLists.label(
                for: "banana",
                in: SettingsOptionLists.skipIntroOptions,
                default: SettingsOptionLists.skipIntroDefault
            ),
            "关"
        )
    }

    func testSubtitleOptionsAreTheFlutterValues() {
        XCTAssertTrue(SettingsOptionLists.isValidSubtitleFontSize("small"))
        XCTAssertTrue(SettingsOptionLists.isValidSubtitleFontSize("medium"))
        XCTAssertTrue(SettingsOptionLists.isValidSubtitleFontSize("large"))
        XCTAssertFalse(SettingsOptionLists.isValidSubtitleFontSize("huge"))
        XCTAssertTrue(SettingsOptionLists.isValidSubtitleColor("white"))
        XCTAssertTrue(SettingsOptionLists.isValidSubtitleColor("yellow"))
        XCTAssertTrue(SettingsOptionLists.isValidSubtitleColor("cyan"))
        XCTAssertFalse(SettingsOptionLists.isValidSubtitleColor("red"))
        XCTAssertTrue(SettingsOptionLists.isValidSubtitlePosition("bottom"))
        XCTAssertTrue(SettingsOptionLists.isValidSubtitlePosition("middle"))
        XCTAssertTrue(SettingsOptionLists.isValidSubtitlePosition("top"))
        XCTAssertFalse(SettingsOptionLists.isValidSubtitlePosition("left"))
        XCTAssertEqual(
            SettingsOptionLists.label(
                for: "cyan",
                in: SettingsOptionLists.subtitleColorOptions,
                default: SettingsOptionLists.subtitleColorDefault
            ),
            "青色"
        )
        XCTAssertEqual(
            SettingsOptionLists.label(
                for: "nowhere",
                in: SettingsOptionLists.subtitlePositionOptions,
                default: SettingsOptionLists.subtitlePositionDefault
            ),
            "底部"
        )
    }

    func testLowMemoryOptionsAreTheFlutterValues() {
        XCTAssertTrue(SettingsOptionLists.isValidLowMemoryMode("auto"))
        XCTAssertTrue(SettingsOptionLists.isValidLowMemoryMode("always"))
        XCTAssertTrue(SettingsOptionLists.isValidLowMemoryMode("never"))
        XCTAssertFalse(SettingsOptionLists.isValidLowMemoryMode("sometimes"))
        XCTAssertEqual(
            SettingsOptionLists.label(
                for: "always",
                in: SettingsOptionLists.lowMemoryOptions,
                default: SettingsOptionLists.lowMemoryDefault
            ),
            "始终开启"
        )
    }

    // MARK: - Normalisation strength label

    func testNormalizationStrengthLabels() {
        XCTAssertEqual(NormalizationStrengthLabel.label(for: 0), "弱")
        XCTAssertEqual(NormalizationStrengthLabel.label(for: 0.5), "弱")
        XCTAssertEqual(NormalizationStrengthLabel.label(for: 1.0), "中")
        XCTAssertEqual(NormalizationStrengthLabel.label(for: 1.5), "强")
        XCTAssertEqual(NormalizationStrengthLabel.label(for: 2.0), "强")
    }

    // MARK: - "Keep at least one" guard

    func testKeepOneGuard() {
        XCTAssertFalse(SourceKeepOneGuard.canDisable(enabledCount: 1))
        XCTAssertFalse(SourceKeepOneGuard.canDisable(enabledCount: 0))
        XCTAssertTrue(SourceKeepOneGuard.canDisable(enabledCount: 2))
        XCTAssertTrue(SourceKeepOneGuard.canDisable(enabledCount: 18))
    }

    // MARK: - Live platform prefs (pure)

    func testLiveEnabledIDsDefaultToAllFive() {
        XCTAssertEqual(LiveSourcePrefs.enabledIDs(from: nil), LiveSourcePrefs.allIDs)
        XCTAssertEqual(LiveSourcePrefs.enabledIDs(from: []), LiveSourcePrefs.allIDs)
        XCTAssertEqual(
            LiveSourcePrefs.enabledIDs(from: ["nope", "alsono"]),
            LiveSourcePrefs.allIDs
        )
    }

    func testLiveEnabledIDsKeepFlutterOrder() {
        XCTAssertEqual(
            LiveSourcePrefs.enabledIDs(from: ["kuaishou", "bilibili"]),
            ["bilibili", "kuaishou"]
        )
        XCTAssertEqual(
            LiveSourcePrefs.enabledIDs(from: ["douyin", "bilibili", "bogus"]),
            ["bilibili", "douyin"]
        )
    }

    func testLiveSettingEnabledRefusesLastOne() {
        XCTAssertNil(LiveSourcePrefs.settingEnabled(
            ["bilibili"], siteId: "bilibili", value: false
        ))
        XCTAssertEqual(
            LiveSourcePrefs.settingEnabled(
                ["bilibili", "douyu"], siteId: "douyu", value: false
            ),
            ["bilibili"]
        )
        XCTAssertEqual(
            LiveSourcePrefs.settingEnabled(
                ["bilibili"], siteId: "douyu", value: true
            ),
            ["bilibili", "douyu"]
        )
        XCTAssertEqual(
            LiveSourcePrefs.settingEnabled(
                ["bilibili"], siteId: "bilibili", value: true
            ),
            ["bilibili"]
        )
    }

    func testLivePrefsRoundTripInIsolatedDirectory() {
        XCTAssertEqual(LiveSourcePrefs.load(documentsDirectory: docs), LiveSourcePrefs.allIDs)
        LiveSourcePrefs.save(["bilibili", "huya"], documentsDirectory: docs)
        XCTAssertEqual(
            LiveSourcePrefs.load(documentsDirectory: docs),
            ["bilibili", "huya"]
        )
        LiveSourcePrefs.save([], documentsDirectory: docs)
        XCTAssertEqual(LiveSourcePrefs.load(documentsDirectory: docs), LiveSourcePrefs.allIDs)
    }

    // MARK: - LX list ordering

    func testLXOrderingRespectsSavedOrderAndDropsDeleted() {
        let custom = LxCustomScriptRecord(
            id: "custom:file:abc123",
            name: "我的脚本",
            url: "https://example.com/x.js",
            fileName: "custom-file-abc123.js",
            addedAt: Date()
        )
        let rows = LXSourceListOrdering.orderedRows(
            bundledIDs: ["suyin", "jiexiang", "huibi"],
            customRecords: [custom],
            deletedBundledIDs: ["jiexiang"],
            savedOrder: ["huibi", "custom:file:abc123", "suyin"]
        )
        XCTAssertEqual(
            rows.map { $0.id },
            ["huibi", "custom:file:abc123", "suyin"]
        )
        XCTAssertEqual(rows.first { $0.id == "custom:file:abc123" }?.isCustom, true)
        XCTAssertEqual(rows.first { $0.id == "huibi" }?.isCustom, false)
    }

    func testLXOrderingWithoutSavedOrderKeepsSeedOrder() {
        let rows = LXSourceListOrdering.orderedRows(
            bundledIDs: ["suyin", "jiexiang", "huibi"],
            customRecords: [],
            deletedBundledIDs: [],
            savedOrder: []
        )
        XCTAssertEqual(rows.map { $0.id }, ["suyin", "jiexiang", "huibi"])
    }
}

// HAo Studio 2.0 — danmaku settings tests (S4 leg B).
//
// Defaults, clamps, dictionary round-trip, wrong-type fallback,
// Flutter-shaped per-platform keys. No network.
// Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class LiveDanmakuSettingsTests: XCTestCase {
    func testDefaultsMatchTheFlutterPage() {
        let settings = LiveDanmakuSettings()
        XCTAssertEqual(settings.fontSize, 14)
        XCTAssertEqual(settings.opacity, 1.0)
        XCTAssertEqual(settings.area, "full")
        XCTAssertTrue(settings.stroke)
        XCTAssertEqual(settings.strokeWidth, 1.0)
        XCTAssertEqual(settings.speed, 1.0)
        XCTAssertEqual(settings.maxCount, 80)
        XCTAssertEqual(settings.colorMode, "uniform")
        XCTAssertFalse(settings.occlusionAvoidance)
        XCTAssertEqual(settings.listStyle, "compact")
        XCTAssertEqual(settings.listSpacing, "standard")
        XCTAssertTrue(settings.showUsernames)
        XCTAssertTrue(settings.similarityEnabled)
        XCTAssertEqual(settings.similarityThreshold, 85)
        XCTAssertFalse(settings.blockEmoteOnly)
        XCTAssertFalse(settings.blockLong)
        XCTAssertEqual(settings.blockLongLength, 30)
        XCTAssertFalse(settings.douyuBotFilter)
        XCTAssertTrue(settings.enabled.isEmpty)
    }

    func testAbsentPlatformIsEnabledExceptVod() {
        let settings = LiveDanmakuSettings()
        XCTAssertTrue(settings.isEnabled("bilibili"))
        XCTAssertTrue(settings.isEnabled("kuaishou"))
        XCTAssertFalse(settings.isEnabled("vod"))
        XCTAssertTrue(settings.isEnabled(for: .bilibili))
        XCTAssertTrue(settings.isEnabled(for: .kuaishou))
    }

    func testEnabledMapIsKeyedByFlutterSiteIdNotPlayerId() {
        // The migrated Hive map uses Flutter ids (bilibili/kuaishou),
        // while the player kernel uses bili/ks. Keying by rawValue
        // would silently drop the migrated Bilibili/Kuaishou switches.
        var settings = LiveDanmakuSettings()
        settings.setEnabled(false, for: .bilibili)
        settings.setEnabled(false, for: .kuaishou)
        XCTAssertEqual(settings.enabled["bilibili"], false)
        XCTAssertEqual(settings.enabled["kuaishou"], false)
        XCTAssertNil(settings.enabled["bili"])
        XCTAssertNil(settings.enabled["ks"])
        XCTAssertFalse(settings.isEnabled(for: .bilibili))
        XCTAssertFalse(settings.isEnabled(for: .kuaishou))
        XCTAssertTrue(settings.isEnabled(for: .douyu))
    }

    func testInitClampsOutOfRangeValues() {
        let settings = LiveDanmakuSettings(
            fontSize: 99, opacity: 0, strokeWidth: 99, speed: 0,
            maxCount: 1, similarityThreshold: 500, blockLongLength: 1
        )
        XCTAssertEqual(settings.fontSize, 20)
        XCTAssertEqual(settings.opacity, 0.3)
        XCTAssertEqual(settings.strokeWidth, 2.0)
        XCTAssertEqual(settings.speed, 0.5)
        XCTAssertEqual(settings.maxCount, 20)
        XCTAssertEqual(settings.similarityThreshold, 100)
        XCTAssertEqual(settings.blockLongLength, 10)
    }

    func testInitNormalisesUnknownEnumStrings() {
        let settings = LiveDanmakuSettings(
            area: "quarter", colorMode: "rainbow",
            listStyle: "grid", listSpacing: "wide"
        )
        XCTAssertEqual(settings.area, "full")
        XCTAssertEqual(settings.colorMode, "uniform")
        XCTAssertEqual(settings.listStyle, "compact")
        XCTAssertEqual(settings.listSpacing, "standard")
    }

    func testDictionaryRoundTrip() {
        var settings = LiveDanmakuSettings()
        settings.fontSize = 18
        settings.opacity = 0.5
        settings.area = "half"
        settings.douyuBotFilter = true
        settings.setEnabled(false, for: .douyu)
        let restored = LiveDanmakuSettings(dictionary: settings.dictionary())
        XCTAssertEqual(restored.fontSize, 18)
        XCTAssertEqual(restored.opacity, 0.5)
        XCTAssertEqual(restored.area, "half")
        XCTAssertTrue(restored.douyuBotFilter)
        XCTAssertFalse(restored.isEnabled(for: .douyu))
        XCTAssertTrue(restored.isEnabled(for: .huya))
    }

    func testDictionaryWrongTypesFallBackToDefaults() {
        let restored = LiveDanmakuSettings(dictionary: [
            LiveDanmakuSettings.keyFontSize: "huge",
            LiveDanmakuSettings.keyOpacity: [1, 2],
            LiveDanmakuSettings.keyMaxCount: "eighty",
            LiveDanmakuSettings.keyEnabled: "not-a-map"
        ])
        XCTAssertEqual(restored.fontSize, 14)
        XCTAssertEqual(restored.opacity, 1.0)
        XCTAssertEqual(restored.maxCount, 80)
        XCTAssertTrue(restored.enabled.isEmpty)
    }

    func testDictionaryAcceptsJsonStringEnabledMap() {
        let restored = LiveDanmakuSettings(dictionary: [
            LiveDanmakuSettings.keyEnabled: "{\"bilibili\":false}"
        ])
        XCTAssertFalse(restored.isEnabled(for: .bilibili))
        XCTAssertTrue(restored.isEnabled(for: .douyu))
    }

    func testDerivedValues() {
        let settings = LiveDanmakuSettings(area: "half", speed: 1.5, maxCount: 200)
        XCTAssertEqual(settings.areaFraction, 0.5)
        XCTAssertEqual(settings.flyingBaseSpeed, 180.0)
        XCTAssertEqual(settings.flyingMaxVisibleCount, 72)
        let small = LiveDanmakuSettings(maxCount: 20)
        XCTAssertEqual(small.flyingMaxVisibleCount, 20)
    }

    func testBlockedEntriesDictionaryRoundTrip() {
        let settings = LiveDanmakuSettings(blockedEntries: [
            LiveDanmakuBlockEntry(id: "1", text: "spam", isUser: false),
            LiveDanmakuBlockEntry(id: "2", text: "bot-name", isUser: true)
        ])
        let restored = LiveDanmakuSettings(dictionary: settings.dictionary())
        XCTAssertEqual(restored.blockedEntries.count, 2)
        XCTAssertEqual(restored.blockedEntries[0].text, "spam")
        XCTAssertFalse(restored.blockedEntries[0].isUser)
        XCTAssertTrue(restored.blockedEntries[1].isUser)
    }

    func testBlockedEntriesAcceptsJsonStringAndIsUserForm() {
        let fromJsonString = LiveDanmakuSettings(dictionary: [
            LiveDanmakuSettings.keyBlockedEntries: "[{\"id\":\"1\",\"text\":\"spam\",\"kind\":\"word\"}]"
        ])
        XCTAssertEqual(fromJsonString.blockedEntries.count, 1)
        XCTAssertFalse(fromJsonString.blockedEntries[0].isUser)
        let fromIsUser = LiveDanmakuSettings(dictionary: [
            LiveDanmakuSettings.keyBlockedEntries: [["id": "2", "text": "bot", "isUser": true]]
        ])
        XCTAssertEqual(fromIsUser.blockedEntries.count, 1)
        XCTAssertTrue(fromIsUser.blockedEntries[0].isUser)
    }

    /// The room page's danmaku switch (2026-11-24 round, item 3):
    /// flipping the per-platform flag twice returns to the
    /// original state, one platform never moves another, and VOD
    /// defaults off (opt-in — its title guess can be wrong).
    func testToggleFlipsPerPlatformSwitch() {
        var settings = LiveDanmakuSettings()
        XCTAssertTrue(settings.isEnabled(for: .bilibili))
        settings.setEnabled(!settings.isEnabled(for: .bilibili), for: .bilibili)
        XCTAssertFalse(settings.isEnabled(for: .bilibili))
        settings.setEnabled(!settings.isEnabled(for: .bilibili), for: .bilibili)
        XCTAssertTrue(settings.isEnabled(for: .bilibili))
        XCTAssertTrue(settings.isEnabled(for: .douyu))
        XCTAssertFalse(settings.isEnabled(LiveDanmakuSettings.vodSiteId))
    }
}

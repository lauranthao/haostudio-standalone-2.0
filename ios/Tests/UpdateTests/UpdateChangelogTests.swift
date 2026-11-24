// HAo Studio 2.0 — changelog locale tests (build 36, item 8, F5).
//
// The update sheet must show the Traditional entry to Traditional
// users: `Locale.current.languageCode` returns only "zh" (no script
// subtag), and the old exact-match switch never saw a Traditional
// tag — so every Traditional user got the Simplified notes. The
// checker now passes the full BCP 47 tag from
// `Locale.preferredLanguages`, and `localized(for:)` normalizes +
// prefix-matches it.

import Foundation
import XCTest

@testable import AppCore

final class UpdateChangelogTests: XCTestCase {
    private let changelog = UpdateChangelog(
        zh: "简体说明", tw: "繁體說明", en: "English notes", text: nil)

    func testTraditionalFullTag() {
        XCTAssertEqual(changelog.localized(for: "zh-Hant-TW"), "繁體說明")
    }

    func testTraditionalScriptOnly() {
        XCTAssertEqual(changelog.localized(for: "zh-Hant"), "繁體說明")
    }

    func testTraditionalRegionOnly() {
        XCTAssertEqual(changelog.localized(for: "zh-TW"), "繁體說明")
        XCTAssertEqual(changelog.localized(for: "zh-HK"), "繁體說明")
        XCTAssertEqual(changelog.localized(for: "zh-MO"), "繁體說明")
    }

    func testSimplifiedFullTag() {
        XCTAssertEqual(changelog.localized(for: "zh-Hans-CN"), "简体说明")
    }

    func testBareZhIsSimplified() {
        // What Locale.current.languageCode returns: no script, so
        // the Simplified entry is the only honest reading.
        XCTAssertEqual(changelog.localized(for: "zh"), "简体说明")
    }

    func testEnglishWithRegion() {
        XCTAssertEqual(changelog.localized(for: "en-US"), "English notes")
    }

    func testUnknownFallsBackToSimplifiedFirst() {
        XCTAssertEqual(changelog.localized(for: "ja"), "简体说明")
    }

    func testNilFallsBackToSimplifiedFirst() {
        XCTAssertEqual(changelog.localized(for: nil), "简体说明")
    }

    func testPlainTextFallbackWhenEntryMissing() {
        let textOnly = UpdateChangelog(zh: nil, tw: nil, en: nil, text: "plain")
        XCTAssertEqual(textOnly.localized(for: "zh-Hant-TW"), "plain")
        XCTAssertEqual(textOnly.localized(for: "en"), "plain")
    }

    func testMissingEntryFallsBackAcrossLanguages() {
        // A manifest that carries only the Simplified entry must
        // still show notes to a Traditional user instead of none.
        let zhOnly = UpdateChangelog(zh: "简体说明", tw: nil, en: nil, text: nil)
        XCTAssertEqual(zhOnly.localized(for: "zh-Hant-TW"), "简体说明")
        XCTAssertEqual(zhOnly.localized(for: "en"), "简体说明")
        let twOnly = UpdateChangelog(zh: nil, tw: "繁體說明", en: nil, text: nil)
        XCTAssertEqual(twOnly.localized(for: "zh-Hans-CN"), "繁體說明")
        XCTAssertEqual(twOnly.localized(for: "en"), "繁體說明")
    }
}

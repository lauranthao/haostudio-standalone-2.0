// HAo Studio 2.0 — backup + update pure-logic tests (S6-B leg).
//
// Wired: SettingsTests target (AppCore), same as
// SettingsGroupsLogicTests. Run with `swift test` from ios/.
// (Not run here: this VM has no Swift toolchain — see the S6-B
// leg report.)

import XCTest

@testable import AppCore

final class BackupUpdateLogicTests: XCTestCase {
    // MARK: - Version comparison
    //
    // b49fix2 P2-61: UpdateCheckLogic.isNewer is deleted — it had
    // zero production callers (production compares through
    // VersionCompare in DefaultUpdateChecker), so its six tests
    // went with it. The live comparator's behaviour is covered in
    // VersionCompareTests, including the non-numeric-part quirk.

    func testVersionIdentity() {
        XCTAssertEqual(UpdateCheckLogic.versionIdentity(version: "1.1.7", build: 12), "1.1.7 (build 12)")
    }

    // MARK: - minOs

    func testParseMinOs() {
        let twoPart = UpdateCheckLogic.parseMinOs("17.0")
        XCTAssertEqual(twoPart?.major, 17)
        XCTAssertEqual(twoPart?.minor, 0)
        XCTAssertEqual(twoPart?.patch, 0)
        let onePart = UpdateCheckLogic.parseMinOs("17")
        XCTAssertEqual(onePart?.major, 17)
        XCTAssertEqual(onePart?.minor, 0)
        XCTAssertEqual(onePart?.patch, 0)
        let threePart = UpdateCheckLogic.parseMinOs("17.0.1")
        XCTAssertEqual(threePart?.patch, 1)
    }

    func testParseMinOsRejectsBadInput() {
        XCTAssertNil(UpdateCheckLogic.parseMinOs(""))
        XCTAssertNil(UpdateCheckLogic.parseMinOs("17.x"))
        XCTAssertNil(UpdateCheckLogic.parseMinOs("17.0.0.0"))
    }

    func testCanInstall() {
        XCTAssertTrue(UpdateCheckLogic.canInstall(deviceVersion: (major: 17, minor: 0, patch: 0), minOs: "17.0"))
        XCTAssertTrue(UpdateCheckLogic.canInstall(deviceVersion: (major: 17, minor: 0, patch: 1), minOs: "17.0"))
        XCTAssertTrue(UpdateCheckLogic.canInstall(deviceVersion: (major: 18, minor: 0, patch: 0), minOs: "17.0"))
        XCTAssertFalse(UpdateCheckLogic.canInstall(deviceVersion: (major: 16, minor: 7, patch: 0), minOs: "17.0"))
        XCTAssertFalse(UpdateCheckLogic.canInstall(deviceVersion: (major: 17, minor: 0, patch: 0), minOs: "17.0.1"))
    }

    func testUnknownMinOsDoesNotBlock() {
        XCTAssertTrue(UpdateCheckLogic.canInstall(deviceVersion: (major: 17, minor: 0, patch: 0), minOs: "bogus"))
    }

    // MARK: - Last-check label

    func testNeverCheckedLabel() {
        XCTAssertEqual(UpdateCheckLogic.lastCheckLabel(date: nil, now: Date()), "从未检查")
    }

    func testTodayLabel() {
        let now = Date()
        XCTAssertTrue(UpdateCheckLogic.lastCheckLabel(date: now, now: now).hasPrefix("今天 "))
    }

    func testYesterdayLabel() {
        let now = Date()
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) else {
            XCTFail("could not compute yesterday")
            return
        }
        XCTAssertTrue(UpdateCheckLogic.lastCheckLabel(date: yesterday, now: now).hasPrefix("昨天 "))
    }

    func testOlderDateLabel() {
        let now = Date()
        guard let old = Calendar.current.date(byAdding: .day, value: -10, to: now) else {
            XCTFail("could not compute old date")
            return
        }
        let label = UpdateCheckLogic.lastCheckLabel(date: old, now: now)
        XCTAssertFalse(label.hasPrefix("今天"))
        XCTAssertFalse(label.hasPrefix("昨天"))
        XCTAssertTrue(label.contains("-"))
    }

    // MARK: - Import result message

    func testCleanImportMessage() {
        let report = BackupImportReport(importedCount: 120, skippedKeys: [], rolledBack: false, embyCredentialsMissing: false)
        XCTAssertEqual(UpdateCheckLogic.importResultTitle(report: report), "导入完成")
        XCTAssertEqual(UpdateCheckLogic.importResultMessage(report: report), "成功导入 120 项。")
    }

    func testImportMessageListsSkippedKeysAndEmbyWarning() {
        let report = BackupImportReport(importedCount: 118, skippedKeys: ["weirdKey", "oldKey"], rolledBack: false, embyCredentialsMissing: true)
        let message = UpdateCheckLogic.importResultMessage(report: report)
        XCTAssertTrue(message.contains("成功导入 118 项。"))
        XCTAssertTrue(message.contains("跳过了 2 个无法识别的键：weirdKey、oldKey。"))
        XCTAssertTrue(message.contains("备份里没有 Emby 凭证，导入后请重新登录 Emby。"))
    }

    func testRolledBackTitleAndMessage() {
        let report = BackupImportReport(importedCount: 0, skippedKeys: [], rolledBack: true, embyCredentialsMissing: false)
        XCTAssertEqual(UpdateCheckLogic.importResultTitle(report: report), "导入失败，已回滚")
        XCTAssertTrue(UpdateCheckLogic.importResultMessage(report: report).contains("已全部回滚，现有数据未动。"))
    }

    func testFix30ImportResultFailureBranchesLiteral() {
        // D31-2: the two failure branches of importResultTitle /
        // importResultMessage had zero coverage — no test ever
        // built a BackupImportReport with a non-default
        // rollbackFailures / nothingWritten. Literal equality,
        // so a swapped title or a dropped "请检查这些项目。"
        // fails.
        let nothingWritten = BackupImportReport(importedCount: 0, skippedKeys: [], rolledBack: true, embyCredentialsMissing: false, rollbackFailures: [], nothingWritten: true)
        XCTAssertEqual(UpdateCheckLogic.importResultTitle(report: nothingWritten), "导入失败")
        XCTAssertEqual(UpdateCheckLogic.importResultMessage(report: nothingWritten), "导入失败，未写入任何内容，现有数据未动。")
        let incomplete = BackupImportReport(importedCount: 0, skippedKeys: [], rolledBack: true, embyCredentialsMissing: false, rollbackFailures: ["f0"])
        XCTAssertEqual(UpdateCheckLogic.importResultTitle(report: incomplete), "导入失败，回滚未完成")
        XCTAssertEqual(UpdateCheckLogic.importResultMessage(report: incomplete), "导入中途失败，回滚未完成，未恢复：f0。请检查这些项目。")
        // Multi-element failures join with "、".
        let multi = BackupImportReport(importedCount: 0, skippedKeys: [], rolledBack: true, embyCredentialsMissing: false, rollbackFailures: ["f0", "f1"])
        XCTAssertEqual(UpdateCheckLogic.importResultMessage(report: multi), "导入中途失败，回滚未完成，未恢复：f0、f1。请检查这些项目。")
    }

    func testImportMessageIncludesWarnings() {
        // b35-sweep-settings: engine warnings (e.g. ignored zip
        // entries) must reach the result alert, not be dropped.
        let report = BackupImportReport(
            importedCount: 5, skippedKeys: [], rolledBack: false,
            embyCredentialsMissing: false,
            warnings: ["忽略了无法识别的备份条目：strange.txt"])
        let message = UpdateCheckLogic.importResultMessage(report: report)
        XCTAssertTrue(message.contains("成功导入 5 项。"))
        XCTAssertTrue(message.contains("忽略了无法识别的备份条目：strange.txt"))
    }

    func testFix30LegacyImportSuccessMessageLiteral() {
        // D31-4: Route B's legacy success message had zero
        // coverage — "已从旧版备份导入" had 0 hits in Tests.
        // Literal equality, so a dropped warnings suffix
        // (the b49fix19 P1-5 regression) fails.
        let plain = MigrationReport(outcome: .migrated, totalKeys: 8, migratedKeys: 5, skippedKeys: 2, unknownKeys: 1, failedKeys: 0, skippedKeyNames: [], unknownKeyNames: [], detail: "")
        XCTAssertEqual(UpdateCheckLogic.legacyImportSuccessMessage(report: plain), "已从旧版备份导入 5 项设置（合并导入：备份里没有的项会保留现在的值；跳过 2 项，未识别 1 项）。")
        var warned = plain
        warned.warnings = ["影视历史有 1 条记录格式不符，已跳过", "跳过了 1 个键"]
        XCTAssertEqual(UpdateCheckLogic.legacyImportSuccessMessage(report: warned), "已从旧版备份导入 5 项设置（合并导入：备份里没有的项会保留现在的值；跳过 2 项，未识别 1 项）。\n影视历史有 1 条记录格式不符，已跳过\n跳过了 1 个键")
    }

    // MARK: - Update prompt content

    private func makeResult(
        version: String? = "1.1.7",
        build: Int? = 12,
        minOs: String? = "17.0",
        downloadURL: URL? = URL(string: "https://example.com/app.ipa"),
        notes: String? = "修了闪退。",
        requiresNewerOS: Bool = false,
        isSkipped: Bool = false
    ) -> UpdateCheckResult {
        UpdateCheckResult(
            latestVersion: version, latestBuild: build, minOs: minOs,
            downloadURL: downloadURL, releaseNotes: notes,
            requiresNewerOS: requiresNewerOS, isSkipped: isSkipped,
            failureMessage: nil)
    }

    func testPromptContentInstallable() {
        let content = UpdateCheckLogic.promptContent(result: makeResult(), deviceVersion: (major: 17, minor: 0, patch: 0))
        XCTAssertEqual(content.versionLabel, "1.1.7 (build 12)")
        XCTAssertEqual(content.releaseNotes, "修了闪退。")
        XCTAssertTrue(content.canInstall)
        XCTAssertNil(content.blockedMessage)
        XCTAssertTrue(content.showUpdateButton)
    }

    func testPromptContentBlockedByMinOs() {
        let content = UpdateCheckLogic.promptContent(result: makeResult(minOs: "18.0", requiresNewerOS: true), deviceVersion: (major: 17, minor: 0, patch: 0))
        XCTAssertFalse(content.canInstall)
        XCTAssertEqual(content.blockedMessage, "新版需要 iOS 18.0 以上，你的设备装不上")
        XCTAssertFalse(content.showUpdateButton)
    }

    func testPromptContentBlockedEvenWhenCheckerFlagSaysOk() {
        let content = UpdateCheckLogic.promptContent(result: makeResult(minOs: "18.0", requiresNewerOS: false), deviceVersion: (major: 17, minor: 0, patch: 0))
        XCTAssertFalse(content.canInstall)
        XCTAssertFalse(content.showUpdateButton)
    }

    func testPromptContentNoDownloadURLHidesUpdateButton() {
        let content = UpdateCheckLogic.promptContent(result: makeResult(downloadURL: nil), deviceVersion: (major: 17, minor: 0, patch: 0))
        XCTAssertTrue(content.canInstall)
        XCTAssertFalse(content.showUpdateButton)
    }

    func testPromptContentMissingNotesFallsBack() {
        let content = UpdateCheckLogic.promptContent(result: makeResult(notes: nil), deviceVersion: (major: 17, minor: 0, patch: 0))
        XCTAssertEqual(content.releaseNotes, "本次更新没有附带更新说明。")
        let blank = UpdateCheckLogic.promptContent(result: makeResult(notes: "   "), deviceVersion: (major: 17, minor: 0, patch: 0))
        XCTAssertEqual(blank.releaseNotes, "本次更新没有附带更新说明。")
    }
}

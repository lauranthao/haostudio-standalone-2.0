// HAo Studio 2.0 — backup + update UI tests (S6-B leg).
//
// WIRED (S7): runs under the `HAoStudioTests` Xcode test target,
// not from `swift test`. The assertions below only touch pure
// logic (UpdatePromptContent); the S7 wiring change was the import
// line (`@testable import HAoStudio`), same as MyEntriesTests.
// What these tests CANNOT cover (verify by hand at merge): the
// sheet actually appears on check, the fileImporter opens the
// .zip picker, ShareLink shares the exported file, the alert
// shows after import. See the S6-B leg report.

import XCTest

@testable import HAoStudio

final class BackupUpdateUITests: XCTestCase {
    private func makeResult(
        minOs: String? = "17.0",
        downloadURL: URL? = URL(string: "https://example.com/app.ipa"),
        notes: String? = "新功能。",
        requiresNewerOS: Bool = false
    ) -> UpdateCheckResult {
        UpdateCheckResult(
            latestVersion: "1.1.7", latestBuild: 12, minOs: minOs,
            downloadURL: downloadURL, releaseNotes: notes,
            requiresNewerOS: requiresNewerOS, isSkipped: false,
            failureMessage: nil)
    }

    /// A blocked build must never offer an update button — the
    /// sheet's only actions are skip / later.
    func testBlockedBuildOffersNoUpdateAction() {
        let content = UpdateCheckLogic.promptContent(result: makeResult(minOs: "18.0", requiresNewerOS: true), deviceVersion: (major: 17, minor: 0, patch: 0))
        XCTAssertFalse(content.showUpdateButton)
        XCTAssertNotNil(content.blockedMessage)
    }

    /// An installable build with a download URL offers update.
    func testInstallableBuildOffersUpdateAction() {
        let content = UpdateCheckLogic.promptContent(result: makeResult(), deviceVersion: (major: 17, minor: 0, patch: 0))
        XCTAssertTrue(content.showUpdateButton)
        XCTAssertNil(content.blockedMessage)
    }

    /// An installable build WITHOUT a download URL must not offer
    /// an update button that leads nowhere.
    func testInstallableBuildWithoutURLOffersNoUpdateAction() {
        let content = UpdateCheckLogic.promptContent(result: makeResult(downloadURL: nil), deviceVersion: (major: 17, minor: 0, patch: 0))
        XCTAssertTrue(content.canInstall)
        XCTAssertFalse(content.showUpdateButton)
    }

    /// The sheet always shows notes — manifest notes, or the
    /// fallback line when the manifest has none.
    func testSheetAlwaysShowsNotes() {
        let withNotes = UpdateCheckLogic.promptContent(result: makeResult(notes: "新功能。"), deviceVersion: (major: 17, minor: 0, patch: 0))
        XCTAssertEqual(withNotes.releaseNotes, "新功能。")
        let withoutNotes = UpdateCheckLogic.promptContent(result: makeResult(notes: nil), deviceVersion: (major: 17, minor: 0, patch: 0))
        XCTAssertEqual(withoutNotes.releaseNotes, "本次更新没有附带更新说明。")
    }
}

// MARK: - Snapshot restore message (b49fix30 D31-3)
//
// BackupSnapshotView.restoreMessage had zero coverage — every
// branch (manifest error, zero restore, non-zero restore with
// the safety-net line, partial restore) was unasserted, and a
// swapped safety-net ternary would have told the user a
// safety-net snapshot existed when it did not. Literal
// equality on every branch × safetyNetTaken, so a swapped arm
// or a dropped line fails. Runs under the HAoStudioTests Xcode
// target (@testable import HAoStudio), not `swift test`.
final class RestoreMessageTests: XCTestCase {
    private func result(
        manifestError: String? = nil,
        keys: Int = 0, files: Int = 0,
        failedKeys: [String] = [], failedFiles: [String] = [],
        dropped: [String: Int] = [:]
    ) -> BackupEngineCore.SnapshotRestoreResult {
        BackupEngineCore.SnapshotRestoreResult(
            manifestError: manifestError, restoredKeys: keys, restoredFiles: files,
            failedKeys: failedKeys, failedFiles: failedFiles,
            historyNormalizedDropped: dropped)
    }

    func testFix30RestoreMessageManifestError() {
        let taken = BackupSnapshotView.restoreMessage(for: result(manifestError: "快照清单损坏。"), safetyNetTaken: true)
        XCTAssertEqual(taken, "快照清单损坏。\n恢复前已为当前状态保存一份快照，可恢复刚拍的安全网快照撤销。")
        let notTaken = BackupSnapshotView.restoreMessage(for: result(manifestError: "快照清单损坏。"), safetyNetTaken: false)
        XCTAssertEqual(notTaken, "快照清单损坏。\n本次恢复没有安全网快照。")
    }

    func testFix30RestoreMessageZeroRestore() {
        XCTAssertEqual(
            BackupSnapshotView.restoreMessage(for: result(), safetyNetTaken: true),
            "没有需要恢复的内容（当前状态与该快照一致）。")
    }

    func testFix30RestoreMessageSuccessWithDroppedHistory() {
        // Dropped history lines sort by file key: hao_live_hist
        // ("直播") before hao_video_hist ("影视").
        let taken = BackupSnapshotView.restoreMessage(
            for: result(keys: 3, files: 2, dropped: ["hao_video_hist": 2, "hao_live_hist": 1]),
            safetyNetTaken: true)
        XCTAssertEqual(taken, "已恢复 3 个设置、2 个文件。导入后新建的歌单、下载不受影响。恢复前已为当前状态保存一份快照。\n直播历史有 1 条记录格式不符，已跳过。\n影视历史有 2 条记录格式不符，已跳过。")
        let notTaken = BackupSnapshotView.restoreMessage(
            for: result(keys: 1, files: 0),
            safetyNetTaken: false)
        XCTAssertEqual(notTaken, "已恢复 1 个设置、0 个文件。导入后新建的歌单、下载不受影响。恢复前未能保存安全网快照。")
    }

    func testFix30RestoreMessagePartialRestore() {
        let taken = BackupSnapshotView.restoreMessage(
            for: result(keys: 1, files: 0, failedKeys: ["k1", "k2"], failedFiles: ["f1"], dropped: ["hao_video_hist": 1]),
            safetyNetTaken: true)
        XCTAssertEqual(taken, "恢复未完成：\n已恢复 1 个设置、0 个文件。\n未恢复的设置：k1、k2。\n未恢复的文件：f1。\n影视历史有 1 条记录格式不符，已跳过。\n恢复前已为当前状态保存一份快照，可恢复刚拍的安全网快照撤销。")
        // Nothing restored yet, keys only, no safety net.
        let notTaken = BackupSnapshotView.restoreMessage(
            for: result(failedKeys: ["k1"]),
            safetyNetTaken: false)
        XCTAssertEqual(notTaken, "恢复未完成：\n未恢复的设置：k1。\n本次恢复没有安全网快照。")
    }
}

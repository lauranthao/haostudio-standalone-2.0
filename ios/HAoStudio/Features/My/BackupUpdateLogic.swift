// HAo Studio 2.0 — backup + update pure logic (S6-B leg).
//
// Foundation ONLY (no SwiftUI / UIKit): this file joins AppCore
// (see Package.swift, next to SettingsLogic.swift) so the
// SettingsTests target covers it under `swift test`. The SwiftUI
// flow in BackupUpdateViews.swift calls these; the app target
// never duplicates them.
//
// The engine / checker seam (completion handlers only — the
// project pins Swift 5.0 and preflight check 5e forbids the
// async keyword): `BackupEngine` / `UpdateChecker` below.
// A leg implements BackupEngine with FileBackupEngine; C leg
// implements UpdateChecker with DefaultUpdateChecker. (An early
// draft of this comment quoted async signatures from the brief;
// those were corrected at merge — the seam below is the real one.)
// - `BackupImportReport` / `UpdateCheckResult` are declared here
//   with exactly the brief's fields. If the A/C legs declare the
//   same types, THESE declarations are deleted at merge — one
//   type, one file (S3 lesson), never two.
// - No new UserDefaults key is invented here: skip/throttle keys
//   belong to the C leg; the UI only reads them through the
//   checker (`skippedVersionLabel`, `lastCheckDate`).
// - Emby credentials live in the Keychain, never in a backup:
//   the export footnote says so, and the import report carries
//   `embyCredentialsMissing` so the result alert can warn that
//   Emby needs a fresh login.

import Foundation

// MARK: - Assumed engine / checker seam (completion-handler form)

/// Backup engine (A leg). Completions arrive on the main thread
/// (same contract as CacheManager).
protocol BackupEngine {
    func exportBackup(completion: @escaping (Result<URL, Error>) -> Void)
    func importBackup(from url: URL, completion: @escaping (Result<BackupImportReport, Error>) -> Void)
}

/// Update checker (C leg). The `checkForUpdate` completion
/// arrives on the main thread. Skip/throttle storage is the
/// checker's own — the UI never touches the keys directly.
protocol UpdateChecker {
    func checkForUpdate(completion: @escaping (UpdateCheckResult) -> Void)
    /// Last successful manifest fetch, or nil when never checked.
    var lastCheckDate: Date? { get }
    /// "1.1.7 (build 12)" when a version is skipped, else nil.
    var skippedVersionLabel: String? { get }
    func skip(version: String, build: Int)
    func clearSkippedVersion()
}

// MARK: - Import report (A leg)

/// What the backup engine reports after an import. Field names
/// follow the brief: success count, skipped keys, rollback flag,
/// Emby-not-exported warning.
struct BackupImportReport {
    var importedCount: Int
    var skippedKeys: [String]
    var rolledBack: Bool
    var embyCredentialsMissing: Bool
    /// Non-fatal warnings from the import (e.g. unrecognised zip
    /// entries that were ignored). b35-sweep-settings: previously
    /// the engine produced these but FileBackupEngine dropped
    /// them, so the user never saw them.
    var warnings: [String] = []
}

// MARK: - Update check result (C leg)

/// What the update checker reports. `latestVersion == nil` means
/// already on the latest version; `failureMessage != nil` means
/// this check fetched nothing (offline / timeout).
struct UpdateCheckResult: Identifiable {
    var latestVersion: String?
    var latestBuild: Int?
    var minOs: String?
    var downloadURL: URL?
    var releaseNotes: String?
    /// Expected IPA size in bytes from the manifest (b49fix2
    /// P1-40): the downloader requires the received byte count
    /// to equal this when it is known. Nil = the manifest
    /// carries no size.
    var size: Int? = nil
    /// Expected SHA-256 hex of the IPA from the manifest
    /// (b49fix2 P1-40): verified when present. Nil = no hash.
    var sha256: String? = nil
    /// True when the latest build needs a newer iOS than this device.
    var requiresNewerOS: Bool
    /// True when this version+build was skipped by the user.
    var isSkipped: Bool
    /// Non-nil when the check itself failed; the message is shown as-is.
    var failureMessage: String?

    var id: String {
        "\(latestVersion ?? "-")-\(latestBuild ?? 0)"
    }
}

// MARK: - Update prompt content (pure decision)

/// Everything the update sheet needs, decided without UI: which
/// version, which notes, whether this device can install it, and
/// whether the update button may appear at all. A blocked build
/// (minOs above this device) NEVER gets an update button.
struct UpdatePromptContent {
    var versionLabel: String
    var releaseNotes: String
    var canInstall: Bool
    var blockedMessage: String?
    var showUpdateButton: Bool
    var downloadURL: URL?
}

// MARK: - Pure rules

enum UpdateCheckLogic {
    /// "1.1.7 (build 12)" — the identity skip records use.
    static func versionIdentity(version: String, build: Int) -> String {
        "\(version) (build \(build))"
    }

    /// Parse "17.0" / "17.0.1" / "17". Nil for anything else —
    /// a bad minOs never blocks an update.
    static func parseMinOs(_ text: String) -> (major: Int, minor: Int, patch: Int)? {
        let parts = text.split(separator: ".")
        guard parts.count >= 1 && parts.count <= 3 else {
            return nil
        }
        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part) else {
                return nil
            }
            numbers.append(value)
        }
        while numbers.count < 3 {
            numbers.append(0)
        }
        return (major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    /// True when the device OS is at or above minOs. An unknown
    /// minOs does not block (the checker's `requiresNewerOS`
    /// field is the other half of the decision).
    static func canInstall(deviceVersion: (major: Int, minor: Int, patch: Int), minOs: String) -> Bool {
        guard let minimum = parseMinOs(minOs) else {
            return true
        }
        if deviceVersion.major != minimum.major {
            return deviceVersion.major > minimum.major
        }
        if deviceVersion.minor != minimum.minor {
            return deviceVersion.minor > minimum.minor
        }
        return deviceVersion.patch >= minimum.patch
    }

    /// Last-check label for the 检查更新 row. Nil = never checked.
    static func lastCheckLabel(date: Date?, now: Date) -> String {
        guard let date = date else {
            return "从未检查"
        }
        let calendar = Calendar.current
        let timeText = timeFormatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return "今天 \(timeText)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now) {
            if calendar.isDate(date, inSameDayAs: yesterday) {
                return "昨天 \(timeText)"
            }
        }
        return dateFormatter.string(from: date)
    }

    private static var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    private static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }

    /// Alert title for an import report.
    static func importResultTitle(report: BackupImportReport) -> String {
        if report.rolledBack {
            return "导入失败，已回滚"
        }
        return "导入完成"
    }

    /// Alert message for an import report: success count, skipped
    /// keys, rollback note, Emby re-login warning — each line only
    /// when it applies, so a clean import reads as one line.
    static func importResultMessage(report: BackupImportReport) -> String {
        var lines: [String] = []
        if report.rolledBack {
            lines.append("导入中途失败，已全部回滚，现有数据未动。")
        } else {
            lines.append("成功导入 \(report.importedCount) 项。")
        }
        if !report.skippedKeys.isEmpty {
            lines.append("跳过了 \(report.skippedKeys.count) 个无法识别的键：\(report.skippedKeys.joined(separator: "、"))。")
        }
        if report.embyCredentialsMissing {
            lines.append("备份里没有 Emby 凭证，导入后请重新登录 Emby。")
        }
        for warning in report.warnings {
            lines.append(warning)
        }
        return lines.joined(separator: "\n")
    }

    /// Sheet content for a check result. The flow only presents
    /// the sheet when a latest version exists, so a nil latest
    /// version here is a defensive fallback (no update button),
    /// never a crash.
    static func promptContent(
        result: UpdateCheckResult,
        deviceVersion: (major: Int, minor: Int, patch: Int)
    ) -> UpdatePromptContent {
        let versionLabel: String
        if let version = result.latestVersion {
            if let build = result.latestBuild {
                versionLabel = versionIdentity(version: version, build: build)
            } else {
                versionLabel = version
            }
        } else {
            versionLabel = "未知版本"
        }
        let releaseNotes: String
        if let notes = result.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if !notes.isEmpty {
                releaseNotes = notes
            } else {
                releaseNotes = "本次更新没有附带更新说明。"
            }
        } else {
            releaseNotes = "本次更新没有附带更新说明。"
        }
        let minOsOk: Bool
        if let minOs = result.minOs {
            minOsOk = canInstall(deviceVersion: deviceVersion, minOs: minOs)
        } else {
            minOsOk = true
        }
        let canInstall = !result.requiresNewerOS && minOsOk
        let blockedMessage: String?
        if canInstall {
            blockedMessage = nil
        } else if let minOs = result.minOs {
            blockedMessage = "新版需要 iOS \(minOs) 以上，你的设备装不上"
        } else {
            blockedMessage = "新版需要更高版本的 iOS，你的设备装不上"
        }
        let showUpdateButton = canInstall && result.latestVersion != nil && result.latestBuild != nil && result.downloadURL != nil
        return UpdatePromptContent(
            versionLabel: versionLabel,
            releaseNotes: releaseNotes,
            canInstall: canInstall,
            blockedMessage: blockedMessage,
            showUpdateButton: showUpdateButton,
            downloadURL: result.downloadURL
        )
    }
}

// MARK: - Import completion signal

extension Notification.Name {
    /// Posted by the backup flow after a successful (non-rolled-back)
    /// import. SettingsStore / the app shell re-read every setting
    /// on this notification (plan §7.2: 导入后全部设置项重读) —
    /// the reload entry itself is coordinator / A-leg work:
    /// SettingsStore has no reload method today.
    static let haoBackupImported = Notification.Name("haoBackupImported")
}

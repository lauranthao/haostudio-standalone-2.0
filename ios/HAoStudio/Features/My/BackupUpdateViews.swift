// HAo Studio 2.0 — backup + update UI (S6-B leg).
//
// The flow + update sheet. The engine (A leg) and the checker
// (C leg) are NOT built here: the flow talks to them only through
// the `BackupEngine` / `UpdateChecker` protocols in
// BackupUpdateLogic.swift, and HAoStudioApp wires the real
// implementations into `BackupUpdateFlow.shared` at launch (S6).
// The nil guards below are defensive only — the app never ships
// with engine/checker unwired — so a nil engine shows a plain
// "不可用" alert instead of a dead button or a crash.
//
// Wiring note:
// - The update button opens the download URL in Safari with
//   `openURL`: no silent download, no automatic install.
// - Red is never used here: the minOs-blocked state is a warning
//   icon + text, not the app's only red (liveRed, LIVE badge only).

import SwiftUI

/// One alert for the whole backup/update flow. SettingsGroupsView
/// presents it with the modern `.alert(title:isPresented:
/// presenting:actions:message:)` form (no deprecated Alert API).
struct BackupUpdateAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// The backup + update flow: one shared instance so the settings
/// rows (SettingsGroupsView) and the My-page migration notice
/// (MyView) drive the same import picker / sheet / alert without
/// passing state through three layers. Completions from the engine
/// / checker are re-dispatched to the main thread here, so the
/// seam does not depend on which queue they arrive on.
@MainActor
final class BackupUpdateFlow: ObservableObject {
    static let shared = BackupUpdateFlow()

    /// Wired by the coordinator at merge (see the file header).
    var engine: BackupEngine?
    /// Wired by the coordinator at merge (see the file header).
    var checker: UpdateChecker?

    @Published var isExporting = false
    @Published var exportedURL: URL?
    /// Envelope warnings from the last successful export (e.g.
    /// the Emby credential warning — the credential stays in the
    /// Keychain and out of the file). Read from the envelope
    /// after export: the engine writes them there, and until
    /// this field existed nothing ever read them back, so the
    /// user never saw them (b36 item 8, F1).
    @Published var exportWarnings: [String] = []
    @Published var isImporting = false
    @Published var showingImporter = false
    @Published var alert: BackupUpdateAlert?
    @Published var isCheckingUpdate = false
    @Published var updatePrompt: UpdateCheckResult?
    @Published var lastCheckDate: Date?
    @Published var skippedVersionLabel: String?

    /// Re-read the checker's display state (last check + skipped
    /// version). Called on appear and after every check / skip.
    func refreshUpdateState() {
        lastCheckDate = checker?.lastCheckDate
        skippedVersionLabel = checker?.skippedVersionLabel
    }

    // MARK: - Export

    func beginExport() {
        guard let engine = engine else {
            alert = BackupUpdateAlert(title: "导出备份不可用", message: "备份引擎不可用，请稍后再试。")
            return
        }
        guard !isExporting else {
            return
        }
        isExporting = true
        exportedURL = nil
        exportWarnings = []
        engine.exportBackup { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }
                self.isExporting = false
                switch result {
                case .success(let url):
                    self.exportedURL = url
                    // b36 item 8, F1: the engine records the
                    // warnings in the envelope (notably the Emby
                    // credential warning); surface them so the
                    // user sees what the file does NOT contain.
                    self.exportWarnings = BackupEngineCore.warningsInBackup(at: url) ?? []
                case .failure(let error):
                    self.alert = BackupUpdateAlert(title: "导出失败", message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Import

    func beginImport() {
        guard engine != nil else {
            alert = BackupUpdateAlert(title: "导入备份不可用", message: "备份引擎不可用，请稍后再试。")
            return
        }
        showingImporter = true
    }

    /// Called with the .zip the user picked in the file importer.
    /// The engine reads it inside its call; the security-scoped
    /// access is held until its completion returns.
    func importPicked(url: URL) {
        guard let engine = engine else {
            alert = BackupUpdateAlert(title: "导入备份不可用", message: "备份引擎不可用，请稍后再试。")
            return
        }
        guard !isImporting else {
            return
        }
        isImporting = true
        let needsStop = url.startAccessingSecurityScopedResource()
        engine.importBackup(from: url) { [weak self] result in
            DispatchQueue.main.async {
                if needsStop {
                    url.stopAccessingSecurityScopedResource()
                }
                guard let self = self else {
                    return
                }
                self.isImporting = false
                switch result {
                case .success(let report):
                    self.alert = BackupUpdateAlert(
                        title: UpdateCheckLogic.importResultTitle(report: report),
                        message: UpdateCheckLogic.importResultMessage(report: report))
                    if !report.rolledBack {
                        NotificationCenter.default.post(name: .haoBackupImported, object: nil)
                    }
                case .failure(let error):
                    self.alert = BackupUpdateAlert(
                        title: "导入失败",
                        message: error.localizedDescription + "\n\n导入失败时会自动回滚，现有数据不受影响。")
                }
            }
        }
    }

    // MARK: - Update check

    func checkForUpdate() {
        guard let checker = checker else {
            alert = BackupUpdateAlert(title: "检查更新不可用", message: "更新检查器不可用，请稍后再试。")
            return
        }
        guard !isCheckingUpdate else {
            return
        }
        isCheckingUpdate = true
        checker.checkForUpdate { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }
                self.isCheckingUpdate = false
                self.refreshUpdateState()
                if let failure = result.failureMessage {
                    self.alert = BackupUpdateAlert(title: "检查更新失败", message: failure)
                    return
                }
                guard let version = result.latestVersion, let build = result.latestBuild else {
                    self.alert = BackupUpdateAlert(title: "已经是最新版本", message: "当前已是最新版本，无需更新。")
                    return
                }
                if result.isSkipped {
                    self.alert = BackupUpdateAlert(
                        title: "已跳过该版本",
                        message: "已跳过 \(UpdateCheckLogic.versionIdentity(version: version, build: build))，可在设置里取消跳过后再提示。")
                    return
                }
                self.updatePrompt = result
            }
        }
    }

    /// Record a skip for the version the sheet is showing, then
    /// dismiss the sheet. The skip itself is the checker's
    /// storage — this leg invents no UserDefaults key for it.
    func skipPromptedVersion() {
        guard let result = updatePrompt else {
            return
        }
        guard let version = result.latestVersion, let build = result.latestBuild else {
            return
        }
        checker?.skip(version: version, build: build)
        updatePrompt = nil
        refreshUpdateState()
    }

    func dismissPrompt() {
        updatePrompt = nil
    }

    /// Cancel a recorded skip; the next check prompts again.
    func clearSkippedVersion() {
        checker?.clearSkippedVersion()
        refreshUpdateState()
    }
}

// MARK: - Update prompt sheet

/// The new-version sheet: version + release notes, a skip button,
/// a later button, and — only when this device can install the
/// build and a download URL exists — an update button that opens
/// the URL in Safari. A build whose minOs is above this device
/// shows "新版需要 iOS X 以上，你的设备装不上" and NO update
/// button, so the user is never offered a build they cannot install.
struct UpdatePromptSheet: View {
    let result: UpdateCheckResult
    let onSkip: () -> Void
    let onLater: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.haoTheme) private var theme

    private var deviceVersion: (major: Int, minor: Int, patch: Int) {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return (major: version.majorVersion, minor: version.minorVersion, patch: version.patchVersion)
    }

    private var content: UpdatePromptContent {
        UpdateCheckLogic.promptContent(result: result, deviceVersion: deviceVersion)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                notesSection
                blockedSection
                buttonsSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.scaffoldBackground)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("发现新版本")
                .font(.haoDetailTitle)
                .foregroundStyle(theme.textPrimary)
            Text(content.versionLabel)
                .font(.haoSubhead)
                .foregroundStyle(theme.textSecondary)
        }
    }

    private var notesSection: some View {
        Text(content.releaseNotes)
            .font(.haoSubhead)
            .foregroundStyle(theme.textPrimary)
    }

    @ViewBuilder
    private var blockedSection: some View {
        if let blocked = content.blockedMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.haoSubhead)
                    .foregroundStyle(theme.accentText)
                Text(blocked)
                    .font(.haoSubhead)
                    .foregroundStyle(theme.textPrimary)
            }
        }
    }

    private var buttonsSection: some View {
        VStack(spacing: 12) {
            if content.showUpdateButton {
                updateButton
            }
            HStack(spacing: 24) {
                Button("跳过该版本") {
                    onSkip()
                }
                .font(.haoCallout)
                .foregroundStyle(theme.accentText)
                Button("以后再说") {
                    onLater()
                }
                .font(.haoCallout)
                .foregroundStyle(theme.accentText)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var updateButton: some View {
        Button(action: {
            if let url = content.downloadURL {
                openURL(url)
            }
            onLater()
        }) {
            Text("更新")
                .font(.haoCalloutStrong)
                .foregroundStyle(theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

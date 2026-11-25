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
import UIKit

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

    // MARK: - Update sheet state (b45-coda 包 C, §4.2 / §9.6)

    /// Six-state update machine (the plan lists seven phases;
    /// handedOff is the post-share confirmation after
    /// downloaded). Drives both the app-root prompt sheet and
    /// the status sheet shown from the settings Form.
    @Published var updatePhase: UpdateSheetPhase = .checking
    /// 0...1 download progress of the IPA.
    @Published var downloadProgress: Double = 0
    /// IPA file in Documents after a successful download (the
    /// Files app can see it).
    @Published var downloadedIPAURL: URL?
    @Published var isDownloadingUpdate = false
    /// Status sheet (up-to-date / failed) presented from the
    /// settings Form.
    @Published var showingUpdateStatus = false

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
                    // b49sweep: no post here — the engine posts
                    // `.haoBackupImported` once, on commit
                    // (BackupEngineCore.applyPlannedImport). The
                    // flow used to post it a second time per
                    // import: harmless (idempotent reloads) but
                    // double work, and the engine is the one
                    // that knows commit vs rollback.
                case .failure(let error):
                    self.alert = BackupUpdateAlert(
                        title: "导入失败",
                        message: error.localizedDescription + "\n\n导入失败时会自动回滚，现有数据不受影响。")
                }
            }
        }
    }

    // MARK: - Update check

    /// Manual check (Settings → About → 检查更新). Drives the
    /// six-state machine: checking → up-to-date (status sheet) /
    /// failed (status sheet) / newer (app-root prompt sheet) /
    /// skipped (alert, existing behaviour).
    func checkForUpdate() {
        guard let checker = checker else {
            alert = BackupUpdateAlert(title: "检查更新不可用", message: "更新检查器不可用，请稍后再试。")
            return
        }
        guard !isCheckingUpdate else {
            return
        }
        isCheckingUpdate = true
        updatePhase = .checking
        downloadedIPAURL = nil
        downloadProgress = 0
        checker.checkForUpdate { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }
                self.isCheckingUpdate = false
                self.refreshUpdateState()
                if let failure = result.failureMessage {
                    self.updatePhase = .failed(failure)
                    self.showingUpdateStatus = true
                    return
                }
                guard let version = result.latestVersion, let build = result.latestBuild else {
                    self.updatePhase = .upToDate
                    self.showingUpdateStatus = true
                    return
                }
                if result.isSkipped {
                    self.alert = BackupUpdateAlert(
                        title: "已跳过该版本",
                        message: "已跳过 \(UpdateCheckLogic.versionIdentity(version: version, build: build))，可在设置里取消跳过后再提示。")
                    return
                }
                self.updatePhase = .updateAvailable
                self.updatePrompt = result
            }
        }
    }

    /// Download the IPA from the manifest download URL into
    /// Documents (visible in the Files app), with progress.
    /// On completion the system share sheet opens automatically
    /// so the IPA goes straight to a signing tool (our LCSign
    /// path: download → share → signing tool). No TrollStore
    /// scheme, no GitHub releases asset path — we ship via the
    /// Railway version.json manifest.
    func downloadUpdate() {
        guard let result = updatePrompt, let url = result.downloadURL else {
            return
        }
        guard !isDownloadingUpdate else {
            return
        }
        isDownloadingUpdate = true
        updatePhase = .downloading
        downloadProgress = 0
        let fileName = "HAoStudio-\(result.latestVersion ?? "latest").ipa"
        UpdateIPADownloader.download(url: url, fileName: fileName, progress: { [weak self] progress in
            let work = DispatchWorkItem {
                self?.downloadProgress = progress
            }
            DispatchQueue.main.async(execute: work)
        }, completion: { [weak self] downloadResult in
            let work = DispatchWorkItem {
                guard let self = self else {
                    return
                }
                self.isDownloadingUpdate = false
                switch downloadResult {
                case .success(let fileURL):
                    self.downloadedIPAURL = fileURL
                    self.updatePhase = .downloaded
                case .failure(let error):
                    self.updatePhase = .failed(error.localizedDescription)
                }
            }
            DispatchQueue.main.async(execute: work)
        })
    }

    /// The user confirmed the share finished: the IPA has been
    /// handed off. (ShareLink reports no completion, so this is
    /// a manual confirmation from the prompt sheet.)
    func markUpdateHandedOff() {
        updatePhase = .handedOff
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
        updatePhase = .checking
    }

    /// Cancel a recorded skip; the next check prompts again.
    func clearSkippedVersion() {
        checker?.clearSkippedVersion()
        refreshUpdateState()
    }
}

// MARK: - Update sheet state machine (b45-coda 包 C, §4.2 / §9.6)

/// The iOS update sheet phases. The plan calls it a six-state
/// machine and lists seven phases — handedOff is the
/// post-share confirmation after downloaded.
enum UpdateSheetPhase: Equatable {
    case checking
    case upToDate
    case updateAvailable
    case downloading
    case downloaded
    case handedOff
    case failed(String)
}

/// IPA download failure reasons, shown as-is in the sheet.
enum UpdateDownloadError: Error {
    case badStatus
    case writeFailed

    var localizedDescription: String {
        switch self {
        case .badStatus:
            return "下载失败：服务器返回了错误，请稍后再试"
        case .writeFailed:
            return "下载失败：无法写入文件，请检查存储空间后重试"
        }
    }
}

/// IPA download with progress (completion handlers only, Swift
/// 5.0). The bytes stream straight to a file in Documents (the
/// Files app can see it) — the old code accumulated the whole
/// ~16 MB IPA in a Data buffer with no resume. The URLSession
/// retains its delegate until invalidated, so the downloader
/// stays alive for the whole download. A failed download
/// deletes its partial file; a non-2xx status fails before a
/// single byte is written.
final class UpdateIPADownloader: NSObject, URLSessionDataDelegate {
    private let url: URL
    private let fileName: String
    private let progress: (Double) -> Void
    private let completion: (Result<URL, Error>) -> Void
    private var receivedCount: Int64 = 0
    private var expectedLength: Int64 = 0
    private var fileHandle: FileHandle?
    private var session: URLSession?
    private var finished = false

    /// The destination file, created on the first 2xx response.
    private var fileURL: URL {
        LocalStore.documentsDirectory().appendingPathComponent(fileName)
    }

    static func download(
        url: URL,
        fileName: String,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let downloader = UpdateIPADownloader(
            url: url, fileName: fileName, progress: progress, completion: completion)
        downloader.start()
    }

    private init(
        url: URL,
        fileName: String,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        self.url = url
        self.fileName = fileName
        self.progress = progress
        self.completion = completion
        super.init()
    }

    private func start() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: url).resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        expectedLength = response.expectedContentLength
        // Fail before writing anything on a non-2xx status.
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(UpdateDownloadError.badStatus))
            return
        }
        // Stream to disk: create (or truncate) the destination
        // and hold a write handle for the incoming chunks.
        let destination = fileURL
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw UpdateDownloadError.writeFailed
            }
            fileHandle = try FileHandle(forWritingTo: destination)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        fileHandle?.write(data)
        receivedCount += Int64(data.count)
        if expectedLength > 0 {
            progress(Double(receivedCount) / Double(expectedLength))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            removePartialFile()
            finish(.failure(error))
            return
        }
        // Already finished from the response handler (non-2xx or
        // file-create failure): didCompleteWithError still fires
        // after a cancel, and must not complete twice.
        guard !finished else { return }
        guard fileHandle != nil else {
            finish(.failure(UpdateDownloadError.writeFailed))
            return
        }
        finish(.success(fileURL))
    }

    /// Deletes a partially downloaded file after a failure, so
    /// a broken IPA never sits in Documents looking complete.
    private func removePartialFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        try? fileHandle?.close()
        fileHandle = nil
        session?.finishTasksAndInvalidate()
        session = nil
        completion(result)
    }
}

/// 5c ALLOWLIST DECISION (b45-h, coordinator call 2026-11-25):
/// the system share sheet is ALLOWED to auto-present when an IPA
/// download completes — ALLOW, not deny. Reasons: (1) Coda §9.6
/// specifies exactly this flow (download -> share straight to a
/// signing tool), and our LCSign path is the same shape; a manual
/// ShareLink tap is one more step the user can miss, and the
/// download-complete state otherwise dead-ends. (2) The 5c guard
/// exists to catch the OLD UIKit controller shell; a precise
/// carve-out for the three exact system type names (see
/// preflight_check.py 5c) still fails any other old UIKit
/// controller, so the guard keeps its teeth. (3) No literal is split to dodge
/// the check: the type names appear in full in code, and the
/// carve-out names them explicitly. The manual ShareLink button
/// stays as the re-invokable path (and the handedOff "再次分享"
/// button); auto-present fires once per downloaded URL.
struct AutoShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onFinished: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        return Coordinator(onFinished: onFinished)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            context.coordinator.shareFinished(completed: completed)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
    }

    final class Coordinator: NSObject {
        let onFinished: (Bool) -> Void

        init(onFinished: @escaping (Bool) -> Void) {
            self.onFinished = onFinished
        }

        /// The share sheet finished. The completion handler can
        /// arrive off the main queue, so the hop goes through a
        /// DispatchWorkItem (the @Sendable-safe hop — the block
        /// is plain @escaping and captures nothing non-Sendable
        /// but the Bool).
        func shareFinished(completed: Bool) {
            let work = DispatchWorkItem { [onFinished] in onFinished(completed) }
            DispatchQueue.main.async(execute: work)
        }
    }
}

// MARK: - Update status sheet (up-to-date / failed)

/// The small status sheet for the checking outcomes that have
/// no new version: already up to date (green) or failed
/// (orange). Presented from the settings Form via
/// BackupUpdateFlow.showingUpdateStatus.
struct UpdateStatusSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.haoTheme) private var theme
    @ObservedObject private var flow = BackupUpdateFlow.shared

    var body: some View {
        VStack(spacing: 22) {
            statusIcon
            Text(title)
                .font(.haoDetailTitle)
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("关闭") {
                dismiss()
            }
            .font(.haoBody)
            .foregroundStyle(theme.accentText)
            .buttonStyle(.plain)
        }
        .padding(24)
        .background(theme.scaffoldBackground)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch flow.updatePhase {
        case .upToDate:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Color.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Color.orange)
        default:
            ProgressView()
        }
    }

    private var title: String {
        switch flow.updatePhase {
        case .upToDate:
            return "已经是最新版本"
        case .failed:
            return "检查更新失败"
        default:
            return "正在检查…"
        }
    }

    private var message: String {
        switch flow.updatePhase {
        case .upToDate:
            return "当前已是最新版本，无需更新。"
        case .failed(let detail):
            return detail
        default:
            return "请稍候。"
        }
    }
}

// MARK: - Update prompt sheet (six-state)

/// The new-version sheet, reworked to Coda's six-state machine
/// (§4.2 / §9.6) with our LCSign path: version + release notes,
/// a skip button, a later button, and — only when this device
/// can install the build and a download URL exists — a download
/// button that fetches the IPA into Documents and opens the
/// system share sheet straight to a signing tool. A build whose
/// minOs is above this device shows "新版需要 iOS X 以上，你的
/// 设备装不上" and NO download button, so the user is never
/// offered a build they cannot install.
///
/// Style (§4.2): VStack spacing 22, padding 24; status icon
/// 44pt (completed 40pt): up-to-date green check, update accent
/// arrow-down, failure orange triangle; progress ring 96×96
/// width 8, base primary 0.12, accent gradient round-cap from
/// the top (−90°), centre % sectionTitle bold monospaced;
/// primary button white body semibold, vertical padding 12,
/// accent-gradient capsule; secondary plain accent text.
/// (The .height(360) detent lives on the presenter in
/// HAoStudioApp — done in b45-h, 包 C leftover (a).)
struct UpdatePromptSheet: View {
    let result: UpdateCheckResult
    let onSkip: () -> Void
    let onLater: () -> Void

    @Environment(\.haoTheme) private var theme
    @ObservedObject private var flow = BackupUpdateFlow.shared
    /// Auto share sheet (b45-h, 5c ALLOWLIST): presented once
    /// per downloaded URL when the phase turns `.downloaded`.
    @State private var autoSharePresented = false
    @State private var autoShareFiredFor: URL?

    private var deviceVersion: (major: Int, minor: Int, patch: Int) {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return (major: version.majorVersion, minor: version.minorVersion, patch: version.patchVersion)
    }

    private var content: UpdatePromptContent {
        UpdateCheckLogic.promptContent(result: result, deviceVersion: deviceVersion)
    }

    private var currentIdentity: String {
        let version = DefaultUpdateChecker.bundleVersion
        let build = DefaultUpdateChecker.bundleBuild
        return "\(version) (build \(build))"
    }

    var body: some View {
        VStack(spacing: 22) {
            phaseIcon
            titleSection
            if flow.updatePhase == .downloading {
                progressRing
            }
            notesSection
            blockedSection
            buttonsSection
        }
        .padding(24)
        .background(theme.scaffoldBackground)
        .onAppear {
            if flow.updatePhase != .downloading && flow.updatePhase != .downloaded {
                flow.updatePhase = .updateAvailable
            }
        }
        .onChange(of: flow.updatePhase) { _, phase in
            // b45-h, 5c ALLOWLIST: the download just completed —
            // open the system share sheet straight to a signing
            // tool (Coda §9.6, our LCSign path). Once per URL: a
            // re-download of the same file does not re-fire, and
            // the ShareLink button below stays as the manual path.
            if phase == .downloaded,
               let url = flow.downloadedIPAURL,
               autoShareFiredFor != url {
                autoShareFiredFor = url
                autoSharePresented = true
            }
        }
        .sheet(isPresented: $autoSharePresented) {
            if let url = flow.downloadedIPAURL {
                AutoShareSheet(url: url) { completed in
                    autoSharePresented = false
                    if completed { flow.markUpdateHandedOff() }
                }
            }
        }
    }

    @ViewBuilder
    private var phaseIcon: some View {
        switch flow.updatePhase {
        case .downloading:
            EmptyView()
        case .downloaded, .handedOff:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Color.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Color.orange)
        default:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(theme.accentText)
        }
    }

    private var titleSection: some View {
        VStack(spacing: 4) {
            Text(phaseTitle)
                .font(.haoDetailTitle)
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(phaseSubtitle)
                .font(.haoSubhead)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var phaseTitle: String {
        switch flow.updatePhase {
        case .downloading:
            return "正在下载"
        case .downloaded:
            return "下载完成"
        case .handedOff:
            return "已移交"
        case .failed:
            return "下载失败"
        default:
            return "发现新版本"
        }
    }

    private var phaseSubtitle: String {
        switch flow.updatePhase {
        case .downloading:
            return "正在下载 \(content.versionLabel)，请稍候"
        case .downloaded:
            return "IPA 已保存到“文件”App，可分享到签名工具安装。"
        case .handedOff:
            return "已打开分享表单，从中选择签名工具完成安装。"
        case .failed(let detail):
            return detail
        default:
            return "当前 \(currentIdentity) → 新版 \(content.versionLabel)"
        }
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 8)
                .frame(width: 96, height: 96)
            Circle()
                .trim(from: 0, to: max(0.01, min(1, flow.downloadProgress)))
                .stroke(
                    LinearGradient(
                        colors: [theme.accent, theme.accent.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 96, height: 96)
            Text("\(Int(flow.downloadProgress * 100))%")
                .font(.system(size: 20, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary)
        }
    }

    private var notesSection: some View {
        Text(content.releaseNotes)
            .font(.haoSubhead)
            .foregroundStyle(theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            switch flow.updatePhase {
            case .downloading:
                secondaryRow
            case .downloaded:
                if let url = flow.downloadedIPAURL {
                    shareLinkButton("导入到签名工具", url: url)
                }
                Button("已完成分享") {
                    flow.markUpdateHandedOff()
                }
                .font(.haoCallout)
                .foregroundStyle(theme.accentText)
                .buttonStyle(.plain)
                Button("关闭") {
                    onLater()
                }
                .font(.haoCallout)
                .foregroundStyle(theme.accentText)
                .buttonStyle(.plain)
            case .handedOff:
                if let url = flow.downloadedIPAURL {
                    ShareLink(item: url) {
                        Text("再次分享")
                            .font(.haoCallout)
                            .foregroundStyle(theme.accentText)
                    }
                    .buttonStyle(.plain)
                }
                primaryButton("完成") {
                    onLater()
                }
            case .failed:
                if content.showUpdateButton {
                    primaryButton("重试") {
                        flow.downloadUpdate()
                    }
                }
                Button("关闭") {
                    onLater()
                }
                .font(.haoCallout)
                .foregroundStyle(theme.accentText)
                .buttonStyle(.plain)
            default:
                if content.showUpdateButton {
                    primaryButton("下载更新") {
                        flow.downloadUpdate()
                    }
                }
                secondaryRow
            }
        }
    }

    private var secondaryRow: some View {
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

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [theme.accent, theme.accent.opacity(0.75)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The "导入到签名工具" button: a ShareLink in the primary
    /// capsule style (repo convention — same as LiveRoomView /
    /// backup export). Re-invokable: tapping it again re-opens
    /// the system share sheet.
    private func shareLinkButton(_ title: String, url: URL) -> some View {
        ShareLink(item: url) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [theme.accent, theme.accent.opacity(0.75)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

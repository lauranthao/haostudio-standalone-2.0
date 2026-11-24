// HAo Studio 2.0 — source management pages (S5-B leg).
//
// Three pages, one per source family. Each page reads/writes
// the EXISTING collections — no new store is invented here:
// - LX scripts: LXScriptStore (`hao_lx_*` collections) +
//   LxBundledScript.allIDs + LXScriptFileStore (files).
// - CMS sources: VideoSourceStore (`hao_sa_video`).
// - Live platforms: LiveSourcePrefs (`hao_live_sources`) —
//   there was no Swift accessor in the baseline, so the
//   read/write lives on LiveSourcePrefs in SettingsLogic.swift,
//   over the existing Flutter-shaped collection.
// Every "keep at least one" list greys out the last enabled
// switch instead of letting the write happen and fail.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - 音源管理

/// LX script list: bundled scripts (minus user-deleted) +
/// user-imported scripts, in saved order. Toggle = enable /
/// disable. Custom scripts can be deleted; bundled scripts can
/// be deleted (into `hao_lx_deleted_bundled`, never re-seeded).
/// "恢复默认" restores the shipped 13 bundled scripts, all
/// enabled, in seed order; user-imported scripts are kept
/// (they are user data, not defaults).
///
/// Import (chen 2026-11-24: build 33 could not upload `.js` at
/// all — there was no file picker, and URL "add" only saved the
/// address string, so the script never loaded and never took
/// part in search or playback, with no error shown):
/// - "从文件选择" opens the Files picker for a `.js` file;
/// - pasting a `.js` URL downloads it right away.
/// Both run the same validation (`LXScriptImportValidator`:
/// `.js`, readable, non-empty, LX marker, parses clean) and
/// the same store + load path (`LXEngine.importScript`); a
/// failure shows its reason, never silently. A script that
/// loads reports its capabilities to the resolver, so the
/// first playable source can come from it. Legacy URL-only
/// records (build 33, no downloaded file) show "未下载" with
/// a re-download button instead of a dead row.
struct LXSourceManagementView: View {
    @Environment(\.haoTheme) private var theme

    @State private var rows: [LXSourceRow] = []
    @State private var enabledIDs: Set<String> = []
    @State private var urlDraft = ""
    @State private var showingRestoreAlert = false
    @State private var showingFileImporter = false
    @State private var isImporting = false
    @State private var importAlertTitle = ""
    @State private var importAlertMessage = ""
    @State private var showingImportAlert = false

    private let scriptStore = LXScriptStore()

    /// The Files picker only shows `.js` files; if the system
    /// has no `.js` type, fall back to any file and let the
    /// validator reject non-`.js` files with a clear error.
    private static var jsContentTypes: [UTType] {
        if let js = UTType(filenameExtension: "js") { return [js] }
        return [.data]
    }

    var body: some View {
        List {
            Section {
                if rows.isEmpty {
                    Text("没有可用的音源脚本。")
                        .font(.haoRowSubtitle)
                        .foregroundStyle(theme.textMuted)
                } else {
                    ForEach(rows) { row in
                        lxRow(row)
                    }
                    .onMove(perform: moveRows)
                }
            } footer: {
                Text("捆绑脚本来自应用内置清单；自定义脚本由你导入。关掉的脚本不会参与搜歌和播放。至少保留一个启用的脚本：最后一个启用的不能关掉或删除；拖动可调整顺序，搜歌和播放按这个顺序找源。")
            }
            Section("添加自定义脚本") {
                TextField("脚本地址（https://…/xxx.js）", text: $urlDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("添加") {
                    importFromURL()
                }
                .font(.haoBody)
                .foregroundStyle(theme.accentText)
                .disabled(isImporting)
                Button("从文件选择 .js 导入") {
                    showingFileImporter = true
                }
                .font(.haoBody)
                .foregroundStyle(theme.accentText)
                .disabled(isImporting)
                if isImporting {
                    ProgressView("正在导入…")
                        .font(.haoFootnote)
                        .foregroundStyle(theme.textMuted)
                }
                Text("粘贴 .js 脚本直链，或从文件 App 选择 .js 文件；导入时会先校验，校验通过才加入列表参与搜歌和播放，失败会提示原因。")
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textMuted)
            }
            Section {
                Button("恢复默认") {
                    showingRestoreAlert = true
                }
                .font(.haoBody)
                .foregroundStyle(theme.accentText)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.scaffoldBackground)
        .haoBottomChromePadding()
        .navigationTitle("音源管理")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
        .onAppear {
            reload()
        }
        .alert("恢复默认音源", isPresented: $showingRestoreAlert) {
            Button("取消", role: .cancel) {
            }
            Button("恢复", role: .destructive) {
                restoreDefaults()
            }
        } message: {
            Text("将恢复全部 13 个内置脚本并全部启用，顺序回到默认。你导入的自定义脚本会保留。")
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: Self.jsContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    importFromFile(url)
                }
            case .failure(let error):
                showImportAlert(title: "选择文件失败", message: error.localizedDescription)
            }
        }
        .alert(importAlertTitle, isPresented: $showingImportAlert) {
            Button("好", role: .cancel) {
            }
        } message: {
            Text(importAlertMessage)
        }
    }

    private func lxRow(_ row: LXSourceRow) -> some View {
        // Keep-at-least-one (fix 2026-11-24, build 35): the LX
        // page was the only source list without the guard the CMS
        // and live pages already have — every switch could be
        // turned off, leaving zero sources for search and
        // playback with no warning. The last enabled switch is
        // greyed out, and deleting that row is blocked the same
        // way (deleting it would leave zero enabled too). The
        // guard lives in the UI, like the other two pages; the
        // store itself does not refuse the write.
        let isRowEnabled = enabledIDs.contains(row.id)
        let isLastEnabled = isRowEnabled && enabledIDs.count == 1
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.haoBody)
                    .foregroundStyle(theme.textPrimary)
                if row.isCustom {
                    Text("自定义")
                        .font(.haoFootnote)
                        .foregroundStyle(theme.textMuted)
                }
                if let status = statusText(for: row) {
                    Text(status.text)
                        .font(.haoFootnote)
                        .foregroundStyle(status.isFailure ? theme.textPrimary : theme.textMuted)
                }
            }
            Spacer()
            if row.isCustom && row.fileName.isEmpty {
                Button("下载") {
                    downloadLegacyScript(row)
                }
                .font(.haoFootnote)
                .foregroundStyle(theme.accentText)
                .disabled(isImporting)
            }
            Toggle(
                "启用",
                isOn: Binding<Bool>(
                    get: { enabledIDs.contains(row.id) },
                    set: { newValue in
                        if !newValue && !SourceKeepOneGuard.canDisable(
                            enabledCount: enabledIDs.count
                        ) {
                            return
                        }
                        scriptStore.setEnabled(row.id, enabled: newValue)
                        reload()
                    }
                )
            )
            .labelsHidden()
            .disabled(isLastEnabled)
            Button(role: .destructive) {
                deleteScript(row)
            } label: {
                Image(systemName: "trash")
                    .font(.haoRowSubtitle)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .disabled(isLastEnabled)
        }
    }

    /// One-line load state for a custom row, read live from the
    /// engine registry: a legacy URL-only record has no file yet;
    /// a saved script whose load failed keeps its reason visible
    /// instead of looking like a working source.
    private func statusText(for row: LXSourceRow) -> (text: String, isFailure: Bool)? {
        guard row.isCustom else { return nil }
        if row.fileName.isEmpty { return ("未下载", false) }
        if let script = LXEngine.shared.script(row.id),
           !script.loaded, let error = script.error {
            return ("加载失败：\(error)", true)
        }
        return nil
    }

    private func reload() {
        rows = LXSourceListOrdering.orderedRows(
            bundledIDs: LxBundledScript.allIDs,
            customRecords: scriptStore.customScripts(),
            deletedBundledIDs: scriptStore.deletedBundledIds(),
            savedOrder: scriptStore.scriptOrder()
        )
        enabledIDs = Set(rows.map { $0.id }.filter { scriptStore.isEnabled($0) })
    }

    private func deleteScript(_ row: LXSourceRow) {
        // The engine owns the full removal: dispose the runtime,
        // drop the registry entry, delete the file copy and the
        // record (bundled ids are marked deleted, never re-seeded).
        LXEngine.shared.removeScript(row.id)
        reload()
    }

    /// Drag reorder (fix 2026-11-24, build 35): the order
    /// collections and the resolver's manual order already
    /// existed, but no UI ever wrote `hao_lx_order`, so the
    /// list order could never change. The saved order is the
    /// order search and playback try the scripts in
    /// (LXSourceResolver sorts its LX jobs by it).
    private func moveRows(from source: IndexSet, to destination: Int) {
        var updated = rows
        updated.move(fromOffsets: source, toOffset: destination)
        rows = updated
        scriptStore.saveScriptOrder(updated.map { $0.id })
    }

    /// Restore the shipped set: clear disabled / explicit /
    /// deleted-bundled / order collections (the contract keys on
    /// LXScriptStore). Custom scripts are untouched.
    private func restoreDefaults() {
        LocalStore.saveCollection(named: LXScriptStore.disabledKey, value: [String]())
        LocalStore.saveCollection(named: LXScriptStore.explicitEnabledKey, value: [String]())
        LocalStore.saveCollection(named: LXScriptStore.deletedBundledKey, value: [String]())
        LocalStore.saveCollection(named: LXScriptStore.orderKey, value: [String]())
        reload()
    }

    private func showImportAlert(title: String, message: String) {
        importAlertTitle = title
        importAlertMessage = message
        showingImportAlert = true
    }

    /// Shared import outcome: success joins the list and can take
    /// part in search and playback; any failure shows its reason.
    /// A re-download replaces the legacy URL-only record for the
    /// same address (the downloaded copy gets a new content id),
    /// so the list never keeps both the dead row and the live one.
    private func handleImportResult(
        _ result: Result<LxScriptInfo, LXScriptImportError>,
        sourceURLString: String
    ) {
        switch result {
        case .success(let info):
            for legacy in scriptStore.customScripts()
            where legacy.fileName.isEmpty && legacy.url == sourceURLString
                && legacy.id != info.id {
                scriptStore.removeCustomScript(legacy.id)
            }
            urlDraft = ""
            showImportAlert(
                title: "导入成功",
                message: "\(info.name) 已加入音源列表，可参与搜歌和播放。")
            reload()
        case .failure(let error):
            showImportAlert(title: "导入失败", message: error.localizedDescription)
            reload()
        }
    }

    private func importFromFile(_ url: URL) {
        isImporting = true
        LXEngine.shared.importScript(from: url) { result in
            isImporting = false
            handleImportResult(result, sourceURLString: url.absoluteString)
        }
    }

    private func importFromURL() {
        let trimmed = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            showImportAlert(
                title: "导入失败",
                message: LXScriptImportError.invalidURL.localizedDescription)
            return
        }
        switch LXScriptImportValidator.validateRemoteURL(url) {
        case .failure(let error):
            showImportAlert(title: "导入失败", message: error.localizedDescription)
            return
        case .success:
            break
        }
        isImporting = true
        LXEngine.shared.importScript(fromRemoteURL: url) { result in
            isImporting = false
            handleImportResult(result, sourceURLString: trimmed)
        }
    }

    /// Re-download a legacy URL-only record (build 33 saved the
    /// address without downloading the code).
    private func downloadLegacyScript(_ row: LXSourceRow) {
        guard let url = URL(string: row.url) else {
            showImportAlert(
                title: "导入失败",
                message: LXScriptImportError.invalidURL.localizedDescription)
            return
        }
        isImporting = true
        LXEngine.shared.importScript(fromRemoteURL: url) { result in
            isImporting = false
            handleImportResult(result, sourceURLString: row.url)
        }
    }
}

// MARK: - 影视源管理

/// CMS source list from VideoSourceStore. Toggle = enable /
/// disable (the last enabled source cannot be switched off);
/// drag = reorder (sort is renumbered so the stored order is
/// the effective order); 恢复默认 = shipped 13 sources.
struct CmsSourceManagementView: View {
    @Environment(\.haoTheme) private var theme

    @State private var sources: [VideoSource] = []
    @State private var showingRestoreAlert = false

    var body: some View {
        List {
            Section {
                if sources.isEmpty {
                    Text("没有可用的影视源。")
                        .font(.haoRowSubtitle)
                        .foregroundStyle(theme.textMuted)
                } else {
                    ForEach(sources) { source in
                        cmsRow(source)
                    }
                    .onMove(perform: moveSources)
                }
            } footer: {
                Text("至少保留一个启用源；拖动可调整顺序，改完立即生效。")
            }
            Section {
                Button("恢复默认") {
                    showingRestoreAlert = true
                }
                .font(.haoBody)
                .foregroundStyle(theme.accentText)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.scaffoldBackground)
        .haoBottomChromePadding()
        .navigationTitle("影视源管理")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
        .onAppear {
            reload()
        }
        .alert("恢复默认影视源", isPresented: $showingRestoreAlert) {
            Button("取消", role: .cancel) {
            }
            Button("恢复", role: .destructive) {
                VideoSourceStore.resetToDefaults()
                reload()
            }
        } message: {
            Text("将恢复 13 个内置影视源及默认开关状态。")
        }
    }

    private func cmsRow(_ source: VideoSource) -> some View {
        let isLastEnabled = source.enabled && sources.filter { $0.enabled }.count == 1
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.haoBody)
                    .foregroundStyle(theme.textPrimary)
                Text(source.apiUrl)
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            Toggle(
                "启用",
                isOn: Binding<Bool>(
                    get: { source.enabled },
                    set: { newValue in
                        setEnabled(source, enabled: newValue)
                    }
                )
            )
            .labelsHidden()
            .disabled(isLastEnabled)
        }
    }

    private func reload() {
        sources = VideoSourceStore.load()
    }

    private func save(_ updated: [VideoSource]) {
        sources = updated
        VideoSourceStore.save(updated)
    }

    private func setEnabled(_ source: VideoSource, enabled: Bool) {
        if !enabled && !SourceKeepOneGuard.canDisable(
            enabledCount: sources.filter { $0.enabled }.count
        ) {
            return
        }
        let updated = sources.map { item in
            if item.id == source.id {
                return VideoSource(
                    id: item.id, name: item.name, apiUrl: item.apiUrl,
                    kind: item.kind, enabled: enabled, sort: item.sort
                )
            }
            return item
        }
        save(updated)
    }

    private func moveSources(from source: IndexSet, to destination: Int) {
        var updated = sources
        updated.move(fromOffsets: source, toOffset: destination)
        updated = updated.enumerated().map { index, item in
            VideoSource(
                id: item.id, name: item.name, apiUrl: item.apiUrl,
                kind: item.kind, enabled: item.enabled, sort: (index + 1) * 10
            )
        }
        save(updated)
    }
}

// MARK: - 直播源管理

/// The 5 live platforms, backed by the `hao_live_sources`
/// collection (LiveSourcePrefs — Flutter LiveSourcesStore
/// shape). At least one platform stays on; the last enabled
/// switch is greyed out.
struct LiveSourceManagementView: View {
    @Environment(\.haoTheme) private var theme

    @State private var enabledIDs: [String] = LiveSourcePrefs.allIDs

    var body: some View {
        List {
            Section {
                ForEach(LivePlatform.allCases) { platform in
                    liveRow(platform)
                }
            } footer: {
                Text("至少保留一个开启的平台；关掉的平台不会在直播首页出现。")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.scaffoldBackground)
        .haoBottomChromePadding()
        .navigationTitle("直播源管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            enabledIDs = LiveSourcePrefs.load()
        }
    }

    private func liveRow(_ platform: LivePlatform) -> some View {
        let siteId = platform.flutterSiteId
        let isEnabled = enabledIDs.contains(siteId)
        let isLastEnabled = isEnabled && enabledIDs.count == 1
        return HStack {
            Text(platform.displayName)
                .font(.haoBody)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Toggle(
                "启用",
                isOn: Binding<Bool>(
                    get: { isEnabled },
                    set: { newValue in
                        setEnabled(siteId, value: newValue)
                    }
                )
            )
            .labelsHidden()
            .disabled(isLastEnabled)
        }
    }

    private func setEnabled(_ siteId: String, value: Bool) {
        guard let next = LiveSourcePrefs.settingEnabled(
            enabledIDs, siteId: siteId, value: value
        ) else {
            return
        }
        enabledIDs = next
        LiveSourcePrefs.save(next)
    }
}

// HAo Studio 2.0 — settings page groups (S5-B leg).
//
// `SettingsGroupsView` renders ONLY the 7 settings Sections —
// it is not a List and not a NavigationStack. The C leg's MyView
// embeds it in its own List (inside its NavigationStack), so the
// Sections get List styling there. Every group is its own
// computed property (S3 lesson: one giant body does not compile).
//
// Row titles copy the Flutter settings page
// (standalone-app-merge23
// lib/features/settings/settings_tab_page.dart) verbatim.
// No login-gated feature, no smart playlist, no real-time
// activity, no purple anywhere. Red is never used here.
//
// Engine note (A leg owns SettingsStore / ThemeStore /
// VideoEngineReporter / CacheManager / WallpaperStore /
// EmbyConfigViewModel): this file uses exactly the interface
// names the brief fixes. Where the brief leaves a signature
// open, the choice is called out in the S5-B leg report so the
// coordinator can align it at merge.
//
// Custom font is deliberately NOT offered: SwiftUI has no
// app-level font override, so the Flutter "自定义字体" row
// would be a dead switch here. It is omitted, not faked.

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Shared collapsible-section header: tap the title to fold /
/// unfold the section, chevron tracks the state. Used by the 7
/// settings groups in `SettingsGroupsView` and by the 我的 entry
/// section in `MyView`, so every section folds the same way.
/// Reads the fold state from `SettingsStore` directly; default
/// expanded (no stored key reads back as true).
struct SettingsSectionHeader: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.haoTheme) private var theme

    let section: SettingsSection

    var body: some View {
        Button(action: {
            settings.setSectionExpanded(!settings.sectionExpanded(section.rawValue), for: section.rawValue)
        }) {
            HStack {
                Text(section.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Image(systemName: settings.sectionExpanded(section.rawValue) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textMuted)
            }
        }
        .buttonStyle(.plain)
    }
}

/// The 8 sections (我的 + the 7 settings groups) as List Sections. Embed in the My tab
/// List; do not wrap in another List / NavigationStack.
struct SettingsGroupsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var themeStore: ThemeStore
    /// b35-sweep-settings: 播放音质开关的实时推送目标。
    /// PlaybackCoordinator.targetQuality 只在 init 读一次 key，
    /// 设置页只写 UserDefaults 时协调器内存值不变、重启前不生效
    /// （见 musicSection 的 onChange）。HAoStudioApp 全 app 注入，
    /// 本页恒在 MainTabView 之下。
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @Environment(\.haoTheme) private var theme

    /// Emby status for the 源管理 → Emby 连接 row subtitle.
    /// The view model loads the stored config on init (A leg).
    @StateObject private var embyViewModel = EmbyConfigViewModel()

    /// Backup + update flow (S6-B, shared with MyView's migration
    /// notice so both drive the same picker / sheet / alert).
    @ObservedObject private var backupFlow = BackupUpdateFlow.shared

    /// Last engine that really played (VideoEngineReporter). Read
    /// through an @ObservedObject — not `VideoEngineReporter.shared`
    /// inline — so the "上次实际" row refreshes when a playback
    /// starts while this page is open (same silent-read class as
    /// the section-expand bug, chen 2026-11-24).
    @ObservedObject private var engineReporter = VideoEngineReporter.shared

    /// Danmaku settings edited by the reused S4 sheet; persisted
    /// when the sheet page disappears.
    @State private var danmakuSettings = LiveDanmakuSettings.load()

    /// Background-colour hex draft. Only a valid `#RRGGBB`
    /// draft is written to the store; an invalid one reverts.
    @State private var bgHexDraft = ""

    /// Cached size (bytes) shown in the 数据 group. Refreshed
    /// on appear and after clearing.
    @State private var cacheSizeBytes: Int = 0

    /// Cache-clear confirmation.
    @State private var showingClearCacheAlert = false

    var body: some View {
        Group {
            appearanceSection
            musicSection
            liveSection
            videoSection
            sourcesSection
            dataSection
            aboutSection
        }
        .fileImporter(
            isPresented: $backupFlow.showingImporter,
            allowedContentTypes: [UTType.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    backupFlow.importPicked(url: url)
                }
            case .failure(let error):
                backupFlow.alert = BackupUpdateAlert(title: "选择文件失败", message: error.localizedDescription)
            }
        }
        .sheet(item: $backupFlow.updatePrompt) { result in
            UpdatePromptSheet(
                result: result,
                onSkip: { backupFlow.skipPromptedVersion() },
                onLater: { backupFlow.dismissPrompt() }
            )
        }
        .alert(
            backupFlow.alert?.title ?? "提示",
            isPresented: alertPresented,
            presenting: backupFlow.alert,
            actions: { _ in
                Button("知道了", role: .cancel) {
                }
            },
            message: { item in
                Text(item.message)
            }
        )
        .onAppear {
            backupFlow.refreshUpdateState()
        }
    }

    /// Presenting binding for the flow alert: shown while an
    /// alert is set, cleared when the user dismisses it.
    private var alertPresented: Binding<Bool> {
        Binding<Bool>(
            get: { backupFlow.alert != nil },
            set: { newValue in
                if !newValue {
                    backupFlow.alert = nil
                }
            }
        )
    }

    // MARK: - Section scaffolding

    private func isExpanded(_ section: SettingsSection) -> Bool {
        settings.sectionExpanded(section.rawValue)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(theme.textMuted)
    }

    /// String-option Picker binding: an unknown stored value
    /// reads back as the default instead of showing a blank row,
    /// and only listed values are ever written.
    private func optionBinding(
        get: @escaping () -> String,
        set: @escaping (String) -> Void,
        valid: @escaping (String) -> Bool,
        default defaultValue: String
    ) -> Binding<String> {
        Binding<String>(
            get: {
                let current = get()
                return valid(current) ? current : defaultValue
            },
            set: { newValue in
                if valid(newValue) {
                    set(newValue)
                }
            }
        )
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        Section(header: SettingsSectionHeader(section: .appearance)) {
            if isExpanded(.appearance) {
                themeRow
                appearanceRow
                wallpaperRow
                wallpaperManageRow
                accentRow
                tabAccentRow
                glassIntensityRow
                backgroundColorRow
            }
        }
    }

    /// Theme picker, inline — same as MyPlaceholderView.
    private var themeRow: some View {
        Picker("主题", selection: $themeStore.themeID) {
            ForEach(HaoThemeID.allCases) { id in
                Text(id.displayName).tag(id)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    private var appearanceRow: some View {
        Picker("外观", selection: $themeStore.appearance) {
            ForEach(HaoAppearance.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var wallpaperRow: some View {
        Toggle("壁纸", isOn: $settings.wallpaperEnabled)
    }

    private var wallpaperManageRow: some View {
        NavigationLink("壁纸管理") {
            WallpaperManagementView()
        }
    }

    /// Custom accent colour (Flutter "自定义强调色"). The
    /// ColorPicker writes SettingsStore.accentOverride; ThemeStore
    /// applies it (A leg). Nil = theme default.
    private var accentRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            ColorPicker(
                "自定义强调色",
                selection: accentBinding,
                supportsOpacity: false
            )
            if settings.accentOverride != nil {
                Button("恢复默认") {
                    settings.accentOverride = nil
                }
                .font(.system(size: 14))
            }
        }
    }

    private var accentBinding: Binding<Color> {
        Binding<Color>(
            get: { settings.accentOverride ?? theme.accent },
            set: { newValue in settings.accentOverride = newValue }
        )
    }

    /// Tab-bar selected colour palette. "默认" + five swatches;
    /// no purple, no red (chen rule). Nil = theme default.
    private var tabAccentRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("底栏选中颜色")
                .font(.system(size: 15))
                .foregroundStyle(theme.textPrimary)
            HStack(spacing: 12) {
                ForEach(tabAccentChoices) { choice in
                    tabAccentSwatch(choice)
                }
            }
        }
    }

    private var tabAccentChoices: [TabAccentChoice] {
        [
            TabAccentChoice(label: "默认", color: nil),
            TabAccentChoice(label: "蓝", color: Color(hex: 0x0A84FF)),
            TabAccentChoice(label: "绿", color: Color(hex: 0x30D158)),
            TabAccentChoice(label: "橙", color: Color(hex: 0xFF9F0A)),
            TabAccentChoice(label: "青", color: Color(hex: 0x64D2FF)),
            TabAccentChoice(label: "粉", color: Color(hex: 0xFF375F)),
        ]
    }

    private func tabAccentSwatch(_ choice: TabAccentChoice) -> some View {
        let selected = isTabAccentSelected(choice.color)
        return Button(action: {
            settings.tabAccentColor = choice.color
        }) {
            VStack(spacing: 4) {
                ZStack {
                    if let color = choice.color {
                        Circle()
                            .fill(color)
                            .frame(width: 28, height: 28)
                    } else {
                        Circle()
                            .fill(theme.surfaceStrong)
                            .frame(width: 28, height: 28)
                            .overlay {
                                Image(systemName: "slash.circle")
                                    .font(.system(size: 14))
                                    .foregroundStyle(theme.textSecondary)
                            }
                    }
                    if selected {
                        Circle()
                            .strokeBorder(theme.textPrimary, lineWidth: 2)
                            .frame(width: 34, height: 34)
                    }
                }
                Text(choice.label)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    /// Selected when both are nil (默认) or the stored colour
    /// matches the swatch hex. Color is not Equatable, so the
    /// comparison goes through the hex string.
    private func isTabAccentSelected(_ color: Color?) -> Bool {
        return colorHexString(settings.tabAccentColor) == colorHexString(color)
    }

    private func colorHexString(_ color: Color?) -> String? {
        guard let color = color else { return nil }
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        let r = Int(round(red * 255))
        let g = Int(round(green * 255))
        let b = Int(round(blue * 255))
        return HexRGB.string(red: r, green: g, blue: b)
    }

    private var glassIntensityRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("液态玻璃强度")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text("\(Int(settings.glassIntensity * 100))%")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
            }
            // Coordinator fix (S5 merge): glassIntensity is a
            // computed forward to ThemeStore, not @Published, so
            // there is no `$settings.glassIntensity` projection —
            // the Slider takes an explicit binding instead.
            Slider(
                value: Binding(
                    get: { settings.glassIntensity },
                    set: { settings.glassIntensity = $0 }
                ),
                in: 0.3...1.0
            )
        }
    }

    private var backgroundColorRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("背景色", isOn: $settings.bgColorEnabled)
            if settings.bgColorEnabled {
                TextField("#RRGGBB", text: $bgHexDraft)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onAppear {
                        bgHexDraft = settings.bgColorHex
                    }
                    .onSubmit {
                        commitBackgroundHex()
                    }
                    .onDisappear {
                        // b35-sweep-settings: 原来只在按 Return 时
                        // 保存；点别处 / 收起分组 / 返回上一页都会
                        // 把未提交的草稿静默丢掉。离开行时也提交
                        // 一次（无效值照旧不保存，见 commit）。
                        commitBackgroundHex()
                    }
                footnote("输入 #RRGGBB，无效值不会保存。")
            }
        }
    }

    private func commitBackgroundHex() {
        let draft = bgHexDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if HexRGB.isValid(draft) {
            settings.bgColorHex = draft.uppercased()
            bgHexDraft = draft.uppercased()
        } else {
            bgHexDraft = settings.bgColorHex
        }
    }

    // MARK: - 音乐播放

    private var musicSection: some View {
        Section(header: SettingsSectionHeader(section: .music)) {
            if isExpanded(.music) {
                Toggle("与其他音频同时播放", isOn: $settings.mixWithOthers)
                    .onChange(of: settings.mixWithOthers) { _, newValue in
                        // Wiring leg B: the switch is not storage-only
                        // (Flutter calls AvMusicPlayer.applyMixWithOthers
                        // on the toggle) — re-apply the session at once
                        // so the playing track follows without restart.
                        NativeMusicPlayer.shared.applyMixWithOthers(newValue)
                    }
                Toggle("启动时自动播放上次歌曲", isOn: $settings.autoResume)
                Picker("播放音质", selection: $settings.musicQuality) {
                    ForEach(AudioQuality.allCases, id: \.self) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .onChange(of: settings.musicQuality) { _, newValue in
                    // b35-sweep-settings: PlaybackCoordinator 只在
                    // init 读一次 musicQuality（targetQuality），
                    // 设置页不推就一直是旧档位、重启才生效。播放器内
                    // 的音质选择走 playerVM.setTargetQuality（已推），
                    // 这里补上同一推送；key 本身由 SettingsStore 写。
                    coordinator.targetQuality = newValue
                }
                Toggle("触感反馈", isOn: $settings.hapticsEnabled)
                NavigationLink("均衡器") {
                    MusicEqualizerView()
                }
                Toggle("音量归一化", isOn: $settings.normalizationEnabled)
                    .onChange(of: settings.normalizationEnabled) { _, newValue in
                        // b35-sweep-settings: NativeMusicPlayer 只在
                        // init 读一次归一化开关/强度进内存变量，
                        // setter 全 app 零调用，设置页拨开关要重启
                        // 才生效。推给 player（下一首起作用，不改
                        // 正播的歌，与 player 的注释一致）。
                        NativeMusicPlayer.shared.setNormalizationEnabled(newValue)
                    }
                footnote("需开启均衡器才能测量响度")
                VStack(alignment: .leading, spacing: 8) {
                    Stepper(
                        "归一化强度",
                        value: $settings.normalizationStrength,
                        in: 0...2,
                        step: 1
                    )
                    .onChange(of: settings.normalizationStrength) { _, newValue in
                        // b35-sweep-settings: 同上，强度也只在 init
                        // 读一次，不推就一直是旧强度。
                        NativeMusicPlayer.shared.setNormalizationStrength(newValue)
                    }
                    footnote("当前：\(NormalizationStrengthLabel.label(for: Double(settings.normalizationStrength)))")
                }
            }
        }
    }

    // MARK: - 直播

    private var liveSection: some View {
        Section(header: SettingsSectionHeader(section: .live)) {
            if isExpanded(.live) {
                NavigationLink("弹幕设置") {
                    LiveDanmakuSettingsSheet(settings: $danmakuSettings)
                        .onAppear {
                            // b35-sweep-settings: danmakuSettings 是
                            // 本页 @State、只在首次加载时读一次；直播
                            // 间里也能改弹幕（LiveRoomView 自己 load +
                            // persist），旧副本会在本页 onDisappear
                            // 时把房间里的新值整份盖回去。进页时重读。
                            danmakuSettings = LiveDanmakuSettings.load()
                        }
                        .onDisappear {
                            danmakuSettings.persist()
                        }
                }
                Toggle("移动网自动降档", isOn: $settings.cellularDowngrade)
                footnote("移动数据下进房间自动降至超清及以下；关后保持首选画质 · 下次进房间生效")
            }
        }
    }

    // MARK: - 影视播放

    private var videoSection: some View {
        Section(header: SettingsSectionHeader(section: .video)) {
            if isExpanded(.video) {
                engineRow
                lastUsedEngineRow
                footnote("下次打开生效；梯子胜出不改变偏好")
                Toggle("自动连播下一集", isOn: $settings.autoNextEpisode)
                doubleTapRow
                Toggle("对白增强", isOn: $settings.dialogueBoost)
                footnote("对白更清楚，大声不炸 · 仅 MPV")
                Toggle("防剧透：隐藏简介", isOn: $settings.hideSynopsis)
                footnote("详情页简介默认隐藏，点按查看")
                Toggle("防剧透：模糊未看海报", isOn: $settings.blurUnwatchedPosters)
                footnote("未看过的影片海报模糊显示，点按查看")
                Toggle("纯音频后台播放", isOn: $settings.audioOnlyBackground)
                footnote("只听声音，后台继续播")
                NavigationLink("影视分类排序") {
                    VideoCategoryEditView()
                }
                footnote("显示 / 隐藏 / 拖动排序")
                videoFitRow
                Toggle("Anime4K 超分", isOn: $settings.superResolution)
                    .disabled(settings.interpolation || settings.sdrToHDR)
                footnote("仅 MPV；三选一，互斥；着色器未打包，当前无实际效果")
                Toggle("插帧", isOn: $settings.interpolation)
                    .disabled(settings.superResolution || settings.sdrToHDR)
                footnote("仅 MPV，立即生效；三选一，互斥；真机效果待验证")
                Toggle("SDR 转 HDR", isOn: $settings.sdrToHDR)
                    .disabled(settings.superResolution || settings.interpolation)
                footnote("仅 MPV，立即生效；三选一，互斥；真机效果待验证")
                Toggle("杜比视界 Profile 8 降级 HDR", isOn: $settings.dvP8Downgrade)
                footnote("开：P8 可走系统播放器；关：P8 只走 MPV / IJK")
                skipIntroRow
                subtitleFontSizeRow
                subtitleColorRow
                subtitlePositionRow
                lowMemoryRow
            }
        }
    }

    private var engineRow: some View {
        Picker("播放器引擎", selection: $settings.enginePreference) {
            ForEach(VideoEngine.allCases, id: \.self) { engine in
                Text(engine.displayName).tag(engine)
            }
        }
    }

    private var lastUsedEngineRow: some View {
        HStack {
            Text("上次实际")
                .font(.system(size: 15))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Text(engineReporter.lastUsed?.displayName ?? "—")
                .font(.system(size: 15))
                .foregroundStyle(theme.textSecondary)
        }
    }

    private var doubleTapRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper(
                "双击快进秒数",
                value: $settings.doubleTapSeconds,
                in: 5...30,
                step: 5
            )
            footnote("当前：\(settings.doubleTapSeconds) 秒")
        }
    }

    private var videoFitRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("视频画面比例", selection: $settings.videoFit) {
                ForEach(VideoFit.allCases, id: \.self) { fit in
                    Text(fit.label).tag(fit)
                }
            }
            footnote("当前：\(settings.videoFit.label)")
        }
    }

    private var skipIntroRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(
                "跳过片头片尾",
                selection: optionBinding(
                    get: { settings.skipIntroMode },
                    set: { newValue in settings.skipIntroMode = newValue },
                    valid: SettingsOptionLists.isValidSkipIntroMode,
                    default: SettingsOptionLists.skipIntroDefault
                )
            ) {
                ForEach(SettingsOptionLists.skipIntroOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            footnote("当前：\(SettingsOptionLists.label(for: settings.skipIntroMode, in: SettingsOptionLists.skipIntroOptions, default: SettingsOptionLists.skipIntroDefault))")
        }
    }

    private var subtitleFontSizeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(
                "字幕字号",
                selection: optionBinding(
                    get: { settings.subtitleFontSize },
                    set: { newValue in settings.subtitleFontSize = newValue },
                    valid: SettingsOptionLists.isValidSubtitleFontSize,
                    default: SettingsOptionLists.subtitleFontSizeDefault
                )
            ) {
                ForEach(SettingsOptionLists.subtitleFontSizeOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            footnote("当前：\(SettingsOptionLists.label(for: settings.subtitleFontSize, in: SettingsOptionLists.subtitleFontSizeOptions, default: SettingsOptionLists.subtitleFontSizeDefault))")
        }
    }

    private var subtitleColorRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(
                "字幕颜色",
                selection: optionBinding(
                    get: { settings.subtitleColor },
                    set: { newValue in settings.subtitleColor = newValue },
                    valid: SettingsOptionLists.isValidSubtitleColor,
                    default: SettingsOptionLists.subtitleColorDefault
                )
            ) {
                ForEach(SettingsOptionLists.subtitleColorOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            footnote("当前：\(SettingsOptionLists.label(for: settings.subtitleColor, in: SettingsOptionLists.subtitleColorOptions, default: SettingsOptionLists.subtitleColorDefault))")
        }
    }

    private var subtitlePositionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(
                "字幕位置",
                selection: optionBinding(
                    get: { settings.subtitlePosition },
                    set: { newValue in settings.subtitlePosition = newValue },
                    valid: SettingsOptionLists.isValidSubtitlePosition,
                    default: SettingsOptionLists.subtitlePositionDefault
                )
            ) {
                ForEach(SettingsOptionLists.subtitlePositionOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            footnote("当前：\(SettingsOptionLists.label(for: settings.subtitlePosition, in: SettingsOptionLists.subtitlePositionOptions, default: SettingsOptionLists.subtitlePositionDefault))")
        }
    }

    private var lowMemoryRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(
                "低内存模式",
                selection: optionBinding(
                    get: { settings.lowMemoryMode },
                    set: { newValue in settings.lowMemoryMode = newValue },
                    valid: SettingsOptionLists.isValidLowMemoryMode,
                    default: SettingsOptionLists.lowMemoryDefault
                )
            ) {
                ForEach(SettingsOptionLists.lowMemoryOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            footnote("当前：\(SettingsOptionLists.label(for: settings.lowMemoryMode, in: SettingsOptionLists.lowMemoryOptions, default: SettingsOptionLists.lowMemoryDefault))")
        }
    }

    // MARK: - 源管理

    private var sourcesSection: some View {
        Section(header: SettingsSectionHeader(section: .sources)) {
            if isExpanded(.sources) {
                NavigationLink("音源管理") {
                    LXSourceManagementView()
                }
                NavigationLink("影视源管理") {
                    CmsSourceManagementView()
                }
                NavigationLink("直播源管理") {
                    LiveSourceManagementView()
                }
                NavigationLink {
                    EmbyConfigView()
                        .onDisappear {
                            // The Emby page saves through its own
                            // view-model instance; refresh this
                            // row's subtitle when coming back.
                            embyViewModel.reload()
                        }
                } label: {
                    HStack {
                        Text("Emby 连接")
                        Spacer()
                        Text(embySubtitle)
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
        }
    }

    private var embySubtitle: String {
        switch embyViewModel.status {
        case .unconfigured:
            return "未配置"
        case .configured(let serverName, _):
            return serverName.isEmpty ? "已配置" : serverName
        case .testing:
            return "测试中…"
        case .failed:
            return "连接失败"
        }
    }

    // MARK: - 数据

    private var dataSection: some View {
        Section(header: SettingsSectionHeader(section: .data)) {
            if isExpanded(.data) {
                HStack {
                    Text("缓存管理")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(cacheSizeBytes),
                        countStyle: .file
                    ))
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
                    Button("清理") {
                        showingClearCacheAlert = true
                    }
                    .font(.system(size: 14))
                }
                .alert("清理缓存", isPresented: $showingClearCacheAlert) {
                    Button("取消", role: .cancel) {
                    }
                    Button("清理", role: .destructive) {
                        // Coordinator fix (S5 merge): CacheManager is
                        // async (background queue, completion on
                        // main) — refresh only after the clear
                        // actually finished.
                        CacheManager.clearAll {
                            refreshCacheSize()
                        }
                    }
                } message: {
                    Text("将清理已缓存的临时数据，已下载内容不受影响。")
                }
                .onAppear {
                    refreshCacheSize()
                }
                backupExportRow
                backupImportRow
            }
        }
    }

    // MARK: - 数据：备份 (S6-B)

    private var backupExportRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("导出备份")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if backupFlow.isExporting {
                    ProgressView()
                } else {
                    Button("导出") {
                        backupFlow.beginExport()
                    }
                    .font(.system(size: 14))
                }
            }
            if let exportedURL = backupFlow.exportedURL {
                ShareLink(item: exportedURL) {
                    HStack {
                        Text("分享备份文件")
                            .font(.system(size: 15))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text(exportedURL.lastPathComponent)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                footnote("已导出，可分享保存到文件 App 或发送给自己。")
            } else {
                footnote("导出为单个 .zip 文件；备份不含 Emby 登录凭证。")
            }
        }
    }

    private var backupImportRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("导入备份")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if backupFlow.isImporting {
                    ProgressView()
                } else {
                    Button("选择文件") {
                        backupFlow.beginImport()
                    }
                    .font(.system(size: 14))
                }
            }
            footnote("从 .zip 备份文件导入；导入失败会自动回滚，现有数据不受影响。")
        }
    }

    private func refreshCacheSize() {
        // Coordinator fix (S5 merge): totalSizeBytes is async —
        // the A-leg API takes a completion, it is not a sync Int.
        CacheManager.totalSizeBytes { total in
            cacheSizeBytes = Int(total)
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section(header: SettingsSectionHeader(section: .about)) {
            if isExpanded(.about) {
                HStack {
                    Text("版本")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text(bundleVersion)
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textSecondary)
                }
                checkUpdateRow
                skippedVersionRow
                Toggle("启动时自动检查更新", isOn: $settings.autoUpdateCheck)
            }
        }
    }

    // MARK: - 关于：检查更新 (S6-B)

    /// Check row: the 版本 row above already shows the current
    /// version, so this row shows the last check time + the
    /// check button. The auto-check switch already exists (S5)
    /// and is NOT duplicated here.
    private var checkUpdateRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("检查更新")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textPrimary)
                Text(UpdateCheckLogic.lastCheckLabel(date: backupFlow.lastCheckDate, now: Date()))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textMuted)
            }
            Spacer()
            if backupFlow.isCheckingUpdate {
                ProgressView()
            } else {
                Button("检查") {
                    backupFlow.checkForUpdate()
                }
                .font(.system(size: 14))
            }
        }
    }

    /// "已跳过 X 版本，点按取消跳过" — only when the checker
    /// reports a skipped version. The skip itself lives with
    /// the checker (C leg); this row only reads and clears it.
    @ViewBuilder
    private var skippedVersionRow: some View {
        if let skipped = backupFlow.skippedVersionLabel {
            HStack {
                Text("已跳过 \(skipped)，点按取消跳过")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Button("取消跳过") {
                    backupFlow.clearSkippedVersion()
                }
                .font(.system(size: 14))
            }
        }
    }

    /// Bundle version (Info.plist CFBundleShortVersionString /
    /// build) — same computation as MyPlaceholderView.
    private var bundleVersion: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (build \(build))"
    }
}

// MARK: - 壁纸管理

/// Wallpaper list + delete + PhotosPicker import, backed by
/// WallpaperStore (A leg). Tapping a row makes it the current
/// wallpaper (SettingsStore.wallpaperCurrent). Files live under
/// `wallpapers/` by relative name only — never absolute paths.
struct WallpaperManagementView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.haoTheme) private var theme

    @State private var names: [String] = []
    @State private var photoItem: PhotosPickerItem?
    @State private var showingImportFailedAlert = false

    var body: some View {
        List {
            Section {
                if names.isEmpty {
                    Text("还没有壁纸，从相册导入一张。")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textMuted)
                } else {
                    ForEach(names, id: \.self) { name in
                        wallpaperRow(name)
                    }
                    .onDelete(perform: deleteWallpapers)
                }
            }
            Section {
                PhotosPicker(
                    "从相册导入",
                    selection: $photoItem,
                    matching: .images
                )
            }
        }
        .haoBottomChromePadding()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.scaffoldBackground)
        .navigationTitle("壁纸管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            reload()
        }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem = newItem else { return }
            importPhoto(newItem)
        }
        .alert("导入失败", isPresented: $showingImportFailedAlert) {
            Button("好", role: .cancel) {
            }
        } message: {
            Text("这张图片无法导入，请换一张试试。")
        }
    }

    private func wallpaperRow(_ name: String) -> some View {
        Button(action: {
            settings.wallpaperCurrent = name
        }) {
            HStack {
                Text(displayName(for: name))
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if settings.wallpaperCurrent == name {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func displayName(for relativeName: String) -> String {
        URL(fileURLWithPath: relativeName).lastPathComponent
    }

    private func reload() {
        names = WallpaperStore.list()
    }

    private func deleteWallpapers(at offsets: IndexSet) {
        let deleted = offsets.map { names[$0] }
        for name in deleted {
            WallpaperStore.delete(name)
        }
        if deleted.contains(settings.wallpaperCurrent) {
            settings.wallpaperCurrent = ""
        }
        settings.reloadWallpapers()
        reload()
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        item.loadTransferable(type: Data.self) { result in
            switch result {
            case .success(let data):
                guard let data = data else {
                    DispatchQueue.main.async {
                        showingImportFailedAlert = true
                    }
                    return
                }
                let imported = WallpaperStore.importImage(data: data)
                DispatchQueue.main.async {
                    if let imported = imported {
                        settings.wallpaperCurrent = imported
                        settings.reloadWallpapers()
                        reload()
                    } else {
                        showingImportFailedAlert = true
                    }
                }
            case .failure:
                DispatchQueue.main.async {
                    showingImportFailedAlert = true
                }
            }
        }
    }
}

// MARK: - 影视分类排序

/// Category show/hide + drag reorder. Names come from the video
/// gateway (`fetchTypeNames`, same source as the video home
/// page); prefs are VideoLibraryStore.categoryPrefs. Every
/// change is saved immediately, so the video tab picks it up on
/// its next load.
struct VideoCategoryEditView: View {
    @Environment(\.haoTheme) private var theme

    @State private var displayNames: [String] = []
    @State private var hiddenNames: Set<String> = []
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded {
                List {
                    Section {
                        ForEach(displayNames, id: \.self) { name in
                            categoryRow(name)
                        }
                        .onMove(perform: moveCategories)
                    } footer: {
                        Text("关掉的分类不会在影视首页出现；拖动可调整顺序，改完立即生效。")
                    }
                }
                .haoBottomChromePadding()
                .environment(\.editMode, .constant(.active))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.scaffoldBackground)
        .navigationTitle("影视分类排序")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadCategories()
        }
    }

    private func categoryRow(_ name: String) -> some View {
        HStack {
            Text(name)
                .font(.system(size: 15))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Toggle(
                "显示",
                isOn: Binding<Bool>(
                    get: { !hiddenNames.contains(name) },
                    set: { newValue in
                        if newValue {
                            hiddenNames.remove(name)
                        } else {
                            hiddenNames.insert(name)
                        }
                        savePrefs()
                    }
                )
            )
            .labelsHidden()
        }
    }

    private func loadCategories() {
        let prefs = VideoLibraryStore.categoryPrefs()
        let gateway = VideoServices.makeGateway()
        gateway.fetchTypeNames { names in
            let visible = VideoLibraryStore.visibleCategories(names, prefs: prefs)
            var ordered = visible
            for name in prefs.order where prefs.hidden.contains(name) && names.contains(name) {
                if !ordered.contains(name) {
                    ordered.append(name)
                }
            }
            for name in names where !ordered.contains(name) {
                ordered.append(name)
            }
            displayNames = ordered
            hiddenNames = Set(prefs.hidden.filter { names.contains($0) })
            loaded = true
        }
    }

    private func moveCategories(from source: IndexSet, to destination: Int) {
        displayNames.move(fromOffsets: source, toOffset: destination)
        savePrefs()
    }

    private func savePrefs() {
        var prefs = VideoLibraryStore.categoryPrefs()
        // Stale hidden names (no longer returned by the gateway)
        // stay hidden — saving must not silently unhide them.
        let staleHidden = prefs.hidden.filter { !displayNames.contains($0) }
        prefs.hidden = displayNames.filter { hiddenNames.contains($0) } + staleHidden
        prefs.order = displayNames
        VideoLibraryStore.saveCategoryPrefs(prefs)
    }
}

// MARK: - Tab accent choice

/// One tab-bar selected-colour swatch. `nil` colour = theme
/// default ("默认"). A struct (not a tuple): ForEach cannot
/// key-path into tuple elements.
struct TabAccentChoice: Identifiable {
    let label: String
    let color: Color?

    var id: String { label }
}

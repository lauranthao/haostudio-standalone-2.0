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
import UIKit
import UniformTypeIdentifiers

/// Shared collapsible-section fold row: tap the row to fold /
/// unfold the section, chevron tracks the state. Used by the 8
/// settings groups in `SettingsGroupsView` and by the 我的 entry
/// section in `MyView`, so every section folds the same way.
/// Reads the fold state from `SettingsStore` directly; default
/// expanded (no stored key reads back as true).
/// b48 (chen 2026-11-25 build 47: "这里还是不能收放", second
/// failure of the header-Button approach): the fold control used
/// to live in the List section HEADER (SettingsSectionHeader).
/// The first section's header is invisible on device — MyView's
/// List pulls its content up 51pt (.contentMargins(.top, -51),
/// the b45 title-gap fix), so the 外观 header sits underneath
/// the 我的 title where chen can neither see nor tap it, and the
/// only chevron he sees is the theme Picker's menu chevron (⌃),
/// which opens the theme menu instead of folding. The fold is
/// therefore a ROW inside the section now — the first row, always
/// visible, always tappable (List rows always receive taps, header
/// Buttons do not reliably). When collapsed only this row shows.
/// Same UserDefaults keys (settingsSectionExpanded_<id>) and the
/// same @Published collapsedSections state as before.
struct SettingsSectionFoldRow: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.haoTheme) private var theme

    let section: SettingsSection

    var body: some View {
        Button(action: {
            withAnimation(HaoLayout.settleSpring) {
                settings.setSectionExpanded(!settings.sectionExpanded(section.rawValue), for: section.rawValue)
            }
        }) {
            HStack {
                Text(section.title)
                    .font(.haoSubheadStrong)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Image(systemName: settings.sectionExpanded(section.rawValue) ? "chevron.down" : "chevron.right")
                    .font(.haoFootnoteStrong)
                    .foregroundStyle(theme.textMuted)
                    .animation(HaoLayout.settleSpring, value: settings.sectionExpanded(section.rawValue))
            }
            .contentShape(Rectangle())
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

    /// VOD danmaku API address + token (b36 item 11), for the
    /// "影视弹幕 API" entry subtitle. Read once per appear of
    /// this page; refreshed when the detail page disappears.
    /// The token never appears on this list page.
    @State private var vodDanmakuApiConfig = VodDanmakuApiConfig.load()

    /// Entry subtitle: "官方地址" while no custom address is
    /// set, otherwise only the host the user typed.
    private var vodDanmakuApiSubtitle: String {
        guard vodDanmakuApiConfig.isCustomAddress else { return "官方地址" }
        return vodDanmakuApiConfig.displayHost ?? "自定义地址"
    }

    /// Background-colour hex draft. Only a valid `#RRGGBB`
    /// draft is written to the store; an invalid one reverts.
    @State private var bgHexDraft = ""

    /// EQ on/off (hao_eq_enabled, written by
    /// MusicEqualizerViewModel / NativeMusicPlayer). 音量归一化
    /// can only measure loudness while EQ is on (the player
    /// returns gain 1.0 otherwise), so the toggle is disabled
    /// with an inline hint until EQ is on (b49 sweep P1).
    /// @AppStorage observes the shared defaults, so flipping EQ
    /// in the 均衡器 page re-enables the toggle here live.
    @AppStorage("hao_eq_enabled") private var eqEnabled = false

    /// Cached size (bytes) shown in the 数据 group. Refreshed
    /// on appear and after clearing.
    @State private var cacheSizeBytes: Int = 0

    /// Cache-clear confirmation.
    @State private var showingClearCacheAlert = false

    /// Disclaimer sheet (read-only, from the About section).
    @State private var showingDisclaimer = false

    /// Storage section state (b45-coda 包 C, §4.4). Refreshed on
    /// appear and after every clear.
    @State private var storageTotalBytes: Int64 = 0
    @State private var storageFreeBytes: Int64 = 0
    @State private var storageAppBytes: Int64 = 0
    @State private var storageNetworkBytes: Int64 = 0
    @State private var storageTempBytes: Int64 = 0
    @State private var storageDownloadsBytes: Int64 = 0
    @State private var storageLoaded = false
    @State private var clearingStorageCategory: String?

    var body: some View {
        Group {
            appearanceSection
            musicSection
            liveSection
            videoSection
            sourcesSection
            dataSection
            storageSection
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
        // The update sheet lives at the app root now
        // (HAoStudioApp, backupFlow): it must present on every
        // tab, including the launch-time auto-check prompt while
        // the Home tab is up — this page only mounts on the My tab.
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
        // b45-coda 包 C: sheets hang on the Form (this Group),
        // never on a Section / row — iOS dismisses a sheet
        // attached to a Section when the List re-renders.
        .sheet(isPresented: $showingDisclaimer) {
            DisclaimerView(mode: .readOnly)
        }
        .sheet(isPresented: $backupFlow.showingUpdateStatus) {
            UpdateStatusSheet()
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
            .font(.haoFootnote)
            .foregroundStyle(theme.textSecondary)
            .listRowSeparator(.hidden)
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
        Section {
            SettingsSectionFoldRow(section: .appearance)
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

    /// Theme picker, navigation style — label left, current
    /// value right, chevron (system settings row grammar).
    private var themeRow: some View {
        Picker("主题", selection: $themeStore.themeID) {
            ForEach(HaoThemeID.allCases) { id in
                Text(id.displayName).tag(id)
            }
        }
    }

    private var appearanceRow: some View {
        HStack {
            Text("外观")
                .font(.haoBody)
                .foregroundStyle(theme.textPrimary)
            Picker("外观", selection: $themeStore.appearance) {
                ForEach(HaoAppearance.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
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
                .font(.haoBody)
                .foregroundStyle(theme.accentText)
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
                .font(.haoBody)
                .foregroundStyle(theme.textPrimary)
            HStack(spacing: 12) {
                ForEach(tabAccentChoices) { choice in
                    tabAccentSwatch(choice)
                }
            }
            // b36 item 8, F8: this palette and 自定义强调色 above
            // write the SAME key (hao_tabbar_accent — Flutter
            // parity, one key, two views). Say so, or picking
            // "蓝" here and watching every button turn blue looks
            // like a bug.
            footnote("与自定义强调色共用同一颜色，改一边另一边跟着变。")
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
                                    .font(.haoRowSubtitle)
                                    .foregroundStyle(theme.textSecondary)
                            }
                    }
                    if selected {
                        Circle()
                            .strokeBorder(theme.textPrimary, lineWidth: 2)
                            .frame(width: 36, height: 36)
                    }
                }
                Text(choice.label)
                    .font(.haoCaption2)
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
                // Chrome O3: the slider only tunes card / sheet
                // surfaces — the tab bar and mini player keep the
                // system glass strength, so the label must not
                // promise whole-app glass.
                Text("卡片玻璃强度")
                    .font(.haoBody)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text("\(Int(settings.glassIntensity * 100))%")
                    .font(.haoBody)
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
            .tint(theme.accent)
            Text("仅调整卡片、浮层等表面的玻璃效果；底栏与迷你播放器保持系统玻璃强度不变。")
                .font(.haoFootnote)
                .foregroundStyle(theme.textSecondary)
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
        Section {
            SettingsSectionFoldRow(section: .music)
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
                    // b49 sweep P1: the toggle is a silent no-op
                    // unless EQ is on (no measured loudness, gain
                    // stays 1.0) — grey it out with an inline
                    // hint until EQ is on, instead of letting it
                    // look live. The 均衡器 entry sits directly
                    // above this row.
                    .disabled(!eqEnabled)
                    .onChange(of: settings.normalizationEnabled) { _, newValue in
                        // b35-sweep-settings: NativeMusicPlayer 只在
                        // init 读一次归一化开关/强度进内存变量，
                        // setter 全 app 零调用，设置页拨开关要重启
                        // 才生效。推给 player（下一首起作用，不改
                        // 正播的歌，与 player 的注释一致）。
                        NativeMusicPlayer.shared.setNormalizationEnabled(newValue)
                    }
                footnote(eqEnabled ? "需开启均衡器才能测量响度" : "先开启均衡器，才能测量响度")
                Stepper(
                    value: $settings.normalizationStrength,
                    in: 0...2,
                    step: 1
                ) {
                    HStack {
                        Text("归一化强度")
                        Spacer()
                        Text(NormalizationStrengthLabel.label(for: Double(settings.normalizationStrength)))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .tint(theme.accent)
                .onChange(of: settings.normalizationStrength) { _, newValue in
                    // b35-sweep-settings: 同上，强度也只在 init
                    // 读一次，不推就一直是旧强度。
                    NativeMusicPlayer.shared.setNormalizationStrength(newValue)
                }
            }
        }
    }

    // MARK: - 直播

    private var liveSection: some View {
        Section {
            SettingsSectionFoldRow(section: .live)
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
        Section {
            SettingsSectionFoldRow(section: .video)
            if isExpanded(.video) {
                engineRow
                lastUsedEngineRow
                footnote("下次打开生效；自动切换引擎时不改变偏好")
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
                // b49 sweep P2: the Anime4K 超分 row is removed —
                // the shaders were never bundled, so the branch is
                // a documented no-op in MpvPlayerBackend; a switch
                // that admits it does nothing is a dead control.
                // It returns when shaders ship. The stored value
                // is cleared once in SettingsStore so a stale true
                // cannot keep resolving to the no-op branch, and
                // the two remaining branches stay mutually
                // exclusive (二选一).
                Toggle("插帧", isOn: $settings.interpolation)
                    .disabled(settings.sdrToHDR)
                footnote("仅 MPV，立即生效；二选一，互斥")
                Toggle("SDR 转 HDR", isOn: $settings.sdrToHDR)
                    .disabled(settings.interpolation)
                footnote("仅 MPV，立即生效；二选一，互斥")
                Toggle("杜比视界 Profile 8 降级 HDR", isOn: $settings.dvP8Downgrade)
                footnote("开：P8 可走系统播放器；关：P8 只走 MPV / IJK")
                skipIntroRow
                subtitleFontSizeRow
                subtitleColorRow
                subtitlePositionRow
                lowMemoryRow
                NavigationLink {
                    VodDanmakuApiSettingsView()
                        .onDisappear {
                            // b36 item 11: the page saves through
                            // its own drafts; refresh this row's
                            // subtitle when coming back.
                            vodDanmakuApiConfig = VodDanmakuApiConfig.load()
                        }
                } label: {
                    HStack {
                        Text("影视弹幕 API")
                        Spacer()
                        Text(vodDanmakuApiSubtitle)
                            .font(.haoBody)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
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
                .font(.haoBody)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Text(engineReporter.lastUsed?.displayName ?? "—")
                .font(.haoBody)
                .foregroundStyle(theme.textSecondary)
        }
    }

    private var doubleTapRow: some View {
        Stepper(
            value: $settings.doubleTapSeconds,
            in: 5...30,
            step: 5
        ) {
            HStack {
                Text("双击快进秒数")
                Spacer()
                Text("\(settings.doubleTapSeconds) 秒")
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .tint(theme.accent)
    }

    private var videoFitRow: some View {
        Picker("视频画面比例", selection: $settings.videoFit) {
            ForEach(VideoFit.allCases, id: \.self) { fit in
                Text(fit.label).tag(fit)
            }
        }
    }

    private var skipIntroRow: some View {
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
    }

    private var subtitleFontSizeRow: some View {
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
    }

    private var subtitleColorRow: some View {
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
    }

    private var subtitlePositionRow: some View {
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
    }

    private var lowMemoryRow: some View {
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
    }

    // MARK: - 源管理

    private var sourcesSection: some View {
        Section {
            SettingsSectionFoldRow(section: .sources)
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
                            .font(.haoBody)
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
        Section {
            SettingsSectionFoldRow(section: .data)
            if isExpanded(.data) {
                HStack {
                    Text("缓存管理")
                        .font(.haoBody)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(cacheSizeBytes),
                        countStyle: .file
                    ))
                    .font(.haoBody)
                    .foregroundStyle(theme.textSecondary)
                    Button("清理") {
                        showingClearCacheAlert = true
                    }
                    .font(.haoBody)
                    .foregroundStyle(theme.accentText)
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
                    .font(.haoBody)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if backupFlow.isExporting {
                    ProgressView()
                } else {
                    Button("导出") {
                        backupFlow.beginExport()
                    }
                    .font(.haoBody)
                    .foregroundStyle(theme.accentText)
                }
            }
            if let exportedURL = backupFlow.exportedURL {
                ShareLink(item: exportedURL) {
                    HStack {
                        Text("分享备份文件")
                            .font(.haoBody)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text(exportedURL.lastPathComponent)
                            .font(.haoFootnote)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                footnote("已导出，可分享保存到文件 App 或发送给自己。")
                // b36 item 8, F1: envelope warnings (notably the
                // Emby credential warning) — the file does not
                // contain everything, and the user must see that
                // here, not only at restore time.
                ForEach(backupFlow.exportWarnings, id: \.self) { warning in
                    footnote(warning)
                }
            } else {
                footnote("导出为单个 .zip 文件；备份不含 Emby 登录凭证。")
            }
        }
    }

    private var backupImportRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("导入备份")
                    .font(.haoBody)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if backupFlow.isImporting {
                    ProgressView()
                } else {
                    Button("选择文件") {
                        backupFlow.beginImport()
                    }
                    .font(.haoBody)
                    .foregroundStyle(theme.accentText)
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

    // MARK: - 存储空间 (b45-coda 包 C, §4.4)

    /// Capacity bar + per-category cleanup + song-cache cap.
    /// The audio cache engine itself is 包 F's — this section
    /// only renders the UI and calls the cleanup that exists
    /// today (URLCache + .part files via CacheManager's public
    /// facts); categories with no cleanup API are listed in the
    /// footnote instead of getting a dead delete button.
    private var storageSection: some View {
        Section(
            footer: Text("可删除的项目会在需要时重新获取或生成；最近 10 分钟内写入的歌曲与临时文件会暂时保留。")
                .font(.haoCaption)
                .foregroundStyle(theme.textSecondary)
        ) {
            SettingsSectionFoldRow(section: .storage)
            if isExpanded(.storage) {
                storageCapacityBlock
                storageAppUsageRow
                storageDownloadsRow
                storageCategoryRow(
                    id: "network",
                    title: "网络缓存",
                    detail: "接口与图片的网络缓存，清理后重新加载。",
                    size: storageNetworkBytes,
                    onClear: clearNetworkCache
                )
                storageCategoryRow(
                    id: "temp",
                    title: "临时文件",
                    detail: "下载中断留下的临时文件，10 分钟内在用的会保留。",
                    size: storageTempBytes,
                    onClear: clearTempFiles
                )
                Toggle("歌曲缓存", isOn: $settings.songCacheEnabled)
                Picker(
                    "缓存上限",
                    selection: $settings.songCacheLimitMB
                ) {
                    ForEach(SongCacheLimitOptions.values, id: \.self) { megabytes in
                        Text(SongCacheLimitOptions.label(for: megabytes)).tag(megabytes)
                    }
                }
                .disabled(!settings.songCacheEnabled)
                footnote("歌曲缓存、图片、分析、模型、诊断与离线索引暂无单独清理入口，可在“数据”分组用“清理缓存”一并清理；上限的执行由音频缓存引擎负责。")
            }
        }
        .onAppear {
            refreshStorage()
        }
    }

    /// Top capacity block: device name + "已用 X，共 Y" + the
    /// three-segment bar + legend. Coda values (§4.4): bar 18pt,
    /// corner 4 continuous, hairline stroke; segments app /
    /// other / free; legend via ViewThatFits.
    private var storageCapacityBlock: some View {
        VStack(spacing: 12) {
            HStack {
                Text(UIDevice.current.name)
                    .font(.haoBodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text(storageCapacityLabel)
                    .font(.haoBody)
                    .foregroundStyle(theme.textSecondary)
                    .monospacedDigit()
            }
            storageCapacityBar
            storageLegend
        }
        .padding(.vertical, 4)
    }

    private var storageCapacityLabel: String {
        guard storageLoaded, storageTotalBytes > 0 else { return "正在统计…" }
        let used = storageTotalBytes - storageFreeBytes
        return "已用 \(formattedBytes(used))，共 \(formattedBytes(storageTotalBytes))"
    }

    private var storageCapacityBar: some View {
        let fractions = StorageCapacityMath.segments(
            app: storageAppBytes,
            used: storageTotalBytes - storageFreeBytes,
            total: storageTotalBytes
        )
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                if fractions.app > 0 {
                    theme.accent
                        .frame(width: max(0, geometry.size.width * fractions.app))
                }
                if fractions.app > 0 && fractions.other > 0 {
                    theme.scaffoldBackground.frame(width: 1)
                }
                if fractions.other > 0 {
                    Color.gray.opacity(0.45)
                        .frame(width: max(0, geometry.size.width * fractions.other))
                }
                if fractions.other > 0 && fractions.free > 0 {
                    theme.scaffoldBackground.frame(width: 1)
                }
                if fractions.free > 0 {
                    Color.primary.opacity(0.04)
                        .frame(width: max(0, geometry.size.width * fractions.free))
                }
            }
        }
        .frame(height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
    }

    private var storageLegend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                storageLegendItems
            }
            VStack(alignment: .leading, spacing: 8) {
                storageLegendItems
            }
        }
    }

    private var storageLegendItems: some View {
        Group {
            storageLegendItem(color: theme.accent, text: "HAo Studio")
            storageLegendItem(color: Color.gray.opacity(0.55), text: "其他已用")
            storageLegendItem(color: Color.primary.opacity(0.12), text: "可用")
        }
    }

    private func storageLegendItem(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.haoCaption)
                .foregroundStyle(theme.textSecondary)
        }
    }

    private var storageAppUsageRow: some View {
        LabeledContent {
            Text(formattedBytes(storageAppBytes))
                .font(.haoBodyStrong)
                .foregroundStyle(theme.textPrimary)
                .monospacedDigit()
        } label: {
            Label("HAo Studio 占用", systemImage: "internaldrive")
        }
    }

    private var storageDownloadsRow: some View {
        NavigationLink(destination: MusicDownloadsView()) {
            HStack {
                Label("已下载", systemImage: "arrow.down.circle")
                Spacer()
                Text(formattedBytes(storageDownloadsBytes))
                    .font(.haoBody)
                    .foregroundStyle(theme.textSecondary)
                    .monospacedDigit()
            }
        }
        .tint(theme.accent)
    }

    /// One clearable category row: title + size on the first
    /// baseline, caption detail below, borderless destructive
    /// delete (disabled at 0 or while clearing, ProgressView
    /// while clearing).
    private func storageCategoryRow(
        id: String,
        title: String,
        detail: String,
        size: Int64,
        onClear: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(.haoBody)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text(formattedBytes(size))
                    .font(.haoBody)
                    .foregroundStyle(theme.textSecondary)
                    .monospacedDigit()
                if clearingStorageCategory == id {
                    ProgressView()
                } else {
                    Button("删除", role: .destructive, action: onClear)
                        .font(.haoBody)
                        .buttonStyle(.borderless)
                        .disabled(size <= 0)
                }
            }
            Text(detail)
                .font(.haoFootnote)
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func refreshStorage() {
        let values = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        storageTotalBytes = (values?[.systemSize] as? NSNumber)?.int64Value ?? 0
        storageFreeBytes = (values?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        storageNetworkBytes = Int64(URLCache.shared.currentDiskUsage)
        storageTempBytes = CacheManager.partFilesSize()
        storageDownloadsBytes = directorySize(
            at: LocalStore.documentsDirectory().appendingPathComponent(DownloadEngine.downloadSubdir),
            excludingPartFiles: true
        )
        CacheManager.totalSizeBytes { total in
            // CacheManager counts URLCache + .part files; the
            // downloads dir is the app's other on-disk footprint.
            self.storageAppBytes = total + self.storageDownloadsBytes
            self.storageLoaded = true
        }
    }

    private func directorySize(at url: URL, excludingPartFiles: Bool) -> Int64 {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        var total: Int64 = 0
        for name in names {
            if excludingPartFiles && name.hasSuffix(".part") { continue }
            let fileURL = url.appendingPathComponent(name)
            if let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value {
                total += size
            }
        }
        return total
    }

    private func clearNetworkCache() {
        clearingStorageCategory = "network"
        URLCache.shared.removeAllCachedResponses()
        DispatchQueue.main.async {
            self.storageNetworkBytes = Int64(URLCache.shared.currentDiskUsage)
            self.clearingStorageCategory = nil
            self.refreshStorage()
        }
    }

    /// Delete .part files, keeping anything written in the last
    /// 10 minutes (Coda's inUseWindow); the directory itself is
    /// never removed.
    private func clearTempFiles() {
        clearingStorageCategory = "temp"
        DispatchQueue.global(qos: .utility).async {
            let dir = LocalStore.documentsDirectory().appendingPathComponent(DownloadEngine.downloadSubdir)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            let cutoff = Date().addingTimeInterval(-600)
            for name in names where name.hasSuffix(".part") {
                let url = dir.appendingPathComponent(name)
                let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
                if modified < cutoff {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            DispatchQueue.main.async {
                self.storageTempBytes = CacheManager.partFilesSize()
                self.clearingStorageCategory = nil
                self.refreshStorage()
            }
        }
    }

    // MARK: - 关于 (b45-coda 包 C, §4.2 / §4.3)

    /// About is the LAST Section of the settings container, not
    /// a separate page. Hero + identity rows + update rows +
    /// link rows + licence / disclaimer rows. All copy is ours
    /// (Coda's platform-naming / AGPL wording is never copied).
    private var aboutSection: some View {
        Section(
            footer: aboutFooter
        ) {
            SettingsSectionFoldRow(section: .about)
            if isExpanded(.about) {
                aboutHero
                aboutVersionRow
                aboutBuildRow
                aboutDeveloperRow
                aboutAutoCheckRow
                aboutCheckUpdateRow
                skippedVersionRow
                aboutWebsiteRow
                aboutRepoRow
                aboutIssuesRow
                aboutReleasesRow
                aboutLicensesRow
                aboutDisclaimerRow
            }
        }
    }

    /// Hero (§4.2): VStack spacing 10, centred, vertical
    /// padding 8; our logo 72×72, iOS bundle-icon corner 16
    /// continuous, no shadow / border; name .title2.bold()
    /// (22pt); slogan .subheadline secondary.
    private var aboutHero: some View {
        VStack(spacing: 10) {
            Image("Logo")
                .resizable()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text("HAo Studio")
                .font(.title2.bold())
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
            Text("音乐、视频与直播，一处尽享")
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// Identity rows: LabeledContent, left title + right value,
    /// values copyable (.textSelection(.enabled)). Version and
    /// build are SEPARATE rows. The commit row only renders when
    /// a commit value exists and is not "unknown" — this build
    /// carries none, so the row is omitted (not faked).
    private var aboutVersionRow: some View {
        aboutIdentityRow(
            icon: "number",
            title: "版本",
            value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        )
    }

    private var aboutBuildRow: some View {
        aboutIdentityRow(
            icon: "hammer",
            title: "构建号",
            value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        )
    }

    private var aboutDeveloperRow: some View {
        aboutIdentityRow(icon: "person", title: "开发者", value: "lauranthao")
    }

    private func aboutIdentityRow(icon: String, title: String, value: String) -> some View {
        LabeledContent {
            Text(value)
                .font(.haoBody)
                .foregroundStyle(theme.textSecondary)
                .textSelection(.enabled)
        } label: {
            Label(title, systemImage: icon)
        }
    }

    private var aboutAutoCheckRow: some View {
        Toggle(isOn: $settings.autoUpdateCheck) {
            Label("启动时自动检查更新", systemImage: "clock.arrow.circlepath")
        }
    }

    /// "检查更新" button: plain, full row, left-aligned, drives
    /// the existing UpdateChecker interactive check.
    private var aboutCheckUpdateRow: some View {
        Button(action: {
            backupFlow.checkForUpdate()
        }) {
            HStack {
                Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                if backupFlow.isCheckingUpdate {
                    ProgressView()
                } else {
                    Text(UpdateCheckLogic.lastCheckLabel(date: backupFlow.lastCheckDate, now: Date()))
                        .font(.haoFootnote)
                        .foregroundStyle(theme.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.textPrimary)
    }

    /// "已跳过 X 版本，点按取消跳过" — only when the checker
    /// reports a skipped version. The skip itself lives with
    /// the checker (C leg); this row only reads and clears it.
    @ViewBuilder
    private var skippedVersionRow: some View {
        if let skipped = backupFlow.skippedVersionLabel {
            HStack {
                Text("已跳过 \(skipped)，点按取消跳过")
                    .font(.haoBody)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Button("取消跳过") {
                    backupFlow.clearSkippedVersion()
                }
                .font(.haoBody)
                .foregroundStyle(theme.accentText)
            }
        }
    }

    /// b47 (chen 2026-11-25 build 46: "设置里面的官网也没改"):
    /// this still pointed at the shop (Railway). The official site
    /// is the GitHub Pages site since b46-site.
    private var aboutWebsiteRow: some View {
        AboutLinkRow(
            title: "官网",
            icon: "globe",
            url: URL(string: "https://lauranthao.github.io/haostudio-standalone-2.0/")!,
            detail: "lauranthao.github.io/haostudio-standalone-2.0"
        )
    }

    private var aboutRepoRow: some View {
        AboutLinkRow(
            title: "GitHub 仓库",
            icon: "chevron.left.forwardslash.chevron.right",
            url: URL(string: "https://github.com/lauranthao/haostudio-standalone-2.0")!,
            detail: "lauranthao/haostudio-standalone-2.0"
        )
    }

    /// b47 (chen 2026-11-25 build 46: "问题反馈的网站你也没给我
    /// 设置好"): this pointed at the issues LIST (empty, no way to
    /// file without hunting for "New issue"). It now lands directly
    /// on the new-issue chooser, where the two templates
    /// (问题反馈 / 功能建议, .github/ISSUE_TEMPLATE/) are offered.
    /// GitHub sign-in is still required to submit — Issues needs an
    /// account; the chooser itself is not publicly viewable (live
    /// check 2026-11-25: /issues/new/choose redirects to sign-in
    /// when logged out, while the templates are live on main).
    private var aboutIssuesRow: some View {
        AboutLinkRow(
            title: "问题反馈",
            icon: "exclamationmark.bubble",
            url: URL(string: "https://github.com/lauranthao/haostudio-standalone-2.0/issues/new/choose")!,
            detail: nil
        )
    }

    private var aboutReleasesRow: some View {
        AboutLinkRow(
            title: "版本发布",
            icon: "shippingbox",
            url: URL(string: "https://github.com/lauranthao/haostudio-standalone-2.0/releases")!,
            detail: nil
        )
    }

    private var aboutLicensesRow: some View {
        NavigationLink(destination: OpenSourceLicensesView()) {
            Label("开源许可与致谢", systemImage: "doc.text")
        }
        .tint(theme.accent)
    }

    private var aboutDisclaimerRow: some View {
        Button(action: {
            showingDisclaimer = true
        }) {
            HStack {
                Label("查看完整免责声明", systemImage: "exclamationmark.shield")
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.textPrimary)
    }

    /// About Section footer (VStack leading, spacing 4 = tight),
    /// rewritten for this app — never Coda's identity copy.
    private var aboutFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("HAo Studio 是一款免费的独立站应用，音乐、视频与直播内容均来自公开的第三方来源，版权归原权利人所有。")
            Text("本应用不设账号、不上传任何数据，所有内容均保存在本机。")
        }
        .font(.haoFootnote)
        .foregroundStyle(theme.textMuted)
    }
}

// MARK: - 关于链接行 (b45-coda 包 C, §4.3)

/// Link row: Link → HStack(spacing 12): Label (title, icon) +
/// Spacer(minLength 8) + optional detail + arrow.up.right
/// (caption, tertiary). Whole row tappable.
struct AboutLinkRow: View {
    let title: String
    let icon: String
    let url: URL
    let detail: String?

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Label(title, systemImage: icon)
                Spacer(minLength: 8)
                if let detail = detail, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(theme.textMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.textPrimary)
    }
}

// MARK: - 开源许可与致谢 (b45-coda 包 C, §4.3)

/// Licences sub-page: our MIT licence + thanks. There is no
/// local third-party-notices document in this repo, so the
/// fallback "致谢" group + "在 GitHub 查看第三方声明" link is
/// what ships (per §4.3 fallback). Structure copied, content
/// rewritten — Coda's AGPL/GPL rows are never copied.
struct OpenSourceLicensesView: View {
    @Environment(\.haoTheme) private var theme
    @State private var showingMIT = false

    var body: some View {
        List {
            Section("许可证") {
                Button(action: {
                    showingMIT = true
                }) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("HAo Studio")
                            .font(.haoBody)
                            .foregroundStyle(theme.textPrimary)
                        Text("MIT 许可证")
                            .font(.haoFootnote)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            Section("致谢") {
                Text(OpenSourceLicenses.thanksText)
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textSecondary)
                AboutLinkRow(
                    title: "在 GitHub 查看第三方声明",
                    icon: "chevron.left.forwardslash.chevron.right",
                    url: URL(string: "https://github.com/lauranthao/haostudio-standalone-2.0")!,
                    detail: nil
                )
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.scaffoldBackground)
        .navigationTitle("开源许可与致谢")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingMIT) {
            DocumentSheetView(title: OpenSourceLicenses.mitTitle, text: OpenSourceLicenses.mitText)
        }
    }
}

// MARK: - 文档 sheet (b45-coda 包 C, §4.3)

/// ScrollView + monospaced footnote text + padding; title =
/// file name; "完成" top-right.
struct DocumentSheetView: View {
    let title: String
    let text: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.haoTheme) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(theme.scaffoldBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 免责声明 (b45-coda 包 C, §4.3)

/// Disclaimer page, version 3 (DisclaimerGate). Read-only mode
/// = bordered "关闭"; first-launch gate mode = prominent
/// "同意并继续" (accent tint) + plain "不同意". The gate is
/// presented by MainTabView (fullScreenCover, themed palette)
/// after HAoStudioApp posts `.haoShowDisclaimerGate` when the
/// splash finishes and the stored version is not current; the
/// exit-on-decline lives in MainTabView's gate binding (a
/// dismiss without acceptance exits the app — Coda's
/// OnboardingView behaviour), so this view only records the
/// consent and confirms the decline first.
struct DisclaimerView: View {
    enum Mode {
        case readOnly
        case gate
    }

    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @Environment(\.haoTheme) private var theme
    @EnvironmentObject private var settings: SettingsStore
    /// Decline confirmation (gate mode only): refusing the
    /// disclaimer does not exit the app (b49sweep: no exit(0) on
    /// decline) — the gate simply stays presented until the user
    /// accepts, so the tap is confirmed first instead of
    /// dismissing on a mis-tap and landing straight back on
    /// the gate.
    @State private var showDeclineConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            // b45-h, 包 C leftover (b): first-launch step
            // capsules (Coda OnboardingView form — current step
            // 18pt, the rest 6pt). The onboarding is a single
            // step (disclaimer only, no login step), so there is
            // exactly one capsule, in the accent colour.
            if mode == .gate {
                Capsule()
                    .fill(theme.accentText)
                    .frame(width: 18, height: 6)
                    .padding(.top, 16)
                    .accessibilityLabel("第 1 步，共 1 步：免责声明")
            }
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.shield")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(theme.accentText)
                        Text("免责声明")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                        Text(DisclaimerContent.summary)
                            .font(.subheadline)
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    ForEach(DisclaimerContent.clauses, id: \.title) { clause in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(clause.title)
                                .font(.headline)
                                .foregroundStyle(theme.textPrimary)
                            Text(clause.body)
                                .font(.callout)
                                .foregroundStyle(theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(24)
            }
            Divider()
            VStack(spacing: 12) {
                if mode == .gate {
                    Button(action: {
                        settings.disclaimerAcceptedVersion = DisclaimerGate.currentVersion
                        dismiss()
                    }) {
                        Text("同意并继续")
                            .font(.haoBodyStrong)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    Button("不同意") {
                        showDeclineConfirm = true
                    }
                    .font(.haoBodyStrong)
                    .foregroundStyle(theme.accentText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .buttonStyle(.plain)
                } else {
                    Button(action: {
                        dismiss()
                    }) {
                        Text("关闭")
                            .font(.haoBodyStrong)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(theme.scaffoldBackground)
        .alert("需要同意免责声明", isPresented: $showDeclineConfirm) {
            Button("不同意", role: .destructive) {
                // Declining dismisses this sheet, but the gate
                // binding in MainTabView keeps the disclaimer
                // presented until it is accepted — decline
                // means stay, never exit.
                dismiss()
            }
            Button("返回阅读", role: .cancel) {
            }
        } message: {
            Text("不同意免责声明将无法使用 HAo Studio。")
        }
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
                        .font(.haoRowSubtitle)
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
                // D3: the tint colours the label text; read it in
                // accentText (the picker itself keeps the accent).
                .foregroundStyle(theme.accentText)
                .tint(theme.accent)
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
                    .font(.haoBody)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if settings.wallpaperCurrent == name {
                    Image(systemName: "checkmark")
                        .font(.haoFootnoteStrong)
                        .foregroundStyle(theme.accentText)
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
                        // An import that leaves the wallpaper off
                        // looks done (checkmark in the list) but
                        // changes nothing visible until the user
                        // flips 壁纸 on — enable it: the import IS
                        // the choice to use this photo.
                        settings.wallpaperEnabled = true
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
                    if displayNames.isEmpty {
                        // b36 item 8, F6: without this the page is
                        // a bare list + footer when the load fails
                        // or no source answers — a dead end with no
                        // explanation and nothing to do.
                        Text("未能加载分类，请检查网络后返回重试。")
                            .font(.haoRowSubtitle)
                            .foregroundStyle(theme.textMuted)
                    }
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
                .font(.haoBody)
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

// HAo Studio 2.0 — live danmaku settings sheet (S4-C leg).
//
// The 14 danmaku settings (Flutter danmaku_settings_page.dart,
// same order, same ranges and defaults):
//  1. 各平台弹幕开关 (per-platform map, absent = enabled)
//  2. 弹幕字号 12–20 (default 14)
//  3. 弹幕不透明度 0.3–1.0 (default 1.0)
//  4. 弹幕区域 full/half/third/fifth (fullscreen only)
//  5. 列表样式 compact/card (default compact)
//  6. 行间距 compact/standard/loose (default standard)
//  7. 显示用户名 (default true)
//  8. 过滤相似弹幕 (default true)
//  9. 相似度阈值 0–100 (default 85)
// 10. 屏蔽纯表情弹幕 (default false)
// 11. 屏蔽超长弹幕 (default false)
// 12. 超长字数 10–100 (default 30)
// 13. 斗鱼疑似机器人过滤 (default false)
// 14. 屏蔽管理 (blocked words / usernames)
//
// The model is B leg's LiveDanmakuSettings
// (Services/LiveSites/LiveDanmakuSettings.swift) — this sheet
// only edits a binding of it. The field names below are the
// seam assumptions (coordinator aligns them at merge; B leg
// owns the real declarations):
//   enabled: [String: Bool], fontSize: Double, opacity: Double,
//   area: String, listStyle: String, listSpacing: String,
//   showUsernames: Bool, similarityEnabled: Bool,
//   similarityThreshold: Int, blockEmoteOnly: Bool,
//   blockLong: Bool, blockLongLength: Int, douyuBotFilter: Bool,
//   blockedEntries: [LiveDanmakuBlockEntry]
//     (id: String, text: String, isUser: Bool)
//   static func load() -> LiveDanmakuSettings, func persist()
// Changes apply to the open room immediately (the room reads
// the same binding); persistence happens on dismiss.

import SwiftUI

struct LiveDanmakuSettingsSheet: View {
    @Binding var settings: LiveDanmakuSettings

    @Environment(\.dismiss) private var dismiss
    @Environment(\.haoTheme) private var theme
    @State private var blockInput = ""
    @State private var blockKindIsUser = false

    var body: some View {
        NavigationStack {
            List {
                platformSection
                fontSection
                opacitySection
                areaSection
                listSection
                filterSection
                blockSection
            }
            .listStyle(.insetGrouped)
            .background(theme.scaffoldBackground)
            .navigationTitle("弹幕设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        settings.persist()
                        dismiss()
                    }
                }
            }
            .onDisappear {
                settings.persist()
            }
        }
    }

    // MARK: - 1. Per-platform switches

    private var platformSection: some View {
        Section {
            ForEach(LivePlatform.allCases) { platform in
                Toggle(
                    platform.displayName,
                    isOn: Binding(
                        get: { settings.enabled[platform.flutterSiteId] ?? true },
                        set: { settings.enabled[platform.flutterSiteId] = $0 }
                    )
                )
            }
        } header: {
            Text("各平台弹幕开关")
        }
    }

    // MARK: - 2. Font size

    private var fontSection: some View {
        Section {
            HStack {
                Slider(
                    value: $settings.fontSize,
                    in: 12...20,
                    step: 1
                )
                Text("\(Int(settings.fontSize))")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 32, alignment: .center)
            }
        } header: {
            Text("弹幕字号")
        }
    }

    // MARK: - 3. Opacity

    private var opacitySection: some View {
        Section {
            HStack {
                Slider(
                    value: $settings.opacity,
                    in: 0.3...1.0,
                    step: 0.1
                )
                Text(String(format: "%.1f", settings.opacity))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 32, alignment: .center)
            }
        } header: {
            Text("弹幕不透明度")
        }
    }

    // MARK: - 4. Area (fullscreen only)

    private var areaSection: some View {
        Section {
            Picker("弹幕区域", selection: $settings.area) {
                Text("全屏").tag("full")
                Text("上半屏").tag("half")
                Text("上 1/3").tag("third")
                Text("上 1/5").tag("fifth")
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
        } header: {
            Text("弹幕区域")
        } footer: {
            Text("仅全屏时生效；竖屏的弹幕列表没有区域可调。")
        }
    }

    // MARK: - 5–7. List style / spacing / usernames

    private var listSection: some View {
        Section {
            Picker("列表样式", selection: $settings.listStyle) {
                Text("一行一条").tag("compact")
                Text("每条一卡").tag("card")
            }
            Picker("行间距", selection: $settings.listSpacing) {
                Text("紧密").tag("compact")
                Text("标准").tag("standard")
                Text("宽松").tag("loose")
            }
            Toggle("显示用户名", isOn: $settings.showUsernames)
        } header: {
            Text("弹幕列表")
        }
    }

    // MARK: - 8–13. Content filtering

    private var filterSection: some View {
        Section {
            Toggle("过滤相似弹幕", isOn: $settings.similarityEnabled)
            if settings.similarityEnabled {
                HStack {
                    Text("相似度阈值")
                    Spacer()
                    Text("\(settings.similarityThreshold)")
                        .foregroundStyle(theme.textSecondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(settings.similarityThreshold) },
                        set: { settings.similarityThreshold = Int($0) }
                    ),
                    in: 0...100,
                    step: 1
                )
                Text("越高越严格（只挡更像的）")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textMuted)
            }
            Toggle("屏蔽纯表情弹幕", isOn: $settings.blockEmoteOnly)
            Toggle("屏蔽超长弹幕", isOn: $settings.blockLong)
            if settings.blockLong {
                HStack {
                    Text("超长字数")
                    Spacer()
                    Text("\(settings.blockLongLength) 字")
                        .foregroundStyle(theme.textSecondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(settings.blockLongLength) },
                        set: { settings.blockLongLength = Int($0) }
                    ),
                    in: 10...100,
                    step: 1
                )
            }
            Toggle("斗鱼疑似机器人过滤", isOn: $settings.douyuBotFilter)
        } header: {
            Text("内容过滤")
        } footer: {
            Text("机器人过滤仅斗鱼生效：隐藏平台标记为疑似自动发送的弹幕。")
        }
    }

    // MARK: - 14. Block management

    private var blockSection: some View {
        Section {
            HStack(spacing: 8) {
                TextField("输入要屏蔽的词或用户名", text: $blockInput)
                    .onSubmit { addBlockEntry() }
                Picker("屏蔽类型", selection: $blockKindIsUser) {
                    Text("关键词").tag(false)
                    Text("用户名").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                Button("添加", action: addBlockEntry)
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
            }
            if settings.blockedEntries.isEmpty {
                Text("暂无屏蔽词")
                    .foregroundStyle(theme.textMuted)
            } else {
                ForEach(settings.blockedEntries) { entry in
                    HStack {
                        Text(entry.text)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text(entry.isUser ? "用户名" : "关键词")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                        Button(action: { removeBlockEntry(entry) }) {
                            Image(systemName: "trash")
                                .foregroundStyle(theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } header: {
            Text("屏蔽管理")
        }
    }

    private func addBlockEntry() {
        let text = blockInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !settings.blockedEntries.contains(where: {
            $0.text == text && $0.isUser == blockKindIsUser
        }) else {
            blockInput = ""
            return
        }
        settings.blockedEntries.append(
            LiveDanmakuBlockEntry(
                id: UUID().uuidString, text: text, isUser: blockKindIsUser))
        blockInput = ""
    }

    private func removeBlockEntry(_ entry: LiveDanmakuBlockEntry) {
        settings.blockedEntries.removeAll { $0.id == entry.id }
    }
}

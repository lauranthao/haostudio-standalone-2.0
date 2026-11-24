// HAo Studio 2.0 — VOD "更多" sheet (S3, leg A).
//
// One of the four independent VOD pieces (P0-08): this file owns
// ONLY the settings sheet state + view. It knows nothing about
// the driver or the gesture layer; the view model hands it a
// binding and applies changes back to the driver. It reads the
// danmaku layer's availability ONLY to gate the danmaku section
// (a switch over an empty layer would be a fake control) — the
// layer itself is owned by the view model, as before.
//
// NO QUALITY SELECTOR (rule 3, iron law): VOD has one play URL
// per episode and no quality tiers, so there is no quality row
// here, no fake button, no "画质" of any kind. The rows are:
// brightness / volume (the shared player rows), speed (VOD
// only), danmaku on/off + opacity (gated on availability),
// episode / line picker, picture fit, audio track, subtitle
// track, dialogue boost (MPV only), and the playback diagnosis
// (engine + hard-decode state + fps — a software decode says
// "软解中" here, never hides).
//
// All colours come from the theme palette (`.haoTheme`); no
// literal colours, no purple, no red (nothing here is a LIVE
// badge or a recording dot).
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation
import SwiftUI

// MARK: - State

/// VOD settings state. A plain value type: the view model owns
/// the current value, the sheet edits a binding, persistence is
/// UserDefaults under `hao_vod_*` keys.
struct VodSettingsState: Equatable {
    /// Picture fit (适应 / 裁剪 / 拉伸).
    var videoFit: VideoFit = .aspectFit
    /// Playback speed 0.5-2.0 (VOD only).
    var playbackSpeed: Double = 1.0
    /// Danmaku overlay on/off.
    var danmakuEnabled: Bool = true
    /// Danmaku text opacity 0.3-1.0.
    var danmakuOpacity: Double = 1.0
    /// Selected audio track index (-1 = default track).
    var audioTrackIndex: Int = -1
    /// Selected subtitle track index (-1 = no subtitles).
    var subtitleTrackIndex: Int = -1
    /// Dialogue boost (MPV only — an audio filter; other engines
    /// ignore it and the row is disabled).
    var dialogueBoostEnabled: Bool = false

    static func load(defaults: UserDefaults = .standard) -> VodSettingsState {
        var state = VodSettingsState()
        if let fitRaw = defaults.string(forKey: "hao_vod_video_fit"),
           let fit = VideoFit(rawValue: fitRaw) {
            state.videoFit = fit
        }
        let speed = defaults.double(forKey: "hao_vod_speed")
        if speed > 0 { state.playbackSpeed = min(2.0, max(0.5, speed)) }
        if defaults.object(forKey: "hao_vod_danmaku") != nil {
            state.danmakuEnabled = defaults.bool(forKey: "hao_vod_danmaku")
        }
        let opacity = defaults.double(forKey: "hao_vod_danmaku_opacity")
        if opacity > 0 { state.danmakuOpacity = min(1.0, max(0.3, opacity)) }
        // The stored -1 default is "never picked": UserDefaults
        // returns 0 for a missing key, and 0 is a real track
        // position — reading it raw forced track 0 on every fresh
        // install, overriding the backend's auto/default pick and
        // showing track 0 as picked in the sheet before the user
        // ever touched it. Same nil-guard as the subtitle track
        // below it.
        state.audioTrackIndex = defaults.object(forKey: "hao_vod_audio_track") == nil
            ? -1 : defaults.integer(forKey: "hao_vod_audio_track")
        state.subtitleTrackIndex = defaults.object(forKey: "hao_vod_subtitle_track") == nil
            ? -1 : defaults.integer(forKey: "hao_vod_subtitle_track")
        state.dialogueBoostEnabled = defaults.bool(forKey: "hao_vod_dialogue_boost")
        return state
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(videoFit.rawValue, forKey: "hao_vod_video_fit")
        defaults.set(playbackSpeed, forKey: "hao_vod_speed")
        defaults.set(danmakuEnabled, forKey: "hao_vod_danmaku")
        defaults.set(danmakuOpacity, forKey: "hao_vod_danmaku_opacity")
        defaults.set(audioTrackIndex, forKey: "hao_vod_audio_track")
        defaults.set(subtitleTrackIndex, forKey: "hao_vod_subtitle_track")
        defaults.set(dialogueBoostEnabled, forKey: "hao_vod_dialogue_boost")
    }
}

// MARK: - Sheet view

/// VOD "更多" sheet — the single entry for every in-player
/// function (chen 2026-11-24: one concise entry, no button
/// pile-up on the bar). Sections, in order: brightness/volume
/// (the shared player rows — the same implementation the live
/// room uses), speed (VOD only), danmaku, episode/line picker,
/// picture fit, tracks, dialogue boost, diagnostics.
/// `audioTracks` / `subtitleTracks` are display names from the
/// backend (empty = the row is hidden — most CMS streams carry
/// neither). `isMpv` enables the dialogue-boost row.
/// NO QUALITY SELECTOR (rule 3, iron law): VOD has one play URL
/// per episode and no quality tiers, so there is no quality row
/// here, no fake button, no "画质" of any kind.
/// The danmaku section is gated on the layer's availability: it
/// shows while loading ("弹幕加载中…", no switch yet), shows the
/// switch once items arrive, and stays hidden when the episode
/// has no danmaku source — never a fake switch.
struct VodSettingsSheet: View {
    @Environment(\.haoTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Binding var state: VodSettingsState
    var engine: VideoEngine
    var diagnostics: VideoPlaybackDiagnostics
    var audioTracks: [String] = []
    var subtitleTracks: [String] = []
    @Binding var brightness: Double
    @ObservedObject var danmaku: VodDanmakuLayerState
    var detail: VideoDetail?
    var lineIndex: Int
    var episodeIndex: Int
    /// True when the user configured a custom danmaku API address
    /// (b36 item 11, leg 3). The "重新加载弹幕" row only appears
    /// then: on the official address the client already retries
    /// an empty 200 once, so a permanent reload row would be a
    /// control most users never need.
    var isCustomDanmakuAddress = false
    /// Re-fetch danmaku for the current episode (reloadDanmaku).
    var onReloadDanmaku: (() -> Void)? = nil
    var onSelectLine: (Int) -> Void
    var onSelectEpisode: (Int) -> Void

    /// Danmaku switch state for this episode (see
    /// VodDanmakuAvailability).
    private var danmakuAvailability: VodDanmakuAvailability {
        VodDanmakuAvailability.resolve(
            isLoading: danmaku.isLoading, didLoad: danmaku.didLoad,
            itemCount: danmaku.items.count)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PlayerBrightnessVolumeRows(
                        brightness: $brightness,
                        brightnessNote: "只在视频播放器里调节；退出播放器不恢复、不覆盖系统亮度。",
                        volumeNote: "系统音量；只在视频播放器里调节。")
                } header: {
                    Text("亮度与音量")
                }

                Section {
                    HStack {
                        Text("倍速")
                        Spacer()
                        Text(String(format: "%.2fx", state.playbackSpeed))
                            .foregroundColor(theme.textSecondary)
                    }
                    Slider(value: $state.playbackSpeed, in: 0.5...2.0, step: 0.25)
                        .tint(theme.accent)
                } header: {
                    Text("倍速")
                } footer: {
                    Text("仅影视可用；长按画面可临时 2x 播放，松开恢复这里的速度。")
                }

                if danmakuAvailability != .unavailable {
                    Section {
                        switch danmakuAvailability {
                        case .loading:
                            HStack {
                                Text("弹幕加载中…")
                                    .foregroundColor(theme.textSecondary)
                                Spacer()
                                ProgressView()
                            }
                        case .available:
                            Toggle("弹幕", isOn: $state.danmakuEnabled)
                                .tint(theme.accent)
                            if state.danmakuEnabled {
                                HStack {
                                    Text("弹幕不透明度")
                                    Spacer()
                                    Text(String(format: "%.0f%%", state.danmakuOpacity * 100))
                                        .foregroundColor(theme.textSecondary)
                                }
                                Slider(value: $state.danmakuOpacity, in: 0.3...1.0, step: 0.1)
                                    .tint(theme.accent)
                            }
                            if isCustomDanmakuAddress {
                                Button("重新加载弹幕") { onReloadDanmaku?() }
                                    .foregroundStyle(theme.accentText)
                            }
                        case .unavailable:
                            EmptyView()
                        }
                    } header: {
                        Text("弹幕")
                    }
                }

                if let detail = detail {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("线路")
                                .font(.haoFootnoteMedium)
                                .foregroundColor(theme.textSecondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(Array(detail.lines.enumerated()), id: \.element.id) { index, line in
                                        Button(action: { onSelectLine(index) }) {
                                            Text(line.name)
                                                .font(.haoDenseBody)
                                                .foregroundStyle(
                                                    index == lineIndex
                                                        ? theme.onAccent : theme.textPrimary)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 8)
                                                .background(
                                                    index == lineIndex
                                                        ? theme.accent : theme.surface,
                                                    in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            Text("选集")
                                .font(.haoFootnoteMedium)
                                .foregroundColor(theme.textSecondary)
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                                spacing: 10
                            ) {
                                ForEach(Array(episodes(of: detail).enumerated()), id: \.element.id) { index, episode in
                                    Button(action: {
                                        onSelectEpisode(index)
                                        dismiss()
                                    }) {
                                        Text(episode.displayName)
                                            .font(.haoFootnoteMedium)
                                            .foregroundStyle(
                                                index == episodeIndex
                                                    ? theme.onAccent : theme.textPrimary)
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 12)
                                            .background(
                                                index == episodeIndex
                                                    ? theme.accent : theme.surface,
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    } header: {
                        Text("选集")
                    }
                }

                Section {
                    Picker("画面比例", selection: $state.videoFit) {
                        ForEach(VideoFit.allCases, id: \.self) { fit in
                            Text(fit.label).tag(fit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(theme.accent)
                } header: {
                    Text("画面")
                }

                if !audioTracks.isEmpty {
                    Section {
                        Picker("音轨", selection: $state.audioTrackIndex) {
                            Text("默认").tag(-1)
                            ForEach(audioTracks.indices, id: \.self) { index in
                                Text(audioTracks[index]).tag(index)
                            }
                        }
                    } header: {
                        Text("音轨")
                    }
                }

                if !subtitleTracks.isEmpty {
                    Section {
                        Picker("字幕", selection: $state.subtitleTrackIndex) {
                            Text("无").tag(-1)
                            ForEach(subtitleTracks.indices, id: \.self) { index in
                                Text(subtitleTracks[index]).tag(index)
                            }
                        }
                    } header: {
                        Text("字幕")
                    }
                }

                if engine == .mpv {
                    Section {
                        Toggle("对白增强", isOn: $state.dialogueBoostEnabled)
                            .tint(theme.accent)
                    } header: {
                        Text("音频")
                    } footer: {
                        Text("仅 MPV 引擎支持")
                    }
                }

                Section {
                    ForEach(diagnostics.detailLines, id: \.self) { line in
                        Text(line)
                            .foregroundColor(theme.textSecondary)
                    }
                } header: {
                    Text("播放诊断")
                }
            }
            .listStyle(.insetGrouped)
            .background(theme.scaffoldBackground)
            .navigationTitle("更多")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        // D3: the sheet tint is the accent (controls
                        // keep it); the label itself reads in
                        // accentText.
                        .foregroundStyle(theme.accentText)
                }
            }
        }
        .tint(theme.accent)
    }

    /// Episodes of the selected line (empty when the line index
    /// is stale — a line switch mid-sheet never crashes the grid).
    private func episodes(of detail: VideoDetail) -> [PlayEpisode] {
        guard detail.lines.indices.contains(lineIndex) else { return [] }
        return detail.lines[lineIndex].episodes
    }
}

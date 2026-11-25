// HAo Studio 2.0 — player sheets: sleep timer, quality, comments
// (S2-C leg).
//
// - Sleep timer: Beans ladder (5/15/30/45/60/90 min, 到歌单结束,
//   播完本首后停止, 播完 N 首后停止, 自定义 1–720 min, 关闭).
//   Wall-clock modes pause via the timer; completion modes are
//   checked by the player view model on natural track completion.
// - Quality: the 5 target tiers. The target persists to the next
//   track; a lower tier playing now never overwrites it, and the
//   badge always shows the ACTUAL tier (Master honesty gate).
// - Comments: READ-ONLY. There is no login in this app, so there is
//   no posting UI at all. The list itself needs a comments API that
//   is NOT in the LX contract, so it shows an honest empty state
//   until the LX leg provides one — no fake comments are invented.

import SwiftUI

// MARK: - Sleep timer

struct MusicSleepTimerView: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.haoTheme) private var theme

    @State private var customMinutesText = ""
    @State private var trackCountText = "3"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SleepTimerOption.all, id: \.label) { option in
                        if option == .custom {
                            customRow
                        } else if option == .afterNTracks {
                            afterNTracksRow
                        } else {
                            Button(action: {
                                select(option)
                            }) {
                                HStack {
                                    Text(option.label)
                                        .foregroundStyle(theme.textPrimary)
                                    Spacer()
                                    if isSelected(option) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(theme.accentText)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("睡眠定时")
                } footer: {
                    if playerVM.sleepActive {
                        Text(sleepStatusText(
                            option: playerVM.sleepTimer.option,
                            remainingText: playerVM.sleepRemainingText,
                            tracksCompleted: playerVM.sleepTimer.tracksCompleted,
                            trackTarget: playerVM.sleepTimer.trackTarget
                        ))
                    } else {
                        Text("到时暂停播放。播完本首 / 播完 N 首 / 到歌单结束在切歌完成时停下。")
                    }
                }
            }
            .navigationTitle("睡眠定时")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                customMinutesText = "\(MusicLibraryStore.sleepCustomMinutes())"
                trackCountText = "\(playerVM.sleepTimer.trackTarget)"
            }
        }
    }

    private func isSelected(_ option: SleepTimerOption) -> Bool {
        if !playerVM.sleepActive { return option == .off }
        return playerVM.sleepTimer.option == option
    }

    private func select(_ option: SleepTimerOption) {
        if option == .off {
            playerVM.sleepTimer.cancel()
        } else {
            playerVM.sleepTimer.start(option)
        }
        dismiss()
    }

    private var customRow: some View {
        HStack {
            Text("自定义")
                .foregroundStyle(theme.textPrimary)
            Spacer()
            TextField("分钟", text: $customMinutesText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Text("分钟")
                .font(.haoFootnote)
                .foregroundStyle(theme.textSecondary)
            Button("开始") {
                let minutes = clampSleepCustomMinutes(Int(customMinutesText))
                MusicLibraryStore.setSleepCustomMinutes(minutes)
                playerVM.sleepTimer.startCustom(minutes: minutes)
                dismiss()
            }
            .foregroundStyle(theme.accentText)
        }
    }

    private var afterNTracksRow: some View {
        HStack {
            Text("播完 N 首后停止")
                .foregroundStyle(theme.textPrimary)
            Spacer()
            TextField("首", text: $trackCountText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
            Text("首")
                .font(.haoFootnote)
                .foregroundStyle(theme.textSecondary)
            Button("开始") {
                let count = clampSleepTrackCount(Int(trackCountText))
                playerVM.sleepTimer.startAfterNTracks(count: count)
                dismiss()
            }
            .foregroundStyle(theme.accentText)
        }
    }
}

// MARK: - Quality

struct MusicQualitySheet: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.haoTheme) private var theme

    private let tiers: [AudioQuality] = [.master, .hiRes, .flac, .high320, .standard128]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(tiers, id: \.rawValue) { tier in
                        Button(action: {
                            playerVM.setTargetQuality(tier)
                            dismiss()
                        }) {
                            HStack {
                                Text(tier.displayName)
                                    .foregroundStyle(theme.textPrimary)
                                Spacer()
                                if coordinator.targetQuality == tier {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(theme.accentText)
                                }
                            }
                        }
                    }
                } header: {
                    // b49fix2 A2: "目标" is jargon — the header
                    // names the actual tier (the target quality).
                    Text("播放音质（\(MusicLibraryStore.badgeLabel(for: coordinator.targetQuality))）")
                } footer: {
                    // b49sweep P2-12: the footer describes both
                    // behaviours — a playing song re-resolves at the
                    // new quality now (position kept, old quality
                    // restored on failure); a paused / unloaded song
                    // picks it up from the next track.
                    Text("播放中的歌立刻按新音质重播（位置保留；该档位不可用时恢复之前的音质）。暂停或没有在播的歌，下一首起生效。没有该档位时立刻降一档播放，徽标只显示实际档位——降档绝不标 Master。")
                }
                Section {
                    HStack {
                        Text("当前实际")
                        Spacer()
                        Text(playerVM.qualityBadgeLabel ?? "—")
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
            .navigationTitle("音质选择")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

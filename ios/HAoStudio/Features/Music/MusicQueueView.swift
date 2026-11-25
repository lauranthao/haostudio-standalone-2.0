// HAo Studio 2.0 — playback queue sheet (S2-C leg; b45-a Coda §2.9).
//
// The current queue: current track highlighted, tap a row to play
// from there, swipe to remove, clear-all button. "不喜欢" marks the
// song as disliked for private FM (fmDislikedIds) and removes it
// from the queue.
//
// b45-a (Coda IOSPlaybackQueueView): rows are 48×48 r5 covers,
// title body medium white 0.95, artist secondary white 0.55, row
// padding 7pt; drag reorder via List + .onMove in a constant-active
// edit mode; top/bottom gradient masks (top 0–0.025, bottom
// 0.91–1.0); the row long-press menu holds exactly one item —
// destructive "从待播清单移除". Swipe-to-delete stays (C21: never
// remove an interaction we already have to match Coda).

import SwiftUI

struct MusicQueueView: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.haoTheme) private var theme

    var body: some View {
        NavigationStack {
            Group {
                if playerVM.queue.isEmpty {
                    MusicEmptyState(icon: "list.bullet", title: "队列是空的", note: "从首页、搜索或歌单里点一首歌开始播。")
                } else {
                    List {
                        Section {
                            ForEach(Array(playerVM.queue.tracks.enumerated()), id: \.element.id) { index, song in
                                queueRow(song: song, index: index)
                                    .listRowBackground(theme.scaffoldBackground)
                                    .listRowSeparatorTint(theme.hairline)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            playerVM.removeFromQueue(at: index)
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            playerVM.removeFromQueue(at: index)
                                        } label: {
                                            Label("从待播清单移除", systemImage: "minus.circle")
                                        }
                                    }
                            }
                            .onMove { source, destination in
                                playerVM.moveQueue(from: source, to: destination)
                            }
                        } header: {
                            Text("\(playerVM.queue.tracks.count) 首歌曲")
                                .font(.haoFootnote)
                                .foregroundStyle(theme.textSecondary)
                                .textCase(nil)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    // Coda queue: constant-active edit mode, so the
                    // reorder handles are always there — no separate
                    // "edit" step before dragging.
                    .environment(\.editMode, .constant(.active))
                    // Top / bottom gradient masks over the list
                    // edges (Coda: top 0–0.025, bottom 0.91–1.0).
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [theme.scaffoldBackground, theme.scaffoldBackground.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 24)
                        .allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            colors: [theme.scaffoldBackground.opacity(0), theme.scaffoldBackground],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 48)
                        .allowsHitTesting(false)
                    }
                }
            }
            .background(theme.scaffoldBackground)
            .navigationTitle("播放队列")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("清空") {
                        playerVM.clearQueue()
                    }
                    .disabled(playerVM.queue.isEmpty)
                }
            }
        }
    }

    private func queueRow(song: MusicSong, index: Int) -> some View {
        let isCurrent = index == playerVM.queue.index
        return Button(action: {
            // b49sweep P1-4: a queue-sheet tap is a manual play —
            // the song is re-asked of every source (a previously
            // failed song is not skipped from memory).
            playerVM.playFromQueue(at: index, manual: true)
        }) {
            HStack(spacing: 12) {
                MusicCoverView(urlString: song.cover, size: 48, cornerRadius: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.haoBodyMedium)
                        .foregroundStyle(isCurrent && playerVM.isPlaying ? theme.accentText : theme.textPrimary)
                        .lineLimit(1)
                    Text(song.artist)
                        .font(.haoSubhead)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if isCurrent && playerVM.isPlaying {
                    MusicPlayingEQView()
                }
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("播放 \(song.title)")
    }
}

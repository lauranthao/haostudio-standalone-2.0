// HAo Studio 2.0 — playback queue sheet (S2-C leg).
//
// The current queue: current track highlighted, tap a row to play
// from there, swipe to remove, clear-all button. "不喜欢" marks the
// song as disliked for private FM (fmDislikedIds) and removes it
// from the queue.

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
                        ForEach(Array(playerVM.queue.tracks.enumerated()), id: \.element.id) { index, song in
                            MusicSongRow(
                                song: song,
                                showPlatformBadge: false,
                                isPlaying: index == playerVM.queue.index && playerVM.isPlaying,
                                onTap: {
                                    playerVM.playFromQueue(at: index)
                                },
                                onDislike: {
                                    MusicLibraryStore.addFMDisliked(key: song.identityKey)
                                    playerVM.removeFromQueue(at: index)
                                }
                            )
                            .listRowBackground(theme.scaffoldBackground)
                            .listRowSeparatorTint(theme.hairline)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    playerVM.removeFromQueue(at: index)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(theme.scaffoldBackground)
            .navigationTitle("播放队列（\(playerVM.queue.tracks.count)）")
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
}

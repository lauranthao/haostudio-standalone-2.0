// HAo Studio 2.0 — video watch history (S3-C leg).
//
// Mirrors Flutter video_history_page.dart: newest first, one row
// per film (title + episode + progress), tap resumes, swipe to
// delete, clear-all with no silent data loss (the button is
// explicit and labelled).

import SwiftUI

struct VideoHistoryView: View {
    @State private var entries: [VideoHistoryEntry] = VideoLibraryStore.history()
    @State private var selectedItem: VideoItem?
    @State private var showClearConfirm = false

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            if entries.isEmpty {
                MusicEmptyState(
                    icon: "clock",
                    title: "还没有观看历史",
                    note: "看过的影片会出现在这里，点一下就能继续看。"
                )
            } else {
                List {
                    ForEach(entries) { entry in
                        Button(action: { selectedItem = entry.item }) {
                            HStack(spacing: 12) {
                                VideoPosterCardImage(item: entry.item, size: 80)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.item.title)
                                        .font(.haoSubheadStrong)
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                    Text(entry.episodeName.isEmpty ? "正片" : entry.episodeName)
                                        .font(.haoFootnote)
                                        .foregroundStyle(theme.textSecondary)
                                        .lineLimit(1)
                                    if entry.durationSeconds > 0 {
                                        ProgressView(value: entry.progress)
                                            .tint(theme.accent)
                                        Text(historyProgressText(entry: entry))
                                            .font(.haoCaption)
                                            .foregroundStyle(theme.textMuted)
                                    } else {
                                        Text("上次看到这里")
                                            .font(.haoCaption)
                                            .foregroundStyle(theme.textMuted)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.haoFootnoteStrong)
                                    .foregroundStyle(theme.textMuted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(theme.scaffoldBackground)
                        .listRowSeparatorTint(theme.hairline)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                VideoLibraryStore.removeHistory(
                                    title: entry.item.title, year: entry.item.year)
                                entries = VideoLibraryStore.history()
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .haoBottomChromePadding()
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("观看历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !entries.isEmpty {
                    Button("清空") { showClearConfirm = true }
                        .font(.haoSubhead)
                        .foregroundStyle(theme.accent)
                }
            }
        }
        .alert("清空观看历史？", isPresented: $showClearConfirm) {
            Button("清空", role: .destructive) {
                VideoLibraryStore.clearHistory()
                entries = []
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会同时清除断点续播位置，这个操作不能撤销。")
        }
        .navigationDestination(item: $selectedItem) { item in
            VideoDetailView(item: item)
        }
        .onAppear { entries = VideoLibraryStore.history() }
    }

    private func historyProgressText(entry: VideoHistoryEntry) -> String {
        if entry.isFinished { return "已看完" }
        return "已看 \(videoTimeText(seconds: entry.positionSeconds)) / \(videoTimeText(seconds: entry.durationSeconds))"
    }
}

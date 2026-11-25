// HAo Studio 2.0 — live follows + history pages (S4-C leg).
//
// Full pages behind the tab's follow/history rows (Flutter
// live_follows_page.dart / live_history_page.dart):
// - Follows: newest first, tap opens the room, swipe to
//   unfollow, clear-all with an explicit confirm.
// - History: newest first, grouped by day section (today /
//   yesterday / 2–6 days ago / earlier, Pure Live
//   HistorySection.of), tap re-enters the room, swipe to delete,
//   clear-all with an explicit confirm.
// Stored rooms carry no live status — the pages show the stored
// title/cover/nick, never a faked LIVE badge.

import SwiftUI

struct LiveFollowsView: View {
    var onSelect: (LiveRoom) -> Void

    @State private var follows: [LiveFollowedRoom] = LiveLibraryStore.follows()
    @State private var showClearConfirm = false

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            if follows.isEmpty {
                MusicEmptyState(
                    icon: "heart",
                    title: "还没有关注",
                    note: "在直播间点关注，主播会出现在这里。"
                )
            } else {
                List {
                    ForEach(follows) { follow in
                        LiveRoomRow(room: follow.toRoom()) {
                            onSelect(follow.toRoom())
                        }
                        .listRowBackground(theme.scaffoldBackground)
                    }
                    .onDelete(perform: removeFollows)
                }
                .haoBottomChromePadding()
                .listStyle(.plain)
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("我的关注")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !follows.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空") { showClearConfirm = true }
                }
            }
        }
        .alert("清空关注？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {
            }
            Button("清空", role: .destructive) {
                LiveLibraryStore.clearFollows()
                follows = []
            }
        } message: {
            Text("关注列表会被清空，这个操作不能撤销。")
        }
        .onAppear { follows = LiveLibraryStore.follows() }
        // A row's long-press menu unfollows through the store
        // directly — the swipe delete refreshes local state, the
        // menu did not, so the unfollowed room stayed listed
        // until re-appear. Refresh on the same signal the tab
        // listens to.
        .onReceive(NotificationCenter.default.publisher(for: .haoLiveFollowChanged)) { _ in
            follows = LiveLibraryStore.follows()
        }
    }

    private func removeFollows(at offsets: IndexSet) {
        for index in offsets {
            let follow = follows[index]
            LiveLibraryStore.removeFollow(platform: follow.platform, roomId: follow.roomId)
        }
        follows = LiveLibraryStore.follows()
    }
}

struct LiveHistoryView: View {
    var onSelect: (LiveRoom) -> Void

    @State private var entries: [LiveHistoryEntry] = LiveLibraryStore.history()
    @State private var showClearConfirm = false

    @Environment(\.haoTheme) private var theme

    /// One day-group section with its entries.
    private struct LiveHistoryGroup: Identifiable {
        var id: String { section.rawValue }
        let section: LiveHistorySection
        let entries: [LiveHistoryEntry]
    }

    /// Sections in display order, each with its entries (newest
    /// first inside a section — the store already orders that
    /// way).
    private var sections: [LiveHistoryGroup] {
        var grouped: [LiveHistoryGroup] = []
        for section in LiveHistorySection.allCases {
            let rows = entries.filter { LiveHistorySection.of($0.watchedAt) == section }
            if !rows.isEmpty {
                grouped.append(LiveHistoryGroup(section: section, entries: rows))
            }
        }
        return grouped
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                MusicEmptyState(
                    icon: "clock",
                    title: "还没有观看历史",
                    note: "进过的直播间会出现在这里，点一下就能再进去。"
                )
            } else {
                List {
                    ForEach(sections) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                LiveHistoryListRow(entry: entry) {
                                    onSelect(entry.toRoom())
                                }
                                .listRowBackground(theme.scaffoldBackground)
                            }
                            .onDelete { offsets in removeHistory(in: group, at: offsets) }
                        } header: {
                            Text(group.section.label)
                        }
                    }
                }
                .haoBottomChromePadding()
                .listStyle(.plain)
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("直播历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !entries.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空") { showClearConfirm = true }
                }
            }
        }
        .alert("清空历史？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {
            }
            Button("清空", role: .destructive) {
                LiveLibraryStore.clearHistory()
                entries = []
            }
        } message: {
            Text("观看历史会被清空，这个操作不能撤销。")
        }
        .onAppear { entries = LiveLibraryStore.history() }
    }

    private func removeHistory(in group: LiveHistoryGroup, at offsets: IndexSet) {
        for index in offsets {
            let entry = group.entries[index]
            LiveLibraryStore.removeHistory(platform: entry.platform, roomId: entry.roomId)
        }
        entries = LiveLibraryStore.history()
    }
}

/// One history row: small cover thumb + title + anchor +
/// relative time.
private struct LiveHistoryListRow: View {
    var entry: LiveHistoryEntry
    var onTap: () -> Void

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                rowCover
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title.isEmpty ? "直播间" : entry.title)
                        .font(.haoSubheadStrong)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(entry.nick.isEmpty ? entry.platform : entry.nick)
                        .font(.haoFootnote)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                    Text(liveRelativeTimeText(date: entry.watchedAt))
                        .font(.haoCaption)
                        .foregroundStyle(theme.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.haoFootnoteStrong)
                    .foregroundStyle(theme.textMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MusicPressScaleStyle())
    }

    private var rowCover: some View {
        Group {
            if let url = URL(string: entry.cover), !entry.cover.isEmpty {
                // Shared loader (build 36 item 10 leg 6): 96x54
                // row thumb — the old AsyncImage decoded the full
                // original for a 96pt thumb.
                HaoCachedImage(
                    urlString: entry.cover,
                    targetWidth: 96,
                    targetHeight: 54
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    rowCoverPlaceholder
                }
            } else {
                rowCoverPlaceholder
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: HaoLayout.cornerSmall, style: .continuous))
    }

    private var rowCoverPlaceholder: some View {
        Rectangle()
            .fill(theme.surfaceStrong)
            .overlay {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.haoCallout)
                    .foregroundStyle(theme.textSecondary)
            }
    }
}

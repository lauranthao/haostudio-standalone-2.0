// HAo Studio 2.0 — My tab (S5-C leg).
//
// My entries + old-data notice + settings groups (B leg). All rows
// are local data; there is no login interface anywhere in this app,
// and no entry leads to a page that does not exist.
// （chen 2026-11-24: 个人资料/会员已删——昵称+头像 section 与只弹
// alert 的会员死入口整段删除，见下方；ProfileStore.swift 同删。）
//
// Entry wiring (counts are synchronous store reads, empty = 0):
// - 我的歌单 → MyPlaylistsView (new, this file: no playlist-list
//   view existed in the baseline; detail page is reused)
// - 音乐收藏 → MusicFavouritesView (reuse)
// - 最近播放 → MyRecentPlaysView (new, this file: no recent view
//   existed in the baseline)
// - 我的下载 → MusicDownloadsView (reuse)
// - 影视收藏 → VideoFavsView (reuse)
// - 影视历史 → VideoHistoryView (reuse)
// - 我的关注 → LiveFollowsView (reuse; onSelect opens the room)
// - 直播历史 → LiveHistoryView (reuse; onSelect opens the room)
//
// Pure helpers (MyEntryCounts / MyBackgroundColor /
// MyBackgroundKind) are static funcs in this file so
// SettingsTests can cover them without I/O or networking.

import Combine
import SwiftUI

// MARK: - Entry counts (pure, unit-tested)

/// The eight My-tab entry counts. Built from arrays so the
/// counting rule itself is unit-testable; `reload()` is the only
/// place that touches the stores.
struct MyEntryCounts: Equatable {
    var playlists: Int = 0
    var favourites: Int = 0
    var recent: Int = 0
    var downloads: Int = 0
    var videoFavourites: Int = 0
    var videoHistory: Int = 0
    var liveFollows: Int = 0
    var liveHistory: Int = 0

    static func make(
        playlists: [UserPlaylist],
        favourites: [MusicSong],
        recent: [MusicSong],
        downloads: [DownloadedSong],
        videoFavourites: [VideoItem],
        videoHistory: [VideoHistoryEntry],
        liveFollows: [LiveFollowedRoom],
        liveHistory: [LiveHistoryEntry]
    ) -> MyEntryCounts {
        return MyEntryCounts(
            playlists: playlists.count,
            favourites: favourites.count,
            recent: recent.count,
            downloads: downloads.count,
            videoFavourites: videoFavourites.count,
            videoHistory: videoHistory.count,
            liveFollows: liveFollows.count,
            liveHistory: liveHistory.count
        )
    }

    /// Reload all eight counts from the stores. Every read here
    /// is synchronous; an empty store reads as 0, never as a
    /// placeholder number.
    static func reload() -> MyEntryCounts {
        return make(
            playlists: MusicLibraryStore.getLists(),
            favourites: MusicLibraryStore.favSongs(),
            recent: MusicLibraryStore.getRecent(),
            downloads: MusicLibraryStore.getDownloads(),
            videoFavourites: VideoLibraryStore.favourites(),
            videoHistory: VideoLibraryStore.history(),
            liveFollows: LiveLibraryStore.follows(),
            liveHistory: LiveLibraryStore.history()
        )
    }
}

// MARK: - Background (pure, unit-tested)

/// Which scaffold-background layer wins.
enum MyBackgroundKind: Equatable {
    case wallpaper
    case color
    case theme
}

enum MyBackgroundColor {
    /// Parse #RRGGBB only (a leading "#" is optional, surrounding
    /// whitespace is ignored). Anything else is nil — an invalid
    /// hex never paints a wrong colour.
    static func color(fromHex hex: String) -> Color? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        guard text.count == 6 else { return nil }
        guard let value = UInt32(text, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Background priority: wallpaper (enabled + loadable) >
    /// background colour (enabled + valid #RRGGBB) > theme
    /// scaffold. A layer that is off or unusable falls through
    /// to the next one; nothing here invents a colour.
    static func kind(
        wallpaperEnabled: Bool,
        wallpaperAvailable: Bool,
        bgColorEnabled: Bool,
        bgColorHex: String
    ) -> MyBackgroundKind {
        if wallpaperEnabled && wallpaperAvailable {
            return .wallpaper
        }
        if bgColorEnabled && color(fromHex: bgColorHex) != nil {
            return .color
        }
        return .theme
    }
}

// MARK: - My tab

struct MyView: View {
    @Environment(\.haoTheme) private var theme
    @EnvironmentObject private var settings: SettingsStore

    @State private var counts = MyEntryCounts()
    @State private var selectedLiveRoom: LiveRoom?
    @State private var showMigrationNotice = MigrationStore.migrationNoticeNeeded()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    // Scroll anchor for the bottom chrome (b35 tab-bar
                    // link): drives minimize / restore as this tab scrolls.
                    // A zero-height, separator-less first row — the List
                    // equivalent of the ScrollView anchor.
                    HaoChromeScrollAnchor()
                        .id(HaoTabScrollTop.id(for: .my))
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    entriesSection
                    migrationSection
                    settingsSection
                }
                .haoBottomChromePadding()
                .haoChromeScrollTracking()
                .haoReselectScrollToTop(tab: .my, proxy: proxy)
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(theme.scaffoldBackground)
                .navigationTitle("我的")
                .navigationDestination(item: $selectedLiveRoom) { room in
                    LiveRoomView(room: room, playlist: [room])
                }
                .onAppear {
                    counts = MyEntryCounts.reload()
                }
                .onReceive(NotificationCenter.default.publisher(for: .haoBackupImported)) { _ in
                    // b35-sweep-settings: 导入备份后本页不重进，
                    // onAppear 不触发，8 个计数还停在导入前（例如导
                    // 入 5 个歌单仍显示 0）。导入成功即重读计数与
                    // 迁移提示（提示本身的判定见 MigrationStore）。
                    counts = MyEntryCounts.reload()
                    showMigrationNotice = MigrationStore.migrationNoticeNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: .haoMusicRecentChanged)) { _ in
                    // b36 item 8, F7: counts went stale while this
                    // page was on screen — playing from the mini
                    // player changes recent plays, a favourite toggle
                    // anywhere changes favourites, and neither
                    // re-triggers onAppear. Reload on the
                    // notifications the music leg already posts.
                    counts = MyEntryCounts.reload()
                }
                .onReceive(NotificationCenter.default.publisher(for: .haoMusicFavChanged)) { _ in
                    counts = MyEntryCounts.reload()
                }
                .onReceive(NotificationCenter.default.publisher(for: .haoVideoFavChanged)) { _ in
                    // Same staleness as the music/live counts above:
                    // the video store already posts on every favourite
                    // toggle; this page just never listened, so the
                    // "影视收藏" count stayed stale after an
                    // unfavourite from the pushed list.
                    counts = MyEntryCounts.reload()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .haoLiveFollowChanged)) { _ in
                // Same staleness as the music counts above: a
                // follow toggle from a card's long-press menu
                // writes the store directly and never re-triggers
                // onAppear, so the "我的关注" count stayed stale
                // while this page was on screen. Only assign when
                // the counts actually changed, so a duplicate
                // notification does not refresh the list twice.
                let reloaded = MyEntryCounts.reload()
                if reloaded != counts {
                    counts = reloaded
                }
            }
        }
    }

    // MARK: - My entries

    private var entriesSection: some View {
        Section(header: SettingsSectionHeader(section: .my)) {
            if settings.sectionExpanded(SettingsSection.my.rawValue) {
                NavigationLink(destination: MyPlaylistsView()) {
                    entryRow(title: "我的歌单", count: counts.playlists)
                }
                NavigationLink(destination: MusicFavouritesView()) {
                    entryRow(title: "音乐收藏", count: counts.favourites)
                }
                NavigationLink(destination: MyRecentPlaysView()) {
                    entryRow(title: "最近播放", count: counts.recent)
                }
                NavigationLink(destination: MusicDownloadsView()) {
                    entryRow(title: "我的下载", count: counts.downloads)
                }
                NavigationLink(destination: VideoFavsView()) {
                    entryRow(title: "影视收藏", count: counts.videoFavourites)
                }
                NavigationLink(destination: VideoHistoryView()) {
                    entryRow(title: "影视历史", count: counts.videoHistory)
                }
                NavigationLink(destination: LiveFollowsView(onSelect: openLiveRoom)) {
                    entryRow(title: "我的关注", count: counts.liveFollows)
                }
                NavigationLink(destination: LiveHistoryView(onSelect: openLiveRoom)) {
                    entryRow(title: "直播历史", count: counts.liveHistory)
                }
            }
        }
    }

    private func entryRow(title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Text("\(count)")
                .font(.haoBody)
                .foregroundStyle(theme.textSecondary)
        }
    }

    /// Enter a live room from follows/history: record history
    /// first (same as LiveTabView.openRoom), then navigate.
    private func openLiveRoom(_ room: LiveRoom) {
        LiveLibraryStore.recordHistory(
            platform: room.platform.rawValue, roomId: room.roomId,
            title: room.title, nick: room.streamer, cover: room.cover)
        counts = MyEntryCounts.reload()
        selectedLiveRoom = room
    }

    // MARK: - Old data notice (moved verbatim from MyPlaceholderView)

    @ViewBuilder
    private var migrationSection: some View {
        if showMigrationNotice {
            Section("旧版数据") {
                Text("未找到旧版数据，可从备份文件导入。")
                    .font(.haoSubhead)
                    .foregroundStyle(theme.textSecondary)
                Button("从备份文件导入") {
                    BackupUpdateFlow.shared.beginImport()
                }
                .font(.haoBody)
                .foregroundStyle(theme.accentText)
                Button("不再提示") {
                    MigrationStore.dismissMigrationNotice()
                    showMigrationNotice = false
                }
                .font(.haoBody)
                .foregroundStyle(theme.accentText)
            }
        }
    }

    // MARK: - Settings (B leg)

    private var settingsSection: some View {
        SettingsGroupsView()
    }
}

// MARK: - Playlist list (new: no playlist-list view existed)

/// Minimal playlist list. Rows open the existing
/// MusicPlaylistDetailView; swipe-to-delete asks first (same
/// confirmation as the detail page — a deleted list is gone
/// for good, never silently).
private struct MyPlaylistsView: View {
    @State private var lists: [UserPlaylist] = MusicLibraryStore.getLists()
    @State private var deleteTarget: UserPlaylist?
    @State private var showDeleteList = false

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            if lists.isEmpty {
                MusicEmptyState(
                    icon: "music.note.list", title: "还没有歌单",
                    note: "在音乐里新建歌单，这里会列出来。")
            } else {
                List {
                    ForEach(lists) { list in
                        NavigationLink(destination: MusicPlaylistDetailView(listId: list.id)) {
                            HStack(spacing: 12) {
                                MusicCoverView(urlString: list.cover, size: 48)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(list.name.isEmpty ? "未命名歌单" : list.name)
                                        .font(.haoSubheadStrong)
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                    Text("\(list.trackCount) 首")
                                        .font(.haoFootnote)
                                        .foregroundStyle(theme.textSecondary)
                                }
                            }
                        }
                        .listRowBackground(theme.scaffoldBackground)
                        .listRowSeparatorTint(theme.hairline)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteTarget = list
                                showDeleteList = true
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
        .navigationTitle("我的歌单")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            lists = MusicLibraryStore.getLists()
        }
        .alert("删除歌单", isPresented: $showDeleteList) {
            Button("删除", role: .destructive) {
                if let target = deleteTarget {
                    MusicLibraryStore.deleteList(id: target.id)
                    lists = MusicLibraryStore.getLists()
                }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("删除后歌单里的歌曲不会从收藏或本地删除。")
        }
    }
}

// MARK: - Recent plays (new: no recent view existed)

/// Recent list on the shared song row: tap plays through the
/// shared music player view model (same as MusicFavouritesView);
/// the row's menu offers favourite / add to playlist
/// (build 36, item 19).
private struct MyRecentPlaysView: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel

    @State private var recent: [MusicSong] = MusicLibraryStore.getRecent()

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            if recent.isEmpty {
                MusicEmptyState(
                    icon: "clock", title: "还没有最近播放",
                    note: "播过的歌曲会出现在这里，点一下就能再播。")
            } else {
                List {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, song in
                        MusicSongRow(
                            song: song,
                            isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
                            onTap: {
                                playerVM.play(song: song, in: recent, startAt: index)
                            },
                            onToggleFav: {
                                recent = MusicLibraryStore.getRecent()
                            }
                        )
                        .listRowBackground(theme.scaffoldBackground)
                        .listRowSeparatorTint(theme.hairline)
                    }
                }
                .haoBottomChromePadding()
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("最近播放")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            recent = MusicLibraryStore.getRecent()
        }
        // Same real-time rule as home (H1): a song played from the
        // mini player or another tab while this list is open must
        // move to the top at once; a cleared list must empty at once.
        .onReceive(NotificationCenter.default.publisher(for: .haoMusicRecentChanged)) { _ in
            recent = MusicLibraryStore.getRecent()
        }
    }
}

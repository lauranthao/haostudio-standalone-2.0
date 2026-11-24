// HAo Studio 2.0 — music library pages (S2-C leg).
//
// Favourites / playlist detail / downloads / local music. All lists
// are local; playback goes through the shared player view model.
// Deleting a download or a local file removes the file AND the index
// entry; a download whose file is gone shows "文件已丢失" and offers
// removal, never a fake play.

import SwiftUI

// MARK: - Favourites

struct MusicFavouritesView: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var libraryVM = MusicLibraryViewModel()

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            if libraryVM.favSongs.isEmpty {
                MusicEmptyState(icon: "heart", title: "还没有收藏的歌曲", note: "点播放器或歌行里的星标收藏歌曲。")
            } else {
                List {
                    ForEach(Array(libraryVM.favSongs.enumerated()), id: \.element.id) { index, song in
                        MusicSongRow(
                            song: song,
                            isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
                            onTap: {
                                playerVM.play(song: song, in: libraryVM.favSongs, startAt: index)
                            }
                        )
                        .listRowBackground(theme.scaffoldBackground)
                        .listRowSeparatorTint(theme.hairline)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                _ = MusicLibraryStore.toggleFav(song)
                            } label: {
                                Label("取消收藏", systemImage: "star.slash")
                            }
                            .tint(theme.accent)
                        }
                    }
                }
                .haoBottomChromePadding()
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MusicCapsuleButton(icon: "play.fill", label: "播放全部", enabled: !libraryVM.favSongs.isEmpty) {
                    playerVM.playAll(libraryVM.favSongs)
                }
            }
        }
        .onAppear { libraryVM.reload() }
        // Favourite sync (build 36, item 12): a toggle from any
        // row posts haoMusicFavChanged — reload so an unfavourite
        // drops the row here without reopening the page.
        .onReceive(NotificationCenter.default.publisher(for: .haoMusicFavChanged)) { _ in
            libraryVM.reload()
        }
    }
}

// MARK: - Playlist detail

struct MusicPlaylistDetailView: View {
    var listId: String

    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var libraryVM = MusicLibraryViewModel()
    @State private var showDeleteList = false
    @State private var showRename = false
    @State private var renameText = ""

    @Environment(\.haoTheme) private var theme

    private var list: UserPlaylist? { libraryVM.playlist(id: listId) }

    var body: some View {
        Group {
            if let list = list {
                List {
                    ForEach(Array(list.tracks.enumerated()), id: \.element.id) { index, song in
                        MusicSongRow(
                            song: song,
                            isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
                            onTap: {
                                playerVM.play(song: song, in: list.tracks, startAt: index)
                            }
                        )
                        .listRowBackground(theme.scaffoldBackground)
                        .listRowSeparatorTint(theme.hairline)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                libraryVM.removeFromPlaylist(song: song, listId: listId)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .haoBottomChromePadding()
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .navigationTitle(list.name)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("播放全部") { playerVM.playAll(list.tracks) }
                            Button("重命名") {
                                renameText = list.name
                                showRename = true
                            }
                            Button("删除歌单", role: .destructive) { showDeleteList = true }
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundStyle(theme.textPrimary)
                        }
                    }
                }
            } else {
                MusicEmptyState(icon: "music.note.list", title: "歌单不存在", note: "它可能已被删除。")
                    .navigationTitle("我的歌单")
            }
        }
        .background(theme.scaffoldBackground)
        .navigationBarTitleDisplayMode(.inline)
        .alert("删除歌单", isPresented: $showDeleteList) {
            Button("删除", role: .destructive) {
                libraryVM.deletePlaylist(id: listId)
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("删除后歌单里的歌曲不会从收藏或本地删除。")
        }
        .alert("重命名歌单", isPresented: $showRename) {
            TextField("歌单名", text: $renameText)
            Button("保存") { libraryVM.renamePlaylist(id: listId, name: renameText) }
            Button("取消", role: .cancel) { }
        }
        .onAppear { libraryVM.reload() }
    }
}

// MARK: - Downloads

struct MusicDownloadsView: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var libraryVM = MusicLibraryViewModel()

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            if libraryVM.downloads.isEmpty {
                MusicEmptyState(icon: "arrow.down.circle", title: "还没有下载", note: "已下载的歌曲会出现在这里，可离线播放。")
            } else {
                List {
                    ForEach(libraryVM.downloads, id: \.key) { download in
                        let fileExists = libraryVM.downloadedFileURL(for: download) != nil
                        // Same shared menu as every other song row
                        // (no 下载 — already downloaded). The whole
                        // row taps to play, like every other list;
                        // the "…" button is a sibling, never nested
                        // inside the play button.
                        MusicSongMenuHost(song: download.song, showDownload: false) { menu in
                            HStack(spacing: 8) {
                                Button(action: {
                                    if fileExists {
                                        playerVM.playLocal(song: download.song, fileURL: libraryVM.downloadedFileURL(for: download))
                                    }
                                }) {
                                    HStack(spacing: 12) {
                                        MusicCoverView(urlString: download.song.cover, size: 56, cornerRadius: 10)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(download.song.title.isEmpty ? "未知歌曲" : download.song.title)
                                                .font(.haoCalloutStrong)
                                                .foregroundStyle(theme.textPrimary)
                                                .lineLimit(1)
                                            HStack(spacing: 6) {
                                                Text(MusicLibraryStore.badgeLabel(for: download.quality))
                                                    .font(.haoCaption2Strong)
                                                    .foregroundStyle(theme.textSecondary)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .overlay {
                                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                            .strokeBorder(theme.hairline, lineWidth: 0.5)
                                                    }
                                                Text(fileExists ? formattedSize(download.sizeBytes) : "文件已丢失")
                                                    .font(.haoFootnote)
                                                    .foregroundStyle(fileExists ? theme.textSecondary : theme.textMuted)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!fileExists)
                                .accessibilityLabel(fileExists ? "播放" : "文件已丢失，无法播放")
                                MusicSongMenuButton(handle: menu)
                            }
                            .contextMenu { menu.menuContent() }
                        }
                        .listRowBackground(theme.scaffoldBackground)
                        .listRowSeparatorTint(theme.hairline)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                libraryVM.deleteDownload(download)
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
        .navigationTitle("已下载")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { libraryVM.reload() }
    }

    private func formattedSize(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
        }
        if bytes >= 1024 {
            return String(format: "%.0f KB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }
}

// MARK: - Local music

struct MusicLocalMusicView: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var libraryVM = MusicLibraryViewModel()

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            if libraryVM.localSongs.isEmpty {
                MusicEmptyState(
                    icon: "folder", title: "还没有导入本地文件",
                    note: "把音频文件放进 local_music/ 目录（备份导入会带过来），这里会列出来直接播。"
                )
            } else {
                List {
                    ForEach(libraryVM.localSongs) { song in
                        MusicSongRow(
                            song: song,
                            showPlatformBadge: false,
                            isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
                            onTap: {
                                playerVM.playLocal(song: song)
                            }
                        )
                        .listRowBackground(theme.scaffoldBackground)
                        .listRowSeparatorTint(theme.hairline)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                libraryVM.deleteLocalSong(song)
                            } label: {
                                Label("删除文件", systemImage: "trash")
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
        .navigationTitle("本地音乐")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MusicCapsuleButton(icon: "play.fill", label: "播放全部", enabled: !libraryVM.localSongs.isEmpty) {
                    if let first = libraryVM.localSongs.first {
                        playerVM.play(song: first, in: libraryVM.localSongs, startAt: 0)
                    }
                }
            }
        }
        .onAppear { libraryVM.reload() }
    }
}

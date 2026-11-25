// HAo Studio 2.0 — music library pages (S2-C leg).
//
// Favourites / playlist detail / downloads / local music. All lists
// are local; playback goes through the shared player view model.
// Deleting a download or a local file removes the file AND the index
// entry; a download whose file is gone shows "文件已丢失" and offers
// removal, never a fake play.
//
// b45-b (Coda §3.3/§3.4/§3.6/§3.8):
// - Playlist detail uses the shared detail Hero + PrimaryActions
//   (cover on top, never a big play button in the middle), an
//   in-list search ("找到 N 首匹配歌曲" / empty "没有匹配的歌曲"),
//   a sort Picker (add-time / title / album / artist,
//   localizedStandardCompare, stable), a delete confirmationDialog,
//   a rename alert ("歌单名称"), a long-press destructive
//   "从歌单中删除" with a "已从歌单中删除" toast, and an intro
//   sheet (detents medium / large). No drag-to-reorder (no onMove).
// - Collections is a grid (not a list): album/artist segmented
//   Picker (max width 240), 2-column grid, skeleton + empty states.
// - Downloads: only explicit downloads (auto-cache never lists),
//   filter + sort + multi-select batch delete, a pending-tasks
//   entry, skeleton/empty/error states.

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
                            showFavHeart: true,
                            onTap: {
                                playerVM.play(song: song, in: libraryVM.favSongs, startAt: index, source: PlaySource(kind: .favourites, id: "favourites"), sourceDisplayName: "音乐收藏")
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

// MARK: - Collections grid (Coda §3.4, b45-b)

/// Favourited albums / artists as a grid (not a list). The
/// data is local-only: albums/artists favourited from their
/// detail pages (MusicLibraryStore favAlbums/favArtists) — no
/// login anywhere.
struct MusicCollectionsView: View {
    enum Kind: String, CaseIterable {
        case albums = "专辑"
        case artists = "歌手"
    }

    @State private var kind: Kind = .albums
    @State private var albums: [AlbumSummary] = []
    @State private var artists: [ArtistSummary] = []
    @State private var isLoading = true

    @Environment(\.haoTheme) private var theme

    /// Two flexible columns; card size from the real screen
    /// width (side margin 20 + 16 column spacing), never a
    /// hardcoded card width.
    private var cardSize: CGFloat {
        max((UIScreen.main.bounds.width - 40 - 16) / 2, 120)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Picker("类型", selection: $kind) {
                    ForEach(Kind.allCases, id: \.rawValue) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                .padding(.top, 12)
                .padding(.bottom, 16)
                if isLoading {
                    collectionsSkeleton
                } else if kind == .albums {
                    if albums.isEmpty {
                        MusicEmptyState(icon: "square.stack", title: "还没有收藏的专辑", note: "在专辑页点星标收藏专辑。")
                            .frame(minHeight: 300)
                    } else {
                        albumGrid
                    }
                } else {
                    if artists.isEmpty {
                        MusicEmptyState(icon: "music.microphone", title: "还没有收藏的歌手", note: "在歌手页点星标收藏歌手。")
                            .frame(minHeight: 300)
                    } else {
                        artistGrid
                    }
                }
            }
            .padding(.horizontal, 20)
            .haoBottomChromeContentPadding()
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
    }

    private var albumGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16),
            ],
            spacing: 24
        ) {
            ForEach(albums) { album in
                NavigationLink(destination: MusicAlbumDetailView(album: album)) {
                    MusicCoverCardBody(
                        coverURL: album.cover, title: album.name,
                        subtitle: album.artist, size: cardSize
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var artistGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16),
            ],
            spacing: 24
        ) {
            ForEach(artists, id: \.name) { artist in
                NavigationLink(destination: MusicArtistDetailView(artist: artist)) {
                    // Coda §3.4: artist card circle 80 compact
                    // (100 non-compact), name cardTitle 1 line.
                    VStack(spacing: 8) {
                        MusicCoverView(urlString: artist.cover, size: 80, cornerRadius: 40)
                        Text(artist.name)
                            .font(.haoBodyStrong)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var collectionsSkeleton: some View {
        VStack(alignment: .leading, spacing: 16) {
            MusicSkeletonBlock(width: 200, height: 22)
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                ],
                spacing: 24
            ) {
                ForEach(0..<6, id: \.self) { _ in
                    MusicSkeletonCard(size: cardSize)
                }
            }
        }
    }

    private func reload() {
        isLoading = true
        albums = MusicLibraryStore.favAlbums()
        artists = MusicLibraryStore.favArtists()
        isLoading = false
    }
}

// MARK: - Playlist detail (Coda §3.6, b45-b)

struct MusicPlaylistDetailView: View {
    var listId: String

    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var libraryVM = MusicLibraryViewModel()
    @State private var showDeleteList = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showIntro = false
    @State private var sortOrder: MusicPlaylistSortOrder = .addedDesc
    @State private var searchText = ""
    @State private var isFavPlaylist = false

    @Environment(\.haoTheme) private var theme

    private var list: UserPlaylist? { libraryVM.playlist(id: listId) }

    /// Sort first (stable), then the in-list search filter.
    private var displayedTracks: [MusicSong] {
        guard let list = list else { return [] }
        let sorted = musicSortedPlaylistTracks(list.tracks, by: sortOrder)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.artist.localizedCaseInsensitiveContains(query)
                || $0.album.localizedCaseInsensitiveContains(query)
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if let list = list {
                List {
                    Section {
                        MusicDetailHero(
                            coverURL: list.cover,
                            title: list.name,
                            subtitle: "本地歌单",
                            metadata: "\(list.trackCount) 首歌曲"
                        )
                    }
                    .listRowBackground(theme.scaffoldBackground)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    Section {
                        HStack {
                            Spacer()
                            MusicDetailPrimaryActions(
                                isFavourite: isFavPlaylist,
                                onToggleFavourite: {
                                    isFavPlaylist = MusicLibraryStore.toggleFavPlaylist(id: list.id)
                                },
                                onPlay: { playerVM.playAll(displayedTracks, source: PlaySource(kind: .playlist, id: listId), sourceDisplayName: list.name) },
                                playEnabled: !displayedTracks.isEmpty
                            ) {
                                Picker("排序", selection: $sortOrder) {
                                    ForEach(MusicPlaylistSortOrder.allCases, id: \.rawValue) { order in
                                        Text(order.label).tag(order)
                                    }
                                }
                                Button("歌单简介") { showIntro = true }
                                Button("重命名") {
                                    renameText = list.name
                                    showRename = true
                                }
                                Button("删除歌单", role: .destructive) { showDeleteList = true }
                            }
                            Spacer()
                        }
                    }
                    .listRowBackground(theme.scaffoldBackground)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    Section {
                        searchField
                    }
                    .listRowBackground(theme.scaffoldBackground)
                    .listRowSeparator(.hidden)
                    if isSearching {
                        Section {
                            Text("找到 \(displayedTracks.count) 首匹配歌曲")
                                .font(.haoFootnote)
                                .foregroundStyle(theme.textSecondary)
                        }
                        .listRowBackground(theme.scaffoldBackground)
                    }
                    if displayedTracks.isEmpty {
                        Section {
                            if isSearching {
                                MusicEmptyState(
                                    icon: "magnifyingglass", title: "没有匹配的歌曲",
                                    note: "试试其他歌名、歌手或专辑"
                                )
                                .frame(minHeight: 180)
                            } else {
                                MusicEmptyState(icon: "music.note", title: "歌单还是空的", note: "从歌曲行里把歌加进来。")
                            }
                        }
                        .listRowBackground(theme.scaffoldBackground)
                        .listRowSeparator(.hidden)
                    } else {
                        Section {
                            ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { index, song in
                                MusicSongRow(
                                    song: song,
                                    isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
                                    showFavHeart: true,
                                    onTap: {
                                        playerVM.play(song: song, in: displayedTracks, startAt: index, source: PlaySource(kind: .playlist, id: listId), sourceDisplayName: list.name)
                                    },
                                    onRemoveFromList: {
                                        libraryVM.removeFromPlaylist(song: song, listId: listId)
                                        playerVM.showToast("已从歌单中删除")
                                    }
                                )
                                .listRowBackground(theme.scaffoldBackground)
                                .listRowSeparatorTint(theme.hairline)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        libraryVM.removeFromPlaylist(song: song, listId: listId)
                                        playerVM.showToast("已从歌单中删除")
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .haoBottomChromePadding()
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .navigationTitle(list.name)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                MusicEmptyState(icon: "music.note.list", title: "歌单不存在", note: "它可能已被删除。")
                    .navigationTitle("我的歌单")
            }
        }
        .background(theme.scaffoldBackground)
        .confirmationDialog("删除歌单？", isPresented: $showDeleteList, titleVisibility: .visible) {
            Button("删除歌单", role: .destructive) {
                libraryVM.deletePlaylist(id: listId)
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("歌单将从本地删除，里面的歌曲不会从收藏或本地删除。")
        }
        .alert("重命名歌单", isPresented: $showRename) {
            TextField("歌单名称", text: $renameText)
            Button("保存") { libraryVM.renamePlaylist(id: listId, name: renameText) }
            Button("取消", role: .cancel) { }
        }
        .sheet(isPresented: $showIntro) {
            playlistIntroSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            libraryVM.reload()
            isFavPlaylist = MusicLibraryStore.isFavPlaylist(id: listId)
        }
    }

    /// Coda detail search: capsule glass, 44pt high, magnifier
    /// + field + clear. Lives above the Hero's list, in the
    /// same column (Coda §3.6).
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            TextField("搜索歌名、歌手或专辑", text: $searchText)
                .font(.haoSubhead)
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private var playlistIntroSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let list = list {
                    Text(list.name.isEmpty ? "未命名歌单" : list.name)
                        .font(.haoDetailTitle)
                        .foregroundStyle(theme.textPrimary)
                    Text("本地歌单 · \(list.trackCount) 首歌曲")
                        .font(.haoSubhead)
                        .foregroundStyle(theme.textSecondary)
                    Text("这是你创建的本地歌单，歌曲只存在这台设备上。")
                        .font(.haoSubhead)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
            }
            .padding(20)
            .navigationTitle("歌单简介")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showIntro = false }
                }
            }
        }
    }
}

// MARK: - Downloads (Coda §3.8, b45-b)

enum MusicDownloadFilter: String, CaseIterable {
    case all = "全部"
    case playable = "可播放"
    case missing = "文件丢失"
}

enum MusicDownloadSort: String, CaseIterable {
    case newest = "最新下载"
    case title = "歌曲名"
    case size = "大小"

    var label: String { rawValue }
}

struct MusicDownloadsView: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var libraryVM = MusicLibraryViewModel()
    @State private var filter: MusicDownloadFilter = .all
    @State private var sort: MusicDownloadSort = .newest
    @State private var isSelecting = false
    @State private var selectedKeys = Set<String>()
    @State private var showDeleteSelected = false
    @State private var pendingTasks = 0
    @State private var isLoading = true

    @Environment(\.haoTheme) private var theme

    /// Only explicit downloads list here — the audio cache
    /// never appears (Coda §3.8). Filter + sort apply on top.
    private var filteredDownloads: [DownloadedSong] {
        var list = libraryVM.downloads
        switch filter {
        case .all:
            break
        case .playable:
            list = list.filter { libraryVM.downloadedFileURL(for: $0) != nil }
        case .missing:
            list = list.filter { libraryVM.downloadedFileURL(for: $0) == nil }
        }
        switch sort {
        case .newest:
            list.sort { $0.downloadedAt > $1.downloadedAt }
        case .title:
            list.sort { $0.song.title.localizedStandardCompare($1.song.title) == .orderedAscending }
        case .size:
            list.sort { $0.sizeBytes > $1.sizeBytes }
        }
        return list
    }

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 1) {
                    ForEach(0..<6, id: \.self) { _ in MusicSkeletonRow() }
                }
            } else if libraryVM.downloads.isEmpty {
                MusicEmptyState(icon: "arrow.down.circle", title: "还没有下载", note: "已下载的歌曲会出现在这里，可离线播放。")
            } else {
                List {
                    Section {
                        tasksEntry
                        filterRow
                    }
                    .listRowBackground(theme.scaffoldBackground)
                    if filteredDownloads.isEmpty {
                        MusicEmptyState(icon: "arrow.down.circle", title: "没有符合条件的下载", note: "换个筛选或排序试试。")
                            .listRowBackground(theme.scaffoldBackground)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(filteredDownloads, id: \.key) { download in
                            downloadRow(download)
                                .listRowBackground(theme.scaffoldBackground)
                                .listRowSeparatorTint(theme.hairline)
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isSelecting {
                    Button("删除 \(selectedKeys.count) 项", role: .destructive) {
                        showDeleteSelected = true
                    }
                    .disabled(selectedKeys.isEmpty)
                } else {
                    Button("选择") { isSelecting = true }
                }
            }
            if isSelecting {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        isSelecting = false
                        selectedKeys = []
                    }
                }
            }
        }
        .alert("删除选中的下载？", isPresented: $showDeleteSelected) {
            Button("删除", role: .destructive) {
                for download in filteredDownloads where selectedKeys.contains(download.key) {
                    libraryVM.deleteDownload(download)
                }
                selectedKeys = []
                isSelecting = false
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将删除 \(selectedKeys.count) 个已下载文件及其记录。")
        }
        .onAppear {
            libraryVM.reload()
            pendingTasks = DownloadEngine.shared.allTasks().filter {
                $0.state == .queued || $0.state == .downloading || $0.state == .paused
            }.count
            isLoading = false
        }
    }

    /// Pending-tasks entry: the count of queued / downloading /
    /// paused engine tasks, into the tasks page.
    private var tasksEntry: some View {
        NavigationLink(destination: MusicDownloadTasksView()) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.accentText)
                Text("下载任务")
                    .font(.haoSubheadStrong)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text(pendingTasks == 0 ? "无待下载" : "\(pendingTasks) 个待下载")
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private var filterRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("筛选", selection: $filter) {
                ForEach(MusicDownloadFilter.allCases, id: \.rawValue) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("\(filteredDownloads.count) 首")
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Picker("排序", selection: $sort) {
                    ForEach(MusicDownloadSort.allCases, id: \.rawValue) { sort in
                        Text(sort.label).tag(sort)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private func downloadRow(_ download: DownloadedSong) -> some View {
        let fileExists = libraryVM.downloadedFileURL(for: download) != nil
        return HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: selectedKeys.contains(download.key) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selectedKeys.contains(download.key) ? theme.accentText : theme.textMuted)
                    .frame(width: 24, height: 24)
                    .onTapGesture {
                        if selectedKeys.contains(download.key) {
                            selectedKeys.remove(download.key)
                        } else {
                            selectedKeys.insert(download.key)
                        }
                    }
            }
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
                            MusicCoverView(urlString: download.song.cover, size: 48, cornerRadius: 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(download.song.title.isEmpty ? "未知歌曲" : download.song.title)
                                    .font(.system(size: 17, weight: .medium))
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
                    .disabled(!fileExists || isSelecting)
                    .accessibilityLabel(fileExists ? "播放" : "文件已丢失，无法播放")
                    MusicSongMenuButton(handle: menu)
                }
                .contextMenu { menu.menuContent() }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                libraryVM.deleteDownload(download)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
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

// MARK: - Download tasks (Coda §3.8, b45-b)

/// Live engine tasks: queued / downloading / paused / failed /
/// completed / cancelled, with pause / resume / cancel. The
/// "等待登录原账号" state does not exist here — there is no login.
struct MusicDownloadTasksView: View {
    @State private var tasks: [DownloadTaskInfo] = []

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            if tasks.isEmpty {
                MusicEmptyState(icon: "arrow.down.circle", title: "没有下载任务", note: "开始下载后，任务会出现在这里。")
            } else {
                List {
                    ForEach(tasks, id: \.request.key) { task in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.request.title)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(theme.textPrimary)
                                    .lineLimit(1)
                                HStack(spacing: 8) {
                                    Text(downloadStateText(task.state))
                                        .font(.haoFootnote)
                                        .foregroundStyle(theme.textSecondary)
                                    if task.totalBytes > 0 {
                                        Text("\(formattedSize(Int(task.downloadedBytes))) / \(formattedSize(Int(task.totalBytes)))")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(theme.textMuted)
                                    }
                                }
                                if task.state == .downloading, task.totalBytes > 0 {
                                    ProgressView(value: Double(task.downloadedBytes), total: Double(task.totalBytes))
                                }
                                if let error = task.errorMessage, !error.isEmpty {
                                    Text(error)
                                        .font(.haoFootnote)
                                        .foregroundStyle(theme.liveRed)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            taskActions(task)
                        }
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
        .navigationTitle("下载任务")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
    }

    @ViewBuilder
    private func taskActions(_ task: DownloadTaskInfo) -> some View {
        switch task.state {
        case .downloading, .queued:
            Button("暂停") { DownloadEngine.shared.pause(key: task.request.key); reload() }
                .font(.haoFootnoteStrong)
                .foregroundStyle(theme.accentText)
        case .paused:
            Button("继续") { DownloadEngine.shared.resume(key: task.request.key); reload() }
                .font(.haoFootnoteStrong)
                .foregroundStyle(theme.accentText)
        case .failed:
            Button("重试") { DownloadEngine.shared.resume(key: task.request.key); reload() }
                .font(.haoFootnoteStrong)
                .foregroundStyle(theme.accentText)
        default:
            EmptyView()
        }
    }

    private func downloadStateText(_ state: DownloadState) -> String {
        switch state {
        case .queued: return "排队中"
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已下载"
        case .failed: return "下载失败"
        case .cancelled: return "已取消"
        }
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

    private func reload() {
        tasks = DownloadEngine.shared.allTasks()
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

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
    // b45-b (Coda §3.3): library groups data — created
    // playlists, favourited playlists, favourited albums,
    // favourited artists. Local only, no login.
    @State private var libraryLists: [UserPlaylist] = []
    @State private var libraryFavAlbums: [AlbumSummary] = []
    @State private var libraryFavArtists: [ArtistSummary] = []
    @State private var libraryFavPlaylistIds: Set<String> = []
    @State private var showCreateList = false
    @State private var newListName = ""

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    // b49 sweep P2: the title is a row INSIDE the
                    // List now (myHeader, first row of
                    // entriesSection) — the pinned title above the
                    // List never scrolled away while every other
                    // tab's title did. The -51pt content margin
                    // below still pulls the first row up to ~12pt
                    // under the status bar (the b45 calibration);
                    // whether the first fold row stays visible is
                    // 改了、未验 (device check).
                    List {
                        entriesSection
                        migrationSection
                        settingsSection
                        // b40: bottom clearance lives INSIDE the list as
                        // a trailing clear row (same value as the other
                        // tab roots' in-content padding) — safeAreaPadding
                        // on the List never reached the rows inside a
                        // NavigationStack, so the last row stayed under
                        // the chrome. Zero-height row + bottom padding =
                        // exactly the clearance, no visible row.
                        Color.clear
                            .frame(height: 0)
                            .haoBottomChromeContentPadding()
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    // b45: the List's hidden-nav-bar reserve (~63pt
                    // by the b44 measurement: 75pt gap − 12pt title
                    // padding) is pulled back with a −51pt top
                    // content margin, so the first row — the 我的
                    // title row now, not a section — sits ~12pt
                    // under the status bar, like the other pages.
                    .contentMargins(.top, -51, for: .scrollContent)
                    .haoChromeScrollTracking()
                    .haoReselectScrollToTop(tab: .my, proxy: proxy)
                    .listStyle(.insetGrouped)
                    // b44: tighten the section rhythm to the other tab
                    // roots' 12pt rhythm — the grouped default leaves a
                    // wide band between the title and the first section
                    // header, which was part of the "空这么多" gap.
                    .listSectionSpacing(12)
                    .scrollContentBackground(.hidden)
                    // b44: no system large title — the title is the
                    // in-content myHeader row inside the List,
                    // exactly like the other pages. The navigation
                    // bar stays hidden so a pushed page's own bar /
                    // back button is unaffected.
                    .toolbar(.hidden, for: .navigationBar)
                    // b45-b (Coda §3.3): new playlist via the system
                    // alert (textfield placeholder "歌单名称").
                    .alert("新建歌单", isPresented: $showCreateList) {
                        TextField("歌单名称", text: $newListName)
                        Button("保存") {
                            let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            _ = MusicLibraryStore.createList(named: name)
                            counts = MyEntryCounts.reload()
                            reloadLibrary()
                        }
                        Button("取消", role: .cancel) { }
                    }
                    .navigationDestination(item: $selectedLiveRoom) { room in
                        LiveRoomView(room: room, playlist: [room])
                    }
                    .onAppear {
                        counts = MyEntryCounts.reload()
                        reloadLibrary()
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
                        reloadLibrary()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .haoMusicFavChanged)) { _ in
                        counts = MyEntryCounts.reload()
                        reloadLibrary()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .haoVideoFavChanged)) { _ in
                        // Same staleness as the music/live counts above:
                        // the video store already posts on every favourite
                        // toggle; this page just never listened, so the
                        // "影视收藏" count stayed stale after an
                        // unfavourite from the pushed list.
                        counts = MyEntryCounts.reload()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .haoVideoHistoryChanged)) { _ in
                        // A1: same staleness for the 影视历史 count —
                        // a watch / remove / clear-all from the player or
                        // the pushed history list now posts, so the count
                        // updates while this page is on screen.
                        counts = MyEntryCounts.reload()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .haoLiveHistoryChanged)) { _ in
                        // A2: same staleness for the 直播历史 count —
                        // entering a room, or a delete from the pushed
                        // history list, now posts, so the count updates
                        // while this page is on screen.
                        counts = MyEntryCounts.reload()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .haoMusicPlaylistChanged)) { _ in
                        // A3: same staleness for the 歌单 count — a
                        // delete from the pushed playlist list now posts.
                        counts = MyEntryCounts.reload()
                        reloadLibrary()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .haoMusicDownloadChanged)) { _ in
                        // A3: same staleness for the 我的下载 count — a
                        // download removed from the pushed list now posts.
                        counts = MyEntryCounts.reload()
                    }
                }
                .haoBackdropLayer()
                .haoTabBackground()
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

    // MARK: - In-content title (b44, moved into the List in b49)

    /// b44 (chen 2026-11-25: 我的页标题要和其他页面一样，标题下
    /// 空一大片): the title is an in-content title like the other
    /// tab roots (homeHeader pattern — 34pt bold, theme text
    /// colour, 12pt top padding), NOT the system large title.
    /// b49 sweep P2: it is a ROW inside the List now (first row
    /// of entriesSection), not a pinned view above the List — the
    /// pinned title never scrolled away while every other tab's
    /// title did. It carries the reselect-scroll-to-top id and
    /// the chrome scroll-offset reader (moved here from the fold
    /// row — they live on the FIRST child of the scroll content).
    /// The -51pt top content margin pulls it up to ~12pt under
    /// the status bar (b45 calibration); the first fold row
    /// staying visible is 改了、未验 (device check).
    private var myHeader: some View {
        Text("我的")
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(theme.textPrimary)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(HaoTabScrollTop.id(for: .my))
            .background { HaoChromeScrollOffsetReader() }
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    // MARK: - My entries (b45-b, Coda §3.3 library groups)

    /// Library groups, in Coda order: created playlists →
    /// favourited playlists → favourited albums → favourited
    /// artists. Each group has a SectionHeader + (for created
    /// lists) a "+" new button, a horizontal shelf with 8pt
    /// vertical padding, and a secondary empty text with 12pt
    /// vertical padding. Group titles sit at 16pt side margin
    /// (not 20). Everything is local — the login-gated hero /
    /// cloud / liked-albums blocks are replaced by these local
    /// equivalents. b44's in-content title (now the first row of
    /// this section) and anchor-free structure are untouched.
    private var entriesSection: some View {
        Section {
            // b49 sweep P2: the title row (myHeader) is the first
            // child of the scroll content now — it carries the
            // reselect-scroll-to-top id and the chrome
            // scroll-offset reader. The fold row below is the
            // second child.
            myHeader
            // b48: the fold is a row now, not a section header —
            // same reason as SettingsSectionFoldRow (the header is
            // hidden under the title by the -51pt content margin).
            SettingsSectionFoldRow(section: .my)
            if settings.sectionExpanded(SettingsSection.my.rawValue) {
                libraryGroupHeader(title: "创建的歌单", showAdd: true)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                if libraryLists.isEmpty {
                    Text("还没有创建的歌单，点右上角 + 新建一个。")
                        .font(.haoSubhead)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.vertical, 12)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    playlistShelf(libraryLists)
                        .padding(.vertical, 8)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                libraryGroupHeader(title: "收藏的歌单")
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                let favLists = libraryLists.filter { libraryFavPlaylistIds.contains($0.id) }
                if favLists.isEmpty {
                    Text("还没有收藏的歌单，在歌单页点星标收藏。")
                        .font(.haoSubhead)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.vertical, 12)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    playlistShelf(favLists)
                        .padding(.vertical, 8)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                libraryGroupHeader(title: "收藏的专辑")
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                if libraryFavAlbums.isEmpty {
                    Text("还没有收藏的专辑，在专辑页点星标收藏。")
                        .font(.haoSubhead)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.vertical, 12)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    albumShelf(libraryFavAlbums)
                        .padding(.vertical, 8)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                libraryGroupHeader(title: "收藏的歌手")
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                if libraryFavArtists.isEmpty {
                    Text("还没有收藏的歌手，在歌手页点星标收藏。")
                        .font(.haoSubhead)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.vertical, 12)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    artistShelf(libraryFavArtists)
                        .padding(.vertical, 8)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                NavigationLink(destination: MyPlaylistsView()) {
                    entryRow(icon: "music.note.list", title: "全部歌单", count: counts.playlists)
                }
                NavigationLink(destination: MusicFavouritesView()) {
                    entryRow(icon: "heart.fill", title: "音乐收藏", count: counts.favourites)
                }
                NavigationLink(destination: MyRecentPlaysView()) {
                    entryRow(icon: "clock.fill", title: "最近播放", count: counts.recent)
                }
                NavigationLink(destination: MusicDownloadsView()) {
                    entryRow(icon: "arrow.down.circle.fill", title: "我的下载", count: counts.downloads)
                }
                NavigationLink(destination: VideoFavsView()) {
                    entryRow(icon: "film.fill", title: "影视收藏", count: counts.videoFavourites)
                }
                NavigationLink(destination: VideoHistoryView()) {
                    entryRow(icon: "clock.arrow.circlepath", title: "影视历史", count: counts.videoHistory)
                }
                NavigationLink(destination: LiveFollowsView(onSelect: openLiveRoom)) {
                    entryRow(icon: "person.2.fill", title: "我的关注", count: counts.liveFollows)
                }
                NavigationLink(destination: LiveHistoryView(onSelect: openLiveRoom)) {
                    entryRow(icon: "antenna.radiowaves.left.and.right", title: "直播历史", count: counts.liveHistory)
                }
            }
        }
    }

    /// Coda §3.3 group header: SectionHeader + "+" new button
    /// (plus 13pt semibold, 44×44).
    private func libraryGroupHeader(title: String, showAdd: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.haoSectionTitle)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            if showAdd {
                Button(action: {
                    newListName = ""
                    showCreateList = true
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("新建歌单")
            }
        }
    }

    /// Playlist shelf: cover + name + "N 首" subtitle.
    private func playlistShelf(_ lists: [UserPlaylist]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(lists) { list in
                    NavigationLink(destination: MusicPlaylistDetailView(listId: list.id)) {
                        VStack(alignment: .leading, spacing: 6) {
                            MusicCoverView(urlString: list.cover, size: 120, cornerRadius: 12)
                            Text(list.name.isEmpty ? "未命名歌单" : list.name)
                                .font(.haoSubheadStrong)
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                                .frame(width: 120, alignment: .leading)
                            Text("\(list.trackCount) 首")
                                .font(.haoFootnote)
                                .foregroundStyle(theme.textSecondary)
                                .frame(width: 120, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func albumShelf(_ albums: [AlbumSummary]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(albums) { album in
                    NavigationLink(destination: MusicAlbumDetailView(album: album)) {
                        VStack(alignment: .leading, spacing: 6) {
                            MusicCoverView(urlString: album.cover, size: 120, cornerRadius: 12)
                            Text(album.name)
                                .font(.haoSubheadStrong)
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                                .frame(width: 120, alignment: .leading)
                            Text(album.artist)
                                .font(.haoFootnote)
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                                .frame(width: 120, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func artistShelf(_ artists: [ArtistSummary]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(artists, id: \.name) { artist in
                    NavigationLink(destination: MusicArtistDetailView(artist: artist)) {
                        VStack(spacing: 6) {
                            MusicCoverView(urlString: artist.cover, size: 80, cornerRadius: 40)
                            Text(artist.name)
                                .font(.haoSubheadStrong)
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                                .frame(width: 96, alignment: .center)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func reloadLibrary() {
        libraryLists = MusicLibraryStore.getLists()
        libraryFavAlbums = MusicLibraryStore.favAlbums()
        libraryFavArtists = MusicLibraryStore.favArtists()
        libraryFavPlaylistIds = MusicLibraryStore.favPlaylistIds()
    }

    /// One entry row: a bare SF Symbol + title + count (Coda §4:
    /// Settings rows use bare SF Symbols with no coloured-square
    /// icon background). The 28pt accent-soft chip is removed —
    /// only the 我的 entry rows deviated; the Settings groups
    /// already use bare Labels. The 28×28 frame stays so the
    /// title alignment does not shift; the icon colour follows
    /// the bare-icon precedent (LiveTabView's header buttons).
    private func entryRow(icon: String, title: String, count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))  // icon size, not text
                .foregroundStyle(theme.textPrimary)
                .frame(width: 28, height: 28)
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
    @State private var showCreateList = false
    @State private var newListName = ""

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
        .toolbar {
            // b45-b (Coda §3.3): "+" new button (plus 13pt
            // semibold, 44×44) + system alert, placeholder
            // "歌单名称".
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    newListName = ""
                    showCreateList = true
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("新建歌单")
            }
        }
        .onAppear {
            lists = MusicLibraryStore.getLists()
        }
        .alert("新建歌单", isPresented: $showCreateList) {
            TextField("歌单名称", text: $newListName)
            Button("保存") {
                let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                _ = MusicLibraryStore.createList(named: name)
                lists = MusicLibraryStore.getLists()
            }
            Button("取消", role: .cancel) { }
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
///
/// b45-b (Coda §3.8 RecentsView): play-all + sort / search, and
/// the list is a reloadable PlaySource (.recent) — one tap
/// replays the whole recent context. Recent updates in real
/// time (chen 2026-11-20): a song played anywhere moves to the
/// top at once, no page switch, no re-entry.
private struct MyRecentPlaysView: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel

    @State private var recent: [MusicSong] = MusicLibraryStore.getRecent()
    @State private var searchText = ""
    @State private var sortNewestFirst = true

    @Environment(\.haoTheme) private var theme

    /// The recent context as a PlaySource (Coda §9.2): kind +
    /// id identify it, so a rename never changes the identity
    /// and the whole list replays with one tap.
    private let source = MusicPlaySource.recent

    private var displayedRecent: [MusicSong] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = recent
        if !query.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.artist.localizedCaseInsensitiveContains(query)
                    || $0.album.localizedCaseInsensitiveContains(query)
            }
        }
        if !sortNewestFirst {
            list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return list
    }

    var body: some View {
        Group {
            if recent.isEmpty {
                MusicEmptyState(
                    icon: "clock", title: "还没有最近播放",
                    note: "播过的歌曲会出现在这里，点一下就能再播。")
            } else {
                List {
                    Section {
                        searchField
                    }
                    .listRowBackground(theme.scaffoldBackground)
                    .listRowSeparator(.hidden)
                    if displayedRecent.isEmpty {
                        MusicEmptyState(icon: "magnifyingglass", title: "没有匹配的歌曲", note: "试试其他歌名、歌手或专辑")
                            .listRowBackground(theme.scaffoldBackground)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(Array(displayedRecent.enumerated()), id: \.element.id) { index, song in
                            MusicSongRow(
                                song: song,
                                isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
                                onTap: {
                                    playerVM.play(song: song, in: displayedRecent, startAt: index, source: PlaySource(kind: .recent, id: "recent"), sourceDisplayName: "最近播放")
                                },
                                onToggleFav: {
                                    recent = MusicLibraryStore.getRecent()
                                }
                            )
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
        .navigationTitle("最近播放")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    Menu {
                        Button("最新在前") { sortNewestFirst = true }
                        Button("按歌名") { sortNewestFirst = false }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .foregroundStyle(theme.textPrimary)
                    }
                    .accessibilityLabel("排序")
                    MusicCapsuleButton(icon: "play.fill", label: "播放全部", enabled: !recent.isEmpty) {
                        // One-tap replay of the recent context
                        // (PlaySource .recent, kind + id).
                        // b46: the source was missing — the context
                        // was never recorded, so switching lost it.
                        playerVM.playAll(recent, source: PlaySource(kind: .recent, id: "recent"), sourceDisplayName: "最近播放")
                    }
                }
            }
        }
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
}

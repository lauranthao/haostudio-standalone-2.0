// HAo Studio 2.0 — home tab aggregation (home leg A).
//
// Replaces HomePlaceholderView. Five sections, top to bottom:
// continue watching / continue listening / hot live / daily
// picks / recent plays. Every section reads ONLY the five
// arrays on HomeViewModel (B leg) plus reload() — this view
// never touches a store directly.
//
// Navigation reuses the destinations the tabs already have:
// a video card opens VideoDetailView, "全部" on continue
// watching opens VideoHistoryView, and a live card opens
// LiveRoomView with the hot list as the switch playlist. Two
// "全部" pages are home's own, because the tab versions do not
// show the same content: "全部" on recent plays lists the same
// view-model array (the music recent list in MyView.swift is
// private inside that file), and "全部" on hot live lists the
// merged follow + history rooms with their LIVE badges (the
// follows page shows follows only, with no badges).
//
// Live cards reuse LiveRoomCard, so the LIVE badge (theme
// liveRed, the only red in the app) appears only when the
// item's isLive is true — a room whose live status was not
// confirmed shows no badge. No section ever invents content:
// an empty section shows its honest empty state.

import SwiftUI

/// Home navigation destinations.
enum HomeDestination: Hashable {
    case detail(VideoItem)
    case history
    case recent
    case hotLive
    case room(LiveRoom, [LiveRoom])
}

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @State private var path: [HomeDestination] = []

    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @Environment(\.haoTheme) private var theme

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Scroll anchor for the bottom chrome (b35 tab-bar
                        // link): drives minimize / restore as this tab scrolls.
                        // It also carries this tab's scroll-to-top id (chrome
                        // O1): a reselect scrolls the proxy to it.
                        HaoChromeScrollAnchor()
                            .id(HaoTabScrollTop.id(for: .home))
                        homeHeader
                        continueWatchingSection
                            .padding(.top, 12)
                        continueListeningSection
                            .padding(.top, 16)
                        hotLiveSection
                            .padding(.top, 16)
                        dailySection
                            .padding(.top, 16)
                        recentSection
                            .padding(.top, 16)
                        Spacer(minLength: 16)
                    }
                    .haoBottomChromeContentPadding()
                }
                .haoChromeScrollTracking()
                .haoReselectScrollToTop(tab: .home, proxy: proxy)
                .refreshable { viewModel.reload() }
                .haoBackdropLayer()
                .haoTabBackground()
                // b39: no system nav bar on this root. The large
                // title "首页" did not render on chen's iPhone Air
                // (build 38 screenshot: zero dark pixels in the
                // title zone, nav bar present but empty — mechanism
                // unproven from code, no appearance customisation
                // exists anywhere), leaving a ~100pt blank above
                // 继续观看. The title now lives in the content
                // (homeHeader) so it can never vanish; pushed pages
                // (detail, history, recent plays, hot live, room)
                // keep their own bars and back buttons. This also
                // retires the b35 opaque-bar fix above: with no bar
                // there is nothing for scrolling covers to smear
                // through.
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: HomeDestination.self) { destination in
                    switch destination {
                    case .detail(let item):
                        VideoDetailView(item: item)
                    case .history:
                        VideoHistoryView()
                    case .recent:
                        HomeRecentPlaysView(viewModel: viewModel)
                    case .hotLive:
                        HomeHotLiveView(viewModel: viewModel) { room, playlist in
                            openRoom(room, playlist: playlist)
                        }
                    case .room(let room, let playlist):
                        LiveRoomView(room: room, playlist: playlist)
                    }
                }
                // Appearance reload, coalesced in the view model:
                // a tab switch back (onAppear) and a pop back
                // (path-empty below) are different triggers for the
                // same "back at home" event — one return trip pays
                // for one reload, never two.
                .onAppear { viewModel.reloadForAppearance() }
                // Follow toggle from a card's long-press menu (shared
                // LiveRoomCard) writes the store directly — the home
                // section used to keep the unfollowed card until the
                // next reload. Rebuild hot live from local data at
                // once; the "全部" page shares this view model, so it
                // updates too. No network is spent (see
                // refreshHotLiveForFollowChange).
                .onReceive(NotificationCenter.default.publisher(for: .haoLiveFollowChanged)) { _ in
                    viewModel.refreshHotLiveForFollowChange()
                }
                // Recent-play change (chen 2026-11-20: 最近播放实时更新):
                // a song can start from any page while the user stays
                // on home (tap a 每日推荐 row, the mini player, an
                // auto-advance), and the store posts
                // haoMusicRecentChanged — the music tab and 我的 both
                // reload on it, home never did, so 最近播放 / 继续听
                // stayed stale until the next tab switch. Direct
                // reload(), not reloadForAppearance(): the data
                // actually changed, so it must not be coalesced away.
                .onReceive(NotificationCenter.default.publisher(for: .haoMusicRecentChanged)) { _ in
                    viewModel.reload()
                }
                // Video-history change (A1): a film watched from the
                // player, or a history row removed/cleared from the
                // pushed list, posts haoVideoHistoryChanged — home's
                // 继续观看 reloads without waiting for a tab switch
                // or pop-back.
                .onReceive(NotificationCenter.default.publisher(for: .haoVideoHistoryChanged)) { _ in
                    viewModel.reload()
                }
                // Live-history change (A2): entering a room, or a
                // history row removed/cleared from the pushed list,
                // posts haoLiveHistoryChanged — home's 热门直播
                // reloads without waiting for a tab switch or
                // pop-back.
                .onReceive(NotificationCenter.default.publisher(for: .haoLiveHistoryChanged)) { _ in
                    viewModel.reload()
                }
                // Return-to-home refresh: NavigationStack's own
                // onAppear does not re-fire when a pushed detail or
                // room pops (the stack itself never disappears), so
                // without this the sections still showed the data from
                // before the push — a video watched from home stayed
                // in its old place in 继续观看 until the tab was
                // switched. An empty path means back at the home root.
                .onChange(of: path) { _, newPath in
                    if newPath.isEmpty { viewModel.reloadForAppearance() }
                }
            }
        }
    }

    // MARK: - Section header

    private func sectionHeader(title: String, onAll: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title)
                .font(.haoSectionTitle)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            if let onAll = onAll {
                Button(action: onAll) {
                    HStack(spacing: 2) {
                        Text("全部")
                            .font(.haoDenseBody)
                        Image(systemName: "chevron.right")
                            .font(.haoCaption2)
                    }
                    // The bare text was a ~30pt-wide hit target;
                    // the padding makes it a ~44pt HIG target
                    // (14pt text + 12pt above and below).
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .foregroundStyle(theme.accentText)
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Continue watching

    /// In-content page title (34pt bold = the system large
    /// title's size), at the same 24pt horizontal padding as the
    /// section headers. b39: the system large title did not
    /// render on chen's phone, so the title lives in the content
    /// now — it is always painted, never dependent on the
    /// navigation bar.
    private var homeHeader: some View {
        Text("首页")
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 24)
            .padding(.top, 12)
    }

    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "继续观看", onAll: { path.append(.history) })
            if viewModel.continueWatching.isEmpty {
                MusicEmptyState(
                    icon: "film",
                    title: "还没有看过影片",
                    note: "看过的影片会出现在这里，点一下继续看"
                )
                .padding(.horizontal, 24)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(viewModel.continueWatching) { entry in
                            VideoContinueCard(entry: entry) {
                                path.append(.detail(entry.item))
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
    }

    // MARK: - Continue listening

    private var continueListeningSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "继续听")
            if viewModel.continueListening.isEmpty {
                MusicEmptyState(
                    icon: "music.note",
                    title: "还没有听过歌",
                    note: "播过的歌会出现在这里，点一下继续听"
                )
                .padding(.horizontal, 24)
            } else {
                // One card only (the view model returns exactly
                // one resume song), so no scroll view: a horizontal
                // ScrollView around a single non-scrollable child
                // is structure with no job. Plain HStack, same
                // 24pt edge as every other section.
                HStack(spacing: 12) {
                    ForEach(Array(viewModel.continueListening.enumerated()), id: \.element.id) { index, song in
                        HomeSongCard(song: song, resumeSeconds: viewModel.continueListeningResumeSeconds) {
                            // H1: the tap resumes from the stored
                            // checkpoint (nil = recent fallback, from 0).
                            // b46: continue-listening is the recent place.
                            playerVM.play(
                                song: song, in: continueListeningQueue(for: song), startAt: 0,
                                resumeFrom: viewModel.continueListeningResumeSeconds.map { Double($0) },
                                source: PlaySource(kind: .recent, id: "recent"), sourceDisplayName: "最近播放")
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    /// The queue behind a "继续听" tap: the resume song first,
    /// then the rest of recent plays (the resume song itself
    /// removed). The tap used to queue just the one song, so
    /// playback stopped dead when it ended instead of carrying
    /// on into what was played recently.
    private func continueListeningQueue(for song: MusicSong) -> [MusicSong] {
        var queue = [song]
        queue.append(contentsOf: viewModel.allRecentPlays.filter { $0.identityKey != song.identityKey })
        return queue
    }

    // MARK: - Hot live

    private var hotLiveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "热门直播", onAll: { path.append(.hotLive) })
            if viewModel.hotLive.isEmpty {
                MusicEmptyState(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "暂无直播",
                    note: "去直播里关注主播，开播后会出现在这里"
                )
                .padding(.horizontal, 24)
            } else {
                LazyVGrid(columns: LiveGridLayout.gridColumns, spacing: LiveGridLayout.gridRowSpacing) {
                    ForEach(viewModel.hotLive, id: \.id) { item in
                        let room = homeLiveRoom(from: item)
                        LiveRoomCard(room: room) {
                            openRoom(room, playlist: hotLiveRooms)
                        }
                    }
                }
                .padding(.horizontal, LiveGridLayout.gridEdgePadding)
            }
        }
    }

    private var hotLiveRooms: [LiveRoom] {
        viewModel.hotLive.map { homeLiveRoom(from: $0) }
    }

    // MARK: - Daily picks

    private var dailySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "每日推荐")
            if viewModel.daily.isEmpty {
                MusicEmptyState(
                    icon: "calendar",
                    title: "今天还没有推荐",
                    note: "先收藏几首歌或播几首歌，每日推荐会从你听过的歌里挑"
                )
                .padding(.horizontal, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.daily.enumerated()), id: \.element.id) { index, song in
                        songRow(song: song, tracks: viewModel.daily, index: index, source: PlaySource(kind: .daily, id: "daily"), sourceDisplayName: "每日推荐")
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - Recent plays

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "最近播放", onAll: { path.append(.recent) })
            if viewModel.recentPlays.isEmpty {
                MusicEmptyState(
                    icon: "clock",
                    title: "还没有播放记录",
                    note: "播过的歌会出现在这里"
                )
                .padding(.horizontal, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.recentPlays.prefix(10).enumerated()), id: \.element.id) { index, song in
                        songRow(song: song, tracks: viewModel.recentPlays, index: index, source: PlaySource(kind: .recent, id: "recent"), sourceDisplayName: "最近播放")
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - Shared song row

    /// One tappable song row wired to the shared music player
    /// (same call as the music home recent section: the mini
    /// player appears and switching tabs does not stop playback).
    /// No onToggleFav: the row flips its own favourite state
    /// (MusicSongMenuHost keeps @State isFav, refreshed from the
    /// haoMusicFavChanged notification the toggle posts), so a
    /// favourite tap needs no view-model refresh at all — the
    /// old reload() here paid for a full reload plus up to 10
    /// live-status requests for one star tap, and changed
    /// nothing else: daily is per-day cached and stable, recent
    /// / continue-listening do not depend on favourites.
    /// (Build 36, item 10.)
    /// b46: `source` is the row's reloadable place — without it
    /// a tap loses the playlist for track switching.
    private func songRow(song: MusicSong, tracks: [MusicSong], index: Int, source: PlaySource? = nil, sourceDisplayName: String? = nil) -> some View {
        MusicSongRow(
            song: song,
            isPlaying: isPlaying(song),
            onTap: {
                playerVM.play(song: song, in: tracks, startAt: index, source: source, sourceDisplayName: sourceDisplayName)
            }
        )
        .padding(.vertical, 6)
    }

    private func isPlaying(_ song: MusicSong) -> Bool {
        playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying
    }

    // MARK: - Live rooms

    /// Enter a room: record history first (Flutter L01, same as
    /// the live tab), then navigate with the playlist for room
    /// switching.
    private func openRoom(_ room: LiveRoom, playlist: [LiveRoom]) {
        LiveLibraryStore.recordHistory(
            platform: room.platform.rawValue, roomId: room.roomId,
            title: room.title, nick: room.streamer, cover: room.cover)
        path.append(.room(room, playlist))
    }
}

/// Build the room page input from a home live item. The
/// platform string is matched against the kernel id first
/// ("bili", "ks"), then the Flutter site id ("bilibili",
/// "kuaishou"), then the display name; an unknown value
/// falls back to Bilibili so the room still opens instead
/// of dropping the tap. File scope (not a HomeView method)
/// so the home hot-live page below can build rooms too.
fileprivate func homeLiveRoom(from item: HomeLiveItem) -> LiveRoom {
    LiveRoom(
        roomId: item.roomId,
        platform: homeLivePlatform(from: item.platform),
        title: item.title,
        streamer: item.nick,
        cover: item.cover,
        isLive: item.isLive
    )
}

fileprivate func homeLivePlatform(from value: String) -> LivePlatform {
    if let platform = LivePlatform(rawValue: value) {
        return platform
    }
    if let platform = LivePlatform.allCases.first(where: { $0.flutterSiteId == value }) {
        return platform
    }
    if let platform = LivePlatform.allCases.first(where: { $0.displayName == value }) {
        return platform
    }
    return .bilibili
}

/// One song in the horizontal "继续听" shelf: square cover +
/// title + artist. Tap plays; the card itself holds no playback.
/// `resumeSeconds` is the stored checkpoint behind this card
/// (nil = recent-play fallback): shown as "上次听到 m:ss" and
/// the value the tap seeks to — the label only ever appears
/// together with the seek, never on its own.
struct HomeSongCard: View {
    var song: MusicSong
    var resumeSeconds: Int? = nil
    var onTap: () -> Void

    @Environment(\.haoTheme) private var theme

    var body: some View {
        // Long-press only (build 36, item 12): a "…" button does
        // not fit the 120pt card layout without redesign. The
        // menu is the same shared one as the rows.
        MusicSongMenuHost(song: song) { menu in
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 6) {
                    MusicCoverView(urlString: song.cover, size: 120, cornerRadius: 12)
                    Text(song.title.isEmpty ? "未知歌曲" : song.title)
                        .font(.haoDenseTitle)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(song.artist.isEmpty ? "未知艺人" : song.artist)
                        .font(.haoCaption)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                    if let resumeSeconds = resumeSeconds {
                        Text("上次听到 \(musicDurationText(seconds: resumeSeconds))")
                            .font(.haoCaption)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: 120, alignment: .leading)
            }
            .buttonStyle(MusicPressScaleStyle())
            .contextMenu { menu.menuContent() }
        }
    }
}

/// Full recent-plays list behind the "全部" link. Reads the
/// view model's full list (allRecentPlays, up to 100) — the
/// home section itself only shows the first 10, so this page
/// used to list exactly the same 10 rows as the section. The
/// music recent list in MyView.swift is private to that file,
/// so the home tab carries this small list instead of
/// duplicating the store read.
private struct HomeRecentPlaysView: View {
    @ObservedObject var viewModel: HomeViewModel

    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            if viewModel.allRecentPlays.isEmpty {
                MusicEmptyState(
                    icon: "clock",
                    title: "还没有播放记录",
                    note: "播过的歌会出现在这里"
                )
                .haoBottomChromePadding()
            } else {
                // Lazy (build 36, item 10): a plain VStack built
                // all 100 rows — each with its cover, menu host
                // and subscriptions — on every appearance. A
                // List only builds the rows on screen, like
                // every other music list in the app. Same rows,
                // same order, same tap behaviour.
                List {
                    ForEach(Array(viewModel.allRecentPlays.enumerated()), id: \.element.id) { index, song in
                        MusicSongRow(
                            song: song,
                            isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
                            onTap: {
                                // b46: recent plays are a reloadable place.
                                playerVM.play(song: song, in: viewModel.allRecentPlays, startAt: index, source: PlaySource(kind: .recent, id: "recent"), sourceDisplayName: "最近播放")
                            }
                            // No onToggleFav: same as the home
                            // songRow — the row flips its own
                            // favourite state; a star tap no
                            // longer pays for a full reload
                            // (build 36, item 10).
                        )
                        .listRowBackground(theme.scaffoldBackground)
                        .listRowSeparatorTint(theme.hairline)
                        .listRowInsets(EdgeInsets(top: 6, leading: 24, bottom: 6, trailing: 24))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .haoBottomChromePadding()
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("最近播放")
        .navigationBarTitleDisplayMode(.inline)
        // This page's only reload: pushing it does NOT re-fire
        // home's onAppear (the NavigationStack root stays
        // mounted), so without this the list would show the data
        // from home's last reload — stale if a song was played
        // from home just before tapping "全部". Coalesced, not
        // unconditional: if home reloaded less than a second ago
        // (e.g. a pop back straight into "全部"), the data is
        // already fresh and this is skipped — no duplicate full
        // reload for one trip. HomeHotLiveView needs no reload
        // of its own (it reuses the same hotLive array).
        .onAppear { viewModel.reloadForAppearance() }
    }
}

/// Full hot-live list behind the "全部" link: the same merged
/// follow + history rooms as the home section, in the same grid
/// with the same cards and LIVE badges. The follows page
/// (LiveFollowsView) used to be the destination, but it shows
/// follows only, with no badges — half the section's rooms were
/// missing behind its own "全部". Follows management is still
/// reachable from the live tab and the 我的 page.
private struct HomeHotLiveView: View {
    @ObservedObject var viewModel: HomeViewModel
    var openRoom: (LiveRoom, [LiveRoom]) -> Void

    @Environment(\.haoTheme) private var theme

    private var rooms: [LiveRoom] {
        viewModel.hotLive.map { homeLiveRoom(from: $0) }
    }

    var body: some View {
        Group {
            if viewModel.hotLive.isEmpty {
                MusicEmptyState(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "暂无直播",
                    note: "去直播里关注主播，开播后会出现在这里"
                )
                .haoBottomChromePadding()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        LazyVGrid(columns: LiveGridLayout.gridColumns, spacing: LiveGridLayout.gridRowSpacing) {
                            ForEach(viewModel.hotLive, id: \.id) { item in
                                let room = homeLiveRoom(from: item)
                                LiveRoomCard(room: room) {
                                    openRoom(room, rooms)
                                }
                            }
                        }
                        .padding(.horizontal, LiveGridLayout.gridEdgePadding)
                        .padding(.top, 12)
                        Spacer(minLength: 16)
                    }
                }
                .haoBottomChromePadding()
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("热门直播")
        .navigationBarTitleDisplayMode(.inline)
    }
}

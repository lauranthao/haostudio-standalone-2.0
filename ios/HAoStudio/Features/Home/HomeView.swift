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
// watching opens VideoHistoryView, "全部" on hot live opens
// LiveFollowsView, and a live card opens LiveRoomView with the
// hot list as the switch playlist. The one exception is
// "全部" on recent plays: the music recent list
// (MyRecentPlaysView) is private inside MyView.swift, so the
// home tab carries its own small HomeRecentPlaysView below
// that lists the same view-model array instead of inventing a
// second store read.
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
    case follows
    case room(LiveRoom, [LiveRoom])
}

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @State private var path: [HomeDestination] = []

    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @Environment(\.haoTheme) private var theme

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Scroll anchor for the bottom chrome (b35 tab-bar
                    // link): drives minimize / restore as this tab scrolls.
                    HaoChromeScrollAnchor()
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
            }
            .haoBottomChromePadding()
            .haoChromeScrollTracking()
            .refreshable { viewModel.reload() }
            .background(theme.scaffoldBackground)
            .navigationTitle("首页")
            .navigationBarTitleDisplayMode(.large)
            // Opaque nav-bar background (fix 2026-11-24, build
            // 35): the bar is translucent by default, so a cover
            // scrolling underneath it shows through as a blurred
            // grey block with no readable content — the grey smear
            // at the top of the build-34 screenshot is the
            // "继续听" cover seen through the bar (HomeView has no
            // banner / hero / header image to delete). A solid
            // scaffold-coloured bar removes the artifact at every
            // scroll position. Theme-owned, so all 4 themes x
            // light/dark keep working; toolbarBackground is
            // iOS 16+, deploy target is 17, no gating needed.
            // The bottom glass tab bar is untouched.
            .toolbarBackground(theme.scaffoldBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: HomeDestination.self) { destination in
                switch destination {
                case .detail(let item):
                    VideoDetailView(item: item)
                case .history:
                    VideoHistoryView()
                case .recent:
                    HomeRecentPlaysView(viewModel: viewModel)
                case .follows:
                    LiveFollowsView(onSelect: { room in
                        openRoom(room, playlist: [room])
                    })
                case .room(let room, let playlist):
                    LiveRoomView(room: room, playlist: playlist)
                }
            }
            .onAppear { viewModel.reload() }
        }
    }

    // MARK: - Section header

    private func sectionHeader(title: String, onAll: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title)
                .font(.haoDetailTitle)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            if let onAll = onAll {
                Button("全部", action: onAll)
                    .font(.haoDenseBody)
                    .foregroundStyle(theme.accent)
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Continue watching

    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "继续观看", onAll: { path.append(.history) })
            if viewModel.continueWatching.isEmpty {
                MusicEmptyState(
                    icon: "film",
                    title: "还没有看过影片",
                    note: "看过的影片会出现在这里，点一下继续看。"
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
                    note: "播过的歌会出现在这里，点一下继续听。"
                )
                .padding(.horizontal, 24)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(viewModel.continueListening.enumerated()), id: \.element.id) { index, song in
                            HomeSongCard(song: song) {
                                playerVM.play(song: song, in: viewModel.continueListening, startAt: index)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
    }

    // MARK: - Hot live

    private var hotLiveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "热门直播", onAll: { path.append(.follows) })
            if viewModel.hotLive.isEmpty {
                MusicEmptyState(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "关注的主播还没开播",
                    note: "去直播里关注主播，开播后会出现在这里。"
                )
                .padding(.horizontal, 24)
            } else {
                LazyVGrid(columns: LiveGridLayout.gridColumns, spacing: LiveGridLayout.gridRowSpacing) {
                    ForEach(viewModel.hotLive, id: \.id) { item in
                        LiveRoomCard(room: liveRoom(from: item)) {
                            openRoom(liveRoom(from: item), playlist: hotLiveRooms)
                        }
                    }
                }
                .padding(.horizontal, LiveGridLayout.gridEdgePadding)
            }
        }
    }

    private var hotLiveRooms: [LiveRoom] {
        viewModel.hotLive.map { liveRoom(from: $0) }
    }

    // MARK: - Daily picks

    private var dailySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "每日推荐")
            if viewModel.daily.isEmpty {
                MusicEmptyState(
                    icon: "calendar",
                    title: "今天还没有推荐",
                    note: "先收藏几首歌或播几首歌，每日推荐会从你听过的歌里挑。"
                )
                .padding(.horizontal, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.daily.enumerated()), id: \.element.id) { index, song in
                        songRow(song: song, tracks: viewModel.daily, index: index)
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
                    note: "播过的歌会出现在这里。"
                )
                .padding(.horizontal, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.recentPlays.prefix(10).enumerated()), id: \.element.id) { index, song in
                        songRow(song: song, tracks: viewModel.recentPlays, index: index)
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
    private func songRow(song: MusicSong, tracks: [MusicSong], index: Int) -> some View {
        MusicSongRow(
            song: song,
            isPlaying: isPlaying(song),
            onTap: {
                playerVM.play(song: song, in: tracks, startAt: index)
            },
            onToggleFav: {
                viewModel.reload()
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

    /// Build the room page input from a home live item. The
    /// platform string is matched against the kernel id first
    /// ("bili", "ks"), then the Flutter site id ("bilibili",
    /// "kuaishou"), then the display name; an unknown value
    /// falls back to Bilibili so the room still opens instead
    /// of dropping the tap.
    private func liveRoom(from item: HomeLiveItem) -> LiveRoom {
        LiveRoom(
            roomId: item.roomId,
            platform: livePlatform(from: item.platform),
            title: item.title,
            streamer: item.nick,
            cover: item.cover,
            isLive: item.isLive
        )
    }

    private func livePlatform(from value: String) -> LivePlatform {
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
}

/// One song in the horizontal "继续听" shelf: square cover +
/// title + artist. Tap plays; the card itself holds no playback.
struct HomeSongCard: View {
    var song: MusicSong
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
                }
                .frame(width: 120, alignment: .leading)
            }
            .buttonStyle(MusicPressScaleStyle())
            .contextMenu { menu.menuContent() }
        }
    }
}

/// Full recent-plays list behind the "全部" link. Reads the
/// same view-model array live (no second store read); the music
/// recent list in MyView.swift is private to that file, so the
/// home tab carries this small list instead of duplicating it.
private struct HomeRecentPlaysView: View {
    @ObservedObject var viewModel: HomeViewModel

    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            if viewModel.recentPlays.isEmpty {
                MusicEmptyState(
                    icon: "clock",
                    title: "还没有播放记录",
                    note: "播过的歌会出现在这里。"
                )
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(viewModel.recentPlays.enumerated()), id: \.element.id) { index, song in
                            MusicSongRow(
                                song: song,
                                isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
                                onTap: {
                                    playerVM.play(song: song, in: viewModel.recentPlays, startAt: index)
                                },
                                onToggleFav: {
                                    viewModel.reload()
                                }
                            )
                            .padding(.vertical, 6)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .haoBottomChromePadding()
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("最近播放")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.reload() }
    }
}

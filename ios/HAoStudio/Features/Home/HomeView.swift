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
    case hotLive
    case daily
    case room(LiveRoom, [LiveRoom])
}

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @State private var path: [HomeDestination] = []
    /// b49fix2 B4: the first-run welcome card, dismissed once.
    @AppStorage("hao_home_welcome_dismissed") private var welcomeDismissed = false
    /// b49fix2 B13: the live grid's laid-out container width,
    /// reported by the preference key below. 0 until the first
    /// layout — the screen width is the first-frame fallback.
    @State private var liveGridWidth: CGFloat = 0

    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @Environment(\.haoTheme) private var theme
    @Environment(\.verticalSizeClass) private var verticalSizeClass

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
                        // b49fix3 P1-3: the first frame shows the
                        // title only — the welcome card + sections
                        // appear once the first reload publishes
                        // (isLoading), never as four empty states.
                        if !viewModel.isLoading {
                            welcomeCard
                            continueWatchingSection
                                .padding(.top, 16)
                            continueListeningSection
                                .padding(.top, 16)
                            hotLiveSection
                                .padding(.top, 16)
                            dailySection
                                .padding(.top, 16)
                        }
                        Spacer(minLength: 16)
                    }
                    .haoBottomClearanceLandscapeAware(isLandscape: verticalSizeClass == .compact)
                }
                .haoChromeScrollTracking()
                .haoReselectScrollToTop(tab: .home, proxy: proxy)
                // Reselect while a page is pushed (b49-sweep):
                // the stock modifier only scrolls the root list
                // — a pushed page carries no anchor, so a
                // reselect did nothing visible. Pop to the tab
                // root first, then scroll to top once the pop
                // lands. At the root (empty path) the stock
                // modifier already handles it; this does nothing.
                .onReceive(NotificationCenter.default.publisher(for: .haoTabReselected)) { note in
                    guard (note.object as? HaoTab) == .home else { return }
                    guard !path.isEmpty else { return }
                    path.removeAll()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        proxy.scrollTo(HaoTabScrollTop.id(for: .home), anchor: .top)
                    }
                }
                // Pull-to-refresh re-checks live status for
                // real (forceLiveRecheck bypasses the 120 s
                // throttle — a refresh the throttle used to
                // swallow silently now really re-checks).
                .refreshable { viewModel.reload(forceLiveRecheck: true) }
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
                    case .hotLive:
                        HomeHotLiveView(viewModel: viewModel) { room, playlist in
                            openRoom(room, playlist: playlist)
                        }
                    case .daily:
                        // The discovery daily page, with its own
                        // view model over the same per-day cache:
                        // the full 20 (not home's first 10), with
                        // play-all and "换一首" built in.
                        MusicDailyView()
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
                // stayed stale until the next tab switch. Debounced,
                // not direct: one user action can post several of
                // these, and each used to pay for a full reload.
                .onReceive(NotificationCenter.default.publisher(for: .haoMusicRecentChanged)) { _ in
                    viewModel.reloadForNotification()
                }
                // Video-history change (A1): a film watched from the
                // player, or a history row removed/cleared from the
                // pushed list, posts haoVideoHistoryChanged — home's
                // 继续观看 reloads without waiting for a tab switch
                // or pop-back.
                .onReceive(NotificationCenter.default.publisher(for: .haoVideoHistoryChanged)) { _ in
                    viewModel.reloadForNotification()
                }
                // Live-history change (A2): entering a room, or a
                // history row removed/cleared from the pushed list,
                // posts haoLiveHistoryChanged — home's 我的直播
                // reloads without waiting for a tab switch or
                // pop-back.
                .onReceive(NotificationCenter.default.publisher(for: .haoLiveHistoryChanged)) { _ in
                    viewModel.reloadForNotification()
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
                // b49fix2 B10: section titles are headers.
                .accessibilityAddTraits(.isHeader)
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
                // b49fix2 B10: "全部" alone tells VoiceOver
                // nothing — name the section it opens.
                .accessibilityLabel("查看全部\(title)")
            }
        }
        .padding(.horizontal, 24)
    }

    /// b49fix2 B1: an empty state always offers a way forward —
    /// a capsule button that switches to the tab where the user
    /// can fill it. The shell (MainTabView) listens for
    /// .haoSwitchTab.
    private func homeEmptyCTA(label: String, icon: String, tab: HaoTab) -> some View {
        MusicCapsuleButton(icon: icon, label: label) {
            NotificationCenter.default.post(name: .haoSwitchTab, object: tab)
        }
        .padding(.top, 6)
    }

    /// b49fix2 B4: first-run hint, shown only while every
    /// section is empty (a fresh install) and never again once
    /// dismissed. Minimal — one card, no new system, no
    /// onboarding flow.
    @ViewBuilder
    private var welcomeCard: some View {
        if !welcomeDismissed,
           viewModel.continueWatching.isEmpty,
           viewModel.continueListening.isEmpty,
           viewModel.hotLive.isEmpty,
           viewModel.daily.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("从搜索开始")
                    .font(.haoSectionTitle)
                    .foregroundStyle(theme.textPrimary)
                Text("去音乐搜一首歌，或去影视找一部影片——播过的都会出现在这里。")
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textSecondary)
                HStack(spacing: 16) {
                    MusicCapsuleButton(icon: "music.note", label: "去音乐") {
                        NotificationCenter.default.post(name: .haoSwitchTab, object: HaoTab.music)
                    }
                    MusicCapsuleButton(icon: "film", label: "去影视") {
                        NotificationCenter.default.post(name: .haoSwitchTab, object: HaoTab.movies)
                    }
                }
                HStack(spacing: 16) {
                    // b49fix3 P1-14: first-run guidance — one
                    // source-configuration action, no new
                    // onboarding flow. Opens My → 设置 → 来源管理.
                    // b49fix4 P2-26: a capsule like the row above —
                    // the plain-text button read weaker than the
                    // action it is. "不再显示" stays text (it is a
                    // dismiss, not an action). b49fix4 P2-37:
                    // stateful deep link — set the row BEFORE the
                    // tab switch; the old 0.35s delayed post could
                    // land before the My tab mounted and be lost.
                    MusicCapsuleButton(icon: "slider.horizontal.3", label: "配置歌源/片源") {
                        SettingsDeepLink.shared.open(row: "sources")
                        NotificationCenter.default.post(name: .haoSwitchTab, object: HaoTab.my)
                    }
                    Button("不再显示") {
                        welcomeDismissed = true
                    }
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(16)
            .background(theme.accentSoft, in: RoundedRectangle(cornerRadius: HaoLayout.cornerLarge, style: .continuous))
            .padding(.horizontal, 24)
            .padding(.top, 12)
        }
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
            .font(.haoScreenTitle)
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            // b49fix2 B10: the in-content page title is a header.
            .accessibilityAddTraits(.isHeader)
    }

    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "继续观看", onAll: { path.append(.history) })
            if viewModel.continueWatching.isEmpty {
                VStack(spacing: 0) {
                    MusicEmptyState(
                        icon: "film",
                        title: "还没有看过影片",
                        note: "看过的影片会出现在这里，点一下继续看"
                    )
                    homeEmptyCTA(label: "去找影片", icon: "film", tab: .movies)
                }
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
                VStack(spacing: 0) {
                    MusicEmptyState(
                        icon: "music.note",
                        title: "还没有听过歌",
                        note: "播过的歌会出现在这里，点一下继续听"
                    )
                    homeEmptyCTA(label: "去听歌", icon: "music.note", tab: .music)
                }
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
            // b49fix2 A15: this list is follows + history, not
            // hot rooms — the honest name is 我的直播.
            sectionHeader(title: "我的直播", onAll: { path.append(.hotLive) })
            if viewModel.hotLive.isEmpty {
                VStack(spacing: 0) {
                    MusicEmptyState(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "暂无直播",
                        note: "去直播里关注主播，开播后会出现在这里"
                    )
                    homeEmptyCTA(label: "去直播", icon: "antenna.radiowaves.left.and.right", tab: .live)
                }
                .padding(.horizontal, 24)
            } else {
                LazyVGrid(columns: liveGridColumns, spacing: LiveGridLayout.gridRowSpacing) {
                    ForEach(viewModel.hotLive, id: \.id) { item in
                        let room = homeLiveRoom(from: item)
                        LiveRoomCard(room: room) {
                            openRoom(room, playlist: hotLiveRooms)
                        }
                    }
                }
                .padding(.horizontal, LiveGridLayout.gridEdgePadding)
                // b49fix2 B13: the laid-out width reports up
                // through this background reader (attached after
                // the padding, so it measures the container
                // width, not the grid width).
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: HomeLiveGridWidthKey.self, value: geo.size.width)
                    }
                )
                .onPreferenceChange(HomeLiveGridWidthKey.self) { liveGridWidth = $0 }
                // b49fix3 P1-9: the status round failed for every
                // room — the missing LIVE badges are a check
                // failure, not "all offline". Retry re-checks
                // (pull-to-refresh does the same, but this says
                // so where the user is looking).
                if viewModel.liveStatusFailed {
                    Button("直播状态查不到，重试") {
                        viewModel.reload(forceLiveRecheck: true)
                    }
                    // b49fix4 P2-6: 13 medium inline retry, top 12
                    // — the same as every other inline text retry
                    // (Live's merged lane set the shared top to 12).
                    .font(.haoFootnoteMedium)
                    .foregroundStyle(theme.accentText)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .accessibilityLabel("重试检查直播状态")
                }
            }
        }
    }

    /// The live grid's columns from the laid-out container width
    /// (b49fix2 B13). Falls back to the screen width on the first
    /// frame, before the preference fires.
    private var liveGridColumns: [GridItem] {
        let width = liveGridWidth > 0 ? liveGridWidth : UIScreen.main.bounds.width
        return homeLiveGridColumns(forWidth: width)
    }

    private var hotLiveRooms: [LiveRoom] {
        viewModel.hotLive.map { homeLiveRoom(from: $0) }
    }

    // MARK: - Daily picks

    private var dailySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Own header, not sectionHeader: daily also needs a
            // play-all capsule next to "全部". Both hide while the
            // list is empty — play-all on an empty list is a dead
            // button, and "全部" would open an empty daily page.
            HStack {
                Text("每日推荐")
                    .font(.haoSectionTitle)
                    .foregroundStyle(theme.textPrimary)
                    // b49fix2 B10: section title is a header.
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !viewModel.allDailyPicks.isEmpty {
                    Button(action: {
                        playerVM.playAll(
                            viewModel.allDailyPicks,
                            source: PlaySource(kind: .daily, id: "daily"),
                            sourceDisplayName: "每日推荐")
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.haoCaption2)
                            Text("播放全部")
                                .font(.haoDenseBody)
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(theme.accentText)
                    // b49fix2 B10: name what the button plays.
                    .accessibilityLabel("播放全部每日推荐")
                    Button(action: { path.append(.daily) }) {
                        HStack(spacing: 2) {
                            Text("全部")
                                .font(.haoDenseBody)
                            Image(systemName: "chevron.right")
                                .font(.haoCaption2)
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(theme.accentText)
                    // b49fix2 B10: name the section it opens.
                    .accessibilityLabel("查看全部每日推荐")
                }
            }
            .padding(.horizontal, 24)
            if viewModel.daily.isEmpty {
                VStack(spacing: 0) {
                    MusicEmptyState(
                        icon: "calendar",
                        title: "今天还没有推荐",
                        note: "先收藏几首歌或播几首歌，每日推荐会从你听过的歌里挑"
                    )
                    homeEmptyCTA(label: "去听歌", icon: "music.note", tab: .music)
                }
                .padding(.horizontal, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.daily.enumerated()), id: \.element.id) { index, song in
                        // Queue = the full 20, not the section's
                        // first 10: pressing next on the 10th row
                        // carries on into picks 11–20 instead of
                        // stopping. Same order, so the index holds.
                        HStack(spacing: 8) {
                            songRow(song: song, tracks: viewModel.allDailyPicks, index: index, source: PlaySource(kind: .daily, id: "daily"), sourceDisplayName: "每日推荐")
                            if !viewModel.dailySpares.isEmpty {
                                Button("换一首") {
                                    viewModel.replaceDailySong(song)
                                }
                                .font(.haoFootnoteStrong)
                                .foregroundStyle(theme.accentText)
                                .accessibilityLabel("不喜欢《\(song.title)》，换一首")
                            }
                        }
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
            showFavHeart: true,
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
/// of dropping the tap. The confirmed watching count rides
/// along (0 = never confirmed — the card hides it) — the old
/// build dropped it, so home cards never showed a count.
/// File scope (not a HomeView method)
/// so the home hot-live page below can build rooms too.
fileprivate func homeLiveRoom(from item: HomeLiveItem) -> LiveRoom {
    LiveRoom(
        roomId: item.roomId,
        platform: homeLivePlatform(from: item.platform),
        title: item.title,
        streamer: item.nick,
        cover: item.cover,
        onlineCount: item.onlineCount,
        isLive: item.isLive
    )
}

/// Live grid columns for a container of the given width: 2 in
/// portrait, 3–4 when the container is wide (landscape phone
/// / iPad) — the fixed 2-column grid left tall 16:9 cells and
/// the floating chrome eating a third of a landscape screen.
/// Same width math as LiveGridLayout.columns(forWidth:); the
/// GridItem array itself lives here because LiveDataGateway is
/// Foundation-only (AppCore) and cannot build SwiftUI items.
/// b49fix2 B13: the width comes from the layout (preference
/// key), not UIScreen.main.bounds — the screen width goes
/// stale on rotation and Split View, so the grid kept the
/// wrong column count until relaunch. The argument is the
/// container width (the reader sits outside the grid padding).
/// At 320pt (SE) this still yields 2 columns of 130pt cells —
/// no overflow.
fileprivate func homeLiveGridColumns(forWidth width: CGFloat) -> [GridItem] {
    let count = LiveGridLayout.columns(forWidth: Double(width))
    return Array(
        repeating: GridItem(.flexible(minimum: 0), spacing: CGFloat(LiveGridLayout.interItemSpacing)),
        count: count
    )
}

/// Reports a live grid's laid-out container width up the tree
/// (b49fix2 B13).
private struct HomeLiveGridWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Bottom clearance inside home's scroll content, landscape-
/// aware: the same value and mini-visibility rule as
/// haoBottomChromeContentPadding (one source of truth:
/// HaoLayout.floatingStackClearance), except in landscape the
/// 12pt breathing room is reclaimed — the floating stack is the
/// same height, so the clearance never drops below it and the
/// last row still clears the chrome exactly, while a ~393pt-tall
/// viewport keeps 12pt more content above the fold. Portrait is
/// byte-identical to the stock modifier.
private struct HomeBottomClearance: ViewModifier {
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var musicPlayer: MusicPlayerViewModel
    var isLandscape: Bool

    func body(content: Content) -> some View {
        let miniVisible = coordinator.currentItem != nil || musicPlayer.miniFallbackSong != nil
        let clearance = HaoLayout.floatingStackClearance(miniPlayerVisible: miniVisible)
        content.padding(
            .bottom,
            isLandscape ? clearance - HaoLayout.contentBreathingRoom : clearance
        )
    }
}

extension View {
    fileprivate func haoBottomClearanceLandscapeAware(isLandscape: Bool) -> some View {
        modifier(HomeBottomClearance(isLandscape: isLandscape))
    }
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
                    MusicCoverView(urlString: song.cover, size: 120, cornerRadius: HaoLayout.cornerMedium)
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
    /// b49fix2 B13: this page's own laid-out grid width (same
    /// preference-key pattern as the home section).
    @State private var liveGridWidth: CGFloat = 0

    private var rooms: [LiveRoom] {
        viewModel.hotLive.map { homeLiveRoom(from: $0) }
    }

    var body: some View {
        Group {
            if viewModel.hotLive.isEmpty {
                VStack(spacing: 0) {
                    MusicEmptyState(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "暂无直播",
                        note: "去直播里关注主播，开播后会出现在这里"
                    )
                    // b49fix3 P1-10: the "全部" empty page gets
                    // the same way forward as the section — a
                    // capsule to the live tab. (homeEmptyCTA is
                    // HomeView-private, so the equivalent is
                    // inlined here.)
                    MusicCapsuleButton(icon: "antenna.radiowaves.left.and.right", label: "去直播") {
                        NotificationCenter.default.post(name: .haoSwitchTab, object: HaoTab.live)
                    }
                    .padding(.top, 6)
                }
                .haoBottomChromePadding()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        LazyVGrid(columns: homeLiveGridColumns(forWidth: liveGridWidth > 0 ? liveGridWidth : UIScreen.main.bounds.width), spacing: LiveGridLayout.gridRowSpacing) {
                            ForEach(viewModel.hotLive, id: \.id) { item in
                                let room = homeLiveRoom(from: item)
                                LiveRoomCard(room: room) {
                                    openRoom(room, rooms)
                                }
                            }
                        }
                        .padding(.horizontal, LiveGridLayout.gridEdgePadding)
                        .padding(.top, 12)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(key: HomeLiveGridWidthKey.self, value: geo.size.width)
                            }
                        )
                        .onPreferenceChange(HomeLiveGridWidthKey.self) { liveGridWidth = $0 }
                        Spacer(minLength: 16)
                    }
                }
                .haoBottomChromePadding()
            }
        }
        .background(theme.scaffoldBackground)
        // b49fix2 A15: follows + history, not hot rooms.
        .navigationTitle("我的直播")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// HAo Studio 2.0 — app shell: 5-tab navigation.
//
// Tabs: Home / Music / Movies / Live / My（首页/音乐/影视/直播/我的，
// chen 2026-11-23 定，按任务书顺序；脚手架原先是 Home/Movies/Live/
// Music/My，已在 S0 按任务书改过来）. My IS the settings page —
// there is no separate settings destination.
//
// The floating stack (mini player above the glass tab bar) lives in a
// bottom safe-area inset, so the bar sits just above the home
// indicator and the mini player is simply the first row of the same
// stack — the two can never overlap each other. The inset positions
// the stack, but it does NOT inset tab content: the content sits in a
// NavigationStack, whose UIKit navigation controller owns the safe
// area there, so on device (chen 2026-11-24 build 33) the last rows
// slid under the bar and could not be dragged into view. The five
// tab roots therefore add their own bottom clearance INSIDE their
// scroll content (haoBottomChromeContentPadding(), b40 —
// safeAreaPadding on the ScrollView never reached the content, and
// the last row stayed under the chrome on build 39), sized to the
// stack height above the safe-area bottom edge. Pushed pages keep
// haoBottomChromePadding() (safeAreaPadding). No tab content relies
// on this inset for clearance.
//
// No TabView is used: the built-in tab bar cannot be replaced by a
// floating capsule. The selected tab is plain @State; switching is a
// content swap (the player slice keeps this — the coordinator, not the
// tab view, owns what keeps playing across tabs).

import SwiftUI
import UIKit

enum HaoTab: String, CaseIterable, Identifiable {
    case home
    case music
    case movies
    case live
    case my

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .music: return "音乐"
        case .movies: return "影视"
        case .live: return "直播"
        case .my: return "我的"
        }
    }

    /// SF Symbols icon (Apple-native; no custom tab art in the foundation).
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .music: return "music.note"
        case .movies: return "film.fill"
        case .live: return "antenna.radiowaves.left.and.right"
        case .my: return "person.fill"
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var musicPlayer: MusicPlayerViewModel
    @EnvironmentObject private var immersiveChrome: ImmersiveChromeState
    @EnvironmentObject private var bottomChrome: BottomChromeState
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedTab: HaoTab = .home
    @State private var showingFullPlayer = false
    /// Wallpaper image cache (build 36, item 10): the background
    /// used to re-read the wallpaper file from disk on EVERY
    /// body evaluation (tab switch, theme switch, chrome
    /// minimise). One UIImage, keyed by the file URL it was
    /// loaded from — reloaded only when the wallpaper changes
    /// (switch / new pick), never per body. A failed load caches
    /// nil under the same URL so a missing file is not retried
    /// on every frame either. Deliberately a single image, not
    /// a cache of many: only one wallpaper is ever on screen.
    @State private var cachedWallpaper: UIImage?
    @State private var cachedWallpaperURL: URL?
    /// Namespace for the cover morph: the mini cover grows into the
    /// full player's cover (matchedGeometryEffect, id
    /// HaoLayout.playerCoverMorphID). Owned here so the mini and the
    /// presented player share one namespace.
    @Namespace private var playerMorph

    private var tabBarItems: [GlassTabBarItem] {
        HaoTab.allCases.map { GlassTabBarItem(tab: $0, title: $0.title, icon: $0.icon) }
    }

    /// The bottom chrome (b39: restored to the original system
    /// UITabBar menu from build 34/35, commit 40d5bf6) — chen
    /// 2026-11-25: "菜单栏就用之前刚开发的时候那样子不就好了吗".
    /// The b38 SwiftUI UnionTabView bar is gone: its chromeBottomOffset
    /// drop pushed the whole unit 26pt below the safe-area edge on
    /// Face ID iPhones, so taps fell through to the page below.
    /// The mini (40pt) sits directly above the bar, VStack spacing
    /// 13 (b43: the bar's glass renders ~13pt above its frame, so
    /// the 13pt frame gap is what makes the GLASS edges touch) —
    /// one connected unit, same width, same margins. The bar
    /// sits 2pt above the safe-area bottom edge (tabBarBottomMargin),
    /// fully inside the hit-testable safe area. The b35
    /// scroll-minimize stays reverted (build 37, chen: "菜单恢复原样"
    /// — the menu is always the original full glass tab bar, no
    /// narrowed capsule form).
    private var bottomChromeContent: some View {
        VStack(spacing: HaoLayout.floatingStackSpacing) {
            MiniPlayerBar(onTapFullPlayer: { showingFullPlayer = true }, morphNamespace: playerMorph)
            GlassTabBar(
                items: tabBarItems,
                selection: $selectedTab,
                // chrome O1: tapping the already-selected tab
                // scrolls that tab's own list back to the top.
                // The five tab roots listen for this
                // notification; nothing else does.
                onReselect: { tab in
                    NotificationCenter.default.post(name: .haoTabReselected, object: tab)
                },
                tabAccent: settingsStore.tabAccentColor
            )
        }
    }

    var body: some View {
        // The palette is resolved from the EFFECTIVE scheme and pushed
        // into the environment here, so a theme/mode switch re-renders
        // every tab immediately with no restart.
        let palette = themeStore.palette(for: colorScheme)
        ZStack {
            backgroundLayer(palette: palette)
            // b36-8: tab switches crossfade (Apple Music: content
            // cross-dissolves, no sideways slide), 200ms ease-out.
            // The outgoing tab is static during the fade, so its
            // scroll anchor cannot flip the chrome mid-transition.
            tabContent
                .transition(.opacity)
                .animation(.easeOut(duration: 0.2), value: selectedTab)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Immersive pages (a live room pushed inside a tab)
            // hide the whole bottom chrome — mini player + glass
            // tab bar — while they are up, so the room's own bottom
            // bar is never covered by it. Tab pages are unaffected;
            // the chrome comes back when the room exits. The glass
            // itself is untouched — hidden, never restyled.
            if !immersiveChrome.isImmersive {
                bottomChromeContent
                    .padding(.horizontal, HaoLayout.tabBarHorizontalMargin)
                    .padding(.bottom, HaoLayout.tabBarBottomMargin)
                    // Full-player morph: as the player expands, the
                    // chrome fades and slides away with it instead of
                    // vanishing the instant the cover starts up — and
                    // fades back in as the player collapses. The
                    // cover itself morphs via matchedGeometryEffect
                    // (MiniPlayerBar / MusicPlayerView, same
                    // namespace); this fade is the tab bar's half of
                    // the same transition, on the same spring.
                    // (b39: no chromeBottomOffset any more — the
                    // stack sits inside the safe area, so the only
                    // offset here is the full-player slide.)
                    .opacity(showingFullPlayer ? 0 : 1)
                    .offset(y: showingFullPlayer ? 24 : 0)
                    .animation(HaoLayout.settleSpring, value: showingFullPlayer)
            }
        }
        .fullScreenCover(isPresented: $showingFullPlayer) {
            // S2-C: a music item opens the real full player.
            // The mini can show a loaded music song while the
            // coordinator has no current item (failed / stopped
            // track): opening from the mini must land on that
            // song's player, not the "cannot play" placeholder.
            // S3-C: a VOD item re-opens the video player (tap-play
            // on the detail page presents it directly; the mini
            // player re-opens it here). S4: a live item re-opens
            // the room page, rebuilt from the playing item.
            if coordinator.currentItem?.kind == .music
                || (coordinator.currentItem == nil && musicPlayer.miniFallbackSong != nil) {
                MusicPlayerView(isPresented: $showingFullPlayer, coverMorphNamespace: playerMorph)
            } else if coordinator.currentItem?.kind == .vod {
                VideoPlayerView()
            } else if coordinator.currentItem?.kind == .live,
                      let item = coordinator.currentItem,
                      let room = MainTabView.liveRoom(from: item) {
                LiveRoomView(room: room, playlist: [room])
            } else {
                FullPlayerPlaceholderView()
            }
        }
        .environment(\.haoTheme, palette)
        // b41: tells the five tab roots which backdrop to draw
        // behind their own content (haoBackdropLayer) — resolved
        // once here from the same background-kind decision, so all
        // roots draw the same backdrop. The picture / colour no
        // longer lives in this view's ZStack: b40 drew it behind
        // the tab roots, where the NavigationStacks' opaque
        // backgrounds covered it, and the image here also pushed
        // the bottom chrome off the screen on device.
        .environment(\.haoBackdrop, backdrop)
        // b36-1: each tab has its own scroll rest offset — forget
        // the previous tab's so the new tab calibrates from scratch
        // (isAtTop for the reselect scroll-to-top guard).
        .onChange(of: selectedTab) { _ in bottomChrome.resetRest() }
        // Wallpaper cache (build 36, item 10): load once on
        // appear and whenever the switch or the picked file
        // changes — never during body evaluation.
        .onAppear { refreshWallpaperCache() }
        .onChange(of: settingsStore.wallpaperEnabled) { _ in refreshWallpaperCache() }
        .onChange(of: settingsStore.wallpaperCurrent) { _ in refreshWallpaperCache() }
    }

    /// Scaffold background behind everything (b41): the wallpaper
    /// photo and the custom background colour are drawn inside the
    /// tab roots now (haoBackdropLayer), so this layer is just the
    /// opaque theme scaffold. It can never cover a backdrop, and
    /// no image sits in this view's ZStack any more — the b40
    /// image here pushed the bottom chrome off the screen on
    /// device while the wallpaper was on.
    private func backgroundLayer(palette: HaoThemePalette) -> some View {
        palette.scaffoldBackground.ignoresSafeArea()
    }

    /// The backdrop the tab roots draw (b41): resolved once from
    /// the background-kind decision, so every tab root draws the
    /// same backdrop. Wallpaper wins when the switch is on and the
    /// image loaded; otherwise the custom colour; otherwise theme.
    private var backdrop: HaoBackdrop {
        HaoBackdrop.resolve(
            wallpaperEnabled: settingsStore.wallpaperEnabled,
            wallpaperImage: cachedWallpaper,
            bgColorEnabled: settingsStore.bgColorEnabled,
            bgColorHex: settingsStore.bgColorHex
        )
    }

    /// Load the wallpaper image into the cache when it is
    /// enabled and its URL moved (or nothing is cached yet).
    /// No-op otherwise — in particular, body re-evaluations
    /// never reach the disk through here.
    private func refreshWallpaperCache() {
        guard settingsStore.wallpaperEnabled,
              let wallpaperURL = settingsStore.wallpaperBackgroundURL else {
            cachedWallpaper = nil
            cachedWallpaperURL = nil
            return
        }
        guard cachedWallpaperURL != wallpaperURL else { return }
        cachedWallpaperURL = wallpaperURL
        cachedWallpaper = UIImage(contentsOfFile: wallpaperURL.path)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .home: HomeView()
        case .music: MusicHomeView()
        case .movies: VideoTabView()
        case .live: LiveTabView(gateway: LiveDataGatewayAdapter.shared)
        case .my: MyView()
        }
    }

    /// Rebuild a room from the playing live item: the id is
    /// "platform:roomId" (LiveDriver.playbackItem), the title /
    /// artist / cover come from the item. The room page fetches
    /// roomInfo on entry for the transport credentials and the
    /// watching count, so a minimal room is enough to re-enter.
    /// Nil when the id is not a live room id.
    static func liveRoom(from item: PlaybackItem) -> LiveRoom? {
        let parts = item.id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let platform = LivePlatform(rawValue: String(parts[0])) else {
            return nil
        }
        return LiveRoom(
            roomId: String(parts[1]), platform: platform,
            title: item.title, streamer: item.artist ?? "",
            cover: item.coverURL?.absoluteString ?? "")
    }
}

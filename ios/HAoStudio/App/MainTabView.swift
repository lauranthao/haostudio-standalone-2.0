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
// slid under the bar and could not be dragged into view. Every
// vertical scroll page under the stack therefore adds its own bottom
// clearance from HaoLayout (haoBottomChromePadding()), sized to the
// stack height above the safe-area bottom edge. No tab content relies
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
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedTab: HaoTab = .home
    @State private var showingFullPlayer = false

    private var tabBarItems: [GlassTabBarItem] {
        HaoTab.allCases.map { GlassTabBarItem(tab: $0, title: $0.title, icon: $0.icon) }
    }

    var body: some View {
        // The palette is resolved from the EFFECTIVE scheme and pushed
        // into the environment here, so a theme/mode switch re-renders
        // every tab immediately with no restart.
        let palette = themeStore.palette(for: colorScheme)
        ZStack {
            backgroundLayer(palette: palette)
            tabContent
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: HaoLayout.floatingStackSpacing) {
                // Beans dock: the mini player shares the tab bar's
                // 12pt side margins (it used to span full width,
                // which read wider — and taller — than the bar).
                MiniPlayerBar(onTapFullPlayer: { showingFullPlayer = true })
                    .padding(.horizontal, HaoLayout.tabBarHorizontalMargin)
                GlassTabBar(items: tabBarItems, selection: $selectedTab, tabAccent: settingsStore.tabAccentColor)
                    .padding(.horizontal, HaoLayout.tabBarHorizontalMargin)
            }
            .padding(.bottom, HaoLayout.tabBarBottomMargin)
        }
        .fullScreenCover(isPresented: $showingFullPlayer) {
            // S2-C: a music item opens the real full player.
            // S3-C: a VOD item re-opens the video player (tap-play
            // on the detail page presents it directly; the mini
            // player re-opens it here). S4: a live item re-opens
            // the room page, rebuilt from the playing item.
            if coordinator.currentItem?.kind == .music {
                MusicPlayerView(isPresented: $showingFullPlayer)
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
    }

    /// Scaffold background, three-layer priority (S5-C):
    /// wallpaper > background color > theme scaffold. A wallpaper
    /// that cannot be loaded falls through to the next layer.
    @ViewBuilder
    private func backgroundLayer(palette: HaoThemePalette) -> some View {
        let wallpaper = wallpaperImage()
        switch MyBackgroundColor.kind(
            wallpaperEnabled: settingsStore.wallpaperEnabled,
            wallpaperAvailable: wallpaper != nil,
            bgColorEnabled: settingsStore.bgColorEnabled,
            bgColorHex: settingsStore.bgColorHex
        ) {
        case .wallpaper:
            if let wallpaper = wallpaper {
                Image(uiImage: wallpaper)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                palette.scaffoldBackground.ignoresSafeArea()
            }
        case .color:
            if let bgColor = MyBackgroundColor.color(fromHex: settingsStore.bgColorHex) {
                bgColor.ignoresSafeArea()
            } else {
                palette.scaffoldBackground.ignoresSafeArea()
            }
        case .theme:
            palette.scaffoldBackground.ignoresSafeArea()
        }
    }

    /// The wallpaper image when enabled and loadable, nil otherwise.
    private func wallpaperImage() -> UIImage? {
        guard settingsStore.wallpaperEnabled,
              let wallpaperURL = settingsStore.wallpaperBackgroundURL else {
            return nil
        }
        return UIImage(contentsOfFile: wallpaperURL.path)
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

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
    /// Metered-download prompt (b45-h, P8 #7): the download
    /// engine fires `onMeteredConfirmationNeeded` once per task;
    /// this object queues the prompts for the dialog below.
    /// A @StateObject (not @State) because the engine's callback
    /// is a stored closure that outlives one body evaluation.
    @StateObject private var meteredPrompt = MeteredDownloadPromptState()
    /// First-launch disclaimer gate (b45-h, 包 C leftover b):
    /// HAoStudioApp posts `.haoShowDisclaimerGate` after the
    /// splash when the stored disclaimer version is not current.
    @State private var showDisclaimerGate = false
    /// One-time storage notice (b49fix2 P1-13): LocalStore posts
    /// .haoStoreSaveFailed / .haoStoreQuarantined when a save
    /// fails or a corrupt file is quarantined; the shell surfaces
    /// it once here instead of leaving 27 call sites each
    /// ignoring the failure.
    @State private var storeNotice: String?
    /// One-time backup nudge (b49fix2 B5): offered after the
    /// first favourite or download.
    @State private var showingBackupNudge = false
    /// The five tab roots, kept alive (b49sweep P1): every tab
    /// mounts once — on first visit — and then stays mounted,
    /// hidden with opacity 0 when it is not selected. The old
    /// content swap rebuilt HomeView()/MusicHomeView()/… on
    /// every selection change, which destroyed the tab's
    /// NavigationStack path, its scroll position and its
    /// @StateObject view model (HomeView's path + viewModel
    /// live inside the destroyed view): push a video detail,
    /// switch tabs and back, and the detail was gone, Home was
    /// back at the top, and the live-status throttle state was
    /// gone so up to 10 room-info requests re-fired. Mounting
    /// lazily (not all five at launch) keeps launch free of
    /// the other tabs' onAppear loads; once mounted, a tab's
    /// onAppear reloads no longer re-fire on return — Home's
    /// return-to-root refresh is path-driven (onChange of
    /// path), so it is unaffected. Hidden tabs cannot be
    /// tapped, are disabled, and leave the accessibility tree.
    @State private var mountedTabs: Set<HaoTab> = [.home]

    private var tabBarItems: [GlassTabBarItem] {
        HaoTab.allCases.map { GlassTabBarItem(tab: $0, title: $0.title, icon: $0.icon) }
    }

    /// The metered dialog's presentation binding (b45-h): the
    /// dialog shows while a prompt is pending. Dismissing it
    /// without choosing (tap outside) counts as "等待 Wi-Fi" —
    /// the task is held, never silently approved or cancelled
    /// (see MeteredDownloadPromptState.dialogDismissed).
    private var meteredDialogBinding: Binding<Bool> {
        return Binding(
            get: { meteredPrompt.pending != nil },
            set: { newValue in
                if !newValue { meteredPrompt.dialogDismissed() }
            }
        )
    }

    /// The disclaimer gate's presentation binding (b45-h, 包 C
    /// leftover b): the gate can only close by accepting — the
    /// 同意 button stores the current version first (a
    /// synchronous UserDefaults write), so its dismiss closes
    /// the gate. Any other dismiss (不同意, or a swipe) NEVER
    /// exits the app (b49sweep: exit(0) on decline killed the
    /// app with no way back) — the gate simply stays presented
    /// until the user accepts. The decline alert's button in
    /// DisclaimerView now reads "不同意" (reworded b49sweep:
    /// it never exited); the behaviour here is: decline = stay.
    private var disclaimerGateBinding: Binding<Bool> {
        return Binding(
            get: { showDisclaimerGate },
            set: { newValue in
                if newValue {
                    showDisclaimerGate = true
                } else if DisclaimerGate.isAccepted(storedVersion: settingsStore.disclaimerAcceptedVersion) {
                    showDisclaimerGate = false
                    // b49fix2 P2-25: the gate just closed with
                    // acceptance — flush a held auto-check result
                    // now (never before: the update prompt must
                    // not overlap the gate).
                    if let pending = BackupUpdateFlow.shared.pendingAutoUpdateResult {
                        BackupUpdateFlow.shared.pendingAutoUpdateResult = nil
                        BackupUpdateFlow.shared.updatePrompt = pending
                        BackupUpdateFlow.shared.showingUpdatePrompt = true
                    }
                } else {
                    showDisclaimerGate = true
                }
            }
        )
    }

    /// b49fix2 B5: one-time backup nudge after the first
    /// favourite or download — the disclaimer is honest that a
    /// reinstall loses everything, but nothing ever suggested a
    /// backup. Shows once per install, never while the
    /// disclaimer gate is up, and never after the user has
    /// exported once (beginExport records that flag).
    private func maybeShowBackupNudge() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "hao_backup_nudge_shown"),
              !defaults.bool(forKey: "hao_backup_exported_once"),
              !showDisclaimerGate else { return }
        // b49fix3 P2-23: the shown flag is written only when the
        // user has seen / dismissed the alert (in its button
        // actions below), not here — writing it before presenting
        // marked the nudge shown even if the app died first.
        showingBackupNudge = true
    }

    /// The bottom chrome (b39: restored to the original system
    /// UITabBar menu from build 34/35, commit 40d5bf6) — chen
    /// 2026-11-25: "菜单栏就用之前刚开发的时候那样子不就好了吗".
    /// The b38 SwiftUI UnionTabView bar is gone: its chromeBottomOffset
    /// drop pushed the whole unit 26pt below the safe-area edge on
    /// Face ID iPhones, so taps fell through to the page below.
    /// b46-chrome (Coda §6.2 whole set, chen 2026-11-25 14:36):
    /// tab bar 64, mini 52, spacing 8, side margins 16, bottom
    /// margin 6 — the 13pt b43 glass compensation is deleted with
    /// the set (it patched the 56pt frame's glass overhang; the
    /// Coda set is self-consistent without it). The mini sits
    /// directly above the bar, VStack spacing 8 — two separate
    /// pills, same width, same margins. The bar sits 6pt above
    /// the safe-area bottom edge (tabBarBottomMargin), fully
    /// inside the hit-testable safe area. The b35 scroll-minimize
    /// stays reverted (build 37, chen: "菜单恢复原样" — the menu is
    /// always the original full glass tab bar, no narrowed
    /// capsule form). Rollback if the device check fails: the
    /// whole b43 set (56/13/40, side 12, bottom 2).
    private var bottomChromeContent: some View {
        VStack(spacing: HaoLayout.floatingStackSpacing) {
            MiniPlayerBar(onTapFullPlayer: {
                // b45-g (Coda §8.1 CoverZoomMotion.open): the expand
                // runs on the open spring (response 0.5 / damping
                // 0.94). The token existed since b45-a but nothing
                // used it — the cover presented with the system
                // default. The chrome fade keeps its own
                // settleSpring (b39 chain, untouched).
                withAnimation(HaoPlayerMotion.playerOpen) { showingFullPlayer = true }
            }, morphNamespace: playerMorph)
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
            // The crossfade lives on tabContent itself now
            // (b49sweep keep-alive ZStack); the outgoing tab is
            // static during the fade, so its scroll anchor cannot
            // flip the chrome mid-transition.
            tabContent
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
                    // b46-chrome (P7): the expand / collapse has a
                    // gated selection tick — the mini's own buttons
                    // already tick through the player VM, but the
                    // strip tap / swipe-up / chevron had no tactile
                    // answer at all, so a tap that opened the player
                    // felt unanswered. Gated by the 触感反馈 switch
                    // (haoSensoryFeedback), fires on both directions.
                    .haoSensoryFeedback(.selection, trigger: showingFullPlayer)
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
                // b49sweep: the placeholder now offers Retry +
                // Clear (see FullPlayerPlaceholderView). Retry
                // dismisses and re-presents after the dismiss
                // animation, so the branch above re-evaluates
                // against the coordinator's current item — if it
                // became playable, the real player opens.
                FullPlayerPlaceholderView(onRetry: {
                    showingFullPlayer = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        showingFullPlayer = true
                    }
                })
            }
        }
        .fullScreenCover(isPresented: disclaimerGateBinding) {
            // Non-dismissable until accepted (b49sweep): a swipe
            // down must not dodge the gate, and the binding
            // setter above refuses a non-accepted dismiss.
            DisclaimerView(mode: .gate)
                .interactiveDismissDisabled()
        }
        .confirmationDialog(
            "使用移动数据下载？",
            isPresented: meteredDialogBinding,
            presenting: meteredPrompt.pending
        ) { prompt in
            Button("继续下载") {
                meteredPrompt.resolveCurrent { DownloadEngine.shared.approveMetered(key: $0.request.key) }
            }
            Button("等待 Wi-Fi") {
                meteredPrompt.resolveCurrent { DownloadEngine.shared.holdMetered(key: $0.request.key) }
            }
            Button("取消", role: .cancel) {
                meteredPrompt.resolveCurrent { DownloadEngine.shared.denyMetered(key: $0.request.key) }
            }
        } message: { prompt in
            Text("当前网络按流量计费（移动数据、热点或低数据模式），下载“\(prompt.title)”会消耗流量。")
        }
        // b49fix2 P1-13: the one-time storage notice.
        .alert("存储提示", isPresented: Binding(get: { storeNotice != nil }, set: { if !$0 { storeNotice = nil } }), presenting: storeNotice) { _ in
            Button("知道了", role: .cancel) {}
        } message: { notice in
            Text(notice)
        }
        // b49fix2 B5: the one-time backup nudge. "去备份" opens
        // the My tab, where the backup rows live in Settings.
        .alert("备份一次更安心", isPresented: $showingBackupNudge) {
            Button("去备份") {
                // b49fix3 P2-23: the user has now seen the nudge.
                UserDefaults.standard.set(true, forKey: "hao_backup_nudge_shown")
                // b49fix4 P2-37: stateful deep link — set the row
                // BEFORE switching tab. The old 0.35s delayed
                // post could land before the My tab mounted and
                // be lost silently; the store keeps the row until
                // MyView / SettingsGroupsView consume it.
                SettingsDeepLink.shared.open(row: "backup")
                mountedTabs.insert(.my)
                selectedTab = .my
            }
            Button("以后再说", role: .cancel) {
                // b49fix3 P2-23: dismissed counts as seen — the
                // nudge is one-time per install either way.
                UserDefaults.standard.set(true, forKey: "hao_backup_nudge_shown")
            }
        } message: {
            Text("收藏和下载只保存在本机，换手机或重装会丢。导出一份备份，几秒钟就好。")
        }
        .onReceive(NotificationCenter.default.publisher(for: .haoShowDisclaimerGate)) { _ in
            showDisclaimerGate = true
        }
        // b49fix2 B1: Home empty-state CTAs ask the shell to
        // switch tabs. Mount the tab (a tab never visited has no
        // root yet) and select it.
        .onReceive(NotificationCenter.default.publisher(for: .haoSwitchTab)) { notification in
            if let tab = notification.object as? HaoTab {
                mountedTabs.insert(tab)
                selectedTab = tab
            }
        }
        // b49fix2 P1-13: a failed save / quarantined file
        // surfaces once here. The posts can arrive off the main
        // queue (LocalStore saves run on any thread), so the
        // @State write hops to main. The first notice wins — a
        // second failure while one is unread does not clobber it.
        .onReceive(NotificationCenter.default.publisher(for: .haoStoreSaveFailed)) { _ in
            DispatchQueue.main.async {
                if storeNotice == nil {
                    storeNotice = "存储空间不足：部分数据没能保存。请清理空间后重试。"
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .haoStoreQuarantined)) { _ in
            DispatchQueue.main.async {
                if storeNotice == nil {
                    storeNotice = "发现一份损坏的本地数据，已隔离保存。你的其他数据不受影响。"
                }
            }
        }
        // b49fix2 B5: first favourite / download → one-time
        // backup nudge. The download post arrives from the
        // engine's queue, so the @State write hops to main.
        // b49fix3 P2-22: toggleFav carries the add/remove in the
        // notification object — only an ADD nudges; an
        // unfavourite must not re-arm the backup prompt.
        .onReceive(NotificationCenter.default.publisher(for: .haoMusicFavChanged)) { note in
            guard note.object as? Bool == true else { return }
            DispatchQueue.main.async { maybeShowBackupNudge() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .haoDownloadCompleted)) { _ in
            DispatchQueue.main.async { maybeShowBackupNudge() }
        }
        .onAppear {
            // b45-h, P8 #7: the engine's metered-confirmation
            // callback had no consumer anywhere in the app — the
            // prompt never showed. The closure captures the prompt
            // state weakly and hops to the main queue in a
            // DispatchWorkItem (the @Sendable-safe hop, same as
            // the engine's own callbacks).
            DownloadEngine.shared.onMeteredConfirmationNeeded = { [weak meteredPrompt] info in
                let prompt = MeteredDownloadPrompt(info: info)
                let work = DispatchWorkItem { meteredPrompt?.offer(prompt) }
                DispatchQueue.main.async(execute: work)
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
        .onChange(of: selectedTab) { _ in
            mountedTabs.insert(selectedTab)
            bottomChrome.resetRest()
        }
        // Wallpaper cache (build 36, item 10): load once on
        // appear and whenever the switch or the picked file
        // changes — never during body evaluation.
        .onAppear {
            mountedTabs.insert(selectedTab)
            refreshWallpaperCache()
        }
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
        // b49sweep: all mounted tabs stay in the hierarchy —
        // only the selected one is visible / hittable. The
        // crossfade is the same 200ms ease-out as before.
        ZStack {
            ForEach(HaoTab.allCases) { tab in
                if mountedTabs.contains(tab) {
                    tabRoot(for: tab)
                        .opacity(tab == selectedTab ? 1 : 0)
                        .allowsHitTesting(tab == selectedTab)
                        .disabled(tab != selectedTab)
                        .accessibilityHidden(tab != selectedTab)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: selectedTab)
    }

    /// One tab root. The roots keep their own NavigationStack
    /// path + view model (HomeView's @State path / @StateObject
    /// viewModel); MainTabView keeps the root VIEW alive, so
    /// that state survives a tab switch.
    @ViewBuilder
    private func tabRoot(for tab: HaoTab) -> some View {
        switch tab {
        case .home: HomeView()
        case .music: MusicHomeView()
        case .movies: VideoTabView(isSelected: tab == selectedTab)
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

// MARK: - Metered-download prompt (b45-h, P8 #7)
//
// One pending metered-download confirmation (plan §9.3): the
// song title + engine key the dialog acts on. The engine fires
// once per task, so a batch can offer several prompts — they
// queue here and show one at a time; answering (or dismissing)
// the current one advances to the next.
struct MeteredDownloadPrompt: Identifiable {
    let info: DownloadTaskInfo
    var id: String { info.request.key }
    var title: String { info.request.title }
}

@MainActor
final class MeteredDownloadPromptState: ObservableObject {
    @Published private(set) var pending: MeteredDownloadPrompt?
    private var queue: [MeteredDownloadPrompt] = []
    private var answeredID: String?

    func offer(_ prompt: MeteredDownloadPrompt) {
        if pending?.id == prompt.id || queue.contains(where: { $0.id == prompt.id }) { return }
        if pending == nil {
            pending = prompt
        } else {
            queue.append(prompt)
        }
    }

    /// Apply the user's choice to the current prompt. The dialog
    /// itself dismisses afterwards; advancing happens in
    /// `dialogDismissed`, so the choice and the advance never
    /// double-run.
    func resolveCurrent(_ action: (DownloadTaskInfo) -> Void) {
        guard let current = pending else { return }
        answeredID = current.id
        action(current.info)
    }

    /// The dialog closed. A prompt answered by a button just
    /// advances; a prompt dismissed without choosing (tap
    /// outside) is held for Wi-Fi — the safe default, never a
    /// silent approve or cancel.
    func dialogDismissed() {
        guard let current = pending else { return }
        if answeredID != current.id {
            DownloadEngine.shared.holdMetered(key: current.info.request.key)
        }
        answeredID = nil
        pending = queue.isEmpty ? nil : queue.removeFirst()
    }
}

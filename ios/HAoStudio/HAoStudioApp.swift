// HAo Studio 2.0 — app entry point (SwiftUI lifecycle).
//
// There is deliberately NO UIKit app-delegate / scene-delegate shell:
// the 2.0 app is SwiftUI from the first frame. The old Info.plist
// scene-manifest entry (which pointed at the deleted scene delegate)
// is removed for the same reason — a SwiftUI @main app must not
// declare a scene delegate class that does not exist.

import AVFoundation
import SwiftUI

@main
struct HAoStudioApp: App {
    @StateObject private var themeStore: ThemeStore
    @StateObject private var coordinator: PlaybackCoordinator
    /// S2-C: one shared music player view model for the whole app
    /// (home, mini player, full player all observe the same queue
    /// and playback state). Created here, next to the coordinator
    /// it observes — never one instance per page.
    @StateObject private var musicPlayer: MusicPlayerViewModel
    /// S3-C: one shared video player view model for the whole app
    /// (detail page, fullscreen player, mini-player re-entry all
    /// observe the same episode/line state). Created here, next to
    /// the coordinator it observes — never one instance per page.
    @StateObject private var videoPlayer: VideoPlayerViewModel
    /// S4-C: one shared live player view model for the whole app
    /// (room page, portrait + landscape, all observe the same
    /// room/quality/line/danmaku state). Created here, next to
    /// the coordinator it observes — never one instance per page.
    /// A leg owns the type (Playback/LivePlayerViewModel.swift);
    /// its init takes the live driver, mirroring the VOD view
    /// model shape.
    @StateObject private var livePlayer: LivePlayerViewModel
    /// One shared immersive-chrome flag for the whole app
    /// (MainTabView hides the bottom chrome while a live room is
    /// up; the room page sets it on appear / clears it on
    /// disappear). Created here, next to the other shared state —
    /// never one instance per page.
    @StateObject private var immersiveChrome = ImmersiveChromeState()
    /// One shared bottom-chrome minimize state for the whole app
    /// (b35 tab-bar link: the tab roots' scroll anchors drive it,
    /// MainTabView renders the minimized / expanded chrome from it,
    /// and the content clearance follows it). Same pattern as
    /// immersiveChrome above — created here, never one per page.
    @StateObject private var bottomChrome = BottomChromeState()
    /// S5-A: one shared settings store for the whole app (Settings
    /// page, theme overrides, engine preference). Built with the
    /// themeStore above — the ThemeStore is created first and
    /// handed in, so theme-owned state has exactly one owner (see
    /// SettingsStore.swift).
    @StateObject private var settingsStore: SettingsStore
    /// b49fix2 P2-59: holds the background task while downloads
    /// are active (see DownloadBackgroundTaskHolder below).
    @StateObject private var downloadBackgroundTask: DownloadBackgroundTaskHolder

    init() {
        // Build 36 item 10 leg 6: size the shared HTTP cache
        // (32MB memory / 200MB disk) before anything loads an
        // image — the shared image loader's disk cache. Runs
        // before the migration below; the loader also configures
        // lazily on first load, so this is the eager path.
        HaoImageLoader.configureSharedURLCache()
        // S1: the snapshot migration runs before anything reads
        // settings, so the first frame already uses the migrated
        // theme and preferences. It is synchronous, idempotent, and
        // skips quietly when there is no snapshot to migrate from.
        _ = MigrationStore.runIfNeeded()
        let themeStore = ThemeStore()
        _themeStore = StateObject(wrappedValue: themeStore)
        let settingsStore = SettingsStore(themeStore: themeStore)
        _settingsStore = StateObject(wrappedValue: settingsStore)
        // S6: wire the backup engine + update checker behind the
        // shared flow (B leg). The flow's rows are live once these
        // two lines run.
        BackupUpdateFlow.shared.engine = FileBackupEngine()
        BackupUpdateFlow.shared.checker = DefaultUpdateChecker()
        // b49fix2 P2-59: while any download is active, hold a
        // background task so iOS does not suspend the app (and
        // freeze the data tasks) the moment it backgrounds. The
        // engine fires onActivityChanged on the main queue at
        // every activity flip.
        let downloadBackgroundTask = DownloadBackgroundTaskHolder()
        _downloadBackgroundTask = StateObject(wrappedValue: downloadBackgroundTask)
        DownloadEngine.shared.onActivityChanged = { [weak downloadBackgroundTask] active in
            downloadBackgroundTask?.setActive(active)
        }
        let coordinator = PlaybackCoordinator()
        // S2: wire the music engine behind the coordinator. The LX
        // resolver answers resolveFirstPlayable; the player is the
        // driver. Without these two lines requestPlay is a no-op.
        coordinator.resolver = LXSourceResolver()
        coordinator.musicDriver = NativeMusicPlayer.shared
        // S3-C: wire the VOD engine behind the coordinator. The
        // driver (A leg) owns engines + episode/line state; URL
        // resolution is the B-leg CmsClient, which answers the
        // seam VideoPlayURLResolver contract. The coordinator
        // wires onEpisodeStarted / onEpisodeFailed itself in the
        // vodDriver didSet — nothing else to do here.
        let vodDriver = VideoDriver()
        vodDriver.playURLResolver = CmsClient.shared
        coordinator.vodDriver = vodDriver
        // S4-C: wire the live engine behind the coordinator. The
        // driver (A leg, Playback/LiveDriver.swift) owns engines +
        // room/quality/line state; room resolution is the B-leg
        // LiveSiteResolver, which answers the seam contract. The
        // coordinator wires onRoomStarted / onRoomFailed itself in
        // the liveDriver didSet — nothing else to do here.
        let liveDriver = LiveDriver()
        coordinator.liveDriver = liveDriver
        _coordinator = StateObject(wrappedValue: coordinator)
        _musicPlayer = StateObject(wrappedValue: MusicPlayerViewModel(coordinator: coordinator))
        _videoPlayer = StateObject(wrappedValue: VideoPlayerViewModel(coordinator: coordinator, settings: settingsStore))
        _livePlayer = StateObject(wrappedValue: LivePlayerViewModel(driver: liveDriver))
    }

    /// The splash covers the first frame; it fades out at 1.5s
    /// (animation #4) once the app reports ready. Readiness is
    /// real, not a hardcoded literal (b49sweep): init() already
    /// ran the migration + store/engine wiring synchronously,
    /// so the shell reports ready when it mounts (see the
    /// onAppear below). The splash's spinner + subtitle path
    /// is therefore live for any future async startup work —
    /// it exits through SplashView's isReady onChange.
    @State private var splashReady = false
    @State private var showingSplash = true
    /// S6: the launch-time automatic update check runs once per app
    /// launch (the 20 h throttle lives in the checker itself).
    @State private var didTriggerAutoUpdateCheck = false
    /// The backup + update flow (S6-B, shared singleton). The
    /// update sheet is attached at this app-root level — NOT in
    /// the settings page — because the launch-time auto check
    /// sets `updatePrompt` while the Home tab is up, and the
    /// settings page only mounts when the My tab is selected
    /// (MainTabView builds only the selected tab): a sheet
    /// attached there never presented until the user opened 我的,
    /// so the update prompt was missed or delayed.
    @StateObject private var backupFlow = BackupUpdateFlow.shared
    /// S7-C: scenePhase drives the live background-audio handoff
    /// (S4 left `handleBackground` / `handleForeground` with no
    /// caller). The session guards both calls, so the launch-time
    /// inactive -> active transition is a no-op.
    @Environment(\.scenePhase) private var scenePhase
    /// System scheme (b49sweep): the splash palette below needs
    /// the effective scheme, and the `.preferredColorScheme`
    /// override applies to MainTabView's subtree only — the App
    /// struct itself still sees the system scheme here.
    @Environment(\.colorScheme) private var systemScheme

    /// Palette for the splash (b49sweep): resolved from the
    /// effective scheme — the appearance override when the user
    /// set one, else the system scheme — so a dark-mode user
    /// never gets a white flash. MainTabView resolves its own
    /// palette from the same rule inside its subtree; the splash
    /// sits outside it, so the app root supplies it here.
    private var splashPalette: HaoThemePalette {
        themeStore.palette(for: themeStore.appearance.preferredColorScheme ?? systemScheme)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                MainTabView()
                    .preferredColorScheme(themeStore.appearance.preferredColorScheme)
                    .onAppear {
                        // b49sweep: the shell mounted, and init()
                        // already ran the migration + wiring
                        // synchronously — the app is ready. This
                        // is the real readiness signal for the
                        // splash (was a hardcoded `true`).
                        splashReady = true
                        // S6: one launch-time automatic update check.
                        // A newer build opens the same update sheet
                        // as a manual check; silence (throttled, up
                        // to date, skipped, offline) shows nothing.
                        if !didTriggerAutoUpdateCheck {
                            didTriggerAutoUpdateCheck = true
                            if let checker = BackupUpdateFlow.shared.checker as? DefaultUpdateChecker {
                                checker.checkAutoIfEnabled { result in
                                    if let result = result {
                                        // b49fix2 P2-25: an auto-check
                                        // result must never overlap
                                        // the disclaimer gate. Before
                                        // acceptance it is stashed in
                                        // the flow; MainTabView flushes
                                        // it when the gate closes with
                                        // acceptance.
                                        if DisclaimerGate.isAccepted(storedVersion: settingsStore.disclaimerAcceptedVersion) {
                                            BackupUpdateFlow.shared.updatePrompt = result
                                            BackupUpdateFlow.shared.showingUpdatePrompt = true
                                        } else {
                                            BackupUpdateFlow.shared.pendingAutoUpdateResult = result
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // Phase 5, §6.3: headphones unplugged (or a
                    // Bluetooth headset disconnected) — the audio
                    // route lost its output device
                    // (.oldDeviceUnavailable). Pause whatever is
                    // playing instead of letting it carry on
                    // through the speaker; the coordinator pauses
                    // only drivers that report isPlaying, so this
                    // is a no-op while nothing plays. Other route
                    // reasons (a device plugged in, a Control
                    // Center switch) never pause. No auto-resume:
                    // the user taps play again.
                    .onReceive(NotificationCenter.default.publisher(
                        for: AVAudioSession.routeChangeNotification
                    )) { notification in
                        guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                              AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .oldDeviceUnavailable
                        else { return }
                        coordinator.pausePlaying()
                    }
                if showingSplash {
                    SplashView(isReady: $splashReady) {
                        showingSplash = false
                        // b45-h, 包 C leftover (b): first-launch
                        // disclaimer gate. The splash is done, so
                        // the gate (if needed) presents over the
                        // tabs; MainTabView owns the presentation
                        // (it has the resolved theme palette).
                        // A bumped DisclaimerGate.currentVersion
                        // re-asks consent the same way.
                        if !DisclaimerGate.isAccepted(storedVersion: settingsStore.disclaimerAcceptedVersion) {
                            NotificationCenter.default.post(name: .haoShowDisclaimerGate, object: nil)
                        }
                    }
                }
            }
            // Update sheet at the app root (see backupFlow above):
            // presents on every tab, including the launch-time
            // auto-check prompt while the Home tab is up.
            // b45-h, 包 C leftover (a): the .height(360) detent
            // (Coda §4.2) is the initial height; .large is the
            // escape hatch when long release notes overflow 360 —
            // the sheet then grows instead of clipping text.
            // b49fix2 P2-24: driven by showingUpdatePrompt, not by
            // updatePrompt — dismissing the sheet mid-download
            // must not clear the prompt (the download keeps
            // running and the sheet reopens on the same prompt).
            // A swipe-dismiss only hides the sheet; dismissPrompt
            // is what clears the prompt.
            .sheet(isPresented: $backupFlow.showingUpdatePrompt) {
                if let result = backupFlow.updatePrompt {
                    UpdatePromptSheet(
                        result: result,
                        onSkip: { backupFlow.skipPromptedVersion() },
                        onLater: { backupFlow.dismissPrompt() }
                    )
                    .presentationDetents([.height(360), .large])
                    .presentationDragIndicator(.visible)
                }
            }
            // b49sweep: the splash reads its background from
            // `.haoTheme`; it sits outside MainTabView, which is
            // where the palette is normally resolved.
            .environment(\.haoTheme, splashPalette)
            .environmentObject(themeStore)
            .environmentObject(settingsStore)
            .environmentObject(coordinator)
            .environmentObject(musicPlayer)
            // build 36, item 10, leg 3: the same instance, also as
            // a plain environment value — MusicSongMenuHost reads
            // it via @Environment(\.musicPlayerVM), which does NOT
            // subscribe to the 0.5 s position tick (unlike the
            // @EnvironmentObject above, which the player / mini
            // bar / list pages keep). Same object, no new state.
            .environment(\.musicPlayerVM, musicPlayer)
            .environmentObject(videoPlayer)
            .environmentObject(livePlayer)
            .environmentObject(immersiveChrome)
            .environmentObject(bottomChrome)
            .onChange(of: scenePhase) { newPhase in
                switch newPhase {
                case .background:
                    livePlayer.handleBackground()
                    // S7 wiring: VOD background audio — the
                    // audio-only switch keeps playing (video off),
                    // otherwise VOD pauses on background.
                    videoPlayer.handleBackground()
                    // Autoresume: capture the music position now —
                    // a suspended app can be killed with no callback.
                    musicPlayer.saveResumeNow()
                case .active:
                    livePlayer.handleForeground()
                    videoPlayer.handleForeground()
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
        }
    }
}

/// Holds a UIBackgroundTaskIdentifier while downloads are active
/// (b49fix2 P2-59). Without it, iOS suspends the app the moment
/// it backgrounds and the engine's data tasks freeze until
/// foreground — the download made no progress in the background.
/// Ended when activity stops; the expiration handler ends it
/// early (the .part files make the downloads resumable, so an
/// expired task loses nothing but time). Main queue only:
/// the engine fires onActivityChanged there.
final class DownloadBackgroundTaskHolder: ObservableObject {
    private var task: UIBackgroundTaskIdentifier = .invalid

    func setActive(_ active: Bool) {
        if active {
            guard task == .invalid else { return }
            task = UIApplication.shared.beginBackgroundTask(withName: "HAoStudio-download") { [weak self] in
                self?.end()
            }
        } else {
            end()
        }
    }

    private func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}

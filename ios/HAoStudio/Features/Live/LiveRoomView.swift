// HAo Studio 2.0 — live room page (S4-C leg).
//
// Portrait entry (Flutter live_room_page.dart, Pure Live layout):
// 16:9 inline video + room info + danmaku chat list + bottom
// bar. ONLY the [ ] button takes the room landscape; rotating
// the phone never rotates the room; landscape rotates the WHOLE
// app (direction lock on still rotates) — the mechanism is
// copied from S3 VOD (VideoOrientation: UIDevice orientation +
// window-scene geometry request), never reinvented.
//
// - Quality / line switcher: LIVE ONLY (VOD has no quality
//   tiers). Same quality+line = no-op; line buttons show only
//   "线路 N", never CDN names; only the PREFERRED quality is
//   persisted (Flutter §2.8 rules).
// - Brightness / volume sliders: ONLY in this player. The app
//   never changes system brightness by itself: on appear the
//   slider is SEEDED from the system value (read-only), and the
//   system value is written only from the slider's own drag.
//   Entering / leaving the room never restores or overwrites
//   the user's system brightness. Volume uses the system
//   MPVolumeView slider (public API, no private volume call).
// - Danmaku: read-only (the app never sends danmaku). Portrait
//   shows the chat list; landscape flies messages over the
//   video (LiveDanmakuView). The 14-item settings sheet is
//   LiveDanmakuSettingsSheet.
// - Exiting the room stops playback and never auto-resumes
//   music (coordinator.stop clears the item; nothing resumes).
//
// Playback state comes from A leg's LivePlayerViewModel
// (Playback/ — the view never owns an engine). The seam
// assumptions this file programs against (coordinator aligns
// them at merge; A leg owns the real declarations):
//   LivePlayerViewModel: ObservableObject, created in
//     HAoStudioApp as LivePlayerViewModel(driver: liveDriver).
//   @Published isPlaying / currentQuality / currentLineIndex /
//     watching / messages (all private(set)); lines / qualities /
//     videoView are read-throughs from the driver;
//   brightnessLevel / volumeLevel (Double 0...1, private(set)) +
//     setBrightness(_:) / setVolume(_:) — the ONLY writers to the
//     screen / system volume; notePlayerEntry() arms on appear,
//     disarmBrightness() stops writes on disappear — exit never
//     restores the system brightness (chen 2026-11-20);
//   togglePlayPause(), switchQuality(to: LiveQuality),
//     switchLine(to: Int index).
//   LiveQuality has `name` (label) + `id` (identity). LiveLine is
//   selected by index (display is always "线路 N").
//   DanmakuMessage has `text` + `userName` (Flutter
//   LiveMessage mirror). The transport is owned by the view model
//   (`startDanmaku` / `stopDanmaku`); the page starts it on appear
//   and stops it on disappear.

import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

struct LiveRoomView: View {
    var room: LiveRoom
    var playlist: [LiveRoom]

    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var livePlayer: LivePlayerViewModel
    @EnvironmentObject private var immersiveChrome: ImmersiveChromeState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.haoTheme) private var theme

    @State private var currentIndex: Int
    @State private var isFullscreen = false
    @State private var controlsVisible = true
    @State private var isFollowing = false
    @State private var showQualitySheet = false
    @State private var showDanmakuSettings = false
    @State private var showBrightnessVolume = false
    @State private var danmakuSettings = LiveDanmakuSettings.load()
    @State private var autoHideWork: DispatchWorkItem?
    @State private var toastWork: DispatchWorkItem?
    /// Battery level for the landscape top bar (Pure Live
    /// TopActionBar shows time + battery — the status bar is
    /// hidden in fullscreen, so the room shows them itself).
    /// -1 = unknown (simulator / not yet read): hidden then.
    @State private var batteryLevel: Float = -1

    /// HH:mm formatter for the landscape clock (one shared
    /// instance — a DateFormatter per render would be wasteful).
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init(room: LiveRoom, playlist: [LiveRoom]) {
        self.room = room
        self.playlist = playlist
        let index = playlist.firstIndex(where: { $0.roomId == room.roomId && $0.platform == room.platform }) ?? 0
        _currentIndex = State(initialValue: index)
    }

    private var currentRoom: LiveRoom {
        guard playlist.indices.contains(currentIndex) else { return room }
        return playlist[currentIndex]
    }

    private var hasPreviousRoom: Bool { currentIndex > 0 }
    private var hasNextRoom: Bool { currentIndex + 1 < playlist.count }

    /// Watching count: the live session's number wins when it
    /// has one; otherwise the card's stored number.
    private var watchingCount: Int {
        livePlayer.watching > 0 ? livePlayer.watching : currentRoom.onlineCount
    }

    /// Danmaku on/off for this platform (absent entry = enabled).
    private var danmakuEnabledForRoom: Bool {
        danmakuSettings.isEnabled(for: currentRoom.platform)
    }

    var body: some View {
        Group {
            if isFullscreen {
                landscapeBody
            } else {
                portraitBody
            }
        }
        .onAppear {
            // Immersive: hide the shell bottom chrome (mini player
            // + glass tab bar) while the room is up, so the room's
            // own bottom bar is never covered by it.
            immersiveChrome.enterImmersive()
            VideoOrientation.unlockPortrait()
            openCurrentRoom()
            isFollowing = LiveLibraryStore.isFollowed(
                platform: currentRoom.platform.rawValue, roomId: currentRoom.roomId)
            // Arm brightness writes (seeds the slider from the
            // system value) and seed the volume state from the
            // system value.
            livePlayer.notePlayerEntry()
            livePlayer.setVolume(Double(AVAudioSession.sharedInstance().outputVolume))
            // Landscape top bar shows time + battery (Pure Live
            // TopActionBar): enable monitoring and take a reading.
            UIDevice.current.isBatteryMonitoringEnabled = true
            batteryLevel = UIDevice.current.batteryLevel
        }
        .onDisappear {
            // The room is gone: the shell bottom chrome comes back.
            immersiveChrome.exitImmersive()
            autoHideWork?.cancel()
            toastWork?.cancel()
            VideoOrientation.unlockPortrait()
            // Battery monitoring was enabled on appear for the
            // landscape clock/battery readout; switch it off
            // again on exit (b36 item 5: it was left on after
            // every room visit).
            UIDevice.current.isBatteryMonitoringEnabled = false
            livePlayer.stopDanmaku()
            livePlayer.disarmBrightness()
            coordinator.stop()
            // Build 35 sweep S3: `stop()` only shuts the backend
            // — the session (room + prefetch timer + resolver)
            // lives on until the next room's `enterRoom` replaces
            // it, so the exited room's lease prefetch kept
            // re-parsing on its timer after exit. `release()` is
            // the documented exit path (it also exits the
            // session); the room page never called it.
            livePlayer.driver.release {}
        }
        .onChange(of: isFullscreen) { _, fullscreen in
            if fullscreen {
                VideoOrientation.lockLandscape()
                showControlsTemporarily()
            } else {
                VideoOrientation.unlockPortrait()
            }
        }
        .onChange(of: livePlayer.isPlaying) { _, playing in
            if playing && isFullscreen {
                showControlsTemporarily()
            }
        }
        .sheet(isPresented: $showQualitySheet) {
            LiveQualityLineSheet(
                qualities: livePlayer.qualities,
                lines: livePlayer.lines,
                // Build 35 sweep S5: the highlight is derived from
                // the driver's acked state, never from local state
                // — the old local indices went stale whenever the
                // driver acked a different tier (cellular
                // downgrade caps the entry tier; a fallback opens
                // another line), so the sheet highlighted a tier
                // that was not playing and tapping that row was a
                // dead no-op.
                selectedQualityIndex: livePlayer.qualities.firstIndex(where: { $0.id == livePlayer.currentQuality?.id }) ?? 0,
                selectedLineIndex: livePlayer.currentLineIndex,
                currentQualityLabel: livePlayer.currentQuality?.name,
                onSelectQuality: { index in switchQuality(to: index) },
                onSelectLine: { index in switchLine(to: index) }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showDanmakuSettings) {
            LiveDanmakuSettingsSheet(settings: $danmakuSettings)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showBrightnessVolume) {
            // The sheet's slider writes through setBrightness, the
            // VM's only screen writer (armed by notePlayerEntry).
            LiveBrightnessVolumeSheet(brightness: Binding(get: { livePlayer.brightnessLevel }, set: { livePlayer.setBrightness($0) }))
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        // The room never shows the system nav bar (fix 2026-11-24,
        // build 35): in portrait the bar stayed visible, so the
        // whole page was laid out below it and the bar area — with
        // no app view painting it — rendered as a black band above
        // the video. The video now reaches the top edge and the
        // back button is overlaid on it (portraitTopBar).
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .statusBarHidden(isFullscreen)
        // Build 35 sweep S6: the view model has always set a toast
        // on a line switch and on a failed quality switch, but no
        // view ever read it — a failed switch closed the sheet and
        // said nothing. Show it above the bottom bar and clear it
        // after 2.5 s (hit-test transparent: it must never eat the
        // tap-to-play underneath).
        .overlay(alignment: .bottom) {
            if let toast = livePlayer.toast {
                Text(toast)
                    .font(.haoDenseBody)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.7), in: Capsule())
                    .padding(.bottom, 96)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: livePlayer.toast)
        .onChange(of: livePlayer.toast) { _, toast in
            toastWork?.cancel()
            guard toast != nil else { return }
            let work = DispatchWorkItem { livePlayer.clearToast() }
            toastWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            batteryLevel = UIDevice.current.batteryLevel
        }
    }

    /// Live status for the badges: the view model's refreshed
    /// value wins when room info has answered (build 35 sweep
    /// S7); until then the card's stored value stands.
    private var isLiveNow: Bool {
        livePlayer.roomIsLive ?? currentRoom.isLive
    }

    // MARK: - Open / switch

    /// Open the current room: record history (Flutter L01),
    /// configure the driver with the room + its platform resolver,
    /// then request playback (the coordinator stops music/VOD
    /// first — one sound at a time — and the live driver plays).
    /// The view model also starts the danmaku transport (roomInfo
    /// supplies the transport credentials when the card has none).
    private func openCurrentRoom() {
        let room = currentRoom
        LiveLibraryStore.recordHistory(
            platform: room.platform.rawValue, roomId: room.roomId,
            title: room.title, nick: room.streamer, cover: room.cover)
        isFollowing = LiveLibraryStore.isFollowed(platform: room.platform.rawValue, roomId: room.roomId)
        let resolver = LiveSites.resolver(for: room.platform)
        livePlayer.driver.configure(room: room, resolver: resolver)
        coordinator.requestLivePlay(LiveDriver.playbackItem(room: room))
        livePlayer.startDanmaku(room: room, resolver: resolver)
    }

    private func switchToRoom(at index: Int) {
        guard playlist.indices.contains(index), index != currentIndex else { return }
        currentIndex = index
        openCurrentRoom()
    }

    /// Same quality = no-op (Flutter §2.8). Compared against the
    /// driver's acked quality, not a local index (build 35 sweep
    /// S5): the ack can differ from the last request (cellular
    /// downgrade, server cap), and the old local comparison made
    /// the highlighted row untappable even when it was not the
    /// tier playing.
    private func switchQuality(to index: Int) {
        guard livePlayer.qualities.indices.contains(index) else { return }
        guard livePlayer.qualities[index].id != livePlayer.currentQuality?.id else { return }
        livePlayer.switchQuality(to: livePlayer.qualities[index])
    }

    /// Same line = no-op, compared against the driver's line
    /// index (build 35 sweep S5 — the local index went stale on
    /// a fallback open, same as quality above).
    private func switchLine(to index: Int) {
        guard livePlayer.lines.indices.contains(index) else { return }
        guard index != livePlayer.currentLineIndex else { return }
        livePlayer.switchLine(to: index)
    }

    private func toggleFollow() {
        let room = currentRoom
        isFollowing = LiveLibraryStore.toggleFollow(
            platform: room.platform.rawValue, roomId: room.roomId,
            title: room.title, nick: room.streamer, cover: room.cover)
    }

    private func toggleDanmaku() {
        danmakuSettings.setEnabled(!danmakuEnabledForRoom, for: currentRoom.platform)
        danmakuSettings.persist()
    }

    // MARK: - Controls auto-hide (landscape only)

    private func showControlsTemporarily() {
        autoHideWork?.cancel()
        // Pure Live slides both bars in/out over 300ms; the
        // show and the auto-hide both animate.
        withAnimation(.easeOut(duration: 0.3)) {
            controlsVisible = true
        }
        guard livePlayer.isPlaying else { return }
        let work = DispatchWorkItem { [self] in
            guard self.livePlayer.isPlaying, self.isFullscreen else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self.controlsVisible = false
            }
        }
        autoHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: - Portrait (16:9 inline video + info + danmaku list)

    private var portraitBody: some View {
        VStack(spacing: 0) {
            videoArea
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(Color.black)
            roomInfoSection
            // Hairline between the info block and the danmaku
            // list (Pure Live's Divider under ResolutionsRow).
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 0.5)
            danmakuSection
            // Hairline above the tools bar: the bar is a toolbar
            // surface, and the list runs up to it.
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 0.5)
            portraitBottomBar
        }
        .ignoresSafeArea(edges: .top)
        .background(theme.scaffoldBackground)
    }

    /// The video frame: the A-leg native surface when attached;
    /// before that, the room cover dimmed as the backdrop and an
    /// honest "no picture yet" note — never a fake frame.
    ///
    /// Tap-to-play lives ONLY on the background layer below
    /// (videoBackground), NOT on this whole ZStack (fix
    /// 2026-11-24, build 35): the on-video buttons (play/pause,
    /// danmaku toggle, [ ] fullscreen) and the back button are
    /// siblings ABOVE that layer, so a tap on them hits only
    /// them. When the gesture sat on the whole area, SwiftUI
    /// fired it as well as the button — [ ] also paused once,
    /// and play/pause toggled twice (net zero, button looked
    /// dead). The same sibling pattern as the VOD player's
    /// gesture layer (VideoPlayerView): chrome above, gesture
    /// below. The danmaku overlay is already hit-test
    /// transparent (LiveDanmakuOverlayView), so taps pass
    /// through it to the background; only the two gradient
    /// chrome strips (top back row, bottom control strip)
    /// keep their taps, like any player's chrome.
    private var videoArea: some View {
        ZStack {
            videoBackground
            if danmakuEnabledForRoom {
                LiveDanmakuOverlayView(
                    messages: livePlayer.messages,
                    sequence: livePlayer.danmakuSequence,
                    settings: danmakuSettings
                )
            }
            // On-video control strip: play/pause, danmaku toggle,
            // [] fullscreen. This IS the player control bar — it
            // lives on the video, not in the page bottom bar:
            // chen's 2026-11-24 screenshot shows the page bottom
            // bar half-covered by the tab bar, so player controls
            // must not depend on it. Always visible in portrait
            // (the page is not immersive — nothing auto-hides
            // here). No speed control: live is real-time.
            VStack {
                Spacer()
                portraitVideoControls
            }
            // Back button over the portrait video (fix 2026-11-24,
            // build 35): with the nav bar hidden the video reaches
            // the top edge, so the back button lives here — the
            // same 36pt black-0.45 circle + 0.55 top gradient as
            // landscapeTopBar. The GeometryReader only positions
            // the row below the status bar; the gradient is the
            // row's own background, so taps still reach the video.
            GeometryReader { geo in
                VStack {
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "chevron.left")
                                .font(.haoBodyStrong)
                                .foregroundStyle(theme.accentOnVideo)
                                .frame(width: 36, height: 36)
                                .background(Color.black.opacity(0.45), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("返回")
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, geo.safeAreaInsets.top + 8)
                    .background(
                        LinearGradient(
                            colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
                            startPoint: .top, endPoint: .bottom)
                    )
                    Spacer()
                }
            }
        }
    }

    /// The video background alone: black + native surface (or
    /// dimmed cover / "暂无画面" placeholder) + paused play
    /// glyph. The tap-to-play gesture lives here and only here,
    /// so it can never double-fire with a button above it.
    private var videoBackground: some View {
        ZStack {
            Color.black
            if let videoView = livePlayer.videoView {
                LiveVideoSurfaceView(view: videoView)
            } else if let url = liveCoverURL(for: currentRoom) {
                // Shared loader (build 36 item 10 leg 6): same
                // cover the card already loaded, downsampled to
                // screen size. Failure shows nothing — the error
                // widget below explains the state.
                let target = HaoImageLoader.fullScreenTargetPoints
                HaoCachedImage(
                    urlString: url.absoluteString,
                    targetWidth: CGFloat(target.width),
                    targetHeight: CGFloat(target.height)
                ) { image in
                    image.resizable().scaledToFill().opacity(0.35)
                } placeholder: {
                    EmptyView()
                }
            }
            if livePlayer.videoView == nil {
                // Pure Live's error widget, same two lines:
                // what happened, then why.
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("暂无画面")
                        .font(.haoCalloutStrong)
                        .foregroundStyle(.white.opacity(0.9))
                    Text("房间未开播或暂时无法观看")
                        .font(.haoFootnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            if !livePlayer.isPlaying && livePlayer.videoView != nil {
                Image(systemName: "play.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { livePlayer.togglePlayPause() }
    }

    /// On-video control strip (portrait). Buttons are 44pt touch
    /// targets (Beans value); white on a bottom gradient scrim —
    /// the same forced-dark chrome as the VOD / live-landscape
    /// bars, so it reads over any frame in any theme combination.
    private var portraitVideoControls: some View {
        HStack(spacing: 8) {
            Button(action: { livePlayer.togglePlayPause() }) {
                Image(systemName: livePlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.haoSectionTitle)
                    .foregroundStyle(theme.accentOnVideo)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(livePlayer.isPlaying ? "暂停" : "播放")
            DanmakuToggleButton(isOn: danmakuEnabledForRoom, action: toggleDanmaku)
            Spacer()
            Button(action: { isFullscreen = true }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.haoSectionTitle)
                    .foregroundStyle(theme.accentOnVideo)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("全屏")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.55)],
                startPoint: .top, endPoint: .bottom)
        )
    }

    /// Watching-count text ("" when the count is unavailable —
    /// never invent a number). The portrait tools bar and the
    /// landscape bottom bar hide the whole flame + count group
    /// when it is empty instead of rendering a dangling label.
    private var watchingText: String { liveWatchingText(watchingCount) }

    /// Room info under the video, Pure Live AppBar-title style:
    /// title on its own line, then the anchor row — avatar 28 +
    /// nick 15 semibold + a sub-line carrying the LIVE badge and
    /// the platform name (Pure Live shows "PLATFORM / AREA"
    /// there; rooms carry no area, so the platform name alone) —
    /// then the follow pill. The watching count lives in the
    /// tools bar below (Pure Live ResolutionsRow), not here, and
    /// the platform capsule is gone: a quiet caption, not a chip.
    private var roomInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Text(currentRoom.title.isEmpty ? "直播间" : currentRoom.title)
                    .font(.haoBodyStrong)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                Spacer()
                if playlist.count > 1 {
                    roomSwitchButtons
                }
            }
            HStack(spacing: 12) {
                anchorAvatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentRoom.streamer.isEmpty ? currentRoom.platform.displayName : currentRoom.streamer)
                        .font(.haoSubheadStrong)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if isLiveNow {
                            Text("LIVE")
                                .font(.haoBadge)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(theme.liveRed, in: Capsule())
                        }
                        Text(currentRoom.platform.displayName)
                            .font(.haoCaption)
                            .foregroundStyle(theme.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button(action: toggleFollow) {
                    Label(
                        isFollowing ? "已关注" : "关注",
                        systemImage: isFollowing ? "heart.fill" : "heart")
                        .font(.haoDenseTitle)
                        .foregroundStyle(isFollowing ? theme.textPrimary : theme.onAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            isFollowing ? theme.surface : theme.accent,
                            in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    /// Previous / next room in the current list (Flutter
    /// room_switch_panel). Hidden when the list has one room.
    private var roomSwitchButtons: some View {
        HStack(spacing: 4) {
            Button(action: { switchToRoom(at: currentIndex - 1) }) {
                Image(systemName: "chevron.up")
                    .font(.haoDenseTitle)
                    .foregroundStyle(hasPreviousRoom ? theme.textPrimary : theme.textMuted)
                    .frame(width: 32, height: 32)
                    .background(theme.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!hasPreviousRoom)
            .accessibilityLabel("上一个房间")
            Button(action: { switchToRoom(at: currentIndex + 1) }) {
                Image(systemName: "chevron.down")
                    .font(.haoDenseTitle)
                    .foregroundStyle(hasNextRoom ? theme.textPrimary : theme.textMuted)
                    .frame(width: 32, height: 32)
                    .background(theme.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!hasNextRoom)
            .accessibilityLabel("下一个房间")
        }
    }

    private var anchorAvatar: some View {
        Group {
            if let url = liveAvatarURL(for: currentRoom) {
                // Shared loader (build 36 item 10 leg 6): 28pt
                // avatar — decode 28x28, not the original.
                HaoCachedImage(
                    urlString: url.absoluteString,
                    targetWidth: 28,
                    targetHeight: 28
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    avatarPlaceholder
                }
            } else {
                avatarPlaceholder
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(theme.surfaceStrong)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.haoRowSubtitle)
                    .foregroundStyle(theme.textSecondary)
            }
    }

    private var danmakuSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("弹幕")
                    .font(.haoSubheadStrong)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if !danmakuEnabledForRoom {
                    Button("已关闭，去开启") { showDanmakuSettings = true }
                        .font(.haoFootnoteMedium)
                        .foregroundStyle(theme.accent)
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            LiveDanmakuListView(
                messages: livePlayer.messages,
                sequence: livePlayer.danmakuSequence,
                settings: danmakuSettings,
                platform: currentRoom.platform.flutterSiteId,
                onOpenSettings: { showDanmakuSettings = true }
            )
        }
    }

    /// Page tools row (portrait) — Pure Live's ResolutionsRow,
    /// iOS edition: flame + watching on the left, the quality
    /// name as a plain text button (the current tier in the
    /// accent, no capsule — Pure Live shows each quality as
    /// text), then brightness/volume and danmaku settings as icon
    /// buttons. Play / danmaku / fullscreen live on the video
    /// control strip (see portraitVideoControls). One control,
    /// one place.
    private var portraitBottomBar: some View {
        HStack(spacing: 16) {
            if !watchingText.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.haoCaption)
                        .foregroundStyle(theme.textSecondary)
                    Text(watchingText)
                        .font(.haoFootnoteMedium)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Button(action: { showQualitySheet = true }) {
                Text(livePlayer.currentQuality?.name ?? "画质")
                    .font(.haoDenseTitle)
                    .foregroundStyle(theme.accent)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            Spacer()
            Button(action: { showBrightnessVolume = true }) {
                Image(systemName: "sun.max")
                    .font(.system(size: 18, weight: .semibold))  // icon size, not text
                    .foregroundStyle(theme.accent)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("亮度与音量")
            Button(action: { showDanmakuSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .semibold))  // icon size, not text
                    .foregroundStyle(theme.accent)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("弹幕设置")
        }
        // The room's stack lays the bar out at the physical screen
        // bottom (the push does not inset it above the shell
        // chrome — that is the reported bug), so once the chrome
        // is hidden the bar would sit on the home indicator:
        // pad by the bottom safe area, and let the surface fill
        // down to it like a native toolbar.
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .safeAreaPadding(.bottom)
        .background(theme.surface)
    }

    // MARK: - Landscape (whole-app rotation, [] only)

    private var landscapeBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let videoView = livePlayer.videoView {
                LiveVideoSurfaceView(view: videoView)
            } else if let url = liveCoverURL(for: currentRoom) {
                // Shared loader (build 36 item 10 leg 6): same as
                // the portrait backdrop — screen-size downsample.
                let target = HaoImageLoader.fullScreenTargetPoints
                HaoCachedImage(
                    urlString: url.absoluteString,
                    targetWidth: CGFloat(target.width),
                    targetHeight: CGFloat(target.height)
                ) { image in
                    image.resizable().scaledToFill().opacity(0.35)
                } placeholder: {
                    EmptyView()
                }
            }
            // Same honest placeholder as portrait (build 36 item
            // 8): landscape used to show only a dimmed cover or
            // black with no explanation when there was no picture.
            if livePlayer.videoView == nil {
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("暂无画面")
                        .font(.haoCalloutStrong)
                        .foregroundStyle(.white.opacity(0.9))
                    Text("房间未开播或暂时无法观看")
                        .font(.haoFootnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            if danmakuEnabledForRoom {
                LiveDanmakuOverlayView(
                    messages: livePlayer.messages,
                    sequence: livePlayer.danmakuSequence,
                    settings: danmakuSettings
                )
            }
            // Tap layer, UNDER the chrome (核查 2026-11-24,
            // build 35 — same pattern as the VOD player): it is
            // a sibling BELOW the controls VStack, not an
            // ancestor of the buttons, so a tap on a button hits
            // only the button. No double-fire here, unlike the
            // portrait videoArea before its fix.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if controlsVisible {
                        withAnimation(.easeOut(duration: 0.3)) {
                            controlsVisible = false
                        }
                        autoHideWork?.cancel()
                    } else {
                        showControlsTemporarily()
                    }
                }
            if controlsVisible {
                VStack(spacing: 0) {
                    landscapeTopBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                    landscapeBottomBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - Landscape chrome (on-video white on a dark scrim —
    // the same forced-dark treatment as the S3 VOD player: the
    // video frame is the background, not the theme scaffold).

    private var landscapeTopBar: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.haoBodyStrong)
                    .foregroundStyle(theme.accentOnVideo)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")
            VStack(alignment: .leading, spacing: 2) {
                Text(currentRoom.title.isEmpty ? "直播间" : currentRoom.title)
                    .font(.haoCalloutStrong)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(currentRoom.streamer.isEmpty ? currentRoom.platform.displayName : currentRoom.streamer)
                    .font(.haoFootnote)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            Spacer()
            landscapeClockAndBattery
            if isLiveNow {
                Text("LIVE")
                    .font(.haoBadge)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(theme.liveRed, in: Capsule())
            }
            Button(action: { showBrightnessVolume = true }) {
                Image(systemName: "sun.max")
                    .font(.haoBodyStrong)
                    .foregroundStyle(theme.accentOnVideo)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("亮度与音量")
            Button(action: { showDanmakuSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.haoBodyStrong)
                    .foregroundStyle(theme.accentOnVideo)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("弹幕设置")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
                startPoint: .top, endPoint: .bottom)
        )
    }

    /// Clock + battery for the landscape top bar (Pure Live
    /// TopActionBar: HH:mm in 14 white, refreshed every 10 s,
    /// and a 35×15 battery outline with the percentage inside).
    /// The status bar is hidden in fullscreen, so the room shows
    /// them itself. Hidden when the level is unknown (simulator).
    private var landscapeClockAndBattery: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: Date(), by: 10)) { timeline in
                Text(Self.clockFormatter.string(from: timeline.date))
                    .font(.haoDenseBody)
                    .foregroundStyle(.white)
            }
            if batteryLevel >= 0 {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(.white, lineWidth: 1)
                        .frame(width: 35, height: 15)
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.white.opacity(0.4))
                            .frame(width: max(0, 31 * CGFloat(batteryLevel)))
                        Spacer(minLength: 0)
                    }
                    .frame(width: 31, height: 11)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    Text("\(Int(batteryLevel * 100))")
                        .font(.haoBadge)
                        .foregroundStyle(.white)
                }
                .frame(width: 35, height: 15)
            }
        }
    }

    /// Landscape bottom bar — Pure Live BottomActionBar order:
    /// play, danmaku, follow, quality as plain white text (no
    /// capsule — the bars are white-on-scrim throughout), Spacer,
    /// flame + watching, exit fullscreen. No refresh button:
    /// Pure Live has one, but there is no public refresh entry
    /// on the driver (refreshURLs is private) — see the style
    /// list. 56pt bar: 44pt controls + 12pt bottom padding.
    private var landscapeBottomBar: some View {
        HStack(spacing: 16) {
            Button(action: { livePlayer.togglePlayPause() }) {
                Image(systemName: livePlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .semibold))  // icon size, not text
                    .foregroundStyle(theme.accentOnVideo)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(livePlayer.isPlaying ? "暂停" : "播放")
            DanmakuToggleButton(isOn: danmakuEnabledForRoom, action: toggleDanmaku)
            Button(action: toggleFollow) {
                Image(systemName: isFollowing ? "heart.fill" : "heart")
                    .font(.haoSectionTitle)
                    .foregroundStyle(isFollowing ? theme.accentOnVideo : .white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFollowing ? "取消关注" : "关注")
            Button(action: { showQualitySheet = true }) {
                Text(livePlayer.currentQuality?.name ?? "画质")
                    .font(.haoDenseTitle)
                    .foregroundStyle(theme.accentOnVideo)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            Spacer()
            if !watchingText.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.haoCaption)
                        .foregroundStyle(.white.opacity(0.85))
                    Text(watchingText)
                        .font(.haoFootnoteMedium)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            Button(action: { isFullscreen = false }) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 18, weight: .semibold))  // icon size, not text
                    .foregroundStyle(theme.accentOnVideo)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("退出全屏")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.55)],
                startPoint: .top, endPoint: .bottom)
        )
    }
}

/// Hosts the live driver's UIView in SwiftUI (copied from the
/// S3 VOD surface wrapper: the view is owned by the backend;
/// this wrapper only embeds it and resizes it to the container).
private struct LiveVideoSurfaceView: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if uiView.subviews.first !== view {
            uiView.subviews.forEach { $0.removeFromSuperview() }
            view.frame = uiView.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            uiView.addSubview(view)
        }
    }
}

/// Quality / line switcher sheet (LIVE ONLY — VOD never shows
/// one). Line buttons show only "线路 N", never CDN names.
/// Same quality+line is a no-op (handled by the caller).
struct LiveQualityLineSheet: View {
    var qualities: [LiveQuality]
    var lines: [LiveLine]
    /// Highlight indices, derived from the driver's acked state
    /// by the caller (build 35 sweep S5) — plain values, not
    /// bindings: the sheet only reads them, and a binding would
    /// invite a second, stale source of truth.
    var selectedQualityIndex: Int
    var selectedLineIndex: Int
    var currentQualityLabel: String?
    var onSelectQuality: (Int) -> Void
    var onSelectLine: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.haoTheme) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !qualities.isEmpty {
                        Text("画质")
                            .font(.haoBodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                            spacing: 8
                        ) {
                            ForEach(Array(qualities.enumerated()), id: \.offset) { index, quality in
                                Button(action: {
                                    onSelectQuality(index)
                                    dismiss()
                                }) {
                                    Text(quality.name)
                                        .font(.haoDenseBody)
                                        .foregroundStyle(
                                            index == selectedQualityIndex
                                                ? theme.onAccent : theme.textPrimary)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(
                                            index == selectedQualityIndex
                                                ? theme.accent : theme.surface,
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if let acked = currentQualityLabel,
                           qualities.indices.contains(selectedQualityIndex),
                           acked != qualities[selectedQualityIndex].name {
                            Text("清晰度已限制为 \(acked)")
                                .font(.haoFootnote)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    if !lines.isEmpty {
                        Text("线路")
                            .font(.haoBodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                            spacing: 8
                        ) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, _ in
                                Button(action: {
                                    onSelectLine(index)
                                    dismiss()
                                }) {
                                    Text("线路 \(index + 1)")
                                        .font(.haoDenseBody)
                                        .foregroundStyle(
                                            index == selectedLineIndex
                                                ? theme.onAccent : theme.textPrimary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(
                                            index == selectedLineIndex
                                                ? theme.accent : theme.surface,
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if qualities.isEmpty && lines.isEmpty {
                        MusicEmptyState(
                            icon: "antenna.radiowaves.left.and.right",
                            title: "暂无画质与线路",
                            note: "房间还没有返回可切换的画质与线路。"
                        )
                    }
                    Spacer(minLength: 16)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
            }
            .background(theme.scaffoldBackground)
            .navigationTitle("画质与线路")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Brightness / volume sheet (live player only). The rows are the
/// shared player rows (PlayerBrightnessVolumeRows — the same
/// implementation the VOD "更多" sheet uses): brightness is a
/// user-driven slider that reads the system value when the sheet
/// opens and writes it only while the user drags; volume is the
/// system MPVolumeView slider (public API) — the sheet never
/// invents a volume value.
struct LiveBrightnessVolumeSheet: View {
    @Binding var brightness: Double

    @Environment(\.dismiss) private var dismiss
    @Environment(\.haoTheme) private var theme

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                PlayerBrightnessVolumeRows(
                    brightness: $brightness,
                    brightnessNote: "只在直播播放器里调节；退出房间不恢复、不覆盖系统亮度。",
                    volumeNote: "系统音量；只在直播播放器里调节。")
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .background(theme.scaffoldBackground)
            .navigationTitle("亮度与音量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .tint(theme.accent)
    }
}

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
    @State private var selectedQualityIndex = 0
    @State private var selectedLineIndex = 0
    @State private var showQualitySheet = false
    @State private var showDanmakuSettings = false
    @State private var showBrightnessVolume = false
    @State private var danmakuSettings = LiveDanmakuSettings.load()
    @State private var autoHideWork: DispatchWorkItem?

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
        }
        .onDisappear {
            // The room is gone: the shell bottom chrome comes back.
            immersiveChrome.exitImmersive()
            autoHideWork?.cancel()
            VideoOrientation.unlockPortrait()
            livePlayer.stopDanmaku()
            livePlayer.disarmBrightness()
            coordinator.stop()
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
                selectedQualityIndex: $selectedQualityIndex,
                selectedLineIndex: $selectedLineIndex,
                currentQualityLabel: livePlayer.currentQuality?.name,
                onSelectQuality: { index in switchQuality(to: index) },
                onSelectLine: { index in switchLine(to: index) }
            )
        }
        .sheet(isPresented: $showDanmakuSettings) {
            LiveDanmakuSettingsSheet(settings: $danmakuSettings)
        }
        .sheet(isPresented: $showBrightnessVolume) {
            // The sheet's slider writes through setBrightness, the
            // VM's only screen writer (armed by notePlayerEntry).
            LiveBrightnessVolumeSheet(brightness: Binding(get: { livePlayer.brightnessLevel }, set: { livePlayer.setBrightness($0) }))
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
        selectedQualityIndex = 0
        selectedLineIndex = 0
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

    /// Same quality = no-op (Flutter §2.8). The driver's ack may
    /// differ from the request; the button label reads the
    /// driver's currentQuality, so the UI follows the ack.
    private func switchQuality(to index: Int) {
        guard livePlayer.qualities.indices.contains(index) else { return }
        guard index != selectedQualityIndex else { return }
        selectedQualityIndex = index
        livePlayer.switchQuality(to: livePlayer.qualities[index])
    }

    /// Same line = no-op. The line switch keeps the room and
    /// resumes at the live edge (the driver owns the resume).
    private func switchLine(to index: Int) {
        guard livePlayer.lines.indices.contains(index) else { return }
        guard index != selectedLineIndex else { return }
        selectedLineIndex = index
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
        controlsVisible = true
        guard livePlayer.isPlaying else { return }
        let work = DispatchWorkItem { [self] in
            guard self.livePlayer.isPlaying, self.isFullscreen else { return }
            self.controlsVisible = false
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
            danmakuSection
            portraitBottomBar
        }
        .ignoresSafeArea(edges: .top)
        .background(theme.scaffoldBackground)
    }

    /// The video frame: the A-leg native surface when attached;
    /// before that, the room cover dimmed as the backdrop and an
    /// honest "no picture yet" note — never a fake frame.
    private var videoArea: some View {
        ZStack {
            Color.black
            if let videoView = livePlayer.videoView {
                LiveVideoSurfaceView(view: videoView)
            } else if let url = liveCoverURL(for: currentRoom) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill().opacity(0.35)
                    }
                }
            }
            if livePlayer.videoView == nil {
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("暂无画面")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            if !livePlayer.isPlaying && livePlayer.videoView != nil {
                Image(systemName: "play.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.9))
            }
            // Flying danmaku over the portrait video (same layer
            // as landscape, same switch): the portrait room used
            // to show danmaku only as the list below, so the
            // toggle had no layer to control on the video.
            if danmakuEnabledForRoom {
                LiveDanmakuOverlayView(
                    messages: livePlayer.messages,
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
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
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
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            DanmakuToggleButton(isOn: danmakuEnabledForRoom, action: toggleDanmaku)
            Spacer()
            Button(action: { isFullscreen = true }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
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
    /// never invent a number). Both the portrait info section and
    /// the landscape bottom bar hide the whole "N人在看" line when
    /// it is empty instead of rendering a dangling label.
    private var watchingText: String { liveWatchingText(watchingCount) }

    private var roomInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(currentRoom.title.isEmpty ? "直播间" : currentRoom.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if currentRoom.isLive {
                            Text("LIVE")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(theme.liveRed, in: Capsule())
                        }
                        if !watchingText.isEmpty {
                            Text("\(watchingText) 人在看")
                                .font(.system(size: 13))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
                Spacer()
                if playlist.count > 1 {
                    roomSwitchButtons
                }
            }
            HStack(spacing: 10) {
                anchorAvatar
                Text(currentRoom.streamer.isEmpty ? currentRoom.platform.displayName : currentRoom.streamer)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(currentRoom.platform.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(theme.surface, in: Capsule())
                Spacer()
                Button(action: toggleFollow) {
                    Label(
                        isFollowing ? "已关注" : "关注",
                        systemImage: isFollowing ? "heart.fill" : "heart")
                        .font(.system(size: 14, weight: .semibold))
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(hasPreviousRoom ? theme.textPrimary : theme.textMuted)
                    .frame(width: 32, height: 32)
                    .background(theme.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!hasPreviousRoom)
            Button(action: { switchToRoom(at: currentIndex + 1) }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(hasNextRoom ? theme.textPrimary : theme.textMuted)
                    .frame(width: 32, height: 32)
                    .background(theme.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!hasNextRoom)
        }
    }

    private var anchorAvatar: some View {
        Group {
            if let url = liveAvatarURL(for: currentRoom) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure, .empty:
                        avatarPlaceholder
                    @unknown default:
                        avatarPlaceholder
                    }
                }
            } else {
                avatarPlaceholder
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(theme.surfaceStrong)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.textSecondary)
            }
    }

    private var danmakuSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("弹幕")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if !danmakuEnabledForRoom {
                    Button("已关闭，去开启") { showDanmakuSettings = true }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            LiveDanmakuListView(
                messages: livePlayer.messages,
                settings: danmakuSettings,
                platform: currentRoom.platform.flutterSiteId,
                onOpenSettings: { showDanmakuSettings = true }
            )
        }
    }

    /// Page tools row (portrait). Play / danmaku / fullscreen
    /// live on the video control strip now (see portraitVideoControls),
    /// so this row holds only the room tools: quality (live only),
    /// brightness/volume, danmaku settings. One control, one place.
    private var portraitBottomBar: some View {
        HStack(spacing: 16) {
            Button(action: { showQualitySheet = true }) {
                Text(livePlayer.currentQuality?.name ?? "画质")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(theme.surface, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(theme.hairline, lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            Spacer()
            Button(action: { showBrightnessVolume = true }) {
                Image(systemName: "sun.max")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            Button(action: { showDanmakuSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
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
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill().opacity(0.35)
                    }
                }
            }
            if danmakuEnabledForRoom {
                LiveDanmakuOverlayView(
                    messages: livePlayer.messages,
                    settings: danmakuSettings
                )
            }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if controlsVisible {
                        controlsVisible = false
                        autoHideWork?.cancel()
                    } else {
                        showControlsTemporarily()
                    }
                }
            if controlsVisible {
                VStack(spacing: 0) {
                    landscapeTopBar
                    Spacer()
                    landscapeBottomBar
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
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(currentRoom.title.isEmpty ? "直播间" : currentRoom.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(currentRoom.streamer.isEmpty ? currentRoom.platform.displayName : currentRoom.streamer)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            Spacer()
            if currentRoom.isLive {
                Text("LIVE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(theme.liveRed, in: Capsule())
            }
            Button(action: { showBrightnessVolume = true }) {
                Image(systemName: "sun.max")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            Button(action: { showDanmakuSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
                startPoint: .top, endPoint: .bottom)
        )
    }

    private var landscapeBottomBar: some View {
        HStack(spacing: 16) {
            Button(action: { livePlayer.togglePlayPause() }) {
                Image(systemName: livePlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            Button(action: { showQualitySheet = true }) {
                Text(livePlayer.currentQuality?.name ?? "画质")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.45), in: Capsule())
            }
            .buttonStyle(.plain)
            DanmakuToggleButton(isOn: danmakuEnabledForRoom, action: toggleDanmaku)
            Spacer()
            if !watchingText.isEmpty {
                Text("\(watchingText) 人在看")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Button(action: { isFullscreen = false }) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
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
    @Binding var selectedQualityIndex: Int
    @Binding var selectedLineIndex: Int
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
                            .font(.system(size: 17, weight: .semibold))
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
                                        .font(.system(size: 14, weight: .medium))
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
                                .font(.system(size: 13))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    if !lines.isEmpty {
                        Text("线路")
                            .font(.system(size: 17, weight: .semibold))
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
                                        .font(.system(size: 14, weight: .medium))
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
    }
}

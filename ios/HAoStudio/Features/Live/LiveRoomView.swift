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
    /// Live picture gestures (build 37, L3 — Pure Live parity):
    /// tap disambiguator (single = play/pause in portrait,
    /// controls toggle in landscape; double = fullscreen) and
    /// the vertical-drag brightness/volume state. The drag pill
    /// shows while `liveDragKind` is set and hides 1 s after
    /// the last update.
    @State private var liveTapDisambiguator = VodTapDisambiguator()
    @State private var pendingLiveSingleTapWork: DispatchWorkItem?
    @State private var liveDragKind: LiveDragKind?
    @State private var liveDragLevel: Double = 0
    @State private var liveDragBaseline: Double = 0
    @State private var liveDragRejected = false
    @State private var liveDragHideWork: DispatchWorkItem?
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
        .background(
            // Hidden volume driver (build 37, L3): the room page
            // wires the view model's volumeApplier through the
            // slider of a 1x1 offscreen MPVolumeView, so a
            // right-half vertical drag changes the system volume
            // without a HUD and without a visible slider. Until
            // this reports, volume drags update state only.
            HiddenMPVolumeView { slider in
                livePlayer.volumeApplier = { [weak slider] level in
                    slider?.setValue(Float(level), animated: false)
                    slider?.sendActions(for: .touchUpInside)
                }
            }
            .frame(width: 1, height: 1)
            .offset(x: -1000, y: -1000)
            .allowsHitTesting(false)
        )
        // Build 37 (L5): disable the navigation-stack edge-swipe
        // pop while fullscreen — see LiveFullscreenPopGuard below.
        .background(LiveFullscreenPopGuard(disabled: isFullscreen))
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
                // (b49 sweep #30) Nil until a tier is acked: the
                // old `?? 0` highlighted tier 0 before anything
                // was resolved, and tapping it ran a switch
                // against no current room → a "切换失败" toast for
                // a tier that was never playing. The sheet
                // disables its quality rows while this is nil.
                selectedQualityIndex: livePlayer.qualities.firstIndex(where: { $0.id == livePlayer.currentQuality?.id }),
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
                // b45-g: same Toast style params as the music
                // player (Coda §8.6, plan §11 C20) — 12.5pt medium,
                // radius 10, shadow black 0.15 / radius 8 / y 4,
                // spring 0.3, bottom entry. Dwell stays 2.5s.
                Text(toast)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .haoDarkGlassRoundedRect(cornerRadius: 10, darkness: 0.7)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .padding(.bottom, 96)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: livePlayer.toast)
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
            title: room.title, nick: room.streamer, cover: room.cover,
            playUrlsJSON: LiveLibraryStore.playUrlsJSON(from: room.data))
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
    /// tier playing. (b49 sweep #30) Nothing is acked yet
    /// (currentQuality == nil) means no switch is possible at
    /// all — the sheet disables its rows then, so this guard is
    /// the second line of defence, not the first.
    private func switchQuality(to index: Int) {
        guard livePlayer.currentQuality != nil else { return }
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
            title: room.title, nick: room.streamer, cover: room.cover,
            playUrlsJSON: LiveLibraryStore.playUrlsJSON(from: room.data))
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

    // MARK: - Picture gestures (build 37, L3 — Pure Live parity)

    /// Size of the picture the drag runs on: portrait is 16:9
    /// of the screen width (the aspectRatio on videoArea);
    /// landscape fills the screen.
    private func liveVideoSize(isLandscape: Bool) -> CGSize {
        let bounds = UIScreen.main.bounds
        if isLandscape {
            return CGSize(width: bounds.width, height: bounds.height)
        }
        return CGSize(width: bounds.width, height: bounds.width * 9 / 16)
    }

    /// Bottom safe-area inset (home indicator) from the key
    /// window — the landscape edge guard reads it.
    private var bottomSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?.safeAreaInsets.bottom ?? 0
    }

    /// Vertical drag on the picture. One gesture for both
    /// layouts; `isLandscape` only changes the size math and
    /// the chrome behaviour (hold the chrome up while dragging
    /// in landscape, re-arm auto-hide on release).
    private func liveDragGesture(isLandscape: Bool) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                liveDragChanged(value, isLandscape: isLandscape)
            }
            .onEnded { _ in
                liveDragEnded(isLandscape: isLandscape)
            }
    }

    /// Single tap (via the disambiguator) / double-tap on the
    /// picture. The first tap waits 0.28 s for a second tap —
    /// the same lag chen accepted on VOD in build 36, and the
    /// strip play/pause buttons stay instant (direct Buttons).
    /// Single tap: portrait toggles play/pause, landscape
    /// toggles the chrome. Double-tap anywhere: fullscreen
    /// toggle (Pure Live) — portrait enters landscape,
    /// landscape returns to the portrait room (never the lobby).
    private func handleLiveTap(at location: CGPoint) {
        let size = liveVideoSize(isLandscape: isFullscreen)
        let outcome = liveTapDisambiguator.tap(
            at: Date().timeIntervalSinceReferenceDate,
            x: location.x,
            width: size.width
        )
        switch outcome {
        case .wait:
            pendingLiveSingleTapWork?.cancel()
            let work = DispatchWorkItem { [self] in
                guard self.liveTapDisambiguator.expirePending(
                    at: Date().timeIntervalSinceReferenceDate
                ) == .singleTap else { return }
                if self.isFullscreen {
                    if self.controlsVisible {
                        withAnimation(.easeOut(duration: 0.3)) {
                            self.controlsVisible = false
                        }
                        self.autoHideWork?.cancel()
                    } else {
                        self.showControlsTemporarily()
                    }
                } else {
                    self.livePlayer.togglePlayPause()
                }
            }
            pendingLiveSingleTapWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + VodGestureConfig.doubleTapWindowSeconds,
                execute: work
            )
        case .singleTap:
            break
        case .doubleTap:
            pendingLiveSingleTapWork?.cancel()
            isFullscreen.toggle()
        }
    }

    /// One vertical-drag move on the picture. Direction lock
    /// (VOD pattern): a mostly-horizontal touch is never a
    /// brightness/volume drag — the latch holds for the whole
    /// touch, so a vertical swipe that later swings sideways
    /// cannot become one, and vice versa. The zone is decided
    /// from the drag START x (left half brightness, right half
    /// volume); the baseline is the live level at drag start,
    /// so the drag never jumps.
    private func liveDragChanged(_ value: DragGesture.Value, isLandscape: Bool) {
        guard !liveDragRejected else { return }
        let size = liveVideoSize(isLandscape: isLandscape)
        // Landscape only: a drag starting in the home-indicator
        // zone belongs to the system, not the player.
        if isLandscape, value.startLocation.y > size.height - bottomSafeAreaInset {
            liveDragRejected = true
            return
        }
        guard !VodGestureMath.isHorizontalDrag(translation: value.translation) else {
            liveDragRejected = true
            return
        }
        if liveDragKind == nil {
            liveDragKind = LiveGestureMath.dragKind(x: value.startLocation.x, width: size.width)
            liveDragBaseline = liveDragKind == .brightness
                ? livePlayer.brightnessLevel : livePlayer.volumeLevel
            liveDragLevel = liveDragBaseline
            // Hold the chrome up while dragging (landscape);
            // portrait has no auto-hide to cancel.
            autoHideWork?.cancel()
            if isLandscape {
                controlsVisible = true
            }
        }
        let level = LiveGestureMath.dragLevel(
            baseline: liveDragBaseline,
            delta: LiveGestureMath.dragDelta(dy: value.translation.height, height: size.height)
        )
        liveDragLevel = level
        if liveDragKind == .brightness {
            livePlayer.setBrightness(level)
        } else {
            livePlayer.setVolume(level)
        }
        scheduleLiveDragHide()
    }

    /// Drag end: the pill hides 1 s after the last update;
    /// landscape re-arms the chrome auto-hide.
    private func liveDragEnded(isLandscape: Bool) {
        defer {
            liveDragRejected = false
            if isLandscape {
                showControlsTemporarily()
            }
        }
        guard liveDragKind != nil else { return }
        scheduleLiveDragHide()
    }

    /// The pill hides 1 s after the last drag update (Pure
    /// Live): every move re-arms the timer.
    private func scheduleLiveDragHide() {
        liveDragHideWork?.cancel()
        let work = DispatchWorkItem { [self] in
            self.liveDragKind = nil
        }
        liveDragHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Centred drag pill (Pure Live player_gestures.dart:
    /// black 0.87, radius 10, icon + 100x6 bar + % — white).
    /// Hit-test transparent: it never eats a tap or a drag.
    private var liveDragIndicator: some View {
        Group {
            if let kind = liveDragKind {
                HStack(spacing: 10) {
                    Image(systemName: LiveGestureMath.iconName(kind: kind, level: liveDragLevel))
                        .font(.system(size: 18))
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.3))
                            .frame(width: 100, height: 6)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white)
                            .frame(width: max(0, 100 * CGFloat(liveDragLevel)), height: 6)
                    }
                    Text("\(Int(liveDragLevel * 100))%")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .haoDarkGlassRoundedRect(cornerRadius: 10, darkness: 0.87)
                .allowsHitTesting(false)
            }
        }
    }

    /// Failure card under the placeholder (build 37, D10): the
    /// reason the open failed + a retry button. Shown only when
    /// the driver reports a failure — while loading, the plain
    /// placeholder stays. The button re-opens the room from
    /// scratch (fresh re-parse, not the dead URLs).
    private var liveFailureCard: some View {
        Group {
            if let failure = livePlayer.openFailure {
                Text(failure.localizedDescription)
                    .font(.haoFootnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button(action: { livePlayer.retryCurrentRoom() }) {
                    Text("重试")
                        .font(.haoCalloutStrong)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("重试播放")
            }
        }
    }

    // MARK: - Portrait (16:9 inline video + info + danmaku list)

    /// Portrait layout (16:9 inline video + info + danmaku list).
    ///
    /// b39: the body does NOT ignore the top safe area — the video
    /// starts below the Dynamic Island / status bar (chen
    /// 2026-11-25 build 38: the island covered the top-centre
    /// icon of the room). The b35 top ignore was there to kill a
    /// black band left by the then-visible navigation bar; the bar
    /// is hidden now (.toolbar(.hidden)), so the band is gone and
    /// the safe area can apply. The scaffold background still
    /// paints the status-bar strip; only the content sits below
    /// the island. The size is adaptive: the 16:9 video is sized
    /// from the real screen width, and the top offset is the
    /// device's own safe-area inset, never a fixed number.
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
            // "No picture yet" placeholder — a SIBLING of the
            // background, not inside it (S5): the card's 重试
            // button lives here, above videoBackground's
            // simultaneous tap gesture, so a tap on it fires
            // only the button. Inside the background the tap
            // also fired the gesture, which toggled play/pause
            // 0.28 s later — and with an open failure that
            // re-ran retryCurrentRoom, a second resolve per
            // tap. Same sibling discipline as the buttons the
            // doc comment above already lists. Position is
            // unchanged: videoArea's size is fixed by the
            // 16:9 aspect ratio at the call site, so this
            // centred VStack lands exactly where it did.
            if livePlayer.videoView == nil {
                // While the open is still in flight (resolving /
                // opening — Huya/Douyu serial resolves take
                // seconds), say so: the old text called the room
                // "not live" before the resolve had even answered.
                // The failure card only shows once the driver
                // reports a failure (openFailure != nil).
                if livePlayer.isLoading && livePlayer.openFailure == nil {
                    VStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                        Text("加载中…")
                            .font(.haoCalloutStrong)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                } else {
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
                        liveFailureCard
                    }
                }
            }
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
            // build 35). b39: portraitBody no longer ignores the
            // top safe area — the video starts below the Dynamic
            // Island / status bar (chen 2026-11-25: the island
            // covered the top of the room) — so the row needs only
            // 8pt below the safe-area edge, not the key-window
            // inset on top of it (the old topSafeAreaInset + 8
            // double-counted once the safe area applies). Same
            // 36pt black-0.45 circle + 0.55 top gradient as
            // landscapeTopBar; the button's hit target is 44pt.
            VStack {
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.haoBodyStrong)
                            .foregroundStyle(theme.accentOnVideo)
                            .frame(width: 36, height: 36)
                            .haoGlassCircle()
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("返回")
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .background(
                    LinearGradient(
                        colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
                        startPoint: .top, endPoint: .bottom)
                )
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Drag pill (build 37, L3): centred over the video,
            // hit-test transparent — it never eats a tap or drag.
            liveDragIndicator
            // Stall warning (b49 sweep #9): the driver publishes
            // it and the view model mirrors it, but no view ever
            // read it — a stalling room looked identical to a
            // healthy one. Same wording as the VOD player
            // ("加载缓慢…") so both players match.
            if livePlayer.stallWarning {
                VStack {
                    stallPill
                        .padding(.top, 56)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// "加载缓慢…" pill (b49 sweep #9): same toast styling as the
    /// room page's toast (12.5pt medium, dark glass, radius 10) —
    /// a status note, never a button, so it stays hit-test
    /// transparent wherever it is placed.
    private var stallPill: some View {
        Text("加载缓慢…")
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .haoDarkGlassRoundedRect(cornerRadius: 10, darkness: 0.7)
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
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
            // The "no picture yet" placeholder lives in
            // videoArea as a sibling above this background
            // (S5) — see the note there. It is NOT here: a
            // button inside this view would double-fire with
            // the simultaneous tap gesture below.
            if !livePlayer.isPlaying && livePlayer.videoView != nil {
                Image(systemName: "play.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .contentShape(Rectangle())
        // Tap + drag on the picture (build 37, L3 — Pure Live):
        // single tap waits 0.28 s for a possible second tap
        // (double-tap = fullscreen, either layout), vertical
        // drag = brightness (left half) / volume (right half).
        // The drag is the view's own gesture (not simultaneous)
        // so a vertical drag on the video does not also scroll
        // the page below it. Same sibling discipline as the VOD
        // gesture layer: this sits on the background only, under
        // the chrome, so buttons above it never double-fire.
        .simultaneousGesture(
            SpatialTapGesture(count: 1).onEnded { value in
                handleLiveTap(at: value.location)
            }
        )
        .gesture(liveDragGesture(isLandscape: false))
    }

    /// On-video control strip (portrait). Buttons are 44pt touch
    /// targets (Beans value); white on a bottom gradient scrim —
    /// the same forced-dark chrome as the VOD / live-landscape
    /// bars, so it reads over any frame in any theme combination.
    /// Quality + brightness/volume live here now (moved off the
    /// bottom bar, which is follow / refresh / share). b39
    /// (AngelLive FullUIPlayerChrome): the on-video controls are
    /// glass, not bare glyphs on a gradient — 44pt glass circles
    /// for the icon buttons, a 32pt glass pill for the quality
    /// text (the bottom gradient scrim stays underneath).
    private var portraitVideoControls: some View {
        HStack(spacing: 8) {
            Button(action: { livePlayer.togglePlayPause() }) {
                Image(systemName: livePlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.haoSectionTitle)
                    .foregroundStyle(theme.accentOnVideo)
                    .frame(width: 44, height: 44)
                    .haoGlassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(livePlayer.isPlaying ? "暂停" : "播放")
            DanmakuToggleButton(isOn: danmakuEnabledForRoom, action: toggleDanmaku)
            Button(action: { showQualitySheet = true }) {
                Text(livePlayer.currentQuality?.name ?? "画质")
                    .font(.haoDenseTitle)
                    .foregroundStyle(theme.accentOnVideo)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .haoGlassCapsule()
            }
            .buttonStyle(.plain)
            .frame(height: 44)
            .accessibilityLabel("画质")
            Spacer()
            Button(action: { showBrightnessVolume = true }) {
                Image(systemName: "sun.max")
                    .font(.haoSectionTitle)
                    .foregroundStyle(theme.accentOnVideo)
                    .frame(width: 44, height: 44)
                    .haoGlassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("亮度与音量")
            Button(action: { isFullscreen = true }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.haoSectionTitle)
                    .foregroundStyle(theme.accentOnVideo)
                    .frame(width: 44, height: 44)
                    .haoGlassCircle()
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
    /// never invent a number). The profile row (portrait) and
    /// the landscape bottom bar hide the whole flame + count group
    /// when it is empty instead of rendering a dangling label.
    private var watchingText: String { liveWatchingText(watchingCount) }

    /// Room info under the video — Dart Simple Live's profile
    /// row: title on its own line, then avatar 48 + nick 15
    /// semibold + a sub-line carrying the LIVE badge and the
    /// platform name, with the flame + watching count on the
    /// right (fire 20pt orange, count 14pt). Padding 12
    /// horizontal / 8 vertical (Simple Live A8 + 12h). The
    /// follow pill lives in the bottom action bar now, not here.
    private var roomInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                            // O-D3: fade in on async confirmation
                            // (0.2s ease-out); removal stays instant.
                            Text("LIVE")
                                .font(.haoBadge)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(theme.liveRed, in: Capsule())
                                .transition(.asymmetric(insertion: .opacity, removal: .identity))
                        }
                        Text(currentRoom.platform.displayName)
                            .font(.haoCaption)
                            .foregroundStyle(theme.textMuted)
                            .lineLimit(1)
                    }
                    .animation(.easeOut(duration: 0.2), value: isLiveNow)
                }
                Spacer()
                if !watchingText.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 20, weight: .semibold))  // icon size, not text
                            .foregroundStyle(.orange)
                        Text(watchingText)
                            .font(.haoDenseTitle)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                // Shared loader (build 36 item 10 leg 6): 48pt
                // avatar (Dart Simple Live 48x48) — decode 48x48,
                // not the original.
                HaoCachedImage(
                    urlString: url.absoluteString,
                    targetWidth: 48,
                    targetHeight: 48
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    avatarPlaceholder
                }
            } else {
                avatarPlaceholder
            }
        }
        .frame(width: 48, height: 48)
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
                        .foregroundStyle(theme.accentText)
                        .buttonStyle(.plain)
                } else {
                    // Danmaku settings entry (the bottom bar no
                    // longer carries it — Dart Simple Live's
                    // message-area 设置 tab, same place).
                    Button(action: { showDanmakuSettings = true }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18, weight: .semibold))  // icon size, not text
                            .foregroundStyle(theme.accentText)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("弹幕设置")
                }
            }
            .padding(.horizontal, 12)
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

    /// Shareable room page URL: the resolver's `link` when it is
    /// a real page URL (Bilibili/Douyu/Huya/Douyin/Kuaishou), else
    /// the platform's room page for this room id.
    private var shareURL: URL? {
        let link = currentRoom.link
        if let url = URL(string: link), url.scheme == "https" {
            return url
        }
        return URL(string: currentRoom.platform.roomLink(roomId: currentRoom.roomId))
    }

    /// Bottom action bar (portrait) — Dart Simple Live's
    /// buildBottomActions: three equal TextButton.icon buttons
    /// (follow / refresh / share), 14pt, bottom padding = home-
    /// indicator safe area + 4. Refresh re-opens the room
    /// (openCurrentRoom); share uses the room's page URL.
    /// Quality lives on the video strip now; brightness/volume
    /// is the video drag + the sun button on the strip; danmaku
    /// settings is the gear in the "弹幕" header. One control,
    /// one place.
    private var portraitBottomBar: some View {
        HStack(spacing: 0) {
            Button(action: toggleFollow) {
                Label(
                    isFollowing ? "已关注" : "关注",
                    systemImage: isFollowing ? "heart.fill" : "heart")
                    .font(.haoDenseTitle)
                    .foregroundStyle(isFollowing ? theme.textPrimary : theme.accentText)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            Button(action: { openCurrentRoom() }) {
                Label("刷新", systemImage: "arrow.clockwise")
                    .font(.haoDenseTitle)
                    .foregroundStyle(theme.accentText)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            if let shareURL {
                ShareLink(item: shareURL) {
                    Label("分享", systemImage: "square.and.arrow.up")
                        .font(.haoDenseTitle)
                        .foregroundStyle(theme.accentText)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        // The room's stack lays the bar out at the physical screen
        // bottom (the push does not inset it above the shell
        // chrome — that is the reported bug), so once the chrome
        // is hidden the bar would sit on the home indicator:
        // pad by the bottom safe area, and let the surface fill
        // down to it like a native toolbar.
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
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
                // Tap + drag on the picture (build 37, L3 — same
                // as portrait: single tap toggles the chrome after
                // the 0.28 s double-tap window, double-tap exits
                // fullscreen, vertical drag = brightness/volume).
                .simultaneousGesture(
                    SpatialTapGesture(count: 1).onEnded { value in
                        handleLiveTap(at: value.location)
                    }
                )
                .gesture(liveDragGesture(isLandscape: true))
            // Same honest placeholder as portrait (build 36 item
            // 8): it sits ABOVE the tap layer, not below it —
            // the layer is a full-screen Color.clear with a
            // contentShape, so a placeholder below it never
            // receives a tap and the 重试 button was dead in
            // fullscreen (a tap only toggled the chrome). The
            // controls VStack above still wins its own area.
            // While the open is still in flight, show loading,
            // not "not live" (same as portrait above).
            if livePlayer.videoView == nil {
                if livePlayer.isLoading && livePlayer.openFailure == nil {
                    VStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                        Text("加载中…")
                            .font(.haoCalloutStrong)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                } else {
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
                        liveFailureCard
                    }
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
                // (b49 sweep #13) The container ignores the safe
                // area so the video is full-bleed like VOD, but
                // the chrome stays inside it: the notch zones
                // (landscape leading/trailing) and the home
                // indicator (bottom) must never cover a button.
                .safeAreaPadding()
            }
            // Drag pill (build 37, L3): centred over the video,
            // hit-test transparent — it never eats a tap or drag.
            liveDragIndicator
            // Stall warning (b49 sweep #9): same pill as portrait,
            // below the top bar so it never covers the title row.
            if livePlayer.stallWarning {
                VStack {
                    stallPill
                        .padding(.top, 64)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Landscape chrome (on-video white on a dark scrim —
    // the same forced-dark treatment as the S3 VOD player: the
    // video frame is the background, not the theme scaffold).

    private var landscapeTopBar: some View {
        HStack(spacing: 12) {
            // Build 37 (L4): this is the LANDSCAPE back button —
            // it only exits fullscreen, back to the portrait room.
            // dismiss() here popped the whole room to the lobby
            // (chen: "直播横屏退出之后直接回到大厅了"). The
            // portrait back button (videoArea) is the one that
            // dismisses the room; the [ ] button in the bottom bar
            // does the same as this one.
            Button(action: { isFullscreen = false }) {
                Image(systemName: "chevron.left")
                    .font(.haoBodyStrong)
                    .foregroundStyle(theme.accentOnVideo)
                    .frame(width: 36, height: 36)
                    .haoGlassCircle()
            }
            .buttonStyle(.plain)
            // 44pt hit target, visual stays 36pt (same as the
            // portrait back button, L1): 36pt is below the
            // file's own 44pt standard for on-video buttons.
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("退出全屏")
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
                // O-D3: fade in on async confirmation (0.2s
                // ease-out); removal stays instant.
                Text("LIVE")
                    .font(.haoBadge)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(theme.liveRed, in: Capsule())
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
            Button(action: { showBrightnessVolume = true }) {
                Image(systemName: "sun.max")
                    .font(.haoBodyStrong)
                    .foregroundStyle(theme.accentOnVideo)
                    .frame(width: 36, height: 36)
                    .haoGlassCircle()
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("亮度与音量")
            Button(action: { showDanmakuSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.haoBodyStrong)
                    .foregroundStyle(theme.accentOnVideo)
                    .frame(width: 36, height: 36)
                    .haoGlassCircle()
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("弹幕设置")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
                startPoint: .top, endPoint: .bottom)
        )
        // O-D3: only the LIVE badge's appearance animates
        // (0.2s ease-out fade-in); isLiveNow gates nothing else
        // in this bar, so no other change animates with it.
        .animation(.easeOut(duration: 0.2), value: isLiveNow)
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
    /// play, danmaku, follow, quality, refresh, room switch as
    /// plain white text (no capsule — the bars are white-on-scrim
    /// throughout), Spacer, flame + watching, exit fullscreen.
    /// (b49 sweep #29) Refresh and prev/next now live here too:
    /// refresh re-resolves + re-opens the room through the
    /// driver's public refresh entry, and the room-switch buttons
    /// reuse the portrait switchToRoom (hidden for a one-room
    /// list, disabled at the ends — same as portrait).
    /// 56pt bar: 44pt controls + 12pt bottom padding.
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
            Button(action: { livePlayer.refreshCurrentRoom() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.accentOnVideo)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("刷新")
            if playlist.count > 1 {
                Button(action: { switchToRoom(at: currentIndex - 1) }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(hasPreviousRoom ? theme.accentOnVideo : .white.opacity(0.4))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(!hasPreviousRoom)
                .accessibilityLabel("上一个房间")
                Button(action: { switchToRoom(at: currentIndex + 1) }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(hasNextRoom ? theme.accentOnVideo : .white.opacity(0.4))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(!hasNextRoom)
                .accessibilityLabel("下一个房间")
            }
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
            // 44pt hit target, visual stays 40pt (same class as
            // the top-bar buttons above).
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
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

/// Disables the navigation-stack edge-swipe pop while the room is
/// fullscreen (build 37, L5). The room is a NavigationStack push
/// with a hidden back button — but hiding the button does NOT
/// disable the swipe-back gesture, so in landscape a left-edge
/// swipe popped the whole room to the lobby: the same symptom L4
/// fixed for the back button, through the gesture instead. The
/// guard walks the responder chain to the UINavigationController
/// and toggles its interactivePopGestureRecognizer; with no
/// navigation controller (mini-player full-screen re-open) it is
/// a no-op. Portrait swipe-back stays enabled — it is the
/// legitimate back action there, same as the back button.
/// Dismantle restores the gesture so a stale disable can never
/// leak into the next page.
private struct LiveFullscreenPopGuard: UIViewRepresentable {
    var disabled: Bool

    func makeUIView(context: Context) -> UIView {
        UIView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        Self.setPopGestureEnabled(!disabled, from: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        setPopGestureEnabled(true, from: uiView)
    }

    private static func setPopGestureEnabled(_ enabled: Bool, from view: UIView) {
        var responder: UIResponder? = view
        while let current = responder {
            if let nav = current as? UINavigationController {
                nav.interactivePopGestureRecognizer?.isEnabled = enabled
                return
            }
            responder = current.next
        }
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
    /// `selectedQualityIndex` is nil until a tier is acked (b49
    /// sweep #30): no tier is highlighted and the rows are
    /// disabled until then.
    var selectedQualityIndex: Int?
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
                                // (b49 sweep #30) No acked tier yet:
                                // the rows are disabled, so a tap
                                // cannot run a switch against no
                                // current room.
                                .disabled(selectedQualityIndex == nil)
                                .opacity(selectedQualityIndex == nil ? 0.5 : 1)
                            }
                        }
                        if let acked = currentQualityLabel,
                           let selected = selectedQualityIndex,
                           qualities.indices.contains(selected),
                           acked != qualities[selected].name {
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
                        // D3: the sheet tint is the accent (the
                        // brightness slider keeps it); the label
                        // itself reads in accentText.
                        .foregroundStyle(theme.accentText)
                }
            }
        }
        .tint(theme.accent)
    }
}

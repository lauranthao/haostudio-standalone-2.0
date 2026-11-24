// HAo Studio 2.0 — full music player (S2-C leg).
//
// chen's screenshot standard (MEMORY.md, music player design
// reference), ported from Flutter music_player_sheet.dart:
// - immersive face: blurred cover + dark gradient background; white
//   text in opacity levels (1.0 / 0.85 / 0.72 / 0.55). This page is
//   a forced dark immersive face — the background is cover-tinted,
//   independent of the theme light/dark mode.
// - large square cover, centred, rounded corners; below it,
//   left-aligned bold white title + lighter artist, star + … on the
//   right; quality badge below the cover (the ACTUAL tier — a
//   drop-down never shows as Master).
// - thin progress bar, elapsed left, remaining right; drag changes
//   only local state, seek fires once on release.
// - three big white triangles prev/play/next, NO background circles.
// - bottom row: 3 pure icons only (lyrics / AirPlay / queue).
// - NO volume slider on iOS (chen: iOS 上不要音量滑杆).
// - lyrics live BEHIND the cover: tap cover -> lyrics in the cover
//   area; tap a lyric line -> seek to that line; tap lyric blank ->
//   cover back. No word-level karaoke: no source returns word timing.
// - whole player fits on one phone screen, no scrolling: the
//   cover / lyrics slot is sized by width AND by the height left
//   after the fixed chrome (see coverSize), so short phones
//   shrink the cover instead of clipping the bottom rows.
// - CLOSE (chen 2026-11-24: opened player could not be closed):
//   fullScreenCover has no system swipe-down dismiss, and the old
//   close control was a bare 32pt white chevron with no scrim —
//   invisible on a light cover and the only way out. Now the
//   close is a 40pt glass circle (Beans PlayerView: 38pt glass
//   circle + white 0.22 hairline) over a 0.55 top scrim, it sets
//   the presenting binding false (Beans closePlayer()), with
//   dismiss() only as fallback, AND a downward swipe anywhere on
//   the player closes it (lyrics mode: swipe must start on the
//   top bar, so the list keeps its vertical drags).
// - WIDTH PIN (chen 2026-11-24, build 35): build 34 on his phone
//   rendered the player ~2x wider than the screen — prev/next
//   triangles at the screen edges, close button / title row /
//   progress times pushed off-screen, the invisible title+progress
//   heights left as a dead gap — while the code reads as a
//   screen-width Spacer layout. Code reading alone cannot name
//   the widening child (not identifiable from Linux), so the
//   stack is now pinned to UIScreen.main.bounds.width: no child
//   can widen it, whatever the culprit is. The pin equals the
//   window width in the normal case (portrait-only player).
//   MusicPlayerLayout holds the pure geometry so the regression
//   guard is arithmetic (MusicPlayerLayoutTests), not a re-read.
//
// AirPlay uses the player leg's AirPlayPickerView (UIViewRepresentable
// wrapping AVRoutePickerView).

import SwiftUI

struct MusicPlayerView: View {
    /// The presenting view's binding. Setting it false is the
    /// close path; defaults to a constant so the view still
    /// compiles anywhere else (then dismiss() is the fallback).
    @Binding var isPresented: Bool
    /// Namespace for the cover morph from the mini player (b35
    /// tab-bar link): when MainTabView passes its namespace, this
    /// cover and the mini cover share one matchedGeometryEffect id
    /// (HaoLayout.playerCoverMorphID), so the cover grows from the
    /// mini (36 / 32 inline) into this full-size cover on open and
    /// shrinks back on close. Nil (default) keeps the old behaviour
    /// — no morph, the player just appears.
    private let coverMorphNamespace: Namespace.ID?

    init(isPresented: Binding<Bool> = .constant(true), coverMorphNamespace: Namespace.ID? = nil) {
        self._isPresented = isPresented
        self.coverMorphNamespace = coverMorphNamespace
    }

    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var showQueue = false
    @State private var showMore = false
    @State private var showSleep = false
    @State private var showQuality = false
    @State private var showEqualizer = false
    @State private var showComments = false
    @State private var showAlbum = false
    @State private var showArtist = false
    @State private var showAddToPlaylistSong: MusicSong?
    @State private var followPausedUntil = Date.distantPast

    var body: some View {
        ZStack {
            playerBackground
            VStack(spacing: 0) {
                topBar
                    .frame(maxWidth: .infinity)
                coverOrLyrics
                    .padding(.top, 8)
                qualityBadge
                    .padding(.top, 12)
                titleRow
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity)
                progressSection
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity)
                transportRow
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity)
                modeRow
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity)
                Spacer()
                bottomRow
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            // Width pin (build 35): a fixed frame, not maxWidth —
            // no child can widen the stack past the screen, which
            // is what build 34 rendered on chen's phone.
            .frame(width: UIScreen.main.bounds.width)
            if let toast = playerVM.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.7), in: Capsule())
                        .padding(.bottom, 90)
                }
            }
        }
        .sheet(isPresented: $showQueue) { MusicQueueView() }
        .sheet(isPresented: $showMore) { moreSheet }
        .sheet(isPresented: $showSleep) { MusicSleepTimerView() }
        .sheet(isPresented: $showQuality) { MusicQualitySheet() }
        .sheet(isPresented: $showEqualizer) { MusicEqualizerView() }
        .sheet(isPresented: $showComments) { MusicCommentsView() }
        .sheet(isPresented: $showAlbum) {
            if let song = playerVM.currentSong {
                NavigationStack {
                    MusicAlbumDetailView(album: AlbumSummary(
                        id: "", name: song.album, artist: song.artist,
                        platform: song.platform))
                }
            }
        }
        .sheet(isPresented: $showArtist) {
            if let song = playerVM.currentSong {
                NavigationStack {
                    MusicArtistDetailView(artist: ArtistSummary(
                        id: "", name: MusicAPIJSON.firstArtist(song.artist),
                        platform: song.platform))
                }
            }
        }
        .sheet(item: $showAddToPlaylistSong) { song in
            MusicAddToPlaylistSheet(song: song) { showAddToPlaylistSong = nil }
        }
        // Swipe down to close (see handleDismissDrag): simultaneous
        // so the Slider and the lyrics list keep their own drags.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24).onEnded(handleDismissDrag)
        )
    }

    /// Close the player. The binding is the authority (Beans
    /// PlayerView: closePlayer() sets isPresented = false) — the
    /// environment dismiss is only a fallback, so the close path
    /// never depends on which presentation wrapper the caller used.
    private func close() {
        isPresented = false
        dismiss()
    }

    /// Swipe-down dismiss. fullScreenCover has no system swipe
    /// dismiss, so the player supplies its own. Only a clearly
    /// downward swipe closes (horizontal drags belong to the
    /// Slider); in lyrics mode the swipe must start on the top bar
    /// because the lyrics list owns vertical drags elsewhere.
    private func handleDismissDrag(_ value: DragGesture.Value) {
        let translation = value.translation
        guard translation.height > 100, abs(translation.width) < 80 else { return }
        if playerVM.showLyrics && value.startLocation.y > 140 { return }
        close()
    }

    /// Cover / lyrics slot size (pure math in MusicPlayerLayout,
    /// tested by MusicPlayerLayoutTests): bounded by width AND by
    /// the height left after the fixed chrome (~330pt: top bar 40
    /// + gaps 60 + badge 23 + title 45 + progress 52 + transport
    /// 52 + mode 28 + bottom row 30) + safe areas + slack, so the
    /// whole player fits on one screen with no scrolling on any
    /// phone height. Tall phones (iPhone Air, 874pt) still get the
    /// 340 cap — the design there is unchanged; short phones
    /// shrink the cover instead of clipping the bottom rows.
    private var coverSize: CGFloat {
        let bounds = UIScreen.main.bounds
        return MusicPlayerLayout.coverSize(
            screenWidth: bounds.width, screenHeight: bounds.height)
    }

    // MARK: - Background

    private var playerBackground: some View {
        ZStack {
            if let cover = playerVM.currentSong?.cover,
               let url = URL(string: cover), !cover.isEmpty {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                            .blur(radius: 60)
                            .scaleEffect(1.2)
                    } else {
                        Color.black
                    }
                }
            } else {
                Color.black
            }
            // Uniform dim + top-to-bottom gradient: the blurred
            // cover can be LIGHT (the reported song's cover reads
            // ~137 grey at the top of the screenshot), and white
            // 0.72-opacity text over it falls below 2:1 contrast —
            // illegible. The dim guarantees every white text role
            // stays legible on any cover while the tint still shows
            // through; on a dark cover it is invisible.
            Color.black.opacity(0.42)
            LinearGradient(
                colors: [Color.black.opacity(0.30), Color.black.opacity(0.45)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button(action: { close() }) {
                Image(systemName: "chevron.down")
                    // Beans PlayerView: chevron.down 15 semibold in a
                    // 38pt glass circle + white 0.22 hairline; ours
                    // is 40pt so the hit target is closer to Apple's
                    // 44pt minimum. The old control was a bare 32pt
                    // white glyph with no surface — invisible on a
                    // light cover and the player's only way out.
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .haoGlassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
            Spacer()
            Text(playerVM.currentSong?.album ?? "")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
            Spacer()
            // No … button here (fix 2026-11-24, build 35): the
            // title row already has one opening the same sheet.
            // The clear 40pt block only balances the close button
            // so the album title stays truly centred — it is
            // layout, not a control.
            Color.clear.frame(width: 40, height: 40)
        }
        // Top scrim so the buttons read on any (even light) cover —
        // the same 0.55 -> 0 top gradient the VOD player uses.
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    // MARK: - Cover / lyrics

    private var coverOrLyrics: some View {
        Group {
            if playerVM.showLyrics {
                lyricsArea
            } else {
                coverArea
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var coverArea: some View {
        let size = coverSize
        return Button(action: { playerVM.toggleLyrics() }) {
            morphCover(size: size)
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("封面，点按查看歌词")
    }

    /// The cover, with the mini-player morph attached when the
    /// presenter supplied the namespace (see coverMorphNamespace).
    /// The corner radius is NOT part of the morph
    /// (matchedGeometryEffect moves the frame only): it snaps from
    /// the mini's 7 (6 inline) to min(24, size * 0.08) at the end of
    /// the transition. When lyrics are showing, coverArea is not
    /// rendered at all, so there is no destination to morph to and
    /// the player simply appears — the close path is unaffected.
    @ViewBuilder
    private func morphCover(size: CGFloat) -> some View {
        let cover = MusicCoverView(
            urlString: playerVM.currentSong?.cover ?? "",
            size: size,
            // Beans PlayerView: min(24, size * 0.08) — 24 at 340.
            cornerRadius: min(24, size * 0.08)
        )
        if let namespace = coverMorphNamespace {
            cover.matchedGeometryEffect(id: HaoLayout.playerCoverMorphID, in: namespace)
        } else {
            cover
        }
    }

    private var lyricsArea: some View {
        let height = coverSize
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // Blank space above the lines: tap -> cover back.
                    // (The tap target is ONLY the blank spacers, never
                    // the rows: a tap gesture on the whole list would
                    // also fire when a lyric row is tapped, seeking
                    // AND flipping back at once.)
                    Color.clear
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .onTapGesture { playerVM.toggleLyrics() }
                    if !playerVM.lyricsLoaded {
                        ProgressView()
                            .tint(.white)
                            .frame(height: height - 48)
                    } else if playerVM.lyrics.isEmpty {
                        Text("暂无歌词")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(height: height - 48)
                            .contentShape(Rectangle())
                            .onTapGesture { playerVM.toggleLyrics() }
                    } else {
                        ForEach(Array(playerVM.lyrics.enumerated()), id: \.offset) { index, line in
                            Button(action: {
                                playerVM.seek(to: line.time)
                            }) {
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(
                                        size: index == playerVM.activeLyricIndex ? 18 : 15,
                                        weight: index == playerVM.activeLyricIndex ? .bold : .regular
                                    ))
                                    .foregroundStyle(.white.opacity(
                                        index == playerVM.activeLyricIndex ? 1.0 : 0.55
                                    ))
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    // Blank space below the lines: tap -> cover back.
                    Color.clear
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .onTapGesture { playerVM.toggleLyrics() }
                }
                .frame(minHeight: height)
            }
            .frame(height: height)
            .simultaneousGesture(
                DragGesture(minimumDistance: 10).onChanged { _ in
                    // Manual scroll pauses auto-follow for 5 s so the
                    // list never fights the finger (Flutter: 5 s).
                    followPausedUntil = Date().addingTimeInterval(5)
                }
            )
            .onChange(of: playerVM.activeLyricIndex) { _, index in
                guard index >= 0, Date() >= followPausedUntil else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
        .accessibilityLabel("歌词，点行跳转，点空白回封面")
    }

    // MARK: - Quality badge

    private var qualityBadge: some View {
        Group {
            if let label = playerVM.qualityBadgeLabel {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                    }
            } else {
                Text(" ")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Title row

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(playerVM.currentSong?.title ?? "未在播放")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(playerVM.currentSong?.artist ?? "")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            Spacer()
            Button(action: { playerVM.toggleFavourite() }) {
                Image(systemName: playerVM.isCurrentFav ? "star.fill" : "star")
                    .font(.system(size: 20, weight: .medium))
                    // White both ways (fix 2026-11-24, build 35):
                    // filled vs outline carries the state, inside
                    // the white icon system — the yellow star broke
                    // it (chen's reference: white icons throughout).
                    .foregroundStyle(playerVM.isCurrentFav ? .white : .white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playerVM.isCurrentFav ? "取消收藏" : "收藏")
            Button(action: { showMore = true }) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更多")
        }
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(spacing: 6) {
            thinProgressBar
            HStack {
                Text(musicDurationText(seconds: Int(playerVM.scrubSeconds ?? playerVM.position)))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text(remainingText)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    /// Thin progress bar (fix 2026-11-24, build 35): the native
    /// Slider's track is nearly invisible at 0 progress — build 34
    /// showed only a faint line and no times. A 4pt bar with an
    /// always-visible track + white fill matches chen's reference
    /// (thin bar, elapsed left, remaining right) and reads in
    /// every state, including a failed song (duration 0: empty
    /// fill, honest 0:00 / -0:00). Drag scrubs locally; seek fires
    /// once on release and the VM rolls back on failure — the same
    /// semantics the Slider had (see seek(to:)).
    private var thinProgressBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(playerVM.duration, 0)
            let current = playerVM.scrubSeconds ?? playerVM.position
            let ratio = duration > 0 ? min(max(current / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(height: 4)
                Capsule()
                    .fill(.white)
                    .frame(width: max(0, width * ratio), height: 4)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let r = min(max(value.location.x / width, 0), 1)
                        playerVM.scrubSeconds = r * max(playerVM.duration, 1)
                    }
                    .onEnded { value in
                        let r = min(max(value.location.x / width, 0), 1)
                        playerVM.seek(to: r * max(playerVM.duration, 1))
                    }
            )
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(musicDurationText(seconds: Int(current))) / \(musicDurationText(seconds: Int(duration)))")
        }
        .frame(height: 4)
    }

    private var remainingText: String {
        let remaining = max(0, Int(playerVM.duration - (playerVM.scrubSeconds ?? playerVM.position)))
        return "-\(musicDurationText(seconds: remaining))"
    }

    // MARK: - Transport

    private var transportRow: some View {
        HStack(spacing: 0) {
            Spacer()
            Button(action: { playerVM.previous() }) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("上一首")
            Spacer()
            Button(action: { playerVM.togglePlayPause() }) {
                Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playerVM.isPlaying ? "暂停" : "播放")
            Spacer()
            Button(action: { playerVM.next() }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下一首")
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Mode / speed / sleep / EQ

    private var modeRow: some View {
        // Spacing 16 (fix 2026-11-24, build 35): 24 overflowed the
        // 320pt iPhone SE (row ≈ 333 > 272 usable). Labels 12pt —
        // secondary chrome, still legible; icons stay 14.
        HStack(spacing: 16) {
            Button(action: { playerVM.cycleMode() }) {
                HStack(spacing: 5) {
                    Image(systemName: playerVM.playMode.icon)
                        .font(.system(size: 14, weight: .semibold))
                    Text(playerVM.playMode.label)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("播放模式：\(playerVM.playMode.label)")
            Menu {
                ForEach([0.6, 0.8, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                    Button(String(format: "%.2fx", speed).replacingOccurrences(of: ".00", with: ".0")) {
                        playerVM.setSpeed(speed)
                    }
                }
            } label: {
                Text(String(format: "%.1fx", playerVM.playbackSpeed))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                    }
            }
            .accessibilityLabel("倍速")
            Button(action: { showSleep = true }) {
                HStack(spacing: 5) {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text(playerVM.sleepActive ? playerVM.sleepRemainingText : "睡眠")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("睡眠定时")
            Button(action: { showEqualizer = true }) {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold))
                    Text("均衡器")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("均衡器")
        }
    }

    // MARK: - Bottom row (3 pure icons only)

    private var bottomRow: some View {
        HStack(spacing: 0) {
            Spacer()
            Button(action: { playerVM.toggleLyrics() }) {
                Image(systemName: "text.quote")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("歌词")
            Spacer()
            MusicAirPlayButton()
            Spacer()
            Button(action: { showQueue = true }) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("播放队列")
            Spacer()
        }
    }

    // MARK: - More sheet

    private var moreSheet: some View {
        NavigationStack {
            List {
                Section {
                    Button(playerVM.isCurrentFav ? "取消收藏" : "收藏") {
                        playerVM.toggleFavourite()
                        showMore = false
                    }
                    if let song = playerVM.currentSong {
                        Button("添加到歌单") {
                            showMore = false
                            showAddToPlaylistSong = song
                        }
                        Button("下载") {
                            showMore = false
                            playerVM.downloadCurrent()
                        }
                    }
                    Button("查看评论（只读）") {
                        showMore = false
                        showComments = true
                    }
                    if let song = playerVM.currentSong, !song.album.isEmpty {
                        Button("查看专辑") {
                            showMore = false
                            showAlbum = true
                        }
                    }
                    if let song = playerVM.currentSong, !song.artist.isEmpty {
                        Button("查看歌手") {
                            showMore = false
                            showArtist = true
                        }
                    }
                }
                Section("音质") {
                    Button("音质选择（目标：\(MusicLibraryStore.badgeLabel(for: coordinator.targetQuality))）") {
                        showMore = false
                        showQuality = true
                    }
                    Button("均衡器") {
                        showMore = false
                        showEqualizer = true
                    }
                }
                Section("歌词") {
                    HStack {
                        Text("歌词偏移")
                        Spacer()
                        Text(MusicLyrics.offsetLabel(playerVM.lyricOffsetMs))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(playerVM.lyricOffsetMs) },
                            set: { playerVM.lyricOffsetMs = Int($0) }
                        ),
                        in: -5000...5000, step: 100
                    )
                }
                Section("反馈") {
                    Toggle("触感反馈", isOn: Binding(
                        get: { MusicLibraryStore.hapticsEnabled() },
                        set: { MusicLibraryStore.setHapticsEnabled($0) }
                    ))
                }
            }
            .navigationTitle("更多")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { showMore = false }
                }
            }
        }
    }
}

/// AirPlay button: the player leg's AirPlayPickerView (UIViewRepresentable
/// wrapping AVRoutePickerView). Fixed 28pt so the row stays aligned.
struct MusicAirPlayButton: View {
    var body: some View {
        AirPlayPickerView()
            .frame(width: 28, height: 28)
            .accessibilityLabel("AirPlay")
    }
}

/// Pure layout math for the full music player (fix 2026-11-24,
/// build 35). The view pins its stack to the screen width and
/// sizes the cover from these values, so the geometry is testable
/// without SwiftUI (MusicPlayerLayoutTests): build 34 rendered the
/// player ~2x wider than the screen on chen's phone, and the
/// regression guard is arithmetic — every row's width against the
/// screen width on every shipping iPhone width — not a code read.
enum MusicPlayerLayout {
    /// Horizontal side padding of the player stack (24pt each side).
    static let sidePadding: CGFloat = 24
    /// Fixed chrome below the cover slot (~330pt: top bar 40 + gaps
    /// 60 + badge 23 + title 45 + progress 52 + transport 52 +
    /// mode 28 + bottom row 30) + safe areas + slack — the height
    /// budget the cover shrinks against on short phones.
    static let fixedChromeHeight: CGFloat = 330

    static func contentWidth(screenWidth: CGFloat) -> CGFloat {
        screenWidth - sidePadding * 2
    }

    /// Cover / lyrics slot size: bounded by width AND by the height
    /// left after the fixed chrome, so the whole player fits on one
    /// screen with no scrolling on any phone height. Tall phones
    /// still get the 340 cap.
    static func coverSize(screenWidth: CGFloat, screenHeight: CGFloat) -> CGFloat {
        min(screenWidth - sidePadding * 2, 340, max(180, screenHeight - 460))
    }

    /// The whole player fits on one screen iff cover + chrome +
    /// safe areas fit the height. Safe areas are iPhone values
    /// (status bar 59 + home indicator 34). The 568pt-tall iPhone
    /// SE (1st gen) is below the floor even at the 180 minimum —
    /// a pre-existing limit, not a build-35 regression — so the
    /// test table starts at 667pt.
    static func fitsOneScreen(screenWidth: CGFloat, screenHeight: CGFloat) -> Bool {
        coverSize(screenWidth: screenWidth, screenHeight: screenHeight)
            + fixedChromeHeight + 59 + 34 <= screenHeight
    }

    // MARK: - Transport row (Spacer distribution, pinned width)

    /// Transport glyph widths: prev/next 40pt font, play 52pt
    /// font; SF Symbols at these sizes are ~40/52/40 wide.
    /// Side padding inside the row is 16pt.
    static let transportContentWidth: CGFloat = 40 + 52 + 40
    static let transportSidePadding: CGFloat = 16

    /// Centres of the three transport buttons for a screen width,
    /// under the pinned layout (row = content width, 4 equal
    /// spacers). All three must lie inside the screen — the build
    /// 34 failure was prev/next at the screen edges.
    static func transportCentres(screenWidth: CGFloat) -> (prev: CGFloat, play: CGFloat, next: CGFloat) {
        let content = contentWidth(screenWidth: screenWidth)
        let row = content - transportSidePadding * 2
        let spacer = (row - transportContentWidth) / 4
        let prev = sidePadding + transportSidePadding + spacer + 20
        let play = screenWidth / 2
        let next = screenWidth - prev
        return (prev, play, next)
    }

    // MARK: - Mode row (must fit the narrowest phone)

    /// Mode-row spacing (16pt — was 24, which overflowed the
    /// 320pt iPhone SE) and item widths at the 12pt label size
    /// (upper bounds: icon 14 + 5 gap + label).
    static let modeRowSpacing: CGFloat = 16
    /// 顺序播放 / 1.0x / 睡眠 / 均衡器.
    static let modeRowItemWidths: [CGFloat] = [67, 50, 45, 57]

    static func modeRowFits(screenWidth: CGFloat) -> Bool {
        modeRowItemWidths.reduce(0, +)
            + modeRowSpacing * CGFloat(modeRowItemWidths.count - 1)
            <= contentWidth(screenWidth: screenWidth)
    }
}

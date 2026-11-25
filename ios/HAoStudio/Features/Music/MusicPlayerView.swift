// HAo Studio 2.0 — full music player (S2-C leg; Apple Music redo,
// build 36 item 2).
//
// chen's standard is Apple Music Now Playing (iOS 27): the order
// from top to bottom is cover -> title/artist + star + … ->
// progress (elapsed left, remaining right) -> transport ->
// bottom row of 3 pure icons (lyrics / AirPlay / queue). No text
// labels on the bottom controls.
// - immersive face: the cover's own colours — Muzify's ArtColor
//   clamps (MIT) for the tint, Kumone's 3-layer backdrop (LGPL,
//   numbers re-implemented) for the gradient; white text in
//   opacity levels (1.0 / 0.85 / 0.72 / 0.55).
// - large square cover, centred, rounded corners 8 (Muzify);
//   below it, left-aligned bold title + lighter artist, star +
//   … on the right; quality badge below the cover (the ACTUAL
//   tier — a drop-down never shows as Master).
// - thin progress bar (4pt, 10pt white knob), elapsed left,
//   remaining right; drag changes only local state, seek fires
//   once on release.
// - three big white triangles prev/play/next, NO background
//   circles; press-scale 0.92.
// - NO volume slider (build 37, chen 2026-11-24: "音乐播放器的
//   音量调整没用的 直接删掉" — deleted outright with its
//   plumbing; the hardware buttons / Control Center are the
//   volume control now).
// - NO mode row (build 37): Apple Music has no such row —
//   shuffle / repeat live in its queue sheet and speed / sleep
//   / EQ do not exist there at all. The play mode, speed and
//   sleep timer moved to the … sheet ("播放" section); EQ was
//   already there.
// - bottom row: 3 pure icons only (lyrics / AirPlay / queue).
// - lyrics live BEHIND the cover: tap cover -> lyrics in the
//   cover area; tap a lyric line -> seek to that line; tap lyric
//   blank -> cover back. Current line 22 bold. No word-level
//   karaoke: no source returns word timing.
// - title / artist are tappable (Apple Music: tap the artist
//   below the title to go to the artist, tap the title for the
//   album) — the same sheets the … menu already opened.
// - whole player fits on one phone screen, no scrolling: the
//   cover / lyrics slot is sized by width AND by the height left
//   after the fixed chrome (see coverSize), so short phones
//   shrink the cover instead of clipping the bottom rows.
// - LANDSCAPE (build 36: build 35 left the landscape player
//   overflowing — the portrait chrome + a 340 cover cannot fit
//   in ~390pt of height): landscape is a two-column layout,
//   cover + badge on the left, all the controls in a right
//   column (top bar, title, progress, transport, bottom row).
//   Same components, same sizes where they fit.
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
//   stack is pinned to the screen width minus the safe-area
//   side insets: no child can widen it, whatever the culprit is.
//   The pin equals the window width in the normal case
//   (portrait has no side insets); in landscape it keeps the
//   content out of the notch / Dynamic Island side zones.
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

    /// Dominant cover colour for the background gradient (b38,
    /// item 1): the average cover colour, saturation-boosted, so
    /// the background reads as the cover's tint. Nil while the
    /// cover loads or when there is no cover — the background
    /// falls back to black + blurred cover.
    @State private var coverTint: UIColor?
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
        GeometryReader { geo in
            ZStack {
                playerBackground
                if geo.size.width > geo.size.height {
                    landscapeBody(geo: geo)
                } else {
                    portraitBody(geo: geo)
                }
                if let toast = playerVM.toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.haoFootnoteMedium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.7), in: Capsule())
                            .padding(.bottom, 90)
                            .transition(.opacity)
                    }
                    .animation(.easeInOut(duration: 0.25), value: playerVM.toast)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Cover tint follows the song (b38, item 1): the old
        // tint is cleared synchronously on a song change, so the
        // previous song's colour never lingers; a stale load
        // result is dropped when the cover has moved on.
        .task(id: playerVM.currentSong?.identityKey) {
            let cover = playerVM.currentSong?.cover ?? ""
            coverTint = nil
            guard !cover.isEmpty else { return }
            HaoImageLoader.shared.load(urlString: cover, targetWidthPoints: 120, targetHeightPoints: 120) { image in
                guard let image = image, playerVM.currentSong?.cover == cover else { return }
                coverTint = image.haoAverageTint()
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
    /// because the lyrics list owns vertical drags elsewhere. The
    /// top-bar zone is 140pt in portrait and the 60pt top strip
    /// in landscape (the screen is short there).
    private func handleDismissDrag(_ value: DragGesture.Value) {
        let translation = value.translation
        guard translation.height > 100, abs(translation.width) < 80 else { return }
        let isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
        if playerVM.showLyrics && value.startLocation.y > (isLandscape ? 60 : 140) { return }
        close()
    }

    /// Content width: the GeometryReader width minus the safe-area
    /// side insets (0 in portrait, the notch zones in landscape).
    /// This is the width pin (build 35) — a fixed frame, not
    /// maxWidth, so no child can widen the stack past the screen.
    private func contentWidth(geo: GeometryProxy) -> CGFloat {
        geo.size.width - geo.safeAreaInsets.leading - geo.safeAreaInsets.trailing
    }

    private func safeWidth(geo: GeometryProxy) -> CGFloat {
        contentWidth(geo: geo)
    }

    private func safeHeight(geo: GeometryProxy) -> CGFloat {
        geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom
    }

    // MARK: - Portrait body (Apple Music Now Playing, top to bottom)

    private func portraitBody(geo: GeometryProxy) -> some View {
        // b38, item 1: the slack is shared across the column
        // (one Spacer per gap, minLength 0) instead of a single
        // Spacer above the bottom row — the old layout left one
        // ~116pt dead gap between transport and bottom row on
        // chen's phone while the top sat tight. The spacers
        // collapse to 0 on short phones, so the minimum height
        // (and fitsOneScreen) is unchanged.
        VStack(spacing: 0) {
            topBar
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            coverOrLyrics(size: MusicPlayerLayout.coverSize(
                screenWidth: geo.size.width, screenHeight: geo.size.height))
                .padding(.top, 8)
            Spacer(minLength: 0)
            qualityBadge
                .padding(.top, 12)
            Spacer(minLength: 0)
            titleRow
                .padding(.top, 10)
                .frame(maxWidth: .infinity)
            if playerVM.loadFailed {
                loadFailedBanner
                    .padding(.top, 10)
            }
            Spacer(minLength: 0)
            progressSection
                .padding(.top, 14)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            transportRow
                .padding(.top, 6)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            bottomRow
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .frame(width: contentWidth(geo: geo))
    }

    /// Persistent "无法播放" state (b38, item 1): the old player
    /// sat silently at 0:00 after a failed request — only a 2 s
    /// toast said anything. The banner names the failure and
    /// offers a retry in place; the progress bar underneath stays
    /// an honest 0:00 / -0:00.
    private var loadFailedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
            Text("无法播放")
                .font(.haoSubhead)
                .foregroundStyle(.white.opacity(0.72))
            Button("重试") {
                playerVM.retryCurrentSong()
            }
            .font(.haoSubheadStrong)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("重试播放")
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Landscape body (two columns: cover left, controls right)

    /// Landscape cannot stack the portrait column — cover 340 +
    /// chrome 284 needs ~700pt of height and the screen only has
    /// ~390. Apple Music's landscape Now Playing puts the artwork
    /// on the left and the controls on the right; this does the
    /// same with the same components (cover/lyrics slot, badge,
    /// title, progress, transport, bottom row), so
    /// nothing is lost or re-implemented for the orientation.
    private func landscapeBody(geo: GeometryProxy) -> some View {
        let cover = MusicPlayerLayout.landscapeCoverSize(
            safeWidth: safeWidth(geo: geo), safeHeight: safeHeight(geo: geo))
        return HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 0) {
                coverOrLyrics(size: cover)
                qualityBadge
                    .padding(.top, 12)
            }
            .frame(width: cover)
            VStack(spacing: 0) {
                topBar
                    .frame(maxWidth: .infinity)
                titleRow
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
                if playerVM.loadFailed {
                    loadFailedBanner
                        .padding(.top, 8)
                }
                progressSection
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
                transportRow
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity)
                Spacer()
                bottomRow
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(width: contentWidth(geo: geo))
    }

    // MARK: - Background

    private var playerBackground: some View {
        ZStack {
            if let tint = coverTint {
                // Kumone backdrop (LGPL, reference only — numbers
                // re-implemented, no code copied), three layers:
                // primary -> secondary diagonal gradient, a white
                // 0.12 radial lift at the top-left, and a
                // clear -> black 0.35 bottom press for legibility.
                // Gradient-only while the tint is known — both
                // refs (Kumone, Muzify) do the background this
                // way; the blurred-cover layer underneath used to
                // mute the tint back to grey.
                LinearGradient(
                    colors: [Color(tint), Color(tint.haoSecondary())],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [.white.opacity(0.12), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 700
                )
                LinearGradient(
                    colors: [.clear, .black.opacity(0.35)],
                    startPoint: .top, endPoint: .bottom
                )
            } else {
                // No tint yet (cover loading / no cover): the old
                // blurred-cover backdrop with light veils, so the
                // screen is never pure black while waiting.
                if let cover = playerVM.currentSong?.cover, !cover.isEmpty {
                    // Shared loader (build 36 item 10 leg 6): the same
                    // cover the main cover view loads, downsampled to
                    // screen size — one download for both, via the
                    // disk cache, instead of two independent full-size
                    // fetches. The loader also upgrades http -> https,
                    // which this path never did (an http cover silently
                    // stayed black here while the main cover loaded).
                    let target = HaoImageLoader.fullScreenTargetPoints
                    HaoCachedImage(
                        urlString: cover,
                        targetWidth: CGFloat(target.width),
                        targetHeight: CGFloat(target.height)
                    ) { image in
                        image.resizable().scaledToFill()
                            .blur(radius: 60)
                            .scaleEffect(1.2)
                    } placeholder: {
                        Color.black
                    }
                } else {
                    Color.black
                }
                Color.black.opacity(0.08)
                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.22)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
        // Kumone backdrop animates colour changes over 0.8 s;
        // keyed on the song so a song change cross-fades the tint
        // instead of snapping it.
        .animation(.easeInOut(duration: 0.8), value: playerVM.currentSong?.identityKey ?? "")
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
                    .font(.haoSubheadStrong)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .haoGlassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
            Spacer()
            Text(playerVM.currentSong?.album ?? "")
                .font(.haoDenseBody)
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

    private func coverOrLyrics(size: CGFloat) -> some View {
        Group {
            if playerVM.showLyrics {
                lyricsArea(height: size)
            } else {
                coverArea(size: size)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func coverArea(size: CGFloat) -> some View {
        Button(action: { playerVM.toggleLyrics() }) {
            morphCover(size: size)
            // Muzify (MIT): black 45%, radius 24, y 12.
            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
            // Muzify (MIT): the cover breathes with playback —
            // 1.0 playing, 0.92 paused.
            .scaleEffect(playerVM.isPlaying ? 1 : 0.92)
            .animation(.spring(response: 0.45, dampingFraction: 0.75), value: playerVM.isPlaying)
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
        // b39 (Sonar): the cover crossfades on track change —
        // the old art fades out as the new art fades in, the way
        // Sonar's player crossfades artwork + background colour.
        // The identity + transition live on the INNER cover only:
        // the outer view keeps matchedGeometryEffect for the mini
        // morph, and a song never changes mid-presentation, so
        // the fade runs only on track change while open.
        let cover = MusicCoverView(
            urlString: playerVM.currentSong?.cover ?? "",
            size: size,
            // Muzify (MIT, MobileNowPlaying L20-25): radius 8.
            cornerRadius: 8
        )
        .id(playerVM.currentSong?.identityKey ?? "")
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.35), value: playerVM.currentSong?.identityKey ?? "")
        if let namespace = coverMorphNamespace {
            cover.matchedGeometryEffect(id: HaoLayout.playerCoverMorphID, in: namespace)
        } else {
            cover
        }
    }

    private func lyricsArea(height: CGFloat) -> some View {
        ScrollViewReader { proxy in
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
                        if playerVM.lyricsLoadFailed {
                            // §3.3 retry: the fetch returned nothing
                            // on a platform that has a lyrics endpoint
                            // (network failure or no lyrics published
                            // — the API cannot tell the two apart, so
                            // the wording stays neutral). The button is
                            // the only tap target here: unlike the plain
                            // empty state it must NOT flip back to the
                            // cover, or the retry could never be tapped
                            // without leaving lyrics.
                            VStack(spacing: 12) {
                                Text("未能加载歌词")
                                    .font(.haoSubhead)
                                    .foregroundStyle(.white.opacity(0.55))
                                Button("重新加载") {
                                    playerVM.retryLyrics()
                                }
                                .font(.haoSubheadStrong)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                                }
                                .buttonStyle(.plain)
                            }
                            .frame(height: height - 48)
                        } else {
                            Text("暂无歌词")
                                .font(.haoSubhead)
                                .foregroundStyle(.white.opacity(0.55))
                                .frame(height: height - 48)
                                .contentShape(Rectangle())
                                .onTapGesture { playerVM.toggleLyrics() }
                        }
                    } else {
                        ForEach(Array(playerVM.lyrics.enumerated()), id: \.offset) { index, line in
                            Button(action: {
                                playerVM.seek(to: line.time)
                            }) {
                                // A11: the translation (when one was
                                // matched and the switch is on) rides
                                // under its line, smaller and dimmer.
                                VStack(spacing: 2) {
                                    Text(line.text.isEmpty ? " " : line.text)
                                        // Apple Music lyrics: the
                                        // current line grows and
                                        // brightens (22 -> 28pt in
                                        // the full lyrics view); in
                                        // this cover slot the step is
                                        // 16 -> 22, eased over 0.3s.
                                        .font(.system(
                                            size: index == playerVM.activeLyricIndex ? 22 : 16,
                                            weight: index == playerVM.activeLyricIndex ? .bold : .regular
                                        ))
                                        .foregroundStyle(.white.opacity(
                                            index == playerVM.activeLyricIndex ? 1.0 : 0.55
                                        ))
                                    if playerVM.showLyricTranslation,
                                       let translation = line.translation, !translation.isEmpty {
                                        Text(translation)
                                            .font(.system(
                                                size: index == playerVM.activeLyricIndex ? 15 : 13
                                            ))
                                            .foregroundStyle(.white.opacity(
                                                index == playerVM.activeLyricIndex ? 0.85 : 0.4
                                            ))
                                    }
                                }
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
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
                // The active line's size step eases over 0.3s
                // (Apple Music lyrics transition), it does not snap.
                .animation(.easeInOut(duration: 0.3), value: playerVM.activeLyricIndex)
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
                    .font(.haoCaption2Strong)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                    }
            } else {
                Text(" ")
                    .font(.haoCaption2Strong)
                    .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Title row

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                // Apple Music: the title opens the album, the
                // artist opens the artist — the same sheets the …
                // menu already opened, so no new destination is
                // invented. Empty title / artist is not tappable.
                Button(action: { showAlbum = true }) {
                    Text(playerVM.currentSong?.title ?? "未在播放")
                        .font(.haoSectionTitle)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled((playerVM.currentSong?.album ?? "").isEmpty)
                .accessibilityLabel("专辑：\(playerVM.currentSong?.album ?? "")")
                Button(action: { showArtist = true }) {
                    Text(playerVM.currentSong?.artist ?? "")
                        .font(.haoCallout)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled((playerVM.currentSong?.artist ?? "").isEmpty)
                .accessibilityLabel("歌手：\(playerVM.currentSong?.artist ?? "")")
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
                    .font(.haoCaption)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text(remainingText)
                    .font(.haoCaption)
                    .monospacedDigit()
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
    /// Build 37: the visual stays 4pt but the HIT area is 28pt
    /// (the old 4pt frame was nearly untappable — the drag only
    /// fired when the finger landed exactly on the 4pt line).
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
                // Apple Music's scrubber knob: a small white dot
                // at the fill end, so the bar reads as draggable
                // even at 0 progress. Clamped inside the track.
                Circle()
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: min(max(width * ratio - 5, 0), max(0, width - 10)))
            }
            .frame(height: 28)
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
        .frame(height: 28)
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
            .buttonStyle(MusicPressScaleStyle())
            .accessibilityLabel("上一首")
            Spacer()
            Button(action: { playerVM.togglePlayPause() }) {
                Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(.white)
            }
            .buttonStyle(MusicPressScaleStyle())
            .accessibilityLabel(playerVM.isPlaying ? "暂停" : "播放")
            Spacer()
            Button(action: { playerVM.next() }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.white)
            }
            .buttonStyle(MusicPressScaleStyle())
            .accessibilityLabel("下一首")
            Spacer()
        }
        .padding(.horizontal, 16)
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
            .buttonStyle(MusicPressScaleStyle())
            .accessibilityLabel("歌词")
            Spacer()
            MusicAirPlayButton()
            Spacer()
            Button(action: { showQueue = true }) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(MusicPressScaleStyle())
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
                // Build 37: the old mode row (play mode / speed /
                // sleep / EQ) is gone — Apple Music has no such row.
                // EQ was already here; the other three live in
                // this section now. The play-mode row does NOT
                // close the sheet on tap, so the new mode label
                // is visible in place (it is shown nowhere else
                // on the player any more).
                Section("播放") {
                    Button {
                        playerVM.cycleMode()
                    } label: {
                        HStack {
                            Text("播放模式")
                            Spacer()
                            Text(playerVM.playMode.label)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Menu {
                        ForEach([0.6, 0.8, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                            Button(action: { playerVM.setSpeed(speed) }) {
                                HStack {
                                    Text(String(format: "%.2fx", speed).replacingOccurrences(of: ".00", with: ".0"))
                                    if speed == playerVM.playbackSpeed {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text("倍速")
                            Spacer()
                            Text(String(format: "%.1fx", playerVM.playbackSpeed))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        showMore = false
                        showSleep = true
                    } label: {
                        HStack {
                            Text("睡眠定时")
                            Spacer()
                            Text(playerVM.sleepActive ? playerVM.sleepRemainingText : "未设置")
                                .foregroundStyle(.secondary)
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
                    // E5: translation switch, same section as the
                    // offset (A11). Default on.
                    Toggle("显示翻译", isOn: $playerVM.showLyricTranslation)
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
/// build 35; Apple Music redo + landscape, build 36 item 2). The
/// view pins its stack to the screen width minus the safe-area side
/// insets and sizes the cover from these values, so the geometry is
/// testable without SwiftUI (MusicPlayerLayoutTests): build 34
/// rendered the player ~2x wider than the screen on chen's phone,
/// and the regression guard is arithmetic — every row's width
/// against the screen width on every shipping iPhone width — not a
/// code read.
enum MusicPlayerLayout {
    /// Horizontal side padding of the player stack (24pt each side).
    static let sidePadding: CGFloat = 24
    /// Fixed chrome below the cover slot (~284pt: top bar 40 + gaps
    /// 42 + badge 23 + title 45 + progress 52 + transport 52 +
    /// bottom row 30) + safe areas + slack — the height budget the
    /// cover shrinks against on short phones. Build 37 removes the
    /// volume row (36 + 8 gap) and the mode row (28 + 10 gap)
    /// from build 36's 366.
    static let fixedChromeHeight: CGFloat = 284

    static func contentWidth(screenWidth: CGFloat) -> CGFloat {
        screenWidth - sidePadding * 2
    }

    /// Cover / lyrics slot size: bounded by width AND by the height
    /// left after the fixed chrome, so the whole player fits on one
    /// screen with no scrolling on any phone height. Tall phones
    /// still get the 340 cap.
    static func coverSize(screenWidth: CGFloat, screenHeight: CGFloat) -> CGFloat {
        min(screenWidth - sidePadding * 2, 340, max(180, screenHeight - 388))
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

    // MARK: - Landscape (two columns; build 36)

    /// Right column height in landscape (top bar 40 + title 45 +
    /// progress 24 + transport 52 + bottom 30 + the tighter 6–8pt
    /// landscape gaps ≈ 217). The left column is cover + badge
    /// (35). Both must fit the safe height. Build 37 removes the
    /// volume row (28 + 6 gap) and the mode row (28 + 8 gap) from
    /// build 36's 287.
    static let landscapeRightColumnHeight: CGFloat = 217
    /// Badge height + its top gap in the left column.
    static let landscapeBadgeHeight: CGFloat = 35

    /// Landscape cover / lyrics slot: bounded by 42% of the safe
    /// width (so the right column keeps room for the transport),
    /// by the safe height minus badge (35) + vertical padding
    /// (24) + slack (37), and by the same 340 cap as portrait.
    /// The 96pt height term is what keeps the left column
    /// (cover + badge 35 + padding 24 + slack 37) inside the safe
    /// height on the narrowest landscape phone (SE 1st gen,
    /// 568pt: cover 224, left column 271 vs safe height 320).
    static func landscapeCoverSize(safeWidth: CGFloat, safeHeight: CGFloat) -> CGFloat {
        min(safeWidth * 0.42, safeHeight - 96, 340)
    }

    /// The landscape player fits on one screen iff the left column
    /// (cover + badge) and the right column (all controls) both fit
    /// the safe height. Safe sizes are the screen minus the
    /// safe-area insets (notch sides + home indicator).
    static func landscapeFitsOneScreen(safeWidth: CGFloat, safeHeight: CGFloat) -> Bool {
        landscapeCoverSize(safeWidth: safeWidth, safeHeight: safeHeight)
            + landscapeBadgeHeight + 12 <= safeHeight
            && landscapeRightColumnHeight + 24 <= safeHeight
    }
}

/// Cover-tint helpers (b38, item 1): the player background is the
/// cover's own colour — Apple Music's album-art-derived gradient.
/// No new dependency: the average is sampled on an 8x8 grid with
/// Core Graphics, and the clamps are Muzify's ArtColor (MIT,
/// Sources/Muzify/UI/Theme.swift L372): saturation <0.12 stays,
/// else 0.45–0.8; brightness 0.38–0.55. The secondary gradient
/// stop is Kumone's rule (LGPL, reference only — numbers
/// re-implemented here, no code copied): hue +0.06, brightness
/// half the primary's, clamped 0.12–0.26.
private extension UIImage {
    func haoAverageTint() -> UIColor? {
        guard let cg = cgImage else { return nil }
        let w = 8, h = 8
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var r = 0, g = 0, b = 0, n = 0
        for i in 0..<(w * h) {
            guard px[i * 4 + 3] > 16 else { continue }
            r += Int(px[i * 4])
            g += Int(px[i * 4 + 1])
            b += Int(px[i * 4 + 2])
            n += 1
        }
        guard n > 0 else { return nil }
        let base = UIColor(
            red: CGFloat(r) / CGFloat(n) / 255,
            green: CGFloat(g) / CGFloat(n) / 255,
            blue: CGFloat(b) / CGFloat(n) / 255,
            alpha: 1
        )
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        if base.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha) {
            // Muzify ArtColor (MIT, Sources/Muzify/UI/Theme.swift
            // L372): near-grey stays near-grey; otherwise clamp
            // saturation 0.45–0.8 and brightness 0.38–0.55, so
            // the tint reads as colour and the white controls
            // stay legible on any cover.
            let clampedSat = sat < 0.12 ? sat : min(0.8, max(0.45, sat))
            return UIColor(
                hue: hue,
                saturation: clampedSat,
                brightness: min(0.55, max(0.38, bri)),
                alpha: 1
            )
        }
        // Greyscale cover: no hue to boost — keep its lightness.
        var white: CGFloat = 0
        base.getWhite(&white, alpha: &alpha)
        return UIColor(white: min(0.6, max(0.25, white)), alpha: 1)
    }
}

private extension UIColor {
    /// Secondary gradient stop (Kumone ArtworkColors rule, see
    /// the file header above): hue +0.06, brightness half the
    /// primary's, clamped 0.12–0.26.
    func haoSecondary() -> UIColor {
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        if getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha) {
            let shiftedHue = hue + 0.06 >= 1 ? hue + 0.06 - 1 : hue + 0.06
            return UIColor(
                hue: shiftedHue, saturation: sat,
                brightness: min(0.26, max(0.12, bri * 0.5)), alpha: alpha
            )
        }
        var white: CGFloat = 0
        getWhite(&white, alpha: &alpha)
        return UIColor(white: min(0.26, max(0.12, white * 0.5)), alpha: alpha)
    }
}

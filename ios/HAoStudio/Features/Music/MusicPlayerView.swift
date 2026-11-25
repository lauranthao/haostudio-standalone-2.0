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
//   blank -> cover back. Current line 28 bold, neighbours 20 and
//   readable (opacity floor 0.45, blur capped at 1.0, no row ever
//   cut); lyrics are left-aligned under a compact header (64pt
//   cover + title/artist + the title row's three actions). No
//   word-level karaoke: no source returns word timing — the
//   per-character wipe is pseudo-syllable timing.
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
//   fullScreenCover has no system swipe-down dismiss. The close
//   is a downward swipe anywhere on the player (lyrics mode:
//   swipe must start on the top bar, so the list keeps its
//   vertical drags) plus the presenting binding set false
//   (Beans closePlayer()) — one close path, no dismiss()
//   fallback (b49: the double-close is gone). b46-player:
//   a 60×5 drag handle sits centred on the top bar as the visual
//   affordance for that swipe, with no scrim behind it (b49:
//   Coda has none; the 0.55 black gradient read as a black band
//   on light covers). The drag stays custom (see
//   handleDismissDrag).
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

import AVFoundation
import SwiftUI

/// Lyrics list scroll offset (b47-player): the lyrics content's
/// minY in the lyrics ScrollView's coordinate space — 0 at the
/// top edge, negative when scrolled. The dismiss drag reads it
/// to know when the list is at its top edge and the drag may
/// take over from scrolling.
private struct LyricsScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct MusicPlayerView: View {
    /// The presenting view's binding. Setting it false is the
    /// close path (the only one — b49 removed the dismiss()
    /// fallback; MainTabView presents via fullScreenCover).
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

    /// Dominant cover colour for the background gradient (b38,
    /// item 1): the average cover colour, saturation-boosted, so
    /// the background reads as the cover's tint. Nil while the
    /// cover loads or when there is no cover — the background
    /// falls back to black + blurred cover.
    @State private var coverTint: UIColor?
    /// Secondary gradient stop from the same palette (b45-a).
    @State private var coverTintSecondary: UIColor?
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
    // b45-a (Coda §2.2/§8.1): cover play bounce — 1.055 easeOut
    // 0.17 s, then spring(0.42, bounce 0.24) back to 1.0. The
    // paused scale is 0.95 (bouncy), not the old 0.92.
    @State private var coverBounce: CGFloat = 1.0
    // b45-a (Coda §2.8): control-bar auto-hide — 3 s without
    // interaction while playing in the lyrics view hides the chrome
    // around the lyrics; any interaction / song change / panel
    // change restores it; VoiceOver never hides it.
    @State private var controlsHidden = false
    @State private var lastControlsInteraction = Date()
    // b45-a (Coda §2.8): cumulative downward lyrics scroll hides
    // the control bar at 200pt; any upward scroll restores it.
    @State private var lyricsScrollDownAccum: CGFloat = 0
    @State private var lastLyricsDragY: CGFloat?
    // b45-g (Coda §8.1 CoverZoomMotion): downward dismiss-drag
    // progress, in points. While a close-candidate drag is in
    // flight the whole surface shrinks toward the mini (min scale
    // 0.86) and rounds up (36pt × min(1, translation/40)); a
    // cancelled drag springs back on playerSpringBack (0.38/0.86).
    // b47-player Coda check (IOSMainWindow.dragGeometry): the
    // scale ramps over the FULL screen height, not the 190pt
    // close threshold — at the 110pt dismiss point Coda is
    // still 0.98, the old /190 ramp was already 0.92.
    @State private var dismissDragY: CGFloat = 0
    /// Translation at which the dismiss gate opened during this
    /// drag (b47-player; nil = gate not yet open). When the gate
    /// opens mid-drag — the drag first scrolled the lyrics list
    /// to its top edge — the morph is anchored there, so the
    /// surface doesn't jump by the scroll distance.
    @State private var dismissDragAnchor: CGFloat?
    /// Whether the dismiss gate was closed at any point during
    /// this drag (the drag started on the lyrics list while it
    /// was scrolled). Distinguishes "gate open from the start"
    /// (anchor 0, morph tracks the raw translation) from "gate
    /// opened mid-drag" (anchor = translation at opening).
    @State private var dismissGateWasClosed = false
    /// Lyrics list scroll offset (b47-player): the content
    /// VStack's minY in the lyrics ScrollView's coordinate space
    /// — 0 at the top edge, negative when scrolled. The dismiss
    /// drag may only take over from the list when it is at its
    /// top edge; further down, the list owns the drag and scrolls.
    @State private var lyricsScrollOffset: CGFloat = 0
    /// Safe-area top inset of the full-screen surface (b47-player:
    /// the root ignores the safe area, so geo reports the real
    /// insets; the dismiss top zone is measured from it).
    @State private var safeTopInset: CGFloat = 59
    /// Full-screen height, tracked from the root GeometryReader
    /// (b47-player Coda check: the drag scale ramps over it).
    @State private var fullScreenHeight: CGFloat = 800
    /// Full-screen width, tracked the same way (b49fix2 B15) —
    /// dismissTopZone reads orientation from the tracked size,
    /// not UIScreen, so Split View / Stage Manager get the real
    /// window width.
    @State private var fullScreenWidth: CGFloat = 390
    /// Drag-linked scale (b47-player Coda check,
    /// IOSMainWindow.dragGeometry): 1.0 at rest, ramping to the
    /// 0.86 floor over the full screen height. The corner radius
    /// below is unchanged: Coda's 36 saturating at 40pt of drag.
    private var dismissDragScale: CGFloat {
        max(0.86, 1 - 0.14 * min(1, dismissDragY / max(1, fullScreenHeight)))
    }
    /// Drag-linked corner radius: 0 at rest, 36pt past 40pt of drag.
    private var dismissDragCornerRadius: CGFloat {
        36 * min(1, dismissDragY / 40)
    }
    // b45-a (Coda §2.8): the lyric row tapped for a seek keeps its
    // confirm state 380 ms (150 ms with Reduce Motion), then the
    // view polls every 50 ms (max 40) until the active line lands
    // on it (2pt tolerance = the active index matching).
    @State private var lyricConfirmIndex: Int?
    @State private var lyricConfirmGeneration = 0
    /// Direction of the last active-line change, for the row
    /// stagger (forward 0.05 s / reverse 0.025 s per row).
    @State private var lyricScrollForward = true
    @State private var prevActiveLyricIndex = -1
    /// Declarative lyrics scroll position (b49): the row id the
    /// list is scrolled to, anchored at 36% of the viewport.
    /// The follow writes it (see the activeLyricIndex onChange);
    /// the user's own scrolling writes it back, and the 3 s
    /// follow pause keeps the follow from fighting the user.
    /// Replaces the imperative ScrollViewReader + scrollTo, which
    /// could silently lose follow with no error.
    @State private var lyricScrollPosition: Int? = nil
    /// b49fix2 P2-43: the follow only writes lyricScrollPosition
    /// while the lyrics are visible; hiding them mid-song (or
    /// changing songs) left a stale index, so the list reopened
    /// at the old line. Reset to the active line whenever the
    /// lyrics become visible or the song changes; nil when the
    /// index is out of range (the follow re-anchors on the next
    /// line change).
    private func resetLyricScrollPosition() {
        let index = playerVM.activeLyricIndex
        lyricScrollPosition = (index >= 0 && index < playerVM.lyrics.count) ? index : nil
    }
    /// The artist name tapped in the multi-artist title row (Coda
    /// §2.3: each artist is its own link; id=0 / empty names are
    /// filtered — we only have names, so empty names are dropped).
    @State private var selectedArtistName = ""

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
                            // b45-g (Coda §8.6 Toast style, plan §11
                            // C20): 12.5pt medium, radius 10, shadow
                            // black 0.15 / radius 8 / y 4, spring
                            // 0.3 in/out. POSITION stays our bottom
                            // capsule slot — only the style params
                            // are Coda's, so the entry edge mirrors
                            // to the bottom. The fill is dark liquid
                            // glass (black 0.7 tint): white text stays
                            // readable in light mode (plain regular
                            // glass would wash it out — theme rule:
                            // light + dark). Dwell stays our 2s —
                            // Coda's was never located (§14 item 1).
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .haoDarkGlassRoundedRect(cornerRadius: HaoLayout.chipCornerRadius, darkness: 0.7)
                            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                            // b47-player: the root is full-screen now,
                            // so the toast keeps its old distance from
                            // the SAFE bottom (toastBottomOffset 90),
                            // not the screen bottom, or it would crowd
                            // the toolbar. b49fix3 P2-37: verified 90
                            // on the music side (live was 96 → 90).
                            .padding(.bottom, HaoLayout.toastBottomOffset + geo.safeAreaInsets.bottom)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .animation(.spring(duration: 0.3), value: playerVM.toast)
                }
            }
            // b45-g: the drag morph — the surface shrinks and rounds
            // as a dismiss drag progresses (see dismissDragY). At
            // rest this is scale 1 / radius 0, i.e. no visual change.
            // b48 (chen 2026-11-25: "动画拖动也没做好", NetEase
            // reference video 14:37): the morph scaled and rounded
            // but never TRANSLATED — the finger went down and the
            // surface stayed put, so the drag felt disconnected.
            // The surface now rides down with the finger 1:1
            // (offset = dismissDragY), like NetEase / Apple Music.
            .offset(y: dismissDragY)
            .scaleEffect(dismissDragScale)
            .clipShape(RoundedRectangle(cornerRadius: dismissDragCornerRadius, style: .continuous))
            .frame(width: geo.size.width, height: geo.size.height)
            .onChange(of: geo.safeAreaInsets.top, initial: true) { _, newValue in
                safeTopInset = newValue
            }
            .onChange(of: geo.size.height, initial: true) { _, newValue in
                fullScreenHeight = newValue
            }
            // b49fix2 B15: track the width too, for dismissTopZone.
            .onChange(of: geo.size.width, initial: true) { _, newValue in
                fullScreenWidth = newValue
            }
            // b49fix2 P2-43: re-anchor the lyrics list whenever it
            // becomes visible or the song changes (see
            // resetLyricScrollPosition) — the follow alone only
            // writes while the list is on screen.
            .onChange(of: playerVM.showLyrics) { _, shown in
                if shown { resetLyricScrollPosition() }
            }
            .onChange(of: playerVM.currentSong?.identityKey) { _, _ in
                resetLyricScrollPosition()
            }
            // b49fix2 P2-27: clearing the queue (or removing its
            // last song) left the full player open on a dead
            // "未在播放" screen — the queue is the player's reason
            // to exist, so when it empties, close to the tab.
            .onChange(of: playerVM.queue.isEmpty) { _, isEmpty in
                if isEmpty && playerVM.currentSong == nil { close() }
            }
        }
        // b47-player (chen build 46: "还不是全屏呀"): the root
        // ignores the safe area, so geo is the FULL screen and the
        // background paints under the status bar and the home
        // indicator. Before this the root was laid out in the safe
        // rect (measured on chen's screenshot: purple [68, 878] of
        // a 912pt screen — the status-bar and home-indicator bands
        // stayed white), because the background's inner
        // ignoresSafeArea cannot paint outside its parent ZStack's
        // safe-sized frame (same trap class as the b43 wallpaper
        // lesson in Glass.swift). Content stays in the safe area
        // via the top/bottom padding in portraitBody/landscapeBody.
        // The surface is always dark (cover tint), so the status
        // bar is forced to light content regardless of the app's
        // appearance — the player's own colours are explicit white
        // / cover tints and the sheets use explicit theme colours,
        // so forcing dark changes no rendered colour, only the
        // system chrome (nav bars, List defaults) which renders
        // dark-coherent with the player.
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        // b49fix2 B11: the player is fixed one-screen chrome (the
        // fixedChromeHeight budget — top bar, transport, toolbar
        // all have fixed heights and the column must fit without
        // scrolling). Unbounded Dynamic Type would overflow it, so
        // text scaling caps at .accessibility1 here: still large
        // for accessibility, but the layout holds.
        .dynamicTypeSize(DynamicTypeSize.xSmall ... DynamicTypeSize.accessibility1)
        // Cover tint follows the song (b38, item 1): the old
        // tint is cleared synchronously on a song change, so the
        // previous song's colour never lingers; a stale load
        // result is dropped when the cover has moved on.
        .task(id: playerVM.currentSong?.identityKey) {
            let cover = playerVM.currentSong?.cover ?? ""
            coverTint = nil
            coverTintSecondary = nil
            guard !cover.isEmpty else { return }
            HaoImageLoader.shared.load(urlString: cover, targetWidthPoints: 120, targetHeightPoints: 120) { image in
                guard let image = image, playerVM.currentSong?.cover == cover else { return }
                let palette = HaoCoverPalette.palette(for: image, key: cover)
                coverTint = palette.primary
                coverTintSecondary = palette.secondary
            }
        }
        // b45-a: the 1 s auto-hide ticker (Coda §2.8) + the cover
        // play bounce (§2.2) + control-bar restore on song change.
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                checkControlsAutoHide()
            }
        }
        .onChange(of: playerVM.isPlaying) { _, playing in
            if playing {
                withAnimation(.easeOut(duration: 0.17)) { coverBounce = 1.055 }
                let work = DispatchWorkItem {
                    withAnimation(HaoPlayerMotion.coverBounceBack) { coverBounce = 1.0 }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.17, execute: work)
            } else {
                coverBounce = 1.0
            }
        }
        .onChange(of: playerVM.currentSong?.identityKey ?? "") { _, _ in
            noteInteraction()
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
                        id: "", name: selectedArtistName.isEmpty
                            ? MusicAPIJSON.firstArtist(song.artist) : selectedArtistName,
                        platform: song.platform))
                }
            }
        }
        .sheet(item: $showAddToPlaylistSong) { song in
            MusicAddToPlaylistSheet(song: song) { showAddToPlaylistSong = nil }
        }
        // Swipe down to close (see handleDismissDrag): simultaneous
        // so the Slider and the lyrics list keep their own drags.
        // The onChanged half drives the drag morph (b45-g); the
        // onEnded half decides close vs spring-back.
        // b48: minimumDistance 0 — the surface follows the finger
        // from the first point of movement. The old 24pt dead zone
        // left the first 24pt of every drag doing nothing, then
        // the morph jumped in late ("没做好" / jump, not smooth).
        // Taps are unaffected (translation ~0 resets the morph)
        // and the lyrics-list gate still owns scrolls.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged(handleDismissDragChanged)
                .onEnded(handleDismissDrag)
        )
    }

    /// Close the player. Single close path (b49): the binding is
    /// the authority (Beans PlayerView: closePlayer() sets
    /// isPresented = false) — the only presentation site is
    /// MainTabView's fullScreenCover(isPresented:), so the
    /// environment dismiss() was a second, redundant close
    /// (double-close on every drag dismiss, build 48). Removed.
    /// b45-a: the close runs on Coda's close spring (response 0.42
    /// / damping 1, CoverZoomMotion.close).
    private func close() {
        withAnimation(HaoPlayerMotion.playerClose) {
            isPresented = false
        }
    }

    /// Mark a user interaction: restores the control bar and
    /// restarts the 3 s auto-hide clock (Coda §2.8).
    private func noteInteraction() {
        lastControlsInteraction = Date()
        if controlsHidden {
            withAnimation(HaoPlayerMotion.controlFade) {
                controlsHidden = false
            }
        }
    }

    /// 1 s auto-hide tick (Coda §2.8): only while playing, in the
    /// lyrics view, not folded, not VoiceOver, with no interaction
    /// for 3 s. VoiceOver never hides the controls.
    private func checkControlsAutoHide() {
        guard playerVM.showLyrics, playerVM.isPlaying,
              !UIAccessibility.isVoiceOverRunning,
              Date().timeIntervalSince(lastControlsInteraction) > 3
        else { return }
        guard !controlsHidden else { return }
        withAnimation(HaoPlayerMotion.controlFade) {
            controlsHidden = true
        }
    }

    /// Swipe-down dismiss. fullScreenCover has no system swipe
    /// dismiss, so the player supplies its own. b45-a (Coda §8.2):
    /// translation > 110pt OR predicted (distance + velocity ×
    /// 0.25) > 190pt closes; horizontal drags belong to the Slider.
    /// b47-player: the distances are measured from the ANCHOR
    /// (dismissDragAnchor) — the translation where the gate
    /// opened — so a drag that first scrolled the lyrics list to
    /// its top edge is judged on the dismiss pull alone, not on
    /// the scroll distance. A drag the gate never opened for (the
    /// list is still scrolled) always springs back.
    /// b45-g: a drag that does NOT close springs the surface back
    /// on Coda's rebound spring (response 0.38 / damping 0.86).
    private func handleDismissDrag(_ value: DragGesture.Value) {
        let anchor = dismissDragAnchor ?? 0
        let effectiveHeight = value.translation.height - anchor
        let effectivePredicted = value.predictedEndTranslation.height - anchor
        // b48 (chen 2026-11-25: "往右滑也可以退出界面"): direction
        // lock — only a DOMINANTLY downward drag dismisses. The old
        // gate only capped the actual width (< 80) while judging
        // the PREDICTED height, so a fast right flick with a
        // downward arc closed the player: its predicted end shot
        // down past 190pt while the actual width was still under
        // 80. Both the actual and the predicted translation must
        // now be taller than they are wide; a right swipe is wider
        // than tall on both, so it springs back instead.
        let downwardDominant = effectiveHeight > abs(value.translation.width)
            && effectivePredicted > abs(value.predictedEndTranslation.width)
        let shouldClose = dismissDragAllowed(startY: value.startLocation.y)
            && downwardDominant
            && (effectiveHeight > 110 || effectivePredicted > 190)
        dismissDragAnchor = nil
        dismissGateWasClosed = false
        if shouldClose {
            dismissDragY = 0
            close()
        } else {
            withAnimation(HaoPlayerMotion.playerSpringBack) {
                dismissDragY = 0
            }
        }
    }

    /// Drag morph driver (b45-g, Coda §8.1): while a drag that
    /// could close is in flight, track its downward distance so
    /// the surface shrinks/rounds with it. Upward or horizontal
    /// movement resets. b47-player: the gate is dismissDragAllowed
    /// — in lyrics mode a drag starting on the list only morphs
    /// once the list is at its top edge (before that the list
    /// owns the drag and scrolls); the morph is anchored to the
    /// translation where the gate opened, so the surface never
    /// jumps by the scroll distance.
    private func handleDismissDragChanged(_ value: DragGesture.Value) {
        noteInteraction()
        let translation = value.translation
        // b48: same direction lock as handleDismissDrag — the morph
        // only engages while the drag is dominantly downward. The
        // old width cap (< 80) let a down-right diagonal morph and
        // close; a right swipe is wider than tall, so it resets
        // the morph instead of dragging the surface.
        guard translation.height > 0, translation.height > abs(translation.width) else {
            dismissDragY = 0
            dismissDragAnchor = nil
            dismissGateWasClosed = false
            return
        }
        guard dismissDragAllowed(startY: value.startLocation.y) else {
            dismissGateWasClosed = true
            dismissDragY = 0
            return
        }
        if dismissDragAnchor == nil {
            dismissDragAnchor = dismissGateWasClosed ? translation.height : 0
        }
        dismissDragY = max(0, translation.height - (dismissDragAnchor ?? 0))
    }

    /// Top zone where a downward drag always dismisses (the top
    /// bar + lyrics header — not scrollable, so no list owns the
    /// drag there). Portrait: the old 140pt zone measured from the
    /// safe-area top (the root used to start there; now it starts
    /// at the screen top, so the inset is added back). Landscape
    /// keeps the old 60pt strip (its safe top is ~0).
    private var dismissTopZone: CGFloat {
        // b49fix2 B15: orientation from the root GeometryReader's
        // tracked size, not UIScreen — Split View / Stage Manager
        // narrow the window without changing the screen.
        let isLandscape = fullScreenWidth > fullScreenHeight
        return isLandscape ? 60 : safeTopInset + 140
    }

    /// Whether a downward drag starting at startY (root
    /// coordinates) may drive the dismiss morph. Outside lyrics
    /// mode: anywhere. In lyrics mode: the top zone always,
    /// otherwise only when the lyrics list is at its top edge
    /// (further down, the list owns the drag and scrolls).
    private func dismissDragAllowed(startY: CGFloat) -> Bool {
        guard playerVM.showLyrics else { return true }
        if startY <= dismissTopZone { return true }
        return lyricsScrollOffset >= -1
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
        // b49fix5 P2-6: the cover absorbs the load-failed banner —
        // coverSize shrinks the slot by the banner's 52pt (42 +
        // top 10) when it shows, so the column total is the same
        // as the no-banner state. Lyrics mode ignores the slot
        // (its area is flexible and absorbs the banner itself).
        let slotSize = MusicPlayerLayout.coverSize(
            screenWidth: geo.size.width, screenHeight: geo.size.height,
            loadFailed: playerVM.loadFailed)
        // b38, item 1: in cover mode the slack is shared across
        // the column (one Spacer per gap, minLength 0) instead of
        // a single Spacer above the bottom row — the old layout
        // left one ~116pt dead gap between transport and bottom
        // row on chen's phone while the top sat tight. The spacers
        // collapse to 0 on short phones, so the minimum height
        // (and fitsOneScreen) is unchanged.
        // b47-player: in lyrics mode there are NO Spacers — the
        // lyrics area itself is flexible and takes ALL the slack
        // (a Spacer would split it and the dead gap between the
        // last lyric line and the progress bar would come back).
        // The column therefore fills the screen exactly: top bar,
        // lyrics, progress, transport, toolbar, with only the
        // fixed paddings between them.
        return VStack(spacing: 0) {
            topBar
                .frame(maxWidth: .infinity)
                .chromeFade(hidden: chromeHidden)
            if playerVM.showLyrics {
                lyricsModeColumn()
                    .padding(.top, 8)
                    .chromeFade(hidden: chromeHidden)
            } else {
                Spacer(minLength: 0)
                coverOrLyrics(size: slotSize)
                    .padding(.top, 8)
                Spacer(minLength: 0)
                titleRow
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity)
                    .chromeFade(hidden: chromeHidden)
            }
            if playerVM.loadFailed {
                loadFailedBanner
                    .padding(.top, 10)
            }
            if !playerVM.showLyrics {
                Spacer(minLength: 0)
            }
            progressSection(isLandscape: false)
                .padding(.top, 14)
                .frame(maxWidth: .infinity)
                .chromeFade(hidden: chromeHidden)
            if !playerVM.showLyrics {
                Spacer(minLength: 0)
            }
            transportRow
                // b47-player Coda check (ControlMetrics): the gap
                // between the progress row and the transport is 24,
                // not 6 — the old 6pt squeezed the two rows together.
                .padding(.top, 24)
                .frame(maxWidth: .infinity)
                .chromeFade(hidden: chromeHidden)
            if !playerVM.showLyrics {
                Spacer(minLength: 0)
            }
            toolbarRow
                // b47-player Coda check (ControlMetrics): the gap
                // between the transport and the utility row is 36 —
                // the old layout had NO gap there (the two rows
                // touched). In cover mode the Spacers absorb the
                // +54; in lyrics mode the flexible area shrinks
                // by it. Budget updated below (292 → 346).
                // b49fix3 P2-36: 36 STAYS — it is Coda's value,
                // not drift (copy plan §player: progress 52 + 24,
                // transport 82 + 36, volume removed, tools 50 =
                // 244 total; 24 would make it 232). The sweep's
                // "unify to 24" would break the Coda copy.
                .padding(.top, 36)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .chromeFade(hidden: chromeHidden)
        }
        .padding(.horizontal, HaoLayout.playerHorizontalMargin)
        // b47-player: the root is full-screen now (see body), so
        // the content is kept inside the safe area here — the
        // layout is pixel-identical to the old safe-sized root,
        // only the background extends under the status bar and
        // the home indicator.
        .padding(.top, geo.safeAreaInsets.top)
        .padding(.bottom, geo.safeAreaInsets.bottom)
        .frame(width: contentWidth(geo: geo))
    }

    /// True when the chrome around the lyrics is hidden (b45-a,
    /// Coda §2.8): only in the lyrics view, only while the 3 s /
    /// 200pt hide is active. The cover / lyrics slot itself never
    /// hides — only the chrome around it.
    private var chromeHidden: Bool {
        controlsHidden && playerVM.showLyrics
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
            // b49fix4 P2-6: the standard retry capsule (15 semibold,
            // 24/12, filled accent) — the old outline button
            // (14/6, strokeBorder) was a fourth retry system.
            .font(.haoSubheadStrong)
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(theme.accent, in: Capsule())
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
                // b49fix5 P1-1: the load-failed banner lives in the
                // LEFT column, under the cover — it used to sit in
                // the right column between titleRow and
                // progressSection, where its ~50pt pushed the right
                // column past the safe height on the shortest
                // landscape phones (SE 1st gen: 41–51pt over).
                // Left column: cover 224 + gap 8 + banner 42 = 274
                // ≤ 320; the right column is back to its 303
                // budget. landscapeFitsOneScreen + the layout tests
                // carry a loadFailed branch so this state is pinned.
                if playerVM.loadFailed {
                    loadFailedBanner
                        .padding(.top, 8)
                }
            }
            .frame(width: cover)
            VStack(spacing: 0) {
                topBar
                    .frame(maxWidth: .infinity)
                    .chromeFade(hidden: chromeHidden)
                titleRow
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
                    .chromeFade(hidden: chromeHidden)
                progressSection(isLandscape: true)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
                    .chromeFade(hidden: chromeHidden)
                transportRow
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity)
                    .chromeFade(hidden: chromeHidden)
                Spacer()
                toolbarRow
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity)
                    .chromeFade(hidden: chromeHidden)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, HaoLayout.playerHorizontalMargin)
        // b47-player: the root is full-screen now (see body), so
        // the vertical padding is measured from the SAFE edges,
        // not the screen edges — the landscape column sits exactly
        // where it sat under the old safe-sized root. b49fix4
        // P1-9: 12 → landscapeVerticalPadding (8) — the honest
        // 303 right-column budget needs the slack back.
        .padding(.top, MusicPlayerLayout.landscapeVerticalPadding + geo.safeAreaInsets.top)
        .padding(.bottom, MusicPlayerLayout.landscapeVerticalPadding + geo.safeAreaInsets.bottom)
        .frame(width: contentWidth(geo: geo))
    }

    // MARK: - Background

    private var playerBackground: some View {
        ZStack {
            if let tint = coverTint {
                // b45-a: Coda ArtworkPalette (numbers re-implemented,
                // no code copied) — the primary + secondary stops
                // from the 10x10 weighted palette; a white 0.12
                // radial lift at the top-left and a clear -> black
                // 0.35 bottom press for legibility. C9: the tint
                // never flips the page colorScheme — the chrome
                // stays one connected page.
                LinearGradient(
                    colors: [Color(tint), Color(coverTintSecondary ?? tint.haoSecondary())],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                // b47-player refs check (BetterLyrics
                // AmbientBackgroundControl.BlurredBlobs): the
                // ambient light DRIFTS — blobs orbit on
                // sin(_time × 0.2) / cos(_time × 0.15), i.e. ~31 s
                // / ~42 s periods. Our colours stay cover-derived
                // (BetterLyrics' blobs are fixed-theme, not from
                // the cover — we do not copy that); only the
                // MOTION is adopted, on the white 0.12 radial
                // lift, so the tint slowly breathes instead of
                // sitting still. TimelineView ticks once a second
                // (a soft 0.12 veil shows no 1 s steps) instead of
                // every frame, so the drift costs ~nothing.
                TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let center = UnitPoint(
                        x: 0.25 + 0.20 * CGFloat(sin(t * 0.2)),
                        y: 0.08 + 0.08 * CGFloat(cos(t * 0.15))
                    )
                    RadialGradient(
                        colors: [.white.opacity(0.12), .clear],
                        center: center, startRadius: 0, endRadius: 700
                    )
                }
                LinearGradient(
                    colors: [.clear, .black.opacity(0.35)],
                    startPoint: .top, endPoint: .bottom
                )
            } else if let cover = playerVM.currentSong?.cover, !cover.isEmpty {
                // Cover known but tint not computed yet: the blurred
                // cover backdrop with light veils, so the screen is
                // never pure black while waiting.
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
                Color.black.opacity(0.08)
                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.22)],
                    startPoint: .top, endPoint: .bottom
                )
            } else {
                // No cover at all: the palette fallback — diagonal
                // gradient on the fallback colours (main
                // RGB(0.16,0.16,0.20) / secondary (0.09,0.09,0.12)),
                // never pure black.
                LinearGradient(
                    colors: [HaoCoverPalette.fallbackPrimaryColor,
                             HaoCoverPalette.fallbackSecondaryColor],
                    startPoint: .topLeading, endPoint: .bottomTrailing
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

    /// b48 (chen 2026-11-25 build 47: the top chevron-down button
    /// overlapped the status-bar time and the album name was cut
    /// behind the Dynamic Island): BOTH are removed — no chevron,
    /// no album name at the top. Song title + artist stay below
    /// the cover (titleRow); dismissal is the drag-down gesture
    /// only (handleDismissDrag; close() is still its closer).
    /// What remains of the top row is the drag grabber (Coda
    /// 60×5, white 0.5) with no backing — b49: Coda's player has
    /// no top scrim, and the 0.55 -> 0 black gradient read as a
    /// black band across the top on light covers (build 48).
    /// The row keeps its 40pt height — the layout budget in
    /// MusicPlayerLayout (fixedChromeHeight 371, top bar 40)
    /// counts it, so the player still fits one screen with no
    /// scrolling.
    private var topBar: some View {
        VStack(spacing: 4) {
            ZStack {
                // b49fix2 P2-44: the bare white-0.5 capsule vanished
                // on light covers once the top scrim was removed
                // (b49). A small dark pill behind it — not a band —
                // keeps the grabber readable on any cover, light
                // or dark.
                Capsule()
                    .fill(.black.opacity(0.28))
                    .frame(width: 76, height: 17)
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: 60, height: 5)
            }
            // b49fix2 A13: the sleep timer used to live only in
            // the more sheet — once set, nothing on the player
            // said so. While active a pill sits under the grabber
            // (the top bar is otherwise empty space); tapping it
            // opens the sleep sheet to adjust or cancel.
            // Completion modes (after N tracks / queue end) have
            // no wall-clock remaining text, so the pill shows just
            // "睡眠定时" for those instead of a trailing blank.
            if playerVM.sleepActive {
                Button(action: {
                    noteInteraction()
                    showSleep = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "moon.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(playerVM.sleepRemainingText.isEmpty ? "睡眠定时" : "睡眠定时 \(playerVM.sleepRemainingText)")
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.3), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playerVM.sleepRemainingText.isEmpty ? "睡眠定时已开启，点按调整" : "睡眠定时 \(playerVM.sleepRemainingText)，点按调整")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 2)
        // b49fix4 P1-9: the frame fits its content — with the sleep
        // pill showing the stack is 46pt tall (grabber 17 + gap 4
        // + pill 23 + top 2), so a fixed 40 spilled 6pt into the
        // gap below. 48 when the pill shows, 40 otherwise; the
        // landscape budget (MusicPlayerLayout) counts the 48.
        .frame(height: playerVM.sleepActive ? 48 : 40)
    }

    // MARK: - Cover / lyrics

    private func coverOrLyrics(size: CGFloat) -> some View {
        Group {
            if playerVM.showLyrics {
                lyricsArea(height: size)
                    // b49fix4 P1-9: pin the lyrics list to the slot
                    // height. Unframed, the ScrollView takes the
                    // whole stack proposal and the landscape column
                    // fills the screen exactly (zero slack — any
                    // future row growth clips it). Framed to the
                    // cover height, lyrics mode has the same
                    // geometry — and the same slack — as cover
                    // mode. Portrait never reaches this branch
                    // (lyricsModeColumn owns lyrics there).
                    .frame(height: size)
            } else {
                coverArea(size: size)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func coverArea(size: CGFloat) -> some View {
        Button(action: {
            noteInteraction()
            playerVM.toggleLyrics()
        }) {
            morphCover(size: size)
            // b45-a (Coda §2.2): shadow by state — playing black
            // 0.34 / radius 26 / y 15; paused 0.18 / 14 / 8.
            .shadow(
                color: .black.opacity(playerVM.isPlaying ? 0.34 : 0.18),
                radius: playerVM.isPlaying ? 26 : 14,
                y: playerVM.isPlaying ? 15 : 8
            )
            // b45-a (Coda §2.2): the cover breathes with playback —
            // 1.0 playing (with the 1.055 easeOut 0.17 s overshoot,
            // see coverBounce), 0.95 paused on the bouncy spring.
            .scaleEffect(playerVM.isPlaying ? coverBounce : 0.95)
            .animation(HaoDesignTokens.bouncy, value: playerVM.isPlaying)
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
            // b45-a (Coda §2.2): corner radius 12 continuous.
            cornerRadius: HaoLayout.cornerMedium
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

    /// True while the user is browsing the lyrics by hand (the
    /// 3 s follow-pause window after the last real scroll move).
    private var isBrowsingLyrics: Bool {
        Date() < followPausedUntil
    }

    private func lyricsArea(height: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                if !playerVM.lyricsLoaded {
                    ProgressView()
                        .tint(.white)
                        .frame(height: height)
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
                                noteInteraction()
                                playerVM.retryLyrics()
                            }
                            .font(.haoSubheadStrong)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .overlay {
                                RoundedRectangle(cornerRadius: HaoLayout.cornerSmall, style: .continuous)
                                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(height: height)
                    } else {
                        Text("暂无歌词")
                            .font(.haoSubhead)
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(height: height)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                noteInteraction()
                                playerVM.toggleLyrics()
                            }
                    }
                } else {
                    // b47-player Coda check
                    // (AppleMusicLyricsColumn): the current line
                    // sits at 36% of the viewport, so the list
                    // carries a 36% blank above the first line
                    // and a 64% blank below the last — the first
                    // and last lines can both reach the anchor.
                    // The old fixed 24pt blanks pinned the first
                    // line near the top and the last line near
                    // the bottom instead. Blank taps flip back
                    // to the cover (our rule, not Coda's: Coda
                    // toggles its controls there). The tap
                    // target is ONLY the blank spacers, never
                    // the rows: a tap gesture on the whole list
                    // would also fire when a lyric row is
                    // tapped, seeking AND flipping back at once.
                    Color.clear
                        .frame(height: height * 0.36)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            noteInteraction()
                            playerVM.toggleLyrics()
                        }
                    ForEach(Array(playerVM.lyrics.enumerated()), id: \.offset) { index, line in
                        let distance = index - playerVM.activeLyricIndex
                        let isActive = index == playerVM.activeLyricIndex
                        let isConfirmed = lyricConfirmIndex == index
                        Button(action: {
                            tapLyricRow(index: index, line: line)
                        }) {
                            // A11: the translation (when one was
                            // matched and the switch is on) rides
                            // under its line, smaller and dimmer.
                            VStack(alignment: .leading, spacing: 2) {
                                if isActive {
                                    // b45-h: per-character karaoke
                                    // wipe (P8 #1) — each char is
                                    // rendered on its own so the
                                    // wipe advances char by char
                                    // (pseudo-syllable split; no
                                    // word timing exists in any
                                    // lyric source), unsung chars
                                    // at 0.28, the sung char
                                    // glowing and swelling.
                                    LyricWipeText(
                                        text: line.text.isEmpty ? " " : line.text,
                                        lineStart: line.time,
                                        lineDuration: (index + 1 < playerVM.lyrics.count ? playerVM.lyrics[index + 1].time : line.time + 4) - line.time,
                                        position: playerVM.position,
                                        // b49fix2 A27: Coda §2.8 — the
                                        // active line is ~36pt, not 28.
                                        fontSize: 36
                                    )
                                } else {
                                    Text(line.text.isEmpty ? " " : line.text)
                                        // b49fix2 A27: inactive lines
                                        // rise with the active one
                                        // (20 -> 24), keeping the
                                        // hierarchy.
                                        .font(.system(size: 24, weight: .regular))
                                        .foregroundStyle(.white.opacity(
                                            MusicLyrics.lineOpacity(
                                                distance: distance,
                                                browsing: isBrowsingLyrics,
                                                sung: index < playerVM.activeLyricIndex)
                                        ))
                                }
                                if playerVM.showLyricTranslation,
                                   let translation = line.translation, !translation.isEmpty {
                                    Text(translation)
                                        .font(.system(
                                            size: isActive ? 15 : 13
                                        ))
                                        .foregroundStyle(.white.opacity(
                                            isActive ? 0.85 : 0.4
                                        ))
                                }
                                // b49fix2 P2-22: romalrc rides under
                                // the line like the translation,
                                // a touch dimmer — only wy songs
                                // carry it, so most rows show nothing
                                // extra. (Furigana: no data source in
                                // the app returns it — deferred.)
                                if let romaji = line.romaji, !romaji.isEmpty {
                                    Text(romaji)
                                        .font(.system(
                                            size: isActive ? 15 : 13
                                        ))
                                        .foregroundStyle(.white.opacity(
                                            isActive ? 0.7 : 0.35
                                        ))
                                }
                            }
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                            // b45-a: the seek-confirm state — the
                            // tapped row stays highlighted until
                            // the active line lands on it.
                            .background(
                                isConfirmed
                                    ? Color.white.opacity(0.12)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: HaoLayout.cornerLarge, style: .continuous)
                            )
                        }
                        .buttonStyle(LyricRowPressStyle())
                        // b46-player (Coda §2.8): non-active rows
                        // sit at 0.98 scale with a faint distance
                        // blur (cap 2.0, floor opacity 0.45) — no
                        // row is ever cut: the old "> 6 away =
                        // opacity 0" left the bottom of the slot
                        // empty on chen's phone.
                        .scaleEffect(isActive ? 1.0 : 0.98)
                        .blur(radius: isActive ? 0 : MusicLyrics.lineBlur(distance: distance))
                        // b45-a: row-by-row stagger — 0.05 s
                        // forward / 0.025 s reverse, capped at
                        // 0.4 s (Coda §8.3).
                        .animation(
                            HaoPlayerMotion.lyricsFollow.delay(
                                min(Double(abs(distance)) * (lyricScrollForward ? 0.05 : 0.025), 0.4)
                            ),
                            value: playerVM.activeLyricIndex
                        )
                        .id(index)
                    }
                    Color.clear
                        .frame(height: height * 0.64)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            noteInteraction()
                            playerVM.toggleLyrics()
                        }
                }
            }
            .frame(minHeight: height)
            // b47-player: report the content's offset so the
            // dismiss drag knows when the list is at its top
            // edge (see LyricsScrollOffsetKey). A background
            // GeometryReader — it measures without sizing.
            .background(
                GeometryReader { contentGeo in
                    Color.clear.preference(
                        key: LyricsScrollOffsetKey.self,
                        value: contentGeo.frame(in: .named("lyricsScroll")).minY
                    )
                }
            )
        }
        .coordinateSpace(name: "lyricsScroll")
        .scrollPosition(id: $lyricScrollPosition, anchor: UnitPoint(x: 0.5, y: 0.36))
        .frame(height: height)
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    noteInteraction()
                    // b45-a: manual scroll pauses auto-follow
                    // for 3 s (Coda holdDuration), timed from
                    // the last real move, inertia included —
                    // onEnded below re-arms it at settle time.
                    followPausedUntil = Date().addingTimeInterval(3)
                    // b45-a: scrolling down accumulates toward
                    // 200pt to hide the control bar; any upward
                    // scroll restores it at once.
                    if let lastY = lastLyricsDragY {
                        let delta = value.translation.height - lastY
                        if delta < 0 {
                            lyricsScrollDownAccum += -delta
                            if lyricsScrollDownAccum >= 200,
                               !controlsHidden {
                                withAnimation(HaoPlayerMotion.controlFade) {
                                    controlsHidden = true
                                }
                            }
                        } else if delta > 0 {
                            lyricsScrollDownAccum = 0
                            noteInteraction()
                        }
                    }
                    lastLyricsDragY = value.translation.height
                }
                .onEnded { _ in
                    followPausedUntil = Date().addingTimeInterval(3)
                    lastLyricsDragY = nil
                }
        )
        .onChange(of: playerVM.activeLyricIndex) { _, index in
            lyricScrollForward = index >= prevActiveLyricIndex
            prevActiveLyricIndex = index
            guard index >= 0, Date() >= followPausedUntil else { return }
            // b45-a: follow spring response 0.7 / damping 0.85,
            // with the scroll capped at remaining time × 0.8 so
            // a follow never overruns the next line.
            let remaining: Double
            if index + 1 < playerVM.lyrics.count {
                remaining = playerVM.lyrics[index + 1].time - playerVM.position
            } else {
                remaining = 0.7
            }
            let response = min(0.7, max(0.10, remaining * 0.8))
            withAnimation(.spring(response: response, dampingFraction: 0.85)) {
                // b49: declarative follow — the position
                // binding scrolls the list (see the
                // .scrollPosition below); the old
                // proxy.scrollTo could silently lose
                // follow with no error. Anchor stays 36%.
                lyricScrollPosition = index
            }
        }
        // b47-player: track the list offset for the dismiss
        // gate (see dismissDragAllowed) — 0 at the top edge,
        // negative when scrolled.
        .onPreferenceChange(LyricsScrollOffsetKey.self) { lyricsScrollOffset = $0 }
        .accessibilityLabel("歌词，点行跳转，点空白回封面")
    }

    /// Tap a lyric row: seek to the line, keep its confirm state
    /// 380 ms (150 ms with Reduce Motion), then poll every 50 ms
    /// (at most 40 times) until the active line lands on it.
    /// A newer tap cancels the older poll by generation.
    private func tapLyricRow(index: Int, line: LyricsLine) {
        noteInteraction()
        lyricConfirmGeneration += 1
        let generation = lyricConfirmGeneration
        lyricConfirmIndex = index
        playerVM.seek(to: line.time)
        let holdMs = UIAccessibility.isReduceMotionEnabled ? 150 : 380
        Task {
            try? await Task.sleep(for: .milliseconds(holdMs))
            guard !Task.isCancelled, lyricConfirmGeneration == generation else { return }
            lyricConfirmIndex = nil
            for _ in 0..<40 {
                guard !Task.isCancelled, lyricConfirmGeneration == generation else { return }
                if playerVM.activeLyricIndex == index { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    // MARK: - Quality badge (below the progress bar)

    /// Quality badge (b46-player, Coda §2.4): 148×24 slot, badge
    /// 21pt, 10.5pt medium, white 0.70, capsule stroke white 0.28
    /// / 0.75pt. b47-player: it rides in the middle of the time
    /// row (see progressSection), never over the bar and never in
    /// its own row. Hit-testing is off. No label (no song /
    /// unknown tier) collapses to zero size, so the row is just
    /// the two times.
    private var qualityBadgeOverlay: some View {
        Group {
            if let label = playerVM.qualityBadgeLabel {
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.70))
                    .frame(height: 21)
                    .padding(.horizontal, 10)
                    .overlay {
                        Capsule()
                            .strokeBorder(.white.opacity(0.28), lineWidth: 0.75)
                    }
                    .frame(width: 148, height: 24)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Title row

    /// Artist names for the tappable artist links (b45-a, Coda
    /// §2.3): split on / 、 , ， ; ； & ＆, empty names filtered.
    private var artistNames: [String] {
        guard let song = playerVM.currentSong else { return [] }
        return MusicLyrics.splitArtists(song.artist)
    }

    /// Lyric source label (b45-a, Coda §2.8 "歌词来源"): the
    /// effective lyric source for this song — the per-song
    /// override when one is set (b49fix2 #16 menu), else the
    /// song's own platform (wy / tx / kw have an endpoint;
    /// kg / mg have none — the honest empty state, not a failure).
    private var lyricSourceLabel: String {
        guard let song = playerVM.currentSong else { return "—" }
        let source = playerVM.lyricSource(for: song)
        if MusicLyricsAPI.hasLyricsEndpoint(source) {
            return source.displayName
        }
        return "无歌词源"
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            titleTextBlock
            Spacer()
            titleActionButtons
        }
    }

    /// Title + tappable artist links (b45-a, Coda §2.3): shared
    /// by the cover-mode title row and the lyrics-mode compact
    /// header (b46-player), so the two never drift apart.
    private var titleTextBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Apple Music: the title opens the album, the
            // artist opens the artist — the same sheets the …
            // menu already opened, so no new destination is
            // invented. Empty title / artist is not tappable.
            // b49sweep P2-13: with no album the title is plain
            // text, not a disabled Button — a disabled button
            // still renders white/semibold like the tappable
            // title, so it looked tappable and did nothing.
            let titleText = Text(playerVM.currentSong?.title ?? "未在播放")
                .font(.haoSectionTitle)
                .foregroundStyle(.white)
                .lineLimit(1)
            if (playerVM.currentSong?.album ?? "").isEmpty {
                titleText
            } else {
                Button(action: {
                    noteInteraction()
                    showAlbum = true
                }) {
                    titleText
                }
                .buttonStyle(.plain)
                .accessibilityLabel("专辑：\(playerVM.currentSong?.album ?? "")")
            }
            // b45-a (Coda §2.3): title and artist share the
            // title3 size; the artist is white 0.62, and each
            // artist in a multi-artist " / " list is its own
            // tappable link.
            HStack(spacing: 0) {
                ForEach(Array(artistNames.enumerated()), id: \.offset) { offset, name in
                    if offset > 0 {
                        Text(" / ")
                            .font(.haoSectionTitle)
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    Button(action: {
                        noteInteraction()
                        selectedArtistName = name
                        showArtist = true
                    }) {
                        Text(name)
                            .font(.haoSectionTitle)
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("歌手：\(name)")
                }
            }
        }
    }

    /// Add-to-playlist + favourite + … (b45-a, Coda §2.3): 22pt
    /// glyphs on 44×44 hit targets. The heart is the meaningful
    /// red #FF3B30 when liked, fading in over 0.18 s with a
    /// 1.3-speed bounce; the … opens the sheet with sleep / EQ /
    /// quality (the toolbar's three icons are comment / queue /
    /// lyrics). Shared by the cover-mode title row and the
    /// lyrics-mode compact header (b46-player).
    private var titleActionButtons: some View {
        HStack(spacing: 12) {
            Button(action: {
                noteInteraction()
                if let song = playerVM.currentSong {
                    showAddToPlaylistSong = song
                }
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(playerVM.currentSong == nil)
            .accessibilityLabel("添加到歌单")
            Button(action: {
                noteInteraction()
                playerVM.toggleFavourite()
            }) {
                Image(systemName: playerVM.isCurrentFav ? "heart.fill" : "heart")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(
                        playerVM.isCurrentFav
                            ? HaoDesignTokens.heartRed : .white.opacity(0.85)
                    )
                    .frame(width: 44, height: 44)
                    .symbolEffect(
                        .bounce, options: .speed(1.3),
                        value: playerVM.isCurrentFav
                    )
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.18), value: playerVM.isCurrentFav)
            .accessibilityLabel(playerVM.isCurrentFav ? "取消收藏" : "收藏")
            Button(action: {
                noteInteraction()
                showMore = true
            }) {
                Image(systemName: "ellipsis")
                    .font(.system(size: HaoLayout.iconSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更多")
        }
    }

    /// Compact lyrics header (b46-player, Coda lyrics top row):
    /// 64pt cover top-left + title/artist + the title row's three
    /// actions on the right. Same content as titleRow, one row.
    private var lyricsHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            MusicCoverView(
                urlString: playerVM.currentSong?.cover ?? "",
                size: 64,
                cornerRadius: HaoLayout.chipCornerRadius
            )
            titleTextBlock
            Spacer()
            titleActionButtons
        }
        .frame(maxWidth: .infinity)
    }

    /// Lyrics-mode middle column (b46-player): compact header over
    /// the lyrics. b47-player: the lyrics area is FLEXIBLE — a
    /// GeometryReader takes all the slack the portrait column has
    /// left and hands its height to lyricsArea, so the lyrics fill
    /// the middle instead of leaving a dead gap above the progress
    /// bar (the old fixed slotSize area was shorter than the tall
    /// screen, and the Spacers spread the rest). The header stays
    /// 64pt; only the area grows. Cover mode is untouched.
    private func lyricsModeColumn() -> some View {
        VStack(spacing: 8) {
            lyricsHeader
            GeometryReader { areaGeo in
                lyricsArea(height: areaGeo.size.height)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Progress

    /// Progress (b47-player): bar → time row in portrait, with
    /// the quality badge centred IN the time row (elapsed left,
    /// badge centre, remaining right) — Apple Music grammar for
    /// the times, no wasted row for the badge. The old own-row
    /// badge (b46-player) left a full row between the bar and the
    /// times and pushed the chrome budget up 30pt. In landscape
    /// the right column has no room for a badge in the row (1pt
    /// of slack on the shortest landscape phone with the sleep
    /// pill showing, 9pt otherwise — b49fix4 P1-9 measured the
    /// real 295/303 budget), so the badge stays overlaid on the
    /// bar there.
    private func progressSection(isLandscape: Bool) -> some View {
        VStack(spacing: 6) {
            thinProgressBar(badgeOverlay: isLandscape)
            HStack {
                Text(musicDurationText(seconds: Int(playerVM.scrubSeconds ?? playerVM.position)))
                    .font(.haoCaption)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                if !isLandscape {
                    qualityBadgeOverlay
                }
                Spacer()
                Text(remainingText)
                    .font(.haoCaption)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    /// Thin progress bar (fix 2026-11-24, build 35; b45-a Coda
    /// §2.4/§8.7): a 7pt track (b47-player Coda check: the
    /// portrait scrubber passes trackHeight 7, not 5 — unplayed
    /// white 0.25, played solid white), the thumb hidden until
    /// dragged — 13pt while dragging
    /// (spring 0.24/0.72), shadow black 0.3 / radius 2 / y 1. Drag
    /// scrubs locally; seek fires once on release and the VM rolls
    /// back on failure — the same semantics the Slider had (see
    /// seek(to:)). The HIT area stays 28pt (the old 4pt frame was
    /// nearly untappable — the drag only fired when the finger
    /// landed exactly on the line). b47-player: the quality badge
    /// overlay lives here ONLY in landscape (portrait shows the
    /// badge centred in the time row, see progressSection).
    private func thinProgressBar(badgeOverlay: Bool) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(playerVM.duration, 0)
            let current = playerVM.scrubSeconds ?? playerVM.position
            let ratio = duration > 0 ? min(max(current / duration, 0), 1) : 0
            let isScrubbing = playerVM.scrubSeconds != nil
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(height: 7)
                Capsule()
                    .fill(.white)
                    .frame(width: max(0, width * ratio), height: 7)
                // Scrubber knob: only while dragging (Coda
                // PlayerSlider), 13pt, eased in on the 0.24/0.72
                // spring. Clamped inside the track.
                if isScrubbing {
                    Circle()
                        .fill(.white)
                        .frame(width: 13, height: 13)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: min(max(width * ratio - 6.5, 0), max(0, width - 13)))
                        .transition(.scale)
                }
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .overlay(alignment: .center) {
                if badgeOverlay {
                    qualityBadgeOverlay
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        noteInteraction()
                        let r = min(max(value.location.x / width, 0), 1)
                        playerVM.scrubSeconds = r * max(playerVM.duration, 1)
                    }
                    .onEnded { value in
                        noteInteraction()
                        let r = min(max(value.location.x / width, 0), 1)
                        playerVM.seek(to: r * max(playerVM.duration, 1))
                    }
            )
            .animation(
                .spring(response: 0.24, dampingFraction: 0.72),
                value: isScrubbing
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

    /// 5-part transport (b45-a, Coda §2.5): shuffle / previous /
    /// play / next / repeat, five equal widths, hot area width/5 ×
    /// 82. Glyphs 17 / 28 / 40; the play key has no fill circle and
    /// no background — a pure white semibold symbol. Shuffle /
    /// repeat show their active state as an 8pt rounded rectangle
    /// in white 0.14 behind the glyph (easeInOut 0.2 s); disabled
    /// buttons sit at 0.35 opacity. Symbol swaps animate with
    /// easeInOut 0.22 (b45-fix #28: .replace is a
    /// ContentTransitionSymbolEffect, not usable in symbolEffect
    /// with a value — and the plain animated swap is the Coda way).
    private var transportRow: some View {
        HStack(spacing: 0) {
            transportButton(
                systemName: "shuffle",
                size: 17,
                isActive: playerVM.isShuffleActive,
                isDisabled: playerVM.currentSong == nil,
                label: playerVM.isShuffleActive ? "关闭随机播放" : "随机播放"
            ) {
                noteInteraction()
                playerVM.toggleShuffle()
            }
            transportButton(
                systemName: "backward.fill",
                size: 28,
                isActive: false,
                isDisabled: playerVM.currentSong == nil,
                label: "上一首"
            ) {
                noteInteraction()
                playerVM.previous()
            }
            Button(action: {
                noteInteraction()
                playerVM.togglePlayPause()
            }) {
                Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 82)
                    .contentShape(Rectangle())
                    .animation(.easeInOut(duration: 0.22), value: playerVM.isPlaying)
            }
            .buttonStyle(HaoCodaPressStyle())
            .disabled(playerVM.currentSong == nil)
            .opacity(playerVM.currentSong == nil ? 0.35 : 1)
            .accessibilityLabel(playerVM.isPlaying ? "暂停" : "播放")
            transportButton(
                systemName: "forward.fill",
                size: 28,
                isActive: false,
                isDisabled: playerVM.currentSong == nil,
                label: "下一首"
            ) {
                noteInteraction()
                playerVM.next()
            }
            transportButton(
                systemName: playerVM.repeatIcon,
                size: 17,
                isActive: playerVM.isRepeatActive,
                isDisabled: playerVM.currentSong == nil,
                label: "循环播放"
            ) {
                noteInteraction()
                playerVM.cycleRepeat()
            }
        }
    }

    private func transportButton(
        systemName: String,
        size: CGFloat,
        isActive: Bool,
        isDisabled: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 82)
                .background(
                    isActive
                        ? Color.white.opacity(0.14)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: HaoLayout.cornerSmall, style: .continuous)
                )
                .animation(.easeInOut(duration: 0.2), value: isActive)
                .contentShape(Rectangle())
        }
        .buttonStyle(HaoCodaPressStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
        .accessibilityLabel(label)
    }


    // MARK: - Toolbar (50pt, Coda §2.6)

    /// Left: the real output-device button — route glyph only,
    /// 20pt medium on a 44×44 hit target, white 0.85 (b47-player:
    /// the output name text is gone — bottom row is icons only,
    /// chen's iron rule; the name lives in the picker sheet and
    /// the VoiceOver label). Right: comment / queue / lyrics,
    /// 20pt medium on 44×44 hit targets; unselected white 0.65,
    /// selected white 1.0 + white 0.16 background r10. Panel
    /// switches run in a Transaction(animation: nil) — only the
    /// layout moves.
    // b47-player Coda check (portraitUtilityBar): the device
    // button left, a 12pt-minimum spacer, then the three icons in
    // an 8pt-spaced group (Coda Spacing.small) — the old layout
    // had the three icons touching with no gap between them.
    // The device button stays ICON-ONLY (chen's build-46 verdict
    // overrules Coda here: Coda shows the device name beside its
    // icon, we do not).
    private var toolbarRow: some View {
        HStack(spacing: 0) {
            MusicOutputDeviceButton()
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                toolbarIcon(
                    // b49fix2 A19: text.bubble read as a twin of the
                    // lyrics quote.bubble at 20pt — the comments
                    // icon is now the speech-bubble silhouette,
                    // clearly different from the quote bubble.
                    systemName: "message",
                    isSelected: false,
                    label: "评论"
                ) {
                    noteInteraction()
                    showComments = true
                }
                toolbarIcon(
                    systemName: "list.bullet",
                    isSelected: false,
                    label: "播放队列"
                ) {
                    noteInteraction()
                    showQueue = true
                }
                toolbarIcon(
                    systemName: "quote.bubble",
                    isSelected: playerVM.showLyrics,
                    label: "歌词"
                ) {
                    noteInteraction()
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        playerVM.toggleLyrics()
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: 50)
    }

    private func toolbarIcon(
        systemName: String,
        isSelected: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: HaoLayout.iconSize, weight: .medium))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.65))
                .frame(width: 44, height: 44)
                // b49fix5 P2-39(b): the selected-state highlight
                // borrows selectionCellCornerRadius's VALUE (10) —
                // it is a highlight, not a selection cell, and the
                // token's name must not be read as the semantics
                // here. A separate highlight token would be the
                // cleaner name, but the value is identical and the
                // token lives in Glass.swift (another lane's file).
                .background(
                    isSelected ? Color.white.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: HaoLayout.selectionCellCornerRadius, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(HaoCodaPressStyle())
        .accessibilityLabel(label)
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
                    // b45-a (Coda §2.9): heartbeat mode — a random
                    // liked song seeds a local queue played IN THIS
                    // player, never a new page.
                    Button("心动模式") {
                        showMore = false
                        playerVM.startHeartbeatMode()
                    }
                    .disabled(playerVM.currentSong == nil)
                    if playerVM.currentSong != nil {
                        ShareLink(item: playerVM.shareText) {
                            Text("分享")
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
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    Menu {
                        ForEach([0.6, 0.8, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                            Button(action: { playerVM.setSpeed(speed) }) {
                                HStack {
                                    // b49fix4 P2-14: one format (%.1fx) —
                                    // the old %.2fx + ".00"→".0" patch
                                    // was a handmade duplicate of it.
                                    Text(String(format: "%.1fx", speed))
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
                                .foregroundStyle(theme.textSecondary)
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
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
                Section("音质") {
                    // b49fix2 A2: "目标" is jargon — the button
                    // names the actual tier (the target quality).
                    Button("音质选择（\(MusicLibraryStore.badgeLabel(for: coordinator.targetQuality))）") {
                        showMore = false
                        showQuality = true
                    }
                    Button("均衡器") {
                        showMore = false
                        showEqualizer = true
                    }
                }
                Section("歌词") {
                    // b49fix2 #16: the lyric source is now a real
                    // switch — follow the song, or pin one of the
                    // platforms with a lyric endpoint (wy/tx/kw).
                    // The checkmark shows the per-song override;
                    // "跟随歌曲" clears it.
                    Menu {
                        Button(action: { playerVM.setLyricSource(nil) }) {
                            HStack {
                                Text("跟随歌曲")
                                if playerVM.lyricSourceOverride == nil {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        ForEach(MusicLyricsAPI.lyricPlatforms, id: \.rawValue) { platform in
                            Button(action: { playerVM.setLyricSource(platform) }) {
                                HStack {
                                    Text(platform.displayName)
                                    if playerVM.lyricSourceOverride == platform {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text("歌词来源")
                            Spacer()
                            Text(lyricSourceLabel)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    Button("重新加载歌词") {
                        playerVM.retryLyrics()
                    }
                    HStack {
                        Text("歌词偏移")
                        Spacer()
                        Text(MusicLyrics.offsetLabel(playerVM.lyricOffsetMs))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(playerVM.lyricOffsetMs) },
                            set: { playerVM.lyricOffsetMs = Int($0) }
                        ),
                        in: -5000...5000, step: 100
                    )
                    // b45-a (Coda §2.8): ±0.2 s quick steps + reset.
                    // The Slider stays; these are the quick path.
                    // b49fix4 P2-15: capsules, not .bordered — the
                    // same small-capsule grammar as the search
                    // suggestion chips (12/7, hairline stroke).
                    HStack(spacing: 12) {
                        Button("−0.2s") {
                            playerVM.adjustLyricOffset(byMs: -200)
                        }
                        .buttonStyle(.plain)
                        .font(.haoFootnoteStrong)
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .overlay {
                            Capsule()
                                .strokeBorder(theme.hairline, lineWidth: 0.5)
                        }
                        Button("+0.2s") {
                            playerVM.adjustLyricOffset(byMs: 200)
                        }
                        .buttonStyle(.plain)
                        .font(.haoFootnoteStrong)
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .overlay {
                            Capsule()
                                .strokeBorder(theme.hairline, lineWidth: 0.5)
                        }
                        Button("还原") {
                            playerVM.resetLyricOffset()
                        }
                        .buttonStyle(.plain)
                        .font(.haoFootnoteStrong)
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .overlay {
                            Capsule()
                                .strokeBorder(theme.hairline, lineWidth: 0.5)
                        }
                        Spacer()
                    }
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
        // b49fix4 P1-12: the sheet's switches had no tint, so ON
        // was system green — the theme accent owns every toggle.
        .tint(theme.accent)
    }
}

/// Coda press style (b45-a, §8.3 ButtonStyles): icon buttons
/// scale to 0.9 + opacity 0.7, easeOut 0.10 on press / 0.24 on
/// release. (MusicPressScaleStyle in MusicRowViews is the older
/// 0.92 spring — the player takes Coda's numbers here.)
struct HaoCodaPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(
                HaoPlayerMotion.pressAnimation(isPressed: configuration.isPressed),
                value: configuration.isPressed
            )
    }
}

/// Lyric-row press state (b45-a, Coda §2.8): background white
/// 0.12, corner 16, scale 0.96, easeOut 0.10 on press / 0.38 on
/// release.
struct LyricRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .background(
                configuration.isPressed
                    ? Color.white.opacity(0.12)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: HaoLayout.cornerLarge, style: .continuous)
            )
            .animation(
                .easeOut(duration: configuration.isPressed ? 0.10 : 0.38),
                value: configuration.isPressed
            )
    }
}

/// Per-character karaoke wipe (b45-h, P8 #1, §9.1): each char
/// of the active line is rendered on its own so the wipe can
/// advance char by char (pseudo-syllable split — no word timing
/// exists in any lyric source), the unsung chars sit at 0.28,
/// the char being sung glows (blur fontSize x 0.24, 0.65 white)
/// and swells up to +7.5% with a lift (long-note emphasis).
/// The wipe steps with the player's published position (0.5 s
/// tick) — not a 30 fps CADisplayLink like Coda's tile
/// renderer; the per-char HStack is cheap enough that no tile
/// cache is needed at our line lengths.
struct LyricWipeText: View {
    var text: String
    /// Start of the line, seconds.
    var lineStart: Double
    /// Line duration, seconds (next line start minus this start;
    /// 4 s for the last line).
    var lineDuration: Double
    /// Current playback position, seconds.
    var position: Double
    var fontSize: CGFloat

    private var chars: [String] {
        return text.map { String($0) }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(chars.enumerated()), id: \.offset) { index, char in
                let progress = MusicLyrics.karaokeCharProgress(
                    lineDuration: lineDuration,
                    charIndex: index,
                    charCount: chars.count,
                    positionInLine: position - lineStart)
                let isCurrent = progress > 0 && progress < 1
                Text(char)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(Color.white.opacity(MusicLyrics.karaokeCharOpacity(charProgress: progress)))
                    .scaleEffect(CGFloat(MusicLyrics.karaokeSwellScale(charProgress: progress)))
                    .offset(y: CGFloat(MusicLyrics.karaokeLift(fontSize: Double(fontSize), charProgress: progress)))
                    .shadow(color: .white.opacity(isCurrent ? MusicLyrics.karaokeGlowOpacity : 0), radius: CGFloat(MusicLyrics.karaokeGlowRadius(fontSize: Double(fontSize))))
            }
        }
    }
}

/// Output-device button (b45-a, Coda §2.6 PlaybackDeviceButton):
/// the audio session's REAL output name (AirPods / AirPlay /
/// Bluetooth / speaker), updated on route changes; the icon
/// follows the output type. Tap opens the public AVRoutePickerView
/// (294pt wide) — never Coda's private MPMediaControls. On the
/// simulator there is no route to pick, so the sheet says so
/// instead of failing silently.
struct MusicOutputDeviceButton: View {
    @State private var showPicker = false
    @State private var outputName = "iPhone"
    @State private var outputIcon = "speaker.wave.2.fill"

    var body: some View {
        Button(action: { showPicker = true }) {
            // b47-player (chen build 46: bottom row must be icons
            // only): the output NAME is gone from the row — it was
            // the only text label down here and made the left side
            // read as a labeled control against three bare icons.
            // The glyph still follows the route (AirPlay / AirPods
            // / headphones / speaker); the name lives in the picker
            // sheet ("当前输出") and in the VoiceOver label.
            Image(systemName: outputIcon)
                .font(.system(size: HaoLayout.iconSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("输出设备：\(outputName)")
        .onAppear(perform: refreshRoute)
        .onReceive(
            NotificationCenter.default.publisher(
                for: AVAudioSession.routeChangeNotification)
        ) { _ in refreshRoute() }
        .sheet(isPresented: $showPicker) {
            NavigationStack {
                VStack(spacing: 16) {
                    AirPlayPickerView()
                        .frame(width: 294, height: 44)
#if targetEnvironment(simulator)
                    Text("模拟器上没有可用的输出设备。")
                        .font(.haoFootnote)
                        .foregroundStyle(theme.textSecondary)
#endif
                    Text("当前输出：\(outputName)")
                        .font(.haoFootnote)
                        .foregroundStyle(theme.textSecondary)
                }
                // b49fix4 P2-22: sheet standard (horizontal 24,
                // top 16) — the old bare .padding() was 16 all
                // round, one rung under the sheet token.
                .padding(.horizontal, HaoLayout.sheetHorizontalPadding)
                .padding(.vertical, HaoLayout.sheetTopPadding)
                .navigationTitle("选择输出设备")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { showPicker = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func refreshRoute() {
        let session = AVAudioSession.sharedInstance()
        guard let output = session.currentRoute.outputs.first else { return }
        outputName = output.portName
        switch output.portType {
        case .airPlay:
            outputIcon = "airplayaudio"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
            outputIcon = "airpods"
        case .headphones:
            outputIcon = "headphones"
        case .builtInSpeaker:
            outputIcon = "speaker.wave.2.fill"
        default:
            outputIcon = "speaker.wave.2.fill"
        }
    }
}

private extension View {
    /// Control-bar fade (b45-a, Coda §2.8): the chrome around the
    /// lyrics fades on the 0.34 s control animation.
    func chromeFade(hidden: Bool) -> some View {
        opacity(hidden ? 0 : 1)
            .animation(HaoPlayerMotion.controlFade, value: hidden)
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
    /// b49fix4 P2-16: one value, not two — this references the
    /// token instead of restating 24 (HaoLayout.playerHorizontalMargin).
    static let sidePadding: CGFloat = HaoLayout.playerHorizontalMargin
    /// Fixed chrome around the cover slot (everything except the
    /// cover itself and the load-failed banner, which is counted
    /// separately — see loadFailedBannerHeight). b47-player: the
    /// quality badge moved out of its own row into the time row
    /// (bar → time row with the badge centred in it), so the
    /// honest budget shrinks 314 → 292 (the badge row's 24 + 6
    /// gap is gone; the time row grows 16 → 24 because the badge
    /// drives it, net −22) and the cover's height term 418 → 396.
    /// b47-player Coda check (ControlMetrics): the control gaps
    /// are 24 (progress → transport) and 36 (transport →
    /// utility), not 6 and 0 — the budget grows back 292 → 346
    /// (+54) and the cover's height term 396 → 450.
    /// b49fix5 P2-6: 346 was 16pt short of the measured rows —
    /// the sweep's 362 counted topBar 40 + title top 10 + title
    /// 50 + progress top 14 + progress 48 + transport top 24 +
    /// transport 82 + toolbar top 36 + toolbar 50 + bottom 8,
    /// but missed the cover's own top 8 (portraitBody puts
    /// .padding(.top, 8) on the slot) and the progress row is 49,
    /// not 48 (28pt hit area + 6 spacing + ~15pt time row — the
    /// same 49 the landscape comment already uses). The honest
    /// base is 40 + 8 + 10 + 50 + 14 + 49 + 24 + 82 + 36 + 50 +
    /// 8 = 371, and the cover's height term is 371 + 93 safe +
    /// 11 slack = 475. MusicPlayerLayoutTests pins
    /// coverSize(375, 667) == 192 on the new budget.
    /// Variable states are NOT in this number: the sleep pill
    /// adds 8 (topBar 40 → 48) and the quality badge adds 9
    /// (time row 15 → 24) — each fits inside the 11pt slack on
    /// 667, and both together still fit on a real 667 phone
    /// (home button: safe areas 20, not the 93 this check
    /// assumes for notched phones). Lyrics mode needs no budget
    /// term: its area is flexible and takes whatever height is
    /// left.
    static let fixedChromeHeight: CGFloat = 371

    static func contentWidth(screenWidth: CGFloat) -> CGFloat {
        screenWidth - sidePadding * 2
    }

    /// Height of the load-failed banner row itself (standard retry
    /// capsule: 15pt semibold + 24pt vertical padding ≈ 42pt).
    /// The gap above it stays at the call site (portrait 10,
    /// landscape 8) — the two call sites do not share a gap.
    static let loadFailedBannerHeight: CGFloat = 42

    /// Cover / lyrics slot size: bounded by width AND by the height
    /// left after the fixed chrome, so the whole player fits on one
    /// screen with no scrolling on any phone height. Tall phones
    /// still get the 340 cap. b49fix5 P2-6: when the load-failed
    /// banner shows in portrait, the slot shrinks by the banner's
    /// 52pt (42 + top 10) — the column total is then identical to
    /// the no-banner state, so the banner cannot overflow the
    /// screen; in lyrics mode the slot is unused and the flexible
    /// lyrics area absorbs the banner instead. The 180 floor still
    /// binds on the shortest phone (667): the slot cannot shrink
    /// below it, so the banner state there relies on the real
    /// home-button safe areas (20pt, not the 93 this check
    /// assumes) — see fitsOneScreen.
    static func coverSize(screenWidth: CGFloat, screenHeight: CGFloat, loadFailed: Bool = false) -> CGFloat {
        let reserved = screenHeight - 475 - (loadFailed ? loadFailedBannerHeight + 10 : 0)
        return min(screenWidth - sidePadding * 2, 340, max(180, reserved))
    }

    /// The whole player fits on one screen iff cover + chrome +
    /// safe areas fit the height. Safe areas are iPhone values
    /// (status bar 59 + home indicator 34). The 568pt-tall iPhone
    /// SE (1st gen) is below the floor even at the 180 minimum —
    /// a pre-existing limit, not a build-35 regression — so the
    /// test table starts at 667pt. b49fix5 P2-6: with loadFailed
    /// the banner's 52pt is added back — the cover already shrank
    /// by it, so the sum equals the no-banner total wherever the
    /// slot is not floored. On 667 the slot floors at 180 and the
    /// fiction fails by 29pt; the real 667 phone is a home-button
    /// phone (safe areas 20, not 93), so it fits at 623pt — the
    /// test pins the floored cover instead of claiming the
    /// fiction fits.
    static func fitsOneScreen(screenWidth: CGFloat, screenHeight: CGFloat, loadFailed: Bool = false) -> Bool {
        coverSize(screenWidth: screenWidth, screenHeight: screenHeight, loadFailed: loadFailed)
            + fixedChromeHeight + (loadFailed ? loadFailedBannerHeight + 10 : 0) + 59 + 34 <= screenHeight
    }

    // MARK: - Transport row (5 equal buttons, b45-a)

    /// Five equal transport buttons; the middle one (play) is
    /// centred on the screen, prev/next symmetric around it — the
    /// build-34 failure (prev/next at the screen edges) stays
    /// guarded by MusicPlayerLayoutTests.
    static let transportButtonCount: CGFloat = 5

    /// Centres of the prev / play / next transport buttons for a
    /// screen width, under the pinned layout (row = content width,
    /// 5 equal buttons). All three must lie inside the screen.
    static func transportCentres(screenWidth: CGFloat) -> (prev: CGFloat, play: CGFloat, next: CGFloat) {
        let content = contentWidth(screenWidth: screenWidth)
        let buttonWidth = content / transportButtonCount
        let prev = sidePadding + buttonWidth * 1.5
        let play = screenWidth / 2
        let next = screenWidth - prev
        return (prev, play, next)
    }

    // MARK: - Landscape (two columns; build 36)

    /// Right column height in landscape — the MEASURED row sum,
    /// not a round number (b49fix4 P1-9: the old 291 claimed title
    /// 46, but the title row is two 20pt lines + 2 spacing = 50,
    /// so the real base is 295; with the sleep pill showing the
    /// top bar is 48, so the worst case is 303). Base: top bar 40
    /// + gap 8 + title 50 + gap 8 + progress 49 + gap 4 +
    /// transport 82 + toolbar 50 + bottom 4 = 295. Worst case
    /// (sleep pill showing): 295 + 8 = 303. The fits check uses
    /// the worst case, so the shortest landscape phone (SE 1st
    /// gen, 320pt) keeps 1pt of slack even with the pill showing.
    static let landscapeRightColumnHeight: CGFloat = 303
    /// Vertical body padding in landscape (top + bottom, each).
    /// b49fix4 P1-9: 12 → 8 — the old 12 left the shortest phone
    /// at 1pt of slack on the WRONG budget (291); with the honest
    /// 303 budget the 12 would overflow it, so the padding gives
    /// the slack back (303 + 16 = 319 ≤ 320).
    static let landscapeVerticalPadding: CGFloat = 8
    /// Badge height + its top gap in the left column (build 36).
    /// Kept for the fits check: the badge no longer lives in the
    /// left column, so the term now stands for the left column's
    /// bottom slack instead of a badge row.
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
    /// safe-area insets (notch sides + home indicator). The cover
    /// check's +12 is the left column's slack term, not the body
    /// padding (the body padding is landscapeVerticalPadding,
    /// counted ×2 in the right-column check).
    /// b49fix5 P1-1: with loadFailed the banner sits in the left
    /// column under the cover (42 + top 8 = 50) instead of the
    /// badge slack (35 + 12 = 47) — the left column is then
    /// cover + 50. SE 1st gen: 224 + 50 = 274 ≤ 320. The right
    /// column is unchanged (the banner left it), so its check
    /// has no loadFailed term.
    static func landscapeFitsOneScreen(safeWidth: CGFloat, safeHeight: CGFloat, loadFailed: Bool = false) -> Bool {
        landscapeCoverSize(safeWidth: safeWidth, safeHeight: safeHeight)
            + (loadFailed ? loadFailedBannerHeight + 8 : landscapeBadgeHeight + 12) <= safeHeight
            && landscapeRightColumnHeight + 2 * landscapeVerticalPadding <= safeHeight
    }
}

/// Cover palette (b45-a, Coda §2.7 ArtworkPalette, numbers
/// re-implemented, no code copied): the cover is shrunk to 10×10,
/// each pixel weighted by saturation × (1 − |brightness − 0.55|);
/// the primary hue is the saturation-weighted circular mean, its
/// saturation min(mean × 1.15, 0.72), brightness clamped 0.32–0.50;
/// the secondary is hue +0.06 with brightness clamped 0.12–0.26.
/// Fallback: primary RGB(0.16,0.16,0.20) / secondary
/// (0.09,0.09,0.12). Results are cached (200 entries) by cover
/// URL, so a song switch never re-samples the same art.
enum HaoCoverPalette {
    struct Pair {
        var primary: UIColor
        var secondary: UIColor
    }

    static let fallbackPrimary = UIColor(red: 0.16, green: 0.16, blue: 0.20, alpha: 1)
    static let fallbackSecondary = UIColor(red: 0.09, green: 0.09, blue: 0.12, alpha: 1)
    static var fallbackPrimaryColor: Color { Color(fallbackPrimary) }
    static var fallbackSecondaryColor: Color { Color(fallbackSecondary) }

    private static var cache: [String: Pair] = [:]
    private static var cacheOrder: [String] = []
    private static let cacheLimit = 200

    static func palette(for image: UIImage, key: String) -> Pair {
        if let cached = cache[key] { return cached }
        let computed = sample(image: image) ?? Pair(primary: fallbackPrimary, secondary: fallbackSecondary)
        cache[key] = computed
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        return computed
    }

    private static func sample(image: UIImage) -> Pair? {
        guard let cg = image.cgImage else { return nil }
        let w = 10, h = 10
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var sinSum: CGFloat = 0, cosSum: CGFloat = 0
        var satWeighted: CGFloat = 0, weightSum: CGFloat = 0
        var briWeighted: CGFloat = 0
        for i in 0..<(w * h) {
            guard px[i * 4 + 3] > 16 else { continue }
            let color = UIColor(
                red: CGFloat(px[i * 4]) / 255,
                green: CGFloat(px[i * 4 + 1]) / 255,
                blue: CGFloat(px[i * 4 + 2]) / 255,
                alpha: 1
            )
            var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
            guard color.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha) else { continue }
            // Weight = saturation × (1 − |brightness − 0.55|):
            // vivid mid-tones count most, greys and extremes least.
            let weight = sat * (1 - abs(bri - 0.55))
            guard weight > 0 else { continue }
            let angle = hue * 2 * CGFloat.pi
            sinSum += weight * sin(angle)
            cosSum += weight * cos(angle)
            satWeighted += weight * sat
            briWeighted += weight * bri
            weightSum += weight
        }
        guard weightSum > 0 else { return nil }
        var hue = atan2(sinSum, cosSum) / (2 * CGFloat.pi)
        if hue < 0 { hue += 1 }
        let sat = min((satWeighted / weightSum) * 1.15, 0.72)
        let bri = min(0.50, max(0.32, briWeighted / weightSum))
        let primary = UIColor(hue: hue, saturation: sat, brightness: bri, alpha: 1)
        let shiftedHue = hue + 0.06 >= 1 ? hue + 0.06 - 1 : hue + 0.06
        let secondary = UIColor(
            hue: shiftedHue, saturation: sat,
            brightness: min(0.26, max(0.12, bri + 0.06)), alpha: 1
        )
        return Pair(primary: primary, secondary: secondary)
    }
}

private extension UIColor {
    /// Secondary gradient stop for a tint computed elsewhere
    /// (same Coda rule: hue +0.06, brightness clamped 0.12–0.26).
    func haoSecondary() -> UIColor {
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        if getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha) {
            let shiftedHue = hue + 0.06 >= 1 ? hue + 0.06 - 1 : hue + 0.06
            return UIColor(
                hue: shiftedHue, saturation: sat,
                brightness: min(0.26, max(0.12, bri + 0.06)), alpha: alpha
            )
        }
        var white: CGFloat = 0
        getWhite(&white, alpha: &alpha)
        return UIColor(white: min(0.26, max(0.12, white + 0.06)), alpha: alpha)
    }
}

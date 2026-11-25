// HAo Studio 2.0 — mini player strip + full-player fallback.
//
// The mini player is a floating glass strip ABOVE the tab bar. Tapping it
// opens the full player. S2-C wiring:
// - The strip shows the coordinator's current item; when that is nil
//   but a music song is still loaded (MusicPlayerViewModel
//   .miniFallbackSong — a failed / stopped track the full player
//   keeps showing), it shows that song instead. Only a truly empty
//   queue hides the strip, so the mini and the full player never
//   disagree about "what is playing".
// - For MUSIC items it shows a real play/pause button bound to
//   NativeMusicPlayer (via the shared MusicPlayerViewModel); for
//   VOD / live items it shows a single play/pause button bound
//   to the shared video / live view model (b49fix2 A6 — the
//   mini used to be display-only for those kinds).
// - Tapping the strip opens the full player (music: the real player).
// - S7-C: the cover slot shows the item's real artwork
//   (MusicCoverView); its placeholder is the same note icon as
//   before when the item carries no cover URL.

import SwiftUI

/// Floating mini-player strip. Hidden entirely when there is no current item.
struct MiniPlayerBar: View {
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var musicPlayer: MusicPlayerViewModel
    /// b49fix2 A6: the shared VOD / live view models (app-root
    /// environment, same as the music VM) — the mini's
    /// play/pause for non-music items.
    @EnvironmentObject private var videoPlayer: VideoPlayerViewModel
    @EnvironmentObject private var livePlayer: LivePlayerViewModel
    @Environment(\.haoTheme) private var theme

    /// Opens the full player for the current item.
    var onTapFullPlayer: () -> Void
    /// Namespace for the cover morph into the full player
    /// (matchedGeometryEffect id HaoLayout.playerCoverMorphID).
    /// Nil keeps the old behaviour (no morph) — the strip is still
    /// fully usable without it.
    var morphNamespace: Namespace.ID? = nil

    /// The item the strip shows. The coordinator's current item
    /// wins (music / VOD / live, as before). When it is nil but a
    /// music song is still loaded — its URL failed to resolve, or
    /// playback was stopped — the strip keeps showing that song,
    /// exactly like the full player does (MusicPlayerViewModel
    /// .currentSong survives a nil currentItem; see
    /// miniFallbackSong). Only a truly empty queue hides the strip.
    /// A VOD episode / live room never lands here as a fallback
    /// song: miniFallbackSong is music-only by construction.
    private var displayItem: PlaybackItem? {
        if let item = coordinator.currentItem { return item }
        return musicPlayer.miniFallbackSong?.toPlaybackItem()
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let item = displayItem {
                expandedBody(item: item)
                // Build 36, item 8 (item 12 follow-up): row actions
                // (download / play-next) set playerVM.toast, but
                // the toast was only rendered inside the full
                // player — with the player closed there was no
                // visible confirmation at all. The same pill
                // floats above the strip here (same look as the
                // full player's toast), so the confirmation is
                // visible wherever the action was taken. It never
                // intercepts taps, and it never changes the strip's
                // geometry — it is an overlay, not a row.
                .overlay(alignment: .top) {
                    toastPill
                        .offset(y: -58)
                }
            } else {
                // No strip (empty queue): a download still toasts,
                // so the pill renders on its own in the same slot
                // instead of vanishing with the strip.
                toastPill
            }
        }
        .animation(.spring(duration: 0.3), value: musicPlayer.toast)
    }

    /// The shared toast pill (same text, style and 2 s lifetime
    /// as the full player's toast — one `playerVM.toast`, rendered
    /// wherever the user can see it). Empty when there is no toast.
    /// b45-g (Coda §8.6, plan §11 C20): 12.5pt medium, radius 10,
    /// shadow black 0.15 / radius 8 / y 4, spring 0.3 in/out;
    /// position stays our bottom slot (see MusicPlayerView).
    @ViewBuilder
    private var toastPill: some View {
        if let toast = musicPlayer.toast {
            Text(toast)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .haoDarkGlassRoundedRect(cornerRadius: HaoLayout.chipCornerRadius, darkness: 0.7)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    /// The cover with the morph attached when the caller supplied
    /// the namespace. The full player attaches the same id to its
    /// cover, so tapping the strip grows this one cover into the
    /// full player's cover (32 up to 340). The
    /// corner radius is NOT part of the morph (matchedGeometryEffect
    /// moves the frame only): it snaps at the end of the transition.
    @ViewBuilder
    private func morphCover(urlString: String, size: CGFloat, cornerRadius: CGFloat) -> some View {
        // b46-chrome (Coda §2.10): the mini cover carries its own
        // shadow (black 0.15 / radius 4 / y 1). The shadow is the
        // mini's, not the shared cover's, so it lives here — no
        // song row gains one.
        let cover = MusicCoverView(urlString: urlString, size: size, cornerRadius: cornerRadius)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        if let namespace = morphNamespace {
            cover.matchedGeometryEffect(id: HaoLayout.playerCoverMorphID, in: namespace)
        } else {
            cover
        }
    }

    /// Expanded form: the wide strip above the full tab bar.
    /// b46-chrome (Coda §2.10/§6.2): the 52pt mini — cover 40 r6,
    /// title 15 semibold / artist 12, 1pt between them, 10pt
    /// between groups, transport 36x36 with 20pt icons, and now
    /// prev/play/next (the prev button was missing — the mini only
    /// had play + next). The chevron is on a full 44x44 hit target
    /// with its own contentShape (was 24x32 with none — below
    /// Apple's 44pt minimum, the likeliest reason a tap on the ^
    /// did nothing on device). The row tap and the swipe-up already
    /// opened the player; the chevron is the same action, now
    /// actually tappable. The thin progress line stays (our Apple
    /// Music feature, not Coda geometry — Coda's iPhone mini has
    /// none, but the task did not order it removed).
    private func expandedBody(item: PlaybackItem) -> some View {
            // b36-1: the strip tap is a gesture, not a Button. The
            // old strip Button's label held a Spacer, so under
            // .buttonStyle(.plain) its hit region was the full row
            // rect (a documented SwiftUI hit-test footgun) and it
            // could claim the tap meant for the play/pause button
            // beside it — the tap opened the full player instead
            // of pausing. A gesture never beats a sibling Button,
            // so the transports are now the only Buttons in the row
            // and always win their own frames. The chevron stays a
            // Button: it does the same action as the strip, so a
            // tap there opening the player is correct either way.
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    // Real artwork when the item carries a cover
                    // URL; MusicCoverView falls back to the note
                    // placeholder when there is none. Coda §2.10:
                    // cover 40, radius 6 (the shadow is on the
                    // morphCover call, not the shared cover).
                    morphCover(
                        urlString: item.coverURL?.absoluteString ?? "",
                        size: HaoLayout.miniCoverSize, cornerRadius: 6)
                    // b49fix5 P2-43: sleep-timer indication — the
                    // timer used to show only on the full player's
                    // topBar, so a collapse made a timed stop look
                    // causeless. A small moon badge on the cover
                    // (music only) marks it; the strip's VoiceOver
                    // label carries the remaining time (same
                    // sleepRemainingText as the topBar).
                    .overlay(alignment: .topTrailing) {
                        if item.kind == .music && musicPlayer.sleepActive {
                            Image(systemName: "moon.fill")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(.black.opacity(0.55), in: Circle())
                                .offset(x: 3, y: -3)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        // Coda §2.10: title subheadline 15 semibold
                        // primary, artist caption 12 secondary.
                        Text(item.title)
                            .font(.haoSubheadStrong)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Text(item.subtitle)
                            .font(.haoCaption)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onTapFullPlayer)
                .accessibilityAddTraits(.isButton)
                if item.kind == .music {
                    // Coda §2.10: prev / play / next, 36x36 hit
                    // targets, 20pt semibold icons, primary tint.
                    // VOD / live get a single play/pause below
                    // (b49fix2 A6) — no prev/next there.
                    Button(action: { musicPlayer.previous() }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(MusicPressScaleStyle())
                    .contentShape(Rectangle())
                    .accessibilityLabel("上一曲")
                    Button(action: { musicPlayer.togglePlayPauseOrRetry() }) {
                        Image(systemName: musicPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(MusicPressScaleStyle())
                    .contentShape(Rectangle())
                    .accessibilityLabel(musicPlayer.isPlaying ? "暂停" : "播放")
                    Button(action: { musicPlayer.next() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(MusicPressScaleStyle())
                    .contentShape(Rectangle())
                    .accessibilityLabel("下一曲")
                }
                if item.kind == .vod || item.kind == .live {
                    // b49fix2 A6: the mini was display-only for
                    // VOD/live — play/pause must work for
                    // whatever is playing. One button (no
                    // prev/next: a video has no previous episode
                    // here, a live room has no next room). The
                    // toggles are safe with nothing loaded.
                    Button(action: { toggleVodLivePlayPause(for: item.kind) }) {
                        Image(systemName: isVodLivePlaying(for: item.kind) ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(MusicPressScaleStyle())
                    .contentShape(Rectangle())
                    .accessibilityLabel(isVodLivePlaying(for: item.kind) ? "暂停" : "播放")
                }
                Button(action: onTapFullPlayer) {
                    Image(systemName: "chevron.up")
                        .font(.haoDenseTitle)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(MusicPressScaleStyle())
                .contentShape(Rectangle())
                .accessibilityLabel("展开全屏播放器")
            }
            // Symmetric content padding (was leading 10 / trailing
            // 6 — the strip read lopsided). 12pt, Coda §6.2 mini
            // side padding (HaoLayout.miniPlayerContentPadding).
            .padding(.horizontal, HaoLayout.miniPlayerContentPadding)
            .frame(height: HaoLayout.miniPlayerHeight)
            // Rounded rectangle at the shared floating-chrome radius,
            // the same shape as the tab bar (chen's Apple Music
            // reference, 2026-11-24): NOT a capsule.
            .haoGlassRoundedRect()
            // Apple Music mini's thin progress line along the
            // strip's bottom edge. Overlay only — no height or
            // layout change; haoGlassRoundedRect already clips to
            // the rounded shape, so the line never pokes past the
            // corners. Inline form has no line (no room, and Apple
            // drops it in the narrowed tray too). Music only
            // (b36-8): the ratio reads the music player's
            // position/duration, which is stale under a VOD/live
            // item — an old music progress line under a video
            // title is wrong, not decorative.
            .overlay(alignment: .bottom) {
                if item.kind == .music {
                    GeometryReader { geo in
                        let ratio = musicPlayer.duration > 0
                            ? min(max(musicPlayer.position / musicPlayer.duration, 0), 1) : 0
                        Capsule()
                            .fill(theme.accent)
                            .frame(width: max(0, geo.size.width * ratio), height: 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 2)
                }
            }
            // b45-g (Coda §8.2, GlassTabBar): swipe up expands the
            // strip into the full player — translation < −28pt or
            // predicted < −72pt. simultaneousGesture, minimumDistance
            // 8: a tap is still a tap (the strip's onTapGesture and
            // the transport buttons keep their own hits), and a
            // downward drag does nothing — only upward opens.
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onEnded { value in
                        if value.translation.height < -28
                            || value.predictedEndTranslation.height < -72 {
                            onTapFullPlayer()
                        }
                    }
            )
            .accessibilityLabel(miniAccessibilityLabel(item: item))
            // b49fix2 B11: fixed chrome — cap Dynamic Type at
            // .accessibility1 so a huge text size cannot blow the
            // 52pt strip apart.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }

    /// VoiceOver label for the strip: the sleep timer's remaining
    /// time rides along when active (same text as the full
    /// player's topBar pill) so the timed stop is announced, not
    /// silent (b49fix5 P2-43).
    private func miniAccessibilityLabel(item: PlaybackItem) -> String {
        let sleep = item.kind == .music && musicPlayer.sleepActive
            ? "，睡眠定时\(musicPlayer.sleepRemainingText.isEmpty ? "已开启" : musicPlayer.sleepRemainingText)"
            : ""
        return "迷你播放器：\(item.title)\(sleep)，点按打开全屏播放器"
    }

    /// Whether the VOD / live item is playing right now (b49fix2
    /// A6). Reads the shared view model for the kind.
    private func isVodLivePlaying(for kind: PlaybackKind) -> Bool {
        switch kind {
        case .vod: return videoPlayer.isPlaying
        case .live: return livePlayer.isPlaying
        case .music: return musicPlayer.isPlaying
        }
    }

    /// Play/pause for a VOD / live item (b49fix2 A6). Safe with
    /// nothing loaded — both view models no-op then.
    private func toggleVodLivePlayPause(for kind: PlaybackKind) {
        switch kind {
        case .vod: videoPlayer.togglePlayPause()
        case .live: livePlayer.togglePlayPause()
        case .music: musicPlayer.togglePlayPauseOrRetry()
        }
    }
}

/// Fallback when the mini player cannot rebuild a real player
/// from the current item (only reachable for a live item whose id
/// does not parse as a room id — music / VOD / live all open
/// their real players). Shows the item title and a plain
/// "cannot play" note, never dev jargon, with a close button —
/// plus, b49sweep, Retry (dismiss + re-present, so the open
/// branch re-evaluates against the coordinator's current item)
/// and Clear-and-close (stops everything and clears the
/// current item, so the mini strip goes away and the
/// placeholder cannot re-present). The plain X close keeps
/// its old meaning: close only, item stays.
struct FullPlayerPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @Environment(\.haoTheme) private var theme

    /// Re-attempt the open: MainTabView dismisses this cover and
    /// re-presents it, re-running the player branch. A still
    /// unparseable live id lands back here — retry re-attempts,
    /// it cannot repair the id (that is the Live slice's job).
    var onRetry: () -> Void = {}

    var body: some View {
        ZStack {
            theme.scaffoldBackground.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("播放器")
                    .font(.haoDetailTitle)
                    .foregroundStyle(theme.textPrimary)
                if let item = coordinator.currentItem {
                    Text(item.title)
                        .font(.haoCallout)
                        .foregroundStyle(theme.textSecondary)
                }
                Text("当前内容无法播放")
                    .font(.haoRowSubtitle)
                    .foregroundStyle(theme.textMuted)
                VStack(spacing: 12) {
                    // b49fix5 P2-26: this retry is the sheet-primary
                    // ACTION exception to the standard retry capsule
                    // (15 semibold, 24/12, filled accent): a sheet's
                    // primary action is a full-width prominent
                    // button (17 bold, 44 high), not a capsule.
                    // The form is deliberate, not a fourth system.
                    Button(action: onRetry) {
                        Text("重试")
                            .font(.haoBodyStrong)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .accessibilityLabel("重试打开播放器")
                    Button("清除内容并关闭") {
                        coordinator.stop()
                        dismiss()
                    }
                    .font(.haoBodyStrong)
                    .foregroundStyle(theme.accentText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除当前内容并关闭播放器")
                }
                .padding(.top, 12)
            }
            .padding()
        }
        .overlay(alignment: .topTrailing) {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.haoDenseTitle)
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(theme.surfaceStrong, in: Circle())
            }
            .padding(16)
            .accessibilityLabel("关闭播放器")
        }
    }
}

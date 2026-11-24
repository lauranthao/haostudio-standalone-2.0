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
//   NativeMusicPlayer (via the shared MusicPlayerViewModel); for VOD /
//   live items it shows no transport button (their players are other
//   slices' — a button with no engine behind it would be fake).
// - Tapping the strip opens the full player (music: the real player).
// - S7-C: the cover slot shows the item's real artwork
//   (MusicCoverView); its placeholder is the same note icon as
//   before when the item carries no cover URL.

import SwiftUI

/// Floating mini-player strip. Hidden entirely when there is no current item.
struct MiniPlayerBar: View {
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var musicPlayer: MusicPlayerViewModel
    @EnvironmentObject private var bottomChrome: BottomChromeState
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
        if let item = displayItem {
            if bottomChrome.isMinimized {
                inlineBody(item: item)
            } else {
                expandedBody(item: item)
            }
        }
    }

    /// The cover with the morph attached when the caller supplied
    /// the namespace. The full player attaches the same id to its
    /// cover, so tapping the strip grows this one cover into the
    /// full player's cover (36 — or 32 inline — up to 340). The
    /// corner radius is NOT part of the morph (matchedGeometryEffect
    /// moves the frame only): it snaps at the end of the transition.
    @ViewBuilder
    private func morphCover(urlString: String, size: CGFloat, cornerRadius: CGFloat) -> some View {
        let cover = MusicCoverView(urlString: urlString, size: size, cornerRadius: cornerRadius)
        if let namespace = morphNamespace {
            cover.matchedGeometryEffect(id: HaoLayout.playerCoverMorphID, in: namespace)
        } else {
            cover
        }
    }

    /// Minimized (inline) form: the strip slides down beside the
    /// minimized tab capsule and narrows to the remaining width.
    /// iOS 26 NowPlayingTray recipe, applied as written: cover +
    /// one title line + play/pause only — the artist line, the next
    /// button and the chevron are dropped while inline (the whole
    /// strip is still the tap target for the full player). Same
    /// height as the tab bar content (56) so the row reads as one
    /// unit with the capsule beside it.
    private func inlineBody(item: PlaybackItem) -> some View {
        HStack(spacing: 12) {
            // b36-1: the strip tap is a gesture, not a Button (see
            // expandedBody — a Spacer-expanded strip Button can
            // claim the tap meant for the play/pause button).
            HStack(spacing: 12) {
                // Beans MiniPlayerView: cover 36, radius 7 (expanded).
                // Inline the iOS 26 recipe uses 32 / radius 6.
                morphCover(
                    urlString: item.coverURL?.absoluteString ?? "",
                    size: HaoLayout.miniInlineCoverSize, cornerRadius: 6)
                Text(item.title)
                    .font(.haoFootnoteStrong)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTapFullPlayer)
            .accessibilityAddTraits(.isButton)
            if item.kind == .music {
                Button(action: { musicPlayer.togglePlayPauseOrRetry() }) {
                    Image(systemName: musicPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.haoCalloutStrong)
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(MusicPressScaleStyle())
                .contentShape(Rectangle())
                .accessibilityLabel(musicPlayer.isPlaying ? "暂停" : "播放")
            }
        }
        .padding(.horizontal, HaoLayout.miniPlayerContentPadding)
        .frame(height: HaoLayout.tabBarContentHeight)
        .haoGlassRoundedRect()
        .accessibilityLabel("迷你播放器：\(item.title)，点按打开全屏播放器")
    }

    /// Expanded form: the wide strip above the full tab bar.
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
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    // Real artwork when the item carries a cover
                    // URL; MusicCoverView falls back to the note
                    // placeholder when there is none.
                    // Beans MiniPlayerView: cover 36, radius 7.
                    morphCover(
                        urlString: item.coverURL?.absoluteString ?? "",
                        size: HaoLayout.miniCoverSize, cornerRadius: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        // Apple Music mini: title 15 / artist 13
                        // in the 64pt bar. This strip is 50pt, so
                        // 14 / 12 — one step up from the old
                        // 12 / 10, still fitting the 36 cover.
                        Text(item.title)
                            .font(.haoDenseTitle)
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
                    Button(action: { musicPlayer.togglePlayPauseOrRetry() }) {
                        Image(systemName: musicPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.haoCalloutStrong)
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(MusicPressScaleStyle())
                    .contentShape(Rectangle())
                    .accessibilityLabel(musicPlayer.isPlaying ? "暂停" : "播放")
                    // Apple Music's mini has a next button next to
                    // play/pause; ours wires the same next() as the
                    // full player (MusicPlayerViewModel.next()).
                    Button(action: { musicPlayer.next() }) {
                        Image(systemName: "forward.fill")
                            .font(.haoCalloutStrong)
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(MusicPressScaleStyle())
                    .contentShape(Rectangle())
                    .accessibilityLabel("下一曲")
                }
                Button(action: onTapFullPlayer) {
                    Image(systemName: "chevron.up")
                        .font(.haoDenseTitle)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 24, height: 32)
                }
                .buttonStyle(MusicPressScaleStyle())
            }
            // Symmetric content padding (was leading 10 / trailing
            // 6 — the strip read lopsided). Same 12pt step as the
            // tab bar's side margins (HaoLayout).
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
            .accessibilityLabel("迷你播放器：\(item.title)，点按打开全屏播放器")
        }
}

/// Fallback when the mini player cannot rebuild a real player
/// from the current item (only reachable for a live item whose id
/// does not parse as a room id — music / VOD / live all open
/// their real players). Shows the item title and a plain
/// "cannot play" note, never dev jargon, with a close button.
struct FullPlayerPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @Environment(\.haoTheme) private var theme

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

// HAo Studio 2.0 — mini player strip + full-player fallback.
//
// The mini player is a floating glass strip ABOVE the tab bar. Tapping it
// opens the full player. S2-C wiring:
// - The strip appears when the PlaybackCoordinator has a current item.
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
    @Environment(\.haoTheme) private var theme

    /// Opens the full player for the current item.
    var onTapFullPlayer: () -> Void

    var body: some View {
        if let item = coordinator.currentItem {
            // No nested Buttons: the strip tap area, the play/pause
            // button and the chevron are SIBLING buttons. A play/pause
            // Button nested inside the strip Button would also fire
            // the strip tap and open the full player on every pause.
            HStack(spacing: 12) {
                Button(action: onTapFullPlayer) {
                    HStack(spacing: 12) {
                        // Real artwork when the item carries a cover
                        // URL; MusicCoverView falls back to the note
                        // placeholder when there is none.
                        // Beans MiniPlayerView: cover 36, radius 7.
                        MusicCoverView(urlString: item.coverURL?.absoluteString ?? "", size: 36, cornerRadius: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            Text(item.subtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if item.kind == .music {
                    Button(action: { musicPlayer.togglePlayPause() }) {
                        Image(systemName: musicPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(musicPlayer.isPlaying ? "暂停" : "播放")
                }
                Button(action: onTapFullPlayer) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 24, height: 32)
                }
                .buttonStyle(.plain)
            }
            // Beans dock: leading 10 / trailing 6 (was 16 both
            // sides — the strip read wider than the tab bar).
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: HaoLayout.miniPlayerHeight)
            .haoGlassCapsule()
            .accessibilityLabel("迷你播放器：\(item.title)，点按打开全屏播放器")
        }
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
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                if let item = coordinator.currentItem {
                    Text(item.title)
                        .font(.system(size: 16))
                        .foregroundStyle(theme.textSecondary)
                }
                Text("当前内容无法播放")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textMuted)
            }
            .padding()
        }
        .overlay(alignment: .topTrailing) {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(theme.surfaceStrong, in: Circle())
            }
            .padding(16)
            .accessibilityLabel("关闭播放器")
        }
    }
}

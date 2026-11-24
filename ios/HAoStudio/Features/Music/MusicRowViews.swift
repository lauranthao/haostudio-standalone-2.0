// HAo Studio 2.0 — shared music rows (S2-C leg).
//
// Song rows, section headers, empty states and cover art used by
// every music list page. All colours come from the theme palette
// (HaoTheme); no hardcoded colours, no red, no purple.
// Radii follow the Beans values (audit §六): badge 4, small 6,
// standard 8, large 12, panel 20.

import SwiftUI

/// Cover art with a themed placeholder. AsyncImage handles the fetch;
/// a missing/empty URL shows the note placeholder, never a grey block.
/// The URL is upgraded http -> https at this choke point (ATS blocks
/// http under NSAllowsArbitraryLoads = false, and AsyncImage fails
/// silently), so every display site — rows, album/artist detail,
/// queue, recent, mini player — gets a fetchable URL.
struct MusicCoverView: View {
    var urlString: String
    var size: CGFloat
    var cornerRadius: CGFloat = 8

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            if let url = URL(string: MusicText.toHttps(urlString)), !urlString.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure, .empty:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(theme.surfaceStrong)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }
    }
}

/// One song row: cover, title + artist, platform badge, duration.
/// Tap = play. The row itself never invents actions: the context menu
/// offers only actions that exist (favourite / add to playlist).
struct MusicSongRow: View {
    var song: MusicSong
    var showPlatformBadge: Bool = true
    var isPlaying: Bool = false
    var onTap: () -> Void
    var onToggleFav: (() -> Void)?
    var onAddToPlaylist: (() -> Void)?

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                MusicCoverView(urlString: song.cover, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title.isEmpty ? "未知歌曲" : song.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isPlaying ? theme.accent : theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if showPlatformBadge, let badge = song.badgePlatform {
                            Text(badge.badgeName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(theme.hairline, lineWidth: 0.5)
                                }
                        }
                        Text(song.artist.isEmpty ? "未知艺人" : song.artist)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if song.dur > 0 {
                    Text(musicDurationText(seconds: song.dur))
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textMuted)
                }
                if isPlaying {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onToggleFav = onToggleFav {
                Button("收藏 / 取消收藏", action: onToggleFav)
            }
            if let onAddToPlaylist = onAddToPlaylist {
                Button("添加到歌单", action: onAddToPlaylist)
            }
        }
    }
}

/// Collapsible section header (Flutter CollapsibleSection): 22
/// semibold title, chevron, optional trailing control.
struct MusicSectionHeader: View {
    var title: String
    var expanded: Bool
    var onToggle: () -> Void
    var trailing: (() -> AnyView)? = nil

    @Environment(\.haoTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if let trailing = trailing {
                trailing()
            }
        }
    }
}

/// Empty state: icon + title + optional note. Used everywhere a list
/// is empty so an empty page always explains itself.
struct MusicEmptyState: View {
    var icon: String
    var title: String
    var note: String?

    @Environment(\.haoTheme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(theme.textMuted)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            if let note = note {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// Small capsule button (Flutter _CapsuleButton): accent-tinted pill.
struct MusicCapsuleButton: View {
    var icon: String
    var label: String
    var enabled: Bool = true
    var action: () -> Void

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(enabled ? theme.accent : theme.textMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(theme.accentSoft, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

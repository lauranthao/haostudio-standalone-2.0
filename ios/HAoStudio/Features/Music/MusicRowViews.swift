// HAo Studio 2.0 — shared music rows (S2-C leg).
//
// Song rows, section headers, empty states and cover art used by
// every music list page. All colours come from the theme palette
// (HaoTheme); no hardcoded colours, no red, no purple.
// Radii follow the Beans values (audit §六): badge 4, small 6,
// standard 8, large 12, panel 20.

import SwiftUI

// MARK: - Player view model, non-subscribing read path
//
// build 36, item 10, leg 3 (tick de-subscription): the shared
// MusicPlayerViewModel is injected as an .environmentObject at the
// app root (HAoStudioApp) so the player / mini bar / list pages can
// subscribe to it — but a row must NOT subscribe. Its `position`
// publishes every 0.5 s while playing, and an @EnvironmentObject
// subscription makes every visible row re-evaluate body on each
// tick. Reading the same instance through @Environment instead
// does NOT subscribe to objectWillChange (only @EnvironmentObject
// / @ObservedObject do), so a row can still call playNext /
// download on demand without paying for the tick. The value is
// the same instance for the app's lifetime, so it never changes
// and never invalidates a reader.
private struct MusicPlayerViewModelKey: EnvironmentKey {
    static let defaultValue: MusicPlayerViewModel? = nil
}

extension EnvironmentValues {
    var musicPlayerVM: MusicPlayerViewModel? {
        get { self[MusicPlayerViewModelKey.self] }
        set { self[MusicPlayerViewModelKey.self] = newValue }
    }
}

/// Cover art with a themed placeholder. Loads through the shared
/// image loader (HaoImageLoader, build 36 item 10 leg 6) at the
/// display size — a 56pt row cover decodes 168px at @3x, not the
/// full original — with the same placeholder on failure as the
/// old AsyncImage branch. The URL is upgraded http -> https at
/// this choke point (ATS blocks http under
/// NSAllowsArbitraryLoads = false, and AsyncImage fails
/// silently), so every display site — rows, album/artist detail,
/// queue, recent, mini player — gets a fetchable URL. The loader
/// normalises http -> https again internally, so the background
/// path (MusicPlayerView), which never upgraded, is covered too.
struct MusicCoverView: View {
    var urlString: String
    var size: CGFloat
    var cornerRadius: CGFloat = 8

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            if !urlString.isEmpty {
                HaoCachedImage(
                    urlString: MusicText.toHttps(urlString),
                    targetWidth: size,
                    targetHeight: size
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
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

/// One song row: cover (or track number), title + artist,
/// platform badge, duration. Tap = play. The "…" button at the
/// right edge opens the shared 7-action menu (see
/// MusicSongMenuHost); long-press opens the identical menu as a
/// context menu. The row itself never invents actions: the menu
/// offers only actions that exist for this song (favourite /
/// add to playlist / play next / download / share / view artist
/// / view album), hiding the ones that don't apply.
///
/// b45-b (Coda §3.2 TrackRow): height 64 (compact 50), cover
/// 48×48 r6, row HStack spacing 12, title body medium 1 line
/// (playing = theme accent), subtitle subheadline 1 line,
/// duration caption monospacedDigit tertiary width 36, heart
/// 18pt in a 24×24 box shown only when favourited, rank column
/// 28 wide (12pt mono, top 3 red), unplayable opacity 0.45.
/// Chart rows pass rankWide for the 52-wide rank column
/// (rank 13 medium mono + 7pt trend triangle).
struct MusicSongRow: View {
    var song: MusicSong
    var showPlatformBadge: Bool = true
    var isPlaying: Bool = false
    /// Apple Music detail-page track number (1-based). When set,
    /// the number replaces the cover — the row keeps the same
    /// title / artist / duration layout.
    var trackNumber: Int? = nil
    /// Coda chart rank (1-based). When set, a rank column leads
    /// the row (28 wide, 52 when rankWide).
    var rank: Int? = nil
    var rankWide: Bool = false
    /// Chart rank movement: > 0 up, < 0 down, 0 / nil = flat.
    var rankTrend: Int? = nil
    /// Coda compact row (album tracks): 50pt high, 40pt cover.
    var compact: Bool = false
    /// Show the 18pt heart when this song is favourited
    /// (Coda: the heart only renders for liked rows).
    var showFavHeart: Bool = false
    var onTap: () -> Void
    /// Post-toggle hook only: the row toggles the favourite itself
    /// (MusicSongMenuHost) and refreshes its own star from the
    /// haoMusicFavChanged notification — no list reload is needed
    /// for the star. Lists that still want a refresh after a
    /// toggle (music home) pass it here; home does not (build 36,
    /// item 10: a favourite tap no longer pays for a full reload).
    var onToggleFav: (() -> Void)? = nil
    /// Queue-only extra menu item ("不喜欢"): nil everywhere else.
    var onDislike: (() -> Void)? = nil
    /// Playlist-detail extra menu item ("从歌单中删除",
    /// destructive): nil everywhere else.
    var onRemoveFromList: (() -> Void)? = nil
    /// Menu-action injection (build 36, item 10, leg 3): when a
    /// caller already holds the player view model it may pass its
    /// play-next / download actions here. Nil everywhere else —
    /// the host then resolves the same actions on demand from the
    /// non-subscribing environment read (see MusicSongMenuHost),
    /// so no caller has to change and the row still never
    /// subscribes to the player's 0.5 s position tick.
    var onPlayNext: ((MusicSong) -> Void)? = nil
    var onDownload: ((MusicSong) -> Void)? = nil
    /// b45-F: show the inline download button / progress ring
    /// (plan §9.3). Off by default — callers opt in. Removal of
    /// an already-downloaded file goes through this callback
    /// (engine delete + library-store removal, owned by the view
    /// model); nil means the downloaded state is display-only.
    var showDownloadButton: Bool = false
    var onRemoveDownload: ((MusicSong) -> Void)? = nil

    @Environment(\.haoTheme) private var theme
    @State private var isFavRow = false

    /// Unplayable when the resolver left a reason (trial-only /
    /// VIP-only / no copyright): the row dims to 0.45 and shows
    /// the reason tag instead of pretending to play.
    private var isUnplayable: Bool { !song.reasonKey.isEmpty }

    var body: some View {
        // The "…" button is a SIBLING of the play button, never
        // nested inside it (nested buttons double-fire — build 35
        // search-history / MiniPlayerBar fix).
        MusicSongMenuHost(song: song, onFavToggled: onToggleFav, onDislike: onDislike, onPlayNext: onPlayNext, onDownload: onDownload, onRemoveFromList: onRemoveFromList.map { remove in { (_: MusicSong) in remove() } }) { menu in
            HStack(spacing: 8) {
                Button(action: onTap) {
                    HStack(spacing: 12) {
                        if let rank = rank {
                            MusicRankLabel(rank: rank, trend: rankTrend, wide: rankWide)
                        }
                        if let trackNumber = trackNumber {
                            Text("\(trackNumber)")
                                .font(.haoSubheadMedium)
                                .foregroundStyle(theme.textSecondary)
                                .frame(width: 28, alignment: .center)
                        } else {
                            MusicCoverView(urlString: song.cover, size: compact ? 40 : 48, cornerRadius: 6)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title.isEmpty ? "未知歌曲" : song.title)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(isPlaying ? theme.accentText : theme.textPrimary)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                if showPlatformBadge, let badge = song.badgePlatform {
                                    Text(badge.badgeName)
                                        .font(.haoCaption2Strong)
                                        .foregroundStyle(theme.textSecondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                .strokeBorder(theme.hairline, lineWidth: 0.5)
                                        }
                                }
                                Text(song.artist.isEmpty ? "未知艺人" : song.artist)
                                    .font(.haoSubhead)
                                    .foregroundStyle(theme.textSecondary)
                                    .lineLimit(1)
                            }
                            if isUnplayable {
                                MusicUnplayableTag(text: song.reasonArg.isEmpty ? "不可播" : song.reasonArg)
                            }
                        }
                        Spacer()
                        if showFavHeart && isFavRow {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(theme.liveRed)
                                .frame(width: 24, height: 24)
                        }
                        if song.dur > 0 {
                            Text(musicDurationText(seconds: song.dur))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(theme.textMuted)
                                .frame(width: 36, alignment: .trailing)
                        }
                        if isPlaying {
                            MusicPlayingEQView()
                        }
                    }
                    .frame(minHeight: compact ? 50 : 64)
                    .contentShape(Rectangle())
                    .opacity(isUnplayable ? 0.45 : 1.0)
                }
                .buttonStyle(.plain)
                MusicSongMenuButton(handle: menu)
                if showDownloadButton {
                    TrackDownloadButton(
                        song: song, onDownload: onDownload,
                        onRemoveDownload: onRemoveDownload)
                }
            }
            .contextMenu { menu.menuContent() }
            .onAppear { isFavRow = MusicLibraryStore.isFav(song) }
            .onReceive(NotificationCenter.default.publisher(for: .haoMusicFavChanged)) { _ in
                isFavRow = MusicLibraryStore.isFav(song)
            }
        }
    }
}

// MARK: - Coda §3.2 shared rows / cards (b45-b)

/// Compact play-count number (Coda PlayCountBadge text):
/// 1.2万 / 3.4亿, never a ".0" tail.
func musicCompactCount(_ count: Int) -> String {
    if count <= 0 { return "" }
    if count >= 100_000_000 {
        let formatted = String(format: "%.1f亿", Double(count) / 100_000_000)
        if formatted.hasSuffix(".0亿") { return String(formatted.dropLast(3)) + "亿" }
        return formatted
    }
    if count >= 10_000 {
        let value = Double(count) / 10_000
        if value >= 100 { return "\(Int(value))万" }
        let formatted = String(format: "%.1f万", value)
        if formatted.hasSuffix(".0万") { return String(formatted.dropLast(3)) + "万" }
        return formatted
    }
    return "\(count)"
}

/// Coda chart rank column: 28 wide (52 wide on chart pages),
/// 12pt mono (13pt wide), top 3 in the meaningful red, plus a
/// 7pt trend triangle (up = red, down = muted).
struct MusicRankLabel: View {
    var rank: Int
    var trend: Int? = nil
    var wide: Bool = false

    @Environment(\.haoTheme) private var theme

    var body: some View {
        VStack(spacing: 1) {
            Text("\(rank)")
                .font(.system(size: wide ? 13 : 12, weight: .medium, design: .monospaced))
                .foregroundStyle(rank <= 3 ? theme.liveRed : theme.textSecondary)
            if let trend = trend, trend != 0 {
                Image(systemName: "triangle.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(trend > 0 ? theme.liveRed : theme.textMuted)
                    .rotationEffect(.degrees(trend > 0 ? 0 : 180))
            }
        }
        .frame(width: wide ? 52 : 28, alignment: .center)
    }
}

/// Coda unplayable-reason tag: 10pt medium, quaternary fill,
/// r4, padding 5×2.
struct MusicUnplayableTag: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Coda CoverCard: 178×178, r8 + 0.5pt primary 0.08 stroke,
/// cover→text 8, title→subtitle 4, title cardTitle max 2 lines,
/// subtitle secondary max 1 line. Play-count badge overlays the
/// cover's top-trailing corner (8pt margin).
struct MusicCoverCard: View {
    var coverURL: String
    var title: String
    var subtitle: String
    var playCount: Int? = nil
    var isVIP: Bool = false
    var size: CGFloat = 178
    var onTap: (() -> Void)? = nil

    @Environment(\.haoTheme) private var theme

    var body: some View {
        // b48: same rule as MusicCoverCardBody — no disabled Button
        // (it renders dimmed, i.e. a grey veil over the cover).
        // The Button exists only when there is an action.
        Group {
            if let onTap = onTap {
                Button(action: onTap) { cardContent }
                    .buttonStyle(.plain)
            } else {
                cardContent
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            MusicCoverView(urlString: coverURL, size: size, cornerRadius: 8)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .overlay(alignment: .topTrailing) {
                    if let playCount = playCount, playCount > 0 {
                        MusicPlayCountBadge(count: playCount)
                            .padding(8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isVIP {
                        MusicVIPBadge()
                            .padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(title.isEmpty ? "未知" : title)
                    .font(.haoBodyStrong)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(width: size, alignment: .leading)
    }
}

/// Coda CoverCardBody (home / grid variant): r22 cover, title
/// body medium max 2 lines, subtitle caption 13 max 1 line.
struct MusicCoverCardBody: View {
    var coverURL: String
    var title: String
    var subtitle: String
    var size: CGFloat = 178
    var onTap: (() -> Void)? = nil

    @Environment(\.haoTheme) private var theme

    var body: some View {
        // b48 (chen 2026-11-25 build 47: "发现歌单这里图片都是灰
        // 色的"): the card used to ALWAYS be a Button, disabled
        // when onTap is nil — and every grid usage (发现歌单 / 新
        // 专辑 / 歌单广场 / 我的专辑) passes no onTap because the
        // surrounding NavigationLink owns the tap. A disabled
        // Button renders dimmed, so every cover read as a grey
        // veil over the photo (the mini player and chart covers,
        // whose Buttons have actions, stayed vivid). A Button with
        // no action is also the wrong shape for a NavigationLink
        // label (nested buttons). The Button now exists only when
        // there is an action; otherwise the card is plain content.
        Group {
            if let onTap = onTap {
                Button(action: onTap) { cardContent }
                    .buttonStyle(.plain)
            } else {
                cardContent
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            MusicCoverView(urlString: coverURL, size: size, cornerRadius: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title.isEmpty ? "未知" : title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(width: size, alignment: .leading)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: size, alignment: .leading)
            }
            .frame(width: size, alignment: .leading)
        }
        .frame(width: size, alignment: .leading)
        // b47-home: clip to the card bounds — the meta line used
        // to spill past the card's right edge and read as cut
        // mid-character (chen's 16:11 frames); the explicit text
        // widths + tail truncation make every line end cleanly
        // with an ellipsis instead.
        .clipped()
    }
}

/// Coda PlayCountBadge: 8pt bold play icon + badge semibold,
/// white, padding 8×4, black 0.35 + ultraThinMaterial 0.6,
/// capsule, cover top-trailing corner.
struct MusicPlayCountBadge: View {
    var count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .bold))
            Text(musicCompactCount(count))
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.35), in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .opacity(0.9)
    }
}

/// Coda VIP badge: "VIP" badge bold, theme accent, padding 4×2,
/// 1pt accent 0.8 stroke, r3.
struct MusicVIPBadge: View {
    @Environment(\.haoTheme) private var theme

    var body: some View {
        Text("VIP")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(theme.accentText)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(theme.accent.opacity(0.8), lineWidth: 1)
            }
    }
}

/// Coda skeleton block: quaternary 0.5 fill. Static (no sweep)
/// — the shimmer sweep is a polish item, not a layout value.
struct MusicSkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .frame(width: width, height: height)
    }
}

/// One skeleton song row (48 cover + two text bars), Coda
/// loading state for track lists.
struct MusicSkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            MusicSkeletonBlock(width: 48, height: 48, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 6) {
                MusicSkeletonBlock(width: 160, height: 14)
                MusicSkeletonBlock(width: 110, height: 11)
            }
            Spacer()
        }
        .frame(minHeight: 64)
    }
}

/// One skeleton cover card (178 cover + two text bars).
struct MusicSkeletonCard: View {
    var size: CGFloat = 178

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MusicSkeletonBlock(width: size, height: size, cornerRadius: 22)
            MusicSkeletonBlock(width: size * 0.8, height: 14)
            MusicSkeletonBlock(width: size * 0.6, height: 11)
        }
        .frame(width: size, alignment: .leading)
    }
}

// MARK: - Coda §3.6 detail Hero + primary actions (b45-b)

/// Shared detail Hero (playlist / album / artist, Coda
/// PlaylistDetailHero): cover min(available width × 0.68, 300),
/// square, r12, shadow black 0.18 / radius 18 / y 10; title
/// detailTitle (title2 bold) centred max 2 lines, top padding
/// 24, side margin 20; subtitle row avatar 24×24 circle +
/// subtitle secondary 1 line, spacing 8, top padding 8;
/// metadata secondary + medium 1 line, minimum scale 0.8, top
/// padding 8; hero vertical padding 20. The top of a detail
/// page is the cover — never a big play button in the middle
/// (chen 2026-11-24, VidHub direction).
struct MusicDetailHero: View {
    var coverURL: String
    var isCircular: Bool = false
    var title: String
    var subtitle: String
    var avatarURL: String = ""
    var metadata: String

    @Environment(\.haoTheme) private var theme

    /// Cover from the real screen width (never a hardcoded
    /// number): min((screen − 40) × 0.68, 300). Detail pages are
    /// full-width on iPhone, so the screen width is the available
    /// width minus the page's side margins.
    private var coverSize: CGFloat {
        min((UIScreen.main.bounds.width - 40) * 0.68, 300)
    }

    var body: some View {
        VStack(spacing: 0) {
            MusicCoverView(
                urlString: coverURL, size: coverSize,
                cornerRadius: isCircular ? coverSize / 2 : 12
            )
            .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
            Text(title.isEmpty ? "未知" : title)
                .font(.haoDetailTitle)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.top, 24)
                .padding(.horizontal, 20)
            HStack(spacing: 8) {
                if !avatarURL.isEmpty {
                    MusicCoverView(urlString: avatarURL, size: 24, cornerRadius: 12)
                }
                Text(subtitle)
                    .font(.haoSubhead)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.top, 8)
            if !metadata.isEmpty {
                Text(metadata)
                    .font(.haoFootnoteMedium)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

/// Coda PlaylistPrimaryActions: height 56, max width 328, side
/// margin 20, HStack spacing 12. Favourite 56×56 glass circle;
/// play capsule min width 116, stretched, height 56, headline
/// font, theme accent background + on-accent text (recomputed
/// from the theme — never hardcoded black-on-white /
/// white-on-black); more ellipsis title2 semibold 56×56 glass
/// circle. The caller supplies the "…" menu content.
struct MusicDetailPrimaryActions<More: View>: View {
    var isFavourite: Bool
    var onToggleFavourite: () -> Void
    var onPlay: () -> Void
    var playEnabled: Bool = true
    @ViewBuilder var more: () -> More

    @Environment(\.haoTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleFavourite) {
                Image(systemName: isFavourite ? "checkmark" : "star")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isFavourite ? theme.accentText : theme.textPrimary)
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay { Circle().strokeBorder(theme.hairline, lineWidth: 0.5) }
            }
            .buttonStyle(MusicPressScaleStyle())
            .accessibilityLabel(isFavourite ? "已收藏" : "收藏")
            Button(action: onPlay) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("播放")
                }
                .font(.headline)
                .foregroundStyle(theme.onAccent)
                .frame(minWidth: 116, maxWidth: .infinity, minHeight: 56, maxHeight: 56)
                .background(theme.accent, in: Capsule())
            }
            .buttonStyle(MusicPressScaleStyle())
            .disabled(!playEnabled)
            .accessibilityLabel("播放全部")
            Menu {
                more()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay { Circle().strokeBorder(theme.hairline, lineWidth: 0.5) }
            }
            .accessibilityLabel("更多操作")
        }
        .frame(maxWidth: 328)
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }
}

// MARK: - Coda §3.6 playlist sort (b45-b)

/// Coda PlaylistTrackSort: add-time (new→old / old→new), song
/// name, album name, artist name — localizedStandardCompare,
/// ties keep the original order (stable sort).
enum MusicPlaylistSortOrder: String, CaseIterable {
    case addedDesc
    case addedAsc
    case title
    case album
    case artist

    var label: String {
        switch self {
        case .addedDesc: return "添加时间（由新到旧）"
        case .addedAsc: return "添加时间（由旧到新）"
        case .title: return "歌曲名"
        case .album: return "专辑名"
        case .artist: return "歌手名"
        }
    }
}

func musicSortedPlaylistTracks(_ tracks: [MusicSong], by order: MusicPlaylistSortOrder) -> [MusicSong] {
    switch order {
    case .addedDesc:
        return Array(tracks.reversed())
    case .addedAsc:
        return tracks
    case .title, .album, .artist:
        return tracks.enumerated().sorted { lhs, rhs in
            let left: String
            let right: String
            switch order {
            case .title: left = lhs.element.title; right = rhs.element.title
            case .album: left = lhs.element.album; right = rhs.element.album
            case .artist: left = lhs.element.artist; right = rhs.element.artist
            default: left = ""; right = ""
            }
            let compared = left.localizedStandardCompare(right)
            if compared != .orderedSame { return compared == .orderedAscending }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }
}

// MARK: - Coda §9.2 PlaySource / PlayContext (b45-b)

/// A reloadable playback "place" (Coda PlaySource): playlist /
/// album / artist / daily / recent / heartbeat / FM. Identity
/// is kind + id — a rename never changes the identity.
enum MusicPlaySourceKind: String {
    case playlist
    case album
    case artist
    case daily
    case recent
    case heartbeat
    case fm
}

struct MusicPlaySource: Hashable, Equatable {
    var kind: MusicPlaySourceKind
    var id: String

    static let recent = MusicPlaySource(kind: .recent, id: "recent")
    static let daily = MusicPlaySource(kind: .daily, id: "daily")
    static let fm = MusicPlaySource(kind: .fm, id: "fm")
    static let heartbeat = MusicPlaySource(kind: .heartbeat, id: "heartbeat")
}

// MARK: - Coda §3.1 SectionHeader (b45-b)

/// Coda SectionHeader: sectionTitle semibold + 13pt semibold
/// accent chevron (hover: chevron +2pt in 0.15s — iOS has no
/// hover, so the chevron is fixed 13pt); header min height 44,
/// 16pt gap to the content below. Non-collapsible: taps the
/// action (usually "view all") when one is given.
struct MusicCodaSectionHeader: View {
    var title: String
    var action: (() -> Void)? = nil

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Button(action: { action?() }) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.haoSectionTitle)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}
// MARK: - Shared song actions menu (build 36, item 12)

/// Pure, testable availability for the shared song menu: an item
/// is hidden when it cannot do anything real for this song — never
/// a dead entry. Download stays visible for an already-downloaded
/// song (the engine toasts "已下载"); only a local file hides it
/// (there is nothing to download).
enum MusicSongMenuAvailability {
    /// False for an imported local file (already on the device).
    static func canDownload(song: MusicSong) -> Bool { !song.isLocal }
    /// False when there is no artist name to look up.
    static func canViewArtist(song: MusicSong) -> Bool {
        !song.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// False when there is no album name to look up.
    static func canViewAlbum(song: MusicSong) -> Bool {
        !song.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// Real share text from the song itself. MusicSong carries no
    /// shareable URL and none is invented.
    static func shareText(song: MusicSong) -> String {
        let platform = song.badgePlatform?.badgeName ?? ""
        if platform.isEmpty { return "《\(song.title)》 - \(song.artist)" }
        return "《\(song.title)》 - \(song.artist)（\(platform)）"
    }
}

/// The 7 shared song actions, built from one handle so a "…"
/// Menu and a long-press context menu offer the identical items.
/// Play-next / download run on the shared player view model;
/// view-artist / view-album open their sheets via the host.
struct MusicSongMenuContent: View {
    var song: MusicSong
    var isFav: Bool
    var showDownload: Bool = true
    var onToggleFav: () -> Void
    var onAddToPlaylist: () -> Void
    var onPlayNext: () -> Void
    var onDownload: () -> Void
    var onShowArtist: () -> Void
    var onShowAlbum: () -> Void
    var onDislike: (() -> Void)? = nil
    /// Coda §8.5: destructive "从歌单中删除" — only when the
    /// row is rendered inside its own playlist.
    var onRemoveFromList: (() -> Void)? = nil

    var body: some View {
        Group {
            Button(action: onToggleFav) {
                Label(isFav ? "取消收藏" : "收藏", systemImage: isFav ? "heart.fill" : "heart")
            }
            Button(action: onAddToPlaylist) {
                Label("加入歌单", systemImage: "text.badge.plus")
            }
            Button(action: onPlayNext) {
                Label("下一首播放", systemImage: "text.insert")
            }
            if showDownload && MusicSongMenuAvailability.canDownload(song: song) {
                Button(action: onDownload) {
                    Label("下载", systemImage: "arrow.down.circle")
                }
            }
            ShareLink(item: MusicSongMenuAvailability.shareText(song: song)) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            if MusicSongMenuAvailability.canViewArtist(song: song) {
                Button(action: onShowArtist) {
                    Label("查看歌手", systemImage: "person")
                }
            }
            if MusicSongMenuAvailability.canViewAlbum(song: song) {
                Button(action: onShowAlbum) {
                    Label("查看专辑", systemImage: "square.stack")
                }
            }
            if let onDislike = onDislike {
                Button(role: .destructive, action: onDislike) {
                    Label("不喜欢（私人漫游不再推）", systemImage: "hand.thumbsdown")
                }
            }
            if let onRemoveFromList = onRemoveFromList {
                Button(role: .destructive, action: onRemoveFromList) {
                    Label("从歌单中删除", systemImage: "trash")
                }
            }
        }
    }
}

/// One song's menu wiring: the song, the host's state bindings,
/// and the two player actions as plain closures. The host builds
/// one handle per body evaluation, so the "…" Menu and the
/// long-press context menu read the same favourite flag and open
/// the same sheets.
///
/// build 36, item 10, leg 3: the handle used to hold the whole
/// MusicPlayerViewModel, which made every row subscribe to the
/// player's 0.5 s position tick through the host's
/// @EnvironmentObject. It now holds only the two closures the
/// menu actually calls (play-next / download); the view model
/// itself never enters a row.
struct MusicSongMenuHandle {
    var song: MusicSong
    var onPlayNext: (MusicSong) -> Void
    var onDownload: (MusicSong) -> Void
    var isFav: Binding<Bool>
    var showAddToPlaylist: Binding<Bool>
    var showAlbum: Binding<Bool>
    var showArtist: Binding<Bool>
    var showDownload: Bool = true
    var onFavToggled: (() -> Void)? = nil
    var onDislike: (() -> Void)? = nil
    var onRemoveFromList: (() -> Void)? = nil

    func menuContent() -> MusicSongMenuContent {
        MusicSongMenuContent(
            song: song,
            isFav: isFav.wrappedValue,
            showDownload: showDownload,
            onToggleFav: {
                isFav.wrappedValue = MusicLibraryStore.toggleFav(song)
                onFavToggled?()
            },
            onAddToPlaylist: { showAddToPlaylist.wrappedValue = true },
            onPlayNext: { onPlayNext(song) },
            onDownload: { onDownload(song) },
            onShowArtist: { showArtist.wrappedValue = true },
            onShowAlbum: { showAlbum.wrappedValue = true },
            onDislike: onDislike,
            onRemoveFromList: onRemoveFromList
        )
    }
}

/// The visible "…" button: 28×28 hit target, ellipsis icon,
/// theme secondary text — Apple Music's row affordance. The
/// favourite label inside the menu is live (the host syncs it),
/// so this button needs no state of its own.
struct MusicSongMenuButton: View {
    var handle: MusicSongMenuHandle

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Menu { handle.menuContent() } label: {
            Image(systemName: "ellipsis")
                .font(.haoSubheadStrong)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多操作")
    }
}

/// Owns one song's action-menu state (favourite flag, the three
/// sheets) and vends a handle to its content, so a row ("…"
/// Menu + long-press) and a shelf card (long-press only) offer
/// the identical menu without duplicating state. The favourite
/// flag is read from the store on appear / when the song changes,
/// and refreshed on `haoMusicFavChanged` — so a toggle from any
/// other row, card, or the full player updates this menu's label
/// live. Artist / album sheets get their own NavigationStack
/// (same as the full player) so they present from every list,
/// including the queue sheet, with no plumbing into the caller's
/// navigation stack. The detail view models resolve an empty id
/// by name search, so no id is faked.
struct MusicSongMenuHost<Content: View>: View {
    var song: MusicSong
    var showDownload: Bool = true
    var onFavToggled: (() -> Void)? = nil
    var onDislike: (() -> Void)? = nil
    /// Caller-injected player actions (build 36, item 10, leg 3).
    /// Nil by default: the host then resolves them on demand from
    /// the non-subscribing environment read below, so existing
    /// call sites need no change.
    var onPlayNext: ((MusicSong) -> Void)? = nil
    var onDownload: ((MusicSong) -> Void)? = nil
    var onRemoveFromList: ((MusicSong) -> Void)? = nil
    @ViewBuilder var content: (MusicSongMenuHandle) -> Content

    /// Non-subscribing read of the shared player view model (see
    /// the EnvironmentKey above): @Environment does NOT subscribe
    /// to objectWillChange, so this host — and every row / card
    /// that embeds it — no longer re-evaluates body on the
    /// player's 0.5 s position tick. The model is only touched
    /// when the user actually taps 下一首播放 / 下载, through the
    /// closures built in `handle`. Deliberately NOT
    /// @EnvironmentObject: that was the subscription this leg
    /// removes.
    @Environment(\.musicPlayerVM) private var playerVM
    @State private var isFav = false
    @State private var showAddToPlaylist = false
    @State private var showAlbum = false
    @State private var showArtist = false

    var body: some View {
        content(handle)
            .sheet(isPresented: $showAddToPlaylist) {
                MusicAddToPlaylistSheet(song: song) { showAddToPlaylist = false }
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showAlbum) {
                NavigationStack {
                    MusicAlbumDetailView(album: AlbumSummary(
                        id: "", name: song.album, artist: song.artist,
                        platform: song.platform))
                }
            }
            .sheet(isPresented: $showArtist) {
                NavigationStack {
                    MusicArtistDetailView(artist: ArtistSummary(
                        id: "", name: MusicAPIJSON.firstArtist(song.artist),
                        platform: song.platform))
                }
            }
            .onAppear { isFav = MusicLibraryStore.isFav(song) }
            .onChange(of: song.identityKey) { _, _ in isFav = MusicLibraryStore.isFav(song) }
            .onReceive(NotificationCenter.default.publisher(for: .haoMusicFavChanged)) { _ in
                isFav = MusicLibraryStore.isFav(song)
            }
    }

    private var handle: MusicSongMenuHandle {
        // Injected closures win; otherwise resolve the player
        // actions on demand from the non-subscribing environment
        // read. Same calls as before (MusicPlayerViewModel
        // .playNext / .download, with their toasts), only the
        // subscription is gone — no behaviour change. A nil model
        // (host used outside the app root) makes the two actions
        // no-ops instead of crashing on a missing environment
        // object; the rest of the menu still works.
        let playNext = onPlayNext ?? { [playerVM] song in playerVM?.playNext(song: song) }
        let download = onDownload ?? { [playerVM] song in playerVM?.download(song: song) }
        return MusicSongMenuHandle(
            song: song,
            onPlayNext: playNext,
            onDownload: download,
            isFav: $isFav,
            showAddToPlaylist: $showAddToPlaylist,
            showAlbum: $showAlbum,
            showArtist: $showArtist,
            showDownload: showDownload,
            onFavToggled: onFavToggled,
            onDislike: onDislike,
            onRemoveFromList: onRemoveFromList.map { remove in { [song] in remove(song) } }
        )
    }
}

/// Apple Music's playing indicator: three accent bars that dance
/// while the track plays (the static waveform glyph read as a dead
/// icon next to a live row). Shown only on the playing row; the
/// animation is transform-free height tweens, cheap in a list.
struct MusicPlayingEQView: View {
    @State private var animating = false

    @Environment(\.haoTheme) private var theme

    private let topHeights: [CGFloat] = [14, 10, 16]
    private let restHeights: [CGFloat] = [6, 12, 8]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(theme.accent)
                    .frame(
                        width: 3,
                        height: animating ? topHeights[index] : restHeights[index]
                    )
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .frame(height: 16, alignment: .bottom)
        .onAppear { animating = true }
    }
}

/// Press feedback (Apple Music: transport buttons shrink to 0.92
/// on tap, spring back). A plain ButtonStyle so any music button
/// can take it without touching its layout.
struct MusicPressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(
                .spring(response: 0.3, dampingFraction: 0.8),
                value: configuration.isPressed
            )
    }
}

/// Collapsible section header (Flutter CollapsibleSection): 22
/// semibold title, chevron, optional trailing control.
/// b40: `titleFont` lets one page ask for the visibly larger
/// header (MusicHomeView passes 28 bold, vibrdrome's section
/// size) without changing the shared default everywhere else.
struct MusicSectionHeader: View {
    var title: String
    var expanded: Bool
    var onToggle: () -> Void
    var trailing: (() -> AnyView)? = nil
    var titleFont: Font = .haoDetailTitle

    @Environment(\.haoTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { withAnimation(HaoLayout.settleSpring) { onToggle() } }) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(titleFont)
                        .foregroundStyle(theme.textPrimary)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        // b45-b (Coda §3.1 SectionHeader): 13pt
                        // semibold accent chevron.
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .animation(HaoLayout.settleSpring, value: expanded)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if let trailing = trailing {
                trailing()
            }
        }
        // b45-b: header min height 44 (Coda §3.1).
        .frame(minHeight: 44)
    }
}

/// Empty state: icon + title + optional note. Used everywhere a list
/// is empty so an empty page always explains itself.
/// `onRetry` (build 36, item 8): load-failure states pass a retry
/// action, so "稍后再试" is never a dead end the user can only
/// escape by leaving the page and coming back. Honest empties
/// (no favourites yet, empty queue, …) leave it nil.
struct MusicEmptyState: View {
    var icon: String
    var title: String
    var note: String?
    var onRetry: (() -> Void)? = nil

    @Environment(\.haoTheme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                // .title is 28pt regular: pixel-identical to the
                // old literal, same fix as D7 (EmbyPosterImage).
                .font(.title)
                .foregroundStyle(theme.textMuted)
            Text(title)
                .font(.haoSubheadStrong)
                .foregroundStyle(theme.textPrimary)
            if let note = note {
                Text(note)
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let onRetry = onRetry {
                MusicCapsuleButton(icon: "arrow.clockwise", label: "重试", action: onRetry)
                    .padding(.top, 6)
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
                    .font(.haoCaptionStrong)
                Text(label)
                    .font(.haoFootnoteStrong)
            }
            .foregroundStyle(enabled ? theme.accentText : theme.textMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(theme.accentSoft, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - b45-F: inline download button + progress ring (plan §9.3)
//
// Fixed 24pt — it never pushes the title / duration around.
// While a download runs it becomes a progress ring; a long
// press offers pause / resume / stop; a downloaded song asks
// for confirmation before it is removed. Progress isolation:
// each row subscribes ONLY to its own task (via its own
// TrackDownloadObserver), and the byte counter ticks at 4/s —
// only that row's ring redraws.

/// Per-row download observer: polls its own task at 4/s, only
/// while the task is non-terminal. One observer per row, so a
/// progress tick never redraws another row.
final class TrackDownloadObserver: ObservableObject {
    /// 4 ticks per second (plan §9.3).
    static let pollInterval: TimeInterval = 0.25

    let key: String
    @Published private(set) var info: DownloadTaskInfo?
    private var timer: Timer?

    init(key: String) {
        self.key = key
        refresh()
    }

    deinit { timer?.invalidate() }

    /// Start polling (called from .onAppear). A terminal task
    /// never starts the timer.
    func start() {
        refresh()
        guard timer == nil, let state = info?.state, !state.isTerminal else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        info = DownloadEngine.shared.taskInfo(for: key)
        if let state = info?.state, state.isTerminal {
            timer?.invalidate()
            timer = nil
        }
    }
}

struct TrackDownloadButton: View {
    var song: MusicSong
    var onDownload: ((MusicSong) -> Void)?
    var onRemoveDownload: ((MusicSong) -> Void)?

    @StateObject private var observer: TrackDownloadObserver
    @State private var showRemoveConfirm = false

    @Environment(\.haoTheme) private var theme

    init(song: MusicSong, onDownload: ((MusicSong) -> Void)? = nil,
         onRemoveDownload: ((MusicSong) -> Void)? = nil) {
        self.song = song
        self.onDownload = onDownload
        self.onRemoveDownload = onRemoveDownload
        _observer = StateObject(wrappedValue: TrackDownloadObserver(key: song.identityKey))
    }

    private var progressFraction: Double {
        guard let info = observer.info, info.totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(info.downloadedBytes) / Double(info.totalBytes)))
    }

    var body: some View {
        Group {
            switch observer.info?.state {
            case .completed:
                Button {
                    if onRemoveDownload != nil { showRemoveConfirm = true }
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(theme.accentText)
                }
            case .downloading, .queued, .fetchingURL, .validating, .waitingNetwork:
                // Progress ring (fixed 24pt, never resizes the row).
                ZStack {
                    Circle()
                        .stroke(theme.hairline, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: CGFloat(progressFraction))
                        .stroke(theme.accentText, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 20, height: 20)
                .contextMenu {
                    Button("暂停") { DownloadEngine.shared.pause(key: song.identityKey) }
                    Button("继续") { DownloadEngine.shared.resume(key: song.identityKey) }
                    Button("停止", role: .destructive) {
                        DownloadEngine.shared.cancel(key: song.identityKey)
                    }
                }
            case .paused:
                Button {
                    DownloadEngine.shared.resume(key: song.identityKey)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(theme.textSecondary)
                }
                .contextMenu {
                    Button("继续") { DownloadEngine.shared.resume(key: song.identityKey) }
                    Button("停止", role: .destructive) {
                        DownloadEngine.shared.cancel(key: song.identityKey)
                    }
                }
            case .failed:
                Button {
                    DownloadEngine.shared.resume(key: song.identityKey)
                } label: {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(theme.textSecondary)
                }
                .contextMenu {
                    Button("重试") { DownloadEngine.shared.resume(key: song.identityKey) }
                    Button("停止", role: .destructive) {
                        DownloadEngine.shared.cancel(key: song.identityKey)
                    }
                }
            default:
                Button {
                    onDownload?(song)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .frame(width: 24, height: 24)
        .buttonStyle(.plain)
        .onAppear { observer.start() }
        .onDisappear { observer.stop() }
        .confirmationDialog(
            "移除已下载？",
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("移除", role: .destructive) { onRemoveDownload?(song) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除本机上的音频文件。")
        }
    }
}

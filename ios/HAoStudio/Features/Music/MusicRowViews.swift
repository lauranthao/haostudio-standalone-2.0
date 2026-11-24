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
/// Apple Music shape: 56pt cover, 10pt radius, title 16 semibold,
/// artist 14 secondary, duration right. Album / chart / playlist
/// track lists pass `trackNumber` instead: Apple Music numbers
/// tracks in detail pages (01, 02…) and shows no cover per row.
struct MusicSongRow: View {
    var song: MusicSong
    var showPlatformBadge: Bool = true
    var isPlaying: Bool = false
    /// Apple Music detail-page track number (1-based). When set,
    /// the number replaces the cover — the row keeps the same
    /// title / artist / duration layout.
    var trackNumber: Int? = nil
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
    /// Menu-action injection (build 36, item 10, leg 3): when a
    /// caller already holds the player view model it may pass its
    /// play-next / download actions here. Nil everywhere else —
    /// the host then resolves the same actions on demand from the
    /// non-subscribing environment read (see MusicSongMenuHost),
    /// so no caller has to change and the row still never
    /// subscribes to the player's 0.5 s position tick.
    var onPlayNext: ((MusicSong) -> Void)? = nil
    var onDownload: ((MusicSong) -> Void)? = nil

    @Environment(\.haoTheme) private var theme

    var body: some View {
        // The "…" button is a SIBLING of the play button, never
        // nested inside it (nested buttons double-fire — build 35
        // search-history / MiniPlayerBar fix).
        MusicSongMenuHost(song: song, onFavToggled: onToggleFav, onDislike: onDislike, onPlayNext: onPlayNext, onDownload: onDownload) { menu in
            HStack(spacing: 8) {
                Button(action: onTap) {
                    HStack(spacing: 12) {
                        if let trackNumber = trackNumber {
                            Text("\(trackNumber)")
                                .font(.haoSubheadMedium)
                                .foregroundStyle(theme.textSecondary)
                                .frame(width: 28, alignment: .center)
                        } else {
                            MusicCoverView(urlString: song.cover, size: 56, cornerRadius: 10)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title.isEmpty ? "未知歌曲" : song.title)
                                .font(.haoCalloutStrong)
                                .foregroundStyle(isPlaying ? theme.accent : theme.textPrimary)
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
                                    .font(.haoRowSubtitle)
                                    .foregroundStyle(theme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if song.dur > 0 {
                            Text(musicDurationText(seconds: song.dur))
                                .font(.haoFootnote)
                                .foregroundStyle(theme.textMuted)
                        }
                        if isPlaying {
                            MusicPlayingEQView()
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                MusicSongMenuButton(handle: menu)
            }
            .contextMenu { menu.menuContent() }
        }
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
            onDislike: onDislike
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
            onDislike: onDislike
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
struct MusicSectionHeader: View {
    var title: String
    var expanded: Bool
    var onToggle: () -> Void
    var trailing: (() -> AnyView)? = nil

    @Environment(\.haoTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { withAnimation(HaoLayout.settleSpring) { onToggle() } }) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.haoDetailTitle)
                        .foregroundStyle(theme.textPrimary)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.haoDenseTitle)
                        .foregroundStyle(theme.textSecondary)
                        .animation(HaoLayout.settleSpring, value: expanded)
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
            .foregroundStyle(enabled ? theme.accent : theme.textMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(theme.accentSoft, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

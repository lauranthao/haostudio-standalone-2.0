// HAo Studio 2.0 — album detail page (S3-C leg).
//
// S2 built the API (MusicAlbumAPI: wy / tx / kg / kw search +
// detail) and left the page as a placeholder. This is the page:
// cover + name + artist + year + track list, play-all, tap a
// track to play.
//
// Id fallback (the API's own convention): a summary without a
// real id — Kugou's opaque `album|artist` key, QQ's `qq-album-…`
// key, or an empty id from the player — resolves by searching
// the album name first and loading the first artist-matching
// hit. A detail that still comes back empty shows an honest
// empty state, never a fake track list.

import SwiftUI

@MainActor
final class MusicAlbumDetailViewModel: ObservableObject {
    @Published private(set) var detail = AlbumDetail(name: "")
    @Published private(set) var isLoading = true

    private let album: AlbumSummary

    init(album: AlbumSummary) {
        self.album = album
        self.detail = AlbumDetail(name: album.name, pic: album.cover, artist: album.artist)
    }

    var songs: [MusicSong] {
        detail.songs.map(MusicSong.init(from:))
    }

    var yearText: String {
        guard album.publishTime > 0 else { return "" }
        let year = Calendar.current.component(
            .year, from: Date(timeIntervalSince1970: TimeInterval(album.publishTime) / 1000))
        return year > 0 ? "\(year)" : ""
    }

    /// A real platform album id. Kugou's `album|artist` key and
    /// QQ's `qq-album-…` key are not ids — the detail fetch would
    /// ask the wrong endpoint with them.
    static func hasRealId(_ album: AlbumSummary) -> Bool {
        guard !album.id.isEmpty else { return false }
        guard !album.id.contains("|") else { return false }
        guard !album.id.hasPrefix("qq-album-") else { return false }
        return true
    }

    func load() {
        isLoading = true
        if Self.hasRealId(album) {
            loadDetail(id: album.id)
            return
        }
        MusicAlbumAPI.shared.searchAlbums(platform: album.platform, keyword: album.name) { [weak self] hits in
            guard let self = self else { return }
            let target = MusicText.normalizeName(self.album.artist)
            let match = hits.first { hit in
                target.isEmpty || MusicText.normalizeName(hit.artist).contains(target)
            } ?? hits.first
            if let match = match, Self.hasRealId(match) {
                self.loadDetail(id: match.id)
            } else {
                self.isLoading = false
            }
        }
    }

    private func loadDetail(id: String) {
        MusicAlbumAPI.shared.albumSongs(
            id: id, platform: album.platform, name: album.name, artist: album.artist
        ) { [weak self] loaded in
            guard let self = self else { return }
            self.isLoading = false
            self.detail = loaded
        }
    }
}

struct MusicAlbumDetailView: View {
    var album: AlbumSummary

    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var viewModel: MusicAlbumDetailViewModel

    @Environment(\.haoTheme) private var theme

    init(album: AlbumSummary) {
        self.album = album
        _viewModel = StateObject(wrappedValue: MusicAlbumDetailViewModel(album: album))
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.songs.isEmpty {
                MusicEmptyState(
                    icon: "square.stack",
                    title: "专辑曲目加载失败",
                    note: "该专辑没有返回曲目，稍后再试。",
                    onRetry: { viewModel.load() }
                )
            } else {
                List {
                    Section {
                        albumHeader
                    }
                    .listRowBackground(theme.scaffoldBackground)
                    .listRowSeparator(.hidden)
                    Section {
                        ForEach(Array(viewModel.songs.enumerated()), id: \.element.id) { index, song in
                            MusicSongRow(
                                song: song,
                                isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
                                trackNumber: index + 1,
                                onTap: {
                                    playerVM.play(song: song, in: viewModel.songs, startAt: index)
                                }
                            )
                            .listRowBackground(theme.scaffoldBackground)
                            .listRowSeparatorTint(theme.hairline)
                        }
                    }
                }
                .haoBottomChromePadding()
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.load() }
    }

    /// Apple Music's big filled play capsule, under the header.
    /// The toolbar capsule is gone — one play control, in the
    /// header, where Apple Music puts it. Same playAll, no new
    /// function.
    private var playAllButton: some View {
        Button(action: { playerVM.playAll(viewModel.songs) }) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.haoCalloutStrong)
                Text("播放")
                    .font(.haoCalloutStrong)
            }
            .foregroundStyle(theme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(theme.accent, in: Capsule())
        }
        .buttonStyle(MusicPressScaleStyle())
        .disabled(viewModel.songs.isEmpty)
        .accessibilityLabel("播放全部")
    }

    private var albumHeader: some View {
        // Apple Music album page: big centred cover, title below
        // it, artist in the accent, year / count / platform in
        // muted grey — not a small cover on the left with text
        // squeezed beside it.
        VStack(spacing: 12) {
            MusicCoverView(urlString: viewModel.detail.pic, size: 200, cornerRadius: 16)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
            Text(viewModel.detail.name.isEmpty ? album.name : viewModel.detail.name)
                .font(.haoDetailTitle)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(viewModel.detail.artist.isEmpty ? album.artist : viewModel.detail.artist)
                .font(.haoCallout)
                .foregroundStyle(theme.accentText)
                .lineLimit(1)
            HStack(spacing: 8) {
                if !viewModel.yearText.isEmpty {
                    Text(viewModel.yearText)
                        .font(.haoFootnote)
                        .foregroundStyle(theme.textMuted)
                }
                if viewModel.detail.songs.count > 0 {
                    Text("共 \(viewModel.detail.songs.count) 首")
                        .font(.haoFootnote)
                        .foregroundStyle(theme.textMuted)
                }
                Text(album.platform.badgeName)
                    .font(.haoCaption2Strong)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(theme.hairline, lineWidth: 0.5)
                    }
            }
            playAllButton
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// HAo Studio 2.0 — artist detail page (S3-C leg).
//
// S2 built the API (MusicArtistAPI: wy / tx / kw search +
// detail) and left the page as a placeholder. This is the page:
// portrait + name + counts, hot songs, albums (tap an album to
// open its detail page).
//
// Id fallback: a summary without a usable id (QQ derived rows
// with an empty mid, or a name-only artist from the player)
// resolves by searching the artist name first and loading the
// first exact hit.

import SwiftUI

@MainActor
final class MusicArtistDetailViewModel: ObservableObject {
    @Published private(set) var detail = ArtistDetail(name: "")
    @Published private(set) var isLoading = true

    private let artist: ArtistSummary

    init(artist: ArtistSummary) {
        self.artist = artist
        self.detail = ArtistDetail(name: artist.name, pic: artist.cover)
    }

    var songs: [MusicSong] {
        detail.songs.map(MusicSong.init(from:))
    }

    func load() {
        isLoading = true
        if !artist.id.isEmpty {
            loadDetail(id: artist.id, name: artist.name)
            return
        }
        MusicArtistAPI.shared.searchArtists(platform: artist.platform, keyword: artist.name) { [weak self] hits in
            guard let self = self else { return }
            let target = MusicText.normalizeName(self.artist.name)
            let match = hits.first {
                MusicText.normalizeName($0.name) == target
            } ?? hits.first
            if let match = match, !match.id.isEmpty {
                self.loadDetail(id: match.id, name: match.name)
            } else if let match = match {
                self.loadDetail(id: "", name: match.name)
            } else {
                self.isLoading = false
            }
        }
    }

    private func loadDetail(id: String, name: String) {
        MusicArtistAPI.shared.artistDetail(platform: artist.platform, id: id, name: name) { [weak self] loaded in
            guard let self = self else { return }
            self.isLoading = false
            self.detail = loaded
        }
    }
}

struct MusicArtistDetailView: View {
    var artist: ArtistSummary

    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var viewModel: MusicArtistDetailViewModel

    @Environment(\.haoTheme) private var theme

    init(artist: ArtistSummary) {
        self.artist = artist
        _viewModel = StateObject(wrappedValue: MusicArtistDetailViewModel(artist: artist))
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.songs.isEmpty && viewModel.detail.albums.isEmpty {
                MusicEmptyState(
                    icon: "person",
                    title: "歌手内容加载失败",
                    note: "该歌手没有返回歌曲或专辑，稍后再试。"
                )
            } else {
                contentList
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MusicCapsuleButton(icon: "play.fill", label: "播放全部", enabled: !viewModel.songs.isEmpty) {
                    playerVM.playAll(viewModel.songs)
                }
            }
        }
        .onAppear { viewModel.load() }
    }

    private var contentList: some View {
        List {
            Section {
                artistHeader
            }
            .listRowBackground(theme.scaffoldBackground)
            .listRowSeparator(.hidden)
            if !viewModel.songs.isEmpty {
                Section("热门歌曲") {
                    ForEach(Array(viewModel.songs.prefix(30).enumerated()), id: \.element.id) { index, song in
                        MusicSongRow(
                            song: song,
                            isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
                            onTap: {
                                playerVM.play(song: song, in: viewModel.songs, startAt: index)
                            },
                            onToggleFav: {
                                _ = MusicLibraryStore.toggleFav(song)
                            },
                            onAddToPlaylist: nil
                        )
                        .listRowBackground(theme.scaffoldBackground)
                        .listRowSeparatorTint(theme.hairline)
                    }
                }
            }
            if !viewModel.detail.albums.isEmpty {
                Section("专辑") {
                    ForEach(viewModel.detail.albums) { album in
                        albumRow(album)
                    }
                }
            }
        }
        .haoBottomChromePadding()
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func albumRow(_ album: AlbumSummary) -> some View {
        NavigationLink(destination: MusicAlbumDetailView(album: album)) {
            HStack(spacing: 12) {
                MusicCoverView(urlString: album.cover, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(albumRowSubtitle(album))
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .listRowBackground(theme.scaffoldBackground)
        .listRowSeparatorTint(theme.hairline)
    }

    private var artistHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            MusicCoverView(urlString: viewModel.detail.pic, size: 96, cornerRadius: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.detail.name.isEmpty ? artist.name : viewModel.detail.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                if !artist.alias.isEmpty {
                    Text("又名 \(artist.alias)")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Text(countsText)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textMuted)
                Text(artist.platform.badgeName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(theme.hairline, lineWidth: 0.5)
                    }
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var countsText: String {
        let songs = viewModel.detail.musicSize
        let albums = viewModel.detail.albumSize
        switch (songs > 0, albums > 0) {
        case (true, true): return "歌曲 \(songs) 首 · 专辑 \(albums) 张"
        case (true, false): return "歌曲 \(songs) 首"
        case (false, true): return "专辑 \(albums) 张"
        case (false, false): return ""
        }
    }

    private func albumRowSubtitle(_ album: AlbumSummary) -> String {
        var parts: [String] = []
        if album.songCount > 0 { parts.append("\(album.songCount) 首") }
        if !album.artist.isEmpty { parts.append(album.artist) }
        return parts.joined(separator: " · ")
    }
}

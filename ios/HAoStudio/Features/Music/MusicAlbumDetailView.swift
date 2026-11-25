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
//
// b45-b (Coda §3.6): the page uses the shared detail Hero +
// PrimaryActions (cover on top, never a big play button in the
// middle), metadata "N 首歌曲 · 总时长 · 发布日期", and "该歌手
// 的其他专辑" (first 12, horizontal shelf).

import SwiftUI

@MainActor
final class MusicAlbumDetailViewModel: ObservableObject {
    @Published private(set) var detail = AlbumDetail(name: "")
    @Published private(set) var isLoading = true
    @Published private(set) var otherAlbums: [AlbumSummary] = []

    private let album: AlbumSummary
    private var otherAlbumsLoaded = false

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

    var publishDateText: String {
        guard album.publishTime > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(album.publishTime) / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    var totalDurationText: String {
        let total = detail.songs.compactMap { $0.duration }.reduce(0, +)
        guard total > 0 else { return "" }
        return musicDurationText(seconds: Int(total))
    }

    /// "N 首歌曲 · 总时长 · 发布日期" (Coda §3.6 album metadata).
    var metadataText: String {
        var parts: [String] = []
        if !detail.songs.isEmpty { parts.append("\(detail.songs.count) 首歌曲") }
        if !totalDurationText.isEmpty { parts.append(totalDurationText) }
        if !publishDateText.isEmpty { parts.append(publishDateText) }
        return parts.joined(separator: " · ")
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
            self.loadOtherAlbums()
        }
    }

    /// "该歌手的其他专辑" (Coda §3.6): the artist's albums via
    /// the artist API, current album excluded, first 12.
    func loadOtherAlbums() {
        guard !otherAlbumsLoaded else { return }
        otherAlbumsLoaded = true
        let artistName = detail.artist.isEmpty ? album.artist : detail.artist
        guard !artistName.isEmpty else { return }
        MusicArtistAPI.shared.searchArtists(platform: album.platform, keyword: artistName) { [weak self] hits in
            guard let self = self else { return }
            let target = MusicText.normalizeName(artistName)
            guard let match = hits.first(where: { MusicText.normalizeName($0.name) == target }) ?? hits.first else { return }
            MusicArtistAPI.shared.artistDetail(platform: self.album.platform, id: match.id, name: match.name) { [weak self] artistDetail in
                guard let self = self else { return }
                self.otherAlbums = Array(artistDetail.albums.filter {
                    $0.name != self.album.name
                }.prefix(12))
            }
        }
    }
}

struct MusicAlbumDetailView: View {
    var album: AlbumSummary

    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var viewModel: MusicAlbumDetailViewModel
    @State private var isFavAlbum = false

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
                        MusicDetailHero(
                            coverURL: viewModel.detail.pic,
                            title: viewModel.detail.name.isEmpty ? album.name : viewModel.detail.name,
                            subtitle: viewModel.detail.artist.isEmpty ? album.artist : viewModel.detail.artist,
                            metadata: viewModel.metadataText
                        )
                    }
                    .listRowBackground(theme.scaffoldBackground)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    Section {
                        HStack {
                            Spacer()
                            MusicDetailPrimaryActions(
                                isFavourite: isFavAlbum,
                                onToggleFavourite: {
                                    isFavAlbum = MusicLibraryStore.toggleFavAlbum(album)
                                },
                                onPlay: { playerVM.playAll(viewModel.songs, source: PlaySource(kind: .album, id: album.id), sourceDisplayName: album.name) },
                                playEnabled: !viewModel.songs.isEmpty
                            ) {
                                ShareLink(item: "《\(album.name)》 - \(album.artist)") {
                                    Label("分享", systemImage: "square.and.arrow.up")
                                }
                            }
                            Spacer()
                        }
                    }
                    .listRowBackground(theme.scaffoldBackground)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    Section {
                        ForEach(Array(viewModel.songs.enumerated()), id: \.element.id) { index, song in
                            MusicSongRow(
                                song: song,
                                isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
                                trackNumber: index + 1,
                                compact: true,
                                showFavHeart: true,
                                onTap: {
                                    playerVM.play(song: song, in: viewModel.songs, startAt: index, source: PlaySource(kind: .album, id: album.id), sourceDisplayName: album.name)
                                }
                            )
                            .listRowBackground(theme.scaffoldBackground)
                            .listRowSeparatorTint(theme.hairline)
                        }
                    }
                    if !viewModel.otherAlbums.isEmpty {
                        Section {
                            MusicCodaSectionHeader(title: "该歌手的其他专辑")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 16) {
                                    ForEach(viewModel.otherAlbums) { other in
                                        NavigationLink(destination: MusicAlbumDetailView(album: other)) {
                                            MusicCoverCardBody(
                                                coverURL: other.cover, title: other.name,
                                                subtitle: other.artist
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .listRowBackground(theme.scaffoldBackground)
                        .listRowSeparator(.hidden)
                    }
                }
                .haoBottomChromePadding()
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // b45-g (Coda §8.2): pull-to-refresh refetches the
                // album. No TTL — album detail has no cache today
                // and none is added; refresh is always a real fetch.
                .refreshable { viewModel.load() }
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.load()
            isFavAlbum = MusicLibraryStore.isFavAlbum(id: album.id, name: album.name)
        }
    }
}

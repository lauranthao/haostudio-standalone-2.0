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
//
// b45-b (Coda §3.6): shared detail Hero (circular cover,
// subtitle = aliases joined with " / " or "歌手") + Primary
// Actions; sections in order: hot songs (horizontal shelf,
// 7 rows per column) → albums → EP & singles → similar artists.
// Albums cap 60, albums and EP/singles split by track count
// (≥ 8 tracks = album). Similar artists have no API in this
// app, so that section is omitted rather than faked.

import SwiftUI

@MainActor
final class MusicArtistDetailViewModel: ObservableObject {
    @Published private(set) var detail = ArtistDetail(name: "")
    @Published private(set) var isLoading = true
    /// b49sweep P2-17: the name search returned hits but none
    /// matched confidently — an honest "找不到这位歌手" instead
    /// of opening a wrong singer. Reset on every load().
    @Published private(set) var notFound = false

    private let artist: ArtistSummary

    init(artist: ArtistSummary) {
        self.artist = artist
        self.detail = ArtistDetail(name: artist.name, pic: artist.cover)
    }

    var songs: [MusicSong] {
        detail.songs.map(MusicSong.init(from:))
    }

    /// Albums (≥ 8 tracks), capped at 60 total with EP/singles.
    var albums: [AlbumSummary] {
        Array(detail.albums.filter { $0.songCount >= 8 || $0.songCount == 0 }.prefix(60))
    }

    /// EP & singles (< 8 tracks), from the same capped pool.
    var epsAndSingles: [AlbumSummary] {
        let capped = Array(detail.albums.prefix(60))
        return capped.filter { $0.songCount > 0 && $0.songCount < 8 }
    }

    func load() {
        isLoading = true
        notFound = false
        if !artist.id.isEmpty {
            loadDetail(id: artist.id, name: artist.name)
            return
        }
        MusicArtistAPI.shared.searchArtists(platform: artist.platform, keyword: artist.name) { [weak self] hits in
            guard let self = self else { return }
            // b49sweep P2-17: exact normalized-name match only —
            // the old first-hit fallback could open a different
            // singer with a similar name. No confident match is
            // an honest "找不到这位歌手", not a guess.
            let target = MusicText.normalizeName(self.artist.name)
            let match = hits.first {
                MusicText.normalizeName($0.name) == target
            }
            if let match = match, !match.id.isEmpty {
                self.loadDetail(id: match.id, name: match.name)
            } else if let match = match {
                self.loadDetail(id: "", name: match.name)
            } else if hits.isEmpty {
                // No hits at all: indistinguishable from a network
                // failure — keep the existing "加载失败" state.
                self.isLoading = false
            } else {
                self.notFound = true
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
    @State private var isFavArtist = false
    // b49fix2 B15: the hot-songs shelf width, measured from the
    // shelf itself (see hotSongsShelf) — never UIScreen, so Split
    // View / Stage Manager get the real row width.
    @State private var shelfWidth: CGFloat = 0

    @Environment(\.haoTheme) private var theme

    init(artist: ArtistSummary) {
        self.artist = artist
        _viewModel = StateObject(wrappedValue: MusicArtistDetailViewModel(artist: artist))
    }

    /// Coda §3.6 artist subtitle: aliases joined with " / ",
    /// or "歌手" when there are none.
    private var subtitleText: String {
        let aliases = artist.alias
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if aliases.isEmpty { return "歌手" }
        return aliases.joined(separator: " / ")
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.notFound {
                // b49sweep P2-17: the search answered but nothing
                // matched confidently — say so, don't guess.
                MusicEmptyState(
                    icon: "magnifyingglass",
                    title: "找不到这位歌手",
                    note: "没有找到和这位歌手名称一致的结果。",
                    onRetry: { viewModel.load() }
                )
            } else if viewModel.songs.isEmpty && viewModel.detail.albums.isEmpty {
                MusicEmptyState(
                    icon: "person",
                    title: "歌手内容加载失败",
                    note: "该歌手没有返回歌曲或专辑，稍后再试。",
                    onRetry: { viewModel.load() }
                )
            } else {
                contentList
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.load()
            isFavArtist = MusicLibraryStore.isFavArtist(id: artist.id, name: artist.name)
        }
    }

    private var contentList: some View {
        List {
            Section {
                MusicDetailHero(
                    coverURL: viewModel.detail.pic,
                    isCircular: true,
                    title: viewModel.detail.name.isEmpty ? artist.name : viewModel.detail.name,
                    subtitle: subtitleText,
                    metadata: countsText
                )
            }
            .listRowBackground(theme.scaffoldBackground)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            Section {
                HStack {
                    Spacer()
                    MusicDetailPrimaryActions(
                        isFavourite: isFavArtist,
                        onToggleFavourite: {
                            isFavArtist = MusicLibraryStore.toggleFavArtist(artist)
                        },
                        onPlay: { playerVM.playAll(viewModel.songs, source: PlaySource(kind: .artist, id: artist.id), sourceDisplayName: artist.name) },
                        playEnabled: !viewModel.songs.isEmpty
                    ) {
                        ShareLink(item: artist.name) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                    }
                    Spacer()
                }
            }
            .listRowBackground(theme.scaffoldBackground)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            if !viewModel.songs.isEmpty {
                Section {
                    MusicCodaSectionHeader(title: "热门歌曲")
                    hotSongsShelf
                }
                .listRowBackground(theme.scaffoldBackground)
                .listRowSeparator(.hidden)
            }
            if !viewModel.albums.isEmpty {
                Section {
                    MusicCodaSectionHeader(title: "专辑")
                    albumShelf(viewModel.albums)
                }
                .listRowBackground(theme.scaffoldBackground)
                .listRowSeparator(.hidden)
            }
            if !viewModel.epsAndSingles.isEmpty {
                Section {
                    MusicCodaSectionHeader(title: "EP & 单曲")
                    albumShelf(viewModel.epsAndSingles)
                }
                .listRowBackground(theme.scaffoldBackground)
                .listRowSeparator(.hidden)
            }
        }
        .haoBottomChromePadding()
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // b45-g (Coda §8.2): pull-to-refresh refetches the artist.
        // No TTL — artist detail has no cache today and none is
        // added; refresh is always a real fetch.
        .refreshable { viewModel.load() }
    }

    /// Hot songs as a horizontal shelf: 7 compact rows per
    /// column (Coda §3.6). Column width from the shelf's measured
    /// width (row width − 20 peek), never UIScreen and never
    /// hardcoded.
    private var hotSongsShelf: some View {
        let columnWidth = max(shelfWidth - 20, 160)
        let indexed = Array(viewModel.songs.enumerated())
        let columns = indexed.chunked(into: 7)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    VStack(spacing: 1) {
                        ForEach(column, id: \.element.id) { item in
                            MusicSongRow(
                                song: item.element,
                                isPlaying: playerVM.currentSong?.identityKey == item.element.identityKey && playerVM.isPlaying,
                                trackNumber: item.offset + 1,
                                compact: true,
                                onTap: {
                                    playerVM.play(song: item.element, in: viewModel.songs, startAt: item.offset, source: PlaySource(kind: .artist, id: artist.id), sourceDisplayName: artist.name)
                                }
                            )
                            .frame(width: columnWidth, alignment: .leading)
                        }
                    }
                    .frame(width: columnWidth, alignment: .leading)
                }
            }
        }
        // b49fix2 B15: measure the shelf's own width (the List row
        // width) — onAppear fires during the first layout pass, so
        // the first painted frame already has the real width; the
        // 160 floor only covers the pre-measurement frame.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { shelfWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, newValue in shelfWidth = newValue }
            }
        )
    }

    private func albumShelf(_ albums: [AlbumSummary]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(albums) { album in
                    NavigationLink(destination: MusicAlbumDetailView(album: album)) {
                        MusicCoverCardBody(
                            coverURL: album.cover, title: album.name,
                            subtitle: albumRowSubtitle(album)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var countsText: String {
        let songs = viewModel.detail.musicSize
        let albums = viewModel.detail.albumSize
        switch (songs > 0, albums > 0) {
        case (true, true): return "\(songs) 首歌曲 · \(albums) 张专辑"
        case (true, false): return "\(songs) 首歌曲"
        case (false, true): return "\(albums) 张专辑"
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

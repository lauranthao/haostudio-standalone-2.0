// HAo Studio 2.0 — music home view model (S2-C leg).
//
// The music tab root (Flutter MusicTabPage): feature shelf, 我的歌单,
// 最近播放. All data is local (playlists / favourites / recent /
// downloads / local files); the shelf tiles navigate to the search,
// daily, plaza, charts and report pages.

import Combine
import SwiftUI

@MainActor
final class MusicHomeViewModel: ObservableObject {
    @Published private(set) var playlists: [UserPlaylist] = []
    @Published private(set) var recent: [MusicSong] = []
    @Published private(set) var favCount = 0
    @Published private(set) var downloadCount = 0
    @Published private(set) var localCount = 0
    @Published var playlistsExpanded = true
    @Published var recentExpanded = true

    private var cancellables = Set<AnyCancellable>()

    init() {
        playlistsExpanded = MusicLibraryStore.playlistsExpanded()
        recentExpanded = MusicLibraryStore.recentExpanded()
        // 最近播放实时更新 (chen 2026-11-20): a song can start
        // from any page while the user stays on this tab, so the
        // list reloads the moment the store changes — not only
        // when the tab re-appears (onAppear reload stays as well).
        NotificationCenter.default.publisher(for: .haoMusicRecentChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    func reload() {
        playlists = MusicLibraryStore.getLists()
        recent = MusicLibraryStore.getRecent()
        favCount = MusicLibraryStore.favIds().count
        downloadCount = MusicLibraryStore.getDownloads().count
        localCount = MusicLibraryStore.localMusicFiles().count
    }

    func setPlaylistsExpanded(_ value: Bool) {
        playlistsExpanded = value
        MusicLibraryStore.setPlaylistsExpanded(value)
    }

    func setRecentExpanded(_ value: Bool) {
        recentExpanded = value
        MusicLibraryStore.setRecentExpanded(value)
    }
}

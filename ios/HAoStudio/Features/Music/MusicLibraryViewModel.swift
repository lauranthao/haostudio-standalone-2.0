// HAo Studio 2.0 — music library view model (S2-C leg).
//
// Favourites / playlists / downloads / local music. All actions are
// local file + JSON operations; playback goes through the shared
// MusicPlayerViewModel (setQueue + requestPlay), never a second
// player. Deleting a download removes the index entry AND the file;
// deleting a local file removes the file AND the index entry.

import SwiftUI

@MainActor
final class MusicLibraryViewModel: ObservableObject {
    @Published private(set) var favSongs: [MusicSong] = []
    @Published private(set) var playlists: [UserPlaylist] = []
    @Published private(set) var downloads: [DownloadedSong] = []
    @Published private(set) var localSongs: [MusicSong] = []
    @Published private(set) var recent: [MusicSong] = []

    func reload() {
        favSongs = MusicLibraryStore.favSongs()
        playlists = MusicLibraryStore.getLists()
        downloads = MusicLibraryStore.getDownloads()
        localSongs = MusicLibraryStore.localSongs()
        recent = MusicLibraryStore.getRecent()
    }

    // MARK: - Favourites

    func isFav(_ song: MusicSong) -> Bool {
        return MusicLibraryStore.isFav(song)
    }

    @discardableResult
    func toggleFav(_ song: MusicSong) -> Bool {
        let added = MusicLibraryStore.toggleFav(song)
        favSongs = MusicLibraryStore.favSongs()
        return added
    }

    // MARK: - Playlists

    func createPlaylist(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = MusicLibraryStore.createList(named: trimmed)
        playlists = MusicLibraryStore.getLists()
    }

    func deletePlaylist(id: String) {
        MusicLibraryStore.deleteList(id: id)
        playlists = MusicLibraryStore.getLists()
    }

    func renamePlaylist(id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var lists = MusicLibraryStore.getLists()
        if let index = lists.firstIndex(where: { $0.id == id }) {
            lists[index].name = trimmed
            MusicLibraryStore.saveLists(lists)
            playlists = lists
        }
    }

    /// Add songs to a playlist (dedupe + 1000 cap, Flutter addTracks).
    /// Returns (added, dropped, dupes) so the UI can report honestly.
    func addToPlaylist(_ songs: [MusicSong], listId: String) -> (added: Int, dropped: Int, dupes: Int) {
        var lists = MusicLibraryStore.getLists()
        guard let index = lists.firstIndex(where: { $0.id == listId }) else {
            return (0, 0, 0)
        }
        let result = lists[index].addTracks(songs)
        MusicLibraryStore.saveLists(lists)
        playlists = lists
        return result
    }

    func removeFromPlaylist(song: MusicSong, listId: String) {
        var lists = MusicLibraryStore.getLists()
        guard let index = lists.firstIndex(where: { $0.id == listId }) else { return }
        lists[index].tracks.removeAll(where: { $0.identityKey == song.identityKey })
        MusicLibraryStore.saveLists(lists)
        playlists = lists
    }

    func playlist(id: String) -> UserPlaylist? {
        return playlists.first(where: { $0.id == id })
    }

    // MARK: - Downloads

    /// Resolve a downloaded song's file. Returns nil when the file
    /// is gone in every place we know (old absolute path, current
    /// relative path, rescan) — the row then shows "文件已丢失" and
    /// offers removal, never a fake play.
    func downloadedFileURL(for download: DownloadedSong) -> URL? {
        return LocalFileIndex.resolve(download.filePath, subdir: "music_downloads")
    }

    func deleteDownload(_ download: DownloadedSong) {
        if let url = downloadedFileURL(for: download) {
            try? FileManager.default.removeItem(at: url)
        }
        MusicLibraryStore.removeDownload(key: download.key)
        downloads = MusicLibraryStore.getDownloads()
        // B7: the player still holds the deleted file — stop it
        // when it is the track playing now, instead of letting the
        // next advance re-resolve the same dead address.
        stopIfPlaying(key: download.key)
    }

    // MARK: - Local music

    func deleteLocalSong(_ song: MusicSong) {
        // b49fix2 #21: resolve FIRST — the stored path may be an
        // old absolute path (container moved) or a relative one;
        // removing the raw string deletes nothing (or the wrong
        // file) in those cases.
        if !song.localPath.isEmpty,
           let url = LocalFileIndex.resolve(song.localPath, subdir: "local_music") {
            try? FileManager.default.removeItem(at: url)
        }
        // b49fix2 P2-9: the read no longer prunes, so the delete
        // path prunes explicitly — otherwise the deleted entry
        // would stay listed forever.
        localSongs = MusicLibraryStore.pruneLocalSongs()
        // B7: same as deleteDownload — never keep playing a file
        // that no longer exists.
        stopIfPlaying(key: song.identityKey)
    }

    /// Stop playback when the deleted file is the track playing
    /// now. The coordinator's current item clears through the
    /// player's failure path when a later retry finds no URL; the
    /// engine itself must not keep sounding from a deleted file.
    private func stopIfPlaying(key: String) {
        let player = NativeMusicPlayer.shared
        guard player.currentTrack?.id == key else { return }
        player.stop()
    }

    // MARK: - Recent

    func clearRecent() {
        MusicLibraryStore.clearRecent()
        recent = []
    }
}

// HAo Studio 2.0 — queue-edit / play-context sync tests (b49fix44 S33-P1-1).
//
// A queue edit (remove / move / insert / clear) must keep the play
// context in step, or the next rebuild from context undoes the edit:
// the removed song comes back, the insert is dropped, the reorder
// is reverted. The rebuild filters the reloaded songs by the
// context's keys, so a live-store source (playlist) cannot resurrect
// a removed song either — the live list still holds it.
//
// NOTE: like the rest of Tests/MusicFeaturesTests, this target is
// unwired until the S7 Xcode test target exists (see Package.swift
// header) — `swift test` does not run it yet. It runs with
// `xcodebuild test` against an iOS Simulator destination.
//
// @MainActor: the view model + coordinator are @MainActor, so the
// whole class is isolated (the per-method pattern in
// MiniPlayerB35Tests would need the same annotation on every test
// here). Cleanup uses addTeardownBlock, not an overridden
// tearDown, so no isolation question arises there.

import XCTest

@testable import HAoStudio

/// Stand-in music driver, same shape as MiniPlayerB35Tests'
/// StubMusicDriver (private to that file, so this file has its own).
private final class QueueContextStubDriver: MusicPlaybackDriver {
    var currentTrack: PlaybackItem?
    var isPlaying = false
    var pauseCalled = false
    var resolveURL: ((PlaybackItem, [URL], @escaping (URL?, AudioQuality?) -> Void) -> Void)?
    var onTrackStarted: ((PlaybackItem) -> Void)?
    var onTrackFailed: ((PlaybackItem, MusicPlayerError) -> Void)?
    func play(item: PlaybackItem) {}
    func open(item: PlaybackItem, url: URL, completion: @escaping (Result<Void, MusicPlayerError>) -> Void) {}
    func pause() { pauseCalled = true }
    func stop() {}
    func resume() {}
    func clearNowPlaying() {}
}

@MainActor
final class MusicPlayerQueueContextTests: XCTestCase {
    /// Snapshot-backed source: the rebuild reads the snapshot the
    /// edit syncs.
    private static let searchSource = PlaySource(kind: .search, id: "queue-context-test")
    /// Live-store source: the rebuild reads the live playlist, which
    /// still holds a removed song — the key filter must drop it.
    private static let playlistSource = PlaySource(kind: .playlist, id: "queue-context-test-list")
    private static let playlistID = "queue-context-test-list"

    private func song(_ id: String, title: String) -> MusicSong {
        MusicSong(songId: id, title: title, artist: "Artist", platform: .wy, dur: 200)
    }

    private func makeViewModel() -> MusicPlayerViewModel {
        let coordinator = PlaybackCoordinator(
            defaults: UserDefaults(suiteName: "MusicPlayerQueueContextTests") ?? .standard)
        let driver = QueueContextStubDriver()
        coordinator.musicDriver = driver
        let viewModel = MusicPlayerViewModel(coordinator: coordinator)
        // Normalise: a host with a saved queue would restore songs
        // into the queue before the test starts.
        viewModel.clearQueue()
        // The tests write the shared store (queue, recent, persisted
        // context, snapshots, the test playlist) — clear it all so
        // no test leaks into the next.
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: "hao.currentPlayContext")
            MusicLibraryStore.clearRecent()
            PlaylistSnapshotStore.delete(source: Self.searchSource)
            PlaylistSnapshotStore.delete(source: Self.playlistSource)
            MusicLibraryStore.saveLists(
                MusicLibraryStore.getLists().filter { $0.id != Self.playlistID })
        }
        return viewModel
    }

    /// The persisted context's keys (`hao.currentPlayContext` in
    /// UserDefaults) — nil when nothing is persisted.
    private func persistedContextKeys() -> [String]? {
        guard let data = UserDefaults.standard.data(forKey: "hao.currentPlayContext"),
              let context = try? JSONDecoder().decode(PlayContext.self, from: data) else {
            return nil
        }
        return context.songKeys
    }

    private func queueKeys(_ viewModel: MusicPlayerViewModel) -> [String] {
        viewModel.queue.tracks.map { $0.identityKey }
    }

    /// Remove-then-next does not resurrect the removed song: the
    /// edit syncs the context keys + snapshot, so the rebuild the
    /// short queue triggers reloads the edited list, not the old one.
    func testRemoveThenNextDoesNotResurrect() {
        let viewModel = makeViewModel()
        let a = song("1", title: "A"), b = song("2", title: "B"), c = song("3", title: "C")
        for s in [a, b, c] { MusicLibraryStore.putLyrics([], for: s.identityKey) }
        viewModel.play(song: a, in: [a, b, c], source: Self.searchSource)
        XCTAssertEqual(queueKeys(viewModel), ["wy|1", "wy|2", "wy|3"])
        XCTAssertEqual(viewModel.currentPlayContext?.songKeys, ["wy|1", "wy|2", "wy|3"])

        viewModel.removeFromQueue(at: 1)
        XCTAssertEqual(queueKeys(viewModel), ["wy|1", "wy|3"])
        XCTAssertEqual(viewModel.currentPlayContext?.songKeys, ["wy|1", "wy|3"])
        // The persisted context stays in step too, or the bug
        // returns after relaunch.
        XCTAssertEqual(persistedContextKeys(), ["wy|1", "wy|3"])

        viewModel.next()
        XCTAssertEqual(queueKeys(viewModel), ["wy|1", "wy|3"])
        XCTAssertEqual(viewModel.currentSong?.identityKey, "wy|3")
    }

    /// Move-then-next follows the new order: the reorder syncs the
    /// keys, so the rebuild the end-of-list restart triggers keeps
    /// the moved order instead of reverting to the playlist order.
    func testMoveThenNextFollowsNewOrder() {
        let viewModel = makeViewModel()
        let a = song("1", title: "A"), b = song("2", title: "B"), c = song("3", title: "C")
        for s in [a, b, c] { MusicLibraryStore.putLyrics([], for: s.identityKey) }
        viewModel.play(song: a, in: [a, b, c], source: Self.searchSource)
        XCTAssertEqual(viewModel.currentSong?.identityKey, "wy|1")

        viewModel.moveQueue(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(queueKeys(viewModel), ["wy|2", "wy|3", "wy|1"])
        XCTAssertEqual(viewModel.currentPlayContext?.songKeys, ["wy|2", "wy|3", "wy|1"])
        XCTAssertEqual(viewModel.currentSong?.identityKey, "wy|1")

        // A is last: next() answers restart, retrying the rebuild
        // first — the rebuild must keep the moved order.
        viewModel.next()
        XCTAssertEqual(queueKeys(viewModel), ["wy|2", "wy|3", "wy|1"])
        XCTAssertEqual(viewModel.currentSong?.identityKey, "wy|1")
    }

    /// Insert-then-next plays the inserted song, and the insert
    /// survives the rebuild the end-of-list restart triggers.
    func testInsertThenNextPlaysInsertedSong() {
        let viewModel = makeViewModel()
        let a = song("1", title: "A"), b = song("2", title: "B"), c = song("3", title: "C")
        let d = song("4", title: "D")
        for s in [a, b, c, d] { MusicLibraryStore.putLyrics([], for: s.identityKey) }
        viewModel.play(song: a, in: [a, b, c], source: Self.searchSource)

        viewModel.playNext(song: d)
        XCTAssertEqual(queueKeys(viewModel), ["wy|1", "wy|4", "wy|2", "wy|3"])
        XCTAssertEqual(viewModel.currentPlayContext?.songKeys, ["wy|1", "wy|4", "wy|2", "wy|3"])

        viewModel.next()
        XCTAssertEqual(viewModel.currentSong?.identityKey, "wy|4")
        viewModel.next()
        XCTAssertEqual(viewModel.currentSong?.identityKey, "wy|2")
        viewModel.next()
        XCTAssertEqual(viewModel.currentSong?.identityKey, "wy|3")
        // C is last: next() answers restart, retrying the rebuild
        // first — the insert must still be in the queue.
        viewModel.next()
        XCTAssertEqual(queueKeys(viewModel), ["wy|1", "wy|4", "wy|2", "wy|3"])
        XCTAssertEqual(viewModel.currentSong?.identityKey, "wy|3")
    }

    /// Clear-then-next does not restore: the clear syncs the
    /// context to empty keys, so the rebuild finds nothing and the
    /// queue stays empty (the "歌单数据找不到了" toast on next() is
    /// the pre-existing one for a fresh launch with no context).
    func testClearThenNextDoesNotRestore() {
        let viewModel = makeViewModel()
        let a = song("1", title: "A"), b = song("2", title: "B"), c = song("3", title: "C")
        for s in [a, b, c] { MusicLibraryStore.putLyrics([], for: s.identityKey) }
        viewModel.play(song: a, in: [a, b, c], source: Self.searchSource)

        viewModel.clearQueue()
        XCTAssertTrue(viewModel.queue.tracks.isEmpty)
        XCTAssertEqual(viewModel.currentPlayContext?.songKeys, [])
        XCTAssertEqual(persistedContextKeys(), [])

        viewModel.next()
        XCTAssertTrue(viewModel.queue.tracks.isEmpty)
        XCTAssertNil(viewModel.currentSong)
    }

    /// A playlist source reloads the LIVE list — which still holds
    /// the removed song — so the rebuild must filter by the
    /// context's keys, not take the list wholesale.
    func testPlaylistRemoveThenRebuildFiltersByKeys() {
        let viewModel = makeViewModel()
        let a = song("1", title: "A"), b = song("2", title: "B"), c = song("3", title: "C")
        for s in [a, b, c] { MusicLibraryStore.putLyrics([], for: s.identityKey) }
        // The live list keeps all three songs even after the queue edit.
        MusicLibraryStore.saveLists([
            UserPlaylist(id: Self.playlistID, name: "Test", tracks: [a, b, c])
        ])
        viewModel.play(song: a, in: [a, b, c], source: Self.playlistSource)
        XCTAssertEqual(viewModel.currentPlayContext?.songKeys, ["wy|1", "wy|2", "wy|3"])

        viewModel.removeFromQueue(at: 1)
        XCTAssertEqual(queueKeys(viewModel), ["wy|1", "wy|3"])
        XCTAssertEqual(viewModel.currentPlayContext?.songKeys, ["wy|1", "wy|3"])

        viewModel.next()
        XCTAssertEqual(viewModel.currentSong?.identityKey, "wy|3")
        // C is last: next() answers restart, retrying the rebuild
        // first — the live list still holds B, the keys must drop it.
        viewModel.next()
        XCTAssertEqual(queueKeys(viewModel), ["wy|1", "wy|3"])
        XCTAssertEqual(viewModel.currentSong?.identityKey, "wy|3")
    }
}

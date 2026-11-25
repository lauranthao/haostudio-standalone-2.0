// HAo Studio 2.0 — streaming search merge (S2-C leg).
//
// Pure merge for streamed search results, ported from Flutter
// `SongSearchService.searchAllStream` + `MusicApi` merge rules:
// - legs settle independently; each batch is appended as it arrives
//   (first result ~1s, no waiting for the slowest leg);
// - dedupe key is platform + songId (empty id falls back to
//   title+artist, same rule as MusicSong.dedupeKey);
// - NetEase (wy) + QQ (tx) rank first, then Kugou, then Kuwo
//   (chen 2026-11-17); within a platform, arrival order is kept
//   (stable — a later leg never reorders an earlier leg's rows);
// - there is NO platform selector: every search queries all platforms
//   by default.
//
// "Infinite scroll" here is the stream itself: rows are revealed as
// legs settle, and the list keeps growing while legs are still in
// flight. There is no page API in the LX contract, so no page
// requests are invented.

import Foundation

/// Merged search state. Batches arrive via the LX leg's completion
/// handler (called once per settled leg); each call appends.
struct MusicSearchMerge {
    private(set) var tracks: [MusicSong] = []
    private var seenKeys = Set<String>()

    /// Append one leg's batch. Returns the newly added tracks (in
    /// batch order) so the view can animate only the new rows.
    /// Duplicates (same dedupeKey) are dropped, keeping the first
    /// arrival.
    @discardableResult
    mutating func appendBatch(_ batch: [MusicSong]) -> [MusicSong] {
        var added: [MusicSong] = []
        for song in batch {
            let key = song.dedupeKey
            if seenKeys.contains(key) { continue }
            seenKeys.insert(key)
            tracks.append(song)
            added.append(song)
        }
        sortForDisplay()
        return added
    }

    /// Platform-priority order (wy + tx first), stable within a
    /// platform: the sort is stable, so equal-priority rows keep
    /// their arrival order.
    mutating func sortForDisplay() {
        tracks = tracks.enumerated().sorted { left, right in
            let lp = left.element.platform.searchPriority
            let rp = right.element.platform.searchPriority
            if lp != rp { return lp < rp }
            return left.offset < right.offset
        }.map { $0.element }
    }

    mutating func reset() {
        tracks.removeAll()
        seenKeys.removeAll()
    }

    var isEmpty: Bool { tracks.isEmpty }
    var count: Int { tracks.count }
}

/// Normalised title+artist key for cross-source dedupe of id-less
/// songs (Flutter search dedupe also folds "(Live)" variants into
/// one result via a second key; this is the same rule, kept in one
/// place so search and the song model agree).
func musicSearchDedupeKey(title: String, artist: String) -> String {
    let normTitle = title
        .lowercased()
        .replacingOccurrences(of: "(live)", with: "")
        .replacingOccurrences(of: "（live）", with: "")
        .replacingOccurrences(of: "live版", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let normArtist = artist
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(normTitle)|\(normArtist)"
}

// MARK: - Category merge (b45-d)

/// Per-kind merge for the non-song search categories (artists /
/// albums / playlists). Same rules as the song merge: platform+id
/// dedupe (caller supplies the fallback key for id-less items),
/// NetEase + QQ first, stable order within a platform — a later
/// page never reorders an earlier page's rows. The API layer
/// already merges across platforms within one page; this struct
/// owns the cross-page append (load-more) on the view-model side.
struct MusicSearchCategoryMerge<Item> {
    private(set) var items: [Item] = []
    private var seenKeys = Set<String>()
    private let key: (Item) -> String
    private let priority: (Item) -> Int

    init(key: @escaping (Item) -> String, priority: @escaping (Item) -> Int) {
        self.key = key
        self.priority = priority
    }

    /// Append one page. Returns the newly added items (in page
    /// order) so the caller can tell an empty page from a page of
    /// pure duplicates.
    @discardableResult
    mutating func append(_ batch: [Item]) -> [Item] {
        var added: [Item] = []
        for item in batch {
            let itemKey = key(item)
            guard !itemKey.isEmpty, !seenKeys.contains(itemKey) else { continue }
            seenKeys.insert(itemKey)
            items.append(item)
            added.append(item)
        }
        sortForDisplay()
        return added
    }

    /// Platform-priority order, stable within a platform: the sort
    /// is stable, so equal-priority rows keep their arrival order.
    mutating func sortForDisplay() {
        items = items.enumerated().sorted { left, right in
            let lp = priority(left.element)
            let rp = priority(right.element)
            if lp != rp { return lp < rp }
            return left.offset < right.offset
        }.map { $0.element }
    }

    mutating func reset() {
        items.removeAll()
        seenKeys.removeAll()
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
}

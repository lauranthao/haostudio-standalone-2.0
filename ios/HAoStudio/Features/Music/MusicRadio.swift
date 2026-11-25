// HAo Studio 2.0 — local radio + daily picks (S2-C leg).
//
// Pure queue builders over LOCAL data only — no login, no account,
// no network:
// - 私人漫游 (personal FM): a seeded shuffle of the local pool
//   (favourites + recent + most-played), minus disliked ids.
// - 心动模式 (heartbeat): the liked songs, seeded-shuffled.
// - 每日推荐 (daily picks): ~20 songs, ranked from the user's
//   own data (listen log + favourites + recent + playlist
//   tracks) — most-played and liked first, then more from the
//   same artists/albums. Deterministic from the data: no
//   Random, no shuffle, no seed. The per-day cache
//   (hao_daily) keeps one day stable; the list changes when
//   the user's data changes, not when the day rolls over.
//   Empty data -> [] (callers show the honest empty state).
// - 私人漫游 / 心动模式 keep their seeded shuffle (FM /
//   heartbeat are meant to shuffle); daily picks must not.
//
// All three are pure functions: the view models supply the inputs
// and play the returned queue. Nothing here invents a song.

import Foundation

enum MusicRadio {
    /// Private FM queue: local pool minus disliked, seeded shuffle.
    /// Seed is the day string so today's FM is stable within the day.
    static func fmQueue(
        favourites: [MusicSong],
        recent: [MusicSong],
        listenTop: [MusicSong],
        dislikedIds: Set<String>,
        seed: String,
        limit: Int = 50
    ) -> [MusicSong] {
        var seen = Set<String>()
        var pool: [MusicSong] = []
        for song in favourites + recent + listenTop {
            let key = song.identityKey
            // B4: dislikes are keyed by identityKey (platform|id),
            // not the bare song id — the same id on two platforms
            // used to dislike both. Bare ids stored before this
            // change still match via the songId check below.
            if dislikedIds.contains(song.songId) || dislikedIds.contains(key) { continue }
            if seen.insert(key).inserted { pool.append(song) }
        }
        var rng = MusicSeededRandom(seed: seed)
        return Array(rng.shuffle(pool).prefix(limit))
    }

    /// Heartbeat queue: the liked songs, seeded-shuffled.
    static func heartbeatQueue(
        favourites: [MusicSong],
        seed: String,
        limit: Int = 50
    ) -> [MusicSong] {
        var rng = MusicSeededRandom(seed: seed)
        return Array(rng.shuffle(favourites).prefix(limit))
    }

    /// Daily picks: ~20 songs, ranked from the user's own data —
    /// never shuffled, never seeded-random.
    ///
    /// Every candidate is a real song from local data only
    /// (listen log + favourites + recent + playlist tracks), so
    /// every pick is playable through the normal music path.
    /// Ranking score per song (all integer, deterministic):
    ///   plays x 10  (a listen event needs >= 5 s heard, so a
    ///                play is a real listen, not a tap-through)
    ///   + 30 when liked (favourite)
    ///   + recent bonus 15..1 for the 15 newest recent plays
    ///   + freshness 10 (last played within 7 days of `dayKey`)
    ///     or 5 (within 30 days)
    ///   + heard bonus min(total heard seconds / 60, 10)
    /// Ties break by plays, then last-played time, then
    /// identityKey — a total order, so the same data always
    /// yields the same list.
    ///
    /// Composition (total = 20 by default):
    ///   - first half: the top-ranked songs overall;
    ///   - second half: more from the same artists/albums —
    ///     first songs by the 5 most-listened artists not
    ///     already picked, then songs sharing an album with a
    ///     first-half song (album only exists on favourites /
    ///     recent / playlist copies — the listen log carries no
    ///     album), then the next-ranked songs, so a thin library
    ///     still fills the list from ranked songs instead of
    ///     random ones. The second half also caps each artist
    ///     at 4 picks while other artists' ranked songs are
    ///     still available, so one artist cannot take the whole
    ///     list; a fill pass ignores the cap, so a one-artist
    ///     library still fills the list.
    /// Disliked songs (FM dislikes, identityKey or bare songId)
    /// are excluded from both halves — a song the user
    /// explicitly disliked must never be recommended.
    /// Empty pool -> []: callers show the honest empty state.
    static func dailyPicks(
        listenLog: [ListenEvent],
        favourites: [MusicSong],
        recent: [MusicSong],
        playlistTracks: [MusicSong] = [],
        dislikedIds: Set<String> = [],
        dayKey: String,
        total: Int = 20
    ) -> [MusicSong] {
        // 1. Aggregate the listen log per song.
        struct LogStats {
            var song: MusicSong
            var plays: Int
            var lastAt: Int
            var heardSeconds: Int
        }
        var stats: [String: LogStats] = [:]
        var logOrder: [String] = []
        for event in listenLog {
            let song = MusicSong(
                songId: event.songId, title: event.title, artist: event.artist,
                cover: event.cover, platform: event.platform, dur: event.totalDur)
            let key = song.identityKey
            if var existing = stats[key] {
                existing.plays += 1
                existing.lastAt = max(existing.lastAt, event.at)
                existing.heardSeconds += event.dur
                if existing.song.cover.isEmpty, !song.cover.isEmpty {
                    existing.song.cover = song.cover
                }
                stats[key] = existing
            } else {
                stats[key] = LogStats(
                    song: song, plays: 1, lastAt: event.at, heardSeconds: event.dur)
                logOrder.append(key)
            }
        }
        // 2. Candidate pool: union of log + favourites + recent +
        //    playlist tracks. Favourites first so their fuller
        //    metadata (album, cover) wins the merge.
        var pool: [String: MusicSong] = [:]
        var poolOrder: [String] = []
        func addToPool(_ song: MusicSong) {
            let key = song.identityKey
            if var kept = pool[key] {
                if kept.cover.isEmpty, !song.cover.isEmpty { kept.cover = song.cover }
                if kept.album.isEmpty, !song.album.isEmpty { kept.album = song.album }
                pool[key] = kept
            } else {
                pool[key] = song
                poolOrder.append(key)
            }
        }
        for song in favourites { addToPool(song) }
        for song in recent { addToPool(song) }
        for song in playlistTracks { addToPool(song) }
        for key in logOrder { addToPool(stats[key]!.song) }
        // 3. Score every candidate.
        let favKeys = Set(favourites.map { $0.identityKey })
        var recentIndex: [String: Int] = [:]
        for (index, song) in recent.enumerated() {
            if recentIndex[song.identityKey] == nil {
                recentIndex[song.identityKey] = index
            }
        }
        let referenceMs = Self.dayReferenceMs(for: dayKey)
        struct Scored {
            var song: MusicSong
            var score: Int
            var plays: Int
            var lastAt: Int
        }
        var scored: [Scored] = []
        for key in poolOrder {
            guard let song = pool[key] else { continue }
            if dislikedIds.contains(song.songId) || dislikedIds.contains(key) { continue }
            if song.songId.isEmpty && song.title.isEmpty { continue }
            let stat = stats[key]
            let plays = stat?.plays ?? 0
            let lastAt = stat?.lastAt ?? 0
            var score = plays * 10
            if favKeys.contains(key) { score += 30 }
            if let index = recentIndex[key] { score += max(0, 15 - index) }
            if let ref = referenceMs {
                if lastAt >= ref - 7 * 24 * 3600 * 1000 { score += 10 }
                else if lastAt >= ref - 30 * 24 * 3600 * 1000 { score += 5 }
            }
            score += min((stat?.heardSeconds ?? 0) / 60, 10)
            scored.append(Scored(song: song, score: score, plays: plays, lastAt: lastAt))
        }
        guard !scored.isEmpty else { return [] }
        // Total order: score, plays, last-played, identityKey.
        let ranked = scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.plays != $1.plays { return $0.plays > $1.plays }
            if $0.lastAt != $1.lastAt { return $0.lastAt > $1.lastAt }
            return $0.song.identityKey < $1.song.identityKey
        }
        // 4. First half: the top-ranked songs overall.
        let half = total / 2
        var picked: [MusicSong] = []
        var seen = Set<String>()
        for entry in ranked.prefix(half) {
            if seen.insert(entry.song.identityKey).inserted { picked.append(entry.song) }
        }
        // 5. Second half: same artists, then same albums, then
        //    the next-ranked songs — with a per-artist cap so one
        //    artist cannot take the whole list while other
        //    artists' ranked songs are still available (max 4
        //    per artist); a fill pass ignores the cap so a
        //    one-artist library still fills the list.
        let artistSet = Set(topArtists(from: listenLog, limit: 5))
        let firstHalfAlbums = Set(picked.map { $0.album }.filter { !$0.isEmpty })
        var artistPool: [Scored] = []
        var albumPool: [Scored] = []
        var restPool: [Scored] = []
        for entry in ranked {
            if seen.contains(entry.song.identityKey) { continue }
            if artistSet.contains(entry.song.artist) { artistPool.append(entry) }
            else if !entry.song.album.isEmpty && firstHalfAlbums.contains(entry.song.album) {
                albumPool.append(entry)
            } else {
                restPool.append(entry)
            }
        }
        let maxPerArtist = 4
        var artistCounts: [String: Int] = [:]
        for song in picked where !song.artist.isEmpty {
            artistCounts[song.artist, default: 0] += 1
        }
        func underCap(_ song: MusicSong) -> Bool {
            guard !song.artist.isEmpty else { return true }
            return (artistCounts[song.artist] ?? 0) < maxPerArtist
        }
        for entry in artistPool + albumPool + restPool {
            if picked.count >= total { break }
            guard underCap(entry.song) else { continue }
            if seen.insert(entry.song.identityKey).inserted {
                picked.append(entry.song)
                if !entry.song.artist.isEmpty {
                    artistCounts[entry.song.artist, default: 0] += 1
                }
            }
        }
        if picked.count < total {
            for entry in artistPool + albumPool + restPool {
                if picked.count >= total { break }
                if seen.insert(entry.song.identityKey).inserted { picked.append(entry.song) }
            }
        }
        return picked
    }

    /// Start-of-day instant (epoch ms) for a `YYYY-MM-DD` day key,
    /// in the device calendar — the same calendar musicDayKey
    /// uses. Nil when the key does not parse, in which case daily
    /// picks simply skip the freshness bonus.
    static func dayReferenceMs(for dayKey: String) -> Int? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dayKey) else { return nil }
        return Int(date.timeIntervalSince1970 * 1000)
    }

    /// Most-played songs from the listen log (by event count), with
    /// full song lengths from totalDur. Mirrors Flutter
    /// ListenReport.compute's bySong aggregation.
    static func mostPlayedSongs(from events: [ListenEvent], limit: Int) -> [MusicSong] {
        var counts: [String: (song: MusicSong, plays: Int)] = [:]
        var order: [String] = []
        for event in events {
            let key = "\(event.platform.rawValue)|\(event.songId)"
            let song = MusicSong(
                songId: event.songId, title: event.title, artist: event.artist,
                cover: event.cover, platform: event.platform, dur: event.totalDur
            )
            if let existing = counts[key] {
                counts[key] = (song: existing.song, plays: existing.plays + 1)
            } else {
                counts[key] = (song: song, plays: 1)
                order.append(key)
            }
        }
        let ranked = order.sorted { counts[$0]!.plays > counts[$1]!.plays }
        return ranked.prefix(limit).map { counts[$0]!.song }
    }

    /// Top artists by listen count, most first.
    static func topArtists(from events: [ListenEvent], limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        for event in events {
            let artist = event.artist.isEmpty ? "—" : event.artist
            counts[artist] = (counts[artist] ?? 0) + 1
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map { $0.key }
    }
}

// MARK: - b45-F: personal FM refill (plan §9.2, Coda PersonalFMRefill)
//
// When the FM queue runs empty, refill it: at most 3 attempts,
// 1 s apart. A refill round is superseded when a newer round
// starts (new generation) or the user leaves FM — the old round
// abandons instead of writing into a queue that no longer
// exists. After the 3rd failure the caller shows a Toast.

enum PersonalFMRefill {
    /// Max refill attempts per empty-queue event.
    static let maxAttempts = 3
    /// Delay between attempts.
    static let retryInterval: TimeInterval = 1
    /// Toast shown when every attempt fails.
    static let failureToastMessage = "私人漫游加载失败，请稍后重试"

    /// Mutable refill state, owned by the FM view model.
    struct State {
        /// Generation of the current round (bumped on every new
        /// refill request and on leaving FM).
        var generation: Int = 0
        /// Attempts used in the current round.
        var attempts: Int = 0

        /// Start a new round (a fresh generation; old attempts
        /// are forgotten and any in-flight old round abandons).
        mutating func beginNewRound() -> Int {
            generation += 1
            attempts = 0
            return generation
        }

        /// Abandon the current round (leaving FM / queue replaced).
        mutating func abandon() {
            generation += 1
            attempts = 0
        }

        /// Record one failed attempt. Returns true when another
        /// attempt is allowed (still inside this generation and
        /// under the cap), false when the caller must Toast.
        /// `generation` guards the async retry: a retry whose
        /// generation no longer matches the state's is superseded
        /// and must abandon.
        mutating func recordFailure(generation: Int) -> Bool {
            guard generation == self.generation else { return false }
            attempts += 1
            return attempts < PersonalFMRefill.maxAttempts
        }
    }
}

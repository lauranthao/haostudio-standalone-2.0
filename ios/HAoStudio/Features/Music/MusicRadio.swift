// HAo Studio 2.0 — local radio + daily picks (S2-C leg).
//
// Pure queue builders over LOCAL data only — no login, no account,
// no network:
// - 私人漫游 (personal FM): a seeded shuffle of the local pool
//   (favourites + recent + most-played), minus disliked ids.
// - 心动模式 (heartbeat): the liked songs, seeded-shuffled.
// - 每日推荐 (daily picks): ~20 songs, half most-played + half
//   discovery via top artists, deterministic per day string
//   (Flutter daily_page: "same-day same list").
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

    /// Daily picks: ~20 songs — half most-played (by listen count)
    /// + half discovery via top artists (songs by the most-listened
    /// artists that are NOT already in the most-played half).
    /// Deterministic per day string; the same day always yields the
    /// same list (Flutter daily_page).
    static func dailyPicks(
        listenTop: [MusicSong],
        byArtist: [String: [MusicSong]],
        topArtists: [String],
        favourites: [MusicSong],
        recent: [MusicSong],
        seed: String,
        total: Int = 20
    ) -> [MusicSong] {
        let half = total / 2
        var picked: [MusicSong] = []
        var seen = Set<String>()
        for song in listenTop.prefix(half) {
            if seen.insert(song.identityKey).inserted { picked.append(song) }
        }
        // Discovery half: songs by top artists, seeded shuffle.
        var discovery: [MusicSong] = []
        for artist in topArtists {
            for song in byArtist[artist] ?? [] {
                if !seen.contains(song.identityKey) { discovery.append(song) }
            }
        }
        if discovery.isEmpty {
            // Fall back to favourites + recent when the listen log has
            // no artist signal yet (fresh install).
            discovery = favourites + recent
        }
        var rng = MusicSeededRandom(seed: seed)
        for song in rng.shuffle(discovery) {
            if picked.count >= total { break }
            if seen.insert(song.identityKey).inserted { picked.append(song) }
        }
        return picked
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

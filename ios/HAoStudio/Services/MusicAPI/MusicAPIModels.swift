// MusicAPIModels.swift
// Music API data models (the Flutter `music_models.dart` shapes
// that the six API modules return). `MusicTrack` is the song shape;
// these are the album / artist / playlist / comment shapes around it.

import Foundation

struct AlbumSummary: Equatable, Identifiable {
    let id: String
    let name: String
    let cover: String
    let artist: String
    /// Publish time in milliseconds since epoch (0 when unknown).
    let publishTime: Int
    let songCount: Int
    let platform: MusicPlatform

    init(id: String, name: String, cover: String = "", artist: String = "",
         publishTime: Int = 0, songCount: Int = 0, platform: MusicPlatform) {
        self.id = id
        self.name = name
        self.cover = cover
        self.artist = artist
        self.publishTime = publishTime
        self.songCount = songCount
        self.platform = platform
    }
}

struct AlbumDetail {
    let name: String
    let pic: String
    let artist: String
    let songs: [MusicTrack]
    /// Publish time in milliseconds since epoch, 0 when unknown.
    /// The album page shows "年份 + 音质"; the year derives from
    /// this (Calendar year of the date). Kuwo has no publish date
    /// in its workaround path, so it stays 0 there.
    let publishTime: Int

    init(name: String, pic: String = "", artist: String = "", songs: [MusicTrack] = [], publishTime: Int = 0) {
        self.name = name
        self.pic = pic
        self.artist = artist
        self.songs = songs
        self.publishTime = publishTime
    }
}

struct ArtistSummary: Equatable {
    let id: String
    let name: String
    let cover: String
    let musicSize: Int
    let albumSize: Int
    let platform: MusicPlatform
    let alias: String

    init(id: String, name: String, cover: String = "", musicSize: Int = 0,
         albumSize: Int = 0, platform: MusicPlatform, alias: String = "") {
        self.id = id
        self.name = name
        self.cover = cover
        self.musicSize = musicSize
        self.albumSize = albumSize
        self.platform = platform
        self.alias = alias
    }
}

struct ArtistDetail {
    let name: String
    let pic: String
    let musicSize: Int
    let albumSize: Int
    let songs: [MusicTrack]
    let albums: [AlbumSummary]

    init(name: String, pic: String = "", musicSize: Int = 0, albumSize: Int = 0,
         songs: [MusicTrack] = [], albums: [AlbumSummary] = []) {
        self.name = name
        self.pic = pic
        self.musicSize = musicSize
        self.albumSize = albumSize
        self.songs = songs
        self.albums = albums
    }
}

struct PlaylistSummary: Equatable {
    let id: String
    let name: String
    let cover: String
    let creator: String
    let playCount: Int
    let trackCount: Int
    let desc: String
    let time: String
    let platform: MusicPlatform

    init(id: String, name: String, cover: String = "", creator: String = "",
         playCount: Int = 0, trackCount: Int = 0, desc: String = "",
         time: String = "", platform: MusicPlatform) {
        self.id = id
        self.name = name
        self.cover = cover
        self.creator = creator
        self.playCount = playCount
        self.trackCount = trackCount
        self.desc = desc
        self.time = time
        self.platform = platform
    }
}

/// One comment (read-only — posting / liking needs a platform login,
/// which this app does not have).
struct CommentItem: Equatable {
    let nick: String
    let avatar: String
    let content: String
    let likes: Int
    /// Milliseconds since epoch.
    let time: Int
    let platform: MusicPlatform
}

/// A playlist imported from a pasted public link. `missing` counts
/// songs known to be missing; `note` is '' when the import is
/// complete, else a user-facing reason. A partial import is reported,
/// never silently short.
struct ImportedPlaylist {
    let name: String
    let tracks: [MusicTrack]
    let platform: MusicPlatform
    let missing: Int
    let note: String
}

/// Kugou share-playlist parameters from a share/zlist.html landing URL.
struct KgShareParams {
    let listid: String
    let uid: String
    let sign: String
    let t: String
    let type: String
    let collection: String
    let chain: String
}

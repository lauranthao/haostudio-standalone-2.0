// MusicSearchAPI.swift
// Song search: the four direct platform legs + LX script legs.
//
// `search(keyword:completion:)` is the UI leg's entry point (name
// and signature are the contract — do not rename). It streams: the
// completion is invoked REPEATEDLY with the cumulative result list
// as each leg settles, so the first result shows in ~1 s (the
// fastest leg's time) instead of waiting for every source. The
// design guarantee is the streaming itself — real-device latency
// cannot be measured on this machine; see the report.
//
// Order rules (Flutter `SongSearchService` parity):
// - The 4 platform legs run concurrently, each capped at 5 s.
//   NetEase + QQ are the stable group and sort first (arrival order
//   within the group); Kugou + Kuwo follow.
// - Dedupe by platform+songId (script hits by title+artist).
// - Cover backfill: a track with no cover takes the cover of a
//   same-title+artist track that has one.
// - Kugou / Kuwo retry once after 800 ms ONLY when the API answered
//   200 with an empty list (their known flakiness); a null fetch
//   (network/timeout) is NOT retried.
// - Script search legs run concurrently but emit only after their
//   platform leg settles.
// - A leg that fails contributes nothing and never kills the others.

import Foundation

final class MusicSearchAPI {
    static let shared = MusicSearchAPI()

    private let client: MusicAPIClient
    private let engine: LXEngine
    /// Per-leg timeout for the aggregated search.
    static let legTimeout: TimeInterval = 5

    init(client: MusicAPIClient = .shared, engine: LXEngine = .shared) {
        self.client = client
        self.engine = engine
    }

    // MARK: - Aggregated search (streaming)

    /// Search all platforms. `completion` is called repeatedly with
    /// the cumulative, deduped, wy+tx-first list as each leg settles.
    /// The caller renders each call; the last call is the complete
    /// list. Empty keyword completes once with [].
    func search(keyword: String, completion: @escaping ([MusicTrack]) -> Void) {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            completion([])
            return
        }
        engine.ensureInitialized { _ in }
        let mergeQueue = DispatchQueue(label: "com.haostudio.musicsearch")
        var results: [MusicTrack] = []
        var seenKeys = Set<String>()
        var settledPlatforms = Set<MusicPlatform>()

        func sortAndBackfill(_ list: [MusicTrack]) -> [MusicTrack] {
            var out = list
            // Cover backfill from the same title+artist.
            var coverByKey: [String: String] = [:]
            for track in out {
                if let cover = track.coverURL?.absoluteString, !cover.isEmpty {
                    let key = "\(MusicText.normalizeName(track.title))|\(MusicText.normalizeName(track.artist))"
                    if coverByKey[key] == nil { coverByKey[key] = cover }
                }
            }
            out = out.map { track in
                guard track.coverURL == nil else { return track }
                let key = "\(MusicText.normalizeName(track.title))|\(MusicText.normalizeName(track.artist))"
                guard let cover = coverByKey[key], let url = URL(string: cover) else { return track }
                return MusicTrack(id: track.id, title: track.title, artist: track.artist,
                                  album: track.album, coverURL: url, duration: track.duration,
                                  sourceID: track.sourceID)
            }
            // Stable wy+tx-first order (arrival order within a group).
            let groupOrder: [String: Int] = ["wy": 0, "tx": 1, "kg": 2, "kw": 3, "mg": 4]
            return out.enumerated().sorted { a, b in
                let ga = groupOrder[a.element.sourceID] ?? 9
                let gb = groupOrder[b.element.sourceID] ?? 9
                if ga != gb { return ga < gb }
                return a.offset < b.offset
            }.map { $0.element }
        }

        func emit() {
            let snapshot = sortAndBackfill(results)
            DispatchQueue.main.async { completion(snapshot) }
        }

        func addTracks(_ tracks: [MusicTrack], dedupeByTitleArtist: Bool) {
            for track in tracks {
                let key: String
                if dedupeByTitleArtist || track.id.isEmpty {
                    key = "t|\(MusicText.normalizeName(track.title))|\(MusicText.normalizeName(track.artist))"
                } else {
                    key = track.dedupeKey
                }
                guard !seenKeys.contains(key) else { continue }
                seenKeys.insert(key)
                results.append(track)
            }
        }

        func platformSettled(_ platform: MusicPlatform) {
            settledPlatforms.insert(platform)
            emit()
            // Script legs for this platform run now (concurrently) and
            // emit only after the platform leg settled — which is now.
            let sources = engine.searchSources(platform: platform.rawValue)
            for source in sources {
                engine.search(scriptID: source.scriptID, platform: platform.rawValue,
                              keyword: query, page: 1, limit: 20) { rawMaps in
                    let tracks = rawMaps.compactMap { MusicSearchAPI.trackFromScriptMap($0, platform: platform) }
                    mergeQueue.async {
                        addTracks(tracks, dedupeByTitleArtist: true)
                        emit()
                    }
                }
            }
        }

        for platform in [MusicPlatform.wy, .tx, .kg, .kw] {
            searchOne(platform: platform, keyword: query) { tracks in
                mergeQueue.async {
                    addTracks(tracks, dedupeByTitleArtist: false)
                    platformSettled(platform)
                }
            }
        }
    }

    // MARK: - Single-platform search

    /// One platform leg (direct API). Empty on any failure.
    func searchOne(platform: MusicPlatform, keyword: String, completion: @escaping ([MusicTrack]) -> Void) {
        let token = LXCancelToken()
        let timeoutWork = DispatchWorkItem { token.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.legTimeout, execute: timeoutWork)
        let done: ([MusicTrack]) -> Void = { tracks in
            timeoutWork.cancel()
            completion(tracks)
        }
        switch platform {
        case .wy:
            searchWy(keyword, limit: 20, token: token, completion: done)
        case .tx:
            searchTx(keyword, limit: 20, token: token, completion: done)
        case .kg:
            searchKg(keyword, limit: 15, token: token, completion: done)
        case .kw:
            searchKw(keyword, limit: 15, token: token, completion: done)
        case .mg:
            done([])
        }
    }

    /// NetEase: POST music.163.com/api/cloudsearch/pc, type=1.
    func searchWy(_ query: String, limit: Int, token: LXCancelToken? = nil, completion: @escaping ([MusicTrack]) -> Void) {
        client.postFormJson(
            "https://music.163.com/api/cloudsearch/pc",
            fields: ["s": query, "type": "1", "limit": "\(limit)", "offset": "0"],
            headers: ["User-Agent": MusicUA.value]
        ) { json in
            guard let json = json, token?.isCancelled != true else { completion([]); return }
            let result = MusicAPIJSON.asMap(json["result"])
            let songs = MusicAPIJSON.asList(result?["songs"])
            completion(songs.map { x in
                let durMs = MusicAPIJSON.asInt(x["duration"] != nil ? x["duration"] : x["dt"])
                let artists = MusicAPIJSON.asList(x["ar"])
                let album = MusicAPIJSON.asMap(x["al"])
                let cover = MusicText.coverHi(MusicAPIJSON.asString(album?["picUrl"]), platform: "wy")
                return MusicTrack(
                    id: MusicAPIJSON.asString(x["id"]),
                    title: MusicAPIJSON.asString(x["name"]),
                    artist: artists.map { MusicAPIJSON.asString($0["name"]) }.joined(separator: "/"),
                    album: MusicAPIJSON.asString(album?["name"]),
                    coverURL: URL(string: cover),
                    duration: (Double(durMs) / 1000.0).rounded(),
                    sourceID: "wy")
            })
        }
    }

    /// QQ: GET c.y.qq.com search_for_qq_cp. songId is the songmid.
    func searchTx(_ query: String, limit: Int, token: LXCancelToken? = nil, completion: @escaping ([MusicTrack]) -> Void) {
        client.getJson(
            "https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp",
            query: [
                "g_tk": "5381", "uin": "0", "format": "json",
                "inCharset": "utf-8", "outCharset": "utf-8", "notice": "0",
                "platform": "h5", "needNewCode": "1", "w": query,
                "zhidaqu": "1", "catZhida": "1", "t": "0", "flag": "1",
                "ie": "utf-8", "sem": "1", "aggr": "0",
                "perpage": "\(limit)", "n": "\(limit)", "p": "1",
                "remoteplace": "txt.mqq.all",
            ],
            headers: ["Referer": "https://y.qq.com/", "User-Agent": MusicUA.value]
        ) { json in
            guard let json = json, token?.isCancelled != true else { completion([]); return }
            let data = MusicAPIJSON.asMap(json["data"])
            let song = MusicAPIJSON.asMap(data?["song"])
            let list = MusicAPIJSON.asList(song?["list"])
            completion(list.map { x in
                let singers = MusicAPIJSON.asList(x["singer"])
                let albummid = MusicAPIJSON.asString(x["albummid"])
                let cover = albummid.isEmpty ? "" : MusicText.coverHi(
                    "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albummid).jpg", platform: "tx")
                return MusicTrack(
                    id: MusicAPIJSON.asString(x["songmid"]),
                    title: MusicAPIJSON.asString(x["songname"]),
                    artist: singers.map { MusicAPIJSON.asString($0["name"]) }.joined(separator: "/"),
                    album: MusicAPIJSON.asString(x["albumname"]),
                    coverURL: URL(string: cover),
                    duration: TimeInterval(MusicAPIJSON.asInt(x["interval"])),
                    sourceID: "tx")
            })
        }
    }

    /// Kugou: GET songsearch.kugou.com. Retry once after 800 ms if
    /// the API answered 200 but with an empty list (its known
    /// flakiness). A null fetch (network/timeout) is NOT retried.
    func searchKg(_ query: String, limit: Int, token: LXCancelToken? = nil, completion: @escaping ([MusicTrack]) -> Void) {
        func attempt(_ attemptNumber: Int) {
            client.getJson(
                "https://songsearch.kugou.com/song_search_v2",
                query: ["keyword": query, "page": "1", "pagesize": "\(limit)", "format": "json"],
                headers: ["User-Agent": MusicUA.value]
            ) { json in
                guard let json = json, token?.isCancelled != true else { completion([]); return }
                let data = MusicAPIJSON.asMap(json["data"])
                let out = MusicAPIJSON.asList(data?["lists"]).compactMap { x -> MusicTrack? in
                    let track = MusicTrack(
                        id: MusicAPIJSON.asString(x["FileHash"]),
                        title: MusicAPIJSON.asString(x["SongName"]),
                        artist: MusicAPIJSON.asString(x["SingerName"]),
                        album: MusicAPIJSON.asString(x["AlbumName"]),
                        duration: TimeInterval(MusicAPIJSON.asInt(x["Duration"])),
                        sourceID: "kg")
                    return track.id.isEmpty ? nil : track
                }
                if !out.isEmpty || attemptNumber >= 1 {
                    completion(out)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(800)) {
                    attempt(attemptNumber + 1)
                }
            }
        }
        attempt(0)
    }

    /// Kuwo: single-quoted pseudo-JSON via r.s. Retry once after
    /// 800 ms if empty (same rule as Kugou).
    func searchKw(_ query: String, limit: Int, token: LXCancelToken? = nil, completion: @escaping ([MusicTrack]) -> Void) {
        func attempt(_ attemptNumber: Int) {
            let url = "https://search.kuwo.cn/r.s?all=\(MusicAPIClient.percentEncode(query))&ft=music&rformat=json&encoding=utf8&rn=\(limit)"
            client.getText(url, headers: ["User-Agent": MusicUA.value]) { text in
                guard let text = text, token?.isCancelled != true else { completion([]); return }
                let out = MusicSearchAPI.parseKwSongs(text)
                if !out.isEmpty || attemptNumber >= 1 {
                    completion(out)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(800)) {
                    attempt(attemptNumber + 1)
                }
            }
        }
        attempt(0)
    }

    // MARK: - Kuwo parsing (pure, unit-tested)

    /// Parse a Kuwo r.s response (single-quoted JSON or raw text).
    /// Try JSON.parse after quote-swap, then the regex fallback.
    static func parseKwSongs(_ text: String) -> [MusicTrack] {
        var list: [[String: Any]] = []
        let swapped = text.replacingOccurrences(of: "'", with: "\"")
        if let decoded = MusicJSON.object(from: swapped) as? [String: Any] {
            list = MusicAPIJSON.asList(decoded["abslist"])
        } else {
            // Regex fallback: parallel field lists, zipped by index.
            func matches(_ pattern: String) -> [String] {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
                let range = NSRange(text.startIndex..., in: text)
                return regex.matches(in: text, range: range).compactMap { match in
                    guard let r = Range(match.range(at: 1), in: text) else { return nil }
                    return String(text[r])
                }
            }
            let ids = matches("'MUSICRID':'(MUSIC_\\d+)'")
            let names = matches("'NAME':'((?:[^'\\\\]|\\\\.)*)'")
            let artists = matches("'ARTIST':'((?:[^'\\\\]|\\\\.)*)'")
            let pics = matches("'web_albumpic_short':'((?:[^'\\\\]|\\\\.)*)'")
            list = ids.enumerated().map { i, rid in
                [
                    "MUSICRID": rid,
                    "NAME": i < names.count ? names[i] : "",
                    "ARTIST": i < artists.count ? artists[i] : "",
                    "web_albumpic_short": i < pics.count ? pics[i] : "",
                ] as [String: Any]
            }
        }
        return list.compactMap { x in
            let rid = MusicAPIJSON.asString(x["MUSICRID"])
            let picShort = MusicAPIJSON.asString(x["web_albumpic_short"])
            let picPath = MusicAPIJSON.asString(x["PICPATH"])
            // Kuwo names arrive with raw escapes (double-escaped
            // \uXXXX + HTML entities) — decode here so the row shows
            // clean text AND cover-backfill title keys match the other
            // platforms.
            let track = MusicTrack(
                id: rid.replacingOccurrences(of: "MUSIC_", with: ""),
                title: MusicText.decodeEntities(MusicAPIJSON.asString(x["NAME"])),
                artist: MusicText.decodeEntities(MusicAPIJSON.asString(x["ARTIST"])),
                album: MusicText.decodeEntities(MusicAPIJSON.asString(x["ALBUM"])),
                coverURL: URL(string: MusicText.coverHi(
                    picShort.isEmpty ? picPath : "https://img1.kuwo.cn/star/albumcover/\(picShort)",
                    platform: "kw")),
                duration: TimeInterval(MusicAPIJSON.asInt(x["DURATION"])),
                sourceID: "kw")
            guard !track.id.isEmpty, !track.title.isEmpty else { return nil }
            return track
        }
    }

    /// Map one LX script search hit to a track. Script hits carry no
    /// stable platform song id in some scripts, so the aggregator
    /// dedupes them by title+artist.
    static func trackFromScriptMap(_ map: [String: Any], platform: MusicPlatform) -> MusicTrack? {
        let id = MusicAPIJSON.asString(map["songmid"] ?? map["id"] ?? map["songId"])
        let title = MusicAPIJSON.asString(map["name"] ?? map["title"] ?? map["songname"])
        guard !title.isEmpty else { return nil }
        let artist = MusicAPIJSON.asString(map["singer"] ?? map["artist"])
        let album = MusicAPIJSON.asString(map["albumName"] ?? map["album"])
        let cover = MusicAPIJSON.asString(map["pic"] ?? map["cover"] ?? map["albumpic"])
        let duration = MusicAPIJSON.asDouble(map["duration"] ?? map["interval"])
        // The track carries the REAL platform: a per-item signal
        // in the script result wins (some scripts return items
        // from another platform than requested); otherwise the
        // platform the script was asked to search. Never a bare
        // script id — the badge must show the platform, not the
        // script (S3-C badge fix).
        let itemPlatform = MusicAPIJSON.asString(
            map["source"] ?? map["platform"] ?? map["sourceID"])
        let resolved = MusicPlatform.platformIfKnown(itemPlatform) ?? platform
        return MusicTrack(
            id: id, title: title, artist: artist, album: album,
            coverURL: URL(string: MusicText.coverHi(cover, platform: resolved.rawValue)),
            duration: duration > 0 ? duration : nil,
            sourceID: resolved.rawValue)
    }

    // MARK: - NetEase charts (排行榜)

    /// NetEase charts (Flutter `neteaseCharts` parity): GET
    /// https://music.163.com/api/toplist, 15 s timeout, UA
    /// MusicUA.value. There is NO QQ/Kugou/Kuwo chart source in
    /// this app — charts are NetEase toplist ids only. A chart IS
    /// a playlist id: the charts page opens it through the existing
    /// `importWyPlaylist` path, no new detail page. Empty on any
    /// failure (the page shows its empty state).
    func neteaseCharts(completion: @escaping ([PlaylistSummary]) -> Void) {
        client.getJson(
            "https://music.163.com/api/toplist",
            headers: ["User-Agent": MusicUA.value],
            timeout: 15
        ) { json in
            guard let json = json else {
                completion([])
                return
            }
            completion(MusicSearchAPI.parseNeteaseCharts(json))
        }
    }

    /// Parse the toplist payload: 65 charts; the four canonical
    /// ones (飙升/新歌/原创/热歌) are pinned first in that order,
    /// the rest keep API order. Entries without an id or a name
    /// are dropped.
    static func parseNeteaseCharts(_ json: [String: Any]) -> [PlaylistSummary] {
        let pinned = ["飙升榜", "新歌榜", "原创榜", "热歌榜"]
        var all = MusicAPIJSON.asList(json["list"]).map { chart in
            PlaylistSummary(
                id: MusicAPIJSON.asString(chart["id"]),
                name: MusicAPIJSON.asString(chart["name"]),
                cover: MusicAPIJSON.asString(chart["coverImgUrl"]),
                trackCount: MusicAPIJSON.asInt(chart["trackCount"]),
                desc: MusicAPIJSON.asString(chart["updateFrequency"]),
                platform: .wy
            )
        }.filter { !$0.id.isEmpty && !$0.name.isEmpty }
        var head: [PlaylistSummary] = []
        for name in pinned {
            if let index = all.firstIndex(where: { $0.name == name }) {
                head.append(all.remove(at: index))
            }
        }
        return head + all
    }
}

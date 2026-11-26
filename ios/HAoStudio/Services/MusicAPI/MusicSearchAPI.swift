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

    // MARK: - Shared merge (stream + paged songs)

    /// Cover backfill (same title+artist) + stable wy+tx-first
    /// order. Shared by the streaming search and the paged song
    /// fetcher so both pages sort identically.
    static func sortAndBackfill(_ list: [MusicTrack]) -> [MusicTrack] {
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
                              sourceID: track.sourceID, trialOnly: track.trialOnly)
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

    // MARK: - Aggregated search (streaming)

    /// Search all platforms. `completion` is called repeatedly with
    /// the cumulative, deduped, wy+tx-first list as each leg settles.
    /// The caller renders each call; the last call is the complete
    /// list. Empty keyword completes once with [].
    func search(keyword: String, completion: @escaping ([MusicTrack], Bool) -> Void) {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            completion([], false)
            return
        }
        engine.ensureInitialized { _ in }
        let mergeQueue = DispatchQueue(label: "com.haostudio.musicsearch")
        var results: [MusicTrack] = []
        var seenKeys = Set<String>()
        var settledPlatforms = Set<MusicPlatform>()
        // b49fix2 P2-4: legs that never answered (nil response /
        // cancelled / timeout). allFailed is true only once every
        // leg has settled, nothing was found, and every leg failed
        // — a genuine no-match still reports false, so the view can
        // tell "搜索失败" from "没有找到".
        var failedPlatforms = Set<MusicPlatform>()
        let platforms: [MusicPlatform] = [.wy, .tx, .kg, .kw, .mg]

        func sortAndBackfill(_ list: [MusicTrack]) -> [MusicTrack] {
            MusicSearchAPI.sortAndBackfill(list)
        }

        func emit() {
            let snapshot = sortAndBackfill(results)
            let allFailed = settledPlatforms.count == platforms.count
                && results.isEmpty && failedPlatforms.count == platforms.count
            DispatchQueue.main.async { completion(snapshot, allFailed) }
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

        for platform in platforms {
            searchOneResult(platform: platform, keyword: query) { tracks, ok in
                mergeQueue.async {
                    addTracks(tracks, dedupeByTitleArtist: false)
                    if !ok { failedPlatforms.insert(platform) }
                    platformSettled(platform)
                }
            }
        }
    }

    // MARK: - Single-platform search

    /// One platform leg (direct API) with transport reporting
    /// (b49fix2 P2-4): `ok` is false only when the leg never
    /// answered (nil response / cancelled / timeout) — an answered
    /// leg with zero matches still reports ok. The plain
    /// `searchOne` below drops the flag; the streaming `search`
    /// above uses it for its all-legs-failed signal.
    func searchOneResult(platform: MusicPlatform, keyword: String, completion: @escaping ([MusicTrack], Bool) -> Void) {
        let token = LXCancelToken()
        let timeoutWork = DispatchWorkItem { token.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.legTimeout, execute: timeoutWork)
        let done: ([MusicTrack], Bool) -> Void = { tracks, ok in
            timeoutWork.cancel()
            completion(tracks, ok)
        }
        switch platform {
        case .wy:
            searchWyResult(keyword, limit: 20, token: token, completion: done)
        case .tx:
            searchTxResult(keyword, limit: 20, token: token, completion: done)
        case .kg:
            searchKgResult(keyword, limit: 15, token: token, completion: done)
        case .kw:
            searchKwResult(keyword, limit: 15, token: token, completion: done)
        case .mg:
            searchMgResult(keyword, limit: 15, token: token, completion: done)
        }
    }

    /// One platform leg (direct API). Empty on any failure.
    func searchOne(platform: MusicPlatform, keyword: String, completion: @escaping ([MusicTrack]) -> Void) {
        searchOneResult(platform: platform, keyword: keyword) { tracks, _ in completion(tracks) }
    }

    /// 咪咕: oiapi MiGu_Music (`?msg=` — `?keyword=` answers code
    /// -1 "请输入msg或id"). Verified live 2026-11-25: code 1 +
    /// data.items[{song, singer, contentId, picture, types[]}].
    /// The track id end-to-end is oiapi's contentId — the
    /// zddyr_mg resolver passes it as songmid (never a random
    /// mg_ id). No duration or album in the response (duration
    /// nil = unknown).
    func searchMg(_ query: String, limit: Int, token: LXCancelToken? = nil, completion: @escaping ([MusicTrack]) -> Void) {
        searchMgResult(query, limit: limit, token: token) { tracks, _ in completion(tracks) }
    }

    /// Same as `searchMg`, plus a transport-success flag (see
    /// `searchWyResult`): false only when the leg never answered
    /// (nil response / cancelled / timeout) — an answered leg with
    /// zero matches still reports ok.
    func searchMgResult(_ query: String, limit: Int, token: LXCancelToken? = nil, completion: @escaping ([MusicTrack], Bool) -> Void) {
        let url = "https://oiapi.net/api/MiGu_Music?msg=\(MusicAPIClient.percentEncode(query))"
        client.getJson(url, headers: ["User-Agent": MusicUA.value], timeout: Self.legTimeout) { json in
            guard let json = json, token?.isCancelled != true else { completion([], false); return }
            completion(Self.parseMgSongs(json, limit: limit), true)
        }
    }

    /// Parse an oiapi MiGu_Music response. Pure, unit-tested.
    static func parseMgSongs(_ json: [String: Any], limit: Int = 20) -> [MusicTrack] {
        guard (json["code"] as? Int) == 1 else { return [] }
        // b49fix26: asMap returns an optional; a missing "data"
        // map means no items (Bitrise #36). `?? [:]` keeps the
        // same empty result as a present-but-empty map.
        let data = MusicAPIJSON.asMap(json["data"]) ?? [:]
        let items = MusicAPIJSON.asList(data["items"])
        return items.prefix(limit).compactMap { x in
            let track = MusicTrack(
                id: MusicAPIJSON.asString(x["contentId"]),
                title: MusicAPIJSON.asString(x["song"]),
                artist: MusicAPIJSON.asString(x["singer"]),
                album: "",
                coverURL: URL(string: MusicText.toHttps(MusicAPIJSON.asString(x["picture"]))),
                duration: nil,
                sourceID: "mg")
            guard !track.id.isEmpty, !track.title.isEmpty else { return nil }
            return track
        }
    }

    /// Trial-only flag for one NetEase cloudsearch song map (build
    /// 36 item 3, pure for tests): `fee` (0 = free, 1 = VIP, 4 =
    /// paid album, 8 = VIP-only per the build-35 search audit) and
    /// `privilege.dlLevel` / `plLevel` (`none` = no full playback
    /// for a no-login client). A missing field never flags.
    static func wyTrialOnly(_ song: [String: Any]) -> Bool {
        let privilege = MusicAPIJSON.asMap(song["privilege"])
        return PreviewAudioClassifier.isTrialOnlyTrack(
            fee: (song["fee"] as? NSNumber)?.intValue,
            dlLevel: privilege.map { MusicAPIJSON.asString($0["dlLevel"]) },
            plLevel: privilege.map { MusicAPIJSON.asString($0["plLevel"]) },
            payPlay: nil)
    }

    /// Trial-only flag for one QQ search song map (build 36 item 3,
    /// pure for tests): `pay.payplay` == 1 means pay-to-play, i.e.
    /// trial-only for a no-login client.
    static func txTrialOnly(_ song: [String: Any]) -> Bool {
        let pay = MusicAPIJSON.asMap(song["pay"])
        return PreviewAudioClassifier.isTrialOnlyTrack(
            fee: nil, dlLevel: nil, plLevel: nil,
            payPlay: pay.map { MusicAPIJSON.asInt($0["payplay"]) == 1 })
    }

    /// NetEase: POST music.163.com/api/cloudsearch/pc, type=1.
    /// `offset` pages the song list (page 0 = the streamed first
    /// page); the single-array wrapper keeps the old call sites.
    func searchWy(_ query: String, limit: Int, offset: Int = 0, token: LXCancelToken? = nil, completion: @escaping ([MusicTrack]) -> Void) {
        searchWyResult(query, limit: limit, offset: offset, token: token) { tracks, _ in completion(tracks) }
    }

    /// Same as `searchWy`, but also reports whether the transport
    /// succeeded (false = nil response / cancelled / timeout), so a
    /// paged caller can tell "no more results" from "page failed".
    func searchWyResult(_ query: String, limit: Int, offset: Int = 0, token: LXCancelToken? = nil, completion: @escaping ([MusicTrack], Bool) -> Void) {
        client.postFormJson(
            "https://music.163.com/api/cloudsearch/pc",
            fields: ["s": query, "type": "1", "limit": "\(limit)", "offset": "\(offset)"],
            headers: ["User-Agent": MusicUA.value]
        ) { json in
            guard let json = json, token?.isCancelled != true else { completion([], false); return }
            let result = MusicAPIJSON.asMap(json["result"])
            let songs = MusicAPIJSON.asList(result?["songs"])
            completion(songs.map { x in
                let durMs = MusicAPIJSON.asInt(x["duration"] != nil ? x["duration"] : x["dt"])
                let artists = MusicAPIJSON.asList(x["ar"])
                let album = MusicAPIJSON.asMap(x["al"])
                let cover = MusicText.coverHi(MusicAPIJSON.asString(album?["picUrl"]), platform: "wy")
                // Build 36 item 3: NetEase marks paywalled tracks in
                // the search payload itself (see `wyTrialOnly`).
                let trialOnly = MusicSearchAPI.wyTrialOnly(x)
                return MusicTrack(
                    id: MusicAPIJSON.asString(x["id"]),
                    title: MusicAPIJSON.asString(x["name"]),
                    artist: artists.map { MusicAPIJSON.asString($0["name"]) }.joined(separator: "/"),
                    album: MusicAPIJSON.asString(album?["name"]),
                    coverURL: URL(string: cover),
                    duration: (Double(durMs) / 1000.0).rounded(),
                    sourceID: "wy",
                    trialOnly: trialOnly)
            }, true)
        }
    }

    /// QQ: GET c.y.qq.com search_for_qq_cp. songId is the songmid.
    /// `page` is 1-based (page 1 = the streamed first page).
    func searchTx(_ query: String, limit: Int, page: Int = 1, token: LXCancelToken? = nil, completion: @escaping ([MusicTrack]) -> Void) {
        searchTxResult(query, limit: limit, page: page, token: token) { tracks, _ in completion(tracks) }
    }

    /// Same as `searchTx`, plus a transport-success flag (see
    /// `searchWyResult`).
    func searchTxResult(_ query: String, limit: Int, page: Int = 1, token: LXCancelToken? = nil, completion: @escaping ([MusicTrack], Bool) -> Void) {
        client.getJson(
            "https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp",
            query: [
                "g_tk": "5381", "uin": "0", "format": "json",
                "inCharset": "utf-8", "outCharset": "utf-8", "notice": "0",
                "platform": "h5", "needNewCode": "1", "w": query,
                "zhidaqu": "1", "catZhida": "1", "t": "0", "flag": "1",
                "ie": "utf-8", "sem": "1", "aggr": "0",
                "perpage": "\(limit)", "n": "\(limit)", "p": "\(page)",
                "remoteplace": "txt.mqq.all",
            ],
            headers: ["Referer": "https://y.qq.com/", "User-Agent": MusicUA.value]
        ) { json in
            guard let json = json, token?.isCancelled != true else { completion([], false); return }
            let data = MusicAPIJSON.asMap(json["data"])
            let song = MusicAPIJSON.asMap(data?["song"])
            let list = MusicAPIJSON.asList(song?["list"])
            completion(list.map { x in
                let singers = MusicAPIJSON.asList(x["singer"])
                let albummid = MusicAPIJSON.asString(x["albummid"])
                let cover = albummid.isEmpty ? "" : MusicText.coverHi(
                    "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albummid).jpg", platform: "tx")
                // Build 36 item 3: QQ marks pay-to-play tracks with
                // `pay.payplay` == 1 (see `txTrialOnly`).
                let trialOnly = MusicSearchAPI.txTrialOnly(x)
                return MusicTrack(
                    id: MusicAPIJSON.asString(x["songmid"]),
                    title: MusicAPIJSON.asString(x["songname"]),
                    artist: singers.map { MusicAPIJSON.asString($0["name"]) }.joined(separator: "/"),
                    album: MusicAPIJSON.asString(x["albumname"]),
                    coverURL: URL(string: cover),
                    duration: TimeInterval(MusicAPIJSON.asInt(x["interval"])),
                    sourceID: "tx",
                    trialOnly: trialOnly)
            }, true)
        }
    }

    /// Kugou: GET songsearch.kugou.com. Retry once after 800 ms if
    /// the API answered 200 but with an empty list (its known
    /// flakiness). A null fetch (network/timeout) is NOT retried.
    /// `page` is 1-based (page 1 = the streamed first page).
    func searchKg(_ query: String, limit: Int, page: Int = 1, token: LXCancelToken? = nil, completion: @escaping ([MusicTrack]) -> Void) {
        searchKgResult(query, limit: limit, page: page, token: token) { tracks, _ in completion(tracks) }
    }

    /// Same as `searchKg`, plus a transport-success flag (see
    /// `searchWyResult`). A 200-with-empty-list retry that still
    /// comes back empty counts as success (the leg answered).
    func searchKgResult(_ query: String, limit: Int, page: Int = 1, token: LXCancelToken? = nil, completion: @escaping ([MusicTrack], Bool) -> Void) {
        func attempt(_ attemptNumber: Int) {
            client.getJson(
                "https://songsearch.kugou.com/song_search_v2",
                query: ["keyword": query, "page": "\(page)", "pagesize": "\(limit)", "format": "json"],
                headers: ["User-Agent": MusicUA.value]
            ) { json in
                guard let json = json, token?.isCancelled != true else { completion([], false); return }
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
                    completion(out, true)
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
    /// 800 ms if empty (same rule as Kugou). `page` is the 0-based
    /// `pn` the API takes (page 0 = the streamed first page).
    func searchKw(_ query: String, limit: Int, page: Int = 0, token: LXCancelToken? = nil, completion: @escaping ([MusicTrack]) -> Void) {
        searchKwResult(query, limit: limit, page: page, token: token) { tracks, _ in completion(tracks) }
    }

    /// Same as `searchKw`, plus a transport-success flag (see
    /// `searchWyResult`).
    func searchKwResult(_ query: String, limit: Int, page: Int = 0, token: LXCancelToken? = nil, completion: @escaping ([MusicTrack], Bool) -> Void) {
        func attempt(_ attemptNumber: Int) {
            let url = "https://search.kuwo.cn/r.s?all=\(MusicAPIClient.percentEncode(query))&ft=music&rformat=json&encoding=utf8&rn=\(limit)&pn=\(page)"
            client.getText(url, headers: ["User-Agent": MusicUA.value]) { text in
                guard let text = text, token?.isCancelled != true else { completion([], false); return }
                let out = MusicSearchAPI.parseKwSongs(text)
                if !out.isEmpty || attemptNumber >= 1 {
                    completion(out, true)
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
        let duration = scriptDurationSeconds(map)
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
            duration: duration,
            sourceID: resolved.rawValue)
    }

    /// Duration of an LX script search hit, in seconds. Scripts
    /// carry it two ways: a numeric `duration` (seconds — kuliao),
    /// or an `interval` string "mm:ss" (feichangdao, suyin — their
    /// formatDuration helper). The old `asDouble(duration ??
    /// interval)` turned "03:45" into 0, so the duration was nil
    /// and the 30 s-preview asset check — which needs a non-nil
    /// expected duration — went blind for script-found songs: a
    /// trial clip could play as if it were the full song. A numeric
    /// `interval` is seconds too (no script returns ms durations
    /// in search results); "00:00" is nil, not 0.
    static func scriptDurationSeconds(_ map: [String: Any]) -> TimeInterval? {
        let durationSeconds = MusicAPIJSON.asDouble(map["duration"])
        if durationSeconds > 0 {
            return durationSeconds
        }
        let intervalSeconds = MusicAPIJSON.asDouble(map["interval"])
        if intervalSeconds > 0 {
            return intervalSeconds
        }
        let interval = MusicAPIJSON.asString(map["interval"])
        let rawParts = interval.split(separator: ":")
        guard rawParts.count == 2 || rawParts.count == 3 else { return nil }
        var parts: [Double] = []
        for raw in rawParts {
            guard let value = Double(raw) else { return nil }
            parts.append(value)
        }
        let seconds: Double
        if parts.count == 2 {
            seconds = parts[0] * 60 + parts[1]
        } else {
            seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
        }
        return seconds > 0 ? seconds : nil
    }

    // MARK: - Paged songs (b45-d: songs tab "load more")

    /// One extra songs page after the streamed first page.
    /// `page` is 1-based (1 = the second page of results). Each leg
    /// fetches its own next slice (wy offset, tx/kg page, kw pn);
    /// the merge is the same wy+tx-first order as the stream.
    /// Completion: merged tracks, any-leg-succeeded, any-leg-full.
    /// An empty page with no leg succeeding is a failure (retryable);
    /// an empty page with legs succeeding means exhausted.
    func searchSongsPage(keyword: String, page: Int, completion: @escaping ([MusicTrack], Bool, Bool) -> Void) {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, page >= 1 else { completion([], false, false); return }
        let mergeQueue = DispatchQueue(label: "com.haostudio.musicsearch.page")
        var results: [MusicTrack] = []
        var seenKeys = Set<String>()
        var anyOk = false
        var anyFull = false
        var remaining = 4
        let token = LXCancelToken()
        let timeoutWork = DispatchWorkItem { token.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.legTimeout, execute: timeoutWork)
        func legDone(_ tracks: [MusicTrack], _ ok: Bool, _ limit: Int) {
            mergeQueue.async {
                if ok { anyOk = true }
                if tracks.count >= limit { anyFull = true }
                for track in tracks {
                    let key: String
                    if track.id.isEmpty {
                        key = "t|\(MusicText.normalizeName(track.title))|\(MusicText.normalizeName(track.artist))"
                    } else {
                        key = track.dedupeKey
                    }
                    guard !seenKeys.contains(key) else { continue }
                    seenKeys.insert(key)
                    results.append(track)
                }
                remaining -= 1
                if remaining == 0 {
                    timeoutWork.cancel()
                    let merged = MusicSearchAPI.sortAndBackfill(results)
                    let ok = anyOk
                    let full = anyFull
                    DispatchQueue.main.async { completion(merged, ok, full) }
                }
            }
        }
        searchWyResult(query, limit: 20, offset: page * 20, token: token) { tracks, ok in legDone(tracks, ok, 20) }
        searchTxResult(query, limit: 20, page: page + 1, token: token) { tracks, ok in legDone(tracks, ok, 20) }
        searchKgResult(query, limit: 15, page: page + 1, token: token) { tracks, ok in legDone(tracks, ok, 15) }
        searchKwResult(query, limit: 15, page: page, token: token) { tracks, ok in legDone(tracks, ok, 15) }
    }

    // MARK: - Categories: artists / albums / playlists (b45-d)

    /// Which non-song result kind a category fetch returns. The
    /// search tab enum mirrors these cases (see MusicSearchViewModel).
    enum MusicSearchCategoryKind: String, CaseIterable {
        case artists
        case albums
        case playlists
    }

    /// Fan-out helper for one category kind: every leg reports
    /// (items, total, ok); when all settle, batches merge in
    /// platform-priority order (wy, tx, kg, kw) with platform+id
    /// dedupe, and the total is the first trustworthy one in that
    /// same order. A leg that fails contributes nothing and never
    /// kills the others.
    private func fetchCategory<Item>(
        legs: [(platform: MusicPlatform, fetch: (@escaping ([Item], Int?, Bool) -> Void) -> Void)],
        dedupeKey: @escaping (Item) -> String,
        completion: @escaping ([Item], Int?, Bool) -> Void
    ) {
        guard !legs.isEmpty else { completion([], nil, false); return }
        let sync = DispatchQueue(label: "com.haostudio.musicsearch.category")
        var batches: [(priority: Int, items: [Item])] = []
        var totals: [Int: Int] = [:]
        var anyOk = false
        var remaining = legs.count
        for leg in legs {
            leg.fetch { items, total, ok in
                sync.async {
                    if ok { anyOk = true }
                    if let total = total { totals[leg.platform.searchPriority] = total }
                    batches.append((leg.platform.searchPriority, items))
                    remaining -= 1
                    if remaining == 0 {
                        var seen = Set<String>()
                        var merged: [Item] = []
                        for batch in batches.sorted(by: { $0.priority < $1.priority }) {
                            for item in batch.items {
                                let key = dedupeKey(item)
                                guard !key.isEmpty, !seen.contains(key) else { continue }
                                seen.insert(key)
                                merged.append(item)
                            }
                        }
                        let total = totals.keys.sorted().first.flatMap { totals[$0] }
                        let ok = anyOk
                        DispatchQueue.main.async { completion(merged, total, ok) }
                    }
                }
            }
        }
    }

    /// Artists for one page. NetEase cloudsearch type 100 (total
    /// trusted); QQ zhida single direct hit (no artist list exists
    /// on search_for_qq_cp — the Lite endpoint returned empty for
    /// every search_type, so QQ contributes at most one artist);
    /// Kugou v3/search/singer (no portrait in the payload — cover
    /// stays empty, no URL invented); Kuwo r.s ft=artist (TOTAL
    /// trusted, PICPATH under BASEPICPATH).
    func searchArtists(keyword: String, limit: Int, offset: Int, completion: @escaping ([ArtistSummary], Int?, Bool) -> Void) {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { completion([], nil, false); return }
        fetchCategory(
            legs: [
                (.wy, { done in self.searchWyArtists(keyword: query, limit: limit, offset: offset, completion: done) }),
                (.tx, { done in self.searchTxZhidaArtist(keyword: query, offset: offset, completion: done) }),
                (.kg, { done in self.searchKgArtists(keyword: query, limit: limit, offset: offset, completion: done) }),
                (.kw, { done in self.searchKwArtists(keyword: query, limit: limit, offset: offset, completion: done) }),
            ],
            dedupeKey: { $0.id.isEmpty ? "name|\($0.name.lowercased())" : "\($0.platform.rawValue)|\($0.id)" },
            completion: completion)
    }

    /// Albums for one page. NetEase cloudsearch type 10 (total
    /// trusted); QQ search_for_qq_cp t=8 (totalnum echoes the song
    /// total — never trusted); Kugou v3/search/album (data.total is
    /// a 500 cap, not a count); Kuwo r.s ft=album (no TOTAL).
    func searchAlbums(keyword: String, limit: Int, offset: Int, completion: @escaping ([AlbumSummary], Int?, Bool) -> Void) {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { completion([], nil, false); return }
        fetchCategory(
            legs: [
                (.wy, { done in self.searchWyAlbums(keyword: query, limit: limit, offset: offset, completion: done) }),
                (.tx, { done in self.searchTxAlbums(keyword: query, limit: limit, offset: offset, completion: done) }),
                (.kg, { done in self.searchKgAlbums(keyword: query, limit: limit, offset: offset, completion: done) }),
                (.kw, { done in self.searchKwAlbums(keyword: query, limit: limit, offset: offset, completion: done) }),
            ],
            dedupeKey: { $0.id.isEmpty ? "name|\($0.name.lowercased())|\($0.artist.lowercased())" : "\($0.platform.rawValue)|\($0.id)" },
            completion: completion)
    }

    /// Playlists for one page. NetEase cloudsearch type 1000 (total
    /// trusted); Kugou v3/search/special (pagesize capped at 30);
    /// Kuwo r.s ft=playlist (TOTAL trusted). QQ has no verified
    /// no-login playlist endpoint (DoSearchForQQMusicLite returned
    /// empty for every search_type), so QQ contributes none.
    func searchPlaylists(keyword: String, limit: Int, offset: Int, completion: @escaping ([PlaylistSummary], Int?, Bool) -> Void) {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { completion([], nil, false); return }
        fetchCategory(
            legs: [
                (.wy, { done in self.searchWyPlaylists(keyword: query, limit: limit, offset: offset, completion: done) }),
                (.kg, { done in self.searchKgPlaylists(keyword: query, limit: limit, offset: offset, completion: done) }),
                (.kw, { done in self.searchKwPlaylists(keyword: query, limit: limit, offset: offset, completion: done) }),
            ],
            dedupeKey: { $0.id.isEmpty ? "name|\($0.name.lowercased())|\($0.creator.lowercased())" : "\($0.platform.rawValue)|\($0.id)" },
            completion: completion)
    }

    // MARK: - Category legs: NetEase

    private func searchWyArtists(keyword: String, limit: Int, offset: Int, completion: @escaping ([ArtistSummary], Int?, Bool) -> Void) {
        client.postFormJson(
            "https://music.163.com/api/cloudsearch/pc",
            fields: ["s": keyword, "type": "100", "limit": "\(limit)", "offset": "\(offset)", "total": "true"],
            headers: ["User-Agent": MusicUA.value],
            timeout: 5
        ) { json in
            guard let json = json else { completion([], nil, false); return }
            let result = MusicAPIJSON.asMap(json["result"])
            let artists = MusicAPIJSON.asList(result?["artists"]).compactMap { x -> ArtistSummary? in
                let name = MusicAPIJSON.asString(x["name"])
                guard !name.isEmpty else { return nil }
                let aliases = x["alias"] as? [String] ?? []
                return ArtistSummary(
                    id: MusicAPIJSON.asString(x["id"]),
                    name: name,
                    cover: MusicText.coverHi(MusicAPIJSON.asString(x["picUrl"]), platform: "wy"),
                    musicSize: MusicAPIJSON.asInt(x["musicSize"]),
                    albumSize: MusicAPIJSON.asInt(x["albumSize"]),
                    platform: .wy,
                    alias: aliases.first ?? "")
            }
            completion(artists, Self.optionalTotal(result?["artistCount"]), true)
        }
    }

    private func searchWyAlbums(keyword: String, limit: Int, offset: Int, completion: @escaping ([AlbumSummary], Int?, Bool) -> Void) {
        client.postFormJson(
            "https://music.163.com/api/cloudsearch/pc",
            fields: ["s": keyword, "type": "10", "limit": "\(limit)", "offset": "\(offset)", "total": "true"],
            headers: ["User-Agent": MusicUA.value],
            timeout: 5
        ) { json in
            guard let json = json else { completion([], nil, false); return }
            let result = MusicAPIJSON.asMap(json["result"])
            let albums = MusicAPIJSON.asList(result?["albums"]).compactMap { x -> AlbumSummary? in
                let name = MusicAPIJSON.asString(x["name"])
                guard !name.isEmpty else { return nil }
                let artist = MusicAPIJSON.asMap(x["artist"])
                return AlbumSummary(
                    id: MusicAPIJSON.asString(x["id"]),
                    name: name,
                    cover: MusicText.coverHi(MusicAPIJSON.asString(x["picUrl"]), platform: "wy"),
                    artist: MusicAPIJSON.asString(artist?["name"]),
                    publishTime: MusicAPIJSON.asInt(x["publishTime"]),
                    songCount: MusicAPIJSON.asInt(x["size"]),
                    platform: .wy)
            }
            completion(albums, Self.optionalTotal(result?["albumCount"]), true)
        }
    }

    private func searchWyPlaylists(keyword: String, limit: Int, offset: Int, completion: @escaping ([PlaylistSummary], Int?, Bool) -> Void) {
        client.postFormJson(
            "https://music.163.com/api/cloudsearch/pc",
            fields: ["s": keyword, "type": "1000", "limit": "\(limit)", "offset": "\(offset)", "total": "true"],
            headers: ["User-Agent": MusicUA.value],
            timeout: 5
        ) { json in
            guard let json = json else { completion([], nil, false); return }
            let result = MusicAPIJSON.asMap(json["result"])
            let lists = MusicAPIJSON.asList(result?["playlists"]).compactMap { x -> PlaylistSummary? in
                let name = MusicAPIJSON.asString(x["name"])
                guard !name.isEmpty else { return nil }
                let creator = MusicAPIJSON.asMap(x["creator"])
                return PlaylistSummary(
                    id: MusicAPIJSON.asString(x["id"]),
                    name: name,
                    cover: MusicText.coverHi(MusicAPIJSON.asString(x["coverImgUrl"]), platform: "wy"),
                    creator: MusicAPIJSON.asString(creator?["nickname"]),
                    playCount: MusicAPIJSON.asInt(x["playCount"]),
                    trackCount: MusicAPIJSON.asInt(x["trackCount"]),
                    platform: .wy)
            }
            completion(lists, Self.optionalTotal(result?["playlistCount"]), true)
        }
    }

    // MARK: - Category legs: QQ

    private func searchTxAlbums(keyword: String, limit: Int, offset: Int, completion: @escaping ([AlbumSummary], Int?, Bool) -> Void) {
        let page = offset / max(limit, 1) + 1
        client.getJson(
            "https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp",
            query: [
                "g_tk": "5381", "uin": "0", "format": "json",
                "inCharset": "utf-8", "outCharset": "utf-8", "notice": "0",
                "platform": "h5", "needNewCode": "1", "w": keyword,
                "zhidaqu": "1", "catZhida": "1", "t": "8", "flag": "1",
                "ie": "utf-8", "sem": "1", "aggr": "0",
                "perpage": "\(limit)", "n": "\(limit)", "p": "\(page)",
                "remoteplace": "txt.mqq.all",
            ],
            headers: ["Referer": "https://y.qq.com/", "User-Agent": MusicUA.value],
            timeout: 5
        ) { json in
            guard let json = json else { completion([], nil, false); return }
            let data = MusicAPIJSON.asMap(json["data"])
            let album = MusicAPIJSON.asMap(data?["album"])
            let albums = MusicAPIJSON.asList(album?["list"]).compactMap { x -> AlbumSummary? in
                let mid = MusicAPIJSON.asString(x["albumMID"])
                let name = MusicAPIJSON.asString(x["albumName"])
                guard !mid.isEmpty, !name.isEmpty else { return nil }
                return AlbumSummary(
                    id: mid,
                    name: name,
                    cover: MusicText.coverHi("https://y.gtimg.cn/music/photo_new/T002R300x300M000\(mid).jpg", platform: "tx"),
                    artist: MusicAPIJSON.asString(x["singerName"]),
                    publishTime: Self.millis(from: MusicAPIJSON.asString(x["publicTime"]), format: "yyyy-MM-dd"),
                    songCount: 0,
                    platform: .tx)
            }
            // data.album.totalnum echoes the song total (verified
            // 600 on a 2-item page) — never trusted for hasMore.
            completion(albums, nil, true)
        }
    }

    /// QQ zhida direct artist hit from the song search payload:
    /// type 2 = singer, with singermid/singername/songnum/albumnum.
    /// At most one artist; deep pages contribute nothing.
    private func searchTxZhidaArtist(keyword: String, offset: Int, completion: @escaping ([ArtistSummary], Int?, Bool) -> Void) {
        guard offset == 0 else { completion([], nil, true); return }
        client.getJson(
            "https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp",
            query: [
                "g_tk": "5381", "uin": "0", "format": "json",
                "inCharset": "utf-8", "outCharset": "utf-8", "notice": "0",
                "platform": "h5", "needNewCode": "1", "w": keyword,
                "zhidaqu": "1", "catZhida": "1", "t": "0", "flag": "1",
                "ie": "utf-8", "sem": "1", "aggr": "0",
                "perpage": "1", "n": "1", "p": "1",
                "remoteplace": "txt.mqq.all",
            ],
            headers: ["Referer": "https://y.qq.com/", "User-Agent": MusicUA.value],
            timeout: 5
        ) { json in
            guard let json = json else { completion([], nil, false); return }
            let data = MusicAPIJSON.asMap(json["data"])
            let zhida = MusicAPIJSON.asMap(data?["zhida"])
            guard MusicAPIJSON.asInt(zhida?["type"]) == 2 else { completion([], nil, true); return }
            let mid = MusicAPIJSON.asString(zhida?["singermid"])
            let name = MusicAPIJSON.asString(zhida?["singername"])
            guard !mid.isEmpty, !name.isEmpty else { completion([], nil, true); return }
            let artist = ArtistSummary(
                id: mid,
                name: name,
                cover: MusicText.coverHi("https://y.gtimg.cn/music/photo_new/T001R300x300M000\(mid).jpg", platform: "tx"),
                musicSize: MusicAPIJSON.asInt(zhida?["songnum"]),
                albumSize: MusicAPIJSON.asInt(zhida?["albumnum"]),
                platform: .tx)
            completion([artist], nil, true)
        }
    }

    // MARK: - Category legs: Kugou

    private func searchKgArtists(keyword: String, limit: Int, offset: Int, completion: @escaping ([ArtistSummary], Int?, Bool) -> Void) {
        let page = offset / max(limit, 1) + 1
        client.getJson(
            "https://mobileservice.kugou.com/api/v3/search/singer",
            query: ["keyword": keyword, "page": "\(page)", "pagesize": "\(limit)"],
            headers: ["User-Agent": MusicUA.value],
            timeout: 5
        ) { json in
            guard let json = json else { completion([], nil, false); return }
            // The singer list carries no portrait in this payload —
            // the card shows a placeholder cover (no URL invented).
            let artists = MusicAPIJSON.asList(json["data"]).compactMap { x -> ArtistSummary? in
                let name = MusicAPIJSON.asString(x["singername"])
                let id = MusicAPIJSON.asString(x["singerid"])
                guard !name.isEmpty, !id.isEmpty else { return nil }
                return ArtistSummary(id: id, name: name, cover: "", platform: .kg)
            }
            completion(artists, nil, true)
        }
    }

    private func searchKgAlbums(keyword: String, limit: Int, offset: Int, completion: @escaping ([AlbumSummary], Int?, Bool) -> Void) {
        let page = offset / max(limit, 1) + 1
        client.getJson(
            "https://mobileservice.kugou.com/api/v3/search/album",
            query: ["keyword": keyword, "page": "\(page)", "pagesize": "\(limit)"],
            headers: ["User-Agent": MusicUA.value],
            timeout: 5
        ) { json in
            guard let json = json else { completion([], nil, false); return }
            let data = MusicAPIJSON.asMap(json["data"])
            let albums = MusicAPIJSON.asList(data?["info"]).compactMap { x -> AlbumSummary? in
                let name = MusicAPIJSON.asString(x["albumname"])
                let id = MusicAPIJSON.asString(x["albumid"])
                guard !name.isEmpty, !id.isEmpty else { return nil }
                return AlbumSummary(
                    id: id,
                    name: name,
                    cover: MusicText.coverHi(Self.kgSizedImage(MusicAPIJSON.asString(x["imgurl"])), platform: "kg"),
                    artist: MusicAPIJSON.asString(x["singername"]),
                    publishTime: Self.millis(from: MusicAPIJSON.asString(x["publishtime"]), format: "yyyy-MM-dd HH:mm:ss"),
                    songCount: MusicAPIJSON.asInt(x["songcount"]),
                    platform: .kg)
            }
            // data.total reads 500 for most queries (a cap, not a
            // count) — hasMore falls back to "full page".
            completion(albums, nil, true)
        }
    }

    private func searchKgPlaylists(keyword: String, limit: Int, offset: Int, completion: @escaping ([PlaylistSummary], Int?, Bool) -> Void) {
        // Playlist pages cap at 30 per request.
        let pageSize = min(max(limit, 1), 30)
        let page = offset / pageSize + 1
        client.getJson(
            "https://mobileservice.kugou.com/api/v3/search/special",
            query: ["keyword": keyword, "page": "\(page)", "pagesize": "\(pageSize)"],
            headers: ["User-Agent": MusicUA.value],
            timeout: 5
        ) { json in
            guard let json = json else { completion([], nil, false); return }
            let data = MusicAPIJSON.asMap(json["data"])
            let lists = MusicAPIJSON.asList(data?["info"]).compactMap { x -> PlaylistSummary? in
                let name = MusicAPIJSON.asString(x["specialname"])
                let id = MusicAPIJSON.asString(x["specialid"])
                guard !name.isEmpty, !id.isEmpty else { return nil }
                return PlaylistSummary(
                    id: id,
                    name: name,
                    cover: MusicText.coverHi(Self.kgSizedImage(MusicAPIJSON.asString(x["imgurl"])), platform: "kg"),
                    creator: MusicAPIJSON.asString(x["nickname"]),
                    playCount: MusicAPIJSON.asInt(x["playcount"]),
                    trackCount: MusicAPIJSON.asInt(x["songcount"]),
                    platform: .kg)
            }
            completion(lists, nil, true)
        }
    }

    // MARK: - Category legs: Kuwo

    /// Kuwo r.s is single-quoted pseudo-JSON (same swap as
    /// `parseKwSongs`); the swapped text decodes as a normal object.
    private static func parseKwCategoryJSON(_ text: String) -> [String: Any]? {
        let swapped = text.replacingOccurrences(of: "'", with: "\"")
        return MusicJSON.object(from: swapped) as? [String: Any]
    }

    private func searchKwArtists(keyword: String, limit: Int, offset: Int, completion: @escaping ([ArtistSummary], Int?, Bool) -> Void) {
        let page = offset / max(limit, 1)
        let url = "https://search.kuwo.cn/r.s?all=\(MusicAPIClient.percentEncode(keyword))&ft=artist&rformat=json&encoding=utf8&rn=\(limit)&pn=\(page)"
        client.getText(url, headers: ["User-Agent": MusicUA.value], timeout: 5) { text in
            guard let text = text, let decoded = Self.parseKwCategoryJSON(text) else { completion([], nil, false); return }
            let basePic = MusicAPIJSON.asString(decoded["BASEPICPATH"])
            let artists = MusicAPIJSON.asList(decoded["abslist"]).compactMap { x -> ArtistSummary? in
                let name = MusicText.decodeEntities(MusicAPIJSON.asString(x["ARTIST"]))
                let id = MusicAPIJSON.asString(x["ARTISTID"])
                guard !name.isEmpty, !id.isEmpty else { return nil }
                let picPath = MusicAPIJSON.asString(x["PICPATH"])
                let cover = picPath.isEmpty ? "" : MusicText.coverHi(basePic + picPath, platform: "kw")
                return ArtistSummary(
                    id: id,
                    name: name,
                    cover: cover,
                    musicSize: MusicAPIJSON.asInt(x["SONGNUM"]),
                    albumSize: MusicAPIJSON.asInt(x["ALBUMNUM"]),
                    platform: .kw)
            }
            completion(artists, Self.optionalTotal(decoded["TOTAL"]), true)
        }
    }

    private func searchKwAlbums(keyword: String, limit: Int, offset: Int, completion: @escaping ([AlbumSummary], Int?, Bool) -> Void) {
        let page = offset / max(limit, 1)
        let url = "https://search.kuwo.cn/r.s?all=\(MusicAPIClient.percentEncode(keyword))&ft=album&rformat=json&encoding=utf8&rn=\(limit)&pn=\(page)"
        client.getText(url, headers: ["User-Agent": MusicUA.value], timeout: 5) { text in
            guard let text = text, let decoded = Self.parseKwCategoryJSON(text) else { completion([], nil, false); return }
            let albums = MusicAPIJSON.asList(decoded["albumlist"]).compactMap { x -> AlbumSummary? in
                let name = MusicText.decodeEntities(MusicAPIJSON.asString(x["name"]))
                let id = MusicAPIJSON.asString(x["albumid"])
                guard !name.isEmpty, !id.isEmpty else { return nil }
                var cover = MusicAPIJSON.asString(x["hts_img"])
                if cover.isEmpty { cover = MusicAPIJSON.asString(x["img"]) }
                if cover.isEmpty {
                    let pic = MusicAPIJSON.asString(x["pic"])
                    if !pic.isEmpty { cover = "https://img1.kuwo.cn/star/albumcover/\(pic)" }
                }
                return AlbumSummary(
                    id: id,
                    name: name,
                    cover: MusicText.coverHi(cover, platform: "kw"),
                    artist: MusicText.decodeEntities(MusicAPIJSON.asString(x["artist"])),
                    publishTime: Self.millis(from: MusicAPIJSON.asString(x["pub"]), format: "yyyy-MM-dd"),
                    songCount: MusicAPIJSON.asInt(x["musiccnt"]),
                    platform: .kw)
            }
            // No TOTAL in the album payload — hasMore falls back to
            // "full page".
            completion(albums, nil, true)
        }
    }

    private func searchKwPlaylists(keyword: String, limit: Int, offset: Int, completion: @escaping ([PlaylistSummary], Int?, Bool) -> Void) {
        let page = offset / max(limit, 1)
        let url = "https://search.kuwo.cn/r.s?all=\(MusicAPIClient.percentEncode(keyword))&ft=playlist&rformat=json&encoding=utf8&rn=\(limit)&pn=\(page)"
        client.getText(url, headers: ["User-Agent": MusicUA.value], timeout: 5) { text in
            guard let text = text, let decoded = Self.parseKwCategoryJSON(text) else { completion([], nil, false); return }
            let lists = MusicAPIJSON.asList(decoded["abslist"]).compactMap { x -> PlaylistSummary? in
                let name = MusicText.decodeEntities(MusicAPIJSON.asString(x["name"]))
                let id = MusicAPIJSON.asString(x["playlistid"])
                guard !name.isEmpty, !id.isEmpty else { return nil }
                var cover = MusicAPIJSON.asString(x["hts_pic"])
                if cover.isEmpty { cover = MusicAPIJSON.asString(x["pic"]) }
                return PlaylistSummary(
                    id: id,
                    name: name,
                    cover: MusicText.coverHi(cover, platform: "kw"),
                    creator: MusicText.decodeEntities(MusicAPIJSON.asString(x["nickname"])),
                    playCount: MusicAPIJSON.asInt(x["playcnt"]),
                    trackCount: MusicAPIJSON.asInt(x["songnum"]),
                    platform: .kw)
            }
            completion(lists, Self.optionalTotal(decoded["TOTAL"]), true)
        }
    }

    // MARK: - Suggestions + hot keywords (b45-d)

    /// Suggestion words for the typed query, merged wy -> tx -> kg
    /// (Kuwo has no verified suggestion endpoint and contributes
    /// nothing). De-duplicated, without the query itself, capped
    /// at 8.
    func searchSuggestions(keyword: String, completion: @escaping ([String]) -> Void) {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { completion([]); return }
        let sync = DispatchQueue(label: "com.haostudio.musicsearch.suggest")
        var byPlatform: [Int: [String]] = [:]
        var remaining = 3
        func legDone(_ priority: Int, _ words: [String]) {
            sync.async {
                byPlatform[priority] = words
                remaining -= 1
                if remaining == 0 {
                    var merged: [String] = []
                    for priority in byPlatform.keys.sorted() {
                        merged.append(contentsOf: byPlatform[priority] ?? [])
                    }
                    let unique = Self.uniqueSuggestionWords(merged, excluding: query)
                    DispatchQueue.main.async { completion(unique) }
                }
            }
        }
        // NetEase /search/suggest/web: names in songs -> artists ->
        // albums -> playlists order.
        client.postFormJson(
            "https://music.163.com/api/search/suggest/web",
            fields: ["s": query],
            headers: ["User-Agent": MusicUA.value],
            timeout: 5
        ) { json in
            guard let json = json else { legDone(0, []); return }
            let result = MusicAPIJSON.asMap(json["result"])
            var words: [String] = []
            for key in ["songs", "artists", "albums", "playlists"] {
                for item in MusicAPIJSON.asList(result?[key]) {
                    words.append(MusicAPIJSON.asString(item["name"]))
                }
            }
            legDone(0, words)
        }
        // QQ smartbox: song / album / singer itemlists.
        client.getJson(
            "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg",
            query: ["is_xml": "0", "key": query],
            headers: ["Referer": "https://y.qq.com/", "User-Agent": MusicUA.value],
            timeout: 5
        ) { json in
            guard let json = json else { legDone(1, []); return }
            let data = MusicAPIJSON.asMap(json["data"])
            var words: [String] = []
            for key in ["song", "album", "singer"] {
                let group = MusicAPIJSON.asMap(data?[key])
                for item in MusicAPIJSON.asList(group?["itemlist"]) {
                    words.append(MusicAPIJSON.asString(item["name"]))
                }
            }
            legDone(1, words)
        }
        // Kugou searchtip host: data[].RecordDatas[].HintInfo.
        // (The plan's v2/getSearchTip path on songsearch.kugou.com
        // is a 404 — the live host is searchtip.kugou.com.)
        client.getJson(
            "https://searchtip.kugou.com/getSearchTip",
            query: ["MusicTipCount": "5", "keyword": query],
            headers: ["User-Agent": MusicUA.value],
            timeout: 5
        ) { json in
            guard let json = json else { legDone(2, []); return }
            var words: [String] = []
            for group in MusicAPIJSON.asList(json["data"]) {
                for record in MusicAPIJSON.asList(group["RecordDatas"]) {
                    words.append(MusicAPIJSON.asString(record["HintInfo"]))
                }
            }
            legDone(2, words)
        }
    }

    /// Hot keywords for an empty query: NetEase default keyword
    /// (one) + QQ hotkeys + Kugou hot words, de-duplicated, capped
    /// at 8.
    func hotKeywords(completion: @escaping ([String]) -> Void) {
        let sync = DispatchQueue(label: "com.haostudio.musicsearch.hot")
        var byPlatform: [Int: [String]] = [:]
        var remaining = 3
        func legDone(_ priority: Int, _ words: [String]) {
            sync.async {
                byPlatform[priority] = words
                remaining -= 1
                if remaining == 0 {
                    var merged: [String] = []
                    for priority in byPlatform.keys.sorted() {
                        merged.append(contentsOf: byPlatform[priority] ?? [])
                    }
                    let unique = Self.uniqueSuggestionWords(merged, excluding: "")
                    DispatchQueue.main.async { completion(unique) }
                }
            }
        }
        client.getJson(
            "https://music.163.com/api/search/defaultkeyword/get",
            headers: ["User-Agent": MusicUA.value],
            timeout: 5
        ) { json in
            guard let json = json else { legDone(0, []); return }
            let data = MusicAPIJSON.asMap(json["data"])
            legDone(0, [MusicAPIJSON.asString(data?["realkeyword"])])
        }
        client.getJson(
            "https://c.y.qq.com/splcloud/fcgi-bin/gethotkey.fcg",
            query: ["g_tk": "5381"],
            headers: ["Referer": "https://y.qq.com/", "User-Agent": MusicUA.value],
            timeout: 5
        ) { json in
            guard let json = json else { legDone(1, []); return }
            let data = MusicAPIJSON.asMap(json["data"])
            legDone(1, MusicAPIJSON.asList(data?["hotkey"]).map { MusicAPIJSON.asString($0["k"]) })
        }
        client.getJson(
            "https://mobileservice.kugou.com/api/v3/search/hot",
            query: ["format": "json", "plat": "0"],
            headers: ["User-Agent": MusicUA.value],
            timeout: 5
        ) { json in
            guard let json = json else { legDone(2, []); return }
            let data = MusicAPIJSON.asMap(json["data"])
            legDone(2, MusicAPIJSON.asList(data?["info"]).map { MusicAPIJSON.asString($0["keyword"]) })
        }
    }

    /// Drop empties, drop the query itself, string-dedupe, cap 8.
    static func uniqueSuggestionWords(_ words: [String], excluding keyword: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let lowerKeyword = keyword.lowercased()
        for raw in words {
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, word.lowercased() != lowerKeyword else { continue }
            let key = word.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(word)
            if out.count >= 8 { break }
        }
        return out
    }

    // MARK: - Category helpers (b45-d)

    /// A total that is only trusted when the payload actually
    /// carries a number (or a numeric string): a missing total is
    /// nil, never 0 — 0 would wrongly end pagination.
    static func optionalTotal(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let parsed = Int(string) { return parsed }
        return nil
    }

    /// Milliseconds since epoch for a "yyyy-MM-dd" / "yyyy-MM-dd
    /// HH:mm:ss" date string; 0 when unparseable.
    static func millis(from dateString: String, format: String) -> Int {
        guard !dateString.isEmpty else { return 0 }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        guard let date = formatter.date(from: dateString) else { return 0 }
        return Int(date.timeIntervalSince1970 * 1000)
    }

    /// Kugou image URLs carry a `{size}` placeholder; 400 is the
    /// card size used by this UI.
    static func kgSizedImage(_ url: String, size: Int = 400) -> String {
        url.replacingOccurrences(of: "{size}", with: "\(size)")
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

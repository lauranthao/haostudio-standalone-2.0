// MusicPlaylistImportAPI.swift
// Playlist plaza + playlist import from pasted public links.
//
// - Plaza: wy (personalized), tx (diss-by-tag), kg (special search),
//   kw (playlist search for 热门). Fetch ONLY the given platform —
//   never silently fall back.
// - Import: wy (`/api/v6/playlist/detail` + `/api/playlist/detail`
//   fallback, then `/api/song/detail/` in chunks of 100), tx
//   (`fcg_ucc_getcdinfo_byids_cp.fcg`), kw (`nplserver.kuwo.cn/pl.svc`,
//   up to 10 pages of 100), kg special (`mobilecdn …/special/song`,
//   name from the special-page title), kg user playlist
//   (`m.kugou.com/plist/list/<id>`).
// - Kugou shared playlists (`m3ws.kugou.com/v2/zlist/list`) need a
//   signed request. The signing secret was REMOVED from source
//   (P0-15) and is deliberately NOT reproduced anywhere in this
//   codebase: `kugouSign` returns nil, and a shared-playlist import
//   fails EXPLICITLY with a note ("需要 Kugou 签名"), never silently
//   and never with a hardcoded secret. The other Kugou import paths
//   (special / user playlist) do not need the signature and work.
// - Import pages retry once after 800 ms on a null fetch.
// - `importFromLink` follows short-link redirects manually (up to 5
//   hops) because the playlist id often sits in an intermediate
//   Location header.

import Foundation

final class MusicPlaylistImportAPI {
    static let shared = MusicPlaylistImportAPI()

    private let client: MusicAPIClient

    init(client: MusicAPIClient = .shared) {
        self.client = client
    }

    // MARK: - Kugou signing (removed — see file header)

    /// Kugou web-API signature. The secret was removed from source
    /// (P0-15) and is not reproduced anywhere: this always returns
    /// nil. Callers that need a signature (shared-playlist import)
    /// fail explicitly with a note instead of signing.
    static func kugouSign(params: [String: String]) -> String? {
        _ = params
        return nil
    }

    // MARK: - Plaza

    /// Fetch ONLY the given platform (never silently fall back).
    func plaza(platform: MusicPlatform, completion: @escaping ([PlaylistSummary]) -> Void) {
        switch platform {
        case .wy: plazaWy(completion: completion)
        case .tx: plazaTx(completion: completion)
        case .kg: plazaKg(completion: completion)
        case .kw: plazaKw(completion: completion)
        case .mg: completion([])
        }
    }

    /// NetEase: personalized playlists, 30.
    func plazaWy(completion: @escaping ([PlaylistSummary]) -> Void) {
        client.getJson(
            "https://music.163.com/api/personalized/playlist?limit=30",
            headers: ["User-Agent": MusicUA.value]
        ) { json in
            guard let json = json else { completion([]); return }
            completion(MusicAPIJSON.asList(json["result"]).compactMap { x in
                let summary = PlaylistSummary(
                    id: MusicAPIJSON.asString(x["id"]),
                    name: MusicAPIJSON.asString(x["name"]),
                    cover: MusicText.coverHi(MusicAPIJSON.asString(x["picUrl"]), platform: "wy"),
                    playCount: MusicAPIJSON.asInt(x["playCount"]),
                    trackCount: MusicAPIJSON.asInt(x["trackCount"]),
                    desc: MusicAPIJSON.asString(x["copywriter"]),
                    platform: .wy)
                guard !summary.id.isEmpty, !summary.name.isEmpty else { return nil }
                return summary
            })
        }
    }

    /// QQ: diss-by-tag, category 10000000, 30 items.
    func plazaTx(completion: @escaping ([PlaylistSummary]) -> Void) {
        let rnd = Int(Date().timeIntervalSince1970 * 1000) % 1_000_000_000
        client.getJson(
            "https://c.y.qq.com/splcloud/fcgi-bin/fcg_get_diss_by_tag.fcg",
            query: [
                "picmid": "1", "rnd": "\(rnd)", "g_tk": "5381",
                "loginUin": "0", "hostUin": "0", "format": "json",
                "inCharset": "utf8", "outCharset": "utf-8", "notice": "0",
                "platform": "yqq.json", "needNewCode": "0",
                "categoryId": "10000000", "sortId": "5", "sin": "0", "ein": "29",
            ],
            headers: ["Referer": "https://y.qq.com/", "User-Agent": MusicUA.value]
        ) { json in
            guard let json = json else { completion([]); return }
            let data = MusicAPIJSON.asMap(json["data"]) ?? [:]
            completion(MusicAPIJSON.asList(data["list"]).compactMap { x in
                let creator = MusicAPIJSON.asMap(x["creator"])
                let summary = PlaylistSummary(
                    id: MusicAPIJSON.asString(x["dissid"]),
                    name: MusicText.decodeEntities(MusicAPIJSON.asString(x["dissname"])),
                    cover: MusicText.coverHi(MusicAPIJSON.asString(x["imgurl"]), platform: "tx"),
                    creator: MusicAPIJSON.asString(creator?["name"]),
                    playCount: MusicAPIJSON.asInt(x["listennum"]),
                    desc: MusicAPIJSON.asString(x["introduction"]),
                    platform: .tx)
                guard !summary.id.isEmpty, !summary.name.isEmpty else { return nil }
                return summary
            })
        }
    }

    /// Kugou: special search for 热门, 30.
    func plazaKg(completion: @escaping ([PlaylistSummary]) -> Void) {
        client.getJson(
            "http://mobilecdn.kugou.com/api/v3/search/special?format=json&keyword=%E7%83%AD%E9%97%A8&page=1&pagesize=30&showtype=1",
            headers: ["User-Agent": MusicUA.value]
        ) { json in
            guard let json = json else { completion([]); return }
            let data = MusicAPIJSON.asMap(json["data"]) ?? [:]
            completion(MusicAPIJSON.asList(data["info"]).compactMap { x in
                let summary = PlaylistSummary(
                    id: MusicAPIJSON.asString(x["specialid"]),
                    name: MusicAPIJSON.asString(x["specialname"]),
                    cover: MusicText.coverHi(
                        MusicAPIJSON.asString(x["imgurl"]).replacingOccurrences(of: "{size}", with: "400"),
                        platform: "kg"),
                    creator: MusicAPIJSON.asString(x["nickname"]),
                    playCount: MusicAPIJSON.asInt(x["playcount"]),
                    trackCount: MusicAPIJSON.asInt(x["songcount"]),
                    desc: MusicAPIJSON.asString(x["intro"]),
                    time: MusicAPIJSON.asString(x["publishtime"]),
                    platform: .kg)
                guard !summary.id.isEmpty, !summary.name.isEmpty else { return nil }
                return summary
            })
        }
    }

    /// Kuwo: playlist search for 热门.
    func plazaKw(completion: @escaping ([PlaylistSummary]) -> Void) {
        searchKwPlaylists("热门", page: 1) { result in
            completion(result.items)
        }
    }

    /// Kuwo playlist search (r.s ft=playlist — used by the plaza).
    /// JSON path after quote-swap, then the regex fallback.
    func searchKwPlaylists(_ query: String, page: Int, completion: @escaping ((items: [PlaylistSummary], total: Int)) -> Void) {
        let url = "https://search.kuwo.cn/r.s?all=\(MusicAPIClient.percentEncode(query))&ft=playlist&rformat=json&encoding=utf8&rn=30&pn=\(page - 1)"
        client.getText(url, headers: ["User-Agent": MusicUA.value]) { text in
            guard let text = text else { completion(([], 0)); return }
            completion(MusicPlaylistImportAPI.parseKwPlaylists(text))
        }
    }

    /// Kuwo r.s ft=playlist payload -> (items, total). Pure function.
    static func parseKwPlaylists(_ text: String) -> (items: [PlaylistSummary], total: Int) {
        var list: [[String: Any]] = []
        var total = 0
        let swapped = text.replacingOccurrences(of: "'", with: "\"")
        if let decoded = MusicJSON.object(from: swapped) as? [String: Any] {
            list = MusicAPIJSON.asList(decoded["abslist"])
            total = MusicAPIJSON.asInt(decoded["TOTAL"])
        } else {
            func matches(_ pattern: String) -> [String] {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
                let range = NSRange(text.startIndex..., in: text)
                return regex.matches(in: text, range: range).compactMap { match in
                    guard let r = Range(match.range(at: 1), in: text) else { return nil }
                    return String(text[r])
                }
            }
            let ids = matches("'DC_TARGETID':'(\\d+)'")
            let names = matches("'name':'((?:[^'\\\\]|\\\\.)*)'")
            let pics = matches("'hts_pic':'((?:[^'\\\\]|\\\\.)*)'")
            let pcs = matches("'playcnt':'(\\d+)'")
            let sns = matches("'songnum':'(\\d+)'")
            let nicks = matches("'nickname':'((?:[^'\\\\]|\\\\.)*)'")
            let intros = matches("'intro':'((?:[^'\\\\]|\\\\.)*)'")
            list = ids.enumerated().map { i, id in
                [
                    "DC_TARGETID": id,
                    "name": i < names.count ? names[i] : "",
                    "hts_pic": i < pics.count ? pics[i] : "",
                    "playcnt": i < pcs.count ? pcs[i] : "0",
                    "songnum": i < sns.count ? sns[i] : "0",
                    "nickname": i < nicks.count ? nicks[i] : "",
                    "intro": i < intros.count ? intros[i] : "",
                ] as [String: Any]
            }
        }
        let items = list.compactMap { x -> PlaylistSummary? in
            let summary = PlaylistSummary(
                id: MusicAPIJSON.firstString(x, keys: ["DC_TARGETID", "playlistid"]),
                name: MusicText.decodeEntities(MusicAPIJSON.asString(x["name"])),
                cover: MusicText.coverHi(
                    MusicAPIJSON.firstString(x, keys: ["hts_pic", "pic"]), platform: "kw"),
                creator: MusicAPIJSON.asString(x["nickname"]),
                playCount: MusicAPIJSON.asInt(x["playcnt"]),
                trackCount: MusicAPIJSON.asInt(x["songnum"]),
                desc: MusicAPIJSON.asString(x["intro"]),
                platform: .kw)
            guard !summary.id.isEmpty, !summary.name.isEmpty else { return nil }
            return summary
        }
        return (items, total)
    }

    // MARK: - Playlist search (wy)

    /// NetEase playlist search (QQ playlist search is rejected by
    /// its API — only wy + kw exist).
    func searchWyPlaylists(_ query: String, page: Int, completion: @escaping ((items: [PlaylistSummary], total: Int)) -> Void) {
        client.postFormJson(
            "https://music.163.com/api/cloudsearch/pc",
            fields: ["s": query, "type": "1000", "limit": "30", "offset": "\((page - 1) * 30)"],
            headers: ["User-Agent": MusicUA.value]
        ) { json in
            guard let json = json else { completion(([], 0)); return }
            let result = MusicAPIJSON.asMap(json["result"]) ?? [:]
            let total = MusicAPIJSON.asInt(result["playlistCount"])
            let items = MusicAPIJSON.asList(result["playlists"]).compactMap { x -> PlaylistSummary? in
                let creator = MusicAPIJSON.asMap(x["creator"])
                let summary = PlaylistSummary(
                    id: MusicAPIJSON.asString(x["id"]),
                    name: MusicAPIJSON.asString(x["name"]),
                    cover: MusicText.coverHi(MusicAPIJSON.asString(x["coverImgUrl"]), platform: "wy"),
                    creator: MusicAPIJSON.asString(creator?["nickname"]),
                    playCount: MusicAPIJSON.asInt(x["playCount"]),
                    trackCount: MusicAPIJSON.asInt(x["trackCount"]),
                    desc: MusicAPIJSON.asString(x["description"]),
                    platform: .wy)
                guard !summary.id.isEmpty, !summary.name.isEmpty else { return nil }
                return summary
            }
            completion((items, total))
        }
    }

    // MARK: - Import helpers

    /// Import page fetch with one retry after 800 ms. Returns nil
    /// only when both attempts fail. A cancelled token is never
    /// retried.
    private func importPageWithRetry(
        fetch: @escaping (@escaping ([String: Any]?) -> Void) -> Void,
        cancelToken: LXCancelToken?,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        fetch { json in
            if json != nil {
                completion(json)
                return
            }
            guard cancelToken?.isCancelled != true else { completion(nil); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(800)) {
                guard cancelToken?.isCancelled != true else { completion(nil); return }
                fetch(completion)
            }
        }
    }

    // MARK: - Import: NetEase

    /// NetEase playlist import. `missing` counts songs known to be
    /// missing; `note` is '' when the import is complete.
    func importWyPlaylist(
        _ id: String,
        onProgress: ((Int, Int?) -> Void)? = nil,
        cancelToken: LXCancelToken? = nil,
        completion: @escaping (ImportedPlaylist) -> Void
    ) {
        // One v6 detail fetch. Retry once (800 ms) whenever the first
        // attempt leaves us with no ids.
        func fetchV6(done: @escaping (String, [String], Bool) -> Void) {
            client.getJson("https://music.163.com/api/v6/playlist/detail?id=\(id)",
                           headers: ["User-Agent": MusicUA.value]) { json in
                let playlist = MusicAPIJSON.asMap(json?["playlist"]) ?? [:]
                let tids = MusicAPIJSON.asList(playlist["trackIds"]).map {
                    MusicAPIJSON.asString($0["id"])
                }.filter { !$0.isEmpty }
                done(MusicAPIJSON.asString(playlist["name"]), tids, json != nil)
            }
        }
        fetchV6 { name, tids, answered in
            var trackIds = tids
            var playlistName = name
            var wasAnswered = answered
            let proceed: () -> Void = { [weak self] in
                guard let self = self else { return }
                if trackIds.isEmpty && cancelToken?.isCancelled != true {
                    // v6 fallback: the old detail endpoint.
                    self.client.getJson("https://music.163.com/api/playlist/detail?id=\(id)",
                                        headers: ["User-Agent": MusicUA.value]) { json in
                        let playlist = MusicAPIJSON.asMap(json?["playlist"]) ?? [:]
                        if playlistName.isEmpty {
                            playlistName = MusicAPIJSON.asString(playlist["name"])
                        }
                        let fallbackIds = MusicAPIJSON.asList(playlist["trackIds"]).map {
                            MusicAPIJSON.asString($0["id"])
                        }.filter { !$0.isEmpty }
                        if !fallbackIds.isEmpty { trackIds = fallbackIds }
                        wasAnswered = wasAnswered || json != nil
                        self.importWyTracks(id: id, name: playlistName, trackIds: trackIds,
                                            answered: wasAnswered, onProgress: onProgress,
                                            cancelToken: cancelToken, completion: completion)
                    }
                    return
                }
                self.importWyTracks(id: id, name: playlistName, trackIds: trackIds,
                                    answered: wasAnswered, onProgress: onProgress,
                                    cancelToken: cancelToken, completion: completion)
            }
            if trackIds.isEmpty && cancelToken?.isCancelled != true {
                // v6 retry once when it left us with no ids.
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(800)) {
                    fetchV6 { retryName, retryIds, retryAnswered in
                        if !retryIds.isEmpty { trackIds = retryIds }
                        if playlistName.isEmpty { playlistName = retryName }
                        wasAnswered = wasAnswered || retryAnswered
                        proceed()
                    }
                }
            } else {
                proceed()
            }
        }
    }

    private func importWyTracks(
        id: String,
        name: String,
        trackIds: [String],
        answered: Bool,
        onProgress: ((Int, Int?) -> Void)?,
        cancelToken: LXCancelToken?,
        completion: @escaping (ImportedPlaylist) -> Void
    ) {
        guard !trackIds.isEmpty else {
            completion(ImportedPlaylist(
                name: name, tracks: [], platform: .wy, missing: 0,
                note: answered ? "歌单为空" : "歌单获取失败，无法得知曲目数量"))
            return
        }
        var out: [MusicTrack] = []
        var missing = 0
        var index = 0
        func nextChunk() {
            guard index < trackIds.count else {
                completion(ImportedPlaylist(name: name, tracks: out, platform: .wy,
                                            missing: missing, note: ""))
                return
            }
            if cancelToken?.isCancelled == true {
                completion(ImportedPlaylist(
                    name: name, tracks: out, platform: .wy,
                    missing: trackIds.count - out.count,
                    note: "已取消导入，已导入 \(out.count) 首"))
                return
            }
            let chunk = Array(trackIds[index..<min(index + 100, trackIds.count)])
            index += 100
            let idsParam = "[\(chunk.joined(separator: ","))]"
            let url = "https://music.163.com/api/song/detail/?ids=\(MusicAPIClient.percentEncode(idsParam))"
            importPageWithRetry(fetch: { done in
                self.client.getJson(url, headers: ["User-Agent": MusicUA.value]) { json in done(json) }
            }, cancelToken: cancelToken) { json in
                if let json = json {
                    let rawCount = MusicAPIJSON.asList(json["songs"]).count
                    out.append(contentsOf: Self.parseWySongDetail(json))
                    missing += chunk.count - rawCount
                } else {
                    missing += chunk.count
                }
                onProgress?(out.count, trackIds.count)
                nextChunk()
            }
        }
        nextChunk()
    }

    /// `/api/song/detail/` payload -> [MusicTrack]. Pure function.
    /// b40 (chen 2026-11-25: 广场/排行榜歌单打开后歌曲读不出信息):
    /// NetEase dropped the old `ar` / `al` keys from this endpoint —
    /// live payload (2026-11-25, 热歌榜 100 首) has `artists` on
    /// 100/100 and `ar` on 0/100, `album` on 100/100 and `al` on
    /// 0/100. The old-only read left every track with an empty
    /// artist ("未知艺人" in the row) and no album / cover. New keys
    /// first, old keys as fallback — the same shape MusicArtistAPI
    /// already parses (its lines 248-250).
    static func parseWySongDetail(_ json: [String: Any]) -> [MusicTrack] {
        MusicAPIJSON.asList(json["songs"]).map { s in
            var artists = MusicAPIJSON.asList(s["artists"])
            if artists.isEmpty { artists = MusicAPIJSON.asList(s["ar"]) }
            let album = MusicAPIJSON.asMap(s["album"]) ?? MusicAPIJSON.asMap(s["al"]) ?? [:]
            let durMs = MusicAPIJSON.asInt(s["duration"] != nil ? s["duration"] : s["dt"])
            return MusicTrack(
                id: MusicAPIJSON.asString(s["id"]),
                title: MusicAPIJSON.asString(s["name"]),
                artist: artists.map { MusicAPIJSON.asString($0["name"]) }.joined(separator: " / "),
                album: MusicAPIJSON.asString(album["name"]),
                coverURL: URL(string: MusicText.coverHi(MusicAPIJSON.asString(album["picUrl"]), platform: "wy")),
                duration: (Double(durMs) / 1000.0).rounded(),
                sourceID: "wy")
        }
    }

    // MARK: - Import: QQ

    /// QQ playlist import (`fcg_ucc_getcdinfo_byids_cp.fcg`).
    func importTxPlaylist(
        _ id: String,
        onProgress: ((Int, Int?) -> Void)? = nil,
        cancelToken: LXCancelToken? = nil,
        completion: @escaping (ImportedPlaylist) -> Void
    ) {
        client.getJson(
            "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg",
            query: [
                "type": "1", "json": "1", "utf8": "1", "onlysong": "0",
                "new_format": "1", "disstid": id, "loginUin": "0",
                "hostUin": "0", "format": "json", "inCharset": "utf8",
                "outCharset": "utf-8", "notice": "0", "platform": "yqq.json",
                "needNewCode": "0",
            ],
            headers: ["Referer": "https://y.qq.com/", "User-Agent": MusicUA.value]
        ) { json in
            guard let json = json else {
                completion(ImportedPlaylist(name: "", tracks: [], platform: .tx,
                                            missing: 0, note: "歌单获取失败"))
                return
            }
            let cdList = MusicAPIJSON.asList(json["cdlist"])
            let cd = cdList.first ?? [:]
            let tracks = MusicAPIJSON.asList(cd["songlist"]).compactMap { s -> MusicTrack? in
                // (b37 M1-a) `new_format=1` changed the payload shape:
                // old keys songmid/songname/albumname/albummid are gone;
                // the new shape is mid, name/title, album: {mid, name},
                // singer: [{mid, name}]. Parse both shapes (old first)
                // or every track gets an empty id and is dropped.
                let singers = MusicAPIJSON.asList(s["singer"])
                let albumDict = MusicAPIJSON.asMap(s["album"])
                let songmid = MusicAPIJSON.asString(s["songmid"])
                let trackId = songmid.isEmpty ? MusicAPIJSON.asString(s["mid"]) : songmid
                let songname = MusicAPIJSON.asString(s["songname"])
                let name2 = songname.isEmpty ? MusicAPIJSON.asString(s["name"]) : songname
                let title = name2.isEmpty ? MusicAPIJSON.asString(s["title"]) : name2
                let albumname = MusicAPIJSON.asString(s["albumname"])
                let album = albumname.isEmpty ? MusicAPIJSON.asString(albumDict?["name"]) : albumname
                let albummid = MusicAPIJSON.asString(s["albummid"])
                let albumMid = albummid.isEmpty ? MusicAPIJSON.asString(albumDict?["mid"]) : albummid
                let track = MusicTrack(
                    id: trackId,
                    title: title,
                    artist: singers.map { MusicAPIJSON.asString($0["name"]) }.joined(separator: " / "),
                    album: album,
                    coverURL: URL(string: albumMid.isEmpty ? "" : MusicText.coverHi(
                        "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid).jpg", platform: "tx")),
                    duration: TimeInterval(MusicAPIJSON.asInt(s["interval"])),
                    sourceID: "tx")
                guard !track.id.isEmpty, !track.title.isEmpty else { return nil }
                return track
            }
            onProgress?(tracks.count, tracks.count)
            completion(ImportedPlaylist(
                name: MusicAPIJSON.asString(cd["dissname"]), tracks: tracks,
                platform: .tx, missing: 0, note: ""))
        }
    }

    // MARK: - Import: Kuwo

    /// Kuwo playlist import (`nplserver.kuwo.cn/pl.svc`, up to 10
    /// pages of 100).
    func importKwPlaylist(
        _ id: String,
        onProgress: ((Int, Int?) -> Void)? = nil,
        cancelToken: LXCancelToken? = nil,
        completion: @escaping (ImportedPlaylist) -> Void
    ) {
        var out: [MusicTrack] = []
        var name = ""
        var stoppedReason: String?
        var page = 0
        func nextPage() {
            if page >= 10 {
                finish()
                return
            }
            if cancelToken?.isCancelled == true {
                stoppedReason = "cancelled"
                finish()
                return
            }
            let pn = page
            page += 1
            importPageWithRetry(fetch: { done in
                self.client.getJson(
                    "https://nplserver.kuwo.cn/pl.svc",
                    query: [
                        "op": "getlistinfo", "pid": id, "pn": "\(pn)",
                        "rn": "100", "encode": "utf8", "keyset": "pl2012",
                        "vipver": "1",
                    ],
                    headers: ["User-Agent": MusicUA.value],
                    timeout: 15
                ) { json in done(json) }
            }, cancelToken: cancelToken) { json in
                guard let json = json else {
                    stoppedReason = cancelToken?.isCancelled == true
                        ? "cancelled" : "第 \(pn + 1) 页获取失败"
                    finish()
                    return
                }
                let list = MusicAPIJSON.asList(json["musiclist"])
                if pn == 0 { name = MusicAPIJSON.asString(json["title"]) }
                guard !list.isEmpty else {
                    finish()
                    return
                }
                for x in list {
                    out.append(MusicTrack(
                        id: MusicAPIJSON.asString(x["id"]),
                        title: MusicAPIJSON.asString(x["name"]),
                        artist: MusicAPIJSON.asString(x["artist"]),
                        coverURL: URL(string: MusicText.coverHi(
                            MusicAPIJSON.firstString(x, keys: ["albumpic", "musicPic"]), platform: "kw")),
                        duration: TimeInterval(MusicAPIJSON.asInt(x["duration"])),
                        sourceID: "kw"))
                }
                onProgress?(out.count, nil)
                if list.count < 100 {
                    finish()
                    return
                }
                nextPage()
            }
        }
        func finish() {
            let tracks = out.filter { !$0.id.isEmpty && !$0.title.isEmpty }
            let note: String
            switch stoppedReason {
            case nil: note = ""
            case "cancelled": note = "已取消导入，已导入 \(tracks.count) 首"
            case let reason?: note = "\(reason)，仅导入 \(tracks.count) 首"
            }
            completion(ImportedPlaylist(name: name, tracks: tracks, platform: .kw,
                                        missing: 0, note: note))
        }
        nextPage()
    }

    // MARK: - Import: Kugou

    /// Kugou 精选集 import (`mobilecdn …/special/song`, 100/page).
    /// The name comes from the special-page title (the JSON playlist
    /// APIs do not return a name).
    func importKgPlaylist(
        _ id: String,
        onProgress: ((Int, Int?) -> Void)? = nil,
        cancelToken: LXCancelToken? = nil,
        completion: @escaping (ImportedPlaylist) -> Void
    ) {
        kgSpecialTitle(id) { title in
            var out: [MusicTrack] = []
            var page = 1
            func nextPage() {
                if cancelToken?.isCancelled == true {
                    completion(ImportedPlaylist(name: title, tracks: out, platform: .kg,
                                                missing: 0, note: "已取消导入，已导入 \(out.count) 首"))
                    return
                }
                let pn = page
                page += 1
                self.importPageWithRetry(fetch: { done in
                    self.client.getJson(
                        "https://mobilecdn.kugou.com/api/v3/special/song?specialid=\(id)&page=\(pn)&pagesize=100&showtype=1",
                        headers: ["User-Agent": MusicUA.value]
                    ) { json in done(json) }
                }, cancelToken: cancelToken) { json in
                    guard let json = json else {
                        completion(ImportedPlaylist(name: title, tracks: out, platform: .kg,
                                                    missing: 0, note: "第 \(pn) 页获取失败，仅导入 \(out.count) 首"))
                        return
                    }
                    let data = MusicAPIJSON.asMap(json["data"]) ?? [:]
                    let list = MusicAPIJSON.asList(data["info"])
                    for x in list {
                        let track = MusicTrack(
                            id: MusicAPIJSON.asString(x["hash"]),
                            title: MusicAPIJSON.asString(x["songname"]),
                            artist: MusicAPIJSON.asString(x["singername"]),
                            album: MusicAPIJSON.asString(x["album_name"]),
                            duration: TimeInterval(MusicAPIJSON.asInt(x["duration"])),
                            sourceID: "kg")
                        guard !track.id.isEmpty, !track.title.isEmpty else { continue }
                        out.append(track)
                    }
                    onProgress?(out.count, nil)
                    if list.count < 100 {
                        completion(ImportedPlaylist(name: title, tracks: out, platform: .kg,
                                                    missing: 0, note: ""))
                        return
                    }
                    nextPage()
                }
            }
            nextPage()
        }
    }

    /// Kugou user playlist import (`m.kugou.com/plist/list/<id>`).
    func importKgPlist(
        _ id: String,
        onProgress: ((Int, Int?) -> Void)? = nil,
        cancelToken: LXCancelToken? = nil,
        completion: @escaping (ImportedPlaylist) -> Void
    ) {
        var out: [MusicTrack] = []
        var total = 0
        var page = 1
        func nextPage() {
            if cancelToken?.isCancelled == true {
                completion(ImportedPlaylist(name: "", tracks: out, platform: .kg,
                                            missing: 0, note: "已取消导入，已导入 \(out.count) 首"))
                return
            }
            let p = page
            page += 1
            self.importPageWithRetry(fetch: { done in
                self.client.getJson(
                    "https://m.kugou.com/plist/list/\(id)",
                    query: ["json": "true", "page": "\(p)", "pagesize": "10"],
                    headers: ["User-Agent": MusicUA.value, "Referer": "https://www.kugou.com/"]
                ) { json in done(json) }
            }, cancelToken: cancelToken) { json in
                guard let json = json else {
                    completion(ImportedPlaylist(name: "", tracks: out, platform: .kg,
                                                missing: 0, note: "第 \(p) 页获取失败，仅导入 \(out.count) 首"))
                    return
                }
                let list = MusicAPIJSON.asMap(json["list"]) ?? [:]
                let info = MusicAPIJSON.asList(list["info"])
                if p == 1 { total = MusicAPIJSON.asInt(list["total"]) }
                for x in info {
                    let track = MusicTrack(
                        id: MusicAPIJSON.asString(x["hash"]).uppercased(),
                        title: MusicAPIJSON.asString(x["songname"]),
                        artist: MusicAPIJSON.asString(x["singername"]),
                        album: MusicAPIJSON.asString(x["album_name"]),
                        duration: TimeInterval(MusicAPIJSON.asInt(x["duration"])),
                        sourceID: "kg")
                    guard !track.id.isEmpty, !track.title.isEmpty else { continue }
                    out.append(track)
                }
                onProgress?(out.count, total > 0 ? total : nil)
                if info.isEmpty || info.count < 10 {
                    completion(ImportedPlaylist(name: "", tracks: out, platform: .kg,
                                                missing: 0, note: ""))
                    return
                }
                nextPage()
            }
        }
        nextPage()
    }

    /// Kugou shared-playlist import — NOT available: the endpoint
    /// (`m3ws.kugou.com/v2/zlist/list`) requires a signed request and
    /// the signing secret was removed from source (P0-15). This fails
    /// explicitly with a note instead of signing with a hardcoded
    /// secret or failing silently.
    func importKgShared(
        _ share: KgShareParams,
        onProgress: ((Int, Int?) -> Void)? = nil,
        cancelToken: LXCancelToken? = nil,
        completion: @escaping (ImportedPlaylist) -> Void
    ) {
        _ = share
        _ = onProgress
        _ = cancelToken
        completion(ImportedPlaylist(
            name: "", tracks: [], platform: .kg, missing: 0,
            note: "酷狗分享歌单需要签名，当前版本暂不支持导入"))
    }

    /// Playlist name from the Kugou special page <title>. Fail-soft:
    /// '' on any failure.
    func kgSpecialTitle(_ id: String, completion: @escaping (String) -> Void) {
        client.getText("https://www.kugou.com/yy/special/single/\(id).html") { html in
            guard let html = html,
                  let regex = try? NSRegularExpression(pattern: "<title>([^<]*)</title>", options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html)
            else {
                completion("")
                return
            }
            var title = String(html[range])
            if let suffix = try? NSRegularExpression(pattern: "_[^_]*_乐库频道_酷狗网$") {
                title = suffix.stringByReplacingMatches(
                    in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "")
            }
            if let suffix = try? NSRegularExpression(pattern: "_酷狗网$") {
                title = suffix.stringByReplacingMatches(
                    in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "")
            }
            completion(title.trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - Import from a pasted link

    /// Import a playlist from a pasted public link (wy / kg / kw /
    /// tx). Nil when the URL is not a recognised playlist link.
    func importFromLink(
        _ input: String,
        onProgress: ((Int, Int?) -> Void)? = nil,
        cancelToken: LXCancelToken? = nil,
        completion: @escaping (ImportedPlaylist?) -> Void
    ) {
        guard let url = MusicPlaylistImportAPI.extractURL(from: input) else {
            completion(nil)
            return
        }
        let host = URL(string: url)?.host ?? ""
        // NetEase short link (163cn.tv/<code>): walk the redirects —
        // the playlist id sits in an intermediate hop's URL.
        if host == "163cn.tv" || host.hasSuffix(".163cn.tv") {
            followRedirects(url) { hops in
                for hop in hops {
                    if let id = MusicPlaylistImportAPI.wyPlaylistIdFromURL(hop) {
                        self.importWyPlaylist(id, onProgress: onProgress, cancelToken: cancelToken) { result in
                            completion(result)
                        }
                        return
                    }
                    if let share = MusicPlaylistImportAPI.kgShareParamsFromURL(hop) {
                        self.importKgShared(share, onProgress: onProgress, cancelToken: cancelToken) { result in
                            completion(result)
                        }
                        return
                    }
                    if let plist = MusicPlaylistImportAPI.kgPlistIdFromURL(hop) {
                        self.importKgPlist(plist, onProgress: onProgress, cancelToken: cancelToken) { result in
                            completion(result)
                        }
                        return
                    }
                }
                completion(nil)
            }
            return
        }
        // Direct long forms (no redirect needed).
        if let id = MusicPlaylistImportAPI.wyPlaylistIdFromURL(url) {
            importWyPlaylist(id, onProgress: onProgress, cancelToken: cancelToken) { completion($0) }
            return
        }
        if let share = MusicPlaylistImportAPI.kgShareParamsFromURL(url) {
            importKgShared(share, onProgress: onProgress, cancelToken: cancelToken) { completion($0) }
            return
        }
        if let special = MusicPlaylistImportAPI.kgSpecialIdFromURL(url) {
            importKgPlaylist(special, onProgress: onProgress, cancelToken: cancelToken) { completion($0) }
            return
        }
        if let plist = MusicPlaylistImportAPI.kgPlistIdFromURL(url) {
            importKgPlist(plist, onProgress: onProgress, cancelToken: cancelToken) { completion($0) }
            return
        }
        if let id = MusicPlaylistImportAPI.firstRegexGroup("kuwo\\.cn/playlist_detail/(\\d+)", in: url) {
            importKwPlaylist(id, onProgress: onProgress, cancelToken: cancelToken) { completion($0) }
            return
        }
        if let id = MusicPlaylistImportAPI.firstRegexGroup("y\\.qq\\.com/.*playlist/(\\d+)", in: url) {
            importTxPlaylist(id, onProgress: onProgress, cancelToken: cancelToken) { completion($0) }
            return
        }
        completion(nil)
    }

    // MARK: - URL extractors (pure, unit-tested)

    /// First URL in pasted text (the user may paste a link with
    /// surrounding text).
    static func extractURL(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s\"'<>]+") else { return nil }
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\u{2E}\u{2C}\u{29}\u{3B}\u{5D}\u{7D}"))
    }

    static func firstRegexGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// NetEase playlist id from a music.163.com URL (desktop hash
    /// form `music.163.com/#/playlist?id=123` included).
    static func wyPlaylistIdFromURL(_ urlString: String) -> String? {
        guard let url = URL(string: urlString),
              url.host?.hasSuffix("music.163.com") == true
        else { return nil }
        var path = url.path
        var queryItems = URLComponents(string: urlString)?.queryItems ?? []
        if url.fragment?.hasPrefix("/playlist") == true,
           let frag = URLComponents(string: url.fragment ?? "") {
            path = frag.path
            queryItems = frag.queryItems ?? []
        }
        guard path.contains("playlist") else { return nil }
        guard let id = queryItems.first(where: { $0.name == "id" })?.value,
              Int(id) != nil
        else { return nil }
        return id
    }

    /// Kugou 精选集 id from a desktop special URL
    /// (`www.kugou.com/yy/special/single/<id>.html`, or a
    /// specialid/global_collection_id/collection_id query param).
    static func kgSpecialIdFromURL(_ urlString: String) -> String? {
        if let id = firstRegexGroup("kugou\\.com/yy/special/single/(\\d{4,})", in: urlString) {
            return id
        }
        guard let components = URLComponents(string: urlString) else { return nil }
        for key in ["specialid", "global_collection_id", "collection_id"] {
            if let id = components.queryItems?.first(where: { $0.name == key })?.value,
               Int(id) != nil {
                return id
            }
        }
        return nil
    }

    /// Kugou user playlist id from the mobile playlist page URL
    /// (`m.kugou.com/plist/list/<id>` or `plist/<id>`).
    static func kgPlistIdFromURL(_ urlString: String) -> String? {
        firstRegexGroup("kugou\\.com/plist/(?:list/)?(\\d{4,})", in: urlString)
    }

    /// Kugou share-playlist parameters from a share/zlist.html
    /// landing URL. Nil when the URL is not a zlist share page.
    static func kgShareParamsFromURL(_ urlString: String) -> KgShareParams? {
        guard let url = URL(string: urlString),
              url.path.contains("zlist"),
              let components = URLComponents(string: urlString)
        else { return nil }
        let query = components.queryItems ?? []
        func value(_ name: String) -> String {
            query.first(where: { $0.name == name })?.value ?? ""
        }
        let listid = value("listid")
        let uid = value("uid")
        guard !listid.isEmpty, !uid.isEmpty else { return nil }
        return KgShareParams(
            listid: listid, uid: uid, sign: value("sign"), t: value("_t"),
            type: value("type").isEmpty ? "0" : value("type"),
            collection: value("global_collection_id"), chain: value("chain"))
    }

    /// Follow HTTP redirects MANUALLY (up to 5 hops) and return every
    /// URL visited, start URL first. Manual because the id often sits
    /// in an INTERMEDIATE Location (163cn.tv -> y.music.163.com/m/
    /// playlist?id=..), and the landing page itself may 404 for our
    /// UA while the id is already known. Fail-soft: on any error
    /// return the hops collected so far (at least the start URL).
    /// Never throws. URLSession follows redirects automatically, so
    /// this uses a dedicated session whose delegate refuses each
    /// redirect and reports the Location header instead.
    func followRedirects(_ urlString: String, completion: @escaping ([String]) -> Void) {
        let follower = RedirectFollower()
        follower.walk(urlString, remaining: 5, hops: [urlString], completion: completion)
    }
}

/// URLSession delegate that refuses redirects: the task completes
/// with the redirect response itself, so the caller can read the
/// Location header and walk the chain manually.
private final class RedirectFollower: NSObject, URLSessionDataDelegate {
    private var completion: (([String]) -> Void)?
    private var hops: [String] = []
    private var remaining = 0
    private var session: URLSession?

    func walk(_ urlString: String, remaining: Int, hops: [String], completion: @escaping ([String]) -> Void) {
        self.completion = completion
        self.hops = hops
        self.remaining = remaining
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        guard let url = URL(string: urlString) else {
            finish()
            return
        }
        var request = URLRequest(url: url)
        request.setValue(MusicUA.value, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request).resume()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Refuse the redirect: the task finishes with the redirect
        // response, and `didCompleteWithError` reads its Location.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let response = task.response as? HTTPURLResponse,
              let location = response.allHeaderFields.first(where: {
                  "\($0.key)".lowercased() == "location"
              })?.value as? String,
              !location.isEmpty,
              remaining > 0
        else {
            finish()
            return
        }
        let current = hops.last ?? ""
        guard let next = URL(string: location, relativeTo: URL(string: current))?.absoluteString,
              next != current
        else {
            finish()
            return
        }
        hops.append(next)
        remaining -= 1
        session.invalidateAndCancel()
        walk(next, remaining: remaining, hops: hops, completion: completion ?? { _ in })
    }

    private func finish() {
        session?.invalidateAndCancel()
        session = nil
        let hops = self.hops
        let completion = self.completion
        self.completion = nil
        DispatchQueue.main.async { completion?(hops) }
    }
}

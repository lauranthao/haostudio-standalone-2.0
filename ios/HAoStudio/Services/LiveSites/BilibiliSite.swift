// HAo Studio 2.0 — Bilibili live site (S4 leg B).
//
// Swift port of the Flutter `lib/shared/platforms/bilibili/
// bilibili_site.dart` (room detail + play info only; categories,
// recommend and search are out of this leg's scope).
//
// Room detail: GET `.../xlive/web-room/v1/index/getInfoByRoom`
// (WBI-signed — unsigned calls return code -352).
// Quality+lines: GET `.../xlive/web-room/v2/index/getRoomPlayInfo`
// (quality = g_qn_desc ∩ accept_qn; NEVER invent a quality the
// server didn't confirm; `current_qn` is kept as the applied
// quality — anonymous requests get silently downgraded, e.g.
// 10000 -> 250, verified live 2026-11-16 on room 7734200; the UI
// must reflect the APPLIED quality).
// Lines = url_info[] hosts for the applied qn, ordered
// http_stream/flv first; lines are identified by URL, never by
// index.
//
// Carousel rooms (live_status 2) resolve like the Flutter
// port: a watchable looping video, started at the loop start
// (the resolution model has no start-offset field, so playback
// begins at 0 — b49fix2 P2-19).
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class BilibiliLiveSite: LiveSiteResolver {
    var platform: LivePlatform {
        .bilibili
    }

    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"
    static let referer = "https://live.bilibili.com/"
    static let roomInfoUrl = "https://api.live.bilibili.com/xlive/web-room/v1/index/getInfoByRoom"
    static let danmuInfoUrl = "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo"
    static let playInfoUrl = "https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo"
    static let buvidUrl = "https://api.bilibili.com/x/frontend/finger/spi"

    private let fetcher: LiveDataFetcher
    private let wbiSigner: BilibiliWbiSigner
    private var buvid3: String = ""
    private var buvid4: String = ""
    private var buvidRequestInFlight: Bool = false
    private var buvidCompletions: [(String, String) -> Void] = []
    private var accessId: String = ""
    private var accessIdInFlight: Bool = false
    private var accessIdCompletions: [(String) -> Void] = []
    /// In-flight room-detail loads, keyed by trimmed room id
    /// (build 36 item 10 leg 4 — see `loadRoomInfo`).
    private var roomDetailInFlight: [String: [(Result<LiveRoom, Error>) -> Void]] = [:]
    /// In-flight raw room_info fetches, keyed by trimmed room id
    /// (b49fix2 P1-21): the playback resolve and the danmaku
    /// roomInfo both need the same room_info response. A second
    /// caller joins the fetch in flight instead of starting
    /// another; every joiner gets its own completion with the
    /// same result. The entry is dropped when the fetch finishes,
    /// so a later fetch always goes to the network.
    private var roomInfoFetchInFlight: [String: [(Result<RoomInfoResult, Error>) -> Void]] = [:]
    /// sub-area id -> parent area id, filled by listCategories.
    /// second/getList returns -400 without parent_area_id, so a
    /// category room list is only attempted when the parent is known.
    private var categoryParentIds: [String: String] = [:]

    /// Guards the buvid / access-id / category-parent state below:
    /// these run from URLSession background callbacks and two
    /// concurrent calls used to mutate the same caches/arrays
    /// with no lock — a data race that traps. The lock is only
    /// ever held for the state touch, never across a network call
    /// or a completion.
    private let stateLock = NSLock()
    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    init(fetcher: LiveDataFetcher? = nil, wbiSigner: BilibiliWbiSigner? = nil) {
        let sharedFetcher = fetcher ?? LiveHTTP.defaultFetcher
        self.fetcher = sharedFetcher
        self.wbiSigner = wbiSigner ?? BilibiliWbiSigner(fetcher: sharedFetcher)
    }

    func makeDanmakuTransport() -> LiveDanmakuTransport {
        BilibiliDanmaku(fetcher: fetcher)
    }

    // MARK: - Room info

    func roomInfo(roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        let trimmed = roomId.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            completion(.failure(LiveError.invalidRoomId))
            return
        }
        // A transient failure is reported as a failure, never
        // disguised as "offline" (build 36 item 8): all three
        // callers already keep the card's values on failure (the
        // room page falls back to the card room AND its danmaku
        // credentials, the gateway answers nil, the home check
        // treats it as unknown). The old disguise hid the LIVE
        // badge the card knew, zeroed the watching count, and
        // discarded the card's danmakuData — so a rate-limited
        // roomInfo also killed danmaku for the whole visit.
        loadRoomInfo(roomId: trimmed, completion: completion)
    }

    /// Strict room load: throws when no parseable room metadata is
    /// available (recovery callers must see the transient error,
    /// never a disguised "offline").
    ///
    /// Build 36 item 10 leg 4: entering a room fires two paths at
    /// once — the playback `resolve` below and the danmaku
    /// `roomInfo` above — and both used to issue their own
    /// room-info + danmaku-info requests (5 HTTP per Bilibili
    /// entry: 2x roomInfo + 2x danmuInfo + 1x playInfo). A
    /// concurrent load for the same room joins the one already in
    /// flight instead of starting another; every joiner still gets
    /// its own completion with the same result, so the failure
    /// semantics are unchanged (a transient failure is reported
    /// as a failure to both paths, never disguised as offline —
    /// build 36 item 8). The entry is dropped when the load
    /// finishes, so a later load (recovery re-parse, quality
    /// switch, prefetch) always fetches fresh: this is dedup,
    /// never a cache.
    func loadRoomInfo(roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        let alreadyInFlight = locked {
            var list = roomDetailInFlight[roomId] ?? []
            list.append(completion)
            roomDetailInFlight[roomId] = list
            return list.count > 1
        }
        if alreadyInFlight {
            return
        }
        fetchRoomInfoShared(roomId: roomId) { result in
            switch result {
            case .success(let roomInfo):
                self.discoverDanmaku(realRoomId: roomInfo.realRoomId) { danmakuData in
                    self.finishRoomDetail(roomId: roomId, result: .success(BilibiliLiveSite.buildRoom(roomInfo: roomInfo.data, roomId: roomId, realRoomId: roomInfo.realRoomId, danmakuData: danmakuData)))
                }
            case .failure(let error):
                self.finishRoomDetail(roomId: roomId, result: .failure(error))
            }
        }
    }

    /// Shared room_info fetch (b49fix2 P1-21): join-or-start, so
    /// the playback resolve and the danmaku roomInfo issue one
    /// room_info request between them instead of two. The lock is
    /// only held for the state touch, never across a completion.
    private func fetchRoomInfoShared(roomId: String, completion: @escaping (Result<RoomInfoResult, Error>) -> Void) {
        let alreadyInFlight = locked {
            var list = roomInfoFetchInFlight[roomId] ?? []
            list.append(completion)
            roomInfoFetchInFlight[roomId] = list
            return list.count > 1
        }
        if alreadyInFlight {
            return
        }
        fetchRoomInfo(roomId: roomId, attempt: 0) { result in
            let completions = self.locked {
                self.roomInfoFetchInFlight.removeValue(forKey: roomId) ?? []
            }
            for item in completions {
                item(result)
            }
        }
    }

    /// Drain one in-flight room-detail load (build 36 item 10 leg
    /// 4): the entry is removed BEFORE the completions run, so a
    /// completion that re-enters the loader (recovery, quality
    /// switch) registers a fresh load instead of joining a
    /// finished one. The lock is only held for the state touch,
    /// never across a completion.
    private func finishRoomDetail(roomId: String, result: Result<LiveRoom, Error>) {
        let completions = locked {
            roomDetailInFlight.removeValue(forKey: roomId) ?? []
        }
        for item in completions {
            item(result)
        }
    }

    private struct RoomInfoResult {
        var data: [String: Any]
        var realRoomId: String
    }

    private func fetchRoomInfo(roomId: String, attempt: Int, completion: @escaping (Result<RoomInfoResult, Error>) -> Void) {
        wbiSigner.signUrl("\(BilibiliLiveSite.roomInfoUrl)?room_id=\(roomId)", forceRefresh: attempt > 0) { result in
            switch result {
            case .success(let params):
                guard let url = URL(string: BilibiliLiveSite.roomInfoUrl) else {
                    completion(.failure(LiveError.parseFailed("Bilibili room info url 无效")))
                    return
                }
                let queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
                self.headers { headers in
                    let request = LiveHTTP.getRequest(url: url, queryItems: queryItems, headers: headers)
                    self.fetcher(request) { data, status, error in
                        if let error = error {
                            self.retryOrFailRoomInfo(roomId: roomId, attempt: attempt, error: error, completion: completion)
                            return
                        }
                        guard let status = status, (200..<300).contains(status), let data = data, let json = LiveJSON.decodeObject(data) else {
                            self.retryOrFailRoomInfo(roomId: roomId, attempt: attempt, error: LiveError.emptyResponse, completion: completion)
                            return
                        }
                        do {
                            let parsed = try BilibiliLiveSite.parseRoomInfoResponse(json)
                            let info = LiveJSON.asMap(parsed["room_info"]) ?? [:]
                            let realRoomId = LiveJSON.asString(info["room_id"])
                            completion(.success(RoomInfoResult(data: parsed, realRoomId: realRoomId.isEmpty ? roomId : realRoomId)))
                        } catch {
                            self.retryOrFailRoomInfo(roomId: roomId, attempt: attempt, error: error, completion: completion)
                        }
                    }
                }
            case .failure(let error):
                self.retryOrFailRoomInfo(roomId: roomId, attempt: attempt, error: error, completion: completion)
            }
        }
    }

    private func retryOrFailRoomInfo(roomId: String, attempt: Int, error: Error, completion: @escaping (Result<RoomInfoResult, Error>) -> Void) {
        if attempt == 0 {
            LiveHTTP.after(milliseconds: 180) {
                self.fetchRoomInfo(roomId: roomId, attempt: 1, completion: completion)
            }
        } else {
            completion(.failure(error))
        }
    }

    // MARK: - Danmaku credentials (single quick discovery)

    private func discoverDanmaku(realRoomId: String, completion: @escaping ([String: Any]?) -> Void) {
        guard let roomNumber = Int(realRoomId), roomNumber != 0 else {
            completion(nil)
            return
        }
        headers { headers in
            self.wbiSigner.signUrl("\(BilibiliLiveSite.danmuInfoUrl)?id=\(realRoomId)&type=0") { result in
                switch result {
                case .success(let params):
                    guard let url = URL(string: BilibiliLiveSite.danmuInfoUrl) else {
                        completion(nil)
                        return
                    }
                    let queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
                    let request = LiveHTTP.getRequest(url: url, queryItems: queryItems, headers: headers)
                    self.fetcher(request) { data, status, _ in
                        guard let status = status, (200..<300).contains(status), let data = data, let json = LiveJSON.decodeObject(data) else {
                            completion(nil)
                            return
                        }
                        guard LiveJSON.asInt(json["code"]) == 0, let candidate = LiveJSON.asMap(json["data"]) else {
                            completion(nil)
                            return
                        }
                        let args = BilibiliLiveSite.parseDanmakuArgs(data: candidate, realRoomId: roomNumber, buvid: self.buvid3, cookie: headers["cookie"] ?? "")
                        if args.token.isEmpty {
                            completion(nil)
                            return
                        }
                        completion(args.dictionary)
                    }
                case .failure:
                    completion(nil)
                }
            }
        }
    }

    // MARK: - Resolve

    func resolve(roomId: String, quality: LiveQuality?, completion: @escaping (Result<LivePlayUrlResolution, Error>) -> Void) {
        let trimmed = roomId.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            completion(.failure(LiveError.invalidRoomId))
            return
        }
        // (b49fix2 P1-21) Playback does not wait for danmaku:
        // the room_info fetch is shared with the danmaku path
        // (one request, both join it), but the danmaku discovery
        // runs only on the roomInfo path — resolve needs just the
        // live status + the real room id, then fires playInfo at
        // once. Five sequential hops become two parallel ones
        // (room_info + playInfo) and the first frame no longer
        // waits on a WBI-signed danmaku round trip.
        fetchRoomInfoShared(roomId: trimmed) { result in
            switch result {
            case .success(let roomInfo):
                let info = LiveJSON.asMap(roomInfo.data["room_info"]) ?? [:]
                guard BilibiliLiveSite.isPlayableLiveStatus(info["live_status"]) else {
                    completion(.failure(LiveError.offline))
                    return
                }
                let realRoomId = roomInfo.realRoomId
                self.requestPlayInfo(roomId: realRoomId.isEmpty ? trimmed : realRoomId, qualityId: quality?.id) { playResult in
                    switch playResult {
                    case .success(let json):
                        do {
                            let qualities = try BilibiliLiveSite.parsePlayQualities(json)
                            let parsed = try BilibiliLiveSite.parsePlayUrlResolution(json, requestedQualityId: quality?.id)
                            completion(.success(BilibiliLiveSite.mergeResolution(parsed, into: qualities)))
                        } catch {
                            completion(.failure(error))
                        }
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Merges the applied quality (with its resolved lines) into
    /// the advertised quality list: the applied tier keeps its
    /// display name from `g_qn_desc` and gains the lines, so the
    /// returned `quality` echoes the tier actually applied and
    /// `appliedUrls` is never empty on success.
    static func mergeResolution(_ parsed: LivePlayUrlResolution, into qualities: [LiveQuality]) -> LivePlayUrlResolution {
        var merged = qualities
        var applied = parsed.quality
        if let appliedQuality = parsed.quality {
            if let index = merged.firstIndex(where: { $0.id == appliedQuality.id }) {
                merged[index].lines = parsed.lines
                applied = merged[index]
            } else {
                merged.append(appliedQuality)
                merged.sort { $0.sort > $1.sort }
            }
        }
        return LivePlayUrlResolution.applying(applied, in: merged)
    }

    private func requestPlayInfo(roomId: String, qualityId: String?, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let url = URL(string: BilibiliLiveSite.playInfoUrl) else {
            completion(.failure(LiveError.parseFailed("Bilibili play info url 无效")))
            return
        }
        headers { headers in
            let queryItems = [
                URLQueryItem(name: "room_id", value: roomId),
                URLQueryItem(name: "protocol", value: "0,1"),
                URLQueryItem(name: "format", value: "0,1,2"),
                URLQueryItem(name: "codec", value: "0"),
                URLQueryItem(name: "qn", value: qualityId ?? "0"),
                URLQueryItem(name: "platform", value: "web"),
                URLQueryItem(name: "ptype", value: "8"),
                URLQueryItem(name: "dolby", value: "5"),
                URLQueryItem(name: "panorama", value: "1"),
                URLQueryItem(name: "mask", value: "0"),
                URLQueryItem(name: "no_playurl", value: "0")
            ]
            let request = LiveHTTP.getRequest(url: url, queryItems: queryItems, headers: headers)
            self.fetcher(request) { data, status, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let status = status, (200..<300).contains(status), let data = data, let json = LiveJSON.decodeObject(data) else {
                    completion(.failure(LiveError.emptyResponse))
                    return
                }
                completion(.success(json))
            }
        }
    }

    // MARK: - Headers / buvid

    private func headers(completion: @escaping ([String: String]) -> Void) {
        resolveBuvid { buvid3, buvid4 in
            completion([
                "user-agent": BilibiliLiveSite.userAgent,
                "referer": BilibiliLiveSite.referer,
                "cookie": "buvid3=\(buvid3);buvid4=\(buvid4);"
            ])
        }
    }

    private func resolveBuvid(completion: @escaping (String, String) -> Void) {
        let cached: (String, String)? = locked {
            buvid3.isEmpty ? nil : (buvid3, buvid4)
        }
        if let cached = cached {
            completion(cached.0, cached.1)
            return
        }
        let alreadyInFlight = locked {
            buvidCompletions.append(completion)
            if buvidRequestInFlight {
                return true
            }
            buvidRequestInFlight = true
            return false
        }
        if alreadyInFlight {
            return
        }
        guard let url = URL(string: BilibiliLiveSite.buvidUrl) else {
            finishBuvidFetch(buvid3: "", buvid4: "")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: LiveHTTP.defaultTimeoutSeconds)
        request.setValue(BilibiliLiveSite.userAgent, forHTTPHeaderField: "user-agent")
        request.setValue(BilibiliLiveSite.referer, forHTTPHeaderField: "referer")
        fetcher(request) { data, _, _ in
            var b3 = ""
            var b4 = ""
            if let data = data, let json = LiveJSON.decodeObject(data), let inner = LiveJSON.asMap(json["data"]) {
                b3 = LiveJSON.asString(inner["b_3"])
                b4 = LiveJSON.asString(inner["b_4"])
            }
            self.finishBuvidFetch(buvid3: b3, buvid4: b4)
        }
    }

    private func finishBuvidFetch(buvid3: String, buvid4: String) {
        let completions = locked {
            self.buvid3 = buvid3
            self.buvid4 = buvid4
            buvidRequestInFlight = false
            let completions = buvidCompletions
            buvidCompletions = []
            return completions
        }
        for item in completions {
            item(buvid3, buvid4)
        }
    }

    // MARK: - Pure parsers (fixture-testable, no network)

    static func parseRoomInfoResponse(_ json: [String: Any]) throws -> [String: Any] {
        if LiveJSON.asInt(json["code"]) != 0 {
            throw LiveError.apiRejected(code: LiveJSON.asInt(json["code"]), message: LiveJSON.asString(json["message"]))
        }
        guard let data = LiveJSON.asMap(json["data"]) else {
            throw LiveError.parseFailed("Bilibili room metadata is incomplete")
        }
        guard LiveJSON.asMap(data["room_info"]) != nil, LiveJSON.asMap(data["anchor_info"]) != nil else {
            throw LiveError.parseFailed("Bilibili room metadata is incomplete")
        }
        return data
    }

    static func buildRoom(roomInfo: [String: Any], roomId: String, realRoomId: String, danmakuData: [String: Any]?) -> LiveRoom {
        let info = LiveJSON.asMap(roomInfo["room_info"]) ?? [:]
        let anchor = LiveJSON.asMap(roomInfo["anchor_info"]) ?? [:]
        let baseInfo = LiveJSON.asMap(anchor["base_info"]) ?? [:]
        let live = BilibiliLiveSite.isPlayableLiveStatus(info["live_status"])
        let face = LiveJSON.asString(baseInfo["face"])
        return LiveRoom(
            roomId: roomId,
            platform: .bilibili,
            title: LiveJSON.asString(info["title"]),
            streamer: LiveJSON.asString(baseInfo["uname"]),
            avatar: face.isEmpty ? "" : "\(face)@100w.jpg",
            cover: LiveJSON.asString(info["cover"]),
            onlineCount: LiveJSON.asInt(info["online"]),
            isLive: live,
            link: LivePlatform.bilibili.roomLink(roomId: roomId),
            data: ["realRoomId": realRoomId],
            danmakuData: danmakuData
        )
    }

    /// 1 = live, 2 = carousel, anything else = offline.
    static func liveStatus(_ value: Any?) -> Int {
        LiveJSON.asInt(value)
    }

    /// A status that plays (b49fix2 P2-19): live (1) and carousel
    /// (2, a watchable looping video — the Flutter port starts it
    /// at the loop start, which the resolution model has no field
    /// for, so playback begins at 0).
    static func isPlayableLiveStatus(_ value: Any?) -> Bool {
        let status = liveStatus(value)
        return status == 1 || status == 2
    }

    /// token + host_list -> transport args. The generic gateway has
    /// stable public DNS while some resolvers intermittently omit
    /// the regional comet records, so it is tried first and the
    /// regional nodes stay as failovers.
    static func parseDanmakuArgs(data: [String: Any], realRoomId: Int, buvid: String = "", cookie: String = "") -> BilibiliDanmakuArgs {
        let officialFallback = "wss://broadcastlv.chat.bilibili.com/sub"
        var serverUrls: [String] = [officialFallback]
        if let hostList = data["host_list"] as? [Any] {
            for item in hostList {
                guard let hostMap = item as? [String: Any] else {
                    continue
                }
                let host = LiveJSON.asString(hostMap["host"]).trimmingCharacters(in: .whitespaces)
                if host.isEmpty {
                    continue
                }
                let port = Int(LiveJSON.asString(hostMap["wss_port"])) ?? 443
                let endpoint = "wss://\(host)\(port == 443 ? "" : ":\(port)")/sub"
                if !serverUrls.contains(endpoint) {
                    serverUrls.append(endpoint)
                }
            }
        }
        return BilibiliDanmakuArgs(
            roomId: realRoomId,
            token: LiveJSON.asString(data["token"]),
            serverUrls: serverUrls,
            buvid: buvid,
            uid: 0,
            cookie: cookie
        )
    }

    /// Extracts only qualities accepted by at least one returned
    /// codec. The global descriptor list also contains unavailable
    /// tiers and previously produced buttons which could never
    /// resolve to a stream.
    static func parsePlayQualities(_ response: [String: Any]) throws -> [LiveQuality] {
        let playUrl = try playUrlPayload(response)
        var descriptions: [Int: String] = [:]
        if let rawList = playUrl["g_qn_desc"] as? [Any] {
            for raw in rawList {
                guard let item = raw as? [String: Any] else {
                    continue
                }
                guard let qn = Int(LiveJSON.asString(item["qn"])), qn > 0 else {
                    continue
                }
                let description = LiveJSON.asString(item["desc"]).trimmingCharacters(in: .whitespaces)
                descriptions[qn] = description.isEmpty ? "未知清晰度" : description
            }
        }
        var accepted = Set<Int>()
        for payload in codecPayloads(playUrl) {
            if let acceptList = payload.codec["accept_qn"] as? [Any] {
                for rawQn in acceptList {
                    if let qn = Int(LiveJSON.asString(rawQn)), qn > 0 {
                        accepted.insert(qn)
                    }
                }
            }
            if let current = Int(LiveJSON.asString(payload.codec["current_qn"])), current > 0 {
                accepted.insert(current)
            }
        }
        let ordered = accepted.sorted { $0 > $1 }
        return ordered.map { qn in
            LiveQuality(id: String(qn), name: descriptions[qn] ?? "未知清晰度", sort: qn)
        }
    }

    /// Keeps the server-acknowledged `current_qn` with the URLs.
    /// Bilibili can advertise 10000/400 to a guest and still return
    /// qn=250 for every request; the returned `quality` is the
    /// tier actually applied (250), never the requested one — the
    /// caller compares ids and rolls back on a mismatch.
    /// No candidates at all is a failure, not an empty resolution:
    /// a resolution with no URLs must never reach the player.
    static func parsePlayUrlResolution(_ response: [String: Any], requestedQualityId: String?) throws -> LivePlayUrlResolution {
        let playUrl = try playUrlPayload(response)
        let requestedQn = requestedQualityId.flatMap { Int($0) }
        var candidates: [BilibiliStreamCandidate] = []
        for payload in codecPayloads(playUrl) {
            let codec = payload.codec
            guard let currentQn = Int(LiveJSON.asString(codec["current_qn"])), currentQn > 0 else {
                continue
            }
            let baseUrl = LiveJSON.asString(codec["base_url"])
            if baseUrl.isEmpty {
                continue
            }
            if let urlInfoList = codec["url_info"] as? [Any] {
                for rawUrl in urlInfoList {
                    guard let urlMap = rawUrl as? [String: Any] else {
                        continue
                    }
                    let url = "\(LiveJSON.asString(urlMap["host"]))\(baseUrl)\(LiveJSON.asString(urlMap["extra"]))".trimmingCharacters(in: .whitespaces)
                    if !url.hasPrefix("http") {
                        continue
                    }
                    candidates.append(BilibiliStreamCandidate(
                        url: url,
                        currentQn: currentQn,
                        protocolName: payload.protocolName,
                        format: payload.format,
                        codec: LiveJSON.asString(codec["codec_name"])
                    ))
                }
            }
        }
        candidates.sort { a, b in
            let aRequested = a.currentQn == requestedQn ? 1 : 0
            let bRequested = b.currentQn == requestedQn ? 1 : 0
            if aRequested != bRequested {
                return aRequested > bRequested
            }
            let protocolOrder = protocolRank(a.protocolName) - protocolRank(b.protocolName)
            if protocolOrder != 0 {
                return protocolOrder < 0
            }
            let formatOrder = formatRank(a.format) - formatRank(b.format)
            if formatOrder != 0 {
                return formatOrder < 0
            }
            let codecOrder = codecRank(a.codec) - codecRank(b.codec)
            if codecOrder != 0 {
                return codecOrder < 0
            }
            let aMcdn = a.url.contains("mcdn") ? 1 : 0
            let bMcdn = b.url.contains("mcdn") ? 1 : 0
            if aMcdn != bMcdn {
                return aMcdn < bMcdn
            }
            return a.url < b.url
        }
        if candidates.isEmpty {
            throw LiveError.parseFailed("Bilibili 未返回可用流地址")
        }
        let appliedQn = candidates[0].currentQn
        var linesByHost: [(host: String, urls: [String], format: String)] = []
        var seenUrls = Set<String>()
        for candidate in candidates {
            if candidate.currentQn != appliedQn {
                continue
            }
            if !seenUrls.insert(candidate.url).inserted {
                continue
            }
            let host = URL(string: candidate.url)?.host ?? candidate.url
            if let index = linesByHost.firstIndex(where: { $0.host == host }) {
                linesByHost[index].urls.append(candidate.url)
            } else {
                linesByHost.append((host: host, urls: [candidate.url], format: streamFormatOf(candidate.format, url: candidate.url)))
            }
        }
        let lines = linesByHost.map { LiveLine(name: $0.host, urls: $0.urls, format: $0.format) }
        let quality = LiveQuality(id: String(appliedQn), name: String(appliedQn), sort: appliedQn, lines: lines)
        return LivePlayUrlResolution.applying(quality, in: [quality])
    }

    static func streamFormatOf(_ format: String, url: String) -> String {
        let normalized = format.lowercased()
        if normalized == "flv" {
            return "flv"
        }
        if normalized == "hls" || url.lowercased().contains(".m3u8") {
            return "hls"
        }
        return "other"
    }

    static func playUrlPayload(_ response: [String: Any]) throws -> [String: Any] {
        if LiveJSON.asInt(response["code"]) != 0 {
            throw LiveError.apiRejected(code: LiveJSON.asInt(response["code"]), message: LiveJSON.asString(response["message"]))
        }
        guard let data = LiveJSON.asMap(response["data"]) else {
            throw LiveError.parseFailed("Bilibili playurl payload is missing")
        }
        guard let playUrlInfo = LiveJSON.asMap(data["playurl_info"]) else {
            throw LiveError.parseFailed("Bilibili playurl payload is missing")
        }
        guard let playUrl = LiveJSON.asMap(playUrlInfo["playurl"]) else {
            throw LiveError.parseFailed("Bilibili playurl payload is missing")
        }
        return playUrl
    }

    private struct CodecPayload {
        var codec: [String: Any]
        var format: String
        var protocolName: String
    }

    private static func codecPayloads(_ playUrl: [String: Any]) -> [CodecPayload] {
        var payloads: [CodecPayload] = []
        guard let streams = playUrl["stream"] as? [Any] else {
            return payloads
        }
        for rawStream in streams {
            guard let stream = rawStream as? [String: Any] else {
                continue
            }
            let protocolName = LiveJSON.asString(stream["protocol_name"])
            guard let formats = stream["format"] as? [Any] else {
                continue
            }
            for rawFormat in formats {
                guard let format = rawFormat as? [String: Any] else {
                    continue
                }
                let formatName = LiveJSON.asString(format["format_name"])
                guard let codecs = format["codec"] as? [Any] else {
                    continue
                }
                for rawCodec in codecs {
                    guard let codec = rawCodec as? [String: Any] else {
                        continue
                    }
                    payloads.append(CodecPayload(codec: codec, format: formatName, protocolName: protocolName))
                }
            }
        }
        return payloads
    }

    private static func protocolRank(_ value: String) -> Int {
        value == "http_stream" ? 0 : 1
    }

    private static func formatRank(_ value: String) -> Int {
        switch value {
        case "flv":
            return 0
        case "ts":
            return 1
        case "fmp4":
            return 2
        default:
            return 3
        }
    }

    private static func codecRank(_ value: String) -> Int {
        value == "avc" ? 0 : 1
    }
}

private struct BilibiliStreamCandidate {
    var url: String
    var currentQn: Int
    var protocolName: String
    var format: String
    var codec: String
}

// MARK: - Lists (recommend / categories / search)
//
// Port of the Flutter `bilibili_site.dart` list methods
// (getRecommendRooms / getCategories / getCategoryRooms /
// searchRooms). The room-detail leg (S4-B) left these out; the
// live tab's gateway needs them. Every method completes with []
// on any failure — a list failure is an empty list, never a throw
// out of the completion handler. All parsing is pure + static so
// fixtures can cover it without network.

extension BilibiliLiveSite {
    private static let rankedRecommendURL = "https://api.live.bilibili.com/room/v1/Area/getListByAreaID"
    private static let fallbackRecommendURL = "https://api.live.bilibili.com/xlive/web-interface/v1/webMain/getMoreRecList"
    private static let areaListURL = "https://api.live.bilibili.com/room/v1/Area/getList"
    private static let categoryRoomsBaseURL = "https://api.live.bilibili.com/xlive/web-interface/v1/second/getList"
    private static let searchURL = "https://api.bilibili.com/x/web-interface/search/type"
    private static let accessIdURL = "https://live.bilibili.com/lol"

    /// Recommended rooms, heat-ranked (Dart `getRecommendRooms`):
    /// the ranked endpoint first (sort=online), the
    /// recommendation feed only as a bounded fallback. Page is
    /// 1-based here; the adapter converts the tab's 0-based page.
    func recommendRooms(page: Int, pageSize: Int, completion: @escaping (Result<[LiveRoom], Error>) -> Void) {
        let size = min(30, max(1, pageSize))
        let currentPage = max(1, page)
        headers { [weak self] headers in
            guard let self = self else { return }
            self.requestRankedRecommend(page: currentPage, pageSize: size, headers: headers, attempt: 0) { [weak self] rooms in
                guard let self = self else { return }
                if let rooms = rooms {
                    completion(.success(rooms))
                    return
                }
                self.requestRecommendFallback(page: currentPage, headers: headers, completion: completion)
            }
        }
    }

    private func requestRankedRecommend(page: Int, pageSize: Int, headers: [String: String], attempt: Int, completion: @escaping ([LiveRoom]?) -> Void) {
        guard let url = LiveListURL.url(base: BilibiliLiveSite.rankedRecommendURL, params: [
            ("areaId", "0"), ("parent_area_id", "0"), ("sort", "online"),
            ("pageSize", "\(pageSize)"), ("page", "\(page)")
        ]) else {
            completion(nil)
            return
        }
        LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: headers, fetcher: fetcher) { [weak self] json in
            guard let self = self else { return }
            if let rooms = BilibiliLiveSite.parseRecommendRooms(json) {
                completion(rooms)
                return
            }
            if attempt == 0 {
                LiveHTTP.after(milliseconds: 180) { [weak self] in
                    guard let self = self else { return }
                    self.requestRankedRecommend(page: page, pageSize: pageSize, headers: headers, attempt: 1, completion: completion)
                }
                return
            }
            completion(nil)
        }
    }

    private func requestRecommendFallback(page: Int, headers: [String: String], completion: @escaping (Result<[LiveRoom], Error>) -> Void) {
        guard let url = LiveListURL.url(base: BilibiliLiveSite.fallbackRecommendURL, params: [
            ("platform", "web"), ("page", "\(page)")
        ]) else {
            completion(.failure(LiveError.emptyResponse))
            return
        }
        LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: headers, fetcher: fetcher) { json in
            if let rooms = BilibiliLiveSite.parseRecommendRooms(json) {
                completion(.success(rooms))
            } else {
                completion(.failure(LiveError.emptyResponse))
            }
        }
    }

    /// Category names + ids (Dart `getCategories`): the parent ->
    /// sub-area tree flattened to sub-areas. The parent id of each
    /// sub-area is recorded for `categoryRooms`.
    func listCategories(completion: @escaping (Result<[(id: String, name: String)], Error>) -> Void) {
        headers { [weak self] headers in
            guard let self = self else { return }
            guard let url = LiveListURL.url(base: BilibiliLiveSite.areaListURL, params: [
                ("need_entrance", "1"), ("parent_id", "0")
            ]) else {
                completion(.failure(LiveError.emptyResponse))
                return
            }
            LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: headers, fetcher: self.fetcher) { [weak self] json in
                guard let self = self else { return }
                guard let triples = BilibiliLiveSite.parseCategories(json) else {
                    completion(.failure(LiveError.emptyResponse))
                    return
                }
                for triple in triples {
                    self.locked { self.categoryParentIds[triple.id] = triple.parentId }
                }
                completion(.success(triples.map { (id: $0.id, name: $0.name) }))
            }
        }
    }

    /// Rooms of one sub-area (Dart `getCategoryRooms`): WBI-signed
    /// second/getList with the area's parent id + w_webid. When the
    /// parent map is empty the categories are fetched first; an
    /// unknown parent yields an empty list rather than a request
    /// the server rejects (-400).
    func categoryRooms(areaId: String, page: Int, pageSize: Int, completion: @escaping (Result<[LiveRoom], Error>) -> Void) {
        if locked({ categoryParentIds.isEmpty }) {
            listCategories { [weak self] _ in
                guard let self = self else { return }
                self.requestCategoryRooms(areaId: areaId, page: page, completion: completion)
            }
            return
        }
        requestCategoryRooms(areaId: areaId, page: page, completion: completion)
    }

    private func requestCategoryRooms(areaId: String, page: Int, completion: @escaping (Result<[LiveRoom], Error>) -> Void) {
        guard let parentId = locked({ categoryParentIds[areaId] }) else {
            completion(.success([]))
            return
        }
        let currentPage = max(1, page)
        fetchAccessId { [weak self] accessId in
            guard let self = self else { return }
            let raw = "\(BilibiliLiveSite.categoryRoomsBaseURL)?platform=web&parent_area_id=\(parentId)&area_id=\(areaId)&sort_type=online&page=\(currentPage)&w_webid=\(accessId)"
            self.signedJSON(raw: raw, forceRefresh: false) { [weak self] json in
                guard let self = self else { return }
                if let rooms = BilibiliLiveSite.parseCategoryRooms(json) {
                    completion(.success(rooms))
                    return
                }
                LiveHTTP.after(milliseconds: 180) { [weak self] in
                    guard let self = self else { return }
                    // (b49fix2 P2-21) An empty w_webid answers
                    // -352: re-signing the same empty param cannot
                    // fix it. Retry once without the w_webid param
                    // at all (the WBI signature still covers the
                    // remaining params) before giving up.
                    let retryRaw: String
                    if accessId.isEmpty {
                        retryRaw = "\(BilibiliLiveSite.categoryRoomsBaseURL)?platform=web&parent_area_id=\(parentId)&area_id=\(areaId)&sort_type=online&page=\(currentPage)"
                    } else {
                        retryRaw = raw
                    }
                    self.signedJSON(raw: retryRaw, forceRefresh: true) { json in
                        if let rooms = BilibiliLiveSite.parseCategoryRooms(json) {
                            completion(.success(rooms))
                        } else {
                            completion(.failure(LiveError.emptyResponse))
                        }
                    }
                }
            }
        }
    }

    /// Room search (Dart `searchRooms`, search_type 'live').
    /// Matches title AND anchor nick on the server side.
    func searchRooms(query: String, page: Int, pageSize: Int, completion: @escaping (Result<[LiveRoom], Error>) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.success([]))
            return
        }
        let size = min(50, max(1, pageSize))
        headers { [weak self] headers in
            guard let self = self else { return }
            guard let url = LiveListURL.url(base: BilibiliLiveSite.searchURL, params: [
                ("context", ""), ("search_type", "live"), ("cover_type", "user_cover"),
                ("order", ""), ("keyword", trimmed), ("category_id", ""),
                ("__refresh__", ""), ("_extra", ""), ("highlight", "0"),
                ("single_column", "0"), ("page", "\(max(1, page))"), ("page_size", "\(size)")
            ]) else {
                completion(.failure(LiveError.emptyResponse))
                return
            }
            LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: headers, fetcher: self.fetcher) { json in
                if let rooms = BilibiliLiveSite.parseSearchRooms(json) {
                    completion(.success(rooms))
                } else {
                    completion(.failure(LiveError.emptyResponse))
                }
            }
        }
    }

    // MARK: - WBI + access id

    /// WBI-signed GET returning decoded JSON (Dart `_getWbiJson`):
    /// the signed param map is passed as the query of a request
    /// against the bare base URL so values are encoded once.
    private func signedJSON(raw: String, forceRefresh: Bool, completion: @escaping ([String: Any]?) -> Void) {
        headers { [weak self] headers in
            guard let self = self else { return }
            self.wbiSigner.signUrl(raw, forceRefresh: forceRefresh) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let params):
                    let base = raw.components(separatedBy: "?")[0]
                    let pairs = params.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
                    guard let url = LiveListURL.url(base: base, params: pairs) else {
                        completion(nil)
                        return
                    }
                    LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: headers, fetcher: self.fetcher, completion: completion)
                case .failure:
                    completion(nil)
                }
            }
        }
    }

    /// w_webid for second/getList, scraped from the live home page
    /// (Dart `getAccessId`): an empty w_webid answers -352, so the
    /// scrape is best-effort and the request still goes out.
    private func fetchAccessId(completion: @escaping (String) -> Void) {
        let cached: String? = locked { accessId.isEmpty ? nil : accessId }
        if let cached = cached {
            completion(cached)
            return
        }
        let alreadyInFlight = locked {
            accessIdCompletions.append(completion)
            if accessIdInFlight {
                return true
            }
            accessIdInFlight = true
            return false
        }
        if alreadyInFlight {
            return
        }
        headers { [weak self] headers in
            guard let self = self else { return }
            guard let url = URL(string: BilibiliLiveSite.accessIdURL) else {
                self.finishAccessIdFetch("")
                return
            }
            var request = URLRequest(url: url, timeoutInterval: LiveHTTP.defaultTimeoutSeconds)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            self.fetcher(request) { [weak self] data, _, _ in
                guard let self = self else { return }
                var found = ""
                if let data = data, let html = String(data: data, encoding: .utf8),
                   let regex = try? NSRegularExpression(pattern: "\"access_id\":\"(.*?)\"", options: []),
                   let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
                   let range = Range(match.range(at: 1), in: html) {
                    found = String(html[range]).replacingOccurrences(of: "\\", with: "")
                }
                self.finishAccessIdFetch(found)
            }
        }
    }

    private func finishAccessIdFetch(_ value: String) {
        let completions = locked {
            accessId = value
            accessIdInFlight = false
            let completions = accessIdCompletions
            accessIdCompletions = []
            return completions
        }
        for item in completions {
            item(value)
        }
    }

    // MARK: - Pure parsers (fixture-testable, no network)

    /// Parses both the ranked list (`recommend_room_list`) and the
    /// webMain fallback (a bare list in `data`). Nil when the
    /// response is not a code-0 object; [] is a real empty page.
    static func parseRecommendRooms(_ json: [String: Any]?) -> [LiveRoom]? {
        guard let json = json, LiveJSON.asInt(json["code"]) == 0 else { return nil }
        let data = json["data"]
        let rawList: [Any]?
        if let map = LiveJSON.asMap(data) {
            rawList = map["recommend_room_list"] as? [Any]
        } else {
            rawList = data as? [Any]
        }
        guard let list = rawList else { return nil }
        var rooms: [LiveRoom] = []
        for raw in list {
            guard let item = LiveJSON.asMap(raw) else { continue }
            let rawId = item["roomid"] ?? item["room_id"]
            let roomId = LiveJSON.asString(rawId)
            guard !roomId.isEmpty else { continue }
            let rawCover = LiveJSON.asString(item["cover"])
            let coverSource = rawCover.isEmpty ? LiveJSON.asString(item["user_cover"]) : rawCover
            let cover = BilibiliLiveSite.normalizeImageURL(coverSource)
            rooms.append(LiveRoom(
                roomId: roomId, platform: .bilibili,
                title: LiveJSON.asString(item["title"]),
                streamer: LiveJSON.asString(item["uname"]),
                avatar: BilibiliLiveSite.normalizeImageURL(LiveJSON.asString(item["face"])),
                cover: BilibiliLiveSite.sizedCover(cover),
                onlineCount: LiveJSON.asInt(item["online"]),
                isLive: true,
                link: LivePlatform.bilibili.roomLink(roomId: roomId)))
        }
        return BilibiliLiveSite.sortRoomsByPopularity(rooms)
    }

    /// The list payload can be a recommendation snapshot, and even
    /// the ranked endpoint can contain small adjacent inversions
    /// while heat changes. Re-sort the values shown on the cards
    /// and use room identity for stable ties so the visible
    /// ranking is always deterministic.
    static func sortRoomsByPopularity(_ rooms: [LiveRoom]) -> [LiveRoom] {
        rooms.sorted {
            if $0.onlineCount != $1.onlineCount { return $0.onlineCount > $1.onlineCount }
            return $0.roomId < $1.roomId
        }
    }

    /// Flattens the parent -> sub-area tree into sub-areas and
    /// keeps each sub-area's parent id (third tuple element) for
    /// categoryRooms. Nil when the response is not a code-0 object.
    static func parseCategories(_ json: [String: Any]?) -> [(id: String, name: String, parentId: String)]? {
        guard let json = json, LiveJSON.asInt(json["code"]) == 0 else { return nil }
        var areas: [(id: String, name: String, parentId: String)] = []
        for parent in LiveJSON.asList(json["data"]) {
            let parentId = LiveJSON.asString(parent["id"])
            for sub in LiveJSON.asList(parent["list"]) {
                let areaId = LiveJSON.asString(sub["id"])
                guard !areaId.isEmpty else { continue }
                areas.append((id: areaId, name: LiveJSON.asString(sub["name"]), parentId: parentId))
            }
        }
        return areas
    }

    /// Parses a second/getList response (`data.list[]`). Nil when
    /// the response is not a code-0 object.
    static func parseCategoryRooms(_ json: [String: Any]?) -> [LiveRoom]? {
        guard let json = json, LiveJSON.asInt(json["code"]) == 0 else { return nil }
        guard let data = LiveJSON.asMap(json["data"]) else { return nil }
        var rooms: [LiveRoom] = []
        for item in LiveJSON.asList(data["list"]) {
            let roomId = LiveJSON.asString(item["roomid"])
            guard !roomId.isEmpty else { continue }
            let cover = BilibiliLiveSite.normalizeImageURL(LiveJSON.asString(item["cover"]))
            rooms.append(LiveRoom(
                roomId: roomId, platform: .bilibili,
                title: LiveJSON.asString(item["title"]),
                streamer: LiveJSON.asString(item["uname"]),
                avatar: BilibiliLiveSite.normalizeImageURL(LiveJSON.asString(item["face"])),
                cover: BilibiliLiveSite.sizedCover(cover),
                onlineCount: LiveJSON.asInt(item["online"]),
                isLive: true,
                link: LivePlatform.bilibili.roomLink(roomId: roomId)))
        }
        return BilibiliLiveSite.sortRoomsByPopularity(rooms)
    }

    /// Parses a search/type response (`data.result.live_room[]`).
    /// Nil when the response is not a code-0 object.
    static func parseSearchRooms(_ json: [String: Any]?) -> [LiveRoom]? {
        guard let json = json, LiveJSON.asInt(json["code"]) == 0 else { return nil }
        guard let data = LiveJSON.asMap(json["data"]),
              let result = LiveJSON.asMap(data["result"]) else { return nil }
        var rooms: [LiveRoom] = []
        for item in LiveJSON.asList(result["live_room"]) {
            let roomId = LiveJSON.asString(item["roomid"])
            guard !roomId.isEmpty else { continue }
            rooms.append(LiveRoom(
                roomId: roomId, platform: .bilibili,
                title: BilibiliLiveSite.stripEmTags(LiveJSON.asString(item["title"])),
                streamer: LiveJSON.asString(item["uname"]),
                avatar: BilibiliLiveSite.searchCover(item["uface"]),
                cover: BilibiliLiveSite.searchCover(item["cover"]),
                onlineCount: LiveJSON.asInt(item["online"]),
                isLive: BilibiliLiveSite.isPlayableLiveStatus(item["live_status"]),
                link: LivePlatform.bilibili.roomLink(roomId: roomId)))
        }
        return rooms
    }

    /// Port of Pure Live's normalizeNetworkImageUrl:
    /// protocol-relative links get https:, bare hosts get https://,
    /// anything else unusable becomes ''.
    static func normalizeImageURL(_ source: String?) -> String {
        var value = (source ?? "").trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.lowercased() != "null" else { return "" }
        let doubleQuoted = value.hasPrefix("\"") && value.hasSuffix("\"")
        let singleQuoted = value.hasPrefix("'") && value.hasSuffix("'")
        if value.count >= 2 && (doubleQuoted || singleQuoted) {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !value.isEmpty else { return "" }
        if value.hasPrefix("//") { return "https:\(value)" }
        if let url = URL(string: value), let scheme = url.scheme,
           (scheme == "http" || scheme == "https"), !(url.host ?? "").isEmpty {
            return value
        }
        if !value.contains(" "),
           value.range(of: "^[\\w.-]+\\.[a-zA-Z]{2,}([/:?#]|$)", options: .regularExpression) != nil {
            return "https://\(value)"
        }
        return ""
    }

    /// Search results highlight the keyword with <em class="keyword">
    /// tags; strip them before display.
    static func stripEmTags(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<.*?em.*?>", options: []) else { return value }
        return regex.stringByReplacingMatches(in: value, options: [], range: NSRange(value.startIndex..., in: value), withTemplate: "")
    }

    /// Search cover/uface: protocol-relative ('//i0.hdslb.com/…') ->
    /// https, served at 400w (suffix only when the URL carries no
    /// suffix or query yet — b49fix2 P2-20).
    static func searchCover(_ raw: Any?) -> String {
        let value = LiveJSON.asString(raw).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return "" }
        let withScheme = value.hasPrefix("//") ? "https:\(value)" : value
        return BilibiliLiveSite.sizedCover(withScheme)
    }

    /// 400w cover suffix (b49fix2 P2-20): appending `@400w.jpg`
    /// unconditionally broke cover URLs that already carry a
    /// suffix or query params — append only when neither is
    /// present.
    static func sizedCover(_ cover: String) -> String {
        guard !cover.isEmpty else { return "" }
        if cover.contains("@") || cover.contains("?") { return cover }
        return "\(cover)@400w.jpg"
    }
}

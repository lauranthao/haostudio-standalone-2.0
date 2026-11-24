// HAo Studio 2.0 — Kuaishou live site (S4 leg B).
//
// Swift port of the Flutter `lib/shared/platforms/kuaishou/
// kuaishou_site.dart` (room detail, qualities, resolve) +
// `kuaishou_room_parser.dart` (initial-state scrape, quality
// parsing) + `kuaishou_models.dart` (play descriptors).
//
// Room detail: HTML scrape — GET `https://live.kuaishou.com/u/
// <roomId>`, `window.__INITIAL_STATE__` -> `liveroom.playList[0]`
// (fallback: legacy top-level `room` object). Balanced-brace
// extraction (string-aware), so a `;` or `</script>` inside a JSON
// string value cannot truncate the state the way a non-greedy
// regex can; the upstream regex is kept as a fallback.
//
// ROOMID RULE: the room identifier is `author.id`, NEVER
// `liveStream.id`. The live-stream id is only the danmaku/feed
// credential (`danmakuData['liveStreamId']`) and the `link` value
// for the native kwai:// deep link.
//
// Qualities: `playUrls` descriptors, each with
// `adaptationSet.representation[]` (one entry per quality, each
// with a signed URL). `{h264|avc}` descriptors first, then
// `{hevc|h265}`; same name+sort merged across CDNs into one
// quality -> N lines. No re-signing: the URLs arrive signed.
// Kuaishou URLs carry no wsTime-style lease, so refreshAt /
// invalidAt stay nil; the signed URLs expire on the server's own
// txTime.
//
// Scope: room parse + room info + resolve only. Search, lists and
// categories are not this leg's work and are not ported.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

// MARK: - Stream format / labels (pure)

extension KuaishouLiveSite {
    /// Declared stream format for one Kuaishou play URL, from its
    /// path suffix (the server signs the transport into the URL
    /// itself — no re-signing, no format field on the
    /// representation). Unknown suffixes report `other` so the
    /// player probes instead of assuming.
    static func kuaishouStreamFormat(_ url: String) -> String {
        let path = url.components(separatedBy: "?")[0].lowercased()
        if path.hasSuffix(".m3u8") {
            return "hls"
        }
        if path.hasSuffix(".flv") {
            return "flv"
        }
        return "other"
    }

    /// Normalise a Kuaishou quality label for display, without
    /// changing the opaque id used to request that stream. CJK
    /// labels (what Kuaishou actually serves: 高清 / 超清 / 蓝光 4M /
    /// 蓝光 质臻) pass through untouched; bare SDK tokens map onto
    /// the same vocabulary.
    static func normalizeKuaishouQualityLabel(_ rawLabel: String) -> String {
        let raw = rawLabel.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if containsCJK(raw) {
            return raw
        }
        let token = raw.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        switch token {
        case "original", "origin", "origion", "source":
            return "原画"
        case "blue", "bluray", "blueray":
            return "蓝光"
        case "uhd", "super", "superhd", "fullhd", "fhd":
            return "超清"
        case "hd", "high":
            return "高清"
        case "sd", "standard", "medium":
            return "标清"
        case "low", "ld", "smooth", "fluent":
            return "流畅"
        case "auto":
            return "自动"
        case "default":
            return "默认"
        default:
            return raw.isEmpty ? "默认" : raw
        }
    }

    private static func containsCJK(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "[\\u{3400}-\\u{9fff}]", options: []) else {
            return false
        }
        return regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
    }
}

// MARK: - Room parser (pure, fixture-testable)

extension KuaishouLiveSite {
    /// Parse `window.__INITIAL_STATE__` out of a room-page HTML
    /// document. Throws when no parseable state is found.
    static func extractKuaishouInitialState(html: String) throws -> [String: Any] {
        let marker = "window.__INITIAL_STATE__"
        if let markerRange = html.range(of: marker),
           let braceStart = html[markerRange.upperBound...].firstIndex(of: "\u{7B}"),
           let end = matchingBraceEnd(html, start: braceStart),
           let decoded = decodeStateJson(String(html[braceStart..<end])) {
            return decoded
        }
        let pattern = "window\\.__INITIAL_STATE__\\s*=\\s*(.*?);\\s*</script>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
           match.numberOfRanges >= 2,
           let captureRange = Range(match.range(at: 1), in: html),
           let decoded = decodeStateJson(String(html[captureRange])) {
            return decoded
        }
        throw LiveError.parseFailed("快手初始状态缺失")
    }

    private static func decodeStateJson(_ text: String) -> [String: Any]? {
        // The state embeds bare `undefined` values; JSON needs `null`.
        let replaced = text.replacingOccurrences(of: "undefined", with: "null")
        guard let data = replaced.data(using: .utf8) else {
            return nil
        }
        return LiveJSON.decodeObject(data)
    }

    /// Index just past the `}` matching the `{` at `start`, or nil
    /// when the braces never balance (or a string never terminates).
    static func matchingBraceEnd(_ text: String, start: String.Index) -> String.Index? {
        let chars = Array(text[start...])
        var depth = 0
        var inString = false
        var escaped = false
        for (offset, ch) in chars.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }
            if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return text.index(start, offsetBy: offset + 1)
                }
            }
        }
        return nil
    }

    /// Parse a Kuaishou room page into a `LiveRoom`.
    ///
    /// Reads `liveroom.playList[0]` (current shape), falling back to
    /// a top-level `room` object (older shape). The room id is
    /// `author.id`; the live-stream id goes to
    /// `danmakuData['liveStreamId']` and `link` only. An offline room
    /// (empty `liveStream`, `isLiving: false`, no `errorType` card)
    /// parses as `isLive: false` with whatever author info the page
    /// carried — never throws for a reachable page. A page carrying
    /// a nonzero `errorType` card (type 2 = rate-limit "请求过快，
    /// 请稍后重试", verified live 2026-11-24 on every room page
    /// from a flagged client) is a transient platform refusal, NOT
    /// an offline room: it throws `LiveError.apiRejected` so
    /// callers can tell it apart from "主播未开播" and fall back to
    /// data they already hold. Throws when the page carries no room
    /// metadata at all.
    static func parseKuaishouRoomPage(html: String, roomId: String) throws -> LiveRoom {
        let state = try extractKuaishouInitialState(html: html)
        var room: [String: Any]?
        if let liveRoom = LiveJSON.asMap(state["liveroom"]),
           let playList = liveRoom["playList"] as? [Any], !playList.isEmpty,
           let first = LiveJSON.asMap(playList[0]) {
            room = first
        }
        if room == nil {
            room = LiveJSON.asMap(state["room"])
        }
        guard let room = room else {
            throw LiveError.parseFailed("快手房间元数据缺失")
        }
        if let errorType = LiveJSON.asMap(room["errorType"]),
           let code = LiveJSON.asIntOrNil(errorType["type"]), code != 0 {
            let title = LiveJSON.asString(errorType["title"])
            throw LiveError.apiRejected(code: code, message: title.isEmpty ? "快手房间加载被拒绝" : title)
        }
        let liveStream = LiveJSON.asMap(room["liveStream"]) ?? [:]
        let author = LiveJSON.asMap(room["author"]) ?? [:]
        let gameInfo = LiveJSON.asMap(room["gameInfo"]) ?? [:]
        let rawLiveState = room["isLiving"]
        let live = (rawLiveState as? Bool) == true
            || (LiveJSON.asIntOrNil(rawLiveState) ?? 0) == 1
            || LiveJSON.asString(rawLiveState).lowercased() == "true"
        let description = LiveJSON.asString(author["description"])
        let liveStreamId = LiveJSON.asString(liveStream["id"])
        let poster = LiveJSON.asString(liveStream["poster"])
        let playUrls = liveStream["playUrls"]
        return LiveRoom(
            roomId: LiveJSON.asString(author["id"]).isEmpty ? roomId : LiveJSON.asString(author["id"]),
            platform: .kuaishou,
            title: description.replacingOccurrences(of: "\n", with: " "),
            streamer: LiveJSON.asString(author["name"]),
            avatar: LiveJSON.asString(author["avatar"]),
            cover: posterUrl(poster),
            onlineCount: live ? (LiveJSON.asIntOrNil(gameInfo["watchingCount"]) ?? 0) : 0,
            isLive: live,
            link: liveStreamId,
            data: playUrls == nil ? nil : ["playUrls": playUrls!],
            danmakuData: liveStreamId.isEmpty ? nil : ["liveStreamId": liveStreamId]
        )
    }

    /// Parse Kuaishou `playUrls` descriptors into qualities.
    ///
    /// Both current room-page and recommendation payloads are
    /// handled: room pages expose `{h264: ..., hevc: ...}` while
    /// list/replay entries are usually a direct adaptation-set
    /// descriptor. Multiple descriptors can represent CDN lines, so
    /// URLs of the same quality are merged and deduped into one
    /// quality -> N lines. An empty result means the room is
    /// unplayable — callers return it as-is, never invent a quality.
    static func parseKuaishouPlayQualities(_ raw: Any?) -> [LiveQuality] {
        let descriptors: [Any]
        if let list = raw as? [Any] {
            descriptors = list
        } else if raw != nil {
            descriptors = [raw!]
        } else {
            descriptors = []
        }
        struct MergedQuality {
            var name: String
            var sort: Int
            var codecRank: Int
            var urls: [String]
        }
        var merged: [String: MergedQuality] = [:]
        for rawDescriptor in descriptors {
            guard let descriptor = rawDescriptor as? [String: Any] else {
                continue
            }
            struct CodecSet {
                var suffix: String
                var codecRank: Int
                var codec: String?
                var descriptor: [String: Any]
            }
            var sets: [CodecSet] = []
            for codec in ["h264", "avc"] {
                if let candidate = LiveJSON.asMap(descriptor[codec]), !representationsOf(candidate).isEmpty {
                    sets.append(CodecSet(suffix: "", codecRank: 0, codec: "avc", descriptor: candidate))
                    break
                }
            }
            for codec in ["hevc", "h265"] {
                if let candidate = LiveJSON.asMap(descriptor[codec]), !representationsOf(candidate).isEmpty {
                    sets.append(CodecSet(suffix: " · H.265", codecRank: 1, codec: "hevc", descriptor: candidate))
                    break
                }
            }
            if sets.isEmpty {
                sets.append(CodecSet(suffix: "", codecRank: 0, codec: nil, descriptor: descriptor))
            }
            for set in sets {
                for item in representationsOf(set.descriptor) {
                    guard let item = item as? [String: Any] else {
                        continue
                    }
                    let url = LiveJSON.asString(item["url"]).trimmingCharacters(in: .whitespaces)
                    guard let uri = URL(string: url), let scheme = uri.scheme, (scheme == "http" || scheme == "https") else {
                        continue
                    }
                    let sort = LiveJSON.asIntOrNil(item["level"]) ?? LiveJSON.asIntOrNil(item["bitrate"]) ?? 0
                    let rawName: String
                    if !LiveJSON.asString(item["name"]).trimmingCharacters(in: .whitespaces).isEmpty {
                        rawName = LiveJSON.asString(item["name"]).trimmingCharacters(in: .whitespaces)
                    } else if !LiveJSON.asString(item["shortName"]).trimmingCharacters(in: .whitespaces).isEmpty {
                        rawName = LiveJSON.asString(item["shortName"]).trimmingCharacters(in: .whitespaces)
                    } else if !LiveJSON.asString(item["qualityType"]).trimmingCharacters(in: .whitespaces).isEmpty {
                        rawName = LiveJSON.asString(item["qualityType"]).trimmingCharacters(in: .whitespaces)
                    } else {
                        rawName = "清晰度 \(sort)"
                    }
                    let name = set.suffix.isEmpty ? rawName : "\(rawName)\(set.suffix)"
                    let key = "\(name)\u{0000}\(sort)"
                    if var existing = merged[key] {
                        if !existing.urls.contains(url) {
                            existing.urls.append(url)
                            merged[key] = existing
                        }
                    } else {
                        merged[key] = MergedQuality(
                            name: name,
                            sort: sort,
                            codecRank: set.codecRank,
                            urls: [url]
                        )
                    }
                }
            }
        }
        let entries = merged.values.sorted {
            if $0.codecRank != $1.codecRank {
                return $0.codecRank < $1.codecRank
            }
            return $0.sort > $1.sort
        }
        return entries.map { entry in
            let lines = entry.urls.map { url in
                LiveLine(
                    name: URL(string: url)?.host ?? url,
                    urls: [url],
                    format: kuaishouStreamFormat(url)
                )
            }
            return LiveQuality(
                id: "\(entry.name)\u{0000}\(entry.sort)",
                name: normalizeKuaishouQualityLabel(entry.name),
                sort: entry.sort,
                lines: lines
            )
        }
    }

    private static func representationsOf(_ descriptor: [String: Any]) -> [Any] {
        if let adaptationSet = LiveJSON.asMap(descriptor["adaptationSet"]),
           let representations = adaptationSet["representation"] as? [Any] {
            return representations
        }
        if let representations = descriptor["representation"] as? [Any] {
            return representations
        }
        return []
    }

    /// Appends `.jpg` when a poster URL carries no image extension;
    /// an empty poster stays empty (never `null.jpg`).
    static func posterUrl(_ poster: String) -> String {
        if poster.isEmpty {
            return ""
        }
        return isImage(poster) ? poster : "\(poster).jpg"
    }

    private static func isImage(_ url: String) -> Bool {
        let imageExtensions: Set<String> = [
            "svgz", "pjp", "png", "ico", "avif", "tiff", "tif", "jfif", "svg",
            "xbm", "pjpeg", "webp", "jpg", "jpeg", "bmp", "gif"
        ]
        if url.isEmpty {
            return false
        }
        let ext = url.components(separatedBy: ".").last?.lowercased().components(separatedBy: "?").first ?? ""
        return imageExtensions.contains(ext)
    }
}

// MARK: - Site

final class KuaishouLiveSite: LiveSiteResolver {
    var platform: LivePlatform {
        .kuaishou
    }

    private let fetcher: LiveDataFetcher

    private static let headers: [String: String] = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36",
        "accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3",
        "connection": "keep-alive",
        "sec-ch-ua": "Google Chrome;v=107, Chromium;v=107, Not=A?Brand;v=24",
        "sec-ch-ua-platform": "macOS",
        "Sec-Fetch-Dest": "document",
        "Sec-Fetch-Mode": "navigate",
        "Sec-Fetch-Site": "same-origin",
        "Sec-Fetch-User": "?1"
    ]

    private static let roomBaseUrl = "https://live.kuaishou.com/u"

    init(fetcher: LiveDataFetcher? = nil) {
        self.fetcher = fetcher ?? LiveHTTP.defaultFetcher
    }

    func makeDanmakuTransport() -> LiveDanmakuTransport {
        KuaishouDanmaku(fetcher: fetcher)
    }

    // MARK: - Room info

    func roomInfo(roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        let trimmed = roomId.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            completion(.failure(LiveError.invalidRoomId))
            return
        }
        // A transient failure is reported as a failure, never
        // disguised as "offline" (build 36 item 8 — same reason
        // as Bilibili: the callers keep the card's values on
        // failure, and the disguise hid the LIVE badge, zeroed
        // the watching count and discarded the card's danmaku
        // credentials — the feed rooms carry liveStreamId, so a
        // rate-limited roomInfo used to kill danmaku outright).
        loadRoomDetail(roomId: trimmed, completion: completion)
    }

    /// Strict room load: throws when the page carries no parseable
    /// playback metadata (resolve must see the transient error,
    /// never a disguised "offline").
    private func loadRoomDetail(roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        guard let url = URL(string: "\(KuaishouLiveSite.roomBaseUrl)/\(roomId)") else {
            completion(.failure(LiveError.parseFailed("快手房间地址无效")))
            return
        }
        var headers = KuaishouLiveSite.headers
        headers["Accept"] = "text/html,application/xhtml+xml"
        let request = LiveHTTP.getRequest(url: url, headers: headers)
        fetcher(request) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data, let html = String(data: data, encoding: .utf8), !html.isEmpty else {
                completion(.failure(LiveError.emptyResponse))
                return
            }
            do {
                completion(.success(try KuaishouLiveSite.parseKuaishouRoomPage(html: html, roomId: roomId)))
            } catch {
                completion(.failure(error))
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
        loadRoomDetail(roomId: trimmed) { result in
            switch result {
            case .success(let room):
                if !room.isLive {
                    completion(.failure(LiveError.offline))
                    return
                }
                let playUrls = LiveJSON.asMap(room.data)?["playUrls"]
                let qualities = KuaishouLiveSite.parseKuaishouPlayQualities(playUrls)
                if qualities.isEmpty {
                    completion(.failure(LiveError.offline))
                    return
                }
                let requested = qualities.first { $0.id == quality?.id } ?? qualities[0]
                completion(.success(LivePlayUrlResolution.applying(requested, in: qualities)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Resolve from a room the app already holds (list feed):
    /// the recommend / category feeds carry signed `playUrls`,
    /// so a room tapped straight from the list can play even when
    /// the room-page re-parse is rate-limited (`errorType` 2 —
    /// the room page answered the card on every probe 2026-11-24
    /// while the same feed's FLV URLs streamed live video).
    /// Nil when the room carries no playable URLs, so the caller
    /// falls through to the network resolve. No request is made
    /// here; the URLs are used as issued (same shape as `resolve`
    /// returns, minus a fresh re-parse).
    func resolutionFromRoom(_ room: LiveRoom, quality: LiveQuality?) -> LivePlayUrlResolution? {
        guard room.platform == .kuaishou else {
            return nil
        }
        let playUrls = LiveJSON.asMap(room.data)?["playUrls"]
        let qualities = KuaishouLiveSite.parseKuaishouPlayQualities(playUrls)
        guard !qualities.isEmpty else {
            return nil
        }
        let requested = qualities.first { $0.id == quality?.id } ?? qualities[0]
        return LivePlayUrlResolution.applying(requested, in: qualities)
    }
}

// MARK: - Lists (recommend / categories / search)
//
// Port of the Flutter `kuaishou_site.dart` list methods
// (getRecommendRooms / getCategories / getCategoryRooms /
// searchRooms) + `kuaishou_room_parser.dart` list parsers. The
// room-detail leg (S4-B) left these out; the live tab's gateway
// needs them. Every method completes with [] on any failure —
// a list failure is an empty list, never a throw out of the
// completion handler. All parsing is pure + static so fixtures
// can cover it without network.
//
// ROOMID RULE (same as room detail): the room identifier is
// `author.id`, NEVER `liveStream.id`. The live-stream id is
// only the danmaku/feed credential (`danmakuData['liveStreamId']`)
// and the `link` value.

extension KuaishouLiveSite {
    private static let recommendURL = "https://live.kuaishou.com/live_api/home/list"
    private static let categoryDataURL = "https://live.kuaishou.com/live_api/category/data"
    private static let gameboardURL = "https://live.kuaishou.com/live_api/gameboard/list"
    private static let nonGameboardURL = "https://live.kuaishou.com/live_api/non-gameboard/list"
    private static let authorSearchURL = "https://live.kuaishou.com/live_api/search/author"
    private static let categoryPageSize = 50

    /// Home hot list via `live_api/home/list` (Dart
    /// `getRecommendRooms`): no pagination server-side; the page
    /// slice is taken client-side.
    func recommendRooms(page: Int, pageSize: Int, completion: @escaping ([LiveRoom]) -> Void) {
        let size = min(100, max(1, pageSize))
        let currentPage = max(1, page)
        guard let url = URL(string: KuaishouLiveSite.recommendURL) else {
            completion([])
            return
        }
        LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: KuaishouLiveSite.headers, fetcher: fetcher) { json in
            guard let rooms = KuaishouLiveSite.parseRecommendRooms(json) else {
                completion([])
                return
            }
            let start = (currentPage - 1) * size
            guard start < rooms.count else {
                completion([])
                return
            }
            completion(Array(rooms[start..<min(start + size, rooms.count)]))
        }
    }

    /// Categories (Dart `getCategories`, port of Pure Live 3.x
    /// `getCategores` + `getSubCategores`): eight fixed top types
    /// (热门 1 / 网游 2 / 单机 3 / 手游 4 / 棋牌 5 / 娱乐 6 /
    /// 综合 7 / 文化 8) from `live_api/category/data`. All types
    /// fetch in parallel; a full first page pulls one more page,
    /// capped at two. One dead type never kills the others; when
    /// every fetch fails, the verified-popular fallback below is
    /// returned so the tab never shows a blank category row.
    func listCategories(completion: @escaping ([(id: String, name: String)]) -> Void) {
        let types = ["1", "2", "3", "4", "5", "6", "7", "8"]
        var first: [[(id: String, name: String)]] = Array(repeating: [], count: types.count)
        let group = DispatchGroup()
        let lock = NSLock()
        for (index, type) in types.enumerated() {
            group.enter()
            fetchCategoryPage(type: type, page: 1) { areas in
                lock.lock()
                first[index] = areas
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: DispatchQueue.global(qos: .utility)) { [weak self] in
            guard let self = self else { return }
            var areas = first.flatMap { $0 }
            var fullTypes: [String] = []
            for (index, type) in types.enumerated() where first[index].count >= KuaishouLiveSite.categoryPageSize {
                fullTypes.append(type)
            }
            if fullTypes.isEmpty {
                completion(areas.isEmpty ? KuaishouLiveSite.fallbackCategories : areas)
                return
            }
            var second: [[(id: String, name: String)]] = Array(repeating: [], count: fullTypes.count)
            let secondGroup = DispatchGroup()
            for (index, type) in fullTypes.enumerated() {
                secondGroup.enter()
                self.fetchCategoryPage(type: type, page: 2) { pageAreas in
                    lock.lock()
                    second[index] = pageAreas
                    lock.unlock()
                    secondGroup.leave()
                }
            }
            secondGroup.notify(queue: DispatchQueue.global(qos: .utility)) {
                areas.append(contentsOf: second.flatMap { $0 })
                completion(areas.isEmpty ? KuaishouLiveSite.fallbackCategories : areas)
            }
        }
    }

    private func fetchCategoryPage(type: String, page: Int, completion: @escaping ([(id: String, name: String)]) -> Void) {
        guard let url = LiveListURL.url(base: KuaishouLiveSite.categoryDataURL, params: [
            ("type", type), ("page", "\(page)"), ("size", "\(KuaishouLiveSite.categoryPageSize)")
        ]) else {
            completion([])
            return
        }
        LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: KuaishouLiveSite.headers, fetcher: fetcher) { json in
            completion(KuaishouLiveSite.parseCategories(json) ?? [])
        }
    }

    /// Verified-popular categories per top type (live probe
    /// 2026-11-16, `category/data` first-page entries). Only used
    /// when all live fetches fail; ids are real, so category
    /// rooms load.
    static let fallbackCategories: [(id: String, name: String)] = [
        ("22008", "和平精英"), ("1001", "王者荣耀"), ("22484", "暗区突围"), ("22744", "格斗游戏"),
        ("2", "穿越火线"), ("21", "绝地求生"),
        ("1", "英雄联盟"), ("1009", "我的世界"), ("3", "地下城与勇士"), ("13", "守望先锋"),
        ("22762", "黑神话悟空"), ("22088", "经典单机"), ("15", "街机游戏"), ("22193", "植物大战僵尸"), ("22189", "红警"),
        ("22181", "原神"), ("1054", "QQ飞车手游"), ("22337", "蛋仔派对"),
        ("1018", "JJ斗地主"), ("22185", "天天象棋"), ("20", "三国杀"), ("6", "斗地主"), ("10", "象棋"), ("1017", "欢乐斗地主"),
        ("1000004", "才艺"), ("1000003", "音乐"), ("1000006", "颜值"), ("1000002", "舞蹈"), ("1000007", "情感"), ("1000005", "脱口秀"), ("1000001", "明星"),
        ("1000024", "其他"), ("1000020", "购物"), ("1000016", "健康"), ("1000021", "媒体"), ("1000011", "美妆"), ("1000008", "汽车"),
        ("1000023", "科普"), ("1000022", "教育")
    ]

    /// Category rooms (Dart `getCategoryRooms`, port of Pure Live
    /// 3.x): game boards (`gameboard/list`, short numeric ids) vs
    /// non-game boards (`non-gameboard/list`, long 10000xx ids),
    /// split on id length < 7.
    func categoryRooms(areaId: String, page: Int, pageSize: Int, completion: @escaping ([LiveRoom]) -> Void) {
        let base = areaId.count < 7 ? KuaishouLiveSite.gameboardURL : KuaishouLiveSite.nonGameboardURL
        guard let url = LiveListURL.url(base: base, params: [
            ("filterType", "0"), ("pageSize", "20"), ("gameId", areaId), ("page", "\(max(1, page))")
        ]) else {
            completion([])
            return
        }
        LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: KuaishouLiveSite.headers, fetcher: fetcher) { json in
            completion(KuaishouLiveSite.parseCategoryRooms(json) ?? [])
        }
    }

    /// Author search (Dart `searchRooms`): returns ANCHORS as
    /// rooms (no viewer count, only a `living` flag). The web
    /// search page never lists rooms, so finding the anchor and
    /// opening their room is the whole flow.
    func searchRooms(query: String, page: Int, pageSize: Int, completion: @escaping ([LiveRoom]) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion([])
            return
        }
        var headers = KuaishouLiveSite.headers
        headers["Referer"] = "https://live.kuaishou.com/search?keyword=\(LiveQuery.percentEncode(trimmed))"
        guard let url = LiveListURL.url(base: KuaishouLiveSite.authorSearchURL, params: [
            ("keyword", trimmed), ("page", "\(max(1, page))"), ("lssid", "")
        ]) else {
            completion([])
            return
        }
        LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: headers, fetcher: fetcher) { json in
            let rooms = KuaishouLiveSite.parseAuthorSearch(json) ?? []
            completion(Array(rooms.prefix(min(100, max(1, pageSize)))))
        }
    }

    // MARK: - Pure parsers (fixture-testable, no network)

    /// Parses a `live_api/home/list` response
    /// (`data.list[].gameLiveInfo[].liveInfo[]`) into rooms.
    /// Nil when the response has no room list.
    static func parseRecommendRooms(_ json: [String: Any]?) -> [LiveRoom]? {
        guard let json = json,
              let data = LiveJSON.asMap(json["data"]) else { return nil }
        var rooms: [LiveRoom] = []
        for section in LiveJSON.asList(data["list"]) {
            for group in LiveJSON.asList(section["gameLiveInfo"]) {
                for item in LiveJSON.asList(group["liveInfo"]) {
                    if let room = KuaishouLiveSite.roomFromFeedItem(item, title: nil) {
                        rooms.append(room)
                    }
                }
            }
        }
        return rooms
    }

    /// Parses a `live_api/gameboard/list` /
    /// `non-gameboard/list` response into rooms. Items are FLAT
    /// here (author/caption/poster/playUrls on the item itself),
    /// unlike the nested `gameLiveInfo[].liveInfo[]` shape of the
    /// recommend feed — hence a separate parser. Field mapping
    /// mirrors `parseRecommendRooms`: room id is `author.id`,
    /// never the live-stream id.
    static func parseCategoryRooms(_ json: [String: Any]?) -> [LiveRoom]? {
        guard let json = json,
              let data = LiveJSON.asMap(json["data"]) else { return nil }
        var rooms: [LiveRoom] = []
        for item in LiveJSON.asList(data["list"]) {
            let author = LiveJSON.asMap(item["author"]) ?? [:]
            let authorId = LiveJSON.asString(author["id"])
            guard !authorId.isEmpty else { continue }
            let caption = LiveJSON.asString(item["caption"])
            let description = LiveJSON.asString(author["description"])
            let title = caption.isEmpty ? description : caption
            if let room = KuaishouLiveSite.roomFromFeedItem(item, title: title) {
                rooms.append(room)
            }
        }
        return rooms
    }

    /// One feed item (recommend `liveInfo` or flat category item)
    /// into a room. `title` overrides the author description
    /// when the caller supplies one (category items carry a
    /// caption); nil keeps the description.
    private static func roomFromFeedItem(_ item: [String: Any], title: String?) -> LiveRoom? {
        let author = LiveJSON.asMap(item["author"]) ?? [:]
        let gameInfo = LiveJSON.asMap(item["gameInfo"]) ?? [:]
        let authorId = LiveJSON.asString(author["id"])
        guard !authorId.isEmpty else { return nil }
        let liveStreamId = LiveJSON.asString(item["id"])
        let description = LiveJSON.asString(author["description"])
        let titleText = (title ?? description).replacingOccurrences(of: "\n", with: " ")
        let streamPoster = LiveJSON.asString(item["poster"])
        let gamePoster = LiveJSON.asString(gameInfo["poster"])
        let cover = streamPoster.isEmpty ? gamePoster : streamPoster
        let playUrls = item["playUrls"]
        // `living` no longer reports live status in the feeds
        // (verified 2026-11-24: 48/48 home/list items and 20/20
        // gameboard items carry `living: false` while their signed
        // playUrls stream live FLV). A false flag therefore must
        // not mark a room offline: an item is live when the flag
        // says so, or when it carries playable stream URLs. With
        // no flag at all the old default (live) stands; a flag that
        // is present but not a Bool falls through to the URL check.
        let hasPlayableUrls = !KuaishouLiveSite.parseKuaishouPlayQualities(playUrls).isEmpty
        let live: Bool
        if let livingFlag = item["living"] as? Bool {
            live = livingFlag || hasPlayableUrls
        } else if item["living"] == nil {
            live = true
        } else {
            live = hasPlayableUrls
        }
        return LiveRoom(
            roomId: authorId, platform: .kuaishou,
            title: titleText,
            streamer: LiveJSON.asString(author["name"]),
            avatar: LiveJSON.asString(author["avatar"]),
            cover: KuaishouLiveSite.posterUrl(cover),
            onlineCount: LiveJSON.asInt(item["watchingCount"]),
            isLive: live,
            link: liveStreamId,
            data: playUrls == nil ? nil : ["playUrls": playUrls as Any],
            danmakuData: liveStreamId.isEmpty ? nil : ["liveStreamId": liveStreamId])
    }

    /// Parses a `live_api/category/data` response
    /// (`data.list[]` of `{id, name, poster}`) into flat areas.
    /// Nil when the response has no category list.
    static func parseCategories(_ json: [String: Any]?) -> [(id: String, name: String)]? {
        guard let json = json,
              let data = LiveJSON.asMap(json["data"]) else { return nil }
        var areas: [(id: String, name: String)] = []
        for item in LiveJSON.asList(data["list"]) {
            let id = LiveJSON.asString(item["id"])
            let name = LiveJSON.asString(item["name"])
            guard !id.isEmpty, !name.isEmpty else { continue }
            areas.append((id: id, name: name))
        }
        return areas
    }

    /// Parses the `live_api/search/author` response into anchor
    /// rooms. The endpoint returns ANCHORS, not rooms: no viewer
    /// count, only a `living` flag (and `bannedStatus`). A
    /// Kuaishou search therefore finds the anchor; opening the
    /// anchor's room fetches the live detail. `watching` is 0
    /// (unknown, never a fabricated count) and banned anchors
    /// report offline. The room id is the anchor id.
    static func parseAuthorSearch(_ json: [String: Any]?) -> [LiveRoom]? {
        guard let json = json,
              let data = LiveJSON.asMap(json["data"]) else { return nil }
        var rooms: [LiveRoom] = []
        for author in LiveJSON.asList(data["list"]) {
            let id = LiveJSON.asString(author["id"]).trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { continue }
            let name = LiveJSON.asString(author["name"])
            let avatar = LiveJSON.asString(author["avatar"])
            let banned = LiveJSON.asMap(author["bannedStatus"])
            let isBanned = banned?["banned"] as? Bool == true
            let live = !isBanned && author["living"] as? Bool == true
            rooms.append(LiveRoom(
                roomId: id, platform: .kuaishou,
                title: name,
                streamer: name,
                avatar: avatar,
                cover: avatar,
                onlineCount: 0,
                isLive: live,
                link: "https://live.kuaishou.com/u/\(id)"))
        }
        return rooms
    }
}

// HAo Studio 2.0 — Huya live site (S4 leg B).
//
// Swift port of the Flutter `lib/shared/platforms/huya/huya_site.dart`
// (room detail, qualities, getPlayUrl waterfall, anonymous identity,
// lease math) + `huya_room_parser.dart` (balanced-brace HTML scrape)
// + `huya_models.dart` (line / bit-rate / play descriptor) +
// `huya_request_params.dart` + `huya_transport_policy.dart`
// (line identity after refresh).
//
// Room detail: HTML scrape — GET `https://www.huya.com/<roomId>`,
// `var TT_ROOM_DATA = {...}` + `stream: {...}`. The regexes LOCATE
// the blobs; extraction then scans balanced braces so nested objects
// are not truncated by the regex's non-greedy `}`.
// Qualities come from `vMultiStreamInfo` (bitRate 0 = 原画; `4K`
// excluded; never an invented fallback). Play URL:
// `<cdnBase>/<streamName>.flv|m3u8?<antiCode>` with `codec=264`
// appended when missing and `ratio` replaced by the bitrate
// (removed for 原画). FLV prefers the native WUP token (~420 s)
// then the web-template anti-code (~120 s) then a web WUP token;
// the native token is NEVER reused for HLS. FLV uses
// `sFlvAntiCode`, HLS `sHlsAntiCode`, never cross-used.
//
// Scope: room parse + room info + resolve only. Search, lists and
// categories are not this leg's work and are not ported.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

// MARK: - Models

enum HuyaLineType {
    case flv
    case hls
}

/// One CDN line (HuyaLineModel): one entry per (CDN, transport)
/// pair in `gameStreamInfoList`. `baseUrl` is the CDN base
/// (sFlvUrl / sHlsUrl); `cdnType` is the CDN name exactly as the
/// server returns it (AL / TX / HS … — never hard-coded, server
/// order is kept). `presenterUid` prefers the stream item's
/// `presenterUid` and falls back to the room's topSid.
struct HuyaLine {
    var baseUrl: String
    var lineType: HuyaLineType
    var flvAntiCode: String
    var hlsAntiCode: String
    var streamName: String
    var cdnType: String
    var presenterUid: Int
    /// Bitrate this line was last resolved for (carried by the
    /// model upstream; the quality menu owns the requested bitrate).
    var bitRate: Int

    init(
        baseUrl: String,
        lineType: HuyaLineType,
        flvAntiCode: String = "",
        hlsAntiCode: String = "",
        streamName: String = "",
        cdnType: String = "",
        presenterUid: Int = 0,
        bitRate: Int = 0
    ) {
        self.baseUrl = baseUrl
        self.lineType = lineType
        self.flvAntiCode = flvAntiCode
        self.hlsAntiCode = hlsAntiCode
        self.streamName = streamName
        self.cdnType = cdnType
        self.presenterUid = presenterUid
        self.bitRate = bitRate
    }
}

/// One quality entry from `vMultiStreamInfo`. `bitRate` is the
/// server's integer bitrate id; 0 = 原画.
struct HuyaBitRate {
    var bitRate: Int
    var name: String

    init(bitRate: Int, name: String) {
        self.bitRate = bitRate
        self.name = name
    }
}

/// Play descriptor for one room snapshot. Stored in
/// `LiveRoom.data` under the keys `lines` / `bitRates` /
/// `isXingxiu` / `uid` (the same keys as the Flutter port); the
/// arrays keep their typed values in memory.
struct HuyaUrlData {
    var lines: [HuyaLine]
    var bitRates: [HuyaBitRate]
    var uid: String
    var isXingxiu: Bool

    static let keyLines = "lines"
    static let keyBitRates = "bitRates"
    static let keyIsXingxiu = "isXingxiu"
    static let keyUid = "uid"

    init(lines: [HuyaLine] = [], bitRates: [HuyaBitRate] = [], uid: String = "", isXingxiu: Bool = false) {
        self.lines = lines
        self.bitRates = bitRates
        self.uid = uid
        self.isXingxiu = isXingxiu
    }

    func toDataMap() -> [String: Any] {
        [
            HuyaUrlData.keyLines: lines,
            HuyaUrlData.keyBitRates: bitRates,
            HuyaUrlData.keyIsXingxiu: isXingxiu,
            HuyaUrlData.keyUid: uid
        ]
    }

    /// Rebuild from a `LiveRoom.data` map; nil when the map is not
    /// a Huya play descriptor (e.g. a room that was never detailed).
    static func fromDataMap(_ data: [String: Any]?) -> HuyaUrlData? {
        guard let data = data else {
            return nil
        }
        guard let lines = data[keyLines] as? [HuyaLine], let bitRates = data[keyBitRates] as? [HuyaBitRate] else {
            return nil
        }
        return HuyaUrlData(
            lines: lines,
            bitRates: bitRates,
            uid: LiveJSON.asString(data[keyUid]),
            isXingxiu: (data[keyIsXingxiu] as? Bool) == true
        )
    }
}

/// Danmaku credentials for a room, stored as a plain map in
/// `LiveRoom.danmakuData` under `uid` / `topSid` / `subSid`.
struct HuyaDanmakuArgs {
    var uid: Int
    var topSid: Int
    var subSid: Int

    static let keyUid = "uid"
    static let keyTopSid = "topSid"
    static let keySubSid = "subSid"

    init(uid: Int = 0, topSid: Int = 0, subSid: Int = 0) {
        self.uid = uid
        self.topSid = topSid
        self.subSid = subSid
    }

    func toDataMap() -> [String: Any] {
        [
            HuyaDanmakuArgs.keyUid: uid,
            HuyaDanmakuArgs.keyTopSid: topSid,
            HuyaDanmakuArgs.keySubSid: subSid
        ]
    }

    static func fromDataMap(_ data: [String: Any]?) -> HuyaDanmakuArgs? {
        guard let data = data else {
            return nil
        }
        guard let uid = LiveJSON.asIntOrNil(data[keyUid]),
              let topSid = LiveJSON.asIntOrNil(data[keyTopSid]),
              let subSid = LiveJSON.asIntOrNil(data[keySubSid]) else {
            return nil
        }
        return HuyaDanmakuArgs(uid: uid, topSid: topSid, subSid: subSid)
    }
}

// MARK: - Request params

enum HuyaRequestParams {
    static let baseUrl = "https://www.huya.com"

    static let kUserAgent = "Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36 Edg/117.0.0.0"

    static let hysdkUa = "HYSDK(Windows,30000002)_APP(pc_exe&7100004&official)_SDK(trans&2.40.0.6448)"

    /// Regexes for the room-page HTML scrape (room detail is HTML,
    /// not JSON).
    static let roomDataRegex = "var\\s+TT_ROOM_DATA\\s*=\\s*(\\{[\\s\\S]*?\\})"
    static let streamRegex = "stream:\\s*(\\{[\\s\\S]*?\\n\\s*\\})"

    static var requestHeaders: [String: String] {
        ["Origin": baseUrl, "Referer": baseUrl, "User-Agent": hysdkUa]
    }

    /// Randomly generates a Huya SDK UA, e.g.
    /// `adr&13.1.0.3456&official&31`. A fixed UA is easier for risk
    /// control to recognise, so a random platform / sub-version /
    /// API level combination lowers the chance a signing request is
    /// refused. `randomInt` supplies the draws so tests can pin
    /// them; production passes the default.
    static func randomSdkUserAgent(randomInt: (Int) -> Int = { Int.random(in: 0..<$0) }) -> String {
        let platforms: [(name: String, version: String, hasApiLevel: Bool)] = [
            (name: "adr", version: "13.1.0", hasApiLevel: true),
            (name: "ios", version: "13.1.0", hasApiLevel: false),
            (name: "huya_nftv", version: "2.6.10", hasApiLevel: true),
            (name: "pc_exe", version: "7000000", hasApiLevel: false)
        ]
        let platform = platforms[randomInt(platforms.count)]
        var version = platform.version
        if platform.name == "adr" || platform.name == "huya_nftv" {
            version = "\(version).\(randomInt(2000) + 3000)"
        }
        var ua = "\(platform.name)&\(version)&official"
        if platform.hasApiLevel {
            ua = "\(ua)&\(randomInt(9) + 28)"
        }
        return ua
    }
}

// MARK: - Room parser (pure, fixture-testable)

extension HuyaLiveSite {
    /// Parses a Huya room page into a detailed `LiveRoom`.
    ///
    /// * `gameLiveInfo.state == 'ON'` (and not a replay) ⇒ live.
    /// * Offline / replay rooms still return a room (isLive false,
    ///   empty lines/bitRates) — never throws for "offline".
    /// * Throws when the page carries no parseable TT_ROOM_DATA /
    ///   stream blobs at all.
    static func parseHuyaRoomPage(html: String, roomId: String) throws -> LiveRoom {
        guard let roomData = extractJsonObject(html, pattern: HuyaRequestParams.roomDataRegex),
              let streamJson = extractJsonObject(html, pattern: HuyaRequestParams.streamRegex) else {
            throw LiveError.parseFailed("虎牙房间播放元数据不可用")
        }
        guard let streamDataList = streamJson["data"] as? [Any], !streamDataList.isEmpty,
              let streamData = streamDataList[0] as? [String: Any] else {
            throw LiveError.parseFailed("虎牙房间流数据不可用")
        }
        let gameLiveInfo = LiveJSON.asMap(streamData["gameLiveInfo"]) ?? [:]
        let state = LiveJSON.asString(roomData["state"])
        let isReplay = (roomData["isReplay"] as? Bool) == true
        let isLiving = state == "ON" && !isReplay

        var topSid = 0
        var subSid = 0
        var lines: [HuyaLine] = []
        var bitRates: [HuyaBitRate] = []
        if isLiving {
            if let streamInfoList = streamData["gameStreamInfoList"] as? [Any], !streamInfoList.isEmpty {
                if let first = streamInfoList[0] as? [String: Any] {
                    topSid = LiveJSON.asInt(first["lChannelId"])
                    subSid = LiveJSON.asInt(first["lSubChannelId"])
                }
                let lineTypes: [(key: String, type: HuyaLineType)] = [
                    (key: "sFlvUrl", type: .flv),
                    (key: "sHlsUrl", type: .hls)
                ]
                for item in streamInfoList {
                    guard let item = item as? [String: Any] else {
                        continue
                    }
                    for entry in lineTypes {
                        let url = LiveJSON.asString(item[entry.key])
                        if url.isEmpty {
                            continue
                        }
                        lines.append(HuyaLine(
                            baseUrl: url,
                            lineType: entry.type,
                            flvAntiCode: LiveJSON.asString(item["sFlvAntiCode"]),
                            hlsAntiCode: LiveJSON.asString(item["sHlsAntiCode"]),
                            streamName: LiveJSON.asString(item["sStreamName"]),
                            cdnType: LiveJSON.asString(item["sCdnType"]),
                            presenterUid: LiveJSON.asIntOrNil(item["presenterUid"]) ?? topSid
                        ))
                    }
                }
            }
            if let multi = streamJson["vMultiStreamInfo"] as? [Any] {
                for item in multi {
                    guard let item = item as? [String: Any] else {
                        continue
                    }
                    let name = LiveJSON.asString(item["sDisplayName"])
                    if name.contains("HDR") || name.contains("4K") {
                        continue
                    }
                    bitRates.append(HuyaBitRate(
                        bitRate: LiveJSON.asIntOrNil(item["iBitRate"]) ?? 0,
                        name: name
                    ))
                }
            }
        }

        let totalCount = LiveJSON.asString(gameLiveInfo["totalCount"]).trimmingCharacters(in: .whitespaces)
        let userCount = LiveJSON.asString(gameLiveInfo["userCount"]).trimmingCharacters(in: .whitespaces)
        let popularityString = totalCount.isEmpty ? userCount : totalCount
        // Huya's room detail returns userCount and totalCount as the
        // same multi-million popularity value — heat, not a concurrent
        // head count.
        let popularity = Int(popularityString) ?? 0
        let danmakuUid = LiveJSON.asIntOrNil(gameLiveInfo["uid"]) ?? 0
        let gid = LiveJSON.asIntOrNil(gameLiveInfo["gid"]) ?? 0

        return LiveRoom(
            roomId: roomId,
            platform: .huya,
            title: LiveJSON.asString(gameLiveInfo["introduction"]),
            streamer: LiveJSON.asString(gameLiveInfo["nick"]),
            avatar: LiveJSON.asString(gameLiveInfo["avatar180"]),
            cover: LiveJSON.asString(gameLiveInfo["screenshot"]),
            onlineCount: popularity,
            isLive: isLiving,
            link: LivePlatform.huya.roomLink(roomId: roomId),
            data: HuyaUrlData(lines: lines, bitRates: bitRates, isXingxiu: gid == 1663).toDataMap(),
            danmakuData: HuyaDanmakuArgs(uid: danmakuUid, topSid: topSid, subSid: subSid).toDataMap()
        )
    }

    /// Quality menu from a room snapshot. Only rates the server
    /// returned in `vMultiStreamInfo`: `4K` excluded, no invented
    /// fallback, bitRate 0 = 原画. When the server returned no rates
    /// at all but lines exist, a single 原画 entry is offered
    /// (source quality needs no `ratio` param).
    static func parseHuyaPlayQualities(lines: [HuyaLine], bitRates: [HuyaBitRate]) -> [LiveQuality] {
        let rates = bitRates.isEmpty ? [HuyaBitRate(bitRate: 0, name: "原画")] : bitRates
        var unique: [Int: HuyaBitRate] = [:]
        for rate in rates {
            if rate.bitRate < 0 || rate.name.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            if rate.name == "4K" {
                continue
            }
            if unique[rate.bitRate] == nil {
                unique[rate.bitRate] = rate
            }
        }
        let playbackLines = lines.map { line in
            LiveLine(name: line.cdnType, format: line.lineType == .hls ? "hls" : "flv")
        }
        return unique.values
            .map { rate in
                LiveQuality(
                    id: String(rate.bitRate),
                    name: rate.name,
                    sort: rate.bitRate == 0 ? 1 << 30 : rate.bitRate,
                    lines: playbackLines
                )
            }
            .sorted { $0.sort > $1.sort }
    }

    /// Locates a JSON object with `pattern` and extracts it with
    /// balanced brace scanning (string-aware), so nested objects
    /// survive. Falls back to the regex's first capture group when
    /// the scan cannot run.
    static func extractJsonObject(_ text: String, pattern: String) -> [String: Any]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        // NSRegularExpression ranges are UTF-16 offsets; String.Index
        // arithmetic counts Character (grapheme clusters). Converting
        // via offsetBy: drifts whenever the text before the match
        // contains multi-unit characters — Huya room pages carry 65
        // CRLF in the header (2 UTF-16 units = 1 Character each), so
        // the old code landed 65 characters inside the JSON and
        // returned a nested object (no `state`, no `data`), failing
        // EVERY room. Use the Range conversion, as
        // DouyinSite.parseRenderData already does.
        guard let matchRange = Range(match.range, in: text) else {
            return nil
        }
        let matchStart = matchRange.lowerBound
        guard let braceAt = text[matchStart...].firstIndex(of: "{") else {
            return nil
        }
        let raw: String?
        if let end = balancedBraceEnd(text, openAt: braceAt) {
            raw = String(text[braceAt...end])
        } else if match.numberOfRanges >= 2, let captureRange = Range(match.range(at: 1), in: text) {
            raw = String(text[captureRange])
        } else {
            raw = nil
        }
        guard let raw = raw, let data = raw.data(using: .utf8) else {
            return nil
        }
        return LiveJSON.decodeObject(data)
    }

    /// Index of the `}` closing the `{` at `openAt`, or nil if
    /// unbalanced. String literals (with `\"` escapes) are skipped
    /// so braces inside strings do not affect depth.
    static func balancedBraceEnd(_ text: String, openAt: String.Index) -> String.Index? {
        let chars = Array(text[openAt...])
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
                    return text.index(openAt, offsetBy: offset)
                }
            }
        }
        return nil
    }
}

// MARK: - Transport policy (line identity after refresh)

/// Line identity rule: lines are identified by URL (CDN + port +
/// media path + credential family), NEVER by index after a refresh
/// — a refresh can reorder/filter the line list and a stale index
/// silently switches the viewer to another CDN/format.
enum HuyaTransportPolicy {
    /// Picks the line index in the refreshed `urls` list that
    /// corresponds to the previously playing `currentUrl`.
    ///
    /// Match order: same CDN + port + media path, preferring the
    /// same format (FLV stays FLV) and the same credential family
    /// (native FLV token stays native); when the broadcaster
    /// restarted and the stream name rotated, fall back to same CDN
    /// + format, then same format, then the first line. When
    /// `advanceLine` is true (current line failed), the NEXT line in
    /// the matched pool is returned instead of the match itself.
    static func selectRefreshedLine(urls: [String], currentUrl: String?, currentLineIndex: Int, advanceLine: Bool) -> Int {
        if urls.isEmpty {
            return 0
        }
        let legacyIndex = max(0, min(currentLineIndex, urls.count - 1))
        let fallback = advanceLine ? (legacyIndex + 1) % urls.count : legacyIndex
        guard let current = currentUrl, let currentUri = mediaUri(current) else {
            return fallback
        }
        let candidates = urls.map { mediaUri($0) }
        let all = candidates.indices.filter { candidates[$0] != nil }
        let isFlv = currentUri.path.lowercased().hasSuffix(".flv")
        let sameFormat = all.filter { candidates[$0]!.path.lowercased().hasSuffix(".flv") == isFlv }
        let wasNative = hasNativeFlvCredential(current)
        let native = sameFormat.filter { hasNativeFlvCredential(urls[$0]) }
        let pools: [[Int]] = wasNative ? [native, sameFormat, all] : [sameFormat, all]
        for pool in pools {
            if pool.isEmpty {
                continue
            }
            func sameCdn(_ i: Int) -> Bool {
                candidates[i]!.host == currentUri.host
                    && normalizedPort(candidates[i]!) == normalizedPort(currentUri)
                    && hasNativeFlvCredential(urls[i]) == wasNative
            }
            var position = -1
            for (offset, i) in pool.enumerated() {
                if sameCdn(i) && candidates[i]!.path == currentUri.path {
                    position = offset
                    break
                }
            }
            if position < 0 {
                for (offset, i) in pool.enumerated() {
                    if sameCdn(i) {
                        position = offset
                        break
                    }
                }
            }
            if position < 0 {
                return pool[0]
            }
            if !advanceLine {
                return pool[position]
            }
            if pool.count > 1 {
                return pool[(position + 1) % pool.count]
            }
            // The only native line failed: broaden to web FLV, then
            // HLS, rather than retrying that same endpoint forever.
        }
        return fallback
    }

    /// Whether this URL is on the short (~100 s / 125 s) transport
    /// lease. Native WUP FLV tokens outlive their credential in
    /// long probes, so they are excluded; every web-template-signed
    /// URL has the short lease.
    static func hasShortTransportLease(_ url: String) -> Bool {
        guard mediaUri(url) != nil else {
            return false
        }
        return !hasNativeFlvCredential(url)
    }

    /// Native WUP FLV credential marker: FLV + t=100 + a native SDK
    /// client ctype. The WUP token's ctype is the requesting SDK, not
    /// a fixed string: real tokens observed in the VM probe carry
    /// huya_pc_exe, huya_ios, tv_huya_nftv or huya_adr (the SDK UA is
    /// randomised per token — see randomSdkUserAgent's adr / ios /
    /// huya_nftv / pc_exe platforms). Web-template-signed URLs carry
    /// ctype=huya_webh5 and never match. Unknown future ctypes fall
    /// back to the short lease (safe side: refresh early, never play
    /// past expiry).
    static func hasNativeFlvCredential(_ url: String) -> Bool {
        guard let uri = URL(string: url),
              let host = uri.host?.lowercased(),
              (host == "huya.com" || host.hasSuffix(".huya.com")),
              uri.path.lowercased().hasSuffix(".flv") else {
            return false
        }
        let query = uri.query ?? ""
        guard LiveQuery.value(query, key: "t") == "100",
              let ctype = LiveQuery.value(query, key: "ctype") else {
            return false
        }
        return ["huya_pc_exe", "huya_ios", "tv_huya_nftv", "huya_adr"].contains(ctype)
    }

    private static func mediaUri(_ url: String) -> URL? {
        guard let uri = URL(string: url),
              let scheme = uri.scheme,
              (scheme == "https" || scheme == "http"),
              let host = uri.host?.lowercased(),
              (host == "huya.com" || host.hasSuffix(".huya.com")) else {
            return nil
        }
        let path = uri.path.lowercased()
        guard path.hasSuffix(".flv") || path.hasSuffix(".m3u8") else {
            return nil
        }
        return uri
    }

    private static func normalizedPort(_ uri: URL) -> Int {
        if let port = uri.port {
            return port
        }
        return uri.scheme == "https" ? 443 : 80
    }
}

// MARK: - Site

/// Huya resolver. Anonymous-only: no account cookie, no session
/// machinery — the anonymous web identity comes from
/// `POST https://udblgn.huya.com/web/anonymousLogin`, with a stable
/// process-local fallback uid when that endpoint fails (the fallback
/// is never cached, so the next acquisition retries the endpoint).
final class HuyaLiveSite: LiveSiteResolver {
    var platform: LivePlatform {
        .huya
    }

    private let fetcher: LiveDataFetcher
    private let wupClient: HuyaWupClient

    private var anonymousViewerIdentity: HuyaViewerIdentity?
    private var viewerIdentityInFlight = false
    private var viewerIdentityCompletions: [(HuyaViewerIdentity) -> Void] = []
    private let fallbackViewerUid: Int
    private let viewerGuid: String

    private var nativeTokenPending: [String: [(Result<HuyaCdnTokenLease, Error>) -> Void]] = [:]
    private var webTokenPending: [String: [(Result<HuyaCdnTokenLease, Error>) -> Void]] = [:]

    private var lastSignatureMillis: Int = 0
    private var playbackTransportIssuedAt: [String: Date] = [:]
    private var playbackTokenLeases: [String: HuyaCdnTokenLease] = [:]
    /// In-flight room-detail loads, keyed by trimmed room id
    /// (build 36 item 10 leg 4 — see `loadRoomDetail`).
    private var roomDetailInFlight: [String: [(Result<LiveRoom, Error>) -> Void]] = [:]

    /// Guards the token/identity/lease state above: resolve runs
    /// from URLSession background callbacks and two concurrent
    /// resolves (prefetch + recovery, or a fast room switch) used
    /// to mutate the same dictionaries/arrays/flags with no lock
    /// — a data race that traps (Dictionary/Array simultaneous
    /// mutation). The lock is only ever held for the state touch,
    /// never across a network call or a completion.
    private let stateLock = NSLock()
    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// Full resolutions banked by a background line walk (b49
    /// sweep #10 — same shape as DouyuLiveSite): `resolve`
    /// completes on the first playable line and the rest keep
    /// resolving; the finished resolution lands here, keyed by
    /// room + requested quality id, so the next resolve answers
    /// at once with every line. 90 s TTL — inside the web
    /// anti-code's ~120 s lease, so a cached resolution is never
    /// served past its usable life.
    private var backgroundResolutions: [String: (resolution: LivePlayUrlResolution, storedAt: Date)] = [:]
    private static let backgroundCacheTTL: TimeInterval = 90

    private func backgroundCacheKey(roomId: String, qualityId: String) -> String {
        "\(roomId)|\(qualityId)"
    }

    private func cachedBackgroundResolution(roomId: String, qualityId: String) -> LivePlayUrlResolution? {
        locked {
            guard let entry = backgroundResolutions[backgroundCacheKey(roomId: roomId, qualityId: qualityId)],
                  Date().timeIntervalSince(entry.storedAt) < HuyaLiveSite.backgroundCacheTTL else {
                return nil
            }
            return entry.resolution
        }
    }

    private func storeBackgroundResolution(_ resolution: LivePlayUrlResolution, roomId: String, qualityId: String) {
        locked {
            backgroundResolutions[backgroundCacheKey(roomId: roomId, qualityId: qualityId)] = (resolution, Date())
        }
    }

    /// Resolves that arrived while a line walk for the same room
    /// + bitrate is still in flight (b49fix2 P1-24 — same shape
    /// as DouyuLiveSite): a second resolve used to start a second
    /// serial chain, whose early completion returned the same dead
    /// first line. Joiners wait for the in-flight walk and get its
    /// FULL resolution when it ends.
    private var lineWalkInFlight: [String: [(Result<LivePlayUrlResolution, Error>) -> Void]] = [:]

    init(fetcher: LiveDataFetcher? = nil, wupClient: HuyaWupClient? = nil) {
        let resolvedFetcher = fetcher ?? LiveHTTP.defaultFetcher
        self.fetcher = resolvedFetcher
        self.wupClient = wupClient ?? HuyaWupClient(fetcher: resolvedFetcher)
        self.fallbackViewerUid = HuyaLiveSite.createFallbackViewerUid()
        self.viewerGuid = LiveCrypto.randomHex(count: 32)
    }

    func makeDanmakuTransport() -> LiveDanmakuTransport {
        HuyaDanmaku(wupClient: wupClient)
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
        // credentials).
        loadRoomDetail(roomId: trimmed, completion: completion)
    }

    /// Strict room load: throws when the page carries no parseable
    /// playback metadata (resolve must see the transient error,
    /// never a disguised "offline").
    ///
    /// Build 36 item 10 leg 4: entering a room fires two paths at
    /// once — the playback `resolve` below and the danmaku
    /// `roomInfo` above — and both used to fetch the room page
    /// separately (2x the same room detail per entry). A
    /// concurrent load for the same room joins the one already in
    /// flight instead of starting another; every joiner still gets
    /// its own completion with the same result, so the failure
    /// semantics are unchanged (a transient failure is reported
    /// as a failure to both paths, never disguised as offline —
    /// build 36 item 8). The entry is dropped when the load
    /// finishes, so a later load (recovery re-parse, quality
    /// switch, prefetch) always fetches fresh: this is dedup,
    /// never a cache.
    private func loadRoomDetail(roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        guard let url = URL(string: "\(HuyaRequestParams.baseUrl)/\(roomId)") else {
            completion(.failure(LiveError.parseFailed("虎牙房间地址无效")))
            return
        }
        let alreadyInFlight = locked {
            var list = roomDetailInFlight[roomId] ?? []
            list.append(completion)
            roomDetailInFlight[roomId] = list
            return list.count > 1
        }
        if alreadyInFlight {
            return
        }
        var headers = HuyaRequestParams.requestHeaders
        headers["Accept"] = "text/html,application/xhtml+xml"
        let request = LiveHTTP.getRequest(url: url, headers: headers)
        fetcher(request) { data, _, error in
            if let error = error {
                self.finishRoomDetail(roomId: roomId, result: .failure(error))
                return
            }
            guard let data = data, let html = String(data: data, encoding: .utf8), !html.isEmpty else {
                self.finishRoomDetail(roomId: roomId, result: .failure(LiveError.emptyResponse))
                return
            }
            do {
                self.finishRoomDetail(roomId: roomId, result: .success(try HuyaLiveSite.parseHuyaRoomPage(html: html, roomId: roomId)))
            } catch {
                self.finishRoomDetail(roomId: roomId, result: .failure(error))
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
                guard let data = HuyaUrlData.fromDataMap(room.data) else {
                    completion(.failure(LiveError.parseFailed("虎牙房间没有播放描述")))
                    return
                }
                let qualities = HuyaLiveSite.parseHuyaPlayQualities(lines: data.lines, bitRates: data.bitRates)
                if qualities.isEmpty {
                    completion(.failure(LiveError.noQualities))
                    return
                }
                let requested = qualities.first { $0.id == quality?.id } ?? qualities[0]
                let bitRate = Int(requested.id) ?? 0
                // A background walk already banked every line for
                // this room + bitrate (b49 sweep #10): answer at
                // once, no serial chain.
                if let cached = self.cachedBackgroundResolution(roomId: trimmed, qualityId: requested.id) {
                    completion(.success(cached))
                    return
                }
                // (b49fix2 P1-24) A line walk for this room +
                // bitrate is still in flight (its first line
                // already completed early): join it instead of
                // starting a second serial chain. The joiner gets
                // the FULL resolution when the walk ends.
                let walkKey = self.backgroundCacheKey(roomId: trimmed, qualityId: requested.id)
                if self.locked({ self.lineWalkInFlight[walkKey] != nil }) {
                    self.locked { self.lineWalkInFlight[walkKey, default: []].append(completion) }
                    return
                }
                self.locked { self.lineWalkInFlight[walkKey] = [] }
                var deliveredEarly = false
                self.resolveHuyaLines(data.lines, bitRate: bitRate, onFirst: { [weak self] first in
                    guard let self = self, !deliveredEarly else { return }
                    deliveredEarly = true
                    // (b49fix2 P2-24) One gameStreamInfoList item
                    // yields one FLV and one HLS line, both named
                    // by cdnType — the menu showed two identical
                    // names. Suffix the format so the user can
                    // tell them apart (selection is by index, so
                    // this is display-only).
                    let liveLines = [LiveLine(name: first.line.cdnType + " " + (first.line.lineType == .hls ? "HLS" : "FLV"), urls: [first.url], format: first.line.lineType == .hls ? "hls" : "flv")]
                    var filled = qualities
                    var applied = requested
                    if let index = filled.firstIndex(where: { $0.id == requested.id }) {
                        filled[index].lines = liveLines
                        applied = filled[index]
                    }
                    completion(.success(LivePlayUrlResolution.applying(applied, in: filled)))
                }) { [weak self] resolved in
                    guard let self = self else { return }
                    /// Drain one finished walk (b49fix2 P1-24):
                    /// the entry is removed BEFORE the completions
                    /// run, so a completion that re-enters
                    /// resolve() registers a fresh walk instead of
                    /// joining a finished one. When the walk
                    /// delivered early, the original completion
                    /// already fired — bank the full resolution
                    /// and answer the joiners only; otherwise
                    /// answer the original completion too.
                    func finishWalk(_ result: Result<LivePlayUrlResolution, Error>) {
                        let waiters = self.locked { self.lineWalkInFlight.removeValue(forKey: walkKey) ?? [] }
                        switch result {
                        case .success(let resolution):
                            if deliveredEarly {
                                self.storeBackgroundResolution(resolution, roomId: trimmed, qualityId: requested.id)
                            } else {
                                completion(.success(resolution))
                            }
                            for waiter in waiters { waiter(.success(resolution)) }
                        case .failure(let error):
                            completion(.failure(error))
                            for waiter in waiters { waiter(.failure(error)) }
                        }
                    }
                    if resolved.isEmpty {
                        if !deliveredEarly {
                            finishWalk(.failure(LiveError.transportFailed("虎牙全部线路均不可用")))
                        }
                        return
                    }
                    var filled = qualities
                    let liveLines = resolved.map { item in
                        LiveLine(name: item.line.cdnType + " " + (item.line.lineType == .hls ? "HLS" : "FLV"), urls: [item.url], format: item.line.lineType == .hls ? "hls" : "flv")
                    }
                    var applied = requested
                    if let index = filled.firstIndex(where: { $0.id == requested.id }) {
                        filled[index].lines = liveLines
                        applied = filled[index]
                    }
                    var refreshAt: Date?
                    var invalidAt: Date?
                    for item in resolved {
                        if let value = self.playUrlRefreshAt(url: item.url), refreshAt == nil || value < refreshAt! {
                            refreshAt = value
                        }
                        if let value = self.playUrlInvalidAt(url: item.url), invalidAt == nil || value < invalidAt! {
                            invalidAt = value
                        }
                    }
                    let full = LivePlayUrlResolution.applying(applied, in: filled, refreshAt: refreshAt, invalidAt: invalidAt)
                    finishWalk(.success(full))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Resolves every line for one bitrate, serially (server order
    /// kept, duplicates dropped, one bad token never discards the
    /// healthy alternatives). (b49 sweep #10) `onFirst` fires on
    /// the first playable line, while the rest keep resolving —
    /// the caller completes early on it and banks the finished
    /// list via the final completion instead of waiting.
    private func resolveHuyaLines(_ lines: [HuyaLine], bitRate: Int, onFirst: @escaping ((line: HuyaLine, url: String)) -> Void, completion: @escaping ([(line: HuyaLine, url: String)]) -> Void) {
        var out: [(line: HuyaLine, url: String)] = []
        var seen = Set<String>()
        var remaining = lines
        func next() {
            if remaining.isEmpty {
                completion(out)
                return
            }
            let line = remaining.removeFirst()
            self.getPlayUrl(line: line, bitRate: bitRate) { result in
                switch result {
                case .success(let url):
                    if !url.isEmpty && seen.insert(url).inserted {
                        let pair = (line: line, url: url)
                        out.append(pair)
                        if out.count == 1 {
                            onFirst(pair)
                        }
                    }
                    next()
                case .failure:
                    next()
                }
            }
        }
        next()
    }

    // MARK: - Play URL waterfall

    /// Builds the signed play URL for one line at `bitRate`.
    ///
    /// FLV prefers the native WUP token (`getCdnTokenInfoEx`, ~420 s
    /// lease) and falls back to the web-template anti-code (~120 s)
    /// when WUP is unavailable; the native token is NEVER reused for
    /// HLS. When the room's own FLV template cannot be signed, a
    /// second WUP call with the anonymous web identity is tried
    /// before giving up. FLV uses its `sFlvAntiCode`, HLS its
    /// `sHlsAntiCode` — never cross-used. `ratio` is replaced with
    /// the requested bitrate and removed for 原画 (bitRate 0);
    /// `codec=264` is appended when missing.
    func getPlayUrl(line: HuyaLine, bitRate: Int, completion: @escaping (Result<String, Error>) -> Void) {
        if line.lineType == .flv {
            attemptNativeFlv(line: line, bitRate: bitRate, completion: completion)
            return
        }
        finishGetPlayUrl(line: line, bitRate: bitRate, antiCode: line.hlsAntiCode.trimmingCharacters(in: .whitespaces), tokenLease: nil, signatureAlreadyBuilt: false, completion: completion)
    }

    private func attemptNativeFlv(line: HuyaLine, bitRate: Int, completion: @escaping (Result<String, Error>) -> Void) {
        fetchNativeToken(line: line) { result in
            switch result {
            case .success(let lease):
                if lease.isExpired(Date()) {
                    self.attemptWebFlv(line: line, bitRate: bitRate, completion: completion)
                    return
                }
                if line.presenterUid > 0 {
                    self.signNative(line: line, bitRate: bitRate, lease: lease, uid: line.presenterUid, completion: completion)
                } else {
                    self.resolveViewerIdentity { viewer in
                        self.signNative(line: line, bitRate: bitRate, lease: lease, uid: viewer.uid, completion: completion)
                    }
                }
            case .failure:
                self.attemptWebFlv(line: line, bitRate: bitRate, completion: completion)
            }
        }
    }

    private func signNative(line: HuyaLine, bitRate: Int, lease: HuyaCdnTokenLease, uid: Int, completion: @escaping (Result<String, Error>) -> Void) {
        do {
            let antiCode = try HuyaAntiCode.build(
                stream: line.streamName,
                viewerUid: uid,
                antiCode: lease.antiCode,
                now: monotonicNow(),
                fallbackViewerUid: fallbackViewerUid
            )
            finishGetPlayUrl(line: line, bitRate: bitRate, antiCode: antiCode, tokenLease: lease, signatureAlreadyBuilt: true, completion: completion)
        } catch {
            attemptWebFlv(line: line, bitRate: bitRate, completion: completion)
        }
    }

    private func attemptWebFlv(line: HuyaLine, bitRate: Int, completion: @escaping (Result<String, Error>) -> Void) {
        let roomFlvAntiCode = line.flvAntiCode.trimmingCharacters(in: .whitespaces)
        let isLegacyStaticToken = LiveQuery.value(roomFlvAntiCode, key: "fm") == nil
        if isLegacyStaticToken {
            finishGetPlayUrl(line: line, bitRate: bitRate, antiCode: roomFlvAntiCode, tokenLease: nil, signatureAlreadyBuilt: false, completion: completion)
            return
        }
        resolveViewerIdentity { viewer in
            do {
                let antiCode = try HuyaAntiCode.build(
                    stream: line.streamName,
                    viewerUid: viewer.uid,
                    antiCode: roomFlvAntiCode,
                    now: self.monotonicNow(),
                    fallbackViewerUid: self.fallbackViewerUid
                )
                self.finishGetPlayUrl(line: line, bitRate: bitRate, antiCode: antiCode, tokenLease: nil, signatureAlreadyBuilt: true, completion: completion)
            } catch {
                self.fetchWebToken(line: line, viewer: viewer) { result in
                    switch result {
                    case .success(let lease):
                        self.finishGetPlayUrl(line: line, bitRate: bitRate, antiCode: lease.antiCode.trimmingCharacters(in: .whitespaces), tokenLease: lease, signatureAlreadyBuilt: false, completion: completion)
                    case .failure:
                        // Keep the (possibly unusable) template; the
                        // empty / re-sign check below throws a clear
                        // error instead of a stale token.
                        self.finishGetPlayUrl(line: line, bitRate: bitRate, antiCode: roomFlvAntiCode, tokenLease: nil, signatureAlreadyBuilt: false, completion: completion)
                    }
                }
            }
        }
    }

    private func finishGetPlayUrl(line: HuyaLine, bitRate: Int, antiCode: String, tokenLease: HuyaCdnTokenLease?, signatureAlreadyBuilt: Bool, completion: @escaping (Result<String, Error>) -> Void) {
        if antiCode.isEmpty {
            let transport = line.lineType == .hls ? "HLS" : "FLV"
            completion(.failure(LiveError.parseFailed("虎牙 \(transport) token 不可用")))
            return
        }
        // The web fallback uses its anonymous viewer identity.
        // Native WUP above has a separate request/signing contract;
        // do not mix those identities.
        if !signatureAlreadyBuilt && LiveQuery.value(antiCode, key: "fm") != nil {
            resolveViewerIdentity { viewer in
                do {
                    let signed = try HuyaAntiCode.build(
                        stream: line.streamName,
                        viewerUid: viewer.uid,
                        antiCode: antiCode,
                        now: self.monotonicNow(),
                        fallbackViewerUid: self.fallbackViewerUid
                    )
                    self.buildFinalUrl(line: line, bitRate: bitRate, antiCode: signed, tokenLease: tokenLease, completion: completion)
                } catch {
                    completion(.failure(error))
                }
            }
            return
        }
        buildFinalUrl(line: line, bitRate: bitRate, antiCode: antiCode, tokenLease: tokenLease, completion: completion)
    }

    private func buildFinalUrl(line: HuyaLine, bitRate: Int, antiCode: String, tokenLease: HuyaCdnTokenLease?, completion: @escaping (Result<String, Error>) -> Void) {
        var code = antiCode
        let ext = line.lineType == .hls ? "m3u8" : "flv"
        let cdnBase = HuyaAntiCode.secureCdnBase(line.baseUrl)
        if LiveQuery.value(code, key: "codec") == nil {
            code += "&codec=264"
        }
        // Huya reuses one anti-leech query for every quality.
        // `ratio`, when already present, describes the URL captured
        // from the page rather than the user's new selection. Always
        // replace it for a transcode and remove it for source
        // quality (bitRate 0).
        code = HuyaAntiCode.replaceQueryParameter(code, key: "ratio", value: bitRate > 0 ? String(bitRate) : nil)
        let url = "\(cdnBase)/\(line.streamName).\(ext)?\(code)"
        // Current AntiCode templates encode the issue instant through
        // seqid. Some legacy/static token families do not. Remember
        // the connection issue instant for every URL built here so
        // legacy lines stay on the same proactive hand-off path
        // instead of waiting for EOF.
        rememberTransportIssuedAt(url, issuedAt: HuyaAntiCode.signedSequenceIssuedAt(url) ?? Date())
        if let lease = tokenLease {
            rememberPlaybackTokenLease(url, lease: lease)
        }
        completion(.success(url))
    }

    // MARK: - Token fetching (in-flight dedup)

    /// Shares one in-flight native token request per stream name.
    /// Each consumer signs a new URL from the shared lease.
    private func fetchNativeToken(line: HuyaLine, completion: @escaping (Result<HuyaCdnTokenLease, Error>) -> Void) {
        let key = line.streamName
        let alreadyPending = locked {
            nativeTokenPending[key, default: []].append(completion)
            return nativeTokenPending[key]!.count > 1
        }
        if alreadyPending {
            return
        }
        wupClient.fetchNativeCdnToken(line: line) { result in
            let completions = self.locked { self.nativeTokenPending.removeValue(forKey: key) ?? [] }
            for item in completions {
                item(result)
            }
        }
    }

    /// Shares one in-flight web-identity token request per viewer +
    /// line + stream. Each consumer signs a new URL from the shared
    /// lease.
    private func fetchWebToken(line: HuyaLine, viewer: HuyaViewerIdentity, completion: @escaping (Result<HuyaCdnTokenLease, Error>) -> Void) {
        let key = "\(viewer.uid)|\(line.baseUrl)|\(line.streamName)"
        let alreadyPending = locked {
            webTokenPending[key, default: []].append(completion)
            return webTokenPending[key]!.count > 1
        }
        if alreadyPending {
            return
        }
        wupClient.fetchWebCdnToken(line: line, viewer: viewer) { result in
            let completions = self.locked { self.webTokenPending.removeValue(forKey: key) ?? [] }
            for item in completions {
                item(result)
            }
        }
    }

    // MARK: - Anonymous identity

    /// Anonymous viewer identity from
    /// `POST https://udblgn.huya.com/web/anonymousLogin`. Cached per
    /// site instance; concurrent callers share the in-flight
    /// request. When the endpoint fails, a stable process-local
    /// fallback UID is used for that one acquisition and NOT cached,
    /// so the next acquisition retries the official endpoint instead
    /// of turning a brief outage into persistent 403s.
    func resolveViewerIdentity(completion: @escaping (HuyaViewerIdentity) -> Void) {
        let cached: HuyaViewerIdentity? = locked { anonymousViewerIdentity }
        if let cached = cached {
            completion(cached)
            return
        }
        let alreadyInFlight = locked {
            viewerIdentityCompletions.append(completion)
            if viewerIdentityInFlight {
                return true
            }
            viewerIdentityInFlight = true
            return false
        }
        if alreadyInFlight {
            return
        }
        loadAnonymousViewerIdentity { identity in
            let completions = self.locked {
                self.viewerIdentityInFlight = false
                if identity.uid != self.fallbackViewerUid {
                    self.anonymousViewerIdentity = identity
                }
                let completions = self.viewerIdentityCompletions
                self.viewerIdentityCompletions = []
                return completions
            }
            for item in completions {
                item(identity)
            }
        }
    }

    private func loadAnonymousViewerIdentity(completion: @escaping (HuyaViewerIdentity) -> Void) {
        guard let url = URL(string: "https://udblgn.huya.com/web/anonymousLogin") else {
            completion(HuyaViewerIdentity(uid: fallbackViewerUid, guid: viewerGuid, isAnonymous: true))
            return
        }
        let body: [String: Any] = ["appId": 5002, "byPass": 3, "context": "", "version": "2.4", "data": [:]]
        let request = LiveHTTP.postJSONRequest(
            url: url,
            body: body,
            headers: [
                "User-Agent": HuyaRequestParams.kUserAgent,
                "Accept": "*/*",
                "Origin": "https://www.huya.com",
                "Referer": "https://www.huya.com/",
                "Sec-Fetch-Dest": "empty",
                "Sec-Fetch-Mode": "cors",
                "Sec-Fetch-Site": "same-site"
            ]
        )
        fetcher(request) { data, _, _ in
            if let data = data,
               let json = LiveJSON.decodeObject(data),
               let dataMap = LiveJSON.asMap(json["data"]),
               let uid = LiveJSON.asIntOrNil(dataMap["uid"]),
               uid > 0 {
                completion(HuyaViewerIdentity(uid: uid, guid: self.viewerGuid, isAnonymous: true))
            } else {
                completion(HuyaViewerIdentity(uid: self.fallbackViewerUid, guid: self.viewerGuid, isAnonymous: true))
            }
        }
    }

    /// `yyuid` from an account cookie (kept for when a cookie store
    /// exists; this port is anonymous-only and never calls it).
    static func parseViewerUidFromCookie(_ cookie: String) -> Int? {
        let pattern = "(?:^|;\\s*)yyuid=(\\d+)(?:;|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: cookie, options: [], range: NSRange(cookie.startIndex..., in: cookie)),
              match.numberOfRanges >= 2,
              let uidRange = Range(match.range(at: 1), in: cookie),
              let uid = Int(cookie[uidRange]), uid > 0 else {
            return nil
        }
        return uid
    }

    private static func createFallbackViewerUid() -> Int {
        let offset = Int.random(in: 0..<1000000) * 100000 + Int.random(in: 0..<100000)
        return 1400000000000 + offset
    }

    // MARK: - Lease math

    /// Wall clock strictly increasing per signature (upstream
    /// guard: two URLs signed in the same millisecond would share a
    /// seqid).
    private func monotonicNow() -> Date {
        locked {
            let wallMillis = Int(Date().timeIntervalSince1970 * 1000)
            let currentMillis = wallMillis > lastSignatureMillis ? wallMillis : lastSignatureMillis + 1
            lastSignatureMillis = currentMillis
            return Date(timeIntervalSince1970: TimeInterval(currentMillis) / 1000)
        }
    }

    private func rememberTransportIssuedAt(_ url: String, issuedAt: Date) {
        locked {
            if playbackTransportIssuedAt.count >= 64 && playbackTransportIssuedAt[url] == nil, let first = playbackTransportIssuedAt.keys.first {
                playbackTransportIssuedAt.removeValue(forKey: first)
            }
            playbackTransportIssuedAt[url] = issuedAt
        }
    }

    private func rememberedTransportIssuedAt(_ url: String) -> Date? {
        // Keep a past deadline authoritative. Removing it exactly at
        // expiry would reveal the much later wsTime bound and
        // incorrectly make a dead URL look healthy again.
        locked { playbackTransportIssuedAt[url] }
    }

    private func rememberPlaybackTokenLease(_ url: String, lease: HuyaCdnTokenLease) {
        locked {
            let now = Date()
            playbackTokenLeases = playbackTokenLeases.filter { !$0.value.isExpired(now) }
            if playbackTokenLeases.count >= 32 && playbackTokenLeases[url] == nil, let first = playbackTokenLeases.keys.first {
                playbackTokenLeases.removeValue(forKey: first)
            }
            playbackTokenLeases[url] = lease
        }
    }

    private func playbackTokenLease(for url: String) -> HuyaCdnTokenLease? {
        // Keep an expired entry until the next URL is registered.
        // Forgetting it at the exact expiry instant would make the
        // longer wsTime bound appear valid again and postpone a
        // recovery that is already due.
        locked { playbackTokenLeases[url] }
    }

    private static func earliest(_ first: Date?, _ second: Date?) -> Date? {
        if let first = first, let second = second {
            return first < second ? first : second
        }
        return first ?? second
    }

    /// Proactive refresh deadline for one URL: earliest of (wsTime
    /// expiry − 30 s), the native token lease's refreshAt, and
    /// (transport issue + 100 s). The transport terms apply ONLY to
    /// short-lease (web-template) URLs — native-token FLV URLs have
    /// no 100 s / 125 s transport bound. Nil when no expiry can be
    /// derived.
    func playUrlRefreshAt(url: String) -> Date? {
        let current = Date()
        let signedInvalidAt = HuyaAntiCode.signedUrlInvalidAt(url)
        let tokenLease = playbackTokenLease(for: url)
        let transportIssuedAt = HuyaTransportPolicy.hasShortTransportLease(url)
            ? (HuyaAntiCode.signedSequenceIssuedAt(url) ?? rememberedTransportIssuedAt(url))
            : nil
        let transportInvalidAt = transportIssuedAt?.addingTimeInterval(HuyaAntiCode.transportInvalidAgeSeconds)
        let invalidAt = HuyaLiveSite.earliest(HuyaLiveSite.earliest(signedInvalidAt, tokenLease?.invalidAt), transportInvalidAt)
        guard invalidAt != nil else {
            return nil
        }
        let signatureRefreshAt = signedInvalidAt?.addingTimeInterval(-HuyaAntiCode.signatureRefreshLeadSeconds)
        let transportRefreshAt = transportIssuedAt?.addingTimeInterval(HuyaAntiCode.transportRefreshAgeSeconds)
        let refreshAt = HuyaLiveSite.earliest(HuyaLiveSite.earliest(signatureRefreshAt, tokenLease?.refreshAt), transportRefreshAt) ?? current
        return refreshAt > current ? refreshAt : current
    }

    /// Hard expiry for one URL: earliest of (wsTime + 5 min), the
    /// native token lease's invalidAt, and (transport issue + 125 s
    /// — web template URLs only). Nil when no expiry can be derived.
    func playUrlInvalidAt(url: String) -> Date? {
        let tokenLease = playbackTokenLease(for: url)
        let transportIssuedAt = HuyaTransportPolicy.hasShortTransportLease(url)
            ? (HuyaAntiCode.signedSequenceIssuedAt(url) ?? rememberedTransportIssuedAt(url))
            : nil
        return HuyaLiveSite.earliest(
            HuyaLiveSite.earliest(HuyaAntiCode.signedUrlInvalidAt(url), tokenLease?.invalidAt),
            transportIssuedAt?.addingTimeInterval(HuyaAntiCode.transportInvalidAgeSeconds)
        )
    }
}

// MARK: - Lists (recommend / categories / search)
//
// Port of the Flutter `huya_site.dart` list methods
// (getRecommendRooms / getCategories / getCategoryRooms /
// searchRooms) + `huya_room_parser.dart` list parsers. The
// room-detail leg (S4-B) left these out; the live tab's gateway
// needs them. Every method completes with [] on any failure —
// a list failure is an empty list, never a throw out of the
// completion handler. All parsing is pure + static so fixtures
// can cover it without network.

extension HuyaLiveSite {
    private static let searchBaseURL = "https://search.cdn.huya.com/"
    private static let cacheListURL = "https://www.huya.com/cache.php"
    private static let categoryConfigURL = "https://live.cdn.huya.com/liveconfig/game/bussLive"

    private var listHeaders: [String: String] {
        [
            "User-Agent": HuyaRequestParams.kUserAgent,
            "Origin": "https://www.huya.com",
            "Referer": "https://www.huya.com/"
        ]
    }

    private var searchHeaders: [String: String] {
        ["User-Agent": HuyaRequestParams.kUserAgent]
    }

    /// Home hot list via cache.php LiveList, no gameId
    /// (Dart `getRecommendRooms`). Page is 1-based here.
    func recommendRooms(page: Int, pageSize: Int, completion: @escaping ([LiveRoom]) -> Void) {
        fetchCacheList(gameId: nil, page: page, completion: completion)
    }

    /// Rooms of one game (Dart `getCategoryRooms`): the same
    /// cache.php list with `gameId`.
    func categoryRooms(areaId: String, page: Int, pageSize: Int, completion: @escaping ([LiveRoom]) -> Void) {
        fetchCacheList(gameId: areaId, page: page, completion: completion)
    }

    private func fetchCacheList(gameId: String?, page: Int, completion: @escaping ([LiveRoom]) -> Void) {
        var params: [(String, String)] = [
            ("m", "LiveList"), ("do", "getLiveListByPage"), ("tagAll", "0"),
            ("page", "\(max(1, page))")
        ]
        if let gameId = gameId, !gameId.isEmpty {
            params.append(("gameId", gameId))
        }
        guard let url = LiveListURL.url(base: HuyaLiveSite.cacheListURL, params: params) else {
            completion([])
            return
        }
        LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: listHeaders, fetcher: fetcher) { json in
            completion(HuyaLiveSite.parseCacheList(json) ?? [])
        }
    }

    /// Room search (Dart `searchRooms`): search.cdn.huya.com,
    /// `response["3"]["docs"]`.
    func searchRooms(query: String, page: Int, pageSize: Int, completion: @escaping ([LiveRoom]) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion([])
            return
        }
        let rows = min(50, max(1, pageSize))
        guard let url = LiveListURL.url(base: HuyaLiveSite.searchBaseURL, params: [
            ("m", "Search"), ("do", "getSearchContent"), ("q", trimmed),
            ("uid", "0"), ("v", "4"), ("typ", "-5"), ("livestate", "0"),
            ("rows", "\(rows)"), ("start", "\((max(1, page) - 1) * rows)")
        ]) else {
            completion([])
            return
        }
        LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: searchHeaders, fetcher: fetcher) { json in
            completion(HuyaLiveSite.parseSearchRooms(json) ?? [])
        }
    }

    /// Categories (Dart `getCategories`, port of Pure Live 3.x
    /// `getCategores` + `getSubCategores`): the four top types
    /// are fixed upstream (网游 1 / 单机 2 / 娱乐 8 / 手游 3);
    /// each one's games come from bussLive. The four fetches run
    /// in parallel and one dead type never kills the other three.
    /// When every fetch fails, the verified-popular fallback below
    /// is returned so the tab never shows a blank category row —
    /// the gids are real and `categoryRooms` accepts them.
    func listCategories(completion: @escaping ([(id: String, name: String)]) -> Void) {
        let types = ["1", "2", "8", "3"]
        var collected: [[(id: String, name: String)]] = Array(repeating: [], count: types.count)
        let group = DispatchGroup()
        let lock = NSLock()
        for (index, type) in types.enumerated() {
            group.enter()
            fetchCategoryType(type) { areas in
                lock.lock()
                collected[index] = areas
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: DispatchQueue.global(qos: .utility)) {
            let areas = collected.flatMap { $0 }
            if areas.isEmpty {
                completion(HuyaLiveSite.fallbackCategories)
            } else {
                completion(areas)
            }
        }
    }

    private func fetchCategoryType(_ type: String, completion: @escaping ([(id: String, name: String)]) -> Void) {
        guard let url = LiveListURL.url(base: HuyaLiveSite.categoryConfigURL, params: [("bussType", type)]) else {
            completion([])
            return
        }
        LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: searchHeaders, fetcher: fetcher) { json in
            completion(HuyaLiveSite.parseCategories(json) ?? [])
        }
    }

    /// Verified-popular games per top type (live probe 2026-11-16,
    /// `bussLive` top entries by heat). Only used when all four
    /// live fetches fail; areaId is the real gid, so category
    /// rooms load.
    static let fallbackCategories: [(id: String, name: String)] = [
        ("1", "英雄联盟"), ("862", "CS2"), ("5937", "无畏契约"), ("5485", "lol云顶之弈"),
        ("393", "炉石传说"), ("4", "穿越火线"), ("7", "DOTA2"), ("8", "魔兽世界"),
        ("2793", "天天吃鸡"), ("100032", "主机游戏"), ("1732", "我的世界"), ("70953", "失控进化-RUST"),
        ("485", "植物大战僵尸"), ("1318", "部落：上升"), ("5907", "互动点播"), ("4375", "精灵宝可梦Let's Go"),
        ("2165", "户外"), ("1663", "星秀"), ("6861", "原创"), ("2356", "体育"),
        ("2135", "一起看"), ("4079", "交友"), ("2633", "二次元"), ("2168", "颜值"),
        ("2336", "王者荣耀"), ("9449", "三角洲行动"), ("3203", "和平精英"), ("7185", "金铲铲之战"),
        ("2928", "QQ飞车手游"), ("4769", "COD手游"), ("2429", "火影忍者手游"), ("6909", "蛋仔派对")
    ]

    // MARK: - Pure parsers (fixture-testable, no network)

    /// Parses a cache.php LiveList response (`data.datas[]`).
    /// Nil when the response has no datas list.
    static func parseCacheList(_ json: [String: Any]?) -> [LiveRoom]? {
        guard let json = json,
              let data = LiveJSON.asMap(json["data"]) else { return nil }
        var rooms: [LiveRoom] = []
        for item in LiveJSON.asList(data["datas"]) {
            let roomId = LiveJSON.asString(item["profileRoom"])
            guard !roomId.isEmpty else { continue }
            var cover = LiveJSON.asString(item["screenshot"])
            if !cover.isEmpty && !cover.contains("?") {
                cover += "?x-oss-process=style/w338_h190&"
            }
            var title = LiveJSON.asString(item["introduction"])
            if title.isEmpty {
                title = LiveJSON.asString(item["roomName"])
            }
            rooms.append(LiveRoom(
                roomId: roomId, platform: .huya,
                title: title,
                streamer: LiveJSON.asString(item["nick"]),
                avatar: LiveJSON.asString(item["avatar180"]),
                cover: cover,
                onlineCount: LiveJSON.asInt(item["totalCount"]),
                isLive: true,
                link: "https://www.huya.com/\(roomId)"))
        }
        return rooms
    }

    /// Parses a search.cdn.huya.com response for rooms
    /// (`response["3"]["docs"]`). Nil when the response has no
    /// room docs.
    static func parseSearchRooms(_ json: [String: Any]?) -> [LiveRoom]? {
        guard let json = json,
              let response = LiveJSON.asMap(json["response"]),
              let docs = LiveJSON.asMap(response["3"]) else { return nil }
        var rooms: [LiveRoom] = []
        for item in LiveJSON.asList(docs["docs"]) {
            let roomId = LiveJSON.asString(item["room_id"])
            guard !roomId.isEmpty else { continue }
            var cover = LiveJSON.asString(item["game_screenshot"])
            if !cover.isEmpty && !cover.contains("?") {
                cover += "?x-oss-process=style/w338_h190&"
            }
            var title = LiveJSON.asString(item["game_introduction"])
            if title.isEmpty {
                title = LiveJSON.asString(item["game_roomName"])
            }
            rooms.append(LiveRoom(
                roomId: roomId, platform: .huya,
                title: title,
                streamer: LiveJSON.asString(item["game_nick"]),
                avatar: LiveJSON.asString(item["game_imgUrl"]),
                cover: cover,
                onlineCount: LiveJSON.asInt(item["game_total_count"]),
                isLive: true,
                link: "https://www.huya.com/\(roomId)"))
        }
        return rooms
    }

    /// Parses a `bussLive` response (`data[]` of `{gid,
    /// gameFullName}`) into flat areas. `gid` has four historical
    /// shapes (Pure Live): Map (comma-separated value, take
    /// first), double, int, String.
    static func parseCategories(_ json: [String: Any]?) -> [(id: String, name: String)]? {
        guard let json = json else { return nil }
        var areas: [(id: String, name: String)] = []
        for item in LiveJSON.asList(json["data"]) {
            let gid = HuyaLiveSite.categoryGid(item["gid"])
            let name = LiveJSON.asString(item["gameFullName"])
            guard !gid.isEmpty, !name.isEmpty else { continue }
            areas.append((id: gid, name: name))
        }
        return areas
    }

    private static func categoryGid(_ raw: Any?) -> String {
        if let map = LiveJSON.asMap(raw) {
            let value = LiveJSON.asString(map["value"])
            return value.components(separatedBy: ",").first ?? ""
        }
        if let number = raw as? NSNumber {
            return "\(number.intValue)"
        }
        return LiveJSON.asString(raw)
    }
}

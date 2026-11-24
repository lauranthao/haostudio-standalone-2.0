// HAo Studio 2.0 — Douyin live site (S4 leg B).
//
// Swift port of the Flutter `lib/shared/platforms/douyin/
// douyin_site.dart` (room detail, qualities, resolve) +
// `douyin_audience.dart` (watching counts) +
// `douyin_request_params.dart` + `douyin_utils.dart` (msToken +
// request-URL building).
//
// Two ids: short web_rid (<= 16 chars) vs long numeric roomId.
// Room detail dispatches on length: web_rid ->
// `webcast/room/web/enter` (signed), HTML fallback on failure;
// roomId -> `webcast.amemv.com/webcast/room/reflow/info/`.
// `room.status == 2` => live; `room.stream_url` is stored as
// LiveRoom.data, and the danmaku credentials (webRid, long roomId,
// anonymous user id, cookie) as LiveRoom.danmakuData.
//
// Quality+lines: `stream_url.flv_pull_url` + `hls_pull_url_map`,
// joined by quality key (ORIGIN/FULL_HD1/HD1/SD2/SD1...), never by
// position; sorted by sdk_params level / known key rank, NOT
// v_bit_rate; lines = the FLV + HLS URLs of the same quality
// merged; switching quality needs no re-signing (plain pull URLs).
// No quality is invented: only keys the server returned become menu
// entries, and the audio-only `ao` variant is excluded.
//
// A-Bogus is NOT ported (743 lines of bit-twiddling; the Flutter
// repo has only shape tests for it, no deterministic vectors, so a
// blind port cannot be verified without a compiler). The site uses
// an injectable request-URL signer defaulting to the unsigned
// builder below (same params as DouyinUtils.buildRequestUrl minus
// the A-Bogus step). X-Bogus (WS handshake) IS ported — it lives in
// DouyinDanmaku.swift with the transport that uses it.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Request params

enum DouyinRequestParams {
    static let browserVersion = "5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"
    static let kDefaultUserAgent = "Mozilla/\(browserVersion)"
    static let aidValue = "6383"
    static let versionCodeValue = "180800"
    static let sdkVersion = "1.0.15"
    static let defaultReferer = "https://live.douyin.com"
    static let defaultAuthority = "live.douyin.com"
}

// MARK: - Request signing (unsigned default; A-Bogus deferred)

/// Signs a Douyin request URL: `(baseUrl, params) -> full URL`.
/// The default is the unsigned builder below; a future A-Bogus
/// implementation can be injected here without touching the site.
typealias DouyinRequestUrlSigner = (String, [String: String]) -> String

enum DouyinUtils {
    /// Random msToken (184 chars, upstream default).
    static func getMSToken(randomLength: Int = 184) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789=")
        var result = ""
        result.reserveCapacity(randomLength)
        for _ in 0..<randomLength {
            result.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return result
    }

    /// Builds a request URL the way `DouyinUtils.buildRequestUrl`
    /// does, minus the A-Bogus step: adds aid / compress /
    /// device_platform / browser_* and a fresh msToken when the
    /// caller did not supply one. Keys are sorted for stable output
    /// (the signed variant's order is the signer's business).
    static func unsignedRequestUrl(baseUrl: String, params: [String: String]) -> String {
        guard var components = URLComponents(string: baseUrl) else {
            return baseUrl
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        for (key, value) in params {
            query[key] = value
        }
        query["aid"] = DouyinRequestParams.aidValue
        query["compress"] = "gzip"
        query["device_platform"] = "web"
        query["browser_language"] = "zh-CN"
        query["browser_platform"] = "Win32"
        query["browser_name"] = "Edge"
        query["browser_version"] = "125.0.0.0"
        if query["msToken"] == nil {
            query["msToken"] = getMSToken()
        }
        components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        return components.url?.absoluteString ?? baseUrl
    }
}

// MARK: - Audience counts (douyin_audience.dart, verbatim logic)

extension DouyinLiveSite {
    /// Concurrent viewers, as the server's raw string ('' when
    /// unavailable).
    static func douyinOnlineViewers(_ room: [String: Any]) -> String {
        let viewStats = LiveJSON.asMap(room["room_view_stats"])
        let roomStats = LiveJSON.asMap(room["stats"])
        var candidates: [Any?] = [
            room["user_count"],
            room["user_count_str"],
            room["online_user_count"],
            room["online_user_for_anchor"]
        ]
        if let viewStats = viewStats {
            candidates.append(viewStats["user_count"])
            candidates.append(viewStats["online_user_count"])
            candidates.append(viewStats["online_user_for_anchor"])
        }
        if let roomStats = roomStats {
            candidates.append(roomStats["user_count"])
            candidates.append(roomStats["online_user_count"])
            candidates.append(roomStats["online_user_for_anchor"])
        }
        for value in candidates {
            let text = LiveJSON.asString(value).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty && text != "null" && text.rangeOfCharacter(from: .decimalDigits) != nil {
                return text
            }
        }
        return ""
    }

    /// Cumulative audience for the session, as the server's raw
    /// string. A zero `total_user` in the anonymous feed is an
    /// unavailable placeholder when `user_count` is already
    /// positive — it is ignored so the card can use its explicit
    /// concurrent count instead of a false zero.
    static func douyinTotalViewers(_ room: [String: Any]) -> String {
        let viewStats = LiveJSON.asMap(room["room_view_stats"])
        let roomStats = LiveJSON.asMap(room["stats"])
        var candidates: [Any?] = []
        if let viewStats = viewStats {
            candidates.append(viewStats["display_value"])
            candidates.append(viewStats["total_user_str"])
            candidates.append(viewStats["total_user"])
        }
        if let roomStats = roomStats {
            candidates.append(roomStats["total_user_str"])
            candidates.append(roomStats["total_user"])
        }
        candidates.append(room["total_user_str"])
        candidates.append(room["total_user"])
        for value in candidates {
            let text = LiveJSON.asString(value).trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text == "null" || text.rangeOfCharacter(from: .decimalDigits) == nil {
                continue
            }
            let normalized = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "，", with: "")
            let number = firstNumber(normalized) ?? 0
            if number > 0 {
                return text
            }
        }
        return ""
    }

    /// Audience count for `LiveRoom.onlineCount`: concurrent viewers
    /// first, cumulative audience as fallback, 0 when the server
    /// sent nothing usable.
    static func douyinWatching(_ room: [String: Any]) -> Int {
        let online = douyinOnlineViewers(room)
        if !online.isEmpty {
            return parseAudience(online)
        }
        return parseAudience(douyinTotalViewers(room))
    }

    /// Expands Chinese units (万 = 1e4, 亿 = 1e8, 千 = 1e3) and
    /// decimals ("1.2万"); unparseable input yields 0, never throws.
    static func parseAudience(_ text: String) -> Int {
        let cleaned = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "，", with: "").trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty {
            return 0
        }
        guard let regex = try? NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)\\s*(万|亿|千)?", options: []),
              let match = regex.firstMatch(in: cleaned, options: [], range: NSRange(cleaned.startIndex..., in: cleaned)),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: cleaned),
              let value = Double(cleaned[valueRange]) else {
            return 0
        }
        var multiplier = 1.0
        if match.numberOfRanges >= 3, let unitRange = Range(match.range(at: 2), in: cleaned) {
            switch cleaned[unitRange] {
            case "亿":
                multiplier = 100000000
            case "万":
                multiplier = 10000
            case "千":
                multiplier = 1000
            default:
                break
            }
        }
        return Int((value * multiplier).rounded())
    }

    private static func firstNumber(_ text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: "[0-9]+(?:\\.[0-9]+)?", options: []),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else {
            return nil
        }
        return Double(text[range])
    }
}

// MARK: - Stream qualities (pure, fixture-testable)

extension DouyinLiveSite {
    /// Resolves Douyin qualities by their stable `sdk_key`.
    ///
    /// The modern `stream_data.data` payload and the legacy pull-url
    /// maps are joined by key, never by position (JSON map order is
    /// not a quality contract). Sort key is the sdk_key rank /
    /// sdk_params level, NOT v_bit_rate — source can legitimately
    /// have a lower instantaneous bitrate than a transcoded tier.
    static func parseStreamQualities(_ rawStreamUrl: Any?) -> [LiveQuality] {
        guard let rawStreamUrl = LiveJSON.asMap(rawStreamUrl) else {
            return []
        }
        let liveCore = LiveJSON.asMap(rawStreamUrl["live_core_sdk_data"])
        let pullData = LiveJSON.asMap(liveCore?["pull_data"])
        let options = LiveJSON.asMap(pullData?["options"])
        var optionQualities: [[String: Any]] = []
        if let list = options?["qualities"] as? [Any] {
            optionQualities = list.compactMap { $0 as? [String: Any] }
        }

        var decodedStreams: [String: Any] = [:]
        let streamDataText = LiveJSON.asString(pullData?["stream_data"]).trimmingCharacters(in: .whitespaces)
        if streamDataText.hasPrefix("\u{7B}"),
           let data = streamDataText.data(using: .utf8),
           let decoded = LiveJSON.decodeObject(data),
           let inner = LiveJSON.asMap(decoded["data"]) {
            decodedStreams = inner
        }

        let flvMap = LiveJSON.asMap(rawStreamUrl["flv_pull_url"]) ?? [:]
        let hlsMap = LiveJSON.asMap(rawStreamUrl["hls_pull_url_map"]) ?? [:]
        let resolutionNames = LiveJSON.asMap(rawStreamUrl["resolution_name"]) ?? [:]

        var descriptors: [String: [String: Any]] = [:]
        for option in optionQualities {
            let key = LiveJSON.asString(option["sdk_key"]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                descriptors[key.lowercased()] = descriptors[key.lowercased()] ?? option
            }
        }
        var allKeys: [String] = []
        for map in [decodedStreams, flvMap, hlsMap] {
            for key in map.keys {
                let text = key.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    allKeys.append(text.lowercased())
                }
            }
        }
        for key in allKeys where descriptors[key] == nil {
            descriptors[key] = ["sdk_key": key]
        }

        var qualities: [LiveQuality] = []
        for (key, descriptor) in descriptors {
            var urls: [String] = []
            let stream = caseInsensitiveMapValue(decodedStreams, key: key)
            let main = LiveJSON.asMap((stream as? [String: Any])?["main"])
            if let main = main {
                addPlayableUrl(&urls, main["flv"])
                addPlayableUrl(&urls, main["hls"])
            }
            addPlayableUrl(&urls, caseInsensitiveMapValue(flvMap, key: key))
            addPlayableUrl(&urls, caseInsensitiveMapValue(hlsMap, key: key))
            if urls.isEmpty {
                continue
            }
            // Douyin may publish an `ao` entry beside its video
            // renditions. It is an audio-only pull URL
            // (`only_audio=1`), not a selectable video quality.
            if isAudioOnlyVariant(key, urls: urls) {
                continue
            }
            let configuredName = LiveJSON.asString(descriptor["name"]).trimmingCharacters(in: .whitespaces)
            let resolutionName = LiveJSON.asString(caseInsensitiveMapValue(resolutionNames, key: key)).trimmingCharacters(in: .whitespaces)
            let sdkParams = decodeSdkParams(main?["sdk_params"])
            let bitRate = LiveJSON.asIntOrNil(descriptor["v_bit_rate"]) ?? LiveJSON.asIntOrNil(sdkParams["vbitrate"])
            let resolutionText = LiveJSON.asString(descriptor["resolution"]).trimmingCharacters(in: .whitespaces)
            let resolution = !resolutionText.isEmpty ? resolutionText : LiveJSON.asString(sdkParams["resolution"])
            let level = LiveJSON.asIntOrNil(descriptor["level"]) ?? 0
            let knownRank = douyinQualityRank(key)
            let sort = knownRank > 0 ? knownRank : (level > 0 ? level * 1000000 : (bitRate ?? 0))
            let lines = urls.map { url in
                LiveLine(name: URL(string: url)?.host ?? url, urls: [url], format: formatOfUrl(url))
            }
            qualities.append(LiveQuality(
                id: key.lowercased(),
                name: douyinQualityLabel(key: key, configuredName: configuredName, resolutionName: resolutionName, resolution: resolution, bitrate: bitRate),
                sort: sort,
                lines: lines
            ))
        }

        qualities.sort {
            if $0.sort != $1.sort {
                return $0.sort > $1.sort
            }
            return $0.id < $1.id
        }

        // Platform aliases can expose the same actual URL under both
        // legacy (`FULL_HD1`) and modern (`uhd`) keys. Presenting
        // both would claim a quality change even though the player
        // receives an identical source.
        var seenStreams = Set<String>()
        return qualities.filter { quality in
            let joined = quality.lines.flatMap { $0.urls }.sorted().joined(separator: "\u{0000}")
            return seenStreams.insert(joined).inserted
        }
    }

    /// Douyin SDK-key label mapping (Pure Live): ORIGIN -> 原画,
    /// FULL_HD1/UHD -> 蓝光, HD1 -> 超清, SD2 -> 高清, SD1 -> 标清,
    /// MD -> 流畅. A CJK server name wins as-is; otherwise the
    /// resolution/bitrate falls back to a plain label, never an
    /// invented quality name.
    static func douyinQualityLabel(key: String, configuredName: String, resolutionName: String, resolution: String?, bitrate: Int?) -> String {
        for candidate in [configuredName, resolutionName] {
            if !candidate.isEmpty && containsCJK(candidate) {
                return candidate
            }
        }
        let token = key.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        switch token {
        case "origin", "origion", "original", "source":
            return "原画"
        case "fullhd", "fullhd1", "uhd", "uhd1", "blue", "bluray", "blueray":
            return "蓝光"
        case "fhd", "hd", "hd1":
            return "超清"
        case "sd", "sd2":
            return "高清"
        case "ld", "sd1":
            return "标清"
        case "md":
            return "流畅"
        case "auto":
            return "自动"
        default:
            break
        }
        if let label = resolutionLabel(resolution) {
            return label
        }
        if let bitrate = bitrate, bitrate > 0 {
            return bitrateLabel(bitrate)
        }
        if !configuredName.isEmpty {
            return configuredName
        }
        if !resolutionName.isEmpty {
            return resolutionName
        }
        return key
    }

    private static func resolutionLabel(_ value: String?) -> String? {
        guard let value = value,
              let regex = try? NSRegularExpression(pattern: "(\\d{3,5})\\s*[x×]\\s*(\\d{3,5})", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: value, options: [], range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges >= 3,
              let widthRange = Range(match.range(at: 1), in: value),
              let heightRange = Range(match.range(at: 2), in: value),
              let width = Int(value[widthRange]),
              let height = Int(value[heightRange]) else {
            return nil
        }
        let shortSide = min(width, height)
        if shortSide >= 2160 {
            return "4K"
        }
        if shortSide >= 1440 {
            return "2K 超清"
        }
        if shortSide >= 1080 {
            return "1080P 高清"
        }
        if shortSide >= 720 {
            return "720P 清晰"
        }
        if shortSide >= 480 {
            return "480P 流畅"
        }
        if shortSide >= 360 {
            return "360P 极速"
        }
        return "\(shortSide)P"
    }

    private static func bitrateLabel(_ bitsPerSecond: Int) -> String {
        if bitsPerSecond >= 1000000 {
            let mbps = Double(bitsPerSecond) / 1000000
            if mbps == mbps.rounded() {
                return "\(Int(mbps))M"
            }
            return String(format: "%.1fM", mbps)
        }
        if bitsPerSecond >= 1000 {
            return "\(bitsPerSecond / 1000)K"
        }
        return "\(bitsPerSecond)"
    }

    static func douyinQualityRank(_ key: String) -> Int {
        switch key.uppercased() {
        case "ORIGION", "ORIGIN":
            return 6000000
        case "FULL_HD1", "UHD":
            return 5000000
        case "HD1", "HD":
            return 4000000
        case "SD2", "SD":
            return 3000000
        case "SD1", "LD":
            return 2000000
        case "MD":
            return 1000000
        default:
            return 0
        }
    }

    private static func decodeSdkParams(_ raw: Any?) -> [String: Any] {
        if let map = raw as? [String: Any] {
            return map
        }
        let value = LiveJSON.asString(raw).trimmingCharacters(in: .whitespaces)
        if value.isEmpty {
            return [:]
        }
        guard let data = value.data(using: .utf8) else {
            return [:]
        }
        return LiveJSON.decodeObject(data) ?? [:]
    }

    private static func caseInsensitiveMapValue(_ map: [String: Any], key: String) -> Any? {
        if let direct = map[key] {
            return direct
        }
        let normalized = key.lowercased()
        for (mapKey, value) in map {
            if mapKey.lowercased() == normalized {
                return value
            }
        }
        return nil
    }

    private static func addPlayableUrl(_ urls: inout [String], _ value: Any?) {
        let url = LiveJSON.asString(value).trimmingCharacters(in: .whitespaces)
        guard let uri = URL(string: url), let scheme = uri.scheme, (scheme == "http" || scheme == "https"), !urls.contains(url) else {
            return
        }
        urls.append(url)
    }

    private static func isAudioOnlyVariant(_ key: String, urls: [String]) -> Bool {
        let token = key.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        if token == "ao" || token == "audio" || token == "audioonly" {
            return true
        }
        if urls.isEmpty {
            return false
        }
        return urls.allSatisfy { url in
            let value = LiveQuery.value(URL(string: url)?.query ?? "", key: "only_audio")?.lowercased()
            return value == "1" || value == "true"
        }
    }

    private static func containsCJK(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "[\\u{3400}-\\u{9fff}]", options: []) else {
            return false
        }
        return regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Declared format from the URL path (`.flv` / `.m3u8`);
    /// 'other' when the path carries neither suffix.
    static func formatOfUrl(_ url: String) -> String {
        let path = URL(string: url)?.path.lowercased() ?? ""
        if path.hasSuffix(".flv") {
            return "flv"
        }
        if path.hasSuffix(".m3u8") {
            return "hls"
        }
        return "other"
    }

    static func douyinIsLive(room: [String: Any], envelope: [String: Any]?) -> Bool {
        if let status = LiveJSON.asIntOrNil(room["status"]) {
            return status == 2
        }
        if let envelope = envelope, let roomStatus = LiveJSON.asIntOrNil(envelope["room_status"]) {
            return roomStatus == 0
        }
        return false
    }

    static func firstText(_ candidates: [Any?]) -> String {
        for value in candidates {
            if value == nil || value is [String: Any] || value is [Any] || value is NSNull {
                continue
            }
            let text = LiveJSON.asString(value).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty && text != "null" {
                return text
            }
        }
        return ""
    }

    static func firstImageUrl(_ candidates: [Any?]) -> String {
        for value in candidates {
            if let list = value as? [Any] {
                let nested = firstImageUrl(list.map { $0 as Any? })
                if !nested.isEmpty {
                    return nested
                }
                continue
            }
            if let image = LiveJSON.asMap(value), let urlList = image["url_list"] as? [Any] {
                let url = firstText(urlList)
                if !url.isEmpty {
                    return url
                }
            }
            let direct = firstText([value])
            if direct.hasPrefix("http://") || direct.hasPrefix("https://") {
                return direct
            }
        }
        return ""
    }
}

// MARK: - Site

/// Douyin resolver. Anonymous-only: one 19-digit anonymous visitor
/// id per process, cookies warmed up best-effort (the handshake may
/// still succeed without a cookie for some rooms).
final class DouyinLiveSite: LiveSiteResolver {
    var platform: LivePlatform {
        .douyin
    }

    private let fetcher: LiveDataFetcher
    private let requestUrlSigner: DouyinRequestUrlSigner

    private var cookie = ""
    private var anonymousCookieInFlight = false
    private var anonymousCookieCompletions: [([String: String]) -> Void] = []
    /// In-flight room-detail loads, keyed by trimmed room id
    /// (build 36 item 10 leg 4 — see `loadRoomDetail`).
    private var roomDetailInFlight: [String: [(Result<LiveRoom, Error>) -> Void]] = [:]

    /// Guards the anonymous-cookie cache + in-flight dedup above:
    /// headers are built from URLSession background callbacks and
    /// two concurrent calls used to mutate the same cache/array
    /// with no lock — a data race that traps. The lock is only
    /// ever held for the state touch, never across a network call
    /// or a completion.
    private let stateLock = NSLock()
    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// Current web clients use a 19-digit anonymous visitor ID. One
    /// ID per process so switching rooms does not create a new
    /// viewer identity.
    static let anonymousUserUniqueId = DouyinLiveSite.generateAnonymousUserUniqueId()

    /// Mirrors the numeric visitor-ID range produced by Douyin's
    /// current web client: 7.3e18 (inclusive) through 8e18
    /// (exclusive).
    static func generateAnonymousUserUniqueId(randomDigit: (Int) -> Int = { Int.random(in: 0..<$0) }) -> String {
        var result = "7" + String(3 + randomDigit(7))
        for _ in 0..<17 {
            result += String(randomDigit(10))
        }
        return result
    }

    init(fetcher: LiveDataFetcher? = nil, requestUrlSigner: DouyinRequestUrlSigner? = nil) {
        self.fetcher = fetcher ?? LiveHTTP.defaultFetcher
        self.requestUrlSigner = requestUrlSigner ?? DouyinUtils.unsignedRequestUrl
    }

    func makeDanmakuTransport() -> LiveDanmakuTransport {
        DouyinDanmaku()
    }

    private var baseHeaders: [String: String] {
        [
            "Authority": DouyinRequestParams.defaultAuthority,
            "Referer": DouyinRequestParams.defaultReferer,
            "User-Agent": DouyinRequestParams.kDefaultUserAgent
        ]
    }

    // MARK: - Headers / cookies

    /// Request headers with the warmed-up anonymous cookie. The
    /// cookie fetch is best-effort: headers without a Cookie are
    /// returned when it fails.
    private func requestHeaders(completion: @escaping ([String: String]) -> Void) {
        let cachedCookie = locked { cookie }
        if !cachedCookie.isEmpty {
            var headers = baseHeaders
            headers["Cookie"] = cachedCookie
            completion(headers)
            return
        }
        let alreadyInFlight = locked {
            anonymousCookieCompletions.append(completion)
            if anonymousCookieInFlight {
                return true
            }
            anonymousCookieInFlight = true
            return false
        }
        if alreadyInFlight {
            return
        }
        fetchAnonymousCookie { [weak self] value in
            guard let self = self else {
                return
            }
            let (completions, cookieValue) = self.locked {
                self.anonymousCookieInFlight = false
                if !value.isEmpty {
                    self.cookie = value
                }
                let completions = self.anonymousCookieCompletions
                self.anonymousCookieCompletions = []
                return (completions, self.cookie)
            }
            for item in completions {
                var headers = self.baseHeaders
                if !cookieValue.isEmpty {
                    headers["Cookie"] = cookieValue
                }
                item(headers)
            }
        }
    }

    private func fetchAnonymousCookie(completion: @escaping (String) -> Void) {
        guard let url = URL(string: "https://live.douyin.com/?from_nav=1") else {
            completion("")
            return
        }
        fetchSetCookiePairs(url: url, method: "GET", keys: ["ttwid", "UIFID_TEMP"], completion: completion)
    }

    /// Warms up cookies for one web_rid page (HEAD): ttwid /
    /// __ac_nonce / msToken. Best-effort: '' on failure.
    private func getWebCookie(webRid: String, completion: @escaping (String) -> Void) {
        guard let url = URL(string: "https://live.douyin.com/\(webRid)") else {
            completion("")
            return
        }
        fetchSetCookiePairs(url: url, method: "HEAD", keys: ["ttwid", "__ac_nonce", "msToken"], completion: completion)
    }

    /// Runs one request through the shared URLSession (NOT the
    /// injectable fetcher — the fetcher type carries no response
    /// headers) and reads the wanted cookies back from the shared
    /// cookie jar, which the shared session fills automatically.
    /// Best-effort: '' on any failure.
    private func fetchSetCookiePairs(url: URL, method: String, keys: [String], completion: @escaping (String) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: LiveHTTP.defaultTimeoutSeconds)
        request.httpMethod = method
        for (key, value) in baseHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let task = URLSession.shared.dataTask(with: request) { _, _, _ in
            let pairs = (HTTPCookieStorage.shared.cookies(for: url) ?? [])
                .filter { keys.contains($0.name) }
                .map { "\($0.name)=\($0.value)" }
            completion(pairs.joined(separator: "; "))
        }
        task.resume()
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

    /// Strict room load: throws when no parseable playback metadata
    /// is available (resolve must see the transient error, never a
    /// disguised "offline").
    ///
    /// Build 36 item 10 leg 4: entering a room fires two paths at
    /// once — the playback `resolve` below and the danmaku
    /// `roomInfo` above — and both used to fetch the room detail
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
        let trimmed = roomId.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            completion(.failure(LiveError.invalidRoomId))
            return
        }
        let alreadyInFlight = locked {
            var list = roomDetailInFlight[trimmed] ?? []
            list.append(completion)
            roomDetailInFlight[trimmed] = list
            return list.count > 1
        }
        if alreadyInFlight {
            return
        }
        resolveDetail(roomId: trimmed) { result in
            self.finishRoomDetail(roomId: trimmed, result: result)
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

    private func resolveDetail(roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        if roomId.count <= 16 {
            getRoomDetailByWebRid(roomId, completion: completion)
        } else {
            getRoomDetailByRoomId(roomId, completion: completion)
        }
    }

    private func getRoomDetailByRoomId(_ roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        guard let url = URL(string: "https://webcast.amemv.com/webcast/room/reflow/info/") else {
            completion(.failure(LiveError.parseFailed("抖音 reflow 地址无效")))
            return
        }
        let queryItems = [
            URLQueryItem(name: "type_id", value: "0"),
            URLQueryItem(name: "live_id", value: "1"),
            URLQueryItem(name: "room_id", value: roomId),
            URLQueryItem(name: "sec_user_id", value: ""),
            URLQueryItem(name: "version_code", value: "99.99.99"),
            URLQueryItem(name: "app_id", value: "6383")
        ]
        requestHeaders { headers in
            let request = LiveHTTP.getRequest(url: url, queryItems: queryItems, headers: headers)
            self.fetcher(request) { data, status, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let httpStatus = status, (200..<300).contains(httpStatus), let data = data, let json = LiveJSON.decodeObject(data) else {
                    completion(.failure(LiveError.emptyResponse))
                    return
                }
                let dataMap = LiveJSON.asMap(json["data"]) ?? [:]
                guard let room = LiveJSON.asMap(dataMap["room"]) else {
                    completion(.failure(LiveError.parseFailed("抖音 reflow/info 没有 room")))
                    return
                }
                let owner = LiveJSON.asMap(room["owner"]) ?? [:]
                let webRid = DouyinLiveSite.firstText([owner["web_rid"]])
                if webRid.isEmpty {
                    completion(.failure(LiveError.parseFailed("抖音 reflow/info 没有 web_rid")))
                    return
                }
                let status = LiveJSON.asIntOrNil(room["status"]) ?? 0
                if status == 4 {
                    // Ended/replay placeholder: resolve through the
                    // web_rid path.
                    self.getRoomDetailByWebRid(webRid, completion: completion)
                    return
                }
                let roomStatus = status == 2
                let headers = self.currentHeaders()
                completion(.success(LiveRoom(
                    roomId: webRid,
                    platform: .douyin,
                    title: DouyinLiveSite.firstText([room["title"]]),
                    streamer: DouyinLiveSite.firstText([owner["nickname"]]),
                    avatar: DouyinLiveSite.firstImageUrl([owner["avatar_thumb"]]),
                    cover: roomStatus ? DouyinLiveSite.firstImageUrl([room["cover"]]) : "",
                    onlineCount: roomStatus ? DouyinLiveSite.douyinWatching(room) : 0,
                    isLive: roomStatus,
                    link: LivePlatform.douyin.roomLink(roomId: webRid),
                    data: roomStatus ? LiveJSON.asMap(room["stream_url"]) : [:],
                    danmakuData: [
                        "webRid": webRid,
                        "roomId": roomId,
                        "userId": DouyinLiveSite.anonymousUserUniqueId,
                        "cookie": headers["Cookie"] ?? ""
                    ]
                )))
            }
        }
    }

    private func getRoomDetailByWebRid(_ webRid: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        getRoomDetailByWebRidApi(webRid) { result in
            switch result {
            case .success(let room):
                completion(.success(room))
            case .failure:
                // API path failed — fall back to the room-page HTML
                // scrape.
                self.getRoomDetailByWebRidHtml(webRid, completion: completion)
            }
        }
    }

    private func getRoomDetailByWebRidApi(_ webRid: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        getRoomDataByApi(webRid) { result in
            switch result {
            case .success(let data):
                guard let list = data["data"] as? [Any], !list.isEmpty,
                      let roomData = LiveJSON.asMap(list[0]) else {
                    completion(.failure(LiveError.parseFailed("抖音 room enter 没有 room 数据")))
                    return
                }
                let userData = LiveJSON.asMap(data["user"]) ?? [:]
                let roomId = DouyinLiveSite.firstText([roomData["id_str"]])
                if roomId.isEmpty {
                    completion(.failure(LiveError.parseFailed("抖音 room enter 没有 room id")))
                    return
                }
                let owner = LiveJSON.asMap(roomData["owner"]) ?? [:]
                let roomStatus = DouyinLiveSite.douyinIsLive(room: roomData, envelope: data)
                let headers = self.currentHeaders()
                completion(.success(LiveRoom(
                    roomId: webRid,
                    platform: .douyin,
                    title: DouyinLiveSite.firstText([roomData["title"]]),
                    streamer: roomStatus
                        ? DouyinLiveSite.firstText([owner["nickname"]])
                        : DouyinLiveSite.firstText([userData["nickname"]]),
                    avatar: roomStatus
                        ? DouyinLiveSite.firstImageUrl([owner["avatar_thumb"]])
                        : DouyinLiveSite.firstImageUrl([userData["avatar_thumb"]]),
                    cover: roomStatus ? DouyinLiveSite.firstImageUrl([roomData["cover"]]) : "",
                    onlineCount: roomStatus ? DouyinLiveSite.douyinWatching(roomData) : 0,
                    isLive: roomStatus,
                    link: LivePlatform.douyin.roomLink(roomId: webRid),
                    data: roomStatus ? LiveJSON.asMap(roomData["stream_url"]) : [:],
                    danmakuData: [
                        "webRid": webRid,
                        "roomId": roomId,
                        "userId": DouyinLiveSite.anonymousUserUniqueId,
                        "cookie": headers["Cookie"] ?? ""
                    ]
                )))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func getRoomDetailByWebRidHtml(_ webRid: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        getRoomDataByHtml(webRid) { result in
            switch result {
            case .success(let detail):
                guard let roomStore = LiveJSON.asMap(detail["roomStore"]),
                      let roomInfo = LiveJSON.asMap(roomStore["roomInfo"]),
                      let room = LiveJSON.asMap(roomInfo["room"]) else {
                    completion(.failure(LiveError.parseFailed("抖音房间 HTML 没有 room 信息")))
                    return
                }
                let owner = LiveJSON.asMap(room["owner"]) ?? [:]
                let anchor = LiveJSON.asMap(roomInfo["anchor"]) ?? [:]
                let realRoomId = DouyinLiveSite.firstText([room["id_str"]])
                let userStore = LiveJSON.asMap(detail["userStore"]) ?? [:]
                let odin = LiveJSON.asMap(userStore["odin"]) ?? [:]
                let rawUserUniqueId = LiveJSON.asString(odin["user_unique_id"])
                let userUniqueId = DouyinLiveSite.is19DigitId(rawUserUniqueId) ? rawUserUniqueId : DouyinLiveSite.anonymousUserUniqueId
                let roomStatus = (LiveJSON.asIntOrNil(room["status"]) ?? 0) == 2
                let headers = self.currentHeaders()
                completion(.success(LiveRoom(
                    roomId: webRid,
                    platform: .douyin,
                    title: DouyinLiveSite.firstText([room["title"]]),
                    streamer: roomStatus
                        ? DouyinLiveSite.firstText([owner["nickname"]])
                        : DouyinLiveSite.firstText([anchor["nickname"]]),
                    avatar: roomStatus
                        ? DouyinLiveSite.firstImageUrl([owner["avatar_thumb"]])
                        : DouyinLiveSite.firstImageUrl([anchor["avatar_thumb"]]),
                    cover: roomStatus ? DouyinLiveSite.firstImageUrl([room["cover"]]) : "",
                    onlineCount: roomStatus ? DouyinLiveSite.douyinWatching(room) : 0,
                    isLive: roomStatus,
                    link: LivePlatform.douyin.roomLink(roomId: webRid),
                    data: roomStatus ? LiveJSON.asMap(room["stream_url"]) : [:],
                    danmakuData: [
                        "webRid": webRid,
                        "roomId": realRoomId,
                        "userId": userUniqueId,
                        "cookie": headers["Cookie"] ?? ""
                    ]
                )))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private static func is19DigitId(_ value: String) -> Bool {
        value.count == 19 && value.allSatisfy { $0.isNumber }
    }

    private func getRoomDataByApi(_ webRid: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        requestHeaders { headers in
            let targetUrl = self.requestUrlSigner(
                "https://live.douyin.com/webcast/room/web/enter/",
                [
                    "app_name": "douyin_web",
                    "enter_from": "web_live",
                    "live_id": "1",
                    "web_rid": webRid,
                    "is_need_double_stream": "false"
                ]
            )
            guard let url = URL(string: targetUrl) else {
                completion(.failure(LiveError.parseFailed("抖音 room enter 地址无效")))
                return
            }
            var request = URLRequest(url: url, timeoutInterval: LiveHTTP.defaultTimeoutSeconds)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            self.fetcher(request) { data, status, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let status = status, (200..<300).contains(status), let data = data, let json = LiveJSON.decodeObject(data),
                      let dataMap = LiveJSON.asMap(json["data"]) else {
                    completion(.failure(LiveError.parseFailed("抖音 room enter 没有 data")))
                    return
                }
                completion(.success(dataMap))
            }
        }
    }

    private func getRoomDataByHtml(_ webRid: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        getWebCookie(webRid: webRid) { dyCookie in
            guard let url = URL(string: "https://live.douyin.com/\(webRid)") else {
                completion(.failure(LiveError.parseFailed("抖音房间地址无效")))
                return
            }
            var headers: [String: String] = [
                "Authority": DouyinRequestParams.defaultAuthority,
                "Referer": DouyinRequestParams.defaultReferer,
                "User-Agent": DouyinRequestParams.kDefaultUserAgent
            ]
            if !dyCookie.isEmpty {
                headers["Cookie"] = dyCookie
            }
            let request = LiveHTTP.getRequest(url: url, headers: headers)
            self.fetcher(request) { data, status, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let status = status, (200..<300).contains(status), let data = data, let html = String(data: data, encoding: .utf8) else {
                    completion(.failure(LiveError.emptyResponse))
                    return
                }
                do {
                    completion(.success(try DouyinLiveSite.parseRenderData(html)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Extracts the RENDER_DATA `state` object from a room page.
    /// The page embeds the JSON double-escaped inside a JS string
    /// (a `state` object whose first key is `appStore`, then a long
    /// payload); the match is unescaped in the same order as the
    /// Flutter port (`\"` -> `"`, `\\` -> `\`), then the `]\n`
    /// terminator the regex consumed is stripped.
    static func parseRenderData(_ html: String) throws -> [String: Any] {
        let openBrace = "\u{7B}"
        let pattern = "\\\(openBrace)\\\\\"state\\\\\":\\\(openBrace)\\\\\"appStore.*?\\]\\\\n"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
              let matchRange = Range(match.range, in: html) else {
            throw LiveError.parseFailed("抖音房间 HTML 没有 render 数据")
        }
        var str = String(html[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        str = str.replacingOccurrences(of: "\\\"", with: "\"")
        str = str.replacingOccurrences(of: "\\\\", with: "\\")
        str = str.replacingOccurrences(of: "]\\n", with: "")
        guard let data = str.data(using: .utf8),
              let decoded = LiveJSON.decodeObject(data),
              let state = LiveJSON.asMap(decoded["state"]) else {
            throw LiveError.parseFailed("抖音房间 HTML 没有 state")
        }
        return state
    }

    /// Headers already warmed up (no fetch): the room-detail
    /// builders run after `requestHeaders`, so the cached cookie is
    /// what they attach.
    private func currentHeaders() -> [String: String] {
        var headers = baseHeaders
        if !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        return headers
    }

    // MARK: - Resolve

    /// Douyin pull URLs are plain CDN URLs (no re-signing, no
    /// lease): issuedAt is recorded but refreshAt/invalidAt stay
    /// nil — there is no expiry to proactively refresh against.
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
                let qualities = DouyinLiveSite.parseStreamQualities(room.data)
                if qualities.isEmpty {
                    completion(.failure(LiveError.noQualities))
                    return
                }
                let requested = qualities.first { $0.id == quality?.id } ?? qualities[0]
                completion(.success(LivePlayUrlResolution.applying(requested, in: qualities)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}

// MARK: - Lists (recommend / categories / search)
//
// Port of the Flutter `douyin_site.dart` list methods
// (getRecommendRooms / getCategories / getCategoryRooms) +
// `douyin_search.dart` (three-stage room search). The
// room-detail leg (S4-B) left these out; the live tab's gateway
// needs them. Every method completes with [] on any failure —
// a list failure is an empty list, never a throw out of the
// completion handler. All parsing is pure + static so fixtures
// can cover it without network.
//
// The feed endpoint has no paging of its own: the whole feed is
// fetched once and the page slice is taken client-side.

extension DouyinLiveSite {
    private static let feedURL = "https://live.douyin.com/webcast/feed/"
    private static let homeURL = "https://live.douyin.com/"
    private static let partitionRoomsURL = "https://live.douyin.com/webcast/web/partition/detail/room/v2/"
    private static let partitionRoomsFallbackURL = "https://webcast.amemv.com/webcast/web/partition/detail/room/v2/"
    private static let liveSearchURL = "https://www.douyin.com/aweme/v1/web/live/search/"
    private static let generalSearchURL = "https://www.douyin.com/aweme/v1/web/general/search/stream/"
    private static let partitionSearchURL = "https://live.douyin.com/webcast/web/partition/search/"
    private static let searchUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// Recommended rooms (Dart `getRecommendRooms`): the
    /// anonymous webcast feed, sliced client-side. A feed failure
    /// returns an empty list rather than fake rooms.
    func recommendRooms(page: Int, pageSize: Int, completion: @escaping ([LiveRoom]) -> Void) {
        let size = max(1, pageSize)
        let currentPage = max(1, page)
        requestHeaders { [weak self] headers in
            guard let self = self else { return }
            guard let url = LiveListURL.url(base: DouyinLiveSite.feedURL, params: [
                ("aid", "6383"), ("app_name", "douyin_web"), ("need_map", "1"),
                ("is_draw", "1"), ("inner_from_drawer", "0"),
                ("enter_source", "web_homepage_hot_web_live_card"),
                ("source_key", "web_homepage_hot_web_live_card")
            ]) else {
                completion([])
                return
            }
            LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: headers, fetcher: self.fetcher) { json in
                guard let rooms = DouyinLiveSite.parseRecommendRooms(json) else {
                    completion([])
                    return
                }
                completion(DouyinLiveSite.slice(rooms, page: currentPage, pageSize: size))
            }
        }
    }

    /// Categories (Dart `getCategories`): the homepage
    /// `categoryData` blob. Homepage blocked (bot check) or the
    /// SSR blob moved: never leave the tab without categories —
    /// the fallback ids are the repo's on-record partition ids.
    func listCategories(completion: @escaping ([(id: String, name: String)]) -> Void) {
        requestHeaders { [weak self] headers in
            guard let self = self else { return }
            guard let url = URL(string: "https://live.douyin.com/?from_nav=1") else {
                completion(DouyinLiveSite.fallbackCategories)
                return
            }
            var request = URLRequest(url: url, timeoutInterval: LiveHTTP.defaultTimeoutSeconds)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            LiveHTTP.fetchText(request: request, fetcher: self.fetcher) { _, html in
                guard let html = html else {
                    completion(DouyinLiveSite.fallbackCategories)
                    return
                }
                let areas = DouyinLiveSite.parseCategories(html)
                completion(areas.isEmpty ? DouyinLiveSite.fallbackCategories : areas)
            }
        }
    }

    static let fallbackCategories: [(id: String, name: String)] = [
        ("1,1", "游戏"), ("2,1", "英雄联盟")
    ]

    /// Rooms of one partition (Dart `getCategoryRooms`):
    /// areaId is "id,type" — the exact shape listCategories
    /// produces. Count is 15 per page, offset by page.
    func categoryRooms(areaId: String, page: Int, pageSize: Int, completion: @escaping ([LiveRoom]) -> Void) {
        let parts = areaId.components(separatedBy: ",")
        let partitionId = parts.first ?? ""
        let partitionType = parts.count > 1 ? parts[1] : ""
        guard !partitionId.isEmpty else {
            completion([])
            return
        }
        let currentPage = max(1, page)
        let params: [String: String] = [
            "aid": "6383", "app_name": "douyin_web", "live_id": "1",
            "device_platform": "web", "language": "zh-CN",
            "enter_from": "link_share", "cookie_enabled": "true",
            "screen_width": "1980", "screen_height": "1080",
            "browser_language": "zh-CN", "browser_platform": "Win32",
            "browser_name": "Edge", "browser_version": "125.0.0.0",
            "browser_online": "true", "count": "15",
            "offset": "\((currentPage - 1) * 15)",
            "partition": partitionId, "partition_type": partitionType,
            "req_from": "2"
        ]
        requestHeaders { [weak self] headers in
            guard let self = self else { return }
            // Build 37 (D1): two hosts, same as partitionRooms —
            // the first host (live.douyin.com) refuses unsigned
            // category requests and the category had no fallback
            // at all, so a refusal became an empty page. A host
            // only wins when it returns a non-empty room list;
            // anything else (refusal, empty, bad JSON) moves to
            // the next host. A genuinely empty category still
            // ends empty — it just costs one extra request.
            let hosts = [DouyinLiveSite.partitionRoomsURL, DouyinLiveSite.partitionRoomsFallbackURL]
            var hostIndex = 0
            func attempt() {
                if hostIndex >= hosts.count {
                    completion([])
                    return
                }
                let target = self.requestUrlSigner(hosts[hostIndex], params)
                hostIndex += 1
                guard let url = URL(string: target) else {
                    attempt()
                    return
                }
                LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: headers, fetcher: self.fetcher) { json in
                    if let rooms = DouyinLiveSite.parseCategoryRooms(json), !rooms.isEmpty {
                        completion(rooms)
                        return
                    }
                    attempt()
                }
            }
            attempt()
        }
    }

    /// Room search (Dart `DouyinSearch.search`): three stages,
    /// first non-empty wins — live API, general API, partition
    /// search. Every stage failing returns [].
    func searchRooms(query: String, page: Int, pageSize: Int, completion: @escaping ([LiveRoom]) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion([])
            return
        }
        let currentPage = max(1, page)
        let size = min(50, max(1, pageSize))
        searchByLiveAPI(keyword: trimmed, page: currentPage, pageSize: size) { [weak self] rooms in
            guard let self = self else { return }
            if !rooms.isEmpty {
                completion(rooms)
                return
            }
            self.searchByGeneralAPI(keyword: trimmed, page: currentPage, pageSize: size) { [weak self] rooms in
                guard let self = self else { return }
                if !rooms.isEmpty {
                    completion(rooms)
                    return
                }
                self.searchByPartition(keyword: trimmed, page: currentPage, pageSize: size, completion: completion)
            }
        }
    }

    /// Search headers (Dart `DouyinSearch._getHeaders`): the
    /// warmed-up anonymous cookie + a search Referer. The cookie
    /// fetch is best-effort: headers without a Cookie are
    /// returned when it fails.
    private func searchHeaders(keyword: String, completion: @escaping ([String: String]) -> Void) {
        requestHeaders { headers in
            var result: [String: String] = [
                "User-Agent": DouyinLiveSite.searchUserAgent,
                "Accept": "application/json, text/plain, */*",
                "Accept-Language": "zh-CN,zh;q=0.9",
                "Referer": "https://www.douyin.com/search/\(LiveQuery.percentEncode(keyword))?source=switch_tab&type=live",
                "Origin": "https://www.douyin.com",
                "Sec-Fetch-Dest": "empty",
                "Sec-Fetch-Mode": "cors",
                "Sec-Fetch-Site": "same-origin"
            ]
            if let cookie = headers["Cookie"], !cookie.isEmpty {
                result["Cookie"] = cookie
            }
            completion(result)
        }
    }

    private func searchByLiveAPI(keyword: String, page: Int, pageSize: Int, completion: @escaping ([LiveRoom]) -> Void) {
        let count = min(50, max(1, pageSize))
        let offset = count * (page - 1)
        searchHeaders(keyword: keyword) { [weak self] headers in
            guard let self = self else { return }
            guard let url = LiveListURL.url(base: DouyinLiveSite.liveSearchURL, params: [
                ("device_platform", "webapp"), ("aid", "6383"), ("channel", "channel_pc_web"),
                ("search_channel", "aweme_live"), ("search_source", "switch_tab"),
                ("query_correct_type", "1"), ("need_filter_settings", "1"),
                ("list_type", "single"), ("keyword", keyword),
                ("offset", "\(offset)"), ("count", "\(count)"), ("os_version", "10")
            ]) else {
                completion([])
                return
            }
            LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: headers, fetcher: self.fetcher) { json in
                guard let json = json, LiveJSON.asInt(json["status_code"]) == 0 else {
                    completion([])
                    return
                }
                completion(DouyinLiveSite.parseSearchVideos(json["data"]))
            }
        }
    }

    private func searchByGeneralAPI(keyword: String, page: Int, pageSize: Int, completion: @escaping ([LiveRoom]) -> Void) {
        let count = min(50, max(1, pageSize))
        let offset = count * (page - 1)
        searchHeaders(keyword: keyword) { [weak self] headers in
            guard let self = self else { return }
            guard let url = LiveListURL.url(base: DouyinLiveSite.generalSearchURL, params: [
                ("device_platform", "webapp"), ("aid", "6383"), ("channel", "channel_pc_web"),
                ("search_channel", "aweme_live"), ("keyword", keyword),
                ("offset", "\(offset)"), ("count", "\(count)"), ("os_version", "10")
            ]) else {
                completion([])
                return
            }
            LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: headers, fetcher: self.fetcher) { json in
                guard let json = json, LiveJSON.asInt(json["status_code"]) == 0 else {
                    completion([])
                    return
                }
                completion(DouyinLiveSite.parseSearchVideos(json["data"]))
            }
        }
    }

    private func searchByPartition(keyword: String, page: Int, pageSize: Int, completion: @escaping ([LiveRoom]) -> Void) {
        searchHeaders(keyword: keyword) { [weak self] headers in
            guard let self = self else { return }
            guard let url = LiveListURL.url(base: DouyinLiveSite.partitionSearchURL, params: [
                ("keyword", keyword), ("aid", "6383")
            ]) else {
                completion([])
                return
            }
            LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: headers, fetcher: self.fetcher) { [weak self] json in
                guard let self = self else { return }
                guard let json = json,
                      let data = LiveJSON.asMap(json["data"]),
                      let partitions = data["SearchResult"] as? [Any],
                      !partitions.isEmpty else {
                    completion([])
                    return
                }
                self.searchPartitionRooms(partitions: partitions, page: page, pageSize: pageSize, headers: headers, completion: completion)
            }
        }
    }

    /// Walks at most the first three partitions, merging rooms
    /// (deduped by room id) until the page is full. One dead
    /// partition never kills the other two.
    private func searchPartitionRooms(partitions: [Any], page: Int, pageSize: Int, headers: [String: String], completion: @escaping ([LiveRoom]) -> Void) {
        var merged: [LiveRoom] = []
        var seen: Set<String> = []
        let limit = min(3, partitions.count)
        var index = 0
        func next() {
            if index >= limit || merged.count >= pageSize {
                completion(merged)
                return
            }
            let partitionItem = partitions[index]
            index += 1
            guard let itemMap = LiveJSON.asMap(partitionItem),
                  let partition = LiveJSON.asMap(itemMap["partition"]) else {
                next()
                return
            }
            let partitionId = LiveJSON.asString(partition["id_str"])
            guard !partitionId.isEmpty, let partitionType = partition["type"] else {
                next()
                return
            }
            self.partitionRooms(partition: partitionId, partitionType: "\(partitionType)", page: page, pageSize: pageSize, headers: headers) { rooms in
                for room in rooms {
                    if seen.insert(room.roomId).inserted {
                        merged.append(room)
                        if merged.count >= pageSize {
                            break
                        }
                    }
                }
                next()
            }
        }
        next()
    }

    /// Partition rooms for one partition id/type, trying both
    /// hosts (Dart `DouyinSearch._getPartitionRooms`). The first
    /// host returning a non-empty list wins.
    private func partitionRooms(partition: String, partitionType: String, page: Int, pageSize: Int, headers: [String: String], completion: @escaping ([LiveRoom]) -> Void) {
        let count = min(50, max(1, pageSize))
        let params: [String: String] = [
            "aid": "6383", "app_name": "douyin_web", "live_id": "1",
            "device_platform": "web", "language": "zh-CN",
            "browser_language": "zh-CN", "browser_platform": "Win32",
            "browser_name": "Chrome", "browser_version": "120.0.0.0",
            "partition": partition, "partition_type": partitionType,
            "count": "\(count)", "offset": "\((page - 1) * count)",
            "cookie_enabled": "true", "screen_width": "1920", "screen_height": "1080"
        ]
        let hosts = [DouyinLiveSite.partitionRoomsURL, DouyinLiveSite.partitionRoomsFallbackURL]
        var hostIndex = 0
        func attempt() {
            if hostIndex >= hosts.count {
                completion([])
                return
            }
            let target = self.requestUrlSigner(hosts[hostIndex], params)
            hostIndex += 1
            guard let url = URL(string: target) else {
                attempt()
                return
            }
            LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: headers, fetcher: self.fetcher) { json in
                guard let json = json, LiveJSON.asInt(json["status_code"]) == 0,
                      let data = LiveJSON.asMap(json["data"]),
                      let list = data["data"] as? [Any], !list.isEmpty else {
                    attempt()
                    return
                }
                completion(DouyinLiveSite.parsePartitionRoomList(list))
            }
        }
        attempt()
    }

    // MARK: - Pure parsers (fixture-testable, no network)

    /// Client-side page slice of a fetched-full list. Page is
    /// 1-based; out-of-range pages are empty, never faked.
    static func slice(_ rooms: [LiveRoom], page: Int, pageSize: Int) -> [LiveRoom] {
        let start = (max(1, page) - 1) * pageSize
        guard start < rooms.count else { return [] }
        let end = min(start + pageSize, rooms.count)
        return Array(rooms[start..<end])
    }

    /// Parses both generations of the anonymous feed response:
    /// the legacy `data.data` list and (since Aug 2026) `data`
    /// as a list of feed envelopes with the room in each
    /// envelope's `data` field. Nil when the response is not a
    /// code-0 object with a room list.
    static func parseRecommendRooms(_ json: [String: Any]?) -> [LiveRoom]? {
        guard let root = json else { return nil }
        if let status = LiveJSON.asIntOrNil(root["status_code"]), status != 0 {
            return nil
        }
        var rawRooms = root["data"]
        if let map = LiveJSON.asMap(rawRooms) {
            rawRooms = map["data"]
        }
        guard let list = rawRooms as? [Any] else { return nil }
        var rooms: [LiveRoom] = []
        var seen: Set<String> = []
        for rawItem in list {
            guard let envelope = LiveJSON.asMap(rawItem) else { continue }
            let embedded = DouyinLiveSite.decodeEmbeddedMap(envelope["data"])
            // The embedded JSON string may itself wrap the room one
            // level deeper ({"room": {...}} — the "new envelope"
            // shape). The wrapper is not room-like, so without this
            // unwrap the item is skipped and the list comes back empty.
            let embeddedRoom = LiveJSON.asMap(embedded?["room"])
            let nestedRoom = LiveJSON.asMap(envelope["room"])
            var room: [String: Any]? = nil
            for candidate in [embeddedRoom, embedded, nestedRoom, envelope] as [[String: Any]?] {
                if let candidate = candidate, DouyinLiveSite.looksLikeRoom(candidate) {
                    room = candidate
                    break
                }
            }
            guard let room = room else { continue }
            let owner = LiveJSON.asMap(room["owner"]) ?? LiveJSON.asMap(envelope["owner"]) ?? [:]
            let roomId = DouyinLiveSite.firstText([envelope["web_rid"], owner["web_rid"], room["web_rid"], room["id_str"], room["id"]])
            guard !roomId.isEmpty, seen.insert(roomId).inserted else { continue }
            let title = DouyinLiveSite.firstText([room["title"], envelope["title"], owner["nickname"]])
            let nick = DouyinLiveSite.firstText([owner["nickname"], envelope["nickname"]])
            rooms.append(LiveRoom(
                roomId: roomId, platform: .douyin,
                title: title,
                streamer: nick,
                avatar: DouyinLiveSite.firstImageUrl([owner["avatar_thumb"], owner["avatar_large"], envelope["avatar_thumb"]]),
                cover: DouyinLiveSite.firstImageUrl([room["cover"], envelope["cover"]]),
                onlineCount: DouyinLiveSite.douyinWatching(room),
                isLive: true,
                link: "https://live.douyin.com/\(roomId)"))
        }
        return rooms
    }

    private static func decodeEmbeddedMap(_ value: Any?) -> [String: Any]? {
        if let direct = LiveJSON.asMap(value) {
            return direct
        }
        // Open brace as a scalar: a literal open brace here
        // would break the preflight brace count (it counts
        // braces naively, including inside strings/comments).
        let openBrace = String(UnicodeScalar(0x7B))
        guard let text = value as? String, text.trimmingCharacters(in: .whitespaces).hasPrefix(openBrace) else {
            return nil
        }
        return LiveJSON.decodeObject(Data(text.utf8))
    }

    private static func looksLikeRoom(_ value: [String: Any]) -> Bool {
        return value["owner"] is [String: Any]
            || value["title"] != nil
            || value["id_str"] != nil
            || value["stream_url"] is [String: Any]
    }

    /// Parses the homepage `categoryData` blob into areas.
    /// areaId is "id,type" — the exact shape categoryRooms
    /// splits on. The blob escaping varies by page generation
    /// (raw, singly- or doubly-escaped JSON), so extraction is
    /// retried on the HTML unescaped 0..3 times; the first
    /// attempt yielding a `categoryData` list wins.
    static func parseCategories(_ html: String) -> [(id: String, name: String)] {
        var text = html
        for _ in 0..<4 {
            let extracted = DouyinLiveSite.extractCategoryDataJson(text)
            if !extracted.isEmpty,
               let renderData = LiveJSON.decodeObject(Data(extracted.utf8)),
               let data = renderData["categoryData"] as? [Any] {
                return DouyinLiveSite.areasFromCategoryData(data)
            }
            text = DouyinLiveSite.unescapeOnce(text)
        }
        return []
    }

    /// One JSON-unescape pass: backslash-quote becomes a quote,
    /// then a doubled backslash becomes one.
    static func unescapeOnce(_ value: String) -> String {
        value.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func areasFromCategoryData(_ data: [Any]) -> [(id: String, name: String)] {
        var areas: [(id: String, name: String)] = []
        for item in data {
            guard let itemMap = LiveJSON.asMap(item),
                  let partition = LiveJSON.asMap(itemMap["partition"]) else { continue }
            let id = "\(LiveJSON.asString(partition["id_str"])),\(LiveJSON.asString(partition["type"]))"
            let title = LiveJSON.asString(partition["title"])
            guard !title.isEmpty else { continue }
            areas.append((id: id, name: title))
            if let subs = itemMap["sub_partition"] as? [Any] {
                for subItem in subs {
                    guard let subMap = LiveJSON.asMap(subItem),
                          let subPartition = LiveJSON.asMap(subMap["partition"]) else { continue }
                    let subId = "\(LiveJSON.asString(subPartition["id_str"])),\(LiveJSON.asString(subPartition["type"]))"
                    let subTitle = LiveJSON.asString(subPartition["title"])
                    guard !subTitle.isEmpty else { continue }
                    areas.append((id: subId, name: subTitle))
                }
            }
        }
        return areas
    }

    static func extractCategoryDataJson(_ source: String) -> String {
        // Open brace built from a scalar (see decodeEmbeddedMap):
        // a literal open brace in these patterns would break the
        // preflight brace count, which counts braces naively.
        let openBrace = String(UnicodeScalar(0x7B))
        let startPatterns = [openBrace + "\\\"pathname\\\":\\\"/\\\",\\\"categoryData\\\":" , openBrace + "\"pathname\":\"/\",\"categoryData\":"]
        for pattern in startPatterns {
            guard let startRange = source.range(of: pattern) else { continue }
            var openBraces = 0
            var foundFirstBrace = false
            var index = startRange.lowerBound
            while index < source.endIndex {
                let char = source[index]
                if char == "{" {
                    openBraces += 1
                    foundFirstBrace = true
                } else if char == "}" {
                    openBraces -= 1
                }
                if foundFirstBrace && openBraces == 0 {
                    let rawData = String(source[startRange.lowerBound...index])
                    return rawData.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                }
                index = source.index(after: index)
            }
        }
        return ""
    }

    /// Parses a partition room list (`data.data[]`) into rooms.
    /// Nil when the payload has no room list.
    static func parseCategoryRooms(_ json: [String: Any]?) -> [LiveRoom]? {
        guard let root = json,
              let data = LiveJSON.asMap(root["data"]),
              let list = data["data"] as? [Any] else { return nil }
        return DouyinLiveSite.parsePartitionRoomList(list)
    }

    /// Parses a partition room list (`data.data[]` from
    /// partition/detail/room/v2) into rooms.
    static func parsePartitionRoomList(_ payload: [Any]) -> [LiveRoom] {
        var rooms: [LiveRoom] = []
        for item in payload {
            guard let itemMap = LiveJSON.asMap(item),
                  let room = LiveJSON.asMap(itemMap["room"]) else { continue }
            let owner = LiveJSON.asMap(room["owner"]) ?? [:]
            let roomId = DouyinLiveSite.firstText([itemMap["web_rid"], owner["web_rid"]])
            guard !roomId.isEmpty else { continue }
            rooms.append(LiveRoom(
                roomId: roomId, platform: .douyin,
                title: DouyinLiveSite.firstText([room["title"]]),
                streamer: DouyinLiveSite.firstText([owner["nickname"]]),
                avatar: DouyinLiveSite.firstImageUrl([owner["avatar_thumb"]]),
                cover: DouyinLiveSite.firstImageUrl([room["cover"]]),
                onlineCount: DouyinLiveSite.douyinWatching(room),
                isLive: true,
                link: "https://live.douyin.com/\(roomId)"))
        }
        return rooms
    }

    /// Parses a search `data` list (live/general API) into rooms.
    static func parseSearchVideos(_ payload: Any?) -> [LiveRoom] {
        guard let list = payload as? [Any] else { return [] }
        var result: [LiveRoom] = []
        var seen: Set<String> = []
        for item in list {
            let raw = DouyinLiveSite.parseRawLiveData(item)
            let itemMap = LiveJSON.asMap(item) ?? [:]
            let fallback: [String: Any] = [
                "nickname": itemMap["nickname"] as Any,
                "title": (itemMap["title"] ?? itemMap["desc"]) as Any,
                "tag": itemMap["search_keyword"] as Any
            ]
            guard let room = DouyinLiveSite.normalizeSearchItem(raw, fallback: fallback),
                  seen.insert(room.roomId).inserted else { continue }
            result.append(room)
        }
        return result
    }

    private static func parseRawLiveData(_ item: Any?) -> [String: Any]? {
        guard let itemMap = LiveJSON.asMap(item) else { return nil }
        let candidates: [Any?] = [
            mapValue(mapValue(itemMap, "lives"), "rawdata"),
            mapValue(mapValue(itemMap, "lives"), "raw_data"),
            mapValue(mapValue(itemMap, "live"), "rawdata"),
            mapValue(mapValue(itemMap, "live_info"), "rawdata"),
            mapValue(mapValue(mapValue(itemMap, "aweme_info"), "live_info"), "rawdata"),
            mapValue(mapValue(itemMap, "data"), "rawdata"),
            itemMap["rawdata"],
            itemMap["lives"],
            itemMap["live"],
            itemMap["live_info"],
            mapValue(mapValue(itemMap, "aweme_info"), "live_info"),
            itemMap["aweme_info"],
            itemMap["data"],
            itemMap
        ]
        for candidate in candidates {
            if let text = candidate as? String {
                if let decoded = LiveJSON.decodeObject(Data(text.utf8)) {
                    return decoded
                }
                continue
            }
            if let map = LiveJSON.asMap(candidate) {
                return map
            }
        }
        return nil
    }

    private static func normalizeSearchItem(_ raw: [String: Any]?, fallback: [String: Any] = [:]) -> LiveRoom? {
        guard let raw = raw else { return nil }
        let room = LiveJSON.asMap(raw["room"]) ?? [:]
        let owner = LiveJSON.asMap(raw["owner"]) ?? [:]
        let roomOwner = LiveJSON.asMap(room["owner"]) ?? [:]
        let roomId = DouyinLiveSite.firstText([raw["id_str"], raw["room_id_str"], room["id_str"], room["id"], raw["room_id"], raw["roomId"]])
        guard !roomId.isEmpty else { return nil }
        let webRid = DouyinLiveSite.firstText([owner["web_rid"], raw["web_rid"], roomOwner["web_rid"]])
        let nickname = DouyinLiveSite.firstText([owner["nickname"], raw["nickname"], roomOwner["nickname"], fallback["nickname"]])
        let title = DouyinLiveSite.firstText([raw["title"], room["title"], fallback["title"], nickname])
        let cover = LiveJSON.asMap(raw["cover"])
        let roomCover = LiveJSON.asMap(room["cover"])
        let avatarLarge = LiveJSON.asMap(owner["avatar_large"])
        let avatarThumb = LiveJSON.asMap(owner["avatar_thumb"])
        func firstUrl(_ value: Any?) -> String {
            guard let list = value as? [Any], let first = list.first else { return "" }
            return LiveJSON.asString(first)
        }
        let pic = DouyinLiveSite.firstText([
            firstUrl(avatarLarge?["url_list"]),
            firstUrl(cover?["url_list"]),
            firstUrl(roomCover?["url_list"]),
            raw["cover_url"]
        ])
        let status = LiveJSON.asInt(raw["status"]) == 2
        var tagText: String?
        if let roadMap = room["partition_road_map"] as? [Any],
           let firstPartition = LiveJSON.asMap(roadMap.first) {
            tagText = LiveJSON.asString(firstPartition["title"])
        }
        if tagText == nil || tagText?.isEmpty == true {
            tagText = DouyinLiveSite.firstText([raw["video_feed_tag"], mapValue(raw["partition"], "title"), fallback["tag"]])
        }
        _ = tagText
        let realWebRid = webRid.isEmpty ? roomId : webRid
        let avatar = DouyinLiveSite.firstText([firstUrl(avatarThumb?["url_list"]), firstUrl(avatarLarge?["url_list"])])
        var watching = DouyinLiveSite.douyinWatching(room)
        if watching == 0 {
            watching = DouyinLiveSite.douyinWatching(raw)
        }
        return LiveRoom(
            roomId: realWebRid, platform: .douyin,
            title: title,
            streamer: nickname.isEmpty ? "抖音直播" : nickname,
            avatar: avatar,
            cover: pic,
            onlineCount: watching,
            isLive: status,
            link: "https://live.douyin.com/\(realWebRid)")
    }

    private static func mapValue(_ value: Any?, _ key: String) -> Any? {
        guard let map = LiveJSON.asMap(value) else { return nil }
        return map[key]
    }
}

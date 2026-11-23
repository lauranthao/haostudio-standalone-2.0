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
        if !cookie.isEmpty {
            var headers = baseHeaders
            headers["Cookie"] = cookie
            completion(headers)
            return
        }
        anonymousCookieCompletions.append(completion)
        if anonymousCookieInFlight {
            return
        }
        anonymousCookieInFlight = true
        fetchAnonymousCookie { [weak self] value in
            guard let self = self else {
                return
            }
            self.anonymousCookieInFlight = false
            if !value.isEmpty {
                self.cookie = value
            }
            let completions = self.anonymousCookieCompletions
            self.anonymousCookieCompletions = []
            for item in completions {
                var headers = self.baseHeaders
                if !self.cookie.isEmpty {
                    headers["Cookie"] = self.cookie
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
        loadRoomDetail(roomId: trimmed) { result in
            switch result {
            case .success(let room):
                completion(.success(room))
            case .failure:
                // UI path: a transient failure must not blank the
                // card — return the room as offline.
                completion(.success(LiveRoom(roomId: trimmed, platform: .douyin, isLive: false, link: LivePlatform.douyin.roomLink(roomId: trimmed))))
            }
        }
    }

    /// Strict room load: throws when no parseable playback metadata
    /// is available (resolve must see the transient error, never a
    /// disguised "offline").
    private func loadRoomDetail(roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        let trimmed = roomId.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            completion(.failure(LiveError.invalidRoomId))
            return
        }
        resolveDetail(roomId: trimmed, completion: completion)
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
}

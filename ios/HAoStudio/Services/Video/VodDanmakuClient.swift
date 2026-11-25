// HAo Studio 2.0 — VOD danmaku client (S3 leg B).
//
// Swift port of the Flutter `vod_danmaku_client.dart`
// (standalone-app-merge23). Two-hop FongMi-compatible fetch
// against the danmu-api service. Anonymous GETs by default —
// no login. When the user configures an access token
// (VodDanmakuApiConfig, b36 item 11), it is sent as the first
// path segment of the hop-1 URL, the only auth position the
// danmu-api protocol defines. Never a header, never a query
// key. Read-only: the app never sends danmaku.
//
//   Hop 1  GET /api/v2/fongmi/danmaku?name=<title>&episode=<ep>
//          -> JSON array of candidates, best match first
//          (server-side score). Only the top-1 passing the
//          client-side dual check is ever used; candidates are
//          never merged.
//   Hop 2  GET <candidate.url> with format=xml rewritten to
//          format=json -> {"count": N, "comments": [{cid, p, m, t}]}
//          where `t` is the media-time axis (seconds) and `m` the
//          text.
//
// Rules (Flutter audit b28-audit-danmaku.md §2-§3, as fixed in
// build 29):
// - Dual validation of a candidate: title gate (the normalised
//   candidate name must contain the normalised query title —
//   compared on a match key with whitespace and Chinese numerals
//   folded, so `庆余年 第2季` matches `庆余年第二季(2024)…` and
//   vice versa) + year gate (a year in the candidate name that
//   disagrees with the detail's year rejects it; no year in the
//   name passes). The season numeral is part of the key, never
//   stripped: an S1 candidate must NOT match an S2 query.
// - Every failure mode is silent: empty result, 404, timeout,
//   network error -> [], never an exception to the player, never
//   a prompt. But silence is not surrender: a 429 or 5xx is
//   retried with backoff (Retry-After honoured, capped at 30 s),
//   and an empty hop-1 200 is retried once — the audit saw a
//   cold fetch occasionally return empty once, and "no danmaku"
//   is never cached as a permanent answer.
// - Per-hop budgets: hop 1 gets 60 s, hop 2 gets 30 s. The audit
//   measured hop 1 cold start at 24.6 s — the old single 10 s
//   budget killed every cold start outright.
// - The full timeline loads by default; `maxTimelineItems`
//   (uniform sampling across the time axis, never first-N) is
//   only the escape hatch if real-device frame rate proves full
//   load too heavy — it defaults to off.
//
// The protocol only passes a PlayEpisode, which has no title —
// so the client is constructed per detail with the title + year
// (C leg constructs it). Completion handlers only, no
// async/await, no `any` (Swift 5.0).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Types

/// One candidate episode returned by hop 1.
struct VodDanmakuCandidate: Equatable {
    /// Human-readable label, e.g. `狂飙(2023)from iqiyi - 狂飙第1集 …`.
    let name: String
    /// Hop-2 address (arrives with `format=xml`; rewritten to json).
    let url: String
}

/// One comment from hop 2 (`{cid, p, m, t}`).
struct VodDanmakuComment: Equatable {
    /// Media time in seconds (`t`; also the first field of `p`).
    let time: Double
    /// Text (`m`).
    let text: String
    /// RGB colour from the 3rd field of `p` (e.g. 16777215 = white).
    let colorRgb: Int?
    /// `p` type 1 = scroll, 4 = top-fixed, 5 = bottom-fixed.
    /// Swift's DanmakuItem has no bottom case, so bottom maps to
    /// scroll on the way out (see `toDanmakuItem`).
    enum Kind {
        case scroll
        case top
        case bottom
    }
    let kind: Kind

    func toDanmakuItem() -> DanmakuItem {
        DanmakuItem(
            text: text,
            timeSeconds: time,
            colorHex: colorRgb.map { String(format: "%06x", $0) } ?? "",
            isTop: kind == .top
        )
    }
}

/// Raw HTTP result handed to the client by the fetcher.
/// `statusCode == 0` means a transport failure (refused / DNS /
/// timeout). `body` is nil for any non-2xx response.
struct VodDanmakuHTTPResult {
    let body: String?
    let statusCode: Int
    let retryAfterSeconds: Double?
}

/// Raw body fetcher (test seam). Production uses the shared
/// URLSession.
typealias VodDanmakuFetcher = (URL, TimeInterval, @escaping (VodDanmakuHTTPResult) -> Void) -> Void

// MARK: - Parsers (pure, static — unit-tested without network)

enum VodDanmakuParsers {
    /// Parse hop-1's JSON array into candidates. Non-list /
    /// malformed entries are dropped, never thrown.
    static func parseCandidates(_ decoded: Any?) -> [VodDanmakuCandidate] {
        guard let list = decoded as? [Any] else { return [] }
        var out: [VodDanmakuCandidate] = []
        for entry in list {
            guard let map = entry as? [String: Any] else { continue }
            let name = VideoJSON.asString(map["name"])
            let url = VideoJSON.asString(map["url"])
            if !name.isEmpty && !url.isEmpty {
                out.append(VodDanmakuCandidate(name: name, url: url))
            }
        }
        return out
    }

    /// Year embedded in a candidate name (`狂飙(2023)…`), or nil.
    static func candidateYear(_ candidateName: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: "(19|20)\\d{2}", options: []),
              let m = re.firstMatch(in: candidateName, options: [], range: NSRange(candidateName.startIndex..., in: candidateName)),
              let r = Range(m.range, in: candidateName) else { return nil }
        return Int(candidateName[r])
    }

    /// Match key for the title gate: `videoNormTitle`, then all
    /// whitespace folded out and Chinese numerals folded to Arabic
    /// digits — so `庆余年 第2季`, `庆余年第二季` and `庆余年 第二季`
    /// all key the same, while the season number itself is
    /// preserved (an S1 key never contains an S2 key). Applied to
    /// both sides, so a conversion can never match a title against
    /// itself only.
    static func matchKey(_ s: String) -> String {
        let norm = videoNormTitle(s)
        let noSpace = norm.components(separatedBy: .whitespaces).joined()
        return foldChineseNumerals(noSpace)
    }

    private static let cnDigits: [Character: Int] = [
        "零": 0, "一": 1, "二": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]

    /// Fold runs of Chinese numerals (`二`, `十二`, `二十一`,
    /// `一百零三`) to Arabic digits. An ordinal 第 before a numeral
    /// run is dropped, so 第二季 and 第2季 fold to the same
    /// canonical "2季". Non-numeral characters pass through
    /// untouched. A run that cannot be parsed falls back to
    /// digit-per-character, which still keeps both sides equal.
    static func foldChineseNumerals(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            // Ordinal 第 before a numeral run: skip it, the run
            // itself is folded by the branch below.
            if ch == "第", i + 1 < chars.count,
               cnDigits[chars[i + 1]] != nil || chars[i + 1] == "十" || chars[i + 1] == "百" || chars[i + 1] == "千" || chars[i + 1].isNumber {
                i += 1
                continue
            }
            if cnDigits[ch] == nil && ch != "十" && ch != "百" && ch != "千" {
                out.append(ch)
                i += 1
                continue
            }
            var j = i
            while j < chars.count && (cnDigits[chars[j]] != nil || chars[j] == "十" || chars[j] == "百" || chars[j] == "千") {
                j += 1
            }
            out.append(String(parseChineseNumeral(String(chars[i..<j]))))
            i = j
        }
        return out
    }

    /// Standard positional parse: 十=10, 百=100, 千=1000 as units.
    static func parseChineseNumeral(_ run: String) -> Int {
        var total = 0
        var current = 0
        var seenAny = false
        for ch in run {
            if let digit = cnDigits[ch] {
                current = digit
                seenAny = true
                continue
            }
            let unit: Int
            switch ch {
            case "十": unit = 10
            case "百": unit = 100
            default: unit = 1000
            }
            total += (current == 0 ? 1 : current) * unit
            current = 0
            seenAny = true
        }
        if !seenAny { return 0 }
        return total + current
    }

    /// Dual validation: title gate + year gate.
    ///
    /// - Title gate: the match key of the normalised query title
    ///   must appear in the match key of the normalised candidate
    ///   name.
    /// - Year gate: when the candidate name carries a year and
    ///   `year` (VideoMeta.year) is known, a mismatch rejects the
    ///   candidate. A candidate without a year passes.
    static func candidatePasses(_ candidate: VodDanmakuCandidate, queryTitle: String, year: String = "") -> Bool {
        let queryNorm = matchKey(queryTitle)
        if queryNorm.isEmpty { return false }
        let candidateNorm = matchKey(candidate.name)
        if !candidateNorm.contains(queryNorm) { return false }
        if let candidateYear = candidateYear(candidate.name), !year.isEmpty,
           let wantYear = Int(year), candidateYear != wantYear {
            return false
        }
        return true
    }

    /// First candidate at or after `startIndex` that passes the
    /// dual validation, or nil. The caller keeps the full list so
    /// "换弹幕源" can scan forward from the current index.
    static func selectCandidate(_ candidates: [VodDanmakuCandidate], queryTitle: String, year: String = "", startIndex: Int = 0) -> VodDanmakuCandidate? {
        var i = startIndex
        while i < candidates.count {
            if candidatePasses(candidates[i], queryTitle: queryTitle, year: year) {
                return candidates[i]
            }
            i += 1
        }
        return nil
    }

    /// Parse hop-2's JSON body (`{"count": N, "comments": [...]}`)
    /// into comments. Entries with missing/illegal time or empty
    /// text are dropped. An unparseable body returns [] instead of
    /// throwing into the caller.
    static func parseCommentsJson(_ body: String) -> [VodDanmakuComment] {
        guard let data = body.data(using: .utf8),
              let decoded = VideoJSON.decode(data) as? [String: Any],
              let raw = decoded["comments"] as? [Any] else { return [] }
        var out: [VodDanmakuComment] = []
        for entry in raw {
            guard let map = entry as? [String: Any] else { continue }
            let text = VideoJSON.asString(map["m"])
            if text.isEmpty { continue }
            var time: Double?
            if let t = map["t"] as? NSNumber {
                time = t.doubleValue
            } else if let t = map["t"] as? String {
                time = Double(t)
            }
            if time == nil {
                time = timeFromP(VideoJSON.asString(map["p"]))
            }
            guard let time = time, !time.isNaN, time >= 0 else { continue }
            var kind: VodDanmakuComment.Kind = .scroll
            var colorRgb: Int?
            let p = VideoJSON.asString(map["p"])
            if !p.isEmpty {
                let parts = p.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count > 1, let typeRaw = Int(parts[1]) {
                    switch typeRaw {
                    case 4: kind = .top
                    case 5: kind = .bottom
                    default: kind = .scroll
                    }
                }
                if parts.count > 2, let rgb = Int(parts[2]), rgb >= 0 && rgb <= 0xFFFFFF {
                    colorRgb = rgb
                }
            }
            out.append(VodDanmakuComment(time: time, text: text, colorRgb: colorRgb, kind: kind))
        }
        return out
    }

    private static func timeFromP(_ p: String) -> Double? {
        if p.isEmpty { return nil }
        let first = p.split(separator: ",", omittingEmptySubsequences: false).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return Double(first)
    }

    /// Rewrite a hop-2 URL to JSON: `format=xml` -> `format=json`
    /// (added when absent). Relative URLs resolve against
    /// `baseUrl`.
    static func rewriteCommentUrlToJson(_ rawUrl: String, baseUrl: String) -> URL? {
        let trimmed = rawUrl.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        var url: URL?
        if let parsed = URL(string: trimmed), parsed.scheme != nil {
            url = parsed
        } else if let base = URL(string: baseUrl) {
            url = URL(string: trimmed, relativeTo: base)?.absoluteURL
        }
        guard let url = url, var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        var items = components.queryItems ?? []
        // Replace format in place (keeping its position); only
        // append when absent. Rebuilding the query with format
        // moved to the end changes the URL string for no reason.
        var replaced = false
        items = items.compactMap { item in
            guard item.name == "format" else { return item }
            if replaced { return nil }
            replaced = true
            return URLQueryItem(name: "format", value: "json")
        }
        if !replaced {
            items.append(URLQueryItem(name: "format", value: "json"))
        }
        components.queryItems = items
        return components.url
    }

    /// Uniformly sample `items` down to `maxCount`, evenly spaced
    /// across the whole timeline — never just the first N, which
    /// would front-load the episode and starve the rest.
    static func uniformSampleTimeline(_ items: [DanmakuItem], maxCount: Int) -> [DanmakuItem] {
        if maxCount <= 0 { return [] }
        if items.count <= maxCount { return items }
        var out: [DanmakuItem] = []
        for i in 0..<maxCount {
            out.append(items[(i * items.count / maxCount)])
        }
        return out
    }
}

// MARK: - API config (b36 item 11)

/// VOD danmaku service address + access token (b36 item 11).
///
/// Stored in UserDefaults under `hao_vod_danmaku_api_url` /
/// `hao_vod_danmaku_api_token`, read directly by the settings
/// page and by `VideoPlayerView.open` — deliberately NOT part
/// of `VodSettingsState` (that is the in-player sheet's
/// per-playback snapshot; the API address is global service
/// configuration, and stuffing it in there would make every
/// sheet change re-persist it).
///
/// Empty semantics (fixed, never ambiguous):
/// - empty address = the built-in official host
///   (`VodDanmakuClient.defaultBaseUrl`). The default is never
///   written to UserDefaults; clearing the address returns to
///   the official service. There is no "danmaku service off"
///   state here — the `hao_vod_danmaku` switch owns that.
/// - empty token = no prefix, anonymous fetch.
/// - the token is sent as the first path segment of the hop-1
///   URL only (`<base>/<TOKEN>/api/v2/fongmi/danmaku?...`);
///   hop 2 reuses the URL the server returned, verbatim except
///   for `format=json`, and is never re-prefixed.
///
/// Q2 (verified 2026-11-24 against the upstream danmu_api
/// `worker.js` on main): the server takes `url.pathname`
/// (WHATWG URL keeps `%2F` / `%3F` / `%23` encoded), splits
/// on `/`, and compares the first segment against its TOKEN
/// with a plain `===` — no `decodeURIComponent` anywhere near
/// the token check (the file's only decode call is for a local
/// danmu resource key). A token containing `/`, `?` or `#`
/// therefore can never authenticate, so the settings page
/// refuses to save one instead of percent-encoding it.
struct VodDanmakuApiConfig: Equatable {
    static let apiUrlKey = "hao_vod_danmaku_api_url"
    static let apiTokenKey = "hao_vod_danmaku_api_token"

    var apiUrl: String = ""
    var apiToken: String = ""

    static func load(defaults: UserDefaults = .standard) -> VodDanmakuApiConfig {
        VodDanmakuApiConfig(
            apiUrl: defaults.string(forKey: apiUrlKey) ?? "",
            apiToken: defaults.string(forKey: apiTokenKey) ?? ""
        )
    }

    /// Normalized copy: surrounding whitespace trimmed, trailing
    /// slashes stripped from the address. Persist this, never
    /// the raw draft.
    func normalized() -> VodDanmakuApiConfig {
        var out = VodDanmakuApiConfig(
            apiUrl: apiUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            apiToken: apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        while out.apiUrl.hasSuffix("/") { out.apiUrl.removeLast() }
        return out
    }

    func save(defaults: UserDefaults = .standard) {
        let value = normalized()
        defaults.set(value.apiUrl, forKey: Self.apiUrlKey)
        defaults.set(value.apiToken, forKey: Self.apiTokenKey)
    }

    /// The base the client actually fetches from: the configured
    /// address, or the built-in official host when the address is
    /// empty. The default is NEVER written to UserDefaults.
    var effectiveBaseUrl: String {
        let trimmed = normalized().apiUrl
        return trimmed.isEmpty ? VodDanmakuClient.defaultBaseUrl : trimmed
    }

    /// True when the user configured an address of their own.
    /// A token alone (on the official host) does not count: the
    /// settings entry subtitle reads "官方地址" in that case.
    var isCustomAddress: Bool { !normalized().apiUrl.isEmpty }

    /// Host of the configured address, for the settings entry
    /// subtitle. Nil when no custom address is set. The token
    /// never appears on the settings list page.
    var displayHost: String? {
        let trimmed = normalized().apiUrl
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)?.host
    }

    /// Hop-1 URL for `title` + `episode`, the single assembly
    /// point (spec §3.5). Empty `baseUrl` falls back to the
    /// built-in default; a reverse-proxy path on the base
    /// (`https://example.com/danmu`) is kept and the API path
    /// appended after it — the old `components.path = ...`
    /// assignment dropped it. The token, when set, goes between
    /// the base and `/api/v2/...`, percent-encoded so a stray
    /// `/` / `?` / `#` can never break the URL structure
    /// (the settings page refuses to save such a token at all;
    /// this is defence in depth for any other writer).
    /// Returns nil when the base is not a usable http(s) URL.
    static func hop1Url(baseUrl: String, token: String, title: String, episode: String) -> URL? {
        let base = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped = base.isEmpty ? VodDanmakuClient.defaultBaseUrl : base
        while stripped.hasSuffix("/") { stripped.removeLast() }
        guard var components = URLComponents(string: stripped),
              components.scheme == "http" || components.scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenPrefix = cleanToken.isEmpty ? "" : "/" + percentEncodeToken(cleanToken)
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + tokenPrefix + "/api/v2/fongmi/danmaku"
        components.queryItems = [
            URLQueryItem(name: "name", value: title),
            URLQueryItem(name: "episode", value: episode),
        ]
        return components.url
    }

    func hop1Url(title: String, episode: String) -> URL? {
        Self.hop1Url(baseUrl: apiUrl, token: apiToken, title: title, episode: episode)
    }

    /// Percent-encode one token path segment: only the RFC 3986
    /// unreserved characters pass through, so `/`, `?`, `#`,
    /// `%` and whitespace all become `%XX`.
    static func percentEncodeToken(_ token: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return token.addingPercentEncoding(withAllowedCharacters: allowed) ?? token
    }

    /// Local format check only — never a network probe (a cold
    /// hop-1 can take ~25 s; reachability proves nothing about
    /// "can fetch danmaku" anyway). Returns the inline error
    /// message, or nil when the draft may be saved.
    /// - All-empty drafts save as empty strings (= default),
    ///   never an error.
    /// - A non-empty address must parse as an http(s) URL with
    ///   a host.
    /// - A token containing `/`, `?` or `#` is refused (see the
    ///   Q2 note on this type): it could never authenticate.
    static func validationError(apiUrl: String, apiToken: String) -> String? {
        let url = apiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.contains("/") || token.contains("?") || token.contains("#") {
            return "密钥不能含 / ? #"
        }
        guard !url.isEmpty else { return nil }
        guard let parsed = URL(string: url),
              parsed.scheme == "http" || parsed.scheme == "https",
              let host = parsed.host, !host.isEmpty else {
            return "地址格式不对，要以 http:// 或 https:// 开头"
        }
        return nil
    }
}

// MARK: - Client

/// VOD danmaku provider (protocol conformance in
/// VideoServiceContracts.swift). Constructed per detail with the
/// title + year — the protocol only passes a PlayEpisode, which
/// has no title.
final class VodDanmakuClient: VodDanmakuProvider {
    /// danmu-api host. Public API; anonymous by default, with
    /// an optional token prefix via `VodDanmakuApiConfig`.
    static let defaultBaseUrl = "https://danmu-api-production-60e143e3.up.railway.app"

    private let title: String
    private let year: String
    private let baseUrl: String
    /// Access token for the hop-1 URL path prefix (empty =
    /// anonymous). Set from `VodDanmakuApiConfig` by the player;
    /// never a header, never a query key.
    private let token: String
    private let fetcher: VodDanmakuFetcher

    /// Hop-1 budget (60 s): the server cold-starts in ~25 s, so a
    /// 10 s budget killed every cold start outright.
    let hop1Timeout: TimeInterval
    /// Hop-2 budget (30 s): the comment payload is multi-MB.
    let hop2Timeout: TimeInterval
    /// Retries after a transient failure (429 / 5xx), on top of the
    /// first attempt. Total attempts = 1 + maxRetries.
    let maxRetries: Int
    /// Base backoff between retries: attempt n waits
    /// retryBaseDelay * 2^n — unless the server sent Retry-After,
    /// which is honoured instead (capped at 30 s).
    let retryBaseDelay: TimeInterval
    /// Delay before the single re-try of an empty hop-1 200.
    let emptyRetryDelay: TimeInterval
    /// Escape hatch: when set, timelines longer than this are
    /// uniformly sampled. Nil = full load.
    let maxTimelineItems: Int?

    private let workQueue = DispatchQueue(label: "com.haostudio.voddanmaku", qos: .utility)

    init(title: String, year: String = "", baseUrl: String = VodDanmakuClient.defaultBaseUrl, token: String = "", fetcher: VodDanmakuFetcher? = nil, hop1Timeout: TimeInterval = 60, hop2Timeout: TimeInterval = 30, maxRetries: Int = 2, retryBaseDelay: TimeInterval = 1, emptyRetryDelay: TimeInterval = 2, maxTimelineItems: Int? = nil) {
        self.title = title
        self.year = year
        self.baseUrl = baseUrl
        self.token = token
        self.fetcher = fetcher ?? VodDanmakuClient.defaultFetcher
        self.hop1Timeout = hop1Timeout
        self.hop2Timeout = hop2Timeout
        self.maxRetries = maxRetries
        self.retryBaseDelay = retryBaseDelay
        self.emptyRetryDelay = emptyRetryDelay
        self.maxTimelineItems = maxTimelineItems
    }

    /// Production fetcher over the shared URLSession. A 429 / 5xx
    /// rides in the result (with Retry-After when present) so the
    /// caller can retry; any other failure is a transport failure
    /// (status 0) and stays silent.
    static func defaultFetcher(url: URL, timeout: TimeInterval, completion: @escaping (VodDanmakuHTTPResult) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(VodDanmakuHTTPResult(body: nil, statusCode: 0, retryAfterSeconds: nil))
                return
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            var retryAfter: Double?
            if status == 429, let raw = http?.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
               let seconds = Double(raw), seconds >= 0 {
                retryAfter = seconds
            }
            guard status >= 200 && status < 300,
                  let data = data,
                  let body = String(data: data, encoding: .utf8) else {
                completion(VodDanmakuHTTPResult(body: nil, statusCode: status, retryAfterSeconds: retryAfter))
                return
            }
            completion(VodDanmakuHTTPResult(body: body, statusCode: status, retryAfterSeconds: retryAfter))
        }
        task.resume()
    }

    // MARK: VodDanmakuProvider

    func fetchDanmaku(for episode: PlayEpisode, completion: @escaping ([DanmakuItem], Bool) -> Void) {
        fetchCandidates(title: title, episode: episode.name) { [weak self] candidates, transportFailed in
            guard let self = self else {
                completion([], true)
                return
            }
            guard let candidates = candidates,
                  let candidate = VodDanmakuParsers.selectCandidate(candidates, queryTitle: self.title, year: self.year) else {
                // No candidate: either the transport failed (flag)
                // or this title simply has no danmaku entry.
                completion([], transportFailed)
                return
            }
            self.fetchComments(for: candidate) { comments, commentsFailed in
                guard let comments = comments else {
                    completion([], commentsFailed)
                    return
                }
                let items = comments.map { $0.toDanmakuItem() }.sorted { $0.timeSeconds < $1.timeSeconds }
                if let cap = self.maxTimelineItems, items.count > cap {
                    completion(VodDanmakuParsers.uniformSampleTimeline(items, maxCount: cap), false)
                    return
                }
                completion(items, false)
            }
        }
    }

    // MARK: Hop 1 — candidates

    /// Candidate list for `title` + `episode` (episode name as
    /// shown by the CMS, e.g. `第1集`). Nil on any failure / empty.
    /// An empty 200 is retried once after `emptyRetryDelay`: a cold
    /// fetch occasionally returns empty once, and "no danmaku" is
    /// never a permanent answer. The Bool is `transportFailed`:
    /// true only when the request itself failed (no response /
    /// no body) — an empty list after the retry is "no entry",
    /// not a failure (sweep-4 P2-9).
    func fetchCandidates(title: String, episode: String, completion: @escaping ([VodDanmakuCandidate]?, Bool) -> Void) {
        // Single assembly point: base path (a reverse-proxy
        // prefix survives) + optional token prefix + API path.
        // Hop 2 is untouched — it reuses the server's URL.
        guard let url = VodDanmakuApiConfig.hop1Url(baseUrl: baseUrl, token: token, title: title, episode: episode) else {
            completion(nil, true)
            return
        }
        var attempt = 0
        func step() {
            fetchWithRetry(url: url, timeout: hop1Timeout) { result in
                guard let result = result else {
                    completion(nil, true)
                    return
                }
                var list: [VodDanmakuCandidate]?
                if let body = result.body, !body.isEmpty,
                   let data = body.data(using: .utf8),
                   let decoded = VideoJSON.decode(data) {
                    list = VodDanmakuParsers.parseCandidates(decoded)
                } else if result.body == nil {
                    // Transport already failed (and already retried
                    // what was retryable) — return immediately
                    // without waiting.
                    completion(nil, true)
                    return
                }
                if let list = list, !list.isEmpty {
                    completion(list, false)
                    return
                }
                // Empty result (empty body or `[]`): one delayed
                // re-try for the cold-fetch glitch.
                if attempt == 0 {
                    attempt += 1
                    self.workQueue.asyncAfter(deadline: .now() + self.emptyRetryDelay) {
                        step()
                    }
                    return
                }
                completion(nil, false)
            }
        }
        step()
    }

    // MARK: Hop 2 — comments

    /// All comments for `candidate`. Nil on any failure / empty.
    /// The Bool is `transportFailed`, same meaning as hop 1: an
    /// empty-but-answered body is "no comments", not a failure.
    func fetchComments(for candidate: VodDanmakuCandidate, completion: @escaping ([VodDanmakuComment]?, Bool) -> Void) {
        guard let url = VodDanmakuParsers.rewriteCommentUrlToJson(candidate.url, baseUrl: baseUrl) else {
            completion(nil, true)
            return
        }
        fetchWithRetry(url: url, timeout: hop2Timeout) { result in
            guard let result = result, let body = result.body, !body.isEmpty else {
                completion(nil, true)
                return
            }
            let comments = VodDanmakuParsers.parseCommentsJson(body)
            completion(comments.isEmpty ? nil : comments, false)
        }
    }

    // MARK: Retry wrapper

    /// One attempt plus `maxRetries` retries on transient failures
    /// (429 / 5xx). Anything else — timeout, 404, DNS, unparseable
    /// — returns nil immediately: still silent, still no danmaku,
    /// but a rate-limit no longer kills the episode outright.
    private func fetchWithRetry(url: URL, timeout: TimeInterval, completion: @escaping (VodDanmakuHTTPResult?) -> Void) {
        var attempt = 0
        func step() {
            fetcher(url, timeout) { result in
                if result.statusCode == 429 || result.statusCode >= 500 {
                    if attempt >= self.maxRetries {
                        completion(nil)
                        return
                    }
                    var delay = self.retryBaseDelay * pow(2.0, Double(attempt))
                    if let retryAfter = result.retryAfterSeconds, retryAfter > 0 {
                        delay = min(retryAfter, 30)
                    }
                    attempt += 1
                    self.workQueue.asyncAfter(deadline: .now() + delay) {
                        step()
                    }
                    return
                }
                if result.statusCode == 0 {
                    completion(nil)
                    return
                }
                completion(result)
            }
        }
        step()
    }
}

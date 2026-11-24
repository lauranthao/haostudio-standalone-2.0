// HAo Studio 2.0 — CMS video client (S3 leg B).
//
// Swift port of the Flutter `cms_client.dart` + `cms_sources.dart`
// (standalone-app-merge23). Direct CMS requests, no server in the
// middle. All requests are GET with the direct-video user agent.
//
// Serial, fastest first: sources are tried one by one in speed
// order; the first usable answer wins. Search stops as soon as 40
// deduped items are collected or the overall budget (15 s page 1,
// 6 s later pages) is spent.
//
// Sources (13 defaults, revision 6 — 暴风 deleted 2026-11-23;
// 极速/光速/新狼/豪华/速播/速播备用 deleted 2026-11-24: their
// search APIs answer but their play-CDN hosts (*uus.com family)
// never connect, so no episode can stream; 量子 deleted
// 2026-11-24: search answers (total 93) but every play file 404s
// — the same death signature as 暴风, and it already shipped
// disabled; 芒果/母鸡 added 2026-11-24 — both verified PLAYABLE
// by the build-35真播放重验: m3u8 playlist + a real .ts segment
// fetched): counted from `cms_sources.dart` (`VideoSource(`
// occurrences = 18, ids 1,2,3,4,6,7,8,9,10,11,12,13,14,15,16,
// 17,18,19 — id 5 暴风 is gone). All 13 ship enabled; none ships
// disabled any more (量子 id 4 was the only disabled one, now
// deleted outright, see revision 6). This matches
// the README ("CMS 源 19→18", build 30) minus the build-35
// deletions/additions (18 − 7 + 2 = 13). One README-side naming
// quirk: the README says "新增电影天堂、素博两个 CMS 源"
// (build 29) but no source named 素博 exists anywhere in the
// Flutter code — the code has 速播资源 / 速播备用 (same pinyin,
// different characters). Count aligns (18); names align except
// that one README wording.
//
// Speed (P0-11): the shipped `sort` is the 2026-11-17 static
// measurement, kept only as the seed order. Real latencies are
// measured at runtime on every successful fetch (see
// CmsSourceSpeedStore) and the effective order re-sorts by them;
// `measureSources` probes every enabled source on demand for the
// settings page. Nothing here pretends a static sort is a live
// measurement.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

// MARK: - Shared JSON readers (used by every Services/Video file)

enum VideoJSON {
    static func asString(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    static func asInt(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    static func asIntOrNil(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func asDouble(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) ?? 0 }
        return 0
    }

    static func asList(_ value: Any?) -> [[String: Any]] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { $0 as? [String: Any] }
    }

    static func asMap(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func asStringList(_ value: Any?) -> [String] {
        guard let list = value as? [Any] else { return [] }
        return list.map { asString($0) }.filter { !$0.isEmpty }
    }

    /// Decode one JSON document. Top-level must be an object or an
    /// array (never a bare string/number — those are not JSON
    /// documents a client can use).
    static func decode(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [])
    }
}

// MARK: - Shared HTTP (URLSession; injectable for tests)

/// One JSON fetch: the decoded object, or nil on any failure
/// (transport, non-2xx, unparseable body). No exceptions escape.
typealias VideoJSONFetcher = (URL, TimeInterval, @escaping ([String: Any]?) -> Void) -> Void

/// One raw-body fetch: HTTP status + body text, or (nil, nil) on
/// any failure. Used by the Douban / danmaku clients.
typealias VideoTextFetcher = (URL, [String: String], TimeInterval, @escaping (Int?, String?) -> Void) -> Void

enum VideoHTTP {
    /// Default JSON fetcher over the shared URLSession.
    static func fetchJSON(url: URL, timeout: TimeInterval, completion: @escaping ([String: Any]?) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(CmsClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data = data,
                  let obj = VideoJSON.decode(data) as? [String: Any]
            else {
                completion(nil)
                return
            }
            completion(obj)
        }
        task.resume()
    }

    /// Default raw-text fetcher over the shared URLSession.
    static func fetchText(url: URL, headers: [String: String], timeout: TimeInterval, completion: @escaping (Int?, String?) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse else {
                completion(nil, nil)
                return
            }
            let body = data.flatMap { String(data: $0, encoding: .utf8) }
            completion(http.statusCode, body)
        }
        task.resume()
    }
}

// MARK: - Shared title helpers (ports of video_title_helpers.dart)

/// Adult type/title words — skipped in type map, home, daily, search.
let kDirectAdultWords = ["伦理", "福利", "成人", "情色", "三级", "写真", "美女", "激情", "性感"]

func isAdultVideo(type: String?, name: String?) -> Bool {
    let t = type ?? ""
    let n = name ?? ""
    if n.contains("里番") || t.contains("里番") { return true }
    return kDirectAdultWords.contains { w in t.contains(w) || n.contains(w) }
}

/// Force http:// → https:// (all upstream URLs must be https).
func videoToHttps(_ url: String) -> String {
    url.hasPrefix("http://") ? "https://" + url.dropFirst(7) : url
}

/// Strip HTML tags (CMS synopsis may contain HTML).
func stripHtmlTags(_ s: String?) -> String {
    guard let s = s, !s.isEmpty else { return "" }
    guard let regex = try? NSRegularExpression(pattern: "<[^>]*>", options: []) else { return s }
    let range = NSRange(s.startIndex..., in: s)
    return regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func videoRegex(_ pattern: String) -> NSRegularExpression? {
    try? NSRegularExpression(pattern: pattern, options: [])
}

/// Normalise a video title for matching/dedupe: lowercase, collapse
/// whitespace, strip up to 3 trailing parenthesised suffixes matching
/// a year / quality word, then up to 3 trailing bare quality words,
/// then trailing separators. Behaviour-identical to the Flutter port.
func videoNormTitle(_ s: String?) -> String {
    var n = (s ?? "").lowercased()
    if let ws = videoRegex("[\\s　]+") {
        let range = NSRange(n.startIndex..., in: n)
        n = ws.stringByReplacingMatches(in: n, options: [], range: range, withTemplate: " ")
    }
    n = n.trimmingCharacters(in: .whitespaces)
    let parenSuffix = "^(19|20)[0-9]{2}$|hd|高清|超清|蓝光|\\b4k\\b|国语|粤语|中字|正片|完整版|抢先版|未删减"
    for _ in 0..<3 {
        guard let re = videoRegex("[\\s\\-–—:：·]*[（(]([^）)]*)[）)]\\s*$"),
              let suffixRe = videoRegex(parenSuffix) else { break }
        let range = NSRange(n.startIndex..., in: n)
        guard let m = re.firstMatch(in: n, options: [], range: range),
              m.numberOfRanges > 1,
              let inner = Range(m.range(at: 1), in: n) else { break }
        let innerText = String(n[inner]).trimmingCharacters(in: .whitespaces)
        let innerRange = NSRange(innerText.startIndex..., in: innerText)
        guard suffixRe.firstMatch(in: innerText, options: [], range: innerRange) != nil else { break }
        let head = String(n[..<Range(m.range, in: n)!.lowerBound])
        guard let trimRe = videoRegex("[\\s\\-–—:：·]+$") else { break }
        let headRange = NSRange(head.startIndex..., in: head)
        n = trimRe.stringByReplacingMatches(in: head, options: [], range: headRange, withTemplate: "")
    }
    for _ in 0..<3 {
        guard let re = videoRegex("[\\s\\-–—:：·]*(hd|高清|超清|蓝光|4k|正片|完整版|抢先版|未删减|导演剪辑版)\\s*$") else { break }
        let range = NSRange(n.startIndex..., in: n)
        let n2 = re.stringByReplacingMatches(in: n, options: [], range: range, withTemplate: "")
        if n2 == n { break }
        n = n2
    }
    if let re = videoRegex("[\\s\\-–—:：·.]+$") {
        let range = NSRange(n.startIndex..., in: n)
        n = re.stringByReplacingMatches(in: n, options: [], range: range, withTemplate: "")
    }
    return n.trimmingCharacters(in: .whitespaces)
}

/// Split a query into a normalised title + trailing year (0 = none).
func videoQueryParts(_ q: String?) -> (qn: String, year: Int) {
    let s = (q ?? "").trimmingCharacters(in: .whitespaces)
    var year = 0
    if let re = videoRegex("(19|20)[0-9]{2}") {
        let range = NSRange(s.startIndex..., in: s)
        let matches = re.matches(in: s, options: [], range: range)
        if let last = matches.last, let r = Range(last.range, in: s) {
            year = Int(s[r]) ?? 0
        }
    }
    let qn: String
    if year != 0 {
        var stripped = s
        if let re = videoRegex("(19|20)[0-9]{2}") {
            let range = NSRange(stripped.startIndex..., in: stripped)
            stripped = re.stringByReplacingMatches(in: stripped, options: [], range: range, withTemplate: " ")
        }
        if let ws = videoRegex("[\\s　]+") {
            let range = NSRange(stripped.startIndex..., in: stripped)
            stripped = ws.stringByReplacingMatches(in: stripped, options: [], range: range, withTemplate: " ")
        }
        qn = videoNormTitle(stripped.trimmingCharacters(in: .whitespaces))
    } else {
        qn = videoNormTitle(s)
    }
    return (qn: qn, year: year)
}

/// Strip a trailing season suffix ("xxx第2季" / "Show Season 2" /
/// "S2") so title lookups use the base series title. Returns the
/// base title and whether anything was stripped. Search-only: never
/// invent season labels from title suffixes in UI.
func vodStripSeasonSuffix(_ title: String?) -> (base: String, stripped: Bool) {
    var base = (title ?? "").trimmingCharacters(in: .whitespaces)
    if base.isEmpty { return (base: base, stripped: false) }
    let cn = "[0-9０-９]{1,2}|[一二三四五六七八九十百千]+"
    let patterns = [
        "[\\s\\-–—:：·]*[\\(（]\\s*(?:第(?:\(cn))季|Season\\s+[0-9]{1,2}(?:\\s+Part\\s+[0-9]{1,2})?|S[0-9]{1,2})\\s*[\\)）]\\s*$",
        "第(?:\(cn))季\\s*$",
        "\\s*Season\\s+[0-9]{1,2}(?:\\s+Part\\s+[0-9]{1,2})?\\s*$",
        "\\s*S[0-9]{1,2}\\s*$",
    ]
    var stripped = false
    for _ in 0..<3 {
        if base.isEmpty { break }
        var changed = false
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(base.startIndex..., in: base)
            let nb = re.stringByReplacingMatches(in: base, options: [], range: range, withTemplate: "").trimmingCharacters(in: .whitespaces)
            if nb != base {
                base = nb
                changed = true
                stripped = true
                break
            }
        }
        if !changed { break }
    }
    if stripped {
        if let re = videoRegex("[\\s\\-–—:：·.,]+$") {
            let range = NSRange(base.startIndex..., in: base)
            base = re.stringByReplacingMatches(in: base, options: [], range: range, withTemplate: "").trimmingCharacters(in: .whitespaces)
        }
    }
    if base.isEmpty {
        return (base: (title ?? "").trimmingCharacters(in: .whitespaces), stripped: false)
    }
    return (base: base, stripped: stripped)
}

/// Home type ordering (first 12 fetched, rows sorted by count, top 10).
let kVideoTypePriority = [
    "连续剧", "电视剧", "电影", "综艺", "动漫", "纪录片",
    "动作片", "喜剧片", "爱情片", "科幻片", "恐怖片", "剧情片",
    "战争片", "国产剧", "韩剧", "欧美剧", "日剧", "动漫电影",
    "国产动漫", "日本动漫", "中国动漫", "短剧", "港剧", "台剧",
    "泰剧", "港澳剧", "台湾剧", "古装片", "历史片", "惊悚片",
    "家庭片", "犯罪片", "冒险片", "动画片",
]

/// Area aliases for by-type client-side filtering.
let kVideoAreaAlias: [String: [String]] = [
    "大陆": ["大陆", "中国大陆", "内地"],
    "香港": ["香港"],
    "台湾": ["台湾"],
    "美国": ["美国"],
    "韩国": ["韩国"],
    "日本": ["日本"],
    "英国": ["英国"],
]

let kKnownVideoAreas = ["大陆", "中国大陆", "内地", "香港", "台湾", "美国", "韩国", "日本", "英国"]

// MARK: - Default sources (revision 5)

extension CmsClient {
    /// Defaults revision for the merge in VideoSourceStore.
    /// 1 = the original 17 sources; 2 = +非凡主站, speed
    /// re-prioritised; 3 = 金鹰/非凡/非凡主站 apiUrl http→https;
    /// 4 = +电影天堂资源; 5 = −暴风资源 (deleted 2026-11-23: its
    /// API answers but its play files 404); 6 = −极速/光速/新狼/
    /// 豪华/速播/速播备用/量子资源, +芒果/母鸡资源 (build-35真播放
    /// 重验 2026-11-24: the 6 deleted sources' search APIs answer
    /// but their play-CDN hosts never connect, so nothing streams;
    /// 量子's play files 404; 芒果/母鸡 verified PLAYABLE: m3u8
    /// playlist + a real .ts segment fetched).
    static let sourcesRevision = 6

    /// UA for CMS video + Douban search-page fallback (must be
    /// verbatim — several upstreams key behaviour off it).
    static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

    /// The 13 default CMS sources, in shipped (sort) order.
    static let defaultSources: [VideoSource] = [
        VideoSource(id: 12, name: "金鹰资源", apiUrl: "https://jyzyapi.com/api.php/provide/vod", kind: "play", enabled: true, sort: 5),
        VideoSource(id: 13, name: "非凡资源", apiUrl: "https://ffzy5.tv/api.php/provide/vod", kind: "search", enabled: true, sort: 6),
        VideoSource(id: 18, name: "非凡主站", apiUrl: "https://cj.ffzyapi.com/api.php/provide/vod", kind: "search", enabled: true, sort: 7),
        VideoSource(id: 6, name: "魔都资源", apiUrl: "https://caiji.moduapi.cc/api.php/provide/vod", kind: "play", enabled: true, sort: 11),
        VideoSource(id: 17, name: "iKun资源", apiUrl: "https://ikunzyapi.com/api.php/provide/vod", kind: "play", enabled: true, sort: 12),
        VideoSource(id: 9, name: "虎牙资源", apiUrl: "https://www.huyaapi.com/api.php/provide/vod", kind: "play", enabled: true, sort: 14),
        VideoSource(id: 14, name: "厂长资源", apiUrl: "https://api.changzhang.tv/api.php/provide/vod/", kind: "play", enabled: true, sort: 16),
        VideoSource(id: 1, name: "红牛资源", apiUrl: "https://www.hongniuzy2.com/api.php/provide/vod/", kind: "play", enabled: true, sort: 18),
        VideoSource(id: 16, name: "如意资源", apiUrl: "https://cj.rycjapi.com/api.php/provide/vod", kind: "play", enabled: true, sort: 21),
        VideoSource(id: 11, name: "360资源", apiUrl: "https://360zy.com/api.php/provide/vod", kind: "play", enabled: true, sort: 22),
        VideoSource(id: 19, name: "电影天堂资源", apiUrl: "https://caiji.dyttzyapi.com/api.php/provide/vod", kind: "play", enabled: true, sort: 25),
        VideoSource(id: 20, name: "芒果资源", apiUrl: "https://caiji.mgzyapi.com/api.php/provide/vod", kind: "play", enabled: true, sort: 26),
        VideoSource(id: 21, name: "母鸡资源", apiUrl: "https://mujiziyuan00.com/api.php/provide/vod", kind: "play", enabled: true, sort: 27),
    ]
}

// MARK: - Source store (user-editable list, revision merge)

/// User-editable CMS source list, persisted under the same
/// collection name the Flutter side uses (`hao_sa_video`) so a
/// migrated user keeps their sources. Merge rules (port of
/// VideoSourcesStore._mergeDefaults):
/// - defaults missing from the persisted list (matched by apiUrl)
///   are appended;
/// - matched defaults get their `sort` refreshed; the user's
///   `enabled` toggle is never touched;
/// - a stored http:// URL whose default twin is now https:// is
///   upgraded in place (same id, sort and enabled);
/// - the merge runs once per revision: a source the user
///   deliberately deleted is never resurrected by a later load.
enum VideoSourceStore {
    static let collectionName = "hao_sa_video"
    static let revisionKey = "hao_sa_video_rev"

    /// Load the persisted list, merged with the current defaults.
    /// Defaults when absent or corrupt — never throws into the UI.
    static func load() -> [VideoSource] {
        let raw: [VideoSource] = LocalStore.loadCollection(named: collectionName, default: [])
        if raw.isEmpty {
            // The migrated file may hold a JSON *string* (the Hive
            // value was a string): try that shape too.
            if let data = try? Data(contentsOf: LocalStore.collectionURL(named: collectionName)),
               let wrapped = try? JSONDecoder().decode(String.self, from: data),
               let inner = wrapped.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([VideoSource].self, from: inner),
               !decoded.isEmpty {
                return mergeDefaults(decoded)
            }
            return CmsClient.defaultSources
        }
        return mergeDefaults(raw)
    }

    /// Enabled sources in effective (runtime-measured) order.
    static func enabledSources() -> [VideoSource] {
        let enabled = load().filter { $0.enabled }
        return CmsSourceSpeedStore.order(enabled)
    }

    static func save(_ sources: [VideoSource]) {
        LocalStore.saveCollection(named: collectionName, value: sources)
    }

    /// Restore the shipped defaults (also bumps the revision so the
    /// merge does not re-add anything the user deleted before the
    /// reset — the reset itself is the deliberate act).
    static func resetToDefaults() {
        save(CmsClient.defaultSources)
        UserDefaults.standard.set(CmsClient.sourcesRevision, forKey: revisionKey)
    }

    /// Delete guard: at least one source must remain.
    static func canDelete(sources: [VideoSource]) -> Bool {
        sources.count > 1
    }

    /// Pure merge (unit-tested): `seenRevision` is the revision the
    /// stored list was last merged at.
    static func mergeDefaults(_ stored: [VideoSource], seenRevision: Int = -1) -> [VideoSource] {
        let seen = seenRevision >= 0
            ? seenRevision
            : UserDefaults.standard.integer(forKey: revisionKey)
        if seen >= CmsClient.sourcesRevision { return stored }
        let storedUrls: Set<String> = Set(stored.flatMap { [$0.apiUrl, videoToHttps($0.apiUrl)] })
        var changed = false
        var merged: [VideoSource] = stored.map { s in
            guard let def = CmsClient.defaultSources.first(where: { $0.apiUrl == s.apiUrl || $0.apiUrl == videoToHttps(s.apiUrl) }) else {
                return s
            }
            if def.apiUrl != s.apiUrl {
                changed = true
                return VideoSource(id: s.id, name: s.name, apiUrl: def.apiUrl, kind: s.kind, enabled: s.enabled, sort: s.sort)
            }
            if def.sort != s.sort {
                changed = true
                return VideoSource(id: s.id, name: s.name, apiUrl: s.apiUrl, kind: s.kind, enabled: s.enabled, sort: def.sort)
            }
            return s
        }
        for def in CmsClient.defaultSources where !storedUrls.contains(def.apiUrl) {
            merged.append(def)
            changed = true
        }
        if changed {
            // Bump the revision ONLY after the merged list lands.
            save(merged)
            UserDefaults.standard.set(CmsClient.sourcesRevision, forKey: revisionKey)
        } else {
            UserDefaults.standard.set(CmsClient.sourcesRevision, forKey: revisionKey)
        }
        return merged
    }
}

// MARK: - Runtime source speeds (P0-11)

/// Measured per-source latency (exponential moving average, ms),
/// persisted in the `cms_source_speed` collection. The shipped
/// `sort` is only the seed: a source with no measurement yet is
/// ordered by `sort * 100` ms nominal, so the initial order is the
/// shipped one and real measurements take over as they arrive.
enum CmsSourceSpeedStore {
    static let collectionName = "cms_source_speed"

    private static var memory: [String: Double] = {
        LocalStore.loadCollection(named: collectionName, default: [:])
    }()

    static func record(apiUrl: String, milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        let old = memory[apiUrl]
        let next = old == nil ? milliseconds : old! * 0.7 + milliseconds * 0.3
        memory[apiUrl] = next
        LocalStore.saveCollection(named: collectionName, value: memory)
    }

    static func latency(apiUrl: String) -> Double? {
        memory[apiUrl]
    }

    /// Effective order: measured latency when known, else the
    /// shipped-sort seed (`sort * 100` ms nominal).
    static func order(_ sources: [VideoSource]) -> [VideoSource] {
        sources.sorted { a, b in
            let ma = memory[a.apiUrl] ?? Double(a.sort) * 100
            let mb = memory[b.apiUrl] ?? Double(b.sort) * 100
            if ma != mb { return ma < mb }
            return a.sort < b.sort
        }
    }
}

// MARK: - CMS value types

/// One entry of the type map: the (first, in source-priority
/// order) source carrying a type name, plus its children and
/// same-name candidates from other sources.
struct CmsTypeEntry {
    let source: Int
    let sourceName: String
    let typeId: String
    let childTypeIds: [String]
    let candidates: [CmsTypeEntry]

    var isParent: Bool { !childTypeIds.isEmpty }
}

/// One alt-source hit: the same title on another source.
struct AltVideoSource: Equatable {
    let source: Int
    let vodId: String
}

/// By-type page result.
struct VideoByTypeResult {
    let name: String
    let page: Int
    let pagecount: Int
    let total: Int
    let items: [VideoItem]
}

/// Internal search row: the item plus the score the source
/// reported and the region the source reported. Swift's VideoItem
/// carries neither score nor area, so both live here only for
/// dedupe/rank/filter decisions.
struct CmsSearchRow {
    let item: VideoItem
    let score: Double
    let hits: Int
    let area: String
}

// MARK: - Client

/// CMS client. Holds the source list (defaults unless overridden)
/// and a 10-min in-memory type-map cache.
final class CmsClient: VideoPlayURLResolver {
    /// App-wide instance (default sources). HAoStudioApp installs
    /// it as the VOD driver's play-URL resolver; the gateway uses
    /// it for search / detail / home / by-type. Tests build their
    /// own instances with stub fetchers instead.
    static let shared = CmsClient()

    private let sources: [VideoSource]
    private let fetcher: VideoJSONFetcher

    init(sources: [VideoSource]? = nil, fetcher: VideoJSONFetcher? = nil) {
        self.sources = sources ?? VideoSourceStore.enabledSources()
        self.fetcher = fetcher ?? VideoHTTP.fetchJSON
    }

    var allSources: [VideoSource] { sources }

    func sourceById(_ id: Int) -> VideoSource? {
        sources.first { $0.id == id }
    }

    func sourceByName(_ name: String) -> VideoSource? {
        sources.first { $0.name == name }
    }

    // MARK: Pure parsers (no I/O — unit-tested)

    /// Map one raw CMS `list[]` row to a VideoItem + score.
    /// Swift's VideoItem.id IS the CMS vod_id string.
    static func parseVideoItem(source: VideoSource, row: [String: Any]) -> CmsSearchRow {
        let pic = VideoJSON.asString(row["vod_pic"])
        let yearRaw = VideoJSON.asString(row["vod_year"])
        let item = VideoItem(
            id: VideoJSON.asString(row["vod_id"]),
            title: VideoJSON.asString(row["vod_name"]),
            coverURL: pic.isEmpty ? nil : URL(string: videoToHttps(pic)),
            year: yearRaw.isEmpty ? nil : yearRaw,
            typeName: VideoJSON.asString(row["type_name"]),
            remarks: VideoJSON.asString(row["vod_remarks"]),
            sourceId: source.id
        )
        return CmsSearchRow(
            item: item,
            score: VideoJSON.asDouble(row["vod_score"]),
            hits: VideoJSON.asInt(row["vod_hits"]),
            area: VideoJSON.asString(row["vod_area"])
        )
    }

    /// Episode / line parsing — port of `directParsePlayUrl`.
    /// `vod_play_from`: line names joined by `$$$`.
    /// `vod_play_url`: per line, episodes joined by `#`; each
    /// episode `<name>$<url>` (split on the FIRST `$`). Empty name
    /// → '正片'. Line display name: the `play_from` name if it
    /// contains CJK, else '线路' + (index+1). m3u8 lines sort
    /// first, every other line is kept after them — never dropped.
    static func parsePlayLines(playUrl: String, playFrom: String) -> [PlayLine] {
        let names = playFrom.components(separatedBy: "$$$")
        let parts = playUrl.components(separatedBy: "$$$")
        var groups: [PlayLine] = []
        for (gi, part) in parts.enumerated() {
            var episodes: [PlayEpisode] = []
            for piece in part.components(separatedBy: "#") {
                guard let dollar = piece.firstIndex(of: "$") else { continue }
                let name = String(piece[..<dollar]).trimmingCharacters(in: .whitespaces)
                let urlString = String(piece[piece.index(after: dollar)...]).trimmingCharacters(in: .whitespaces)
                guard !urlString.isEmpty, let url = URL(string: videoToHttps(urlString)) else { continue }
                episodes.append(PlayEpisode(name: name.isEmpty ? "正片" : name, url: url, index: episodes.count))
            }
            if episodes.isEmpty { continue }
            let rawName = gi < names.count ? names[gi] : ""
            let hasCjk = rawName.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            groups.append(PlayLine(name: hasCjk ? rawName : "线路\(gi + 1)", episodes: episodes))
        }
        let m3 = groups.filter { g in g.episodes.contains { $0.url?.absoluteString.contains(".m3u8") == true } }
        let rest = groups.filter { g in !g.episodes.contains { $0.url?.absoluteString.contains(".m3u8") == true } }
        return m3 + rest
    }

    /// Fallback: synthesise one 直链 line when no lines parse but
    /// the content embeds a direct media URL (m3u8 first, then mp4,
    /// then flv). Only the FIRST direct link of the winning
    /// extension is taken.
    static func parsePlayLinesWithContentFallback(playUrl: String, playFrom: String, content: String) -> [PlayLine] {
        let lines = parsePlayLines(playUrl: playUrl, playFrom: playFrom)
        if !lines.isEmpty { return lines }
        for ext in ["m3u8", "mp4", "flv"] {
            let pattern = "[\\$]?(https?://[^\\s\"<>]+[.]\(ext)[^\\s\"<>]*)"
            guard let re = try? NSRegularExpression(pattern: pattern, options: []),
                  let m = re.firstMatch(in: content, options: [], range: NSRange(content.startIndex..., in: content)),
                  m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: content) else { continue }
            let found = String(content[r])
            guard let url = URL(string: videoToHttps(found)) else { continue }
            return [PlayLine(name: "直链", episodes: [PlayEpisode(name: "正片", url: url, index: 0)])]
        }
        return lines
    }

    /// Parse a CMS detail document (`?ac=videolist&ids=`) into a
    /// VideoDetail. Nil when there is no usable item/lines.
    static func parseCmsDetail(source: VideoSource, vodId: String, json: [String: Any]) -> VideoDetail? {
        let list = VideoJSON.asList(json["list"])
        guard let d = list.first else { return nil }
        let lines = parsePlayLinesWithContentFallback(
            playUrl: VideoJSON.asString(d["vod_play_url"]),
            playFrom: VideoJSON.asString(d["vod_play_from"]),
            content: VideoJSON.asString(d["vod_content"])
        )
        guard !lines.isEmpty else { return nil }
        let yearRaw = VideoJSON.asString(d["vod_year"])
        let item = VideoItem(
            id: vodId,
            title: VideoJSON.asString(d["vod_name"]),
            coverURL: {
                let pic = VideoJSON.asString(d["vod_pic"])
                return pic.isEmpty ? nil : URL(string: videoToHttps(pic))
            }(),
            year: yearRaw.isEmpty ? nil : yearRaw,
            typeName: VideoJSON.asString(d["type_name"]),
            remarks: VideoJSON.asString(d["vod_remarks"]),
            sourceId: source.id
        )
        let actorRaw = VideoJSON.asString(d["vod_actor"])
        let cast = actorRaw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let meta = VideoMeta(
            rating: {
                let s = VideoJSON.asString(d["vod_score"])
                return Double(s)
            }(),
            year: yearRaw.isEmpty ? nil : yearRaw,
            cast: cast,
            synopsis: {
                let c = stripHtmlTags(VideoJSON.asString(d["vod_content"]))
                return c.isEmpty ? nil : c
            }(),
            doubanId: nil
        )
        return VideoDetail(item: item, lines: lines, meta: meta)
    }

    /// Probe check: pass when the JSON has `list[]` or `class[]`
    /// (or `code == 0`).
    static func isProbeOk(_ json: [String: Any]) -> Bool {
        if VideoJSON.asInt(json["code"]) == 0 && json["code"] != nil { return true }
        if json["list"] is [Any] { return true }
        if json["class"] is [Any] { return true }
        return false
    }

    /// Dedupe + rank a raw merged search list (pure, tested).
    /// Dedupe key normTitle|year; an exact-title later duplicate
    /// replaces the kept item's source/id/pic; adult rows dropped;
    /// top 40. Rank: exact title match, starts-with, contains,
    /// then query-year match, then year desc. (Swift's VideoItem
    /// carries no score, so the Flutter score tie-break is not
    /// representable here — rank uses title/year only.)
    static func dedupeAndRankSearch(_ rows: [CmsSearchRow], query: String) -> [VideoItem] {
        var seen: [String: Int] = [:]
        var out: [VideoItem] = []
        let parts = videoQueryParts(query)
        for row in rows {
            let x = row.item
            if x.title.isEmpty { continue }
            if isAdultVideo(type: x.typeName, name: x.title) { continue }
            let key = "\(videoNormTitle(x.title))|\(x.year ?? "")"
            if let idx = seen[key] {
                // An exact-title later duplicate replaces the kept
                // item's source/id/pic; otherwise the first item
                // stands (score is not a VideoItem field, so a
                // higher-scored duplicate changes nothing visible).
                if videoNormTitle(x.title) == parts.qn && videoNormTitle(out[idx].title) != parts.qn {
                    out[idx] = x
                }
                continue
            }
            seen[key] = out.count
            out.append(x)
        }
        func rankScore(_ item: VideoItem) -> Int {
            let n = videoNormTitle(item.title)
            if n == parts.qn { return 0 }
            if n.hasPrefix(parts.qn) { return 1 }
            if n.contains(parts.qn) { return 2 }
            return 3
        }
        let sorted = out.enumerated().sorted { a, b in
            let d = rankScore(a.element) - rankScore(b.element)
            if d != 0 { return d < 0 }
            if parts.year != 0 {
                let ya = Int(a.element.year ?? "") ?? 0
                let yb = Int(b.element.year ?? "") ?? 0
                let da = (ya == parts.year ? 0 : 1) - (yb == parts.year ? 0 : 1)
                if da != 0 { return da < 0 }
            }
            let y = (Int(b.element.year ?? "") ?? 0) - (Int(a.element.year ?? "") ?? 0)
            if y != 0 { return y < 0 }
            return a.offset < b.offset
        }.map { $0.element }
        return Array(sorted.prefix(40))
    }

    // MARK: - Fetch helpers

    private func cmsURL(source: VideoSource, query: String) -> URL? {
        URL(string: source.apiUrl + query)
    }

    /// Fetch one CMS JSON document and record the source's runtime
    /// latency (P0-11). Nil on any failure.
    private func fetchJSON(source: VideoSource, query: String, timeout: TimeInterval, completion: @escaping ([String: Any]?) -> Void) {
        guard let url = cmsURL(source: source, query: query) else {
            completion(nil)
            return
        }
        let started = Date()
        fetcher(url, timeout) { json in
            if json != nil {
                CmsSourceSpeedStore.record(apiUrl: source.apiUrl, milliseconds: Date().timeIntervalSince(started) * 1000)
            }
            completion(json)
        }
    }

    // MARK: - Search

    /// Search one source (5 s default; 3 s in the serial fan-out).
    /// Completion carries the rows and whether the source answered
    /// at all (an empty list from a live source still counts).
    func searchOne(source: VideoSource, query: String, page: Int = 1, timeout: TimeInterval = 5, completion: @escaping ([CmsSearchRow], Bool) -> Void) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        fetchJSON(source: source, query: "?ac=videolist&wd=\(encoded)&pg=\(page)", timeout: timeout) { json in
            guard let json = json else {
                completion([], false)
                return
            }
            completion(VideoJSON.asList(json["list"]).map { CmsClient.parseVideoItem(source: source, row: $0) }, true)
        }
    }

    /// Serial search over enabled sources in speed order.
    /// Page 1: 3 s per source, 15 s overall budget, sequential
    /// fallback is the loop itself (serial by design). Later
    /// pages: 6 s overall, no fallback. Completion carries the
    /// ranked items and whether ANY source answered at all
    /// (false + empty = "video source unreachable").
    func search(query: String, page: Int = 1, completion: @escaping ([VideoItem], Bool) -> Void) {
        var rows: [CmsSearchRow] = []
        var anyOk = false
        let deadline = Date().addingTimeInterval(page == 1 ? 15 : 6)
        let perSource: TimeInterval = 3
        var index = 0
        func finish() {
            DispatchQueue.main.async {
                completion(CmsClient.dedupeAndRankSearch(rows, query: query), anyOk)
            }
        }
        func step() {
            if index >= sources.count || Date() > deadline {
                finish()
                return
            }
            if page == 1 && !rows.isEmpty {
                // Early exit: 40 deduped items is a full page.
                let ranked = CmsClient.dedupeAndRankSearch(rows, query: query)
                if ranked.count >= 40 {
                    finish()
                    return
                }
            }
            let source = sources[index]
            index += 1
            searchOne(source: source, query: query, page: page, timeout: perSource) { found, answered in
                if answered { anyOk = true }
                rows.append(contentsOf: found)
                step()
            }
        }
        step()
    }

    // MARK: - Detail

    /// Detail for one vod id (8 s timeout). Nil when absent or
    /// when no lines parse.
    func detail(sourceId: Int, vodId: String, completion: @escaping (VideoDetail?) -> Void) {
        guard let source = sourceById(sourceId) else {
            completion(nil)
            return
        }
        detail(source: source, vodId: vodId, completion: completion)
    }

    func detail(source: VideoSource, vodId: String, completion: @escaping (VideoDetail?) -> Void) {
        let encoded = vodId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? vodId
        fetchJSON(source: source, query: "?ac=videolist&ids=\(encoded)", timeout: 8) { json in
            guard let json = json else {
                completion(nil)
                return
            }
            completion(CmsClient.parseCmsDetail(source: source, vodId: vodId, json: json))
        }
    }

    // MARK: - Alt sources

    /// Same title on other sources (serial scan, priority order,
    /// exact normalised-title (+ year) match). Up to 3 matches,
    /// 15 s cap. Used for multi-source episode union / source
    /// switching on the detail page.
    func altSources(title: String, year: String, excludeSourceId: Int, completion: @escaping ([AltVideoSource]) -> Void) {
        let qn = videoNormTitle(title)
        var out: [AltVideoSource] = []
        let deadline = Date().addingTimeInterval(15)
        var index = 0
        func finish() {
            DispatchQueue.main.async { completion(out) }
        }
        func step() {
            if index >= sources.count || out.count >= 3 || Date() > deadline {
                finish()
                return
            }
            let source = sources[index]
            index += 1
            if source.id == excludeSourceId {
                step()
                return
            }
            let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
            fetchJSON(source: source, query: "?ac=videolist&wd=\(encoded)&pg=1", timeout: 5) { json in
                guard let json = json else {
                    step()
                    return
                }
                for raw in VideoJSON.asList(json["list"]) {
                    let name = VideoJSON.asString(raw["vod_name"])
                    let y = VideoJSON.asString(raw["vod_year"])
                    if videoNormTitle(name) == qn && (year.isEmpty || y.isEmpty || y == year) {
                        out.append(AltVideoSource(source: source.id, vodId: VideoJSON.asString(raw["vod_id"])))
                        break
                    }
                }
                step()
            }
        }
        step()
    }

    // MARK: - Type map

    private var typeMapCache: [String: CmsTypeEntry]?
    private var typeMapAt: Date?
    private var typeMapInFlight = false
    private var typeMapPending: [([String: CmsTypeEntry]) -> Void] = []
    private var typeMapTables: [(source: VideoSource, json: [String: Any])] = []
    private let typeMapLock = NSLock()

    /// `?ac=list` on every kind == "play" source; map type_name →
    /// entry. Two-stage deterministic build: fetch all class
    /// tables first, then build in source-priority order (the
    /// first source carrying a name wins; same-name entries from
    /// other sources become candidates). 10-min cache; a partial
    /// table (fewer than half the play sources answered) is NOT
    /// cached. Concurrent callers share one in-flight fetch.
    func typeMap(completion: @escaping ([String: CmsTypeEntry]) -> Void) {
        if let cached = typeMapCache, let at = typeMapAt,
           Date().timeIntervalSince(at) < 600 {
            completion(cached)
            return
        }
        typeMapLock.lock()
        if typeMapInFlight {
            typeMapPending.append(completion)
            typeMapLock.unlock()
            return
        }
        typeMapInFlight = true
        typeMapPending = [completion]
        typeMapTables = []
        typeMapLock.unlock()
        let playSources = sources.filter { $0.isPlaySource }
        let group = DispatchGroup()
        for source in playSources {
            group.enter()
            fetchJSON(source: source, query: "?ac=list", timeout: 8) { json in
                if let json = json {
                    self.typeMapLock.lock()
                    self.typeMapTables.append((source: source, json: json))
                    self.typeMapLock.unlock()
                }
                group.leave()
            }
        }
        // 6 s overall cap: a partial map is fine, home rows come
        // from the types that did answer.
        let timeoutWork = DispatchWorkItem { [weak self] in
            self?.finishTypeMap(playSources: playSources)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 6, execute: timeoutWork)
        group.notify(queue: .global()) { [weak self] in
            timeoutWork.cancel()
            self?.finishTypeMap(playSources: playSources)
        }
    }

    private func finishTypeMap(playSources: [VideoSource]) {
        typeMapLock.lock()
        guard typeMapInFlight else {
            typeMapLock.unlock()
            return
        }
        typeMapInFlight = false
        let tables = typeMapTables
        let pending = typeMapPending
        typeMapPending = []
        typeMapTables = []
        typeMapLock.unlock()
        let order: [Int: Int] = Dictionary(uniqueKeysWithValues: playSources.enumerated().map { ($0.element.id, $0.offset) })
        let sorted = tables.sorted { (order[$0.source.id] ?? 999) < (order[$1.source.id] ?? 999) }
        var grouped: [String: [CmsTypeEntry]] = [:]
        for table in sorted {
            for entry in CmsClient.parseClassTable(source: table.source, json: table.json) {
                grouped[entry.key, default: []].append(entry.value)
            }
        }
        var map: [String: CmsTypeEntry] = [:]
        for (key, entries) in grouped {
            guard let first = entries.first else { continue }
            map[key] = CmsTypeEntry(
                source: first.source, sourceName: first.sourceName, typeId: first.typeId,
                childTypeIds: first.childTypeIds, candidates: Array(entries.dropFirst())
            )
        }
        if tables.count * 2 >= playSources.count {
            typeMapCache = map
            typeMapAt = Date()
        }
        DispatchQueue.main.async {
            for completion in pending { completion(map) }
        }
    }

    /// One source's `?ac=list` class table → type_name → entry.
    /// Children come from the table's own `type_pid` links; adult
    /// and 里番 names are skipped both as entries and as children.
    static func parseClassTable(source: VideoSource, json: [String: Any]) -> [String: CmsTypeEntry] {
        var rows: [(name: String, id: String, pid: String)] = []
        var ids = Set<String>()
        for c in VideoJSON.asList(json["class"]) {
            let name = VideoJSON.asString(c["type_name"]).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            if isAdultVideo(type: name, name: nil) { continue }
            if name.contains("里番") { continue }
            let id = VideoJSON.asString(c["type_id"])
            if id.isEmpty { continue }
            rows.append((name: name, id: id, pid: VideoJSON.asString(c["type_pid"])))
            ids.insert(id)
        }
        var childrenOf: [String: [String]] = [:]
        for r in rows where r.pid != "0" && r.pid != "" && ids.contains(r.pid) {
            childrenOf[r.pid, default: []].append(r.id)
        }
        var entries: [String: CmsTypeEntry] = [:]
        for r in rows where entries[r.name] == nil {
            entries[r.name] = CmsTypeEntry(
                source: source.id, sourceName: source.name, typeId: r.id,
                childTypeIds: childrenOf[r.id] ?? [], candidates: []
            )
        }
        return entries
    }

    // MARK: - Home / daily / by-type

    private var homeCache: [VideoHomeRow]?
    private var homeCacheAt: Date?
    private var homeCacheKey: String?

    /// One `?ac=videolist&t=<typeId>&pg=<p>` page from one source:
    /// parsed rows (title + cover required, adult dropped) + the
    /// source's total/pagecount. Nil when the request fails.
    private func fetchTypePage(source: VideoSource, typeId: String, page: Int, extraQuery: String = "", completion: @escaping ((rows: [CmsSearchRow], total: Int, pagecount: Int)?) -> Void) {
        let encoded = typeId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? typeId
        fetchJSON(source: source, query: "?ac=videolist&t=\(encoded)&pg=\(page)\(extraQuery)", timeout: 8) { json in
            guard let json = json else {
                completion(nil)
                return
            }
            let rows = VideoJSON.asList(json["list"]).compactMap { x -> CmsSearchRow? in
                let row = CmsClient.parseVideoItem(source: source, row: x)
                if row.item.title.isEmpty { return nil }
                if row.item.coverURL == nil { return nil }
                if isAdultVideo(type: row.item.typeName, name: row.item.title) { return nil }
                return row
            }
            completion((rows: rows, total: VideoJSON.asInt(json["total"]), pagecount: max(1, VideoJSON.asInt(json["pagecount"]))))
        }
    }

    /// One category page (`page` 0-based; CMS pages are 1-based,
    /// so the fetch uses `page + 1`). Same candidate ladder as
    /// homeRowOne: leaf → one type page on the primary source,
    /// falling back to same-name candidates; parent → child pages
    /// interleaved. Nil when no candidate returns a matching page.
    func byType(typeName: String, page: Int, completion: @escaping (VideoByTypeResult?) -> Void) {
        typeMap { map in
            guard let entry = map[typeName] else {
                completion(nil)
                return
            }
            let attempts = [entry] + entry.candidates
            let limited = Array(attempts.prefix(4))
            var index = 0
            func step() {
                if index >= limited.count {
                    completion(nil)
                    return
                }
                let target = limited[index]
                index += 1
                guard let source = self.sourceById(target.source) else {
                    step()
                    return
                }
                if target.isParent {
                    self.fetchChildPages(source: source, childTypeIds: target.childTypeIds, page: page + 1) { pages in
                        let valid = pages.compactMap { $0 }
                        if valid.isEmpty {
                            step()
                            return
                        }
                        let items = CmsClient.interleaveTypePages(valid.map { $0.rows.map { $0.item } })
                        let total = valid.reduce(0) { $0 + $1.total }
                        let pagecount = valid.map { $0.pagecount }.max() ?? 0
                        completion(VideoByTypeResult(name: typeName, page: page, pagecount: pagecount, total: total, items: items))
                    }
                    return
                }
                self.fetchTypePage(source: source, typeId: target.typeId, page: page + 1) { result in
                    guard let result = result, CmsClient.leafPageMatches(name: typeName, items: result.rows.map { $0.item }) else {
                        step()
                        return
                    }
                    completion(VideoByTypeResult(name: typeName, page: page, pagecount: result.pagecount, total: result.total, items: result.rows.map { $0.item }))
                }
            }
            step()
        }
    }

    /// One home row: leaf → `?ac=videolist&t=<typeId>&pg=1` on the
    /// primary source, falling back to same-name candidates; parent
    /// → all child type_ids, merged. At most 4 attempts.
    /// Completion carries the row and the source's total (home
    /// sorts rows by total desc).
    func homeRowOne(typeName: String, entry: CmsTypeEntry, completion: @escaping (VideoHomeRow?, Int) -> Void) {
        let attempts = [entry] + entry.candidates
        let limited = Array(attempts.prefix(4))
        var index = 0
        func step() {
            if index >= limited.count {
                completion(nil, 0)
                return
            }
            let target = limited[index]
            index += 1
            guard let source = sourceById(target.source) else {
                step()
                return
            }
            if target.isParent {
                fetchChildPages(source: source, childTypeIds: target.childTypeIds, page: 1) { pages in
                    let valid = pages.compactMap { $0 }
                    if valid.isEmpty {
                        step()
                        return
                    }
                    let items = Array(CmsClient.interleaveTypePages(valid.map { $0.rows.map { $0.item } }).prefix(10))
                    if items.isEmpty {
                        step()
                        return
                    }
                    let total = valid.reduce(0) { $0 + $1.total }
                    completion(VideoHomeRow(id: typeName, title: typeName, items: items), total)
                }
                return
            }
            fetchTypePage(source: source, typeId: target.typeId, page: 1) { page in
                guard let page = page, CmsClient.leafPageMatches(name: typeName, items: page.rows.map { $0.item }) else {
                    step()
                    return
                }
                completion(VideoHomeRow(id: typeName, title: typeName, items: Array(page.rows.map { $0.item }.prefix(10))), page.total)
            }
        }
        step()
    }

    /// Fetch one page per child type id, at most 5 in flight at
    /// once. Results stay in child order.
    private func fetchChildPages(source: VideoSource, childTypeIds: [String], page: Int, completion: @escaping ([(rows: [CmsSearchRow], total: Int, pagecount: Int)?]) -> Void) {
        var out: [(rows: [CmsSearchRow], total: Int, pagecount: Int)?] = Array(repeating: nil, count: childTypeIds.count)
        let group = DispatchGroup()
        let lock = NSLock()
        let fanout = 5
        var start = 0
        func batch() {
            let end = min(start + fanout, childTypeIds.count)
            if start >= end {
                DispatchQueue.main.async { completion(out) }
                return
            }
            let batchStart = start
            start = end
            for i in batchStart..<end {
                group.enter()
                fetchTypePage(source: source, typeId: childTypeIds[i], page: page) { result in
                    lock.lock()
                    out[i] = result
                    lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .global()) { batch() }
        }
        batch()
    }

    /// First 12 types (priority order), each raced against its own
    /// 8 s timeout; keep rows with items; sort rows by count desc,
    /// take top 10. Total budget 9 s. 60 s repeat-call throttle.
    func home(completion: @escaping ([VideoHomeRow]) -> Void) {
        let key = sources.map { $0.apiUrl }.joined(separator: ",")
        if let cached = homeCache, homeCacheKey == key, let at = homeCacheAt,
           Date().timeIntervalSince(at) < 60 {
            completion(cached)
            return
        }
        let started = Date()
        typeMap { map in
            var names = Array(map.keys)
            names.sort { a, b in
                let ia = kVideoTypePriority.firstIndex(of: a) ?? -1
                let ib = kVideoTypePriority.firstIndex(of: b) ?? -1
                if ia >= 0 && ib >= 0 { return ia < ib }
                if ia >= 0 { return true }
                if ib >= 0 { return false }
                return a < b
            }
            let rowBudget = 9 - Date().timeIntervalSince(started)
            if rowBudget <= 0 {
                completion([])
                return
            }
            var got: [VideoHomeRow] = []
            var counts: [String: Int] = [:]
            let group = DispatchGroup()
            let lock = NSLock()
            var finished = false
            func finish() {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                let rows = got.sorted { (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) }
                let top = Array(rows.prefix(10))
                self.homeCache = top
                self.homeCacheAt = Date()
                self.homeCacheKey = key
                DispatchQueue.main.async { completion(top) }
            }
            for name in names.prefix(12) {
                guard let entry = map[name] else { continue }
                group.enter()
                self.homeRowOne(typeName: name, entry: entry) { row, total in
                    if let row = row, !row.items.isEmpty {
                        lock.lock()
                        got.append(row)
                        counts[row.id] = total
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + rowBudget) { finish() }
            group.notify(queue: .global()) { finish() }
        }
    }

    /// Daily picks: `?ac=videolist&pg=1` over all play sources
    /// (3 workers in Flutter — serial here, 10 s cap); dedupe by
    /// name|year; series first, then the rest; take 12.
    func daily(completion: @escaping ([VideoItem]) -> Void) {
        let playSources = sources.filter { $0.isPlaySource }
        var all: [CmsSearchRow] = []
        let deadline = Date().addingTimeInterval(10)
        var index = 0
        func finish() {
            var seen: [String: CmsSearchRow] = [:]
            var series: [VideoItem] = []
            var other: [VideoItem] = []
            for row in all {
                let x = row.item
                if x.title.isEmpty || x.coverURL == nil { continue }
                if isAdultVideo(type: x.typeName, name: x.title) { continue }
                let key = "\(videoNormTitle(x.title))|\(x.year ?? "")"
                if let ex = seen[key] {
                    if row.score > ex.score { seen[key] = row }
                    continue
                }
                seen[key] = row
                if (x.typeName ?? "").contains("剧") {
                    series.append(x)
                } else {
                    other.append(x)
                }
            }
            DispatchQueue.main.async {
                completion(Array((series + other).prefix(12)))
            }
        }
        func step() {
            if index >= playSources.count || Date() > deadline {
                finish()
                return
            }
            let source = playSources[index]
            index += 1
            fetchJSON(source: source, query: "?ac=videolist&pg=1", timeout: 8) { json in
                if let json = json {
                    all.append(contentsOf: VideoJSON.asList(json["list"]).map { CmsClient.parseVideoItem(source: source, row: $0) })
                }
                step()
            }
        }
        step()
    }

    /// By-type page. Parent categories fan out to child type_ids
    /// and merge; leaves query one source, falling back to
    /// same-name candidates. Filtered (area/year) fetches a window
    /// of 10 CMS pages for leaves, then client-side filters.
    func byType(name: String, page: Int, area: String = "all", year: String = "all", by: String = "", completion: @escaping (VideoByTypeResult?) -> Void) {
        typeMap { map in
            guard let entry = map[name] else {
                completion(nil)
                return
            }
            if entry.isParent {
                self.byParentType(name: name, entry: entry, page: page, area: area, year: year, by: by, completion: completion)
            } else {
                self.byLeafType(name: name, entry: entry, page: page, area: area, year: year, by: by, completion: completion)
            }
        }
    }

    private func byLeafType(name: String, entry: CmsTypeEntry, page: Int, area: String, year: String, by: String, completion: @escaping (VideoByTypeResult?) -> Void) {
        let filtered = area != "all" || year != "all"
        let window = 10
        let attempts = Array(([entry] + entry.candidates).prefix(4))
        var anyOk = false
        var bestPagecount = 1
        var index = 0
        func step() {
            if index >= attempts.count {
                if !anyOk {
                    completion(nil)
                } else {
                    completion(VideoByTypeResult(name: name, page: page, pagecount: bestPagecount, total: 0, items: []))
                }
                return
            }
            let target = attempts[index]
            index += 1
            guard let source = sourceById(target.source) else {
                step()
                return
            }
            let pagesToFetch = filtered ? (0..<window).map { (page - 1) * window + 1 + $0 } : [page]
            var extraQuery = ""
            if area != "all" && area != "other" {
                extraQuery += "&area=\((area.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? area))"
            }
            if year != "all" && year != "earlier" {
                extraQuery += "&year=\((year.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? year))"
            }
            if by == "hits" || by == "score" {
                extraQuery += "&by=\(by)"
            }
            let group = DispatchGroup()
            var raws: [[String: Any]?] = Array(repeating: nil, count: pagesToFetch.count)
            let lock = NSLock()
            for (i, p) in pagesToFetch.enumerated() {
                group.enter()
                let encoded = target.typeId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? target.typeId
                fetchJSON(source: source, query: "?ac=videolist&t=\(encoded)&pg=\(p)\(extraQuery)", timeout: 8) { json in
                    if json != nil { anyOk = true }
                    lock.lock()
                    raws[i] = json
                    lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .global()) {
                var srcPagecount = 1
                var srcTotal = 0
                for json in raws.compactMap({ $0 }) {
                    srcPagecount = max(srcPagecount, VideoJSON.asInt(json["pagecount"]))
                    srcTotal = max(srcTotal, VideoJSON.asInt(json["total"]))
                }
                bestPagecount = max(bestPagecount, srcPagecount)
                var rows: [CmsSearchRow] = []
                for json in raws.compactMap({ $0 }) {
                    for x in VideoJSON.asList(json["list"]) {
                        let row = CmsClient.parseVideoItem(source: source, row: x)
                        if row.item.title.isEmpty || row.item.coverURL == nil { continue }
                        rows.append(row)
                    }
                }
                if !CmsClient.leafPageMatches(name: name, items: rows.map { $0.item }) {
                    step()
                    return
                }
                let items = CmsClient.filterByTypeItems(rows, area: area, year: year, by: by)
                let pagecount = filtered ? max(1, Int(ceil(Double(srcPagecount) / Double(window)))) : srcPagecount
                let result = VideoByTypeResult(name: name, page: page, pagecount: pagecount, total: filtered ? items.count : srcTotal, items: items)
                DispatchQueue.main.async { completion(result) }
            }
        }
        step()
    }

    private func byParentType(name: String, entry: CmsTypeEntry, page: Int, area: String, year: String, by: String, completion: @escaping (VideoByTypeResult?) -> Void) {
        let filtered = area != "all" || year != "all"
        let attempts = Array(([entry] + entry.candidates).prefix(4))
        var anyOk = false
        var bestPagecount = 1
        var index = 0
        func step() {
            if index >= attempts.count {
                if !anyOk {
                    completion(nil)
                } else {
                    completion(VideoByTypeResult(name: name, page: page, pagecount: bestPagecount, total: 0, items: []))
                }
                return
            }
            let target = attempts[index]
            index += 1
            guard let source = sourceById(target.source) else {
                step()
                return
            }
            if target.isParent {
                fetchChildPages(source: source, childTypeIds: target.childTypeIds, page: page) { fetched in
                    let pages = fetched.compactMap { $0 }
                    if pages.isEmpty {
                        step()
                        return
                    }
                    anyOk = true
                    let total = pages.reduce(0) { $0 + $1.total }
                    let pagecount = pages.reduce(1) { max($0, $1.pagecount) }
                    bestPagecount = max(bestPagecount, pagecount)
                    let rows = CmsClient.interleaveTypeRows(pages.map { $0.rows })
                    if rows.isEmpty {
                        step()
                        return
                    }
                    var items = CmsClient.filterByTypeItems(rows, area: area, year: year, by: by)
                    if !filtered && items.count > 20 { items = Array(items.prefix(20)) }
                    let result = VideoByTypeResult(name: name, page: page, pagecount: pagecount, total: filtered ? items.count : total, items: items)
                    DispatchQueue.main.async { completion(result) }
                }
                return
            }
            fetchTypePage(source: source, typeId: target.typeId, page: page) { result in
                guard let result = result else {
                    step()
                    return
                }
                anyOk = true
                if !CmsClient.leafPageMatches(name: name, items: result.rows.map { $0.item }) {
                    step()
                    return
                }
                var items = CmsClient.filterByTypeItems(result.rows, area: area, year: year, by: by)
                if !filtered && items.count > 20 { items = Array(items.prefix(20)) }
                let pageResult = VideoByTypeResult(name: name, page: page, pagecount: result.pagecount, total: filtered ? items.count : result.total, items: items)
                DispatchQueue.main.async { completion(pageResult) }
            }
        }
        step()
    }

    // MARK: - Type helpers (pure)

    /// A leaf page is usable when it has items AND at least one
    /// item's type matches the requested name — or when every
    /// item's type is blank (some sources omit type_name).
    static func leafPageMatches(name: String, items: [VideoItem]) -> Bool {
        if items.isEmpty { return false }
        if items.contains(where: { $0.typeName == name }) { return true }
        return items.allSatisfy { ($0.typeName ?? "").isEmpty }
    }

    /// Round-robin interleave of per-child page lists, deduped by
    /// source|vodId.
    static func interleaveTypePages(_ pages: [[VideoItem]]) -> [VideoItem] {
        var out: [VideoItem] = []
        var seen = Set<String>()
        var idx = 0
        var added = true
        while added {
            added = false
            for list in pages where idx < list.count {
                let item = list[idx]
                if seen.insert("\(item.sourceId ?? -1)|\(item.id)").inserted {
                    out.append(item)
                }
                added = true
            }
            idx += 1
        }
        return out
    }

    /// Area/year filters + hits/score sort shared by the leaf and
    /// parent by-type paths.
    /// Area/year filters + hits/score sort shared by the leaf and
    /// parent by-type paths. Runs on rows (not items) because the
    /// region lives in `vod_area`, which Swift's VideoItem does
    /// not carry — the row keeps it for exactly this filter.
    static func filterByTypeItems(_ rows: [CmsSearchRow], area: String, year: String, by: String) -> [VideoItem] {
        var out = rows
        if area != "all" {
            if area == "other" {
                out = out.filter { row in
                    !kKnownVideoAreas.contains { a in row.area.contains(a) }
                }
            } else {
                let aliases = kVideoAreaAlias[area] ?? [area]
                out = out.filter { row in
                    aliases.contains { a in row.area.contains(a) }
                }
            }
        }
        if year != "all" {
            if year == "earlier" {
                out = out.filter { (Int($0.item.year ?? "") ?? 9999) <= 2021 }
            } else {
                out = out.filter { $0.item.year == year }
            }
        }
        if by == "hits" {
            out.sort { $0.hits > $1.hits }
        } else if by == "score" {
            out.sort { $0.score > $1.score }
        }
        return out.map { $0.item }
    }

    /// Round-robin interleave of per-child page ROW lists, deduped
    /// by source|vodId (the row form of interleaveTypePages).
    static func interleaveTypeRows(_ pages: [[CmsSearchRow]]) -> [CmsSearchRow] {
        var out: [CmsSearchRow] = []
        var seen = Set<String>()
        var idx = 0
        var added = true
        while added {
            added = false
            for list in pages where idx < list.count {
                let row = list[idx]
                if seen.insert("\(row.item.sourceId ?? -1)|\(row.item.id)").inserted {
                    out.append(row)
                }
                added = true
            }
            idx += 1
        }
        return out
    }

    // MARK: - Probe + runtime measurement

    /// Probe (`testSource`): `GET <apiUrl>?ac=videolist&pg=1` —
    /// pass when the JSON has `list[]` or `class[]` (or code 0).
    func probe(source: VideoSource, completion: @escaping (Bool) -> Void) {
        fetchJSON(source: source, query: "?ac=videolist&pg=1", timeout: 8) { json in
            completion(json.map { CmsClient.isProbeOk($0) } ?? false)
        }
    }

    /// Runtime speed measurement (P0-11): probe every enabled
    /// source once (3 s each, serial) and record the latency.
    /// Completion carries apiUrl → measured ms for the sources
    /// that answered. The settings page calls this on demand;
    /// every normal fetch also records its latency.
    func measureSources(completion: @escaping ([String: Double]) -> Void) {
        var measured: [String: Double] = [:]
        var index = 0
        let enabled = sources
        func finish() {
            DispatchQueue.main.async { completion(measured) }
        }
        func step() {
            if index >= enabled.count {
                finish()
                return
            }
            let source = enabled[index]
            index += 1
            let started = Date()
            fetchJSON(source: source, query: "?ac=videolist&pg=1", timeout: 3) { json in
                if json != nil {
                    measured[source.apiUrl] = Date().timeIntervalSince(started) * 1000
                }
                step()
            }
        }
        step()
    }

    // MARK: - VideoPlayURLResolver

    /// Resolve a playable URL for one episode on one line.
    /// Candidates: the episode at the same index on every line,
    /// requested line first, then the other lines in parse order
    /// (m3u8 lines first — the parse already orders them). URLs in
    /// `excluding` are never handed out twice. The FIRST
    /// non-excluded candidate wins; nil only when every line's
    /// episode is excluded or missing.
    ///
    /// No second-level fetch exists here on purpose: in the
    /// Flutter client the CMS episode URL IS the stream URL (the
    /// player opens it directly). This resolver's job is line
    /// fallback + the excluding list, not re-parsing a play page.
    func resolvePlayURL(detail: VideoDetail, episode: PlayEpisode, line: PlayLine, excluding: [URL], completion: @escaping (URL?) -> Void) {
        let excluded = Set(excluding.map { $0.absoluteString })
        var candidates: [URL] = []
        if let url = line.episode(at: episode.index)?.url {
            candidates.append(url)
        }
        for other in detail.lines where other.name != line.name {
            if let url = other.episode(at: episode.index)?.url {
                candidates.append(url)
            }
        }
        // The requested episode's own URL, even if its index
        // drifted on another line: match by name as a last resort.
        if candidates.isEmpty, let url = episode.url {
            candidates.append(url)
        }
        for url in candidates where !excluded.contains(url.absoluteString) {
            completion(url)
            return
        }
        completion(nil)
    }
}

// HAo Studio 2.0 — Douban metadata service (S3 leg B).
//
// Swift port of the Flutter `douban_service.dart` +
// `douban_parsers.dart` (standalone-app-merge23). Douban is the
// SOLE metadata source: search + detail, no key, no login.
//
// Resolution order: title → id via suggest, then the desktop
// search page, then the builtin map. Then abstract + mobile page
// (poster / overview / score). Whole detail flow race-capped at
// 15 s.
//
// Year check (the mismatch rule): a title→id link is only trusted
// while the detail's year is within 1 of the CMS year. A mismatch
// evicts the link AND the wrong detail, and the mismatch is never
// cached — title→id entries carry a 7-day TTL, so even a mismatch
// that slips past every check self-heals within a week.
//
// Throttle + backoff (kept — the upstream rate-limits
// aggressively): all calls serialised through one chain with a
// ≥ 1 s gap; HTTP 403 blocks all calls for 60 s; after 3
// consecutive suggest failures, suggest is disabled permanently
// (persisted flag).
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Models

/// One Douban title. JSON keys match the Flutter DoubanDetail so
/// the migrated `hao_douban_detail` collection file decodes as-is.
struct DoubanDetail: Codable, Equatable {
    var id: String
    var media: String
    var title: String
    var year: String?
    var poster: String
    var overview: String
    var score: String?
    var genres: [String]
    var runtime: Int?
    var countries: [String]
    var director: String
    var castNames: [String]
    var castPhotos: [String]
    var episodes: String?

    init(id: String = "", media: String = "movie", title: String = "", year: String? = nil,
         poster: String = "", overview: String = "", score: String? = nil,
         genres: [String] = [], runtime: Int? = nil, countries: [String] = [],
         director: String = "", castNames: [String] = [], castPhotos: [String] = [],
         episodes: String? = nil) {
        self.id = id
        self.media = media
        self.title = title
        self.year = year
        self.poster = poster
        self.overview = overview
        self.score = score
        self.genres = genres
        self.runtime = runtime
        self.countries = countries
        self.director = director
        self.castNames = castNames
        self.castPhotos = castPhotos
        self.episodes = episodes
    }

    /// Map to the seam VideoMeta: rating / year / cast /
    /// synopsis / Douban id.
    func toVideoMeta() -> VideoMeta {
        VideoMeta(
            rating: score.flatMap { Double($0) },
            year: year,
            cast: castNames,
            synopsis: overview.isEmpty ? nil : overview,
            doubanId: id.isEmpty ? nil : id
        )
    }
}

/// One suggest hit (`j/subject_suggest`).
struct DoubanSearchHit: Equatable {
    let id: String
    let title: String
    let year: Int
    let type: String
}

// MARK: - Pure parsers (no I/O — unit-tested)

enum DoubanParsers {
    /// Last resort before giving up (verified ids).
    static let builtinIds: [String: String] = [
        "流浪地球2": "35267208",
        "庆余年": "25853071",
        "肖申克的救赎": "1292052",
        "霸王别姬": "1291546",
        "泰坦尼克号": "1292722",
    ]

    /// Title→id mapping TTL: a film's id never changes, so the TTL
    /// only bounds how long a wrong mapping can hurt.
    static let idMapTTL: TimeInterval = 7 * 24 * 3600

    /// Detail-entry TTL (b49 sweep #7): same 7 days as the id map.
    /// A detail's rating / cast / synopsis do change (and a
    /// truncated write used to live forever behind the 200-entry
    /// cap), so entries expire instead of serving stale data.
    static let detailTTL: TimeInterval = idMapTTL

    /// True when a cached detail carries no usable content at all
    /// (b49 sweep #7 — the length check): an empty overview with
    /// no cast, no score and no poster is a truncated write, not
    /// a sparse film, and must refetch instead of being served.
    static func detailIsEmpty(_ detail: DoubanDetail) -> Bool {
        detail.overview.isEmpty && detail.castNames.isEmpty &&
        detail.score == nil && detail.poster.isEmpty
    }

    /// First (19|20)xx year in `s`, or 0 when there is none.
    static func parseYear(_ s: String?) -> Int {
        guard let s = s, !s.isEmpty else { return 0 }
        guard let re = try? NSRegularExpression(pattern: "(19|20)[0-9]{2}", options: []),
              let m = re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range, in: s) else { return 0 }
        return Int(s[r]) ?? 0
    }

    /// True when `gotYear` (the detail's year) and `wantYear` (the
    /// CMS year) are both known and more than 1 year apart. A
    /// 1-year gap is tolerated (release-year vs first-air-year
    /// drift between sources).
    static func yearsMismatch(gotYear: String?, useYear: Bool, wantYear: Int) -> Bool {
        if !useYear || wantYear == 0 { return false }
        let got = parseYear(gotYear)
        if got == 0 { return false }
        return abs(got - wantYear) > 1
    }

    /// A cached detail whose cast has names but NO photos is stale:
    /// it was saved when the photo fetch failed, and the cache is
    /// permanent — without this, photos never appear again.
    static func photosMissing(_ cached: DoubanDetail?) -> Bool {
        guard let cached = cached else { return false }
        return !cached.castNames.isEmpty &&
            (cached.castPhotos.count < cached.castNames.count ||
             cached.castPhotos.allSatisfy { $0.isEmpty })
    }

    /// Parse `movie.douban.com/j/subject_abstract?subject_id=<id>`.
    /// Nil when `r == "error"` or there is no `subject`.
    static func parseAbstract(_ json: [String: Any]?) -> DoubanDetail? {
        guard let json = json else { return nil }
        if VideoJSON.asString(json["r"]) == "error" { return nil }
        guard let s = VideoJSON.asMap(json["subject"]) else { return nil }
        let duration = VideoJSON.asString(s["duration"])
        var runtime: Int?
        if let re = try? NSRegularExpression(pattern: "([0-9]+)", options: []),
           let m = re.firstMatch(in: duration, options: [], range: NSRange(duration.startIndex..., in: duration)),
           m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: duration) {
            runtime = Int(duration[r])
        }
        let rate = s["rate"]
        let rateString: String? = {
            guard let rate = rate else { return nil }
            let text = VideoJSON.asString(rate)
            return text.isEmpty ? nil : text
        }()
        let directors = VideoJSON.asStringList(s["directors"])
        let actors = VideoJSON.asStringList(s["actors"])
        let region = VideoJSON.asString(s["region"])
        return DoubanDetail(
            id: VideoJSON.asString(s["id"]),
            media: (s["is_tv"] as? Bool) == true ? "tv" : "movie",
            title: VideoJSON.asString(s["title"]),
            year: {
                let y = VideoJSON.asString(s["release_year"])
                return y.isEmpty ? nil : y
            }(),
            score: rateString,
            genres: VideoJSON.asStringList(s["types"]),
            runtime: runtime,
            countries: region.isEmpty ? [] : [region],
            director: directors.joined(separator: "/"),
            castNames: Array(actors.prefix(10)),
            episodes: {
                let e = VideoJSON.asString(s["episodes_count"])
                return e.isEmpty ? nil : e
            }()
        )
    }

    /// Parse the mobile page `m.douban.com/movie/subject/<id>/` →
    /// poster / overview / score. Poster via og:image `pNNNN` id →
    /// l_ratio_poster URL, else any l_ratio_poster match (then m,
    /// then s), else the raw og:image; overview from the
    /// description meta (entity-decoded, leading `…评分：X.X 简介：`
    /// prefix stripped); score from the ratingValue meta.
    static func parseMPage(_ html: String?) -> (poster: String, overview: String, score: String?) {
        guard let html = html, !html.isEmpty else { return (poster: "", overview: "", score: nil) }
        func firstMatch(_ pattern: String, in text: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
        var poster = ""
        let og = firstMatch("<meta[^>]*property=\"og:image\"[^>]*content=\"([^\"]+)\"", in: html)
            ?? firstMatch("<meta[^>]*content=\"([^\"]+)\"[^>]*property=\"og:image\"", in: html)
        let ogUrl = (og ?? "").replacingOccurrences(of: "&amp;", with: "&")
        if let idm = firstMatch("/public/(p[0-9]+)\\.jpg", in: ogUrl) {
            for tier in ["l_ratio_poster", "m_ratio_poster", "s_ratio_poster"] {
                let pattern = "https://img[0-9]+\\.doubanio\\.com/view/photo/\(tier)/public/\(idm)\\.jpg"
                if let re = try? NSRegularExpression(pattern: pattern, options: []),
                   let m = re.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
                   let r = Range(m.range, in: html) {
                    poster = String(html[r]).replacingOccurrences(of: tier, with: "l_ratio_poster")
                    break
                }
            }
        }
        if poster.isEmpty {
            for tier in ["l_ratio_poster", "m_ratio_poster", "s_ratio_poster"] {
                let pattern = "https://img[0-9]+\\.doubanio\\.com/view/photo/\(tier)/public/p[0-9]+\\.jpg"
                if let re = try? NSRegularExpression(pattern: pattern, options: []),
                   let m = re.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
                   let r = Range(m.range, in: html) {
                    poster = String(html[r]).replacingOccurrences(of: tier, with: "l_ratio_poster")
                    break
                }
            }
        }
        if poster.isEmpty && !ogUrl.isEmpty { poster = ogUrl }

        var overview = ""
        if let dm = firstMatch("<meta[^>]*itemprop=\"description\"[^>]*content=\"([^\"]*)\"", in: html)
            ?? firstMatch("<meta[^>]*content=\"([^\"]*)\"[^>]*itemprop=\"description\"", in: html) {
            var txt = dm
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&#39;", with: "'")
            if let re = try? NSRegularExpression(pattern: "^.*?豆瓣评分：[0-9.]+ *简介：", options: []) {
                let range = NSRange(txt.startIndex..., in: txt)
                txt = re.stringByReplacingMatches(in: txt, options: [], range: range, withTemplate: "")
            }
            overview = txt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let score = firstMatch("<meta[^>]*itemprop=\"ratingValue\"[^>]*content=\"([0-9.]+)\"", in: html)
        return (poster: poster, overview: overview, score: score)
    }

    /// Suggest endpoint: `movie.douban.com/j/subject_suggest?q=<title>`
    /// — JSON array; parse every hit (id / title / year / type).
    static func parseSuggestHits(_ json: Any?) -> [DoubanSearchHit] {
        guard let list = json as? [Any] else { return [] }
        var out: [DoubanSearchHit] = []
        for entry in list {
            guard let e = entry as? [String: Any] else { continue }
            let id = VideoJSON.asString(e["id"])
            if id.isEmpty { continue }
            let rawYear = e["year"]
            let year: Int
            if let number = rawYear as? NSNumber {
                year = number.intValue
            } else {
                year = Int(VideoJSON.asString(rawYear)) ?? 0
            }
            out.append(DoubanSearchHit(
                id: id,
                title: VideoJSON.asString(e["title"]),
                year: year,
                type: VideoJSON.asString(e["type"])
            ))
        }
        return out
    }

    /// Pick the best suggest hit for `title` (+ `year` when known).
    /// Every hit is scored on normalised title first, then year
    /// closeness; a hit is only eligible when its title matches
    /// (exact / starts-with / contains, either direction) and,
    /// when both years are known, the years are within 1. Nil when
    /// nothing is eligible — the caller falls through to the
    /// desktop search page / builtin map instead of caching a
    /// wrong id.
    static func pickSuggestId(hits: [DoubanSearchHit], title: String, year: Int) -> String? {
        let qn = videoNormTitle(title)
        if qn.isEmpty { return nil }
        var best: DoubanSearchHit?
        var bestTitleScore = Int.max
        var bestYearDiff = Int.max
        for hit in hits {
            let cn = videoNormTitle(hit.title)
            if cn.isEmpty || qn.count < 2 || cn.count < 2 {
                if cn != qn { continue }
            }
            let titleScore: Int
            if cn == qn {
                titleScore = 0
            } else if cn.hasPrefix(qn) || qn.hasPrefix(cn) {
                titleScore = 1
            } else if cn.contains(qn) || qn.contains(cn) {
                titleScore = 2
            } else {
                continue
            }
            var yearDiff = Int.max
            if year != 0 && hit.year != 0 {
                let d = abs(hit.year - year)
                if d > 1 { continue }
                yearDiff = d
            }
            if titleScore < bestTitleScore ||
                (titleScore == bestTitleScore && yearDiff < bestYearDiff) {
                best = hit
                bestTitleScore = titleScore
                bestYearDiff = yearDiff
            }
        }
        return best?.id
    }

    /// Desktop search fallback: `www.douban.com/search?cat=1002&q=<title>`
    /// — HTML regex `sid:\s*(\d+)` else `movie.douban.com/subject/(\d+)`.
    static func parseSearchPageId(_ html: String?) -> String? {
        guard let html = html, !html.isEmpty else { return nil }
        for pattern in ["sid:\\s*([0-9]+)", "movie\\.douban\\.com/subject/([0-9]+)"] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: []),
                  let m = re.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: html) else { continue }
            return String(html[r])
        }
        return nil
    }

    /// Desktop page `movie.douban.com/subject/<id>/` cast section →
    /// `{actor name: avatar URL}`.
    static func parseDesktopCast(_ html: String?) -> [String: String] {
        var out: [String: String] = [:]
        guard let html = html, !html.isEmpty else { return out }
        guard let blockRe = try? NSRegularExpression(pattern: "<li class=\"celebrity\">(.*?)</li>", options: [.dotMatchesLineSeparators]),
              let avatarRe = try? NSRegularExpression(pattern: "https://img[0-9]+\\.doubanio\\.com/view/celebrity/s_ratio_celebrity/public/p[\\w.]+?\\.jpg", options: []),
              let nameRe = try? NSRegularExpression(pattern: "<span class=\"name\">\\s*<a[^>]*>([^<]+)</a>", options: []) else { return out }
        let range = NSRange(html.startIndex..., in: html)
        for block in blockRe.matches(in: html, options: [], range: range) {
            guard block.numberOfRanges > 1, let bodyRange = Range(block.range(at: 1), in: html) else { continue }
            let body = String(html[bodyRange])
            let bodyRange2 = NSRange(body.startIndex..., in: body)
            guard let avatarMatch = avatarRe.firstMatch(in: body, options: [], range: bodyRange2),
                  let avatarRange = Range(avatarMatch.range, in: body),
                  let nameMatch = nameRe.firstMatch(in: body, options: [], range: bodyRange2),
                  nameMatch.numberOfRanges > 1,
                  let nameRange = Range(nameMatch.range(at: 1), in: body) else { continue }
            let name = String(body[nameRange]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                out[name] = out[name] ?? String(body[avatarRange])
            }
        }
        return out
    }

    /// Baidu Baike lemma card → actor photo URL, or nil.
    /// Guards against wrong-person matches: `title` must equal
    /// `name` exactly, and a non-empty `desc` must describe an
    /// entertainer (演员/歌手/艺人/明星/导演/主持/偶像/童星/舞者).
    static func parseBaikeCardPhoto(_ json: [String: Any]?, name: String) -> String? {
        guard let json = json, !name.isEmpty else { return nil }
        let title = VideoJSON.asString(json["title"]).trimmingCharacters(in: .whitespaces)
        if title != name { return nil }
        let desc = VideoJSON.asString(json["desc"])
        let entertainer = ["演员", "歌手", "艺人", "明星", "导演", "主持", "偶像", "童星", "舞者"]
        if !desc.isEmpty && !entertainer.contains(where: { desc.contains($0) }) { return nil }
        let image = VideoJSON.asString(json["image"]).trimmingCharacters(in: .whitespaces)
        return image.isEmpty ? nil : image
    }

    /// Title → id cache key: season-stripped title, whitespace
    /// removed, lowercased.
    static func titleKey(_ title: String?) -> String {
        vodStripSeasonSuffix(title).base
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
    }
}

// MARK: - Cache

/// Cache backend for Douban detail + id map.
protocol DoubanCache {
    func detail(id: String) -> DoubanDetail?
    func setDetail(id: String, detail: DoubanDetail)
    func removeDetail(id: String)
    func idForTitle(key: String) -> String?
    func setIdForTitle(key: String, id: String)
    func removeIdForTitle(key: String)
    var suggestDisabled: Bool { get }
    func disableSuggest()
}

/// In-memory cache (tests / previews).
final class MemoryDoubanCache: DoubanCache {
    private var details: [String: DoubanDetail] = [:]
    private var detailTimes: [String: Date] = [:]
    private var ids: [String: String] = [:]
    private var idTimes: [String: Date] = [:]
    private var disabled = false

    func detail(id: String) -> DoubanDetail? {
        // b49 sweep #7: same TTL + completeness rule as the file
        // cache — an expired or truncated entry is a miss.
        guard let at = detailTimes[id],
              Date().timeIntervalSince(at) < DoubanParsers.detailTTL,
              let cached = details[id],
              !DoubanParsers.detailIsEmpty(cached) else {
            if detailTimes[id] != nil {
                details.removeValue(forKey: id)
                detailTimes.removeValue(forKey: id)
            }
            return nil
        }
        return cached
    }

    func setDetail(id: String, detail: DoubanDetail) {
        details[id] = detail
        detailTimes[id] = Date()
        if details.count > 200 {
            details.removeValue(forKey: details.keys.first ?? "")
        }
    }

    func removeDetail(id: String) {
        details.removeValue(forKey: id)
        detailTimes.removeValue(forKey: id)
    }

    func idForTitle(key: String) -> String? {
        guard let at = idTimes[key] else { return nil }
        if Date().timeIntervalSince(at) >= DoubanParsers.idMapTTL {
            ids.removeValue(forKey: key)
            idTimes.removeValue(forKey: key)
            return nil
        }
        return ids[key]
    }

    func setIdForTitle(key: String, id: String) {
        ids[key] = id
        idTimes[key] = Date()
    }

    func removeIdForTitle(key: String) {
        ids.removeValue(forKey: key)
        idTimes.removeValue(forKey: key)
    }

    var suggestDisabled: Bool { disabled }

    func disableSuggest() { disabled = true }
}

/// File-backed cache (production). Stores under the same names the
/// migration wrote (`hao_douban_detail` / `hao_douban_idmap`
/// collections, `hao_douban_no_suggest` UserDefaults flag), so a
/// migrated user's cache survives. Detail entries are the flat
/// Flutter shape (detail fields + `at` at the same level).
final class FileDoubanCache: DoubanCache {
    static let maxEntries = 200
    private let detailCollection = "hao_douban_detail"
    private let idMapCollection = "hao_douban_idmap"
    private let noSuggestKey = "hao_douban_no_suggest"

    struct DetailEntry: Codable {
        let detail: DoubanDetail
        let at: Int

        enum CodingKeys: String, CodingKey { case at }

        init(detail: DoubanDetail, at: Int) {
            self.detail = detail
            self.at = at
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            at = try container.decodeIfPresent(Int.self, forKey: .at) ?? 0
            detail = try DoubanDetail(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(at, forKey: .at)
            try detail.encode(to: encoder)
        }
    }

    struct IdEntry: Codable {
        let id: String
        let at: Int
    }

    private func readDetails() -> [String: DetailEntry] {
        LocalStore.loadCollection(named: detailCollection, default: [:])
    }

    private func writeDetails(_ map: [String: DetailEntry]) {
        LocalStore.saveCollection(named: detailCollection, value: map)
    }

    private func readIdMap() -> [String: Any] {
        // The migrated file may hold bare-String legacy entries
        // (no timestamp) — decode loosely, not as [String: IdEntry].
        let url = LocalStore.collectionURL(named: idMapCollection)
        guard let data = try? Data(contentsOf: url),
              let obj = VideoJSON.decode(data) as? [String: Any] else { return [:] }
        return obj
    }

    private func writeIdMap(_ map: [String: Any]) {
        let url = LocalStore.collectionURL(named: idMapCollection)
        guard let data = try? JSONSerialization.data(withJSONObject: map, options: []) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    func detail(id: String) -> DoubanDetail? {
        // b49 sweep #7: detail entries expire (7 days, same as the
        // id map) and a truncated entry is a miss — the old code
        // returned the entry regardless of its stored `at`, so a
        // stale or truncated detail lived until the 200-entry cap
        // evicted it.
        guard let entry = readDetails()[id] else { return nil }
        let ageMs = Int(Date().timeIntervalSince1970 * 1000) - entry.at
        guard ageMs >= 0, Double(ageMs) < DoubanParsers.detailTTL * 1000,
              !DoubanParsers.detailIsEmpty(entry.detail) else {
            removeDetail(id: id)
            return nil
        }
        return entry.detail
    }

    func setDetail(id: String, detail: DoubanDetail) {
        var map = readDetails()
        map[id] = DetailEntry(detail: detail, at: Int(Date().timeIntervalSince1970 * 1000))
        if map.count > Self.maxEntries {
            let sorted = map.keys.sorted { (map[$0]?.at ?? 0) < (map[$1]?.at ?? 0) }
            for key in sorted.prefix(map.count - Self.maxEntries) {
                map.removeValue(forKey: key)
            }
        }
        writeDetails(map)
    }

    func removeDetail(id: String) {
        var map = readDetails()
        if map.removeValue(forKey: id) != nil { writeDetails(map) }
    }

    func idForTitle(key: String) -> String? {
        let map = readIdMap()
        let value = map[key]
        if value is String { return nil } // legacy, no timestamp → expired
        guard let entry = value as? [String: Any],
              let id = entry["id"] as? String, !id.isEmpty,
              let at = entry["at"] as? NSNumber else { return nil }
        let ageMs = Int(Date().timeIntervalSince1970 * 1000) - at.intValue
        if ageMs >= 0 && Double(ageMs) < DoubanParsers.idMapTTL * 1000 { return id }
        return nil
    }

    func setIdForTitle(key: String, id: String) {
        var map = readIdMap()
        map[key] = ["id": id, "at": Int(Date().timeIntervalSince1970 * 1000)]
        if map.count > Self.maxEntries {
            let sorted = map.keys.sorted {
                let atA = ((map[$0] as? [String: Any])?["at"] as? NSNumber)?.intValue ?? 0
                let atB = ((map[$1] as? [String: Any])?["at"] as? NSNumber)?.intValue ?? 0
                return atA < atB
            }
            for k in sorted.prefix(map.count - Self.maxEntries) {
                map.removeValue(forKey: k)
            }
        }
        writeIdMap(map)
    }

    func removeIdForTitle(key: String) {
        var map = readIdMap()
        if map.removeValue(forKey: key) != nil { writeIdMap(map) }
    }

    var suggestDisabled: Bool {
        UserDefaults.standard.string(forKey: noSuggestKey) == "1"
    }

    func disableSuggest() {
        UserDefaults.standard.set("1", forKey: noSuggestKey)
    }
}

// MARK: - Service

/// Douban metadata service. No key, no login. All calls go through
/// one serial chain with a ≥ 1 s gap; HTTP 403 blocks all calls
/// for 60 s.
final class DoubanService {
    static let detailTimeout: TimeInterval = 15

    private let fetcher: VideoTextFetcher
    private let cache: DoubanCache
    private let castPhotoFetcher: (String, @escaping (String) -> Void) -> Void

    /// Serial chain: every call waits for the previous one plus
    /// the 1 s gap. Implemented with a serial queue + last-call
    /// timestamp (no locks, no timers in flight).
    private let chain = DispatchQueue(label: "com.haostudio.douban")
    private var lastCall = Date.distantPast
    private var blockedUntil = Date.distantPast
    private var suggestFails = 0

    var blocked: Bool { Date() < blockedUntil }

    init(
        fetcher: VideoTextFetcher? = nil,
        cache: DoubanCache? = nil,
        castPhotoFetcher: ((String, @escaping (String) -> Void) -> Void)? = nil
    ) {
        self.fetcher = fetcher ?? VideoHTTP.fetchText
        self.cache = cache ?? FileDoubanCache()
        self.castPhotoFetcher = castPhotoFetcher ?? DoubanService.defaultCastPhotoFetcher
    }

    // MARK: - Cast photos (Baidu Baike lemma card, free, no key)

    private static func defaultCastPhotoFetcher(name: String, completion: @escaping (String) -> Void) {
        guard let url = URL(string: "https://baike.baidu.com/api/openapi/BaikeLemmaCardApi?scope=103&format=json&appid=379020&bk_key=\(name.addingPercentEncoding(withAllowedCharacters: videoStrictQueryAllowed) ?? name)&bk_length=600") else {
            completion("")
            return
        }
        VideoHTTP.fetchText(url: url, headers: [:], timeout: 5) { _, body in
            guard let body = body,
                  let data = body.data(using: .utf8),
                  let obj = VideoJSON.decode(data) as? [String: Any] else {
                completion("")
                return
            }
            completion(DoubanParsers.parseBaikeCardPhoto(obj, name: name) ?? "")
        }
    }

    // MARK: - Serial call

    /// Run `work` on the serial chain after the ≥ 1 s gap. The
    /// gap is measured from the previous call's START (same as the
    /// Flutter chain). A blocked service fails fast without
    /// consuming the chain.
    private func call<T>(work: @escaping (@escaping (T?) -> Void) -> Void, completion: @escaping (T?) -> Void) {
        chain.async { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }
            if self.blocked {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let wait = 1 - Date().timeIntervalSince(self.lastCall)
            if wait > 0 {
                Thread.sleep(forTimeInterval: wait)
            }
            self.lastCall = Date()
            work { result in
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private func note403() {
        blockedUntil = Date().addingTimeInterval(60)
    }

    // MARK: - Low-level fetch

    /// GET returning a JSON object. Nil on transport failure,
    /// non-2xx, or an unparseable body. 403 notes the 60 s block.
    private func fetchJSON(url: URL, timeout: TimeInterval = 10, completion: @escaping ([String: Any]?) -> Void) {
        let headers = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Referer": "https://movie.douban.com/",
        ]
        call(work: { done in
            self.fetcher(url, headers, timeout) { status, body in
                if status == 403 {
                    self.note403()
                    done(nil)
                    return
                }
                guard let status = status, (200..<300).contains(status),
                      let body = body,
                      let data = body.data(using: .utf8),
                      let obj = VideoJSON.decode(data) as? [String: Any] else {
                    done(nil)
                    return
                }
                done(obj)
            }
        }, completion: completion)
    }

    /// GET returning plain text. Nil on transport failure or
    /// non-2xx. 403 notes the 60 s block.
    private func fetchText(url: URL, headers: [String: String], timeout: TimeInterval = 10, completion: @escaping (String?) -> Void) {
        call(work: { done in
            self.fetcher(url, headers, timeout) { status, body in
                if status == 403 {
                    self.note403()
                    done(nil)
                    return
                }
                guard let status = status, (200..<300).contains(status), let body = body else {
                    done(nil)
                    return
                }
                done(body)
            }
        }, completion: completion)
    }

    // MARK: - Search (suggest)

    /// Suggest search: `j/subject_suggest?q=<title>` → hits.
    /// Never throws; empty on any failure. A valid reply with no
    /// eligible hit is NOT a suggest failure (the service answered
    /// fine — the title just has no good match). The endpoint
    /// answers a bare JSON array, so this parses the raw body
    /// (the object fetcher cannot represent it).
    func search(title: String, completion: @escaping ([DoubanSearchHit]) -> Void) {
        suggestHits(title: title, year: 0, completion: completion)
    }

    /// Suggest hits from a raw body (the endpoint answers a bare
    /// JSON array — parsed here, not through the object fetcher).
    private func suggestHits(title: String, year: Int, completion: @escaping ([DoubanSearchHit]) -> Void) {
        if cache.suggestDisabled {
            completion([])
            return
        }
        guard let url = URL(string: "https://movie.douban.com/j/subject_suggest?q=\(title.addingPercentEncoding(withAllowedCharacters: videoStrictQueryAllowed) ?? title)") else {
            completion([])
            return
        }
        let headers = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Referer": "https://movie.douban.com/",
        ]
        call(work: { done in
            self.fetcher(url, headers, 8) { status, body in
                if status == 403 {
                    self.note403()
                    done([])
                    return
                }
                guard let status = status, (200..<300).contains(status),
                      let body = body,
                      let data = body.data(using: .utf8),
                      let decoded = VideoJSON.decode(data) else {
                    self.suggestFails += 1
                    if self.suggestFails >= 3 { self.cache.disableSuggest() }
                    done([])
                    return
                }
                let hits = DoubanParsers.parseSuggestHits(decoded)
                if !hits.isEmpty { self.suggestFails = 0 }
                done(hits)
            }
        }, completion: { hits in completion(hits ?? []) })
    }

    // MARK: - Title → id

    /// Title → Douban id (suggest → desktop search → builtin map).
    /// Cached by title key for 7 days (not permanently).
    func resolveId(title: String, year: Int = 0, completion: @escaping (String?) -> Void) {
        let key = DoubanParsers.titleKey(title)
        if let cached = cache.idForTitle(key: key) {
            completion(cached)
            return
        }
        let base = vodStripSeasonSuffix(title).base
        suggestHits(title: base, year: year) { hits in
            if let id = DoubanParsers.pickSuggestId(hits: hits, title: base, year: year) {
                self.cache.setIdForTitle(key: key, id: id)
                completion(id)
                return
            }
            self.searchPageId(title: base) { pageId in
                if let pageId = pageId, !pageId.isEmpty {
                    self.cache.setIdForTitle(key: key, id: pageId)
                    completion(pageId)
                    return
                }
                let builtin = DoubanParsers.builtinIds[title] ?? DoubanParsers.builtinIds[base]
                if let builtin = builtin {
                    self.cache.setIdForTitle(key: key, id: builtin)
                }
                completion(builtin)
            }
        }
    }

    private func searchPageId(title: String, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "https://www.douban.com/search?cat=1002&q=\(title.addingPercentEncoding(withAllowedCharacters: videoStrictQueryAllowed) ?? title)") else {
            completion(nil)
            return
        }
        let headers = [
            "User-Agent": CmsClient.userAgent,
            "Referer": "https://www.douban.com/",
        ]
        fetchText(url: url, headers: headers, timeout: 10) { html in
            completion(DoubanParsers.parseSearchPageId(html))
        }
    }

    // MARK: - Detail

    /// Full detail flow, race-capped at 15 s (nil on timeout).
    /// Never throws for upstream failures — returns nil. A
    /// year-mismatched detail is never cached and never shown:
    /// the title→id link is dropped so the next open re-resolves.
    func detail(title: String, year: String, completion: @escaping (DoubanDetail?) -> Void) {
        if blocked {
            completion(nil)
            return
        }
        var done = false
        let lock = NSLock()
        func finish(_ value: DoubanDetail?) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            DispatchQueue.main.async { completion(value) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.detailTimeout) {
            finish(nil)
        }
        let strip = vodStripSeasonSuffix(title)
        let base = strip.base
        let wantYear = DoubanParsers.parseYear(year)
        // The CMS year belongs to the full title (a specific
        // season), not to the stripped base series — e.g. 庆余年第二季
        // (2024) resolves to the 庆余年 series entry (2019).
        // Enforce the year only when no season suffix was stripped.
        let useYear = !strip.stripped && wantYear != 0
        resolveId(title: base, year: useYear ? wantYear : 0) { id in
            guard let id = id, !id.isEmpty else {
                finish(nil)
                return
            }
            if let cached = self.cache.detail(id: id) {
                if DoubanParsers.yearsMismatch(gotYear: cached.year, useYear: useYear, wantYear: wantYear) {
                    self.cache.removeIdForTitle(key: DoubanParsers.titleKey(base))
                    self.cache.removeDetail(id: id)
                    self.resolveId(title: base, year: useYear ? wantYear : 0) { id2 in
                        guard let id2 = id2, !id2.isEmpty else {
                            finish(nil)
                            return
                        }
                        if id2 != id, let cached2 = self.cache.detail(id: id2),
                           !DoubanParsers.yearsMismatch(gotYear: cached2.year, useYear: useYear, wantYear: wantYear),
                           !DoubanParsers.photosMissing(cached2) {
                            finish(cached2)
                            return
                        }
                        self.fetchDetail(id: id2, base: base, year: year, useYear: useYear, wantYear: wantYear, finish: finish)
                    }
                    return
                }
                if !DoubanParsers.photosMissing(cached) {
                    finish(cached)
                    return
                }
            }
            self.fetchDetail(id: id, base: base, year: year, useYear: useYear, wantYear: wantYear, finish: finish)
        }
    }

    private func fetchDetail(id: String, base: String, year: String, useYear: Bool, wantYear: Int, finish: @escaping (DoubanDetail?) -> Void) {
        guard let url = URL(string: "https://movie.douban.com/j/subject_abstract?subject_id=\(id)") else {
            finish(nil)
            return
        }
        fetchJSON(url: url, timeout: 10) { json in
            guard let abstract = DoubanParsers.parseAbstract(json) else {
                finish(nil)
                return
            }
            if DoubanParsers.yearsMismatch(gotYear: abstract.year, useYear: useYear, wantYear: wantYear) {
                self.cache.removeIdForTitle(key: DoubanParsers.titleKey(base))
                finish(nil)
                return
            }
            self.fetchMobilePage(id: id, abstract: abstract, base: base, year: year, finish: finish)
        }
    }

    private func fetchMobilePage(id: String, abstract: DoubanDetail, base: String, year: String, finish: @escaping (DoubanDetail?) -> Void) {
        guard let url = URL(string: "https://m.douban.com/movie/subject/\(id)/") else {
            finish(nil)
            return
        }
        let headers = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Referer": "https://movie.douban.com/",
        ]
        fetchText(url: url, headers: headers, timeout: 10) { html in
            let mp = DoubanParsers.parseMPage(html)
            self.fetchCastPhotos(id: id, abstract: abstract, base: base, year: year, poster: mp.poster, overview: mp.overview, score: abstract.score ?? mp.score, finish: finish)
        }
    }

    private func fetchCastPhotos(id: String, abstract: DoubanDetail, base: String, year: String, poster: String, overview: String, score: String?, finish: @escaping (DoubanDetail?) -> Void) {
        // Desktop page (cast avatars) + Baike lookups in parallel;
        // a failed/slow side degrades to [:] and never kills the
        // detail. In production the desktop page is login-walled,
        // so Baike is the common case. Douban photos win when
        // present; Baike fills the rest.
        let group = DispatchGroup()
        var desktopPhotos: [String: String] = [:]
        var baikePhotos: [String: String] = [:]
        group.enter()
        if let url = URL(string: "https://movie.douban.com/subject/\(id)/") {
            let headers = [
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                "Referer": "https://movie.douban.com/",
            ]
            fetchText(url: url, headers: headers, timeout: 6) { html in
                desktopPhotos = DoubanParsers.parseDesktopCast(html)
                group.leave()
            }
        } else {
            group.leave()
        }
        let castNames = abstract.castNames
        if castNames.isEmpty {
            group.notify(queue: .global()) {
                self.assembleDetail(id: id, abstract: abstract, base: base, year: year, poster: poster, overview: overview, score: score, byName: desktopPhotos, finish: finish)
            }
            return
        }
        let photoGroup = DispatchGroup()
        let lock = NSLock()
        for name in castNames {
            photoGroup.enter()
            castPhotoFetcher(name) { photo in
                if !photo.isEmpty {
                    lock.lock()
                    baikePhotos[name] = photo
                    lock.unlock()
                }
                photoGroup.leave()
            }
        }
        photoGroup.notify(queue: .global()) {
            group.notify(queue: .global()) {
                var byName = baikePhotos
                for (name, photo) in desktopPhotos { byName[name] = photo }
                self.assembleDetail(id: id, abstract: abstract, base: base, year: year, poster: poster, overview: overview, score: score, byName: byName, finish: finish)
            }
        }
    }

    private func assembleDetail(id: String, abstract: DoubanDetail, base: String, year: String, poster: String, overview: String, score: String?, byName: [String: String], finish: @escaping (DoubanDetail?) -> Void) {
        let castPhotos = abstract.castNames.map { byName[$0] ?? "" }
        let detail = DoubanDetail(
            id: id,
            media: abstract.media,
            title: abstract.title.isEmpty ? base : abstract.title,
            year: abstract.year ?? (year.isEmpty ? nil : String(year.prefix(4))),
            poster: poster,
            overview: overview,
            score: score,
            genres: abstract.genres,
            runtime: abstract.runtime,
            countries: abstract.countries,
            director: abstract.director,
            castNames: Array(abstract.castNames.prefix(10)),
            castPhotos: castPhotos,
            episodes: abstract.episodes
        )
        cache.setDetail(id: id, detail: detail)
        finish(detail)
    }
}

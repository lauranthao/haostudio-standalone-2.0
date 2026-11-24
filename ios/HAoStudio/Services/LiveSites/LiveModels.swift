// HAo Studio 2.0 — live models + site resolver contract (S4 leg B).
//
// Swift port of the Flutter `LiveRoom` / `LivePlayQuality` /
// `LivePlayUrlResolution` shapes (standalone-app-merge23,
// `lib/core/models/live_models.dart`) trimmed to what the five live
// platforms need: room info, qualities, lines, stream URLs, and the
// danmaku message the five transports deliver.
//
// Scope (chen 2026-11-16): ONLY Bilibili, Douyu, Huya, Douyin,
// Kuaishou. The other 29 Pure Live platforms are never added.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

// MARK: - Platform

/// The five live platforms. `rawValue` is the player-kernel
/// platform id — exactly the five strings
/// `PlayerKernel.httpHeaders(platform:)` recognises (`bili`,
/// `douyu`, `huya`, `douyin`, `ks`); any other value gets no
/// Referer and some CDNs answer 403. `LiveRoom.platform` uses
/// these values.
/// The Flutter site ids (`bilibili`, `kuaishou`, …) differ for two
/// platforms; they live on `flutterSiteId` and are used ONLY for
/// the danmaku settings enabled-map keys, which S1 migrates
/// verbatim from the Flutter Hive box.
enum LivePlatform: String, CaseIterable, Identifiable {
    case bilibili = "bili"
    case douyu = "douyu"
    case huya = "huya"
    case douyin = "douyin"
    case kuaishou = "ks"

    /// ForEach identity: the kernel id (unique per case).
    var id: String { rawValue }

    /// Flutter site id (`lib/shared/platforms/sites.dart`).
    /// Danmaku-settings keys only — never for player headers.
    var flutterSiteId: String {
        switch self {
        case .bilibili:
            return "bilibili"
        case .douyu:
            return "douyu"
        case .huya:
            return "huya"
        case .douyin:
            return "douyin"
        case .kuaishou:
            return "kuaishou"
        }
    }

    var displayName: String {
        switch self {
        case .bilibili:
            return "哔哩哔哩"
        case .douyu:
            return "斗鱼"
        case .huya:
            return "虎牙"
        case .douyin:
            return "抖音"
        case .kuaishou:
            return "快手"
        }
    }

    /// Room page URL for a room id (used for `LiveRoom.link` fallbacks).
    func roomLink(roomId: String) -> String {
        switch self {
        case .bilibili:
            return "https://live.bilibili.com/\(roomId)"
        case .douyu:
            return "https://www.douyu.com/\(roomId)"
        case .huya:
            return "https://www.huya.com/\(roomId)"
        case .douyin:
            return "https://live.douyin.com/\(roomId)"
        case .kuaishou:
            return "https://live.kuaishou.com/u/\(roomId)"
        }
    }
}

// MARK: - Room

/// One live room: identity, presentation fields and the
/// adapter-specific payloads the resolvers and transports need.
///
/// `data` is the play descriptor (Bilibili: real room id; Huya:
/// lines + bit rates; Douyin: `stream_url` map; Kuaishou: `playUrls`;
/// Douyu: unused). `danmakuData` carries the transport credentials
/// (Bilibili token + server urls; Huya uid/topSid/subSid; Douyin
/// webRid/roomId/userId/cookie; Kuaishou liveStreamId; Douyu roomId).
/// Both maps mirror the Flutter `LiveRoom` fields of the same names.
struct LiveRoom {
    var roomId: String
    var platform: LivePlatform
    var title: String
    var streamer: String
    var avatar: String
    var cover: String
    var onlineCount: Int
    var isLive: Bool
    var link: String
    var data: [String: Any]?
    var danmakuData: [String: Any]?

    init(
        roomId: String,
        platform: LivePlatform,
        title: String = "",
        streamer: String = "",
        avatar: String = "",
        cover: String = "",
        onlineCount: Int = 0,
        isLive: Bool = false,
        link: String = "",
        data: [String: Any]? = nil,
        danmakuData: [String: Any]? = nil
    ) {
        self.roomId = roomId
        self.platform = platform
        self.title = title
        self.streamer = streamer
        self.avatar = avatar
        self.cover = cover
        self.onlineCount = onlineCount
        self.isLive = isLive
        self.link = link
        self.data = data
        self.danmakuData = danmakuData
    }
}

// MARK: - Room identity (merge: A + C legs need this)

/// Identity equality for rooms: two rooms are the same room when
/// they share platform + room id. Deliberately NOT a full-field
/// comparison — a room re-fetched from the platform (fresh title /
/// watching count) is still the same room. Lives in this file
/// because the S3 rule is that Hashable/Equatable belong in the
/// file that declares the type, never in an extension elsewhere —
/// and this IS that file. The C leg needs it twice: `LiveRoomPage`
/// is Equatable (its `rooms` must compare) and `LiveDestination`
/// is Hashable (it carries a room + playlist).
extension LiveRoom: Equatable {
    static func == (lhs: LiveRoom, rhs: LiveRoom) -> Bool {
        lhs.roomId == rhs.roomId && lhs.platform == rhs.platform
    }
}

extension LiveRoom: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(roomId)
        hasher.combine(platform)
    }
}

// MARK: - Qualities / lines / resolution

/// One CDN line: a name and the playable stream addresses on it.
/// A line with no urls is an unfilled placeholder (the quality was
/// advertised but its line was not resolved yet).
struct LiveLine: Equatable {
    var name: String
    var urls: [String]
    var format: String

    init(name: String, urls: [String] = [], format: String = "other") {
        self.name = name
        self.urls = urls
        self.format = format
    }
}

/// One quality tier (画质档位): its lines, best first. `sort` orders
/// qualities descending (higher = better); each platform fills it
/// from the server's own ranking, never invented.
struct LiveQuality: Equatable {
    var id: String
    var name: String
    var sort: Int
    var lines: [LiveLine]

    init(id: String, name: String, sort: Int = 0, lines: [LiveLine] = []) {
        self.id = id
        self.name = name
        self.sort = sort
        self.lines = lines
    }
}

/// What `resolve` returns: every quality the server confirmed,
/// with the stream addresses filled in for the applied quality.
///
/// Shape (shared with the A leg's `LiveRoomSession` /
/// `LiveRecovery`): `lines` are the applied quality's lines,
/// `formats` their distinct formats, `qualities` every confirmed
/// tier, `quality` the tier actually applied.
///
/// Quality-echo contract (A leg `requestQualityChange`): when the
/// caller asked for a quality, `quality?.id` is the tier the
/// server actually applied. A mismatch (e.g. Bilibili silently
/// downgrading an anonymous request) is reported as-is — the
/// session sees the mismatch and rolls back — never by
/// fabricating the requested id. A resolve only succeeds when it
/// has playable URLs; no streams at all is a failure, not an
/// empty resolution.
///
/// `issuedAt` is when this resolution was produced; `refreshAt` /
/// `invalidAt` are the signed-URL lease (Huya fills them, the
/// other platforms leave them nil — their URLs hold until a
/// resolve fails).
struct LivePlayUrlResolution {
    var lines: [LiveLine]
    var formats: [String]
    var qualities: [LiveQuality]
    var quality: LiveQuality?
    var issuedAt: Date
    var refreshAt: Date?
    var invalidAt: Date?
    var isLive: Bool

    init(
        lines: [LiveLine] = [],
        formats: [String] = [],
        qualities: [LiveQuality] = [],
        quality: LiveQuality? = nil,
        issuedAt: Date = Date(),
        refreshAt: Date? = nil,
        invalidAt: Date? = nil,
        isLive: Bool = true
    ) {
        self.lines = lines
        // `formats` is derived data: an empty list means "derive
        // from the lines", never "this resolution has no format".
        self.formats = formats.isEmpty ? LivePlayUrlResolution.distinctFormats(of: lines) : formats
        self.qualities = qualities
        self.quality = quality
        self.issuedAt = issuedAt
        self.refreshAt = refreshAt
        self.invalidAt = invalidAt
        self.isLive = isLive
    }

    /// Builds a resolution from the full quality list and the
    /// applied quality (whose `lines` are the resolution lines).
    /// Callers fill the applied quality's lines first.
    static func applying(
        _ applied: LiveQuality?,
        in qualities: [LiveQuality],
        refreshAt: Date? = nil,
        invalidAt: Date? = nil,
        isLive: Bool = true
    ) -> LivePlayUrlResolution {
        let lines = applied?.lines ?? []
        return LivePlayUrlResolution(
            lines: lines,
            formats: distinctFormats(of: lines),
            qualities: qualities,
            quality: applied,
            issuedAt: Date(),
            refreshAt: refreshAt,
            invalidAt: invalidAt,
            isLive: isLive
        )
    }

    static func distinctFormats(of lines: [LiveLine]) -> [String] {
        var seen: [String] = []
        for line in lines where !seen.contains(line.format) {
            seen.append(line.format)
        }
        return seen
    }

    /// All playable urls of the applied quality, deduplicated, in
    /// line order. Falls back to the top-level lines when the
    /// quality object is absent, or when it carries no lines.
    var appliedUrls: [String] {
        let qualityLines = quality?.lines ?? []
        let urls = (qualityLines.isEmpty ? lines : qualityLines).flatMap { $0.urls }
        var seen = Set<String>()
        var result: [String] = []
        for url in urls where seen.insert(url).inserted {
            result.append(url)
        }
        return result
    }
}

// MARK: - Danmaku message

/// One received danmaku line. Receive-only: the app never sends
/// danmaku. `colorArgb` is 0xAARRGGBB (white when the platform
/// sent no colour). `time` is the receive time.
/// `id` is assigned once at construction and survives copies
/// (value copies keep the same UUID), so a row's identity is
/// stable across the list's head-trim: the portrait list keys
/// its rows by this id, never by position. It is a `let` with a
/// default value, so it is NOT a memberwise-init parameter —
/// every existing `DanmakuMessage(...)` call site is unaffected.
struct DanmakuMessage: Identifiable {
    let id = UUID()

    enum Kind {
        case scroll
        case top
        case bottom
    }

    var time: Date
    var userName: String
    var text: String
    var colorArgb: UInt32
    var kind: Kind
    var isSuperChat: Bool
    var suspectedAutomated: Bool

    init(
        time: Date = Date(),
        userName: String = "",
        text: String,
        colorArgb: UInt32 = 0xFFFFFFFF,
        kind: Kind = .scroll,
        isSuperChat: Bool = false,
        suspectedAutomated: Bool = false
    ) {
        self.time = time
        self.userName = userName
        self.text = text
        self.colorArgb = colorArgb
        self.kind = kind
        self.isSuperChat = isSuperChat
        self.suspectedAutomated = suspectedAutomated
    }
}

// MARK: - Errors

/// Failures a resolver or transport reports to its caller. A
/// transport failure never crashes the room — the caller degrades
/// to video-only.
enum LiveError: Error {
    case invalidRoomId
    case offline
    case transportFailed(String)
    case apiRejected(code: Int, message: String)
    case emptyResponse
    case parseFailed(String)
    case unsupported(String)
}

extension LiveError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidRoomId:
            return "房间号为空"
        case .offline:
            return "主播未开播"
        case .transportFailed(let detail):
            return "网络请求失败：\(detail)"
        case .apiRejected(let code, let message):
            return "平台接口拒绝（\(code)）：\(message)"
        case .emptyResponse:
            return "平台返回了空响应"
        case .parseFailed(let detail):
            return "解析失败：\(detail)"
        case .unsupported(let detail):
            return "不支持：\(detail)"
        }
    }
}

// MARK: - Resolver contract (used by the A leg)

/// One platform's room + stream resolver. `resolve` with
/// `quality == nil` fills the default (best) quality's lines;
/// with a quality it fills that tier's lines instead (quality
/// switching — see the echo contract on
/// `LivePlayUrlResolution`: the returned `quality?.id` is the
/// tier actually applied, which the caller compares against the
/// requested id).
/// Implementations never throw out of the completion handler: every
/// failure arrives as `Result.failure`.
protocol LiveSiteResolver {
    var platform: LivePlatform { get }

    func roomInfo(roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void)
    func resolve(roomId: String, quality: LiveQuality?, completion: @escaping (Result<LivePlayUrlResolution, Error>) -> Void)

    /// Resolve from a room the caller already holds (its list-feed
    /// `data`), without a network request. The session tries this
    /// when the network resolve fails with anything but a
    /// definitive offline — e.g. Kuaishou, whose list feeds carry
    /// signed `playUrls` while its room page can be rate-limited.
    /// Default nil: only platforms whose list feeds carry signed
    /// stream URLs implement it.
    func resolutionFromRoom(_ room: LiveRoom, quality: LiveQuality?) -> LivePlayUrlResolution?

    /// The receive-only danmaku transport for this platform,
    /// configured from a room's `danmakuData` at `start` time.
    func makeDanmakuTransport() -> LiveDanmakuTransport
}

extension LiveSiteResolver {
    /// Default-quality resolve (highest available).
    func resolve(roomId: String, completion: @escaping (Result<LivePlayUrlResolution, Error>) -> Void) {
        resolve(roomId: roomId, quality: nil, completion: completion)
    }

    /// Default: no list-feed resolution — the network resolve is
    /// the only source.
    func resolutionFromRoom(_ room: LiveRoom, quality: LiveQuality?) -> LivePlayUrlResolution? {
        nil
    }
}

/// The five resolvers, in the order the live tab lists them.
enum LiveSites {
    static func resolver(for platform: LivePlatform, fetcher: LiveDataFetcher? = nil) -> LiveSiteResolver {
        switch platform {
        case .bilibili:
            return BilibiliLiveSite(fetcher: fetcher)
        case .douyu:
            return DouyuLiveSite(fetcher: fetcher)
        case .huya:
            return HuyaLiveSite(fetcher: fetcher)
        case .douyin:
            return DouyinLiveSite(fetcher: fetcher)
        case .kuaishou:
            return KuaishouLiveSite(fetcher: fetcher)
        }
    }
}

// MARK: - Shared JSON helpers (built on VideoJSON, same module)

enum LiveJSON {
    static func asString(_ value: Any?) -> String {
        VideoJSON.asString(value)
    }

    static func asInt(_ value: Any?) -> Int {
        VideoJSON.asInt(value)
    }

    static func asIntOrNil(_ value: Any?) -> Int? {
        VideoJSON.asIntOrNil(value)
    }

    static func asDouble(_ value: Any?) -> Double {
        VideoJSON.asDouble(value)
    }

    static func asMap(_ value: Any?) -> [String: Any]? {
        VideoJSON.asMap(value)
    }

    static func asList(_ value: Any?) -> [[String: Any]] {
        VideoJSON.asList(value)
    }

    static func asStringList(_ value: Any?) -> [String] {
        VideoJSON.asStringList(value)
    }

    static func decode(_ data: Data) -> Any? {
        VideoJSON.decode(data)
    }

    /// Decode one JSON document that must be an object.
    static func decodeObject(_ data: Data) -> [String: Any]? {
        decode(data) as? [String: Any]
    }
}

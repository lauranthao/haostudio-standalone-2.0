// HAo Studio 2.0 — Emby models + config store (S3 leg B).
//
// Swift port of the Flutter `emby_models.dart`
// (standalone-app-merge23). One Emby server, configured by the
// user in Settings. Credentials live ONLY in the Keychain (see
// KeychainStore) — never in UserDefaults, never in a JSON
// collection file, never in a backup export, never in a log line.
//
// Field names ARE the persisted JSON key names — do not rename
// (migrated data has no migration). The config JSON on disk
// carries the credential fields BLANK: EmbyConfigStore strips
// them on save and fills the active credential from the Keychain
// on load (transient, in memory only).
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation
import Security

// MARK: - Server config

/// One Emby server, as the user typed it in the Emby connect page.
struct EmbyServerConfig: Codable, Equatable {
    var baseUrl: String
    /// API key (fallback credential, advanced settings). Only ever
    /// read by EmbyClient (header / stream URL). Never logged.
    /// On disk this is always blank — the live value comes from
    /// the Keychain (see EmbyConfigStore).
    var apiKey: String
    var userId: String
    var enabled: Bool
    var movieLibraryId: String?
    var tvLibraryId: String?
    var name: String
    var note: String
    /// Account name for password login. Stored (it is the login
    /// name, not a secret); the PASSWORD is never stored — only
    /// the accessToken it was exchanged for.
    var username: String
    /// User token from POST /Users/AuthenticateByName. Empty when
    /// the server was connected with an API key instead. On disk
    /// always blank — the live value comes from the Keychain.
    var accessToken: String
    var deviceId: String
    var serverName: String
    var serverVersion: String
    var reportProgress: Bool
    var strmDirect: Bool
    var fallbackUrls: [String]
    var reminderDays: Int
    var lastPlayedAtMs: Int?
    /// Which API root answered the last successful probe: true =
    /// `/emby` (the official root), false = the bare root. The
    /// client applies it in `init`, so a root-only server keeps
    /// working across the fresh client every gateway call builds
    /// (b35 sweep: the prefix used to live only in the probe's
    /// short-lived client and was lost before the first data call).
    var useEmbyPrefix: Bool

    init(baseUrl: String = "", apiKey: String = "", userId: String = "", enabled: Bool = true,
         movieLibraryId: String? = nil, tvLibraryId: String? = nil, name: String = "Emby",
         note: String = "", username: String = "", accessToken: String = "", deviceId: String = "",
         serverName: String = "", serverVersion: String = "", reportProgress: Bool = true,
         strmDirect: Bool = false, fallbackUrls: [String] = [], reminderDays: Int = 0,
         lastPlayedAtMs: Int? = nil, useEmbyPrefix: Bool = true) {
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.userId = userId
        self.enabled = enabled
        self.movieLibraryId = movieLibraryId
        self.tvLibraryId = tvLibraryId
        self.name = name
        self.note = note
        self.username = username
        self.accessToken = accessToken
        self.deviceId = deviceId
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.reportProgress = reportProgress
        self.strmDirect = strmDirect
        self.fallbackUrls = fallbackUrls
        self.reminderDays = reminderDays
        self.lastPlayedAtMs = lastPlayedAtMs
        self.useEmbyPrefix = useEmbyPrefix
    }

    /// The credential actually sent on API calls and the stream
    /// URL: the account token when logged in, else the API key.
    var authToken: String { accessToken.isEmpty ? apiKey : accessToken }

    /// True when the login came from username + password (a user
    /// token is stored), as opposed to an API key. Decides the 401
    /// wording ("用户名或密码不对" vs "密钥不对").
    var usesPasswordAuth: Bool { !accessToken.isEmpty }

    /// Configured = an address AND at least one credential
    /// (account token or API key). An address with neither does
    /// not qualify.
    var isConfigured: Bool {
        !baseUrl.trimmingCharacters(in: .whitespaces).isEmpty &&
            (!accessToken.trimmingCharacters(in: .whitespaces).isEmpty ||
             !apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Stable random device id (32 hex chars from a secure RNG).
    static func newDeviceId() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if result != errSecSuccess {
            // Fallback: arc4random is still uniform for an opaque id.
            bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Copy with the credential fields blanked (the on-disk form).
    func withoutCredentials() -> EmbyServerConfig {
        var copy = self
        copy.apiKey = ""
        copy.accessToken = ""
        return copy
    }

    // MARK: - Codable (tolerant decode)

    /// Decode with defaults for every field: a legacy config
    /// (build 28: no username / accessToken / deviceId / …) must
    /// still load instead of failing the whole decode. Encoding
    /// stays synthesised (all keys written).
    enum CodingKeys: String, CodingKey {
        case baseUrl, apiKey, userId, enabled, movieLibraryId, tvLibraryId,
             name, note, username, accessToken, deviceId, serverName,
             serverVersion, reportProgress, strmDirect, fallbackUrls,
             reminderDays, lastPlayedAtMs, useEmbyPrefix
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseUrl = try container.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        userId = try container.decodeIfPresent(String.self, forKey: .userId) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        movieLibraryId = try container.decodeIfPresent(String.self, forKey: .movieLibraryId)
        tvLibraryId = try container.decodeIfPresent(String.self, forKey: .tvLibraryId)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Emby"
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
        serverName = try container.decodeIfPresent(String.self, forKey: .serverName) ?? ""
        serverVersion = try container.decodeIfPresent(String.self, forKey: .serverVersion) ?? ""
        reportProgress = try container.decodeIfPresent(Bool.self, forKey: .reportProgress) ?? true
        strmDirect = try container.decodeIfPresent(Bool.self, forKey: .strmDirect) ?? false
        fallbackUrls = try container.decodeIfPresent([String].self, forKey: .fallbackUrls) ?? []
        reminderDays = try container.decodeIfPresent(Int.self, forKey: .reminderDays) ?? 0
        lastPlayedAtMs = try container.decodeIfPresent(Int.self, forKey: .lastPlayedAtMs)
        useEmbyPrefix = try container.decodeIfPresent(Bool.self, forKey: .useEmbyPrefix) ?? true
    }

    // The default struct dump DOES print every field, including
    // apiKey / accessToken — the old comment claimed otherwise.
    // The redacted CustomStringConvertible below is what keeps
    // the credential out of print() / String(describing:); dump()
    // still uses Mirror and still exposes it, so never dump a
    // config. On disk the credential fields are always blank
    // (see EmbyConfigStore).
}

/// Redacted debug description: the credential fields never print.
/// `print(config)` and string interpolation use this; `dump()`
/// bypasses it (Mirror), so a config must never be dumped.
extension EmbyServerConfig: CustomStringConvertible {
    var description: String {
        let key = apiKey.isEmpty ? "(empty)" : "•••"
        let token = accessToken.isEmpty ? "(empty)" : "•••"
        return "EmbyServerConfig(baseUrl: \(baseUrl), username: \(username), userId: \(userId), apiKey: \(key), accessToken: \(token), deviceId: \(deviceId), serverName: \(serverName), enabled: \(enabled))"
    }
}

/// Server address split into the connect page's fields.
/// `parse` accepts a full URL (`https://host:8096/emby`), a bare
/// host (`192.168.1.10`), or host + port (`host:8096`).
/// `compose` builds the stored `baseUrl` back (port always
/// explicit, so the stored shape stays
/// `scheme://host:port[/path]`).
struct EmbyServerAddress: Equatable {
    let useHttps: Bool
    let host: String
    let port: Int
    let path: String

    init(useHttps: Bool, host: String, port: Int, path: String) {
        self.useHttps = useHttps
        self.host = host
        self.port = port
        self.path = path
    }

    static func parse(_ raw: String) -> EmbyServerAddress {
        var text = raw.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("/") { text = String(text.dropLast()) }
        if text.isEmpty {
            return EmbyServerAddress(useHttps: false, host: "", port: 8096, path: "")
        }
        if text.contains("://") {
            if let uri = URL(string: text), let host = uri.host, !host.isEmpty {
                let https = uri.scheme == "https"
                var path = uri.path
                while path.hasSuffix("/") { path = String(path.dropLast()) }
                return EmbyServerAddress(
                    useHttps: https,
                    host: host,
                    port: uri.port ?? (https ? 443 : 8096),
                    path: path == "/" ? "" : path
                )
            }
            return EmbyServerAddress(useHttps: text.hasPrefix("https://"), host: text, port: 8096, path: "")
        }
        var path = ""
        var hostPort = text
        if let slash = text.firstIndex(of: "/") {
            hostPort = String(text[..<slash])
            path = String(text[slash...])
            while path.hasSuffix("/") { path = String(path.dropLast()) }
        }
        var host = hostPort
        var port = 8096
        if let colon = hostPort.lastIndex(of: ":") {
            let after = String(hostPort[hostPort.index(after: colon)...])
            if let parsed = Int(after), parsed > 0 && parsed <= 65535 {
                host = String(hostPort[..<colon])
                port = parsed
            }
        }
        return EmbyServerAddress(useHttps: false, host: host, port: port, path: path)
    }

    /// Build `scheme://host:port[/path]`. Empty host => "" (the
    /// page treats that as "not filled in").
    static func compose(useHttps: Bool, host: String, port: Int, path: String) -> String {
        let h = host.trimmingCharacters(in: .whitespaces)
        if h.isEmpty { return "" }
        var p = path.trimmingCharacters(in: .whitespaces)
        while p.hasSuffix("/") { p = String(p.dropLast()) }
        if !p.isEmpty && !p.hasPrefix("/") { p = "/\(p)" }
        return "\(useHttps ? "https" : "http")://\(h):\(port)\(p)"
    }

    var baseUrl: String {
        EmbyServerAddress.compose(useHttps: useHttps, host: host, port: port, path: path)
    }
}

// MARK: - Auth / probe results

/// Outcome of `authenticateByName`: ok + the token and user id to
/// store, or a human-readable failure (same tiers as the probe).
struct EmbyAuthResult {
    let ok: Bool
    /// User token to store (never the password — the password is
    /// only ever sent in the AuthenticateByName body, once).
    let accessToken: String
    let userId: String
    let userName: String
    let errorKind: EmbyErrorKind?
    let errorMessage: String

    init(ok: Bool, accessToken: String = "", userId: String = "", userName: String = "",
         errorKind: EmbyErrorKind? = nil, errorMessage: String = "") {
        self.ok = ok
        self.accessToken = accessToken
        self.userId = userId
        self.userName = userName
        self.errorKind = errorKind
        self.errorMessage = errorMessage
    }
}

/// Outcome of `probe`: ok + server identity + users, or a
/// human-readable failure (three tiers, never the CMS wording).
struct EmbyProbeResult {
    let ok: Bool
    let serverName: String
    let version: String
    /// Users returned by GET /Users. Single user = auto-take;
    /// multiple = Settings shows the picker; none = config error.
    let users: [EmbyUser]
    let errorKind: EmbyErrorKind?
    let errorMessage: String
    /// The base URL that actually answered (main address or one of
    /// the fallback lines). "" when nothing answered.
    let workingBaseUrl: String
    /// The API prefix that answered (`/emby` vs the bare root).
    /// The config page persists it so data calls start on the
    /// working prefix instead of re-discovering it per client.
    let useEmbyPrefix: Bool

    init(ok: Bool, serverName: String = "", version: String = "", users: [EmbyUser] = [],
         errorKind: EmbyErrorKind? = nil, errorMessage: String = "", workingBaseUrl: String = "",
         useEmbyPrefix: Bool = true) {
        self.ok = ok
        self.serverName = serverName
        self.version = version
        self.users = users
        self.errorKind = errorKind
        self.errorMessage = errorMessage
        self.workingBaseUrl = workingBaseUrl
        self.useEmbyPrefix = useEmbyPrefix
    }
}

/// Failure tiers for Emby requests. The message wording is fixed
/// at the throw site so probe / list / detail can never drift
/// apart — and so the CMS wording is never reused for Emby.
enum EmbyErrorKind: Equatable {
    /// Connection refused / DNS / timeout: address wrong or server down.
    case unreachable
    /// HTTP 401: the key is wrong.
    case unauthorized
    /// HTTP 404: the addressed item/library is gone.
    case notFound
    /// Anything else (5xx, bad JSON, unknown item type).
    case other
}

/// Human failure text, one per tier. Three tiers, never the CMS
/// wording, never the raw URL or key.
struct EmbyError: Error, Equatable {
    let kind: EmbyErrorKind
    let message: String

    static func unreachable() -> EmbyError {
        EmbyError(kind: .unreachable, message: "连不上 Emby 服务器，检查地址和网络")
    }

    static func unauthorized() -> EmbyError {
        EmbyError(kind: .unauthorized, message: "Emby 密钥不对，请在设置里重新填写")
    }

    /// 401 on a password login: the account name or the password
    /// is wrong (never "the key" — there is no key in this mode).
    static func unauthorizedAccount() -> EmbyError {
        EmbyError(kind: .unauthorized, message: "Emby 用户名或密码不对，请重新登录")
    }

    static func notFound(_ message: String? = nil) -> EmbyError {
        EmbyError(kind: .notFound, message: message ?? "在 Emby 里没有找到这个内容")
    }

    static func other(_ message: String) -> EmbyError {
        EmbyError(kind: .other, message: message)
    }
}

// MARK: - Library / user / user data

/// One Emby library (View): only `movies` / `tvshows` are kept
/// for pin resolution, but the list itself returns ALL libraries.
struct EmbyLibrary: Equatable {
    let id: String
    let name: String
    let collectionType: String

    var isMovieLibrary: Bool { collectionType == "movies" }
    var isTvLibrary: Bool { collectionType == "tvshows" }

    static func fromJSON(_ json: [String: Any]) -> EmbyLibrary {
        EmbyLibrary(
            id: VideoJSON.asString(json["Id"]),
            name: VideoJSON.asString(json["Name"]),
            collectionType: VideoJSON.asString(json["CollectionType"])
        )
    }
}

/// One Emby user, as returned by GET /Users.
struct EmbyUser: Equatable {
    let id: String
    let name: String

    static func fromJSON(_ json: [String: Any]) -> EmbyUser {
        EmbyUser(id: VideoJSON.asString(json["Id"]), name: VideoJSON.asString(json["Name"]))
    }
}

/// One item's server-side user data (the `UserData` object Emby
/// returns on item queries when `UserData` is in `Fields`).
/// Missing fields stay at their "never watched" defaults, never
/// throw.
struct EmbyUserData: Equatable {
    var playbackPositionSeconds: Double
    var playedPercentage: Double
    var played: Bool
    var isFavorite: Bool
    var likes: Bool?

    init(playbackPositionSeconds: Double = 0, playedPercentage: Double = 0,
         played: Bool = false, isFavorite: Bool = false, likes: Bool? = nil) {
        self.playbackPositionSeconds = playbackPositionSeconds
        self.playedPercentage = playedPercentage
        self.played = played
        self.isFavorite = isFavorite
        self.likes = likes
    }

    static func fromJSON(_ json: Any?) -> EmbyUserData {
        guard let json = json as? [String: Any] else { return EmbyUserData() }
        let ticks = VideoJSON.asDouble(json["PlaybackPositionTicks"])
        let pct = json["PlayedPercentage"] as? NSNumber
        return EmbyUserData(
            playbackPositionSeconds: ticks > 0 ? ticks / Double(EmbyClient.ticksPerSecond) : 0,
            playedPercentage: pct != nil ? min(1, max(0, pct!.doubleValue / 100)) : 0,
            played: (json["Played"] as? Bool) ?? false,
            isFavorite: (json["IsFavorite"] as? Bool) ?? false,
            likes: json["Likes"] as? Bool
        )
    }
}

/// One page of library items.
struct EmbyItemsPage {
    let items: [VideoItem]
    let totalCount: Int
}

/// One episode with its stream facts (container/codecs), so
/// detail can tag the episode's stream URL for the kernel's
/// engine gate.
struct EmbyEpisode {
    let item: VideoItem
    /// Nil when the episode carries no MediaSources (old server,
    /// or the field was dropped) — the stream URL is then unmarked
    /// and the kernel falls back to the unknown-format behaviour.
    let facts: EmbyStreamFacts?
    /// Skip-intro/outro markers parsed from the episode's
    /// `Chapters`. Nil = the server returned no chapters.
    let markers: EmbySkipMarkers?
}

/// Skip-intro/outro markers from an item's `Chapters` (IntroSkip
/// plugin: IntroStart/IntroEnd/CreditsStart). Servers without the
/// plugin return an empty array or no field; the parser treats
/// that as "no markers".
struct EmbySkipMarkers: Equatable {
    let introStart: Double?
    let introEnd: Double?
    let creditsStart: Double?

    static func fromChapters(_ chapters: Any?) -> EmbySkipMarkers? {
        guard let list = chapters as? [Any] else { return nil }
        var introStart: Double?
        var introEnd: Double?
        var creditsStart: Double?
        for entry in list {
            guard let chapter = entry as? [String: Any] else { continue }
            let name = VideoJSON.asString(chapter["Name"])
            let start = (chapter["StartPositionTicks"] as? NSNumber)?.doubleValue
            guard let start = start else { continue }
            let seconds = start / Double(EmbyClient.ticksPerSecond)
            if name == "IntroStart" { introStart = seconds }
            if name == "IntroEnd" { introEnd = seconds }
            if name == "CreditsStart" { creditsStart = seconds }
        }
        if introStart == nil && introEnd == nil && creditsStart == nil { return nil }
        return EmbySkipMarkers(introStart: introStart, introEnd: introEnd, creditsStart: creditsStart)
    }
}

// MARK: - Stream facts

/// Container / codec facts for one Emby file, parsed from its
/// `MediaSources[0]` (detail requests ask for `MediaSources`).
///
/// Feeds the kernel's engine gate: the facts ride the stream URL
/// as `hao_*` query markers (see EmbyClient.streamUrl) because
/// the URL itself has no suffix for the kernel to read. Only the
/// DEFAULT audio track's codec is kept — an optional TrueHD track
/// next to an AAC default still plays on every engine.
///
/// (Build 36, item 14, G-B) Subtitle / multi-audio facts are
/// parsed too: ASS subtitles and multi-audio force MPV-first
/// routing, and external subtitle streams ride as `hao_extsub`
/// so the driver can `sub-add` them on MPV (G-G).
struct EmbySubtitleStream: Equatable {
    /// `MediaStreams[].Index` — the value for the Subtitles URL.
    let index: Int
    let codec: String?
    let language: String?
    let isExternal: Bool
    let isDefault: Bool
}

struct EmbyStreamFacts: Equatable {
    var container: String?
    var videoCodec: String?
    var audioCodec: String?
    var dolbyVision: Bool
    var dvProfile: Int?
    var dvCompatId: Int?
    var width: Int?
    var height: Int?
    var bitRate: Int?
    var size: Int?
    var sourcePath: String?
    /// ASS/SSA subtitles are present (embedded or external).
    var hasAssSubtitles: Bool
    /// Any subtitle track is present.
    var hasSubtitleTracks: Bool
    /// Two or more audio tracks are present.
    var hasMultipleAudioTracks: Bool
    /// Audio-track count (for the `hao_atracks` marker).
    var audioTrackCount: Int
    /// Codec of the first subtitle track (for the `hao_sub`
    /// marker when it is not ASS).
    var subtitleCodec: String?
    /// Server-external subtitle streams (to `sub-add` on MPV).
    var externalSubtitles: [EmbySubtitleStream]
    /// `MediaSources[0].Id` — needed to build the subtitle URL.
    var mediaSourceId: String?

    init(container: String? = nil, videoCodec: String? = nil, audioCodec: String? = nil,
         dolbyVision: Bool = false, dvProfile: Int? = nil, dvCompatId: Int? = nil,
         width: Int? = nil, height: Int? = nil, bitRate: Int? = nil, size: Int? = nil,
         sourcePath: String? = nil, hasAssSubtitles: Bool = false,
         hasSubtitleTracks: Bool = false, hasMultipleAudioTracks: Bool = false,
         audioTrackCount: Int = 0, subtitleCodec: String? = nil,
         externalSubtitles: [EmbySubtitleStream] = [], mediaSourceId: String? = nil) {
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.dolbyVision = dolbyVision
        self.dvProfile = dvProfile
        self.dvCompatId = dvCompatId
        self.width = width
        self.height = height
        self.bitRate = bitRate
        self.size = size
        self.sourcePath = sourcePath
        self.hasAssSubtitles = hasAssSubtitles
        self.hasSubtitleTracks = hasSubtitleTracks
        self.hasMultipleAudioTracks = hasMultipleAudioTracks
        self.audioTrackCount = audioTrackCount
        self.subtitleCodec = subtitleCodec
        self.externalSubtitles = externalSubtitles
        self.mediaSourceId = mediaSourceId
    }

    /// Parse the first media source of an item detail document.
    /// Missing / malformed MediaSources => empty facts (the old
    /// unknown-format behaviour: every engine is tried).
    ///
    /// Dolby Vision detection: the key names below are the ones a
    /// real Emby 4.8.4 server returns in MediaStreams
    /// (`VideoRange: DolbyVision`, `ExtendedVideoType:
    /// DolbyVision`, `ExtendedVideoSubType: DoviProfile81`). The
    /// old `VideoRangeType` read is kept as a fallback — never the
    /// only signal.
    static func fromMediaSources(_ mediaSources: Any?) -> EmbyStreamFacts {
        guard let list = mediaSources as? [Any] else { return EmbyStreamFacts() }
        var source: [String: Any]?
        for entry in list {
            if let map = entry as? [String: Any] {
                source = map
                break
            }
        }
        guard let source = source else { return EmbyStreamFacts() }
        let container = (VideoJSON.asString(source["Container"]).isEmpty ? nil : VideoJSON.asString(source["Container"]).lowercased())
        let streams = VideoJSON.asList(source["MediaStreams"])
        var video: [String: Any]?
        for stream in streams where VideoJSON.asString(stream["Type"]) == "Video" {
            video = stream
            break
        }
        let audioStreams = streams.filter { VideoJSON.asString($0["Type"]) == "Audio" }
        var audio: [String: Any]?
        for stream in audioStreams where (stream["IsDefault"] as? Bool) == true {
            audio = stream
            break
        }
        if audio == nil { audio = audioStreams.first }
        var dvProfile: Int?
        var dvCompatId: Int?
        if let subType = video?["ExtendedVideoSubType"] as? String {
            let lower = subType.lowercased()
            if let re = try? NSRegularExpression(pattern: "doviprofile([0-9])([0-9])?", options: []),
               let m = re.firstMatch(in: lower, options: [], range: NSRange(lower.startIndex..., in: lower)),
               m.numberOfRanges > 1, let r1 = Range(m.range(at: 1), in: lower) {
                dvProfile = Int(lower[r1])
                if m.numberOfRanges > 2, let r2 = Range(m.range(at: 2), in: lower), !lower[r2].isEmpty {
                    dvCompatId = Int(lower[r2])
                }
            }
        }
        func isDv(_ value: String?) -> Bool {
            guard let value = value else { return false }
            let v = value.lowercased()
            return v.contains("dolbyvision") || v.contains("dovi")
        }
        let dolbyVision = dvProfile != nil ||
            isDv(video?["ExtendedVideoType"] as? String) ||
            isDv(video?["VideoRange"] as? String) ||
            isDv(video?["VideoRangeType"] as? String)
        // (Build 36, item 14, G-B) Subtitle / multi-audio facts.
        // `Type == "Subtitle"` streams were skipped entirely
        // before this: an MP4+ASS file went AVPlayer-first and
        // played video with NO subtitles — silently wrong, not
        // an error. ASS/SSA forces MPV-first routing; external
        // streams are described so the driver can `sub-add` them.
        let subtitleStreams = streams.filter { VideoJSON.asString($0["Type"]) == "Subtitle" }
        var hasAssSubtitles = false
        var subtitleCodec: String?
        var externalSubtitles: [EmbySubtitleStream] = []
        for stream in subtitleStreams {
            let codec = VideoJSON.asString(stream["Codec"]).lowercased()
            if codec == "ass" || codec == "ssa" { hasAssSubtitles = true }
            if subtitleCodec == nil && !codec.isEmpty { subtitleCodec = codec }
            let isExternal = (stream["IsExternal"] as? Bool) ?? false
            if isExternal {
                let language = VideoJSON.asString(stream["Language"])
                externalSubtitles.append(EmbySubtitleStream(
                    index: VideoJSON.asIntOrNil(stream["Index"]) ?? 0,
                    codec: codec.isEmpty ? nil : codec,
                    language: language.isEmpty ? nil : language,
                    isExternal: true,
                    isDefault: (stream["IsDefault"] as? Bool) ?? false
                ))
            }
        }
        return EmbyStreamFacts(
            container: container,
            videoCodec: {
                let c = VideoJSON.asString(video?["Codec"])
                return c.isEmpty ? nil : c.lowercased()
            }(),
            audioCodec: {
                let c = VideoJSON.asString(audio?["Codec"])
                return c.isEmpty ? nil : c.lowercased()
            }(),
            dolbyVision: dolbyVision,
            dvProfile: dvProfile,
            dvCompatId: dvCompatId,
            width: VideoJSON.asIntOrNil(video?["Width"]),
            height: VideoJSON.asIntOrNil(video?["Height"]),
            bitRate: VideoJSON.asIntOrNil(video?["BitRate"]),
            size: VideoJSON.asIntOrNil(source["Size"]),
            sourcePath: {
                let p = VideoJSON.asString(source["Path"])
                return p.isEmpty ? nil : p
            }(),
            hasAssSubtitles: hasAssSubtitles,
            hasSubtitleTracks: !subtitleStreams.isEmpty,
            hasMultipleAudioTracks: audioStreams.count >= 2,
            audioTrackCount: audioStreams.count,
            subtitleCodec: subtitleCodec,
            externalSubtitles: externalSubtitles,
            mediaSourceId: {
                let id = VideoJSON.asString(source["Id"])
                return id.isEmpty ? nil : id
            }()
        )
    }

    var isEmpty: Bool {
        container == nil && videoCodec == nil && audioCodec == nil &&
            !dolbyVision && dvProfile == nil && width == nil &&
            height == nil && bitRate == nil && size == nil &&
            !hasAssSubtitles && !hasSubtitleTracks &&
            !hasMultipleAudioTracks && externalSubtitles.isEmpty &&
            mediaSourceId == nil
    }

    /// `hao_*` query markers for the stream URL. Empty when there
    /// is nothing to say (the URL stays exactly as before).
    func toQueryParams() -> [String: String] {
        if isEmpty { return [:] }
        var params: [String: String] = [:]
        if let container = container, !container.isEmpty { params["hao_container"] = container }
        if let videoCodec = videoCodec, !videoCodec.isEmpty { params["hao_vcodec"] = videoCodec }
        if let audioCodec = audioCodec, !audioCodec.isEmpty { params["hao_acodec"] = audioCodec }
        if dolbyVision { params["hao_dv"] = "1" }
        if dolbyVision, let dvProfile = dvProfile {
            params["hao_dvprofile"] = dvCompatId != nil ? "\(dvProfile).\(dvCompatId!)" : "\(dvProfile)"
        }
        if let width = width { params["hao_width"] = "\(width)" }
        if let height = height { params["hao_height"] = "\(height)" }
        if let bitRate = bitRate { params["hao_bitrate"] = "\(bitRate)" }
        if let size = size { params["hao_size"] = "\(size)" }
        // (Build 36, item 14, G-B) Subtitle / track markers on the
        // same established `hao_*` channel; Emby ignores unknown
        // query params. `hao_sub` is the subtitle codec (`ass` /
        // `srt` / `vtt` / `pgs`); `hao_atracks` the audio-track
        // count; `hao_extsub` the external subtitle list
        // (`index:codec:language`, comma-joined) with `hao_msrc`
        // the media-source id for the subtitle URL.
        if hasAssSubtitles {
            params["hao_sub"] = "ass"
        } else if let subtitleCodec = subtitleCodec, !subtitleCodec.isEmpty {
            params["hao_sub"] = subtitleCodec
        }
        if audioTrackCount > 0 { params["hao_atracks"] = "\(audioTrackCount)" }
        if !externalSubtitles.isEmpty {
            let list = externalSubtitles.map { sub in
                "\(sub.index):\(sub.codec ?? ""):\(sub.language ?? "")"
            }.joined(separator: ",")
            params["hao_extsub"] = list
            if let mediaSourceId = mediaSourceId, !mediaSourceId.isEmpty {
                params["hao_msrc"] = mediaSourceId
            }
        }
        return params
    }
}

// MARK: - Synopsis dedupe (build 31 regression)

/// Collapse a synopsis that repeats itself. Some servers return an
/// Overview whose paragraphs repeat (and the old detail page
/// rendered the same Overview twice — once in the header, once at
/// the bottom). The service layer guarantees the text it hands out
/// contains no repeated paragraph and is never the same text
/// doubled: exact-duplicate paragraphs are dropped (first copy
/// kept), and a whole text that is exactly two copies of itself
/// is halved. Distinct paragraphs are preserved untouched.
///
/// This is the Swift-side regression test target for the build-31
/// "剧情介绍重复" fix: the synopsis is carried in exactly one
/// field (`VideoMeta.synopsis`) and the text itself is deduped
/// here, so no layer can show it twice.
enum EmbySynopsis {
    static func dedupe(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        // Whole text doubled ("X<ws>X", any whitespace between the
        // copies): collapse to one copy.
        if let re = try? NSRegularExpression(pattern: "^(?s)(.+)\\s+\\1$", options: []),
           let m = re.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)),
           m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: trimmed) {
            return String(trimmed[r])
        }
        // Repeated paragraphs (split on blank lines, keep order).
        let paragraphs = trimmed.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if paragraphs.count <= 1 { return trimmed }
        var seen = Set<String>()
        var kept: [String] = []
        for paragraph in paragraphs {
            if seen.insert(paragraph).inserted {
                kept.append(paragraph)
            }
        }
        return kept.joined(separator: "\n")
    }
}

// MARK: - Config store

/// Fault-tolerant read/write of the Emby config (same pattern as
/// VideoSourceStore: uninitialised / bad JSON = "not configured",
/// never a throw into the UI).
///
/// The on-disk JSON (`hao_emby_config` collection) NEVER carries
/// the credential: save strips `apiKey` / `accessToken` and puts
/// the active credential in the Keychain; load fills the active
/// credential back from the Keychain (transient, in memory only).
enum EmbyConfigStore {
    static let collectionName = "hao_emby_config"

    static func load() -> EmbyServerConfig? {
        let stored: EmbyServerConfig? = LocalStore.loadCollection(named: collectionName, default: nil)
        guard var config = stored, !config.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        // The Keychain holds the single active credential
        // (migration wrote the apiKey there; a password login
        // overwrites it with the user token). The on-disk JSON
        // carries BOTH credential fields blank, so the field is
        // recovered from the persisted user id: a password login
        // always returns one (AuthenticateByName fails without
        // it), key auth never sets one. The old code keyed on the
        // (always blank) stored accessToken, so the branch was
        // dead and every token landed in `apiKey` — the 401
        // wording then said "密钥不对" for password users and the
        // token showed in the API-key field (b35 sweep).
        if let key = KeychainStore.loadEmbyApiKey(), !key.isEmpty {
            if !config.userId.isEmpty {
                // A stored user id means the last login was by
                // password; the Keychain value IS that token.
                config.accessToken = key
            } else {
                config.apiKey = key
            }
        }
        return config
    }

    /// Returns false when the write failed (caller keeps the
    /// in-memory value; the UI never throws for a storage
    /// failure). The credential goes to the Keychain, never to
    /// the JSON file.
    @discardableResult
    static func save(_ config: EmbyServerConfig) -> Bool {
        let credential = config.authToken
        // JSON first, Keychain second: the old order wrote the
        // credential to the Keychain and then the JSON, so a
        // failed JSON write left a live credential for a config
        // the file never recorded — and a failed Keychain write
        // after a JSON write left the file claiming a credential
        // the Keychain does not hold. Either way the two stores
        // disagree. Now a failed JSON write returns before the
        // Keychain is touched, and a failed Keychain write
        // restores the previous JSON (or an empty config when
        // there was none) before returning false.
        let previous = load()
        guard LocalStore.saveCollection(named: collectionName, value: config.withoutCredentials()) else { return false }
        if !credential.isEmpty {
            guard KeychainStore.saveEmbyApiKey(credential) else {
                if let previous = previous {
                    LocalStore.saveCollection(named: collectionName, value: previous.withoutCredentials())
                } else {
                    LocalStore.saveCollection(named: collectionName, value: EmbyServerConfig())
                }
                return false
            }
        }
        return true
    }

    static func clear() {
        // An empty config reads back as "not configured" (load
        // returns nil for a blank baseUrl); the Keychain item goes
        // with it.
        LocalStore.saveCollection(named: collectionName, value: EmbyServerConfig())
        _ = KeychainStore.deleteEmbyApiKey()
    }
}

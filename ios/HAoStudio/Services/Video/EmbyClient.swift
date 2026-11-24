// HAo Studio 2.0 — Emby client (S3 leg B).
//
// Swift port of the Flutter `emby_client.dart`
// (standalone-app-merge23). Direct, no server in the middle.
//
// Auth, two modes, one credential on the wire:
// - Username + password (primary): POST /Users/AuthenticateByName
//   exchanges the password for an AccessToken + User Id; the token
//   is stored, the PASSWORD IS NEVER STORED.
// - API key (fallback, advanced settings): the old X-Emby-Token.
// Whichever is present rides as `X-Emby-Token` on every API call
// and as `api_key` on the stream URL. The key enters a URL only in
// the three stream builders (`streamUrl`, `subtitleUrl`,
// `transcodedHlsUrl`) and their static from-URL rebuilders —
// because the native player kernels take a bare URL and no custom
// headers — always through `queryValue`, never raw. A URL carrying
// the key is never logged, never put in an exception message, and
// never used as a cache key: image URLs carry no key at all (header
// auth only, see `imageHeaders` / `imageUrl`), and the recovery
// ladder keys attempts on the redacted URL (see `redactedURL`).
//
// API root prefix: the official API lives under `/emby`
// (http://host:8096/emby/...), but some deployments answer at the
// root. `probe` tries `/emby` first, then the root, and remembers
// which worked; data calls use the remembered prefix (default
// `/emby` until a probe has run). The baseUrl itself is NEVER
// force-upgraded to https: a plain-http LAN address is a legal
// setup.
//
// P0-10: movie / TV plus Genres classification (`byGenre`);
// synopsis dedupe regression (see EmbySynopsis in EmbyModels).
//
// Server-side progress reporting / played-marking / favorites /
// rating landed against the official Emby API endpoints —
// endpoint names/shapes verified against the Emby Server API
// listing, but the exact request binding is still unvalidated
// against a real server: every mutating call is best-effort
// (false on any failure, never thrown into playback).
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Transport types

/// Raw HTTP result handed to the client by the fetcher. The client
/// owns status mapping, so tests can drive every tier with canned
/// statuses and no network.
struct EmbyResponse {
    let statusCode: Int
    let json: Any?
    /// True when the transport failed with URLError.timedOut
    /// (not a refused/DNS failure): the client maps it to
    /// .timedOut instead of .unreachable. Defaults false so
    /// canned test responses keep working unchanged.
    let timedOut: Bool

    init(statusCode: Int, json: Any?, timedOut: Bool = false) {
        self.statusCode = statusCode
        self.json = json
        self.timedOut = timedOut
    }
}

/// Fetch one Emby JSON document. Never throws for an HTTP status —
/// the status rides in EmbyResponse for the client to map.
/// Transport failures (refused / DNS) become EmbyError.unreachable;
/// a timeout becomes EmbyError.timedOut (see EmbyResponse.timedOut).
/// The URL is never included in the message.
typealias EmbyFetcher = (URL, [String: String], TimeInterval, @escaping (EmbyResponse) -> Void) -> Void

/// Mutating Emby request (POST/DELETE): method + full URL + auth
/// headers + optional JSON body. Returns the status + decoded JSON
/// without throwing for an HTTP status (like EmbyFetcher). The API
/// key NEVER enters the URL here — auth rides the header. (The key
/// does enter URLs, but only in the stream / subtitle / transcode
/// builders, which are not built by this path.)
typealias EmbyMutator = (String, URL, [String: String], [String: Any]?, TimeInterval, @escaping (EmbyResponse) -> Void) -> Void

enum EmbyTransport {
    /// Production fetcher over the shared URLSession.
    static func fetch(url: URL, headers: [String: String], timeout: TimeInterval, completion: @escaping (EmbyResponse) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let urlError = error as? URLError, urlError.code == .timedOut {
                completion(EmbyResponse(statusCode: 0, json: nil, timedOut: true))
                return
            }
            if error != nil {
                completion(EmbyResponse(statusCode: 0, json: nil))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var json: Any?
            if let data = data, !data.isEmpty {
                json = VideoJSON.decode(data)
            }
            completion(EmbyResponse(statusCode: status, json: json))
        }
        task.resume()
    }

    /// Production mutator over the shared URLSession.
    static func mutate(method: String, url: URL, headers: [String: String], jsonBody: [String: Any]?, timeout: TimeInterval, completion: @escaping (EmbyResponse) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if jsonBody != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let jsonBody = jsonBody {
            request.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody, options: [])
        }
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let urlError = error as? URLError, urlError.code == .timedOut {
                completion(EmbyResponse(statusCode: 0, json: nil, timedOut: true))
                return
            }
            if error != nil {
                completion(EmbyResponse(statusCode: 0, json: nil))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var json: Any?
            if let data = data, !data.isEmpty {
                json = VideoJSON.decode(data)
            }
            completion(EmbyResponse(statusCode: status, json: json))
        }
        task.resume()
    }
}

// MARK: - Client

/// Emby client. Parallel to CmsClient, NOT a subclass of it: the
/// protocol shape, the category system (Views → Movie/Series →
/// Season → Episode) and the failure surface (address / key /
/// userId) are all different.
final class EmbyClient {
    /// The source id every Emby item/detail/history row carries.
    /// CMS source ids are ints, so 'emby' can never collide.
    static let sourceId = "emby"

    /// .NET ticks per second: Emby positions are 100-ns ticks.
    static let ticksPerSecond = 10_000_000

    /// Seconds → ticks (for progress reports).
    static func ticksFromSeconds(_ seconds: Double) -> Int {
        Int((seconds * Double(ticksPerSecond)).rounded())
    }

    /// The episode/item id inside one of our own stream URLs
    /// (`.../Videos/<id>/stream?...`), or nil when the URL is not
    /// one of ours. Lets the player report progress for the episode
    /// actually playing without carrying a separate id through the
    /// page. Never throws.
    static func episodeIdFromStreamUrl(_ url: String) -> String? {
        guard let parsed = URL(string: url) else { return nil }
        let path = parsed.path
        guard let re = try? NSRegularExpression(pattern: "/Videos/([^/]+)/stream", options: []),
              let m = re.firstMatch(in: path, options: [], range: NSRange(path.startIndex..., in: path)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: path) else { return nil }
        let id = String(path[r])
        if id.isEmpty { return nil }
        return id.removingPercentEncoding ?? id
    }

    /// The episode/item id inside one of our own Emby playback
    /// URLs — the direct stream (`.../Videos/<id>/stream?...`)
    /// or the HLS transcode master playlist
    /// (`.../Videos/<id>/master.m3u8?...`) — or nil when the URL
    /// is not one of ours. Used ONLY by the driver's
    /// `currentEmbyItemId()`: after the transcode last resort
    /// opens, the current URL is the master playlist, and the
    /// direct-only `episodeIdFromStreamUrl` cannot see an id in
    /// it, so the reporting session would never start. Never
    /// throws.
    static func episodeIdFromEmbyPlaybackUrl(_ url: String) -> String? {
        guard let parsed = URL(string: url) else { return nil }
        let path = parsed.path
        guard let re = try? NSRegularExpression(pattern: "/Videos/([^/]+)/(?:stream|master\\.m3u8)", options: []),
              let m = re.firstMatch(in: path, options: [], range: NSRange(path.startIndex..., in: path)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: path) else { return nil }
        let id = String(path[r])
        if id.isEmpty { return nil }
        return id.removingPercentEncoding ?? id
    }

    /// Fields requested on item queries. MediaSources is
    /// deliberately absent: the v1 stream URL is built directly
    /// (static=true), and list payloads stay small without it.
    /// People + RecursiveItemCount ride here too: the detail page
    /// shows 导演/主演 from People, and the series poster badge
    /// shows the episode total from RecursiveItemCount.
    static let itemFields =
        "Overview,Genres,ProductionYear,CommunityRating,RunTimeTicks," +
        "ChildCount,RecursiveItemCount,People,ImageTags," +
        "PrimaryImageAspectRatio,UserData"

    /// Detail fields: item fields + MediaSources (container /
    /// codecs / Dolby Vision — the facts the kernel's engine gate
    /// reads) + Chapters (IntroStart/IntroEnd/CreditsStart skip
    /// markers).
    static let detailFields = itemFields + ",MediaSources,Chapters"

    private(set) var config: EmbyServerConfig
    private let fetcher: EmbyFetcher
    private let mutator: EmbyMutator

    /// Set by probe / ensureApiRoot; default true = try `/emby`
    /// first (the official API root). `init` seeds it from the
    /// stored config (`useEmbyPrefix`, persisted by the last
    /// successful probe) so a root-only server is not re-tried on
    /// `/emby` by every fresh client the gateway builds.
    private(set) var useEmbyPrefix = true

    /// Temporary base-URL override, used only while one probe /
    /// login attempt tries a fallback line. Always cleared in a
    /// finally (see probeBase / authenticateByName) so data calls
    /// can never accidentally use a fallback address.
    private var baseOverride: String?

    var isConfigured: Bool { config.isConfigured }

    init(config: EmbyServerConfig, fetcher: EmbyFetcher? = nil, mutator: EmbyMutator? = nil) {
        self.config = config
        self.useEmbyPrefix = config.useEmbyPrefix
        self.fetcher = fetcher ?? EmbyTransport.fetch
        self.mutator = mutator ?? EmbyTransport.mutate
    }

    /// Replace the config (e.g. after a successful login fills in
    /// the token + user id). The Keychain write itself is the
    /// caller's job (EmbyConfigStore.save).
    func updateConfig(_ config: EmbyServerConfig) {
        self.config = config
        self.useEmbyPrefix = config.useEmbyPrefix
    }

    private var base: String {
        var base = (baseOverride ?? config.baseUrl).trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base = String(base.dropLast()) }
        return base
    }

    /// Account token when logged in, else the API key.
    private var authHeaders: [String: String] {
        ["X-Emby-Token": config.authToken]
    }

    /// Image auth headers: the image URL itself stays clean (no
    /// api_key), so it can be a cache key safely.
    var imageHeaders: [String: String] { authHeaders }

    private func apiUrl(_ path: String) -> URL? {
        URL(string: base + (useEmbyPrefix ? "/emby" : "") + path)
    }

    private func apiQuery(_ path: String, query: [String: String]) -> URL? {
        guard var components = URLComponents(string: base + (useEmbyPrefix ? "/emby" : "") + path) else { return nil }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }

    // MARK: URL builders (pure)

    /// Poster/detail image URL. No api_key in the URL — auth rides
    /// the header (`imageHeaders`). `tag` is omitted when the item
    /// has no Primary tag (the caller then usually leaves the
    /// cover empty instead).
    func imageUrl(itemId: String, maxWidth: Int? = nil, maxHeight: Int? = nil, tag: String? = nil, type: String = "Primary") -> String {
        var params: [String: String] = [:]
        if let maxWidth = maxWidth { params["maxWidth"] = "\(maxWidth)" }
        if let maxHeight = maxHeight { params["maxHeight"] = "\(maxHeight)" }
        if let tag = tag, !tag.isEmpty { params["tag"] = tag }
        let query = params.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")
        let path = "/Items/\(itemId)/Images/\(type)"
        guard let url = apiUrl(path) else { return "" }
        return query.isEmpty ? url.absoluteString : "\(url.absoluteString)?\(query)"
    }

    /// Direct (no-transcode) stream URL. THE ONLY place the key
    /// enters a URL — the player kernels take a bare URL. Never log
    /// this value, never put it in an exception, never use it as a
    /// key.
    ///
    /// STRM direct (`strmDirect`, default off): when on and the
    /// item's MediaSource path is a remote http(s) URL (a .strm
    /// target), that URL is returned directly — no server
    /// round-trip, no credential in the URL.
    ///
    /// `facts` (from the item's MediaSources) rides as `hao_*`
    /// query markers so the kernel can pick a capable engine
    /// before the first open. Emby ignores unknown query params;
    /// no markers when facts are absent.
    func streamUrl(itemId: String, facts: EmbyStreamFacts? = nil) -> String {
        if config.strmDirect, let strmPath = facts?.sourcePath,
           strmPath.hasPrefix("http://") || strmPath.hasPrefix("https://") {
            return strmPath
        }
        guard let url = apiUrl("/Videos/\(itemId)/stream") else { return "" }
        // Strict RFC 3986 query-value encoding: `.urlQueryAllowed`
        // lets `&`, `=` and `+` through, so a token containing any
        // of them would split the query string and fail auth (b35
        // sweep — the token is the one value that must survive
        // verbatim).
        let token = EmbyClient.queryValue(config.authToken)
        var result = "\(url.absoluteString)?static=true&api_key=\(token)"
        let markers = facts?.toQueryParams() ?? [:]
        if !markers.isEmpty {
            let qs = markers.map { "\($0.key)=\(EmbyClient.queryValue($0.value))" }.joined(separator: "&")
            result += "&\(qs)"
        }
        return result
    }

    /// External subtitle URL (build 36, item 14, G-G): the
    /// standard Emby endpoint
    /// `GET /Videos/{ItemId}/{MediaSourceId}/Subtitles/{Index}`.
    /// Same auth-in-URL discipline as `streamUrl` — one of the
    /// three places the key enters a URL (with `transcodedHlsUrl`).
    /// Never log it; use `redactedURL` for any diagnostic copy.
    func subtitleUrl(itemId: String, mediaSourceId: String, index: Int) -> String {
        guard let url = apiUrl("/Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(index)") else { return "" }
        return "\(url.absoluteString)?api_key=\(EmbyClient.queryValue(config.authToken))"
    }

    /// HLS transcode master playlist (build 36, item 14, G-H):
    /// the server transcodes video+audio to H.264/AAC on the fly.
    /// Last resort only — the driver tries it after the direct
    /// URL fails on every engine, so it never triggers for
    /// playable files. Cost is server CPU, only on files no
    /// bundled kernel can play (VVC, a missing audio decoder).
    func transcodedHlsUrl(itemId: String) -> String {
        guard let url = apiUrl("/Videos/\(itemId)/master.m3u8") else { return "" }
        return "\(url.absoluteString)?static=true&api_key=\(EmbyClient.queryValue(config.authToken))"
    }

    /// Build a subtitle URL from one of our own stream URLs
    /// (pure — the driver has the stream URL but no client).
    /// Returns nil when the URL is not an Emby direct stream.
    static func subtitleUrl(fromStreamUrl streamUrl: String, mediaSourceId: String, index: Int) -> URL? {
        guard episodeIdFromStreamUrl(streamUrl) != nil,
              let stream = URL(string: streamUrl),
              let components = URLComponents(url: stream, resolvingAgainstBaseURL: false) else { return nil }
        let token = components.queryItems?.first(where: { $0.name == "api_key" })?.value ?? ""
        guard !token.isEmpty, !mediaSourceId.isEmpty else { return nil }
        var path = stream.path
        if path.hasSuffix("/stream") { path = String(path.dropLast("/stream".count)) }
        // `path` is now `…/Videos/{itemId}` (with any `/emby`
        // prefix kept) — append only the subtitle tail.
        let base = "\(stream.scheme ?? "http")://\(stream.host ?? "")\(stream.port.map { ":\($0)" } ?? "")\(path)"
        return URL(string: "\(base)/\(mediaSourceId)/Subtitles/\(index)?api_key=\(queryValue(token))")
    }

    /// Build the transcode HLS URL from one of our own stream
    /// URLs (pure — the driver has the stream URL but no client).
    /// Returns nil when the URL is not an Emby direct stream.
    static func transcodedHlsUrl(fromStreamUrl streamUrl: String) -> URL? {
        guard episodeIdFromStreamUrl(streamUrl) != nil,
              let stream = URL(string: streamUrl),
              let components = URLComponents(url: stream, resolvingAgainstBaseURL: false) else { return nil }
        let token = components.queryItems?.first(where: { $0.name == "api_key" })?.value ?? ""
        guard !token.isEmpty else { return nil }
        var path = stream.path
        if path.hasSuffix("/stream") { path = String(path.dropLast("/stream".count)) }
        // `path` is now `…/Videos/{itemId}` (with any `/emby`
        // prefix kept) — append only the playlist tail.
        let base = "\(stream.scheme ?? "http")://\(stream.host ?? "")\(stream.port.map { ":\($0)" } ?? "")\(path)"
        return URL(string: "\(base)/master.m3u8?static=true&api_key=\(queryValue(token))")
    }

    /// Percent-encode one query value: unreserved characters only
    /// (ALPHA / DIGIT / `-` / `.` / `_` / `~`); everything else —
    /// including `&`, `=`, `+`, space — is escaped.
    static func queryValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Diagnostic copy of a URL string with the credential
    /// stripped: the `api_key` query item becomes `•••`, every
    /// other component untouched. Any log line, diagnostic key or
    /// error string that carries a stream URL must go through
    /// this first — the raw URL must never be stored or printed.
    static func redactedURL(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString),
              let items = components.queryItems, !items.isEmpty else { return urlString }
        guard items.contains(where: { $0.name == "api_key" }) else { return urlString }
        components.queryItems = items.map { item in
            item.name == "api_key" ? URLQueryItem(name: item.name, value: "•••") : item
        }
        return components.string ?? urlString
    }

    // MARK: Low-level GET

    /// One data GET. On a 404 it retries once with the other API
    /// prefix: a wrong prefix looks exactly like "not found", and
    /// a config saved before prefix persistence (or a server that
    /// moved) would otherwise fail every data call while the
    /// Settings probe still succeeds. The working prefix sticks
    /// for the rest of this client's life; probe / login /
    /// ensureApiRoot walk the prefixes themselves, so they pass
    /// `allowPrefixRetry: false` and must never double-walk.
    private func getJSON(url: URL, timeout: TimeInterval = 8, allowPrefixRetry: Bool = true, completion: @escaping (Result<[String: Any], EmbyError>) -> Void) {
        fetcher(url, authHeaders, timeout) { response in
            // mapDocument with wantMap: true only succeeds with a map;
            // the cast below therefore always succeeds in practice.
            let mapped = self.mapDocument(response, wantMap: true).map { $0 as? [String: Any] ?? [:] }
            if allowPrefixRetry,
               case .failure(let error) = mapped, error.kind == .notFound,
               let retryURL = self.flippedPrefixURL(url) {
                let original = self.useEmbyPrefix
                self.useEmbyPrefix.toggle()
                self.getJSON(url: retryURL, timeout: timeout, allowPrefixRetry: false) { retried in
                    if case .failure = retried { self.useEmbyPrefix = original }
                    completion(retried)
                }
                return
            }
            completion(mapped)
        }
    }

    private func getDocument(url: URL, timeout: TimeInterval = 8, allowPrefixRetry: Bool = true, completion: @escaping (Result<Any, EmbyError>) -> Void) {
        fetcher(url, authHeaders, timeout) { response in
            let mapped = self.mapDocument(response, wantMap: false)
            if allowPrefixRetry,
               case .failure(let error) = mapped, error.kind == .notFound,
               let retryURL = self.flippedPrefixURL(url) {
                let original = self.useEmbyPrefix
                self.useEmbyPrefix.toggle()
                self.getDocument(url: retryURL, timeout: timeout, allowPrefixRetry: false) { retried in
                    if case .failure = retried { self.useEmbyPrefix = original }
                    completion(retried)
                }
                return
            }
            completion(mapped)
        }
    }

    /// The same URL with the other API prefix (`/emby` inserted or
    /// removed right after the base). Nil when the URL is not one
    /// of ours (never rewrite an unrelated URL).
    private func flippedPrefixURL(_ url: URL) -> URL? {
        let s = url.absoluteString
        let b = base
        if s.hasPrefix(b + "/emby/") {
            return URL(string: b + String(s.dropFirst((b + "/emby").count)))
        }
        if s.hasPrefix(b + "/") {
            return URL(string: b + "/emby" + String(s.dropFirst(b.count)))
        }
        return nil
    }

    /// Map a raw response to a document or a typed error. 401's
    /// wording depends on the auth mode (password login vs key).
    private func mapDocument(_ response: EmbyResponse, wantMap: Bool) -> Result<Any, EmbyError> {
        let status = response.statusCode
        if response.timedOut {
            return .failure(.timedOut())
        }
        if status == 0 {
            return .failure(.unreachable())
        }
        if status == 401 {
            return .failure(config.usesPasswordAuth ? .unauthorizedAccount() : .unauthorized())
        }
        if status == 404 {
            return .failure(.notFound())
        }
        if status < 200 || status >= 300 {
            return .failure(.other("Emby 服务器返回了错误（\(status)）"))
        }
        guard let json = response.json else {
            return .failure(.other("Emby 返回了无法识别的数据"))
        }
        if wantMap {
            guard let map = json as? [String: Any] else {
                return .failure(.other("Emby 返回了无法识别的数据"))
            }
            return .success(map)
        }
        return .success(json)
    }

    // MARK: Probe

    /// GET /System/Info with the credential. Tries `/emby` first,
    /// then the root, and remembers the working prefix. 200 +
    /// ServerName / Version = "server reachable, credential
    /// correct". 401 = credential wrong (same on both prefixes —
    /// no point trying the second). Anything else on both prefixes
    /// = unreachable / wrong address.
    ///
    /// On success also fetches GET /Users — unless `config.userId`
    /// is already known (a non-admin user token cannot read
    /// /Users, and a failed fetch must not fail a probe whose
    /// credential System/Info already accepted).
    func probe(completion: @escaping (EmbyProbeResult) -> Void) {
        let bases = [config.baseUrl] + config.fallbackUrls.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var lastFailure: EmbyProbeResult?
        var index = 0
        func step() {
            if index >= bases.count {
                completion(lastFailure ?? EmbyProbeResult(ok: false, errorKind: .unreachable, errorMessage: EmbyError.unreachable().message))
                return
            }
            let base = bases[index]
            index += 1
            probeBase(base) { result in
                if result.ok {
                    completion(result)
                    return
                }
                lastFailure = result
                // 401 is base-independent: the credential itself is wrong.
                if result.errorKind == .unauthorized {
                    completion(result)
                    return
                }
                step()
            }
        }
        step()
    }

    /// Probe ONE base URL (both prefixes). The override is always
    /// cleared afterwards, so a later data call uses config.baseUrl.
    private func probeBase(_ base: String, completion: @escaping (EmbyProbeResult) -> Void) {
        baseOverride = base
        var lastError: EmbyError?
        var prefixIndex = 0
        let prefixes = [true, false]
        func step() {
            if prefixIndex >= prefixes.count {
                baseOverride = nil
                let error = lastError ?? .unreachable()
                completion(EmbyProbeResult(
                    ok: false,
                    errorKind: error.kind,
                    errorMessage: error.kind == .notFound ? "Emby 服务器地址不对，请检查地址" : error.message
                ))
                return
            }
            useEmbyPrefix = prefixes[prefixIndex]
            prefixIndex += 1
            guard let url = apiUrl("/System/Info") else {
                lastError = .unreachable()
                step()
                return
            }
            // Manual prefix walk: no auto-retry inside getJSON.
            getJSON(url: url, allowPrefixRetry: false) { result in
                switch result {
                case .failure(let error):
                    // Transport failures stop the walk: when the
                    // server never answered, the /emby-vs-root
                    // prefix is not the question — trying the
                    // other prefix just burns another timeout.
                    // Only a real HTTP answer (404 / other) walks.
                    if error.kind == .unauthorized || error.kind == .unreachable || error.kind == .timedOut {
                        self.baseOverride = nil
                        completion(EmbyProbeResult(ok: false, errorKind: error.kind, errorMessage: error.message))
                        return
                    }
                    lastError = error
                    step()
                case .success(let info):
                    let serverName = VideoJSON.asString(info["ServerName"])
                    let version = VideoJSON.asString(info["Version"])
                    if serverName.isEmpty && version.isEmpty {
                        lastError = .other("Emby 服务器没有返回服务器信息")
                        step()
                        return
                    }
                    self.fetchUsersOrEmpty { users in
                        self.baseOverride = nil
                        completion(EmbyProbeResult(ok: true, serverName: serverName, version: version, users: users, workingBaseUrl: base, useEmbyPrefix: self.useEmbyPrefix))
                    }
                }
            }
        }
        step()
    }

    /// Users for the probe: skipped when `config.userId` is already
    /// known; a failed fetch is an empty list, never a probe failure.
    private func fetchUsersOrEmpty(completion: @escaping ([EmbyUser]) -> Void) {
        if !config.userId.isEmpty {
            completion([])
            return
        }
        fetchUsers { users in
            completion(users ?? [])
        }
    }

    // MARK: Account login

    /// Username + password login: POST /Users/AuthenticateByName.
    /// Returns the AccessToken + User Id to store; the password is
    /// sent once in the request body and never stored anywhere.
    /// Tries `/emby` first, then the root (same prefix walk as
    /// probe). 401 = wrong name/password. `baseUrl` tries a
    /// fallback line instead of the main address; the override is
    /// always cleared afterwards.
    func authenticateByName(username: String, password: String, baseUrl: String? = nil, timeout: TimeInterval = 8, completion: @escaping (EmbyAuthResult) -> Void) {
        let deviceId = config.deviceId.isEmpty ? EmbyServerConfig.newDeviceId() : config.deviceId
        baseOverride = baseUrl
        var lastError: EmbyError?
        var prefixIndex = 0
        let prefixes = [true, false]
        func step() {
            if prefixIndex >= prefixes.count {
                baseOverride = nil
                let error = lastError ?? .unreachable()
                completion(EmbyAuthResult(ok: false, errorKind: error.kind, errorMessage: error.message))
                return
            }
            useEmbyPrefix = prefixes[prefixIndex]
            prefixIndex += 1
            guard let url = apiUrl("/Users/AuthenticateByName") else {
                lastError = .unreachable()
                step()
                return
            }
            let headers = [
                "X-Emby-Authorization": "MediaBrowser Client=\"HAo Studio\", Device=\"iPhone\", DeviceId=\"\(deviceId)\", Version=\"2.0.0\"",
            ]
            mutator("POST", url, headers, ["Username": username, "Pw": password], timeout) { response in
                if response.statusCode == 401 {
                    self.baseOverride = nil
                    completion(EmbyAuthResult(ok: false, errorKind: .unauthorized, errorMessage: EmbyError.unauthorizedAccount().message))
                    return
                }
                if response.statusCode == 404 {
                    step()
                    return
                }
                if response.statusCode == 0 {
                    // Transport failure: the server never answered,
                    // so the prefix is not the question. Fail at
                    // once instead of burning a second timeout on
                    // the other prefix (and keep the timeout
                    // distinction for the message).
                    self.baseOverride = nil
                    let error = response.timedOut ? EmbyError.timedOut() : .unreachable()
                    completion(EmbyAuthResult(ok: false, errorKind: error.kind, errorMessage: error.message))
                    return
                }
                if response.statusCode < 200 || response.statusCode >= 300 {
                    self.baseOverride = nil
                    completion(EmbyAuthResult(ok: false, errorKind: .other, errorMessage: "Emby 服务器返回了错误（\(response.statusCode)）"))
                    return
                }
                guard let doc = response.json as? [String: Any] else {
                    self.baseOverride = nil
                    completion(EmbyAuthResult(ok: false, errorKind: .other, errorMessage: "Emby 登录返回了无法识别的数据"))
                    return
                }
                let token = VideoJSON.asString(doc["AccessToken"])
                let user = doc["User"] as? [String: Any]
                let userId = VideoJSON.asString(user?["Id"])
                let userName = VideoJSON.asString(user?["Name"])
                if token.isEmpty || userId.isEmpty {
                    self.baseOverride = nil
                    completion(EmbyAuthResult(ok: false, errorKind: .other, errorMessage: "Emby 登录没有返回有效的凭证"))
                    return
                }
                self.baseOverride = nil
                completion(EmbyAuthResult(ok: true, accessToken: token, userId: userId, userName: userName))
            }
        }
        step()
    }

    /// Lightweight reachability check for one fallback line, no
    /// credential needed: GET /System/Info/Public (the public,
    /// unauthenticated endpoint). 200 + a server-identity field =
    /// "this address is an Emby server". Never throws.
    func checkPublicLine(_ lineBaseUrl: String, completion: @escaping (Bool) -> Void) {
        var base = lineBaseUrl.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base = String(base.dropLast()) }
        if base.isEmpty {
            completion(false)
            return
        }
        let prefixes = ["/emby", ""]
        var index = 0
        func step() {
            if index >= prefixes.count {
                completion(false)
                return
            }
            let prefix = prefixes[index]
            index += 1
            guard let url = URL(string: base + prefix + "/System/Info/Public") else {
                step()
                return
            }
            fetcher(url, [:], 5) { response in
                // Transport failure (status 0): the host never
                // answered, so the other prefix cannot help —
                // stop instead of burning a second 5 s timeout.
                if response.statusCode == 0 {
                    completion(false)
                    return
                }
                if response.statusCode != 200 {
                    step()
                    return
                }
                guard let doc = response.json as? [String: Any],
                      (!VideoJSON.asString(doc["ServerName"]).isEmpty ||
                       !VideoJSON.asString(doc["Version"]).isEmpty ||
                       !VideoJSON.asString(doc["Id"]).isEmpty) else {
                    step()
                    return
                }
                completion(true)
            }
        }
        step()
    }

    /// Resolve (and remember) the working API prefix without
    /// returning users. Used by the tab page before its first data
    /// load; the full probe (with users) lives in Settings.
    func ensureApiRoot(completion: @escaping (EmbyError?) -> Void) {
        var prefixIndex = 0
        let prefixes = [true, false]
        func step() {
            if prefixIndex >= prefixes.count {
                completion(.unreachable())
                return
            }
            useEmbyPrefix = prefixes[prefixIndex]
            prefixIndex += 1
            guard let url = apiUrl("/System/Info") else {
                step()
                return
            }
            // Manual prefix walk: no auto-retry inside getJSON.
            getJSON(url: url, allowPrefixRetry: false) { result in
                switch result {
                case .success:
                    completion(nil)
                case .failure(let error):
                    // Same rule as probeBase: a transport failure
                    // stops the prefix walk; only a real HTTP
                    // answer (wrong prefix looks like 404) walks.
                    if error.kind == .unauthorized || error.kind == .unreachable || error.kind == .timedOut {
                        completion(error)
                        return
                    }
                    step()
                }
            }
        }
        step()
    }

    private func fetchUsers(completion: @escaping ([EmbyUser]?) -> Void) {
        guard let url = apiUrl("/Users") else {
            completion(nil)
            return
        }
        // Probe context: the caller walks prefixes itself.
        getDocument(url: url, allowPrefixRetry: false) { result in
            switch result {
            case .failure:
                completion(nil)
            case .success(let doc):
                var list: [Any]?
                if let array = doc as? [Any] {
                    list = array
                } else if let map = doc as? [String: Any], let items = map["Items"] as? [Any] {
                    list = items
                }
                guard let list = list else {
                    completion([])
                    return
                }
                let users = list.compactMap { $0 as? [String: Any] }
                    .map { EmbyUser.fromJSON($0) }
                    .filter { !$0.id.isEmpty }
                completion(users)
            }
        }
    }

    // MARK: Libraries

    /// GET /Users/{userId}/Views — movies + tvshows libraries
    /// ONLY (只接电影+电视两个库). Music / photos / homevideo /
    /// mixed libraries are dropped here: the tab only ever asks
    /// for Movie / Video / Series items, so any other library
    /// would surface as a chip that always opens an empty grid.
    func libraries(completion: @escaping (Result<[EmbyLibrary], EmbyError>) -> Void) {
        guard let url = apiUrl("/Users/\(config.userId)/Views") else {
            completion(.failure(.unreachable()))
            return
        }
        getJSON(url: url) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                let items = VideoJSON.asList(json["Items"])
                    .map { EmbyLibrary.fromJSON($0) }
                    .filter { !$0.id.isEmpty && ($0.isMovieLibrary || $0.isTvLibrary) }
                completion(.success(items))
            }
        }
    }

    /// Count items under one library (Limit 1 — only
    /// TotalRecordCount is read). Used by the tab page's library
    /// inventory line.
    func libraryItemCount(libraryId: String, includeItemTypes: String? = nil, completion: @escaping (Result<Int, EmbyError>) -> Void) {
        var query: [String: String] = [
            "parentId": libraryId,
            "Recursive": "true",
            "StartIndex": "0",
            "Limit": "1",
        ]
        if let includeItemTypes = includeItemTypes, !includeItemTypes.isEmpty {
            query["IncludeItemTypes"] = includeItemTypes
        }
        guard let url = apiQuery("/Users/\(config.userId)/Items", query: query) else {
            completion(.failure(.unreachable()))
            return
        }
        getJSON(url: url) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                completion(.success(VideoJSON.asInt(json["TotalRecordCount"])))
            }
        }
    }

    // MARK: Items

    /// Movies rail: 'Video' as well as 'Movie' — loose video files
    /// the server never matched to a movie carry Type 'Video' and
    /// were invisible before. Trailers / extras are their own
    /// types ('Trailer' / 'Extra'), so they stay out.
    func movies(libraryId: String? = nil, startIndex: Int = 0, limit: Int = 50, genres: String? = nil, completion: @escaping (Result<EmbyItemsPage, EmbyError>) -> Void) {
        items(includeItemTypes: "Movie,Video", libraryId: libraryId, startIndex: startIndex, limit: limit, genres: genres, completion: completion)
    }

    func series(libraryId: String? = nil, startIndex: Int = 0, limit: Int = 50, genres: String? = nil, completion: @escaping (Result<EmbyItemsPage, EmbyError>) -> Void) {
        items(includeItemTypes: "Series", libraryId: libraryId, startIndex: startIndex, limit: limit, genres: genres, completion: completion)
    }

    /// Server-side favorites (UserData.IsFavorite) across movies
    /// and series, SortName order.
    func favorites(startIndex: Int = 0, limit: Int = 50, completion: @escaping (Result<EmbyItemsPage, EmbyError>) -> Void) {
        items(includeItemTypes: "Movie,Video,Series", startIndex: startIndex, limit: limit, filters: "IsFavorite", completion: completion)
    }

    /// One genre across movies and series (Emby `Genres` filter).
    /// This is the P0-10 classification: movie / TV plus Genres.
    func byGenre(_ genre: String, startIndex: Int = 0, limit: Int = 50, completion: @escaping (Result<EmbyItemsPage, EmbyError>) -> Void) {
        items(includeItemTypes: "Movie,Video,Series", startIndex: startIndex, limit: limit, genres: genre, completion: completion)
    }

    /// Distinct genre names across movies + series, from real
    /// library content (first 200 items, sorted). Emby exposes no
    /// /Genres list endpoint, so the tab's genre chips are built
    /// from what the server actually holds — never a hardcoded
    /// list. A genre that only appears past the first 200 items
    /// will not chip until the library grows past it; the library
    /// itself stays fully browsable without a chip.
    func genreNames(completion: @escaping ([String]) -> Void) {
        let query: [String: String] = [
            "IncludeItemTypes": "Movie,Series",
            "Recursive": "true",
            "StartIndex": "0",
            "Limit": "200",
            "SortBy": "SortName",
            "Fields": "Genres",
        ]
        guard let url = apiQuery("/Users/\(config.userId)/Items", query: query) else {
            completion([])
            return
        }
        getJSON(url: url) { result in
            switch result {
            case .failure:
                completion([])
            case .success(let json):
                var seen: [String] = []
                var set = Set<String>()
                for raw in VideoJSON.asList(json["Items"]) {
                    for genre in VideoJSON.asStringList(raw["Genres"]) where !genre.isEmpty {
                        if set.insert(genre).inserted { seen.append(genre) }
                    }
                }
                completion(seen.sorted())
            }
        }
    }

    private func items(includeItemTypes: String, libraryId: String? = nil, startIndex: Int = 0, limit: Int = 50, genres: String? = nil, filters: String? = nil, completion: @escaping (Result<EmbyItemsPage, EmbyError>) -> Void) {
        var query: [String: String] = [
            "IncludeItemTypes": includeItemTypes,
            "Recursive": "true",
            "StartIndex": "\(startIndex)",
            "Limit": "\(limit)",
            "SortBy": "SortName",
            "Fields": EmbyClient.itemFields,
        ]
        if let libraryId = libraryId, !libraryId.isEmpty { query["parentId"] = libraryId }
        if let genres = genres, !genres.isEmpty { query["Genres"] = genres }
        if let filters = filters, !filters.isEmpty { query["Filters"] = filters }
        guard let url = apiQuery("/Users/\(config.userId)/Items", query: query) else {
            completion(.failure(.unreachable()))
            return
        }
        getJSON(url: url) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                completion(.success(self.pageFromJSON(json)))
            }
        }
    }

    /// Emby title search (title only — the server does not match
    /// cast or synopsis). Emby-only; v1 never merges CMS results
    /// in. Paginated: callers page with `startIndex` until
    /// `items.count >= totalCount`.
    func search(query: String, startIndex: Int = 0, limit: Int = 50, completion: @escaping (Result<EmbyItemsPage, EmbyError>) -> Void) {
        guard let url = apiQuery("/Users/\(config.userId)/Items", query: [
            "searchTerm": query,
            "IncludeItemTypes": "Movie,Series,Episode,Video",
            "Recursive": "true",
            "StartIndex": "\(startIndex)",
            "Limit": "\(limit)",
            "Fields": EmbyClient.itemFields,
        ]) else {
            completion(.failure(.unreachable()))
            return
        }
        getJSON(url: url) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                completion(.success(self.pageFromJSON(json)))
            }
        }
    }

    // MARK: Resume / NextUp

    /// Server-side "continue watching": GET /Users/{userId}/Items/
    /// Resume. Items in progress (movies + episodes), each carrying
    /// its UserData (resume position / played / favorite) and
    /// RunTimeTicks. The position rides on the entry itself —
    /// VideoItem has no user-data fields (see the seam note on
    /// toVideoItem) — so the tab can render a progress bar and
    /// seed the local resume on tap without a second request.
    func resumeItems(limit: Int = 50, completion: @escaping (Result<[EmbyResumeItem], EmbyError>) -> Void) {
        guard let url = apiQuery("/Users/\(config.userId)/Items/Resume", query: [
            "MediaTypes": "Video",
            "Recursive": "true",
            "Limit": "\(limit)",
            "Fields": EmbyClient.itemFields,
        ]) else {
            completion(.failure(.unreachable()))
            return
        }
        getJSON(url: url) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                completion(.success(self.resumeItemsFromJSON(json)))
            }
        }
    }

    /// Parse the Resume list into in-progress entries. An entry
    /// with no playback position is dropped (not in progress —
    /// a finished item the server still lists must not render
    /// as a 0:00 row). Episode entries keep their display name
    /// ("第N集" / title); films get "正片", matching the detail
    /// page's episode names so the local resume seed selects
    /// the right episode.
    func resumeItemsFromJSON(_ json: [String: Any]) -> [EmbyResumeItem] {
        VideoJSON.asList(json["Items"]).compactMap { item in
            let userData = EmbyUserData.fromJSON(item["UserData"])
            guard userData.playbackPositionSeconds > 0 else { return nil }
            let runTimeTicks = VideoJSON.asDouble(item["RunTimeTicks"])
            let duration = runTimeTicks > 0 ? runTimeTicks / Double(EmbyClient.ticksPerSecond) : 0
            let type = VideoJSON.asString(item["Type"])
            let episodeName = type == "Episode" ? EmbyClient.episodeDisplayName(item) : "正片"
            return EmbyResumeItem(
                item: toVideoItem(item),
                episodeName: episodeName,
                positionSeconds: userData.playbackPositionSeconds,
                durationSeconds: duration)
        }
    }

    /// Next unwatched episode(s) of one series: GET /Shows/NextUp.
    /// Empty when the series is fully watched or the server has no
    /// next episode for it.
    func nextUp(seriesId: String, limit: Int = 5, completion: @escaping (Result<[VideoItem], EmbyError>) -> Void) {
        guard let url = apiQuery("/Shows/NextUp", query: [
            "userId": config.userId,
            "seriesId": seriesId,
            "Limit": "\(limit)",
            "Fields": EmbyClient.itemFields,
        ]) else {
            completion(.failure(.unreachable()))
            return
        }
        getJSON(url: url) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                completion(.success(self.pageFromJSON(json).items))
            }
        }
    }

    /// One item's server-side user data (resume position / played /
    /// favorite / rating). Best-effort: nil when the item is gone
    /// or the server cannot be reached — the caller (detail page)
    /// falls back to local state instead of failing the page.
    func userData(itemId: String, completion: @escaping (EmbyUserData?) -> Void) {
        guard let url = apiQuery("/Users/\(config.userId)/Items/\(itemId)", query: ["Fields": "UserData"]) else {
            completion(nil)
            return
        }
        getJSON(url: url) { result in
            switch result {
            case .failure:
                completion(nil)
            case .success(let json):
                completion(EmbyUserData.fromJSON(json["UserData"]))
            }
        }
    }

    // MARK: Server sync (best-effort writes)

    /// One mutating call: 2xx = true, anything else = false.
    /// Cancellation is swallowed too (a disposed page reporting
    /// late is not an error) — callers are all fire-and-forget.
    private func mutate(method: String, url: URL, completion: @escaping (Bool) -> Void) {
        mutator(method, url, authHeaders, nil, 8) { response in
            completion(response.statusCode >= 200 && response.statusCode < 300)
        }
    }

    /// Automatic playback sync (start / progress / stopped / mark
    /// played) behind the 数据上报 switch (`reportProgress`,
    /// default on): when the user turns it off, NO request is sent
    /// at all — the method returns false without touching the
    /// network. Explicit user actions (favorite / like below) use
    /// `mutate` directly and are never gated.
    private func reportMutate(method: String, url: URL, completion: @escaping (Bool) -> Void) {
        if !config.reportProgress {
            completion(false)
            return
        }
        mutate(method: method, url: url, completion: completion)
    }

    private func playingItemsUrl(itemId: String, suffix: String = "") -> URL? {
        apiUrl("/Users/\(config.userId)/PlayingItems/\(itemId)\(suffix)")
    }

    private func ticksQuery(positionSeconds: Double, isPaused: Bool? = nil) -> String {
        var qs = "PositionTicks=\(EmbyClient.ticksFromSeconds(positionSeconds))"
        if let isPaused = isPaused { qs += "&IsPaused=\(isPaused)" }
        return qs
    }

    /// Report that playback of `itemId` started (position in
    /// seconds). Gated by the 数据上报 switch.
    func reportPlaybackStart(itemId: String, positionSeconds: Double = 0, completion: @escaping (Bool) -> Void) {
        guard let base = playingItemsUrl(itemId: itemId) else {
            completion(false)
            return
        }
        guard let url = URL(string: "\(base.absoluteString)?\(ticksQuery(positionSeconds: positionSeconds))") else {
            completion(false)
            return
        }
        reportMutate(method: "POST", url: url, completion: completion)
    }

    /// Periodic progress report (position in seconds). The player
    /// throttles calls to one per 15 s of forward playback + exit +
    /// completion; the server is the resume source of truth across
    /// devices. Gated by the 数据上报 switch.
    func reportPlaybackProgress(itemId: String, positionSeconds: Double, isPaused: Bool = false, completion: @escaping (Bool) -> Void) {
        guard let base = playingItemsUrl(itemId: itemId, suffix: "/Progress") else {
            completion(false)
            return
        }
        guard let url = URL(string: "\(base.absoluteString)?\(ticksQuery(positionSeconds: positionSeconds, isPaused: isPaused))") else {
            completion(false)
            return
        }
        reportMutate(method: "POST", url: url, completion: completion)
    }

    /// Report that playback of `itemId` stopped. The final position
    /// should already have been reported via progress; this only
    /// ends the session server-side. Gated by the 数据上报 switch.
    func reportPlaybackStopped(itemId: String, completion: @escaping (Bool) -> Void) {
        guard let url = playingItemsUrl(itemId: itemId) else {
            completion(false)
            return
        }
        reportMutate(method: "DELETE", url: url, completion: completion)
    }

    /// Mark `itemId` played on the server. Gated by the 数据上报
    /// switch: the 已看标记 is part of the same sync, fired
    /// automatically on episode end, not by a user tap.
    func markPlayed(itemId: String, completion: @escaping (Bool) -> Void) {
        guard let url = apiUrl("/Users/\(config.userId)/PlayedItems/\(itemId)") else {
            completion(false)
            return
        }
        reportMutate(method: "POST", url: url, completion: completion)
    }

    /// Set or clear the server-side favorite flag for `itemId`.
    func setFavorite(itemId: String, favorite: Bool, completion: @escaping (Bool) -> Void) {
        guard let url = apiUrl("/Users/\(config.userId)/FavoriteItems/\(itemId)") else {
            completion(false)
            return
        }
        mutate(method: favorite ? "POST" : "DELETE", url: url, completion: completion)
    }

    /// Like (true) or dislike (false) `itemId` on the server.
    /// Emby's rating API is a like/dislike flag, not stars.
    func rateItem(itemId: String, likes: Bool, completion: @escaping (Bool) -> Void) {
        guard let base = apiUrl("/Users/\(config.userId)/Items/\(itemId)/Rating"),
              let url = URL(string: "\(base.absoluteString)?likes=\(likes)") else {
            completion(false)
            return
        }
        mutate(method: "POST", url: url, completion: completion)
    }

    /// Clear the server-side rating for `itemId`.
    func clearRating(itemId: String, completion: @escaping (Bool) -> Void) {
        guard let url = apiUrl("/Users/\(config.userId)/Items/\(itemId)/Rating") else {
            completion(false)
            return
        }
        mutate(method: "DELETE", url: url, completion: completion)
    }

    // MARK: Seasons / episodes

    /// Seasons of a series, sorted by IndexNumber (missing → last).
    func seasons(seriesId: String, completion: @escaping (Result<[[String: Any]], EmbyError>) -> Void) {
        guard let url = apiQuery("/Shows/\(seriesId)/Seasons", query: [
            "userId": config.userId,
            "Limit": "100",
            "Fields": "Overview,ImageTags",
        ]) else {
            completion(.failure(.unreachable()))
            return
        }
        getJSON(url: url) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                var items = VideoJSON.asList(json["Items"]).filter { item in
                    let type = VideoJSON.asString(item["Type"])
                    return type == "Season" || type.isEmpty
                }
                items.sort { EmbyClient.compareIndexNumber($0, $1) }
                completion(.success(items))
            }
        }
    }

    /// Episodes of one season, sorted by IndexNumber (missing →
    /// last). Each episode carries its stream facts (MediaSources
    /// are requested here so detail can tag the stream URLs).
    func episodes(seriesId: String, seasonId: String, completion: @escaping (Result<[EmbyEpisode], EmbyError>) -> Void) {
        guard let url = apiQuery("/Shows/\(seriesId)/Episodes", query: [
            "userId": config.userId,
            "seasonId": seasonId,
            "MediaTypes": "Video",
            "Limit": "1000",
            "Fields": EmbyClient.detailFields,
        ]) else {
            completion(.failure(.unreachable()))
            return
        }
        getJSON(url: url) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                var items = VideoJSON.asList(json["Items"])
                items.sort { EmbyClient.compareIndexNumber($0, $1) }
                let episodes = items.map { item in
                    EmbyEpisode(
                        item: self.toVideoItem(item),
                        facts: EmbyStreamFacts.fromMediaSources(item["MediaSources"]),
                        markers: EmbySkipMarkers.fromChapters(item["Chapters"])
                    )
                }
                completion(.success(episodes))
            }
        }
    }

    /// Episodes of one season as playable PlayEpisodes (the mapping
    /// detail uses). One season per request, never a full-series
    /// sweep.
    func seasonEpisodes(seriesId: String, seasonId: String, completion: @escaping (Result<[PlayEpisode], EmbyError>) -> Void) {
        episodes(seriesId: seriesId, seasonId: seasonId) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let eps):
                completion(.success(EmbyClient.episodesToPlayEpisodes(eps, streamUrl: { [weak self] id, facts in
                    self?.streamUrl(itemId: id, facts: facts) ?? ""
                })))
            }
        }
    }

    /// One season's fetched episodes → playable episodes (name
    /// falls back to '第 N 集' from the list position; the stream
    /// URL is tagged with the episode's stream facts for the
    /// engine gate).
    static func episodesToPlayEpisodes(_ eps: [EmbyEpisode], streamUrl: (String, EmbyStreamFacts?) -> String) -> [PlayEpisode] {
        eps.enumerated().map { (index, episode) in
            PlayEpisode(
                name: episode.item.title.isEmpty ? "第 \(index + 1) 集" : episode.item.title,
                url: URL(string: streamUrl(episode.item.id, episode.facts)),
                index: index,
                introStart: episode.markers?.introStart,
                introEnd: episode.markers?.introEnd,
                creditsStart: episode.markers?.creditsStart
            )
        }
    }

    // MARK: Detail

    /// Single item → VideoDetail. Movie: 1 line ('直链') + 1
    /// episode ('正片'). Series: one line per season ('第 N 季'),
    /// episodes sorted by IndexNumber — EVERY season is fetched
    /// eagerly, in order. (An earlier version fetched only the
    /// first season with episodes and left the rest as empty
    /// lines "to be filled on demand" — but nothing ever called
    /// the on-demand loader, so seasons 2+ opened an empty grid
    /// with a dead play button. Eager fetch is the fix; season
    /// lists are short.)
    /// A bare Episode id plays as a single-episode direct stream.
    func detail(itemId: String, completion: @escaping (Result<VideoDetail, EmbyError>) -> Void) {
        guard let url = apiQuery("/Users/\(config.userId)/Items/\(itemId)", query: ["Fields": EmbyClient.detailFields]) else {
            completion(.failure(.unreachable()))
            return
        }
        getJSON(url: url) { result in
            switch result {
            case .failure(let error):
                if error.kind == .notFound {
                    completion(.failure(.notFound("这部影片在 Emby 里找不到了")))
                    return
                }
                completion(.failure(error))
            case .success(let item):
                self.buildDetail(itemId: itemId, item: item, completion: completion)
            }
        }
    }

    private func buildDetail(itemId: String, item: [String: Any], completion: @escaping (Result<VideoDetail, EmbyError>) -> Void) {
        let type = VideoJSON.asString(item["Type"])
        let meta = toVideoMeta(item)
        let facts = EmbyStreamFacts.fromMediaSources(item["MediaSources"])
        if type == "Movie" || type == "Episode" || type == "Video" {
            let episodeName = type == "Episode" ? EmbyClient.episodeDisplayName(item) : "正片"
            let markers = EmbySkipMarkers.fromChapters(item["Chapters"])
            guard let stream = URL(string: streamUrl(itemId: itemId, facts: facts)) else {
                completion(.failure(.other("这部影片在 Emby 里打不开")))
                return
            }
            let videoItem = toVideoItem(item)
            let detail = VideoDetail(
                item: videoItem,
                lines: [PlayLine(name: "直链", episodes: [PlayEpisode(name: episodeName, url: stream, index: 0, introStart: markers?.introStart, introEnd: markers?.introEnd, creditsStart: markers?.creditsStart)])],
                meta: meta
            )
            completion(.success(detail))
            return
        }
        if type == "Series" {
            seasons(seriesId: itemId) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let seasonList):
                    self.buildSeriesDetail(itemId: itemId, item: item, meta: meta, seasonList: seasonList, completion: completion)
                }
            }
            return
        }
        completion(.failure(.other("这部影片在 Emby 里打不开")))
    }

    private func buildSeriesDetail(itemId: String, item: [String: Any], meta: VideoMeta, seasonList: [[String: Any]], completion: @escaping (Result<VideoDetail, EmbyError>) -> Void) {
        var lines: [PlayLine] = []
        var foundEpisodes = false
        var index = 0
        func step() {
            if index >= seasonList.count {
                if lines.isEmpty || !foundEpisodes {
                    completion(.failure(.other("这部剧集在 Emby 里没有可播的集")))
                    return
                }
                completion(.success(VideoDetail(item: toVideoItem(item), lines: lines, meta: meta)))
                return
            }
            let season = seasonList[index]
            index += 1
            let seasonId = VideoJSON.asString(season["Id"])
            if seasonId.isEmpty {
                step()
                return
            }
            let seasonIndex = VideoJSON.asIntOrNil(season["IndexNumber"])
            let lineName: String
            if let seasonIndex = seasonIndex {
                lineName = "第 \(seasonIndex) 季"
            } else {
                let name = VideoJSON.asString(season["Name"])
                lineName = name.isEmpty ? "季" : name
            }
            episodes(seriesId: itemId, seasonId: seasonId) { result in
                switch result {
                case .failure:
                    // A season whose episodes cannot be fetched
                    // contributes no line: an empty line opens an
                    // empty grid with a dead play button (b35
                    // sweep — the same dead-line shape the eager
                    // fetch fixed for later seasons). When every
                    // season fails, the step() terminator below
                    // reports "没有可播的集" instead.
                    step()
                case .success(let fetched):
                    let eps = EmbyClient.episodesToPlayEpisodes(fetched, streamUrl: { [weak self] id, facts in
                        self?.streamUrl(itemId: id, facts: facts) ?? ""
                    })
                    if eps.isEmpty {
                        // A season the server reports with no
                        // episodes is not a playable line either.
                        step()
                        return
                    }
                    foundEpisodes = true
                    lines.append(PlayLine(name: lineName, episodes: eps))
                    step()
                }
            }
        }
        step()
    }

    // MARK: Mapping (pure apart from imageUrl)

    private func pageFromJSON(_ json: [String: Any]) -> EmbyItemsPage {
        let items = VideoJSON.asList(json["Items"]).filter { item in
            let type = VideoJSON.asString(item["Type"])
            return type == "Movie" || type == "Series" || type == "Episode" || type == "Video"
        }.map { toVideoItem($0) }
        return EmbyItemsPage(items: items, totalCount: VideoJSON.asInt(json["TotalRecordCount"]) == 0 ? items.count : VideoJSON.asInt(json["TotalRecordCount"]))
    }

    /// One raw item → VideoItem. Missing fields never throw: no
    /// ImageTags → cover stays nil (placeholder), no Overview /
    /// rating / ChildCount → empty. `UserData` is NOT dropped: the
    /// server's resume position / played / favorite / rating ride
    /// on the item — but Swift's VideoItem has no user-data
    /// fields, so resume position is exposed separately through
    /// `userData(itemId:)` (seam gap — see the leg report).
    func toVideoItem(_ json: [String: Any]) -> VideoItem {
        let id = VideoJSON.asString(json["Id"])
        let imageTags = json["ImageTags"] as? [String: Any]
        let tag = imageTags?["Primary"] as? String
        let yearRaw = VideoJSON.asString(json["ProductionYear"])
        let genres = VideoJSON.asStringList(json["Genres"])
        return VideoItem(
            id: id,
            title: VideoJSON.asString(json["Name"]),
            coverURL: {
                guard let tag = tag, !tag.isEmpty else { return nil }
                return URL(string: imageUrl(itemId: id, maxWidth: 400, tag: tag))
            }(),
            year: yearRaw.isEmpty ? nil : yearRaw,
            typeName: genres.isEmpty ? nil : genres.joined(separator: " / "),
            remarks: nil,
            sourceId: nil
        )
    }

    func toVideoMeta(_ json: [String: Any]) -> VideoMeta {
        let ratingRaw = json["CommunityRating"]
        let rating: Double? = {
            if let number = ratingRaw as? NSNumber { return number.doubleValue }
            return nil
        }()
        let people = VideoJSON.asList(json["People"])
        func namesOf(_ type: String) -> String {
            people.filter { VideoJSON.asString($0["Type"]) == type }
                .map { VideoJSON.asString($0["Name"]) }
                .filter { !$0.isEmpty }
                .joined(separator: type == "Actor" ? "，" : " / ")
        }
        let actor = namesOf("Actor")
        let cast = actor.components(separatedBy: "，").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let yearRaw = VideoJSON.asString(json["ProductionYear"])
        let overview = VideoJSON.asString(json["Overview"])
        return VideoMeta(
            rating: rating,
            year: yearRaw.isEmpty ? nil : yearRaw,
            cast: cast,
            synopsis: {
                let deduped = EmbySynopsis.dedupe(overview)
                return deduped.isEmpty ? nil : deduped
            }(),
            doubanId: nil
        )
    }

    /// Episode display name: the episode title when present, else
    /// '第 N 集' from IndexNumber, else '正片'.
    static func episodeDisplayName(_ json: [String: Any]) -> String {
        let name = VideoJSON.asString(json["Name"])
        if !name.isEmpty { return name }
        if let index = VideoJSON.asIntOrNil(json["IndexNumber"]) {
            return "第 \(index) 集"
        }
        return "正片"
    }

    /// Sort by IndexNumber (missing → last).
    static func compareIndexNumber(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        let ai = VideoJSON.asIntOrNil(a["IndexNumber"])
        let bi = VideoJSON.asIntOrNil(b["IndexNumber"])
        if ai == nil && bi == nil { return false }
        if ai == nil { return false }
        if bi == nil { return true }
        return ai! < bi!
    }

    /// Format a CommunityRating: 8.0 → '8.0' would read as a typo;
    /// 8 → '8'. Keep one decimal only when it carries information.
    static func formatRating(_ rating: Double) -> String {
        if rating == rating.rounded(.towardZero) && abs(rating) < 100 {
            return "\(Int(rating))"
        }
        return String(format: "%.1f", rating)
    }
}

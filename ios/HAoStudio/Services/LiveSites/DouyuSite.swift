// HAo Studio 2.0 — Douyu live site (S4 leg B).
//
// Swift port of the Flutter `lib/shared/platforms/douyu/
// douyu_site.dart` + `douyu_utils.dart` (anonymous-only port of
// Pure Live 3.x `douyu_utils.dart`).
//
// Room detail: GET `https://www.douyu.com/betard/<roomId>`.
// Quality+lines: POST `.../lapi/live/getH5PlayV1/<roomId>` with a
// signed form body. The encryption descriptor comes from GET
// `.../wgapi/livenc/liveweb/websec/getEncryption?did=<did>`, is
// cached for 5 minutes, and the signed body is built from it
// (auth = md5 chain over rand_str/key, salted with
// roomId+timestamp). The same DID must appear in the cookie, the
// signed query and the descriptor fetch — Douyu rejects a
// signature presented by another device.
//
// `rate` is an opaque request code (source is commonly 0), not a
// bitrate; the advertised `multirates` order is kept, never
// re-sorted numerically. CDNs sort with `scdn*` last (Pure Live
// 3.x comparator, verbatim).
//
// Anonymous-only: no account cookie, no session machinery.
// Anonymous H5 play is downgraded by the server when it must be,
// and resolve reports the confirmed rate instead of the requested
// one.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

// MARK: - Signing utils (pure, fixture-testable)

enum DouyuUtils {
    static let defaultDeviceId = "10000000000000000000000000001501"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
    static let encryptionUrl = "https://www.douyu.com/wgapi/livenc/liveweb/websec/getEncryption"
    static let expirySafetySeconds = 30
    static let maximumCacheAgeSeconds = 5 * 60

    /// Creates the browser DID used by a single app process (32 hex
    /// chars).
    static func generateDeviceId() -> String {
        LiveCrypto.randomHex(count: 32)
    }

    /// Validates the server encryption descriptor using second-based
    /// Unix time.
    static func isEncryptionKeyUsable(_ value: [String: Any], nowSeconds: Int, safetySeconds: Int = expirySafetySeconds) -> Bool {
        guard let expiresAt = LiveJSON.asIntOrNil(value["expire_at"]) else {
            return false
        }
        guard let encTime = LiveJSON.asIntOrNil(value["enc_time"]) else {
            return false
        }
        if expiresAt <= nowSeconds + safetySeconds {
            return false
        }
        if encTime <= 0 || encTime > 16 {
            return false
        }
        if LiveJSON.asString(value["key"]).isEmpty {
            return false
        }
        if LiveJSON.asString(value["rand_str"]).isEmpty {
            return false
        }
        if LiveJSON.asString(value["enc_data"]).isEmpty {
            return false
        }
        return true
    }

    static func requestHeaders(roomId: String = "", deviceId: String) -> [String: String] {
        let referer = roomId.isEmpty ? "https://www.douyu.com/" : "https://www.douyu.com/\(roomId)"
        return [
            "accept": "application/json, text/plain, */*",
            "accept-language": "zh-CN,zh;q=0.9,en;q=0.7",
            "origin": "https://www.douyu.com",
            "referer": referer,
            "user-agent": userAgent,
            "cookie": cookieHeader(deviceId: deviceId)
        ]
    }

    /// Anonymous-only cookie: just the device id, twice. No account
    /// fields exist in this project.
    static func cookieHeader(deviceId: String) -> String {
        "dy_did=\(deviceId); acf_did=\(deviceId)"
    }

    /// Builds the form body from an already validated encryption
    /// descriptor. Deterministic unit-test seam for the platform
    /// signing path.
    static func buildSignedData(encryptionKey: [String: Any], roomId: String, timestampSeconds: Int, rate: Int = -1, cdn: String = "", deviceId: String = defaultDeviceId) throws -> String {
        if !isEncryptionKeyUsable(encryptionKey, nowSeconds: timestampSeconds, safetySeconds: 0) {
            throw LiveError.parseFailed("Douyu encryption descriptor is incomplete or expired")
        }
        let key = LiveJSON.asString(encryptionKey["key"])
        let randStr = LiveJSON.asString(encryptionKey["rand_str"])
        guard let encTime = LiveJSON.asIntOrNil(encryptionKey["enc_time"]) else {
            throw LiveError.parseFailed("Douyu encryption descriptor is incomplete or expired")
        }
        let salt = LiveJSON.asInt(encryptionKey["is_special"]) == 1 ? "" : "\(roomId)\(timestampSeconds)"
        var secret = randStr
        for _ in 0..<encTime {
            secret = LiveCrypto.md5Hex("\(secret)\(key)")
        }
        let auth = LiveCrypto.md5Hex("\(secret)\(key)\(salt)")
        return LiveQuery.build([
            ("enc_data", LiveJSON.asString(encryptionKey["enc_data"])),
            ("tt", String(timestampSeconds)),
            ("did", deviceId),
            ("auth", auth),
            ("cdn", cdn),
            ("rate", String(rate)),
            ("hevc", "0"),
            ("fa", "0"),
            ("ive", "0"),
            ("ver", "Douyu_new"),
            ("iar", "0")
        ])
    }
}

// MARK: - Site

final class DouyuLiveSite: LiveSiteResolver {
    var platform: LivePlatform {
        .douyu
    }

    private let fetcher: LiveDataFetcher
    private let deviceId: String
    private var encryptionKey: [String: Any] = [:]
    private var encryptionKeyFetchedAtSeconds: Int?
    private var encryptionKeyDeviceId: String?
    private var encryptionKeyRefreshInFlight: Bool = false
    private var encryptionKeyCompletions: [(Result<Void, Error>) -> Void] = []

    /// Guards the encryption-key cache + in-flight dedup above:
    /// signing runs from URLSession background callbacks and two
    /// concurrent resolves used to mutate the same cache/array
    /// with no lock — a data race that traps. The lock is only
    /// ever held for the state touch, never across a network call
    /// or a completion.
    private let stateLock = NSLock()
    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// Full resolutions banked by a background line walk (b49
    /// sweep #10): `resolveLines` completes on the first playable
    /// line and keeps resolving the rest; the finished resolution
    /// lands here, keyed by room + requested quality id, so the
    /// next resolve for the same room/quality answers at once with
    /// every line. 120 s TTL — well inside the URLs' own expiry —
    /// after which a fresh serial chain runs again.
    private var backgroundResolutions: [String: (resolution: LivePlayUrlResolution, storedAt: Date)] = [:]
    private static let backgroundCacheTTL: TimeInterval = 120

    private func backgroundCacheKey(roomId: String, qualityId: String) -> String {
        "\(roomId)|\(qualityId)"
    }

    private func cachedBackgroundResolution(roomId: String, qualityId: String) -> LivePlayUrlResolution? {
        locked {
            guard let entry = backgroundResolutions[backgroundCacheKey(roomId: roomId, qualityId: qualityId)],
                  Date().timeIntervalSince(entry.storedAt) < DouyuLiveSite.backgroundCacheTTL else {
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
    /// + tier is still in flight (b49fix2 P1-24): a second resolve
    /// used to start a second serial chain, whose early completion
    /// returned the same dead first line — so the driver failed
    /// the room before the first walk banked the other lines.
    /// Joiners wait for the in-flight walk and get its FULL
    /// resolution when it ends. Same join shape as Huya's
    /// roomDetailInFlight.
    private var lineWalkInFlight: [String: [(Result<LivePlayUrlResolution, Error>) -> Void]] = [:]

    init(fetcher: LiveDataFetcher? = nil, deviceId: String? = nil) {
        self.fetcher = fetcher ?? LiveHTTP.defaultFetcher
        self.deviceId = deviceId ?? DouyuUtils.generateDeviceId()
    }

    func makeDanmakuTransport() -> LiveDanmakuTransport {
        DouyuDanmaku()
    }

    // MARK: - Room info

    func roomInfo(roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        let trimmed = roomId.trimmingCharacters(in:.whitespaces)
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
        fetchRoomInfo(roomId: trimmed, completion: completion)
    }

    private func fetchRoomInfo(roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        guard let url = URL(string: "https://www.douyu.com/betard/\(roomId)") else {
            completion(.failure(LiveError.parseFailed("Douyu room url 无效")))
            return
        }
        let request = LiveHTTP.getRequest(url: url, headers: DouyuUtils.requestHeaders(roomId: roomId, deviceId: deviceId))
        fetcher(request) { data, status, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let status = status, (200..<300).contains(status), let data = data, let json = LiveJSON.decodeObject(data) else {
                completion(.failure(LiveError.emptyResponse))
                return
            }
            guard let roomInfo = LiveJSON.asMap(json["room"]) else {
                completion(.failure(LiveError.parseFailed("Douyu betard response has no room")))
                return
            }
            completion(.success(DouyuLiveSite.parseRoomDetail(roomInfo, roomId: roomId)))
        }
    }

    // MARK: - Resolve

    func resolve(roomId: String, quality: LiveQuality?, completion: @escaping (Result<LivePlayUrlResolution, Error>) -> Void) {
        let trimmed = roomId.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            completion(.failure(LiveError.invalidRoomId))
            return
        }
        requestPlayData(roomId: trimmed) { result in
            switch result {
                case .success(let playData):
                    var cdns = DouyuLiveSite.parseCdnCodes(playData)
                    // Pure Live 3.x comparator, verbatim: scdn* sorts LAST.
                    cdns.sort { a, b in
                        let aScdn = a.hasPrefix("scdn")
                        let bScdn = b.hasPrefix("scdn")
                        if aScdn && !bScdn {
                            return false
                        }
                        if !aScdn && bScdn {
                            return true
                        }
                        return false
                    }
                    let qualities = DouyuLiveSite.parsePlayQualities(playData, cdns: cdns)
                    if qualities.isEmpty {
                        completion(.failure(LiveError.noQualities))
                        return
                    }
                    let requested = qualities.first { $0.id == quality?.id } ?? qualities[0]
                    let requestedRate = Int(requested.id) ?? -1
                    // A background walk already banked every line
                    // for this room + tier (b49 sweep #10): answer
                    // at once, no serial chain.
                    if let cached = self.cachedBackgroundResolution(roomId: trimmed, qualityId: requested.id) {
                        completion(.success(cached))
                        return
                    }
                    // (b49fix2 P1-24) A line walk for this room +
                    // tier is still in flight (its first line
                    // already completed early): join it instead of
                    // starting a second serial chain. The joiner
                    // gets the FULL resolution when the walk ends,
                    // so a dead first line no longer fails the
                    // room before the other lines finish resolving.
                    let walkKey = self.backgroundCacheKey(roomId: trimmed, qualityId: requested.id)
                    if self.locked({ self.lineWalkInFlight[walkKey] != nil }) {
                        self.locked { self.lineWalkInFlight[walkKey, default: []].append(completion) }
                        return
                    }
                    self.locked { self.lineWalkInFlight[walkKey] = [] }
                    self.resolveLines(roomId: trimmed, qualities: qualities, requested: requested, requestedRate: requestedRate, cdns: cdns, walkKey: walkKey, completion: completion)
                case .failure(let error):
                    completion(.failure(error))
            }
        }
    }

    /// Serial, fastest first (chen's rule: the first playable source
    /// plays immediately). CDNs are tried one by one for the
    /// requested rate; every success is kept as a line, in server
    /// order. All failing means the room cannot be resolved.
    ///
    /// (b49 sweep #10) The FIRST playable line completes at once —
    /// the driver opens it while the remaining CDNs keep resolving
    /// in the background; when they finish, the full resolution is
    /// cached (see `storeBackgroundResolution` /
    /// `cachedBackgroundResolution`) so the next re-parse
    /// (recovery / quality switch / line fallback) returns every
    /// line without another serial chain.
    private func resolveLines(roomId: String, qualities: [LiveQuality], requested: LiveQuality, requestedRate: Int, cdns: [String], walkKey: String, completion: @escaping (Result<LivePlayUrlResolution, Error>) -> Void) {
        var lines: [LiveLine] = []
        var remainingCdns = cdns
        var appliedRate: Int?
        var deliveredEarly = false
        /// Drain one finished walk (b49fix2 P1-24): the entry is
        /// removed BEFORE the completions run, so a completion
        /// that re-enters resolve() registers a fresh walk
        /// instead of joining a finished one. When the walk
        /// delivered early, the original completion already fired
        /// — bank the full resolution and answer the joiners
        /// only; otherwise answer the original completion too.
        func finishWalk(_ result: Result<LivePlayUrlResolution, Error>) {
            let waiters = self.locked { self.lineWalkInFlight.removeValue(forKey: walkKey) ?? [] }
            switch result {
            case .success(let resolution):
                if deliveredEarly {
                    self.storeBackgroundResolution(resolution, roomId: roomId, qualityId: requested.id)
                } else {
                    completion(.success(resolution))
                }
                for waiter in waiters { waiter(.success(resolution)) }
            case .failure(let error):
                completion(.failure(error))
                for waiter in waiters { waiter(.failure(error)) }
            }
        }
        func buildResolution() -> LivePlayUrlResolution {
            var filled = qualities
            // The lines belong to the tier the server confirmed
            // for them, which may differ from the requested
            // tier; the returned `quality` echoes the
            // confirmed one so the caller can roll back on a
            // mismatch instead of playing a tier it did not ask
            // for under the requested id.
            let effectiveId = appliedRate.map(String.init) ?? requested.id
            let targetId = filled.contains(where: { $0.id == effectiveId }) ? effectiveId : requested.id
            let index = filled.firstIndex(where: { $0.id == targetId }) ?? 0
            filled[index].lines = lines
            return LivePlayUrlResolution.applying(filled[index], in: filled)
        }
        func next() {
            if remainingCdns.isEmpty {
                if lines.isEmpty {
                    finishWalk(.failure(LiveError.transportFailed("斗鱼全部线路均不可用")))
                    return
                }
                finishWalk(.success(buildResolution()))
                return
            }
            let cdn = remainingCdns.removeFirst()
            self.requestPlayData(roomId: roomId, rate: requestedRate, cdn: cdn) { result in
                switch result {
                    case .success(let playData):
                        do {
                            var url = try DouyuLiveSite.parsePlayUrl(playData)
                            if url.contains("expire=300") && url.contains("fcdn=ws") {
                                url += "&expire=0"
                            }
                            if let rate = DouyuLiveSite.confirmedRate(playData["rate"]) {
                                appliedRate = rate
                            }
                            let name = cdn.isEmpty ? "默认线路" : cdn
                            lines.append(LiveLine(name: name, urls: [url], format: DouyuLiveSite.streamFormat(url)))
                            if !deliveredEarly {
                                deliveredEarly = true
                                completion(.success(buildResolution()))
                            }
                            next()
                        } catch {
                            next()
                        }
                    case .failure:
                        next()
                }
            }
        }
        next()
    }

    // MARK: - Play data (signed POST, retried once)

    private func requestPlayData(roomId: String, rate: Int = -1, cdn: String = "", completion: @escaping (Result<[String: Any], Error>) -> Void) {
        requestPlayDataAttempt(roomId: roomId, rate: rate, cdn: cdn, attempt: 0, completion: completion)
    }

    private func requestPlayDataAttempt(roomId: String, rate: Int, cdn: String, attempt: Int, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        sign(roomId: roomId, rate: rate, cdn: cdn, forceRefresh: attempt > 0) { signResult in
            switch signResult {
                case .success(let body):
                    guard let url = URL(string: "https://www.douyu.com/lapi/live/getH5PlayV1/\(roomId)") else {
                        completion(.failure(LiveError.parseFailed("Douyu play url 无效")))
                        return
                    }
                    let request = LiveHTTP.postFormRequest(url: url, body: body, headers: DouyuUtils.requestHeaders(roomId: roomId, deviceId: self.deviceId))
                    self.fetcher(request) { data, status, error in
                        if let error = error {
                            self.retryOrFailPlayData(roomId: roomId, rate: rate, cdn: cdn, attempt: attempt, error: error, completion: completion)
                            return
                        }
                        guard let status = status, status == 200, let data = data, let json = LiveJSON.decodeObject(data) else {
                            self.retryOrFailPlayData(roomId: roomId, rate: rate, cdn: cdn, attempt: attempt, error: LiveError.apiRejected(code: status ?? -1, message: "H5 play HTTP \(status.map(String.init) ?? "unknown")"), completion: completion)
                            return
                        }
                        do {
                            completion(.success(try DouyuLiveSite.parsePlayResponse(json)))
                        } catch {
                            self.retryOrFailPlayData(roomId: roomId, rate: rate, cdn: cdn, attempt: attempt, error: error, completion: completion)
                        }
                    }
                case .failure(let error):
                    self.retryOrFailPlayData(roomId: roomId, rate: rate, cdn: cdn, attempt: attempt, error: error, completion: completion)
            }
        }
    }

    private func retryOrFailPlayData(roomId: String, rate: Int, cdn: String, attempt: Int, error: Error, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        if attempt == 0 {
            requestPlayDataAttempt(roomId: roomId, rate: rate, cdn: cdn, attempt: 1, completion: completion)
        } else {
            completion(.failure(error))
        }
    }

    // MARK: - Signing (descriptor fetch + cache)

    private func sign(roomId: String, rate: Int, cdn: String, forceRefresh: Bool, completion: @escaping (Result<String, Error>) -> Void) {
        refreshEncryptionKey(forceRefresh: forceRefresh) { result in
            switch result {
                case .success:
                    do {
                        let key = self.locked { self.encryptionKey }
                        let body = try DouyuUtils.buildSignedData(
                            encryptionKey: key,
                            roomId: roomId,
                            timestampSeconds: Int(Date().timeIntervalSince1970),
                            rate: rate,
                            cdn: cdn,
                            deviceId: self.deviceId
                        )
                        completion(.success(body))
                    } catch {
                        completion(.failure(error))
                    }
                case .failure(let error):
                    completion(.failure(error))
            }
        }
    }

    private func refreshEncryptionKey(forceRefresh: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        let nowSeconds = Int(Date().timeIntervalSince1970)
        let cachedUsable = locked {
            if !forceRefresh, let fetchedAt = encryptionKeyFetchedAtSeconds, encryptionKeyDeviceId == deviceId {
                return nowSeconds - fetchedAt < DouyuUtils.maximumCacheAgeSeconds && DouyuUtils.isEncryptionKeyUsable(encryptionKey, nowSeconds: nowSeconds)
            }
            return false
        }
        if cachedUsable {
            completion(.success(()))
            return
        }
        let alreadyInFlight = locked {
            encryptionKeyCompletions.append(completion)
            if encryptionKeyRefreshInFlight {
                return true
            }
            encryptionKeyRefreshInFlight = true
            return false
        }
        if alreadyInFlight {
            return
        }
        guard let url = URL(string: DouyuUtils.encryptionUrl) else {
            finishEncryptionKeyRefresh(result:.failure(LiveError.parseFailed("Douyu encryption url 无效")))
            return
        }
        let queryItems = [URLQueryItem(name: "did", value: deviceId)]
        let request = LiveHTTP.getRequest(url: url, queryItems: queryItems, headers: DouyuUtils.requestHeaders(deviceId: deviceId))
        fetcher(request) { data, _, error in
            if let error = error {
                self.finishEncryptionKeyRefresh(result:.failure(error))
                return
            }
            guard let data = data, let json = LiveJSON.decodeObject(data), let rawData = LiveJSON.asMap(json["data"]) else {
                self.finishEncryptionKeyRefresh(result:.failure(LiveError.parseFailed("Douyu encryption response is missing data")))
                return
            }
            if !DouyuUtils.isEncryptionKeyUsable(rawData, nowSeconds: Int(Date().timeIntervalSince1970)) {
                self.finishEncryptionKeyRefresh(result:.failure(LiveError.parseFailed("Douyu encryption descriptor is incomplete or expired")))
                return
            }
            self.locked {
                self.encryptionKey = rawData
                self.encryptionKeyFetchedAtSeconds = Int(Date().timeIntervalSince1970)
                self.encryptionKeyDeviceId = self.deviceId
            }
            self.finishEncryptionKeyRefresh(result:.success(()))
        }
    }

    private func finishEncryptionKeyRefresh(result: Result<Void, Error>) {
        let completions = locked {
            encryptionKeyRefreshInFlight = false
            let completions = encryptionKeyCompletions
            encryptionKeyCompletions = []
            return completions
        }
        for item in completions {
            item(result)
        }
    }

    // MARK: - Pure parsers (fixture-testable, no network)

    /// Builds a room from a betard `room` object.
    static func parseRoomDetail(_ roomInfo: [String: Any], roomId: String) -> LiveRoom {
        let live = isLiveRoomPayload(roomInfo)
        let bizAll = LiveJSON.asMap(roomInfo["room_biz_all"]) ?? [:]
        let hot = LiveJSON.asInt(bizAll["hot"])
        let resolvedId = LiveJSON.asString(roomInfo["room_id"])
        return LiveRoom(
            roomId: resolvedId.isEmpty ? roomId : resolvedId,
            platform:.douyu,
            title: LiveJSON.asString(roomInfo["room_name"]),
            streamer: LiveJSON.asString(roomInfo["owner_name"]),
            avatar: LiveJSON.asString(roomInfo["owner_avatar"]),
            cover: LiveJSON.asString(roomInfo["room_pic"]),
            onlineCount: hot,
            isLive: live,
            link: LivePlatform.douyu.roomLink(roomId: roomId),
            danmakuData: ["roomId": resolvedId.isEmpty ? roomId : resolvedId]
        )
    }

    /// show_status == 1, not a replay loop, title not starting with
    /// 【回放】.
    static func isLiveRoomPayload(_ roomInfo: [String: Any]) -> Bool {
        LiveJSON.asInt(roomInfo["show_status"]) == 1
        && LiveJSON.asInt(roomInfo["videoLoop"]) != 1
        && !LiveJSON.asString(roomInfo["room_name"]).hasPrefix("【回放】")
    }

    static func parsePlayResponse(_ response: [String: Any]) throws -> [String: Any] {
        let errorCode = LiveJSON.asIntOrNil(response["error"]) ?? LiveJSON.asIntOrNil(response["code"]) ?? -1
        if errorCode != 0 {
            let message = LiveJSON.asString(response["msg"]).trimmingCharacters(in:.whitespaces)
            throw LiveError.apiRejected(code: errorCode, message: message.isEmpty ? "H5 play API error \(errorCode)" : "H5 play API error \(errorCode): \(message)")
        }
        guard let rawData = LiveJSON.asMap(response["data"]) else {
            throw LiveError.parseFailed("H5 play response is missing data")
        }
        return rawData
    }

    static func parseCdnCodes(_ data: [String: Any]) -> [String] {
        var result: [String] = []
        if let rawCdns = data["cdnsWithName"] as? [Any] {
            for item in rawCdns {
                guard let entry = item as? [String: Any] else {
                    continue
                }
                let code = LiveJSON.asString(entry["cdn"]).trimmingCharacters(in:.whitespaces)
                if !code.isEmpty && !result.contains(code) {
                    result.append(code)
                }
            }
        }
        let current = LiveJSON.asString(data["rtmp_cdn"]).trimmingCharacters(in:.whitespaces)
        if !current.isEmpty {
            result.removeAll { $0 == current }
            result.insert(current, at: 0)
        }
        if result.isEmpty {
            result.append("")
        }
        return result
    }

    /// Keeps Douyu's advertised `multirates` order. The numeric
    /// `rate` is an opaque request code (source is commonly 0), not
    /// a bitrate; sorting it numerically would reverse source and
    /// low-quality choices.
    static func parsePlayQualities(_ playData: [String: Any], cdns: [String]) -> [LiveQuality] {
        var qualities: [LiveQuality] = []
        if let rates = playData["multirates"] as? [Any] {
            let rateItems = rates.compactMap { $0 as? [String: Any]}
            for (index, item) in rateItems.enumerated() {
                guard let rate = LiveJSON.asIntOrNil(item["rate"]) else {
                    continue
                }
                if qualities.contains(where: { $0.id == String(rate)}) {
                    continue
                }
                let name = LiveJSON.asString(item["name"]).trimmingCharacters(in:.whitespaces)
                let lines = cdns.map { LiveLine(name: $0.isEmpty ? "默认线路" : $0)}
                qualities.append(LiveQuality(id: String(rate), name: name.isEmpty ? "默认" : name, sort: rateItems.count - index, lines: lines))
            }
        }
        if qualities.isEmpty {
            let rate = LiveJSON.asIntOrNil(playData["rate"]) ?? -1
            let lines = cdns.map { LiveLine(name: $0.isEmpty ? "默认线路" : $0)}
            qualities.append(LiveQuality(id: String(rate), name: "默认", sort: 1, lines: lines))
        }
        return qualities
    }

    static func parsePlayUrl(_ data: [String: Any]) throws -> String {
        let live = htmlUnescape(LiveJSON.asString(data["rtmp_live"]).trimmingCharacters(in:.whitespaces))
        // Some current H5 responses return a complete signed FLV
        // address in rtmp_live. It must win over the separate CDN
        // base fields; prefixing a second absolute URL produces a
        // syntactically valid but unopenable input.
        if isPlayableUrl(live) {
            return live
        }
        for baseKey in ["rtmp_url", "flv_url"] {
            let base = htmlUnescape(LiveJSON.asString(data[baseKey]).trimmingCharacters(in:.whitespaces))
            if base.isEmpty || live.isEmpty {
                continue
            }
            let joined = "\(stripTrailingSlashes(base))/\(stripLeadingSlashes(live))"
            if isPlayableUrl(joined) {
                return joined
            }
        }
        for key in ["player_1", "stream_url", "url"] {
            let value = htmlUnescape(LiveJSON.asString(data[key]).trimmingCharacters(in:.whitespaces))
            if isPlayableUrl(value) {
                return value
            }
        }
        let flvUrl = htmlUnescape(LiveJSON.asString(data["flv_url"]).trimmingCharacters(in:.whitespaces))
        if isDirectMediaUrl(flvUrl) {
            return flvUrl
        }
        throw LiveError.parseFailed("H5 play response has no playable URL")
    }

    /// The server-confirmed rate: unlike a bitrate, rate is an
    /// opaque integer identifier. Do not truncate malformed
    /// fractions (e.g. 0.5) into a false source-quality
    /// acknowledgement.
    static func confirmedRate(_ rawRate: Any?) -> Int? {
        if let number = rawRate as? NSNumber {
            let double = number.doubleValue
            if double.isFinite && double == double.rounded() {
                return number.intValue
            }
            return nil
        }
        return Int(LiveJSON.asString(rawRate).trimmingCharacters(in:.whitespaces))
    }

    /// Declared stream facts for one resolved URL. getH5PlayV1
    /// serves FLV; a signed path without an extension is still FLV.
    static func streamFormat(_ url: String) -> String {
        let path = URL(string: url)?.path.lowercased() ?? ""
        if path.hasSuffix(".m3u8") {
            return "hls"
        }
        return "flv"
    }

    private static func isPlayableUrl(_ value: String) -> Bool {
        guard let url = URL(string: value), let host = url.host,!host.isEmpty else {
            return false
        }
        return ["http", "https", "rtmp"].contains(url.scheme ?? "")
    }

    private static func isDirectMediaUrl(_ value: String) -> Bool {
        guard isPlayableUrl(value) else {
            return false
        }
        let path = URL(string: value)?.path.lowercased() ?? ""
        return path.hasSuffix(".flv") || path.hasSuffix(".m3u8") || path.hasSuffix(".mp4")
    }

    private static func stripTrailingSlashes(_ value: String) -> String {
        var result = value
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private static func stripLeadingSlashes(_ value: String) -> String {
        var result = value
        while result.hasPrefix("/") {
            result.removeFirst()
        }
        return result
    }

    private static func htmlUnescape(_ value: String) -> String {
        value
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
    }
}

// MARK: - Lists (recommend / categories / search)
//
// Port of the Flutter `douyu_site.dart` list methods
// (getCategories / getRecommendRooms / getCategoryRooms /
// searchRooms). The room-detail leg (S4-B) left these out; the
// live tab's gateway needs them. Every method completes with []
// on any failure — a list failure is an empty list, never a throw
// out of the completion handler. All parsing is pure + static so
// fixtures can cover it without network.

extension DouyuLiveSite {
    private static let categoryListURL = "https://m.douyu.com/api/cate/list"
    private static let searchShowURL = "https://www.douyu.com/japi/search/api/searchShow"

    /// Category names + ids (Dart `getCategories`): flat cate2
    /// list — this project's area model has no category tree.
    func listCategories(completion: @escaping (Result<[(id: String, name: String)], Error>) -> Void) {
        guard let url = URL(string: DouyuLiveSite.categoryListURL) else {
            completion(.failure(LiveError.emptyResponse))
            return
        }
        LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: DouyuUtils.requestHeaders(deviceId: deviceId), fetcher: fetcher) { json in
            if let areas = DouyuLiveSite.parseCategories(json) {
                completion(.success(areas))
            } else {
                completion(.failure(LiveError.emptyResponse))
            }
        }
    }

    /// Recommended rooms (Dart `getRecommendRooms`): the "全部"
    /// all-page feed, page 1-based here.
    func recommendRooms(page: Int, pageSize: Int, completion: @escaping (Result<[LiveRoom], Error>) -> Void) {
        let currentPage = max(1, page)
        guard let url = URL(string: "https://www.douyu.com/japi/weblist/apinc/allpage/6/\(currentPage)") else {
            completion(.failure(LiveError.emptyResponse))
            return
        }
        LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: DouyuUtils.requestHeaders(deviceId: deviceId), fetcher: fetcher) { json in
            if let rooms = DouyuLiveSite.parseRoomList(json) {
                completion(.success(rooms))
            } else {
                completion(.failure(LiveError.emptyResponse))
            }
        }
    }

    /// Rooms of one category (Dart `getCategoryRooms`): the
    /// mixList feed for `2_<cate2Id>`, same parser as recommend.
    func categoryRooms(areaId: String, page: Int, pageSize: Int, completion: @escaping (Result<[LiveRoom], Error>) -> Void) {
        let currentPage = max(1, page)
        guard let url = URL(string: "https://www.douyu.com/gapi/rkc/directory/mixList/2_\(areaId)/\(currentPage)") else {
            completion(.failure(LiveError.emptyResponse))
            return
        }
        LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: DouyuUtils.requestHeaders(deviceId: deviceId), fetcher: fetcher) { json in
            if let rooms = DouyuLiveSite.parseRoomList(json) {
                completion(.success(rooms))
            } else {
                completion(.failure(LiveError.emptyResponse))
            }
        }
    }

    /// Room search (Dart `searchRooms`): `relateShow` entries.
    /// A non-zero `error` is a failure, answered as `.failure`
    /// (b49fix2 P2-1) instead of an empty list.
    func searchRooms(query: String, page: Int, pageSize: Int, completion: @escaping (Result<[LiveRoom], Error>) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.success([]))
            return
        }
        var headers = DouyuUtils.requestHeaders(deviceId: deviceId)
        headers["referer"] = "https://www.douyu.com/search/"
        guard let url = LiveListURL.url(base: DouyuLiveSite.searchShowURL, params: [
            ("kw", trimmed), ("page", "\(max(1, page))"), ("pageSize", "\(min(50, max(1, pageSize)))")
        ]) else {
            completion(.failure(LiveError.emptyResponse))
            return
        }
        LiveHTTP.fetchJSON(url: url, timeoutSeconds: LiveHTTP.defaultTimeoutSeconds, headers: headers, fetcher: fetcher) { json in
            if let rooms = DouyuLiveSite.parseSearchRooms(json) {
                completion(.success(rooms))
            } else {
                completion(.failure(LiveError.emptyResponse))
            }
        }
    }

    // MARK: - Pure parsers (fixture-testable, no network)

    /// Parses a `cate/list` response (`data.cate2Info[]`) into
    /// flat areas. Nil when the response has no category list.
    static func parseCategories(_ json: [String: Any]?) -> [(id: String, name: String)]? {
        guard let json = json,
              let data = LiveJSON.asMap(json["data"]) else { return nil }
        let subList = LiveJSON.asList(data["cate2Info"])
        guard !subList.isEmpty else { return nil }
        var areas: [(id: String, name: String)] = []
        for item in subList {
            let areaId = LiveJSON.asString(item["cate2Id"])
            let areaName = LiveJSON.asString(item["cate2Name"])
            guard !areaId.isEmpty else { continue }
            areas.append((id: areaId, name: areaName))
        }
        return areas
    }

    /// Parses `data.rl[]` — shared by recommendRooms and
    /// categoryRooms. Only `type == 1` entries are live rooms; an
    /// empty/malformed list is returned as-is, never faked.
    static func parseRoomList(_ json: [String: Any]?) -> [LiveRoom]? {
        guard let json = json,
              let data = LiveJSON.asMap(json["data"]) else { return nil }
        var rooms: [LiveRoom] = []
        for item in LiveJSON.asList(data["rl"]) {
            guard LiveJSON.asInt(item["type"]) == 1 else { continue }
            let roomId = LiveJSON.asString(item["rid"])
            guard !roomId.isEmpty else { continue }
            let avatarRaw = LiveJSON.asString(item["av"])
            // (b49fix2 P1-19) The feed's `av` is already a full
            // URL ending in `_middle.jpg` — prefixing it again
            // built a garbage double-prefixed URL that 404s, so
            // every recommend/category avatar was broken. Use it
            // directly when it starts with http; the prefixed
            // construction survives only for a bare avatar id.
            let avatar = avatarRaw.isEmpty ? "" : (avatarRaw.hasPrefix("http") ? avatarRaw : "https://apic.douyucdn.cn/upload/\(avatarRaw)_middle.jpg")
            rooms.append(LiveRoom(
                roomId: roomId, platform: .douyu,
                title: LiveJSON.asString(item["rn"]),
                streamer: LiveJSON.asString(item["nn"]),
                avatar: avatar,
                cover: LiveJSON.asString(item["rs16"]),
                onlineCount: LiveJSON.asInt(item["ol"]),
                isLive: true,
                link: "https://www.douyu.com/\(roomId)"))
        }
        return rooms
    }

    /// Parses a searchShow response (`data.relateShow[]`). Nil
    /// when the response is not an object or `error` is non-zero.
    static func parseSearchRooms(_ json: [String: Any]?) -> [LiveRoom]? {
        guard let json = json else { return nil }
        guard LiveJSON.asInt(json["error"]) == 0 else { return nil }
        guard let data = LiveJSON.asMap(json["data"]) else { return nil }
        var rooms: [LiveRoom] = []
        for item in LiveJSON.asList(data["relateShow"]) {
            let roomId = LiveJSON.asString(item["rid"])
            guard !roomId.isEmpty else { continue }
            let isLive = LiveJSON.asInt(item["isLive"]) == 1 && LiveJSON.asInt(item["roomType"]) == 0
            rooms.append(LiveRoom(
                roomId: roomId, platform: .douyu,
                title: LiveJSON.asString(item["roomName"]),
                streamer: LiveJSON.asString(item["nickName"]),
                avatar: LiveJSON.asString(item["avatar"]),
                cover: LiveJSON.asString(item["roomSrc"]),
                onlineCount: LiveJSON.asInt(item["hot"]),
                isLive: isLive,
                link: "https://www.douyu.com/\(roomId)"))
        }
        return rooms
    }
}

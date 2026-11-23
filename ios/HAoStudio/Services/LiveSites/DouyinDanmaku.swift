// HAo Studio 2.0 — Douyin danmaku (S4 leg B).
//
// Swift port of the Flutter `lib/shared/platforms/douyin/
// douyin_danmaku.dart` + `douyin_xbogus.dart` + `proto/douyin.proto`:
//   WS wss://webcast100-ws-web-lq.douyin.com/webcast/im/push/v2/
//   (alt host webcast100-ws-web-hl)
//   PushFrame / Response / ChatMessage protobuf; payload usually gzip.
//   WS URL signed by getSignature(roomId, userId) — md5 of the param
//   string, then X-Bogus.
//   Handshake headers: Cookie (ttwid / msToken / ...), Origin +
//   Referer https://live.douyin.com.
//
// The WS handshake REQUIRES the `ttwid` cookie. A browser/WKWebView
// JS WebSocket cannot send Cookie headers — only a native WS can,
// which is why this transport runs on `URLSessionWebSocketTask`.
//
// Protobuf: hand-written minimal decoder (varint + length-delimited
// + fixed32/64 + skipping) — only what danmaku needs. No
// SwiftProtobuf: adding a dependency requires Xcode project
// changes, unverifiable without a compiler. The writer half exists
// so the transport can encode its own heartbeat/ack frames and so
// tests can build fixtures.
//
// Args for `start` (from the room detail's `danmakuData`):
//   - `roomId`: long numeric room id (required).
//   - `webRid`: short room id (defaults to `roomId`).
//   - `userId`: anonymous viewer id; generated (7.3e18–8e18) if absent.
//   - `cookie`: session cookie; when absent a HEAD request to
//     https://live.douyin.com/<webRid> warms it up from `set-cookie`
//     (ttwid / __ac_nonce / msToken).
//
// Best-effort: handshake/signing failure reports `onClose`; the
// video keeps playing. Malformed frames are dropped, never thrown.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

// MARK: - Minimal protobuf

enum DouyinProtobufError: Error {
    case truncated
    case invalidWireType
    case invalidVarint
}

/// Wire reader: varint (0), 64-bit (1), length-delimited (2),
/// 32-bit (5). Unknown fields are skipped by wire type; a truncated
/// field throws.
struct DouyinProtoReader {
    var bytes: [UInt8]
    var position: Int = 0

    var isAtEnd: Bool {
        position >= bytes.count
    }

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift = 0
        while true {
            if position >= bytes.count {
                throw DouyinProtobufError.truncated
            }
            if shift >= 64 {
                throw DouyinProtobufError.invalidVarint
            }
            let byte = bytes[position]
            position += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
        }
    }

    /// Returns nil at the end of the message, or on an illegal tag 0.
    mutating func readTag() throws -> (field: Int, wire: Int)? {
        if isAtEnd {
            return nil
        }
        let tag = try readVarint()
        let field = Int(tag >> 3)
        let wire = Int(tag & 0x7)
        if field == 0 {
            return nil
        }
        if wire != 0 && wire != 1 && wire != 2 && wire != 5 {
            throw DouyinProtobufError.invalidWireType
        }
        return (field, wire)
    }

    mutating func readLengthDelimited() throws -> Data {
        let length = try readVarint()
        if length > UInt64(bytes.count - position) {
            throw DouyinProtobufError.truncated
        }
        let start = position
        position += Int(length)
        return Data(bytes[start..<position])
    }

    mutating func readFixed32() throws -> UInt32 {
        if position + 4 > bytes.count {
            throw DouyinProtobufError.truncated
        }
        let value = UInt32(bytes[position])
            | (UInt32(bytes[position + 1]) << 8)
            | (UInt32(bytes[position + 2]) << 16)
            | (UInt32(bytes[position + 3]) << 24)
        position += 4
        return value
    }

    mutating func readFixed64() throws -> UInt64 {
        if position + 8 > bytes.count {
            throw DouyinProtobufError.truncated
        }
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(bytes[position + i]) << (i * 8)
        }
        position += 8
        return value
    }

    mutating func skipField(wire: Int) throws {
        switch wire {
        case 0:
            _ = try readVarint()
        case 1:
            _ = try readFixed64()
        case 2:
            _ = try readLengthDelimited()
        case 5:
            _ = try readFixed32()
        default:
            throw DouyinProtobufError.invalidWireType
        }
    }
}

enum DouyinProtobufWriter {
    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        while true {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 {
                byte |= 0x80
            }
            out.append(byte)
            if value == 0 {
                return out
            }
        }
    }

    static func tag(field: Int, wire: Int) -> [UInt8] {
        varint(UInt64((field << 3) | wire))
    }

    static func varintField(field: Int, _ value: UInt64) -> [UInt8] {
        tag(field: field, wire: 0) + varint(value)
    }

    static func bytesField(field: Int, _ value: [UInt8]) -> [UInt8] {
        tag(field: field, wire: 2) + varint(UInt64(value.count)) + value
    }

    static func stringField(field: Int, _ value: String) -> [UInt8] {
        bytesField(field: field, [UInt8](value.utf8))
    }
}

// MARK: - Message structs (field numbers from douyin.proto)

struct DouyinPushFrame {
    var seqId: Int64 = 0
    var logId: Int64 = 0
    var service: String = ""
    var method: String = ""
    var headersList: [String] = []
    var payloadEncoding: String = ""
    var payloadType: String = ""
    var payload: Data = Data()

    static func decode(_ data: Data) throws -> DouyinPushFrame {
        var reader = DouyinProtoReader(data)
        var frame = DouyinPushFrame()
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, 0):
                frame.seqId = Int64(bitPattern: try reader.readVarint())
            case (2, 0):
                frame.logId = Int64(bitPattern: try reader.readVarint())
            case (3, 2):
                frame.service = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (4, 2):
                frame.method = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (5, 2):
                frame.headersList.append(String(decoding: try reader.readLengthDelimited(), as: UTF8.self))
            case (6, 2):
                frame.payloadEncoding = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (7, 2):
                frame.payloadType = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (8, 2):
                frame.payload = try reader.readLengthDelimited()
            default:
                try reader.skipField(wire: wire)
            }
        }
        return frame
    }

    /// Encodes only the fields the transport sets (heartbeat/ack
    /// frames carry payloadType, and acks add logId + payload).
    func encode() -> Data {
        var out: [UInt8] = []
        if seqId != 0 {
            out += DouyinProtobufWriter.varintField(field: 1, UInt64(bitPattern: seqId))
        }
        if logId != 0 {
            out += DouyinProtobufWriter.varintField(field: 2, UInt64(bitPattern: logId))
        }
        if !service.isEmpty {
            out += DouyinProtobufWriter.stringField(field: 3, service)
        }
        if !method.isEmpty {
            out += DouyinProtobufWriter.stringField(field: 4, method)
        }
        for header in headersList {
            out += DouyinProtobufWriter.stringField(field: 5, header)
        }
        if !payloadEncoding.isEmpty {
            out += DouyinProtobufWriter.stringField(field: 6, payloadEncoding)
        }
        if !payloadType.isEmpty {
            out += DouyinProtobufWriter.stringField(field: 7, payloadType)
        }
        if !payload.isEmpty {
            out += DouyinProtobufWriter.bytesField(field: 8, [UInt8](payload))
        }
        return Data(out)
    }
}

struct DouyinResponseMessage {
    var method: String = ""
    var payload: Data = Data()
    var msgId: Int64 = 0
    var msgType: Int64 = 0
    var offset: Int64 = 0
    var needWrdsStore: Bool = false
    var wrdsVersion: Int64 = 0
    var wrdsSubKey: String = ""

    static func decode(_ data: Data) throws -> DouyinResponseMessage {
        var reader = DouyinProtoReader(data)
        var message = DouyinResponseMessage()
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, 2):
                message.method = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (2, 2):
                message.payload = try reader.readLengthDelimited()
            case (3, 0):
                message.msgId = Int64(bitPattern: try reader.readVarint())
            case (4, 0):
                message.msgType = Int64(bitPattern: try reader.readVarint())
            case (5, 0):
                message.offset = Int64(bitPattern: try reader.readVarint())
            case (6, 0):
                message.needWrdsStore = try reader.readVarint() != 0
            case (7, 0):
                message.wrdsVersion = Int64(bitPattern: try reader.readVarint())
            case (8, 2):
                message.wrdsSubKey = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            default:
                try reader.skipField(wire: wire)
            }
        }
        return message
    }
}

struct DouyinResponse {
    var messages: [DouyinResponseMessage] = []
    var cursor: String = ""
    var fetchInterval: Int64 = 0
    var now: Int64 = 0
    var internalExt: String = ""
    var fetchType: Int64 = 0
    var routeParams: String = ""
    var heartbeatDuration: Int64 = 0
    var needAck: Bool = false
    var pushServer: String = ""
    var liveCursor: String = ""
    var historyNoMore: Bool = false

    static func decode(_ data: Data) throws -> DouyinResponse {
        var reader = DouyinProtoReader(data)
        var response = DouyinResponse()
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, 2):
                response.messages.append(try DouyinResponseMessage.decode(reader.readLengthDelimited()))
            case (2, 2):
                response.cursor = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (3, 0):
                response.fetchInterval = Int64(bitPattern: try reader.readVarint())
            case (4, 0):
                response.now = Int64(bitPattern: try reader.readVarint())
            case (5, 2):
                response.internalExt = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (6, 0):
                response.fetchType = Int64(bitPattern: try reader.readVarint())
            case (7, 2):
                response.routeParams = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (8, 0):
                response.heartbeatDuration = Int64(bitPattern: try reader.readVarint())
            case (9, 0):
                response.needAck = try reader.readVarint() != 0
            case (10, 2):
                response.pushServer = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (11, 2):
                response.liveCursor = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (12, 0):
                response.historyNoMore = try reader.readVarint() != 0
            default:
                try reader.skipField(wire: wire)
            }
        }
        return response
    }
}

struct DouyinChatCommon {
    var method: String = ""
    var msgId: Int64 = 0
    var roomId: Int64 = 0
    var createTime: Int64 = 0

    static func decode(_ data: Data) throws -> DouyinChatCommon {
        var reader = DouyinProtoReader(data)
        var common = DouyinChatCommon()
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, 2):
                common.method = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (2, 0):
                common.msgId = Int64(bitPattern: try reader.readVarint())
            case (3, 0):
                common.roomId = Int64(bitPattern: try reader.readVarint())
            case (4, 0):
                common.createTime = Int64(bitPattern: try reader.readVarint())
            default:
                try reader.skipField(wire: wire)
            }
        }
        return common
    }
}

struct DouyinChatUser {
    var id: Int64 = 0
    var shortId: Int64 = 0
    var nickName: String = ""

    static func decode(_ data: Data) throws -> DouyinChatUser {
        var reader = DouyinProtoReader(data)
        var user = DouyinChatUser()
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, 0):
                user.id = Int64(bitPattern: try reader.readVarint())
            case (2, 0):
                user.shortId = Int64(bitPattern: try reader.readVarint())
            case (3, 2):
                user.nickName = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            default:
                try reader.skipField(wire: wire)
            }
        }
        return user
    }
}

struct DouyinChatMessage {
    var common: DouyinChatCommon?
    var user: DouyinChatUser?
    var content: String = ""

    static func decode(_ data: Data) throws -> DouyinChatMessage {
        var reader = DouyinProtoReader(data)
        var message = DouyinChatMessage()
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, 2):
                message.common = try DouyinChatCommon.decode(reader.readLengthDelimited())
            case (2, 2):
                message.user = try DouyinChatUser.decode(reader.readLengthDelimited())
            case (3, 2):
                message.content = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            default:
                try reader.skipField(wire: wire)
            }
        }
        return message
    }
}

// MARK: - X-Bogus

/// Port of `douyin_xbogus.dart`: RC4 with a single-byte key, then a
/// custom-alphabet base64 over the 12-byte signed blob. `random1` /
/// `random2` are injectable so tests can assert a deterministic
/// signature; production passes nil (secure randoms).
enum DouyinXBogus {
    static let alphabet = "Dkdpgh4ZKsQB80/Mfvw36XI1R25+WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe"
    static let standardAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    /// RC4 (KSA + PRGA) with a single-byte key.
    static func rc4Encrypt(key: Int, data: inout [UInt8]) {
        var s = [Int](0..<256)
        var j = 0
        for i in 0..<256 {
            j = (j + s[i] + key) & 0xFF
            s.swapAt(i, j)
        }
        var ii = 0
        j = 0
        for k in data.indices {
            ii = (ii + 1) & 0xFF
            j = (j + s[ii]) & 0xFF
            s.swapAt(ii, j)
            data[k] ^= UInt8(s[(s[ii] + s[j]) & 0xFF])
        }
    }

    /// Standard base64 groups of 3 -> 4 chars, with each output
    /// character remapped through the custom alphabet. The input is
    /// always 12 bytes (a multiple of 3); a trailing partial group
    /// is dropped rather than padded.
    static func encodeBase64(_ data: [UInt8]) -> String {
        let standard = [UInt8](standardAlphabet.utf8)
        let custom = [UInt8](alphabet.utf8)
        var lookup = [UInt8](repeating: 0, count: 128)
        for i in 0..<64 {
            lookup[Int(standard[i])] = custom[i]
        }
        var out: [UInt8] = []
        var i = 0
        while i + 2 < data.count {
            let b0 = data[i]
            let b1 = data[i + 1]
            let b2 = data[i + 2]
            out.append(lookup[Int(standard[Int((b0 >> 2) & 0x3F)])])
            out.append(lookup[Int(standard[Int(((b0 << 4) | (b1 >> 4)) & 0x3F)])])
            out.append(lookup[Int(standard[Int(((b1 << 2) | (b2 >> 6)) & 0x3F)])])
            out.append(lookup[Int(standard[Int(b2 & 0x3F)])])
            i += 3
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// MD5 of the 16 bytes parsed from a 32-char hex string, bytes
    /// 14 and 15. Returns nil on a malformed hex string.
    static func md5Last2(_ hexStr: String) -> [UInt8]? {
        if hexStr.count != 32 {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        for i in 0..<16 {
            let start = hexStr.index(hexStr.startIndex, offsetBy: i * 2)
            let end = hexStr.index(start, offsetBy: 2)
            guard let byte = UInt8(hexStr[start..<end], radix: 16) else {
                return nil
            }
            bytes.append(byte)
        }
        let digest = LiveCrypto.md5(Data(bytes))
        if digest.count < 16 {
            return nil
        }
        return [digest[14], digest[15]]
    }

    /// `msStub` must be a 32-char MD5 hex string. Returns nil when it
    /// is not (callers treat that as "no signature").
    static func generate(msStub: String, counter: Int, random1: Int? = nil, random2: Int? = nil) -> String? {
        if msStub.count != 32 {
            return nil
        }
        let random1 = random1 ?? Int.random(in: 0..<256)
        let random2 = random2 ?? Int.random(in: 0..<255)
        let header = 0x40 | (random1 & 0x1F)
        guard let md5Bytes = md5Last2(msStub) else {
            return nil
        }
        var payload: [UInt8] = [
            UInt8(counter & 0x3F),
            0,
            1,
            0x0E,
            0x45,
            0x3F,
            md5Bytes[0],
            md5Bytes[1],
            UInt8(random2),
            0
        ]
        var checksum: UInt8 = 0
        for i in 0..<9 {
            checksum ^= payload[i]
        }
        payload[9] = checksum
        rc4Encrypt(key: random2, data: &payload)
        var finalData: [UInt8] = [UInt8(header), UInt8(random2)]
        finalData.append(contentsOf: payload)
        return encodeBase64(finalData)
    }
}

// MARK: - Args

struct DouyinDanmakuArgs {
    var webRid: String
    var roomId: String
    var userId: String
    var cookie: String

    init(webRid: String = "", roomId: String = "", userId: String = "", cookie: String = "") {
        self.webRid = webRid
        self.roomId = roomId
        self.userId = userId
        self.cookie = cookie
    }

    static func fromMap(_ args: [String: Any]) -> DouyinDanmakuArgs {
        let roomId = LiveJSON.asString(args["roomId"])
        return DouyinDanmakuArgs(
            webRid: LiveJSON.asString(args["webRid"]).isEmpty ? roomId : LiveJSON.asString(args["webRid"]),
            roomId: roomId,
            userId: LiveJSON.asString(args["userId"]),
            cookie: LiveJSON.asString(args["cookie"])
        )
    }
}

// MARK: - Transport

final class DouyinDanmaku: LiveDanmakuTransportBase {
    static let webSocketPath = "/webcast/im/push/v2/"
    static let webSocketHosts = [
        "webcast100-ws-web-lq.douyin.com",
        "webcast100-ws-web-hl.douyin.com"
    ]
    static let heartbeatSeconds = 10

    private var args = DouyinDanmakuArgs()

    init(socket: LiveDanmakuSocket? = nil) {
        super.init()
        self._injectedSocket = socket
    }

    override func start(danmakuData: [String: Any]) {
        let generation = beginStart()
        args = DouyinDanmakuArgs.fromMap(danmakuData)
        if args.roomId.isEmpty {
            onClose?()
            return
        }
        // Anonymous viewer id (Pure Live douyin_site L975-990:
        // 7.3e18–8e18). Built digit-by-digit: Random.nextInt caps
        // at 2^32.
        if args.userId.isEmpty {
            args = DouyinDanmakuArgs(
                webRid: args.webRid,
                roomId: args.roomId,
                userId: DouyinLiveSite.generateAnonymousUserUniqueId(),
                cookie: args.cookie
            )
        }
        // Warm up the ttwid cookie when the room detail did not
        // supply one.
        if args.cookie.trimmingCharacters(in: .whitespaces).isEmpty {
            DouyinDanmaku.warmUpCookie(webRid: args.webRid) { [weak self] cookie in
                guard let self = self, generation == self._generation, !self._stopped else {
                    return
                }
                if !cookie.isEmpty {
                    self.args = DouyinDanmakuArgs(
                        webRid: self.args.webRid,
                        roomId: self.args.roomId,
                        userId: self.args.userId,
                        cookie: cookie
                    )
                }
                self.connect(generation: generation)
            }
            return
        }
        connect(generation: generation)
    }

    override func heartbeat() {
        var frame = DouyinPushFrame()
        frame.payloadType = "hb"
        sendSocket(frame.encode())
    }

    private func joinRoom() {
        var frame = DouyinPushFrame()
        frame.payloadType = "hb"
        sendSocket(frame.encode())
    }

    private func connect(generation: Int) {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        var components = URLComponents()
        components.scheme = "wss"
        components.host = DouyinDanmaku.webSocketHosts[0]
        components.path = DouyinDanmaku.webSocketPath
        components.queryItems = [
            URLQueryItem(name: "app_name", value: "douyin_web"),
            URLQueryItem(name: "version_code", value: DouyinRequestParams.versionCodeValue),
            URLQueryItem(name: "webcast_sdk_version", value: DouyinRequestParams.sdkVersion),
            URLQueryItem(name: "update_version_code", value: DouyinRequestParams.sdkVersion),
            URLQueryItem(name: "compress", value: "gzip"),
            URLQueryItem(name: "cursor", value: "h-1_t-\(timestamp)_r-1_d-1_u-1"),
            URLQueryItem(name: "host", value: "https://live.douyin.com"),
            URLQueryItem(name: "aid", value: "6383"),
            URLQueryItem(name: "live_id", value: "1"),
            URLQueryItem(name: "did_rule", value: "3"),
            URLQueryItem(name: "debug", value: "false"),
            URLQueryItem(name: "maxCacheMessageNumber", value: "20"),
            URLQueryItem(name: "endpoint", value: "live_pc"),
            URLQueryItem(name: "support_wrds", value: "1"),
            URLQueryItem(name: "im_path", value: "/webcast/im/fetch/"),
            URLQueryItem(name: "user_unique_id", value: args.userId),
            URLQueryItem(name: "device_platform", value: "web"),
            URLQueryItem(name: "cookie_enabled", value: "true"),
            URLQueryItem(name: "screen_width", value: "1920"),
            URLQueryItem(name: "screen_height", value: "1080"),
            URLQueryItem(name: "browser_language", value: "zh-CN"),
            URLQueryItem(name: "browser_platform", value: "Win32"),
            URLQueryItem(name: "browser_name", value: "Mozilla"),
            URLQueryItem(name: "browser_version", value: DouyinRequestParams.browserVersion),
            URLQueryItem(name: "browser_online", value: "true"),
            URLQueryItem(name: "tz_name", value: "Asia/Shanghai"),
            URLQueryItem(name: "identity", value: "audience"),
            URLQueryItem(name: "room_id", value: args.roomId),
            URLQueryItem(name: "need_persist_msg_count", value: "15"),
            URLQueryItem(name: "heartbeatDuration", value: "0")
        ]
        let sign = DouyinDanmaku.getSignature(args.roomId, args.userId)
        guard let baseUrl = components.url else {
            onClose?()
            return
        }
        let serverUrls = DouyinDanmaku.buildServerUrls(baseUrl, signature: sign)
        guard let url = serverUrls.first.flatMap({ URL(string: $0) }) else {
            onClose?()
            return
        }
        _reconnect = { [weak self] in
            guard let self = self else {
                return
            }
            self.connect(generation: generation)
        }
        connectSocket(url: url, headers: DouyinDanmaku.buildHandshakeHeaders(args), generation: generation, onSocketMessage: { [weak self] data in
            self?.decodeMessage(data)
        }, onSocketReady: { [weak self] in
            guard let self = self else {
                return
            }
            self._connected = true
            self.onReady?()
            self.joinRoom()
            self.startHeartbeat(every: DouyinDanmaku.heartbeatSeconds)
        })
    }

    /// Equivalent signed URLs for every current web IM edge. The
    /// signature alphabet contains `+` and `/`, so it must go through
    /// query encoding (appending it raw turns `+` into a space on
    /// some stacks).
    static func buildServerUrls(_ baseUrl: URL, signature: String) -> [String] {
        var signed = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false)
        var items = signed?.queryItems ?? []
        items.append(URLQueryItem(name: "signature", value: signature))
        signed?.queryItems = items
        guard let signedUrl = signed?.url else {
            return []
        }
        return webSocketHosts.map { host in
            var components = URLComponents(url: signedUrl, resolvingAgainstBaseURL: false)
            components?.scheme = "wss"
            components?.host = host
            return components?.url?.absoluteString ?? signedUrl.absoluteString
        }
    }

    static func buildHandshakeHeaders(_ args: DouyinDanmakuArgs) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": DouyinRequestParams.kDefaultUserAgent,
            "Origin": "https://live.douyin.com",
            "Referer": "https://live.douyin.com/\(args.webRid)"
        ]
        if !args.cookie.trimmingCharacters(in: .whitespaces).isEmpty {
            headers["Cookie"] = args.cookie
        }
        return headers
    }

    /// X-Bogus signature for the WS URL (Pure Live L304-311).
    static func getSignature(_ roomId: String, _ uniqueId: String) -> String {
        let params: [(String, String)] = [
            ("live_id", "1"),
            ("aid", "6383"),
            ("version_code", DouyinRequestParams.versionCodeValue),
            ("webcast_sdk_version", DouyinRequestParams.sdkVersion),
            ("room_id", roomId),
            ("sub_room_id", ""),
            ("sub_channel_id", ""),
            ("did_rule", "3"),
            ("user_unique_id", uniqueId),
            ("device_platform", "web"),
            ("device_type", ""),
            ("ac", ""),
            ("identity", "audience")
        ]
        let sigParam = params.map { "\($0.0)=\($0.1)" }.joined(separator: ",")
        let md5SigParam = LiveCrypto.md5Hex(sigParam)
        return DouyinXBogus.generate(msStub: md5SigParam, counter: 1) ?? ""
    }

    /// HEAD `https://live.douyin.com/<webRid>` and collect ttwid /
    /// __ac_nonce / msToken from `set-cookie`. Best-effort: '' on
    /// failure (the handshake may still succeed without a cookie for
    /// some rooms). Runs through the shared URLSession, not the
    /// injectable fetcher — the fetcher type carries no response
    /// headers, so set-cookie cannot be read through it.
    static func warmUpCookie(webRid: String, completion: @escaping (String) -> Void) {
        guard let url = URL(string: "https://live.douyin.com/\(webRid)") else {
            completion("")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: LiveHTTP.defaultTimeoutSeconds)
        request.httpMethod = "HEAD"
        request.setValue(DouyinRequestParams.kDefaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let task = URLSession.shared.dataTask(with: request) { _, _, _ in
            let wanted = ["ttwid", "__ac_nonce", "msToken"]
            let pairs = (HTTPCookieStorage.shared.cookies(for: url) ?? [])
                .filter { wanted.contains($0.name) }
                .map { "\($0.name)=\($0.value)" }
            completion(pairs.joined(separator: "; "))
        }
        task.resume()
    }

    // MARK: - Frame decode

    func decodeMessage(_ data: Data) {
        do {
            let frame = try DouyinPushFrame.decode(data)
            let encodedPayload = frame.payload
            let isGzip = frame.payloadEncoding.lowercased() == "gzip"
                || (encodedPayload.count >= 2 && encodedPayload[0] == 0x1F && encodedPayload[1] == 0x8B)
            let decompressed = isGzip ? try LiveInflate.inflateGzip(encodedPayload) : encodedPayload
            let response = try DouyinResponse.decode(decompressed)
            if response.needAck {
                sendAck(logId: frame.logId, internalExt: response.internalExt)
            }
            for message in response.messages {
                if message.method == "WebcastChatMessage" {
                    unpackChatMessage(message.payload)
                }
                // WebcastRoomUserSeqMessage (online count) has no field
                // in DanmakuMessage; skipped.
            }
        } catch {
            // Best-effort: a bad frame must not kill the room.
        }
    }

    private func unpackChatMessage(_ payload: Data) {
        do {
            let chatMessage = try DouyinChatMessage.decode(payload)
            let commonRoomId = chatMessage.common.map { String($0.roomId) } ?? ""
            // Only filter when a room is configured: an
            // unconfigured client (empty roomId, e.g. in tests)
            // has no room to filter against, and dropping
            // everything would silence all chat.
            if !commonRoomId.isEmpty && commonRoomId != "0" && !args.roomId.isEmpty && commonRoomId != args.roomId {
                return
            }
            let text = chatMessage.content
            if text.isEmpty {
                return
            }
            onMessage?(DanmakuMessage(
                userName: chatMessage.user?.nickName ?? "",
                text: text
            ))
        } catch {
            // Best-effort: a bad chat message must not kill the room.
        }
    }

    private func sendAck(logId: Int64, internalExt: String) {
        var frame = DouyinPushFrame()
        frame.payloadType = "ack"
        frame.logId = logId
        frame.payload = Data(internalExt.utf8)
        sendSocket(frame.encode())
    }
}

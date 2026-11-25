// HAo Studio 2.0 — Bilibili danmaku (S4 leg B).
//
// Swift port of the Flutter `lib/shared/platforms/bilibili/
// bilibili_danmaku.dart`:
//   WS wss://broadcastlv.chat.bilibili.com/sub (or a host from
//   getDanmuInfo's host_list)
//   16-byte big-endian frame header:
//     [packetLen:u32][headerLen:u16][protover:u16][operation:u32][seq:u32]
//   auth packet (op 7): {uid, roomid, protover, buvid, key: token, ...}
//   heartbeat (op 2, empty body) every 30 s
//   op 3: popularity heartbeat (skipped); op 5: notification (plain
//   JSON, or a zlib (protover 2) compressed packet stream); op 8:
//   auth ack — only after code == 0 is the transport connected.
//
// DEVIATION (documented, needs live verification at final
// packaging): the Flutter join payload sends protover 3 (brotli),
// but there is no Brotli decoder available without a new
// dependency/framework, and this leg may not add one. The Swift
// join payload therefore sends protover 0 (plain JSON frames); the
// decoder handles protover 0 fully and protover 2 (zlib, via
// LiveInflate). Protover-3 frames are dropped, never crash. The
// server is expected to honour protover 0, but that is unverified.
//
// Credentials come from `danmakuData` (`token`, `serverUrls` /
// `hostList`, `buvid`, `uid`, `cookie`) when the room detail
// supplied them; otherwise they are discovered here via unsigned
// GET getDanmuInfo (max 3 refreshes, best-effort).
//
// Malformed frames are dropped, never thrown out of the transport.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation
import Security

// MARK: - Args

/// Danmaku credentials for one Bilibili room, stored as a plain map
/// in `LiveRoom.danmakuData` via `dictionary`.
struct BilibiliDanmakuArgs {
    var roomId: Int
    var token: String
    var serverUrls: [String]
    var buvid: String
    var uid: Int
    var cookie: String

    init(roomId: Int = 0, token: String = "", serverUrls: [String] = [], buvid: String = "", uid: Int = 0, cookie: String = "") {
        self.roomId = roomId
        self.token = token
        self.serverUrls = serverUrls
        self.buvid = buvid
        self.uid = uid
        self.cookie = cookie
    }

    /// The map form stored in `LiveRoom.danmakuData` / passed to
    /// `start(danmakuData:)`.
    var dictionary: [String: Any] {
        [
            "roomId": roomId,
            "token": token,
            "serverUrls": serverUrls,
            "buvid": buvid,
            "uid": uid,
            "cookie": cookie
        ]
    }

    static func fromMap(_ args: [String: Any]) -> BilibiliDanmakuArgs {
        var serverUrls: [String] = []
        if let rawUrls = args["serverUrls"] as? [Any] {
            for item in rawUrls {
                let value = LiveJSON.asString(item)
                if !value.isEmpty {
                    serverUrls.append(value)
                }
            }
        }
        // host_list entries: {host, wss_port} -> wss://host:port/sub
        if let hostList = args["hostList"] as? [Any] {
            for item in hostList {
                guard let hostMap = item as? [String: Any] else {
                    continue
                }
                let host = LiveJSON.asString(hostMap["host"]).trimmingCharacters(in: .whitespaces)
                let port = LiveJSON.asString(hostMap["wss_port"])
                if !host.isEmpty, !port.isEmpty {
                    serverUrls.append("wss://\(host):\(port)/sub")
                }
            }
        }
        return BilibiliDanmakuArgs(
            roomId: LiveJSON.asInt(args["roomId"]),
            token: LiveJSON.asString(args["token"]),
            serverUrls: serverUrls,
            buvid: LiveJSON.asString(args["buvid"]),
            uid: LiveJSON.asInt(args["uid"]),
            cookie: LiveJSON.asString(args["cookie"])
        )
    }
}

// MARK: - Transport

final class BilibiliDanmaku: LiveDanmakuTransportBase {
    static let packetHeaderLength = 16
    static let maxTransportMessageBytes = 8 * 1024 * 1024
    static let maxDecompressedMessageBytes = 16 * 1024 * 1024
    static let maxPacketsPerMessage = 4096
    static let maxCompressedNestingDepth = 2
    static let heartbeatSeconds = 30
    static let authTimeoutSeconds = 8
    static let defaultServerUrl = "wss://broadcastlv.chat.bilibili.com/sub"
    static let danmuInfoUrl = "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo"

    private let fetcher: LiveDataFetcher
    private var args = BilibiliDanmakuArgs()
    private var credentialRefreshCount = 0
    private var refreshingCredentials = false
    private var authWorkItem: DispatchWorkItem?
    /// Index into the server endpoints (b49 sweep #27): each
    /// reconnect advances to the next endpoint instead of
    /// retrying the same dead host forever. Reset on start().
    private var endpointIndex = 0

    init(fetcher: LiveDataFetcher? = nil, socket: LiveDanmakuSocket? = nil) {
        self.fetcher = fetcher ?? LiveHTTP.defaultFetcher
        super.init()
        self._injectedSocket = socket
    }

    override func start(danmakuData: [String: Any]) {
        let generation = beginStart()
        args = BilibiliDanmakuArgs.fromMap(danmakuData)
        credentialRefreshCount = 0
        refreshingCredentials = false
        endpointIndex = 0
        if args.roomId == 0 {
            onClose?()
            return
        }
        if args.token.isEmpty {
            discoverCredentials(generation: generation, attempt: 0)
            return
        }
        connect(args: args, generation: generation)
    }

    override func heartbeat() {
        sendSocket(BilibiliDanmaku.encodeData("", action: 2))
    }

    override func stop() {
        authWorkItem?.cancel()
        authWorkItem = nil
        super.stop()
    }

    // MARK: - Connect / join

    private func connect(args: BilibiliDanmakuArgs, generation: Int) {
        self.args = args
        let endpoints = args.serverUrls.isEmpty ? [BilibiliDanmaku.defaultServerUrl] : args.serverUrls
        // (b49 sweep #27) Rotate through the endpoints: the
        // reconnect closure and the auth-timeout path advance the
        // index first, so a dead host is never retried twice in a
        // row while a healthy one sits in the list.
        let url = URL(string: endpoints[endpointIndex % endpoints.count])
        guard let url = url else {
            onClose?()
            return
        }
        var headers: [String: String] = [:]
        if !args.cookie.isEmpty {
            headers["cookie"] = args.cookie
        }
        _reconnect = { [weak self] in
            guard let self = self else {
                return
            }
            self.endpointIndex += 1
            self.connect(args: self.args, generation: generation)
        }
        connectSocket(url: url, headers: headers, generation: generation, onSocketMessage: { [weak self] data in
            self?.decodeMessage(data)
        }, onSocketReady: { [weak self] in
            guard let self = self else {
                return
            }
            self.sendJoin(args: args)
            self.scheduleAuthTimeout(generation: generation)
            self.startHeartbeat(every: BilibiliDanmaku.heartbeatSeconds)
        })
    }

    private func sendJoin(args: BilibiliDanmakuArgs) {
        let payload = BilibiliDanmaku.buildJoinPayload(args)
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: jsonData, encoding: .utf8) else {
            return
        }
        sendSocket(BilibiliDanmaku.encodeData(json, action: 7))
    }

    /// Auth payload (op 7). `queueUuid` is injectable for tests.
    /// protover is 0 here (see the file header): no Brotli decoder
    /// is available in this target, so the transport asks for plain
    /// JSON frames instead of the Flutter default protover 3.
    static func buildJoinPayload(_ args: BilibiliDanmakuArgs, queueUuid: String? = nil) -> [String: Any] {
        [
            "uid": args.uid,
            "roomid": args.roomId,
            "protover": 0,
            "buvid": args.buvid,
            "support_ack": true,
            "queue_uuid": queueUuid ?? newQueueUuid(),
            "scene": "room",
            "platform": "web",
            "type": 2,
            "key": args.token
        ]
    }

    private static func newQueueUuid() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%x", $0 & 0xF) }.joined()
    }

    private func scheduleAuthTimeout(generation: Int) {
        authWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, generation == self._generation, !self._stopped, !self._connected else {
                return
            }
            self.reconnectNow(generation: generation)
        }
        authWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(BilibiliDanmaku.authTimeoutSeconds), execute: item)
    }

    private func reconnectNow(generation: Int) {
        _socket?.close()
        _socket = nil
        endpointIndex += 1
        connect(args: args, generation: generation)
    }

    // MARK: - Credential discovery

    private func discoverCredentials(generation: Int, attempt: Int) {
        guard let url = URL(string: "\(BilibiliDanmaku.danmuInfoUrl)?id=\(args.roomId)&type=0") else {
            onClose?()
            return
        }
        var headers: [String: String] = [:]
        headers["Referer"] = "https://live.bilibili.com/\(args.roomId)"
        let request = LiveHTTP.getRequest(url: url, headers: headers)
        fetcher(request) { [weak self] data, status, _ in
            guard let self = self, generation == self._generation, !self._stopped else {
                return
            }
            var refreshed: BilibiliDanmakuArgs?
            if let status = status, (200..<300).contains(status),
               let data = data, let json = LiveJSON.decodeObject(data),
               LiveJSON.asInt(json["code"]) == 0,
               let candidate = LiveJSON.asMap(json["data"]) {
                let token = LiveJSON.asString(candidate["token"])
                if !token.isEmpty {
                    refreshed = BilibiliLiveSite.parseDanmakuArgs(data: candidate, realRoomId: self.args.roomId, buvid: self.args.buvid, cookie: self.args.cookie)
                }
            }
            if let refreshed = refreshed, !refreshed.token.isEmpty {
                self.connect(args: refreshed, generation: generation)
                return
            }
            if attempt < 2 {
                LiveHTTP.after(milliseconds: 500 * (attempt + 1)) { [weak self] in
                    guard let self = self, generation == self._generation, !self._stopped else {
                        return
                    }
                    self.discoverCredentials(generation: generation, attempt: attempt + 1)
                }
                return
            }
            self.onClose?()
        }
    }

    private func refreshCredentialsAndReconnect(generation: Int) {
        if _stopped || refreshingCredentials || credentialRefreshCount >= 3 || args.roomId == 0 {
            // (b49 sweep #26) The refresh budget is spent (or the
            // room is gone): do not sit half-open with a dead
            // socket and `_connected == false` for the rest of the
            // visit — close and report, so the room page can stop
            // expecting danmaku instead of waiting silently.
            if !_stopped && args.roomId != 0 && credentialRefreshCount >= 3 {
                _socket?.close()
                _socket = nil
                onClose?()
            }
            return
        }
        refreshingCredentials = true
        credentialRefreshCount += 1
        guard let url = URL(string: "\(BilibiliDanmaku.danmuInfoUrl)?id=\(args.roomId)&type=0") else {
            refreshingCredentials = false
            return
        }
        var headers: [String: String] = [:]
        headers["Referer"] = "https://live.bilibili.com/\(args.roomId)"
        let request = LiveHTTP.getRequest(url: url, headers: headers)
        fetcher(request) { [weak self] data, status, _ in
            guard let self = self else {
                return
            }
            self.refreshingCredentials = false
            guard generation == self._generation, !self._stopped else {
                return
            }
            var refreshed: BilibiliDanmakuArgs?
            if let status = status, (200..<300).contains(status),
               let data = data, let json = LiveJSON.decodeObject(data),
               LiveJSON.asInt(json["code"]) == 0,
               let candidate = LiveJSON.asMap(json["data"]) {
                let token = LiveJSON.asString(candidate["token"])
                if !token.isEmpty {
                    refreshed = BilibiliLiveSite.parseDanmakuArgs(data: candidate, realRoomId: self.args.roomId, buvid: self.args.buvid, cookie: self.args.cookie)
                }
            }
            guard let refreshed = refreshed, !refreshed.token.isEmpty else {
                // (b49 sweep #26) The refresh yielded no token:
                // do not return silently with the old socket open
                // but unauthenticated — close it and re-discover
                // credentials with backoff (discoverCredentials
                // retries 3x, then reports onClose). A fresh
                // discovery can still save the visit; a silent
                // return could not.
                self._socket?.close()
                self._socket = nil
                self.discoverCredentials(generation: generation, attempt: 0)
                return
            }
            self._socket?.close()
            self._socket = nil
            self.connect(args: refreshed, generation: generation)
        }
    }

    // MARK: - Frame encode

    /// Encode one frame: 16-byte big-endian header + UTF-8 body.
    static func encodeData(_ message: String, action: Int) -> Data {
        let body = Data(message.utf8)
        var data = Data(capacity: body.count + 16)
        appendUInt32(&data, UInt32(body.count + 16))
        appendUInt16(&data, 16)
        appendUInt16(&data, 0)
        appendUInt32(&data, UInt32(action))
        appendUInt32(&data, 1)
        data.append(body)
        return data
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    // MARK: - Frame decode

    /// Decode one inbound WebSocket message (possibly several frames,
    /// possibly compressed). Malformed input is skipped, never thrown.
    func decodeMessage(_ data: Data) {
        do {
            if data.count > BilibiliDanmaku.maxTransportMessageBytes {
                return
            }
            try decodePacketStream(data, depth: 0)
        } catch {
            // Best-effort: a bad frame must not kill the room.
        }
    }

    private func decodePacketStream(_ data: Data, depth: Int) throws {
        if depth > BilibiliDanmaku.maxCompressedNestingDepth {
            throw LiveError.parseFailed("Bilibili 弹幕包嵌套过深")
        }
        var offset = 0
        var packetCount = 0
        while offset + BilibiliDanmaku.packetHeaderLength <= data.count {
            packetCount += 1
            if packetCount > BilibiliDanmaku.maxPacketsPerMessage {
                throw LiveError.parseFailed("Bilibili 弹幕消息包过多")
            }
            let packetLength = Int(BilibiliDanmaku.readUInt32(data, offset))
            let headerLength = Int(BilibiliDanmaku.readUInt16(data, offset + 4))
            let protocolVersion = Int(BilibiliDanmaku.readUInt16(data, offset + 6))
            let operation = Int(BilibiliDanmaku.readUInt32(data, offset + 8))
            if headerLength < BilibiliDanmaku.packetHeaderLength
                || packetLength < headerLength
                || packetLength > BilibiliDanmaku.maxTransportMessageBytes
                || offset + packetLength > data.count {
                throw LiveError.parseFailed("Bilibili 弹幕帧无效")
            }
            let body = data.subdata(in: (offset + headerLength)..<(offset + packetLength))
            try decodePacket(protocolVersion: protocolVersion, operation: operation, body: body, depth: depth)
            offset += packetLength
        }
        if offset != data.count {
            throw LiveError.parseFailed("Bilibili 弹幕帧不完整")
        }
    }

    private func decodePacket(protocolVersion: Int, operation: Int, body: Data, depth: Int) throws {
        if operation == 3 {
            // Popularity heartbeat — no field for it in DanmakuMessage; skip.
            return
        }
        if operation == 5 {
            if protocolVersion == 2 {
                let decoded = try LiveInflate.inflateZlib(body)
                if decoded.count > BilibiliDanmaku.maxDecompressedMessageBytes {
                    throw LiveError.parseFailed("Bilibili 弹幕解压后过大")
                }
                try decodePacketStream(decoded, depth: depth + 1)
            } else if protocolVersion == 3 {
                // Brotli: no decoder in this target; drop, never crash.
                return
            } else {
                let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    parseMessage(text)
                }
            }
            return
        }
        if operation == 8 {
            // Auth ack — the transport is usable only after code == 0.
            let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            var code = 0
            if !text.isEmpty, let jsonData = text.data(using: .utf8), let obj = LiveJSON.decodeObject(jsonData) {
                code = LiveJSON.asInt(obj["code"])
            } else if !text.isEmpty {
                code = -1
            }
            if code == 0, !_connected {
                authWorkItem?.cancel()
                authWorkItem = nil
                _connected = true
                heartbeat()
                onReady?()
            } else if code != 0 {
                authWorkItem?.cancel()
                authWorkItem = nil
                _connected = false
                refreshCredentialsAndReconnect(generation: _generation)
            }
        }
    }

    static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    // MARK: - Notification dispatch

    /// Parse one notification JSON object (`cmd` dispatch). Only
    /// chat-like commands produce a DanmakuMessage; gifts / super
    /// chats become chat text (the model has no gift payload).
    func parseMessage(_ jsonMessage: String) {
        guard let jsonData = jsonMessage.data(using: .utf8),
              let obj = LiveJSON.decodeObject(jsonData) else {
            return
        }
        let cmd = LiveJSON.asString(obj["cmd"])
        if cmd.contains("DANMU_MSG") {
            guard let info = obj["info"] as? [Any], info.count >= 3 else {
                return
            }
            let message = LiveJSON.asString(info[1])
            if message.isEmpty {
                return
            }
            let meta = info[0] as? [Any] ?? []
            // meta[3] is the colour, but a short/truncated meta
            // array must not trap here: default to 0 (white) when
            // the server sends fewer than 4 elements.
            let color = meta.count > 3 ? LiveJSON.asInt(meta[3]) : 0
            let user = info[2] as? [Any] ?? []
            let userName = user.count > 1 ? LiveJSON.asString(user[1]) : ""
            onMessage?(DanmakuMessage(
                userName: userName,
                text: message,
                colorArgb: color == 0 ? 0xFFFFFFFF : (0xFF000000 | (UInt32(color) & 0xFFFFFF))
            ))
        } else if cmd == "SEND_GIFT" || cmd == "COMBO_SEND" {
            guard let data = LiveJSON.asMap(obj["data"]) else {
                return
            }
            let name = (cmd == "COMBO_SEND" ? LiveJSON.asString(data["gift_name"]) : LiveJSON.asString(data["giftName"])).trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                return
            }
            let count = cmd == "COMBO_SEND" ? LiveJSON.asInt(data["total_num"]) : LiveJSON.asInt(data["num"])
            onMessage?(DanmakuMessage(
                userName: LiveJSON.asString(data["uname"]),
                text: "送出 \(name) ×\(count == 0 ? 1 : count)"
            ))
        } else if cmd == "SUPER_CHAT_MESSAGE" {
            guard let data = LiveJSON.asMap(obj["data"]) else {
                return
            }
            let userInfo = LiveJSON.asMap(data["user_info"])
            let userName = LiveJSON.asString(userInfo?["uname"])
            let text = LiveJSON.asString(data["message"])
            if text.isEmpty {
                return
            }
            onMessage?(DanmakuMessage(
                userName: userName,
                text: "💰 \(LiveJSON.asString(data["price"])) \(text)",
                isSuperChat: true
            ))
        } else if cmd == "WARNING" || cmd == "CUT_OFF" {
            let reason = LiveJSON.asString(obj["msg"]).trimmingCharacters(in: .whitespaces)
            let lead = cmd == "WARNING" ? "直播间收到警告" : "直播被切断"
            onMessage?(DanmakuMessage(text: reason.isEmpty ? lead : "\(lead)：\(reason)"))
        }
    }
}

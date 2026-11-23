// HAo Studio 2.0 — Douyu danmaku (S4 leg B).
//
// Swift port of the Flutter `lib/shared/platforms/douyu/
// douyu_danmaku.dart`:
//   WS wss://danmuproxy.douyu.com:8506
//   login:  `type@=loginreq/roomid@=<roomId>/`
//   join:   `type@=joingroup/rid@=<roomId>/gid@=-9999/`
//   heartbeat: `type@=mrkl/` every 45 s
//   frames: 12-byte little-endian header (len, len, 689, 0, 0) + body
//           + trailing NUL.
// No auth / no cookie — the easiest danmaku of the five.
//
// Args for `start`: a map with `roomId`.
//
// Deviation from Pure Live, deliberate (kept): Pure Live only emits
// `chatmsg` when the `if` field == '1' (room-fan flag). Gating on fan
// status hides most chat, so this port emits every `chatmsg`.
// Revisit only if spam becomes a problem.
//
// Malformed frames are skipped, never thrown.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

final class DouyuDanmaku: LiveDanmakuTransportBase {
    static let serverUrl = "wss://danmuproxy.douyu.com:8506"
    static let heartbeatSeconds = 45

    private var roomId = ""

    init(socket: LiveDanmakuSocket? = nil) {
        super.init()
        self._injectedSocket = socket
    }

    override func start(danmakuData: [String: Any]) {
        let generation = beginStart()
        roomId = LiveJSON.asString(danmakuData["roomId"])
        if roomId.isEmpty {
            onClose?()
            return
        }
        connect(generation: generation)
    }

    override func heartbeat() {
        sendSocket(DouyuDanmaku.serializeDouyu("type@=mrkl/"))
    }

    private func connect(generation: Int) {
        guard let url = URL(string: DouyuDanmaku.serverUrl) else {
            onClose?()
            return
        }
        _reconnect = { [weak self] in
            guard let self = self else {
                return
            }
            self.connect(generation: generation)
        }
        connectSocket(url: url, headers: [:], generation: generation, onSocketMessage: { [weak self] data in
            self?.decodeMessage(data)
        }, onSocketReady: { [weak self] in
            guard let self = self else {
                return
            }
            self._connected = true
            self.onReady?()
            self.joinRoom()
            self.startHeartbeat(every: DouyuDanmaku.heartbeatSeconds)
        })
    }

    private func joinRoom() {
        sendSocket(DouyuDanmaku.serializeDouyu("type@=loginreq/roomid@=\(roomId)/"))
        sendSocket(DouyuDanmaku.serializeDouyu("type@=joingroup/rid@=\(roomId)/gid@=-9999/"))
    }

    /// Decode one inbound frame into DanmakuMessages via `onMessage`.
    /// A frame may hold several concatenated messages; malformed
    /// frames are skipped, never thrown.
    func decodeMessage(_ data: Data) {
        guard let text = DouyuDanmaku.deserializeDouyu(data) else {
            return
        }
        var parsed: Any = DouyuDanmaku.sttToJObject(text)
        // A frame holding several '//'-separated messages parses to a
        // list; take the first map (Pure Live drops these entirely).
        if let list = parsed as? [Any] {
            parsed = list.first { $0 is [String: Any] } ?? [:] as [String: Any]
        }
        guard let map = parsed as? [String: Any] else {
            return
        }
        let type = LiveJSON.asString(map["type"])
        if type == "rss" && LiveJSON.asString(map["ss"]) == "0" {
            let close = onClose
            stop()
            close?()
            return
        }
        var liveMessage: DanmakuMessage?
        if type == "chatmsg" {
            let color = LiveJSON.asInt(map["col"])
            liveMessage = DanmakuMessage(
                userName: LiveJSON.asString(map["nn"]),
                text: LiveJSON.asString(map["txt"]),
                colorArgb: DouyuDanmaku.douyuColorArgb(color),
                // Pure Live's suspected-automated rule (sites/douyu.dart):
                // a chatmsg with no `dms` field and `ifs` != '1'. The
                // Douyu-bot filter hides tagged messages when enabled.
                suspectedAutomated: map["dms"] == nil && LiveJSON.asString(map["ifs"]) != "1"
            )
        } else if type == "comm_chatmsg" {
            // `comm_chatmsg` / `voice_trlt` (super chat) carry a nested
            // LiveSuperChatMessage in Pure Live; this model has no
            // super-chat payload, so they render as plain chat text.
            if let chat = LiveJSON.asMap(map["chatmsg"]) {
                let price = LiveJSON.asInt(chat["cprice"]) / 100
                liveMessage = DanmakuMessage(
                    userName: LiveJSON.asString(chat["nn"]),
                    text: "💰 ¥\(price) \(LiveJSON.asString(chat["txt"]))",
                    isSuperChat: true
                )
            }
        }
        if let liveMessage = liveMessage, !liveMessage.text.isEmpty {
            onMessage?(liveMessage)
        }
    }

    /// Frame one `type@=` body: [len][len][689:u16][0][0] body NUL.
    static func serializeDouyu(_ body: String) -> Data {
        let payload = Data(body.utf8)
        let total = 4 + 4 + payload.count + 1
        var out = Data(capacity: total + 4)
        appendUInt32LE(&out, UInt32(total))
        appendUInt32LE(&out, UInt32(total))
        appendUInt16LE(&out, 689)
        out.append(0)
        out.append(0)
        out.append(payload)
        out.append(0)
        return out
    }

    /// Strip the 12-byte header (+ trailing NUL) and UTF-8 decode the
    /// body. Returns nil for a malformed frame.
    static func deserializeDouyu(_ buffer: Data) -> String? {
        if buffer.count < 13 {
            return nil
        }
        let fullLength = Int(readUInt32LE(buffer, 0))
        let bodyLength = fullLength - 9
        if bodyLength < 0 || 12 + bodyLength > buffer.count {
            return nil
        }
        let bytes = buffer.subdata(in: 12..<(12 + bodyLength))
        return String(bytes: [UInt8](bytes), encoding: .utf8)
    }

    /// Parse Douyu's `key@=value/key2@=value2/` ("STT") encoding into
    /// nested maps/lists. `@S` -> `/`, `@A` -> `@`.
    static func sttToJObject(_ str: String) -> Any {
        if str.contains("//") {
            var result: [Any] = []
            for field in str.components(separatedBy: "//") {
                if field.isEmpty {
                    continue
                }
                result.append(sttToJObject(field))
            }
            return result
        }
        if str.contains("@=") {
            var result: [String: Any] = [:]
            for field in str.components(separatedBy: "/") {
                if field.isEmpty {
                    continue
                }
                let tokens = field.components(separatedBy: "@=")
                if tokens.count < 2 {
                    continue
                }
                result[tokens[0]] = sttToJObject(unescapeSlashAt(tokens[1]))
            }
            return result
        } else if str.contains("@A=") {
            return sttToJObject(unescapeSlashAt(str))
        } else {
            return unescapeSlashAt(str)
        }
    }

    private static func unescapeSlashAt(_ str: String) -> String {
        str.replacingOccurrences(of: "@S", with: "/").replacingOccurrences(of: "@A", with: "@")
    }

    /// Douyu `col` index -> ARGB colour (Pure Live `getColor`).
    static func douyuColorArgb(_ type: Int) -> UInt32 {
        switch type {
        case 1:
            return 0xFFFF0000
        case 2:
            return 0xFF1E87F0
        case 3:
            return 0xFF7AC84B
        case 4:
            return 0xFFFF7F00
        case 5:
            return 0xFF9B39F4
        case 6:
            return 0xFFFF69B4
        default:
            return 0xFFFFFFFF
        }
    }

    static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func appendUInt32LE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func appendUInt16LE(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }
}

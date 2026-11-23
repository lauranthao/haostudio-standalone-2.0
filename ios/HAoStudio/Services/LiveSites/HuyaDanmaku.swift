// HAo Studio 2.0 — Huya danmaku (S4 leg B).
//
// Swift port of the Flutter `lib/shared/platforms/huya/
// huya_danmaku.dart` + `huya_wup.dart` (super-chat board):
//   WS wss://wsapi.huya.com
//   join: TARS EWSCmdC2S_RegisterGroupReq (16) with groups
//         `live:<topSid>` / `chat:<topSid>`
//   heartbeat: TARS EWSCmdC2S_HeartBeatReq (20) every 60 s
//   inbound: TARS command type 7 (HYPushMessage) or 22
//     (HYPushMessageV2)
//     uri 1400  -> chat message (HYMessage)
//     uri 8006  -> attendee count (no field in DanmakuMessage; skipped)
//     uri 8001  -> presenter uid; stream ended when it matches ours
//     uri 2001314 -> super-chat board notification
//
// Args for `start` (from the room detail's `danmakuData`):
//   - `uid`: PRESENTER uid (gameLiveInfo['uid']); used only for the
//     uri-8001 stream-ended check. 0 when unknown.
//   - `topSid` / `subSid`: from the room detail's stream info
//     (`lChannelId` / `lSubChannelId`). When absent, the room page
//     is scraped once for `TT_ROOM_DATA` + `stream:`.
//   - `roomId`: needed only for that scrape fallback.
//
// Super chats: a 2001314 notification first tries to parse the panel
// straight from the WS payload; when that fails (or the board lags
// the notification) a bounded background refresh re-fetches the board
// with dedupe, so a super chat is never lost and never shown twice.
// The "(来自…上头条)" headline broadcast on uri-1400 triggers the
// same refresh pipeline.
//
// Deviation: the Flutter model carries the super-chat payload in
// `LiveMessage.data` (userName/message are the placeholder
// `SUPER_CHAT_MESSAGE`). This model has no payload field, so a super
// chat renders as text — "💰 ¥<price> <message>" — with
// `isSuperChat: true`, which preserves every field in readable form.
//
// Malformed frames are dropped, never thrown.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

final class HuyaDanmaku: LiveDanmakuTransportBase {
    static let serverUrl = "wss://wsapi.huya.com"
    static let heartbeatSeconds = 60
    static let defaultSuperChatRetryDelaysMilliseconds = [0, 600, 1800, 4000]
    static let maxRememberedSuperChats = 512

    private let wupClient: HuyaWupClient
    private let fetcher: LiveDataFetcher
    private let superChatRetryDelaysMilliseconds: [Int]
    private var superChatFetcher: ((Int, @escaping (Result<[HuyaSuperChatMessage], Error>) -> Void) -> Void)?

    private var args = HuyaDanmakuArgs()
    private var emittedSuperChatIds: [String] = []
    private var superChatRefreshInFlight = false
    private var superChatRefreshQueued = false

    init(
        wupClient: HuyaWupClient,
        fetcher: LiveDataFetcher? = nil,
        socket: LiveDanmakuSocket? = nil,
        superChatRetryDelaysMilliseconds: [Int]? = nil,
        superChatFetcher: ((Int, @escaping (Result<[HuyaSuperChatMessage], Error>) -> Void) -> Void)? = nil
    ) {
        self.wupClient = wupClient
        self.fetcher = fetcher ?? LiveHTTP.defaultFetcher
        self.superChatRetryDelaysMilliseconds = superChatRetryDelaysMilliseconds ?? HuyaDanmaku.defaultSuperChatRetryDelaysMilliseconds
        self.superChatFetcher = superChatFetcher
        super.init()
        self._injectedSocket = socket
    }

    /// Seeds the room args without connecting (tests only): the
    /// decode paths that need a topSid (super-chat refresh) can be
    /// exercised without a live WebSocket.
    func setTestArgs(_ args: HuyaDanmakuArgs) {
        self.args = args
    }

    override func start(danmakuData: [String: Any]) {
        let generation = beginStart()
        emittedSuperChatIds = []
        superChatRefreshInFlight = false
        superChatRefreshQueued = false
        args = HuyaDanmakuArgs.fromDataMap(danmakuData) ?? HuyaDanmakuArgs(
            uid: LiveJSON.asInt(danmakuData["uid"]),
            topSid: LiveJSON.asInt(danmakuData["topSid"]),
            subSid: LiveJSON.asInt(danmakuData["subSid"])
        )
        if args.topSid == 0 {
            let roomId = LiveJSON.asString(danmakuData["roomId"]).trimmingCharacters(in: .whitespaces)
            if roomId.isEmpty {
                onClose?()
                return
            }
            resolveSids(roomId: roomId, generation: generation)
            return
        }
        connect(generation: generation)
    }

    override func heartbeat() {
        sendSocket(HuyaDanmaku.heartbeatData)
    }

    override func stop() {
        superChatRefreshInFlight = false
        superChatRefreshQueued = false
        emittedSuperChatIds = []
        super.stop()
    }

    // MARK: - Connect / join

    private func connect(generation: Int) {
        guard let url = URL(string: HuyaDanmaku.serverUrl) else {
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
            self.heartbeat()
            self.startHeartbeat(every: HuyaDanmaku.heartbeatSeconds)
        })
    }

    private func joinRoom() {
        sendSocket(HuyaDanmaku.joinData(topSid: args.topSid))
    }

    /// TARS group-join: EWSCmdC2S_RegisterGroupReq (16) with groups
    /// [`live:<topSid>`, `chat:<topSid>`].
    static func joinData(topSid: Int) -> Data {
        do {
            let group = TarsOutputStream()
            try group.writeStringList(["live:\(topSid)", "chat:\(topSid)"], tag: 0)
            try group.writeString("", tag: 1)
            let command = TarsOutputStream()
            try command.writeInt(16, tag: 0)
            try command.writeBytes(group.bytes, tag: 1)
            return command.bytes
        } catch {
            return Data()
        }
    }

    /// Current website heartbeat: `EWSCmdC2S_HeartBeatReq` (20).
    static var heartbeatData: Data {
        do {
            let command = TarsOutputStream()
            try command.writeInt(20, tag: 0)
            try command.writeBytes(Data(), tag: 1)
            return command.bytes
        } catch {
            return Data()
        }
    }

    /// Scrape `topSid`/`subSid` from the room page via the shared
    /// room parser (`TT_ROOM_DATA` + `stream:`). Best-effort: null on
    /// any failure.
    private func resolveSids(roomId: String, generation: Int) {
        guard let url = URL(string: "https://www.huya.com/\(roomId)") else {
            onClose?()
            return
        }
        let headers: [String: String] = [
            "Origin": "https://www.huya.com",
            "Referer": "https://www.huya.com",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        ]
        let request = LiveHTTP.getRequest(url: url, headers: headers)
        fetcher(request) { [weak self] data, _, _ in
            guard let self = self, generation == self._generation, !self._stopped else {
                return
            }
            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                self.onClose?()
                return
            }
            do {
                let room = try HuyaLiveSite.parseHuyaRoomPage(html: html, roomId: roomId)
                guard let resolved = HuyaDanmakuArgs.fromDataMap(room.danmakuData), resolved.topSid != 0 else {
                    self.onClose?()
                    return
                }
                self.args = HuyaDanmakuArgs(uid: self.args.uid, topSid: resolved.topSid, subSid: resolved.subSid)
                self.connect(generation: generation)
            } catch {
                self.onClose?()
            }
        }
    }

    // MARK: - Frame decode

    func decodeMessage(_ data: Data) {
        do {
            let stream = TarsInputStream(data)
            let type = try stream.readInt(tag: 0)
            if type == 7 {
                let inner = TarsInputStream(try stream.readBytes(tag: 1))
                var pushMessage = HYPushMessage()
                try pushMessage.read(from: inner)
                decodePush(pushMessage.uri, pushMessage.msg)
            } else if type == 22 {
                let inner = TarsInputStream(try stream.readBytes(tag: 1))
                var push = HYPushMessageV2()
                try push.read(from: inner)
                for item in push.items {
                    decodePush(item.uri, item.msg)
                }
            }
        } catch {
            // Best-effort: a bad frame must not kill the room.
        }
    }

    private func decodePush(_ uri: Int, _ payload: Data) {
        if uri == 1400 {
            do {
                var messageNotice = HYMessage()
                try messageNotice.read(from: TarsInputStream(payload))
                let color = messageNotice.bulletFormat.fontColor
                // "xxx(来自 XX 上头条)" 是醒目留言在弹幕区的播报。消息板
                // WUP 尚未更新时该播报先到，靠它触发一次后台重拉把这条
                // SC 补上——与 2001314 通知共用同一条刷新管线。播报本身
                // 先发出，补拉的 SC 跟在后面。
                onMessage?(DanmakuMessage(
                    userName: messageNotice.userInfo.nickName,
                    text: messageNotice.content,
                    colorArgb: color <= 0 ? 0xFFFFFFFF : (0xFF000000 | (UInt32(color) & 0xFFFFFF))
                ))
                if HuyaDanmaku.isHeadlineSuperChat(messageNotice.content) {
                    scheduleSuperChatRefresh(generation: _generation)
                }
            } catch {
                // Best-effort: a bad chat frame must not kill the room.
            }
        } else if uri == 8006 {
            // Attendee count — no field in DanmakuMessage; skipped.
            return
        } else if uri == 2001314 {
            if let fromPanel = HuyaDanmaku.superChatsFromPanel(payload) {
                for chat in fromPanel {
                    if !rememberSuperChat(chat) {
                        continue
                    }
                    onMessage?(HuyaDanmaku.superChatMessage(chat))
                }
                return
            }
            // The notification can arrive before the message-board WUP
            // result is updated. Reconcile in the background with a
            // small bounded retry window instead of serialising
            // unrelated websocket messages on the HTTP call.
            scheduleSuperChatRefresh(generation: _generation)
        } else if uri == 8001 {
            do {
                let presenterUid = try TarsInputStream(payload).readInt(tag: 0)
                if presenterUid == 0 || presenterUid == args.uid {
                    let close = onClose
                    stop()
                    close?()
                }
            } catch {
                return
            }
        }
    }

    /// 醒目留言在弹幕区的播报形态："xxx(来自一元上头条)" — the
    /// `\(来自.+?上头条\)` pattern, checked without a regex: "(来自"
    /// followed by at least one character, then "上头条)".
    private static func isHeadlineSuperChat(_ content: String) -> Bool {
        guard let from = content.range(of: "(来自"),
              let to = content[from.upperBound...].range(of: "上头条)") else {
            return false
        }
        return content.distance(from: from.upperBound, to: to.lowerBound) >= 1
    }

    /// Parses the super-chat panel straight from a uri-2001314 WS
    /// payload. Returns nil when the payload carries no panel at
    /// tag 1 (caller falls back to the HTTP board refresh).
    static func superChatsFromPanel(_ payload: Data) -> [HuyaSuperChatMessage]? {
        if payload.isEmpty {
            return nil
        }
        do {
            if try TarsInputStream(payload).skipToTag(1) == false {
                return nil
            }
            var panel = GameEventMessageBoardPanel()
            try panel.read(from: TarsInputStream(payload))
            return HuyaWupClient.superChatsFromPanel(panel)
        } catch {
            return nil
        }
    }

    static func superChatMessage(_ chat: HuyaSuperChatMessage) -> DanmakuMessage {
        DanmakuMessage(
            userName: chat.userName,
            text: "💰 ¥\(chat.price) \(chat.message)",
            isSuperChat: true
        )
    }

    // MARK: - Super-chat board refresh

    private func scheduleSuperChatRefresh(generation: Int) {
        if generation != _generation {
            return
        }
        if superChatRefreshInFlight {
            superChatRefreshQueued = true
            return
        }
        superChatRefreshQueued = false
        superChatRefreshInFlight = true
        refreshSuperChats(generation: generation, attempt: 0)
    }

    private func refreshSuperChats(generation: Int, attempt: Int) {
        if attempt >= superChatRetryDelaysMilliseconds.count {
            finishSuperChatRefresh(generation: generation)
            return
        }
        let delay = superChatRetryDelaysMilliseconds[attempt]
        let run = { [weak self] in
            guard let self = self, generation == self._generation, !self._stopped, self.args.topSid != 0 else {
                self?.finishSuperChatRefresh(generation: generation)
                return
            }
            let fetch = self.superChatFetcher ?? { lPid, completion in
                self.wupClient.fetchSuperChatMessageList(lPid: lPid, first: true, completion: completion)
            }
            fetch(self.args.topSid) { [weak self] result in
                guard let self = self, generation == self._generation, !self._stopped else {
                    self?.finishSuperChatRefresh(generation: generation)
                    return
                }
                switch result {
                case .success(let messages):
                    let hadKnownMessages = !self.emittedSuperChatIds.isEmpty
                    var emittedNewMessage = false
                    for message in messages {
                        if !self.rememberSuperChat(message) {
                            continue
                        }
                        emittedNewMessage = true
                        self.onMessage?(HuyaDanmaku.superChatMessage(message))
                    }
                    // Once this transport already has a baseline, an
                    // unseen item proves that the delayed WUP board
                    // caught up and no later retry is needed.
                    if hadKnownMessages && emittedNewMessage {
                        self.finishSuperChatRefresh(generation: generation)
                        return
                    }
                    self.refreshSuperChats(generation: generation, attempt: attempt + 1)
                case .failure:
                    // Best-effort: a failed board fetch must not kill
                    // the room. Retries are bounded by the delays.
                    self.refreshSuperChats(generation: generation, attempt: attempt + 1)
                }
            }
        }
        if delay > 0 {
            LiveHTTP.after(milliseconds: delay, execute: run)
        } else {
            run()
        }
    }

    private func finishSuperChatRefresh(generation: Int) {
        superChatRefreshInFlight = false
        if superChatRefreshQueued && generation == _generation && !_stopped {
            superChatRefreshQueued = false
            superChatRefreshInFlight = true
            refreshSuperChats(generation: generation, attempt: 0)
        }
    }

    private func rememberSuperChat(_ message: HuyaSuperChatMessage) -> Bool {
        if emittedSuperChatIds.contains(message.messageId) {
            return false
        }
        emittedSuperChatIds.append(message.messageId)
        while emittedSuperChatIds.count > HuyaDanmaku.maxRememberedSuperChats {
            emittedSuperChatIds.removeFirst()
        }
        return true
    }
}

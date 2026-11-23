// HAo Studio 2.0 — Huya TARS structs (S4 leg B).
//
// Swift port of the Flutter `lib/core/tars/types.dart`
// (HuyaUserId, MessageUser), `get_cdn_token_ex_req.dart` /
// `get_cdn_token_ex_resp.dart`, the message-board structs
// (`get_game_event_message_board_req.dart`,
// `get_game_event_message_board_rsp.dart`,
// `game_event_message_board_panel.dart`,
// `game_event_message_board_info.dart`), and the danmaku structs
// in `lib/shared/platforms/huya/huya_danmaku.dart` (HYPushMessage,
// HYPushMessageV2, HYMessageItem, HYSender, HYMessage,
// HYBulletFormat).
//
// Tag numbers are quoted from the Dart sources; a wrong tag is a
// silent protocol failure, so each field carries its tag in a
// comment. Structs are value types with a fresh instance per
// read (the Dart `deepCopy` dance is unnecessary in Swift).
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

// MARK: - Identity / users

/// Huya user identity for WUP calls (tags 0...7).
struct HuyaUserId: TarsStruct {
    var lUid: Int = 0
    var sGuid: String = ""
    var sToken: String = ""
    var sHuYaUA: String = ""
    var sCookie: String = ""
    var iTokenType: Int = 0
    var sDeviceInfo: String = ""
    var sQIMEI: String = ""

    init() {
    }

    func write(to output: TarsOutputStream) {
        do {
            try output.writeInt(lUid, tag: 0)
            try output.writeString(sGuid, tag: 1)
            try output.writeString(sToken, tag: 2)
            try output.writeString(sHuYaUA, tag: 3)
            try output.writeString(sCookie, tag: 4)
            try output.writeInt(iTokenType, tag: 5)
            try output.writeString(sDeviceInfo, tag: 6)
            try output.writeString(sQIMEI, tag: 7)
        } catch {
            // In-memory write only fails on a tag over 255.
        }
    }

    mutating func read(from input: TarsInputStream) throws {
        lUid = try input.readInt(tag: 0)
        sGuid = try input.readString(tag: 1)
        sToken = try input.readString(tag: 2)
        sHuYaUA = try input.readString(tag: 3)
        sCookie = try input.readString(tag: 4)
        iTokenType = try input.readInt(tag: 5)
        sDeviceInfo = try input.readString(tag: 6)
        sQIMEI = try input.readString(tag: 7)
    }
}

/// One message-board user (nick tag 1, avatar tag 2).
struct HuyaMessageUser: TarsStruct {
    var sNick: String = ""
    var sAvatar: String = ""

    init() {
    }

    func write(to output: TarsOutputStream) {
        do {
            try output.writeString(sNick, tag: 1)
            try output.writeString(sAvatar, tag: 2)
        } catch {
            // In-memory write only fails on a tag over 255.
        }
    }

    mutating func read(from input: TarsInputStream) throws {
        sNick = try input.readString(tag: 1)
        sAvatar = try input.readString(tag: 2)
    }
}

// MARK: - CDN token (getCdnTokenInfoEx, servant liveui)

/// Request: FLV url tag 0, stream name tag 1, loop time tag 2,
/// identity tag 3, app id tag 4 (default 66).
struct GetCdnTokenExReq: TarsStruct {
    var sFlvUrl: String = ""
    var sStreamName: String = ""
    var iLoopTime: Int = 0
    var tId: HuyaUserId = HuyaUserId()
    var iAppId: Int = 66

    init() {
    }

    func write(to output: TarsOutputStream) {
        do {
            try output.writeString(sFlvUrl, tag: 0)
            try output.writeString(sStreamName, tag: 1)
            try output.writeInt(iLoopTime, tag: 2)
            try output.writeStruct(tId, tag: 3)
            try output.writeInt(iAppId, tag: 4)
        } catch {
            // In-memory write only fails on a tag over 255.
        }
    }

    mutating func read(from input: TarsInputStream) throws {
        sFlvUrl = try input.readString(tag: 0)
        sStreamName = try input.readString(tag: 1)
        iLoopTime = try input.readInt(tag: 2)
        tId = try input.readStruct(tag: 3)
        iAppId = try input.readInt(tag: 4)
    }
}

/// Response: FLV token tag 0, server expire time tag 1.
struct GetCdnTokenExResp: TarsStruct {
    var sFlvToken: String = ""
    var iExpireTime: Int = 0

    init() {
    }

    func write(to output: TarsOutputStream) {
        do {
            try output.writeString(sFlvToken, tag: 0)
            try output.writeInt(iExpireTime, tag: 1)
        } catch {
            // In-memory write only fails on a tag over 255.
        }
    }

    mutating func read(from input: TarsInputStream) throws {
        sFlvToken = try input.readString(tag: 0)
        iExpireTime = try input.readInt(tag: 1)
    }
}

// MARK: - Super-chat message board (getHeadLineMessageBoard, servant wupui)

/// Board request: room pid tag 0, offset tag 1, identity tag 2,
/// scope tag 3, page size tag 4 (default 10).
struct GetGameEventMessageBoardReq: TarsStruct {
    var lPid: Int = 0
    var sOffset: String = ""
    var tId: HuyaUserId = HuyaUserId()
    var iMessageBoardScope: Int = 0
    var iPageSize: Int = 10

    init() {
    }

    func write(to output: TarsOutputStream) {
        do {
            try output.writeInt(lPid, tag: 0)
            try output.writeString(sOffset, tag: 1)
            try output.writeStruct(tId, tag: 2)
            try output.writeInt(iMessageBoardScope, tag: 3)
            try output.writeInt(iPageSize, tag: 4)
        } catch {
            // In-memory write only fails on a tag over 255.
        }
    }

    mutating func read(from input: TarsInputStream) throws {
        lPid = try input.readInt(tag: 0)
        sOffset = try input.readString(tag: 1)
        tId = try input.readStruct(tag: 2)
        iMessageBoardScope = try input.readInt(tag: 3)
        iPageSize = try input.readInt(tag: 4)
    }
}

/// Board response: the panel at tag 1.
struct GetGameEventMessageBoardRsp: TarsStruct {
    var tMessageBoardPanel: GameEventMessageBoardPanel = GameEventMessageBoardPanel()

    init() {
    }

    func write(to output: TarsOutputStream) {
        do {
            try output.writeStruct(tMessageBoardPanel, tag: 1)
        } catch {
            // In-memory write only fails on a tag over 255.
        }
    }

    mutating func read(from input: TarsInputStream) throws {
        tMessageBoardPanel = try input.readStruct(tag: 1)
    }
}

/// The board panel: its entries at tag 1.
struct GameEventMessageBoardPanel: TarsStruct {
    var vGameEventMessageBoardInfo: [GameEventMessageBoardInfo] = []

    init() {
    }

    func write(to output: TarsOutputStream) {
        do {
            try output.writeStructList(vGameEventMessageBoardInfo, tag: 1)
        } catch {
            // In-memory write only fails on a tag over 255.
        }
    }

    mutating func read(from input: TarsInputStream) throws {
        vGameEventMessageBoardInfo = try input.readStructList(tag: 1)
    }
}

/// One super-chat entry: user tag 0, content tag 1, cost tag 2,
/// total seconds tag 4, countdown tag 5, message id tag 9,
/// paid cost tag 12.
struct GameEventMessageBoardInfo: TarsStruct {
    var tMessageUser: HuyaMessageUser = HuyaMessageUser()
    var sContent: String = ""
    var iCost: Int = 0
    var iTotalSec: Int = 0
    var iCountDown: Int = 0
    var lMessageId: Int = 0
    var iCostPay: Int = 0

    init() {
    }

    func write(to output: TarsOutputStream) {
        do {
            try output.writeStruct(tMessageUser, tag: 0)
            try output.writeString(sContent, tag: 1)
            try output.writeInt(iCost, tag: 2)
            try output.writeInt(iTotalSec, tag: 4)
            try output.writeInt(iCountDown, tag: 5)
            try output.writeInt(lMessageId, tag: 9)
            try output.writeInt(iCostPay, tag: 12)
        } catch {
            // In-memory write only fails on a tag over 255.
        }
    }

    mutating func read(from input: TarsInputStream) throws {
        tMessageUser = try input.readStruct(tag: 0)
        sContent = try input.readString(tag: 1)
        iCost = try input.readInt(tag: 2)
        iTotalSec = try input.readInt(tag: 4)
        iCountDown = try input.readInt(tag: 5)
        lMessageId = try input.readInt(tag: 9)
        iCostPay = try input.readInt(tag: 12)
    }
}

// MARK: - Danmaku push structs (WebSocket, command types 7 / 22)

/// Command-type-7 push: push type tag 0, uri tag 1, payload tag 2,
/// protocol type tag 3.
struct HYPushMessage: TarsStruct {
    var pushType: Int = 0
    var uri: Int = 0
    var msg: Data = Data()
    var protocolType: Int = 0

    init() {
    }

    func write(to output: TarsOutputStream) {
        do {
            try output.writeInt(pushType, tag: 0)
            try output.writeInt(uri, tag: 1)
            try output.writeBytes(msg, tag: 2)
            try output.writeInt(protocolType, tag: 3)
        } catch {
            // In-memory write only fails on a tag over 255.
        }
    }

    mutating func read(from input: TarsInputStream) throws {
        pushType = try input.readInt(tag: 0)
        uri = try input.readInt(tag: 1)
        msg = try input.readBytes(tag: 2)
        protocolType = try input.readInt(tag: 3)
    }
}

/// Command-type-22 push: group id tag 0, items tag 1.
struct HYPushMessageV2: TarsStruct {
    var groupId: String = ""
    var items: [HYMessageItem] = []

    init() {
    }

    func write(to output: TarsOutputStream) {
        do {
            try output.writeString(groupId, tag: 0)
            try output.writeStructList(items, tag: 1)
        } catch {
            // In-memory write only fails on a tag over 255.
        }
    }

    mutating func read(from input: TarsInputStream) throws {
        groupId = try input.readString(tag: 0)
        items = try input.readStructList(tag: 1)
    }
}

/// One item of a v2 push: uri tag 0, payload tag 1, message id tag 2.
struct HYMessageItem: TarsStruct {
    var uri: Int = 0
    var msg: Data = Data()
    var messageId: Int = 0

    init() {
    }

    func write(to output: TarsOutputStream) {
        do {
            try output.writeInt(uri, tag: 0)
            try output.writeBytes(msg, tag: 1)
            try output.writeInt(messageId, tag: 2)
        } catch {
            // In-memory write only fails on a tag over 255.
        }
    }

    mutating func read(from input: TarsInputStream) throws {
        uri = try input.readInt(tag: 0)
        msg = try input.readBytes(tag: 1)
        messageId = try input.readInt(tag: 2)
    }
}

/// Chat sender: uid tag 0, nick name tag 2, gender tag 3.
/// NOTE: the Dart port reads `lMid` from tag 0 as well (same value
/// as uid) — kept byte-identical here.
struct HYSender: TarsStruct {
    var uid: Int = 0
    var lMid: Int = 0
    var nickName: String = ""
    var gender: Int = 0

    init() {
    }

    func write(to output: TarsOutputStream) {
        do {
            try output.writeInt(uid, tag: 0)
            try output.writeString(nickName, tag: 2)
            try output.writeInt(gender, tag: 3)
        } catch {
            // In-memory write only fails on a tag over 255.
        }
    }

    mutating func read(from input: TarsInputStream) throws {
        uid = try input.readInt(tag: 0)
        // The Dart port reads lMid from tag 0 as well (same value
        // as uid). A forward-only TARS stream cannot re-read tag 0,
        // so mirror it here instead of reading the tag twice.
        lMid = uid
        nickName = try input.readString(tag: 2)
        gender = try input.readInt(tag: 3)
    }
}

/// One chat message (uri 1400): sender tag 0, content tag 3,
/// bullet format tag 6.
struct HYMessage: TarsStruct {
    var userInfo: HYSender = HYSender()
    var content: String = ""
    var bulletFormat: HYBulletFormat = HYBulletFormat()

    init() {
    }

    func write(to output: TarsOutputStream) {
        do {
            try output.writeStruct(userInfo, tag: 0)
            try output.writeString(content, tag: 3)
            try output.writeStruct(bulletFormat, tag: 6)
        } catch {
            // In-memory write only fails on a tag over 255.
        }
    }

    mutating func read(from input: TarsInputStream) throws {
        userInfo = try input.readStruct(tag: 0)
        content = try input.readString(tag: 3)
        bulletFormat = try input.readStruct(tag: 6)
    }
}

/// Bullet format: font colour tag 0, font size tag 1 (default 4),
/// text speed tag 2, transition type tag 3 (default 1).
struct HYBulletFormat: TarsStruct {
    var fontColor: Int = 0
    var fontSize: Int = 4
    var textSpeed: Int = 0
    var transitionType: Int = 1

    init() {
    }

    func write(to output: TarsOutputStream) {
        do {
            try output.writeInt(fontColor, tag: 0)
            try output.writeInt(fontSize, tag: 1)
            try output.writeInt(textSpeed, tag: 2)
            try output.writeInt(transitionType, tag: 3)
        } catch {
            // In-memory write only fails on a tag over 255.
        }
    }

    mutating func read(from input: TarsInputStream) throws {
        fontColor = try input.readInt(tag: 0)
        fontSize = try input.readInt(tag: 1, defaultValue: 4)
        textSpeed = try input.readInt(tag: 2)
        transitionType = try input.readInt(tag: 3, defaultValue: 1)
    }
}

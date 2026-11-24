// HAo Studio 2.0 — Bilibili danmaku tests (S4 leg B).
//
// Frame round-trip, auth ack, message kinds, protover-2 zlib
// frames (fixture compressed with Python zlib), join payload
// (protover 0), credential discovery. No network.
// Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class BilibiliDanmakuTests: XCTestCase {
    // One inner DANMU_MSG frame, zlib-compressed, inside an outer
    // protover-2 op-5 frame. Compressed with Python zlib; the inner
    // message is "hello protover2" from "tester".
    private let protover2FrameBase64 = "AAAAeAAQAAIAAAAFAAAAAXicY2BgyGAQYAABViBmrFZKzk1RslJycfTzDY33DXZX0lHKzEvLV7KKjjbQMTQzNzc3MjTVMdBRUk4DA6VYHaWM1JycfIWCovyS/LLUIiMlnWhDI2MdpZLU4pLUIiUdg9jYWgCL/hp1"

    private func transport(
        fetcher: LiveDataFetcher? = nil,
        socket: FakeDanmakuSocket? = nil
    ) -> BilibiliDanmaku {
        BilibiliDanmaku(fetcher: fetcher, socket: socket)
    }

    private func headerFields(_ data: Data) -> (length: UInt32, headerLength: UInt16, protover: UInt16, operation: UInt32, sequence: UInt32) {
        let u32: (Int) -> UInt32 = { offset in
            data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        }
        let u16: (Int) -> UInt16 = { offset in
            data.subdata(in: offset..<offset + 2).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        }
        return (u32(0), u16(4), u16(6), u32(8), u32(12))
    }

    // MARK: - Frames

    func testEncodeDataHeaderLayout() {
        let data = BilibiliDanmaku.encodeData("hello", action: 5)
        XCTAssertEqual(data.count, 16 + 5)
        let fields = headerFields(data)
        XCTAssertEqual(fields.length, 21)
        XCTAssertEqual(fields.headerLength, 16)
        XCTAssertEqual(fields.protover, 0)
        XCTAssertEqual(fields.operation, 5)
        XCTAssertEqual(fields.sequence, 1)
        XCTAssertEqual(String(data: data.subdata(in: 16..<data.count), encoding: .utf8), "hello")
    }

    func testBuildJoinPayloadUsesProtoverZero() {
        let args = BilibiliDanmakuArgs(roomId: 6, token: "tok", serverUrls: [], buvid: "B1", uid: 0, cookie: "")
        let payload = BilibiliDanmaku.buildJoinPayload(args, queueUuid: "abcdef01")
        XCTAssertEqual(payload["uid"] as? Int, 0)
        XCTAssertEqual(payload["roomid"] as? Int, 6)
        XCTAssertEqual(payload["protover"] as? Int, 0)
        XCTAssertEqual(payload["buvid"] as? String, "B1")
        XCTAssertEqual(payload["key"] as? String, "tok")
        XCTAssertEqual(payload["queue_uuid"] as? String, "abcdef01")
    }

    // MARK: - Connect / auth

    func testStartWithTokenConnectsAndJoins() {
        let socket = FakeDanmakuSocket()
        let danmaku = transport(socket: socket)
        danmaku.start(danmakuData: [
            "roomId": 6, "token": "tok",
            "serverUrls": ["wss://broadcastlv.chat.bilibili.com/sub"],
            "buvid": "B1"
        ])
        XCTAssertEqual(socket.connectedUrls, [URL(string: "wss://broadcastlv.chat.bilibili.com/sub")!])
        XCTAssertEqual(socket.sent.count, 1)
        let join = headerFields(socket.sent[0])
        XCTAssertEqual(join.operation, 7)
        let body = String(data: socket.sent[0].subdata(in: 16..<socket.sent[0].count), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"roomid\":6"))
        XCTAssertTrue(body.contains("\"protover\":0"))
        XCTAssertTrue(body.contains("\"key\":\"tok\""))
        danmaku.stop()
    }

    func testAuthAckMarksConnectedAndCallsOnReady() {
        let socket = FakeDanmakuSocket()
        let danmaku = transport(socket: socket)
        var ready = false
        danmaku.onReady = { ready = true }
        danmaku.start(danmakuData: [
            "roomId": 6, "token": "tok",
            "serverUrls": ["wss://broadcastlv.chat.bilibili.com/sub"]
        ])
        XCTAssertFalse(danmaku.isConnected)
        socket.simulateMessage(BilibiliDanmaku.encodeData("{\"code\":0}", action: 8))
        XCTAssertTrue(ready)
        XCTAssertTrue(danmaku.isConnected)
        danmaku.stop()
    }

    func testStartWithoutRoomIdCloses() {
        let danmaku = transport()
        var closed = false
        danmaku.onClose = { closed = true }
        danmaku.start(danmakuData: [:])
        XCTAssertTrue(closed)
    }

    func testStartDiscoversCredentialsWhenTokenEmpty() {
        let socket = FakeDanmakuSocket()
        let fetcher = routingFetcher([
            ("getDanmuInfo", jsonData("{\"code\":0,\"data\":{\"token\":\"tok2\",\"host_list\":[{\"host\":\"tx.chat.bilibili.com\",\"wss_port\":443}]}}"), 200)
        ])
        let danmaku = transport(fetcher: fetcher, socket: socket)
        danmaku.start(danmakuData: ["roomId": 6])
        XCTAssertEqual(socket.connectedUrls, [URL(string: "wss://broadcastlv.chat.bilibili.com/sub")!])
        XCTAssertEqual(socket.sent.count, 1)
        XCTAssertEqual(headerFields(socket.sent[0]).operation, 7)
        danmaku.stop()
    }

    // MARK: - Message kinds

    private func decodeOne(_ json: String, action: Int = 5) -> [DanmakuMessage] {
        let danmaku = transport()
        var received: [DanmakuMessage] = []
        danmaku.onMessage = { received.append($0) }
        danmaku.decodeMessage(BilibiliDanmaku.encodeData(json, action: action))
        return received
    }

    func testDecodeDanmuMessage() {
        let messages = decodeOne("{\"cmd\":\"DANMU_MSG\",\"info\":[[0,16777215,0,\"#ffffff\"],\"hello\",[123,\"tester\",0]]}")
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].text, "hello")
        XCTAssertEqual(messages[0].userName, "tester")
        XCTAssertEqual(messages[0].colorArgb, 0xFFFFFFFF)
    }

    func testDecodeDanmuMessageWithShortMetaDoesNotTrap() {
        // A truncated info[0] (fewer than 4 elements) used to trap
        // on meta[3] in the live room; it must parse with the
        // default colour instead of crashing.
        let shortMeta = decodeOne("{\"cmd\":\"DANMU_MSG\",\"info\":[[0],\"hello\",[123,\"tester\",0]]}")
        XCTAssertEqual(shortMeta.count, 1)
        XCTAssertEqual(shortMeta[0].text, "hello")
        XCTAssertEqual(shortMeta[0].colorArgb, 0xFFFFFFFF)
        let emptyMeta = decodeOne("{\"cmd\":\"DANMU_MSG\",\"info\":[[],\"hello\",[123,\"tester\",0]]}")
        XCTAssertEqual(emptyMeta.count, 1)
        XCTAssertEqual(emptyMeta[0].colorArgb, 0xFFFFFFFF)
    }

    func testDecodeGiftAndSuperChat() {
        let gift = decodeOne("{\"cmd\":\"SEND_GIFT\",\"data\":{\"uname\":\"送礼人\",\"giftName\":\"小花花\",\"num\":3}}")
        XCTAssertEqual(gift[0].text, "送出 小花花 ×3")
        XCTAssertEqual(gift[0].userName, "送礼人")
        let superChat = decodeOne("{\"cmd\":\"SUPER_CHAT_MESSAGE\",\"data\":{\"user_info\":{\"uname\":\"大佬\"},\"price\":30,\"message\":\"厉害\"}}")
        XCTAssertEqual(superChat[0].text, "💰 30 厉害")
        XCTAssertTrue(superChat[0].isSuperChat)
        let warning = decodeOne("{\"cmd\":\"WARNING\",\"msg\":\"请注意言行\"}")
        XCTAssertEqual(warning[0].text, "直播间收到警告：请注意言行")
    }

    func testDecodePopularityFrameIsSkipped() {
        let danmaku = transport()
        var received: [DanmakuMessage] = []
        danmaku.onMessage = { received.append($0) }
        danmaku.decodeMessage(BilibiliDanmaku.encodeData("12345", action: 3))
        XCTAssertTrue(received.isEmpty)
    }

    func testDecodeMalformedFrameIsDropped() {
        let danmaku = transport()
        var received: [DanmakuMessage] = []
        danmaku.onMessage = { received.append($0) }
        danmaku.decodeMessage(Data([0x00, 0x00, 0x00, 0x10]))
        danmaku.decodeMessage(Data([0xFF, 0xFE, 0xFD]))
        danmaku.decodeMessage(Data())
        XCTAssertTrue(received.isEmpty)
    }

    func testDecodeProtoverTwoZlibFrame() throws {
        let data = try XCTUnwrap(Data(base64Encoded: protover2FrameBase64))
        let danmaku = transport()
        var received: [DanmakuMessage] = []
        danmaku.onMessage = { received.append($0) }
        danmaku.decodeMessage(data)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].text, "hello protover2")
        XCTAssertEqual(received[0].userName, "tester")
    }
}

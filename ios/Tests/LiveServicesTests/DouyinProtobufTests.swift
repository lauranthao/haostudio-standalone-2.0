// HAo Studio 2.0 — Douyin protobuf + X-Bogus tests (S4 leg B).
//
// Hand-written varint/length-delimited codec round-trips, message
// decode, the gzip PushFrame path, and the deterministic X-Bogus
// vectors (Python reference implementation of douyin_xbogus.dart).
// No network. Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class DouyinProtobufTests: XCTestCase {
    // A PushFrame (payloadEncoding "gzip") whose payload is the
    // gzip of a Response carrying one WebcastChatMessage from
    // "抖音用户": "你好抖音". Generated with Python (protobuf +
    // gzip); see the fixture note in DouyinDanmaku.swift.
    private let gzipFrameBase64 = "MgRnemlwQnAfiwgA2ygEawL/40rgEgpPTUpOLC5xzkgs8U0tLk5MTxVy41LAJi6QInHgCLtCw6Pzq9iERDieswv8YJPiedY17eX8zc+nrHjWsV2K58neBU+X7oWISaQoMApxJJcWFecX6RpKdKgDAFQfPqZvAAAA"

    private let xbogusAlphabet = "Dkdpgh4ZKsQB80/Mfvw36XI1R25+WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe"

    // MARK: - Reader / writer

    func testVarintRoundTrip() throws {
        let values: [UInt64] = [0, 1, 127, 128, 300, 16384, UInt64.max]
        for value in values {
            let bytes = Data(DouyinProtobufWriter.varintField(field: 1, value))
            var reader = DouyinProtoReader(bytes)
            let tag = try XCTUnwrap(try reader.readTag())
            XCTAssertEqual(tag.field, 1)
            XCTAssertEqual(tag.wire, 0)
            XCTAssertEqual(try reader.readVarint(), value)
        }
    }

    func testReaderThrowsOnTruncatedVarint() {
        var reader = DouyinProtoReader(Data([0x80]))
        XCTAssertThrowsError(try reader.readVarint())
        var empty = DouyinProtoReader(Data())
        XCTAssertThrowsError(try empty.readVarint())
        XCTAssertNil(try? empty.readTag())
    }

    func testReaderSkipsUnknownFields() throws {
        var bytes: [UInt8] = []
        bytes += DouyinProtobufWriter.varintField(field: 9, 42)
        bytes += DouyinProtobufWriter.stringField(field: 10, "unknown")
        bytes += DouyinProtobufWriter.varintField(field: 1, 7)
        var reader = DouyinProtoReader(Data(bytes))
        let first = try XCTUnwrap(try reader.readTag())
        try reader.skipField(wire: first.wire)
        let second = try XCTUnwrap(try reader.readTag())
        try reader.skipField(wire: second.wire)
        let third = try XCTUnwrap(try reader.readTag())
        XCTAssertEqual(third.field, 1)
        XCTAssertEqual(try reader.readVarint(), 7)
    }

    func testReaderRejectsInvalidWireType() {
        var reader = DouyinProtoReader(Data([0x0E])) // field 1, wire 6
        XCTAssertThrowsError(try reader.skipField(wire: 6))
        _ = reader
    }

    func testFixed32And64() throws {
        var bytes: [UInt8] = []
        bytes += DouyinProtobufWriter.tag(field: 1, wire: 5) + [0x78, 0x56, 0x34, 0x12]
        bytes += DouyinProtobufWriter.tag(field: 2, wire: 1) + [0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01]
        var reader = DouyinProtoReader(Data(bytes))
        _ = try reader.readTag()
        XCTAssertEqual(try reader.readFixed32(), 0x12345678)
        _ = try reader.readTag()
        XCTAssertEqual(try reader.readFixed64(), 0x0123456789ABCDEF)
    }

    // MARK: - Message round-trips

    func testPushFrameEncodeDecodeRoundTrip() throws {
        var frame = DouyinPushFrame()
        frame.seqId = 12345
        frame.logId = 67890
        frame.method = "SendMessage"
        frame.payloadType = "hb"
        frame.payload = Data([0x01, 0x02, 0x03])
        let decoded = try DouyinPushFrame.decode(frame.encode())
        XCTAssertEqual(decoded.seqId, 12345)
        XCTAssertEqual(decoded.logId, 67890)
        XCTAssertEqual(decoded.method, "SendMessage")
        XCTAssertEqual(decoded.payloadType, "hb")
        XCTAssertEqual(decoded.payload, Data([0x01, 0x02, 0x03]))
    }

    func testChatMessageDecode() throws {
        var commonBytes: [UInt8] = []
        commonBytes += DouyinProtobufWriter.stringField(field: 1, "WebcastChatMessage")
        commonBytes += DouyinProtobufWriter.varintField(field: 2, 100)
        commonBytes += DouyinProtobufWriter.varintField(field: 3, 123456)
        commonBytes += DouyinProtobufWriter.varintField(field: 4, 1700000000)
        var userBytes: [UInt8] = []
        userBytes += DouyinProtobufWriter.varintField(field: 1, 999)
        userBytes += DouyinProtobufWriter.varintField(field: 2, 888)
        userBytes += DouyinProtobufWriter.stringField(field: 3, "抖音用户")
        var chatBytes: [UInt8] = []
        chatBytes += DouyinProtobufWriter.bytesField(field: 1, commonBytes)
        chatBytes += DouyinProtobufWriter.bytesField(field: 2, userBytes)
        chatBytes += DouyinProtobufWriter.stringField(field: 3, "你好抖音")
        let chat = try DouyinChatMessage.decode(Data(chatBytes))
        XCTAssertEqual(chat.common?.method, "WebcastChatMessage")
        XCTAssertEqual(chat.common?.msgId, 100)
        XCTAssertEqual(chat.common?.roomId, 123456)
        XCTAssertEqual(chat.user?.nickName, "抖音用户")
        XCTAssertEqual(chat.user?.id, 999)
        XCTAssertEqual(chat.content, "你好抖音")
    }

    func testResponseDecode() throws {
        var messageBytes: [UInt8] = []
        messageBytes += DouyinProtobufWriter.stringField(field: 1, "WebcastChatMessage")
        messageBytes += DouyinProtobufWriter.bytesField(field: 2, [0x01, 0x02])
        messageBytes += DouyinProtobufWriter.varintField(field: 3, 100)
        var responseBytes: [UInt8] = []
        responseBytes += DouyinProtobufWriter.bytesField(field: 1, messageBytes)
        responseBytes += DouyinProtobufWriter.stringField(field: 2, "cursor-1")
        responseBytes += DouyinProtobufWriter.varintField(field: 3, 5000)
        responseBytes += DouyinProtobufWriter.varintField(field: 9, 1)
        responseBytes += DouyinProtobufWriter.stringField(field: 5, "ext")
        let response = try DouyinResponse.decode(Data(responseBytes))
        XCTAssertEqual(response.messages.count, 1)
        XCTAssertEqual(response.messages[0].method, "WebcastChatMessage")
        XCTAssertEqual(response.messages[0].msgId, 100)
        XCTAssertEqual(response.cursor, "cursor-1")
        XCTAssertEqual(response.fetchInterval, 5000)
        XCTAssertTrue(response.needAck)
        XCTAssertEqual(response.internalExt, "ext")
    }

    // MARK: - Gzip PushFrame path

    func testDecodeGzipPushFrameEmitsChat() throws {
        let data = try XCTUnwrap(Data(base64Encoded: gzipFrameBase64))
        let danmaku = DouyinDanmaku()
        var received: [DanmakuMessage] = []
        danmaku.onMessage = { received.append($0) }
        danmaku.decodeMessage(data)
        XCTAssertEqual(received.count, 1)
        // Guard the indexing: a decode failure must fail this
        // test, not crash the whole test runner (which aborts
        // every suite after this one).
        guard received.count == 1 else { return }
        XCTAssertEqual(received[0].text, "你好抖音")
        XCTAssertEqual(received[0].userName, "抖音用户")
    }

    // MARK: - X-Bogus

    func testMd5Last2() {
        XCTAssertEqual(DouyinXBogus.md5Last2("4b7fae23895aed4ea2b7edf787a64750"), [63, 133])
        XCTAssertNil(DouyinXBogus.md5Last2("short"))
    }

    func testGenerateXBogusDeterministicVectors() {
        let stub = "4b7fae23895aed4ea2b7edf787a64750"
        XCTAssertEqual(DouyinXBogus.generate(msStub: stub, counter: 1, random1: 123, random2: 45), "In9W5yNUA5YxlyXX")
        XCTAssertEqual(DouyinXBogus.generate(msStub: stub, counter: 1, random1: 0, random2: 0), "fDpl4KiMGEi7FVPK")
        XCTAssertEqual(DouyinXBogus.generate(msStub: stub, counter: 1, random1: 255, random2: 254), "1eVnhJc1lIlC49jt")
        XCTAssertNil(DouyinXBogus.generate(msStub: "not-an-md5", counter: 1, random1: 0, random2: 0))
    }

    func testGetSignatureStructure() {
        let signature = DouyinDanmaku.getSignature("123456", "7123456789012345678")
        XCTAssertEqual(signature.count, 16)
        XCTAssertTrue(signature.allSatisfy { xbogusAlphabet.contains($0) })
    }
}

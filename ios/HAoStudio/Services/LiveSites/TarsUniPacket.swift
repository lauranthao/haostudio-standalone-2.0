// HAo Studio 2.0 — TUP packet framing + WUP HTTP client (S4 leg B).
//
// Swift port of the Flutter `lib/core/tars/tup/` (`uni_attribute.dart`,
// `uni_packet.dart`, `request_packet.dart`, `tars_uni_packet.dart`,
// `const.dart`, `tup_response.dart`, `tup_result_exception.dart`) and
// `lib/core/tars/base_tars_http.dart`, TUP3 only — every Huya WUP call
// sets TUP3 and the server answers in kind.
//
// Wire shape: 4-byte big-endian total length + TARS RequestPacket
// (version 3, packet type 0, servant, function, attribute map as
// sBuffer, timeout 0, empty context/status). The attribute map holds
// the request struct under `tReq`, the response struct under `tRsp`,
// and the integer result code under the empty key `""`.
//
// P0-03 (audit, carried over from the Flutter diff in the shelved
// clone): the timeout is named `timeoutSeconds` and defaults to 6;
// a non-2xx HTTP status is reported as `TupResultError` carrying
// the HTTP status; an empty body throws instead of a force unwrap.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Constants / errors

/// TUP packet-type constants (TUP3 only is used).
enum TupConst {
    static let packetTypeTarsNormal = 0
    static let packetTypeTarsOneway = 1
    static let packetTypeTup = 2
    static let packetTypeTup3 = 3
}

/// Non-zero TUP result code, or a transport failure. `code` carries
/// the TUP result code, the HTTP status for HTTP failures, or -1
/// when no code was ever received (empty body).
struct TupResultError: Error {
    var code: Int
    var message: String?

    init(_ code: Int, message: String? = nil) {
        self.code = code
        self.message = message
    }
}

extension TupResultError: LocalizedError {
    var errorDescription: String? {
        if let message = message {
            return "TUP 失败（\(code)）：\(message)"
        }
        return "TUP 失败（\(code)）"
    }
}

/// TUP response envelope: result code + decoded response struct.
struct TupResponse<T> {
    var code: Int
    var response: T?
}

// MARK: - Attribute map (TUP3)

/// The TUP attribute map: `String` keys to TARS-encoded values.
/// Only struct values are used by the Huya calls (`tReq` / `tRsp`)
/// plus the integer result code under `""`.
final class UniAttribute {
    private var dataMap: [String: Data] = [:]
    private var cache: [String: Any] = [:]

    var isEmpty: Bool {
        dataMap.isEmpty
    }

    func putStruct<T: TarsStruct>(_ name: String, _ value: T) throws {
        let output = TarsOutputStream()
        try output.writeStruct(value, tag: 0)
        dataMap[name] = output.bytes
        cache.removeValue(forKey: name)
    }

    func putInt(_ name: String, _ value: Int) throws {
        let output = TarsOutputStream()
        try output.writeInt(value, tag: 0)
        dataMap[name] = output.bytes
        cache.removeValue(forKey: name)
    }

    /// Decode the struct stored under `name`. Returns nil when the
    /// key is absent; throws when the bytes do not decode.
    func structValue<T: TarsStruct>(name: String) throws -> T? {
        if let cached = cache[name] as? T {
            return cached
        }
        guard let bytes = dataMap[name] else {
            return nil
        }
        let input = TarsInputStream(bytes)
        let value: T = try input.readStruct(tag: 0, required: true)
        cache[name] = value
        return value
    }

    /// Decode the integer stored under `name` (the result code
    /// under `""`). Returns `defaultValue` when absent.
    func intValue(name: String, defaultValue: Int = 0) -> Int {
        if let cached = cache[name] as? Int {
            return cached
        }
        guard let bytes = dataMap[name] else {
            return defaultValue
        }
        do {
            let input = TarsInputStream(bytes)
            let value = try input.readInt(tag: 0, required: true)
            cache[name] = value
            return value
        } catch {
            return defaultValue
        }
    }

    func encode() throws -> Data {
        let output = TarsOutputStream()
        try output.writeStringToBytesMap(dataMap, tag: 0)
        return output.bytes
    }

    func decode(_ data: Data) throws {
        let input = TarsInputStream(data)
        dataMap = try input.readStringToBytesMap(tag: 0, required: false)
        cache = [:]
    }
}

// MARK: - Request packet

/// The TARS RequestPacket (tags 1...10), TUP3 framing's inner
/// packet. `sBuffer` carries the encoded attribute map.
struct RequestPacket: TarsStruct {
    var iVersion: Int = 0
    var cPacketType: Int = 0
    var iMessageType: Int = 0
    var iRequestId: Int = 0
    var sServantName: String = ""
    var sFuncName: String = ""
    var sBuffer: Data = Data()
    var iTimeout: Int = 0
    var context: [String: String] = [:]
    var status: [String: String] = [:]

    init() {
    }

    func write(to output: TarsOutputStream) {
        do {
            try output.writeInt(iVersion, tag: 1)
            try output.writeInt(cPacketType, tag: 2)
            try output.writeInt(iMessageType, tag: 3)
            try output.writeInt(iRequestId, tag: 4)
            try output.writeString(sServantName, tag: 5)
            try output.writeString(sFuncName, tag: 6)
            try output.writeBytes(sBuffer, tag: 7)
            try output.writeInt(iTimeout, tag: 8)
            try output.writeStringToStringMap(context, tag: 9)
            try output.writeStringToStringMap(status, tag: 10)
        } catch {
            // Writing to an in-memory buffer only fails on a tag
            // over 255, which these fixed tags never reach.
        }
    }

    mutating func read(from input: TarsInputStream) throws {
        iVersion = try input.readInt(tag: 1)
        cPacketType = try input.readInt(tag: 2)
        iMessageType = try input.readInt(tag: 3)
        iRequestId = try input.readInt(tag: 4)
        sServantName = try input.readString(tag: 5)
        sFuncName = try input.readString(tag: 6)
        sBuffer = try input.readBytes(tag: 7)
        iTimeout = try input.readInt(tag: 8)
        context = try input.readStringToStringMap(tag: 9)
        status = try input.readStringToStringMap(tag: 10)
    }
}

// MARK: - Uni packet

/// One TUP3 packet: attribute map + RequestPacket + 4-byte
/// big-endian total-length prefix.
final class TarsUniPacket {
    static let headSize = 4

    private let attributes = UniAttribute()
    private var packet = RequestPacket()

    init() {
        packet.iVersion = TupConst.packetTypeTup3
        packet.cPacketType = TupConst.packetTypeTarsNormal
        packet.iMessageType = 0
        packet.iTimeout = 0
        packet.sBuffer = Data([0])
        packet.context = [:]
        packet.status = [:]
    }

    var servantName: String {
        get { packet.sServantName }
        set { packet.sServantName = newValue }
    }

    var funcName: String {
        get { packet.sFuncName }
        set { packet.sFuncName = newValue }
    }

    var requestId: Int {
        get { packet.iRequestId }
        set { packet.iRequestId = newValue }
    }

    var version: Int {
        get { packet.iVersion }
        set { packet.iVersion = newValue }
    }

    var packetType: Int {
        get { packet.cPacketType }
        set { packet.cPacketType = newValue }
    }

    func putStruct<T: TarsStruct>(_ name: String, _ value: T) throws {
        try attributes.putStruct(name, value)
    }

    func putInt(_ name: String, _ value: Int) throws {
        try attributes.putInt(name, value)
    }

    /// Result code from the `""` attribute (0 = success).
    func resultCode() -> Int {
        attributes.intValue(name: "")
    }

    /// Result description from the packet status map.
    var resultDescription: String {
        packet.status["STATUS_RESULT_DESC"] ?? ""
    }

    func responseStruct<T: TarsStruct>(name: String) throws -> T? {
        try attributes.structValue(name: name)
    }

    func encode() throws -> Data {
        guard !packet.sServantName.isEmpty else {
            throw TarsError.requiredFieldMissing(5)
        }
        guard !packet.sFuncName.isEmpty else {
            throw TarsError.requiredFieldMissing(6)
        }
        packet.sBuffer = try attributes.encode()
        let output = TarsOutputStream()
        packet.write(to: output)
        let body = output.bytes
        var result = Data()
        result.reserveCapacity(TarsUniPacket.headSize + body.count)
        let total = UInt32(TarsUniPacket.headSize + body.count)
        result.append(UInt8((total >> 24) & 0xFF))
        result.append(UInt8((total >> 16) & 0xFF))
        result.append(UInt8((total >> 8) & 0xFF))
        result.append(UInt8(total & 0xFF))
        result.append(body)
        return result
    }

    func decode(_ data: Data) throws {
        guard data.count >= TarsUniPacket.headSize else {
            throw TarsError.truncated
        }
        // The packet is a bare field sequence (tags 1...10), NOT a
        // struct with begin/end markers — the Dart port writes and
        // reads the fields directly, so decode must do the same.
        let input = TarsInputStream(data, position: TarsUniPacket.headSize)
        packet = RequestPacket()
        try packet.read(from: input)
        try attributes.decode(packet.sBuffer)
    }
}

// MARK: - WUP HTTP client

/// TARS-over-HTTP (WUP) client: POSTs a TUP3 packet to
/// `https://wup.huya.com` with `Content-Type: application/x-wup`
/// and decodes the TUP3 response.
///
/// P0-03: `timeoutSeconds` is in SECONDS and defaults to 6; a
/// non-2xx HTTP status throws `TupResultError` carrying the HTTP
/// status; an empty body throws `TupResultError(-1)` instead of a
/// force unwrap. The request timeout is also set on the
/// `URLRequest` (seconds), so a stalled server trips a real
/// timeout.
final class BaseTarsHttp {
    let baseUrl: String
    let servantName: String
    let path: String
    let timeoutSeconds: TimeInterval
    let headers: [String: String]
    private let fetcher: LiveDataFetcher

    init(baseUrl: String, servantName: String, path: String = "", timeoutSeconds: TimeInterval = 6, headers: [String: String] = [:], fetcher: LiveDataFetcher? = nil) {
        self.baseUrl = baseUrl
        self.servantName = servantName
        self.path = path
        self.timeoutSeconds = timeoutSeconds
        self.headers = headers
        self.fetcher = fetcher ?? LiveHTTP.defaultFetcher
    }

    /// Encode one TUP3 request packet for `methodName`.
    func buildRequest<T: TarsStruct>(methodName: String, request: T) throws -> Data {
        let packet = TarsUniPacket()
        packet.requestId = 0
        packet.version = TupConst.packetTypeTup3
        packet.packetType = TupConst.packetTypeTarsNormal
        packet.servantName = servantName
        packet.funcName = methodName
        try packet.putStruct("tReq", request)
        return try packet.encode()
    }

    /// Call `methodName` and decode the response struct. A non-zero
    /// TUP result code throws `TupResultError` with that code.
    func request<T: TarsStruct, R: TarsStruct>(methodName: String, request: T, response: R, completion: @escaping (Result<R, Error>) -> Void) {
        requestWithCode(methodName: methodName, request: request, response: response) { result in
            switch result {
            case .success(let envelope):
                if envelope.code == 0 {
                    if let value = envelope.response {
                        completion(.success(value))
                    } else {
                        completion(.failure(TupResultError(-1, message: "empty TUP response")))
                    }
                } else {
                    completion(.failure(TupResultError(envelope.code)))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Call `methodName` and return the full envelope (code +
    /// response) so callers can distinguish TUP codes themselves.
    func requestWithCode<T: TarsStruct, R: TarsStruct>(methodName: String, request: T, response: R, completion: @escaping (Result<TupResponse<R>, Error>) -> Void) {
        let body: Data
        do {
            body = try buildRequest(methodName: methodName, request: request)
        } catch {
            completion(.failure(error))
            return
        }
        guard let url = URL(string: baseUrl + path) else {
            completion(.failure(TupResultError(-1, message: "invalid WUP url")))
            return
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/x-wup", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = body
        fetcher(urlRequest) { data, statusCode, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let statusCode = statusCode, (200..<300).contains(statusCode) else {
                completion(.failure(TupResultError(statusCode ?? -1, message: "HTTP \(statusCode.map(String.init) ?? "unknown")")))
                return
            }
            guard let data = data, !data.isEmpty else {
                completion(.failure(TupResultError(-1, message: "empty TUP response")))
                return
            }
            do {
                let envelope: TupResponse<R> = try BaseTarsHttp.decodeResponse(data, response: response)
                completion(.success(envelope))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Decode one TUP3 response packet into its envelope. Pure and
    /// testable without the network.
    static func decodeResponse<R: TarsStruct>(_ data: Data, response: R) throws -> TupResponse<R> {
        let packet = TarsUniPacket()
        try packet.decode(data)
        let code = packet.resultCode()
        let value: R? = try packet.responseStruct(name: "tRsp")
        return TupResponse(code: code, response: value ?? response)
    }
}

// HAo Studio 2.0 — hand-written TARS codec (S4 leg B).
//
// Swift port of the Flutter `lib/core/tars/codec/`
// (`tars_input_stream.dart` + `tars_output_stream.dart` +
// `tars_struct.dart`), which is itself the TARS wire format:
// one header byte per field — low nibble = type, high nibble =
// tag (tag 15 escapes to a second byte) — big-endian values.
//
// Only the field types the Huya danmaku + WUP calls use are
// implemented: int (zero/byte/short/int/long), string (1/4),
// bytes (simple-list / int-list), list, map, struct. Floats and
// doubles decode/encode for completeness (no live call uses them).
//
// No force unwraps: every read bounds-checks and throws
// `TarsError.truncated` instead of trapping; a bad frame only
// drops the danmaku message, never the room.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

// MARK: - Types

/// TARS field types (wire values 0...13, same order as the Dart
/// `TarsStructType` enum).
enum TarsStructType: Int {
    case byte = 0
    case short = 1
    case int = 2
    case long = 3
    case float = 4
    case double = 5
    case string1 = 6
    case string4 = 7
    case map = 8
    case list = 9
    case structBegin = 10
    case structEnd = 11
    case zeroTag = 12
    case simpleList = 13
}

enum TarsError: Error {
    case truncated
    case typeMismatch(String)
    case requiredFieldMissing(Int)
    case invalidSize(Int)
    case stringTooLong(Int)
    case tagTooLarge(Int)
    case unsupported(String)
}

extension TarsError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .truncated:
            return "TARS 数据被截断"
        case .typeMismatch(let detail):
            return "TARS 类型不匹配：\(detail)"
        case .requiredFieldMissing(let tag):
            return "TARS 缺少必填字段 tag \(tag)"
        case .invalidSize(let size):
            return "TARS 非法长度 \(size)"
        case .stringTooLong(let length):
            return "TARS 字符串过长 \(length)"
        case .tagTooLarge(let tag):
            return "TARS 标签过大 \(tag)"
        case .unsupported(let detail):
            return "TARS 不支持：\(detail)"
        }
    }
}

/// A TARS-serialisable struct. `read` fills a fresh instance from
/// the stream (missing optional fields keep their defaults, exactly
/// like the Dart `read(..., isRequire: false)`).
protocol TarsStruct {
    init()
    func write(to output: TarsOutputStream)
    mutating func read(from input: TarsInputStream) throws
}

// MARK: - Output stream

/// TARS writer. Mirrors `TarsOutputStream` in the Dart port,
/// including its int-size optimisation (0 writes a ZERO_TAG head
/// with no value bytes; small ints write BYTE / SHORT).
final class TarsOutputStream {
    private var buffer = Data()

    var bytes: Data {
        buffer
    }

    func writeHead(type: TarsStructType, tag: Int) throws {
        if tag < 15 {
            let head = (tag << 4) | type.rawValue
            buffer.append(UInt8(head))
        } else if tag < 256 {
            let head = (15 << 4) | type.rawValue
            buffer.append(UInt8(head))
            buffer.append(UInt8(tag))
        } else {
            throw TarsError.tagTooLarge(tag)
        }
    }

    func writeInt(_ value: Int, tag: Int) throws {
        if value == 0 {
            try writeHead(type: .zeroTag, tag: tag)
            return
        }
        if value >= -128 && value <= 127 {
            try writeHead(type: .byte, tag: tag)
            buffer.append(UInt8(bitPattern: Int8(value)))
            return
        }
        if value >= -32768 && value <= 32767 {
            try writeHead(type: .short, tag: tag)
            appendInt16(Int16(value))
            return
        }
        if value >= -2147483648 && value <= 2147483647 {
            try writeHead(type: .int, tag: tag)
            appendInt32(Int32(value))
            return
        }
        try writeHead(type: .long, tag: tag)
        appendInt64(Int64(value))
    }

    func writeBool(_ value: Bool, tag: Int) throws {
        try writeInt(value ? 1 : 0, tag: tag)
    }

    func writeFloat(_ value: Float, tag: Int) throws {
        try writeHead(type: .float, tag: tag)
        var bits = value.bitPattern.bigEndian
        withUnsafeBytes(of: &bits) { bytes in
            buffer.append(contentsOf: bytes)
        }
    }

    func writeDouble(_ value: Double, tag: Int) throws {
        try writeHead(type: .double, tag: tag)
        var bits = value.bitPattern.bigEndian
        withUnsafeBytes(of: &bits) { bytes in
            buffer.append(contentsOf: bytes)
        }
    }

    func writeString(_ value: String, tag: Int) throws {
        let bytes = [UInt8](value.utf8)
        if bytes.isEmpty {
            try writeHead(type: .string1, tag: tag)
            buffer.append(0)
            return
        }
        if bytes.count > 255 {
            try writeHead(type: .string4, tag: tag)
            appendInt32(Int32(bytes.count))
            buffer.append(contentsOf: bytes)
        } else {
            try writeHead(type: .string1, tag: tag)
            buffer.append(UInt8(bytes.count))
            buffer.append(contentsOf: bytes)
        }
    }

    /// Byte arrays write as SIMPLE_LIST (head + BYTE head at tag 0
    /// + length as an int at tag 0 + raw bytes).
    func writeBytes(_ value: Data, tag: Int) throws {
        try writeHead(type: .simpleList, tag: tag)
        try writeHead(type: .byte, tag: 0)
        try writeInt(value.count, tag: 0)
        buffer.append(value)
    }

    func writeStringList(_ values: [String], tag: Int) throws {
        try writeHead(type: .list, tag: tag)
        try writeInt(values.count, tag: 0)
        for value in values {
            try writeString(value, tag: 0)
        }
    }

    func writeStructList<T: TarsStruct>(_ values: [T], tag: Int) throws {
        try writeHead(type: .list, tag: tag)
        try writeInt(values.count, tag: 0)
        for value in values {
            try writeStruct(value, tag: 0)
        }
    }

    func writeStruct<T: TarsStruct>(_ value: T, tag: Int) throws {
        try writeHead(type: .structBegin, tag: tag)
        value.write(to: self)
        try writeHead(type: .structEnd, tag: 0)
    }

    func writeStringToBytesMap(_ map: [String: Data], tag: Int) throws {
        try writeHead(type: .map, tag: tag)
        try writeInt(map.count, tag: 0)
        for key in map.keys.sorted() {
            try writeString(key, tag: 0)
            if let value = map[key] {
                try writeBytes(value, tag: 1)
            }
        }
    }

    func writeStringToStringMap(_ map: [String: String], tag: Int) throws {
        try writeHead(type: .map, tag: tag)
        try writeInt(map.count, tag: 0)
        for key in map.keys.sorted() {
            try writeString(key, tag: 0)
            if let value = map[key] {
                try writeString(value, tag: 1)
            }
        }
    }

    private func appendInt16(_ value: Int16) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { bytes in
            buffer.append(contentsOf: bytes)
        }
    }

    private func appendInt32(_ value: Int32) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { bytes in
            buffer.append(contentsOf: bytes)
        }
    }

    private func appendInt64(_ value: Int64) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { bytes in
            buffer.append(contentsOf: bytes)
        }
    }
}

// MARK: - Input stream

/// TARS reader. Mirrors `TarsInputStream` in the Dart port:
/// fields are found by scanning forward to their tag
/// (`skipToTag`); absent optional fields return the default.
final class TarsInputStream {
    private let data: Data
    private var position: Int = 0

    /// Maximum string length, same as `TarsStruct.TARS_MAX_STRING_LENGTH`
    /// (100 MB) in the Dart port.
    static let maxStringLength = 100 * 1024 * 1024

    /// Sanity cap for list / map element counts (real Huya
    /// payloads are tiny; a corrupt length must not allocate).
    static let maxCollectionSize = 100000

    init(_ data: Data, position: Int = 0) {
        self.data = data
        self.position = position
    }

    var remainingCount: Int {
        data.count - position
    }

    // MARK: Head

    /// One header byte: returns (type, tag, headerLength).
    func readHead() throws -> (type: TarsStructType, tag: Int, length: Int) {
        guard position < data.count else {
            throw TarsError.truncated
        }
        let first = Int(data[position])
        position += 1
        let rawType = first & 0x0F
        var tag = (first & 0xF0) >> 4
        var length = 1
        if tag == 15 {
            guard position < data.count else {
                throw TarsError.truncated
            }
            tag = Int(data[position])
            position += 1
            length = 2
        }
        guard let type = TarsStructType(rawValue: rawType) else {
            throw TarsError.typeMismatch("unknown TARS type \(rawType)")
        }
        return (type, tag, length)
    }

    /// Peek at the next head without consuming it.
    func peekHead() throws -> (type: TarsStructType, tag: Int, length: Int) {
        let saved = position
        let head = try readHead()
        position = saved
        return head
    }

    /// Scan forward to `tag`. Returns true when the next field IS
    /// that tag (its head is left unread); false when the field is
    /// absent (the stream stops at the struct end or a later tag).
    /// Running out of data is "absent", not an error: optional
    /// fields past the last written tag must read as their default.
    func skipToTag(_ tag: Int) throws -> Bool {
        while true {
            let head: (type: TarsStructType, tag: Int, length: Int)
            do {
                head = try peekHead()
            } catch TarsError.truncated {
                return false
            }
            if tag <= head.tag || head.type == .structEnd {
                return tag == head.tag
            }
            position += head.length
            try skipField(type: head.type)
        }
    }

    func skipToStructEnd() throws {
        while true {
            let head = try readHead()
            if head.type == .structEnd {
                return
            }
            try skipField(type: head.type)
        }
    }

    func skipField() throws {
        let head = try readHead()
        try skipField(type: head.type)
    }

    func skipField(type: TarsStructType) throws {
        switch type {
        case .byte:
            try skip(1)
        case .short:
            try skip(2)
        case .int:
            try skip(4)
        case .long:
            try skip(8)
        case .float:
            try skip(4)
        case .double:
            try skip(8)
        case .string1:
            let length = try readUInt8()
            try skip(Int(length))
        case .string4:
            let length = try readInt32()
            if length < 0 {
                throw TarsError.invalidSize(Int(length))
            }
            try skip(Int(length))
        case .map:
            let size = try readInt(tag: 0, required: true)
            if size < 0 || size > TarsInputStream.maxCollectionSize {
                throw TarsError.invalidSize(size)
            }
            for _ in 0..<(size * 2) {
                try skipField()
            }
        case .list:
            let size = try readInt(tag: 0, required: true)
            if size < 0 || size > TarsInputStream.maxCollectionSize {
                throw TarsError.invalidSize(size)
            }
            for _ in 0..<size {
                try skipField()
            }
        case .simpleList:
            let inner = try readHead()
            guard inner.type == .byte else {
                throw TarsError.typeMismatch("SIMPLE_LIST element is not BYTE")
            }
            let size = try readInt(tag: 0, required: true)
            if size < 0 {
                throw TarsError.invalidSize(size)
            }
            try skip(size)
        case .structBegin:
            try skipToStructEnd()
        case .structEnd, .zeroTag:
            break
        }
    }

    // MARK: Scalar reads

    func readInt(tag: Int, required: Bool = false, defaultValue: Int = 0) throws -> Int {
        guard try skipToTag(tag) else {
            if required {
                throw TarsError.requiredFieldMissing(tag)
            }
            return defaultValue
        }
        let head = try readHead()
        switch head.type {
        case .zeroTag:
            return 0
        case .byte:
            return Int(try readInt8())
        case .short:
            return Int(try readInt16())
        case .int:
            return Int(try readInt32())
        case .long:
            return Int(try readInt64())
        default:
            throw TarsError.typeMismatch("int field tag \(tag) has type \(head.type)")
        }
    }

    func readBool(tag: Int, required: Bool = false, defaultValue: Bool = false) throws -> Bool {
        let value = try readInt(tag: tag, required: required, defaultValue: defaultValue ? 1 : 0)
        return value != 0
    }

    func readString(tag: Int, required: Bool = false, defaultValue: String = "") throws -> String {
        guard try skipToTag(tag) else {
            if required {
                throw TarsError.requiredFieldMissing(tag)
            }
            return defaultValue
        }
        let head = try readHead()
        switch head.type {
        case .string1:
            let length = Int(try readUInt8())
            return try readUTF8(length: length)
        case .string4:
            let length = Int(try readInt32())
            if length < 0 || length > TarsInputStream.maxStringLength {
                throw TarsError.stringTooLong(length)
            }
            return try readUTF8(length: length)
        default:
            throw TarsError.typeMismatch("string field tag \(tag) has type \(head.type)")
        }
    }

    func readFloat(tag: Int, required: Bool = false, defaultValue: Float = 0) throws -> Float {
        guard try skipToTag(tag) else {
            if required {
                throw TarsError.requiredFieldMissing(tag)
            }
            return defaultValue
        }
        let head = try readHead()
        switch head.type {
        case .zeroTag:
            return 0
        case .float:
            return try readFloat32()
        case .double:
            return Float(try readFloat64())
        default:
            throw TarsError.typeMismatch("float field tag \(tag) has type \(head.type)")
        }
    }

    func readDouble(tag: Int, required: Bool = false, defaultValue: Double = 0) throws -> Double {
        guard try skipToTag(tag) else {
            if required {
                throw TarsError.requiredFieldMissing(tag)
            }
            return defaultValue
        }
        let head = try readHead()
        switch head.type {
        case .zeroTag:
            return 0
        case .float:
            return Double(try readFloat32())
        case .double:
            return try readFloat64()
        default:
            throw TarsError.typeMismatch("double field tag \(tag) has type \(head.type)")
        }
    }

    /// Byte arrays arrive as SIMPLE_LIST (or, rarely, a LIST of
    /// ints); both shapes are accepted, like the Dart port.
    func readBytes(tag: Int, required: Bool = false) throws -> Data {
        guard try skipToTag(tag) else {
            if required {
                throw TarsError.requiredFieldMissing(tag)
            }
            return Data()
        }
        let head = try readHead()
        switch head.type {
        case .simpleList:
            let inner = try readHead()
            guard inner.type == .byte else {
                throw TarsError.typeMismatch("bytes field tag \(tag) element is not BYTE")
            }
            let size = try readInt(tag: 0, required: true)
            if size < 0 {
                throw TarsError.invalidSize(size)
            }
            return try readData(length: size)
        case .list:
            let size = try readInt(tag: 0, required: true)
            if size < 0 || size > TarsInputStream.maxCollectionSize {
                throw TarsError.invalidSize(size)
            }
            var bytes = Data()
            bytes.reserveCapacity(size)
            for _ in 0..<size {
                let element = try readInt(tag: 0, required: true)
                guard element >= 0 && element <= 255 else {
                    throw TarsError.typeMismatch("bytes list element \(element) is not a byte")
                }
                bytes.append(UInt8(element))
            }
            return bytes
        default:
            throw TarsError.typeMismatch("bytes field tag \(tag) has type \(head.type)")
        }
    }

    // MARK: Composite reads

    func readStringList(tag: Int, required: Bool = false) throws -> [String] {
        guard try skipToTag(tag) else {
            if required {
                throw TarsError.requiredFieldMissing(tag)
            }
            return []
        }
        let head = try readHead()
        guard head.type == .list else {
            throw TarsError.typeMismatch("list field tag \(tag) has type \(head.type)")
        }
        let size = try readInt(tag: 0, required: true)
        if size < 0 || size > TarsInputStream.maxCollectionSize {
            throw TarsError.invalidSize(size)
        }
        var values: [String] = []
        values.reserveCapacity(size)
        for _ in 0..<size {
            values.append(try readString(tag: 0, required: true))
        }
        return values
    }

    func readStructList<T: TarsStruct>(tag: Int, required: Bool = false) throws -> [T] {
        guard try skipToTag(tag) else {
            if required {
                throw TarsError.requiredFieldMissing(tag)
            }
            return []
        }
        let head = try readHead()
        guard head.type == .list else {
            throw TarsError.typeMismatch("list field tag \(tag) has type \(head.type)")
        }
        let size = try readInt(tag: 0, required: true)
        if size < 0 || size > TarsInputStream.maxCollectionSize {
            throw TarsError.invalidSize(size)
        }
        var values: [T] = []
        values.reserveCapacity(size)
        for _ in 0..<size {
            values.append(try readStruct(tag: 0, required: true))
        }
        return values
    }

    func readStruct<T: TarsStruct>(tag: Int, required: Bool = false) throws -> T {
        guard try skipToTag(tag) else {
            if required {
                throw TarsError.requiredFieldMissing(tag)
            }
            return T()
        }
        let head = try readHead()
        guard head.type == .structBegin else {
            throw TarsError.typeMismatch("struct field tag \(tag) has type \(head.type)")
        }
        var value = T()
        try value.read(from: self)
        try skipToStructEnd()
        return value
    }

    func readStringToBytesMap(tag: Int, required: Bool = false) throws -> [String: Data] {
        guard try skipToTag(tag) else {
            if required {
                throw TarsError.requiredFieldMissing(tag)
            }
            return [:]
        }
        let head = try readHead()
        guard head.type == .map else {
            throw TarsError.typeMismatch("map field tag \(tag) has type \(head.type)")
        }
        let size = try readInt(tag: 0, required: true)
        if size < 0 || size > TarsInputStream.maxCollectionSize {
            throw TarsError.invalidSize(size)
        }
        var map: [String: Data] = [:]
        for _ in 0..<size {
            let key = try readString(tag: 0, required: true)
            let value = try readBytes(tag: 1, required: true)
            map[key] = value
        }
        return map
    }

    func readStringToStringMap(tag: Int, required: Bool = false) throws -> [String: String] {
        guard try skipToTag(tag) else {
            if required {
                throw TarsError.requiredFieldMissing(tag)
            }
            return [:]
        }
        let head = try readHead()
        guard head.type == .map else {
            throw TarsError.typeMismatch("map field tag \(tag) has type \(head.type)")
        }
        let size = try readInt(tag: 0, required: true)
        if size < 0 || size > TarsInputStream.maxCollectionSize {
            throw TarsError.invalidSize(size)
        }
        var map: [String: String] = [:]
        for _ in 0..<size {
            let key = try readString(tag: 0, required: true)
            let value = try readString(tag: 1, required: true)
            map[key] = value
        }
        return map
    }

    // MARK: - Raw reads

    private func skip(_ count: Int) throws {
        if count < 0 || position + count > data.count {
            throw TarsError.truncated
        }
        position += count
    }

    private func readUInt8() throws -> UInt8 {
        guard position < data.count else {
            throw TarsError.truncated
        }
        let value = data[position]
        position += 1
        return value
    }

    private func readInt8() throws -> Int8 {
        Int8(bitPattern: try readUInt8())
    }

    private func readInt16() throws -> Int16 {
        let bits = try readBigEndianUnsigned(count: 2)
        return Int16(bitPattern: UInt16(truncatingIfNeeded: bits))
    }

    private func readInt32() throws -> Int32 {
        let bits = try readBigEndianUnsigned(count: 4)
        return Int32(bitPattern: UInt32(truncatingIfNeeded: bits))
    }

    private func readInt64() throws -> Int64 {
        let bits = try readBigEndianUnsigned(count: 8)
        return Int64(bitPattern: bits)
    }

    /// Big-endian bytes accumulated unsigned (signed accumulation
    /// would trap on overflow while shifting).
    private func readBigEndianUnsigned(count: Int) throws -> UInt64 {
        let bytes = try readData(length: count)
        var value: UInt64 = 0
        for byte in bytes {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    private func readFloat32() throws -> Float {
        let bits = try readBigEndianUnsigned(count: 4)
        return Float(bitPattern: UInt32(truncatingIfNeeded: bits))
    }

    private func readFloat64() throws -> Double {
        let bits = try readBigEndianUnsigned(count: 8)
        return Double(bitPattern: bits)
    }

    private func readUTF8(length: Int) throws -> String {
        let bytes = try readData(length: length)
        return String(decoding: bytes, as: UTF8.self)
    }

    private func readData(length: Int) throws -> Data {
        if length < 0 || position + length > data.count {
            throw TarsError.truncated
        }
        let slice = data.subdata(in: position..<(position + length))
        position += length
        return slice
    }
}

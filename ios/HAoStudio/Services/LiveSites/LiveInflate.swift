// HAo Studio 2.0 — pure-Swift DEFLATE decoder (S4 leg B).
//
// RFC 1951 inflate, written by hand because the two compressed
// danmaku paths need it and the app cannot take a dependency for
// it: Bilibili protover-2 frames are zlib and Douyin push payloads
// are usually gzip (both are DEFLATE streams; brotli / protover-3
// is a different algorithm and stays out — see BilibiliDanmaku).
//
// No Compression / zlib import: the Xcode app target would need a
// new linked framework for it, and this leg may not touch the
// project file. The decoder is verified by fixtures generated with
// Python's zlib/gzip (see LiveInflateTests): stored, fixed-Huffman
// and dynamic-Huffman blocks, plus gzip wrappers.
//
// Safety: output is capped at 16 MB (same cap the Flutter port
// puts on decompressed danmaku); a corrupt stream throws instead
// of allocating. Decode failures only drop the frame, never crash
// the room.

import Foundation

enum LiveInflateError: Error {
    case truncated
    case invalidBlockType
    case invalidHuffmanCode
    case invalidDistance
    case invalidHeader
    case outputTooLarge
    case checksumMismatch
}

enum LiveInflate {
    /// Hard output cap, in bytes (16 MB — the Flutter Bilibili
    /// decoder's `_maxDecompressedMessageBytes`).
    static let maxOutputBytes = 16 * 1024 * 1024

    /// Inflate a raw DEFLATE stream.
    static func inflate(_ data: Data) throws -> Data {
        var reader = BitReader(data: data)
        var output = [UInt8]()
        output.reserveCapacity(min(data.count * 3, 1 << 20))
        var isFinal = false
        while !isFinal {
            let header = try reader.readBits(3)
            isFinal = (header & 1) == 1
            let blockType = (header >> 1) & 0x3
            switch blockType {
            case 0:
                try inflateStored(reader: &reader, output: &output)
            case 1:
                let tables = fixedTables()
                try inflateCompressed(reader: &reader, output: &output, literalTable: tables.literal, distanceTable: tables.distance)
            case 2:
                let tables = try readDynamicTables(reader: &reader)
                try inflateCompressed(reader: &reader, output: &output, literalTable: tables.literal, distanceTable: tables.distance)
            default:
                throw LiveInflateError.invalidBlockType
            }
        }
        return Data(output)
    }

    /// Inflate a zlib stream (2-byte header + DEFLATE + Adler-32).
    static func inflateZlib(_ data: Data) throws -> Data {
        guard data.count >= 2 else {
            throw LiveInflateError.truncated
        }
        let compressionMethod = data[0] & 0x0F
        guard compressionMethod == 8 else {
            throw LiveInflateError.invalidHeader
        }
        guard data.count >= 6 else {
            throw LiveInflateError.truncated
        }
        let body = data.subdata(in: 2..<(data.count - 4))
        let output = try inflate(body)
        let storedAdler = readBigEndianUInt32(data, at: data.count - 4)
        if adler32([UInt8](output)) != storedAdler {
            throw LiveInflateError.checksumMismatch
        }
        return output
    }

    /// Inflate a gzip stream (header + DEFLATE + CRC32 + ISIZE).
    /// The CRC is not verified (ISIZE is); a bad CRC still yields
    /// the bytes, and the caller drops the frame on a bad ISIZE.
    static func inflateGzip(_ data: Data) throws -> Data {
        guard data.count >= 18 else {
            throw LiveInflateError.truncated
        }
        guard data[0] == 0x1F && data[1] == 0x8B && data[2] == 8 else {
            throw LiveInflateError.invalidHeader
        }
        let flags = data[3]
        var offset = 10
        if (flags & 0x04) != 0 {
            guard data.count >= offset + 2 else {
                throw LiveInflateError.truncated
            }
            let extraLength = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + extraLength
        }
        if (flags & 0x08) != 0 {
            guard let end = findZeroByte(data, from: offset) else {
                throw LiveInflateError.truncated
            }
            offset = end + 1
        }
        if (flags & 0x10) != 0 {
            guard let end = findZeroByte(data, from: offset) else {
                throw LiveInflateError.truncated
            }
            offset = end + 1
        }
        if (flags & 0x02) != 0 {
            offset += 2
        }
        guard data.count >= offset + 8 else {
            throw LiveInflateError.truncated
        }
        let bodyEnd = data.count - 8
        guard bodyEnd >= offset else {
            throw LiveInflateError.truncated
        }
        let body = data.subdata(in: offset..<bodyEnd)
        let output = try inflate(body)
        let expectedSize = readLittleEndianUInt32(data, at: data.count - 4)
        if UInt32(output.count) != expectedSize {
            throw LiveInflateError.checksumMismatch
        }
        return output
    }

    /// Detect a gzip payload by its magic bytes (same check the
    /// Flutter Douyin decoder uses alongside `payloadEncoding`).
    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[0] == 0x1F && data[1] == 0x8B
    }

    // MARK: - Blocks

    private static func inflateStored(reader: inout BitReader, output: inout [UInt8]) throws {
        reader.alignToByte()
        guard reader.remainingBytes >= 4 else {
            throw LiveInflateError.truncated
        }
        let length = reader.readUInt16LittleEndian()
        let complement = reader.readUInt16LittleEndian()
        if length ^ complement != 0xFFFF {
            throw LiveInflateError.invalidHeader
        }
        guard reader.remainingBytes >= Int(length) else {
            throw LiveInflateError.truncated
        }
        try appendOutput(&output, bytes: reader.readBytes(Int(length)))
    }

    private static func inflateCompressed(reader: inout BitReader, output: inout [UInt8], literalTable: HuffmanTable, distanceTable: HuffmanTable) throws {
        while true {
            let symbol = try literalTable.decode(reader: &reader)
            if symbol == 256 {
                return
            }
            if symbol < 256 {
                try appendOutput(&output, byte: UInt8(symbol))
                continue
            }
            let lengthIndex = symbol - 257
            guard lengthIndex >= 0 && lengthIndex < lengthBases.count else {
                throw LiveInflateError.invalidHuffmanCode
            }
            let extraLengthBits = lengthExtraBits[lengthIndex]
            let extraLength = extraLengthBits == 0 ? 0 : try reader.readBits(extraLengthBits)
            let length = lengthBases[lengthIndex] + extraLength
            let distanceSymbol = try distanceTable.decode(reader: &reader)
            guard distanceSymbol >= 0 && distanceSymbol < distanceBases.count else {
                throw LiveInflateError.invalidHuffmanCode
            }
            let extraDistanceBits = distanceExtraBits[distanceSymbol]
            let extraDistance = extraDistanceBits == 0 ? 0 : try reader.readBits(extraDistanceBits)
            let distance = distanceBases[distanceSymbol] + extraDistance
            guard distance > 0 && distance <= output.count else {
                throw LiveInflateError.invalidDistance
            }
            for _ in 0..<length {
                let byte = output[output.count - distance]
                try appendOutput(&output, byte: byte)
            }
        }
    }

    private static func appendOutput(_ output: inout [UInt8], byte: UInt8) throws {
        if output.count >= maxOutputBytes {
            throw LiveInflateError.outputTooLarge
        }
        output.append(byte)
    }

    private static func appendOutput(_ output: inout [UInt8], bytes: [UInt8]) throws {
        if output.count + bytes.count > maxOutputBytes {
            throw LiveInflateError.outputTooLarge
        }
        output.append(contentsOf: bytes)
    }

    // MARK: - Tables

    private static func fixedTables() -> (literal: HuffmanTable, distance: HuffmanTable) {
        var literalLengths = [Int](repeating: 0, count: 288)
        for i in 0..<144 {
            literalLengths[i] = 8
        }
        for i in 144..<256 {
            literalLengths[i] = 9
        }
        for i in 256..<280 {
            literalLengths[i] = 7
        }
        for i in 280..<288 {
            literalLengths[i] = 8
        }
        let literal = HuffmanTable(lengths: literalLengths)
        let distance = HuffmanTable(lengths: [Int](repeating: 5, count: 30))
        return (literal, distance)
    }

    private static func readDynamicTables(reader: inout BitReader) throws -> (literal: HuffmanTable, distance: HuffmanTable) {
        let literalCount = try reader.readBits(5) + 257
        let distanceCount = try reader.readBits(5) + 1
        let codeLengthCount = try reader.readBits(4) + 4
        let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var codeLengths = [Int](repeating: 0, count: 19)
        for i in 0..<codeLengthCount {
            codeLengths[codeLengthOrder[i]] = try reader.readBits(3)
        }
        let codeLengthTable = HuffmanTable(lengths: codeLengths)
        let totalCount = literalCount + distanceCount
        var lengths = [Int](repeating: 0, count: totalCount)
        var index = 0
        while index < totalCount {
            let symbol = try codeLengthTable.decode(reader: &reader)
            if symbol < 16 {
                lengths[index] = symbol
                index += 1
            } else if symbol == 16 {
                guard index > 0 else {
                    throw LiveInflateError.invalidHuffmanCode
                }
                let repeatCount = try reader.readBits(2) + 3
                let previous = lengths[index - 1]
                for _ in 0..<repeatCount {
                    if index >= totalCount {
                        throw LiveInflateError.invalidHuffmanCode
                    }
                    lengths[index] = previous
                    index += 1
                }
            } else if symbol == 17 {
                let repeatCount = try reader.readBits(3) + 3
                for _ in 0..<repeatCount {
                    if index >= totalCount {
                        throw LiveInflateError.invalidHuffmanCode
                    }
                    lengths[index] = 0
                    index += 1
                }
            } else if symbol == 18 {
                let repeatCount = try reader.readBits(7) + 11
                for _ in 0..<repeatCount {
                    if index >= totalCount {
                        throw LiveInflateError.invalidHuffmanCode
                    }
                    lengths[index] = 0
                    index += 1
                }
            } else {
                throw LiveInflateError.invalidHuffmanCode
            }
        }
        let literal = HuffmanTable(lengths: Array(lengths[0..<literalCount]))
        let distance = HuffmanTable(lengths: Array(lengths[literalCount..<totalCount]))
        return (literal, distance)
    }

    // MARK: - Length / distance bases (RFC 1951 section 3.2.5)

    private static let lengthBases = [
        3, 4, 5, 6, 7, 8, 9, 10,
        11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115,
        131, 163, 195, 227, 258
    ]

    private static let lengthExtraBits = [
        0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4,
        5, 5, 5, 5, 0
    ]

    private static let distanceBases = [
        1, 2, 3, 4, 5, 7, 9, 13,
        17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073,
        4097, 6145, 8193, 12289, 16385, 24577
    ]

    private static let distanceExtraBits = [
        0, 0, 0, 0, 1, 1, 2, 2,
        3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10,
        11, 11, 12, 12, 13, 13
    ]

    // MARK: - Checksums / byte helpers

    private static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    private static func readBigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private static func readLittleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    private static func findZeroByte(_ data: Data, from offset: Int) -> Int? {
        var index = offset
        while index < data.count {
            if data[index] == 0 {
                return index
            }
            index += 1
        }
        return nil
    }
}

// MARK: - Bit reader (LSB-first within each byte, RFC 1951 section 3.1.1)

private struct BitReader {
    private let data: Data
    private var byteOffset: Int = 0
    private var bitOffset: Int = 0

    init(data: Data) {
        self.data = data
    }

    var remainingBytes: Int {
        data.count - byteOffset
    }

    mutating func readBit() throws -> Int {
        guard byteOffset < data.count else {
            throw LiveInflateError.truncated
        }
        let bit = (data[byteOffset] >> bitOffset) & 1
        bitOffset += 1
        if bitOffset == 8 {
            bitOffset = 0
            byteOffset += 1
        }
        return Int(bit)
    }

    mutating func readBits(_ count: Int) throws -> Int {
        var value = 0
        for i in 0..<count {
            let bit = try readBit()
            value |= bit << i
        }
        return value
    }

    mutating func alignToByte() {
        if bitOffset != 0 {
            bitOffset = 0
            byteOffset += 1
        }
    }

    mutating func readUInt16LittleEndian() -> UInt16 {
        let low = UInt16(data[byteOffset])
        let high = UInt16(data[byteOffset + 1])
        byteOffset += 2
        return low | (high << 8)
    }

    mutating func readBytes(_ count: Int) -> [UInt8] {
        let end = byteOffset + count
        let bytes = [UInt8](data[byteOffset..<end])
        byteOffset = end
        return bytes
    }
}

// MARK: - Canonical Huffman table (RFC 1951 section 3.2.2)

private struct HuffmanTable {
    /// table[length][code] = symbol. Codes are read MSB-first from
    /// the stream (the first bit read is the code's top bit), so the
    /// decode loop shifts the accumulated code left per bit.
    private let table: [Int: [Int: Int]]
    private let maxLength: Int

    init(lengths: [Int]) {
        var counts = [Int](repeating: 0, count: 16)
        for length in lengths where length > 0 {
            counts[length] += 1
        }
        var nextCode = [Int](repeating: 0, count: 16)
        var code = 0
        for length in 1..<16 {
            code = (code + counts[length - 1]) << 1
            nextCode[length] = code
        }
        var built: [Int: [Int: Int]] = [:]
        var runningMax = 0
        for (symbol, length) in lengths.enumerated() where length > 0 {
            let assigned = nextCode[length]
            nextCode[length] += 1
            if built[length] == nil {
                built[length] = [:]
            }
            built[length]?[assigned] = symbol
            if length > runningMax {
                runningMax = length
            }
        }
        self.table = built
        self.maxLength = runningMax
    }

    func decode(reader: inout BitReader) throws -> Int {
        var code = 0
        for length in 1...max(1, maxLength) {
            let bit = try reader.readBit()
            code = (code << 1) | bit
            if let symbol = table[length]?[code] {
                return symbol
            }
        }
        throw LiveInflateError.invalidHuffmanCode
    }
}

// HAo Studio 2.0 — Douyin request signing (build 37, D1).
//
// Pure Swift port of Pure Live's `DouyinSigner`:
//   packages/live_core/lib/src/sites/douyin/douyin_sign.dart
// (itself a port of 3.x's `lib/core/utils/douyin/abogus.dart`,
// `douyin_utils.dart`, `lib/core/danmaku/xbogus.dart` and
// `DouyinDanmaku.getSignature`). The algorithms, tables and
// alphabets are kept bit for bit; the test vectors in
// `DouyinSignerTests` are the ones computed with the 3.x code.
//
// Algorithm (one paragraph): `aBogus(query, body)` takes the
// millisecond clock before and after, SM3-twice of the query and
// of the body each salted with "cus", and SM3 of the RC4-encrypted
// (key [0, 1, 14]) user agent after custom-base64 with alphabet1;
// those digests plus the two timestamps, the options [0, 1, 14],
// aid 6383, page id 0 and the browser fingerprint (length twice)
// are laid out as bytes in the `_order` field order, an XOR check
// byte over the `_checkOrder` fields is appended, the whole byte
// string runs through the 256-entry stream cipher (a fresh copy of
// the table per signature), and the result — behind a 12-byte
// random prefix (three 0–9999 draws) — is custom-base64 with
// alphabet0, `=`-padded to a multiple of four. `signedUrl` merges
// the base URL's query with the caller's params (first position
// kept), forces aid/compress/device_platform/browser_* and an
// msToken when absent, form-encodes the query (Dart
// `encodeQueryComponent`: everything but [A-Za-z0-9-_.~] is
// percent-encoded) and appends `&a_bogus=` + the signature of
// exactly that query string. `xBogus`/`danmakuSignature` are the
// X-Bogus of the MD5 of the fixed danmaku parameter stub (same
// file, same vectors). SM3 (GB/T 32905-2016) and MD5 (RFC 1321)
// are implemented in this file — no crypto dependency, no
// CryptoKit (which does not exist on Linux), so the file compiles
// standalone in a Linux harness.
//
// Self-contained: Foundation only, no network, no UI, no
// reference to any other app file. The user agent below must stay
// identical to `DouyinRequestParams.kDefaultUserAgent` (both are
// Pure Live's `DouyinApi.userAgent`, the Chrome 134 UA a_bogus
// encodes). Swift 5.0: completion handlers only, no async/await,
// no `any`.

import Foundation

/// Signs Douyin web requests. `userAgent` must be the exact UA the
/// signed requests are sent with (a_bogus encodes it).
/// `fingerprint` is the simulated browser window (default: random,
/// fixed for this signer); `nowMilliseconds` and `randomInt` are
/// injectable for tests.
struct DouyinSigner {
    /// The UA encoded into every a_bogus. Must match
    /// `DouyinRequestParams.kDefaultUserAgent`.
    static let defaultUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"

    /// One signer per process: a stable fingerprint, the system
    /// clock and the system random source.
    static let shared = DouyinSigner(userAgent: DouyinSigner.defaultUserAgent)

    let userAgent: String
    let fingerprint: String
    let nowMilliseconds: () -> Int64
    let randomInt: (Int) -> Int

    init(
        userAgent: String,
        fingerprint: String? = nil,
        nowMilliseconds: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        randomInt: @escaping (Int) -> Int = { Int.random(in: 0..<$0) }
    ) {
        self.userAgent = userAgent
        self.nowMilliseconds = nowMilliseconds
        self.randomInt = randomInt
        self.fingerprint = fingerprint ?? DouyinSigner.browserFingerprint(random: randomInt)
    }

    // MARK: - msToken / fingerprint / visitor id

    static let msTokenAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789="

    /// A random msToken: `length` characters of `A–Z a–z 0–9 =`
    /// (3.x's `getMSToken`; not a server-issued token).
    func msToken(length: Int = 184) -> String {
        precondition(length >= 0, "msToken length must not be negative")
        let alphabet = Array(DouyinSigner.msTokenAlphabet)
        var out = ""
        out.reserveCapacity(length)
        for _ in 0..<length {
            out.append(alphabet[randomInt(alphabet.count)])
        }
        return out
    }

    /// A browser window drawn from 3.x's ranges.
    static func browserFingerprint(random: (Int) -> Int) -> String {
        func between(_ low: Int, _ high: Int) -> Int { low + random(high - low + 1) }
        let innerWidth = between(1024, 1920)
        let innerHeight = between(768, 1080)
        let outerWidth = innerWidth + between(24, 32)
        let outerHeight = innerHeight + between(75, 90)
        let screenY = [0, 30][random(2)]
        let sizeWidth = between(1024, 1920)
        let sizeHeight = between(768, 1080)
        let availWidth = between(1280, 1920)
        let availHeight = between(800, 1080)
        return "\(innerWidth)|\(innerHeight)|\(outerWidth)|\(outerHeight)|0|\(screenY)|0|0|\(sizeWidth)|\(sizeHeight)|\(availWidth)|\(availHeight)|\(innerWidth)|\(innerHeight)|24|24|Win32"
    }

    /// A visitor id like the web client's (`user_unique_id`): `7`,
    /// a digit 3–9 and 17 more digits, 7.3e18 up to 8e18 (3.x's
    /// `generateAnonymousUserUniqueId`).
    static func visitorId(random: (Int) -> Int) -> String {
        var out = "7" + String(3 + random(7))
        for _ in 0..<17 {
            out += String(random(10))
        }
        return out
    }

    // MARK: - signedUrl

    /// 3.x's `buildRequestUrl`: `baseUrl`'s query plus `params`
    /// (ordered pairs; a later pair with an existing key replaces
    /// its value in place, as a Dart map does), the fixed browser
    /// parameters, an msToken unless one is given, form-encoded as
    /// the query `Q`; the URL's query becomes `Q&a_bogus=…` (last,
    /// as the signature's alphabet needs no encoding). Returns nil
    /// when `baseUrl` is not a URL with a scheme and host — the
    /// caller falls back to the unsigned builder.
    func signedUrl(baseUrl: String, orderedParams: [(String, String)]) -> String? {
        guard let components = URLComponents(string: baseUrl),
              components.scheme != nil, components.host != nil
        else { return nil }
        var pairs: [(String, String)] = []
        for item in components.queryItems ?? [] {
            upsert(&pairs, item.name, item.value ?? "")
        }
        for pair in orderedParams {
            upsert(&pairs, pair.0, pair.1)
        }
        for pair in DouyinSigner.forcedParams {
            upsert(&pairs, pair.0, pair.1)
        }
        if pairs.first(where: { $0.0 == "msToken" }) == nil {
            pairs.append(("msToken", msToken()))
        }
        let query = pairs.map { "\(DouyinSigner.encodeQueryComponent($0.0))=\(DouyinSigner.encodeQueryComponent($0.1))" }.joined(separator: "&")
        let bogus = aBogus(query: query)
        var prefix = baseUrl
        var fragment = ""
        if let hash = prefix.firstIndex(of: "#") {
            fragment = String(prefix[hash...])
            prefix = String(prefix[..<hash])
        }
        if let question = prefix.firstIndex(of: "?") {
            prefix = String(prefix[..<question])
        }
        return prefix + "?" + query + "&a_bogus=" + bogus + fragment
    }

    /// The dictionary form used by the site's `requestUrlSigner`
    /// seam. A Swift dictionary has no order, so the params are
    /// sorted by key for a deterministic query — the signature is
    /// computed over exactly the query that is sent, so any order
    /// is valid server-side. Use `signedUrl(baseUrl:orderedParams:)`
    /// when the order must match Dart's.
    func signedUrl(baseUrl: String, params: [String: String]) -> String? {
        let ordered = params.keys.sorted().map { ($0, params[$0] ?? "") }
        return signedUrl(baseUrl: baseUrl, orderedParams: ordered)
    }

    // MARK: - a_bogus

    /// The a_bogus of the query string `query` and request `body`
    /// (empty for a GET).
    ///
    /// SM3 twice over the salted query and body, SM3 of the
    /// RC4-encrypted UA, the clock before and after, the options,
    /// aid and page id and the fingerprint are laid out in 3.x's
    /// order, followed by an XOR check byte; the bytes go through
    /// the stream cipher and, behind a 12-byte random prefix, into
    /// the custom base64. Fields 24 and 25 (the timestamps' high
    /// bytes) are 0 as in 3.x, which masked the timestamp to 32
    /// bits before shifting it.
    func aBogus(query: String, body: String = "") -> String {
        let start = nowMilliseconds()
        let paramsHash = DouyinSigner.sm3(DouyinSigner.sm3(Array((query + DouyinSigner.salt).utf8)))
        let bodyHash = DouyinSigner.sm3(DouyinSigner.sm3(Array((body + DouyinSigner.salt).utf8)))
        let uaHash = DouyinSigner.sm3(Array(DouyinSigner.base64Encode(DouyinSigner.rc4(key: DouyinSigner.uaKey, data: Array(userAgent.utf16).map { Int($0) }), alphabet: DouyinSigner.alphabet1).utf8))
        let end = nowMilliseconds()

        var fields: [Int: Int] = [:]
        fields[8] = 3
        fields[18] = 44
        fields[66] = 0
        fields[69] = 0
        fields[70] = 0
        fields[71] = 0
        fields[20] = Int((start >> 24) & 0xFF)
        fields[21] = Int((start >> 16) & 0xFF)
        fields[22] = Int((start >> 8) & 0xFF)
        fields[23] = Int(start & 0xFF)
        fields[24] = 0
        fields[25] = 0
        fields[26] = (DouyinSigner.options[0] >> 24) & 0xFF
        fields[27] = (DouyinSigner.options[0] >> 16) & 0xFF
        fields[28] = (DouyinSigner.options[0] >> 8) & 0xFF
        fields[29] = DouyinSigner.options[0] & 0xFF
        fields[30] = (DouyinSigner.options[1] / 256) & 0xFF
        fields[31] = DouyinSigner.options[1] % 256
        fields[32] = (DouyinSigner.options[1] >> 24) & 0xFF
        fields[33] = (DouyinSigner.options[1] >> 16) & 0xFF
        fields[34] = (DouyinSigner.options[2] >> 24) & 0xFF
        fields[35] = (DouyinSigner.options[2] >> 16) & 0xFF
        fields[36] = (DouyinSigner.options[2] >> 8) & 0xFF
        fields[37] = DouyinSigner.options[2] & 0xFF
        fields[38] = Int(paramsHash[21])
        fields[39] = Int(paramsHash[22])
        fields[40] = Int(bodyHash[21])
        fields[41] = Int(bodyHash[22])
        fields[42] = Int(uaHash[23])
        fields[43] = Int(uaHash[24])
        fields[44] = Int((end >> 24) & 0xFF)
        fields[45] = Int((end >> 16) & 0xFF)
        fields[46] = Int((end >> 8) & 0xFF)
        fields[47] = Int(end & 0xFF)
        fields[48] = 3
        fields[49] = 0
        fields[50] = 0
        fields[51] = (DouyinSigner.pageId >> 24) & 0xFF
        fields[52] = (DouyinSigner.pageId >> 16) & 0xFF
        fields[53] = (DouyinSigner.pageId >> 8) & 0xFF
        fields[54] = DouyinSigner.pageId & 0xFF
        fields[55] = DouyinSigner.pageId
        fields[56] = DouyinSigner.aid
        fields[57] = DouyinSigner.aid & 0xFF
        fields[58] = (DouyinSigner.aid >> 8) & 0xFF
        fields[59] = (DouyinSigner.aid >> 16) & 0xFF
        fields[60] = (DouyinSigner.aid >> 24) & 0xFF
        fields[64] = fingerprint.utf16.count
        fields[65] = fingerprint.utf16.count

        var values: [Int] = DouyinSigner.order.map { fields[$0] ?? 0 }
        values.append(contentsOf: Array(fingerprint.utf16).map { Int($0) })
        var check = 0
        for index in DouyinSigner.checkOrder {
            check ^= fields[index] ?? 0
        }
        values.append(check)
        return DouyinSigner.base64EncodePadded(randomPrefix() + DouyinSigner.transform(values), alphabet: DouyinSigner.alphabet0)
    }

    // MARK: - X-Bogus (danmaku handshake)

    /// The danmaku connection's `signature` for this broadcast's
    /// `roomId` and the visitor's `userUniqueId` (3.x's
    /// `DouyinDanmaku.getSignature`): the X-Bogus of the MD5 of the
    /// fixed parameter string. Its alphabet has `+` and `/`, so it
    /// must be sent percent-encoded (REG-DOUYIN-002). Returns nil
    /// only when the internal MD5 stub cannot be signed (never in
    /// practice — the stub is fixed).
    func danmakuSignature(roomId: String, userUniqueId: String) -> String? {
        let stub = [
            "live_id=1",
            "aid=6383",
            "version_code=180800",
            "webcast_sdk_version=1.0.15",
            "room_id=\(roomId)",
            "sub_room_id=",
            "sub_channel_id=",
            "did_rule=3",
            "user_unique_id=\(userUniqueId)",
            "device_platform=web",
            "device_type=",
            "ac=",
            "identity=audience",
        ].joined(separator: ",")
        return xBogus(msStub: DouyinSigner.md5Hex(Array(stub.utf8)))
    }

    /// 3.x's `generateXBogus`: two random bytes, the last two bytes
    /// of the MD5 of the 16 bytes `msStub` (32 hex digits) spells,
    /// a 10-byte payload with an XOR check byte RC4-encrypted under
    /// the second random byte, all 12 bytes in the X-Bogus base64
    /// alphabet (16 characters). Returns nil when `msStub` is not
    /// 32 hex digits (Dart throws).
    func xBogus(msStub: String, counter: Int = 1) -> String? {
        guard let stubBytes = DouyinSigner.parseHexBytes(msStub), stubBytes.count == 16 else { return nil }
        let random1 = randomInt(256)
        let random2 = randomInt(255)
        let digest = DouyinSigner.md5(stubBytes)
        var payload: [Int] = [
            counter & 0x3F, 0, 1, 0x0E, 0x45, 0x3F,
            Int(digest[14]), Int(digest[15]), random2, 0,
        ]
        var checksum = 0
        for i in 0..<9 {
            checksum ^= payload[i]
        }
        payload[9] = checksum
        let encrypted = DouyinSigner.rc4(key: [random2], data: payload)
        let bytes = [0x40 | (random1 & 0x1F), random2] + encrypted
        return DouyinSigner.base64Encode(bytes, alphabet: DouyinSigner.xBogusAlphabet)
    }

    // MARK: - Internals

    /// Three groups of four bytes, each from one 0–9999 draw.
    private func randomPrefix() -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(12)
        for _ in 0..<3 {
            let value = randomInt(10000)
            out.append((value & 0xFF & 170) | 1)
            out.append((value & 0xFF & 85) | 2)
            out.append(((value >> 8) & 170) | 5)
            out.append(((value >> 8) & 85) | 40)
        }
        return out
    }

    private func upsert(_ pairs: inout [(String, String)], _ key: String, _ value: String) {
        if let index = pairs.firstIndex(where: { $0.0 == key }) {
            pairs[index].1 = value
        } else {
            pairs.append((key, value))
        }
    }

    /// Dart `Uri.encodeQueryComponent`: everything but
    /// [A-Za-z0-9-_.~] is percent-encoded (uppercase hex).
    static func encodeQueryComponent(_ string: String) -> String {
        var out = ""
        for byte in Array(string.utf8) {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F, 0x2E, 0x7E:
                out.append(Character(UnicodeScalar(byte)))
            default:
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }

    /// The stream cipher; every signature starts from the initial
    /// table (3.x built a new signer for every request).
    static func transform(_ bytes: [Int]) -> [Int] {
        var table = DouyinSigner.table
        let length = table.count
        var output: [Int] = []
        output.reserveCapacity(bytes.count)
        var indexB = table[1]
        var initial = 0
        var valueE = 0
        for (index, byte) in bytes.enumerated() {
            var sum: Int
            if index == 0 {
                initial = table[indexB]
                sum = indexB + initial
                table[1] = initial
                table[indexB] = indexB
            } else {
                sum = initial + valueE
            }
            output.append(byte ^ table[sum % length])
            let next = (index + 2) % length
            valueE = table[next]
            sum = (indexB + valueE) % length
            initial = table[sum]
            table[sum] = table[next]
            table[next] = initial
            indexB = sum
        }
        return output
    }

    /// Base64 with alphabet 0, `=` padded to a multiple of four.
    static func base64EncodePadded(_ bytes: [Int], alphabet: String) -> String {
        let chars = Array(alphabet)
        var out = ""
        var count = 0
        var i = 0
        while i < bytes.count {
            let remaining = bytes.count - i
            let n = (bytes[i] << 16) | (remaining > 1 ? bytes[i + 1] << 8 : 0) | (remaining > 2 ? bytes[i + 2] : 0)
            let group = remaining > 2 ? 4 : remaining + 1
            for j in 0..<group {
                out.append(chars[(n >> (18 - 6 * j)) & 0x3F])
                count += 1
            }
            i += 3
        }
        out.append(String(repeating: "=", count: (4 - count % 4) % 4))
        return out
    }

    /// Base64 of `bytes` with `alphabet` (3.x's `base64Encode`).
    static func base64Encode(_ bytes: [Int], alphabet: String) -> String {
        let chars = Array(alphabet)
        var out = ""
        var i = 0
        while i < bytes.count {
            let remaining = bytes.count - i
            let n = (bytes[i] << 16) | (remaining > 1 ? bytes[i + 1] << 8 : 0) | (remaining > 2 ? bytes[i + 2] : 0)
            let group = remaining > 2 ? 4 : remaining + 1
            for j in 0..<group {
                out.append(chars[(n >> (18 - 6 * j)) & 0x3F])
            }
            if remaining < 3 {
                out.append(String(repeating: "=", count: 3 - remaining))
            }
            i += 3
        }
        return out
    }

    /// Standard RC4 (KSA + PRGA) over integer bytes.
    static func rc4(key: [Int], data: [Int]) -> [Int] {
        var s = Array(0..<256)
        var j = 0
        for i in 0..<256 {
            j = (j + s[i] + key[i % key.count]) % 256
            s.swapAt(i, j)
        }
        var i = 0
        j = 0
        var out: [Int] = []
        out.reserveCapacity(data.count)
        for byte in data {
            i = (i + 1) % 256
            j = (j + s[i]) % 256
            s.swapAt(i, j)
            out.append((byte ^ s[(s[i] + s[j]) % 256]) & 0xFF)
        }
        return out
    }

    /// The SM3 digest of `data` (GB/T 32905-2016), 32 bytes.
    static func sm3(_ data: [UInt8]) -> [UInt8] {
        func rotl(_ x: UInt32, _ n: Int) -> UInt32 {
            let s = n % 32
            if s == 0 { return x }
            return (x << s) | (x >> (32 - s))
        }
        func p0(_ x: UInt32) -> UInt32 { x ^ rotl(x, 9) ^ rotl(x, 17) }
        func p1(_ x: UInt32) -> UInt32 { x ^ rotl(x, 15) ^ rotl(x, 23) }

        var padded = data
        padded.append(0x80)
        let zeros = (56 - (data.count + 1) % 64 + 64) % 64
        padded.append(contentsOf: [UInt8](repeating: 0, count: zeros))
        let bitLength = UInt64(data.count) * 8
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var v = DouyinSigner.sm3IV
        var w = [UInt32](repeating: 0, count: 68)
        var w1 = [UInt32](repeating: 0, count: 64)
        var offset = 0
        while offset < padded.count {
            for j in 0..<16 {
                let o = offset + j * 4
                w[j] = (UInt32(padded[o]) << 24) | (UInt32(padded[o + 1]) << 16) | (UInt32(padded[o + 2]) << 8) | UInt32(padded[o + 3])
            }
            for j in 16..<68 {
                w[j] = p1(w[j - 16] ^ w[j - 9] ^ rotl(w[j - 3], 15)) ^ rotl(w[j - 13], 7) ^ w[j - 6]
            }
            for j in 0..<64 {
                w1[j] = w[j] ^ w[j + 4]
            }
            var a = v[0]
            var b = v[1]
            var c = v[2]
            var d = v[3]
            var e = v[4]
            var f = v[5]
            var g = v[6]
            var h = v[7]
            for j in 0..<64 {
                let t: UInt32 = j < 16 ? 0x79CC4519 : 0x7A879D8A
                let ss1 = rotl(rotl(a, 12) &+ e &+ rotl(t, j), 7)
                let ss2 = ss1 ^ rotl(a, 12)
                let ff: UInt32 = j < 16 ? a ^ b ^ c : (a & b) | (a & c) | (b & c)
                let gg: UInt32 = j < 16 ? e ^ f ^ g : (e & f) | ((~e) & g)
                let tt1 = ff &+ d &+ ss2 &+ w1[j]
                let tt2 = gg &+ h &+ ss1 &+ w[j]
                d = c
                c = rotl(b, 9)
                b = a
                a = tt1
                h = g
                g = rotl(f, 19)
                f = e
                e = p0(tt2)
            }
            v[0] ^= a
            v[1] ^= b
            v[2] ^= c
            v[3] ^= d
            v[4] ^= e
            v[5] ^= f
            v[6] ^= g
            v[7] ^= h
            offset += 64
        }
        var digest: [UInt8] = []
        digest.reserveCapacity(32)
        for word in v {
            digest.append(UInt8((word >> 24) & 0xFF))
            digest.append(UInt8((word >> 16) & 0xFF))
            digest.append(UInt8((word >> 8) & 0xFF))
            digest.append(UInt8(word & 0xFF))
        }
        return digest
    }

    /// The MD5 digest of `data` (RFC 1321), 16 bytes. Kept in this
    /// file (instead of reusing `LiveCrypto.md5`) so the signer
    /// stays self-contained and compilable on Linux, where
    /// CryptoKit does not exist.
    static func md5(_ data: [UInt8]) -> [UInt8] {
        let s: [UInt32] = [
            7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
            5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
            4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
            6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
        ]
        let k: [UInt32] = [
            0xD76AA478, 0xE8C7B756, 0x242070DB, 0xC1BDCEEE, 0xF57C0FAF, 0x4787C62A, 0xA8304613, 0xFD469501,
            0x698098D8, 0x8B44F7AF, 0xFFFF5BB1, 0x895CD7BE, 0x6B901122, 0xFD987193, 0xA679438E, 0x49B40821,
            0xF61E2562, 0xC040B340, 0x265E5A51, 0xE9B6C7AA, 0xD62F105D, 0x02441453, 0xD8A1E681, 0xE7D3FBC8,
            0x21E1CDE6, 0xC33707D6, 0xF4D50D87, 0x455A14ED, 0xA9E3E905, 0xFCEFA3F8, 0x676F02D9, 0x8D2A4C8A,
            0xFFFA3942, 0x8771F681, 0x6D9D6122, 0xFDE5380C, 0xA4BEEA44, 0x4BDECFA9, 0xF6BB4B60, 0xBEBFBC70,
            0x289B7EC6, 0xEAA127FA, 0xD4EF3085, 0x04881D05, 0xD9D4D039, 0xE6DB99E5, 0x1FA27CF8, 0xC4AC5665,
            0xF4292244, 0x432AFF97, 0xAB9423A7, 0xFC93A039, 0x655B59C3, 0x8F0CCC92, 0xFFEFF47D, 0x85845DD1,
            0x6FA87E4F, 0xFE2CE6E0, 0xA3014314, 0x4E0811A1, 0xF7537E82, 0xBD3AF235, 0x2AD7D2BB, 0xEB86D391,
        ]
        func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

        var padded = data
        padded.append(0x80)
        let zeros = (56 - (data.count + 1) % 64 + 64) % 64
        padded.append(contentsOf: [UInt8](repeating: 0, count: zeros))
        let bitLength = UInt64(data.count) * 8
        for shift in stride(from: 0, through: 56, by: 8) {
            padded.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xEFCDAB89
        var c0: UInt32 = 0x98BADCFE
        var d0: UInt32 = 0x10325476
        var offset = 0
        while offset < padded.count {
            var m = [UInt32](repeating: 0, count: 16)
            for j in 0..<16 {
                let o = offset + j * 4
                m[j] = UInt32(padded[o]) | (UInt32(padded[o + 1]) << 8) | (UInt32(padded[o + 2]) << 16) | (UInt32(padded[o + 3]) << 24)
            }
            var a = a0
            var b = b0
            var c = c0
            var d = d0
            for i in 0..<64 {
                var f: UInt32
                var g: Int
                switch i / 16 {
                case 0:
                    f = (b & c) | ((~b) & d)
                    g = i
                case 1:
                    f = (d & b) | ((~d) & c)
                    g = (5 * i + 1) % 16
                case 2:
                    f = b ^ c ^ d
                    g = (3 * i + 5) % 16
                default:
                    f = c ^ (b | (~d))
                    g = (7 * i) % 16
                }
                let tmp = d
                d = c
                c = b
                b = b &+ rotl(a &+ f &+ k[i] &+ m[g], s[i])
                a = tmp
            }
            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
            offset += 64
        }
        var digest: [UInt8] = []
        digest.reserveCapacity(16)
        for word in [a0, b0, c0, d0] {
            digest.append(UInt8(word & 0xFF))
            digest.append(UInt8((word >> 8) & 0xFF))
            digest.append(UInt8((word >> 16) & 0xFF))
            digest.append(UInt8((word >> 24) & 0xFF))
        }
        return digest
    }

    /// Lowercase hex MD5 of UTF-8 bytes.
    static func md5Hex(_ data: [UInt8]) -> String {
        md5(data).map { String(format: "%02x", $0) }.joined()
    }

    /// The 16 bytes of a 32-hex-digit string, or nil when the
    /// string is not 32 hex digits.
    static func parseHexBytes(_ hex: String) -> [UInt8]? {
        guard hex.count == 32 else { return nil }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: return byte - 0x30
            case 0x61...0x66: return byte - 0x61 + 10
            case 0x41...0x46: return byte - 0x41 + 10
            default: return nil
            }
        }
        let bytes = Array(hex.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(16)
        for i in 0..<16 {
            guard let hi = nibble(bytes[i * 2]), let lo = nibble(bytes[i * 2 + 1]) else { return nil }
            out.append((hi << 4) | lo)
        }
        return out
    }

    // MARK: - Constants (bit for bit from douyin_sign.dart)

    static let aid = 6383
    static let pageId = 0
    static let salt = "cus"
    static let options = [0, 1, 14]
    static let uaKey = [0, 1, 14]
    static let alphabet0 = "Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe"
    static let alphabet1 = "ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe"
    static let xBogusAlphabet = "Dkdpgh4ZKsQB80/Mfvw36XI1R25+WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe"

    /// The fixed browser parameters `signedUrl` forces, in Dart's
    /// insertion order.
    static let forcedParams: [(String, String)] = [
        ("aid", "6383"),
        ("compress", "gzip"),
        ("device_platform", "web"),
        ("browser_language", "zh-CN"),
        ("browser_platform", "Win32"),
        ("browser_name", "Edge"),
        ("browser_version", "125.0.0.0"),
    ]

    static let sm3IV: [UInt32] = [
        0x7380166F, 0x4914B2B9, 0x172442D7, 0xDA8A0600,
        0xA96F30BC, 0x163138AA, 0xE38DEE4D, 0xB0FB0E4E,
    ]

    /// Field order of the signed values (3.x's `sortIndex`).
    static let order = [
        18, 20, 52, 26, 30, 34, 58, 38, 40, 53, 42, 21, 27, 54, 55, 31,
        35, 57, 39, 41, 43, 22, 28, 32, 60, 36, 23, 29, 33, 37, 44, 45,
        59, 46, 47, 48, 49, 50, 24, 25, 65, 66, 70, 71,
    ]

    /// Field order of the XOR check byte (3.x's `sortIndex2`).
    static let checkOrder = [
        18, 20, 26, 30, 34, 38, 40, 42, 21, 27, 31, 35, 39, 41, 43, 22,
        28, 32, 36, 23, 29, 33, 37, 44, 45, 46, 47, 48, 49, 50, 24, 25,
        52, 53, 54, 55, 57, 58, 59, 60, 65, 66, 70, 71,
    ]

    /// Initial stream-cipher table (3.x's `bigArray`).
    static let table = [
        121, 243, 55, 234, 103, 36, 47, 228, 30, 231, 106, 6, 115, 95, 78, 101,
        250, 207, 198, 50, 139, 227, 220, 105, 97, 143, 34, 28, 194, 215, 18, 100,
        159, 160, 43, 8, 169, 217, 180, 120, 247, 45, 90, 11, 27, 197, 46, 3,
        84, 72, 5, 68, 62, 56, 221, 75, 144, 79, 73, 161, 178, 81, 64, 187,
        134, 117, 186, 118, 16, 241, 130, 71, 89, 147, 122, 129, 65, 40, 88, 150,
        110, 219, 199, 255, 181, 254, 48, 4, 195, 248, 208, 32, 116, 167, 69, 201,
        17, 124, 125, 104, 96, 83, 80, 127, 236, 108, 154, 126, 204, 15, 20, 135,
        112, 158, 13, 1, 188, 164, 210, 237, 222, 98, 212, 77, 253, 42, 170, 202,
        26, 22, 29, 182, 251, 10, 173, 152, 58, 138, 54, 141, 185, 33, 157, 31,
        252, 132, 233, 235, 102, 196, 191, 223, 240, 148, 39, 123, 92, 82, 128, 109,
        57, 24, 38, 113, 209, 245, 2, 119, 153, 229, 189, 214, 230, 174, 232, 63,
        52, 205, 86, 140, 66, 175, 111, 171, 246, 133, 238, 193, 99, 60, 74, 91,
        225, 51, 76, 37, 145, 211, 166, 151, 213, 206, 0, 200, 244, 176, 218, 44,
        184, 172, 49, 216, 93, 168, 53, 21, 183, 41, 67, 85, 224, 155, 226, 242,
        87, 177, 146, 70, 190, 12, 162, 19, 137, 114, 25, 165, 163, 192, 23, 59,
        9, 94, 179, 107, 35, 7, 142, 131, 239, 203, 149, 136, 61, 249, 14, 156,
    ]
}

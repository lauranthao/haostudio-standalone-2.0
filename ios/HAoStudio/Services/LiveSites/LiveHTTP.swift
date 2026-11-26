// HAo Studio 2.0 — shared live HTTP + crypto helpers (S4 leg B).
//
// One injectable fetcher type for every live site, so tests feed
// recorded bytes and production goes through the shared URLSession.
// Timeouts are always SECONDS and always named so (audit P0-03:
// the old `timeOut` carried no unit and 60000 was read as 60000
// seconds). Default is 6 s.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Security

// MARK: - Fetcher

/// One raw request: response body, HTTP status, transport error.
/// The timeout lives on the `URLRequest` itself (`timeoutInterval`,
/// seconds). Tests inject a stub; production uses
/// `LiveHTTP.defaultFetcher`.
typealias LiveDataFetcher = (URLRequest, @escaping (Data?, Int?, Error?) -> Void) -> Void

enum LiveHTTP {
    /// Default request timeout, in SECONDS (P0-03: explicit unit,
    /// default 6 s, matching the Huya WUP client).
    static let defaultTimeoutSeconds: TimeInterval = 6

    /// Production fetcher over the shared URLSession.
    static func defaultFetcher(request: URLRequest, completion: @escaping (Data?, Int?, Error?) -> Void) {
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            completion(data, status, error)
        }
        task.resume()
    }

    /// Production JSON fetcher (GET with the given headers).
    static func fetchJSON(url: URL, timeoutSeconds: TimeInterval, headers: [String: String] = [:], fetcher: LiveDataFetcher? = nil, completion: @escaping ([String: Any]?) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let run = fetcher ?? defaultFetcher
        run(request) { data, status, _ in
            guard let status = status, (200..<300).contains(status), let data = data else {
                completion(nil)
                return
            }
            completion(LiveJSON.decodeObject(data))
        }
    }

    /// Production text fetcher (GET or POST, raw body + status).
    static func fetchText(request: URLRequest, fetcher: LiveDataFetcher? = nil, completion: @escaping (Int?, String?) -> Void) {
        let run = fetcher ?? defaultFetcher
        run(request) { data, status, _ in
            guard let status = status, let data = data else {
                completion(nil, nil)
                return
            }
            completion(status, String(data: data, encoding: .utf8))
        }
    }

    /// Build a GET request with query items and headers.
    static func getRequest(url: URL, queryItems: [URLQueryItem] = [], headers: [String: String] = [:], timeoutSeconds: TimeInterval = defaultTimeoutSeconds) -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        var request = URLRequest(url: components.url ?? url, timeoutInterval: timeoutSeconds)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    /// Build a POST request with a form-encoded body.
    static func postFormRequest(url: URL, body: String, headers: [String: String] = [:], timeoutSeconds: TimeInterval = defaultTimeoutSeconds) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body.data(using: .utf8)
        return request
    }

    /// Build a POST request with a JSON body.
    static func postJSONRequest(url: URL, body: [String: Any], headers: [String: String] = [:], timeoutSeconds: TimeInterval = defaultTimeoutSeconds) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        return request
    }

    /// Run `work` after a delay, on a background queue. Used for the
    /// small fixed retries (Bilibili 180 ms, Douyu descriptor refresh).
    static func after(milliseconds: Int, execute work: @escaping () -> Void) {
        let deadline = DispatchTime.now() + .milliseconds(milliseconds)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline, execute: work)
    }

    /// Run `work` after a delay in SECONDS, on a background queue.
    static func after(seconds: Double, execute work: @escaping () -> Void) {
        let deadline = DispatchTime.now() + seconds
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline, execute: work)
    }
}

// MARK: - Query strings

enum LiveQuery {
    /// RFC 3986 percent-encoding for one query value: only the
    /// unreserved set passes through. Matches Dart's
    /// `Uri.encodeQueryComponent` for the ASCII values the live
    /// signers feed it (ids, hex digests, plain tokens).
    static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// `k=v&k=v` from ordered pairs, values percent-encoded.
    static func build(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&")
    }

    /// Parse `k=v&k=v` into ordered pairs, keeping first-seen order
    /// and the LAST value for a repeated key (Dart `Uri.queryParameters`
    /// behaviour). Percent-decoding is applied to keys and values.
    static func parse(_ query: String) -> [(String, String)] {
        var orderedKeys: [String] = []
        var values: [String: String] = [:]
        for segment in query.split(separator: "&") {
            if segment.isEmpty {
                continue
            }
            let text = String(segment)
            let separator = text.firstIndex(of: "=")
            let rawKey: String
            let rawValue: String
            if let separator = separator {
                rawKey = String(text[..<separator])
                rawValue = String(text[text.index(after: separator)...])
            } else {
                rawKey = text
                rawValue = ""
            }
            let key = rawKey.removingPercentEncoding ?? rawKey
            let value = rawValue.removingPercentEncoding ?? rawValue
            if values[key] == nil {
                orderedKeys.append(key)
            }
            values[key] = value
        }
        return orderedKeys.map { ($0, values[$0] ?? "") }
    }

    static func value(_ query: String, key: String) -> String? {
        parse(query).first { $0.0 == key }?.1
    }
}

// MARK: - Crypto

enum LiveCrypto {
    /// Lowercase hex MD5 of UTF-8 text (CryptoKit; available on the
    /// 10.15 floor — same import the LX engine already uses).
    static func md5Hex(_ text: String) -> String {
        md5Hex(Data(text.utf8))
    }

    /// Lowercase hex MD5 of raw bytes.
    static func md5Hex(_ data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Raw MD5 digest bytes (16 bytes).
    static func md5(_ data: Data) -> [UInt8] {
        Array(Insecure.MD5.hash(data: data))
    }

    /// `count` random hex characters (lowercase), from the secure
    /// generator. Used for device ids / viewer guids.
    static func randomHex(count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: (count + 1) / 2)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            return String(repeating: "0", count: count)
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(count))
    }

    /// One random byte value 0...255, from the secure generator.
    static func randomByte() -> Int {
        var byte: UInt8 = 0
        let status = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
        if status != errSecSuccess {
            return 0
        }
        return Int(byte)
    }
}

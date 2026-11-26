// MusicHTTP.swift
// Shared HTTP transport + JSON + URL helpers for the music slice.
//
// - `MusicHTTPClient`: one request, no status validation (platform
//   APIs answer with non-200 bodies we still parse — Flutter's Dio
//   `validateStatus: (_) => true` parity). Default implementation is
//   URLSession; tests inject a fake.
// - `MusicJSON`: JSON encode/decode helpers. IRON LAW: never pass a
//   top-level String to `JSONSerialization.data(withJSONObject:)`
//   (NSException -> crash); strings go through `JSONEncoder`, dicts
//   and arrays through `JSONSerialization` (top-level dict/array only).
// - URL/text helpers ported from the Flutter music services
//   (`toHttps`, `isPlayableUrl`, `normalizeName`, `baseSongTitle`,
//   HTML entity decoding for Kuwo's pseudo-JSON).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - HTTP client

protocol MusicHTTPClient {
    /// One request. The returned handle lets the caller cancel the
    /// in-flight request (job timeout / resolve cancelled).
    @discardableResult
    func request(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        timeout: TimeInterval,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) -> MusicHTTPCancellable
}

protocol MusicHTTPCancellable {
    func cancel()
}

/// URLSession implementation. No status validation: the caller
/// inspects the body/status itself, as the platform APIs do.
final class URLSessionMusicHTTPClient: MusicHTTPClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    @discardableResult
    func request(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        timeout: TimeInterval,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) -> MusicHTTPCancellable {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let task = session.dataTask(with: request) { data, response, error in
            completion(data, response, error)
        }
        task.resume()
        return URLSessionHTTPTask(task: task)
    }
}

final class URLSessionHTTPTask: MusicHTTPCancellable {
    private let task: URLSessionDataTask

    init(task: URLSessionDataTask) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

// MARK: - JSON helpers

enum MusicJSON {
    /// Encode a JSON value to its string form. Dicts/arrays go
    /// through `JSONSerialization` (legal top-level types); a
    /// top-level String goes through `JSONEncoder` (the iron-law
    /// safe path — `JSONSerialization` throws NSException on it).
    static func string(from value: Any) -> String? {
        if let dict = value as? [String: Any] {
            guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        if let array = value as? [Any] {
            guard let data = try? JSONSerialization.data(withJSONObject: array) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        if let string = value as? String {
            guard let data = try? JSONEncoder().encode(string) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    /// A JS string literal (`"..."` or `null`) for embedding a Swift
    /// string in an evaluated JS snippet.
    static func jsStringLiteral(_ value: String?) -> String {
        guard let value = value else { return "null" }
        return string(from: value) ?? "\"\""
    }

    /// Decode a JSON string to `Any` (dict/array/string/number/bool/
    /// null). Reading has no top-level restriction.
    static func object(from jsonString: String) -> Any? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func dictionary(from jsonString: String) -> [String: Any]? {
        object(from: jsonString) as? [String: Any]
    }
}

// MARK: - URL / text helpers (Flutter parity)

enum MusicText {
    /// Upgrade an http URL to https. Empty/invalid input passes
    /// through unchanged (callers validate playability separately).
    static func toHttps(_ url: String) -> String {
        guard url.hasPrefix("http://") else { return url }
        return "https://" + url.dropFirst("http://".count)
    }

    /// A URL is playable when it is http(s) or a local file with a
    /// non-empty host-or-path, and its host contains no `%`
    /// (a percent in the host means the URL was double-encoded).
    static func isPlayableURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https" || scheme == "file")
        else { return false }
        if let host = url.host, host.contains("%") { return false }
        if scheme == "file" { return !url.path.isEmpty }
        return url.host != nil && !url.host!.isEmpty
    }

    /// Normalise a song/artist name for matching: lowercased,
    /// whitespace removed, common punctuation stripped.
    static func normalizeName(_ name: String) -> String {
        let lowered = name.lowercased()
        let stripped = lowered.components(separatedBy: CharacterSet(charactersIn: "()[]{}<>「」『』《》\"'·・-–—_")).joined()
        // Collapse whitespace runs to one space (and trim): "  Hello
        // World  " -> "hello world". Callers compare normalized
        // names, so both sides get the same treatment.
        let collapsed = stripped.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        return collapsed
    }

    /// Strip version/parenthetical suffixes from a title for search
    /// matching (`Song (Live)` -> `Song`).
    static func baseSongTitle(_ title: String) -> String {
        var out = title
        for open in ["\u{28}", "\u{5B}", "（", "【"] {
            if let idx = out.firstIndex(of: Character(open)) {
                out = String(out[out.startIndex..<idx])
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Decode the HTML entities Kuwo's pseudo-JSON carries
    /// (`&amp;`, `&quot;`, `&#39;`, numeric `&#NN;`).
    static func decodeHTMLEntities(_ text: String) -> String {
        var out = text
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&#39;": "'", "&nbsp;": " ",
        ]
        for (entity, replacement) in named {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric entities &#NN; / &#xHH;
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let range = NSRange(out.startIndex..., in: out)
            var result = out
            for match in regex.matches(in: out, range: range).reversed() {
                guard let fullRange = Range(match.range, in: out),
                      let numRange = Range(match.range(at: 2), in: out)
                else { continue }
                let numText = String(out[numRange])
                let isHex = Range(match.range(at: 1), in: out).map { !out[$0].isEmpty } ?? false
                let code = isHex ? Int(numText, radix: 16) : Int(numText)
                if let code = code, let scalar = Unicode.Scalar(code) {
                    result.replaceSubrange(fullRange, with: String(Character(scalar)))
                }
            }
            out = result
        }
        return out
    }

    /// Full entity decoding for Kuwo names: double-escaped `\uXXXX`
    /// sequences first, then HTML entities. (Flutter `decodeEntities`.)
    static func decodeEntities(_ text: String) -> String {
        var out = text
        if let regex = try? NSRegularExpression(pattern: "\\\\u([0-9a-fA-F]{4})") {
            let range = NSRange(out.startIndex..., in: out)
            var result = out
            for match in regex.matches(in: out, range: range).reversed() {
                guard let fullRange = Range(match.range, in: out),
                      let numRange = Range(match.range(at: 1), in: out),
                      let code = Int(String(out[numRange]), radix: 16),
                      let scalar = Unicode.Scalar(code)
                else { continue }
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
            out = result
        }
        return decodeHTMLEntities(out)
    }

    /// Upgrade a cover URL: QQ `y.gtimg.cn` `T00xR300x300M000` ->
    /// 800px, NetEase `music.126.net` -> `param=800y800` (replacing
    /// any existing size param). Flutter `coverHi` parity.
    static func coverHi(_ urlString: String, platform: String) -> String {
        var s = toHttps(urlString)
        guard !s.isEmpty else { return s }
        if s.contains("y.gtimg.cn/music/photo_new/T00") {
            if let regex = try? NSRegularExpression(pattern: "T00([12])R300x300M000") {
                let range = NSRange(s.startIndex..., in: s)
                s = regex.stringByReplacingMatches(
                    in: s, range: range, withTemplate: "T00$1R800x800M000")
            }
        }
        if s.contains("music.126.net") {
            if let regex = try? NSRegularExpression(pattern: "([?&])param=\\d+y\\d+") {
                let range = NSRange(s.startIndex..., in: s)
                if regex.firstMatch(in: s, range: range) != nil {
                    s = regex.stringByReplacingMatches(
                        in: s, range: range, withTemplate: "$1param=800y800")
                } else {
                    s = s.contains("?") ? s + "&param=800y800" : s + "?param=800y800"
                }
            }
        }
        return s
    }
}

// MARK: - b45-F: NetEase CDN twin-host failover (plan §7.4)
//
// NetEase serves audio from twin hosts `m801` ↔ `m801c` (the
// signature lives in the path, so it is host-independent). A host
// that fails BEFORE the request (DNS / connect / certificate) is
// remembered unreachable for 10 minutes on a monotonic clock;
// a playback failure then retries the same URL on the twin host
// once. Playback-mid-stream failures are not host failures and
// never mark a host.

enum NeteaseCDNHostFailover {
    /// Unreachable-host TTL (10 minutes, monotonic clock).
    static let unreachableTTL: TimeInterval = 10 * 60

    private static var unreachableUntil: [String: TimeInterval] = [:]
    private static let lock = NSLock()

    /// Monotonic now (survives wall-clock changes).
    static var monotonicNow: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// True when this host is a NetEase audio CDN twin host
    /// (`m801…` / `m801c…`).
    static func isTwinHost(_ host: String) -> Bool {
        host.lowercased().hasPrefix("m801")
    }

    /// The twin-host URL for a NetEase CDN URL: `m801.` ↔
    /// `m801c.` swapped, everything else (path, query, signature)
    /// untouched. Nil for non-twin hosts.
    static func twinHostURL(for url: URL) -> URL? {
        guard let host = url.host, isTwinHost(host) else { return nil }
        let lowered = host.lowercased()
        let twin: String
        if lowered.hasPrefix("m801c.") {
            twin = "m801." + host.dropFirst("m801c.".count)
        } else if lowered.hasPrefix("m801.") {
            twin = "m801c." + host.dropFirst("m801.".count)
        } else {
            return nil
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = twin
        return components?.url
    }

    /// True when a pre-request failure (DNS / connection /
    /// certificate) should mark the host unreachable. Timeouts
    /// and HTTP statuses are not pre-request failures.
    static func isPreRequestFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRequired:
            return true
        default:
            return false
        }
    }

    /// Record a pre-request failure for the URL's host. Callers
    /// must check `isPreRequestFailure` first (or pass the error
    /// through `noteFailure(url:error:)`).
    static func noteUnreachable(host: String) {
        lock.lock()
        unreachableUntil[host.lowercased()] = monotonicNow() + unreachableTTL
        lock.unlock()
    }

    static func noteFailure(url: URL, error: Error) {
        guard isPreRequestFailure(error), let host = url.host else { return }
        noteUnreachable(host: host)
    }

    static func isUnreachable(host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = unreachableUntil[host.lowercased()] else { return false }
        if monotonicNow() >= until {
            unreachableUntil.removeValue(forKey: host.lowercased())
            return false
        }
        return true
    }

    /// Preferred URL to request: the twin host when the URL's host
    /// is currently remembered unreachable, otherwise the URL
    /// itself.
    static func preferredURL(for url: URL) -> URL {
        guard let host = url.host, isUnreachable(host: host) else { return url }
        return twinHostURL(for: url) ?? url
    }
}

// MusicAPITransport.swift
// Shared HTTP transport for the six music API modules.
//
// One `MusicHTTPClient` underneath (URLSession by default); every
// call uses per-call timeouts matching the Flutter values. Upstream
// failures return empty / nil, never throw out of the per-platform
// functions — one platform failing must not kill the others.
// Completions are delivered on the main queue (the UI leg consumes
// them); internal chaining hops threads freely.
//
// Timeout / retry policy (unified across the six modules):
// - Song search legs: 5 s cap each (aggregator), kg/kw retry once
//   after 800 ms ONLY when the API answered 200 with an empty list
//   (their known flakiness); a null fetch (network/timeout) is NOT
//   retried.
// - Detail / album / artist / plaza / comments: 10 s default
//   (artist detail 15 s, Kuwo lyrics 15 s, comments 8 s).
// - Playlist import pages: one retry after 800 ms on null.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The user agent for all music search/detail/lyrics/comments/plaza
/// calls (same string the resolver uses).
enum MusicUA {
    static let value =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 " +
        "Safari/604.1"
}

/// Loose JSON field readers. Kuwo's single-quoted JSON yields string
/// numbers after the quote swap — accept both num and String.
enum MusicAPIJSON {
    static func asInt(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    static func asDouble(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) ?? 0 }
        return 0
    }

    static func asString(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    static func asList(_ value: Any?) -> [[String: Any]] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { $0 as? [String: Any] }
    }

    static func asMap(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    /// First artist of a `/`-joined artist string.
    static func firstArtist(_ artist: String) -> String {
        let separators = CharacterSet(charactersIn: "/、;；,，")
        let parts = artist.components(separatedBy: separators)
        return parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// First non-empty string among several candidate keys
    /// (QQ/Kuwo payloads spell the same field several ways).
    static func firstString(_ map: [String: Any], keys: [String]) -> String {
        for key in keys {
            let value = asString(map[key])
            if !value.isEmpty { return value }
        }
        return ""
    }
}

final class MusicAPIClient {
    static let shared = MusicAPIClient()

    private let httpClient: MusicHTTPClient

    init(httpClient: MusicHTTPClient = URLSessionMusicHTTPClient()) {
        self.httpClient = httpClient
    }

    // MARK: - URL building

    static func url(_ base: String, query: [String: String] = [:]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }

    // MARK: - Requests

    /// GET returning a JSON object. Nil on network error, non-200
    /// status, or an unparseable body.
    func getJson(
        _ urlString: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        timeout: TimeInterval = 10,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        guard let url = Self.url(urlString, query: query) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        httpClient.request(url: url, method: "GET", headers: headers, body: nil, timeout: timeout) { data, response, error in
            let result = Self.parseJsonResponse(data: data, response: response, error: error)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// POST with a `application/x-www-form-urlencoded` body,
    /// returning a JSON object.
    func postFormJson(
        _ urlString: String,
        fields: [String: String],
        headers: [String: String] = [:],
        timeout: TimeInterval = 10,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let body = fields.map { key, value in
            "\(Self.percentEncode(key))=\(Self.percentEncode(value))"
        }.joined(separator: "&")
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/x-www-form-urlencoded"
        httpClient.request(url: url, method: "POST", headers: allHeaders,
                           body: body.data(using: .utf8), timeout: timeout) { data, response, error in
            let result = Self.parseJsonResponse(data: data, response: response, error: error)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// POST with a raw JSON body, returning a JSON object.
    func postJson(
        _ urlString: String,
        json: [String: Any],
        headers: [String: String] = [:],
        timeout: TimeInterval = 10,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/json"
        let body = MusicJSON.string(from: json)?.data(using: .utf8)
        httpClient.request(url: url, method: "POST", headers: allHeaders,
                           body: body, timeout: timeout) { data, response, error in
            let result = Self.parseJsonResponse(data: data, response: response, error: error)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// GET returning plain text. Nil on network error or non-200.
    func getText(
        _ urlString: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        timeout: TimeInterval = 10,
        completion: @escaping (String?) -> Void
    ) {
        guard let url = Self.url(urlString, query: query) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        httpClient.request(url: url, method: "GET", headers: headers, body: nil, timeout: timeout) { data, response, error in
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data,
                  let text = String(data: data, encoding: .utf8)
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async { completion(text) }
        }
    }

    /// Raw GET returning status + headers + body (for the redirect
    /// walker in playlist import).
    func getRaw(
        _ urlString: String,
        headers: [String: String] = [:],
        timeout: TimeInterval = 8,
        completion: @escaping (Int?, [String: String], Data?) -> Void
    ) {
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil, [:], nil) }
            return
        }
        httpClient.request(url: url, method: "GET", headers: headers, body: nil, timeout: timeout) { data, response, error in
            var status: Int?
            var headers: [String: String] = [:]
            if let httpResponse = response as? HTTPURLResponse {
                status = httpResponse.statusCode
                for (key, value) in httpResponse.allHeaderFields {
                    headers["\(key)".lowercased()] = "\(value)"
                }
            }
            _ = error
            DispatchQueue.main.async { completion(status, headers, data) }
        }
    }

    // MARK: - Helpers

    static func parseJsonResponse(data: Data?, response: URLResponse?, error: Error?) -> [String: Any]? {
        guard error == nil,
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let data = data, !data.isEmpty,
              let text = String(data: data, encoding: .utf8),
              let dict = MusicJSON.object(from: text) as? [String: Any]
        else { return nil }
        return dict
    }

    static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

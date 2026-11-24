// HAo Studio 2.0 — Bilibili WBI signing (S4 leg B).
//
// Swift port of the Flutter `lib/shared/platforms/bilibili/
// bilibili_wbi.dart` (itself a port of Pure Live 3.x
// `bilibili_site.dart`: getWbiKeys / getWbiSign / getMixinKey /
// mixinKeyEncTab).
//
// How it works: GET `api.bilibili.com/x/web-interface/nav` returns
// `wbi_img.img_url` / `sub_url`; the 32-char file stems are the
// img/sub keys. The mixin key reorders (imgKey + subKey) through
// the fixed 64-entry table and takes the first 32 chars. A request
// is signed by sorting its query params, stripping `!'()*` from
// values, adding `wts` (unix seconds), and appending
// `w_rid = md5(query + mixinKey)`.
//
// Why it is needed: unsigned calls to getInfoByRoom, getDanmuInfo
// and second/getList return code -352; WBI-signed calls return
// code 0 (verified live 2026-11-16 for rooms 6 / 7734200).
// Keys are cached 6 h and the in-flight nav fetch is shared, as in
// the Flutter port.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum BilibiliWbi {
    static let mixinKeyEncTab: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
        37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
        22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52
    ]

    /// Mixin key: reorder `origin` (imgKey + subKey, 64 chars)
    /// through the table and take the first 32 chars.
    static func mixinKey(origin: String) -> String {
        let chars = Array(origin)
        var result = ""
        for index in mixinKeyEncTab {
            if index < chars.count {
                result.append(chars[index])
            }
        }
        return String(result.prefix(32))
    }

    /// Pure signing step: sort params, strip `!'()*` from values,
    /// add `wts`, then `w_rid = md5(query + mixinKey)`.
    /// `wtsSeconds` is injectable so the signature is deterministic
    /// in tests.
    static func signParams(_ params: [String: String], mixinKey: String, wtsSeconds: Int? = nil) -> [String: String] {
        var queryParams = params
        let wts = wtsSeconds ?? Int(Date().timeIntervalSince1970)
        queryParams["wts"] = String(wts)
        var cleaned: [String: String] = [:]
        for key in queryParams.keys.sorted() {
            let value = queryParams[key] ?? ""
            cleaned[key] = value.filter { !"!'()*".contains($0) }
        }
        let query = cleaned.keys.sorted().map { key in
            "\(LiveQuery.percentEncode(key))=\(LiveQuery.percentEncode(cleaned[key] ?? ""))"
        }.joined(separator: "&")
        // The returned params carry the cleaned values too: the
        // server signs over the stripped values, so sending the
        // originals would fail verification.
        var signed = cleaned
        signed["w_rid"] = LiveCrypto.md5Hex(query + mixinKey)
        return signed
    }

    /// File stem of a `wbi_img` url: the last path component
    /// before its extension.
    static func keyStem(from url: String) -> String {
        guard let parsed = URL(string: url) else {
            return ""
        }
        let last = parsed.lastPathComponent
        if let dot = last.firstIndex(of: ".") {
            return String(last[..<dot])
        }
        return last
    }

    /// Parse `(imgKey, subKey)` out of a nav response body. Nil
    /// when the body carries no usable keys.
    static func parseKeys(from json: [String: Any]) -> (String, String)? {
        guard let data = LiveJSON.asMap(json["data"]) else {
            return nil
        }
        guard let wbiImage = LiveJSON.asMap(data["wbi_img"]) else {
            return nil
        }
        let imgUrl = LiveJSON.asString(wbiImage["img_url"])
        let subUrl = LiveJSON.asString(wbiImage["sub_url"])
        if imgUrl.isEmpty || subUrl.isEmpty {
            return nil
        }
        let imgKey = keyStem(from: imgUrl)
        let subKey = keyStem(from: subUrl)
        if imgKey.isEmpty || subKey.isEmpty {
            return nil
        }
        return (imgKey, subKey)
    }
}

/// Stateful WBI signer: caches keys 6 h, shares the in-flight nav
/// fetch between concurrent callers (a second caller waits for the
/// first instead of firing a duplicate nav request).
final class BilibiliWbiSigner {
    static let navUrl = URL(string: "https://api.bilibili.com/x/web-interface/nav")!

    private let fetcher: LiveDataFetcher
    private var imgKey: String = ""
    private var subKey: String = ""
    private var keysUpdatedAt: Date?
    private var pendingCompletions: [(Result<(String, String), Error>) -> Void] = []
    private var isFetchingKeys: Bool = false

    init(fetcher: LiveDataFetcher? = nil) {
        self.fetcher = fetcher ?? LiveHTTP.defaultFetcher
    }

    /// (imgKey, subKey), cached 6 h; concurrent callers share the
    /// in-flight nav fetch.
    func getKeys(forceRefresh: Bool = false, completion: @escaping (Result<(String, String), Error>) -> Void) {
        if !forceRefresh, !imgKey.isEmpty, !subKey.isEmpty, let updatedAt = keysUpdatedAt {
            if Date().timeIntervalSince(updatedAt) < 6 * 60 * 60 {
                completion(.success((imgKey, subKey)))
                return
            }
        }
        pendingCompletions.append(completion)
        if isFetchingKeys {
            return
        }
        isFetchingKeys = true
        var request = URLRequest(url: BilibiliWbiSigner.navUrl, timeoutInterval: LiveHTTP.defaultTimeoutSeconds)
        request.setValue(BilibiliLiveSite.userAgent, forHTTPHeaderField: "User-Agent")
        fetcher(request) { data, status, error in
            self.isFetchingKeys = false
            let completions = self.pendingCompletions
            self.pendingCompletions = []
            if let error = error {
                for item in completions {
                    item(.failure(error))
                }
                return
            }
            guard let status = status, (200..<300).contains(status), let data = data else {
                for item in completions {
                    item(.failure(LiveError.emptyResponse))
                }
                return
            }
            guard let json = LiveJSON.decodeObject(data), let keys = BilibiliWbi.parseKeys(from: json) else {
                for item in completions {
                    item(.failure(LiveError.parseFailed("Bilibili WBI keys missing from nav response")))
                }
                return
            }
            self.imgKey = keys.0
            self.subKey = keys.1
            self.keysUpdatedAt = Date()
            for item in completions {
                item(.success(keys))
            }
        }
    }

    /// Sign a full URL: its query params + `wts` + `w_rid`.
    /// Returns the signed param map — pass it as the query of a
    /// request against the bare base URL so values are encoded once.
    func signUrl(_ url: String, forceRefresh: Bool = false, completion: @escaping (Result<[String: String], Error>) -> Void) {
        getKeys(forceRefresh: forceRefresh) { result in
            switch result {
            case .success(let keys):
                let mixin = BilibiliWbi.mixinKey(origin: keys.0 + keys.1)
                var params: [String: String] = [:]
                if let components = URLComponents(string: url), let items = components.queryItems {
                    for item in items {
                        params[item.name] = item.value ?? ""
                    }
                }
                completion(.success(BilibiliWbi.signParams(params, mixinKey: mixin)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}

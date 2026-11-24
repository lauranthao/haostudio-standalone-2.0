// HAo Studio 2.0 — Emby image loader (S5, leg A).
//
// Fixes the S3 poster-401 debt: the old code fed Emby image URLs
// to AsyncImage with no auth, so every poster came back 401. This
// loader fetches through URLSession with the Emby auth header
// (`EmbyClient.imageHeaders`, X-Emby-Token from the Keychain) and
// hands the decoded image back; the token NEVER enters the URL,
// a log line, or the cache key (the cache key is the clean image
// URL string, exactly as EmbyClient builds it).
//
// - Memory cache only (NSCache, 200 images): disk caching of
//   authenticated images would need the token on read-back, so
//   there is none — a cold start re-fetches posters. Disk
//   caching waits on verifying the Emby image response headers
//   (Cache-Control / ETag) — build 36 item 10 leg 6 follow-up,
//   not this file.
// - 401 / any failure / bad data → completion(nil), no retry loop.
//   A dead poster is a placeholder, never a spinner that retries
//   forever.
// - Cost-bounded (build 36 item 10 leg 6): the old count-only
//   cap (200, no cost) theoretically allowed ~190MB (400x600
//   posters decode to ~0.96MB each). totalCostLimit is now
//   50MB (HaoImagePolicy: ~54 posters resident); each image is
//   stored with its decoded-byte cost, countLimit 200 stays as
//   a backstop.
// - No `EmbyClient.shared` exists (the client is built per
//   config), so each load builds a short-lived client from the
//   stored config to read its `imageHeaders` — same credential
//   source, no new storage.

import Foundation
import UIKit

final class EmbyImageLoader {
    static let shared = EmbyImageLoader()

    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 200
        cache.totalCostLimit = HaoImagePolicy.embyMemoryCacheTotalCostLimit
    }

    /// Load one Emby image. `config` overrides the stored config
    /// (tests pass an explicit config so they never touch the
    /// Documents dir); nil means "load the stored config".
    /// `session` is injectable for tests (a stub URLProtocol);
    /// production uses `.shared`. Completion always fires on the
    /// main queue, exactly once.
    func load(
        urlString: String,
        config: EmbyServerConfig? = nil,
        session: URLSession = .shared,
        completion: @escaping (UIImage?) -> Void
    ) {
        let clean = urlString.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: clean),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        if let cached = cache.object(forKey: clean as NSString) {
            DispatchQueue.main.async { completion(cached) }
            return
        }
        let resolved = config ?? EmbyConfigStore.load()
        guard let resolved = resolved, resolved.isConfigured else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        for (field, value) in EmbyClient(config: resolved).imageHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let task = session.dataTask(with: request) { [weak self] data, response, _ in
            // The completion fires exactly once even when this
            // loader is gone (b35 sweep: the old `guard let self`
            // return swallowed it, hanging a caller that waits
            // on the callback).
            guard let self = self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let data = data, !data.isEmpty,
                  let image = UIImage(data: data)
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.cache.setObject(image, forKey: clean as NSString, cost: Self.decodedCost(of: image))
            DispatchQueue.main.async { completion(image) }
        }
        task.resume()
    }

    /// Decoded RGBA8 bytes for the cost budget: from the backing
    /// bitmap when there is one, else estimated from the point
    /// size x scale (a cost of 0 would let an image bypass the
    /// totalCostLimit entirely).
    private static func decodedCost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return HaoImagePolicy.decodedBytes(
                widthPixels: cgImage.width, heightPixels: cgImage.height
            )
        }
        let widthPixels = Int((image.size.width * image.scale).rounded())
        let heightPixels = Int((image.size.height * image.scale).rounded())
        return HaoImagePolicy.decodedBytes(widthPixels: widthPixels, heightPixels: heightPixels)
    }

    /// Drop the memory cache (Settings "清理缓存" also clears this;
    /// it is RAM, not disk — see CacheManager).
    func clearCache() {
        cache.removeAllObjects()
    }
}

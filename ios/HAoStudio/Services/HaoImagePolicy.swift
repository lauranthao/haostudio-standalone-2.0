// HAo Studio 2.0 — shared image policy (build 36, item 10, leg 6).
//
// The pure, Foundation-only half of the shared image loader
// (HaoImageLoader.swift). It holds every number and rule the
// loader needs — cache capacities, target-size math, decoded-byte
// cost, URL normalisation, in-flight coalescing — with NO UIKit /
// ImageIO / SwiftUI dependency, so a Linux harness can compile
// this file as-is and measure the real code (see
// ~/workspace/.tmp/b36fix/harness-item10-leg6/).
//
// - Downsampling target: display points x screen scale. A 56pt
//   row cover at @3x needs 168px, not the 1000px original; a
//   110pt poster needs ~330px, not 1200px.
// - Decoded cost: 4 bytes per pixel (RGBA8). A 400x600 Emby
//   poster decodes to ~0.96MB; 200 of them (the old count-only
//   cap) is ~190MB of RAM, which is why Emby now also gets a
//   totalCostLimit (see EmbyImageLoader).
// - URL normalisation: trim + http -> https (ATS blocks plain
//   http under NSAllowsArbitraryLoads = false). One choke point
//   for every image URL in the app.
// - In-flight coalescing: one URL downloads once, however many
//   views asked for it at once (player background + main cover +
//   Now Playing used to be 3 independent requests for the same
//   URL). Waiters are completed with the same raw Data and each
//   downsamples to its own target size.

import Foundation

enum HaoImagePolicy {
    /// URLCache.shared capacities, set once at launch by
    /// HaoImageLoader.configureSharedURLCache(). Disk 200MB:
    /// posters/covers run ~100-300KB encoded, so ~700-2000
    /// images fit; memory 32MB holds the encoded bytes of the
    /// hot set. The Settings "清理缓存" row already counts and
    /// clears URLCache.shared, so this disk cache is accounted
    /// for and clearable with no new UI.
    static let sharedURLCacheMemoryCapacity = 32 * 1024 * 1024
    static let sharedURLCacheDiskCapacity = 200 * 1024 * 1024
    static let sharedURLCacheDiskPath = "HaoImageCache"

    /// Shared loader's decoded-image memory cache: 100MB total,
    /// 300 entries. Largest single entry is a full-screen
    /// background at @3x (~1170x2532x4B ~= 11.8MB), so 100MB
    /// holds ~8 backgrounds or ~150 posters; NSCache evicts
    /// under memory pressure either way — the cap bounds the
    /// steady state, it is not a guarantee. Count limit 300
    /// stays as a backstop for many tiny (56pt) covers.
    static let memoryCacheTotalCostLimit = 100 * 1024 * 1024
    static let memoryCacheCountLimit = 300

    /// Emby loader's decoded-image memory cache: 50MB total.
    /// Emby posters are fetched at maxWidth 400, so one decodes
    /// to at most ~400x600x4B ~= 0.96MB; 50MB holds ~54 of them.
    /// The old count-only cap (200, no cost) theoretically
    /// allowed ~190MB. countLimit 200 stays as a backstop.
    static let embyMemoryCacheTotalCostLimit = 50 * 1024 * 1024

    /// Target pixels for a display size: points x screen scale,
    /// at least 1px. The loader downsamples to this, never up.
    static func targetPixels(points: Double, scale: Double) -> Int {
        max(1, Int((points * scale).rounded()))
    }

    /// Decoded RGBA8 bytes for a bitmap of this size. Used as
    /// the NSCache cost, so the cost limit is a real byte
    /// budget, not an entry count.
    static func decodedBytes(widthPixels: Int, heightPixels: Int) -> Int {
        max(0, widthPixels) * max(0, heightPixels) * 4
    }

    /// Normalise an image URL string: trim whitespace, upgrade
    /// http -> https, reject empty / non-http(s) strings. Nil
    /// means "no fetchable image", never a request.
    static func normalizedURLString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        guard scheme == "http" else { return url.absoluteString }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.scheme = "https"
        return parts?.url?.absoluteString ?? url.absoluteString
    }

    /// Memory-cache key: one entry per (URL, downsample size).
    /// The size is part of the key on purpose — a 56pt row load
    /// must not poison the full player cover with a 168px
    /// bitmap. The download itself is still shared (see the
    /// coalescer): the disk cache holds one copy of the bytes.
    static func memoryCacheKey(urlString: String, maxPixelSize: Int) -> String {
        "\(urlString)|\(maxPixelSize)"
    }
}

/// In-flight request coalescer: one key downloads once. The
/// first caller returns false ("you start the fetch"); every
/// later caller while it is in flight returns true ("already
/// running — your completion is queued"). `complete` fires
/// every queued completion exactly once with the same value
/// (nil on failure — a failed fetch must not leave a waiter
/// hanging, and must not be re-fetched by each waiter).
/// Thread-safe (NSLock); the value type is generic so the
/// harness can drive the real code with Data on Linux.
final class HaoImageCoalescer<Value> {
    private let lock = NSLock()
    private var pending: [String: [(Value?) -> Void]] = [:]

    init() {}

    func join(key: String, completion: @escaping (Value?) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if pending[key] != nil {
            pending[key]?.append(completion)
            return true
        }
        pending[key] = [completion]
        return false
    }

    func complete(key: String, value: Value?) {
        lock.lock()
        let waiters = pending.removeValue(forKey: key) ?? []
        lock.unlock()
        for waiter in waiters {
            waiter(value)
        }
    }

    var inFlightCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }
}

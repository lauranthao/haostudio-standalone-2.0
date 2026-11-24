// HAo Studio 2.0 — shared image loader (build 36, item 10, leg 6).
//
// One loader for CMS posters, music covers and live covers /
// avatars, replacing the 15 bare AsyncImage call sites (audit
// B2/B3). Before this file the app had no image subsystem at
// all: no downsampling (a 56pt row cover downloaded and decoded
// the full original), no configured URLCache, and the same cover
// was fetched up to 3 times at once (player background + main
// cover + Now Playing, each its own request).
//
// What this loader does, per URL:
// - Memory: NSCache keyed by (URL, downsample size), costed in
//   decoded bytes (HaoImagePolicy), 100MB / 300 entries.
// - Disk: URLCache.shared, configured once at launch to
//   32MB memory / 200MB disk (configureSharedURLCache, called
//   from HAoStudioApp.init and lazily on first load). Responses
//   are cached per their own Cache-Control headers — a 403 is
//   not cached, so a 403 poster still re-requests (that is the
//   B5 Referer leg's problem, not this one's; this leg does not
//   change request headers — see the file header note in
//   VideoPosterCard.swift).
// - In flight: one URL downloads once (HaoImageCoalescer);
//   concurrent waiters share the bytes and each downsamples to
//   its own target size.
// - Downsampling: CGImageSource thumbnail at max(display points
//   x screen scale). The view only ever decodes the pixels it
//   displays.
//
// Behaviour contract: display, placeholder and failure states
// are unchanged — HaoCachedImage below renders the caller's own
// placeholder while loading or on failure, exactly like the
// AsyncImage phase switch it replaces. No new setting, no new
// switch: the loader is the only path, there is nothing to
// toggle.
//
// Not covered here, on purpose:
// - Emby posters keep their own loader (auth header); only its
//   totalCostLimit changed (see EmbyImageLoader). Emby disk
//   caching waits on response-header verification (B6 follow-up).
// - CMS Referer (B5 / video O1) is a separate leg: this loader
//   sends no Referer, same as AsyncImage did.

import Foundation
import ImageIO
import SwiftUI
import UIKit

final class HaoImageLoader {
    static let shared = HaoImageLoader()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let coalescer = HaoImageCoalescer<Data>()
    private let cacheConfigureLock = NSLock()
    private var cacheConfigured = false
    private var defaultSession: URLSession?

    init() {
        memoryCache.totalCostLimit = HaoImagePolicy.memoryCacheTotalCostLimit
        memoryCache.countLimit = HaoImagePolicy.memoryCacheCountLimit
    }

    /// Configure URLCache.shared once (idempotent). Called from
    /// HAoStudioApp.init before any image loads; also called
    /// lazily on first load so previews / tests that never run
    /// the app entry still get the configured cache. Must run
    /// before the default session is created — the session
    /// captures URLCache.shared at creation time.
    static func configureSharedURLCache() {
        shared.ensureSharedURLCacheConfigured()
    }

    private func ensureSharedURLCacheConfigured() {
        cacheConfigureLock.lock()
        defer { cacheConfigureLock.unlock() }
        guard !cacheConfigured else { return }
        cacheConfigured = true
        URLCache.shared = URLCache(
            memoryCapacity: HaoImagePolicy.sharedURLCacheMemoryCapacity,
            diskCapacity: HaoImagePolicy.sharedURLCacheDiskCapacity,
            diskPath: HaoImagePolicy.sharedURLCacheDiskPath
        )
    }

    /// Full-screen target in points (backgrounds: player cover
    /// backdrop, live room backdrop, video surface backdrop).
    /// UIScreen.main.bounds is the established pattern in this
    /// codebase (MusicPlayerView, VideoPlayerView).
    static var fullScreenTargetPoints: (width: Double, height: Double) {
        let bounds = UIScreen.main.bounds
        return (width: Double(bounds.width), height: Double(bounds.height))
    }

    /// Synchronous memory-cache lookup (Now Playing pre-check
    /// aside, callers normally just call load — it checks the
    /// same cache first). Nil means "not in memory" (disk or
    /// network still needed), never "no such image".
    func cachedImage(
        urlString: String,
        targetWidthPoints: Double,
        targetHeightPoints: Double
    ) -> UIImage? {
        guard let clean = HaoImagePolicy.normalizedURLString(urlString) else { return nil }
        let key = HaoImagePolicy.memoryCacheKey(
            urlString: clean, maxPixelSize: maxPixelSize(
                targetWidthPoints: targetWidthPoints,
                targetHeightPoints: targetHeightPoints
            )
        )
        return memoryCache.object(forKey: key as NSString)
    }

    /// Load one image, downsampled to the target display size.
    /// `session` is injectable for tests (a stub URLProtocol);
    /// production passes nil and gets the shared session.
    /// Completion always fires on the main queue, exactly once.
    /// A failure completes with nil — the caller shows its
    /// placeholder, there is no retry loop here (Now Playing
    /// keeps its own 3-attempt budget on top).
    func load(
        urlString: String,
        targetWidthPoints: Double,
        targetHeightPoints: Double,
        session: URLSession? = nil,
        completion: @escaping (UIImage?) -> Void
    ) {
        ensureSharedURLCacheConfigured()
        guard let clean = HaoImagePolicy.normalizedURLString(urlString),
              let url = URL(string: clean)
        else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let maxPixel = maxPixelSize(
            targetWidthPoints: targetWidthPoints,
            targetHeightPoints: targetHeightPoints
        )
        let key = HaoImagePolicy.memoryCacheKey(urlString: clean, maxPixelSize: maxPixel)
        if let cached = memoryCache.object(forKey: key as NSString) {
            DispatchQueue.main.async { completion(cached) }
            return
        }
        let cache = memoryCache
        let coalescer = self.coalescer
        let alreadyInFlight = coalescer.join(key: clean) { data in
            Self.deliver(
                data: data, maxPixelSize: maxPixel,
                cacheKey: key, cache: cache, completion: completion
            )
        }
        guard !alreadyInFlight else { return }
        let request = URLRequest(url: url, timeoutInterval: 30)
        let task = (session ?? makeDefaultSession()).dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let goodData = (status == 200 && data != nil && !data!.isEmpty) ? data : nil
            // The coalescer (not self) is captured here, so the
            // waiters complete exactly once even if the loader
            // itself is gone by the time the fetch lands.
            coalescer.complete(key: clean, value: goodData)
        }
        task.resume()
    }

    /// Drop the decoded-image memory cache (Settings "清理缓存"
    /// calls this through CacheManager.clearAll; the disk cache
    /// is cleared by the same call via URLCache.shared).
    func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }

    private func makeDefaultSession() -> URLSession {
        cacheConfigureLock.lock()
        defer { cacheConfigureLock.unlock() }
        if let session = defaultSession {
            return session
        }
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache.shared
        config.requestCachePolicy = .useProtocolCachePolicy
        let session = URLSession(configuration: config)
        defaultSession = session
        return session
    }

    private func maxPixelSize(targetWidthPoints: Double, targetHeightPoints: Double) -> Int {
        let scale = Double(UIScreen.main.scale)
        let widthPixels = HaoImagePolicy.targetPixels(points: targetWidthPoints, scale: scale)
        let heightPixels = HaoImagePolicy.targetPixels(points: targetHeightPoints, scale: scale)
        return max(widthPixels, heightPixels)
    }

    /// Decode + downsample on the URLSession callback queue
    /// (background), cache the result, then complete on main.
    /// Runs once per waiter — each waiter downsamples the same
    /// shared bytes to its own size. Static + cache passed in,
    /// so delivery does not depend on the loader instance still
    /// existing when the fetch lands.
    private static func deliver(
        data: Data?,
        maxPixelSize: Int,
        cacheKey: String,
        cache: NSCache<NSString, UIImage>,
        completion: @escaping (UIImage?) -> Void
    ) {
        guard let data = data,
              let image = downsampledImage(data: data, maxPixelSize: maxPixelSize)
        else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        if let cgImage = image.cgImage {
            let cost = HaoImagePolicy.decodedBytes(
                widthPixels: cgImage.width, heightPixels: cgImage.height
            )
            cache.setObject(image, forKey: cacheKey as NSString, cost: cost)
        }
        DispatchQueue.main.async { completion(image) }
    }

    private static func downsampledImage(data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

/// AsyncImage replacement for every remote image in the app:
/// loads through HaoImageLoader at the target display size and
/// renders the caller's own content / placeholder. The placeholder
/// shows while loading AND on failure, exactly like the
/// AsyncImage `.failure, .empty` branch it replaces — a missing
/// or failed image is a themed tile, never a spinner or a grey
/// block. `loadingURL` guards the scroll-reuse race (same shape
/// as EmbyPosterImage): a stale load landing after the cell
/// moved to another URL must not overwrite the new image.
struct HaoCachedImage<Content: View, Placeholder: View>: View {
    var urlString: String
    var targetWidth: CGFloat
    var targetHeight: CGFloat
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var loadingURL: String?

    var body: some View {
        Group {
            if let image = image {
                content(Image(uiImage: image))
            } else {
                placeholder()
            }
        }
        .onAppear {
            loadImage()
        }
        .onChange(of: urlString) { _, _ in
            loadImage()
        }
    }

    private func loadImage() {
        guard !urlString.isEmpty else {
            image = nil
            loadingURL = nil
            return
        }
        let requested = urlString
        loadingURL = requested
        HaoImageLoader.shared.load(
            urlString: urlString,
            targetWidthPoints: Double(targetWidth),
            targetHeightPoints: Double(targetHeight)
        ) { loaded in
            guard loadingURL == requested else { return }
            image = loaded
        }
    }
}

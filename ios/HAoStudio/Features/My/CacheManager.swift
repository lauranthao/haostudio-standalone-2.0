// HAo Studio 2.0 — cache manager (S5, leg A).
//
// Disk-cache accounting for the Settings "清理缓存" row. Only
// caches that REALLY exist are counted:
// - URLCache.shared on-disk usage (HTTP cache), and
// - unfinished downloads: the `.part` files under
//   `Documents/music_downloads/` (DownloadEngine.downloadSubdir;
//   a `.part` file is the resume state of a paused / interrupted
//   download — see Services/DownloadEngine/DownloadEngine.swift).
//
// Deliberately NOT counted: the music / video JSON collections
// (user data, not cache), and completed downloads (user files).
// Clearing removes the HTTP cache, the image memory caches
// (HaoImageLoader + EmbyImageLoader — RAM, not disk; the Emby
// one was previously defined but never called from anywhere),
// and the `.part` files only; completed downloads are never
// deleted by a cache clear.

import Foundation

enum CacheManager {
    /// Total on-disk cache size in bytes (URLCache disk usage +
    /// `.part` files). Completion fires on the main queue.
    static func totalSizeBytes(
        documentsURL: URL? = nil,
        completion: @escaping (Int64) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            var total: Int64 = Int64(URLCache.shared.currentDiskUsage)
            total += partFilesSize(documentsURL: documentsURL)
            let result = total
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Delete the HTTP cache, the image memory caches, and all
    /// `.part` files. Completion fires on the main queue, after
    /// the deletes.
    static func clearAll(
        documentsURL: URL? = nil,
        completion: @escaping () -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            URLCache.shared.removeAllCachedResponses()
            HaoImageLoader.shared.clearMemoryCache()
            EmbyImageLoader.shared.clearCache()
            let docs = documentsURL ?? LocalStore.documentsDirectory()
            let dir = docs.appendingPathComponent(DownloadEngine.downloadSubdir)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names where name.hasSuffix(".part") {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
            DispatchQueue.main.async { completion() }
        }
    }

    /// Sum of `.part` file sizes under the downloads directory.
    /// `documentsURL` is the test seam (nil = the real container).
    static func partFilesSize(documentsURL: URL? = nil) -> Int64 {
        let docs = documentsURL ?? LocalStore.documentsDirectory()
        let dir = docs.appendingPathComponent(DownloadEngine.downloadSubdir)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var total: Int64 = 0
        for name in names where name.hasSuffix(".part") {
            let url = dir.appendingPathComponent(name)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value {
                total += size
            }
        }
        return total
    }
}

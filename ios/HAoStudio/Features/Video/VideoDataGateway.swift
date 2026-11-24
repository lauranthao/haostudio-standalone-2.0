// HAo Studio 2.0 — video data gateway (S3-C leg).
//
// The ONE seam between the video UI (this leg) and the video
// services (B leg: CmsClient / DoubanService / EmbyClient /
// DownloadEngine) and the player core (A leg: VideoDriver).
//
// Why a protocol instead of calling the B-leg clients directly:
// the three S3 legs are built in parallel clones from the same
// seam commit, so the B-leg types do not exist in this clone yet.
// The UI below talks ONLY to this protocol (seam models only:
// VideoItem / VideoDetail / VideoHomeRow / VideoMeta).
// RealVideoDataGateway (below) maps these methods onto the B-leg
// clients — no UI file changes were needed at merge.
//
// Method shapes mirror the Flutter side (merge23):
// - CmsClient.search / detail / home / byType / typeMap
// - DoubanService.detail (title + year) — folded into fetchDetail
//   by the adapter, so the UI sees one merged VideoDetail.
// - EmbyClient.libraries / byGenre / movies / series / search —
//   mapped onto seam models (VideoItem / VideoDetail) by the
//   adapter; Emby-only shapes are the two small structs below.
// - DownloadEngine.enqueue — one call, Bool result.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.
// All completions fire on the main queue.

import Foundation

/// One Emby library (a media folder: 电影 / 电视剧 / ...).
/// The adapter maps it from the B-leg Emby models.
struct VideoEmbyLibrary: Equatable, Identifiable {
    let id: String
    let name: String
}

/// One page of items from a list endpoint. `hasMore` is false
/// when the last page returned fewer rows than the page size, or
/// when the service says there is nothing after this page.
struct VideoItemPage: Equatable {
    let items: [VideoItem]
    let hasMore: Bool

    static let empty = VideoItemPage(items: [], hasMore: false)
}

/// What the video UI needs from the services. Every method takes
/// the narrowest inputs and returns seam models only.
protocol VideoDataGateway {
    // MARK: - CMS home / browse / search / detail

    /// Home rows (category strips + recommendations). The adapter
    /// merges CmsClient.home rows with the daily row.
    func fetchHome(completion: @escaping ([VideoHomeRow]) -> Void)
    /// Category names for the tab's category strip.
    func fetchTypeNames(completion: @escaping ([String]) -> Void)
    /// One category page (0-based). Empty page = end of list.
    /// `area` / `year` / `by` are the CmsClient filter values
    /// ("all" / "all" / "" = unfiltered, exactly what the old
    /// two-argument call fetched). Swift forbids default arguments
    /// in a protocol method, so the full signature is the
    /// requirement and callers pass the three values explicitly.
    func fetchByType(_ type: String, page: Int, area: String, year: String, by: String, completion: @escaping (VideoItemPage) -> Void)
    /// CMS search across enabled sources, fastest first.
    func search(keyword: String, completion: @escaping ([VideoItem]) -> Void)
    /// Full detail: CMS lines + Douban metadata merged. Nil when
    /// the title cannot be resolved on any source.
    func fetchDetail(item: VideoItem, completion: @escaping (VideoDetail?) -> Void)

    // MARK: - Emby

    /// True when an Emby server is configured (address + login).
    /// False until B leg wires the stored config — the Emby tab
    /// then shows the "not configured" state, never fake rows.
    var embyConfigured: Bool { get }
    func fetchEmbyLibraries(completion: @escaping ([VideoEmbyLibrary]) -> Void)
    /// Genre names for the Genres chips.
    func fetchEmbyGenres(completion: @escaping ([String]) -> Void)
    /// Items in one library, or in one genre across libraries
    /// when `genre` is set (libraryId nil = all libraries).
    func fetchEmbyItems(
        libraryId: String?,
        genre: String?,
        page: Int,
        completion: @escaping (VideoItemPage) -> Void
    )
    /// Emby detail: streams as play lines. Movies get one line
    /// with one "正片" episode; series get one line per season
    /// group with one episode per item.
    func fetchEmbyDetail(item: VideoItem, completion: @escaping (VideoDetail?) -> Void)
    /// Emby library search.
    func searchEmby(keyword: String, completion: @escaping ([VideoItem]) -> Void)

    // MARK: - Download

    /// Queue one episode for download (B-leg DownloadEngine).
    /// True when the task was queued; false when the engine is
    /// not installed or the episode has no URL to fetch yet.
    func enqueueDownload(
        detail: VideoDetail,
        episode: PlayEpisode,
        line: PlayLine,
        completion: @escaping (Bool) -> Void
    )
}

/// Real gateway (S3 merge): the C-leg protocol mapped onto the
/// B-leg clients. No UI file changes — every view already talks
/// to `VideoDataGateway` only.
///
/// - CMS: CmsClient.shared (search / detail / home / by-type).
/// - Douban: a per-gateway DoubanService, merged into fetchDetail
///   (see the race note there). Douban is the SOLE metadata source.
/// - Emby: a fresh EmbyClient per call from the stored config
///   (EmbyConfigStore.load — Keychain credential, never logged);
///   nil client = not configured, every Emby call answers empty.
/// - Downloads: DownloadEngine.shared, video kind.
///
/// All completions fire on the main queue (the clients answer on
/// URLSession queues, so every callback is re-dispatched here).
final class RealVideoDataGateway: VideoDataGateway {
    private let cms = CmsClient.shared
    private let douban = DoubanService()
    private let downloads = DownloadEngine.shared

    /// One Emby client from the stored config, or nil when the
    /// server is not configured (S5 owns the config page; until
    /// then the Emby tab shows "not configured", never fake rows).
    private func embyClient() -> EmbyClient? {
        guard let config = EmbyConfigStore.load(), config.isConfigured else { return nil }
        return EmbyClient(config: config)
    }

    var embyConfigured: Bool { EmbyConfigStore.load()?.isConfigured == true }

    // MARK: - CMS home / browse / search / detail

    func fetchHome(completion: @escaping ([VideoHomeRow]) -> Void) {
        // Home rows + the daily row, in parallel; the daily row
        // goes first when it has items.
        var homeRows: [VideoHomeRow]?
        var dailyItems: [VideoItem]?
        func finish() {
            guard let home = homeRows, let daily = dailyItems else { return }
            var rows = home
            if !daily.isEmpty {
                rows.insert(VideoHomeRow(id: "daily", title: "每日推荐", items: daily), at: 0)
            }
            completion(rows)
        }
        cms.home { rows in
            DispatchQueue.main.async {
                homeRows = rows
                finish()
            }
        }
        cms.daily { items in
            DispatchQueue.main.async {
                dailyItems = items
                finish()
            }
        }
    }

    func fetchTypeNames(completion: @escaping ([String]) -> Void) {
        // Same priority order as CmsClient.home: kVideoTypePriority
        // first, then the rest alphabetically.
        cms.typeMap { map in
            var names = Array(map.keys)
            names.sort { a, b in
                let ia = kVideoTypePriority.firstIndex(of: a) ?? -1
                let ib = kVideoTypePriority.firstIndex(of: b) ?? -1
                if ia >= 0 && ib >= 0 { return ia < ib }
                if ia >= 0 { return true }
                if ib >= 0 { return false }
                return a < b
            }
            let sorted = names
            DispatchQueue.main.async { completion(sorted) }
        }
    }

    func fetchByType(_ type: String, page: Int, area: String, year: String, by: String, completion: @escaping (VideoItemPage) -> Void) {
        // The filtered byType overload (name:page:area:year:by:) —
        // NOT the old byType(typeName:page:) overload, which has
        // no filter parameters. Its `page` is 0-based like the
        // gateway's (see the note on byLeafType / byParentType).
        cms.byType(name: type, page: page, area: area, year: year, by: by) { result in
            DispatchQueue.main.async {
                guard let result = result else {
                    completion(.empty)
                    return
                }
                completion(VideoItemPage(
                    items: result.items,
                    hasMore: result.page < result.pagecount
                ))
            }
        }
    }

    func search(keyword: String, completion: @escaping ([VideoItem]) -> Void) {
        cms.search(query: keyword) { items, _ in
            DispatchQueue.main.async { completion(items) }
        }
    }

    /// CMS detail + Douban metadata, one completion. The two fetches
    /// run in parallel; Douban is slow by design (serial chain + 1 s
    /// gap, suggest + abstract + mobile + cast photos), so it gets
    /// 2.5 s after the CMS detail lands — a cache/builtin hit merges
    /// in, a slow miss falls back to the CMS meta (rating / cast /
    /// synopsis from vod_score / vod_actor / vod_content) instead of
    /// holding the episode grid hostage. The detail view tolerates
    /// exactly one completion, so there is no second call.
    func fetchDetail(item: VideoItem, completion: @escaping (VideoDetail?) -> Void) {
        guard let sourceId = item.sourceId else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var cmsDetail: VideoDetail?
        var doubanMeta: VideoMeta?
        var cmsDone = false
        var doubanDone = false
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            guard var detail = cmsDetail else {
                completion(nil)
                return
            }
            if let dMeta = doubanMeta {
                detail = VideoDetail(
                    item: detail.item,
                    lines: detail.lines,
                    meta: VideoMeta(
                        rating: dMeta.rating ?? detail.meta?.rating,
                        year: dMeta.year ?? detail.meta?.year,
                        cast: dMeta.cast.isEmpty ? (detail.meta?.cast ?? []) : dMeta.cast,
                        synopsis: dMeta.synopsis ?? detail.meta?.synopsis,
                        doubanId: dMeta.doubanId
                    )
                )
            }
            completion(detail)
        }
        func maybeFinish() {
            // Complete when CMS is in and Douban has answered or
            // timed out. All state lives on the main queue.
            guard cmsDone else { return }
            if doubanDone { finish() }
        }
        cms.detail(sourceId: sourceId, vodId: item.id) { detail in
            DispatchQueue.main.async {
                cmsDetail = detail
                cmsDone = true
                maybeFinish()
                // Douban cap: 2.5 s after the CMS detail lands.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    if !doubanDone {
                        doubanDone = true
                        maybeFinish()
                    }
                }
            }
        }
        douban.detail(title: item.title, year: item.year ?? "") { detail in
            DispatchQueue.main.async {
                doubanMeta = detail?.toVideoMeta()
                doubanDone = true
                maybeFinish()
            }
        }
    }

    // MARK: - Emby

    func fetchEmbyLibraries(completion: @escaping ([VideoEmbyLibrary]) -> Void) {
        guard let client = embyClient() else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        client.libraries { result in
            DispatchQueue.main.async {
                switch result {
                case .failure:
                    completion([])
                case .success(let libs):
                    completion(libs.map { VideoEmbyLibrary(id: $0.id, name: $0.name) })
                }
            }
        }
    }

    func fetchEmbyGenres(completion: @escaping ([String]) -> Void) {
        guard let client = embyClient() else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        client.genreNames { names in
            DispatchQueue.main.async { completion(names) }
        }
    }

    func fetchEmbyItems(
        libraryId: String?,
        genre: String?,
        page: Int,
        completion: @escaping (VideoItemPage) -> Void
    ) {
        guard let client = embyClient() else {
            DispatchQueue.main.async { completion(.empty) }
            return
        }
        let startIndex = page * 50
        if let genre = genre, !genre.isEmpty {
            client.byGenre(genre, startIndex: startIndex) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .failure:
                        completion(.empty)
                    case .success(let pageResult):
                        completion(VideoItemPage(
                            items: pageResult.items,
                            hasMore: startIndex + pageResult.items.count < pageResult.totalCount
                        ))
                    }
                }
            }
            return
        }
        // No genre: movies + series in parallel (a library holds
        // one kind, the other call returns empty; no library means
        // both kinds across all libraries).
        var moviesPage: EmbyItemsPage?
        var seriesPage: EmbyItemsPage?
        func finish() {
            guard let movies = moviesPage, let series = seriesPage else { return }
            let items = movies.items + series.items
            let total = movies.totalCount + series.totalCount
            completion(VideoItemPage(
                items: items,
                hasMore: startIndex + items.count < total
            ))
        }
        client.movies(libraryId: libraryId, startIndex: startIndex) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure: moviesPage = EmbyItemsPage(items: [], totalCount: 0)
                case .success(let pageResult): moviesPage = pageResult
                }
                finish()
            }
        }
        client.series(libraryId: libraryId, startIndex: startIndex) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure: seriesPage = EmbyItemsPage(items: [], totalCount: 0)
                case .success(let pageResult): seriesPage = pageResult
                }
                finish()
            }
        }
    }

    func fetchEmbyDetail(item: VideoItem, completion: @escaping (VideoDetail?) -> Void) {
        guard let client = embyClient() else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        client.detail(itemId: item.id) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure:
                    completion(nil)
                case .success(let detail):
                    completion(detail)
                }
            }
        }
    }

    func searchEmby(keyword: String, completion: @escaping ([VideoItem]) -> Void) {
        guard let client = embyClient() else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        client.search(query: keyword) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure:
                    completion([])
                case .success(let pageResult):
                    completion(pageResult.items)
                }
            }
        }
    }

    // MARK: - Download

    /// Queue one episode for download. The URL resolves the same
    /// way the player does (line fallback, no exclusions — a fresh
    /// download has tried nothing). False when the episode has no
    /// URL to fetch. An m3u8 URL is also refused: the engine
    /// downloads the single URL as-is, so an m3u8 would save only
    /// the playlist file (not the segments) while the page claimed
    /// "已加入下载" — a file that cannot play offline. A direct
    /// mp4/flv file downloads whole.
    func enqueueDownload(
        detail: VideoDetail,
        episode: PlayEpisode,
        line: PlayLine,
        completion: @escaping (Bool) -> Void
    ) {
        cms.resolvePlayURL(detail: detail, episode: episode, line: line, excluding: []) { url in
            guard let url = url, url.pathExtension.lowercased() != "m3u8" else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let key = VideoResumeKey.episodeId(title: detail.item.title, year: detail.item.year, episodeName: episode.name)
            let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
            let request = DownloadRequest(
                key: key,
                title: "\(detail.item.title) \(episode.name)",
                sourceURL: url,
                fileName: "\(detail.item.title)-\(episode.name).\(ext)",
                kind: .video,
                qualityCode: ""
            )
            self.downloads.enqueue(request: request)
            DispatchQueue.main.async { completion(true) }
        }
    }
}

/// The single place the app asks for a gateway. The real adapter
/// above; no view file names a concrete client.
enum VideoServices {
    static func makeGateway() -> VideoDataGateway {
        RealVideoDataGateway()
    }
}

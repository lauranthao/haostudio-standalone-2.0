// HAo Studio 2.0 — live data gateway adapter.
//
// The concrete LiveDataGateway the live tab / search talk to.
// Wires the five platform site clients (S4-B: room info +
// resolve + danmaku) to the gateway protocol (S4-C) by adding
// the list methods the B leg never ported — recommend, categories
// (name -> platform area id), category rooms, search — as
// `LiveListSite` methods on each site class. No sixth platform:
// only Bilibili / Douyu / Huya / Douyin / Kuaishou (chen
// 2026-11-16).
//
// Endpoints (ported from the Flutter site adapters in
// standalone-app-merge23, `lib/shared/platforms/<site>/`, which
// were probed live from the VM in Nov 2026 — no invented API):
// - Bilibili: ranked `room/v1/Area/getListByAreaID`
//   (sort=online, fallback `xlive/.../webMain/getMoreRecList`);
//   categories `room/v1/Area/getList`; category rooms WBI-signed
//   `xlive/.../second/getList` (+ w_webid scraped from
//   live.bilibili.com/lol); search `api.bilibili.com/
//   x/web-interface/search/type` (search_type 'live').
// - Douyu: categories `m.douyu.com/api/cate/list`; recommend
//   `japi/weblist/apinc/allpage/6/<page>`; category rooms
//   `gapi/rkc/directory/mixList/2_<cate2Id>/<page>`; search
//   `japi/search/api/searchShow`.
// - Huya: recommend + category rooms `cache.php` LiveList
//   (`getLiveListByPage`, gameId for categories); categories
//   `live.cdn.huya.com/liveconfig/game/bussLive` per top type
//   (网游 1 / 单机 2 / 娱乐 8 / 手游 3) with a verified-popular
//   fallback; search `search.cdn.huya.com/` (`getSearchContent`).
// - Douyin: recommend `live.douyin.com/webcast/feed/` (no server
//   paging — sliced client-side); categories from the homepage
//   `categoryData` blob (fallback: 游戏 1,1 / 英雄联盟 2,1);
//   category rooms `webcast/web/partition/detail/room/v2/`;
//   search three-stage (live API -> general API -> partition).
// - Kuaishou: recommend `live_api/home/list` (no server paging
//   — sliced client-side); categories `live_api/category/data`
//   per top type (1-8) with a verified-popular fallback;
//   category rooms gameboard / non-gameboard lists (split on id
//   length < 7); search `live_api/search/author` (anchors).
//
// Paging: the tab's page is 0-based; the sites take 1-based
// pages. `hasMore` is a full-page heuristic for server-paged
// lists (Bilibili 30, Douyin partition 15, Kuaishou board 20,
// Douyu/Huya list 20 — the last two endpoints take no page-size
// parameter, so 20 is the observed full-page size; a wrong guess
// costs one extra fetch or one truncated page, both surfaced
// honestly by the tab's retry state). Client-paged recommends
// (Douyin / Kuaishou feeds) slice a cached full fetch, so
// `hasMore` is exact there.
//
// All gateway completions fire on the main queue (protocol
// contract). All list failures arrive as empty results, never
// as throws out of a completion handler. The tab keeps its
// honest empty state for a genuinely empty / failed load.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

/// Build a GET URL from a base + ordered query pairs (values
/// percent-encoded once). Shared by the five site list methods.
enum LiveListURL {
    static func url(base: String, params: [(String, String)]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url
    }
}

/// What a platform site must offer beyond the resolver contract
/// (`roomInfo` / `resolve`) for the gateway to list rooms.
/// Pages are 1-based; `pageSize` is advisory where the endpoint
/// fixes its own page size.
protocol LiveListSite {
    func recommendRooms(page: Int, pageSize: Int, completion: @escaping ([LiveRoom]) -> Void)
    func listCategories(completion: @escaping ([(id: String, name: String)]) -> Void)
    func categoryRooms(areaId: String, page: Int, pageSize: Int, completion: @escaping ([LiveRoom]) -> Void)
    func searchRooms(query: String, page: Int, pageSize: Int, completion: @escaping ([LiveRoom]) -> Void)
    func roomInfo(roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void)
}

extension BilibiliLiveSite: LiveListSite {}
extension DouyuLiveSite: LiveListSite {}
extension HuyaLiveSite: LiveListSite {}
extension DouyinLiveSite: LiveListSite {}
extension KuaishouLiveSite: LiveListSite {}

/// The gateway the live tab uses. One shared instance (the site
/// clients keep warmed-up cookies / buvid / WBI keys, so they
/// must not be rebuilt per tab render). A custom fetcher can be
/// injected for tests; production uses the shared URLSession.
final class LiveDataGatewayAdapter: LiveDataGateway {
    static let shared = LiveDataGatewayAdapter()

    private let bilibili: BilibiliLiveSite
    private let douyu: DouyuLiveSite
    private let huya: HuyaLiveSite
    private let douyin: DouyinLiveSite
    private let kuaishou: KuaishouLiveSite

    /// Platform kernel id -> category name -> platform area id.
    /// Filled by fetchCategories; a recommend call inside a
    /// category fetches categories first when the map is cold.
    private var areaIds: [String: [String: String]] = [:]

    /// Platform kernel id -> full recommend feed (client-paged
    /// platforms only: Douyin / Kuaishou). Replaced on every
    /// page-0 fetch (pull-to-refresh / platform switch).
    private var recommendCache: [String: [LiveRoom]] = [:]

    init(fetcher: LiveDataFetcher? = nil) {
        self.bilibili = BilibiliLiveSite(fetcher: fetcher)
        self.douyu = DouyuLiveSite(fetcher: fetcher)
        self.huya = HuyaLiveSite(fetcher: fetcher)
        self.douyin = DouyinLiveSite(fetcher: fetcher)
        self.kuaishou = KuaishouLiveSite(fetcher: fetcher)
    }

    private func site(for platform: LivePlatform) -> LiveListSite {
        switch platform {
        case .bilibili: return bilibili
        case .douyu: return douyu
        case .huya: return huya
        case .douyin: return douyin
        case .kuaishou: return kuaishou
        }
    }

    func fetchRecommended(platform: String, area: String?, page: Int, completion: @escaping (LiveRoomPage) -> Void) {
        guard let platformValue = LivePlatform(rawValue: platform) else {
            DispatchQueue.main.async { completion(.empty) }
            return
        }
        let site = site(for: platformValue)
        let sitePage = max(0, page) + 1
        if let area = area {
            fetchCategoryRooms(site: site, platform: platformValue, areaName: area, page: sitePage, completion: completion)
            return
        }
        switch platformValue {
        case .douyin, .kuaishou:
            fetchClientPagedRecommend(site: site, platform: platformValue, page: sitePage, completion: completion)
        default:
            site.recommendRooms(page: sitePage, pageSize: 30) { rooms in
                let hasMore = LiveDataGatewayAdapter.pageHasMore(platform: platformValue, count: rooms.count)
                DispatchQueue.main.async {
                    completion(LiveRoomPage(rooms: LiveDataGatewayAdapter.deduplicated(rooms), hasMore: hasMore))
                }
            }
        }
    }

    func fetchCategories(platform: String, completion: @escaping ([String]) -> Void) {
        guard let platformValue = LivePlatform(rawValue: platform) else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        site(for: platformValue).listCategories { [weak self] areas in
            DispatchQueue.main.async {
                self?.rememberCategories(platform: platformValue, areas: areas)
                completion(areas.map { $0.name })
            }
        }
    }

    func searchRooms(query: String, platform: String, completion: @escaping ([LiveRoom]) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let platformValue = LivePlatform(rawValue: platform) else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        site(for: platformValue).searchRooms(query: trimmed, page: 1, pageSize: 30) { rooms in
            DispatchQueue.main.async { completion(LiveDataGatewayAdapter.deduplicated(rooms)) }
        }
    }

    func fetchRoomDetail(room: LiveRoom, completion: @escaping (LiveRoom?) -> Void) {
        site(for: room.platform).roomInfo(roomId: room.roomId) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let info):
                    completion(info)
                case .failure:
                    completion(nil)
                }
            }
        }
    }

    // MARK: - Categories (name -> area id)

    private func rememberCategories(platform: LivePlatform, areas: [(id: String, name: String)]) {
        var map = areaIds[platform.rawValue] ?? [:]
        for area in areas where map[area.name] == nil {
            map[area.name] = area.id
        }
        areaIds[platform.rawValue] = map
    }

    private func fetchCategoryRooms(site: LiveListSite, platform: LivePlatform, areaName: String, page: Int, completion: @escaping (LiveRoomPage) -> Void) {
        if let areaId = areaIds[platform.rawValue]?[areaName] {
            requestCategoryRooms(site: site, platform: platform, areaId: areaId, page: page, completion: completion)
            return
        }
        site.listCategories { [weak self] areas in
            DispatchQueue.main.async {
                guard let self = self else {
                    completion(.empty)
                    return
                }
                self.rememberCategories(platform: platform, areas: areas)
                guard let areaId = self.areaIds[platform.rawValue]?[areaName] else {
                    completion(.empty)
                    return
                }
                self.requestCategoryRooms(site: site, platform: platform, areaId: areaId, page: page, completion: completion)
            }
        }
    }

    private func requestCategoryRooms(site: LiveListSite, platform: LivePlatform, areaId: String, page: Int, completion: @escaping (LiveRoomPage) -> Void) {
        site.categoryRooms(areaId: areaId, page: page, pageSize: 30) { rooms in
            let hasMore = LiveDataGatewayAdapter.pageHasMore(platform: platform, count: rooms.count)
            DispatchQueue.main.async {
                completion(LiveRoomPage(rooms: LiveDataGatewayAdapter.deduplicated(rooms), hasMore: hasMore))
            }
        }
    }

    // MARK: - Client-paged recommends (Douyin / Kuaishou feeds)

    private func fetchClientPagedRecommend(site: LiveListSite, platform: LivePlatform, page: Int, completion: @escaping (LiveRoomPage) -> Void) {
        if page > 1, let cached = recommendCache[platform.rawValue] {
            let pageRooms = LiveDataGatewayAdapter.slice(cached, page: page, pageSize: 30)
            let end = (page - 1) * 30 + pageRooms.count
            let result = LiveRoomPage(rooms: pageRooms, hasMore: end < cached.count)
            DispatchQueue.main.async { completion(result) }
            return
        }
        site.recommendRooms(page: 1, pageSize: 100) { [weak self] rooms in
            DispatchQueue.main.async {
                guard let self = self else {
                    completion(.empty)
                    return
                }
                // Dedup before caching: every slice of this feed
                // hands rooms to a ForEach(id: roomId), so a repeat
                // anywhere in the feed would trap on any page.
                let unique = LiveDataGatewayAdapter.deduplicated(rooms)
                self.recommendCache[platform.rawValue] = unique
                let pageRooms = LiveDataGatewayAdapter.slice(unique, page: page, pageSize: 30)
                let end = (page - 1) * 30 + pageRooms.count
                completion(LiveRoomPage(rooms: pageRooms, hasMore: end < unique.count))
            }
        }
    }

    // MARK: - Pure paging helpers (fixture-testable, no network)

    /// Drop repeated rooms (same platform + room id, first wins):
    /// the tab grid and the search grid both render with
    /// `ForEach(id: roomId)`, and a repeated id in one page traps
    /// there. Server pages do repeat rooms (overlapping pages,
    /// hot-room duplication), so every list this gateway hands out
    /// goes through here first.
    static func deduplicated(_ rooms: [LiveRoom]) -> [LiveRoom] {
        var seen = Set<String>()
        return rooms.filter { seen.insert($0.platform.rawValue + "|" + $0.roomId).inserted }
    }

    /// Full-page heuristic for server-paged lists: a page that
    /// came back exactly full probably has a next page.
    /// Thresholds are the page sizes the site methods request.
    static func pageHasMore(platform: LivePlatform, count: Int) -> Bool {
        switch platform {
        case .bilibili: return count >= 30
        case .douyin: return count >= 15
        case .kuaishou: return count >= 20
        case .douyu, .huya: return count >= 20
        }
    }

    /// Client-side page slice of a fetched-full list. Page is
    /// 1-based; out-of-range pages are empty, never faked.
    static func slice(_ rooms: [LiveRoom], page: Int, pageSize: Int) -> [LiveRoom] {
        let start = (max(1, page) - 1) * pageSize
        guard start < rooms.count else { return [] }
        return Array(rooms[start..<min(start + pageSize, rooms.count)])
    }
}

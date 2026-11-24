// HAo Studio 2.0 — LiveDataGatewayAdapter tests (audit leg).
//
// PENDING FILE — do NOT drop into ios/Tests/ yet. The adapter
// (Features/Live/LiveDataGatewayAdapter.swift) and its protocol
// (Features/Live/LiveDataGateway.swift) are not in the AppCore
// SwiftPM target. The coordinator must first add both files to
// Package.swift's AppCore sources (same single-file precedent as
// Features/Live/LiveLibraryStore.swift):
//
//   "Features/Live/LiveDataGateway.swift",
//   "Features/Live/LiveDataGatewayAdapter.swift",
//
// then move this file to ios/Tests/LiveServicesTests/.
// Until then it would fail Codemagic's test step (unknown type).
//
// Coverage: gateway dispatch per platform (recommend / search /
// categories / room detail / category rooms via the area-name
// map), pure paging helpers, and the client-paged recommend
// cache (Douyin / Kuaishou fetch the full feed once, slice
// per page). No network: routing stub fetcher + inline fixtures.
// Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class LiveGatewayAdapterTests: XCTestCase {

    private var bilibiliRecommendJSON: String {
        """
        {"code":0,"data":{"recommend_room_list":[
        {"roomid":6,"title":"测试直播","cover":"//i0.hdslb.com/bfs/live/cover.jpg","uname":"主播A","face":"//i0.hdslb.com/bfs/face/1.jpg","online":"1234"},
        {"roomid":7,"title":"第二间","cover":"https://i0.hdslb.com/bfs/live/c2.jpg","uname":"主播B","face":"https://i0.hdslb.com/bfs/face/2.jpg","online":9999}
        ]}}
        """
    }

    private var bilibiliSearchJSON: String {
        """
        {"code":0,"data":{"result":{"live_room":[
        {"roomid":21,"title":"<em class=\\"keyword\\">测试</em>直播","cover":"//i0.hdslb.com/bfs/live/s.jpg","uname":"搜主播","uface":"//i0.hdslb.com/bfs/face/3.jpg","online":321,"live_status":1},
        {"roomid":22,"title":"下播了","cover":"","uname":"另一位","uface":"","online":0,"live_status":0}
        ]}}}
        """
    }

    /// Same room twice in one page (the server repeats hot rooms):
    /// the gateway must hand out one copy, never two — the grids
    /// render with ForEach(id: roomId) and a repeat traps there.
    private var bilibiliRecommendWithDuplicateJSON: String {
        """
        {"code":0,"data":{"recommend_room_list":[
        {"roomid":6,"title":"测试直播","cover":"//i0.hdslb.com/bfs/live/cover.jpg","uname":"主播A","face":"//i0.hdslb.com/bfs/face/1.jpg","online":"1234"},
        {"roomid":6,"title":"测试直播","cover":"//i0.hdslb.com/bfs/live/cover.jpg","uname":"主播A","face":"//i0.hdslb.com/bfs/face/1.jpg","online":"1234"},
        {"roomid":7,"title":"第二间","cover":"https://i0.hdslb.com/bfs/live/c2.jpg","uname":"主播B","face":"https://i0.hdslb.com/bfs/face/2.jpg","online":9999}
        ]}}
        """
    }

    private var bilibiliSearchWithDuplicateJSON: String {
        """
        {"code":0,"data":{"result":{"live_room":[
        {"roomid":21,"title":"<em class=\\"keyword\\">测试</em>直播","cover":"//i0.hdslb.com/bfs/live/s.jpg","uname":"搜主播","uface":"//i0.hdslb.com/bfs/face/3.jpg","online":321,"live_status":1},
        {"roomid":21,"title":"<em class=\\"keyword\\">测试</em>直播","cover":"//i0.hdslb.com/bfs/live/s.jpg","uname":"搜主播","uface":"//i0.hdslb.com/bfs/face/3.jpg","online":321,"live_status":1}
        ]}}}
        """
    }

    private var bilibiliCategoriesJSON: String {
        """
        {"code":0,"data":[
        {"id":1,"name":"网游","list":[{"id":2,"name":"英雄联盟","pic":"//i0.hdslb.com/bfs/pic.jpg"},{"id":3,"name":"CS2","pic":""}]},
        {"id":4,"name":"手游","list":[{"id":5,"name":"王者荣耀","pic":""}]}
        ]}
        """
    }

    private var bilibiliCategoryRoomsJSON: String {
        """
        {"code":0,"data":{"list":[
        {"roomid":11,"title":"分区房","cover":"//i0.hdslb.com/bfs/live/x.jpg","uname":"分区主播","face":"//i0.hdslb.com/bfs/face/9.jpg","online":55}
        ]}}
        """
    }

    private var roomInfoJSON: String {
        """
        {"code":0,"data":{"room_info":{"room_id":6,"title":"测试直播","live_status":1,"cover":"https://a/cover.jpg","online":1234},"anchor_info":{"base_info":{"uname":"主播","face":"https://a/face.jpg"}}}}
        """
    }

    private var navJSON: String {
        """
        {"code":0,"data":{"wbi_img":{"img_url":"https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9420b84077c.png","sub_url":"https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f011814e06a491.png"}}}
        """
    }

    private var douyuCategoriesJSON: String {
        """
        {"data":{"cate2Info":[
        {"cate2Id":1,"cate2Name":"英雄联盟","icon":"https://i.jpg"},
        {"cate2Id":2,"cate2Name":"户外","smallIcon":""}
        ]}}
        """
    }

    private var kuaishouRecommendJSON: String {
        """
        {"data":{"list":[{"gameLiveInfo":[{"liveInfo":[
        {"id":"ls1","poster":"https://p1.jpg","living":true,"watchingCount":888,"playUrls":{},"author":{"id":"u1","name":"快手主播","avatar":"https://a1.jpg","description":"快手房"},"gameInfo":{"poster":"https://g1.jpg"}},
        {"id":"ls2","poster":"","living":false,"watchingCount":0,"author":{"id":"u2","name":"回放","avatar":"","description":"回放房"},"gameInfo":{}}
        ]}]}]}}
        """
    }

    // MARK: - Recommend / search / categories / room detail

    func testAdapterRecommendBilibiliViaStub() {
        let adapter = LiveDataGatewayAdapter(fetcher: routingFetcher([("getListByAreaID", jsonData(bilibiliRecommendJSON), 200)]))
        let expectation = self.expectation(description: "adapter recommend")
        adapter.fetchRecommended(platform: "bili", area: nil, page: 0) { page in
            XCTAssertEqual(page.rooms.count, 2)
            XCTAssertEqual(page.rooms[0].roomId, "7")
            XCTAssertFalse(page.hasMore)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testAdapterSearchBilibiliViaStub() {
        let adapter = LiveDataGatewayAdapter(fetcher: routingFetcher([("search/type", jsonData(bilibiliSearchJSON), 200)]))
        let expectation = self.expectation(description: "adapter search")
        adapter.searchRooms(query: "测试", platform: "bili") { rooms in
            XCTAssertEqual(rooms.count, 2)
            XCTAssertEqual(rooms[0].title, "测试直播")
            XCTAssertTrue(rooms[0].isLive)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - Duplicate room ids never reach the grids

    func testAdapterRecommendDedupsRepeatedRooms() {
        let adapter = LiveDataGatewayAdapter(fetcher: routingFetcher([("getListByAreaID", jsonData(bilibiliRecommendWithDuplicateJSON), 200)]))
        let expectation = self.expectation(description: "adapter recommend dedup")
        adapter.fetchRecommended(platform: "bili", area: nil, page: 0) { page in
            XCTAssertEqual(page.rooms.count, 2)
            XCTAssertEqual(page.rooms[0].roomId, "7")
            XCTAssertEqual(page.rooms[1].roomId, "6")
            XCTAssertFalse(page.hasMore)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testAdapterSearchDedupsRepeatedRooms() {
        let adapter = LiveDataGatewayAdapter(fetcher: routingFetcher([("search/type", jsonData(bilibiliSearchWithDuplicateJSON), 200)]))
        let expectation = self.expectation(description: "adapter search dedup")
        adapter.searchRooms(query: "测试", platform: "bili") { rooms in
            XCTAssertEqual(rooms.count, 1)
            XCTAssertEqual(rooms[0].roomId, "21")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testDeduplicatedKeepsFirstAndOrder() {
        let rooms = [
            LiveRoom(roomId: "6", platform: .bilibili),
            LiveRoom(roomId: "6", platform: .douyu),
            LiveRoom(roomId: "6", platform: .bilibili),
            LiveRoom(roomId: "7", platform: .bilibili),
        ]
        let unique = LiveDataGatewayAdapter.deduplicated(rooms)
        XCTAssertEqual(unique.map { $0.platform.rawValue + "|" + $0.roomId }, ["bili|6", "douyu|6", "bili|7"])
    }

    func testAdapterCategoriesDouyuViaStub() {
        let adapter = LiveDataGatewayAdapter(fetcher: routingFetcher([("cate/list", jsonData(douyuCategoriesJSON), 200)]))
        let expectation = self.expectation(description: "adapter categories")
        adapter.fetchCategories(platform: "douyu") { names in
            XCTAssertEqual(names, ["英雄联盟", "户外"])
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testAdapterRoomDetailBilibiliViaStub() {
        let adapter = LiveDataGatewayAdapter(fetcher: routingFetcher([
            ("getInfoByRoom", jsonData(roomInfoJSON), 200),
            ("getDanmuInfo", jsonData("{\"code\":0,\"data\":{\"token\":\"tok\",\"host_list\":[]}}"), 200),
            ("nav", jsonData(navJSON), 200),
        ]))
        let expectation = self.expectation(description: "adapter room detail")
        adapter.fetchRoomDetail(room: LiveRoom(roomId: "6", platform: .bilibili)) { room in
            XCTAssertEqual(room?.title, "测试直播")
            XCTAssertEqual(room?.isLive, true)
            XCTAssertEqual(room?.streamer, "主播")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - Category rooms via the area-name map

    func testAdapterCategoryRoomsBilibiliViaStub() {
        let lolHTML = "<html><head><script>window.__access_id = \"abc123\";</script></head></html>"
        let adapter = LiveDataGatewayAdapter(fetcher: routingFetcher([
            ("second/getList", jsonData(bilibiliCategoryRoomsJSON), 200),
            ("Area/getList", jsonData(bilibiliCategoriesJSON), 200),
            ("live.bilibili.com/lol", lolHTML.data(using: .utf8), 200),
            ("nav", jsonData(navJSON), 200),
        ]))
        let expectation = self.expectation(description: "adapter category rooms")
        adapter.fetchRecommended(platform: "bili", area: "英雄联盟", page: 0) { page in
            XCTAssertEqual(page.rooms.count, 1)
            XCTAssertEqual(page.rooms[0].roomId, "11")
            XCTAssertEqual(page.rooms[0].title, "分区房")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - Pure paging helpers

    func testAdapterSliceAndHasMore() {
        let rooms = (1...65).map { LiveRoom(roomId: "\($0)", platform: .douyin) }
        XCTAssertEqual(LiveDataGatewayAdapter.slice(rooms, page: 1, pageSize: 30).count, 30)
        XCTAssertEqual(LiveDataGatewayAdapter.slice(rooms, page: 3, pageSize: 30).count, 5)
        XCTAssertEqual(LiveDataGatewayAdapter.slice(rooms, page: 4, pageSize: 30).count, 0)
        XCTAssertTrue(LiveDataGatewayAdapter.pageHasMore(platform: .bilibili, count: 30))
        XCTAssertFalse(LiveDataGatewayAdapter.pageHasMore(platform: .bilibili, count: 29))
        XCTAssertTrue(LiveDataGatewayAdapter.pageHasMore(platform: .douyin, count: 15))
        XCTAssertFalse(LiveDataGatewayAdapter.pageHasMore(platform: .douyin, count: 14))
        XCTAssertTrue(LiveDataGatewayAdapter.pageHasMore(platform: .kuaishou, count: 20))
        XCTAssertFalse(LiveDataGatewayAdapter.pageHasMore(platform: .douyu, count: 19))
        XCTAssertTrue(LiveDataGatewayAdapter.pageHasMore(platform: .huya, count: 20))
    }

    // MARK: - Client-paged recommend cache (Kuaishou feed)

    func testAdapterClientPagedRecommendFetchesFeedOnce() {
        var calls = 0
        let fixture = jsonData(kuaishouRecommendJSON)
        let fetcher: LiveDataFetcher = { request, completion in
            calls += 1
            if let url = request.url?.absoluteString, url.contains("home/list") {
                completion(fixture, 200, nil)
            } else {
                completion(nil, 404, nil)
            }
        }
        let adapter = LiveDataGatewayAdapter(fetcher: fetcher)
        let first = self.expectation(description: "adapter ks page 0")
        adapter.fetchRecommended(platform: "ks", area: nil, page: 0) { page in
            XCTAssertEqual(page.rooms.count, 2)
            XCTAssertFalse(page.hasMore)
            XCTAssertEqual(calls, 1)
            first.fulfill()
        }
        waitForExpectations(timeout: 5)
        let second = self.expectation(description: "adapter ks page 1")
        adapter.fetchRecommended(platform: "ks", area: nil, page: 1) { page in
            XCTAssertEqual(page.rooms.count, 0)
            XCTAssertFalse(page.hasMore)
            XCTAssertEqual(calls, 1)
            second.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - Unknown platform

    func testAdapterUnknownPlatformReturnsEmpty() {
        let adapter = LiveDataGatewayAdapter(fetcher: stubFetcher(data: jsonData("{}"), status: 200))
        let recommend = self.expectation(description: "adapter unknown recommend")
        adapter.fetchRecommended(platform: "nope", area: nil, page: 0) { page in
            XCTAssertEqual(page.rooms.count, 0)
            recommend.fulfill()
        }
        waitForExpectations(timeout: 5)
        let search = self.expectation(description: "adapter unknown search")
        adapter.searchRooms(query: "x", platform: "nope") { rooms in
            XCTAssertEqual(rooms.count, 0)
            search.fulfill()
        }
        waitForExpectations(timeout: 5)
    }
}

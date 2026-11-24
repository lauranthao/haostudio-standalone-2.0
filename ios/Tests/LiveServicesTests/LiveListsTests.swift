// HAo Studio 2.0 — live list tests (audit leg: gateway adapter).
//
// Parser + stub-fetcher coverage for the five platforms' list
// methods (recommend / categories / category rooms / search)
// that the LiveDataGatewayAdapter dispatches to. No network:
// every test runs on inline fixtures or a routing stub fetcher.
// The adapter itself (Features/Live) is not in AppCore, so its
// dispatch/paging is covered by the pending
// LiveGatewayAdapterTests (see the audit delivery notes);
// the pure paging slice shared by the client-paged feeds is
// covered here through DouyinLiveSite.slice.
//
// Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class LiveListsTests: XCTestCase {

    // MARK: - Bilibili

    private var bilibiliRecommendJSON: String {
        """
        {"code":0,"data":{"recommend_room_list":[
        {"roomid":6,"title":"测试直播","cover":"//i0.hdslb.com/bfs/live/cover.jpg","uname":"主播A","face":"//i0.hdslb.com/bfs/face/1.jpg","online":"1234"},
        {"roomid":7,"title":"第二间","cover":"https://i0.hdslb.com/bfs/live/c2.jpg","uname":"主播B","face":"https://i0.hdslb.com/bfs/face/2.jpg","online":9999}
        ]}}
        """
    }

    func testBilibiliRecommendParsesRankedListSortedByWatching() {
        guard let rooms = BilibiliLiveSite.parseRecommendRooms(jsonObject(bilibiliRecommendJSON)) else {
            XCTFail("expected rooms, got nil")
            return
        }
        XCTAssertEqual(rooms.count, 2)
        XCTAssertEqual(rooms[0].roomId, "7")
        XCTAssertEqual(rooms[0].onlineCount, 9999)
        XCTAssertEqual(rooms[1].roomId, "6")
        XCTAssertEqual(rooms[1].cover, "https://i0.hdslb.com/bfs/live/cover.jpg@400w.jpg")
        XCTAssertEqual(rooms[1].avatar, "https://i0.hdslb.com/bfs/face/1.jpg")
        XCTAssertTrue(rooms[0].isLive)
        XCTAssertEqual(rooms[0].link, "https://live.bilibili.com/7")
    }

    func testBilibiliRecommendRejectsNonZeroCode() {
        XCTAssertNil(BilibiliLiveSite.parseRecommendRooms(jsonObject("{\"code\":-404,\"message\":\"啥都没有\"}")))
        XCTAssertNil(BilibiliLiveSite.parseRecommendRooms(nil))
    }

    func testBilibiliCategoriesFlattenWithParentIds() {
        let json = jsonObject("""
        {"code":0,"data":[
        {"id":1,"name":"网游","list":[{"id":2,"name":"英雄联盟","pic":"//i0.hdslb.com/bfs/pic.jpg"},{"id":3,"name":"CS2","pic":""}]},
        {"id":4,"name":"手游","list":[{"id":5,"name":"王者荣耀","pic":""}]}
        ]}
        """)
        guard let areas = BilibiliLiveSite.parseCategories(json) else {
            XCTFail("expected areas, got nil")
            return
        }
        XCTAssertEqual(areas.map { $0.id }, ["2", "3", "5"])
        XCTAssertEqual(areas.map { $0.name }, ["英雄联盟", "CS2", "王者荣耀"])
        XCTAssertEqual(areas.map { $0.parentId }, ["1", "1", "4"])
    }

    func testBilibiliCategoryRoomsParse() {
        let json = jsonObject("""
        {"code":0,"data":{"list":[
        {"roomid":11,"title":"分区房","cover":"//i0.hdslb.com/bfs/live/x.jpg","uname":"分区主播","face":"//i0.hdslb.com/bfs/face/9.jpg","online":55}
        ]}}
        """)
        guard let rooms = BilibiliLiveSite.parseCategoryRooms(json) else {
            XCTFail("expected rooms, got nil")
            return
        }
        XCTAssertEqual(rooms.count, 1)
        XCTAssertEqual(rooms[0].roomId, "11")
        XCTAssertEqual(rooms[0].onlineCount, 55)
        XCTAssertEqual(rooms[0].cover, "https://i0.hdslb.com/bfs/live/x.jpg@400w.jpg")
    }

    func testBilibiliSearchStripsEmTagsAndMapsLiveStatus() {
        let json = jsonObject("""
        {"code":0,"data":{"result":{"live_room":[
        {"roomid":21,"title":"<em class=\\"keyword\\">测试</em>直播","cover":"//i0.hdslb.com/bfs/live/s.jpg","uname":"搜主播","uface":"//i0.hdslb.com/bfs/face/3.jpg","online":321,"live_status":1},
        {"roomid":22,"title":"下播了","cover":"","uname":"另一位","uface":"","online":0,"live_status":0}
        ]}}}
        """)
        guard let rooms = BilibiliLiveSite.parseSearchRooms(json) else {
            XCTFail("expected rooms, got nil")
            return
        }
        XCTAssertEqual(rooms.count, 2)
        XCTAssertEqual(rooms[0].title, "测试直播")
        XCTAssertTrue(rooms[0].isLive)
        XCTAssertEqual(rooms[0].cover, "https://i0.hdslb.com/bfs/live/s.jpg@400w.jpg")
        XCTAssertFalse(rooms[1].isLive)
    }

    func testBilibiliRecommendEndToEndViaStub() {
        let fetcher = routingFetcher([("getListByAreaID", jsonData(bilibiliRecommendJSON), 200)])
        let site = BilibiliLiveSite(fetcher: fetcher)
        let expectation = self.expectation(description: "bilibili recommend")
        site.recommendRooms(page: 1, pageSize: 30) { rooms in
            XCTAssertEqual(rooms.count, 2)
            XCTAssertEqual(rooms[0].roomId, "7")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - Douyu

    private var douyuRoomListJSON: String {
        """
        {"data":{"rl":[
        {"type":1,"rid":100,"rs16":"https://r1.jpg","ol":500,"rn":"斗鱼房","nn":"斗鱼主播","av":"abc123"},
        {"type":2,"rid":101,"rs16":"https://r2.jpg","ol":999,"rn":"不是房间","nn":"x","av":""},
        {"type":1,"rid":102,"rs16":"","ol":0,"rn":"无封面","nn":"y","av":""}
        ]}}
        """
    }

    func testDouyuRoomListKeepsOnlyLiveRooms() {
        guard let rooms = DouyuLiveSite.parseRoomList(jsonObject(douyuRoomListJSON)) else {
            XCTFail("expected rooms, got nil")
            return
        }
        XCTAssertEqual(rooms.count, 2)
        XCTAssertEqual(rooms[0].roomId, "100")
        XCTAssertEqual(rooms[0].avatar, "https://apic.douyucdn.cn/upload/abc123_middle.jpg")
        XCTAssertEqual(rooms[0].link, "https://www.douyu.com/100")
        XCTAssertEqual(rooms[1].avatar, "")
        XCTAssertTrue(rooms[0].isLive)
    }

    func testDouyuCategoriesParseCate2() {
        let json = jsonObject("""
        {"data":{"cate2Info":[
        {"cate2Id":1,"cate2Name":"英雄联盟","icon":"https://i.jpg"},
        {"cate2Id":2,"cate2Name":"户外","smallIcon":""}
        ]}}
        """)
        guard let areas = DouyuLiveSite.parseCategories(json) else {
            XCTFail("expected areas, got nil")
            return
        }
        XCTAssertEqual(areas.map { $0.id }, ["1", "2"])
        XCTAssertEqual(areas.map { $0.name }, ["英雄联盟", "户外"])
    }

    func testDouyuSearchParsesRelateShow() {
        let json = jsonObject("""
        {"error":0,"data":{"relateShow":[
        {"rid":200,"roomName":"搜索房","roomSrc":"https://c.jpg","nickName":"搜到","avatar":"https://a.jpg","hot":777,"isLive":1,"roomType":0},
        {"rid":201,"roomName":"未开播","roomSrc":"","nickName":"z","avatar":"","hot":0,"isLive":0,"roomType":0}
        ]}}
        """)
        guard let rooms = DouyuLiveSite.parseSearchRooms(json) else {
            XCTFail("expected rooms, got nil")
            return
        }
        XCTAssertEqual(rooms.count, 2)
        XCTAssertTrue(rooms[0].isLive)
        XCTAssertEqual(rooms[0].onlineCount, 777)
        XCTAssertFalse(rooms[1].isLive)
    }

    func testDouyuSearchRejectsNonZeroError() {
        XCTAssertNil(DouyuLiveSite.parseSearchRooms(jsonObject("{\"error\":1,\"msg\":\"bad\"}")))
    }

    func testDouyuRecommendEndToEndViaStub() {
        let fetcher = routingFetcher([("allpage", jsonData(douyuRoomListJSON), 200)])
        let site = DouyuLiveSite(fetcher: fetcher)
        let expectation = self.expectation(description: "douyu recommend")
        site.recommendRooms(page: 1, pageSize: 30) { rooms in
            XCTAssertEqual(rooms.count, 2)
            XCTAssertEqual(rooms[0].roomId, "100")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - Huya

    private var huyaCacheJSON: String {
        """
        {"data":{"datas":[
        {"profileRoom":300,"screenshot":"https://huyaimg/a.jpg","introduction":"虎牙房","roomName":"备用名","nick":"虎牙主播","avatar180":"https://av.jpg","totalCount":"12345"},
        {"profileRoom":301,"screenshot":"https://huyaimg/b.jpg?x=1","introduction":"","roomName":"备用标题","nick":"n2","avatar180":"","totalCount":100}
        ]}}
        """
    }

    func testHuyaCacheListParsesAndSizesCover() {
        guard let rooms = HuyaLiveSite.parseCacheList(jsonObject(huyaCacheJSON)) else {
            XCTFail("expected rooms, got nil")
            return
        }
        XCTAssertEqual(rooms.count, 2)
        XCTAssertEqual(rooms[0].cover, "https://huyaimg/a.jpg?x-oss-process=style/w338_h190&")
        XCTAssertEqual(rooms[0].onlineCount, 12345)
        XCTAssertEqual(rooms[1].cover, "https://huyaimg/b.jpg?x=1")
        XCTAssertEqual(rooms[1].title, "备用标题")
    }

    func testHuyaSearchParsesDocs3() {
        let json = jsonObject("""
        {"response":{"3":{"docs":[
        {"room_id":400,"game_screenshot":"https://s.jpg","game_introduction":"搜索房","game_roomName":"","game_nick":"搜主播","game_imgUrl":"https://g.jpg","game_total_count":"55"}
        ]}}}
        """)
        guard let rooms = HuyaLiveSite.parseSearchRooms(json) else {
            XCTFail("expected rooms, got nil")
            return
        }
        XCTAssertEqual(rooms.count, 1)
        XCTAssertEqual(rooms[0].roomId, "400")
        XCTAssertEqual(rooms[0].onlineCount, 55)
        XCTAssertEqual(rooms[0].cover, "https://s.jpg?x-oss-process=style/w338_h190&")
    }

    func testHuyaCategoriesParseAllGidShapes() {
        let json = jsonObject("""
        {"data":[
        {"gid":1,"gameFullName":"英雄联盟"},
        {"gid":2.0,"gameFullName":"双"},
        {"gid":{"value":"3,4"},"gameFullName":"图"},
        {"gid":"5","gameFullName":"串"}
        ]}
        """)
        guard let areas = HuyaLiveSite.parseCategories(json) else {
            XCTFail("expected areas, got nil")
            return
        }
        XCTAssertEqual(areas.map { $0.id }, ["1", "2", "3", "5"])
        XCTAssertEqual(areas.map { $0.name }, ["英雄联盟", "双", "图", "串"])
    }

    func testHuyaFallbackCategoriesAreRealIds() {
        let areas = HuyaLiveSite.fallbackCategories
        XCTAssertFalse(areas.isEmpty)
        for area in areas {
            XCTAssertFalse(area.id.isEmpty)
            XCTAssertFalse(area.name.isEmpty)
            XCTAssertNotNil(Int(area.id))
        }
    }

    func testHuyaRecommendEndToEndViaStub() {
        let fetcher = routingFetcher([("cache.php", jsonData(huyaCacheJSON), 200)])
        let site = HuyaLiveSite(fetcher: fetcher)
        let expectation = self.expectation(description: "huya recommend")
        site.recommendRooms(page: 1, pageSize: 30) { rooms in
            XCTAssertEqual(rooms.count, 2)
            XCTAssertEqual(rooms[0].roomId, "300")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - Douyin

    func testDouyinRecommendParsesLegacyFeed() {
        let json = jsonObject("""
        {"status_code":0,"data":{"data":[
        {"room":{"id_str":"111","title":"抖音房","owner":{"nickname":"抖主播","web_rid":"aaa","avatar_thumb":{"url_list":["https://av1.jpg"]}},"cover":{"url_list":["https://cv1.jpg"]},"status":2,"stream_url":{}},"web_rid":"aaa"}
        ]}}
        """)
        guard let rooms = DouyinLiveSite.parseRecommendRooms(json) else {
            XCTFail("expected rooms, got nil")
            return
        }
        XCTAssertEqual(rooms.count, 1)
        XCTAssertEqual(rooms[0].roomId, "aaa")
        XCTAssertEqual(rooms[0].title, "抖音房")
        XCTAssertEqual(rooms[0].streamer, "抖主播")
        XCTAssertEqual(rooms[0].cover, "https://cv1.jpg")
        XCTAssertEqual(rooms[0].avatar, "https://av1.jpg")
    }

    func testDouyinRecommendParsesNewEnvelopeShape() {
        let json = jsonObject("""
        {"status_code":0,"data":[
        {"data":"{\\"room\\":{\\"id_str\\":\\"222\\",\\"title\\":\\"新形态\\",\\"owner\\":{\\"nickname\\":\\"新主播\\",\\"web_rid\\":\\"bbb\\"},\\"cover\\":{\\"url_list\\":[\\"https://cv2.jpg\\"]},\\"status\\":2}}","web_rid":"bbb"}
        ]}
        """)
        guard let rooms = DouyinLiveSite.parseRecommendRooms(json) else {
            XCTFail("expected rooms, got nil")
            return
        }
        XCTAssertEqual(rooms.count, 1)
        XCTAssertEqual(rooms[0].roomId, "bbb")
        XCTAssertEqual(rooms[0].title, "新形态")
    }

    func testDouyinCategoriesParseHomepageBlob() {
        let html = "<html><body>{\"pathname\":\"/\",\"categoryData\":[{\"partition\":{\"id_str\":\"1\",\"type\":1,\"title\":\"游戏\"},\"sub_partition\":[{\"partition\":{\"id_str\":\"2\",\"type\":1,\"title\":\"英雄联盟\"}}]}]}</body></html>"
        let areas = DouyinLiveSite.parseCategories(html)
        XCTAssertEqual(areas.map { $0.id }, ["1,1", "2,1"])
        XCTAssertEqual(areas.map { $0.name }, ["游戏", "英雄联盟"])
    }

    func testDouyinSearchVideosParseRawData() {
        let payload = jsonArray("""
        [{"lives":{"rawdata":"{\\"room\\":{\\"id_str\\":\\"333\\",\\"title\\":\\"搜索房\\",\\"owner\\":{\\"nickname\\":\\"搜主播\\",\\"web_rid\\":\\"ccc\\"},\\"status\\":2},\\"owner\\":{\\"nickname\\":\\"搜主播\\",\\"web_rid\\":\\"ccc\\"}}"}}]
        """)
        let rooms = DouyinLiveSite.parseSearchVideos(payload)
        XCTAssertEqual(rooms.count, 1)
        XCTAssertEqual(rooms[0].roomId, "ccc")
        XCTAssertEqual(rooms[0].title, "搜索房")
        XCTAssertEqual(rooms[0].streamer, "搜主播")
    }

    func testDouyinPartitionRoomListParses() {
        let payload = jsonArray("""
        [{"room":{"id_str":"444","title":"分区房","owner":{"nickname":"分区主播","web_rid":"ddd","avatar_thumb":{"url_list":["https://av4.jpg"]}},"cover":{"url_list":["https://cv4.jpg"]}},"web_rid":"ddd"}]
        """)
        let rooms = DouyinLiveSite.parsePartitionRoomList(payload)
        XCTAssertEqual(rooms.count, 1)
        XCTAssertEqual(rooms[0].roomId, "ddd")
        XCTAssertEqual(rooms[0].title, "分区房")
        XCTAssertEqual(rooms[0].cover, "https://cv4.jpg")
    }

    func testDouyinSlicePagesClientSide() {
        let rooms = (1...65).map { LiveRoom(roomId: "\($0)", platform: .douyin) }
        XCTAssertEqual(DouyinLiveSite.slice(rooms, page: 1, pageSize: 30).count, 30)
        XCTAssertEqual(DouyinLiveSite.slice(rooms, page: 2, pageSize: 30).first?.roomId, "31")
        XCTAssertEqual(DouyinLiveSite.slice(rooms, page: 3, pageSize: 30).count, 5)
        XCTAssertEqual(DouyinLiveSite.slice(rooms, page: 4, pageSize: 30).count, 0)
    }

    // MARK: - Kuaishou

    private var kuaishouRecommendJSON: String {
        """
        {"data":{"list":[{"gameLiveInfo":[{"liveInfo":[
        {"id":"ls1","poster":"https://p1.jpg","living":true,"watchingCount":888,"playUrls":{},"author":{"id":"u1","name":"快手主播","avatar":"https://a1.jpg","description":"快手房\\n第二行"},"gameInfo":{"poster":"https://g1.jpg"}},
        {"id":"ls2","poster":"","living":false,"watchingCount":0,"author":{"id":"u2","name":"回放","avatar":"","description":"回放房"},"gameInfo":{}}
        ]}]}]}}
        """
    }

    func testKuaishouRecommendParsesNestedFeed() {
        guard let rooms = KuaishouLiveSite.parseRecommendRooms(jsonObject(kuaishouRecommendJSON)) else {
            XCTFail("expected rooms, got nil")
            return
        }
        XCTAssertEqual(rooms.count, 2)
        XCTAssertEqual(rooms[0].roomId, "u1")
        XCTAssertEqual(rooms[0].title, "快手房 第二行")
        XCTAssertEqual(rooms[0].onlineCount, 888)
        XCTAssertTrue(rooms[0].isLive)
        XCTAssertEqual(rooms[0].danmakuData?["liveStreamId"] as? String, "ls1")
        XCTAssertFalse(rooms[1].isLive)
    }

    func testKuaishouCategoryRoomsParseFlatItems() {
        let json = jsonObject("""
        {"data":{"list":[
        {"id":"ls9","caption":"分区标题","poster":"https://p9.jpg","living":true,"watchingCount":11,"author":{"id":"u9","name":"分区主播","avatar":"https://a9.jpg","description":"描述"},"gameInfo":{"poster":""}}
        ]}}
        """)
        guard let rooms = KuaishouLiveSite.parseCategoryRooms(json) else {
            XCTFail("expected rooms, got nil")
            return
        }
        XCTAssertEqual(rooms.count, 1)
        XCTAssertEqual(rooms[0].roomId, "u9")
        XCTAssertEqual(rooms[0].title, "分区标题")
    }

    func testKuaishouAuthorSearchParsesAnchors() {
        let json = jsonObject("""
        {"data":{"list":[
        {"id":" au1 ","name":"搜到主播","avatar":"https://aa.jpg","living":true,"bannedStatus":{"banned":false}},
        {"id":"au2","name":"被封","avatar":"","living":true,"bannedStatus":{"banned":true}},
        {"id":"au3","name":"未开播","avatar":"","living":false}
        ]}}
        """)
        guard let rooms = KuaishouLiveSite.parseAuthorSearch(json) else {
            XCTFail("expected rooms, got nil")
            return
        }
        XCTAssertEqual(rooms.count, 3)
        XCTAssertEqual(rooms[0].roomId, "au1")
        XCTAssertTrue(rooms[0].isLive)
        XCTAssertFalse(rooms[1].isLive)
        XCTAssertFalse(rooms[2].isLive)
        XCTAssertEqual(rooms[0].onlineCount, 0)
    }

    func testKuaishouCategoriesParse() {
        let json = jsonObject("""
        {"data":{"list":[
        {"id":1001,"name":"王者荣耀","poster":""},
        {"id":"22008","name":"和平精英","poster":"https://p.jpg"}
        ]}}
        """)
        guard let areas = KuaishouLiveSite.parseCategories(json) else {
            XCTFail("expected areas, got nil")
            return
        }
        XCTAssertEqual(areas.map { $0.id }, ["1001", "22008"])
        XCTAssertEqual(areas.map { $0.name }, ["王者荣耀", "和平精英"])
    }

    func testKuaishouRecommendFirstPageViaStub() {
        let fetcher = routingFetcher([("home/list", jsonData(kuaishouRecommendJSON), 200)])
        let site = KuaishouLiveSite(fetcher: fetcher)
        let expectation = self.expectation(description: "kuaishou page 1")
        site.recommendRooms(page: 1, pageSize: 1) { rooms in
            XCTAssertEqual(rooms.count, 1)
            XCTAssertEqual(rooms[0].roomId, "u1")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testKuaishouRecommendSecondPageViaStub() {
        let fetcher = routingFetcher([("home/list", jsonData(kuaishouRecommendJSON), 200)])
        let site = KuaishouLiveSite(fetcher: fetcher)
        let expectation = self.expectation(description: "kuaishou page 2")
        site.recommendRooms(page: 2, pageSize: 1) { rooms in
            XCTAssertEqual(rooms.count, 1)
            XCTAssertEqual(rooms[0].roomId, "u2")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testKuaishouCategoriesEndToEndViaStub() {
        let fixture = """
        {"data":{"list":[
        {"id":1001,"name":"王者荣耀","poster":""},
        {"id":"22008","name":"和平精英","poster":""}
        ]}}
        """
        let fetcher = routingFetcher([("category/data", jsonData(fixture), 200)])
        let site = KuaishouLiveSite(fetcher: fetcher)
        let expectation = self.expectation(description: "kuaishou categories")
        site.listCategories { areas in
            XCTAssertEqual(areas.count, 16)
            XCTAssertEqual(areas[0].id, "1001")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }
}

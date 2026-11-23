// HAo Studio 2.0 — Huya WUP client tests (S4 leg B).
//
// Token-lease math (ms/s/seconds disambiguation) and the super-chat
// board mapping, plus one stubbed WUP fetch. No network.
// Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class HuyaWupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1700000000)

    private func tokenResponse(token: String, expire: Int) -> GetCdnTokenExResp {
        var response = GetCdnTokenExResp()
        response.sFlvToken = token
        response.iExpireTime = expire
        return response
    }

    // MARK: - Lease from response

    func testLeaseFromWsTimePlusFiveMinutes() throws {
        let lease = try HuyaCdnTokenLease.from(
            response: tokenResponse(token: "wsSecret=x&wsTime=6553f5a0", expire: 0),
            now: now
        )
        XCTAssertEqual(lease.invalidAt, Date(timeIntervalSince1970: 1700001184 + 300))
        XCTAssertEqual(lease.refreshAt, Date(timeIntervalSince1970: 1700001184 + 300 - 30))
        XCTAssertTrue(lease.needsRefresh(Date(timeIntervalSince1970: 1700001184 + 271)))
        XCTAssertFalse(lease.needsRefresh(Date(timeIntervalSince1970: 1700001184 + 269)))
        XCTAssertTrue(lease.isExpired(Date(timeIntervalSince1970: 1700001184 + 300)))
    }

    func testLeaseServerExpiryInSecondsCapsInvalidAt() throws {
        // iExpireTime as plain seconds (server expiry sooner than wsTime+300).
        let lease = try HuyaCdnTokenLease.from(
            response: tokenResponse(token: "wsSecret=x&wsTime=6553f5a0", expire: 1700001200),
            now: now
        )
        XCTAssertEqual(lease.invalidAt, Date(timeIntervalSince1970: 1700001200))
        XCTAssertEqual(lease.refreshAt, Date(timeIntervalSince1970: 1700001200 - 30))
    }

    func testLeaseServerExpiryInMilliseconds() throws {
        let lease = try HuyaCdnTokenLease.from(
            response: tokenResponse(token: "wsSecret=x&wsTime=6553f5a0", expire: 1700001200000),
            now: now
        )
        XCTAssertEqual(lease.invalidAt, Date(timeIntervalSince1970: 1700001200))
    }

    func testLeaseServerExpiryAsDurationSeconds() throws {
        // Small iExpireTime (<= 1e9) is a duration from now.
        let lease = try HuyaCdnTokenLease.from(
            response: tokenResponse(token: "wsSecret=x&wsTime=6553f5a0", expire: 120),
            now: now
        )
        XCTAssertEqual(lease.invalidAt, Date(timeIntervalSince1970: 1700000000 + 120))
    }

    func testLeaseThrowsOnEmptyTokenOrMissingWsTime() {
        XCTAssertThrowsError(try HuyaCdnTokenLease.from(response: tokenResponse(token: "", expire: 0), now: now))
        XCTAssertThrowsError(try HuyaCdnTokenLease.from(response: tokenResponse(token: "wsSecret=x", expire: 0), now: now))
    }

    // MARK: - Super-chat panel mapping

    private func panelItem(
        content: String, cost: Int = 0, costPay: Int = 0,
        totalSec: Int = 60, countDown: Int = 30, messageId: Int = 1,
        nick: String = "老板", avatar: String = "https://a/b.jpg"
    ) -> GameEventMessageBoardInfo {
        var user = HuyaMessageUser()
        user.sNick = nick
        user.sAvatar = avatar
        var item = GameEventMessageBoardInfo()
        item.tMessageUser = user
        item.sContent = content
        item.iCost = cost
        item.iCostPay = costPay
        item.iTotalSec = totalSec
        item.iCountDown = countDown
        item.lMessageId = messageId
        return item
    }

    func testSuperChatsFromPanelSkipsEmptyAndExpired() {
        var panel = GameEventMessageBoardPanel()
        panel.vGameEventMessageBoardInfo = [
            panelItem(content: "  ", messageId: 1),
            panelItem(content: "过期了", totalSec: 0, countDown: 0, messageId: 2),
            panelItem(content: "有效", cost: 50, messageId: 3)
        ]
        let messages = HuyaWupClient.superChatsFromPanel(panel, now: now)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].message, "有效")
        XCTAssertEqual(messages[0].price, 50)
        XCTAssertEqual(messages[0].messageId, "huya:3")
        XCTAssertEqual(messages[0].userName, "老板")
        XCTAssertEqual(messages[0].endTime, now.addingTimeInterval(30))
        XCTAssertEqual(messages[0].startTime, now.addingTimeInterval(30 - 60))
    }

    func testSuperChatPriceFallsBackToCostPayOver100MinOne() {
        var panel = GameEventMessageBoardPanel()
        panel.vGameEventMessageBoardInfo = [
            panelItem(content: "一元", cost: 0, costPay: 100, messageId: 1),
            panelItem(content: "零头", cost: 0, costPay: 49, messageId: 2),
            panelItem(content: "四舍五入", cost: 0, costPay: 250, messageId: 3)
        ]
        let messages = HuyaWupClient.superChatsFromPanel(panel, now: now)
        XCTAssertEqual(messages.map { $0.price }, [1, 1, 3])
    }

    func testSuperChatUsesTotalSecWhenCountDownIsZero() {
        var panel = GameEventMessageBoardPanel()
        panel.vGameEventMessageBoardInfo = [
            panelItem(content: "无倒计时", totalSec: 45, countDown: 0, messageId: 1)
        ]
        let messages = HuyaWupClient.superChatsFromPanel(panel, now: now)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].endTime, now.addingTimeInterval(45))
    }

    // MARK: - Stubbed fetch

    func testFetchNativeCdnTokenDecodesStubbedPacket() throws {
        let packet = TarsUniPacket()
        packet.servantName = "liveui"
        packet.funcName = "getCdnTokenInfoEx"
        try packet.putStruct("tRsp", tokenResponse(token: "wsSecret=x&wsTime=6553f5a0", expire: 0))
        try packet.putInt("", 0)
        let data = try packet.encode()
        let client = HuyaWupClient(fetcher: stubFetcher(data: data, status: 200))
        let line = HuyaLine(
            baseUrl: "https://al.huya.com/", lineType: .flv,
            flvAntiCode: "", hlsAntiCode: "", streamName: "stream-1",
            cdnType: "AL", presenterUid: 1, bitRate: 0
        )
        let expectation = self.expectation(description: "token")
        client.fetchNativeCdnToken(line: line) { result in
            if case .success(let lease) = result {
                XCTAssertEqual(lease.antiCode, "wsSecret=x&wsTime=6553f5a0")
                XCTAssertEqual(lease.invalidAt, Date(timeIntervalSince1970: 1700001184 + 300))
            } else {
                XCTFail("expected success, got \(result)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }
}

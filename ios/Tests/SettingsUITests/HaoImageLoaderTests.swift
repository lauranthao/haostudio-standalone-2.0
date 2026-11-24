// HAo Studio 2.0 — shared image loader tests (build 36, item 10, leg 6).
//
// iOS-only (see SettingsStoreTests.swift header): unwired in
// `ios/Package.swift`, runs under the S7 Xcode test target.
// No network: the URLSession is built on the stub URLProtocol
// from ImageLoaderTests.swift (same target) that answers from
// canned statuses / data and counts requests, so the dedup and
// cache behaviour is observable. The loader is constructed fresh
// per test, so each test starts with an empty memory cache.
//
// What is NOT tested here (needs the device, see the leg report):
// real downsampled pixel dimensions on a @3x screen, disk-cache
// persistence across launches, and scroll / frame-rate effects.

import Foundation
import UIKit
import XCTest

@testable import HAoStudio

final class HaoImageLoaderTests: XCTestCase {
    private var session: URLSession!
    private var loader: HaoImageLoader!
    private let coverURL = "https://cdn.example.com/covers/song-1.jpg"

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubImageURLProtocol.self]
        session = URLSession(configuration: config)
        loader = HaoImageLoader()
        StubImageURLProtocol.requestCount = 0
        StubImageURLProtocol.lastRequest = nil
        StubImageURLProtocol.handler = nil
    }

    override func tearDown() {
        session.invalidateAndCancel()
        StubImageURLProtocol.handler = nil
        super.tearDown()
    }

    private func load(
        urlString: String? = nil,
        width: Double = 56,
        height: Double = 56,
        file: StaticString = #file,
        line: UInt = #line
    ) -> UIImage?? {
        var result: UIImage??
        let expectation = self.expectation(description: "image load completes")
        loader.load(
            urlString: urlString ?? coverURL,
            targetWidthPoints: width, targetHeightPoints: height,
            session: session
        ) { image in
            result = image
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
        return result
    }

    /// B3: three concurrent loads of the same URL (row 56pt,
    /// player cover 340pt, Now Playing 600pt — the old three
    /// independent requests) download exactly once, and all
    /// three complete with an image.
    func testConcurrentLoadsSameURLDownloadOnce() {
        let data = SettingsTestImages.pngData()
        // Hold the first response back briefly so all three
        // loads join while it is in flight.
        StubImageURLProtocol.handler = { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return (200, data)
        }
        var results: [UIImage?] = []
        let done = expectation(description: "all three loads complete")
        done.expectedFulfillmentCount = 3
        loader.load(urlString: coverURL, targetWidthPoints: 56, targetHeightPoints: 56, session: session) { image in
            results.append(image)
            done.fulfill()
        }
        loader.load(urlString: coverURL, targetWidthPoints: 340, targetHeightPoints: 340, session: session) { image in
            results.append(image)
            done.fulfill()
        }
        loader.load(urlString: coverURL, targetWidthPoints: 600, targetHeightPoints: 600, session: session) { image in
            results.append(image)
            done.fulfill()
        }
        waitForExpectations(timeout: 5)
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0 != nil })
        XCTAssertEqual(StubImageURLProtocol.requestCount, 1)
    }

    /// B3: a second load of the same URL at the same size is
    /// served from the memory cache — no second request.
    func testSecondLoadHitsMemoryCache() {
        StubImageURLProtocol.handler = { _ in (200, SettingsTestImages.pngData()) }
        let first = load()
        XCTAssertNotNil(first ?? nil)
        XCTAssertEqual(StubImageURLProtocol.requestCount, 1)
        let second = load()
        XCTAssertNotNil(second ?? nil)
        XCTAssertEqual(StubImageURLProtocol.requestCount, 1)
    }

    /// Different URLs are different downloads.
    func testDifferentURLsDownloadSeparately() {
        StubImageURLProtocol.handler = { _ in (200, SettingsTestImages.pngData()) }
        let first = load(urlString: coverURL)
        let second = load(urlString: "https://cdn.example.com/covers/song-2.jpg")
        XCTAssertNotNil(first ?? nil)
        XCTAssertNotNil(second ?? nil)
        XCTAssertEqual(StubImageURLProtocol.requestCount, 2)
    }

    /// A failure completes with nil, is not cached, and does not
    /// leave a waiter hanging: both loads hit the network.
    func testFailureReturnsNilAndDoesNotPoisonCache() {
        StubImageURLProtocol.handler = { _ in (404, nil) }
        XCTAssertNil(load() ?? nil)
        XCTAssertNil(load() ?? nil)
        XCTAssertEqual(StubImageURLProtocol.requestCount, 2)
    }

    /// http is upgraded to https before the request goes out
    /// (ATS blocks plain http; the player background never
    /// upgraded before this leg).
    func testHttpURLUpgradedToHttps() {
        StubImageURLProtocol.handler = { _ in (200, SettingsTestImages.pngData()) }
        let image = load(urlString: "http://cdn.example.com/covers/song-1.jpg")
        XCTAssertNotNil(image ?? nil)
        XCTAssertEqual(StubImageURLProtocol.lastRequest?.url?.scheme, "https")
    }

    /// The policy numbers the loader and the Emby loader run on.
    func testPolicyNumbers() {
        // 56pt row cover at @3x decodes 168px, not the original.
        XCTAssertEqual(HaoImagePolicy.targetPixels(points: 56, scale: 3), 168)
        // 110pt poster at @3x.
        XCTAssertEqual(HaoImagePolicy.targetPixels(points: 110, scale: 3), 330)
        // Decoded RGBA8 bytes.
        XCTAssertEqual(HaoImagePolicy.decodedBytes(widthPixels: 400, heightPixels: 600), 960_000)
        // Emby budget: 50MB holds ~52 full-size 400x600 posters;
        // the old count-only cap theoretically allowed ~190MB.
        XCTAssertEqual(HaoImagePolicy.embyMemoryCacheTotalCostLimit, 50 * 1024 * 1024)
        XCTAssertEqual(
            HaoImagePolicy.embyMemoryCacheTotalCostLimit
                / HaoImagePolicy.decodedBytes(widthPixels: 400, heightPixels: 600),
            54
        )
        // URL normalisation.
        XCTAssertEqual(
            HaoImagePolicy.normalizedURLString("  http://cdn.example.com/a.jpg "),
            "https://cdn.example.com/a.jpg"
        )
        XCTAssertNil(HaoImagePolicy.normalizedURLString(""))
        XCTAssertNil(HaoImagePolicy.normalizedURLString("ftp://cdn.example.com/a.jpg"))
    }
}

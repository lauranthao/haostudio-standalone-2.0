// HAo Studio 2.0 — update checker tests (S6, C leg).
//
// All fixture, no network: a scripted fetcher answers in call order,
// a controllable clock drives the 15 s total cap and the 20 h
// throttle without waiting, and a mock system version pretends to
// be older devices for the minOs checks. Tests drive the B-leg seam
// (checkForUpdate returning UpdateCheckResult) on
// DefaultUpdateChecker.

import Foundation
import XCTest

@testable import AppCore

// MARK: - Mocks

/// One scripted fetch task. Records whether the deadline guard
/// cancelled it.
final class MockFetchTask: UpdateCancellable {
    var cancelled = false

    func cancel() {
        cancelled = true
    }
}

/// Scripted fetcher: answers each call with the next scripted reply,
/// in order, and hands back a fresh task per call. A hang reply
/// never calls back, which is how the total cap test proves the
/// checker gives up on its own and cancels the in-flight task.
final class MockUpdateFetcher: UpdateFetching {
    enum Scripted {
        case respond(data: Data, status: Int)
        case fail(Error)
        case hang
    }

    var scripted: [Scripted] = []
    var requests: [(url: URL, timeout: TimeInterval)] = []
    var tasks: [MockFetchTask] = []

    func fetch(url: URL, timeout: TimeInterval, completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) -> UpdateCancellable {
        requests.append((url: url, timeout: timeout))
        let task = MockFetchTask()
        tasks.append(task)
        guard !scripted.isEmpty else {
            return task
        }
        switch scripted.removeFirst() {
        case .respond(let data, let status):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            completion(data, response, nil)
        case .fail(let error):
            completion(nil, nil, error)
        case .hang:
            break
        }
        return task
    }
}

/// Controllable clock: now only moves when the test advances it, and
/// scheduled work only fires when its time comes.
final class MockUpdateClock: UpdateClock {
    var nowDate: Date
    private var scheduled: [(fireDate: Date, work: () -> Void)] = []

    init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.nowDate = now
    }

    func now() -> Date {
        nowDate
    }

    func scheduleAfter(_ delay: TimeInterval, work: @escaping () -> Void) {
        scheduled.append((fireDate: nowDate.addingTimeInterval(delay), work: work))
    }

    func advance(by interval: TimeInterval) {
        nowDate = nowDate.addingTimeInterval(interval)
        let due = scheduled.filter { $0.fireDate <= nowDate }
        scheduled.removeAll { $0.fireDate <= nowDate }
        for item in due {
            item.work()
        }
    }
}

final class MockSystemInfo: UpdateSystemInfo {
    var version = "17.2"

    var operatingSystemVersionString: String {
        version
    }
}

// MARK: - Tests

final class UpdateCheckerTests: XCTestCase {
    private var fetcher: MockUpdateFetcher!
    private var clock: MockUpdateClock!
    private var systemInfo: MockSystemInfo!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        fetcher = MockUpdateFetcher()
        clock = MockUpdateClock()
        systemInfo = MockSystemInfo()
        suiteName = "com.haostudio.update.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        if let suiteName = suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeChecker(currentVersion: String = "1.1.6", currentBuild: Int = 31) -> DefaultUpdateChecker {
        DefaultUpdateChecker(
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            fetcher: fetcher,
            clock: clock,
            systemInfo: systemInfo,
            defaults: defaults
        )
    }

    private func manifestData(
        version: String = "1.1.6",
        build: Int = 32,
        minOs: String? = "17.0",
        ipaUrl: String = "https://chen-hao-shop-production.up.railway.app/HAoStudio-1.1.6.ipa",
        size: Int? = 23174093,
        changelog: Any? = ["zh": "中文说明", "tw": "中文說明", "en": "English notes"]
    ) -> Data {
        var root: [String: Any] = [
            "version": version,
            "build": build,
            "ipaUrl": ipaUrl,
        ]
        if let minOs = minOs {
            root["minOs"] = minOs
        }
        if let size = size {
            root["size"] = size
        }
        if let changelog = changelog {
            root["changelog"] = changelog
        }
        return try! JSONSerialization.data(withJSONObject: root, options: [])
    }

    private func manifest(version: String = "1.1.6", build: Int = 32, minOs: String? = "17.0") -> UpdateManifest {
        let object = try! JSONSerialization.jsonObject(with: manifestData(version: version, build: build, minOs: minOs), options: [])
        return UpdateManifestParser.parse(object)!
    }

    private func nowMs() -> Int64 {
        Int64(clock.nowDate.timeIntervalSince1970 * 1000)
    }

    private func checkForUpdate(_ checker: DefaultUpdateChecker) -> UpdateCheckResult {
        let expectation = self.expectation(description: "check for update")
        var result: UpdateCheckResult?
        checker.checkForUpdate { found in
            XCTAssertTrue(Thread.isMainThread, "checkForUpdate completion must arrive on the main thread")
            result = found
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
        return result!
    }

    private func checkAuto(_ checker: DefaultUpdateChecker) -> UpdateCheckResult? {
        let expectation = self.expectation(description: "auto check")
        var result: UpdateCheckResult?
        var finished = false
        checker.checkAuto { found in
            XCTAssertTrue(Thread.isMainThread, "checkAuto completion must arrive on the main thread")
            result = found
            finished = true
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
        XCTAssertTrue(finished)
        return result
    }

    private func assertNewer(_ result: UpdateCheckResult, version: String, build: Int, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(result.latestVersion, version, file: file, line: line)
        XCTAssertEqual(result.latestBuild, build, file: file, line: line)
        XCTAssertFalse(result.requiresNewerOS, file: file, line: line)
        XCTAssertFalse(result.isSkipped, file: file, line: line)
        XCTAssertNil(result.failureMessage, file: file, line: line)
        XCTAssertEqual(result.id, "\(version)-\(build)", file: file, line: line)
    }

    private func assertFailed(_ result: UpdateCheckResult, file: StaticString = #file, line: UInt = #line) {
        XCTAssertNil(result.latestVersion, file: file, line: line)
        XCTAssertNil(result.latestBuild, file: file, line: line)
        XCTAssertNil(result.downloadURL, file: file, line: line)
        XCTAssertNotNil(result.failureMessage, file: file, line: line)
        XCTAssertFalse(result.requiresNewerOS, file: file, line: line)
        XCTAssertFalse(result.isSkipped, file: file, line: line)
    }

    private func assertUpToDate(_ result: UpdateCheckResult, file: StaticString = #file, line: UInt = #line) {
        XCTAssertNil(result.latestVersion, file: file, line: line)
        XCTAssertNil(result.failureMessage, file: file, line: line)
        XCTAssertFalse(result.requiresNewerOS, file: file, line: line)
        XCTAssertFalse(result.isSkipped, file: file, line: line)
    }

    // MARK: - Primary, retry, fallback

    func testPrimarySuccessReturnsNewerManifest() {
        fetcher.scripted = [.respond(data: manifestData(), status: 200)]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertNewer(result, version: "1.1.6", build: 32)
        XCTAssertEqual(fetcher.requests.count, 1)
        XCTAssertEqual(fetcher.requests[0].url, DefaultUpdateChecker.primaryManifestURL)
        XCTAssertEqual(fetcher.requests[0].timeout, 15, accuracy: 0.001)
        XCTAssertNil(checker.lastFetchError)
        XCTAssertEqual(result.minOs, "17.0")
        XCTAssertEqual(result.downloadURL?.absoluteString, "https://chen-hao-shop-production.up.railway.app/HAoStudio-1.1.6.ipa")
        XCTAssertNotNil(result.releaseNotes)
        XCTAssertTrue(["中文说明", "中文說明", "English notes"].contains(result.releaseNotes!))
        XCTAssertNotNil(checker.lastCheckDate)
        if let lastCheck = checker.lastCheckDate {
            XCTAssertEqual(lastCheck.timeIntervalSince1970, clock.nowDate.timeIntervalSince1970, accuracy: 0.001)
        }
    }

    func testPrimaryFailsOnceThenRetrySucceeds() {
        fetcher.scripted = [
            .fail(URLError(.notConnectedToInternet)),
            .respond(data: manifestData(), status: 200),
        ]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertNewer(result, version: "1.1.6", build: 32)
        XCTAssertEqual(fetcher.requests.count, 2)
        XCTAssertTrue(fetcher.requests.allSatisfy { $0.url == DefaultUpdateChecker.primaryManifestURL })
        XCTAssertNil(checker.lastFetchError)
    }

    func testPrimaryFailsTwiceThenFallbackSucceeds() {
        fetcher.scripted = [
            .fail(URLError(.notConnectedToInternet)),
            .fail(URLError(.cannotFindHost)),
            .respond(data: manifestData(), status: 200),
        ]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertNewer(result, version: "1.1.6", build: 32)
        XCTAssertEqual(fetcher.requests.count, 3)
        XCTAssertEqual(fetcher.requests[0].url, DefaultUpdateChecker.primaryManifestURL)
        XCTAssertEqual(fetcher.requests[1].url, DefaultUpdateChecker.primaryManifestURL)
        XCTAssertEqual(fetcher.requests[2].url, DefaultUpdateChecker.fallbackManifestURL)
    }

    func testFallbackAlsoFailsReportsPrimaryError() {
        fetcher.scripted = [
            .fail(URLError(.notConnectedToInternet)),
            .fail(URLError(.notConnectedToInternet)),
            .respond(data: Data(), status: 502),
        ]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertFailed(result)
        XCTAssertEqual(checker.lastFetchError, .network)
        XCTAssertNil(checker.lastHttpStatus)
        XCTAssertEqual(fetcher.requests.count, 3)
        XCTAssertNil(checker.lastCheckDate, "a failed fetch writes no last-check date")
    }

    func testHttp500RetriesPrimary() {
        fetcher.scripted = [
            .respond(data: Data(), status: 500),
            .respond(data: manifestData(), status: 200),
        ]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertNewer(result, version: "1.1.6", build: 32)
        XCTAssertEqual(fetcher.requests.count, 2)
        XCTAssertTrue(fetcher.requests.allSatisfy { $0.url == DefaultUpdateChecker.primaryManifestURL })
    }

    func testHttp404GoesToFallbackWithoutRetry() {
        fetcher.scripted = [
            .respond(data: Data(), status: 404),
            .respond(data: manifestData(), status: 200),
        ]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertNewer(result, version: "1.1.6", build: 32)
        XCTAssertEqual(fetcher.requests.count, 2)
        XCTAssertEqual(fetcher.requests[0].url, DefaultUpdateChecker.primaryManifestURL)
        XCTAssertEqual(fetcher.requests[1].url, DefaultUpdateChecker.fallbackManifestURL)
    }

    func testParseErrorTriesFallbackOnceThenReportsParse() {
        let empty = try! JSONSerialization.data(withJSONObject: [:], options: [])
        fetcher.scripted = [
            .respond(data: empty, status: 200),
            .respond(data: empty, status: 200),
        ]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertFailed(result)
        XCTAssertEqual(checker.lastFetchError, .parse)
        XCTAssertEqual(result.failureMessage, "更新信息解析失败，请稍后再试")
        XCTAssertEqual(fetcher.requests.count, 2)
    }

    // MARK: - 15 s total cap

    func testTotalTimeoutIsFifteenSecondsAndCancelsTask() {
        fetcher.scripted = [.hang]
        let checker = makeChecker()
        let expectation = self.expectation(description: "check for update")
        var result: UpdateCheckResult?
        checker.checkForUpdate { found in
            result = found
            expectation.fulfill()
        }
        clock.advance(by: 14)
        XCTAssertNil(result, "no result before the 15 s cap")
        XCTAssertFalse(fetcher.tasks[0].cancelled, "no cancel before the 15 s cap")
        clock.advance(by: 1)
        waitForExpectations(timeout: 5)
        assertFailed(result!)
        XCTAssertEqual(result!.failureMessage, "检查超时，请稍后再试")
        XCTAssertEqual(checker.lastFetchError, .timeout)
        XCTAssertEqual(fetcher.requests.count, 1, "a hung primary must not be retried after the cap")
        XCTAssertTrue(fetcher.tasks[0].cancelled, "the deadline guard cancels the in-flight task")
    }

    // MARK: - Version and build comparison

    func testNewerMajorVersion() {
        fetcher.scripted = [.respond(data: manifestData(version: "2.0.0", build: 1), status: 200)]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertNewer(result, version: "2.0.0", build: 1)
    }

    func testSameVersionHigherBuildIsNewer() {
        fetcher.scripted = [.respond(data: manifestData(version: "1.1.6", build: 32), status: 200)]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertNewer(result, version: "1.1.6", build: 32)
    }

    func testSameVersionSameBuildIsUpToDate() {
        fetcher.scripted = [.respond(data: manifestData(version: "1.1.6", build: 31), status: 200)]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertUpToDate(result)
    }

    func testLowerVersionIsUpToDate() {
        fetcher.scripted = [.respond(data: manifestData(version: "1.1.5", build: 99), status: 200)]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertUpToDate(result)
    }

    func testLowerBuildOfSameVersionIsUpToDate() {
        fetcher.scripted = [.respond(data: manifestData(version: "1.1.6", build: 30), status: 200)]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertUpToDate(result)
    }

    // MARK: - Skip list

    func testSkipAndUnskip() {
        let checker = makeChecker()
        XCTAssertFalse(checker.isSkipped(manifest(version: "1.1.6", build: 32)))
        XCTAssertNil(checker.skippedVersionLabel)
        checker.skip(version: "1.1.6", build: 32)
        XCTAssertTrue(checker.isSkipped(manifest(version: "1.1.6", build: 32)))
        XCTAssertEqual(checker.skippedVersionLabel, "1.1.6 (build 32)")
        XCTAssertEqual(defaults.string(forKey: DefaultUpdateChecker.skippedVersionKey), "1.1.6+32")

        fetcher.scripted = [.respond(data: manifestData(), status: 200)]
        let skippedResult = checkForUpdate(checker)
        XCTAssertEqual(skippedResult.latestVersion, "1.1.6")
        XCTAssertEqual(skippedResult.latestBuild, 32)
        XCTAssertTrue(skippedResult.isSkipped)
        XCTAssertNil(skippedResult.failureMessage)

        checker.clearSkippedVersion()
        XCTAssertFalse(checker.isSkipped(manifest(version: "1.1.6", build: 32)))
        XCTAssertNil(checker.skippedVersionLabel)

        fetcher.scripted = [.respond(data: manifestData(), status: 200)]
        let clearedResult = checkForUpdate(checker)
        assertNewer(clearedResult, version: "1.1.6", build: 32)
    }

    func testSkipDoesNotSkipNextBuild() {
        let checker = makeChecker()
        checker.skip(version: "1.1.6", build: 32)
        fetcher.scripted = [.respond(data: manifestData(version: "1.1.6", build: 33), status: 200)]
        let result = checkForUpdate(checker)
        assertNewer(result, version: "1.1.6", build: 33)
    }

    // MARK: - 20 h throttle

    func testAutoCheckThrottledWithinTwentyHours() {
        defaults.set(nowMs() - 3600 * 1000, forKey: DefaultUpdateChecker.lastUpdateCheckAtKey)
        fetcher.scripted = [.respond(data: manifestData(), status: 200)]
        let checker = makeChecker()
        let result = checkAuto(checker)
        XCTAssertNil(result)
        XCTAssertEqual(fetcher.requests.count, 0, "throttled auto check must not send a request")
    }

    func testAutoCheckRunsAfterTwentyHours() {
        defaults.set(nowMs() - 21 * 3600 * 1000, forKey: DefaultUpdateChecker.lastUpdateCheckAtKey)
        fetcher.scripted = [.respond(data: manifestData(), status: 200)]
        let checker = makeChecker()
        let result = checkAuto(checker)
        XCTAssertEqual(result?.latestVersion, "1.1.6")
        XCTAssertEqual(result?.latestBuild, 32)
        XCTAssertEqual(fetcher.requests.count, 1)
    }

    func testAutoCheckWritesStampOnlyOnSuccess() {
        let checker = makeChecker()
        XCTAssertNil(defaults.object(forKey: DefaultUpdateChecker.lastUpdateCheckAtKey))

        fetcher.scripted = [
            .fail(URLError(.notConnectedToInternet)),
            .fail(URLError(.notConnectedToInternet)),
            .fail(URLError(.notConnectedToInternet)),
        ]
        let failedResult = checkAuto(checker)
        XCTAssertNil(failedResult)
        XCTAssertNil(defaults.object(forKey: DefaultUpdateChecker.lastUpdateCheckAtKey), "a failed fetch must not consume the 20 h window")
        XCTAssertEqual(fetcher.requests.count, 3, "primary, retry, fallback")

        fetcher.scripted = [.respond(data: manifestData(), status: 200)]
        let okResult = checkAuto(checker)
        XCTAssertEqual(okResult?.latestVersion, "1.1.6")
        XCTAssertEqual(okResult?.latestBuild, 32)
        XCTAssertEqual((defaults.object(forKey: DefaultUpdateChecker.lastUpdateCheckAtKey) as? NSNumber)?.int64Value, nowMs())
        XCTAssertEqual(fetcher.requests.count, 4)
    }

    func testAutoCheckWritesStampEvenWhenUpToDate() {
        fetcher.scripted = [.respond(data: manifestData(version: "1.1.6", build: 31), status: 200)]
        let checker = makeChecker()
        let result = checkAuto(checker)
        XCTAssertNil(result, "up to date stays silent")
        XCTAssertEqual((defaults.object(forKey: DefaultUpdateChecker.lastUpdateCheckAtKey) as? NSNumber)?.int64Value, nowMs())
    }

    func testManualCheckIgnoresThrottle() {
        defaults.set(nowMs(), forKey: DefaultUpdateChecker.lastUpdateCheckAtKey)
        fetcher.scripted = [.respond(data: manifestData(), status: 200)]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertNewer(result, version: "1.1.6", build: 32)
        XCTAssertEqual(fetcher.requests.count, 1)
    }

    func testManualCheckDoesNotMoveAutoWindow() {
        fetcher.scripted = [.respond(data: manifestData(), status: 200)]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertNewer(result, version: "1.1.6", build: 32)
        XCTAssertNotNil(checker.lastCheckDate, "a manual success still records the last-check date")
        XCTAssertNil(defaults.object(forKey: DefaultUpdateChecker.lastUpdateCheckAtKey), "a manual check never writes the auto throttle stamp")
    }

    func testAutoCheckDoesNotNagSkipped() {
        let checker = makeChecker()
        checker.skip(version: "1.1.6", build: 32)
        fetcher.scripted = [.respond(data: manifestData(), status: 200)]
        let result = checkAuto(checker)
        XCTAssertNil(result, "a skipped release stays silent on auto check")
        XCTAssertNotNil(defaults.object(forKey: DefaultUpdateChecker.lastUpdateCheckAtKey), "the fetch still succeeded, so the stamp is written")
    }

    func testAutoCheckDisabledSwitch() {
        defaults.set(false, forKey: DefaultUpdateChecker.autoUpdateCheckKey)
        fetcher.scripted = [.respond(data: manifestData(), status: 200)]
        let checker = makeChecker()
        let expectation = self.expectation(description: "auto check")
        var result: UpdateCheckResult?
        var finished = false
        checker.checkAutoIfEnabled { found in
            result = found
            finished = true
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
        XCTAssertTrue(finished)
        XCTAssertNil(result)
        XCTAssertEqual(fetcher.requests.count, 0, "switch off means no request at all")
        XCTAssertNil(defaults.object(forKey: DefaultUpdateChecker.lastUpdateCheckAtKey))
    }

    func testAutoCheckEnabledSwitchDefaultsOn() {
        fetcher.scripted = [.respond(data: manifestData(), status: 200)]
        let checker = makeChecker()
        let expectation = self.expectation(description: "auto check")
        var result: UpdateCheckResult?
        checker.checkAutoIfEnabled { found in
            result = found
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
        XCTAssertEqual(result?.latestVersion, "1.1.6")
        XCTAssertEqual(result?.latestBuild, 32)
        XCTAssertEqual(fetcher.requests.count, 1)
    }

    // MARK: - minOs

    func testMinOsHigherThanDeviceRequiresHigherOS() {
        systemInfo.version = "17.2"
        fetcher.scripted = [.respond(data: manifestData(version: "2.0.0", build: 1, minOs: "18.0"), status: 200)]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        XCTAssertEqual(result.latestVersion, "2.0.0")
        XCTAssertEqual(result.latestBuild, 1)
        XCTAssertTrue(result.requiresNewerOS)
        XCTAssertFalse(result.isSkipped)
        XCTAssertNil(result.failureMessage)
    }

    func testMinOsEqualToDeviceIsFine() {
        systemInfo.version = "17.2"
        fetcher.scripted = [.respond(data: manifestData(version: "2.0.0", build: 1, minOs: "17.2"), status: 200)]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertNewer(result, version: "2.0.0", build: 1)
    }

    func testMinOsLowerThanDeviceIsFine() {
        systemInfo.version = "17.2"
        fetcher.scripted = [.respond(data: manifestData(minOs: "15.0"), status: 200)]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertNewer(result, version: "1.1.6", build: 32)
    }

    func testAutoCheckWithHigherMinOsStaysSilent() {
        systemInfo.version = "17.2"
        fetcher.scripted = [.respond(data: manifestData(version: "2.0.0", build: 1, minOs: "18.0"), status: 200)]
        let checker = makeChecker()
        let result = checkAuto(checker)
        XCTAssertNil(result, "a release the device cannot install must not nag on auto check")
        XCTAssertNotNil(defaults.object(forKey: DefaultUpdateChecker.lastUpdateCheckAtKey), "the fetch still succeeded, so the stamp is written")
    }

    // MARK: - Manifest parsing

    func testChangelogPlainStringForm() {
        fetcher.scripted = [.respond(data: manifestData(changelog: "Some notes"), status: 200)]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertNewer(result, version: "1.1.6", build: 32)
        XCTAssertEqual(result.releaseNotes, "Some notes")
    }

    func testManifestWithoutMinOsParses() {
        fetcher.scripted = [.respond(data: manifestData(minOs: nil), status: 200)]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertNewer(result, version: "1.1.6", build: 32)
        XCTAssertNil(result.minOs)
    }

    func testManifestRejectsNonHttpDownloadURL() {
        // An update button that opens a non-http(s) URL (or a
        // relative one) is never offered: the manifest is refused
        // and the fallback runs instead.
        fetcher.scripted = [
            .respond(data: manifestData(ipaUrl: "ftp://example.invalid/app.ipa"), status: 200),
            .respond(data: manifestData(), status: 200),
        ]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertNewer(result, version: "1.1.6", build: 32)
        XCTAssertEqual(fetcher.requests.count, 2, "the bad-URL manifest must fall through to the fallback")
    }

    func testManifestBooleanBuildIsParseError() {
        // `build: true` is a boolean, not build 1: the manifest
        // must fail parsing (and the fallback runs), not offer a
        // phantom build-1 release.
        let root: [String: Any] = [
            "version": "9.9.9",
            "build": true,
            "ipaUrl": "https://example.invalid/app.ipa",
        ]
        let badData = try! JSONSerialization.data(withJSONObject: root, options: [])
        fetcher.scripted = [
            .respond(data: badData, status: 200),
            .respond(data: manifestData(), status: 200),
        ]
        let checker = makeChecker()
        let result = checkForUpdate(checker)
        assertNewer(result, version: "1.1.6", build: 32)
        XCTAssertEqual(fetcher.requests.count, 2)
    }

    func testChangelogLocalization() {
        let object = try! JSONSerialization.jsonObject(with: manifestData(), options: [])
        let parsed = UpdateManifestParser.parse(object)!
        XCTAssertEqual(parsed.changelog?.localized(for: "zh-Hans"), "中文说明")
        XCTAssertEqual(parsed.changelog?.localized(for: "zh"), "中文说明")
        XCTAssertEqual(parsed.changelog?.localized(for: "zh-Hant"), "中文說明")
        XCTAssertEqual(parsed.changelog?.localized(for: "en"), "English notes")
        XCTAssertEqual(parsed.changelog?.localized(for: nil), "中文说明")
    }
}

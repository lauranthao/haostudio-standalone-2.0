// HAo Studio 2.0 — resolver policy tests (S2-B).
//
// Covers the P0-16 budget table, the cooldown rules (3 failures ->
// 5 min, timeout -> 2 min immediately, empty is not a failure,
// success clears the streak), the speed EMA, and the 1 h /
// 200-entry play-URL cache. No network, no real waiting: the
// cooldown/cache clocks are injected.

import Foundation
import XCTest

@testable import AppCore

final class LXResolverPolicyTests: XCTestCase {
    private var docs: URL!

    override func setUp() {
        super.setUp()
        docs = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-policy-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let docs = docs {
            try? FileManager.default.removeItem(at: docs)
        }
        super.tearDown()
    }

    // MARK: - Budget table (P0-16)

    func testBudgetCaps() {
        XCTAssertEqual(ResolverBudget.total, 8)
        XCTAssertEqual(ResolverBudget.firstPassCap, 5)
        XCTAssertEqual(ResolverBudget.laterPassCap, 2)
        XCTAssertEqual(ResolverBudget.perJob, 3)
        // First tier pass never eats the whole budget: 3 s stay
        // reserved for lower tiers.
        XCTAssertEqual(ResolverBudget.passBudget(passIndex: 0, remaining: 8), 5)
        XCTAssertEqual(ResolverBudget.passBudget(passIndex: 1, remaining: 8), 2)
        XCTAssertEqual(ResolverBudget.passBudget(passIndex: 2, remaining: 8), 2)
        // Bounded by the time actually left.
        XCTAssertEqual(ResolverBudget.passBudget(passIndex: 0, remaining: 1), 1)
        XCTAssertEqual(ResolverBudget.passBudget(passIndex: 1, remaining: 0.5), 0.5)
    }

    // MARK: - Cooldown

    private func makeCooldown(now: Date) -> (ResolverCooldown, FakeClock) {
        let clock = FakeClock(now: now)
        let cooldown = ResolverCooldown(documentsDirectory: docs)
        cooldown.now = { clock.now }
        return (cooldown, clock)
    }

    func testThreeErrorsCoolForFiveMinutes() {
        let (cooldown, clock) = makeCooldown(now: Date())
        XCTAssertFalse(cooldown.isCoolingDown("tang"))
        cooldown.record("tang", outcome: .error, milliseconds: 100)
        cooldown.record("tang", outcome: .error, milliseconds: 100)
        XCTAssertFalse(cooldown.isCoolingDown("tang"))
        cooldown.record("tang", outcome: .error, milliseconds: 100)
        XCTAssertTrue(cooldown.isCoolingDown("tang"))
        clock.now = clock.now.addingTimeInterval(4 * 60 + 59)
        XCTAssertTrue(cooldown.isCoolingDown("tang"))
        clock.now = clock.now.addingTimeInterval(2)
        XCTAssertFalse(cooldown.isCoolingDown("tang"))
    }

    func testTimeoutCoolsImmediatelyForTwoMinutes() {
        let (cooldown, clock) = makeCooldown(now: Date())
        cooldown.record("lzm", outcome: .timeout, milliseconds: 3000)
        XCTAssertTrue(cooldown.isCoolingDown("lzm"))
        clock.now = clock.now.addingTimeInterval(119)
        XCTAssertTrue(cooldown.isCoolingDown("lzm"))
        clock.now = clock.now.addingTimeInterval(2)
        XCTAssertFalse(cooldown.isCoolingDown("lzm"))
    }

    func testEmptyIsNotAFailure() {
        let (cooldown, _) = makeCooldown(now: Date())
        for _ in 0..<5 {
            cooldown.record("gd", outcome: .empty, milliseconds: 50)
        }
        XCTAssertFalse(cooldown.isCoolingDown("gd"))
        XCTAssertNil(cooldown.fails["gd"])
    }

    func testSuccessClearsFailureStreakAndCooldown() {
        let (cooldown, _) = makeCooldown(now: Date())
        cooldown.record("zddyr", outcome: .error, milliseconds: 100)
        cooldown.record("zddyr", outcome: .error, milliseconds: 100)
        cooldown.record("zddyr", outcome: .error, milliseconds: 100)
        XCTAssertTrue(cooldown.isCoolingDown("zddyr"))
        cooldown.record("zddyr", outcome: .success, milliseconds: 200)
        XCTAssertFalse(cooldown.isCoolingDown("zddyr"))
        XCTAssertNil(cooldown.fails["zddyr"])
    }

    func testSpeedEma70_30() {
        let (cooldown, _) = makeCooldown(now: Date())
        cooldown.record("tang", outcome: .success, milliseconds: 100)
        XCTAssertEqual(cooldown.averageMs("tang"), 100)
        cooldown.record("tang", outcome: .success, milliseconds: 300)
        // 100 * 0.7 + 300 * 0.3 = 160.
        XCTAssertEqual(cooldown.averageMs("tang"), 160)
        // Unknown speed sorts in the middle (Flutter parity: 500 ms).
        XCTAssertEqual(cooldown.averageMs("never-seen"), 500)
    }

    func testCooldownPersistsAndReloads() {
        let (cooldown, _) = makeCooldown(now: Date())
        cooldown.record("tang", outcome: .error, milliseconds: 100)
        cooldown.record("tang", outcome: .error, milliseconds: 100)
        cooldown.record("tang", outcome: .error, milliseconds: 100)
        cooldown.saveNow()
        let reloaded = ResolverCooldown(documentsDirectory: docs)
        XCTAssertTrue(reloaded.isCoolingDown("tang"))
    }

    // MARK: - b49fix22 D24-1: newest-wins speed merge

    private func plantDiskSpeeds(_ map: [String: ResolverSpeedRecord]) {
        let data = try! JSONEncoder().encode(map)
        try! data.write(to: docs.appendingPathComponent("hao_resolver_speed.json"), options: [.atomic])
    }

    func testNewerImportedSpeedSurvivesSave() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let (cooldown, _) = makeCooldown(now: t0)
        cooldown.record("qq", outcome: .success, milliseconds: 300)
        // The backup's record is one minute newer than the live
        // recording — newest-wins keeps it, and the backfill
        // makes averageMs() see it at once, no restart.
        plantDiskSpeeds(["qq": ResolverSpeedRecord(avg: 120, updatedAtMs: Int(t0.addingTimeInterval(60).timeIntervalSince1970 * 1000))])
        cooldown.saveNow()
        XCTAssertEqual(cooldown.averageMs("qq"), 120)
    }

    func testOlderImportedSpeedDoesNotOverwriteLiveRecording() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let (cooldown, _) = makeCooldown(now: t0)
        cooldown.record("qq", outcome: .success, milliseconds: 300)
        // The backup's record is one minute older — memory wins.
        plantDiskSpeeds(["qq": ResolverSpeedRecord(avg: 120, updatedAtMs: Int(t0.addingTimeInterval(-60).timeIntervalSince1970 * 1000))])
        cooldown.saveNow()
        XCTAssertEqual(cooldown.averageMs("qq"), 300)
        // ...and the disk file keeps the live value, not the import.
        let reloaded = ResolverCooldown(documentsDirectory: docs)
        XCTAssertEqual(reloaded.averageMs("qq"), 300)
    }

    func testUnstampedImportedSpeedLosesToLiveRecording() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let (cooldown, _) = makeCooldown(now: t0)
        cooldown.record("qq", outcome: .success, milliseconds: 300)
        // A pre-fix22 record carries no `updated` — it counts as
        // epoch, older than any stamped live recording.
        plantDiskSpeeds(["qq": ResolverSpeedRecord(avg: 120)])
        cooldown.saveNow()
        XCTAssertEqual(cooldown.averageMs("qq"), 300)
    }

    func testRecordStampsUpdatedAt() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let (cooldown, _) = makeCooldown(now: t0)
        XCTAssertNil(cooldown.updatedAt["qq"])
        cooldown.record("qq", outcome: .success, milliseconds: 300)
        XCTAssertEqual(cooldown.updatedAt["qq"], t0)
    }

    // MARK: - Play-URL cache

    func testCacheHitAndOneHourExpiry() {
        let clock = FakeClock(now: Date())
        let cache = PlayURLCache()
        cache.now = { clock.now }
        let key = PlayURLCache.key(songId: "123", platform: "wy", quality: .hiRes)
        XCTAssertNil(cache.get(key))
        cache.put(key, url: "https://example.com/a.mp3", tier: .hiRes)
        XCTAssertEqual(cache.get(key)?.url, "https://example.com/a.mp3")
        XCTAssertEqual(cache.get(key)?.tier, .hiRes)
        clock.now = clock.now.addingTimeInterval(59 * 60)
        XCTAssertNotNil(cache.get(key))
        clock.now = clock.now.addingTimeInterval(61)
        XCTAssertNil(cache.get(key))
    }

    func testCacheCapEvictsOldest() {
        let cache = PlayURLCache()
        for i in 0..<205 {
            cache.put("k\(i)", url: "https://example.com/\(i).mp3", tier: .standard128)
        }
        XCTAssertEqual(cache.count, 200)
        XCTAssertNil(cache.get("k0"))
        XCTAssertNil(cache.get("k4"))
        XCTAssertNotNil(cache.get("k5"))
        XCTAssertNotNil(cache.get("k204"))
    }

    func testCacheEvict() {
        let cache = PlayURLCache()
        cache.put("k", url: "https://example.com/a.mp3", tier: .flac)
        cache.evict("k")
        XCTAssertNil(cache.get("k"))
        XCTAssertEqual(cache.count, 0)
    }

    func testCacheKeyIncludesTier() {
        let a = PlayURLCache.key(songId: "1", platform: "wy", quality: .master)
        let b = PlayURLCache.key(songId: "1", platform: "wy", quality: .hiRes)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Failure memory (b46)

    /// b46: a manual play clears one song's failures so the next
    /// resolve re-asks every source; other songs stay remembered.
    func testFailureMemoryClearSong() {
        let memory = ResolveFailureMemory()
        memory.record(sourceKey: "lx:netease", songId: "111")
        memory.record(sourceKey: "lx:qq", songId: "111")
        memory.record(sourceKey: "lx:netease", songId: "222")
        XCTAssertTrue(memory.isFailed(sourceKey: "lx:netease", songId: "111"))
        XCTAssertTrue(memory.isFailed(sourceKey: "lx:qq", songId: "111"))
        memory.clear(songId: "111")
        XCTAssertFalse(memory.isFailed(sourceKey: "lx:netease", songId: "111"))
        XCTAssertFalse(memory.isFailed(sourceKey: "lx:qq", songId: "111"))
        XCTAssertTrue(memory.isFailed(sourceKey: "lx:netease", songId: "222"))
    }
}

/// Mutable clock for tests that inject `now`.
final class FakeClock {
    var now: Date
    init(now: Date) { self.now = now }
}

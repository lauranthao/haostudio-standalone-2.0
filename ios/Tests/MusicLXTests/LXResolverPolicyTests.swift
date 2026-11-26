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

    // MARK: - b49fix23 D25-4: clamp the imported stamp to now

    func testClockAheadImportedStampIsClampedToNow() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let (cooldown, _) = makeCooldown(now: t0)
        cooldown.record("qq", outcome: .success, milliseconds: 300)
        // The backup's record is stamped 10 minutes in the
        // future (its device clock was ahead). Clamped to now,
        // it ties with the live recording, and the tie goes to
        // memory — the import must not suppress live speeds
        // until this clock catches up.
        plantDiskSpeeds(["qq": ResolverSpeedRecord(avg: 100, updatedAtMs: Int(t0.addingTimeInterval(600).timeIntervalSince1970 * 1000))])
        cooldown.saveNow()
        XCTAssertEqual(cooldown.averageMs("qq"), 300)
        // ...and the disk file keeps the live value too.
        let reloaded = ResolverCooldown(documentsDirectory: docs)
        XCTAssertEqual(reloaded.averageMs("qq"), 300)
    }

    // MARK: - b49fix23 D25-5: avg is field-level, not wholesale

    func testNewerImportedRecordWithNilAvgKeepsMemoryAvg() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let (cooldown, _) = makeCooldown(now: t0)
        cooldown.record("qq", outcome: .success, milliseconds: 300)
        cooldown.record("qq", outcome: .error, milliseconds: 0)
        // The backup's record is newer and cleared the failure
        // streak (fails nil) but never measured a speed (avg
        // nil) — the live measured avg survives; fails is still
        // cleared wholesale.
        plantDiskSpeeds(["qq": ResolverSpeedRecord(avg: nil, fails: nil, updatedAtMs: Int(t0.addingTimeInterval(60).timeIntervalSince1970 * 1000))])
        cooldown.saveNow()
        XCTAssertEqual(cooldown.averageMs("qq"), 300)
        XCTAssertNil(cooldown.fails["qq"])
        // ...and the disk file keeps the live avg too.
        let reloaded = ResolverCooldown(documentsDirectory: docs)
        XCTAssertEqual(reloaded.averageMs("qq"), 300)
    }

    // MARK: - b49fix24 D26-3: load() clamps too, and the file self-heals

    func testLoadClampsFutureStampsToNow() {
        // A pre-fix file carrying a future `updated` stamp and
        // a `cooled` deadline an hour out: load() clamps both on
        // the way into memory — the stamp to now, the cooldown
        // to now + coolFor (5 minutes). The planted stamps are
        // future against the REAL clock (load() runs in init,
        // before the test's fake clock is installed).
        let beforeLoad = Date()
        plantDiskSpeeds(["qq": ResolverSpeedRecord(
            avg: 300, fails: 3,
            cooledUntilMs: Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000),
            updatedAtMs: Int(Date().addingTimeInterval(365 * 24 * 3600).timeIntervalSince1970 * 1000))])
        let cooldown = ResolverCooldown(documentsDirectory: docs)
        XCTAssertEqual(cooldown.averageMs("qq"), 300)
        XCTAssertEqual(cooldown.fails["qq"], 3)
        let stamped = cooldown.updatedAt["qq"]
        XCTAssertNotNil(stamped)
        XCTAssertTrue(stamped! <= Date())
        XCTAssertTrue(stamped! >= beforeLoad)
        let cooled = cooldown.cooledUntil["qq"]
        XCTAssertNotNil(cooled)
        XCTAssertTrue(cooled! <= Date().addingTimeInterval(301))
        XCTAssertTrue(cooled! >= beforeLoad.addingTimeInterval(299))
    }

    func testLoadPlusSaveHealsFutureStampOutOfFile() {
        // The file self-heals: loaded clamped, the next save
        // writes the clamped stamp back — a source that is never
        // resolved again no longer keeps its future stamp
        // forever.
        let beforeLoad = Date()
        plantDiskSpeeds(["qq": ResolverSpeedRecord(
            avg: 300, fails: nil, cooledUntilMs: nil,
            updatedAtMs: Int(Date().addingTimeInterval(365 * 24 * 3600).timeIntervalSince1970 * 1000))])
        let cooldown = ResolverCooldown(documentsDirectory: docs)
        cooldown.saveNow()
        let data = try! Data(contentsOf: docs.appendingPathComponent("hao_resolver_speed.json"))
        let map = try! JSONDecoder().decode([String: ResolverSpeedRecord].self, from: data)
        let writtenMs = map["qq"]?.updatedAtMs
        XCTAssertNotNil(writtenMs)
        XCTAssertTrue(writtenMs! <= Int(Date().timeIntervalSince1970 * 1000) + 1000)
        XCTAssertTrue(writtenMs! >= Int(beforeLoad.timeIntervalSince1970 * 1000))
    }

    // MARK: - b49fix24 D26-4: a clear is not resurrected by the disk-only branch

    func testClearIsNotResurrectedByNextSave() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let (cooldown, _) = makeCooldown(now: t0)
        // An error-only source: 3 errors, no avg ever measured
        // — the disk record holds fails + cooldown, and the key
        // has no avg, so saveLocked builds no map entry for it.
        for _ in 0..<3 { cooldown.record("qq", outcome: .error, milliseconds: 100) }
        XCTAssertTrue(cooldown.isCoolingDown("qq"))
        XCTAssertEqual(cooldown.fails["qq"], 3)
        cooldown.saveNow()
        // The user taps the song: clear() drops fails /
        // cooldown and stamps the key newer (a tie with the
        // disk stamp — the tie counts as memory).
        cooldown.clear(keys: ["qq"])
        XCTAssertNil(cooldown.fails["qq"])
        XCTAssertFalse(cooldown.isCoolingDown("qq"))
        // The next save must NOT take the disk record wholesale
        // and resurrect the cleared fails / cooldown.
        cooldown.saveNow()
        XCTAssertNil(cooldown.fails["qq"])
        XCTAssertFalse(cooldown.isCoolingDown("qq"))
        // ...and the disk file agrees after a relaunch.
        let reloaded = ResolverCooldown(documentsDirectory: docs)
        XCTAssertNil(reloaded.fails["qq"])
    }

    func testDiskOnlyKeyWithNoMemoryStampIsStillTakenWholesale() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let (cooldown, _) = makeCooldown(now: t0)
        // The normal disk-only case is unchanged: memory has no
        // stamp at all for the key, so the disk record (fails +
        // cooldown included) is taken wholesale.
        plantDiskSpeeds(["qq": ResolverSpeedRecord(
            avg: 250, fails: 3,
            cooledUntilMs: Int(t0.addingTimeInterval(300).timeIntervalSince1970 * 1000),
            updatedAtMs: Int(t0.timeIntervalSince1970 * 1000))])
        cooldown.saveNow()
        XCTAssertEqual(cooldown.averageMs("qq"), 250)
        XCTAssertEqual(cooldown.fails["qq"], 3)
        XCTAssertTrue(cooldown.isCoolingDown("qq"))
    }

    // MARK: - b49fix25 D27-1: a clear stamp persists as a stub even when the disk never had the key

    func testClearStampPersistsAsStubWhenDiskNeverHadTheKey() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let (cooldown, _) = makeCooldown(now: t0)
        // 3 fast errors inside the throttle window (record()
        // only saves every 10 attempts or 5 s) — the disk has
        // no record for the key yet.
        for _ in 0..<3 { cooldown.record("qq", outcome: .error, milliseconds: 100) }
        XCTAssertTrue(cooldown.isCoolingDown("qq"))
        XCTAssertEqual(cooldown.fails["qq"], 3)
        // The user taps the song: clear() drops fails /
        // cooldown and stamps the key — the stamp must reach
        // the file as a stub, even though the disk never had
        // this key.
        cooldown.clear(keys: ["qq"])
        let data = try! Data(contentsOf: docs.appendingPathComponent("hao_resolver_speed.json"))
        let map = try! JSONDecoder().decode([String: ResolverSpeedRecord].self, from: data)
        let stub = map["qq"]
        XCTAssertNotNil(stub)
        XCTAssertNil(stub?.avg)
        XCTAssertNil(stub?.fails)
        XCTAssertNil(stub?.cooledUntilMs)
        XCTAssertEqual(stub?.updatedAtMs, Int(t0.timeIntervalSince1970 * 1000))
    }

    func testClearSurvivesRestartAndOlderImport() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let (cooldown, _) = makeCooldown(now: t0)
        for _ in 0..<3 { cooldown.record("qq", outcome: .error, milliseconds: 100) }
        cooldown.clear(keys: ["qq"])
        // Simulate a restart: a fresh ResolverCooldown loads
        // the file — the stub's stamp comes back into memory.
        // (load() runs on the real clock in init, before the
        // fake clock is installed; the stub stamp t0 is in the
        // past, so the load clamp leaves it alone.)
        let reloaded = ResolverCooldown(documentsDirectory: docs)
        XCTAssertEqual(reloaded.updatedAt["qq"], t0)
        XCTAssertNil(reloaded.fails["qq"])
        reloaded.now = { t0 }
        // An import installs an OLDER fails record for the key
        // (the backup was taken before the clear).
        plantDiskSpeeds(["qq": ResolverSpeedRecord(
            avg: nil, fails: 3,
            cooledUntilMs: Int(t0.addingTimeInterval(300).timeIntervalSince1970 * 1000),
            updatedAtMs: Int(t0.addingTimeInterval(-60).timeIntervalSince1970 * 1000))])
        reloaded.saveNow()
        // The clear is not resurrected: the stub's newer stamp
        // wins, fails and cooldown stay cleared, in memory and
        // in the file.
        XCTAssertNil(reloaded.fails["qq"])
        XCTAssertFalse(reloaded.isCoolingDown("qq"))
        let data = try! Data(contentsOf: docs.appendingPathComponent("hao_resolver_speed.json"))
        let map = try! JSONDecoder().decode([String: ResolverSpeedRecord].self, from: data)
        XCTAssertNil(map["qq"]?.fails)
        XCTAssertNil(map["qq"]?.cooledUntilMs)
        XCTAssertEqual(map["qq"]?.updatedAtMs, Int(t0.timeIntervalSince1970 * 1000))
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

    /// b49fix23 D25-3: a manual clear bumps a synchronous
    /// per-song generation, so a resolve enqueued BEFORE the
    /// clear knows the failure memory it is about to read is
    /// stale. The generation is per song — a clear for another
    /// song does not move this song's generation.
    func testFailureMemoryClearGeneration() {
        let memory = ResolveFailureMemory()
        memory.record(sourceKey: "lx:netease", songId: "111")
        XCTAssertEqual(memory.clearGeneration(songId: "111"), 0)
        // A resolve enqueued now captures generation 0.
        let captured = memory.clearGeneration(songId: "111")
        // A manual clear requested while it waits bumps it.
        memory.bumpClearGeneration(songId: "111")
        XCTAssertEqual(memory.clearGeneration(songId: "111"), 1)
        XCTAssertNotEqual(memory.clearGeneration(songId: "111"), captured)
        // Another song's clear does not move this song.
        memory.bumpClearGeneration(songId: "222")
        XCTAssertEqual(memory.clearGeneration(songId: "111"), 1)
        XCTAssertEqual(memory.clearGeneration(songId: "222"), 1)
        // The dict clear itself still works as before.
        memory.clear(songId: "111")
        XCTAssertFalse(memory.isFailed(sourceKey: "lx:netease", songId: "111"))
    }
}

/// Mutable clock for tests that inject `now`.
final class FakeClock {
    var now: Date
    init(now: Date) { self.now = now }
}

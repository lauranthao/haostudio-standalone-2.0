// HAo Studio 2.0 — resolver behaviour tests (S2-B).
//
// Serial fastest-first resolution with fake jobs (no network, no
// real 8 s waits): the first playable URL returns at once and later
// jobs never run; per-job and whole-resolve budgets use short
// injected values; a 3-failure cooldown skips the job; the 1 h
// cache answers the second resolve without invoking any job; a
// low-tier URL at a master request is never labelled Master.

import Foundation
import XCTest

@testable import AppCore

final class LXResolverTests: XCTestCase {
    private var docs: URL!

    override func setUp() {
        super.setUp()
        docs = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-resolver-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let docs = docs {
            try? FileManager.default.removeItem(at: docs)
        }
        super.tearDown()
    }

    /// Resolver with fake jobs on the tx platform (no xinghai warmup
    /// on tx, so the test makes no network call). Budgets are short
    /// so timeout tests finish in well under a second.
    private func makeResolver(
        jobs: @escaping () -> [LXResolverJob],
        cooldown: ResolverCooldown? = nil,
        cache: PlayURLCache? = nil
    ) -> LXSourceResolver {
        let engine = LXEngine(
            fileStore: LXScriptFileStore(documentsDirectory: docs),
            scriptStore: LXScriptStore(documentsDirectory: docs),
            bundleLoader: { _ in nil })
        return LXSourceResolver(
            engine: engine,
            cooldown: cooldown ?? ResolverCooldown(documentsDirectory: docs),
            cache: cache ?? PlayURLCache(),
            scriptStore: LXScriptStore(documentsDirectory: docs),
            documentsDirectory: docs,
            perJobTimeout: 0.3,
            totalBudget: 1.5,
            firstPassCap: 0.8,
            laterPassCap: 0.4,
            jobListProvider: { _, _, _, _, _ in jobs() })
    }

    private func job(
        key: String,
        order: Int = 1,
        run: @escaping (LXCancelToken, @escaping (LXResolverOutcome) -> Void) -> Void
    ) -> LXResolverJob {
        LXResolverJob(
            key: key, name: key, order: order,
            platforms: [.tx], warmup: nil, run: run)
    }

    private func resolve(
        _ resolver: LXSourceResolver,
        quality: AudioQuality = .hiRes,
        songId: String = "s1",
        excluding: [URL] = []
    ) -> PlayUrlResult? {
        let expectation = self.expectation(description: "resolve")
        var out: PlayUrlResult?
        resolver.resolve(
            songId: songId, platform: .tx, title: "Song", artist: "Singer",
            quality: quality, excluding: excluding
        ) { result in
            out = result
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        return out
    }

    func testFirstPlayableReturnsImmediatelyAndLaterJobsNeverRun() {
        var ran: [String] = []
        let resolver = makeResolver {
            [
                self.job(key: "slow") { _, done in
                    ran.append("slow")
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                        done(.url("https://example.com/slow.mp3", nil))
                    }
                },
                self.job(key: "never") { _, done in
                    ran.append("never")
                    done(.url("https://example.com/never.mp3", nil))
                },
            ]
        }
        let started = Date()
        let result = resolve(resolver)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(result?.url, "https://example.com/slow.mp3")
        XCTAssertEqual(ran, ["slow"])
        // Returned on the first job, not after a full pass.
        XCTAssertLessThan(elapsed, 1.0)
        XCTAssertEqual(resolver.lastResolvedTier, .hiRes)
    }

    func testEmptyJobFallsThroughToNextJob() {
        let resolver = makeResolver {
            [
                self.job(key: "empty") { _, done in done(.empty) },
                self.job(key: "good") { _, done in
                    done(.url("https://example.com/good.mp3", nil))
                },
            ]
        }
        XCTAssertEqual(resolve(resolver)?.url, "https://example.com/good.mp3")
    }

    func testPerJobTimeoutMovesOnWithoutWaitingForTheJob() {
        var secondRan = false
        let resolver = makeResolver {
            [
                self.job(key: "hangs") { _, _ in
                    // Never calls back: the 0.3 s per-job timeout
                    // must move on anyway.
                },
                self.job(key: "second") { _, done in
                    secondRan = true
                    done(.url("https://example.com/second.mp3", nil))
                },
            ]
        }
        let started = Date()
        let result = resolve(resolver)
        XCTAssertEqual(result?.url, "https://example.com/second.mp3")
        XCTAssertTrue(secondRan)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertFalse(resolver.lastResolveTruncated)
    }

    func testWholeResolveBudgetTruncatesAndReportsIt() {
        // A job whose prerequisite never answers: the pass budget
        // dies with jobs still untried, so the resolve is truncated
        // (a plain hanging job would time out and count as tried).
        var runCalled = false
        let warmupJob = LXResolverJob(
            key: "slow-warmup", name: "slow-warmup", order: 1,
            platforms: [.tx],
            warmup: { _ in
                // Never calls back.
            },
            run: { _, done in
                runCalled = true
                done(.empty)
            })
        let resolver = makeResolver { [warmupJob, warmupJob] }
        let started = Date()
        let result = resolve(resolver)
        XCTAssertNil(result)
        XCTAssertFalse(runCalled)
        XCTAssertTrue(resolver.lastResolveTruncated)
        // Total budget is 1.5 s (injected), not the production 8 s.
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }

    func testThreeFailuresCoolTheJobAcrossResolves() {
        var invocations = 0
        let cooldown = ResolverCooldown(documentsDirectory: docs)
        // Phase 2 adds a healthy job; the provider reads the flag.
        var includeGood = false
        let resolver = makeResolver(
            jobs: {
                var list = [
                    self.job(key: "flaky") { _, done in
                        invocations += 1
                        done(.error)
                    },
                ]
                if includeGood {
                    list.append(self.job(key: "good") { _, done in
                        done(.url("https://example.com/good.mp3", nil))
                    })
                }
                return list
            },
            cooldown: cooldown)
        // Three failing resolves: the flaky job runs each time.
        // (.standard128 has no lower tier, so one invocation per
        // resolve; distinct songIds, so the 1 h cache never answers
        // without invoking a job.)
        for i in 0..<3 { _ = resolve(resolver, quality: .standard128, songId: "cool-\(i)") }
        XCTAssertEqual(invocations, 3)
        XCTAssertTrue(cooldown.isCoolingDown("flaky"))
        // Fourth resolve, now with a healthy job: a cooled job sorts
        // last (Flutter parity — cooled jobs are still tried when
        // reached, never skipped outright), so the healthy job wins
        // the race and the flaky job is not reached.
        includeGood = true
        _ = resolve(resolver, quality: .standard128, songId: "cool-3")
        XCTAssertEqual(invocations, 3)
        XCTAssertTrue(cooldown.isCoolingDown("flaky"))
    }

    func testCacheAnswersSecondResolveWithoutInvokingJobs() {
        var invocations = 0
        let cache = PlayURLCache()
        let resolver = makeResolver(
            jobs: {
                [
                    self.job(key: "good") { _, done in
                        invocations += 1
                        done(.url("https://example.com/cached.mp3", nil))
                    },
                ]
            },
            cache: cache)
        XCTAssertEqual(resolve(resolver)?.url, "https://example.com/cached.mp3")
        XCTAssertEqual(invocations, 1)
        XCTAssertEqual(resolve(resolver)?.url, "https://example.com/cached.mp3")
        XCTAssertEqual(invocations, 1)
        XCTAssertEqual(resolve(resolver)?.via, "cache")
    }

    func testMasterRequestWithLowTierUrlIsLabelledHiResNotMaster() {
        let resolver = makeResolver {
            [
                self.job(key: "tang") { _, done in
                    // A bare URL carries no tier signal: at a master
                    // request the declared tier caps at hires.
                    done(.url("https://example.com/low.mp3", nil))
                },
            ]
        }
        let result = resolve(resolver, quality: .master)
        XCTAssertEqual(result?.url, "https://example.com/low.mp3")
        XCTAssertEqual(result?.quality, .hiRes)
        XCTAssertEqual(resolver.lastResolvedTier, .hiRes)
    }

    func testMasterRequestWithRealMasterReportKeepsMaster() {
        let resolver = makeResolver {
            [
                self.job(key: "zddyr") { _, done in
                    done(.url("https://example.com/master.mp3", .master))
                },
            ]
        }
        let result = resolve(resolver, quality: .master)
        XCTAssertEqual(result?.quality, .master)
        XCTAssertEqual(resolver.lastResolvedTier, .master)
    }

    func testEmptySongIdResolvesToNilImmediately() {
        let resolver = makeResolver { [] }
        XCTAssertNil(resolve(resolver, songId: ""))
    }

    func testResolveFirstPlayableParsesPlatformSongId() {
        let resolver = makeResolver {
            [
                self.job(key: "good") { _, done in
                    done(.url("https://example.com/x.mp3", nil))
                },
            ]
        }
        let expectation = self.expectation(description: "protocol resolve")
        var out: URL?
        resolver.resolveFirstPlayable(
            for: PlaybackItem(id: "tx|s1", kind: .music, title: "Song", artist: "Singer"),
            targetQuality: .hiRes
        ) { url in
            out = url
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(out?.absoluteString, "https://example.com/x.mp3")
    }

    func testResolveFirstPlayableRejectsIdWithoutPlatform() {
        let resolver = makeResolver { [] }
        let expectation = self.expectation(description: "bad id")
        var out: URL? = URL(string: "https://example.com/keep.mp3")
        resolver.resolveFirstPlayable(
            for: PlaybackItem(id: "no-separator", kind: .music, title: "Song", artist: nil),
            targetQuality: .hiRes
        ) { url in
            out = url
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertNil(out)
    }

    // MARK: - Build 36 item 3: 30 s previews never count as success

    func testPreviewURLFallsThroughToNextJob() {
        let resolver = makeResolver {
            [
                // QQ trial file (RS0 prefix): must not win.
                self.job(key: "trial") { _, done in
                    done(.url("https://ws.stream.qqmusic.qq.com/RS0abc123.m4a", nil))
                },
                self.job(key: "good") { _, done in
                    done(.url("https://example.com/good.mp3", nil))
                },
            ]
        }
        let result = resolve(resolver)
        XCTAssertEqual(result?.url, "https://example.com/good.mp3")
        XCTAssertEqual(result?.via, "good")
    }

    func testPreviewURLFallsThroughToNextJobNetEaseOuter() {
        // A NetEase outer URL on a trial-only track is a preview by
        // construction; the next source must win instead.
        let engine = LXEngine(
            fileStore: LXScriptFileStore(documentsDirectory: docs),
            scriptStore: LXScriptStore(documentsDirectory: docs),
            bundleLoader: { _ in nil })
        let resolver = LXSourceResolver(
            engine: engine,
            cooldown: ResolverCooldown(documentsDirectory: docs),
            cache: PlayURLCache(),
            scriptStore: LXScriptStore(documentsDirectory: docs),
            documentsDirectory: docs,
            perJobTimeout: 0.3,
            totalBudget: 1.5,
            firstPassCap: 0.8,
            laterPassCap: 0.4,
            jobListProvider: { _, _, _, _, _ in
                [
                    self.job(key: "outer") { _, done in
                        done(.url("https://music.163.com/song/media/outer/url?id=123.mp3", nil))
                    },
                    self.job(key: "good") { _, done in
                        done(.url("https://example.com/good.mp3", nil))
                    },
                ]
            })
        // Trial-only must travel with the track for the outer-URL
        // rule to fire: resolve via a PlaybackItem that carries it.
        let expectation = self.expectation(description: "outer preview falls through")
        var out: URL?
        resolver.resolveFirstPlayable(
            for: PlaybackItem(id: "wy|s1", kind: .music, title: "Song", artist: "Singer",
                             duration: 200, trialOnly: true),
            targetQuality: .hiRes
        ) { url in
            out = url
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(out?.absoluteString, "https://example.com/good.mp3")
    }

    func testPreviewJobIsNotRetriedAtLowerTiers() {
        // A job that answered with a preview at master must not be
        // re-asked at the lower tiers of the same resolve: a trial
        // at one tier is a trial at every tier.
        var previewRuns = 0
        let previewJob = self.job(key: "trial") { _, done in
            previewRuns += 1
            done(.url("https://ws.stream.qqmusic.qq.com/RS0abc123.m4a", nil))
        }
        let goodJob = self.job(key: "good") { _, done in
            done(.url("https://example.com/good.mp3", nil))
        }
        let engine = LXEngine(
            fileStore: LXScriptFileStore(documentsDirectory: docs),
            scriptStore: LXScriptStore(documentsDirectory: docs),
            bundleLoader: { _ in nil })
        let resolver = LXSourceResolver(
            engine: engine,
            cooldown: ResolverCooldown(documentsDirectory: docs),
            cache: PlayURLCache(),
            scriptStore: LXScriptStore(documentsDirectory: docs),
            documentsDirectory: docs,
            perJobTimeout: 0.3,
            totalBudget: 1.5,
            firstPassCap: 0.8,
            laterPassCap: 0.4,
            jobListProvider: { _, tier, _, _, _ in
                // Only the trial job serves master; the good job
                // joins from hires down.
                tier == .master ? [previewJob] : [previewJob, goodJob]
            })
        let result = resolve(resolver, quality: .master)
        XCTAssertEqual(result?.url, "https://example.com/good.mp3")
        XCTAssertEqual(previewRuns, 1)
    }

    func testPreviewDoesNotCoolTheJob() {
        // A preview is an empty answer, not a failure: the job
        // keeps serving other songs and is never cooled for it.
        var invocations = 0
        let cooldown = ResolverCooldown(documentsDirectory: docs)
        let resolver = makeResolver(
            jobs: {
                [
                    self.job(key: "trial") { _, done in
                        invocations += 1
                        done(.url("https://ws.stream.qqmusic.qq.com/RS0abc123.m4a", nil))
                    },
                ]
            },
            cooldown: cooldown)
        for i in 0..<3 { _ = resolve(resolver, quality: .standard128, songId: "pv-\(i)") }
        XCTAssertEqual(invocations, 3)
        XCTAssertFalse(cooldown.isCoolingDown("trial"))
    }

    func testExcludingSkipsSameURLFromFastestJob() {
        // The player fallback re-resolve passes the failed/preview
        // URL in `excluding`: the fastest job must not hand the
        // same URL back again — the next candidate wins.
        var fastRuns = 0
        let cache = PlayURLCache()
        let resolver = makeResolver(
            jobs: {
                [
                    self.job(key: "fast") { _, done in
                        fastRuns += 1
                        done(.url("https://example.com/first.mp3", nil))
                    },
                    self.job(key: "slow") { _, done in
                        done(.url("https://example.com/second.mp3", nil))
                    },
                ]
            },
            cache: cache)
        XCTAssertEqual(resolve(resolver)?.url, "https://example.com/first.mp3")
        // The first URL is cached now: excluding it must bypass the
        // cache AND skip it when the fastest job returns it again.
        let excluded = URL(string: "https://example.com/first.mp3")!
        XCTAssertEqual(resolve(resolver, excluding: [excluded])?.url,
                       "https://example.com/second.mp3")
        XCTAssertEqual(fastRuns, 2)
    }

    func testPreviewAtMasterRequestKeepsMasterHonesty() {
        // A preview that claims Master never becomes a Master
        // result; the fallback URL is labelled with its real tier.
        let resolver = makeResolver {
            [
                self.job(key: "trial") { _, done in
                    done(.url("https://ws.stream.qqmusic.qq.com/RS0abc123.m4a", .master))
                },
                self.job(key: "good") { _, done in
                    done(.url("https://example.com/low.mp3", nil))
                },
            ]
        }
        let result = resolve(resolver, quality: .master)
        XCTAssertEqual(result?.url, "https://example.com/low.mp3")
        XCTAssertEqual(result?.quality, .hiRes)
        XCTAssertEqual(resolver.lastResolvedTier, .hiRes)
    }
}

// HAo Studio 2.0 — audio-quality tests (S2-B).
//
// Covers the LX quality codes, the downgrade chain, and the Master
// honesty gate: only a real Master URL may be labelled Master; a
// lower-tier URL plays as a drop-down, never as Master.

import Foundation
import XCTest

@testable import AppCore

final class MusicQualityTests: XCTestCase {
    func testQualityCodes() {
        XCTAssertEqual(AudioQuality.master.lxCode, "master")
        XCTAssertEqual(AudioQuality.hiRes.lxCode, "hires")
        XCTAssertEqual(AudioQuality.flac.lxCode, "lossless")
        XCTAssertEqual(AudioQuality.high320.lxCode, "320k")
        XCTAssertEqual(AudioQuality.standard128.lxCode, "128k")
    }

    func testDisplayNames() {
        XCTAssertEqual(AudioQuality.master.displayName, "Master")
        XCTAssertEqual(AudioQuality.hiRes.displayName, "Hi-Res")
        XCTAssertEqual(AudioQuality.flac.displayName, "无损 FLAC")
        XCTAssertEqual(AudioQuality.high320.displayName, "高音质 320k")
        XCTAssertEqual(AudioQuality.standard128.displayName, "标准 128k")
    }

    func testDowngradeChain() {
        XCTAssertEqual(
            AudioQuality.chain(from: .master),
            [.master, .hiRes, .flac, .high320, .standard128])
        XCTAssertEqual(
            AudioQuality.chain(from: .flac),
            [.flac, .high320, .standard128])
        XCTAssertEqual(AudioQuality.chain(from: .standard128), [.standard128])
        // Ranks are strictly ordered, best first.
        XCTAssertTrue(AudioQuality.master.rank > AudioQuality.hiRes.rank)
        XCTAssertTrue(AudioQuality.hiRes.rank > AudioQuality.flac.rank)
        XCTAssertTrue(AudioQuality.flac.rank > AudioQuality.high320.rank)
        XCTAssertTrue(AudioQuality.high320.rank > AudioQuality.standard128.rank)
    }

    // MARK: - LX script quality selection

    func testLxQualityForScriptMasterIsLiteralOnly() {
        // A script without a literal `master` quality can never be
        // asked for master — no hires substitution.
        XCTAssertNil(MusicQualityGate.lxQualityForScript(.master, available: ["hires", "flac"]))
        XCTAssertEqual(MusicQualityGate.lxQualityForScript(.master, available: ["hires", "master"]), "master")
    }

    func testLxQualityForScriptHiResFallbacks() {
        XCTAssertEqual(MusicQualityGate.lxQualityForScript(.hiRes, available: ["hires"]), "hires")
        XCTAssertEqual(MusicQualityGate.lxQualityForScript(.hiRes, available: ["flac24bit"]), "flac24bit")
        XCTAssertEqual(MusicQualityGate.lxQualityForScript(.hiRes, available: ["flac"]), "flac")
        XCTAssertNil(MusicQualityGate.lxQualityForScript(.hiRes, available: ["128k"]))
    }

    func testLxQualityForScriptFlacAndLowTiersAreLiteral() {
        XCTAssertEqual(MusicQualityGate.lxQualityForScript(.flac, available: ["flac24bit"]), "flac24bit")
        XCTAssertEqual(MusicQualityGate.lxQualityForScript(.flac, available: ["flac"]), "flac")
        XCTAssertNil(MusicQualityGate.lxQualityForScript(.flac, available: ["hires"]))
        XCTAssertEqual(MusicQualityGate.lxQualityForScript(.high320, available: ["320k"]), "320k")
        XCTAssertNil(MusicQualityGate.lxQualityForScript(.high320, available: ["128k"]))
        XCTAssertEqual(MusicQualityGate.lxQualityForScript(.standard128, available: ["128k"]), "128k")
        XCTAssertNil(MusicQualityGate.lxQualityForScript(.standard128, available: ["320k"]))
    }

    // MARK: - Master honesty gate

    func testDeclaredTierOnlyZddyrAndXinghaiMayClaimMaster() {
        XCTAssertEqual(MusicQualityGate.declaredTier(resolverKey: "zddyr", requested: .master), .master)
        XCTAssertEqual(MusicQualityGate.declaredTier(resolverKey: "xinghai", requested: .master), .master)
        // Every other resolver — including LX scripts — caps at hires.
        XCTAssertEqual(MusicQualityGate.declaredTier(resolverKey: "tang", requested: .master), .hiRes)
        XCTAssertEqual(MusicQualityGate.declaredTier(resolverKey: "lx:suyin", requested: .master), .hiRes)
        XCTAssertEqual(MusicQualityGate.declaredTier(resolverKey: "lzm", requested: .master), .hiRes)
        // Non-master requests keep the label.
        XCTAssertEqual(MusicQualityGate.declaredTier(resolverKey: "tang", requested: .flac), .flac)
    }

    func testReportedTierForMapsReportToServedTier() {
        // b49sweep2 P1-15 (6a677ae): the report maps to the tier
        // actually served, for EVERY request — not just master.
        // The old version only handled master requests (anything
        // else fell through to nil, and the caller labelled the
        // result with the REQUESTED tier), so a script that
        // served 128k at a flac request showed a FLAC badge. The
        // old testReportedTierForKeepsMasterOnlyOnLiteralMaster
        // encoded the pre-fix collapse (non-master report at a
        // master request -> hiRes; any report at a non-master
        // request -> nil) and was never updated with it. A
        // literal 'master' report is still the only way to keep
        // the Master label (see the declaredTier gate above).
        XCTAssertEqual(MusicQualityGate.reportedTierFor(reported: "master", requested: .master), .master)
        // A non-master report at a master request is the tier
        // actually served, not a hiRes collapse.
        XCTAssertEqual(MusicQualityGate.reportedTierFor(reported: "hires", requested: .master), .hiRes)
        XCTAssertEqual(MusicQualityGate.reportedTierFor(reported: "flac", requested: .master), .flac)
        XCTAssertEqual(MusicQualityGate.reportedTierFor(reported: "flac24bit", requested: .master), .hiRes)
        XCTAssertEqual(MusicQualityGate.reportedTierFor(reported: "320k", requested: .flac), .high320)
        XCTAssertEqual(MusicQualityGate.reportedTierFor(reported: "128k", requested: .flac), .standard128)
        XCTAssertEqual(MusicQualityGate.reportedTierFor(reported: "master", requested: .hiRes), .master)
        XCTAssertNil(MusicQualityGate.reportedTierFor(reported: nil, requested: .master))
        XCTAssertNil(MusicQualityGate.reportedTierFor(reported: "unknown-xyz", requested: .master))
        XCTAssertEqual(MusicQualityGate.reportedTierFor(reported: "  FLAC  ", requested: .master), .flac)
    }

    func testLxApiServedTierNeedsMasterWithoutFallback() {
        XCTAssertEqual(
            MusicQualityGate.lxApiServedTier(response: ["quality": "master"], requested: .master),
            .master)
        // A fallback stream is hires even when the API says master.
        XCTAssertEqual(
            MusicQualityGate.lxApiServedTier(
                response: ["quality": "master", "quality_fallback": true], requested: .master),
            .hiRes)
        XCTAssertEqual(
            MusicQualityGate.lxApiServedTier(response: ["quality": "hires"], requested: .master),
            .hiRes)
        XCTAssertEqual(
            MusicQualityGate.lxApiServedTier(response: [:], requested: .master),
            .hiRes)
        XCTAssertNil(
            MusicQualityGate.lxApiServedTier(response: ["quality": "master"], requested: .hiRes))
    }
}

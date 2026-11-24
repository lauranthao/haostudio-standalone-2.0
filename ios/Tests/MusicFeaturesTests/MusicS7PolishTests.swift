// HAo Studio 2.0 — S7-A polish tests.
//
// Local-file quality derivation (MusicModels.swift) + plaza
// play-count text (MusicDiscoveryViews.swift). Pure functions only:
// no files, no network, no runloop.
//
// NOTE: like the rest of Tests/MusicFeaturesTests, this target is
// unwired until the S7 Xcode test target exists (see Package.swift
// header) — `swift test` does not run it yet.

import XCTest

@testable import MusicFeatures

final class MusicS7PolishTests: XCTestCase {

    // MARK: - Local-file quality tier

    func testLocalLosslessHiResBySampleRate() {
        XCTAssertEqual(
            localFileQualityTier(isLossless: true, sampleRate: 96_000, bitsPerChannel: 16, bitrateKbps: nil),
            .hiRes
        )
        XCTAssertEqual(
            localFileQualityTier(isLossless: true, sampleRate: 192_000, bitsPerChannel: 24, bitrateKbps: nil),
            .hiRes
        )
    }

    func testLocalLosslessHiResByBitDepth() {
        XCTAssertEqual(
            localFileQualityTier(isLossless: true, sampleRate: 44_100, bitsPerChannel: 24, bitrateKbps: nil),
            .hiRes
        )
    }

    func testLocalLosslessPlainIsFlac() {
        XCTAssertEqual(
            localFileQualityTier(isLossless: true, sampleRate: 44_100, bitsPerChannel: 16, bitrateKbps: nil),
            .flac
        )
    }

    func testLocalLosslessUnknownRateStillFlac() {
        // Lossless is lossless even when rate / depth are unknown —
        // still FLAC, never a guessed Hi-Res.
        XCTAssertEqual(
            localFileQualityTier(isLossless: true, sampleRate: nil, bitsPerChannel: nil, bitrateKbps: nil),
            .flac
        )
    }

    func testLocalLossy320() {
        XCTAssertEqual(
            localFileQualityTier(isLossless: false, sampleRate: 44_100, bitsPerChannel: nil, bitrateKbps: 320),
            .high320
        )
        XCTAssertEqual(
            localFileQualityTier(isLossless: false, sampleRate: 44_100, bitsPerChannel: nil, bitrateKbps: 500),
            .high320
        )
    }

    func testLocalLossyBelow320IsNil() {
        // 128k / 256k lossy proves no tier in our five-tier ladder —
        // the badge shows the honest "本地", never a guessed tier.
        XCTAssertNil(
            localFileQualityTier(isLossless: false, sampleRate: 44_100, bitsPerChannel: nil, bitrateKbps: 128)
        )
        XCTAssertNil(
            localFileQualityTier(isLossless: false, sampleRate: 44_100, bitsPerChannel: nil, bitrateKbps: 256)
        )
        XCTAssertNil(
            localFileQualityTier(isLossless: false, sampleRate: nil, bitsPerChannel: nil, bitrateKbps: nil)
        )
    }

    func testLocalNeverMaster() {
        // Master honesty gate: even the best local file tops out at
        // Hi-Res — no local file may ever be labelled Master.
        XCTAssertNotEqual(
            localFileQualityTier(isLossless: true, sampleRate: 192_000, bitsPerChannel: 32, bitrateKbps: nil),
            .master
        )
        XCTAssertNotEqual(
            localFileQualityTier(isLossless: false, sampleRate: 48_000, bitsPerChannel: nil, bitrateKbps: 1411),
            .master
        )
    }

    func testLocalUnprovableFileLabel() {
        // A missing / unreadable file shows the honest "本地".
        XCTAssertEqual(
            localFileQualityLabel(for: URL(fileURLWithPath: "/no/such/file.flac")),
            "本地"
        )
    }

    // MARK: - Plaza play-count text

    func testPlazaPlayCountText() {
        XCTAssertEqual(plazaPlayCountText(0), "")
        XCTAssertEqual(plazaPlayCountText(-5), "")
        XCTAssertEqual(plazaPlayCountText(999), "999次播放")
        XCTAssertEqual(plazaPlayCountText(12_345), "1.2万次播放")
        XCTAssertEqual(plazaPlayCountText(123_456_789), "1.2亿次播放")
    }

    func testPlazaPlayCountTextStripsZeroTenth() {
        // b36 follow-up, same ".0"-tail rule as liveWatchingText.
        XCTAssertEqual(plazaPlayCountText(10_000), "1万次播放")
        XCTAssertEqual(plazaPlayCountText(10_500), "1.1万次播放")
        XCTAssertEqual(plazaPlayCountText(100_000), "10万次播放")
        XCTAssertEqual(plazaPlayCountText(100_000_000), "1亿次播放")
        XCTAssertEqual(plazaPlayCountText(1_000_000_000), "10亿次播放")
    }
}

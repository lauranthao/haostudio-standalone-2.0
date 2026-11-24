// HAo Studio 2.0 — 30 s preview/trial detection tests (build 36,
// item 3).
//
// Pure classification, no network, no audio: the trial-only search
// flag, resolver response flags, preview URL patterns, and the
// asset-duration backstop. Resolver fall-through behaviour (a
// preview falls through to the next source exactly like an empty
// answer) lives in LXResolverTests.

import Foundation
import XCTest

@testable import AppCore

final class PreviewAudioTests: XCTestCase {
    // MARK: - Search-time trial-only flag

    func testTrialOnlyFreeNetEaseTrack() {
        XCTAssertFalse(PreviewAudioClassifier.isTrialOnlyTrack(
            fee: 0, dlLevel: "exhigh", plLevel: "exhigh", payPlay: nil))
    }

    func testTrialOnlyNetEaseFeeValues() {
        for fee in [1, 4, 8] {
            XCTAssertTrue(
                PreviewAudioClassifier.isTrialOnlyTrack(
                    fee: fee, dlLevel: "exhigh", plLevel: "exhigh", payPlay: nil),
                "fee \(fee) must flag trial-only")
        }
    }

    func testTrialOnlyNetEasePrivilegeNone() {
        XCTAssertTrue(PreviewAudioClassifier.isTrialOnlyTrack(
            fee: 0, dlLevel: "none", plLevel: "exhigh", payPlay: nil))
        XCTAssertTrue(PreviewAudioClassifier.isTrialOnlyTrack(
            fee: 0, dlLevel: "standard", plLevel: "none", payPlay: nil))
    }

    func testTrialOnlyMissingFieldsNeverFlag() {
        XCTAssertFalse(PreviewAudioClassifier.isTrialOnlyTrack(
            fee: nil, dlLevel: nil, plLevel: nil, payPlay: nil))
        XCTAssertFalse(PreviewAudioClassifier.isTrialOnlyTrack(
            fee: nil, dlLevel: "", plLevel: "", payPlay: nil))
        XCTAssertFalse(PreviewAudioClassifier.isTrialOnlyTrack(
            fee: nil, dlLevel: nil, plLevel: nil, payPlay: false))
    }

    func testTrialOnlyQQPayPlay() {
        XCTAssertTrue(PreviewAudioClassifier.isTrialOnlyTrack(
            fee: nil, dlLevel: nil, plLevel: nil, payPlay: true))
    }

    func testWyTrialOnlyFromSearchPayload() {
        XCTAssertTrue(MusicSearchAPI.wyTrialOnly([
            "fee": 8,
            "privilege": ["dlLevel": "none", "plLevel": "none"],
        ]))
        XCTAssertTrue(MusicSearchAPI.wyTrialOnly([
            "fee": 1,
            "privilege": ["dlLevel": "exhigh", "plLevel": "exhigh"],
        ]))
        XCTAssertFalse(MusicSearchAPI.wyTrialOnly([
            "fee": 0,
            "privilege": ["dlLevel": "exhigh", "plLevel": "standard"],
        ]))
        XCTAssertFalse(MusicSearchAPI.wyTrialOnly([:]))
    }

    func testTxTrialOnlyFromSearchPayload() {
        XCTAssertTrue(MusicSearchAPI.txTrialOnly(["pay": ["payplay": 1]]))
        XCTAssertFalse(MusicSearchAPI.txTrialOnly(["pay": ["payplay": 0]]))
        XCTAssertFalse(MusicSearchAPI.txTrialOnly([:]))
    }

    // MARK: - Resolver response flags

    func testPreviewResponseFreeTrialInfo() {
        XCTAssertTrue(PreviewAudioClassifier.isPreviewResponse([
            "code": 200,
            "data": [["url": "https://example.com/a.mp3",
                      "freeTrialInfo": ["start": 0, "end": 30000]]],
        ]))
        XCTAssertTrue(PreviewAudioClassifier.isPreviewResponse([
            "code": 0,
            "data": ["items": [["url": "https://example.com/a.mp3",
                                "freeTrialInfo": ["start": 0, "end": 30000]]]],
        ]))
        XCTAssertTrue(PreviewAudioClassifier.isPreviewResponse([
            "freeTrial": true, "url": "https://example.com/a.mp3",
        ]))
    }

    func testPreviewResponseNullFreeTrialInfoIsNotTrial() {
        XCTAssertFalse(PreviewAudioClassifier.isPreviewResponse([
            "code": 200,
            "data": [["url": "https://example.com/a.mp3",
                      "freeTrialInfo": NSNull()]],
        ]))
        XCTAssertFalse(PreviewAudioClassifier.isPreviewResponse([
            "code": 200, "url": "https://example.com/a.mp3",
        ]))
        XCTAssertFalse(PreviewAudioClassifier.isPreviewResponse([
            "code": 200, "url": "https://example.com/a.mp3",
            "freeTrial": false,
        ]))
    }

    // MARK: - URL patterns

    func testPreviewURLQQTrialFile() {
        XCTAssertTrue(PreviewAudioClassifier.isPreviewURL(
            "https://ws.stream.qqmusic.qq.com/RS0abc123.m4a?vkey=xyz"))
        XCTAssertTrue(PreviewAudioClassifier.isPreviewURL(
            "https://dl.stream.qqmusic.qq.com/rs0DEF456.mp3"))
        XCTAssertFalse(PreviewAudioClassifier.isPreviewURL(
            "https://ws.stream.qqmusic.qq.com/C400abc123.m4a?vkey=xyz"))
        // "RS0" inside a normal file id is not a trial marker —
        // only a filename STARTING with RS0 counts.
        XCTAssertFalse(PreviewAudioClassifier.isPreviewURL(
            "https://ws.stream.qqmusic.qq.com/C400xRS0y.m4a"))
    }

    func testPreviewURLNetEaseOuterURLNeedsTrialOnlyFlag() {
        let outer = "https://music.163.com/song/media/outer/url?id=123.mp3"
        XCTAssertTrue(PreviewAudioClassifier.isPreviewURL(outer, trialOnly: true))
        XCTAssertFalse(PreviewAudioClassifier.isPreviewURL(outer, trialOnly: false))
        XCTAssertFalse(PreviewAudioClassifier.isPreviewURL(
            "https://m8.music.126.net/abc.mp3", trialOnly: true))
    }

    func testPreviewURLInvalidURLIsNotPreview() {
        XCTAssertFalse(PreviewAudioClassifier.isPreviewURL("not a url"))
        XCTAssertFalse(PreviewAudioClassifier.isPreviewURL(""))
    }

    // MARK: - Asset duration backstop

    func testPreviewAssetStandardThirtySecondClip() {
        XCTAssertTrue(PreviewAudioClassifier.isPreviewAsset(
            actualDuration: 30, expectedDuration: 200, trialOnly: false))
        XCTAssertTrue(PreviewAudioClassifier.isPreviewAsset(
            actualDuration: 30.05, expectedDuration: 200, trialOnly: false))
    }

    func testPreviewAssetFullLengthIsNotPreview() {
        XCTAssertFalse(PreviewAudioClassifier.isPreviewAsset(
            actualDuration: 200, expectedDuration: 200, trialOnly: false))
        XCTAssertFalse(PreviewAudioClassifier.isPreviewAsset(
            actualDuration: 199, expectedDuration: 200, trialOnly: true))
    }

    func testPreviewAssetGenuinelyShortSongsNeverFlagged() {
        // Expected <= 60 s: a short song is short, not a preview.
        XCTAssertFalse(PreviewAudioClassifier.isPreviewAsset(
            actualDuration: 30, expectedDuration: 45, trialOnly: false))
        XCTAssertFalse(PreviewAudioClassifier.isPreviewAsset(
            actualDuration: 30, expectedDuration: 60, trialOnly: true))
    }

    func testPreviewAssetUnknownDurationNeverFlagged() {
        XCTAssertFalse(PreviewAudioClassifier.isPreviewAsset(
            actualDuration: 0, expectedDuration: 200, trialOnly: false))
        XCTAssertFalse(PreviewAudioClassifier.isPreviewAsset(
            actualDuration: .nan, expectedDuration: 200, trialOnly: false))
        XCTAssertFalse(PreviewAudioClassifier.isPreviewAsset(
            actualDuration: 30, expectedDuration: nil, trialOnly: false))
    }

    func testPreviewAssetSixtySecondTrialNeedsTrialOnlyFlag() {
        // Trial clips run 30–60 s: the looser bound applies only to
        // tracks the search payload already flagged paywalled.
        XCTAssertTrue(PreviewAudioClassifier.isPreviewAsset(
            actualDuration: 60, expectedDuration: 240, trialOnly: true))
        XCTAssertFalse(PreviewAudioClassifier.isPreviewAsset(
            actualDuration: 60, expectedDuration: 240, trialOnly: false))
        XCTAssertFalse(PreviewAudioClassifier.isPreviewAsset(
            actualDuration: 90, expectedDuration: 240, trialOnly: true))
    }

    func testPreviewAssetTruncatedFileIsRetriedToo() {
        // An asset at half the expected length or less is not the
        // real song, whatever the cause — the next source is tried.
        XCTAssertTrue(PreviewAudioClassifier.isPreviewAsset(
            actualDuration: 35, expectedDuration: 200, trialOnly: false))
        XCTAssertFalse(PreviewAudioClassifier.isPreviewAsset(
            actualDuration: 36, expectedDuration: 200, trialOnly: false))
    }

    // MARK: - Flag threading (defaults)

    func testMusicTrackTrialOnlyDefaultsToFalse() {
        let track = MusicTrack(id: "1", title: "T", artist: "A", sourceID: "wy")
        XCTAssertFalse(track.trialOnly)
    }

    func testPlaybackItemDurationAndTrialOnlyDefaults() {
        let item = PlaybackItem(id: "wy|1", kind: .music, title: "T", artist: "A")
        XCTAssertNil(item.duration)
        XCTAssertFalse(item.trialOnly)
    }
}

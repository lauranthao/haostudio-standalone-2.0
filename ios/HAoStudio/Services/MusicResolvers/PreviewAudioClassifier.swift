// PreviewAudioClassifier.swift
// 30-second trial/preview detection (build 36, item 3 — chen:
// "很多音乐也只能播放30秒").
//
// Root cause: NetEase and QQ return ~30 s trial clips for VIP/paid
// tracks to an unauthenticated client, and this app has NO login,
// so those tracks can never be unlocked that way. A trial URL used
// to count as a successful resolve: it loads and plays fine, ends
// after 30 s, and the player just advances — so chen hears 30 s of
// every paywalled song. A preview URL must NEVER count as success:
// it falls through to the next source exactly like a failed resolve.
//
// Three detection signals, all free — no extra network round-trip,
// no asset-duration probe on the fast path:
//
// 1. Resolver response flags (`isPreviewResponse`): NetEase
//    `/song/url/v1` marks a trial with a non-null `freeTrialInfo`
//    (Music Assistant and YesPlayMusic both reject the stream on
//    exactly this field); QQ and the LX APIs use the same key or an
//    explicit `freeTrial` / `isTrial` boolean. Checked at the
//    resolver before any URL is accepted.
// 2. URL patterns (`isPreviewURL`): QQ trial files are named with
//    an `RS0` prefix — the bundled stellarwave script already
//    checks `/RS0/i` on the vkey `purl`, and the purl IS the path
//    part of the final URL, so the last path component starting
//    with `RS0` is the same signal one step downstream. NetEase's
//    unauthenticated outer URL
//    (`music.163.com/song/media/outer/url`) serves a trial for VIP
//    songs and the full track for free ones, so it only counts as a
//    preview on a track already flagged trial-only at search time
//    (yuxi.js returns exactly this URL with no trial check).
//    NetEase CDN trial files themselves carry NO URL marker — that
//    is why signal 3 exists.
// 3. Asset duration (`isPreviewAsset`): the backstop for
//    aggregators that return a bare URL string with no metadata
//    (lzm / gd / wwwweb / the zddyr-xinghai LX APIs). The duration
//    comes from the AVURLAsset the player already loaded — zero
//    extra network, zero first-play latency: the check runs at load
//    time, before the engine plays, and again when the duration
//    first becomes known during playback. A trial clip is a small
//    fraction of the real song; the strict bound only fires when
//    the asset is <= 35 s AND under half the expected length, so a
//    genuinely short song (expected <= 60 s) can never be flagged.
//    A track flagged trial-only at search gets the looser bound
//    (<= 60 s, under 80% of expected) because trial clips run
//    30–60 s and a VIP-only track has no full-length source at
//    this platform without login. Either way a misread flag cannot
//    reject a full-length file: its duration ≈ the expected one.
//
// Search-time flag (`isTrialOnlyTrack`): NetEase cloudsearch
// carries `fee` (0 = free, anything else = VIP / paid album) and
// `privilege.dlLevel` / `plLevel` (`none` = no full playback for
// this client — the build-35 audit's fee:8 / dlLevel:none markers);
// QQ search carries `pay.payplay` (1 = pay-to-play). The flag only
// ever tightens detection; it never skips a source by itself.

import Foundation

enum PreviewAudioClassifier {
    // MARK: - Search-time trial-only flag

    /// True when the search metadata says this track is paywalled
    /// for a no-login client. Every argument is optional: a missing
    /// field simply does not flag (never guess from absence).
    /// - `fee`: NetEase song `fee` (0 = free; 1 = VIP, 4 = paid
    ///   album, 8 = VIP-only per the build-35 search audit).
    /// - `dlLevel` / `plLevel`: NetEase `privilege` levels;
    ///   `"none"` means no full playback/download at this client.
    /// - `payPlay`: QQ `pay.payplay` == 1 (pay-to-play).
    static func isTrialOnlyTrack(
        fee: Int?,
        dlLevel: String?,
        plLevel: String?,
        payPlay: Bool?
    ) -> Bool {
        if let fee = fee, fee != 0 { return true }
        let dl = dlLevel.flatMap { $0.isEmpty ? nil : $0 }
        let pl = plLevel.flatMap { $0.isEmpty ? nil : $0 }
        if dl == "none" || pl == "none" { return true }
        if payPlay == true { return true }
        return false
    }

    // MARK: - Resolver response flags

    /// True when a resolver's JSON response marks the returned audio
    /// as a trial. Looks at the top level, under `data` (dict or
    /// first list element), and under `data.items[0]` (oiapi's
    /// NetEase shape) — the trial marker rides next to the URL in
    /// every one of those shapes.
    static func isPreviewResponse(_ json: [String: Any]) -> Bool {
        for candidate in responseCandidates(json) {
            if isTrialMap(candidate) { return true }
        }
        return false
    }

    private static func responseCandidates(_ json: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = [json]
        if let data = json["data"] as? [String: Any] {
            out.append(data)
            if let items = data["items"] as? [Any],
               let first = items.first as? [String: Any] {
                out.append(first)
            }
        } else if let list = json["data"] as? [Any],
                  let first = list.first as? [String: Any] {
            out.append(first)
        }
        return out
    }

    /// One response object is a trial when it carries NetEase's
    /// `freeTrialInfo` (any non-null value — a present field means
    /// the URL is a trial clip) or an explicit trial boolean.
    /// `freeTrialPrivilege` is deliberately NOT a signal: it rides
    /// on the privilege object of playable tracks too.
    private static func isTrialMap(_ map: [String: Any]) -> Bool {
        if let value = map["freeTrialInfo"], !(value is NSNull) { return true }
        for key in ["freeTrial", "isTrial", "trial", "preview"] {
            if let flag = map[key] as? NSNumber, flag.boolValue { return true }
        }
        return false
    }

    // MARK: - URL patterns

    /// True when the URL itself is a trial file. No network, no
    /// asset probe — pure string classification, safe on the fast
    /// path.
    /// - QQ trial: the vkey `purl` starts with `RS0` (bundled
    ///   stellarwave.js checks `/RS0/i` on the purl); the purl is
    ///   the path part of the final URL.
    /// - NetEase outer URL: trial-by-construction for VIP songs,
    ///   full-length for free ones — only a preview when the track
    ///   is already flagged trial-only at search time.
    static func isPreviewURL(_ urlString: String, trialOnly: Bool = false) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        if url.lastPathComponent.uppercased().hasPrefix("RS0") { return true }
        if trialOnly,
           url.host?.lowercased() == "music.163.com",
           url.path.contains("/song/media/outer/url") {
            return true
        }
        return false
    }

    // MARK: - Asset duration (post-load backstop)

    /// True when a loaded audio asset is a trial clip of the song
    /// it claims to be. `actualDuration` is the AVURLAsset duration
    /// (0 / NaN / infinite while still unknown — never a preview
    /// then); `expectedDuration` is the real song length from
    /// search metadata (nil for local files and restored queue
    /// items — never flagged without an expectation to compare
    /// against).
    static func isPreviewAsset(
        actualDuration: TimeInterval,
        expectedDuration: TimeInterval?,
        trialOnly: Bool = false
    ) -> Bool {
        guard let expected = expectedDuration, expected > 60,
              actualDuration > 0, actualDuration.isFinite else { return false }
        if trialOnly {
            return actualDuration <= 60 && actualDuration < expected * 0.8
        }
        return actualDuration <= 35 && actualDuration < expected * 0.5
    }
}

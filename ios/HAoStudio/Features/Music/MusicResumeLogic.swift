// HAo Studio 2.0 — music auto-resume checkpoints.
//
// Pure decision rules for the auto-resume POSITION feature
// (chen 2026-11-23: save every 10 s while playing + on entering
// background, local only — the same cadence Netflix/YouTube use).
//
// Why periodic instead of "only when killed": iOS has no reliable
// kill callback. A backgrounded app is suspended and can be killed
// with no code running at all; `applicationWillTerminate` only
// fires when the app is still actively running in the background.
// So the checkpoint is written while the app is alive: every
// 10 s of playback, on pause, and on entering background. The
// loss on kill is at most ~10 s of progress.
//
// This type holds NO state and does NO I/O — the view model owns
// the clock and the store calls. Foundation-only, so it runs
// under `swift test` in AppCore (same pattern as SettingsLogic).

import Foundation

enum MusicResumeLogic {
    /// Periodic save cadence while playing.
    static let saveInterval: TimeInterval = 10

    /// A checkpoint must move at least this far from the last
    /// saved value to be worth rewriting the resume file.
    static let minMoveToRewriteSeconds: Int = 5

    /// Positions within this many seconds of the end count as
    /// finished, never as a resume point.
    static let endMarginSeconds: Double = 5

    /// Should the periodic saver write a checkpoint now?
    /// - `position`: current playback position in seconds.
    /// - `lastSavedAt` / `lastSavedKey` / `lastSavedSeconds`:
    ///   the last checkpoint actually written (nil = none yet).
    /// - `currentKey`: identityKey of the track now playing.
    ///
    /// The gate keeps writes light: at most one rewrite per
    /// 10 s, and only when the position has actually moved
    /// (a track change always counts as a move).
    static func shouldSaveCheckpoint(
        isPlaying: Bool,
        position: Double,
        now: Date,
        lastSavedAt: Date?,
        lastSavedKey: String?,
        lastSavedSeconds: Int,
        currentKey: String
    ) -> Bool {
        guard isPlaying, position >= 1 else { return false }
        if let lastSavedAt = lastSavedAt,
           now.timeIntervalSince(lastSavedAt) < saveInterval {
            return false
        }
        if lastSavedKey == currentKey,
           abs(Int(position) - lastSavedSeconds) < minMoveToRewriteSeconds {
            return false
        }
        return true
    }

    /// Should an explicit save (pause / entering background)
    /// write now? Same as the periodic gate but without the
    /// 10 s interval — the point is to capture the latest
    /// position before the app can be killed. An identical
    /// (key, seconds) checkpoint is still skipped.
    static func shouldSaveNow(
        position: Double,
        lastSavedKey: String?,
        lastSavedSeconds: Int,
        currentKey: String
    ) -> Bool {
        guard position >= 1 else { return false }
        if lastSavedKey == currentKey, Int(position) == lastSavedSeconds {
            return false
        }
        return true
    }

    /// Validate a stored resume position. Returns the seconds
    /// to seek to, or nil to start from 0.
    /// - `duration`: the known track length in seconds, or nil
    ///   when unknown. A position at/past the end (within the
    ///   end margin) is finished, not a resume point.
    static func validatedResumeSeconds(stored: Int, duration: Double?) -> Int? {
        guard stored > 0 else { return nil }
        if let duration = duration, duration > 0 {
            guard Double(stored) < duration - endMarginSeconds else { return nil }
        }
        return stored
    }

    /// The seconds a play request arms for the one-shot resume
    /// seek, from the `resumeFrom` it carries. Only the home
    /// "继续听" tap passes a value (the stored checkpoint);
    /// every other caller passes nil. A non-positive value arms
    /// nothing — 0 / negative means "from the start", never a
    /// seek to 0. The armed value is still re-validated against
    /// the loaded duration before the seek lands (see
    /// validatedResumeSeconds), so an over-long checkpoint
    /// (track replaced by a shorter version) never seeks.
    static func resumeSecondsToArm(requested: Double?) -> Int? {
        guard let requested = requested, requested > 0 else { return nil }
        return Int(requested)
    }
}

// MARK: - b45-F: confirmed quality badge (plan §9.2)
//
// Session-restore gap check (2026-11-25): the position
// checkpoint was persisted, but the quality badge was not —
// after a relaunch the badge was blank until the next resolve
// reported a tier. The badge is a "last confirmed value":
// persisted per track, decoupled from the engine and from any
// play URL (which is never cached). A track re-resolves its URL
// on play; the badge only fills the UI until the new tier lands.

enum ConfirmedQualityBadge {
    /// UserDefaults key: `[identityKey: qualityCode]`.
    static let defaultsKey = "hao_last_confirmed_quality"

    /// Persist the tier actually served for this track (call on
    /// every successful track start, with the resolver-reported
    /// tier — never the requested tier).
    static func save(
        identityKey: String,
        quality: AudioQuality,
        defaults: UserDefaults = .standard
    ) {
        guard !identityKey.isEmpty else { return }
        var map = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        map[identityKey] = quality.rawValue
        // Bounded: a stale badge for a track never played again
        // is harmless, but the map must not grow forever.
        if map.count > 500 {
            let sorted = map.keys.sorted()
            for key in sorted.prefix(map.count - 500) { map.removeValue(forKey: key) }
        }
        defaults.set(map, forKey: defaultsKey)
    }

    /// The last confirmed tier for this track, or nil when none
    /// was ever confirmed (badge stays blank until the first
    /// successful resolve).
    static func confirmedQuality(
        identityKey: String,
        defaults: UserDefaults = .standard
    ) -> AudioQuality? {
        guard !identityKey.isEmpty else { return nil }
        let map = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        guard let code = map[identityKey] else { return nil }
        return AudioQuality(rawValue: code)
    }

    /// Gap check for session restore: true when a badge survives
    /// a relaunch for this track.
    static func isPersisted(
        identityKey: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        confirmedQuality(identityKey: identityKey, defaults: defaults) != nil
    }
}

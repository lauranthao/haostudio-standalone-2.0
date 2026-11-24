// HAo Studio 2.0 — VOD playback-settings wiring (S7 wiring, leg A).
//
// Pure logic for the twelve 影视播放器 settings keys, so the
// behaviour layer and the tests share one reading of Flutter
// (origin/main `lib/core/player/vod_controls.dart`,
// `vod_features.dart`, `super_resolution.dart`,
// `kernel/player_kernel.dart`, `kernel/mpv_backend.dart`).
// Foundation only: this file compiles into AppCore and is covered
// by Tests/SettingsTests.
//
// Key-by-key Flutter semantics (verified against origin/main):
// - doubleTapSeconds: double-tap seek step, left third back /
//   right third forward / middle no seek, clamped to [0, duration].
// - skipIntroMode: off / manual / auto3s / autoNow. The window
//   comes from Emby chapter markers (introStart/introEnd) or the
//   per-episode custom seconds (CMS has no markers at all).
//   manual shows a pill in the window, auto3s shows the pill with
//   a 3 s countdown then seeks, autoNow seeks on the first
//   position event inside the window. Credits: manual shows a
//   pill, auto modes advance to the next episode. A resume landing
//   inside the window skips once in autoNow — correct behaviour.
// - subtitleFontSize/Color/Position: MPV-only tiers, applied as
//   mpv `sub-font-size` / `sub-color` / `sub-pos` at open and live
//   on the running player. AVPlayer/IJK have no such properties —
//   the backend capability check no-ops there, never a fake row.
// - superResolution/interpolation/sdrToHDR: mutually exclusive
//   trio, first-branch-wins (super-res → interpolation →
//   SDR→HDR). Only the first passing branch is ever applied, so a
//   phone GPU never runs two of them at once.
// - dvP8Downgrade: routing only — when on, Dolby Vision profile 8
//   in an Apple container is admitted to AVPlayer; when off, P8
//   goes to the ffmpeg kernels only. Profile 5 is NOT governed by
//   this switch (build 36, item 13): it has no HDR base layer, so
//   it is always admitted to AVPlayer in an Apple container —
//   the ffmpeg kernels render it green. It changes no MPV decode
//   parameter. The gate itself lives in VideoCapability
//   (`videoEngineCanPlayFacts`); this file owns nothing for it.
// - hideSynopsis/blurUnwatchedPosters: detail-page spoiler guards.
//   The synopsis is replaced by a placeholder until tapped (per
//   detail load, the reveal never persists); an unwatched title's
//   cover is blurred until tapped (watched titles are never
//   blurred).
// - audioOnlyBackground: background-only audio. The driver drops
//   to audio-only on background and restores video on foreground
//   when the switch is on; when off, VOD pauses on background
//   (Flutter `native_video_player_page.dart` lifecycle handler)
//   and stays paused on return — never surprise audio, never
//   background data burn.
//
// Swift 5.0: no async/await, no `any`.

import Foundation

// MARK: - Double-tap seek

/// Pure seek target for a double-tap: `forward` = right third of
/// the screen, else left third. Clamped to [0, duration]; a
/// zero/unknown duration seeks nowhere (returns the current
/// position). Flutter `resolveDoubleTapSeek` parity.
func resolveDoubleTapSeek(
    position: Double,
    duration: Double,
    forward: Bool,
    seconds: Double
) -> Double {
    if duration <= 0 { return position }
    let target = position + (forward ? seconds : -seconds)
    return min(max(0, target), duration)
}

// MARK: - Enhancement trio (super-res / interpolation / SDR→HDR)

/// Which trio branch is effective, in the same first-branch-wins
/// order as Flutter `resolveVodEnhancement` (super-res →
/// interpolation → SDR→HDR): at most one branch is ever on, and a
/// switch turned on while another is on cannot take effect until
/// the other is off.
enum VodEnhancementBranch: Equatable {
    case superResolution
    case interpolation
    case sdrToHdr
}

func resolveVodEnhancement(
    superResolution: Bool,
    interpolation: Bool,
    sdrToHdr: Bool
) -> VodEnhancementBranch? {
    if superResolution { return .superResolution }
    if interpolation { return .interpolation }
    if sdrToHdr { return .sdrToHdr }
    return nil
}

// MARK: - Subtitle appearance (MPV tiers)

/// Resolved mpv subtitle properties for one tier triple. Values
/// are Flutter's `vodSubtitleFontSizeValues` /
/// `vodSubtitleColorValues` / `vodSubtitlePositionValues`
/// verbatim (mpv defaults: size 55, white #FFFFFF, pos 100 =
/// bottom; 0 = top). An unknown tier reads as the default, never
/// a crash, never a guessed value.
struct VodSubtitleAppearance: Equatable {
    /// mpv `sub-font-size`.
    var fontSize: Int
    /// mpv `sub-color`, 6-digit #RRGGBB.
    var color: String
    /// mpv `sub-pos` (0 = top, 100 = bottom).
    var position: Double

    static let `default` = VodSubtitleAppearance(fontSize: 55, color: "#FFFFFF", position: 100.0)

    static func forTiers(fontSize fontSizeTier: String, color colorTier: String, position positionTier: String) -> VodSubtitleAppearance {
        let sizes: [String: Int] = [
            "small": 42,
            "medium": 55,
            "large": 70,
        ]
        let colors: [String: String] = [
            "white": "#FFFFFF",
            "yellow": "#FFFF00",
            "cyan": "#00FFFF",
        ]
        let positions: [String: Double] = [
            "bottom": 100.0,
            "middle": 50.0,
            "top": 8.0,
        ]
        return VodSubtitleAppearance(
            fontSize: sizes[fontSizeTier] ?? 55,
            color: colors[colorTier] ?? "#FFFFFF",
            position: positions[positionTier] ?? 100.0
        )
    }
}

// MARK: - Skip intro

/// Skip-intro mode, stored values verbatim from Flutter
/// (`_skipIntroOrder`). Unknown stored values read as `.off`.
enum VodSkipIntroMode: String {
    case off
    case manual
    case auto3s
    case autoNow

    static func fromStored(_ raw: String) -> VodSkipIntroMode {
        return VodSkipIntroMode(rawValue: raw) ?? .off
    }
}

/// One episode's intro window in seconds, or nil when there is
/// nothing to skip to. Effective end = the Emby `introEnd` marker
/// when present, else the per-episode custom seconds when > 0.
/// Effective start = the marker's `introStart` when present, else
/// 0. A marker end of 0 or a custom value of 0 means "no skip" —
/// never seek to 0. Flutter `resolveIntroWindow` parity.
struct VodSkipWindow: Equatable {
    var start: Double
    var end: Double
}

func resolveIntroWindow(
    introStart: Double?,
    introEnd: Double?,
    customSeconds: Int
) -> VodSkipWindow? {
    let end = introEnd ?? (customSeconds > 0 ? Double(customSeconds) : nil)
    guard let end = end, end > 0 else { return nil }
    let start = introStart ?? 0.0
    guard start < end else { return nil }
    return VodSkipWindow(start: start, end: end)
}

/// What the per-position skip check wants the player to do.
/// The view model turns these into a seek / pill / advance; this
/// type only decides, never seeks.
enum VodSkipAction: Equatable {
    /// Nothing to do (mode off, no window, outside the window).
    case none
    /// Show the "跳过片头" pill. `countdown` is the remaining
    /// auto3s seconds (nil = manual pill, no countdown).
    case showIntroPill(countdown: Int?)
    /// Seek to the end of the intro window now.
    case skipIntro(to: Double)
    /// Show the "跳过片尾" pill.
    case showCreditsPill
    /// Advance to the next episode (credits auto mode).
    case advanceNextEpisode
}

/// Mutable skip state for one episode. The view model owns one
/// and calls `check` on every position tick (0.5 s); the state
/// remembers whether the automatic skip already fired, so seeking
/// back into the window after an auto skip still shows the manual
/// pill but never auto-skips twice.
struct VodSkipIntroState {
    private var window: VodSkipWindow?
    private var creditsStart: Double?
    private var introAutoDone = false
    private var creditsDone = false
    /// Remaining auto3s countdown in seconds, while counting.
    private var countdownRemaining: Double?

    /// Reset for a new episode (or a line switch to the same
    /// episode on another line — the window is per episode).
    mutating func resetForEpisode(window: VodSkipWindow?, creditsStart: Double?) {
        self.window = window
        self.creditsStart = creditsStart
        introAutoDone = false
        creditsDone = false
        countdownRemaining = nil
    }

    /// One position tick. `elapsed` is the seconds since the last
    /// tick (the player polls every 0.5 s). Automatic actions
    /// (auto skip / auto advance) only fire while `isPlaying` —
    /// a paused player shows the pill but never seeks on its own.
    mutating func check(
        position: Double,
        duration: Double,
        mode: VodSkipIntroMode,
        isPlaying: Bool,
        elapsed: Double
    ) -> VodSkipAction {
        if mode == .off {
            countdownRemaining = nil
            return .none
        }
        if let action = checkCredits(position: position, duration: duration, mode: mode, isPlaying: isPlaying) {
            return action
        }
        return checkIntro(position: position, mode: mode, isPlaying: isPlaying, elapsed: elapsed)
    }

    private mutating func checkIntro(
        position: Double,
        mode: VodSkipIntroMode,
        isPlaying: Bool,
        elapsed: Double
    ) -> VodSkipAction {
        guard let window = window else {
            countdownRemaining = nil
            return .none
        }
        let inWindow = position >= window.start && position < window.end
        if !inWindow {
            countdownRemaining = nil
            return .none
        }
        switch mode {
        case .off:
            return .none
        case .manual:
            return .showIntroPill(countdown: nil)
        case .autoNow:
            if introAutoDone { return .showIntroPill(countdown: nil) }
            if !isPlaying { return .showIntroPill(countdown: nil) }
            introAutoDone = true
            countdownRemaining = nil
            return .skipIntro(to: window.end)
        case .auto3s:
            if introAutoDone { return .showIntroPill(countdown: nil) }
            if !isPlaying { return .showIntroPill(countdown: nil) }
            if countdownRemaining == nil { countdownRemaining = 3.0 }
            countdownRemaining = (countdownRemaining ?? 3.0) - elapsed
            let left = Int(ceil(countdownRemaining ?? 0))
            if (countdownRemaining ?? 0) <= 0 {
                introAutoDone = true
                countdownRemaining = nil
                return .skipIntro(to: window.end)
            }
            return .showIntroPill(countdown: max(1, left))
        }
    }

    private mutating func checkCredits(
        position: Double,
        duration: Double,
        mode: VodSkipIntroMode,
        isPlaying: Bool
    ) -> VodSkipAction? {
        guard let credits = creditsStart, !creditsDone else { return nil }
        // A credits marker at/after (duration - 5 s) is not a
        // usable trigger — the episode is effectively over already.
        if duration <= 0 || credits >= duration - 5 { return nil }
        if position < credits { return nil }
        switch mode {
        case .off:
            return nil
        case .manual:
            return .showCreditsPill
        case .auto3s, .autoNow:
            if !isPlaying { return .showCreditsPill }
            creditsDone = true
            return .advanceNextEpisode
        }
    }
}

// MARK: - Per-episode custom intro seconds (CMS)

/// The per-episode custom intro-seconds map
/// (`hao_vod_skip_intro_durations`, migrated as a collection
/// file). Key = normalised series title + episode name, exactly
/// like Flutter `skipIntroDurationKey`. There is no Swift writer
/// yet — no UI sets a custom duration — so a missing file reads
/// as empty, never a throw.
enum VodSkipIntroDurations {
    static let collectionName = "hao_vod_skip_intro_durations"

    static func key(title: String, episodeName: String) -> String {
        return "\(videoNormTitle(title))|\(episodeName)"
    }

    static func readAll(documentsDirectory: URL? = nil) -> [String: Int] {
        if let dir = documentsDirectory {
            let url = dir.appendingPathComponent("\(collectionName).json")
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else {
                return [:]
            }
            return decoded
        }
        return LocalStore.loadCollection(named: collectionName, default: [String: Int]())
    }

    /// Custom intro seconds for one episode (0 = none set).
    /// Values are clamped to 0...300 on read.
    static func customSeconds(
        title: String,
        episodeName: String,
        documentsDirectory: URL? = nil
    ) -> Int {
        let raw = readAll(documentsDirectory: documentsDirectory)[key(title: title, episodeName: episodeName)] ?? 0
        return min(300, max(0, raw))
    }
}

// MARK: - Spoiler guards

/// True when the detail page hides the synopsis behind its
/// placeholder (per detail load; the reveal never persists).
func spoilerSynopsisHidden(hideSynopsis: Bool, revealed: Bool) -> Bool {
    return hideSynopsis && !revealed
}

/// True when the detail cover stays blurred (unwatched titles
/// only — watched titles are never blurred — until tapped).
func spoilerCoverBlurred(blurUnwatched: Bool, watched: Bool, revealed: Bool) -> Bool {
    return blurUnwatched && !watched && !revealed
}

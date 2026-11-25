// HAo Studio 2.0 — native music player, leg A of S2.
//
// AVPlayer only. Music never follows the video/live kernel selector.
// A/B dual engines with 2.5 s crossfade on automatic advance only;
// manual next/previous has no crossfade. Five play modes, speed
// 0.6-2.0, 10 s open timeout, seek with read-back verification,
// position watchdog (4 s warn / 12 s fail), generation-guarded
// crossfade, 10-band EQ, Now Playing, AirPlay picker.
//
// Baseline (read, not copied): Flutter build 31
// (music_player_controller.dart, play_mode.dart, equalizer_store.dart,
// volume_fader.dart) and old Swift NativeMusicPlayer.swift (463 lines,
// AVPlayer core + Now Playing reusable; its web coupling and web
// callbacks are NOT carried over — this player has no web view).
//
// Design notes the coordinator needs to know:
// - Speed range is 0.6-2.0 per this brief and HiveKeys (musicSpeed
//   "double 0.6..2.0"). Flutter build 29 widened the slider clamp to
//   0.5-2.0 in clampSpeed; minSpeed was 0.5 here too (A12, build 35)
//   and is now 0.6, matching the VM clamp, the store and the menu.
// - Watchdog thresholds are 4 s warn / 12 s fail per P0-06. Flutter
//   build 30/31 uses 10 s load / 15 s mid-play; flagged in handoff.
// - AVPlayer has no API to insert an AVAudioUnitEQ node into its
//   pipeline. The EQ node below owns the 10-band state (frequencies,
//   gains, bypass); the identical RBJ biquad curve is applied to the
//   AVPlayerItem audio through an MTAudioProcessingTap whose
//   coefficients are snapshotted at item creation. The tap never
//   holds a lock while processing samples: it grabs the snapshot
//   reference once, then runs lock-free.
// - Loudness is measured in the tap and attributed by the identity
//   key snapshotted into the tap at item creation, never by a
//   global. Measurement runs only while the EQ is enabled, matching
//   Flutter ("normalisation needs the EQ on to measure loudness").
// - No Live Activities anywhere here. Now Playing (lock screen /
//   Control Center / Dynamic Island media card) is a different
//   thing and is implemented; tapping the card does not open the app.
// - Swift 5.0: completion handlers only, no async/await, no `any`.
//   JSON never goes through JSONSerialization with a top-level
//   String (NSException crash); the loudness cache uses JSONEncoder.

import Foundation
import AVFoundation
import MediaPlayer
import MediaToolbox
import AVKit
import SwiftUI
import UIKit

// MARK: - Play modes

/// The five music play modes, verified against Flutter build 31
/// (services/music/play_mode.dart): sequential, list loop, single
/// loop, shuffle, single play. Stored codes are the Hive `playMode`
/// codes (seq / loop / one / shuffle / once); unknown codes read back
/// as sequential, never crash. Cycle order for the mode button:
/// sequential -> list loop -> single loop -> shuffle -> single play.
enum MusicPlayMode: String, CaseIterable {
    case sequential
    case listLoop
    case singleLoop
    case shuffle
    case single

    var code: String {
        switch self {
        case .sequential: return "seq"
        case .listLoop: return "loop"
        case .singleLoop: return "one"
        case .shuffle: return "shuffle"
        case .single: return "once"
        }
    }

    var label: String {
        switch self {
        case .sequential: return "顺序播放"
        case .listLoop: return "列表循环"
        case .singleLoop: return "单曲循环"
        case .shuffle: return "随机播放"
        case .single: return "单曲播放"
        }
    }

    var next: MusicPlayMode {
        let order = MusicPlayMode.allCases
        guard let i = order.firstIndex(of: self) else { return .sequential }
        return order[(i + 1) % order.count]
    }

    static func fromCode(_ code: String?) -> MusicPlayMode {
        switch code {
        case "loop": return .listLoop
        case "one": return .singleLoop
        case "shuffle": return .shuffle
        case "once": return .single
        default: return .sequential
        }
    }
}

/// Pure queue math, ported from Flutter play_mode.dart.
/// Returns the next index, or -1 when playback must STOP (end of
/// queue in a non-looping mode). `auto` is true for automatic advance
/// on track completion, false for an explicit user tap on next:
/// single loop replays on auto but advances on manual tap; single
/// play stops on auto but still advances on manual tap.
func musicNextTrackIndex(
    mode: MusicPlayMode,
    current: Int,
    length: Int,
    auto: Bool,
    randomIndex: (() -> Int)? = nil
) -> Int {
    guard length > 0, current >= 0, current < length else { return -1 }
    switch mode {
    case .sequential:
        return current + 1 < length ? current + 1 : -1
    case .listLoop:
        return (current + 1) % length
    case .singleLoop:
        if auto { return current }
        return (current + 1) % length
    case .shuffle:
        if length == 1 { return current }
        let pick = randomIndex ?? { Int.random(in: 0..<length) }
        // B1: bounded retries — a degenerate random source that
        // always returns the current index used to spin forever.
        // Fall back to the next index after `length` tries.
        for _ in 0..<length {
            let n = pick()
            if n != current { return n }
        }
        return (current + 1) % length
    case .single:
        if auto { return -1 }
        return current + 1 < length ? current + 1 : -1
    }
}

/// Previous-track index. Manual only (there is no auto-previous).
/// Shuffle picks a random other track. Loop modes wrap at the start;
/// sequential and single play stop at the first track.
func musicPrevTrackIndex(
    mode: MusicPlayMode,
    current: Int,
    length: Int,
    randomIndex: (() -> Int)? = nil
) -> Int {
    guard length > 0, current >= 0, current < length else { return -1 }
    if mode == .shuffle {
        if length == 1 { return current }
        let pick = randomIndex ?? { Int.random(in: 0..<length) }
        // B1: bounded retries — same degenerate-source guard as
        // musicNextTrackIndex above.
        for _ in 0..<length {
            let n = pick()
            if n != current { return n }
        }
        // b41: this used to fall back to the NEXT track
        // ((current + 1) % length) — a copy-paste from
        // musicNextTrackIndex. A previous-step fallback must fall
        // back to the previous track, as MusicQueue.swift does.
        return (current - 1 + length) % length
    }
    switch mode {
    case .sequential, .single:
        return current == 0 ? -1 : current - 1
    case .listLoop, .singleLoop:
        return (current - 1 + length) % length
    case .shuffle:
        // Unreachable: shuffle returns above. Exhaustiveness only.
        return current
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Position has not moved for 4 s. userInfo: the current track id
    /// under MusicNotificationKeys.trackId. Warning only; playback
    /// continues and `isPlaying` is still true.
    static let haoMusicStallWarning = Notification.Name("haoMusicStallWarning")
    /// Position has not moved for 12 s. Playback is treated as
    /// failed: `isPlaying` is false by the time this posts.
    static let haoMusicStallFailed = Notification.Name("haoMusicStallFailed")
    /// A seek did not land. userInfo: the actual position under
    /// MusicNotificationKeys.actualPosition, so the UI can roll the
    /// progress bar back and show a toast.
    static let haoMusicSeekFailed = Notification.Name("haoMusicSeekFailed")
    /// The recent-plays list changed (a song started playing, or
    /// the list was cleared). The music home view model reloads
    /// on this: without it 最近播放 only refreshed when the tab
    /// re-appeared, not while the user stayed on it.
    static let haoMusicRecentChanged = Notification.Name("haoMusicRecentChanged")
    /// The favourites list changed (a song was favourited or
    /// unfavourited from any row, card, or the full player).
    /// Rows, the player view model (current-song star) and the
    /// favourites view reload on this, so the star never goes
    /// stale while the song is playing.
    static let haoMusicFavChanged = Notification.Name("haoMusicFavChanged")
    /// A user playlist was deleted (A3). 我的's 歌单 count reloads
    /// on this; the pushed playlist list refreshes itself locally,
    /// but the count on 我的 only refreshed on re-appear before.
    static let haoMusicPlaylistChanged = Notification.Name("haoMusicPlaylistChanged")
    /// A downloaded song was removed (A3). 我的's 我的下载 count
    /// reloads on this — same staleness as the playlist count.
    static let haoMusicDownloadChanged = Notification.Name("haoMusicDownloadChanged")
    /// The Emby server config changed (saved or cleared in
    /// Settings). Posters are keyed by clean image URL, so a new
    /// server's posters must not reuse the old server's cached
    /// images; the video driver also ends any open reporter
    /// session, which was built from the old config.
    static let haoEmbyConfigChanged = Notification.Name("haoEmbyConfigChanged")
}

enum MusicNotificationKeys {
    static let trackId = "trackId"
    static let actualPosition = "actualPosition"
}

// MARK: - Equalizer

/// EQ settings (P0-19). Gains are 10 bands, dB, normalised to
/// 0.5 dB steps within +-12. `presetName` is the display label
/// (built-in preset id, custom preset name, or nil for hand-tuned).
struct EqualizerSettings: Equatable {
    var enabled: Bool
    var gains: [Double]
    var presetName: String?
    var preamp: Double = 0

    static let flat = EqualizerSettings(enabled: false, gains: [Double](repeating: 0, count: 10), presetName: "flat", preamp: 0)

    var normalized: EqualizerSettings {
        var copy = self
        copy.gains = EqualizerPreset.normalizeGains(gains)
        copy.preamp = EqualizerPreset.normalizeGain(preamp)
        return copy
    }
}

/// Built-in EQ presets. Gains copied 1:1 from Beans
/// (BeansEqualizer.swift) via Flutter build 31 equalizer_store.dart.
/// Band frequencies: 31, 62, 125, 250, 500, 1000, 2000, 4000, 8000,
/// 16000 Hz. Maximum gain 12 dB.
enum EqualizerPreset: String, CaseIterable {
    case flat
    case bass
    case vocal
    case pop
    case rock
    case classical
    case jazz
    case electronic

    var displayName: String {
        switch self {
        case .flat: return "默认"
        case .bass: return "低音增强"
        case .vocal: return "人声"
        case .pop: return "流行"
        case .rock: return "摇滚"
        case .classical: return "古典"
        case .jazz: return "爵士"
        case .electronic: return "电子"
        }
    }

    var gains: [Double] {
        switch self {
        case .flat: return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bass: return [6, 5, 3, 1, 0, 0, -1, -1, 0, 0]
        case .vocal: return [-2, -1, 0, 2, 4, 4, 3, 2, 0, -1]
        case .pop: return [2, 2, 1, 0, 2, 3, 2, 1, 2, 2]
        case .rock: return [5, 4, 2, -1, -2, 1, 3, 4, 5, 4]
        case .classical: return [3, 2, 1, 0, 0, 1, 2, 3, 4, 4]
        case .jazz: return [3, 2, 1, 2, -1, -1, 0, 2, 3, 3]
        case .electronic: return [5, 4, 1, -2, -1, 2, 4, 3, 5, 4]
        }
    }

    static func fromId(_ id: String?) -> EqualizerPreset {
        switch id {
        case "bass": return .bass
        case "vocal": return .vocal
        case "pop": return .pop
        case "rock": return .rock
        case "classical": return .classical
        case "jazz": return .jazz
        case "electronic": return .electronic
        default: return .flat
        }
    }

    static let bandFrequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let maximumGain: Double = 12

    /// Beans normalizedGain: clamp +-12, round to 0.5 dB.
    static func normalizeGain(_ value: Double) -> Double {
        let clamped = min(maximumGain, max(-maximumGain, value))
        return (clamped * 2).rounded() / 2
    }

    /// Beans normalizedGains: pad short lists with 0, normalise each.
    static func normalizeGains(_ values: [Double]) -> [Double] {
        return (0..<10).map { i in
            i < values.count ? normalizeGain(values[i]) : 0
        }
    }
}

/// Volume normalisation gain math, ported from Flutter build 31
/// (music_player_controller.dart). Target -14 LUFS; louder tracks
/// are attenuated towards it, quieter tracks are never boosted.
/// Max cut per strength level: 0 light 3 dB, 1 standard 6 dB,
/// 2 strong 12 dB. Applies from the next load, never mid-song.
enum MusicNormalization {
    static let targetLufs: Double = -14.0
    static let maxCutDb: [Double] = [3.0, 6.0, 12.0]

    static func gainLinear(lufs: Double, strength: Int) -> Double {
        guard lufs.isFinite else { return 1.0 }
        let maxCut = maxCutDb[min(max(strength, 0), 2)]
        let db = min(0.0, max(-maxCut, targetLufs - lufs))
        return pow(10.0, db / 20.0)
    }

    /// Parse the persisted loudness cache (identityKey to LUFS).
    /// Junk is dropped, not trusted: empty keys, non-finite values
    /// and values outside -70...0 are skipped; capped at 200 entries.
    static func parseLoudnessCache(_ raw: [String: Double]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (key, value) in raw {
            guard !key.isEmpty, value.isFinite else { continue }
            out[key] = min(0.0, max(-70.0, value))
        }
        while out.count > 200 { out.removeValue(forKey: out.keys.first!) }
        return out
    }

    /// LUFS estimate from accumulated mean square. The tap measures
    /// plain RMS; the -0.691 offset is the BS.1770 K-weighting
    /// reference-level correction, not a gated loudness measurement.
    /// Good enough to drive the attenuation-only gain above; it is
    /// never presented to the user as a precise measurement.
    static func lufsFromMeanSquare(_ meanSquare: Double) -> Double? {
        guard meanSquare > 0, meanSquare.isFinite else { return nil }
        return min(0.0, max(-70.0, 10.0 * log10(meanSquare) - 0.691))
    }
}

// MARK: - Stall watchdog

/// Position watchdog (P0-06). Pure logic with an injectable clock so
/// tests never wait real seconds. The player ticks it every 0.5 s
/// with the visible position/duration: any movement restarts the
/// clock. Warns once per stall episode at 4 s, fails at 12 s.
/// A track frozen at its own end (missed completion event) reports
/// `.atEnd` instead of `.failed`, so the player advances instead of
/// treating it as a failure.
final class MusicStallWatchdog {
    enum Event: Equatable {
        case none
        case warn
        case failed
        case atEnd
    }

    static let warnAfter: TimeInterval = 4
    static let failAfter: TimeInterval = 12

    /// Injectable clock. Production uses the wall clock; tests drive it.
    var now: () -> Date = { Date() }

    private var lastProgressAt: Date?
    private var lastPosition: TimeInterval = 0
    private var lastDuration: TimeInterval = 0
    private var progressSeen = false
    private var warned = false

    func resetForNewTrack() {
        lastProgressAt = now()
        lastPosition = 0
        lastDuration = 0
        progressSeen = false
        warned = false
    }

    func noteBaseline() {
        lastProgressAt = now()
    }

    func tick(position: TimeInterval, duration: TimeInterval, isPlaying: Bool) -> Event {
        if position != lastPosition || duration != lastDuration {
            lastPosition = position
            lastDuration = duration
            lastProgressAt = now()
            if position > 0 || duration > 0 { progressSeen = true }
            warned = false
            return .none
        }
        guard isPlaying, let since = lastProgressAt else { return .none }
        let stalledFor = now().timeIntervalSince(since)
        if stalledFor >= MusicStallWatchdog.failAfter {
            lastProgressAt = nil
            if duration > 0 && position >= duration {
                return .atEnd
            }
            return .failed
        }
        if stalledFor >= MusicStallWatchdog.warnAfter && !warned {
            warned = true
            return .warn
        }
        return .none
    }
}

// MARK: - Player engine

/// The thin seam between NativeMusicPlayer and AVPlayer. The real
/// engine is AVPlayerEngine below; tests inject a fake through the
/// player's `makeEngine` factory. Only the operations the player
/// actually needs are exposed, so a fake stays faithful.
protocol MusicPlayerEngine: AnyObject {
    /// True only while audio is really sounding (real engine: AVPlayer
    /// timeControlStatus is .playing). Never the requested state.
    var isPlaying: Bool { get }
    var rate: Float { get set }
    var volume: Float { get set }
    var currentTimeSeconds: Double { get }
    var durationSeconds: Double { get }
    var hasItem: Bool { get }
    var equalizer: MusicEqualizer? { get set }
    /// Fired when the current item plays to its end.
    var onEnded: (() -> Void)? { get set }
    /// Fired when the current item fails to play to its end.
    var onFailed: (() -> Void)? { get set }
    /// Fired about every 0.5 s while an item is loaded.
    var onTimeUpdate: ((Double, Double) -> Void)? { get set }

    /// Load a URL and call completion exactly once: true when the
    /// item is ready to play, false when it failed before starting.
    /// `identityKey` stamps the item for EQ loudness attribution.
    func load(url: URL, headers: [String: String]?, identityKey: String, completion: @escaping (Bool) -> Void)
    func play()
    func pause()
    func seek(to seconds: Double, completion: @escaping (Bool) -> Void)
    func unload()
}

/// AVPlayer-backed engine. Owns one AVPlayer, its item observations
/// and its periodic time observer. Load failure is reported through
/// the completion, never swallowed: a load that never becomes ready
/// is the player's 10 s timeout's job, not this engine's.
final class AVPlayerEngine: MusicPlayerEngine {
    private let player = AVPlayer()
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var loadCompletion: ((Bool) -> Void)?
    private var currentIdentityKey = ""
    /// URL of the loaded item (nil after unload): the seek
    /// tolerance depends on it (exact for files, lenient for
    /// network streams — see seekTolerance(for:)).
    private var currentURL: URL?

    var equalizer: MusicEqualizer?

    var isPlaying: Bool {
        player.timeControlStatus == .playing
    }

    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var currentTimeSeconds: Double {
        let t = CMTimeGetSeconds(player.currentTime())
        return t.isFinite ? t : 0
    }

    var durationSeconds: Double {
        guard let item = player.currentItem else { return 0 }
        let d = CMTimeGetSeconds(item.duration)
        return d.isFinite ? d : 0
    }

    var hasItem: Bool { player.currentItem != nil }

    var onEnded: (() -> Void)?
    var onFailed: (() -> Void)?
    var onTimeUpdate: ((Double, Double) -> Void)?

    init() {
        startTimeObserver()
    }

    deinit {
        if let t = timeObserver { player.removeTimeObserver(t) }
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        if let o = failObserver { NotificationCenter.default.removeObserver(o) }
        statusObservation?.invalidate()
    }

    func load(url: URL, headers: [String: String]?, identityKey: String, completion: @escaping (Bool) -> Void) {
        finishLoad(false)
        currentIdentityKey = identityKey
        currentURL = url
        let asset: AVURLAsset
        if let headers = headers, !headers.isEmpty {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        } else {
            asset = AVURLAsset(url: url)
        }
        let item = AVPlayerItem(asset: asset)
        if let eq = equalizer, eq.settings.enabled {
            item.audioMix = eq.makeAudioMix(identityKey: identityKey)
        }
        loadCompletion = completion
        observeEnd(of: item)
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self = self else { return }
            switch item.status {
            case .readyToPlay:
                self.finishLoad(true)
            case .failed:
                self.finishLoad(false)
            default:
                break
            }
        }
        player.replaceCurrentItem(with: item)
    }

    private func finishLoad(_ ok: Bool) {
        guard let completion = loadCompletion else { return }
        loadCompletion = nil
        statusObservation?.invalidate()
        statusObservation = nil
        completion(ok)
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func seek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let tol = Self.seekTolerance(for: currentURL)
        player.seek(to: target, toleranceBefore: tol, toleranceAfter: tol) { finished in
            completion(finished)
        }
    }

    /// Seek tolerance for a URL. Exact (.zero) for local files
    /// (cheap, sample-accurate); lenient (0.5 s) for network
    /// streams. An exact seek on a progressive-download stream
    /// forces the player to fetch and decode to the exact sample;
    /// on a slow link the seek stalls past the watchdog's 12 s
    /// fail line and the track is reopened at the pre-seek
    /// position — the build-30 "drag seek doesn't load". 0.5 s
    /// snaps to the nearest sync frame without re-buffering and
    /// still lands inside the 2 s read-back window.
    static func seekTolerance(for url: URL?) -> CMTime {
        if url?.isFileURL == true { return .zero }
        return CMTime(seconds: 0.5, preferredTimescale: 600)
    }

    func unload() {
        finishLoad(false)
        currentURL = nil
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        if let o = failObserver { NotificationCenter.default.removeObserver(o); failObserver = nil }
        player.replaceCurrentItem(with: nil)
    }

    /// Re-attach or detach the EQ tap on the currently loaded item
    /// (A5): flipping the EQ switch mid-song must take effect on
    /// this song, not only the next one. Enabling builds a fresh
    /// tap from the current settings; disabling removes the mix so
    /// the old curve stops running. No-op with no item loaded.
    func refreshAudioMix() {
        guard let item = player.currentItem else { return }
        if let eq = equalizer, eq.settings.enabled {
            item.audioMix = eq.makeAudioMix(identityKey: currentIdentityKey)
        } else {
            item.audioMix = nil
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        if let o = failObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in self?.onEnded?() }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in self?.onFailed?() }
    }

    private func startTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.onTimeUpdate?(self.currentTimeSeconds, self.durationSeconds)
        }
    }
}

// MARK: - Equalizer engine

/// One biquad section (RBJ peaking filter), Direct Form II
/// transposed. Coefficients are computed from band gain/frequency
/// on a non-realtime thread; the realtime path only runs the loop.
struct EqualizerBiquad {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double
    var z1: Double = 0
    var z2: Double = 0

    /// RBJ peaking EQ, Q fixed at 1.0 (Beans behaviour: one Q for
    /// all bands). Sample rate is the tap's actual rate, passed in
    /// at snapshot build time, never assumed.
    static func peaking(frequency: Double, gainDb: Double, sampleRate: Double) -> EqualizerBiquad {
        let a = pow(10.0, gainDb / 40.0)
        let w0 = 2.0 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / 2.0
        let cosW0 = cos(w0)
        let b0 = 1.0 + alpha * a
        let b1 = -2.0 * cosW0
        let b2 = 1.0 - alpha * a
        let a0 = 1.0 + alpha / a
        let a1 = -2.0 * cosW0
        let a2 = 1.0 - alpha / a
        return EqualizerBiquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    mutating func process(_ input: Float) -> Float {
        let x = Double(input)
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return Float(y)
    }
}

/// Immutable coefficient snapshot for the realtime tap. Built from
/// the current settings whenever settings change or a tap is
/// prepared (never on the realtime thread); the tap grabs this
/// reference once per process call and then runs lock-free.
/// `identityKey` is the track the tap belongs to, snapshotted at
/// item creation, so loudness can never be attributed to the wrong
/// song. `revision` lets the tap notice a settings change and
/// rebuild its filters without any lock held across the sample loop.
struct EqualizerSnapshot {
    let bands: [EqualizerBiquad]
    let preampLinear: Double
    let identityKey: String
    let revision: Int
    let sampleRate: Double
}

/// 10-band EQ engine (P0-19).
///
/// The AVAudioUnitEQ node owns the band state: frequencies, gains
/// and bypass, configured exactly like Beans. AVPlayer exposes no
/// API to insert that node into its pipeline, so the same curve is
/// applied through an MTAudioProcessingTap on the AVPlayerItem: the
/// tap reads a snapshot built from these same settings at item
/// creation time. Loudness is measured in the tap and reported with
/// the snapshotted identity key, so a crossfade overlap can never
/// attribute one track's loudness to the other. The tap holds its
/// lock only to grab the snapshot reference, never while processing
/// samples.
final class MusicEqualizer {
    /// The 10-band node: the single source of truth for band
    /// parameters. `applyEqualizer` keeps it in sync with settings.
    let node: AVAudioUnitEQ

    private(set) var settings: EqualizerSettings
    private let defaults: UserDefaults
    /// Called on the main queue when a tap finalizes a track's
    /// loudness: (identityKey, LUFS). The player routes it to the
    /// loudness cache; reports for a stale key are stored under that
    /// key, never applied to the current track.
    var onLoudnessMeasured: ((String, Double) -> Void)?

    /// Bumped on every applyEqualizer. The tap compares its own
    /// revision against this to pick up live gain changes.
    private(set) var revision: Int = 0
    private var snapshotLock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.node = AVAudioUnitEQ(numberOfBands: 10)
        self.settings = MusicEqualizer.loadSettings(defaults: defaults)
        syncNode()
    }

    // MARK: Persistence (keys per docs/storage-mapping.md)

    static func loadSettings(defaults: UserDefaults) -> EqualizerSettings {
        let enabled = defaults.bool(forKey: "hao_eq_enabled")
        let rawGains = defaults.array(forKey: "hao_eq_band_gains") as? [Double] ?? []
        let gains = EqualizerPreset.normalizeGains(rawGains)
        let preset = defaults.string(forKey: "hao_eq_preset") ?? "flat"
        let customName = defaults.string(forKey: "hao_eq_custom_name") ?? ""
        let preamp = EqualizerPreset.normalizeGain(defaults.double(forKey: "hao_eq_preamp"))
        let name: String? = customName.isEmpty ? preset : customName
        return EqualizerSettings(enabled: enabled, gains: gains, presetName: name, preamp: preamp).normalized
    }

    private func persist() {
        defaults.set(settings.enabled, forKey: "hao_eq_enabled")
        defaults.set(settings.gains, forKey: "hao_eq_band_gains")
        defaults.set(settings.presetName ?? "flat", forKey: "hao_eq_preset")
        defaults.set(settings.preamp, forKey: "hao_eq_preamp")
    }

    /// Apply new settings: update the AVAudioUnitEQ node, persist,
    /// and bump the revision so live taps rebuild their filters.
    /// Never called from the realtime thread.
    func applyEqualizer(_ newSettings: EqualizerSettings) {
        settings = newSettings.normalized
        syncNode()
        persist()
        snapshotLock.lock()
        revision += 1
        snapshotLock.unlock()
    }

    /// Apply one of the Beans built-in presets (preamp reset to 0,
    /// matching Flutter applyPreset).
    func applyPreset(_ preset: EqualizerPreset) {
        applyEqualizer(EqualizerSettings(enabled: settings.enabled, gains: preset.gains, presetName: preset.rawValue, preamp: 0))
    }

    private func syncNode() {
        for (i, band) in node.bands.enumerated() {
            guard i < EqualizerPreset.bandFrequencies.count else { break }
            band.frequency = Float(EqualizerPreset.bandFrequencies[i])
            band.gain = Float(i < settings.gains.count ? settings.gains[i] : 0)
            band.bypass = !settings.enabled
            band.filterType = .parametric
        }
        node.globalGain = Float(settings.preamp)
        node.bypass = !settings.enabled
    }

    /// Build a fresh coefficient snapshot from the current settings.
    /// Called on a non-realtime thread (tap prepare, live settings
    /// change); the realtime path never rebuilds coefficients.
    /// The lock is held only to copy the settings value.
    func snapshot(sampleRate: Double, identityKey: String) -> EqualizerSnapshot {
        snapshotLock.lock()
        let current = settings
        let rev = revision
        snapshotLock.unlock()
        let bands = (0..<10).map { i in
            EqualizerBiquad.peaking(
                frequency: EqualizerPreset.bandFrequencies[i],
                gainDb: i < current.gains.count ? current.gains[i] : 0,
                sampleRate: sampleRate
            )
        }
        return EqualizerSnapshot(
            bands: bands,
            preampLinear: pow(10.0, current.preamp / 20.0),
            identityKey: identityKey,
            revision: rev,
            sampleRate: sampleRate
        )
    }

    // MARK: Tap

    /// The tap's per-instance state. One context per AVPlayerItem,
    /// created in makeAudioMix, retained by the tap through
    /// clientInfo and released in tapFinalize. The snapshot
    /// (coefficients + identity key) is captured here, at item
    /// creation, never read from a global at finalize time — that is
    /// the P0-19 attribution fix.
    private final class TapContext {
        weak var equalizer: MusicEqualizer?
        var snapshot: EqualizerSnapshot
        var sampleRate: Double
        var filters: [[EqualizerBiquad]]
        var sumSquares: Double = 0
        var sampleCount: Int = 0

        init(equalizer: MusicEqualizer, snapshot: EqualizerSnapshot, channelCount: Int) {
            self.equalizer = equalizer
            self.snapshot = snapshot
            self.sampleRate = snapshot.sampleRate
            self.filters = (0..<channelCount).map { _ in snapshot.bands }
        }
    }

    /// An AVAudioMix carrying the EQ tap for one item, stamped with
    /// that track's identity key. Returns nil when the tap cannot be
    /// created; the caller then plays without EQ rather than failing
    /// the track (fail-open: EQ must never break playback).
    func makeAudioMix(identityKey: String) -> AVAudioMix? {
        guard settings.enabled else { return nil }
        let context = TapContext(
            equalizer: self,
            snapshot: snapshot(sampleRate: 44100, identityKey: identityKey),
            channelCount: 2
        )
        let retained = Unmanaged.passRetained(context)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained.toOpaque(),
            init: MusicEqualizer.tapInit,
            finalize: MusicEqualizer.tapFinalize,
            prepare: MusicEqualizer.tapPrepare,
            unprepare: MusicEqualizer.tapUnprepare,
            process: MusicEqualizer.tapProcess
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap
        )
        guard status == noErr, let createdTap = tap else {
            retained.release()
            return nil
        }
        let mix = AVMutableAudioMix()
        let params = AVMutableAudioMixInputParameters()
        params.audioTapProcessor = createdTap
        mix.inputParameters = [params]
        return mix
    }

    private static let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
        tapStorageOut.pointee = clientInfo
    }

    private static let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
        let raw = MTAudioProcessingTapGetStorage(tap)
        let context = Unmanaged<TapContext>.fromOpaque(raw).takeRetainedValue()
        if context.sampleCount > 0 {
            let meanSquare = context.sumSquares / Double(context.sampleCount)
            if let lufs = MusicNormalization.lufsFromMeanSquare(meanSquare),
               !context.snapshot.identityKey.isEmpty {
                let key = context.snapshot.identityKey
                let handler = context.equalizer?.onLoudnessMeasured
                DispatchQueue.main.async { handler?(key, lufs) }
            }
        }
    }

    private static let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
        let raw = MTAudioProcessingTapGetStorage(tap)
        let context = Unmanaged<TapContext>.fromOpaque(raw).takeUnretainedValue()
        let channels = max(1, Int(format.pointee.mChannelsPerFrame))
        let rate = format.pointee.mSampleRate
        guard rate > 0 else { return }
        context.sampleRate = rate
        if let eq = context.equalizer {
            context.snapshot = eq.snapshot(sampleRate: rate, identityKey: context.snapshot.identityKey)
        }
        context.filters = (0..<channels).map { _ in context.snapshot.bands }
        context.sumSquares = 0
        context.sampleCount = 0
    }

    private static let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

    private static let tapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
        let raw = MTAudioProcessingTapGetStorage(tap)
        let context = Unmanaged<TapContext>.fromOpaque(raw).takeUnretainedValue()
        let _ = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
        // Live settings change: rebuild filters from the fresh
        // snapshot. The snapshot copy is taken outside the sample
        // loop; the loop itself runs lock-free.
        if let eq = context.equalizer, eq.revision != context.snapshot.revision {
            let fresh = eq.snapshot(sampleRate: context.sampleRate, identityKey: context.snapshot.identityKey)
            context.snapshot = fresh
            context.filters = context.filters.map { _ in fresh.bands }
        }
        let snapshot = context.snapshot
        let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)
        for (channelIndex, buffer) in abl.enumerated() {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            var channelFilters = channelIndex < context.filters.count ? context.filters[channelIndex] : snapshot.bands
            let preamp = Float(snapshot.preampLinear)
            let samples = data.assumingMemoryBound(to: Float.self)
            var sumSquares: Double = 0
            for i in 0..<frames {
                var sample = samples[i] * preamp
                for b in 0..<channelFilters.count {
                    sample = channelFilters[b].process(sample)
                }
                samples[i] = sample
                sumSquares += Double(sample) * Double(sample)
            }
            if channelIndex < context.filters.count {
                context.filters[channelIndex] = channelFilters
            }
            context.sumSquares += sumSquares
            context.sampleCount += frames
        }
    }
}

// MARK: - Native music player

/// Native music player: AVPlayer A/B dual engines, crossfade on
/// automatic advance, five play modes, speed 0.6-2.0, 10 s open
/// timeout, verified seek, stall watchdog, generation-guarded
/// crossfade, 10-band EQ, Now Playing, AirPlay.
///
/// One sound at a time: `play` stops whatever this player is doing
/// first, and the coordinator stops the other domains before
/// starting music. Music uses AVPlayer only and never reads the
/// video/live kernel selector.
final class NativeMusicPlayer: NSObject, ObservableObject, MusicPlaybackDriver {
    static let shared = NativeMusicPlayer()

    // Published state. Names are fixed: the UI leg reads these.
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var playMode: MusicPlayMode {
        didSet { defaults.set(playMode.code, forKey: "playMode") }
    }
    @Published private(set) var playbackSpeed: Double = 1.0
    @Published private(set) var actualQuality: AudioQuality?
    @Published private(set) var currentTrack: PlaybackItem?

    // Driver wiring, set by PlaybackCoordinator.
    var resolveURL: ((PlaybackItem, [URL], @escaping (URL?, AudioQuality?) -> Void) -> Void)?
    var onTrackStarted: ((PlaybackItem) -> Void)?
    var onTrackFailed: ((PlaybackItem, MusicPlayerError) -> Void)?

    static let openTimeout: TimeInterval = 10
    static let crossfadeDuration: TimeInterval = 2.5
    static let seekTolerance: TimeInterval = 2.0
    static let minSpeed: Double = 0.6
    static let maxSpeed: Double = 2.0

    /// Set by the view model from the sleep timer's onChanged: a
    /// completion-mode timer is armed (end of current track /
    /// after N tracks / end of queue). Auto-advance then hard-cuts
    /// instead of the 2.5 s crossfade — the ramp makes the next
    /// track audible before onTrackStarted fires, so the timer's
    /// pause would land ~2.5 s into the next song instead of at
    /// the boundary (b49sweep P2-11). Wall-clock timers fire via
    /// onFire directly and never set this. Manual next/previous
    /// never trigger the timer (the view model's expectedItemId
    /// gate), so only advanceAutoFrom reads it.
    var sleepCompletionArmed = false

    /// Test seam: open timeout seconds. Production is 10; tests set
    /// a short value so the timeout path runs without waiting.
    var openTimeoutInterval: TimeInterval = NativeMusicPlayer.openTimeout

    let equalizer: MusicEqualizer
    let watchdog = MusicStallWatchdog()

    private let defaults: UserDefaults
    private var engineA: MusicPlayerEngine
    private var engineB: MusicPlayerEngine
    private var activeEngine: MusicPlayerEngine
    private var standbyEngine: MusicPlayerEngine

    private var queue: [PlaybackItem] = []
    private var queueIndex: Int = 0
    private var generation: Int = 0
    private var pendingItem: PlaybackItem?
    /// URL currently loaded on the active engine (build 36 item 3):
    /// the fallback re-resolve excludes exactly this URL, so a
    /// failed — or preview — URL is never handed out twice.
    private var currentURL: URL?
    /// Track id whose loaded asset already passed the preview
    /// check (build 36 item 3): the late check in `handleTimeUpdate`
    /// only runs once per track, when the duration first becomes
    /// known after load.
    private var previewCheckedTrackID: String?
    private var playRequested: Bool = false
    private var stallFailed: Bool = false

    private var openTimeoutWork: DispatchWorkItem?
    /// b44 (chen 2026-11-25: 切歌读不到信息，要打开 app 重新播放):
    /// a manual / remote track switch stops the current audio FIRST
    /// (coordinator.requestPlay -> driver.stop()), so the app has no
    /// playing audio while the next track's URL resolves (LX scripts
    /// + network, up to the resolver's 8 s budget) — and this app
    /// holds no background-task assertion anywhere, so iOS may
    /// suspend a backgrounded app mid-resolve. The resolve
    /// completion then never fires: no failure is reported, Now
    /// Playing stays cleared (teardownNowPlaying ran in stop() and
    /// setupNowPlaying only runs after a successful load), and the
    /// view model already shows the new song paused — the user has
    /// to open the app and tap play, which re-requests in the
    /// foreground and works. Two layers, both in this file:
    /// (1) a background task spans every resolve that starts after
    /// audio stops, so the resolve + open can finish in background;
    /// (2) a resolve timeout (12 s > the resolver's 8 s budget, so
    /// it can only fire when the completion is really lost) turns a
    /// silent stall into a reported failure, which the view model
    /// already handles (advance / "无法播放").
    private var switchBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Id of the currently armed resolve timeout (0 = none). The id
    /// — not the work item alone — guards the timeout: a superseding
    /// request arms a new timeout, and a late completion from the old
    /// request must never cancel the new one.
    private var resolveTimeoutId = 0
    private var resolveTimeoutWork: DispatchWorkItem?
    /// Resolve timeout seconds. The resolver's own budget caps a
    /// resolve at 8 s, so a completion still missing at 12 s is
    /// lost, not slow.
    static let resolveTimeout: TimeInterval = 12
    private var crossfadeTimer: Timer?
    private var fadeTimer: Timer?
    private var watchdogTimer: Timer?
    /// True while an engine seek is in flight. The watchdog
    /// ignores ticks while set: a slow seek freezes the position
    /// by design, and without this the watchdog would declare a
    /// stall at 12 s and reopen the track at the pre-seek
    /// position. Cleared by the seek completion; the 20 s safety
    /// in watchdogTick() covers an engine that never calls its
    /// completion (a contract violation).
    private var seekInFlight = false
    private var seekStartedAt: Date?
    private var interruptionObserver: NSObjectProtocol?
    private var wasPlayingBeforeInterruption: Bool = false

    // MARK: - b45-F: prefetch / offline / failure recovery
    // (plan §7.4 / §9.2 / §9.3)

    /// Manual track switch: 0.8 s quick crossfade when the next
    /// track is already cached locally, otherwise an immediate
    /// hard cut. (Auto-advance keeps the 2.5 s crossfade.)
    static let manualCrossfadeDuration: TimeInterval = 0.8

    /// Local-audio lookup, installed by the coordinator: the
    /// downloaded file or audio-cache file for an item, or nil.
    /// Drives the manual crossfade, the offline selector and the
    /// prefetch "already cached" check.
    var localAudioURL: ((PlaybackItem) -> URL?)?

    /// Offline when the download engine's path monitor says so
    /// (single source of truth for the player).
    var isOffline: Bool { !DownloadEngine.shared.isNetworkAvailable }

    /// Offline fallback state for the UI leg: how many upcoming
    /// tracks were skipped to reach a local one, and whether the
    /// "no offline song at all" alert must show.
    @Published private(set) var offlineSkippedCount = 0
    @Published private(set) var offlineAlertNeeded = false

    /// Offline alert copy (plan §9.3, OfflinePlaybackAlert).
    enum OfflinePlaybackAlert {
        static let title = "离线播放"
        static let message = "当前无网络，已跳过无法离线播放的歌曲。"
        static let playNextOfflineTitle = "播放下一首离线歌曲"
        static let viewDownloadsTitle = "查看已下载"
    }

    /// Dismiss the offline alert (called by the UI leg).
    func dismissOfflineAlert() { offlineAlertNeeded = false }

    /// Consecutive unplayable tracks (plan §7.4: 5 in a row stops
    /// playback). Reset on every successful track start.
    private var consecutiveFailureCount = 0
    /// Recovery stage for the current item: 0 = fresh, 1 = twin
    /// host tried, 2 = re-resolved. Reset on success.
    private var recoverStage = 0

    /// Last successfully opened URL + tier, for quality-switch
    /// rollback: a failed quality switch returns to the exact
    /// URL / tier that was playing.
    private var lastGoodURL: URL?
    private var lastGoodQuality: AudioQuality?
    private var lastGoodItemID: String?

    /// True while a crossfade ramp is running. A manual "next"
    /// during a transition does NOT hard-cut: it is remembered
    /// and runs once the audible transition finishes.
    private var crossfadeInProgress = false
    private var pendingManualNext = false
    /// True when the running crossfade is a manual 0.8 s one
    /// (its failure path falls back to a hard cut, never to
    /// auto-advance).
    private var crossfadeIsManual = false

    /// Upcoming-track prefetcher (plan §7.4/§9.2).
    let prefetcher = QueuePrefetcher()

    private var normalizationEnabled: Bool = false
    private var normalizationStrength: Int = 1
    private var measuredLoudness: [String: Double] = [:]
    /// IDs of tracks whose playback failed (engine failure, or
    /// unresolvable during auto-advance). The view model consults
    /// this before counting a track change as a natural completion:
    /// a failed track must never count toward the sleep timer's
    /// "after N tracks" (A13). Cleared when the track later starts
    /// successfully, and on stop().
    private var failedTrackIds = Set<String>()

    /// True when this id belongs to a track whose playback failed
    /// (A13). The view model checks the previous song's keys before
    /// counting its change as a natural completion.
    func didTrackFail(id: String) -> Bool {
        return failedTrackIds.contains(id)
    }

    /// Manual play requests that failed to resolve/open, published
    /// so the UI leg can say so (build 36, item 8, F1): a tap that
    /// silently does nothing is a dead button with no feedback.
    /// A counter, not just the id — the same song can fail twice
    /// in a row and each failure must surface (a bare id would not
    /// re-emit). Auto-advance skips never touch this: they are not
    /// user taps, and the next song starting is their feedback.
    @Published private(set) var failedRequestCount = 0
    /// Id of the most recent failed manual play request.
    @Published private(set) var lastFailedRequestId: String?

    /// Report a manual play-request failure: publish it for the UI
    /// leg and forward to the coordinator's onTrackFailed (which
    /// clears the recorded current item). Only the manual paths
    /// (play / attemptOpen) call this — recovery and auto-advance
    /// failures go through recoverFromFailure / advanceAuto.
    private func reportFailedRequest(_ item: PlaybackItem, _ error: MusicPlayerError) {
        // b44: a failed switch settles the request — end the
        // background task (a task left running would hold the app
        // awake for nothing).
        endSwitchBackgroundTask()
        lastFailedRequestId = item.id
        failedRequestCount += 1
        onTrackFailed?(item, error)
    }

    /// Manual play-request failure, Coda `handleUnplayable` parity
    /// (PlayerServiceIOS.swift:1349): report only — the view model
    /// owns the advance (its handleCurrentSongFailed, via the
    /// failedRequestCount publication below). b49sweep P0-1: this
    /// used to advance the player's own queue AFTER
    /// reportFailedRequest published, and @Published emits
    /// synchronously, so one failed tap advanced twice — the view
    /// model advanced with manual (auto:false) semantics while
    /// the player advanced with auto semantics, and in shuffle
    /// each rolled its own random pick (the next song started,
    /// then restarted / re-buffered). The bookkeeping stays:
    /// failedTrackIds (didTrackFail guards the sleep timer's
    /// natural-completion count) and the recovery stage reset.
    /// The old 5-in-a-row stop is gone with the advance — the view
    /// model's handleCurrentSongFailed bounds the skips to one
    /// pass over the queue instead; the auto path
    /// (noteFailedAdvance) keeps its own 5-stop. Callers that
    /// drive this player without a view model must observe
    /// failedRequestCount and advance themselves. Timeouts advance
    /// the same way (Coda counts any unplayable track) but are
    /// never written to the failure memory — the song stays
    /// playable later.
    private func handleManualPlayFailure(_ item: PlaybackItem, _ error: MusicPlayerError) {
        reportFailedRequest(item, error)
        guard !queue.isEmpty, queueIndex >= 0, queueIndex < queue.count,
              queue[queueIndex].id == item.id else { return }
        failedTrackIds.insert(item.id)
        recoverStage = 0
    }

    private var nowPlayingActive: Bool = false
    private var nowPlayingArtwork: MPMediaItemArtwork?
    /// Artwork fetch attempts for the current track (reset on a
    /// track change). The old fetch dropped its error silently
    /// with no retry, so one failed fetch meant no artwork for
    /// the whole track.
    private var nowPlayingArtworkAttempts = 0
    private var nowPlayingArtworkRetryWork: DispatchWorkItem?
    private var lastNowPlayingElapsedUpdate: Date = .distantPast

    init(makeEngine: @escaping () -> MusicPlayerEngine = { AVPlayerEngine() }, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.equalizer = MusicEqualizer(defaults: defaults)
        let engineARef = makeEngine()
        let engineBRef = makeEngine()
        self.engineA = engineARef
        self.engineB = engineBRef
        self.activeEngine = engineARef
        self.standbyEngine = engineBRef
        self.playMode = MusicPlayMode.fromCode(defaults.string(forKey: "playMode"))
        self.playbackSpeed = NativeMusicPlayer.clampSpeed(defaults.double(forKey: "musicSpeed") == 0 ? 1.0 : defaults.double(forKey: "musicSpeed"))
        self.normalizationEnabled = defaults.bool(forKey: "hao_music_normalization_enabled")
        self.normalizationStrength = defaults.object(forKey: "hao_music_normalization_strength") == nil ? 1 : min(2, max(0, defaults.integer(forKey: "hao_music_normalization_strength")))
        super.init()
        engineARef.equalizer = equalizer
        engineBRef.equalizer = equalizer
        engineARef.onEnded = { [weak self] in self?.handleEngineEnded(engine: engineARef) }
        engineBRef.onEnded = { [weak self] in self?.handleEngineEnded(engine: engineBRef) }
        engineARef.onFailed = { [weak self] in self?.handleEngineFailed(engine: engineARef) }
        engineBRef.onFailed = { [weak self] in self?.handleEngineFailed(engine: engineBRef) }
        engineARef.onTimeUpdate = { [weak self] pos, dur in self?.handleTimeUpdate(pos: pos, duration: dur, engine: engineARef) }
        engineBRef.onTimeUpdate = { [weak self] pos, dur in self?.handleTimeUpdate(pos: pos, duration: dur, engine: engineBRef) }
        equalizer.onLoudnessMeasured = { [weak self] key, lufs in self?.noteMeasuredLoudness(key, lufs) }
        loadLoudnessCache()
        applyMixWithOthers(defaults.bool(forKey: SettingsStore.mixWithOthersKey))
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in self?.handleInterruption(note) }
    }

    deinit {
        crossfadeTimer?.invalidate()
        fadeTimer?.invalidate()
        watchdogTimer?.invalidate()
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o) }
        teardownNowPlaying()
    }

    // MARK: - Helpers

    /// Apply the "与其他音频同时播放" preference to the audio
    /// session (Flutter `AvMusicPlayer.applyMixWithOthers`):
    /// category .playback, mode .default, [.mixWithOthers] when
    /// on, no options when off, then setActive(true). Called at
    /// init with the stored value and from the settings toggle,
    /// so a change takes effect on the playing track — no restart.
    /// Music-player only, like Flutter: the video / live drivers
    /// set their own session when they open.
    func applyMixWithOthers(_ mix: Bool) {
        let options: AVAudioSession.CategoryOptions = mix ? [.mixWithOthers] : []
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: options)
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
    }

    private func ensureMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Begin the background task that keeps a post-audio-stop
    /// resolve alive in background (b44). Ends any previous task
    /// first (one switch at a time). No-op when tasks are
    /// unavailable (beginBackgroundTask returns .invalid) — the
    /// resolve timeout below still converts a stall into a reported
    /// failure. Called on main (every call site runs in ensureMain).
    private func beginSwitchBackgroundTask() {
        endSwitchBackgroundTask()
        switchBackgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.handleSwitchBackgroundTaskExpired()
        }
    }

    private func endSwitchBackgroundTask() {
        guard switchBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(switchBackgroundTask)
        switchBackgroundTask = .invalid
    }

    /// The system ran out of background time before the switch
    /// settled: fail the pending request now (on main) instead of
    /// leaving it hung — the view model advances / shows
    /// "无法播放", exactly as for any other resolve failure.
    private func handleSwitchBackgroundTaskExpired() {
        ensureMain {
            self.endSwitchBackgroundTask()
            if let item = self.pendingItem {
                self.pendingItem = nil
                self.reportFailedRequest(item, .timeout)
            }
        }
    }

    /// Arm the resolve timeout for one resolve (b44). Returns its
    /// id; the caller's resolve completion cancels it by id (a late
    /// completion from a superseded request must not cancel the new
    /// request's timeout). On fire, the request is still pending, so
    /// the timeout reports it as a failure through onFire.
    private func beginResolveTimeout(onFire: @escaping () -> Void) -> Int {
        cancelResolveTimeout()
        resolveTimeoutId += 1
        let myId = resolveTimeoutId
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.resolveTimeoutId == myId else { return }
            self.resolveTimeoutWork = nil
            onFire()
        }
        resolveTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resolveTimeout, execute: work)
        return myId
    }

    private func cancelResolveTimeout() {
        resolveTimeoutWork?.cancel()
        resolveTimeoutWork = nil
    }

    private func cancelResolveTimeout(id: Int) {
        guard resolveTimeoutId == id else { return }
        cancelResolveTimeout()
    }

    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    static func clampSpeed(_ value: Double) -> Double {
        return min(maxSpeed, max(minSpeed, value))
    }

    /// Recompute the published playing flag from real engine state.
    /// True only while audio is really sounding, or while a play was
    /// requested and an item is loaded but still buffering. False
    /// the moment the watchdog fails, the item fails, or playback
    /// is paused or stopped: never report playing for a dead stream.
    private func recomputePlayingState() {
        let sounding = activeEngine.isPlaying || (crossfadeTimer != nil && standbyEngine.isPlaying)
        let buffering = playRequested && activeEngine.hasItem && !stallFailed
        isPlaying = (sounding || buffering) && !stallFailed && currentTrack != nil
    }

    private func fadeEnabled() -> Bool {
        return defaults.object(forKey: "hao_music_fade_enabled") == nil ? true : defaults.bool(forKey: "hao_music_fade_enabled")
    }

    private func targetGain(for item: PlaybackItem?) -> Double {
        guard let item = item else { return 1.0 }
        return normalizationGain(for: item)
    }

    // MARK: - Queue

    /// Replace the queue and start playback at `startAt`. Automatic
    /// advance walks this queue according to `playMode`.
    func setQueue(_ items: [PlaybackItem], startAt: Int) {
        ensureMain {
            self.queue = items
            guard !items.isEmpty else { self.stop(); return }
            let index = min(max(startAt, 0), items.count - 1)
            self.queueIndex = index
            self.play(item: items[index])
        }
    }

    /// Replace the queue WITHOUT starting playback (A1). The view
    /// model uses this before `coordinator.requestPlay` so one tap
    /// resolves exactly once: `setQueue` would already `play()` the
    /// item, and `requestPlay` would then `stop()` + replay it,
    /// throwing the first resolve away (and failing outright when
    /// the second resolve fails even though the first had a URL).
    func setQueueOnly(_ items: [PlaybackItem], startAt: Int) {
        ensureMain {
            self.queue = items
            guard !items.isEmpty else { return }
            self.queueIndex = min(max(startAt, 0), items.count - 1)
        }
    }

    private func indexOf(_ item: PlaybackItem) -> Int? {
        return queue.firstIndex(where: { $0.id == item.id })
    }

    // MARK: - Play / open

    /// Play an item: stop what this player is doing, resolve the
    /// first playable URL serially (fastest first, via the
    /// coordinator-wired resolver), open it, and on open failure
    /// consume exactly one fallback candidate before giving up.
    /// Tapping the song that is already playing does not restart it.
    func play(item: PlaybackItem) {
        ensureMain {
            if let current = self.currentTrack, current.id == item.id, self.activeEngine.hasItem {
                if self.isPlaying { return }
                self.resume()
                return
            }
            self.stopEnginesForNewRequest()
            self.pendingItem = item
            self.stallFailed = false
            // b44: this switch stopped audio first, so the resolve
            // runs with no audio keeping the app alive in
            // background — hold a background task for it, and arm
            // the resolve timeout (a lost completion must fail
            // loudly, never hang silently).
            self.beginSwitchBackgroundTask()
            let timeoutId = self.beginResolveTimeout { [weak self] in
                guard let self = self else { return }
                guard self.pendingItem?.id == item.id else { return }
                self.pendingItem = nil
                self.handleManualPlayFailure(item, .timeout)
            }
            self.resolveURL?(item, []) { [weak self] url, tier in
                guard let self = self else { return }
                self.ensureMain {
                    self.cancelResolveTimeout(id: timeoutId)
                    guard self.pendingItem?.id == item.id else { return }
                    guard let url = url else {
                        self.pendingItem = nil
                        self.handleManualPlayFailure(item, .noPlayableURL)
                        return
                    }
                    self.actualQuality = tier
                    self.attemptOpen(item: item, url: url, tried: [url])
                }
            }
            if self.resolveURL == nil {
                self.pendingItem = nil
                self.reportFailedRequest(item, .noPlayableURL)
            }
        }
    }

    /// One open attempt plus at most one fallback re-resolution.
    /// `tried` lists the URLs already consumed for this request, so
    /// the fallback consumes exactly one more candidate, never a fan
    /// out and never an unbounded retry loop.
    private func attemptOpen(item: PlaybackItem, url: URL, tried: [URL]) {
        open(item: item, url: url) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                return
            case .failure(let error):
                guard tried.count < 2 else {
                    self.pendingItem = nil
                    self.handleManualPlayFailure(item, error)
                    return
                }
                // b44: same stall class as the first resolve — the
                // fallback re-resolve gets its own timeout (the
                // background task from play() is still active).
                let timeoutId = self.beginResolveTimeout { [weak self] in
                    guard let self = self else { return }
                    guard self.pendingItem?.id == item.id else { return }
                    self.pendingItem = nil
                    self.handleManualPlayFailure(item, error)
                }
                self.resolveURL?(self.resolveItemSkippingExcludedLocal(item, excluding: tried), tried) { [weak self] nextURL, tier in
                    guard let self = self else { return }
                    self.ensureMain {
                        self.cancelResolveTimeout(id: timeoutId)
                        guard self.pendingItem?.id == item.id else { return }
                        guard let nextURL = nextURL else {
                            self.pendingItem = nil
                            self.handleManualPlayFailure(item, error)
                            return
                        }
                        self.actualQuality = tier
                        self.attemptOpen(item: item, url: nextURL, tried: tried + [nextURL])
                    }
                }
                if self.resolveURL == nil {
                    self.pendingItem = nil
                    self.reportFailedRequest(item, error)
                }
            }
        }
    }

    /// Open a URL on the active engine with a 10 s timeout (P0-04).
    /// The completion fires exactly once for the live attempt: a
    /// timeout is a stream error, a load failure is a load error,
    /// and a newer open supersedes this one (its completion is then
    /// dropped, never double-reported). Manual opens start silent
    /// and fade in over 600 ms when fading is on, matching Flutter.
    func open(item: PlaybackItem, url: URL, completion: @escaping (Result<Void, MusicPlayerError>) -> Void) {
        ensureMain {
            let gen = self.nextGeneration()
            self.stopCrossfadeTimer()
            self.pendingItem = item
            self.currentURL = url
            self.openTimeoutWork?.cancel()
            self.openTimeoutWork = nil
            let engine = self.activeEngine
            var completed = false
            let finish: (Result<Void, MusicPlayerError>) -> Void = { [weak self] result in
                guard let self = self, !completed else { return }
                completed = true
                self.openTimeoutWork?.cancel()
                self.openTimeoutWork = nil
                completion(result)
            }
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard gen == self.generation, !completed else { return }
                engine.unload()
                self.playRequested = false
                self.recomputePlayingState()
                finish(.failure(.timeout))
            }
            self.openTimeoutWork = timeoutWork
            DispatchQueue.main.asyncAfter(deadline: .now() + self.openTimeoutInterval, execute: timeoutWork)
            engine.load(url: url, headers: nil, identityKey: item.id) { [weak self] ok in
                guard let self = self else { return }
                self.ensureMain {
                    guard gen == self.generation, !completed else { return }
                    guard ok, engine.hasItem else {
                        self.playRequested = false
                        self.recomputePlayingState()
                        finish(.failure(.loadFailed))
                        return
                    }
                    // Build 36 item 3: the loaded asset IS the
                    // verdict for aggregators that return a bare URL
                    // with no trial metadata — a ~30 s asset for a
                    // minutes-long song is a preview, never a
                    // playable track. Caught here, before the engine
                    // plays a single sample, it is a load failure:
                    // the caller's fallback re-resolves with this
                    // URL excluded and tries the next source.
                    if PreviewAudioClassifier.isPreviewAsset(
                        actualDuration: engine.durationSeconds,
                        expectedDuration: item.duration,
                        trialOnly: item.trialOnly) {
                        engine.unload()
                        self.playRequested = false
                        self.recomputePlayingState()
                        finish(.failure(.loadFailed))
                        return
                    }
                    self.startPlaybackAfterLoad(item: item, engine: engine, gen: gen, finish: finish)
                }
            }
        }
    }

    /// Shared tail of a successful load: start the engine, re-apply
    /// speed and the track gain, start the watchdog, publish state.
    private func startPlaybackAfterLoad(
        item: PlaybackItem,
        engine: MusicPlayerEngine,
        gen: Int,
        finish: @escaping (Result<Void, MusicPlayerError>) -> Void
    ) {
        guard gen == generation else { return }
        playRequested = true
        stallFailed = false
        engine.play()
        engine.rate = Float(playbackSpeed)
        let gain = targetGain(for: item)
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        if let index = indexOf(item) { queueIndex = index }
        currentTrack = item
        failedTrackIds.remove(item.id)
        pendingItem = nil
        // b44: the switch settled (audio is playing again) — the
        // background task is no longer needed.
        endSwitchBackgroundTask()
        position = 0
        duration = engine.durationSeconds
        // Build 36 item 3: the load-time preview check already ran
        // with this duration — but only when the duration was known
        // at load. When it was still 0/unknown, the late check in
        // `handleTimeUpdate` still has to run for this track.
        if engine.durationSeconds > 0 { previewCheckedTrackID = item.id }
        watchdog.resetForNewTrack()
        startWatchdogTimerIfNeeded()
        setupNowPlaying()
        updateNowPlayingInfo()
        resetNowPlayingArtwork()
        fetchNowPlayingArtworkIfNeeded()
        if fadeEnabled() && gain > 0 {
            engine.volume = 0
            rampVolume(engine: engine, from: 0, to: Float(gain), duration: 0.6, gen: gen, completion: nil)
        } else {
            engine.volume = Float(gain)
        }
        recomputePlayingState()
        // b45-F: same success bookkeeping as the crossfade path.
        noteSuccessfulStart(item: item)
        finish(.success(()))
        onTrackStarted?(item)
    }

    private func stopEnginesForNewRequest() {
        stopCrossfadeTimer()
        fadeTimer?.invalidate()
        fadeTimer = nil
        openTimeoutWork?.cancel()
        openTimeoutWork = nil
        playRequested = false
        activeEngine.pause()
        standbyEngine.pause()
        standbyEngine.unload()
    }

    private func stopCrossfadeTimer() {
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
    }

    // MARK: - Transport

    func play() {
        ensureMain {
            guard self.currentTrack != nil, self.activeEngine.hasItem else { return }
            self.resume()
        }
    }

    func resume() {
        ensureMain {
            guard self.currentTrack != nil, self.activeEngine.hasItem else { return }
            if self.isPlaying { return }
            self.playRequested = true
            self.stallFailed = false
            self.activeEngine.play()
            self.activeEngine.rate = Float(self.playbackSpeed)
            self.watchdog.noteBaseline()
            if self.fadeEnabled() {
                let from = self.activeEngine.volume
                let to = Float(self.targetGain(for: self.currentTrack))
                self.rampVolume(engine: self.activeEngine, from: from, to: to, duration: 0.4, gen: self.generation, completion: nil)
            } else {
                self.activeEngine.volume = Float(self.targetGain(for: self.currentTrack))
            }
            self.recomputePlayingState()
            // b47 (chen 2026-11-25 build 46: 灵动岛/锁屏/控制中心不能切歌):
            // resume() only refreshed the info, never rebuilt the
            // registration — after any teardown (failed switch, engine
            // failure) a resume played the song but the card stayed
            // dead. setupNowPlaying is idempotent (already active =
            // refresh only), so rebuilding here is a pure safety net.
            self.setupNowPlaying()
            self.updateNowPlayingInfo()
        }
    }

    func pause() {
        ensureMain {
            guard self.currentTrack != nil else { return }
            self.playRequested = false
            self.activeEngine.pause()
            self.standbyEngine.pause()
            self.recomputePlayingState()
            self.updateNowPlayingInfo()
        }
    }

    func toggle() {
        if isPlaying { pause() } else { resume() }
    }

    /// Stop everything and clear the current track. The coordinator
    /// clears `currentItem` alongside; this player never leaves a
    /// ghost engine sounding after stop.
    func stop() {
        ensureMain {
            self.nextGeneration()
            self.stopCrossfadeTimer()
            self.fadeTimer?.invalidate()
            self.fadeTimer = nil
            self.openTimeoutWork?.cancel()
            self.openTimeoutWork = nil
            // b44: a stop abandons any pending switch — end its
            // background task and cancel its resolve timeout.
            self.endSwitchBackgroundTask()
            self.cancelResolveTimeout()
            self.watchdogTimer?.invalidate()
            self.watchdogTimer = nil
            self.playRequested = false
            self.stallFailed = false
            self.pendingItem = nil
            // b45-F: a stop also abandons any remembered manual
            // "next" and any running transition.
            self.pendingManualNext = false
            self.crossfadeInProgress = false
            self.crossfadeIsManual = false
            self.prefetcher.cancel()
            self.failedTrackIds.removeAll()
            self.activeEngine.pause()
            self.activeEngine.unload()
            self.standbyEngine.pause()
            self.standbyEngine.unload()
            self.currentTrack = nil
            self.currentURL = nil
            self.previewCheckedTrackID = nil
            self.actualQuality = nil
            self.position = 0
            self.duration = 0
            // #9 hygiene: cancel a pending Now Playing artwork
            // retry — its guard (currentTrack == nil after this
            // stop) already made it a no-op, but a cancelled work
            // item never fires at all.
            self.nowPlayingArtworkRetryWork?.cancel()
            self.nowPlayingArtworkRetryWork = nil
            self.recomputePlayingState()
            self.teardownNowPlaying()
        }
    }

    // MARK: - Speed and mode

    /// Set playback speed, clamped to 0.6-2.0, persisted to
    /// `musicSpeed`. Applies immediately to both engines and survives
    /// the next open.
    func setSpeed(_ speed: Double) {
        ensureMain {
            let clamped = NativeMusicPlayer.clampSpeed(speed)
            self.playbackSpeed = clamped
            self.defaults.set(clamped, forKey: "musicSpeed")
            if self.playRequested {
                self.activeEngine.rate = Float(clamped)
                self.standbyEngine.rate = Float(clamped)
            }
            self.updateNowPlayingInfo()
        }
    }

    func setPlayMode(_ mode: MusicPlayMode) {
        ensureMain { self.playMode = mode }
    }

    // MARK: - Seek

    /// Seek with read-back verification (P0-05). The completion
    /// reports whether the seek actually landed (within the 2 s
    /// tolerance Flutter uses). On failure the published position
    /// returns to the real position and a notification tells the UI
    /// to roll the progress bar back and show a toast.
    func seek(to seconds: TimeInterval, completion: @escaping (Bool) -> Void) {
        ensureMain {
            let gen = self.generation
            guard self.currentTrack != nil, self.activeEngine.hasItem else {
                completion(false)
                return
            }
            let target = max(0, self.duration > 0 ? min(seconds, self.duration) : seconds)
            self.seekInFlight = true
            self.seekStartedAt = Date()
            self.activeEngine.seek(to: target) { [weak self] finished in
                guard let self = self else { return }
                self.ensureMain {
                    self.seekInFlight = false
                    self.seekStartedAt = nil
                    self.watchdog.noteBaseline()
                    let actual = self.activeEngine.currentTimeSeconds
                    let landed = finished && abs(actual - target) <= NativeMusicPlayer.seekTolerance
                    self.position = actual
                    self.updateNowPlayingInfo()
                    if landed {
                        completion(true)
                    } else if gen == self.generation {
                        NotificationCenter.default.post(
                            name: .haoMusicSeekFailed,
                            object: self,
                            userInfo: [MusicNotificationKeys.actualPosition: actual]
                        )
                        completion(false)
                    } else {
                        completion(false)
                    }
                }
            }
        }
    }

    // MARK: - Manual next / previous

    /// Restart the loaded track from the beginning (b41: the manual
    /// next / previous dead-end behaviour — a 1-song queue, or the
    /// ends in sequential / single mode). No-op when nothing is
    /// loaded. Seeks to 0, then resumes if paused: a manual tap
    /// always answers. No re-resolve, no queue change, no crossfade.
    func restartCurrentTrack() {
        ensureMain {
            guard self.currentTrack != nil else { return }
            self.seek(to: 0) { [weak self] _ in
                self?.play()
            }
        }
    }

    /// Manual next: no crossfade. At the end of a non-looping queue
    /// this used to be a silent no-op (the current track kept
    /// playing and the button looked dead — chen 2026-11-25: the
    /// lock-screen / Dynamic Island / Control Center buttons did
    /// nothing). Now it restarts the current song instead (b41):
    /// a manual tap always answers.
    func next() {
        ensureMain {
            guard !self.queue.isEmpty, self.currentTrack != nil else { return }
            // b45-F: a transition already in progress is never
            // hard-cut — the tap is remembered and runs once the
            // audible transition finishes.
            if self.crossfadeInProgress {
                self.pendingManualNext = true
                return
            }
            let nextIndex = musicNextTrackIndex(mode: self.playMode, current: self.queueIndex, length: self.queue.count, auto: false)
            guard nextIndex >= 0, nextIndex != self.queueIndex else {
                // Dead end (1-song queue, or the end in sequential /
                // single mode) — or the computed next IS the current
                // song (a 1-song queue in a looping / shuffle mode):
                // restart it instead of reopening it (b41).
                self.restartCurrentTrack()
                return
            }
            let target = self.queue[nextIndex]
            // b45-F: manual switch, next track already cached
            // locally → 0.8 s quick crossfade; otherwise hard cut.
            if self.isPlaying, let localURL = self.localAudioURL?(target) {
                self.queueIndex = nextIndex
                self.manualCrossfade(to: target, url: localURL)
                return
            }
            self.queueIndex = nextIndex
            self.play(item: target)
        }
    }

    /// Manual previous: no crossfade. Shuffle picks a random other
    /// track; loop modes wrap; sequential and single play used to
    /// stop silently at the first track — now they restart the
    /// current song instead (b41, same rule as next()).
    func previous() {
        ensureMain {
            guard !self.queue.isEmpty, self.currentTrack != nil else { return }
            // b45-F: same transition rule as next() — never cut an
            // audible crossfade; remember the tap instead.
            if self.crossfadeInProgress {
                self.pendingManualNext = true
                return
            }
            let prevIndex = musicPrevTrackIndex(mode: self.playMode, current: self.queueIndex, length: self.queue.count)
            guard prevIndex >= 0, prevIndex != self.queueIndex else {
                // Dead end (first track in sequential / single mode)
                // — or the computed previous IS the current song (a
                // 1-song queue in a looping / shuffle mode): restart
                // it instead of reopening it (b41).
                self.restartCurrentTrack()
                return
            }
            let target = self.queue[prevIndex]
            // b45-F: previous ALWAYS changes track (never a
            // restart-by-position rule); loop modes wrap at the
            // head to the tail (musicPrevTrackIndex). A cached
            // previous track gets the same 0.8 s quick crossfade.
            if self.isPlaying, let localURL = self.localAudioURL?(target) {
                self.queueIndex = prevIndex
                self.manualCrossfade(to: target, url: localURL)
                return
            }
            self.queueIndex = prevIndex
            self.play(item: target)
        }
    }

    /// Manual 0.8 s quick crossfade to an already-cached track
    /// (b45-F, plan §9.2). The regular crossfade path, but with
    /// the manual duration and a manual failure path (a failed
    /// cached load falls back to a hard cut via play(), never to
    /// auto-advance).
    private func manualCrossfade(to item: PlaybackItem, url: URL) {
        crossfadeIsManual = true
        crossfade(to: item, url: url, tried: [url], attempts: 0, duration: NativeMusicPlayer.manualCrossfadeDuration)
    }

    // MARK: - Automatic advance and crossfade

    private func handleEngineEnded(engine: MusicPlayerEngine) {
        ensureMain {
            if engine !== self.activeEngine {
                if self.crossfadeTimer != nil {
                    self.standbyEndedDuringCrossfade = true
                }
                return
            }
            guard self.currentTrack != nil else { return }
            self.playRequested = false
            // #5: the track ended — report not-playing now, before
            // advanceAuto starts the next one. handleEngineFailed
            // already recomputes; this path did not, so isPlaying
            // kept the finished track's true through the whole
            // crossfade setup.
            self.recomputePlayingState()
            self.advanceAuto()
        }
    }

    private var standbyEndedDuringCrossfade: Bool = false

    private func handleEngineFailed(engine: MusicPlayerEngine) {
        ensureMain {
            if engine !== self.activeEngine {
                self.standbyEngine.pause()
                self.standbyEngine.unload()
                return
            }
            guard let item = self.currentTrack else { return }
            self.playRequested = false
            self.recomputePlayingState()
            // A13: this track failed — record it before recovery
            // advances, so the advance is not counted as a natural
            // completion by the view model.
            self.failedTrackIds.insert(item.id)
            // Build 36 item 3: exclude the failed URL so the
            // fallback resolve hands out the next candidate,
            // never the same URL again.
            self.recoverFromFailure(item: item, excluding: self.currentURL.map { [$0] } ?? [])
        }
    }

    /// Automatic advance after completion (or after a failure the
    /// single fallback could not save). Walks the queue per the play
    /// mode with a 2.5 s crossfade; unresolvable tracks are skipped,
    /// bounded by one full pass over the queue.
    private func advanceAuto() {
        guard !queue.isEmpty else { stop(); return }
        advanceAutoFrom(index: queueIndex, attempts: 0)
    }

    private func advanceAutoFrom(index: Int, attempts: Int) {
        guard attempts < queue.count else {
            stop()
            return
        }
        // b45-F: offline — jump to the first locally available
        // track (download or audio cache), counting the skips;
        // with no local track at all, show the offline alert.
        // NOTE (wiring): the re-resolve below goes through the
        // coordinator, which returns `item.localFileURL` first
        // when set — a failed LOCAL copy is therefore re-offered
        // by the coordinator unless the item is stripped first.
        // b49sweep P1-8: the retry paths pass a stripped copy
        // (resolveItemSkippingExcludedLocal), so no
        // coordinator-side flag is needed.
        if isOffline {
            let isLooping = playMode == .listLoop || playMode == .singleLoop
            if let found = OfflineQueueSelector.firstAvailableIndex(
                itemCount: queue.count, currentIndex: index,
                isLooping: isLooping, isFM: false,
                isAvailable: { [weak self] i in
                    guard let self = self else { return false }
                    let candidate = self.queue[i]
                    return candidate.localFileURL != nil || self.localAudioURL?(candidate) != nil
                }) {
                offlineSkippedCount = found.skipped
                queueIndex = found.index
                play(item: queue[found.index])
            } else {
                offlineSkippedCount = 0
                offlineAlertNeeded = true
                stop()
            }
            return
        }
        let nextIndex = musicNextTrackIndex(mode: playMode, current: index, length: queue.count, auto: true)
        guard nextIndex >= 0 else {
            stop()
            return
        }
        let item = queue[nextIndex]
        queueIndex = nextIndex
        let gen = generation
        // b44: auto-advance resolves after the previous track ends —
        // audio has stopped, so the same suspension window as a
        // manual switch applies. Hold a background task and arm the
        // resolve timeout (a lost completion advances, never hangs).
        beginSwitchBackgroundTask()
        let timeoutId = beginResolveTimeout { [weak self] in
            guard let self = self else { return }
            guard gen == self.generation else { return }
            self.failedTrackIds.insert(item.id)
            self.advanceAutoFrom(index: nextIndex, attempts: attempts + 1)
        }
        resolveURL?(item, []) { [weak self] url, tier in
            guard let self = self else { return }
            self.ensureMain {
                self.cancelResolveTimeout(id: timeoutId)
                guard gen == self.generation else { return }
                guard let url = url else {
                    // A13: unresolvable during auto-advance — the
                    // skip is failure-driven, not a completion.
                    self.failedTrackIds.insert(item.id)
                    self.advanceAutoFrom(index: nextIndex, attempts: attempts + 1)
                    return
                }
                self.actualQuality = tier
                if self.sleepCompletionArmed {
                    self.hardCut(to: item, url: url, tried: [url], attempts: attempts)
                } else {
                    self.crossfade(to: item, url: url, tried: [url], attempts: attempts)
                }
            }
        }
        if resolveURL == nil {
            stop()
        }
    }

    /// Hard cut to an already-resolved URL (b49sweep P2-11): the
    /// crossfade's 2.5 s ramp makes the next track audible before
    /// onTrackStarted fires, so a completion-mode sleep timer
    /// would pause ~2.5 s into the next song. With
    /// sleepCompletionArmed, load the URL on the active engine
    /// directly — open() fires onTrackStarted at the boundary
    /// (via startPlaybackAfterLoad), so the timer pauses exactly
    /// at the end of the current track. This is the manual
    /// switch's open path, not a re-resolve: attemptOpen / play
    /// would re-resolve and, on failure, take manual
    /// handleManualPlayFailure semantics, which is wrong for an
    /// auto-advance (singleLoop must replay, single must stop).
    /// On failure, mirror the crossfade fallback — one
    /// re-resolve with `tried`, then auto-skip. The generation
    /// guard uses the generation at failure time (open() already
    /// bumped it), not the caller's.
    private func hardCut(to item: PlaybackItem, url: URL, tried: [URL], attempts: Int) {
        open(item: item, url: url) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                return
            case .failure:
                let gen = self.generation
                guard tried.count < 2 else {
                    self.failedTrackIds.insert(item.id)
                    self.advanceAutoFrom(index: self.queueIndex, attempts: attempts + 1)
                    return
                }
                let timeoutId = self.beginResolveTimeout { [weak self] in
                    guard let self = self else { return }
                    guard gen == self.generation else { return }
                    self.failedTrackIds.insert(item.id)
                    self.advanceAutoFrom(index: self.queueIndex, attempts: attempts + 1)
                }
                self.resolveURL?(self.resolveItemSkippingExcludedLocal(item, excluding: tried), tried) { [weak self] nextURL, tier in
                    guard let self = self else { return }
                    self.ensureMain {
                        self.cancelResolveTimeout(id: timeoutId)
                        guard gen == self.generation else { return }
                        guard let nextURL = nextURL else {
                            self.failedTrackIds.insert(item.id)
                            self.advanceAutoFrom(index: self.queueIndex, attempts: attempts + 1)
                            return
                        }
                        self.actualQuality = tier
                        self.hardCut(to: item, url: nextURL, tried: tried + [nextURL], attempts: attempts)
                    }
                }
            }
        }
    }

    /// A/B crossfade (P0-07): the next track loads on the standby
    /// engine and fades in over 2.5 s while the outgoing fades out.
    /// The generation guards every async step; an expired crossfade
    /// pauses the incoming engine before returning, so no ghost
    /// playback can survive a rapid series of track changes. When
    /// the outgoing track already ended, the incoming starts at full
    /// volume instead of swallowing its intro with a ramp.
    private func crossfade(to item: PlaybackItem, url: URL, tried: [URL], attempts: Int, duration: TimeInterval = NativeMusicPlayer.crossfadeDuration) {
        let gen = nextGeneration()
        stopCrossfadeTimer()
        standbyEndedDuringCrossfade = false
        crossfadeInProgress = true
        let outgoing = activeEngine
        let incoming = standbyEngine
        // Crossfade load timeout (mirrors open()): a load that
        // never becomes ready stalls auto-advance forever in
        // silence — the standby asset status stays .unknown
        // (black-holed host / stalled handshake), runCrossfadeRamp
        // only starts after a successful load, and the watchdog
        // cannot rescue it (playRequested is false during the
        // crossfade load). unload() fires the pending load
        // completion with ok=false, so the existing failure branch
        // below (fallback re-resolve once, then skip with attempts
        // counted) handles it; no new failure path is needed.
        // Both closures run on main, so the flag needs no lock;
        // the gen guard covers a superseded crossfade (do not
        // unload a newer load).
        var loadFinished = false
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard gen == self.generation, !loadFinished else { return }
            incoming.unload()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + self.openTimeoutInterval, execute: timeoutWork)
        let outgoingDone = outgoing.durationSeconds > 0 && outgoing.currentTimeSeconds >= outgoing.durationSeconds - 0.05
        let target = Float(targetGain(for: item))
        incoming.load(url: url, headers: nil, identityKey: item.id) { [weak self] ok in
            guard let self = self else { return }
            self.ensureMain {
                loadFinished = true
                timeoutWork.cancel()
                guard gen == self.generation else {
                    if incoming === self.standbyEngine { incoming.pause() }
                    return
                }
                guard ok, incoming.hasItem,
                      !PreviewAudioClassifier.isPreviewAsset(
                        actualDuration: incoming.durationSeconds,
                        expectedDuration: item.duration,
                        trialOnly: item.trialOnly) else {
                    // Build 36 item 3: same as a load failure — a
                    // ~30 s asset for a minutes-long song is a
                    // preview, and the fallback below re-resolves
                    // with this URL in `tried`, so the next source
                    // is tried instead of the same clip.
                    // b45-F: a MANUAL crossfade never auto-advances
                    // on failure — it falls back to a hard cut.
                    if self.crossfadeIsManual {
                        self.endCrossfadeTransition()
                        self.play(item: item)
                        return
                    }
                    if tried.count < 2 {
                        // b44: same stall class as the first resolve
                        // (task from advanceAutoFrom is still active).
                        let timeoutId = self.beginResolveTimeout { [weak self] in
                            guard let self = self else { return }
                            guard gen == self.generation else { return }
                            self.failedTrackIds.insert(item.id)
                            self.advanceAutoFrom(index: self.queueIndex, attempts: attempts + 1)
                        }
                        self.resolveURL?(self.resolveItemSkippingExcludedLocal(item, excluding: tried), tried) { [weak self] nextURL, tier in
                            guard let self = self else { return }
                            self.ensureMain {
                                self.cancelResolveTimeout(id: timeoutId)
                                guard gen == self.generation else {
                                    if incoming === self.standbyEngine { incoming.pause() }
                                    return
                                }
                                guard let nextURL = nextURL else {
                                    // A13: the fallback resolve found
                                    // nothing — failure-driven skip.
                                    self.failedTrackIds.insert(item.id)
                                    self.endCrossfadeTransition()
                                    self.advanceAutoFrom(index: self.queueIndex, attempts: attempts + 1)
                                    return
                                }
                                self.actualQuality = tier
                                self.crossfade(to: item, url: nextURL, tried: tried + [nextURL], attempts: attempts, duration: duration)
                            }
                        }
                    } else {
                        // A13: the fallback could not save this
                        // track either — failure-driven skip.
                        self.failedTrackIds.insert(item.id)
                        self.endCrossfadeTransition()
                        self.advanceAutoFrom(index: self.queueIndex, attempts: attempts + 1)
                    }
                    return
                }
                self.playRequested = true
                self.stallFailed = false
                self.currentURL = url
                if outgoingDone {
                    incoming.volume = target
                    incoming.play()
                    incoming.rate = Float(self.playbackSpeed)
                    self.finishCrossfade(item: item, gen: gen)
                } else {
                    incoming.volume = 0
                    incoming.play()
                    incoming.rate = Float(self.playbackSpeed)
                    self.runCrossfadeRamp(item: item, gen: gen, outgoingStartVolume: outgoing.volume, target: target, duration: duration)
                }
            }
        }
    }

    /// Clear the transition flags without advancing (a crossfade
    /// that failed before any audio swapped in).
    private func endCrossfadeTransition() {
        crossfadeInProgress = false
        crossfadeIsManual = false
    }

    private func runCrossfadeRamp(item: PlaybackItem, gen: Int, outgoingStartVolume: Float, target: Float, duration: TimeInterval = NativeMusicPlayer.crossfadeDuration) {
        let outgoing = activeEngine
        let incoming = standbyEngine
        let steps = 50
        var step = 0
        stopCrossfadeTimer()
        crossfadeTimer = Timer.scheduledTimer(withTimeInterval: duration / Double(steps), repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            guard gen == self.generation else {
                timer.invalidate()
                self.crossfadeTimer = nil
                if incoming === self.standbyEngine { incoming.pause() }
                return
            }
            step += 1
            let t = Float(step) / Float(steps)
            outgoing.volume = outgoingStartVolume * (1 - t)
            incoming.volume = target * t
            if step >= steps {
                timer.invalidate()
                self.crossfadeTimer = nil
                self.finishCrossfade(item: item, gen: gen)
            }
        }
    }

    private func finishCrossfade(item: PlaybackItem, gen: Int) {
        guard gen == generation else {
            if standbyEngine.isPlaying { standbyEngine.pause() }
            return
        }
        let outgoing = activeEngine
        swap(&self.activeEngine, &self.standbyEngine)
        outgoing.pause()
        outgoing.unload()
        if let index = indexOf(item) { queueIndex = index }
        currentTrack = item
        failedTrackIds.remove(item.id)
        pendingItem = nil
        // b44: the auto-advance settled (audio is playing again) —
        // the background task is no longer needed.
        endSwitchBackgroundTask()
        position = activeEngine.currentTimeSeconds
        duration = activeEngine.durationSeconds
        // Build 36 item 3: the load-time preview check already ran
        // with this duration — but only when the duration was known
        // at load; otherwise the late check still has to run.
        if activeEngine.durationSeconds > 0 { previewCheckedTrackID = item.id }
        watchdog.resetForNewTrack()
        startWatchdogTimerIfNeeded()
        setupNowPlaying()
        updateNowPlayingInfo()
        resetNowPlayingArtwork()
        fetchNowPlayingArtworkIfNeeded()
        recomputePlayingState()
        // b45-F: the transition settled — record the success
        // (resets the consecutive-failure count and the recovery
        // stage, banks the last-good URL/tier, persists the
        // confirmed quality badge), then honour a manual "next"
        // that arrived mid-transition.
        noteSuccessfulStart(item: item)
        endCrossfadeTransition()
        onTrackStarted?(item)
        if pendingManualNext {
            pendingManualNext = false
            next()
            return
        }
        if standbyEndedDuringCrossfade {
            standbyEndedDuringCrossfade = false
            advanceAuto()
        }
    }

    /// Shared success bookkeeping for a track that is now
    /// sounding (manual open + crossfade): reset the failure
    /// counters, bank the last-good URL/tier for quality-switch
    /// rollback, persist the confirmed quality badge, and kick
    /// the prefetcher for the upcoming tracks.
    private func noteSuccessfulStart(item: PlaybackItem) {
        consecutiveFailureCount = 0
        recoverStage = 0
        lastGoodURL = currentURL
        lastGoodQuality = actualQuality
        lastGoodItemID = item.id
        if let tier = actualQuality {
            ConfirmedQualityBadge.save(identityKey: item.id, quality: tier)
        }
        maybePrefetch()
    }

    /// Quality-switch rollback (plan §7.4): a failed quality
    /// switch returns to the exact URL / tier that was playing.
    /// No-op when nothing good was ever banked for this track.
    func rollbackToLastGoodQuality() {
        ensureMain {
            guard let item = self.currentTrack,
                  let url = self.lastGoodURL,
                  self.lastGoodItemID == item.id
            else { return }
            self.actualQuality = self.lastGoodQuality
            self.open(item: item, url: url) { _ in }
        }
    }

    /// Kick the prefetcher for the upcoming queue (b45-F). The
    /// prefetcher checks its own conditions and window; a new
    /// track start supersedes the previous round.
    private func maybePrefetch() {
        guard !queue.isEmpty, queueIndex >= 0, queueIndex < queue.count else { return }
        let upcoming = Array(queue[(queueIndex + 1)...].prefix(QueuePrefetcher.windowSongs))
        guard !upcoming.isEmpty else { return }
        prefetcher.prefetch(
            items: upcoming,
            conditions: QueuePrefetcher.Conditions(
                isPlaying: isPlaying,
                isBuffering: pendingItem != nil,
                cacheEnabled: HaoAudioCache.isEnabled(),
                networkConnected: DownloadEngine.shared.isNetworkAvailable,
                isMetered: DownloadEngine.shared.isMeteredNetwork,
                isConstrained: DownloadEngine.shared.isLowDataMode,
                isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled),
            resolveURL: { [weak self] item, completion in
                guard let self = self else { completion(nil, nil, false); return }
                self.resolveURL?(item, []) { url, tier in
                    let isTrial = url.map {
                        PreviewAudioClassifier.isPreviewURL($0.absoluteString, trialOnly: item.trialOnly)
                    } ?? false
                    completion(url, tier, isTrial)
                }
                if self.resolveURL == nil { completion(nil, nil, false) }
            },
            cachedBytes: { [weak self] item in
                guard let self = self else { return nil }
                if item.localFileURL != nil {
                    return (try? FileManager.default.attributesOfItem(
                        atPath: item.localFileURL!.path)[.size] as? NSNumber)?.int64Value ?? 0
                }
                guard let entry = HaoAudioCache.entry(
                    trackID: item.id, requestedQuality: "",
                    sourceIsNetease: false)
                else { return nil }
                return entry.byteCount
            },
            cacheDownload: { item, url, tier, completion in
                QueuePrefetcher.downloadIntoCache(item: item, url: url, tier: tier, completion: completion)
            })
    }

    /// Volume ramp helper (manual-open fade-in, resume fade-in).
    /// Generation-guarded: a newer load stops the stale ramp so it
    /// can never fight the new song's volume.
    /// `to` is the track gain; `from` is the engine's current
    /// volume. The ramp targets the gain directly (build 37: the
    /// Now Playing volume slider is deleted, so there is no user
    /// multiplier any more).
    private func rampVolume(engine: MusicPlayerEngine, from: Float, to: Float, duration: TimeInterval, gen: Int, completion: (() -> Void)?) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        let scaledTo = to
        guard duration > 0, from != scaledTo else {
            engine.volume = scaledTo
            completion?()
            return
        }
        let steps = max(1, Int(duration / 0.05))
        var step = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            guard gen == self.generation else {
                timer.invalidate()
                self.fadeTimer = nil
                return
            }
            step += 1
            let t = Float(step) / Float(steps)
            let liveTo = to
            engine.volume = from + (liveTo - from) * t
            if step >= steps {
                timer.invalidate()
                self.fadeTimer = nil
                completion?()
            }
        }
    }

    // MARK: - Time updates and watchdog

    private func handleTimeUpdate(pos: Double, duration dur: Double, engine: MusicPlayerEngine) {
        ensureMain {
            guard engine === self.activeEngine else { return }
            guard self.activeEngine.hasItem else { return }
            self.position = pos
            self.duration = dur
            self.recomputePlayingState()
            // Build 36 item 3, late check: when the asset duration
            // was still unknown at load, it arrives here instead.
            // Once per track, the first known duration is judged —
            // a ~30 s asset for a minutes-long song is a preview,
            // and recovery re-resolves with this URL excluded so
            // the next source is tried instead of the same clip.
            // The load-time check already cleared tracks whose
            // duration was known at load (`previewCheckedTrackID`).
            if let track = self.currentTrack,
               self.previewCheckedTrackID != track.id, dur > 0 {
                self.previewCheckedTrackID = track.id
                if PreviewAudioClassifier.isPreviewAsset(
                    actualDuration: dur,
                    expectedDuration: track.duration,
                    trialOnly: track.trialOnly) {
                    self.recoverFromFailure(
                        item: track,
                        excluding: self.currentURL.map { [$0] } ?? [])
                }
            }
            if Date().timeIntervalSince(self.lastNowPlayingElapsedUpdate) >= 1.0 {
                self.updateNowPlayingInfo()
            }
        }
    }

    private func startWatchdogTimerIfNeeded() {
        guard watchdogTimer == nil else { return }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
    }

    /// One watchdog tick. Test seam: tests call this directly with a
    /// driven fake clock instead of waiting real seconds.
    func testTickWatchdog() {
        watchdogTick()
    }

    private func watchdogTick() {
        // A seek in flight freezes the position by design: never
        // let the watchdog fail (and reopen) a track for a seek
        // that is still running. The 20 s safety clears a flag
        // whose engine never called its seek completion.
        if seekInFlight {
            if let started = seekStartedAt, Date().timeIntervalSince(started) > 20 {
                seekInFlight = false
                seekStartedAt = nil
            } else {
                return
            }
        }
        guard currentTrack != nil, activeEngine.hasItem else { return }
        let event = watchdog.tick(
            position: activeEngine.currentTimeSeconds,
            duration: activeEngine.durationSeconds,
            isPlaying: playRequested
        )
        switch event {
        case .none:
            return
        case .warn:
            NotificationCenter.default.post(
                name: .haoMusicStallWarning,
                object: self,
                userInfo: [MusicNotificationKeys.trackId: currentTrack?.id ?? ""]
            )
        case .atEnd:
            playRequested = false
            advanceAuto()
        case .failed:
            stallFailed = true
            playRequested = false
            recomputePlayingState()
            NotificationCenter.default.post(
                name: .haoMusicStallFailed,
                object: self,
                userInfo: [MusicNotificationKeys.trackId: currentTrack?.id ?? ""]
            )
            if let item = currentTrack {
                // Build 36 item 3: exclude the stalled URL, same as
                // the engine-failure path above.
                recoverFromFailure(item: item, excluding: currentURL.map { [$0] } ?? [])
            }
        }
    }

    /// Stall / failure recovery: one fallback re-resolution of the
    /// same track, reopened at the last known position; if that
    /// fails, auto-advance to the next track per the play mode.
    /// Never loops: one re-resolve, then advance or stop.
    /// `excluding` lists URLs that must not come back (build 36
    /// item 3: a URL that failed, or proved to be a 30 s preview,
    /// is never handed out twice — the resolver skips it and the
    /// coordinator evicts it from cache first).
    /// b45-F staged failure recovery (plan §7.4):
    /// - Stage 0 → 1: the failing URL is a NetEase CDN host →
    ///   retry the SAME URL on the twin host once, resuming from
    ///   the breakpoint.
    /// - Stage 1 → 2: full re-resolve (skipping the failed URL;
    ///   the local copy is stripped by
    ///   resolveItemSkippingExcludedLocal when it is the failed
    ///   one, so the coordinator never re-offers it), resuming
    ///   from the breakpoint.
    /// - Stage 2: offline → the downloaded copy (only when it is
    ///   not the failed one); online → the serial multi-source
    ///   resolve already ran, so advance to the next track. Five
    ///   consecutive unplayable tracks stop playback.
    private func recoverFromFailure(item: PlaybackItem, excluding: [URL] = []) {
        let resumePosition = position
        let gen = nextGeneration()
        // b44: recovery resolves after the engine died — audio has
        // stopped, so the same suspension window as a switch applies.
        beginSwitchBackgroundTask()
        // Stage 0: twin-host retry of the same URL.
        if recoverStage == 0,
           let current = currentURL,
           let twin = NeteaseCDNHostFailover.twinHostURL(for: current),
           twin != current {
            recoverStage = 1
            // A pre-request failure on this host also marks it
            // unreachable for 10 minutes (the twin is preferred
            // next time); a mid-stream failure does not.
            open(item: item, url: twin) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success:
                    self.actualQuality = self.lastGoodQuality
                    if resumePosition > 0 {
                        self.seek(to: resumePosition) { _ in }
                    }
                case .failure:
                    self.recoverFromFailure(item: item, excluding: excluding)
                }
            }
            return
        }
        let timeoutId = beginResolveTimeout { [weak self] in
            guard let self = self else { return }
            guard gen == self.generation, self.currentTrack?.id == item.id else { return }
            self.noteFailedAdvance(item: item)
        }
        resolveURL?(resolveItemSkippingExcludedLocal(item, excluding: excluding), excluding) { [weak self] url, tier in
            guard let self = self else { return }
            self.ensureMain {
                self.cancelResolveTimeout(id: timeoutId)
                guard gen == self.generation, self.currentTrack?.id == item.id else { return }
                guard let url = url else {
                    // Stage 2: the re-resolve found nothing.
                    // Offline → downloaded copy, unless that copy
                    // is the failed one; online → next.
                    if self.isOffline, let local = self.localAudioURL?(item) ?? item.localFileURL,
                       !excluding.contains(local) {
                        self.open(item: item, url: local) { [weak self] result in
                            guard let self = self else { return }
                            switch result {
                            case .success:
                                if resumePosition > 0 { self.seek(to: resumePosition) { _ in } }
                            case .failure:
                                self.noteFailedAdvance(item: item)
                            }
                        }
                    } else {
                        self.noteFailedAdvance(item: item)
                    }
                    return
                }
                self.recoverStage = 2
                self.actualQuality = tier
                self.open(item: item, url: url) { [weak self] result in
                    guard let self = self else { return }
                    switch result {
                    case .success:
                        if resumePosition > 0 {
                            self.seek(to: resumePosition) { _ in }
                        }
                    case .failure:
                        self.noteFailedAdvance(item: item)
                    }
                }
            }
        }
        if resolveURL == nil {
            noteFailedAdvance(item: item)
        }
    }

    /// b49sweep P1-8: a copy of the item with its local file URL
    /// stripped when that URL is among the failed/tried ones. The
    /// coordinator's resolveURL returns item.localFileURL FIRST
    /// (before honouring `excluding`), so a failed local or
    /// downloaded copy would be re-offered forever during a
    /// retry chain. The copy keeps the same id (the resolver's
    /// eviction key), so only the local-first offer changes —
    /// no coordinator-side flag is needed.
    private func resolveItemSkippingExcludedLocal(_ item: PlaybackItem, excluding: [URL]) -> PlaybackItem {
        guard let local = item.localFileURL, excluding.contains(local) else { return item }
        return PlaybackItem(
            id: item.id, songId: item.songId, title: item.title, artist: item.artist,
            album: item.album, coverURL: item.coverURL, previewURL: item.previewURL,
            localFileURL: nil, duration: item.duration, isLocal: item.isLocal,
            audioQuality: item.audioQuality, playSource: item.playSource,
            isDownloaded: item.isDownloaded)
    }

    /// Count one unplayable track toward the 5-in-a-row stop
    /// (plan §7.4). A success anywhere resets the count (see
    /// noteSuccessfulStart).
    private func noteFailedAdvance(item: PlaybackItem) {
        consecutiveFailureCount += 1
        failedTrackIds.insert(item.id)
        recoverStage = 0
        if consecutiveFailureCount >= 5 {
            consecutiveFailureCount = 0
            stop()
            return
        }
        advanceAuto()
    }

    // MARK: - Loudness and normalisation

    /// Record a track's integrated loudness (LUFS), measured during
    /// playback in the EQ tap. Stored under the identity key the tap
    /// was stamped with, never under the current track: a report for
    /// a stale key is kept under that key and never changes the
    /// sounding track's gain. In-memory cap 200, oldest dropped;
    /// persisted best-effort so the second-play effect survives a
    /// restart. Never pre-downloads or decodes a track for loudness.
    func noteMeasuredLoudness(_ identityKey: String, _ lufs: Double) {
        guard !identityKey.isEmpty, lufs.isFinite else { return }
        measuredLoudness.removeValue(forKey: identityKey)
        measuredLoudness[identityKey] = min(0.0, max(-70.0, lufs))
        while measuredLoudness.count > 200 {
            measuredLoudness.removeValue(forKey: measuredLoudness.keys.first!)
        }
        persistLoudnessCache()
    }

    /// The gain the player volume should sit at for a track: 1.0
    /// unless normalisation is on AND this track has a measured
    /// loudness. Applies to the next load, never mid-song.
    func normalizationGain(for item: PlaybackItem) -> Double {
        guard normalizationEnabled else { return 1.0 }
        guard let lufs = measuredLoudness[item.id] else { return 1.0 }
        return MusicNormalization.gainLinear(lufs: lufs, strength: normalizationStrength)
    }

    func setNormalizationEnabled(_ value: Bool) {
        ensureMain {
            self.normalizationEnabled = value
            self.defaults.set(value, forKey: "hao_music_normalization_enabled")
        }
    }

    func setNormalizationStrength(_ strength: Int) {
        ensureMain {
            let clamped = min(2, max(0, strength))
            self.normalizationStrength = clamped
            self.defaults.set(clamped, forKey: "hao_music_normalization_strength")
        }
    }

    private func loudnessCacheURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hao_music_loudness_cache.json")
    }

    private func loadLoudnessCache() {
        guard let data = try? Data(contentsOf: loudnessCacheURL()),
              let raw = try? JSONDecoder().decode([String: Double].self, from: data) else { return }
        measuredLoudness = MusicNormalization.parseLoudnessCache(raw)
    }

    private func persistLoudnessCache() {
        guard let data = try? JSONEncoder().encode(measuredLoudness) else { return }
        try? data.write(to: loudnessCacheURL(), options: [.atomic])
    }

    // MARK: - Equalizer passthrough

    /// Apply EQ settings (UI leg calls this). Persists under the
    /// `hao_eq_*` keys and pushes the new curve to the live taps.
    /// A5: when the enabled switch flips, the already-loaded item
    /// gets its audioMix re-attached / detached now — otherwise the
    /// flip only takes effect on the next song (gain slides already
    /// worked mid-song via the revision mechanism; only the switch
    /// did not).
    func applyEqualizer(_ settings: EqualizerSettings) {
        ensureMain {
            let wasEnabled = self.equalizer.settings.enabled
            self.equalizer.applyEqualizer(settings)
            if wasEnabled != settings.enabled {
                (self.activeEngine as? AVPlayerEngine)?.refreshAudioMix()
                if self.standbyEngine.hasItem {
                    (self.standbyEngine as? AVPlayerEngine)?.refreshAudioMix()
                }
            }
        }
    }

    func applyEqualizerPreset(_ preset: EqualizerPreset) {
        ensureMain { self.equalizer.applyPreset(preset) }
    }

    // MARK: - Interruption

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            guard isPlaying else { return }
            wasPlayingBeforeInterruption = true
            pause()
        case .ended:
            guard wasPlayingBeforeInterruption else { return }
            wasPlayingBeforeInterruption = false
            if let optionsRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                if options.contains(.shouldResume) { resume() }
            }
        @unknown default:
            break
        }
    }

    // MARK: - Now Playing and remote commands

    /// Remote next / previous handler installed by
    /// MusicPlayerViewModel (b41, chen 2026-11-25: the lock-screen /
    /// Dynamic Island / Control Center buttons did nothing). The
    /// view model is the single app-level owner of the queue, so
    /// remote commands run its live queue — exactly the in-app
    /// buttons' path — instead of this player's own queue, which
    /// goes stale after play-next inserts / removals (only
    /// startPlayback re-syncs it) and has no currentTrack-nil
    /// fallback. Nil (no view model yet) falls back to this
    /// player's own next() / previous(). The view model lives for
    /// the app lifetime, so the closures never go stale.
    var onRemoteNext: (() -> Void)?
    var onRemotePrevious: (() -> Void)?
    /// Remote-like handler installed by MusicPlayerViewModel
    /// (b45-a): Control Center's like command toggles the same
    /// favourite as the in-app heart. Nil falls back to "no such
    /// content" — the command is only meaningful with a view model.
    var onRemoteLike: (() -> Void)?

    /// Push the current favourite state to the Control Center like
    /// command (b45-a, NowPlayingManager.refreshLikeState):
    /// likeCommand.isActive follows whether the current song is
    /// liked. A no-op until setupNowPlaying has run.
    func refreshLikeCommand(isLiked: Bool) {
        guard nowPlayingActive else { return }
        MPRemoteCommandCenter.shared().likeCommand.isActive = isLiked
    }

    private func setupNowPlaying() {
        guard !nowPlayingActive else { updateNowPlayingInfo(); return }
        nowPlayingActive = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget(self, action: #selector(remotePlay))
        center.pauseCommand.addTarget(self, action: #selector(remotePause))
        center.togglePlayPauseCommand.addTarget(self, action: #selector(remoteToggle))
        center.changePlaybackPositionCommand.addTarget(self, action: #selector(remoteSeek(_:)))
        // b42 (chen 2026-11-25 build 41: Control Center shows ONLY
        // [10s-back] [pause] [10s-forward], no prev/next buttons):
        // registering skipForward/skipBackward alongside next/prev
        // makes iOS pick the SKIP layout instead of the TRACK layout
        // — the two command sets are alternatives, not additive
        // (RxMusicPlayer: .moveTrack vs .skip(second:) are mutually
        // exclusive remote-control modes, switched by removing and
        // re-adding targets). The b41 queue fix never got a chance
        // to run because the buttons did not exist. Only the track
        // commands are registered now, so the system UI shows the
        // Apple Music prev/next layout. The in-app ±10s seek buttons
        // are SwiftUI buttons in the player view and are untouched.
        center.nextTrackCommand.addTarget(self, action: #selector(remoteNext))
        center.previousTrackCommand.addTarget(self, action: #selector(remotePrevious))
        // b45-a (Coda NowPlayingManager, like ~L55-70): the like
        // command — Control Center long-press likes the current
        // track, and isActive follows the favourite state (see
        // refreshLikeCommand, driven by the view model). Only
        // next/previous are track commands otherwise (b42: no
        // ±15s skip commands — the skip layout would hide the
        // track buttons).
        center.likeCommand.isEnabled = true
        center.likeCommand.addTarget(self, action: #selector(remoteLike))
        updateNowPlayingInfo()
    }

    private func teardownNowPlaying() {
        guard nowPlayingActive else { return }
        nowPlayingActive = false
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(self)
        center.pauseCommand.removeTarget(self)
        center.togglePlayPauseCommand.removeTarget(self)
        center.changePlaybackPositionCommand.removeTarget(self)
        // b42: skipForward/skipBackward are no longer registered
        // (see setupNowPlaying) — nothing to remove here.
        center.nextTrackCommand.removeTarget(self)
        center.previousTrackCommand.removeTarget(self)
        center.likeCommand.removeTarget(self)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// `MusicPlaybackDriver` witness (b45 M2): the coordinator
    /// clears the music card when VOD/live takes the single Now
    /// Playing slot. stop() already tears down; this is the
    /// handle for switches that bypass a music stop.
    func clearNowPlaying() {
        teardownNowPlaying()
        // b47 (chen 2026-11-25 build 46: 灵动岛/锁屏/控制中心不能切歌):
        // a failure clear must not leave a dead card while the song
        // is still loaded — restore the registration at once so the
        // next/previous buttons keep working (a tap on next is then
        // just a retry). Safe by construction: stop() nils
        // currentTrack before its teardown, and requestVodPlay /
        // requestLivePlay stop music first, so a domain switch never
        // re-registers here — only the engine-failure path
        // (onTrackFailed, same-id guard, track still loaded) does.
        if currentTrack != nil {
            setupNowPlaying()
        }
    }

    private func updateNowPlayingInfo() {
        // b47 (chen 2026-11-25 build 46: 灵动岛/锁屏/控制中心不能切歌):
        // self-heal — the registration is built only on a successful
        // load (startPlaybackAfterLoad / finishCrossfade) but torn
        // down on every stop() and every failure clear, so any
        // pause/resume/seek/speed refresh after a teardown silently
        // returned with the card dead. While a track is still loaded,
        // rebuild the registration first (setupNowPlaying ends by
        // refreshing the info itself, so nothing is lost); with no
        // track loaded there is nothing to restore.
        if !nowPlayingActive, currentTrack != nil {
            ensureMain { self.setupNowPlaying() }
            return
        }
        guard nowPlayingActive, let track = currentTrack else { return }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artist ?? ""
        // E4/B2: the real album when known; "HAo Studio" only as
        // the fallback for tracks without one.
        info[MPMediaItemPropertyAlbumTitle] = track.album ?? "HAo Studio"
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if position >= 0 { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackSpeed : 0.0
        if let art = nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastNowPlayingElapsedUpdate = Date()
    }

    private func fetchNowPlayingArtworkIfNeeded() {
        guard let coverURL = Self.upgradedArtworkURL(currentTrack?.coverURL),
              nowPlayingArtwork == nil else { return }
        guard nowPlayingArtworkAttempts < Self.nowPlayingArtworkMaxAttempts else { return }
        let trackId = currentTrack?.id
        let attempt = nowPlayingArtworkAttempts + 1
        nowPlayingArtworkAttempts = attempt
        // Shared loader (build 36 item 10 leg 6): the player cover
        // already fetched this URL — the loader checks the memory
        // / disk cache first instead of a third independent
        // download, and downsamples to 1024pt (b45-a, Coda
        // NowPlayingManager: lock-screen artwork at 1024px, so
        // opening it from the lock screen never goes blurry). The
        // 3-attempt budget and backoff below are unchanged; the
        // loader completion already runs on the main queue, so the
        // old DispatchQueue.main hop inside the fetch is gone.
        HaoImageLoader.shared.load(
            urlString: coverURL.absoluteString,
            targetWidthPoints: 1024,
            targetHeightPoints: 1024
        ) { [weak self] image in
            guard let self = self else { return }
            if let image = image {
                let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                // A slow fetch from the previous track must never
                // paint its art onto the new one.
                guard self.currentTrack?.id == trackId,
                      self.nowPlayingArtwork == nil else { return }
                self.nowPlayingArtwork = art
                self.updateNowPlayingInfo()
                return
            }
            NSLog("[HAoStudio][Music] Now Playing artwork fetch failed (attempt %d/%d) track=%@",
                  Int32(attempt), Int32(Self.nowPlayingArtworkMaxAttempts), trackId ?? "")
            // Retry on the main queue after a backoff, unless the
            // track already changed (then the next track's own
            // fetch takes over).
            let delay = Self.nowPlayingArtworkRetryDelay(forAttempt: attempt)
            guard delay > 0 else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.currentTrack?.id == trackId else { return }
                self.fetchNowPlayingArtworkIfNeeded()
            }
            self.nowPlayingArtworkRetryWork?.cancel()
            self.nowPlayingArtworkRetryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Track changed: drop the artwork, its retry state and any
    /// pending retry, so a late fetch can never paint the old
    /// track's art onto the new one.
    private func resetNowPlayingArtwork() {
        nowPlayingArtwork = nil
        nowPlayingArtworkAttempts = 0
        nowPlayingArtworkRetryWork?.cancel()
        nowPlayingArtworkRetryWork = nil
    }

    /// Artwork fetch budget: 3 attempts per track.
    static let nowPlayingArtworkMaxAttempts = 3

    /// Backoff (seconds) before the retry after `attempt`
    /// (attempts are 1-based; 0 after the last attempt).
    static func nowPlayingArtworkRetryDelay(forAttempt attempt: Int) -> TimeInterval {
        switch attempt {
        case 1: return 1.0
        case 2: return 3.0
        default: return 0
        }
    }

    /// http -> https for an artwork URL (ATS blocks http under
    /// NSAllowsArbitraryLoads = false). Same rule as
    /// MusicText.toHttps, kept local so this file stays
    /// self-contained for the MusicCore test target (it does not
    /// compile the MusicResolvers dir).
    static func upgradedArtworkURL(_ url: URL?) -> URL? {
        guard let url = url else { return nil }
        guard url.scheme?.lowercased() == "http" else { return url }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.scheme = "https"
        return parts?.url ?? url
    }

    @objc private func remotePlay() -> MPRemoteCommandHandlerStatus {
        resume()
        return .success
    }

    @objc private func remotePause() -> MPRemoteCommandHandlerStatus {
        pause()
        return .success
    }

    @objc private func remoteToggle() -> MPRemoteCommandHandlerStatus {
        toggle()
        return .success
    }

    @objc private func remoteSeek(_ event: MPChangePlaybackPositionCommandEvent) -> MPRemoteCommandHandlerStatus {
        seek(to: event.positionTime) { _ in }
        return .success
    }

    @objc private func remoteNext() -> MPRemoteCommandHandlerStatus {
        handleRemoteNext()
        return .success
    }

    @objc private func remotePrevious() -> MPRemoteCommandHandlerStatus {
        handleRemotePrevious()
        return .success
    }

    /// Control Center like (b45-a): toggles the favourite through
    /// the view model — the same path as the in-app heart — so the
    /// two stay in sync. Runs on main: the view model's queue is
    /// main-confined.
    @objc private func remoteLike() -> MPRemoteCommandHandlerStatus {
        guard let handler = onRemoteLike else { return .commandFailed }
        ensureMain {
            handler()
        }
        return .success
    }

    /// Remote-next dispatch (b41, internal for tests): the view
    /// model's handler when installed — the same live-queue path
    /// as the in-app buttons — else this player's own next().
    /// Runs on main: the view model's queue is main-confined.
    func handleRemoteNext() {
        ensureMain {
            if let handler = self.onRemoteNext {
                handler()
            } else {
                self.next()
            }
        }
    }

    /// Remote-previous dispatch (b41): same contract as
    /// handleRemoteNext.
    func handleRemotePrevious() {
        ensureMain {
            if let handler = self.onRemotePrevious {
                handler()
            } else {
                self.previous()
            }
        }
    }
}

// MARK: - AirPlay

/// Real AirPlay picker (AVRoutePickerView). The UI leg places this
/// view in the player interface; this leg only provides the wrapper.
struct AirPlayPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - b45-F: queue prefetcher (plan §7.4 / §9.2)
//
// Window: 5 songs / 20 minutes / 100 MB. Only while playing,
// not buffering, cache on, network connected / unmetered /
// unconstrained, and not in Low Power Mode. One bounded worker,
// sequential. Already-cached tracks only count their bytes;
// uncached tracks resolve a URL and download the whole file.
// A full window stops the round; a network error ends the round
// without retry. Trial clips are never prefetched and never
// cached. Unlike Coda, "always highest" does NOT disable
// prefetch — it prefetches the target tier (the resolve closure
// already carries the coordinator's target quality).

final class QueuePrefetcher {
    static let windowSongs = 5
    static let windowMinutes: TimeInterval = 20 * 60
    static let windowBytes: Int64 = 100 * 1024 * 1024

    struct Conditions {
        var isPlaying: Bool
        var isBuffering: Bool
        var cacheEnabled: Bool
        var networkConnected: Bool
        var isMetered: Bool
        var isConstrained: Bool
        var isLowPowerMode: Bool

        var permits: Bool {
            isPlaying && !isBuffering && cacheEnabled
                && networkConnected && !isMetered && !isConstrained
                && !isLowPowerMode
        }
    }

    private let workQueue = DispatchQueue(label: "com.haostudio.prefetch")
    private var generation = 0

    /// Cancel any in-flight round (queue / track change, stop).
    func cancel() {
        workQueue.async { self.generation += 1 }
    }

    /// Run one prefetch round over `items` (already limited to
    /// the window size by the caller). All work is sequential on
    /// the worker queue; a new round supersedes this one.
    func prefetch(
        items: [PlaybackItem],
        conditions: Conditions,
        resolveURL: @escaping (PlaybackItem, @escaping (URL?, AudioQuality?, Bool) -> Void) -> Void,
        cachedBytes: @escaping (PlaybackItem) -> Int64?,
        cacheDownload: @escaping (PlaybackItem, URL, AudioQuality?, @escaping (Int64?) -> Void) -> Void
    ) {
        workQueue.async {
            self.generation += 1
            let gen = self.generation
            guard conditions.permits else { return }
            var songs = 0
            var accountedSeconds: TimeInterval = 0
            var accountedBytes: Int64 = 0
            for item in items {
                guard gen == self.generation else { return } // superseded
                guard songs < Self.windowSongs,
                      accountedSeconds < Self.windowMinutes,
                      accountedBytes < Self.windowBytes
                else { return } // window full: stop
                // Trial clips are never prefetched.
                if item.trialOnly { continue }
                if let bytes = cachedBytes(item) {
                    // Already cached: only count the bytes.
                    songs += 1
                    accountedSeconds += item.duration ?? 0
                    accountedBytes += bytes
                    continue
                }
                // Resolve, then download the whole file.
                let resolved = self.waitForResolve(item: item, resolveURL: resolveURL)
                guard gen == self.generation else { return }
                guard let url = resolved.url, !resolved.isTrial else { continue }
                guard let downloaded = self.waitForDownload(
                    item: item, url: url, tier: resolved.tier, cacheDownload: cacheDownload)
                else { return } // network error ends the round, no retry
                songs += 1
                accountedSeconds += item.duration ?? 0
                accountedBytes += downloaded
            }
        }
    }

    private func waitForResolve(
        item: PlaybackItem,
        resolveURL: @escaping (PlaybackItem, @escaping (URL?, AudioQuality?, Bool) -> Void) -> Void
    ) -> (url: URL?, tier: AudioQuality?, isTrial: Bool) {
        var result: (url: URL?, tier: AudioQuality?, isTrial: Bool) = (nil, nil, false)
        let semaphore = DispatchSemaphore(value: 0)
        resolveURL(item) { url, tier, isTrial in
            result = (url, tier, isTrial)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private func waitForDownload(
        item: PlaybackItem,
        url: URL,
        tier: AudioQuality?,
        cacheDownload: @escaping (PlaybackItem, URL, AudioQuality?, @escaping (Int64?) -> Void) -> Void
    ) -> Int64? {
        var result: Int64?
        let semaphore = DispatchSemaphore(value: 0)
        cacheDownload(item, url, tier) { bytes in
            result = bytes
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    /// Whole-file download into the audio cache (the prefetch
    /// download leg). Streams the temp file into the cache writer
    /// in 64 KB chunks — the whole file is never held in memory.
    /// Returns the cached byte count, 0 when the file was over
    /// the cap (stream-only, not an error), nil on network error.
    static func downloadIntoCache(
        item: PlaybackItem,
        url: URL,
        tier: AudioQuality?,
        completion: @escaping (Int64?) -> Void
    ) {
        let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
            guard error == nil, let tempURL = tempURL else {
                completion(nil)
                return
            }
            let ext: String
            if let mime = (response as? HTTPURLResponse)?.mimeType, !mime.isEmpty {
                ext = HaoAudioCache.fileExtension(forMimeType: mime)
            } else if !url.pathExtension.isEmpty {
                ext = url.pathExtension
            } else {
                ext = "mp3"
            }
            guard let writer = HaoAudioCache.StreamingWriter(
                trackID: item.id,
                requestedQuality: tier?.lxCode ?? "",
                servedQuality: tier?.lxCode ?? "",
                source: "prefetch",
                servedBitrate: 0,
                fileExtension: ext)
            else {
                completion(0)
                return
            }
            guard let handle = try? FileHandle(forReadingFrom: tempURL) else {
                writer.cancel()
                completion(nil)
                return
            }
            while true {
                let chunk = handle.readData(ofLength: 64 * 1024)
                if chunk.isEmpty { break }
                writer.append(chunk)
            }
            try? handle.close()
            if let entry = writer.finish() {
                completion(entry.byteCount)
            } else {
                completion(0) // over the cap: stream-only, not an error
            }
        }
        task.resume()
    }
}

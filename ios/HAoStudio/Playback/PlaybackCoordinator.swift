// HAo Studio 2.0 — playback coordinator SHELL (foundation slice).
//
// This file is an interface + rules only. There is NO engine, NO parsing
// and NO network here; the player slice wires the engines behind it.
// Nothing in the foundation UI calls `requestPlay`, so `currentItem`
// stays nil and the mini player stays hidden until the player slice
// lands — the shell must never pretend something is playing.
//
// Iron laws encoded here (chen 2026-11-16/17 — the coordinator exists
// so these rules have exactly one enforcement point, not one copy per
// player):
//
// 1. ONE SOUND AT A TIME. Starting any kind of playback stops whatever
//    is currently playing first (music / VOD / live never overlap).
// 2. MUSIC USES AVPLAYER ONLY. Music never follows the video/live
//    kernel selector (MPV / IJK / AVPlayer) — that selector is video
//    and live only. Lyrics go BEHIND the cover (tap cover -> lyrics in
//    the cover area; tap lyrics blank -> cover back; tap a lyric line
//    -> seek). The player slice must honour both.
// 3. VOD AND LIVE ARE DIFFERENT PLAYERS, never mixed:
//    - Quality selector: LIVE ONLY, never on VOD (Apple CMS gives one
//      play URL per episode — no quality tiers, so no fake button).
//    - Long-press 2x speed: VOD ONLY (live is real-time and cannot be
//      sped up).
//    - Live switches stream ONLY when stalled; it never proactively
//      switches to a "better" line.
//    - Entry orientation: VOD tap-play goes DIRECTLY landscape
//      fullscreen; live enters PORTRAIT and only the [] button takes
//      it landscape.
// 4. SOURCE RESOLUTION IS SERIAL, FASTEST FIRST. Ask sources one by
//    one in speed order; the FIRST source that returns a playable URL
//    plays immediately — never ask all sources, never wait for a higher
//    tier once a playable URL exists. If the target quality has no URL,
//    play one tier down AT ONCE and keep the target quality for the
//    next track. (`SourceResolver` below is the contract; the player
//    slice implements it.)
// 5. NO LOGIN-GATED FEATURES. The app has no login interface: comment
//    posting, like/follow sync to platform accounts and anything else
//    that needs a platform login must not be added behind this
//    coordinator. Likes are stored locally only; comments are read-only.

import Foundation

/// What kind of playback a request is. VOD and live are distinct cases
/// on purpose — no shared "video" case that could blur rule 3.
enum PlaybackKind: String, Equatable {
    case music
    case vod
    case live
}

/// Audio-quality target tier. The target persists to the next track;
/// a lower tier plays immediately as a drop-down, never labelled as
/// the target tier (Master honesty gate: only a real Master URL
/// satisfies Master).
enum AudioQuality: String, CaseIterable {
    case master
    case hiRes
    case flac
    case high320
    case standard128

    var displayName: String {
        switch self {
        case .master: return "Master"
        case .hiRes: return "Hi-Res"
        case .flac: return "无损 FLAC"
        case .high320: return "高音质 320k"
        case .standard128: return "标准 128k"
        }
    }
}

/// One playable item, as far as the foundation shell knows it.
/// No URL lives here: the URL is resolved at play time by the
/// SourceResolver (rule 4), never stored ahead of playback.
struct PlaybackItem: Identifiable, Equatable {
    let id: String
    let kind: PlaybackKind
    let title: String
    let artist: String?
    /// the player shows title/artist without artwork then. Added by
    /// the S2 music leg with a default so existing constructions keep
    /// compiling.
    let coverURL: URL?

    /// Local file to play directly (downloads / local music). When
    /// set, the coordinator returns this URL without asking the LX
    /// resolver — local files never go through network resolution.
    let localFileURL: URL?

    /// Album name for Now Playing (B2/E4). Nil when unknown — the
    /// player falls back to "HAo Studio" then. Added with a
    /// default so existing constructions keep compiling.
    let album: String?

    /// Expected full length in seconds, from search metadata
    /// (build 36 item 3). Nil when unknown (local files, restored
    /// queue items): the preview-duration check never fires without
    /// an expectation to compare against.
    let duration: TimeInterval?

    /// Search-time VIP-only flag (build 36 item 3): NetEase
    /// `fee != 0` / `privilege` `none`, QQ `pay.payplay` — the
    /// track is trial-only for a no-login client. Only ever
    /// tightens preview detection; never skips a source by itself.
    let trialOnly: Bool

    var subtitle: String { artist ?? kindSubtitle }

    init(id: String, kind: PlaybackKind, title: String, artist: String?,
         coverURL: URL? = nil, localFileURL: URL? = nil, album: String? = nil,
         duration: TimeInterval? = nil, trialOnly: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.artist = artist
        self.coverURL = coverURL
        self.localFileURL = localFileURL
        self.album = album
        self.duration = duration
        self.trialOnly = trialOnly
    }

    private var kindSubtitle: String {
        switch kind {
        case .music: return "音乐"
        case .vod: return "影视"
        case .live: return "直播"
        }
    }
}

/// Serial source resolution (rule 4). The player slice implements this:
/// ask sources one by one, fastest first, and call `completion` with the
/// FIRST playable URL — never collect all candidates, never hold playback
/// for a higher tier. `completion(nil)` only when every source returned
/// nothing. `excluding` lists URLs that already failed for this request
/// — or proved to be 30 s previews (build 36 item 3) — so the resolver
/// hands out the next candidate instead of repeating one. Completion-handler
/// style (not async/await): the project keeps SWIFT_VERSION = 5.0 from
/// the old project, and concurrency needs Swift 5.5+.
protocol SourceResolver {
    func resolveFirstPlayable(
        for item: PlaybackItem,
        targetQuality: AudioQuality?,
        excluding: [URL],
        completion: @escaping (URL?) -> Void
    )
}

/// A resolver that reports the tier actually played by its last
/// resolve (Master honesty gate: the quality badge shows the real
/// tier, never the target). The LX resolver conforms; resolvers
/// that cannot report a tier simply do not conform, and the tier
/// stays nil (unknown).
protocol TierReportingResolver {
    var lastResolvedTier: AudioQuality? { get }
}

/// A resolver that can drop cached play URLs (S2 leg B exposed
/// `evictPlayUrl` on LXSourceResolver). The coordinator uses it to
/// honour `excluding`: a URL that failed at playback must never be
/// served from cache again on the fallback resolve. The method is
/// keyed by (songId, platform, quality), not by URL, so the
/// coordinator evicts every tier for the song — the failed URL
/// may have come from a below-target tier (downgrade), and
/// evicting only the target tier could leave the dead URL cached
/// under the tier that actually served it.
protocol PlayURLEvictingResolver {
    func evictPlayUrl(songId: String, platform: MusicPlatform, quality: AudioQuality)
}

// LXSourceResolver already exposes exactly this method (S2 leg B);
// this declaration only states the conformance, so the coordinator
// can use it without knowing the concrete resolver class.
extension LXSourceResolver: PlayURLEvictingResolver {}

// b46: the failure-memory clear lives on LXSourceResolver itself.
extension LXSourceResolver: FailureMemoryClearingResolver {}

/// A resolver that remembers per-source+song failures (b45-F).
/// A manual play clears the memory for one song so a transient
/// failure never makes it unplayable for 10 minutes (b46).
/// Resolvers without a memory are unaffected (default no-op).
protocol FailureMemoryClearingResolver {
    func clearFailureMemory(forSongId songId: String)
}

extension FailureMemoryClearingResolver {
    func clearFailureMemory(forSongId songId: String) {}
}

// MARK: - Player errors and driver contract (moved from
// NativeMusicPlayer.swift at the S2 merge: the MusicLX SwiftPM test
// target compiles this file without the iOS-only player file, so the
// contracts the coordinator programs against live here.)

/// Structured open/seek errors (P0-04). A timeout is handled exactly
/// like a stream error: the load is dropped and the caller falls
/// back to the next candidate.
enum MusicPlayerError: Error, Equatable {
    case timeout
    case noPlayableURL
    case loadFailed
    case seekFailed
    /// The room is not live (the platform said so). Shown as
    /// "房间未开播", not "没有可播放的地址" (b39).
    case offline
    /// No engine can play this stream's format (b49 sweep #28):
    /// the live driver's counterpart of VOD's
    /// VideoPlaybackFailure.unsupportedFormat — a format problem
    /// re-parsing cannot fix, so the driver fails at once with
    /// this instead of a generic network error.
    case unsupportedFormat
}

extension MusicPlayerError: LocalizedError {
    /// Human-readable reason for the failure card (build 37,
    /// D10): the room page shows this under the placeholder
    /// with a retry button. A plain enum has no description of
    /// its own, so without this the card would show the
    /// generated "The operation couldn't be completed" text.
    var errorDescription: String? {
        switch self {
        case .timeout:
            return "打开超时，请检查网络后重试"
        case .noPlayableURL:
            return "没有可播放的地址"
        case .loadFailed:
            return "播放失败，请检查网络后重试"
        case .seekFailed:
            return "跳转失败"
        case .offline:
            return "房间未开播"
        case .unsupportedFormat:
            return "此格式暂不支持播放"
        }
    }
}

/// What PlaybackCoordinator needs from the music player. The
/// coordinator owns the resolver and the current-item bookkeeping;
/// the player owns engines, queue and modes. The coordinator wires
/// `resolveURL` to its resolver (serial, fastest first) and listens
/// to `onTrackStarted` / `onTrackFailed` to keep `currentItem` in
/// sync with the player's `currentTrack`.
protocol MusicPlaybackDriver: AnyObject {
    var currentTrack: PlaybackItem? { get }
    var isPlaying: Bool { get }
    /// Resolve a playable URL for an item. `excluding` lists URLs
    /// that already failed for this request, so the resolver can
    /// hand out the next candidate instead of repeating one. The
    /// second value is the actual tier the URL plays at, when the
    /// resolver knows it; nil means unknown, never the target tier.
    var resolveURL: ((PlaybackItem, [URL], @escaping (URL?, AudioQuality?) -> Void) -> Void)? { get set }
    var onTrackStarted: ((PlaybackItem) -> Void)? { get set }
    var onTrackFailed: ((PlaybackItem, MusicPlayerError) -> Void)? { get set }
    func play(item: PlaybackItem)
    func open(item: PlaybackItem, url: URL, completion: @escaping (Result<Void, MusicPlayerError>) -> Void)
    func pause()
    func stop()
    func resume()
    /// Clear this driver's Now Playing registration + info
    /// (b45 M2: the coordinator switches the single Now Playing
    /// slot between domains — music / VOD / live — so a stale
    /// music card must not survive a switch to VOD/live).
    /// The music driver's stop() already tears down; this is the
    /// handle the coordinator uses when another domain starts
    /// without going through a music stop.
    func clearNowPlaying()
}

/// What PlaybackCoordinator needs from the VOD player (S3). The
/// coordinator owns mutual exclusion (rule 1) and current-item
/// bookkeeping; the video driver owns engines (MPV / IJK / AVPlayer
/// via PlayerKernel), episode/line state and resume. URL resolution
/// lives inside the video driver (CMS / Emby), never in this file.
/// VOD never follows the music quality selector and never shows a
/// quality button (rule 3). Reuses MusicPlayerError: it is a
/// generic player error (timeout / no URL / load / seek failed),
/// not music-specific despite the name.
protocol VideoPlaybackDriver: AnyObject {
    var currentEpisode: PlaybackItem? { get }
    var isPlaying: Bool { get }
    /// Resolve a playable URL for an episode. `excluding` lists URLs
    /// that already failed for this request, so the resolver hands
    /// out the next candidate instead of repeating one.
    var resolveURL: ((PlaybackItem, [URL], @escaping (URL?) -> Void) -> Void)? { get set }
    var onEpisodeStarted: ((PlaybackItem) -> Void)? { get set }
    var onEpisodeFailed: ((PlaybackItem, MusicPlayerError) -> Void)? { get set }
    func play(item: PlaybackItem)
    func open(item: PlaybackItem, url: URL, completion: @escaping (Result<Void, MusicPlayerError>) -> Void)
    func pause()
    func stop()
    func resume()
    func seek(to seconds: Double, completion: @escaping (Bool) -> Void)
    /// Publish this driver's Now Playing registration + info
    /// (b45 M2: VOD owns the single Now Playing slot while an
    /// episode plays — play/pause + seek + previous/next episode;
    /// never the ±10s skip commands, which would hide the
    /// episode buttons, same b42 lesson as music). The
    /// coordinator calls this when an episode really starts, and
    /// clears the other domains first.
    func publishNowPlaying()
    /// Clear this driver's Now Playing registration + info.
    /// Called by stop() / release() and by the coordinator when
    /// another domain takes the slot. Idempotent.
    func clearNowPlaying()
}

/// What PlaybackCoordinator needs from the live player (S4). The
/// coordinator owns mutual exclusion (rule 1) and current-item
/// bookkeeping; the live driver owns engines (MPV / IJK / AVPlayer
/// via PlayerKernel), room state and recovery (LiveRoomSession).
/// URL resolution lives inside the live driver (the session's
/// LiveSiteResolver), never in this file — the `resolveURL` slot
/// below is the driver's own fallback-resolve hook (same shape as
/// VOD's), wired by the driver itself, NOT by this coordinator.
/// Live never follows the music quality selector and never shows
/// a seek bar (real-time); the quality selector is live-only and
/// lives in the session (P0-09 rollback). Reuses MusicPlayerError:
/// it is a generic player error, not music-specific despite the name.
protocol LivePlaybackDriver: AnyObject {
    var currentRoom: PlaybackItem? { get }
    var isPlaying: Bool { get }
    /// Resolve a playable URL for a room. `excluding` lists URLs
    /// that already failed for this request, so the resolver hands
    /// out the next candidate instead of repeating one.
    var resolveURL: ((PlaybackItem, [URL], @escaping (URL?) -> Void) -> Void)? { get set }
    var onRoomStarted: ((PlaybackItem) -> Void)? { get set }
    var onRoomFailed: ((PlaybackItem, MusicPlayerError) -> Void)? { get set }
    func play(item: PlaybackItem)
    func open(item: PlaybackItem, url: URL, completion: @escaping (Result<Void, MusicPlayerError>) -> Void)
    func pause()
    func stop()
    func resume()
    func seek(to seconds: Double, completion: @escaping (Bool) -> Void)
    /// Publish this driver's Now Playing registration + info
    /// (b45 M2: live owns the single Now Playing slot while a
    /// room plays — play/pause ONLY, no next/previous (live has
    /// no tracks) and no seek (live is real-time). The
    /// coordinator calls this when a room really starts, and
    /// clears the other domains first).
    func publishNowPlaying()
    /// Clear this driver's Now Playing registration + info.
    /// Called by stop() / release() and by the coordinator when
    /// another domain takes the slot. Idempotent.
    func clearNowPlaying()
}

/// Single-audio coordinator. One instance for the whole app
/// (owned by HAoStudioApp, injected as an environment object).
@MainActor
final class PlaybackCoordinator: ObservableObject {
    /// The item the UI shows in the mini player / full player.
    /// Nil in the foundation slice: no engine, no playback, no item.
    @Published private(set) var currentItem: PlaybackItem?

    /// Target audio-quality tier. Persists across tracks (and restarts,
    /// via UserDefaults); a lower tier playing now never overwrites it.
    @Published var targetQuality: AudioQuality {
        didSet { defaults.set(targetQuality.rawValue, forKey: Self.targetQualityKey) }
    }

    /// The resolver the player slice plugs in. Nil in the foundation:
    /// `requestPlay` refuses to record playback without one. (Bare
    /// protocol existential, not `any`: `any` needs Swift 5.6+, and the
    /// project keeps SWIFT_VERSION = 5.0 from the old project.)
    var resolver: SourceResolver?

    /// The music player driver, installed by the app entry once the
    /// player slice exists. Wiring (not a public API change): the
    /// driver resolves URLs through `resolver`, reports track starts
    /// so `currentItem` stays in sync with the player's current
    /// track, and reports failures so a failed track never stays
    /// recorded as playing. When no driver is installed the
    /// foundation behaviour below still applies.
    var musicDriver: MusicPlaybackDriver? {
        didSet {
            musicDriver?.resolveURL = { [weak self] item, excluding, completion in
                guard let self = self else {
                    completion(nil, nil)
                    return
                }
                // Local files never go through network resolution.
                if let fileURL = item.localFileURL {
                    completion(fileURL, nil)
                    return
                }
                if let resolver = self.resolver {
                    // Honour `excluding` (S2 gap fix): drop every
                    // failed URL from the resolver's cache BEFORE
                    // re-resolving, so the fallback resolve never
                    // gets the same dead URL back from cache. The
                    // identity key is `platform|songId` (Flutter
                    // identityKey convention, same parse as
                    // LXSourceResolver.resolveFirstPlayable); an id
                    // without a platform separator has nothing to
                    // evict and resolves normally.
                    if !excluding.isEmpty,
                       let evicting = resolver as? PlayURLEvictingResolver {
                        let parts = item.id.split(separator: "|", maxSplits: 1)
                        if parts.count == 2,
                           let platform = MusicPlatform(code: String(parts[0])) {
                            let songId = String(parts[1])
                            for quality in AudioQuality.allCases {
                                evicting.evictPlayUrl(songId: songId, platform: platform, quality: quality)
                            }
                        }
                    }
                    resolver.resolveFirstPlayable(for: item, targetQuality: self.targetQuality, excluding: excluding) { url in
                        let tier = (resolver as? TierReportingResolver)?.lastResolvedTier
                        DispatchQueue.main.async { completion(url, tier) }
                    }
                } else {
                    completion(nil, nil)
                }
            }
            musicDriver?.onTrackStarted = { [weak self] item in
                DispatchQueue.main.async {
                    self?.currentItem = item
                    // b45 M2: the music card takes the single Now
                    // Playing slot — a stale VOD/live registration
                    // must not survive the switch (their stop()
                    // already clears, but paths that bypass the
                    // coordinator's requestPlay can leave one).
                    self?.vodDriver?.clearNowPlaying()
                    self?.liveDriver?.clearNowPlaying()
                }
            }
            musicDriver?.onTrackFailed = { [weak self] item, _ in
                DispatchQueue.main.async {
                    if self?.currentItem?.id == item.id {
                        self?.currentItem = nil
                        // Same id guard as the currentItem clear:
                        // a stale failure for an old track must
                        // not kill the current track's card.
                        self?.musicDriver?.clearNowPlaying()
                    }
                }
            }
        }
    }

    /// The VOD player driver, installed by the app entry once the
    /// video slice exists. The coordinator only owns mutual exclusion
    /// (rule 1) and current-item bookkeeping for VOD; URL resolution
    /// lives inside the video driver (CMS / Emby), never in this file.
    var vodDriver: VideoPlaybackDriver? {
        didSet {
            vodDriver?.onEpisodeStarted = { [weak self] item in
                DispatchQueue.main.async {
                    self?.currentItem = item
                    // b45 M2: the VOD card takes the single Now
                    // Playing slot — clear the other domains
                    // first, then publish this episode.
                    self?.musicDriver?.clearNowPlaying()
                    self?.liveDriver?.clearNowPlaying()
                    self?.vodDriver?.publishNowPlaying()
                }
            }
            vodDriver?.onEpisodeFailed = { [weak self] item, _ in
                DispatchQueue.main.async {
                    if self?.currentItem?.id == item.id {
                        self?.currentItem = nil
                        self?.vodDriver?.clearNowPlaying()
                    }
                }
            }
        }
    }

    /// The live player driver, installed by the app entry once the
    /// live slice exists. Same shape as `vodDriver`: the coordinator
    /// only owns mutual exclusion (rule 1) and current-item
    /// bookkeeping for live; URL resolution lives inside the live
    /// driver (the session's LiveSiteResolver), never in this file
    /// — so this didSet wires ONLY the started/failed callbacks and
    /// never touches the driver's own `resolveURL`.
    var liveDriver: LivePlaybackDriver? {
        didSet {
            liveDriver?.onRoomStarted = { [weak self] item in
                DispatchQueue.main.async {
                    self?.currentItem = item
                    // b45 M2: the live card takes the single Now
                    // Playing slot — clear the other domains
                    // first, then publish this room.
                    self?.musicDriver?.clearNowPlaying()
                    self?.vodDriver?.clearNowPlaying()
                    self?.liveDriver?.publishNowPlaying()
                }
            }
            liveDriver?.onRoomFailed = { [weak self] item, _ in
                DispatchQueue.main.async {
                    if self?.currentItem?.id == item.id {
                        self?.currentItem = nil
                        self?.liveDriver?.clearNowPlaying()
                    }
                }
            }
        }
    }

    static let targetQualityKey = "musicQuality"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.targetQualityKey)
        self.targetQuality = AudioQuality(rawValue: saved ?? "") ?? .hiRes
    }

    /// Request playback of an item. Foundation behaviour: records the
    /// request ONLY when a resolver is plugged in (player slice). Until
    /// then this is a no-op by design — recording an item with no engine
    /// would show a mini player for playback that is not happening.
    /// With a music driver installed (player slice): stop the current
    /// playback first (rule 1, one sound at a time), then let the
    /// driver resolve serially (rule 4) and open the URL; `currentItem`
    /// is set by the driver's onTrackStarted callback, only once the
    /// track really starts. Tapping the song that is already playing
    /// does not restart it.
    /// b46: clear the resolver's failure memory for one song, so
    /// a manual play re-asks every source for it. Automatic skips
    /// do not call this — the memory is what makes skipping past
    /// a dead song instant there.
    func clearResolveFailureMemory(forSongId songId: String) {
        (resolver as? FailureMemoryClearingResolver)?.clearFailureMemory(forSongId: songId)
    }

    func requestPlay(_ item: PlaybackItem) {
        guard let driver = musicDriver else {
            guard resolver != nil else { return }
            currentItem = item
            return
        }
        if let current = driver.currentTrack, current.id == item.id {
            // M3 (b45, chen 2026-11-25: 切歌和直播/影视混起来):
            // the same-track resume used to bypass mutual
            // exclusion — a live room / VOD episode kept sounding
            // under the resumed song. Stop the other domains
            // first, exactly like the new-request path below.
            vodDriver?.stop()
            liveDriver?.stop()
            if driver.isPlaying { return }
            // Clear first (like the siblings): if the resume
            // fails, nothing is playing and the stale live/VOD
            // item must not stay in the mini player; a
            // successful resume records the song below.
            currentItem = nil
            driver.resume()
            // #8: only record the item when the resume actually
            // started — resume() is a guarded no-op when the engine
            // is gone (after a failed open the current track still
            // holds the old item while no engine exists), and
            // recording it then shows the mini player for a song
            // that never plays.
            if driver.isPlaying {
                currentItem = item
            }
            return
        }
        vodDriver?.stop()
        liveDriver?.stop()
        driver.stop()
        // M1 (b45): clear the mini player BEFORE the resolve —
        // the siblings (requestVodPlay / requestLivePlay) both do
        // this, requestPlay did not. Resolving takes seconds and
        // only onTrackStarted re-records; until then the mini
        // kept the dead live room / VOD episode, and tapping it
        // re-opened the room/episode and killed the switch.
        // Never optimistically record the song here: a failed
        // song must not enter the mini player.
        currentItem = nil
        driver.play(item: item)
    }

    /// Request VOD playback of an episode. The episode's
    /// PlaybackItem id MUST be the stable resume key
    /// (VideoResumeKey.key(title:year:) + episode name) so the
    /// driver, history and resume all agree on identity. Stops
    /// music first (rule 1), then lets the VOD driver resolve and
    /// open. Tapping the episode that is already playing resumes
    /// it instead of restarting.
    func requestVodPlay(_ item: PlaybackItem) {
        guard let driver = vodDriver else { return }
        if let current = driver.currentEpisode, current.id == item.id {
            if driver.isPlaying { return }
            driver.resume()
            // #8: only record the item when the resume actually
            // started — resume() is a guarded no-op when the
            // backend is gone (after a failed open the current
            // episode still holds the old item while backend is
            // nil), and recording it then shows the mini player
            // for an episode that never plays.
            if driver.isPlaying {
                currentItem = item
            }
            return
        }
        musicDriver?.stop()
        liveDriver?.stop()
        currentItem = nil
        driver.play(item: item)
    }

    /// Request live playback of a room. Stops music and VOD first
    /// (rule 1), then lets the live driver resolve and open. The
    /// room page configures the driver (room + resolver) before
    /// calling this. Tapping the room that is already playing
    /// resumes it instead of restarting.
    func requestLivePlay(_ item: PlaybackItem) {
        guard let driver = liveDriver else { return }
        if let current = driver.currentRoom, current.id == item.id {
            if driver.isPlaying { return }
            driver.resume()
            // #8: only record the item when the resume actually
            // started — resume() is a guarded no-op when the
            // backend is gone (after a failed open the current room
            // still holds the old room while backend is nil), and
            // recording it then shows the mini player for a room
            // that never plays.
            if driver.isPlaying {
                currentItem = item
            }
            return
        }
        musicDriver?.stop()
        vodDriver?.stop()
        currentItem = nil
        driver.play(item: item)
    }

    /// Stop music only — rule 1 for a VOD open that bypasses
    /// requestVodPlay: the VOD engine path plays through the
    /// driver directly, so the music stop in requestVodPlay never
    /// runs and a second-or-later VOD open leaves the song playing
    /// (build 37, P1). Leaves the VOD/live drivers and currentItem
    /// untouched: the caller owns the new item (the driver's
    /// onEpisodeStarted sets currentItem when the episode really
    /// starts). No auto-resume: exiting never restarts the music.
    func stopMusic() {
        musicDriver?.stop()
    }

    /// Stop live only — the live half of the same bypass (#7):
    /// requestVodPlay stops live too, but the VOD engine path
    /// never reaches it, so a live room playing in the background
    /// (audio-only) kept sounding under the VOD audio. Same shape
    /// as stopMusic: live driver only, currentItem untouched, no
    /// auto-resume.
    func stopLive() {
        liveDriver?.stop()
    }

    /// Pause whatever is playing right now, without clearing
    /// anything (build 37, Phase 5, §6.3: 耳机拔出后的暂停行为).
    /// The app root calls this when the audio route loses its
    /// output device (headphones unplugged / Bluetooth headset
    /// disconnected — AVAudioSession `.oldDeviceUnavailable`):
    /// without it the song / episode / room kept sounding
    /// through the speaker. Pause, not stop: the item stays
    /// loaded, the mini player stays, and one tap resumes —
    /// the same behaviour as the pause button. Only drivers
    /// that report isPlaying are paused, so a route change
    /// while nothing plays is a no-op; each driver's own
    /// pause() updates its state (music recomputes isPlaying
    /// and refreshes Now Playing; VOD reports the pause to
    /// Emby; live notes it in the session), exactly like a
    /// manual pause. No auto-resume: the user resumes.
    func pausePlaying() {
        if musicDriver?.isPlaying == true { musicDriver?.pause() }
        if vodDriver?.isPlaying == true { vodDriver?.pause() }
        if liveDriver?.isPlaying == true { liveDriver?.pause() }
    }

    /// Stop everything. Clears the current item; the player slice also
    /// stops the engine here (rule 1: starting anything else stops the
    /// current playback first).
    func stop() {
        musicDriver?.stop()
        vodDriver?.stop()
        liveDriver?.stop()
        // b45 M2: the music stop tears its own Now Playing down;
        // VOD/live do the same in their stop() — clear here too
        // so no domain's card survives a full stop.
        vodDriver?.clearNowPlaying()
        liveDriver?.clearNowPlaying()
        currentItem = nil
    }
}

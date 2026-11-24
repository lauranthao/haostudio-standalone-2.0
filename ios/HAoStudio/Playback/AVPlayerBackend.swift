// HAo Studio 2.0 — AVPlayer backend (S3, leg A).
//
// The system player (AVPlayer + AVPlayerLayer) behind the
// VideoPlayerBackend protocol. This is Pure Live's 'exo' slot on
// iOS: BetterPlayer is ExoPlayer on Android and AVPlayer on iOS,
// so the "EXOPlayer" chen asked for IS this on iOS — ExoPlayer
// itself cannot run on iOS (Android-only).
//
// What it plays: HLS (.m3u8) and MP4 — i.e. VOD movies/episodes
// (HLS/MP4), HEVC / Dolby Vision P8 in an Apple container. What
// it CANNOT play: FLV / MKV / AVI / WMV / RMVB / TS / WebM / MPG /
// DASH / AV1 / VP8 / VP9 / TrueHD / DTS / APE / Opus / Vorbis
// audio — the capability gate in VideoCapability never sends
// those here, so this backend never wastes an open attempt on
// them. (Build 36, item 14, G-A/G-D: the new containers and
// codecs joined the gate; the old comment only named FLV/MKV.)
//
// Hard decode: none requested, none needed — AVPlayer decodes
// through VideoToolbox natively. Once the item is ready, the
// state is verified hardware by construction (the system decoder
// is the hardware decoder); before ready it is unknown.
//
// Background audio: AVPlayer keeps its audio going in the
// background with the app's .playback audio session; the video
// layer simply stops drawing.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import UIKit
import AVFoundation

// Container that keeps the player layer filling it on every layout
// pass (the driver sizes the container to its video view bounds).
private final class AVPlayerContainerView: UIView {
    var playerLayer: AVPlayerLayer?
    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }
}

// KVO observe on AVPlayerItem needs the key-path type pinned
// explicitly: this Xcode version cannot infer Value from
// `item.observe(\.status, ...)` (nor from the Bool key paths), so
// all three route through this helper where
// KeyPath<AVPlayerItem, Value> is explicit.
private func observePlayerItem<Value>(_ item: AVPlayerItem, _ keyPath: KeyPath<AVPlayerItem, Value>, handler: @escaping () -> Void) -> NSKeyValueObservation {
    return item.observe(keyPath, options: [.new]) { _, _ in handler() }
}

final class AVPlayerBackend: NSObject, VideoPlayerBackend, VodTrackListCapable {
    var onEvent: ((VideoBackendEvent) -> Void)?
    var onVideoSize: ((CGSize) -> Void)?

    let engine: VideoEngine = .avplayer

    /// Audio / subtitle tracks from the current item's media
    /// selection groups (build 36, item 14, G-F). Published
    /// through `onTracksChanged` when the item is ready; the
    /// driver mirrors them into the settings sheet pickers.
    /// `VodTrackInfo.index` is the position in the group, so
    /// `selectAudioTrack` / `selectSubtitleTrack` map it back to
    /// the same option. Empty when the item has no selection
    /// groups yet (e.g. a remote HLS whose groups are not loaded)
    /// — the pickers then stay hidden, never fake.
    private var cachedAudioTracks: [VodTrackInfo] = []
    private var cachedSubtitleTracks: [VodTrackInfo] = []
    var onTracksChanged: (([VodTrackInfo], [VodTrackInfo]) -> Void)?

    var audioTracks: [VodTrackInfo] { cachedAudioTracks }
    var subtitleTracks: [VodTrackInfo] { cachedSubtitleTracks }

    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private let containerView = AVPlayerContainerView()

    private var rate: Double = 1
    private var currentURL: URL?
    private var didEmitFirstFrame = false
    private var didEmitPrepared = false

    /// Hard-decode state: unknown until the item is ready, then
    /// verified hardware — AVPlayer decodes through VideoToolbox
    /// natively, so a ready item IS a hardware-decoded item (no
    /// software fallback exists on this path).
    private(set) var hardwareDecode: VideoHardwareDecodeState = .unknown

    /// Pending open completion (fires exactly once).
    private var openCompletion: ((Bool) -> Void)?

    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemBufferEmptyObservation: NSKeyValueObservation?
    private var itemLikelyObservation: NSKeyValueObservation?

    override init() {
        super.init()
        containerView.backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        playerLayer.player = player
        containerView.playerLayer = playerLayer
        containerView.layer.addSublayer(playerLayer)
        playerLayer.frame = containerView.bounds
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            self?.timeControlChanged()
        }
    }

    func setVideoFit(_ fit: VideoFit) {
        switch fit {
        case .aspectFit: playerLayer.videoGravity = .resizeAspect
        case .aspectFill: playerLayer.videoGravity = .resizeAspectFill
        case .fill: playerLayer.videoGravity = .resize
        }
    }

    var view: UIView { containerView }

    var isPlaying: Bool { player.timeControlStatus == .playing }

    var currentTime: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? t : 0
    }

    var duration: Double {
        guard let item = player.currentItem else { return Double.nan }
        let d = item.duration.seconds
        return d.isFinite ? d : Double.nan
    }

    var isPrepared: Bool { player.currentItem?.status == .readyToPlay }

    var playbackRate: Double {
        get { rate }
        set {
            rate = newValue
            // AVPlayer.play() resumes at defaultRate (1.0); keep the
            // chosen speed by driving play() through rate instead.
            if player.timeControlStatus == .playing {
                player.rate = Float(newValue)
            }
        }
    }

    func open(url: URL, headers: [String: String], completion: @escaping (Bool) -> Void) {
        shutdown()
        currentURL = url
        didEmitFirstFrame = false
        didEmitPrepared = false
        hardwareDecode = .unknown
        cachedAudioTracks = []
        cachedSubtitleTracks = []
        openCompletion = completion
        // NOTE: AVURLAssetHTTPHeaderFieldsKey is NOT in scope on this
        // Xcode version (same as NativeMusicPlayer.swift) — use the
        // literal string key; AVURLAsset options is [String: Any].
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        itemStatusObservation = observePlayerItem(item, \.status) { [weak self] in
            self?.itemStatusChanged()
        }
        itemBufferEmptyObservation = observePlayerItem(item, \.isPlaybackBufferEmpty) { [weak self] in
            self?.bufferChanged()
        }
        itemLikelyObservation = observePlayerItem(item, \.isPlaybackLikelyToKeepUp) { [weak self] in
            self?.bufferChanged()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(itemDidPlayToEndTime), name: .AVPlayerItemDidPlayToEndTime, object: item)
        NotificationCenter.default.addObserver(self, selector: #selector(itemFailedToPlayToEndTime(_:)), name: .AVPlayerItemFailedToPlayToEndTime, object: item)
        player.replaceCurrentItem(with: item)
        player.rate = Float(rate)
    }

    /// Fire the pending open completion exactly once.
    private func finishOpen(_ ok: Bool) {
        guard let completion = openCompletion else { return }
        openCompletion = nil
        completion(ok)
    }

    func play() {
        player.rate = Float(rate)
    }

    // MARK: - Audio / subtitle tracks (build 36, item 14, G-F)

    /// Read the current item's media-selection groups and publish
    /// them. Called when the item is ready. A group with one
    /// option still publishes (the picker then shows the single
    /// track); a missing group publishes an empty list.
    private func refreshTrackLists() {
        guard let item = player.currentItem else { return }
        let asset = item.asset
        var audio: [VodTrackInfo] = []
        if let group = asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            for (position, option) in group.options.enumerated() {
                let lang = option.extendedLanguageTag ?? option.locale?.identifier
                let name = option.displayName.isEmpty
                    ? (lang?.uppercased() ?? "音轨 \(position + 1)") : option.displayName
                audio.append(VodTrackInfo(
                    index: position, displayName: name, language: lang,
                    isDefault: option == group.defaultOption, isExternal: false))
            }
        }
        var subtitles: [VodTrackInfo] = []
        if let group = asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            for (position, option) in group.options.enumerated() {
                let lang = option.extendedLanguageTag ?? option.locale?.identifier
                let name = option.displayName.isEmpty
                    ? (lang?.uppercased() ?? "字幕 \(position + 1)") : option.displayName
                subtitles.append(VodTrackInfo(
                    index: position, displayName: name, language: lang,
                    isDefault: option == group.defaultOption, isExternal: false))
            }
        }
        cachedAudioTracks = audio
        cachedSubtitleTracks = subtitles
        onTracksChanged?(audio, subtitles)
    }

    /// Switch the audio track: the index is the position in the
    /// `.audible` group (-1 = the group's default option).
    func selectAudioTrack(index: Int) {
        guard let item = player.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else { return }
        if index < 0 {
            if let def = group.defaultOption { item.select(def, in: group) }
            return
        }
        guard group.options.indices.contains(index) else { return }
        item.select(group.options[index], in: group)
    }

    /// Switch the subtitle track: the index is the position in
    /// the `.legible` group (-1 = no subtitles).
    func selectSubtitleTrack(index: Int) {
        guard let item = player.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return }
        if index < 0 {
            item.select(nil, in: group)
            return
        }
        guard group.options.indices.contains(index) else { return }
        item.select(group.options[index], in: group)
    }

    func pause() {
        player.pause()
    }

    func seek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        let target = CMTimeMakeWithSeconds(seconds, preferredTimescale: 1000)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self = self, finished else {
                completion(false)
                return
            }
            // Read-back verification: the seek callback fires when
            // the seek is done, but confirm the playhead actually
            // landed near the target before reporting success.
            completion(abs(self.currentTime - seconds) <= 2.0)
        }
    }

    func shutdown() {
        finishOpen(false)
        NotificationCenter.default.removeObserver(self)
        itemStatusObservation = nil
        itemBufferEmptyObservation = nil
        itemLikelyObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
        hardwareDecode = .unknown
    }

    deinit {
        shutdown()
    }

    // MARK: - State mapping

    private func emit(_ event: VideoBackendEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    private func timeControlChanged() {
        guard player.currentItem != nil else { return }
        switch player.timeControlStatus {
        case .playing:
            if !didEmitFirstFrame {
                didEmitFirstFrame = true
                emit(.firstFrame)
                if let size = naturalSize() { onVideoSize?(size) }
            }
            emit(.playing)
        case .paused:
            emit(.paused)
        case .waitingToPlayAtSpecifiedRate:
            emit(.stalled)
        @unknown default:
            break
        }
    }

    private func itemStatusChanged() {
        guard let item = player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            // Native decode: a ready item is hardware-decoded.
            hardwareDecode = .hardware(decoder: "VideoToolbox")
            refreshTrackLists()
            if !didEmitPrepared {
                didEmitPrepared = true
                emit(.prepared)
                finishOpen(true)
            }
            if let size = naturalSize() { onVideoSize?(size) }
        case .failed:
            if !didEmitPrepared { finishOpen(false) }
            emit(.finished(.error))
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func bufferChanged() {
        guard let item = player.currentItem else { return }
        // Buffer ran dry while playing: the clock-based stall
        // detection in the driver owns the recovery, but the
        // spinner state also wants to know (pre-start only, per
        // the driver).
        if item.isPlaybackBufferEmpty, !item.isPlaybackLikelyToKeepUp, player.timeControlStatus != .paused {
            emit(.stalled)
        }
    }

    private func naturalSize() -> CGSize? {
        guard let track = player.currentItem?.asset.tracks(withMediaType: .video).first else { return nil }
        let size = track.naturalSize.applying(track.preferredTransform)
        let w = abs(size.width), h = abs(size.height)
        guard w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    @objc private func itemDidPlayToEndTime(_ note: Notification) {
        emit(.finished(.ended))
    }

    @objc private func itemFailedToPlayToEndTime(_ note: Notification) {
        if !didEmitPrepared { finishOpen(false) }
        emit(.finished(.error))
    }
}

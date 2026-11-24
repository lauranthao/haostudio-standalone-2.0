// HAo Studio 2.0 — playback diagnostics (S3, leg A).
//
// Hard-decode state / FPS sampling / playback diagnosis. The one
// rule for all of it: a software decode is NEVER silent. When the
// engine falls back to software, the diagnosis says "软解中" in
// plain text, and the driver decides (4K HEVC / Dolby Vision ->
// switch to AVPlayer; anything else -> stay, labelled).
//
// Plan §四 4.2: request -> verify -> downgrade. Requesting is the
// backends' job (MPV `hwdec=auto-safe`, IJK `videotoolbox=1`,
// AVPlayer native). Verifying is here: the state below is only
// ever set from a read-back (MPV `hwdec-current`), a native
// guarantee (AVPlayer), or an explicit "no read-back API" marker
// (IJK) — never from the requested option alone.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation
import UIKit

// MARK: - Hard-decode state

/// Hard-decode state for one open, as verified — not as requested.
enum VideoHardwareDecodeState: Equatable {
    /// Nothing verified yet (before open, or the engine reports
    /// nothing readable).
    case unknown
    /// Verified hard decode: the backend read the live decoder
    /// back (MPV `hwdec-current` = videotoolbox; AVPlayer native
    /// VideoToolbox once the item is ready).
    case hardware(decoder: String)
    /// Requested + session established + frames rendering, but the
    /// engine exposes no read-back API (IJK: there is no public
    /// call that returns the VideoToolbox session). Shown as
    /// "硬解（未验证）" — visible, never presented as verified.
    case assumedHardware(decoder: String)
    /// Verified software decode: the read-back says so
    /// (MPV `hwdec-current` = `no` / empty). The diagnosis MUST
    /// label this "软解中".
    case software

    /// Short label for the settings sheet / debug overlay.
    var label: String {
        switch self {
        case .unknown: return "硬解未知"
        case .hardware(let decoder): return "硬解 · \(decoder)"
        case .assumedHardware(let decoder): return "硬解（未验证）· \(decoder)"
        case .software: return "软解中"
        }
    }

    /// True only when hard decode is VERIFIED (not assumed).
    var isVerifiedHardware: Bool {
        if case .hardware = self { return true }
        return false
    }

    /// True when the picture is being decoded in software right
    /// now (verified). Assumed-hardware and unknown are NOT
    /// software — the driver must not "fix" a stream it has not
    /// proven to be soft.
    var isSoftware: Bool {
        if case .software = self { return true }
        return false
    }
}

// MARK: - FPS sampling

/// Pure FPS math, so tests can drive it without a display link.
/// `fps` is frames per second over a window; `droppedFrames`
/// counts intervals longer than 1.5x the expected frame interval
/// (a frame that arrived a full frame late).
enum VideoFpsMath {
    static func fps(frameCount: Int, over seconds: Double) -> Double {
        guard seconds > 0, frameCount >= 0 else { return 0 }
        return Double(frameCount) / seconds
    }

    static func droppedFrames(intervals: [Double], expectedInterval: Double) -> Int {
        guard expectedInterval > 0 else { return 0 }
        var dropped = 0
        for interval in intervals {
            if interval > expectedInterval * 1.5 { dropped += 1 }
        }
        return dropped
    }
}

/// Live FPS sampler, driven by a display link. Reports about once
/// a second through `onSample` (fps, dropped frames in that
/// window). VOD only: the sampler exists to prove a 4K HEVC
/// stream holds its frame rate after the hard-decode check, and
/// to flag a struggling software decode before the user notices
/// the stutter. Start/stop are idempotent; the link is always
/// invalidated on stop so nothing keeps the runloop alive after
/// the player closes.
final class VideoFpsSampler: NSObject {
    /// (fps, dropped frames in the last window).
    var onSample: ((Double, Int) -> Void)?

    private var displayLink: CADisplayLink?
    private var windowStart: CFTimeInterval = 0
    private var frameCount: Int = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var intervals: [Double] = []

    var isRunning: Bool { displayLink != nil }

    func start() {
        guard displayLink == nil else { return }
        windowStart = CACurrentMediaTime()
        lastTimestamp = windowStart
        frameCount = 0
        intervals = []
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    deinit {
        displayLink?.invalidate()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastTimestamp > 0 {
            intervals.append(now - lastTimestamp)
        }
        lastTimestamp = now
        frameCount += 1
        let elapsed = now - windowStart
        if elapsed >= 1.0 {
            let fps = VideoFpsMath.fps(frameCount: frameCount, over: elapsed)
            let dropped = VideoFpsMath.droppedFrames(intervals: intervals, expectedInterval: 1.0 / 60.0)
            frameCount = 0
            intervals = []
            windowStart = now
            onSample?(fps, dropped)
        }
    }
}

// MARK: - Playback diagnosis

/// One playback diagnosis snapshot: everything the settings
/// sheet / debug overlay shows about the current open. Built by
/// the driver from the backend + sampler; the strings are the
/// user-visible truth (a soft decode says so here, never hides).
struct VideoPlaybackDiagnostics: Equatable {
    let engine: VideoEngine
    let hardwareDecode: VideoHardwareDecodeState
    /// Option/property names the backend tried and the engine
    /// refused (P0-02). Names only, never values.
    let rejectedOptionNames: [String]
    /// Last sampled FPS (0 = no sample yet).
    let fps: Double
    /// Dropped frames in the last sample window.
    let droppedFrames: Int
    /// Stream facts, when the URL carried them (Emby `hao_*`).
    let facts: VideoStreamFacts?
    /// True when the driver switched engines because of a verified
    /// software decode (4K HEVC / Dolby Vision -> AVPlayer).
    let fellBackForSoftwareDecode: Bool
    /// Engines the open ladder attempted, in try order (build 36,
    /// item 14, G-K): the failure card and the diagnosis sheet
    /// show what was tried. `var` with a default so the existing
    /// memberwise constructions keep compiling.
    var attemptedEngines: [VideoEngine] = []

    static let empty = VideoPlaybackDiagnostics(
        engine: .mpv, hardwareDecode: .unknown, rejectedOptionNames: [],
        fps: 0, droppedFrames: 0, facts: nil, fellBackForSoftwareDecode: false
    )

    /// One-line summary for the settings sheet. A software decode
    /// is spelled out ("软解中"); a verified hard decode names
    /// its decoder; an unverified one says so.
    var summaryLine: String {
        var parts = ["\(engine.displayName)", hardwareDecode.label]
        if fps > 0 { parts.append(String(format: "%.0f fps", fps)) }
        if droppedFrames > 0 { parts.append("掉帧 \(droppedFrames)") }
        if fellBackForSoftwareDecode { parts.append("已切系统播放器（软解）") }
        return parts.joined(separator: " · ")
    }

    /// Full detail lines for a debug view, including rejected
    /// options (names only) and stream facts.
    var detailLines: [String] {
        var lines = [
            "引擎：\(engine.displayName)",
            "硬解：\(hardwareDecode.label)",
        ]
        if fps > 0 { lines.append("帧率：\(String(format: "%.1f", fps)) fps") }
        if droppedFrames > 0 { lines.append("掉帧：\(droppedFrames)（上一秒）") }
        if let facts = facts {
            if let container = facts.container { lines.append("容器：\(container)") }
            if let codec = facts.videoCodec { lines.append("视频编码：\(codec)") }
            if facts.dolbyVision {
                lines.append("杜比视界：是\(facts.dvProfile.map { "（P\($0)）" } ?? "")")
            }
            if facts.is4K { lines.append("分辨率：4K") }
        }
        if !rejectedOptionNames.isEmpty {
            lines.append("被拒属性：\(rejectedOptionNames.joined(separator: "、"))")
        }
        if !attemptedEngines.isEmpty {
            lines.append("已尝试引擎：\(attemptedEngines.map { $0.displayName }.joined(separator: "、"))")
        }
        if fellBackForSoftwareDecode {
            lines.append("已因软解自动切换到系统播放器")
        }
        return lines
    }
}

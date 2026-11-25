// HAo Studio 2.0 — VOD danmaku layer (S3, leg A).
//
// One of the four independent VOD pieces (P0-08): this file owns
// ONLY the danmaku overlay state + rendering. It fetches data
// through the `VodDanmakuProvider` protocol (implemented by Leg
// B — this file invents NO provider implementation) and knows
// nothing about the driver, the gesture layer or the settings
// sheet. The view model holds the state object and the player
// page renders this view over the video area.
//
// Read-only: the app never sends danmaku.
//
// Rendering: scrolling danmaku travels right-to-left over 8 s on
// a deterministic lane (4 lanes, assigned by item index — no
// layout measuring, no collisions to solve at runtime); top
// danmaku pins to the top centre for 5 s. Each row owns its own
// offset state, keyed by stable item id, so the 0.5 s position
// ticks from the driver never restart an in-flight animation.
//
// Colour: an item's own `colorHex` wins; the default is white
// with a dark shadow — danmaku is video-overlay content, not
// themed chrome, and white is the only colour readable over any
// video frame in either mode.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation
import SwiftUI

// MARK: - State

/// Danmaku overlay state. The player page creates one (via the
/// view model) and calls `load` when the episode changes.
final class VodDanmakuLayerState: ObservableObject {
    /// All danmaku for the current episode, sorted by time.
    @Published private(set) var items: [DanmakuItem] = []
    /// Overlay on/off (bound to the settings sheet).
    @Published var isEnabled: Bool = true
    /// Text opacity 0.3-1.0 (bound to the settings sheet).
    @Published var opacity: Double = 1.0
    /// Font size in points (b49fix7 P2-23, b49fix8 P2-13).
    /// Follows the user's live danmaku font-size setting
    /// (`LiveDanmakuSettings.fontSize`, default 14, range
    /// 12-20) — the live settings page owns the control, so
    /// this is a read, not a second writer. The construction
    /// read below is only the initial value: this state lives
    /// as long as the app-level player view model, so it is
    /// NOT fresh on every open — the player VM re-reads the
    /// setting in applySettings() (on engine attach and on
    /// every settings change), which is the refresh path, plus
    /// the UserDefaults observer below (b49fix9 P2-6), which
    /// covers a VOD left hanging while the live settings page
    /// changes the size. Was a fixed 16 medium.
    @Published var fontSize: Double = LiveDanmakuSettings.load().fontSize
    /// A fetch is in flight for the current episode. The player
    /// page reads this (with `didLoad`) to decide whether the
    /// danmaku switch is real yet: a switch shown while the fetch
    /// is still running would be a fake switch when the episode
    /// turns out to have no danmaku source.
    @Published private(set) var isLoading = false
    /// A fetch finished for the current episode (items or empty).
    /// False before the first load and while a reload is running.
    @Published private(set) var didLoad = false
    /// The last fetch failed at the transport level (the danmaku
    /// server could not be reached) — as opposed to "this title
    /// has no danmaku", which is `didLoad && items.isEmpty`.
    /// The settings sheet shows a visible failure + retry from
    /// this (sweep-4 P2-9); a silent empty layer used to read
    /// exactly like "no danmaku for this episode".
    @Published private(set) var loadFailed = false

    /// How long a scrolling line takes to cross the screen.
    static let scrollDuration: Double = 8
    /// How long a top line stays pinned.
    static let topDuration: Double = 5
    /// Scrolling lanes.
    static let laneCount: Int = 4

    private var loadedEpisodeId: String?
    /// Generation of the in-flight fetch. Every `load` that starts
    /// a fetch bumps it and the completion only applies when its
    /// captured generation is still current: a reload (or an
    /// episode change, or a `clear`) supersedes an older fetch,
    /// and the older completion arriving late must not overwrite
    /// the newer result. The second reload cancels the first in
    /// effect — the network request itself has no cancel handle,
    /// but its result is discarded.
    private var loadGeneration = 0

    /// Token for the UserDefaults change observer (b49fix9 P2-6).
    private var settingsObserver: NSObjectProtocol?

    init() {
        // b49fix9 P2-6: applySettings() refreshes the font size on
        // attach and on every settings change, but a VOD left
        // hanging while the live settings page changes the size
        // never passes through applySettings — VOD is a
        // fullScreenCover and the settings page cannot open over
        // it, so the window is narrow, but this observer closes it
        // for real instead of documenting it away.
        // UserDefaults.didChangeNotification fires for any defaults
        // write; the refresh is a scalar re-read and only assigns
        // when the size actually changed, so unrelated writes cause
        // no @Published churn. Same token-retained shape as the
        // MusicPlayerViewModel observers (b49fix2 P1-30).
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshFontSizeFromSettings()
        }
    }

    deinit {
        if let token = settingsObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Re-read the font size from the live settings and apply it
    /// when it changed (b49fix9 P2-6). Scalar-only read — the full
    /// `LiveDanmakuSettings.load()` would also read the enabled-map
    /// and block-list collection files, which this callback does
    /// not need. The struct init clamps to 12...20, so a stale or
    /// corrupt stored value cannot land here unclamped.
    private func refreshFontSizeFromSettings() {
        let stored = UserDefaults.standard.object(forKey: LiveDanmakuSettings.keyFontSize) as? Double
        let size = LiveDanmakuSettings(fontSize: stored ?? LiveDanmakuSettings.defaultFontSize).fontSize
        if fontSize != size { fontSize = size }
    }

    /// Fetch danmaku for `episode` through `provider`. A nil
    /// provider (Leg B not wired yet) leaves the layer empty —
    /// never a crash, never a fake list. Re-loading the same
    /// episode is a no-op.
    func load(for episode: PlayEpisode, provider: VodDanmakuProvider?) {
        load(for: episode, provider: provider, forceReload: false)
    }

    /// Re-fetch danmaku for `episode` even when it is already the
    /// loaded episode (b36 item 11, leg 3: the player sheet's
    /// "重新加载弹幕" row). Clears the current items, so the
    /// sheet shows "弹幕加载中…" until the new fetch lands, and
    /// bumps the generation so a still-running older fetch cannot
    /// overwrite the new result.
    func reload(for episode: PlayEpisode, provider: VodDanmakuProvider?) {
        load(for: episode, provider: provider, forceReload: true)
    }

    private func load(for episode: PlayEpisode, provider: VodDanmakuProvider?, forceReload: Bool) {
        guard forceReload || loadedEpisodeId != episode.id else { return }
        loadedEpisodeId = episode.id
        items = []
        loadGeneration += 1
        let generation = loadGeneration
        guard let provider = provider else {
            isLoading = false
            didLoad = true
            return
        }
        isLoading = true
        didLoad = false
        loadFailed = false
        provider.fetchDanmaku(for: episode) { [weak self] fetched, failed in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard generation == self.loadGeneration,
                      self.loadedEpisodeId == episode.id else { return }
                self.items = fetched.sorted { $0.timeSeconds < $1.timeSeconds }
                self.loadFailed = failed
                self.isLoading = false
                self.didLoad = true
            }
        }
    }

    /// Clear the layer (episode changed / player released).
    /// Bumps the generation too, so a fetch still in flight when
    /// the player closes cannot refill the layer after the clear.
    func clear() {
        loadGeneration += 1
        loadedEpisodeId = nil
        items = []
        isLoading = false
        didLoad = false
        loadFailed = false
    }

    /// Items visible at `position` (seconds), each with a stable
    /// id (its index in the sorted list — stable across the 0.5 s
    /// position ticks, so row animation state survives re-render).
    /// Scrolling items are visible from their time until they cross
    /// (8 s); top items from their time for 5 s.
    func visibleItems(at position: Double) -> [(id: Int, item: DanmakuItem)] {
        guard isEnabled else { return [] }
        var out: [(id: Int, item: DanmakuItem)] = []
        for (index, item) in items.enumerated() {
            let age = position - item.timeSeconds
            if item.isTop {
                if age >= 0 && age <= VodDanmakuLayerState.topDuration {
                    out.append((id: index, item: item))
                }
            } else {
                if age >= 0 && age <= VodDanmakuLayerState.scrollDuration {
                    out.append((id: index, item: item))
                }
            }
        }
        return out
    }
}

// MARK: - Availability (switch gating)

/// Whether the current episode has danmaku to switch. The player
/// page shows the danmaku switch only when there is something to
/// switch: a switch over an empty layer would be a fake control.
/// - loading: the fetch is still running (or never started) — the
///   page shows "弹幕加载中", never a switch.
/// - available: items arrived — the switch is real.
/// - unavailable: the fetch finished with nothing — the switch
///   stays hidden.
/// - failed: the danmaku server could not be reached — the page
///   shows the failure with a retry instead of silently hiding
///   the section (sweep-4 P2-9).
enum VodDanmakuAvailability {
    case loading
    case available
    case unavailable
    case failed

    /// Pure derivation from the layer state, so tests can drive it
    /// without a view. Items win over loading: while a new episode
    /// reloads, the old items are already cleared by `load`, so a
    /// non-empty list always means switchable danmaku. A failed
    /// fetch wins over the empty state, so the failure is visible
    /// instead of reading as "no danmaku".
    static func resolve(isLoading: Bool, didLoad: Bool, itemCount: Int, loadFailed: Bool = false) -> VodDanmakuAvailability {
        if itemCount > 0 { return .available }
        if loadFailed { return .failed }
        if isLoading || !didLoad { return .loading }
        return .unavailable
    }
}

// MARK: - Colour

extension Color {
    /// Danmaku hex ("rrggbb", no '#'). Empty or malformed input
    /// reads as white (the default danmaku colour).
    static func danmakuColor(hex: String) -> Color {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return .white }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Rendering

/// One scrolling danmaku row. Owns its horizontal offset as
/// @State, keyed by the item id in the parent ForEach: the offset
/// animates once on appear (right edge -> off the left edge over
/// 8 s) and is never restarted by the parent's position ticks.
private struct VodDanmakuScrollingRow: View {
    let item: DanmakuItem
    let lane: Int
    let containerWidth: CGFloat
    let opacity: Double
    let fontSize: CGFloat

    @State private var xOffset: CGFloat?

    var body: some View {
        Text(item.text)
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(Color.danmakuColor(hex: item.colorHex))
            .shadow(color: .black.opacity(0.8), radius: 1, x: 0, y: 1)
            .opacity(opacity)
            .offset(x: xOffset ?? containerWidth, y: CGFloat(lane) * 24)
            .onAppear {
                withAnimation(.linear(duration: VodDanmakuLayerState.scrollDuration)) {
                    xOffset = -containerWidth
                }
            }
    }
}

/// The danmaku overlay. The page places it over the video area
/// and passes the driver's current position; the layer itself
/// decides what is visible.
struct VodDanmakuLayer: View {
    @ObservedObject var state: VodDanmakuLayerState
    var position: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let visible = state.visibleItems(at: position)
            ZStack(alignment: .topLeading) {
                // Scrolling rows, one per lane by item index.
                ForEach(visible.filter { !$0.item.isTop }, id: \.id) { entry in
                    VodDanmakuScrollingRow(
                        item: entry.item,
                        lane: entry.id % VodDanmakuLayerState.laneCount,
                        containerWidth: width,
                        opacity: state.opacity,
                        fontSize: CGFloat(state.fontSize)
                    )
                }
                // Top (pinned) rows, stacked from the top centre.
                VStack(spacing: 4) {
                    ForEach(visible.filter { $0.item.isTop }.prefix(3), id: \.id) { entry in
                        Text(entry.item.text)
                            .font(.system(size: CGFloat(state.fontSize), weight: .medium))
                            .foregroundColor(Color.danmakuColor(hex: entry.item.colorHex))
                            .shadow(color: .black.opacity(0.8), radius: 1, x: 0, y: 1)
                            .opacity(state.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 8)
            }
        }
        .allowsHitTesting(false)
    }
}

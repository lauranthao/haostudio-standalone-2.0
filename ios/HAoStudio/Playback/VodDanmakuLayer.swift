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
    /// A fetch is in flight for the current episode. The player
    /// page reads this (with `didLoad`) to decide whether the
    /// danmaku switch is real yet: a switch shown while the fetch
    /// is still running would be a fake switch when the episode
    /// turns out to have no danmaku source.
    @Published private(set) var isLoading = false
    /// A fetch finished for the current episode (items or empty).
    /// False before the first load and while a reload is running.
    @Published private(set) var didLoad = false

    /// How long a scrolling line takes to cross the screen.
    static let scrollDuration: Double = 8
    /// How long a top line stays pinned.
    static let topDuration: Double = 5
    /// Scrolling lanes.
    static let laneCount: Int = 4

    private var loadedEpisodeId: String?

    /// Fetch danmaku for `episode` through `provider`. A nil
    /// provider (Leg B not wired yet) leaves the layer empty —
    /// never a crash, never a fake list. Re-loading the same
    /// episode is a no-op.
    func load(for episode: PlayEpisode, provider: VodDanmakuProvider?) {
        guard loadedEpisodeId != episode.id else { return }
        loadedEpisodeId = episode.id
        items = []
        guard let provider = provider else {
            isLoading = false
            didLoad = true
            return
        }
        isLoading = true
        didLoad = false
        provider.fetchDanmaku(for: episode) { [weak self] fetched in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.items = fetched.sorted { $0.timeSeconds < $1.timeSeconds }
                self.isLoading = false
                self.didLoad = true
            }
        }
    }

    /// Clear the layer (episode changed / player released).
    func clear() {
        loadedEpisodeId = nil
        items = []
        isLoading = false
        didLoad = false
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
enum VodDanmakuAvailability {
    case loading
    case available
    case unavailable

    /// Pure derivation from the layer state, so tests can drive it
    /// without a view. Items win over loading: while a new episode
    /// reloads, the old items are already cleared by `load`, so a
    /// non-empty list always means switchable danmaku.
    static func resolve(isLoading: Bool, didLoad: Bool, itemCount: Int) -> VodDanmakuAvailability {
        if itemCount > 0 { return .available }
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

    @State private var xOffset: CGFloat?

    var body: some View {
        Text(item.text)
            .font(.system(size: 16, weight: .medium))
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
                        opacity: state.opacity
                    )
                }
                // Top (pinned) rows, stacked from the top centre.
                VStack(spacing: 4) {
                    ForEach(visible.filter { $0.item.isTop }.prefix(3), id: \.id) { entry in
                        Text(entry.item.text)
                            .font(.system(size: 16, weight: .medium))
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

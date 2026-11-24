// HAo Studio 2.0 — draggable sidebar container (build 36, item 19).
//
// Chen 2026-11-24 screenshot: Emby-style sidebar under the poster
// wall; the wall drags sideways with the finger and springs open /
// closed. Apple-native behaviour, system primitives only:
// DragGesture + spring + selection haptic. No custom gesture
// recogniser, no invented physics.
//
// Wiring (browse page):
//   @StateObject private var sidebarDrag = HaoSidebarDragState()
//   HaoDragSidebar(state: sidebarDrag) {
//       BrowseSidebarContent(...)          // rows, see §3.5
//   } content: {
//       VStack(spacing: 0) {
//           filterRows                      // NOT draggable: strips keep their own scroll
//           ScrollView { VideoPosterGrid(...) }
//               .simultaneousGesture(sidebarDrag.contentDragGesture)
//       }
//   }
// The container measures its own width (GeometryReader) and hands
// it to the state; the gesture is attached ONLY to the grid's
// ScrollView, so a horizontal swipe on a filter/chip strip scrolls
// the strip and never moves the panel.

import SwiftUI

/// Shared drag state for one sidebar. Owned by the page
/// (`@StateObject`), passed to both the container and the grid's
/// gesture, so panel offset and gesture read the same state.
@MainActor
final class HaoSidebarDragState: ObservableObject {
    /// Settled state: sidebar fully open / closed.
    @Published var isOpen = false
    /// Live finger offset during a drag (0 when not dragging).
    @Published private(set) var dragOffset: CGFloat = 0
    /// Width measured by the container (0 until first layout).
    @Published private(set) var width: CGFloat = 0

    private var dragEngaged = false
    private var dragBaseOffset: CGFloat = 0

    /// Total panel offset: settled position + live finger offset.
    var totalOffset: CGFloat { (isOpen ? width : 0) + dragOffset }

    /// Open progress 0...1 for dim / corner / shadow.
    var progress: CGFloat {
        CGFloat(HaoSidebarDragMath.progress(offset: Double(totalOffset), width: Double(width)))
    }

    /// Called by the container from its GeometryReader.
    func setWidth(_ newWidth: CGFloat) {
        guard newWidth > 0, newWidth != width else { return }
        width = newWidth
    }

    func toggle() {
        withAnimation(HaoLayout.settleSpring) { isOpen.toggle() }
    }

    func close() {
        guard isOpen || dragOffset != 0 else { return }
        withAnimation(HaoLayout.settleSpring) {
            isOpen = false
            dragOffset = 0
        }
    }

    /// The drag gesture for the scrollable content region (the
    /// poster grid's ScrollView). Attach with
    /// `.simultaneousGesture(...)` so vertical scrolling keeps
    /// working — the ScrollView still gets the touch; this
    /// handler only follows the horizontal component, and only
    /// once horizontal clearly dominates (direction lock).
    var contentDragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { [weak self] value in
                guard let self = self, self.width > 0 else { return }
                let translation = value.translation
                if !self.dragEngaged {
                    // Direction lock: a mostly-vertical touch
                    // belongs to the poster's vertical scroll —
                    // ignore it and let the ScrollView keep it.
                    guard abs(translation.width) > abs(translation.height) else { return }
                    self.dragEngaged = true
                    self.dragBaseOffset = self.isOpen ? self.width : 0
                }
                // Follow the finger 1:1 (no animation while
                // dragging), rubber-banded past the ends.
                let raw = Double(self.dragBaseOffset + translation.width)
                let clamped = HaoSidebarDragMath.clampedOffset(raw: raw, min: 0, max: Double(self.width))
                self.dragOffset = CGFloat(clamped) - self.dragBaseOffset
            }
            .onEnded { [weak self] value in
                guard let self = self else { return }
                let total = Double((self.isOpen ? self.width : 0) + self.dragOffset)
                let totalMovement = Double(hypot(value.translation.width, value.translation.height))
                self.dragEngaged = false
                if HaoSidebarDragMath.isTap(totalMovement: totalMovement) {
                    // A tap: the panel barely moved; clear the
                    // live offset with a settle spring so even a
                    // 10pt nudge never sticks.
                    withAnimation(HaoLayout.settleSpring) { self.dragOffset = 0 }
                    return
                }
                let open = HaoSidebarDragMath.shouldOpen(
                    currentOffset: total,
                    velocity: Double(value.velocity.width),
                    width: Double(self.width))
                withAnimation(HaoLayout.settleSpring) {
                    self.dragOffset = 0
                    self.isOpen = open
                }
            }
    }
}

/// A left sidebar under a sliding content panel.
struct HaoDragSidebar<Sidebar: View, Content: View>: View {
    @ObservedObject var state: HaoSidebarDragState
    var sidebar: Sidebar
    var content: Content

    @Environment(\.haoTheme) private var theme

    init(
        state: HaoSidebarDragState,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder content: () -> Content
    ) {
        self.state = state
        self.sidebar = sidebar()
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let width = CGFloat(HaoSidebarDragMath.sidebarWidth(screenWidth: Double(geometry.size.width)))
            ZStack(alignment: .leading) {
                sidebar
                    .frame(width: width)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(theme.surfaceSolid)
                contentPanel(width: width)
            }
            .onAppear { state.setWidth(width) }
            .onChange(of: geometry.size.width) { _, _ in state.setWidth(width) }
            .haoSensoryFeedback(.selection, trigger: state.isOpen)
        }
    }

    private func contentPanel(width: CGFloat) -> some View {
        let progress = state.progress
        let radius = HaoLayout.floatingChromeCornerRadius * progress
        return ZStack {
            content
                .background(theme.scaffoldBackground)
            // Dim while open: tap closes. It carries the same
            // drag gesture so a close-drag starting on the dim
            // works (a bare tap-gesture view would eat the touch).
            if progress > 0.02 {
                Color.black.opacity(0.3 * progress)
                    .onTapGesture { state.close() }
                    .simultaneousGesture(state.contentDragGesture)
            }
        }
        .offset(x: state.totalOffset)
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: radius,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous))
        .shadow(
            color: .black.opacity(0.2 * progress),
            radius: 16 * progress, x: -8 * progress, y: 0)
    }
}

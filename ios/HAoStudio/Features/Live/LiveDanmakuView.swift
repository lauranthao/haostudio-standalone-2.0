// HAo Studio 2.0 — live danmaku views (S4-C leg).
//
// Two renderings of the same live stream (A-leg transport,
// B-leg settings model):
// - Portrait: the chat list below the video (Flutter's portrait
//   list — a list has no scroll speed and no overlay area to
//   size, so speed/area show as explanatory text in settings,
//   never sliders).
// - Landscape: flying danmaku over the video (VOD layer pattern:
//   8 s right-to-left, deterministic lanes, white text with a
//   dark shadow — danmaku is video-overlay content, not themed
//   chrome, and white is the only colour readable over any
//   video frame in either mode).
//
// Read-only: the app never sends danmaku (B-leg transports are
// receive-only).
//
// Every one of the 14 settings is honoured here — a toggle that
// did nothing would be an orphan control:
// enabled-per-platform, font size, opacity, area (fullscreen
// only), list style, row spacing, show usernames, similarity
// filter + threshold, block emote-only, block long + length,
// Douyu bot filter, blocked words/users.

import Foundation
import SwiftUI

// MARK: - Filter (pure)

/// Content filtering for one incoming message. Pure functions:
/// the list and the overlay both call shouldShow when a message
/// arrives, so a hidden message never enters either view.
enum LiveDanmakuFilter {
    /// Whether `message` may be shown under `settings`.
    /// `recentTexts` are the texts already shown (most recent
    /// first, capped by the caller) — the similarity filter only
    /// compares against those.
    static func shouldShow(
        message: DanmakuMessage,
        settings: LiveDanmakuSettings,
        recentTexts: [String]
    ) -> Bool {
        if settings.blockedEntries.contains(where: { entry in
            entry.isUser ? entry.text == message.userName : message.text.contains(entry.text)
        }) {
            return false
        }
        if settings.blockEmoteOnly && isEmoteOnly(message.text) {
            return false
        }
        if settings.blockLong && message.text.count > settings.blockLongLength {
            return false
        }
        if settings.douyuBotFilter && message.suspectedAutomated {
            return false
        }
        if settings.similarityEnabled {
            let threshold = Double(settings.similarityThreshold) / 100
            for recent in recentTexts {
                if similarity(message.text, recent) >= threshold {
                    return false
                }
            }
        }
        return true
    }

    /// True when the text is only emoji and/or [表情] tokens.
    static func isEmoteOnly(_ text: String) -> Bool {
        var remainder = text
        while let open = remainder.firstIndex(of: "["),
              let close = remainder[open...].firstIndex(of: "]"),
              close > open {
            remainder.removeSubrange(open...close)
        }
        let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        for scalar in trimmed.unicodeScalars {
            if scalar.properties.isEmoji { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            return false
        }
        return true
    }

    /// Normalised text for similarity: lowercase, no punctuation,
    /// no digits, no whitespace (Flutter: "加标点、数字变体" still
    /// counts as similar).
    static func normalized(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.punctuationCharacters.contains(scalar) { continue }
            if CharacterSet.decimalDigits.contains(scalar) { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// Similarity 0...1 between two texts (1 = identical after
    /// normalisation). Empty-after-normalisation texts are never
    /// similar (they carry nothing to compare).
    static func similarity(_ left: String, _ right: String) -> Double {
        let a = normalized(left)
        let b = normalized(right)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let distance = levenshtein(a, b)
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(distance) / Double(longest)
    }

    /// Levenshtein edit distance (two-row DP, no allocation blowup
    /// on long texts — capped inputs keep it cheap).
    static func levenshtein(_ left: String, _ right: String) -> Int {
        let a = Array(left)
        let b = Array(right)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                let deletion = previous[j] + 1
                let insertion = current[j - 1] + 1
                let substitution = previous[j - 1] + cost
                current[j] = min(deletion, insertion, substitution)
            }
            previous = current
        }
        return previous[b.count]
    }
}

// MARK: - Shared helpers

/// Flying area fraction for the settings `area` value (fullscreen
/// only): whole video / top half / top third / top fifth.
func liveDanmakuAreaFraction(_ area: String) -> Double {
    switch area {
    case "half": return 0.5
    case "third": return 1.0 / 3.0
    case "fifth": return 1.0 / 5.0
    default: return 1.0
    }
}

/// Row vertical padding for the settings `listSpacing` value.
func liveDanmakuRowPadding(_ spacing: String) -> CGFloat {
    switch spacing {
    case "compact": return 2
    case "loose": return 12
    default: return 6
    }
}

/// UIColor from a 0xAARRGGBB danmaku colour (platform colour
/// mode). A zero RGB means the platform sent no colour — white,
/// never black-on-video. The transports already map a missing
/// colour to white; this guard covers a raw zero.
func liveDanmakuColor(argb: UInt32) -> Color {
    let rgb = argb & 0x00FF_FFFF
    guard rgb != 0 else { return .white }
    let alpha = CGFloat((argb >> 24) & 0xFF) / 255
    return Color(
        red: CGFloat((argb >> 16) & 0xFF) / 255,
        green: CGFloat((argb >> 8) & 0xFF) / 255,
        blue: CGFloat(argb & 0xFF) / 255,
        opacity: alpha > 0 ? alpha : 1)
}

// MARK: - Shared toggle button

/// The one danmaku on/off button both players use (live portrait
/// strip + live landscape bar; the VOD "更多" sheet binds the same
/// on/off rule to a Toggle row instead — one switch rule, one icon
/// language: filled message = on, outline = off). On-video chrome
/// is forced-dark (white on the video), the same treatment as the
/// VOD / live-landscape bars, so it reads over any frame in any of
/// the 8 theme combinations. Never a fake switch: the button only
/// appears where a danmaku layer exists to toggle.
struct DanmakuToggleButton: View {
    var isOn: Bool
    var action: () -> Void

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "message.fill" : "message")
                .font(.system(size: 18, weight: .semibold))  // icon size, not text
                .foregroundStyle(isOn ? theme.accentOnVideo : .white.opacity(0.5))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "关闭弹幕" : "开启弹幕")
    }
}

// MARK: - Portrait chat list

/// The portrait danmaku list: newest at the bottom, auto-scrolls
/// as messages arrive. Filters apply at arrival time, so a hidden
/// message never enters the list (and never counts toward the
/// similarity window).
struct LiveDanmakuListView: View {
    var messages: [DanmakuMessage]
    /// Monotonic append counter from the view model (build 35 D2):
    /// observed alongside `messages.count`, because the count stops
    /// changing once the 200-message window is full.
    var sequence: Int
    var settings: LiveDanmakuSettings
    var platform: String
    var onOpenSettings: () -> Void

    @Environment(\.haoTheme) private var theme
    @State private var shown: [DanmakuMessage] = []
    @State private var recentTexts: [String] = []
    @State private var lastSeenCount = 0
    @State private var lastSeenSequence = 0
    /// Bumps whenever `shown` changes (build 35 sweep S8): the
    /// auto-scroll trigger. `shown.count` cannot be the trigger
    /// any more — once the list is capped at `maxCount`, an append
    /// + trim leaves the count unchanged and the scroll would
    /// freeze, the same trap D2 fixed for `messages.count`.
    @State private var shownVersion = 0
    /// Last auto-scroll time + one coalesced delayed scroll (b36
    /// item 10 D-9): a burst used to fire one 0.2 s scroll
    /// animation per message, each interrupting the last. Scrolls
    /// at most once per `scrollThrottleSeconds`; a scroll skipped
    /// by the throttle is rescheduled once, so the list still
    /// lands at the bottom when the burst ends.
    @State private var lastScrollAt = Date.distantPast
    @State private var pendingScrollWork: DispatchWorkItem?
    static let scrollThrottleSeconds: TimeInterval = 0.3

    private var isEnabled: Bool {
        settings.enabled[platform] ?? true
    }

    /// Cap the visible chat list at `maxCount` (build 35 sweep
    /// S8): `shown` was append-only, so a long session in a busy
    /// room grew it without bound — and every append re-ran
    /// `Array(shown.enumerated())` + ForEach diffing over the
    /// whole list. The view-model window (200) does not bound
    /// this array. Oldest first out. Pure, so tests can drive it
    /// without a view.
    static func capped(_ shown: [DanmakuMessage], to maxCount: Int) -> [DanmakuMessage] {
        guard shown.count > maxCount else { return shown }
        return Array(shown.suffix(maxCount))
    }

    var body: some View {
        Group {
            if !isEnabled {
                danmakuOffNote
            } else if shown.isEmpty {
                emptyNote
            } else {
                chatList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { ingestNewMessages() }
        .onDisappear {
            pendingScrollWork?.cancel()
            pendingScrollWork = nil
        }
        .onChange(of: messages.count) { _, _ in ingestNewMessages() }
        .onChange(of: sequence) { _, _ in ingestNewMessages() }
        .onChange(of: settings.enabled[platform] ?? true) { _, _ in
            if isEnabled {
                ingestNewMessages()
            }
        }
    }

    private var danmakuOffNote: some View {
        VStack(spacing: 8) {
            Text("弹幕已关闭")
                .font(.haoDenseBody)
                .foregroundStyle(theme.textSecondary)
            Button("在弹幕设置中开启", action: onOpenSettings)
                .font(.haoFootnoteMedium)
                .foregroundStyle(theme.accentText)
                .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyNote: some View {
        Text("暂无弹幕")
            .font(.haoRowSubtitle)
            .foregroundStyle(theme.textMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(
                    alignment: .leading,
                    spacing: liveDanmakuRowPadding(settings.listSpacing)
                ) {
                    // Stable row identity (b36 item 10 D-3): rows
                    // are keyed by the message's own id, never by
                    // position — head-trim used to shift every
                    // remaining row's `offset` and SwiftUI rebuilt
                    // the whole list on each trim. The old
                    // `.id(index)` modifier is gone for the same
                    // reason: it re-keyed rows by position too.
                    ForEach(shown, id: \.id) { message in
                        danmakuRow(message)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
            .onChange(of: shownVersion) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    /// Auto-scroll to the newest row, throttled (b36 item 10
    /// D-9): at most one scroll per 0.3 s; a skipped scroll is
    /// coalesced into a single delayed one so a burst still ends
    /// at the bottom. Scrolls to the last message's stable id —
    /// the old `shown.count - 1` target only worked because rows
    /// were (wrongly) keyed by index.
    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let lastId = shown.last?.id else { return }
        let now = Date()
        if now.timeIntervalSince(lastScrollAt) >= Self.scrollThrottleSeconds {
            lastScrollAt = now
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
            return
        }
        pendingScrollWork?.cancel()
        let delay = Self.scrollThrottleSeconds - now.timeIntervalSince(lastScrollAt)
        let work = DispatchWorkItem {
            guard let lastId = shown.last?.id else { return }
            lastScrollAt = Date()
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
        pendingScrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @ViewBuilder
    private func danmakuRow(_ message: DanmakuMessage) -> some View {
        if settings.listStyle == "card" {
            danmakuText(message)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            danmakuText(message)
        }
    }

    private func danmakuText(_ message: DanmakuMessage) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if settings.showUsernames && !message.userName.isEmpty {
                Text(message.userName)
                    .font(.system(size: CGFloat(settings.fontSize), weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            Text(message.text)
                .font(.system(size: CGFloat(settings.fontSize)))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
        }
        .opacity(settings.opacity)
    }

    /// Take newly arrived messages through the filter. A replaced
    /// stream (room switch: count drops) resets the list.
    /// Build 35 D2: `messages` is capped at 200, so once full its
    /// count stops changing and the count observation never fires
    /// again. The view also observes `sequence` (one per append)
    /// and, when the window slid, takes the newest `appended`
    /// messages as a suffix — those are exactly the ones that
    /// arrived since the last ingest (truncation only drops the
    /// oldest).
    private func ingestNewMessages() {
        guard isEnabled else { return }
        var changed = false
        if messages.count < lastSeenCount {
            if !shown.isEmpty {
                changed = true
            }
            shown = []
            recentTexts = []
            lastSeenCount = 0
        }
        let appended = sequence - lastSeenSequence
        lastSeenSequence = sequence
        let fresh: ArraySlice<DanmakuMessage>
        if messages.count > lastSeenCount {
            fresh = messages[lastSeenCount..<messages.count]
        } else if appended > 0, !messages.isEmpty {
            fresh = messages.suffix(min(appended, messages.count))
        } else {
            if changed {
                shownVersion += 1
            }
            return
        }
        lastSeenCount = messages.count
        for message in fresh {
            guard LiveDanmakuFilter.shouldShow(
                message: message, settings: settings, recentTexts: recentTexts
            ) else { continue }
            shown.append(message)
            changed = true
            recentTexts.insert(message.text, at: 0)
            recentTexts = Array(recentTexts.prefix(20))
        }
        // Build 35 sweep S8: cap the visible list at the
        // `maxCount` setting (this finally wires that setting —
        // until now nothing read it). The count-based scroll
        // trigger above is replaced by `shownVersion`, so the
        // scroll keeps working once the cap holds the count
        // steady.
        if changed {
            shown = Self.capped(shown, to: settings.maxCount)
            shownVersion += 1
        }
    }
}

// MARK: - Landscape flying overlay

/// One flying row: right-to-left on a fixed lane (VOD layer
/// pattern). The row owns its own offset state, keyed by a stable
/// id, so parent re-renders never restart an in-flight animation.
/// Duration, shadow and colour come from the settings (build 36
/// item 8 — the overlay used to hardcode 8 s, a fixed shadow and
/// always-white text while the model carried speed / stroke /
/// colorMode). `duration` is fixed at creation: a row created
/// before a speed change keeps its own removal time.
private struct LiveFlyingRow: View {
    var message: DanmakuMessage
    var settings: LiveDanmakuSettings
    var containerWidth: CGFloat
    var duration: Double

    @State private var offsetX: CGFloat?

    var body: some View {
        HStack(spacing: 6) {
            if settings.showUsernames && !message.userName.isEmpty {
                Text(message.userName)
                    .font(.system(size: CGFloat(settings.fontSize), weight: .semibold))
            }
            Text(message.text)
                .font(.system(size: CGFloat(settings.fontSize)))
        }
        .foregroundStyle(flyingColor)
        .shadow(
            color: settings.stroke ? .black.opacity(0.8) : .clear,
            radius: settings.stroke ? CGFloat(settings.strokeWidth) : 0, x: 0, y: 1)
        .opacity(settings.opacity)
        .offset(x: offsetX ?? containerWidth)
        .onAppear {
            withAnimation(.linear(duration: duration)) {
                offsetX = -(containerWidth + 300)
            }
        }
    }

    /// Platform colour mode uses the colour the transport
    /// supplied; uniform mode (and a missing colour) is white —
    /// the only colour readable over any video frame.
    private var flyingColor: Color {
        guard settings.colorMode == "platform" else { return .white }
        return liveDanmakuColor(argb: message.colorArgb)
    }
}

/// Flying danmaku over the fullscreen video. Lanes live inside
/// the settings area fraction (top of the video); each new
/// message takes the next lane round-robin. Messages leave one
/// crossing time after they arrive (8 s at speed 1.0 — the
/// `speed` setting divides it).
struct LiveDanmakuOverlayView: View {
    /// Flying lanes inside the area fraction (VOD parity).
    static let laneCount: Int = 4
    /// Backlog cap on a fresh mount: when the overlay (re)appears
    /// — room open, danmaku toggled back on, room switch — only
    /// the most recent N messages fly. Without it a busy room's
    /// capped 200-message history would burst onto the video at
    /// once; the overlay shows the live flow, not history (the
    /// portrait list below is the history).
    static let maxBacklogOnAppear: Int = 20

    /// First message index to ingest on a fresh mount: skip all
    /// but the most recent `maxBacklog` messages. Pure, so tests
    /// can drive it without a view.
    static func startIndexForFreshMount(messageCount: Int, maxBacklog: Int) -> Int {
        max(0, messageCount - maxBacklog)
    }

    var messages: [DanmakuMessage]
    /// Monotonic append counter from the view model (build 35 D2):
    /// observed alongside `messages.count`, because the count stops
    /// changing once the 200-message window is full.
    var sequence: Int
    var settings: LiveDanmakuSettings

    @State private var flying: [LiveFlyingItem] = []
    @State private var recentTexts: [String] = []
    @State private var lastSeenCount = 0
    @State private var lastSeenSequence = 0
    @State private var nextLane = 0
    /// Pending per-row removal work (b36 item 5): each flying
    /// row schedules its own removal one crossing time after
    /// arrival (`settings.flyingDuration` — the same duration
    /// its animation uses). A fired item removes itself from
    /// this array (b36 item 10 D-4), so it only ever holds rows
    /// still in flight. The work items are cancelled on
    /// disappear, so a back-out leaves no work behind that
    /// mutates this view's state after the room is gone.
    @State private var removalWorkItems: [DispatchWorkItem] = []

    var body: some View {
        GeometryReader { geometry in
            let areaHeight = geometry.size.height * CGFloat(liveDanmakuAreaFraction(settings.area))
            ZStack(alignment: .topLeading) {
                ForEach(flying) { item in
                    LiveFlyingRow(
                        message: item.message,
                        settings: settings,
                        containerWidth: geometry.size.width,
                        duration: settings.flyingDuration
                    )
                    .position(
                        x: geometry.size.width / 2,
                        y: laneY(item.lane, areaHeight: areaHeight)
                    )
                }
            }
            .frame(width: geometry.size.width, height: areaHeight, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .onAppear { ingestNewMessages() }
        .onDisappear {
            removalWorkItems.forEach { $0.cancel() }
            removalWorkItems = []
        }
        .onChange(of: messages.count) { _, _ in ingestNewMessages() }
        .onChange(of: sequence) { _, _ in ingestNewMessages() }
    }

    private func laneY(_ lane: Int, areaHeight: CGFloat) -> CGFloat {
        let laneHeight = areaHeight / CGFloat(LiveDanmakuOverlayView.laneCount)
        return laneHeight * (CGFloat(lane) + 0.5)
    }

    private func ingestNewMessages() {
        if messages.count < lastSeenCount {
            flying = []
            recentTexts = []
            lastSeenCount = 0
            nextLane = 0
        }
        // Fresh mount (or reset): skip the backlog, fly only the
        // most recent messages (see maxBacklogOnAppear).
        if lastSeenCount == 0 {
            lastSeenCount = Self.startIndexForFreshMount(
                messageCount: messages.count, maxBacklog: Self.maxBacklogOnAppear)
        }
        // Build 35 D2: see LiveDanmakuListView — once `messages`
        // is capped at 200 its count stops changing, so the count
        // observation never fires again. Observe `sequence` too
        // and take the newest `appended` messages as a suffix when
        // the window slid.
        let appended = sequence - lastSeenSequence
        lastSeenSequence = sequence
        let fresh: ArraySlice<DanmakuMessage>
        if messages.count > lastSeenCount {
            fresh = messages[lastSeenCount..<messages.count]
        } else if appended > 0, !messages.isEmpty {
            fresh = messages.suffix(min(appended, messages.count))
        } else {
            return
        }
        lastSeenCount = messages.count
        for message in fresh {
            guard LiveDanmakuFilter.shouldShow(
                message: message, settings: settings, recentTexts: recentTexts
            ) else { continue }
            let item = LiveFlyingItem(message: message, lane: nextLane)
            nextLane = (nextLane + 1) % LiveDanmakuOverlayView.laneCount
            flying.append(item)
            // Build 35 sweep S8: cap the in-flight rows at the
            // pool ceiling (`maxCount`, at most 72 — this finally
            // wires `flyingMaxVisibleCount`). The 8 s expiry alone
            // does not bound a burst: a busy room could hold
            // hundreds of animating rows at once.
            if flying.count > settings.flyingMaxVisibleCount {
                flying.removeFirst(flying.count - settings.flyingMaxVisibleCount)
            }
            recentTexts.insert(message.text, at: 0)
            recentTexts = Array(recentTexts.prefix(20))
            let itemId = item.id
            // Self-cleaning removal (b36 item 10 D-4): the work
            // item removes itself from `removalWorkItems` when it
            // fires, so the array only ever holds rows still in
            // flight — before this, every fired item stayed
            // retained until `onDisappear` (~3000 stale items in
            // a busy 10-minute room). `var` + IUO is the
            // self-reference: the closure captures the variable,
            // not the not-yet-created value.
            var removal: DispatchWorkItem!
            removal = DispatchWorkItem {
                flying.removeAll { $0.id == itemId }
                removalWorkItems.removeAll { $0 === removal }
            }
            removalWorkItems.append(removal)
            DispatchQueue.main.asyncAfter(deadline: .now() + settings.flyingDuration, execute: removal)
        }
    }
}

/// One in-flight overlay row (stable id survives re-renders).
private struct LiveFlyingItem: Identifiable {
    let id = UUID()
    let message: DanmakuMessage
    let lane: Int
}

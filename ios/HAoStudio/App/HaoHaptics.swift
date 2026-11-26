// HAo Studio 2.0 — haptics switch gate.
//
// Split out of Glass.swift in b49phase1 P6. Pure move —
// no symbol renamed, no value changed.

import SwiftUI

// MARK: - Haptics switch gate (build 36 follow-up, chrome O6)

/// `.sensoryFeedback`, gated by the 触感反馈 switch (Settings →
/// 触感反馈; UserDefaults key `hapticsEnabled`, default true — the
/// same key the music player already reads through
/// MusicLibraryStore.hapticsEnabled(), mirrored live by
/// SettingsStore.hapticsEnabled; no second copy of the key). Off =
/// this feedback never fires; on = the platform behaviour is
/// unchanged. The gate reads the live SettingsStore, so flipping
/// the switch takes effect without remounting.
private struct HaoGatedSensoryFeedback<V: Equatable>: ViewModifier {
    @EnvironmentObject private var settings: SettingsStore
    let feedback: SensoryFeedback
    let trigger: V

    func body(content: Content) -> some View {
        if settings.hapticsEnabled {
            content.sensoryFeedback(feedback, trigger: trigger)
        } else {
            content
        }
    }
}

extension View {
    /// `.sensoryFeedback` that obeys the 触感反馈 switch. Use this
    /// for every selection/tap haptic in the app; the raw
    /// `.sensoryFeedback` must not be called from app views (the
    /// music player's programmatic hapticTick is the only other
    /// haptic path and is already gated the same way).
    func haoSensoryFeedback<V: Equatable>(_ feedback: SensoryFeedback, trigger: V) -> some View {
        modifier(HaoGatedSensoryFeedback(feedback: feedback, trigger: trigger))
    }
}

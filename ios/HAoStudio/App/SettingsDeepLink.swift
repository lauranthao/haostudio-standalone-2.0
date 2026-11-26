// HAo Studio 2.0 — stateful deep link into a Settings row.
//
// Split out of Glass.swift in b49phase1 P6. Pure move —
// no symbol renamed, no value changed.

import SwiftUI
import Combine

/// Stateful deep link into a Settings row (b49fix4 P2-37).
/// Replaces the old two-hop 0.35s delayed `haoOpenSettingsRow`
/// NotificationCenter posts: a delayed post is fire-and-forget
/// — if the listener is not mounted yet (cold start, tab switch
/// in flight) the post is lost silently and the user lands on
/// the wrong section. A pending row survives in this store until
/// a consumer reads it, so a cold start cannot drop it.
///
/// Row ids: "backup" = 导入备份, "sources" = 来源管理.
/// Senders set the row and switch tab; consumers read it on
/// appear AND on change (a value set before the tab mounts is
/// only seen on appear; a value set while mounted is only seen
/// on change). Only MyView clears it — after its scroll + retry
/// — because it is the last actor in the chain and both
/// consumers must have seen the value first.
final class SettingsDeepLink: ObservableObject {
    static let shared = SettingsDeepLink()

    /// Known rows only (b49fix5 P2-12): an unknown row is
    /// ignored by open(row:) and never stored — both consumers'
    /// `default` branches just return, so a stranded bad value
    /// would otherwise be retried on every appear forever.
    static let knownRows: Set<String> = ["backup", "sources"]

    @Published var pendingRow: String?

    /// Row id currently flashed after a deep-link scroll
    /// ("backupImport" / "musicSources", b49fix5 P2-15): set by
    /// MyView when it scrolls, cleared ~1s later.
    /// SettingsGroupsView paints the row with accentSoft while
    /// set, so the user sees which row the link landed on.
    @Published var highlightedRow: String?

    /// Flash generation (b49fix6 P2-11): each flashRow bumps it;
    /// the delayed clear only fires for the latest generation,
    /// so a re-flash from the slow-layout retry is not cut
    /// short by the stale clear scheduled by the first flash.
    private var highlightGeneration = 0

    /// Set the highlight and clear it ~1.2s later. Re-flashing
    /// the same row re-arms the clear clock.
    func flashRow(_ row: String) {
        highlightedRow = row
        highlightGeneration += 1
        let generation = highlightGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if self.highlightGeneration == generation, self.highlightedRow == row {
                self.highlightedRow = nil
            }
        }
    }

    func open(row: String) {
        guard Self.knownRows.contains(row) else { return }
        pendingRow = row
    }
}

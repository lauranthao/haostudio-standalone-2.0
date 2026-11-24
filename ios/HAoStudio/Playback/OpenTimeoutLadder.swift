// HAo Studio 2.0 — shared open-timeout ladder (build 36, item 8,
// smell 1: Duplicated Code + Shotgun Surgery).
//
// Build 36, item 14, G-J wrote the same open-timeout ladder twice,
// word for word, in VideoDriver and LiveDriver: the same
// per-attempt budget (10 s), the same whole-open cap (2.5x), the
// same `openAttemptTimedOut` flag, the same per-attempt timeout
// with its exactly-once `settled` guard. Changing the cap meant
// editing two drivers in lockstep. The shared pieces live here;
// the two drivers keep only what genuinely differs between VOD
// and live (see "NOT shared" below).
//
// NOT shared, deliberately (do not unify without a device check):
// - The overall-cap timeout body: VideoDriver bumps the
//   generation FIRST (`nextGeneration()`), so a ladder attempt
//   that completes after the cap sees a stale gen and shuts its
//   backend down; LiveDriver does not bump it. Different
//   ghost-audio defences, each load-bearing for its driver.
// - The ladder-run superseded branch: VideoDriver drops a
//   superseded open silently; LiveDriver settles it as
//   `.loadFailed` (build 35 #11 — otherwise `isLoading` sticks
//   true forever in attemptOpen). Unifying either side changes
//   the other driver's stale-open behaviour.
// - Live's fresh-URL path (`openFresh`, `freshRounds`) and VOD's
//   transcode last resort (`failOrTranscode`): routing, not
//   timeouts — each driver keeps its own.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

/// The open-timeout numbers, in exactly one place (build 36,
/// item 8, smell 1). Both drivers alias these through their own
/// `openTimeout` / `openTotalTimeoutFactor` statics so existing
/// call sites and test seams keep their names.
enum OpenTimeoutPolicy {
    /// Per-attempt budget (build 36, item 14, G-J): each ladder
    /// attempt gets its own 10 s in production. Tests drive it
    /// shorter through the driver's `openTimeoutInterval` seam.
    static let perAttemptTimeout: TimeInterval = 10
    /// Whole-open cap factor: the whole open (ladder +
    /// re-resolution) may take at most 2.5x the per-attempt
    /// budget — 25 s in production.
    static let totalTimeoutFactor: Double = 2.5

    /// The whole-open cap for a per-attempt budget.
    static func totalTimeout(for perAttempt: TimeInterval) -> TimeInterval {
        return perAttempt * totalTimeoutFactor
    }
}

/// One ladder attempt's timeout guard, shared by VideoDriver and
/// LiveDriver (build 36, item 14, G-J — the per-attempt timeout
/// was written twice, word for word, in the two drivers).
///
/// Behaviour, identical to the code it replaces in both drivers:
/// - A hanging attempt fails like a stream error after its own
///   budget, and the ladder moves to the next engine.
/// - The `settled` guard makes the ladder completion fire exactly
///   once: a late backend answer after the timeout is dropped
///   (and its backend shut down by the caller) instead of
///   double-reporting or sounding behind the next engine.
/// - The timeout work item runs on the main queue, like the
///   original `DispatchQueue.main.asyncAfter`.
///
/// Retention (why the work item holds `self` strongly): the
/// guard is a local in the driver's attempt closure — nothing
/// else retains it after that closure returns. The dispatch
/// queue retains the work item until it fires, and the work item
/// retains the guard, so the timeout always fires even when the
/// backend never answers. `complete(ok:)` cancels the work item
/// (releasing that hold); the driver's open completion holds the
/// guard until the backend answers, so a late answer still finds
/// it. The guard holds the driver only weakly, through the
/// `onTimeout` closure the driver supplies — if the driver is
/// gone, the timeout is a no-op, exactly like the original.
/// The work item clears `timeoutWork` when it fires, so the
/// guard does not keep itself alive through its own work item
/// after the timeout.
final class OpenAttemptTimeoutGuard {
    private var settled = false
    private var attemptBackend: VideoPlayerBackend?
    private var timeoutWork: DispatchWorkItem?

    /// Arm the timeout for one attempt. `onTimeout` runs on the
    /// main queue when the budget expires before `complete(ok:)`
    /// is called; the driver uses it to record
    /// `openAttemptTimedOut`, shut the current backend down, and
    /// fail the attempt — the same body both drivers had inline.
    init(timeout: TimeInterval, onTimeout: @escaping () -> Void) {
        let work = DispatchWorkItem { [self] in
            guard !self.settled else { return }
            self.settled = true
            self.timeoutWork = nil
            onTimeout()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    /// Remember the backend this attempt opened. Call right after
    /// `openOnEngine` returns — it sets the driver's backend
    /// synchronously before opening the URL, so the backend read
    /// here is the attempt's backend, as in the original
    /// `attemptBackend = self.backend` assignment.
    func noteBackend(_ backend: VideoPlayerBackend?) {
        attemptBackend = backend
    }

    /// The backend of this attempt, for the caller's late-answer
    /// path: shut it down when it is no longer the driver's
    /// current backend.
    var backend: VideoPlayerBackend? { attemptBackend }

    /// The backend-open answer. Returns true when this call
    /// settled the attempt (timeout cancelled, completion fired);
    /// false when the attempt already timed out — the caller
    /// then runs the late-answer shutdown and returns without
    /// firing the completion again.
    @discardableResult
    func complete(ok: Bool, attemptCompletion: (Bool) -> Void) -> Bool {
        guard !settled else { return false }
        settled = true
        timeoutWork?.cancel()
        timeoutWork = nil
        attemptCompletion(ok)
        return true
    }
}

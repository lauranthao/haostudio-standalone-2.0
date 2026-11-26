// HAo Studio 2.0 — online update checker (S6, C leg).
//
// Swift port of the Flutter update_service.dart (main, 1.1.6+31),
// with the source order reversed per plan section 7.1: the shop
// server is the primary manifest source and GitHub raw is the
// fallback (Flutter does it the other way round, with Gitee).
// Everything else follows Flutter: one retry of the primary on transient failures,
// then the fallback once; version + build comparison; skip recorded
// per version+build; automatic checks throttled to 20 hours with the
// stamp written only after a manifest was fetched successfully.
//
// Differences from Flutter, all required by the plan:
// - Total cap 15 s for the whole check (primary + retry + fallback
//   together), not per request and not Flutter's 30 s. The cap is a
//   deadline: when it fires, the in-flight task is cancelled and the
//   check reports a timeout.
// - The manifest minOs is read: when it is higher than the device
//   system version the result carries requiresNewerOS, never an
//   install prompt for a build the device cannot run.
// - Completion handlers only (Swift 5.0). The checkForUpdate
//   completion arrives on the main thread, per the B-leg seam.
//
// The checker implements the B-leg UpdateChecker protocol (see
// BackupUpdateLogic.swift): checkForUpdate, lastCheckDate,
// skippedVersionLabel, skip, clearSkippedVersion. The concrete class
// is DefaultUpdateChecker because the UpdateChecker name belongs to
// the protocol.
//
// One check at a time: the checker holds a single in-flight task
// slot for the deadline guard, so the app must not run a manual and
// an automatic check concurrently.
//
// Foundation-only. URLSession, the clock, and the system version are
// all injected, so the tests run against fixtures and mocks and never
// touch the network.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why a manifest fetch failed. Kept separate so the caller can tell
/// the user what actually happened instead of a generic message.
enum UpdateFetchError: Equatable {
    case timeout
    case network
    case http(Int)
    case parse
}

/// The outcome of one update check, before it is mapped onto the
/// B-leg UpdateCheckResult the UI reads.
enum UpdateCheckOutcome {
    case newerAvailable(UpdateManifest)
    case skipped(UpdateManifest)
    case upToDate(UpdateManifest)
    case requiresHigherOS(UpdateManifest, requiredMinOs: String)
    case unavailable(UpdateFetchError)
}

/// Which manifest source answered (b49fix2 P2-68): the shop
/// server (primary) or GitHub raw (fallback).
enum UpdateManifestSource: String {
    case primary
    case fallback
}

/// One in-flight fetch, cancellable by the deadline guard.
protocol UpdateCancellable: AnyObject {
    func cancel()
}

extension URLSessionTask: UpdateCancellable {}

/// One manifest fetch: body data, HTTP response, or a transport
/// error. Returns the in-flight task so the caller can cancel it.
/// The timeout is the time left under the check total cap.
protocol UpdateFetching {
    func fetch(url: URL, timeout: TimeInterval, completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) -> UpdateCancellable
}

/// The live fetcher: one GET over the shared URLSession.
struct URLSessionUpdateFetcher: UpdateFetching {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(url: URL, timeout: TimeInterval, completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) -> UpdateCancellable {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request) { data, response, error in
            completion(data, response as? HTTPURLResponse, error)
        }
        task.resume()
        return task
    }
}

/// Clock abstraction: the checker never reads the wall clock
/// directly, so tests can drive the 15 s cap and the 20 h throttle
/// without waiting.
protocol UpdateClock {
    func now() -> Date
    func scheduleAfter(_ delay: TimeInterval, work: @escaping () -> Void)
}

/// The live clock.
struct SystemUpdateClock: UpdateClock {
    func now() -> Date {
        Date()
    }

    func scheduleAfter(_ delay: TimeInterval, work: @escaping () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// System version abstraction: the minOs comparison needs the device
/// version, and tests need to pretend to be older devices.
protocol UpdateSystemInfo {
    var operatingSystemVersionString: String { get }
}

/// The live system version, from ProcessInfo.
struct ProcessUpdateSystemInfo: UpdateSystemInfo {
    var operatingSystemVersionString: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

/// Holds the one in-flight fetch so the deadline guard can cancel
/// it. Locked because the fetch and the guard run on different
/// queues.
final class UpdateTaskSlot {
    private let lock = NSLock()
    private var task: UpdateCancellable?

    func set(_ task: UpdateCancellable?) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func clear(_ task: UpdateCancellable) {
        lock.lock()
        if self.task === task {
            self.task = nil
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}

final class DefaultUpdateChecker: UpdateChecker {
    /// Primary manifest: the shop server.
    static let primaryManifestURLString = "https://chen-hao-shop-production.up.railway.app/version.json"
    /// Fallback manifest: GitHub raw (this repo's version.json).
    static let fallbackManifestURLString = "https://raw.githubusercontent.com/lauranthao/haostudio-standalone-2.0/main/version.json"

    /// Total wall-clock cap for one check: primary + retry + fallback
    /// together must finish inside this. Not per request.
    static let totalTimeout: TimeInterval = 15

    /// Automatic checks run at most once per interval.
    static let autoCheckInterval: TimeInterval = 20 * 60 * 60

    /// UserDefaults keys. The first three are the Flutter Hive key
    /// names, so a migrated 1.1.6 install keeps its skip and
    /// throttle state. The last one is 2.0-native: the display date
    /// of the last successful fetch of any kind (manual or auto).
    static let skippedVersionKey = "skippedVersion"
    static let lastUpdateCheckAtKey = "lastUpdateCheckAt"
    static let autoUpdateCheckKey = "autoUpdateCheck"
    static let lastCheckDateKey = "hao_last_update_check_date"
    /// The last primary manifest id seen ("version+build", b49fix2
    /// P2-68): a fallback answer on a later launch is compared
    /// against this, so a drift between the two sources is caught
    /// even when the shop has been down for days. This is checker
    /// state, not user data — it is deliberately not in the
    /// backup catalogue.
    static let lastPrimaryManifestKey = "hao_last_primary_manifest"

    /// The two manifest URLs, parsed once. Both literals are valid.
    static let primaryManifestURL = URL(string: DefaultUpdateChecker.primaryManifestURLString)!
    static let fallbackManifestURL = URL(string: DefaultUpdateChecker.fallbackManifestURLString)!

    /// Current app version, from the bundle unless the caller passes
    /// explicit values (tests always pass them).
    static var bundleVersion: String {
        if let info = Bundle.main.infoDictionary,
           let version = info["CFBundleShortVersionString"] as? String {
            return version
        }
        return "0.0.0"
    }

    /// Current app build, from the bundle unless the caller passes
    /// explicit values.
    static var bundleBuild: Int {
        if let info = Bundle.main.infoDictionary,
           let buildString = info["CFBundleVersion"] as? String,
           let build = Int(buildString) {
            return build
        }
        return 0
    }

    let currentVersion: String
    let currentBuild: Int

    private let fetcher: UpdateFetching
    private let clock: UpdateClock
    private let systemInfo: UpdateSystemInfo
    private let defaults: UserDefaults
    private let stateQueue = DispatchQueue(label: "com.haostudio.update-checker")

    /// Kind of the most recent fetch failure, for the manual-check
    /// error message. Nil when the last fetch succeeded or none ran.
    private(set) var lastFetchError: UpdateFetchError?

    /// HTTP status of the most recent fetch failure, when the failure
    /// was an HTTP error. Nil otherwise.
    private(set) var lastHttpStatus: Int?

    /// Source of the last manifest fetched successfully (b49fix2
    /// P2-68). Nil when no manifest was ever fetched.
    private(set) var lastManifestSource: UpdateManifestSource?

    /// True when the last fallback answer disagreed with the
    /// last-seen primary manifest (b49fix2 P2-68). The fallback
    /// result is still used — the check must not fail outright
    /// when the shop is down — but the disagreement is logged
    /// and flagged instead of silently trusted as truth.
    private(set) var lastFallbackDisagreed = false

    init(
        currentVersion: String = DefaultUpdateChecker.bundleVersion,
        currentBuild: Int = DefaultUpdateChecker.bundleBuild,
        fetcher: UpdateFetching = URLSessionUpdateFetcher(),
        clock: UpdateClock = SystemUpdateClock(),
        systemInfo: UpdateSystemInfo = ProcessUpdateSystemInfo(),
        defaults: UserDefaults = .standard
    ) {
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.fetcher = fetcher
        self.clock = clock
        self.systemInfo = systemInfo
        self.defaults = defaults
    }

    // MARK: - B-leg seam

    /// Last successful manifest fetch of any kind (manual or auto),
    /// or nil when never checked. This is a display date only: the
    /// 20 h throttle reads its own stamp, so a manual check never
    /// moves the automatic window.
    var lastCheckDate: Date? {
        guard let seconds = (defaults.object(forKey: DefaultUpdateChecker.lastCheckDateKey) as? NSNumber)?.doubleValue, seconds > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    /// "1.1.6 (build 32)" when a version is skipped, else nil. The
    /// stored value is the Flutter-style "version+build" id, so a
    /// migrated 1.1.6 skip keeps working; the label is derived.
    var skippedVersionLabel: String? {
        guard let id = defaults.string(forKey: DefaultUpdateChecker.skippedVersionKey), !id.isEmpty else {
            return nil
        }
        guard let plus = id.lastIndex(of: "+") else {
            return id
        }
        let version = String(id[..<plus])
        let buildText = String(id[id.index(after: plus)...])
        guard let build = Int(buildText) else {
            return id
        }
        return "\(version) (build \(build))"
    }

    func skip(version: String, build: Int) {
        defaults.set("\(version)+\(build)", forKey: DefaultUpdateChecker.skippedVersionKey)
    }

    func clearSkippedVersion() {
        defaults.removeObject(forKey: DefaultUpdateChecker.skippedVersionKey)
    }

    // MARK: - Manual and automatic checks

    /// Manual check (Settings, About, Check for updates). Always
    /// reports a result. The completion arrives on the main thread.
    func checkForUpdate(completion: @escaping (UpdateCheckResult) -> Void) {
        fetchRemote { manifest, error in
            let result: UpdateCheckResult
            if let manifest = manifest {
                result = self.result(for: self.classify(manifest))
            } else {
                result = UpdateCheckResult(
                    latestVersion: nil, latestBuild: nil, minOs: nil,
                    downloadURL: nil, releaseNotes: nil,
                    requiresNewerOS: false, isSkipped: false,
                    failureMessage: DefaultUpdateChecker.failureMessage(for: error ?? .network)
                )
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// Automatic check. Returns nil when it should stay silent:
    /// throttled, up to date, skipped, fetch failed, or the release
    /// needs a higher iOS than the device runs. The completion
    /// arrives on the main thread.
    ///
    /// The throttle stamp is written only after the remote manifest
    /// was fetched successfully: a failed fetch must not consume the
    /// 20 h window, so the next cold start retries instead of staying
    /// silent for 20 h.
    func checkAuto(completion: @escaping (UpdateCheckResult?) -> Void) {
        let last = (defaults.object(forKey: DefaultUpdateChecker.lastUpdateCheckAtKey) as? NSNumber)?.int64Value ?? 0
        let nowMs = Int64(clock.now().timeIntervalSince1970 * 1000)
        if nowMs - last < Int64(DefaultUpdateChecker.autoCheckInterval * 1000) {
            DispatchQueue.main.async {
                completion(nil)
            }
            return
        }
        fetchRemote { manifest, _ in
            guard let manifest = manifest else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            self.defaults.set(nowMs, forKey: DefaultUpdateChecker.lastUpdateCheckAtKey)
            let outcome = self.classify(manifest)
            if case .newerAvailable = outcome {
                let found = self.result(for: outcome)
                DispatchQueue.main.async {
                    completion(found)
                }
            } else {
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }
    }

    /// Automatic check gated by the "launch-time automatic check"
    /// switch (autoUpdateCheck, default on). When the switch is off
    /// no request is sent and the throttle stamp is not written, so
    /// turning the switch back on checks on the next cold start. The
    /// manual check is never gated.
    func checkAutoIfEnabled(completion: @escaping (UpdateCheckResult?) -> Void) {
        if let flag = defaults.object(forKey: DefaultUpdateChecker.autoUpdateCheckKey) as? NSNumber,
           CFGetTypeID(flag) == CFBooleanGetTypeID(),
           !flag.boolValue {
            DispatchQueue.main.async {
                completion(nil)
            }
            return
        }
        checkAuto(completion: completion)
    }

    // MARK: - Classification and result mapping

    /// Classifies one fetched manifest against this device.
    func classify(_ manifest: UpdateManifest) -> UpdateCheckOutcome {
        if let minOs = manifest.minOs,
           VersionCompare.compare(minOs, systemInfo.operatingSystemVersionString) > 0 {
            return .requiresHigherOS(manifest, requiredMinOs: minOs)
        }
        if !isNewer(manifest) {
            return .upToDate(manifest)
        }
        if isSkipped(manifest) {
            return .skipped(manifest)
        }
        return .newerAvailable(manifest)
    }

    /// A release is newer when its version is newer, or when the
    /// version is equal and its build is higher.
    func isNewer(_ manifest: UpdateManifest) -> Bool {
        if VersionCompare.isNewerVersion(manifest.version, than: currentVersion) {
            return true
        }
        if VersionCompare.isNewerVersion(currentVersion, than: manifest.version) {
            return false
        }
        return manifest.build > currentBuild
    }

    /// Maps one classified outcome onto the B-leg result the UI
    /// reads. An up-to-date device reports no latest version; a
    /// failed fetch reports only a failure message.
    private func result(for outcome: UpdateCheckOutcome) -> UpdateCheckResult {
        switch outcome {
        case .newerAvailable(let manifest):
            return result(for: manifest, requiresNewerOS: false, isSkipped: false)
        case .skipped(let manifest):
            return result(for: manifest, requiresNewerOS: false, isSkipped: true)
        case .upToDate:
            return UpdateCheckResult(
                latestVersion: nil, latestBuild: nil, minOs: nil,
                downloadURL: nil, releaseNotes: nil,
                requiresNewerOS: false, isSkipped: false, failureMessage: nil
            )
        case .requiresHigherOS(let manifest, _):
            return result(for: manifest, requiresNewerOS: true, isSkipped: false)
        case .unavailable(let error):
            return UpdateCheckResult(
                latestVersion: nil, latestBuild: nil, minOs: nil,
                downloadURL: nil, releaseNotes: nil,
                requiresNewerOS: false, isSkipped: false,
                failureMessage: DefaultUpdateChecker.failureMessage(for: error)
            )
        }
    }

    private func result(for manifest: UpdateManifest, requiresNewerOS: Bool, isSkipped: Bool) -> UpdateCheckResult {
        UpdateCheckResult(
            latestVersion: manifest.version,
            latestBuild: manifest.build,
            minOs: manifest.minOs,
            downloadURL: manifest.downloadURL,
            // b36 item 8, F5: preferredLanguages carries the script
            // subtag ("zh-Hant-TW"), languageCode alone is just
            // "zh" — Traditional users would get Simplified notes.
            // b49fix26: member order is releaseNotes, size, sha256
            // (Bitrise #36) — the old order put size first.
            releaseNotes: manifest.changelog?.localized(for: Locale.preferredLanguages.first ?? Locale.current.languageCode),
            // b49fix2 P1-40: the manifest's size + hash ride into
            // the result so the downloader can verify the IPA
            // instead of trusting any 200 body.
            size: manifest.size,
            sha256: manifest.sha256,
            requiresNewerOS: requiresNewerOS,
            isSkipped: isSkipped,
            // b49fix4 P2-43: the single manifest-result funnel —
            // every manifest-backed result (manual + auto) carries
            // its source. `fromFallback` is the source itself
            // (lastManifestSource), NOT the drift flag — the old
            // code showed no source note for a clean fallback
            // result. Drift rides separately in fallbackDisagreed.
            fromFallback: lastManifestSource == .fallback,
            fallbackDisagreed: lastFallbackDisagreed,
            failureMessage: nil
        )
    }

    /// Shown as-is by the UI when the check fetched nothing.
    static func failureMessage(for error: UpdateFetchError) -> String {
        switch error {
        case .timeout:
            return "检查超时，请稍后再试"
        case .network:
            return "网络不可用，请检查网络后重试"
        case .http(let status):
            return "服务器返回了错误（\(status)），请稍后再试"
        case .parse:
            return "更新信息解析失败，请稍后再试"
        }
    }

    // MARK: - Skip list (manifest form, internal)

    func isSkipped(_ manifest: UpdateManifest) -> Bool {
        defaults.string(forKey: DefaultUpdateChecker.skippedVersionKey) == manifest.id
    }

    func skip(_ manifest: UpdateManifest) {
        skip(version: manifest.version, build: manifest.build)
    }

    // MARK: - Fetch: primary, one retry, then fallback

    /// Fetches the remote manifest. Never throws. When both sources
    /// fail, the primary error is reported: it is the source the user
    /// can actually reach. The whole check is capped at totalTimeout
    /// by a deadline: when it fires, the in-flight task is cancelled
    /// and the check reports a timeout.
    ///
    /// b49fix2 P1-5: the task slot is PER CHECK, created here and
    /// passed down — the old shared instance slot let a manual and
    /// an automatic check share one slot, so one check's deadline
    /// guard cancelled the other's in-flight task and one
    /// completion was dropped (a manual check could stick on
    /// "checking" forever). Each check now completes independently.
    func fetchRemote(completion: @escaping (UpdateManifest?, UpdateFetchError?) -> Void) {
        let slot = UpdateTaskSlot()
        let deadline = clock.now().addingTimeInterval(DefaultUpdateChecker.totalTimeout)
        var finished = false
        let finish: (UpdateManifest?, UpdateFetchError?) -> Void = { manifest, error in
            self.stateQueue.async {
                guard !finished else {
                    return
                }
                finished = true
                slot.set(nil)
                self.lastFetchError = error
                if let error = error, case .http(let status) = error {
                    self.lastHttpStatus = status
                } else {
                    self.lastHttpStatus = nil
                }
                if manifest != nil {
                    self.defaults.set(self.clock.now().timeIntervalSince1970, forKey: DefaultUpdateChecker.lastCheckDateKey)
                }
                completion(manifest, error)
            }
        }
        clock.scheduleAfter(DefaultUpdateChecker.totalTimeout) {
            self.stateQueue.async {
                slot.cancel()
                finish(nil, .timeout)
            }
        }
        attemptPrimary(deadline: deadline, allowRetry: true, finish: finish, slot: slot)
    }

    private func attemptPrimary(
        deadline: Date,
        allowRetry: Bool,
        finish: @escaping (UpdateManifest?, UpdateFetchError?) -> Void,
        slot: UpdateTaskSlot
    ) {
        fetchOne(url: DefaultUpdateChecker.primaryManifestURL, deadline: deadline, slot: slot) { manifest, error in
            if let manifest = manifest {
                self.recordPrimaryManifest(manifest)
                finish(manifest, nil)
                return
            }
            let failure = error ?? .network
            if allowRetry && DefaultUpdateChecker.isTransient(failure) {
                self.attemptPrimary(deadline: deadline, allowRetry: false, finish: { retryManifest, retryError in
                    if let retryManifest = retryManifest {
                        self.recordPrimaryManifest(retryManifest)
                        finish(retryManifest, nil)
                        return
                    }
                    self.attemptFallback(deadline: deadline, primaryError: retryError ?? failure, finish: finish, slot: slot)
                }, slot: slot)
                return
            }
            if allowRetry {
                // Non-transient primary failure: no retry, straight
                // to the fallback.
                self.attemptFallback(deadline: deadline, primaryError: failure, finish: finish, slot: slot)
            } else {
                // The retry already ran and failed: report it. The
                // caller (the retry handler above) runs the fallback
                // exactly once — calling it here too would fetch the
                // fallback twice and hang when the script is spent.
                finish(nil, failure)
            }
        }
    }

    /// Record a primary manifest as the last-seen truth (b49fix2
    /// P2-68): the fallback is compared against this id.
    private func recordPrimaryManifest(_ manifest: UpdateManifest) {
        lastManifestSource = .primary
        lastFallbackDisagreed = false
        defaults.set(manifest.id, forKey: DefaultUpdateChecker.lastPrimaryManifestKey)
    }

    /// Record a fallback answer (b49fix2 P2-68): when it disagrees
    /// with the last-seen primary, flag it and log — the two
    /// sources serve the same version.json, so a drift means one
    /// of them is stale. The fallback result is still used (the
    /// shop may genuinely be down); it is just never silently
    /// treated as truth.
    private func recordFallbackManifest(_ manifest: UpdateManifest) {
        lastManifestSource = .fallback
        if let lastPrimary = defaults.string(forKey: DefaultUpdateChecker.lastPrimaryManifestKey),
           !lastPrimary.isEmpty,
           lastPrimary != manifest.id {
            lastFallbackDisagreed = true
            print("[UpdateChecker] WARNING: fallback manifest \(manifest.id) disagrees with last-seen primary \(lastPrimary)")
        } else {
            lastFallbackDisagreed = false
        }
    }

    private func attemptFallback(
        deadline: Date,
        primaryError: UpdateFetchError,
        finish: @escaping (UpdateManifest?, UpdateFetchError?) -> Void,
        slot: UpdateTaskSlot
    ) {
        fetchOne(url: DefaultUpdateChecker.fallbackManifestURL, deadline: deadline, slot: slot) { manifest, _ in
            if let manifest = manifest {
                self.recordFallbackManifest(manifest)
                finish(manifest, nil)
                return
            }
            finish(nil, primaryError)
        }
    }

    /// One GET of a manifest URL. Classifies every failure; never
    /// throws. The request timeout is the time left under the total
    /// cap, so a hung request cannot outlive the check even if the
    /// deadline guard never fires.
    private func fetchOne(
        url: URL,
        deadline: Date,
        slot: UpdateTaskSlot,
        completion: @escaping (UpdateManifest?, UpdateFetchError?) -> Void
    ) {
        let remaining = deadline.timeIntervalSince(clock.now())
        guard remaining > 0 else {
            completion(nil, .timeout)
            return
        }
        var task: UpdateCancellable? = nil
        let fetched = fetcher.fetch(url: url, timeout: remaining) { data, response, error in
            if let task = task {
                slot.clear(task)
            }
            if let urlError = error as? URLError {
                if urlError.code == .timedOut {
                    completion(nil, .timeout)
                } else {
                    completion(nil, .network)
                }
                return
            }
            if error != nil {
                completion(nil, .network)
                return
            }
            guard let http = response else {
                completion(nil, .network)
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(nil, .http(http.statusCode))
                return
            }
            guard let data = data,
                  let object = try? JSONSerialization.jsonObject(with: data, options: []),
                  let manifest = UpdateManifestParser.parse(object)
            else {
                completion(nil, .parse)
                return
            }
            completion(manifest, nil)
        }
        task = fetched
        slot.set(fetched)
    }

    /// Transient: worth one immediate retry on the same host. A parse
    /// failure is never transient: retrying a manifest the server
    /// already answered cannot fix it.
    static func isTransient(_ error: UpdateFetchError) -> Bool {
        switch error {
        case .timeout:
            return true
        case .network:
            return true
        case .http(let status):
            return status >= 500 && status < 600
        case .parse:
            return false
        }
    }
}

// LXEngine.swift
// LX music-source engine: JavaScriptCore, one JSContext per script.
//
// Flutter parity (`lib/services/music/lx_script_engine.dart`,
// 1.1.6+32), translated to Swift 5.0 / completion handlers:
// - One JSContext per script (top-level `const` redeclaration forces
//   separation); per-context serial queue; `LXError` on failure.
// - `LXPrelude` installs `globalThis.lx` (`request`/`on`/`send`,
//   utils, env), `btoa`/`atob`/`Buffer` shims, and routes
//   `setTimeout` through the host. The host-provided global is
//   `sendMessage(channel, payloadJSON)` — a Swift `@convention(block)`
//   closure installed on every context (no `JSExport` selector
//   mapping to get wrong). Channels: `LxRequest` (HTTP jobs),
//   `LxTimeout` (timers), `LxSend` (`inited` / `updateAlert` /
//   `showConfigView`), `LxLog` (console, last 100 lines).
// - Dart -> JS calls go through `__haoLxDispatch('request',
//   payloadJson)` (defined by the prelude) and poll
//   `__haoLxDispatchResult(id)` every 10 ms; HTTP results come back
//   via `__haoLxDeliver(id, errText, respJson)`.
// - `inited` is the only capability record: the script's source map
//   (platform -> actions + qualities). A script that never sends
//   `inited` fails after 10 s (polled every 100 ms, early exit in the
//   common synchronous case). Some scripts defer `inited` behind a
//   slow update check (up to ~5 s), so the wait is bounded, not zero.
// - Disposal is identity-guarded everywhere: a timer, HTTP delivery
//   or dispatch poll that fires after the runtime was replaced or
//   removed drops its work instead of evaluating on a released
//   JSContext (the v1.0.7-class use-after-free the Flutter engine
//   guards against the same way).
//
// Public API (names are the contract — the UI leg and the resolver
// call these):
//   - `LXEngine.shared`
//   - `runScript(sourceID:function:args:completion:)` — `function` is
//     `musicUrl` / `search` / `pic` / `lyric`; `args` follow the
//     Flutter LX call convention:
//       * `musicUrl`: `[musicInfo dict, quality String]`
//       * `search`: `[keyword String, page Int, limit Int,
//         platform String?]` — the platform is optional here; the
//         typed `search(scriptID:platform:…)` always passes it.
//       * `pic` / `lyric`: `[musicInfo dict]`
//   - `getMusicUrl(scriptID:platform:track:quality:completion:)` —
//     typed convenience, returns `(url, actualQuality)`.
//   - `search(scriptID:platform:keyword:page:limit:completion:)` —
//     returns raw result maps.
//   - `importScript(from:) -> Result<LxCustomScriptRecord,
//     LXScriptImportError>` — sync validate + copy into
//     `Documents/lx_scripts/` + register; async load follows.
//     Never overwrites a bundled script (custom files carry a
//     `custom-` prefix). The `completion:` overload reports the
//     async load result too, so the UI can say whether the script
//     actually joined the source list instead of going silent.
//   - `importScript(fromRemoteURL:session:completion:)` —
//     download a pasted `.js` URL, then the same validate +
//     store + load path. A URL-only record with no downloaded
//     file is never loaded (build 33 saved the address and
//     stopped there — that was the dead end).
//
// Completions are delivered on the main queue. All JS evaluation
// happens on the script's own serial queue.

import Foundation
import JavaScriptCore

// MARK: - Cancel token

/// Cooperative cancellation for one dispatch. The resolver sets it
/// when a job times out; the dispatch poll loop stops at the next
/// iteration and any in-flight HTTP task is cancelled.
final class LXCancelToken {
    private let lock = NSLock()
    private var _cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _cancelled
    }

    func cancel() {
        lock.lock()
        _cancelled = true
        lock.unlock()
    }
}

// MARK: - HTTP job (one `lx.request` from a script)

struct LXHTTPJob {
    let id: Int
    let url: String
    let method: String
    let headers: [String: String]
    let body: String?
    let timeoutMs: Int
}

// MARK: - One script runtime

final class LXRuntime {
    let scriptId: String
    let name: String
    let origin: String
    let isCustom: Bool
    let queue: DispatchQueue
    let context: JSContext

    weak var engine: LXEngine?

    var initedReceived = false
    var initedData: [String: Any]?
    var lastUpdateAlert: [String: Any]?
    var configView: [String: Any]?
    var logs: [String] = []
    var httpJobs: [LXHTTPJob] = []
    var pumping = false
    var currentTask: URLSessionDataTask?
    var timers: [String: DispatchWorkItem] = [:]
    var disposed = false
    var lastException: String?

    init(scriptId: String, name: String, origin: String, isCustom: Bool, engine: LXEngine) {
        self.scriptId = scriptId
        self.name = name
        self.origin = origin
        self.isCustom = isCustom
        self.engine = engine
        self.queue = DispatchQueue(label: "com.haostudio.lxengine.\(scriptId)")
        self.context = JSContext()
    }

    /// Install the host bridge on this context. Must run on `queue`.
    func installBridge() {
        context.exceptionHandler = { [weak self] _, exception in
            guard let self = self else { return }
            let text = exception?.toString() ?? "unknown JS error"
            self.lastException = text
            self.appendLog("[JS exception] \(text)")
        }
        // `sendMessage(channel, payloadJSON)` — the prelude's only
        // host call. A @convention(block) closure keeps the call
        // positional (no JSExport selector mapping involved).
        let bridge: @convention(block) (String, String) -> Void = { [weak self] channel, payload in
            guard let self = self, !self.disposed else { return }
            // Always re-dispatch onto the runtime queue: the block
            // may run on any thread the JS engine calls from.
            self.queue.async {
                self.handleMessage(channel: channel, payload: payload)
            }
        }
        context.setObject(bridge, forKeyedSubscript: "sendMessage" as NSString)
    }

    // MARK: - Message channels (run on `queue`)

    func handleMessage(channel: String, payload: String) {
        guard !disposed else { return }
        guard let dict = MusicJSON.dictionary(from: payload) else { return }
        switch channel {
        case "LxSend": ingestSend(dict)
        case "LxRequest": ingestRequest(dict)
        case "LxLog": ingestLog(dict)
        case "LxTimeout": ingestTimeout(dict)
        default: break
        }
    }

    private func ingestSend(_ dict: [String: Any]) {
        let event = dict["event"] as? String
        let data = dict["data"]
        switch event {
        case "inited":
            initedReceived = true
            initedData = data as? [String: Any]
        case "updateAlert":
            lastUpdateAlert = data as? [String: Any]
        case "showConfigView":
            configView = data as? [String: Any]
        default:
            break
        }
    }

    private func ingestRequest(_ dict: [String: Any]) {
        guard let id = dict["id"] as? Int,
              let url = dict["url"] as? String
        else { return }
        let job = LXHTTPJob(
            id: id,
            url: url,
            method: (dict["method"] as? String) ?? "GET",
            headers: (dict["headers"] as? [String: String]) ?? [:],
            body: dict["body"] as? String,
            timeoutMs: (dict["timeout"] as? Int) ?? 0
        )
        httpJobs.append(job)
    }

    private func ingestLog(_ dict: [String: Any]) {
        let text = (dict["text"] as? String) ?? ""
        guard !text.isEmpty else { return }
        appendLog(text)
    }

    private func ingestTimeout(_ dict: [String: Any]) {
        let idx = (dict["timeoutIndex"] as? String) ?? ""
        guard !idx.isEmpty else { return }
        if (dict["action"] as? String) == "clear" {
            timers.removeValue(forKey: idx)?.cancel()
            return
        }
        timers.removeValue(forKey: idx)?.cancel()
        let ms = max(0, (dict["timeout"] as? Int) ?? 0)
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.queue.async { self.fireTimeout(idx) }
        }
        timers[idx] = item
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .milliseconds(ms), execute: item)
    }

    /// Fire one prelude timer on THIS runtime — only when this
    /// runtime is still the registered owner of its script id.
    func fireTimeout(_ idx: String) {
        guard !disposed,
              let engine = engine,
              engine.runtime(for: scriptId) === self
        else { return }
        timers.removeValue(forKey: idx)
        evaluate("__haoLxFireTimeout(\(MusicJSON.jsStringLiteral(idx)))")
    }

    func appendLog(_ text: String) {
        logs.append(text)
        if logs.count > 100 { logs.removeFirst(logs.count - 100) }
    }

    // MARK: - JS evaluation (run on `queue`)

    /// Evaluate a snippet; returns the JSValue (nil on error).
    @discardableResult
    func evaluate(_ script: String) -> JSValue? {
        lastException = nil
        return context.evaluateScript(script)
    }

    func dispose() {
        disposed = true
        for item in timers.values { item.cancel() }
        timers.removeAll()
        currentTask?.cancel()
        currentTask = nil
    }
}

// MARK: - Engine

final class LXEngine {
    static let shared = LXEngine()

    /// Default wait for a script's deferred `inited` (Flutter parity:
    /// 10 s, polled every 100 ms).
    static let defaultInitedTimeout: TimeInterval = 10

    private let stateQueue = DispatchQueue(label: "com.haostudio.lxengine")
    private var runtimes: [String: LXRuntime] = [:]
    private var registry: [String: LxScriptInfo] = [:]
    private var initialized = false
    private var initializing = false
    private var pendingInitCompletions: [([LxScriptInfo]) -> Void] = []

    private let fileStore: LXScriptFileStore
    private let scriptStore: LXScriptStore
    private let initedTimeout: TimeInterval
    /// Reads a bundled script's code by id. Default: app bundle
    /// `Scripts/<id>.js` resource (registered by the coordinator in
    /// the Xcode project), falling back to a bare `<id>.js`.
    private let bundleLoader: (String) -> String?

    init(
        fileStore: LXScriptFileStore = LXScriptFileStore(),
        scriptStore: LXScriptStore = LXScriptStore(),
        initedTimeout: TimeInterval = LXEngine.defaultInitedTimeout,
        bundleLoader: ((String) -> String?)? = nil
    ) {
        self.fileStore = fileStore
        self.scriptStore = scriptStore
        self.initedTimeout = initedTimeout
        self.bundleLoader = bundleLoader ?? { id in
            if let url = Bundle.main.url(forResource: id, withExtension: "js", subdirectory: "Scripts"),
               let code = try? String(contentsOf: url, encoding: .utf8) {
                return code
            }
            if let url = Bundle.main.url(forResource: id, withExtension: "js"),
               let code = try? String(contentsOf: url, encoding: .utf8) {
                return code
            }
            return nil
        }
    }

    // MARK: - Registry access

    func runtime(for scriptId: String) -> LXRuntime? {
        stateQueue.sync { runtimes[scriptId] }
    }

    func script(_ id: String) -> LxScriptInfo? {
        stateQueue.sync { registry[id] }
    }

    var scripts: [LxScriptInfo] {
        stateQueue.sync { orderedRegistry() }
    }

    /// All capabilities of loaded + enabled scripts, in script order.
    var allSources: [LxScriptSourceInfo] {
        scripts.filter { $0.loaded && scriptStore.isEnabled($0.id) }
            .flatMap { $0.sources }
    }

    /// Registry in user order (saved order first, then seed order,
    /// then anything unknown last).
    private func orderedRegistry() -> [LxScriptInfo] {
        let order = scriptStore.scriptOrder()
        let all = Array(registry.values)
        return all.sorted { a, b in
            let ai = order.firstIndex(of: a.id) ?? Int.max
            let bi = order.firstIndex(of: b.id) ?? Int.max
            if ai != bi { return ai < bi }
            let seedA = LxBundledScript.allIDs.firstIndex(of: a.id) ?? Int.max
            let seedB = LxBundledScript.allIDs.firstIndex(of: b.id) ?? Int.max
            return seedA < seedB
        }
    }

    // MARK: - Initialisation

    /// Load every enabled, not-yet-loaded script (bundled + custom),
    /// in batches of 5 (Flutter parity — a slow script's 10 s
    /// `inited` wait must not block the whole load). Idempotent:
    /// concurrent calls coalesce; later calls get the snapshot at
    /// once. Completion on the main queue.
    func ensureInitialized(completion: @escaping ([LxScriptInfo]) -> Void) {
        stateQueue.async {
            if self.initialized {
                let snapshot = self.orderedRegistry()
                DispatchQueue.main.async { completion(snapshot) }
                return
            }
            self.pendingInitCompletions.append(completion)
            guard !self.initializing else { return }
            self.initializing = true
            // Build 36 item 6: drop orphan files for bundled ids
            // that no longer ship (e.g. `tang.js` left by an older
            // build). Never re-seeded; user-deleted bundled ids
            // are untouched here — their files were already deleted
            // by `removeScript`, and `seedOrRefresh` never runs
            // for them (loadNextBatch skips `deletedBundledIds`).
            self.removeOrphanBundledFiles()
            self.loadNextBatch()
        }
    }

    /// Delete on-disk copies of bundled ids that no longer ship
    /// (`LxBundledScript.removedBundledIDs`). Runs once per
    /// initialisation, on the state queue; the file IO is small.
    private func removeOrphanBundledFiles() {
        for id in LxBundledScript.removedBundledIDs {
            _ = fileStore.removeOrphanBundledFile(id: id)
        }
    }

    private func loadNextBatch() {
        // Runs on the state queue (called from `ensureInitialized`
        // and from the batch completion below), so the registry is
        // read directly — never `stateQueue.sync` here (deadlock).
        let deleted = Set(scriptStore.deletedBundledIds())
        var pending: [(id: String, name: String, origin: String, isCustom: Bool, fileName: String?)] = []
        for id in LxBundledScript.allIDs where !deleted.contains(id) {
            guard registry[id] == nil, scriptStore.isEnabled(id) else { continue }
            pending.append((id, id, "", false, nil))
        }
        for record in scriptStore.customScripts() {
            guard registry[record.id] == nil, scriptStore.isEnabled(record.id),
                  !record.fileName.isEmpty
            else { continue }
            // A record with no file name is a legacy URL-only
            // record (build 33 saved the address without
            // downloading): there is no code to load, so it is
            // skipped — the list offers a re-download instead of
            // letting it occupy a batch slot.
            pending.append((record.id, record.name, "custom:file", true, record.fileName))
        }
        let batch = Array(pending.prefix(5))
        guard !batch.isEmpty else {
            self.initialized = true
            self.initializing = false
            let snapshot = self.orderedRegistry()
            let completions = self.pendingInitCompletions
            self.pendingInitCompletions = []
            DispatchQueue.main.async {
                for completion in completions { completion(snapshot) }
            }
            return
        }
        let group = DispatchGroup()
        for item in batch {
            group.enter()
            loadScript(id: item.id, name: item.name, origin: item.origin,
                       isCustom: item.isCustom, fileName: item.fileName) { _ in
                group.leave()
            }
        }
        group.notify(queue: stateQueue) { [weak self] in
            self?.loadNextBatch()
        }
    }

    // MARK: - Script loading

    /// Load (or reload) one script by id. Reads the code from the
    /// `lx_scripts/` file (seeding from the bundle first for bundled
    /// ids; custom scripts read their registered `fileName`),
    /// evaluates prelude + body on a fresh context, waits for
    /// `inited`, registers the capability record. Completion on the
    /// main queue.
    func loadScript(
        id: String,
        name: String? = nil,
        origin: String = "",
        isCustom: Bool = false,
        fileName: String? = nil,
        completion: ((Result<LxScriptInfo, Error>) -> Void)? = nil
    ) {
        // Resolve the code synchronously (file IO is small).
        let code: String?
        if let fileName = fileName, !fileName.isEmpty {
            // Custom script: the registered file name is authoritative.
            // An empty file name is a legacy URL-only record with no
            // downloaded code — it falls through to the bundled
            // branch and fails as not found, never as a crash.
            code = fileStore.readFile(named: fileName)
        } else {
            let bundleCode = LxBundledScript.isBundled(id) ? bundleLoader(id) : nil
            if let fileURL = fileStore.seedOrRefresh(id: id, bundleCode: bundleCode) {
                code = try? String(contentsOf: fileURL, encoding: .utf8)
            } else {
                code = nil
            }
        }
        guard let code = code else {
            // Record the failure in the registry: `loadNextBatch`
            // only queues ids absent from the registry, so without
            // this entry the same batch would reload forever and
            // `ensureInitialized` would never complete. (A bundled
            // script missing from the bundle, or a custom script
            // whose file was deleted, hung init exactly this way;
            // the import test's nil `bundleLoader` made all 13
            // bundled loads take this path, so the test timed out.)
            // A later successful load overwrites this entry.
            let error = LXError.notFound(id)
            let failed = LxScriptInfo(
                id: id, name: name ?? id, origin: origin,
                loaded: false, error: error.localizedDescription)
            stateQueue.async { self.registry[id] = failed }
            finishLoad(id: id, result: .failure(error), completion: completion)
            return
        }
        let displayName = name ?? LXScriptHeader.parseName(from: code) ?? id
        let version = LXScriptHeader.parseVersion(from: code) ?? ""
        let runtime = LXRuntime(
            scriptId: id, name: displayName, origin: origin,
            isCustom: isCustom, engine: self)
        stateQueue.async {
            // Identity guard: a reload replaces the runtime first.
            self.runtimes[id] = runtime
        }
        runtime.queue.async {
            runtime.installBridge()
            runtime.evaluate(LXPrelude.source)
            runtime.evaluate("globalThis.__haoLxScriptId = \(MusicJSON.jsStringLiteral(id));")
            if isCustom {
                // User keys go only to custom scripts, never bundled.
                let keyNames = ["tx_cookie", "wy_cookie", "wanfeng_key", "yunmge_token", "apizero_key"]
                let keys = LXUserKeyStore.keysDictionary(scriptID: id, keyNames: keyNames)
                if let keysJson = MusicJSON.string(from: keys) {
                    runtime.evaluate("globalThis.__haoLxUserKeys = \(keysJson);")
                }
            }
            runtime.evaluate(code)
            if let exception = runtime.lastException {
                self.failLoad(runtime: runtime, error: LXError.invalidScript(exception), completion: completion)
                return
            }
            self.waitForInited(runtime: runtime, displayName: displayName, version: version,
                               stepsLeft: Int(self.initedTimeout * 10), completion: completion)
        }
    }

    private func waitForInited(
        runtime: LXRuntime,
        displayName: String,
        version: String,
        stepsLeft: Int,
        completion: ((Result<LxScriptInfo, Error>) -> Void)?
    ) {
        runtime.queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
            // Bail the moment this runtime stops being the registered
            // one (script removed / re-loaded mid-load).
            guard self.runtime(for: runtime.scriptId) === runtime else {
                self.finishLoad(id: runtime.scriptId,
                                result: .failure(LXError.scriptNotLoaded(runtime.scriptId)),
                                completion: completion)
                return
            }
            if runtime.initedReceived {
                self.completeLoad(runtime: runtime, displayName: displayName, version: version, completion: completion)
                return
            }
            // Scripts issue checkUpdate at load; pump their HTTP so a
            // deferred `inited` gated on a request can still arrive.
            self.pumpHTTP(runtime)
            guard stepsLeft > 1 else {
                self.failLoad(runtime: runtime, error: LXError.initedTimeout(runtime.scriptId), completion: completion)
                return
            }
            self.waitForInited(runtime: runtime, displayName: displayName, version: version,
                               stepsLeft: stepsLeft - 1, completion: completion)
        }
    }

    private func completeLoad(
        runtime: LXRuntime,
        displayName: String,
        version: String,
        completion: ((Result<LxScriptInfo, Error>) -> Void)?
    ) {
        if (runtime.initedData?["status"] as? Bool) == false {
            failLoad(runtime: runtime, error: LXError.invalidScript("status false"), completion: completion)
            return
        }
        let sources = LXEngine.parseSources(runtime: runtime, name: displayName)
        let info = LxScriptInfo(
            id: runtime.scriptId,
            name: displayName,
            version: version,
            origin: runtime.origin,
            loaded: true,
            sources: sources,
            configView: runtime.configView != nil,
            updateAlert: runtime.lastUpdateAlert.flatMap { MusicJSON.string(from: $0) }
        )
        stateQueue.async {
            self.registry[runtime.scriptId] = info
        }
        // Fire-and-forget: scripts issue checkUpdate at load; without
        // a pump those requests would sit until the next dispatch.
        runtime.queue.async { self.pumpHTTP(runtime) }
        finishLoad(id: runtime.scriptId, result: .success(info), completion: completion)
    }

    private func failLoad(
        runtime: LXRuntime,
        error: Error,
        completion: ((Result<LxScriptInfo, Error>) -> Void)?
    ) {
        stateQueue.async {
            // Identity-guarded: only remove when this load's runtime
            // is still the registered one.
            if self.runtimes[runtime.scriptId] === runtime {
                self.runtimes.removeValue(forKey: runtime.scriptId)
            }
        }
        runtime.queue.async { runtime.dispose() }
        let failed = LxScriptInfo(
            id: runtime.scriptId, name: runtime.name, origin: runtime.origin,
            loaded: false, error: (error as? LXError)?.localizedDescription ?? error.localizedDescription)
        stateQueue.async { self.registry[runtime.scriptId] = failed }
        finishLoad(id: runtime.scriptId, result: .failure(error), completion: completion)
    }

    private func finishLoad(
        id: String,
        result: Result<LxScriptInfo, Error>,
        completion: ((Result<LxScriptInfo, Error>) -> Void)?
    ) {
        guard let completion = completion else { return }
        DispatchQueue.main.async { completion(result) }
    }

    /// Parse the `inited` source map into capability records.
    /// `local` (a local-file pseudo-source) is skipped — its musicUrl
    /// needs server ids we never produce.
    static func parseSources(runtime: LXRuntime, name: String) -> [LxScriptSourceInfo] {
        guard let raw = runtime.initedData?["sources"] as? [String: Any] else { return [] }
        var out: [LxScriptSourceInfo] = []
        for (platform, value) in raw {
            guard platform != "local",
                  let entry = value as? [String: Any]
            else { continue }
            var actions: [String] = []
            if let rawActions = entry["actions"] as? [Any] {
                for action in rawActions {
                    if let s = action as? String,
                       ["musicUrl", "search", "pic", "lyric"].contains(s) {
                        actions.append(s)
                    }
                }
            }
            guard !actions.isEmpty else { continue }
            var qualities: [String] = []
            let rawQ = entry["qualitys"] ?? entry["qualities"]
            if let list = rawQ as? [Any] {
                for q in list { qualities.append("\(q)") }
            }
            out.append(LxScriptSourceInfo(
                scriptId: runtime.scriptId,
                scriptName: name,
                platform: platform,
                displayName: name,
                actions: actions,
                qualities: qualities))
        }
        return out
    }

    // MARK: - Dispatch

    /// Raw LX call (the mandated public API). `function` is
    /// `musicUrl` / `search` / `pic` / `lyric`; `args` follow the
    /// Flutter LX call convention (see the file header). The result
    /// is the script's raw return value (`String`, `[String: Any]`,
    /// `[[String: Any]]` …). Completion on the main queue.
    func runScript(
        sourceID: String,
        function: String,
        args: [Any],
        completion: @escaping (Result<Any, Error>) -> Void
    ) {
        runScript(sourceID: sourceID, function: function, args: args,
                  timeout: 8, cancelToken: nil, completion: completion)
    }

    /// Dispatch with an explicit timeout and cancellation token
    /// (the resolver passes its per-job token).
    func runScript(
        sourceID: String,
        function: String,
        args: [Any],
        timeout: TimeInterval,
        cancelToken: LXCancelToken?,
        completion: @escaping (Result<Any, Error>) -> Void
    ) {
        guard let runtime = runtime(for: sourceID) else {
            DispatchQueue.main.async { completion(.failure(LXError.scriptNotLoaded(sourceID))) }
            return
        }
        // Build the dispatch payload: `{'action': fn, 'source': …,
        // 'info': …}`. The source platform is the first arg's
        // `source` field when present; the resolver passes it
        // explicitly through the typed helpers below instead.
        let payload: [String: Any]
        switch function {
        case "musicUrl":
            // args: [musicInfo dict, quality String]
            let musicInfo = (args.first as? [String: Any]) ?? [:]
            let quality = (args.count > 1 ? args[1] as? String : nil) ?? "hires"
            payload = ["action": function,
                       "source": (musicInfo["source"] as? String) ?? "",
                       "info": ["musicInfo": musicInfo, "type": quality]]
        case "search":
            // args: [keyword String, page Int, limit Int, platform String?]
            let keyword = (args.first as? String) ?? ""
            let page = (args.count > 1 ? args[1] as? Int : nil) ?? 1
            let limit = (args.count > 2 ? args[2] as? Int : nil) ?? 20
            let platform = (args.count > 3 ? args[3] as? String : nil) ?? ""
            payload = ["action": function,
                       "source": platform,
                       "info": ["keyword": keyword, "text": keyword, "page": page, "limit": limit]]
        case "pic", "lyric":
            // args: [musicInfo dict]
            let musicInfo = (args.first as? [String: Any]) ?? [:]
            payload = ["action": function,
                       "source": (musicInfo["source"] as? String) ?? "",
                       "info": ["musicInfo": musicInfo]]
        default:
            DispatchQueue.main.async { completion(.failure(LXError.dispatchFailed("unknown function \(function)"))) }
            return
        }
        dispatch(runtime: runtime, payload: payload, timeout: timeout,
                 cancelToken: cancelToken, completion: completion)
    }

    /// Typed play-URL call. Returns `(url, actualQuality)`: the URL
    /// plus the tier the script actually served (nil = no tier
    /// signal — a bare URL string). Nil when the script cannot serve
    /// this platform/quality or the lookup fails.
    func getMusicUrl(
        scriptID: String,
        platform: String,
        track: MusicTrack,
        quality: AudioQuality,
        cancelToken: LXCancelToken? = nil,
        completion: @escaping ((url: String, actualQuality: AudioQuality?)?) -> Void
    ) {
        guard let info = script(scriptID), info.loaded,
              let source = info.sources.first(where: { $0.platform == platform }),
              source.supportsMusicUrl,
              let qualityString = MusicQualityGate.lxQualityForScript(quality, available: source.qualities)
        else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let musicInfo: [String: Any] = [
            "songmid": track.id,
            "id": track.id,
            "name": track.title,
            "singer": track.artist,
            "albumName": track.album,
            // LX musicInfo carries the platform; some scripts read
            // musicInfo.source instead of the dispatch top-level source.
            "source": platform,
        ]
        let payload: [String: Any] = [
            "action": "musicUrl",
            "source": platform,
            "info": ["musicInfo": musicInfo, "type": qualityString],
        ]
        guard let runtime = runtime(for: scriptID) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        dispatch(runtime: runtime, payload: payload, timeout: 8, cancelToken: cancelToken) { result in
            switch result {
            case .failure:
                completion(nil)
            case .success(let value):
                if let urlString = value as? String, !urlString.isEmpty {
                    completion((url: MusicText.toHttps(urlString), actualQuality: nil))
                } else if let map = value as? [String: Any],
                          let rawUrl = map["url"] as? String, !rawUrl.isEmpty {
                    let reported = (map["quality"] as? String) ?? (map["type"] as? String)
                    let actual = MusicQualityGate.reportedTierFor(reported: reported, requested: quality)
                    completion((url: MusicText.toHttps(rawUrl), actualQuality: actual))
                } else {
                    completion(nil)
                }
            }
        }
    }

    /// Search via one script (only scripts declaring `search` for the
    /// platform). Returns raw result maps; [] on any failure.
    /// 5 s timeout (Flutter parity).
    func search(
        scriptID: String,
        platform: String,
        keyword: String,
        page: Int = 1,
        limit: Int = 20,
        completion: @escaping ([[String: Any]]) -> Void
    ) {
        guard let info = script(scriptID), info.loaded,
              let source = info.sources.first(where: { $0.platform == platform }),
              source.supportsSearch,
              let runtime = runtime(for: scriptID)
        else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        let payload: [String: Any] = [
            "action": "search",
            "source": platform,
            "info": ["keyword": keyword, "text": keyword, "page": page, "limit": limit],
        ]
        dispatch(runtime: runtime, payload: payload, timeout: 5, cancelToken: nil) { result in
            switch result {
            case .failure:
                completion([])
            case .success(let value):
                completion(LXEngine.unwrapSearchResult(value))
            }
        }
    }

    /// Unwrap a script search result into raw song maps. Pure
    /// function: bare list, or the LX-standard `{isEnd, list}`
    /// object; anything else is [].
    static func unwrapSearchResult(_ value: Any) -> [[String: Any]] {
        if let list = value as? [Any] {
            return list.compactMap { $0 as? [String: Any] }
        }
        if let map = value as? [String: Any],
           let list = map["list"] as? [Any] {
            return list.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    /// The dispatch core: evaluate `__haoLxDispatch`, then poll
    /// `__haoLxDispatchResult` every 10 ms until done, cancelled or
    /// past the deadline. All JS work happens on the runtime queue;
    /// completion on the main queue.
    private func dispatch(
        runtime: LXRuntime,
        payload: [String: Any],
        timeout: TimeInterval,
        cancelToken: LXCancelToken?,
        completion: @escaping (Result<Any, Error>) -> Void
    ) {
        runtime.queue.async {
            guard !runtime.disposed,
                  self.runtime(for: runtime.scriptId) === runtime
            else {
                self.completeOnMain(.failure(LXError.scriptNotLoaded(runtime.scriptId)), completion: completion)
                return
            }
            guard let payloadJson = MusicJSON.string(from: payload) else {
                self.completeOnMain(.failure(LXError.dispatchFailed("bad payload")), completion: completion)
                return
            }
            let script = "__haoLxDispatch(\(MusicJSON.jsStringLiteral("request")), \(MusicJSON.jsStringLiteral(payloadJson)))"
            let idValue = runtime.evaluate(script)
            guard let idString = idValue?.toString(),
                  let id = Int(idString)
            else {
                self.completeOnMain(.failure(LXError.dispatchFailed(idValue?.toString() ?? "nil")), completion: completion)
                return
            }
            let deadline = Date().addingTimeInterval(timeout)
            self.pollDispatch(runtime: runtime, id: id, deadline: deadline,
                              cancelToken: cancelToken, completion: completion)
        }
    }

    private func pollDispatch(
        runtime: LXRuntime,
        id: Int,
        deadline: Date,
        cancelToken: LXCancelToken?,
        completion: @escaping (Result<Any, Error>) -> Void
    ) {
        runtime.queue.asyncAfter(deadline: .now() + .milliseconds(10)) {
            // Identity guard: never evaluate on a released JSContext.
            guard !runtime.disposed,
                  self.runtime(for: runtime.scriptId) === runtime
            else {
                self.completeOnMain(.failure(LXError.scriptNotLoaded(runtime.scriptId)), completion: completion)
                return
            }
            // The caller gave up (job timeout) — stop polling at
            // once; a late result is never read.
            if cancelToken?.isCancelled == true {
                runtime.currentTask?.cancel()
                self.completeOnMain(.failure(LXError.cancelled), completion: completion)
                return
            }
            self.pumpHTTP(runtime)
            let resultValue = runtime.evaluate("__haoLxDispatchResult(\(id))")
            if let raw = resultValue?.toString(),
               let res = MusicJSON.dictionary(from: raw),
               (res["done"] as? Bool) == true {
                if (res["ok"] as? Bool) == true {
                    let value: Any = res["value"] ?? NSNull()
                    self.completeOnMain(.success(value), completion: completion)
                } else {
                    let message = (res["error"] as? String) ?? "脚本执行失败"
                    self.completeOnMain(.failure(LXError.dispatchFailed(message)), completion: completion)
                }
                return
            }
            if Date() > deadline {
                self.completeOnMain(.failure(LXError.timedOut("request")), completion: completion)
                return
            }
            self.pollDispatch(runtime: runtime, id: id, deadline: deadline,
                              cancelToken: cancelToken, completion: completion)
        }
    }

    private func completeOnMain(
        _ result: Result<Any, Error>,
        completion: @escaping (Result<Any, Error>) -> Void
    ) {
        DispatchQueue.main.async { completion(result) }
    }

    // MARK: - HTTP pump

    /// Perform every pending `lx.request` HTTP job for this runtime
    /// via URLSession and deliver each result back into JS.
    /// Sequential: scripts issue requests one at a time.
    func pumpHTTP(_ runtime: LXRuntime) {
        runtime.queue.async {
            guard !runtime.disposed, !runtime.pumping,
                  !runtime.httpJobs.isEmpty
            else { return }
            runtime.pumping = true
            let job = runtime.httpJobs.removeFirst()
            self.performHTTPJob(job, runtime: runtime)
        }
    }

    private func performHTTPJob(_ job: LXHTTPJob, runtime: LXRuntime) {
        guard let url = URL(string: job.url) else {
            deliverHTTP(runtime: runtime, job: job, error: "invalid URL", response: nil)
            return
        }
        var request = URLRequest(
            url: url,
            timeoutInterval: job.timeoutMs > 0
                ? TimeInterval(job.timeoutMs) / 1000.0 : 8)
        request.httpMethod = job.method
        for (key, value) in job.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body = job.body {
            request.httpBody = body.data(using: .utf8)
        }
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            var errText: String?
            var respJson: String?
            if let error = error {
                errText = error.localizedDescription
            } else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                var headers: [String: String] = [:]
                if let httpResponse = response as? HTTPURLResponse {
                    for (key, value) in httpResponse.allHeaderFields {
                        headers["\(key)"] = "\(value)"
                    }
                }
                var body: Any = ""
                if let data = data, !data.isEmpty {
                    if let text = String(data: data, encoding: .utf8),
                       let parsed = MusicJSON.object(from: text) {
                        body = parsed
                    } else if let text = String(data: data, encoding: .utf8) {
                        body = text
                    }
                }
                respJson = MusicJSON.string(from: [
                    "statusCode": statusCode,
                    "headers": headers,
                    "body": body,
                ])
                if respJson == nil { errText = "response encode failed" }
            }
            runtime.queue.async {
                // Identity guard, re-checked after the await: the
                // script may have been removed mid-flight.
                guard !runtime.disposed,
                      self.runtime(for: runtime.scriptId) === runtime
                else {
                    runtime.pumping = false
                    return
                }
                self.deliverHTTP(runtime: runtime, job: job, error: errText, response: respJson)
            }
        }
        runtime.currentTask = task
        task.resume()
    }

    private func deliverHTTP(runtime: LXRuntime, job: LXHTTPJob, error: String?, response: String?) {
        // Called on the runtime queue.
        runtime.evaluate(
            "__haoLxDeliver(\(job.id), \(MusicJSON.jsStringLiteral(error)), \(MusicJSON.jsStringLiteral(response)))")
        runtime.currentTask = nil
        runtime.pumping = false
        pumpHTTP(runtime)
    }

    // MARK: - Source lookup for the resolver / search legs

    /// Scripts that can serve `musicUrl` for this platform at this
    /// tier, in registry order, with the quality string to ask for.
    func musicUrlSources(platform: String, quality: AudioQuality) -> [(scriptID: String, scriptName: String, scriptQuality: String)] {
        scripts.filter { $0.loaded && scriptStore.isEnabled($0.id) }
            .compactMap { info in
                guard let source = info.sources.first(where: { $0.platform == platform }),
                      source.supportsMusicUrl,
                      let qStr = MusicQualityGate.lxQualityForScript(quality, available: source.qualities)
                else { return nil }
                return (scriptID: info.id, scriptName: info.name, scriptQuality: qStr)
            }
    }

    /// Scripts that can serve `search` for this platform, in registry order.
    func searchSources(platform: String) -> [(scriptID: String, scriptName: String)] {
        scripts.filter { $0.loaded && scriptStore.isEnabled($0.id) }
            .compactMap { info in
                guard let source = info.sources.first(where: { $0.platform == platform }),
                      source.supportsSearch
                else { return nil }
                return (scriptID: info.id, scriptName: info.name)
            }
    }

    /// Last 100 console lines from one script.
    func logs(for scriptID: String) -> [String] {
        guard let runtime = runtime(for: scriptID) else { return [] }
        return runtime.queue.sync { runtime.logs }
    }

    // MARK: - Import / removal

    /// Read a user `.js` file for import. File-picker URLs are
    /// security-scoped: access is claimed for the read only.
    private func readScriptFile(at url: URL) -> Result<String, LXScriptImportError> {
        guard url.pathExtension.lowercased() == "js" else {
            return .failure(.notJavaScriptFile)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let code = try? String(contentsOf: url, encoding: .utf8) else {
            return .failure(.unreadableFile)
        }
        return .success(code)
    }

    /// Import a user `.js` file: validate it synchronously (see
    /// `LXScriptImportValidator`), copy it into
    /// `Documents/lx_scripts/` under a `custom-` name (never
    /// overwriting a bundled script), register it, and kick off
    /// the load. The returned record means "validated and saved";
    /// the load result arrives via `loadCompletion` (or the
    /// `completion:` overload below). A load that fails `inited`
    /// leaves the script in the registry as failed, like any
    /// other bad script.
    @discardableResult
    func importScript(from url: URL) -> Result<LxCustomScriptRecord, LXScriptImportError> {
        switch readScriptFile(at: url) {
        case .failure(let error):
            return .failure(error)
        case .success(let code):
            return importScript(code: code, sourceURLString: url.absoluteString)
        }
    }

    /// Import already-read script code (file import and URL
    /// download share this path, so both validate identically).
    /// `loadCompletion` receives the load result when given.
    @discardableResult
    func importScript(
        code: String,
        sourceURLString: String,
        loadCompletion: ((Result<LxScriptInfo, Error>) -> Void)? = nil
    ) -> Result<LxCustomScriptRecord, LXScriptImportError> {
        switch LXScriptImportValidator.validate(code: code) {
        case .failure(let error):
            return .failure(error)
        case .success:
            break
        }
        let id = LXScriptFileStore.customScriptID(for: code)
        let fileName = LXScriptFileStore.customFileName(for: code)
        guard fileStore.write(code: code, fileName: fileName) else {
            return .failure(.writeFailed)
        }
        let name = LXScriptFileStore.displayName(for: code, fileName: fileName)
        let record = LxCustomScriptRecord(
            id: id, name: name, url: sourceURLString,
            fileName: fileName, addedAt: Date())
        scriptStore.saveCustomScript(record)
        loadScript(id: id, name: name, origin: "custom:file",
                   isCustom: true, fileName: fileName, completion: loadCompletion)
        return .success(record)
    }

    /// File import with the load result: `completion` fires once —
    /// with the validation error right away, or with the load
    /// result (success = the script joined the source list and
    /// can take part in search and playback). Completion on the
    /// main queue.
    func importScript(
        from url: URL,
        completion: @escaping (Result<LxScriptInfo, LXScriptImportError>) -> Void
    ) {
        switch readScriptFile(at: url) {
        case .failure(let error):
            DispatchQueue.main.async { completion(.failure(error)) }
        case .success(let code):
            let result = importScript(
                code: code, sourceURLString: url.absoluteString,
                loadCompletion: { loadResult in
                    completion(Self.mapLoadResult(loadResult))
                })
            if case .failure(let error) = result {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// URL import: download a pasted `.js` address, then run the
    /// same validate + store + load path as file import.
    /// `completion` fires once, on the main queue, with the load
    /// result (or the download / validation error). `session` is
    /// injectable so tests can stub the download.
    func importScript(
        fromRemoteURL url: URL,
        session: URLSession = .shared,
        completion: @escaping (Result<LxScriptInfo, LXScriptImportError>) -> Void
    ) {
        switch LXScriptImportValidator.validateRemoteURL(url) {
        case .failure(let error):
            DispatchQueue.main.async { completion(.failure(error)) }
            return
        case .success:
            break
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                let detail = LXScriptImportValidator.shortDetail(error.localizedDescription)
                DispatchQueue.main.async { completion(.failure(.downloadFailed(detail))) }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(.downloadFailed("无服务器响应"))) }
                return
            }
            guard http.statusCode == 200 else {
                DispatchQueue.main.async {
                    completion(.failure(.downloadFailed("服务器返回状态码 \(http.statusCode)")))
                }
                return
            }
            guard let data = data, !data.isEmpty else {
                DispatchQueue.main.async { completion(.failure(.emptyFile)) }
                return
            }
            guard let code = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async { completion(.failure(.downloadFailed("下载内容无法按 UTF-8 解码"))) }
                return
            }
            let result = self.importScript(
                code: code, sourceURLString: url.absoluteString,
                loadCompletion: { loadResult in
                    completion(Self.mapLoadResult(loadResult))
                })
            if case .failure(let error) = result {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
        task.resume()
    }

    /// Map an engine load result onto the import error type: a
    /// failed load keeps the saved record and reports the reason,
    /// so the UI can show it instead of going silent.
    private static func mapLoadResult(
        _ result: Result<LxScriptInfo, Error>
    ) -> Result<LxScriptInfo, LXScriptImportError> {
        switch result {
        case .success(let info):
            return .success(info)
        case .failure(let error):
            let detail = (error as? LXError)?.localizedDescription ?? error.localizedDescription
            return .failure(.loadFailed(detail))
        }
    }

    /// Remove a script: dispose its runtime, drop the registry entry,
    /// delete its file copy. Bundled ids are marked deleted so they
    /// are never re-seeded; custom scripts lose their record and file.
    func removeScript(_ id: String) {
        stateQueue.async {
            if let runtime = self.runtimes.removeValue(forKey: id) {
                runtime.queue.async { runtime.dispose() }
            }
            self.registry.removeValue(forKey: id)
        }
        if LxBundledScript.isBundled(id) {
            scriptStore.markBundledDeleted(id)
            _ = fileStore.delete(id: id)
        } else {
            if let record = scriptStore.customScripts().first(where: { $0.id == id }) {
                _ = fileStore.deleteFile(named: record.fileName)
            }
            scriptStore.removeCustomScript(id)
        }
    }
}

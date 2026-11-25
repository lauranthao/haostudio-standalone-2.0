// HAo Studio 2.0 — Emby config view model (S5, leg A: engine only).
//
// The Settings Emby page binds to this. It owns NO storage of its
// own: the config lives in EmbyConfigStore
// (`Services/Video/EmbyModels.swift`) and the credential lives in
// the Keychain (via EmbyConfigStore.save). `password` and `apiKey`
// are memory-only fields — they are never written to disk by this
// class, never logged, and never appear in a debug description.
//
// Login flow: username + password is primary (POST
// /Users/AuthenticateByName, exchanged once for a token); the API
// key is the fallback. `testConnection` tries password login when
// both username and password are filled, otherwise probes with
// the API key. A successful test remembers the resolved config
// (token / user id / server name / version) so `save()` persists
// the working values, not just the typed ones.

import Foundation

/// Emby connection state for the Settings page.
enum EmbyConfigStatus: Equatable {
    case unconfigured
    case configured(serverName: String, version: String)
    case testing
    case failed(message: String)
}

@MainActor
final class EmbyConfigViewModel: ObservableObject {
    @Published var baseUrl: String = ""
    @Published var username: String = ""
    /// Memory only: sent once in AuthenticateByName, never stored.
    @Published var password: String = ""
    /// Memory only: the fallback credential. Persisted through
    /// EmbyConfigStore.save (Keychain), never written to a file.
    @Published var apiKey: String = ""
    /// (b49fix4 P1-7) Whether playback progress is reported to
    /// the user's own Emby server. Default on; the only UI that
    /// reads or writes `EmbyServerConfig.reportProgress` — before
    /// this switch the reporter ran with no way to turn it off,
    /// while the disclaimer claimed reporting happened only
    /// "after enabling it".
    @Published var reportProgress: Bool = true
    @Published private(set) var status: EmbyConfigStatus = .unconfigured

    /// Test seam: build the client for a config. Production uses
    /// the real client; tests inject a client with a canned
    /// fetcher/mutator so no network is needed.
    var makeClient: (EmbyServerConfig) -> EmbyClient = { config in
        EmbyClient(config: config)
    }

    /// The config a successful test resolved (token / user id /
    /// server name / version). Memory only; `save()` merges it
    /// with the typed fields.
    private var resolvedConfig: EmbyServerConfig?

    init() {
        reload()
    }

    /// Re-read the stored config (server / user / status) from
    /// EmbyConfigStore. Called on init and when the Settings page
    /// comes back from the Emby page: the Emby page owns its own
    /// view-model instance, so without this the "Emby 连接" row
    /// subtitle would stay stale after a save (chen 2026-11-24:
    /// same silent-read class as the section-expand bug).
    func reload() {
        if let stored = EmbyConfigStore.load() {
            baseUrl = stored.baseUrl
            username = stored.username
            apiKey = stored.apiKey
            reportProgress = stored.reportProgress
            resolvedConfig = stored
            if stored.isConfigured {
                status = .configured(serverName: stored.serverName, version: stored.serverVersion)
            } else {
                status = .unconfigured
            }
        } else {
            baseUrl = ""
            username = ""
            apiKey = ""
            reportProgress = true
            resolvedConfig = nil
            status = .unconfigured
        }
    }

    /// Test the connection. An empty address fails immediately
    /// without touching the network. With a username + password,
    /// logs in first (the token it returns is then used for the
    /// probe); otherwise probes with the API key. The completion
    /// reports success; `status` carries the human-readable state.
    func testConnection(completion: @escaping (Bool) -> Void) {
        let address = baseUrl.trimmingCharacters(in: .whitespaces)
        if address.isEmpty {
            status = .failed(message: "请先填写服务器地址")
            completion(false)
            return
        }
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        if !trimmedUsername.isEmpty && !password.isEmpty {
            loginThenProbe(address: address, username: trimmedUsername, completion: completion)
            return
        }
        if apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            status = .failed(message: "请填写 API 密钥或用户名密码")
            completion(false)
            return
        }
        status = .testing
        let config = EmbyServerConfig(baseUrl: address, apiKey: apiKey.trimmingCharacters(in: .whitespaces), username: trimmedUsername)
        probe(config: config, completion: completion)
    }

    private func loginThenProbe(address: String, username: String, completion: @escaping (Bool) -> Void) {
        status = .testing
        let loginConfig = EmbyServerConfig(baseUrl: address, username: username)
        let client = makeClient(loginConfig)
        client.authenticateByName(username: username, password: password) { [weak self] result in
            guard let self = self else {
                completion(false)
                return
            }
            DispatchQueue.main.async {
                guard result.ok else {
                    self.status = .failed(message: result.errorMessage.isEmpty ? "Emby 用户名或密码不对，请重新登录" : result.errorMessage)
                    completion(false)
                    return
                }
                var config = loginConfig
                config.accessToken = result.accessToken
                config.userId = result.userId
                config.username = result.userName.isEmpty ? username : result.userName
                if config.deviceId.isEmpty {
                    config.deviceId = EmbyServerConfig.newDeviceId()
                }
                self.resolvedConfig = config
                self.probe(config: config, completion: completion)
            }
        }
    }

    private func probe(config: EmbyServerConfig, completion: @escaping (Bool) -> Void) {
        let client = makeClient(config)
        client.probe { [weak self] result in
            guard let self = self else {
                completion(false)
                return
            }
            DispatchQueue.main.async {
                guard result.ok else {
                    self.status = .failed(message: result.errorMessage.isEmpty ? "连不上 Emby 服务器，检查地址和网络" : result.errorMessage)
                    completion(false)
                    return
                }
                var resolved = config
                resolved.serverName = result.serverName
                resolved.serverVersion = result.version
                resolved.useEmbyPrefix = result.useEmbyPrefix
                if !result.workingBaseUrl.isEmpty {
                    resolved.baseUrl = result.workingBaseUrl
                }
                self.resolvedConfig = resolved
                self.status = .configured(serverName: result.serverName, version: result.version)
                completion(true)
            }
        }
    }

    /// Persist the current fields (plus the values a successful
    /// test resolved: token / user id / device id / server name /
    /// version). The API key / token goes to the Keychain through
    /// EmbyConfigStore.save; the JSON file on disk stays
    /// credential-free. Returns false when the write failed (the
    /// in-memory values are kept; the UI never throws for a
    /// storage failure). Also false — without writing anything —
    /// when there is nothing worth saving: an empty address, or
    /// an address with no credential at all (b35 sweep: it used
    /// to "succeed" and dismiss, leaving the user believing the
    /// server was configured). Clears the in-memory password on
    /// success: the token replaces it, and the password must not
    /// linger.
    @discardableResult
    func save() -> Bool {
        let address = baseUrl.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return false }
        var config = resolvedConfig ?? EmbyConfigStore.load() ?? EmbyServerConfig()
        // b36 item 8, F4: the merged config may carry a token for
        // a DIFFERENT server — test server A, then retype the
        // address as B without re-testing, and A's token would be
        // saved against B's address (then every Emby call fails
        // auth while the page claims to be configured). When the
        // typed address is not the server the merged config came
        // from, drop the server-bound fields first. A freshly
        // typed API key (applied below) still saves; otherwise
        // the guard below fails honestly instead of storing a
        // dead login. Comparison ignores surrounding whitespace
        // and a trailing "/" (probe returns the typed address
        // verbatim, so a match after a successful test is exact).
        if Self.normalizedBaseUrl(config.baseUrl) != Self.normalizedBaseUrl(address) {
            config.accessToken = ""
            config.userId = ""
            config.serverName = ""
            config.serverVersion = ""
        }
        config.baseUrl = address
        config.username = username.trimmingCharacters(in: .whitespaces)
        let typedKey = apiKey.trimmingCharacters(in: .whitespaces)
        if !typedKey.isEmpty {
            // A freshly typed API key replaces any stored token:
            // the user is switching to key auth.
            config.apiKey = typedKey
            config.accessToken = ""
            // Key auth has no user id: without this, a leftover
            // user id would make the next load mistake the key
            // for a password-login token (see EmbyConfigStore).
            config.userId = ""
        }
        guard !config.authToken.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if config.deviceId.isEmpty {
            config.deviceId = EmbyServerConfig.newDeviceId()
        }
        config.enabled = true
        config.reportProgress = reportProgress
        let ok = EmbyConfigStore.save(config)
        if ok {
            resolvedConfig = config
            password = ""
            // A new server means new posters and a new reporter
            // session: drop the old server's cached images and
            // tell the video driver to end its open session (the
            // client it holds was built from the old config).
            EmbyImageLoader.shared.clearCache()
            NotificationCenter.default.post(name: .haoEmbyConfigChanged, object: nil)
            if config.isConfigured {
                status = .configured(serverName: config.serverName, version: config.serverVersion)
            } else {
                status = .unconfigured
            }
        }
        return ok
    }

    /// Forget the server entirely: config file + Keychain token.
    func clear() {
        EmbyConfigStore.clear()
        EmbyImageLoader.shared.clearCache()
        NotificationCenter.default.post(name: .haoEmbyConfigChanged, object: nil)
        resolvedConfig = nil
        baseUrl = ""
        username = ""
        password = ""
        apiKey = ""
        reportProgress = true
        status = .unconfigured
    }

    /// Base URL for same-server comparison (b36 item 8, F4):
    /// surrounding whitespace and trailing slashes ignored, so
    /// "https://host:8096/" matches "https://host:8096".
    private static func normalizedBaseUrl(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }
}

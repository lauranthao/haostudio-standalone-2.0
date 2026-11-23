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
        if let stored = EmbyConfigStore.load() {
            baseUrl = stored.baseUrl
            username = stored.username
            apiKey = stored.apiKey
            resolvedConfig = stored
            if stored.isConfigured {
                status = .configured(serverName: stored.serverName, version: stored.serverVersion)
            } else {
                status = .unconfigured
            }
        } else {
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
        let config = EmbyServerConfig(baseUrl: address, apiKey: apiKey, username: trimmedUsername)
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
    /// storage failure). Clears the in-memory password on success:
    /// the token replaces it, and the password must not linger.
    @discardableResult
    func save() -> Bool {
        let address = baseUrl.trimmingCharacters(in: .whitespaces)
        var config = resolvedConfig ?? EmbyConfigStore.load() ?? EmbyServerConfig()
        config.baseUrl = address
        config.username = username.trimmingCharacters(in: .whitespaces)
        let typedKey = apiKey.trimmingCharacters(in: .whitespaces)
        if !typedKey.isEmpty {
            // A freshly typed API key replaces any stored token:
            // the user is switching to key auth.
            config.apiKey = typedKey
            config.accessToken = ""
        }
        if config.deviceId.isEmpty {
            config.deviceId = EmbyServerConfig.newDeviceId()
        }
        config.enabled = true
        let ok = EmbyConfigStore.save(config)
        if ok {
            resolvedConfig = config
            password = ""
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
        resolvedConfig = nil
        baseUrl = ""
        username = ""
        password = ""
        apiKey = ""
        status = .unconfigured
    }
}

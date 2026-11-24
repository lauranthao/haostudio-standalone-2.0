// HAo Studio 2.0 — live services test helpers (S4 leg B).
//
// Shared fakes for the LiveServicesTests target: a scriptable
// danmaku socket, canned HTTP fetchers, and JSON shortcuts.
// No network: every helper is in-memory.
//
// Swift 5.0: no async/await, no `any`.

import Foundation
import XCTest
@testable import AppCore

/// Scriptable `LiveDanmakuSocket`: records what the transport sends
/// and lets the test drive inbound frames / disconnects. `connect`
/// fires `onConnected` synchronously so a transport's join step runs
/// inside `start(...)` and tests stay deterministic.
final class FakeDanmakuSocket: LiveDanmakuSocket {
    var onMessage: ((Data) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?

    var sent: [Data] = []
    var connectedUrls: [URL] = []
    var connectedHeaders: [[String: String]] = []
    var closeCount = 0

    func connect(url: URL, headers: [String: String]) {
        connectedUrls.append(url)
        connectedHeaders.append(headers)
        onConnected?()
    }

    func send(_ data: Data) {
        sent.append(data)
    }

    func close() {
        closeCount += 1
    }

    func simulateMessage(_ data: Data) {
        onMessage?(data)
    }

    func simulateDisconnected() {
        onDisconnected?()
    }
}

/// A fetcher that always answers the same canned response.
func stubFetcher(data: Data?, status: Int? = 200, error: Error? = nil) -> LiveDataFetcher {
    return { _, completion in
        completion(data, status, error)
    }
}

/// A fetcher that answers from a URL-keyed table (substring match on
/// the absolute URL, first match wins); unmatched URLs get a 404.
func routingFetcher(_ routes: [(String, Data?, Int?)]) -> LiveDataFetcher {
    return { request, completion in
        let url = request.url?.absoluteString ?? ""
        for (needle, data, status) in routes {
            if url.contains(needle) {
                completion(data, status ?? 200, nil)
                return
            }
        }
        completion(nil, 404, nil)
    }
}

/// A routing fetcher that answers asynchronously (like URLSession)
/// and records every requested URL. The repo's `routingFetcher`
/// answers synchronously, which serializes two back-to-back calls
/// (the first finishes before the second starts) — the in-flight
/// room-detail dedup (build 36 item 10 leg 4) only engages when
/// the second call lands while the first is still in flight, so
/// dedup tests need this async variant. `fallback` answers
/// unmatched URLs (Huya's WUP calls need the room page to fall
/// back to the web-template anti-code, like the repo's resolve
/// tests do with a blanket stub fetcher).
final class CountingRoutingFetcher {
    private let routes: [(String, Data?, Int?)]
    private let fallback: (Data?, Int?)
    private let lock = NSLock()
    private(set) var requestedURLs: [String] = []

    init(_ routes: [(String, Data?, Int?)], fallback: (Data?, Int?) = (nil, 404)) {
        self.routes = routes
        self.fallback = fallback
    }

    /// Requests whose URL contains `needle` (counted for every
    /// request, whether or not any route matched it).
    func count(containing needle: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestedURLs.filter { $0.contains(needle) }.count
    }

    var fetcher: LiveDataFetcher {
        return { [weak self] request, completion in
            guard let self = self else { return }
            let url = request.url?.absoluteString ?? ""
            self.lock.lock()
            self.requestedURLs.append(url)
            self.lock.unlock()
            var answer = self.fallback
            for (needle, data, status) in self.routes where url.contains(needle) {
                answer = (data, status ?? 200)
                break
            }
            let captured = answer
            DispatchQueue.global().async {
                completion(captured.0, captured.1, nil)
            }
        }
    }
}

func jsonData(_ string: String) -> Data {
    Data(string.utf8)
}

func jsonObject(_ string: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: jsonData(string), options: [])) as? [String: Any] ?? [:]
}

func jsonArray(_ string: String) -> [Any] {
    (try? JSONSerialization.jsonObject(with: jsonData(string), options: [])) as? [Any] ?? []
}

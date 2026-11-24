// HAo Studio 2.0 — live danmaku sockets + transport base (S4 leg B).
//
// The five danmaku transports share one WebSocket shape and one
// lifecycle (generation-guarded start/stop, heartbeat timer,
// reconnect-on-disconnect), so that shape lives here once instead of
// four times.
//
// `LiveDanmakuSocket` is the raw binary/text pipe: connect, send,
// close. `URLSessionLiveDanmakuSocket` is the production
// implementation on `URLSessionWebSocketTask` (iOS 13+; deployment
// target is 17). A native socket matters for Douyin: the handshake
// must carry a Cookie header, which a WKWebView JS WebSocket cannot
// send. Transports take an injectable socket so tests can drive the
// decode paths without a network.
//
// `LiveDanmakuTransportBase` is the shared lifecycle for the four
// WebSocket transports (Bilibili / Douyu / Huya / Douyin). Kuaishou
// polls over HTTP and implements `LiveDanmakuTransport` directly.
//
// Reconnect policy: a dropped socket calls `onReconnect` and
// re-runs the transport's `connect` step after 2 s, generation-
// guarded, until `stop()` is called. Credential problems (Bilibili
// auth rejection) are handled by the transport itself, not here.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Raw socket

/// A raw WebSocket pipe for one danmaku transport. Callbacks are
/// properties (not connect parameters) so a transport can re-wire
/// them when it reconnects without rebuilding the socket.
protocol LiveDanmakuSocket: AnyObject {
    var onMessage: ((Data) -> Void)? { get set }
    var onConnected: (() -> Void)? { get set }
    var onDisconnected: (() -> Void)? { get set }

    /// Opens the connection. `onConnected` fires once the task is
    /// resumed (the handshake itself is only proven by the first
    /// successful receive; a failed handshake surfaces as
    /// `onDisconnected`).
    func connect(url: URL, headers: [String: String])
    func send(_ data: Data)
    func close()
}

/// `URLSessionWebSocketTask` implementation. Binary frames arrive as
/// `Data`; text frames are UTF-8 encoded into `Data` so transports
/// see one shape. The receive loop is recursive and explicit-label
/// only (see S3 lesson 5).
final class URLSessionLiveDanmakuSocket: LiveDanmakuSocket {
    var onMessage: ((Data) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var closed = false

    func connect(url: URL, headers: [String: String]) {
        close()
        closed = false
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let session = URLSession(configuration: .default)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        onConnected?()
        receiveNext()
    }

    func send(_ data: Data) {
        task?.send(.data(data), completionHandler: { _ in })
    }

    func close() {
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func receiveNext() {
        task?.receive(completionHandler: { [weak self] result in
            guard let self = self, !self.closed else {
                return
            }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self.onMessage?(data)
                case .string(let text):
                    self.onMessage?(Data(text.utf8))
                @unknown default:
                    break
                }
                self.receiveNext()
            case .failure:
                self.disconnect()
            }
        })
    }

    private func disconnect() {
        guard !closed else {
            return
        }
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        onDisconnected?()
    }
}

// MARK: - Transport protocol

/// One receive-only danmaku transport for a room. `start` takes the
/// room's `danmakuData` map (credentials); `heartbeat` sends the
/// platform's keep-alive frame; `stop` ends everything and drops
/// the callbacks so a dead room cannot message a dead UI.
protocol LiveDanmakuTransport: AnyObject {
    var isConnected: Bool { get }
    var onMessage: ((DanmakuMessage) -> Void)? { get set }
    var onReady: (() -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var onReconnect: (() -> Void)? { get set }

    func start(danmakuData: [String: Any])
    func heartbeat()
    func stop()
}

// MARK: - Shared lifecycle for the WebSocket transports

/// Generation-guarded lifecycle shared by the four WebSocket
/// transports. Subclasses implement `start(danmakuData:)` (resolve
/// args, then call `connectSocket(url:headers:)`) and `heartbeat()`;
/// `stop()` is shared and may be extended by overriding it and
/// calling `super.stop()` first.
///
/// - `_generation` increments on every `start`/`stop`, so callbacks
///   from a previous room never fire into the current one.
/// - The heartbeat timer fires `heartbeat()` on the shared schedule;
///   the first beat is sent by the transport itself on ready (some
///   servers want a beat immediately after auth).
/// - A dropped socket calls `onReconnect` and re-runs `reconnect`
///   after 2 s. Subclasses set `reconnect` to their connect step
///   (re-join with the saved args).
class LiveDanmakuTransportBase: LiveDanmakuTransport {
    var isConnected: Bool {
        _connected
    }

    var onMessage: ((DanmakuMessage) -> Void)?
    var onReady: (() -> Void)?
    var onClose: (() -> Void)?
    var onReconnect: (() -> Void)?

    var _connected = false
    var _stopped = false
    var _generation = 0
    var _socket: LiveDanmakuSocket?
    var _injectedSocket: LiveDanmakuSocket?
    var _heartbeatTimer: DispatchSourceTimer?
    var _reconnect: (() -> Void)?

    /// Seconds between a dropped socket and the reconnect attempt.
    static let reconnectDelaySeconds: Double = 2

    func start(danmakuData: [String: Any]) {
        // Subclasses override; the base implementation is only a
        // guard against being used directly.
        _ = danmakuData
    }

    func heartbeat() {
        // Subclasses override.
    }

    func stop() {
        _generation += 1
        _stopped = true
        _connected = false
        cancelHeartbeat()
        _reconnect = nil
        _socket?.close()
        _socket = nil
        onMessage = nil
        onReconnect = nil
        onClose = nil
        onReady = nil
    }

    /// Begins a generation: closes any previous socket, resets the
    /// connected flag, and returns the generation the caller must
    /// capture and check in every later callback.
    func beginStart() -> Int {
        _generation += 1
        _stopped = false
        _connected = false
        cancelHeartbeat()
        _socket?.close()
        _socket = nil
        _reconnect = nil
        return _generation
    }

    /// Opens the (possibly injected) socket with generation-guarded
    /// callbacks. `onSocketMessage` receives raw frames;
    /// `onSocketReady` runs the join step.
    func connectSocket(
        url: URL,
        headers: [String: String],
        generation: Int,
        onSocketMessage: @escaping (Data) -> Void,
        onSocketReady: @escaping () -> Void
    ) {
        let socket = _injectedSocket ?? URLSessionLiveDanmakuSocket()
        _socket = socket
        socket.onMessage = { [weak self] data in
            guard let self = self, generation == self._generation else {
                return
            }
            onSocketMessage(data)
        }
        socket.onConnected = { [weak self] in
            guard let self = self, generation == self._generation else {
                return
            }
            onSocketReady()
        }
        socket.onDisconnected = { [weak self] in
            guard let self = self, generation == self._generation, !self._stopped else {
                return
            }
            self._connected = false
            self.cancelHeartbeat()
            self.onReconnect?()
            let reconnect = self._reconnect
            LiveHTTP.after(seconds: LiveDanmakuTransportBase.reconnectDelaySeconds) { [weak self] in
                guard let self = self, generation == self._generation, !self._stopped else {
                    return
                }
                reconnect?()
            }
        }
        socket.connect(url: url, headers: headers)
    }

    /// Starts the repeating heartbeat timer (previous timer, if any,
    /// is cancelled). The timer holds a weak reference to self.
    func startHeartbeat(every seconds: Int) {
        cancelHeartbeat()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + .seconds(seconds), repeating: .seconds(seconds))
        timer.setEventHandler { [weak self] in
            self?.heartbeat()
        }
        timer.resume()
        _heartbeatTimer = timer
    }

    func cancelHeartbeat() {
        _heartbeatTimer?.cancel()
        _heartbeatTimer = nil
    }

    func sendSocket(_ data: Data) {
        _socket?.send(data)
    }
}

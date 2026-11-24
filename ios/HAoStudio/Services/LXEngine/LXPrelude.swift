// LXPrelude.swift
// LX engine host shim injected into every script's JSContext.
//
// Verbatim translation of the Flutter `kLxPrelude` from
// `lib/services/music/lx_script_engine.dart` (1.1.6+32): it installs
// `globalThis.lx` (event names, `request`/`on`/`send`, utils, env),
// `btoa`/`atob`/`Buffer` shims, and routes `setTimeout` through the
// host. The host-provided globals it relies on are:
//
//   - `sendMessage(channel, payloadJSON)` — Swift closure installed
//     by `LXEngine` on every context; channels `LxRequest`,
//     `LxTimeout`, `LxSend`, `LxLog` (see `LXEngine`).
//   - `__haoLxDispatch(idOrFunction, payload)` /
//     `__haoLxDispatchResult(id)` — the call/response bridge that
//     the engine installs after the prelude evaluates.
//   - `__haoLxDispatchDiscard(id)` — Swift-only addition (2026-11-24,
//     build 36 item 10): unconditionally deletes a dispatch result
//     entry when a poll exits early (cancel/timeout); no script
//     calls it, and the Flutter prelude does not have it.
//
// The prelude is brace-balanced (preflight check 5b counts braces
// inside string literals), contains no `async`/`any` token, and no
// web-view or metadata-service references. Keep it byte-identical to
// the Flutter version unless a behaviour difference is recorded in
// the report.

import Foundation

enum LXPrelude {
    /// The host shim, evaluated into every per-script JSContext before
    /// the script body. Single evaluation per context is guarded by
    /// `globalThis.__haoLxInstalled`.
    static let source = #"""

(function () {
  if (globalThis.__haoLxInstalled) return;
  var __haoLog = function (level, args) {
    try {
      var parts = [];
      for (var i = 0; i < args.length; i++) {
        var a = args[i];
        try { parts.push(typeof a === 'string' ? a : JSON.stringify(a)); }
        catch (e) { parts.push(String(a)); }
      }
      sendMessage('LxLog', JSON.stringify({ scriptId: globalThis.__haoLxScriptId || null, level: level, text: parts.join(' ') }));
    } catch (e) {}
  };
  if (typeof console === 'undefined') { globalThis.console = {}; }
  console.log = function () { __haoLog('log', arguments); };
  console.info = function () { __haoLog('info', arguments); };
  console.warn = function () { __haoLog('warn', arguments); };
  console.error = function () { __haoLog('error', arguments); };
  console.debug = function () { __haoLog('debug', arguments); };
  console.group = function () { __haoLog('group', arguments); };
  console.groupEnd = function () { __haoLog('groupEnd', arguments); };

  var __handlers = {};
  var __reqSeq = 0;
  var __reqCallbacks = {};
  var __dispatchSeq = 0;
  var __dispatchResults = {};

  function __on(event, fn) {
    if (!__handlers[event]) __handlers[event] = [];
    __handlers[event].push(fn);
  }
  function __send(event, data) {
    try { sendMessage('LxSend', JSON.stringify({ scriptId: globalThis.__haoLxScriptId || null, event: event, data: data === undefined ? null : data })); } catch (e) {}
  }
  function __request(url, options, callback) {
    if (typeof options === 'function') { callback = options; options = {}; }
    options = options || {};
    var id = ++__reqSeq;
    __reqCallbacks[id] = callback;
    var body = (options.body !== undefined && options.body !== null) ? options.body : null;
    if (body !== null && typeof body !== 'string') {
      try { body = JSON.stringify(body); } catch (e) { body = String(body); }
    }
    try {
      sendMessage('LxRequest', JSON.stringify({ scriptId: globalThis.__haoLxScriptId || null, id: id, url: String(url), method: options.method || 'GET', headers: options.headers || {}, body: body, timeout: options.timeout || 0 }));
    } catch (e) {
      var cb = __reqCallbacks[id];
      delete __reqCallbacks[id];
      if (cb) { try { cb(new Error(String(e)), null); } catch (e2) {} }
    }
  }
  globalThis.__haoLxDeliver = function (id, errText, respJson) {
    var cb = __reqCallbacks[id];
    if (!cb) return 'no-callback';
    delete __reqCallbacks[id];
    var resp = null;
    if (respJson) { try { resp = JSON.parse(respJson); } catch (e) { resp = null; } }
    try {
      if (errText) cb(new Error(errText), null);
      else cb(null, resp);
    } catch (e) {}
    return 'ok';
  };
  globalThis.__haoLxDispatch = function (event, payloadJson) {
    var id = ++__dispatchSeq;
    __dispatchResults[id] = { done: false, ok: false, value: null, error: null };
    var payload = null;
    try { payload = JSON.parse(payloadJson); }
    catch (e) { __dispatchResults[id] = { done: true, ok: false, value: null, error: 'bad payload: ' + e.message }; return id; }
    var handlers = __handlers[event] || [];
    if (handlers.length === 0) { __dispatchResults[id] = { done: true, ok: false, value: null, error: 'no handler for event ' + event }; return id; }
    try {
      var ret = handlers[0](payload);
      if (ret && typeof ret.then === 'function') {
        ret.then(
          function (v) { __dispatchResults[id] = { done: true, ok: true, value: v === undefined ? null : v, error: null }; },
          function (e) { __dispatchResults[id] = { done: true, ok: false, value: null, error: e && e.message ? e.message : String(e) }; }
        );
      } else {
        __dispatchResults[id] = { done: true, ok: true, value: ret === undefined ? null : ret, error: null };
      }
    } catch (e) {
      __dispatchResults[id] = { done: true, ok: false, value: null, error: e && e.message ? e.message : String(e) };
    }
    return id;
  };
  globalThis.__haoLxDispatchResult = function (id) {
    var r = __dispatchResults[id];
    if (!r) return JSON.stringify({ done: true, ok: false, value: null, error: 'unknown dispatch ' + id });
    var out = JSON.stringify(r);
    if (r.done) delete __dispatchResults[id];
    return out;
  };
  globalThis.__haoLxDispatchDiscard = function (id) {
    delete __dispatchResults[id];
    return 'ok';
  };
  // Timers: flutter_js's native setTimeout is bridged through a
  // process-wide static Dart callback (JSCore: _sendMessageDartFunc),
  // so with 20 runtimes a timer scheduled by script A fires its
  // callback in the NEWEST runtime's context — and after A is
  // disposed, in a released JSContext (native UAF, v1.0.7-class).
  // Route timers through our own stamped channel instead: Dart
  // fires __haoLxFireTimeout only on the runtime still registered
  // under this script id, and drops the timer outright once the
  // script is removed. flutter_js's own extensions (fetch /
  // handle_promises) do not use setTimeout, so nothing else loses
  // its timer by overwriting the global here.
  var __haoTimeoutSeq = 0;
  var __haoTimeoutCallbacks = {};
  globalThis.__haoLxFireTimeout = function (idx) {
    var fn = __haoTimeoutCallbacks[idx];
    if (!fn) return 'no-timer';
    delete __haoTimeoutCallbacks[idx];
    try { fn(); } catch (e) {}
    return 'ok';
  };
  globalThis.setTimeout = function (fn, ms) {
    if (typeof fn === 'string') { try { fn = new Function(fn); } catch (e) { return 0; } }
    if (typeof fn !== 'function') return 0;
    var args = [];
    for (var i = 2; i < arguments.length; i++) args.push(arguments[i]);
    var id = ++__haoTimeoutSeq;
    __haoTimeoutCallbacks[id] = function () { fn.apply(null, args); };
    try { sendMessage('LxTimeout', JSON.stringify({ scriptId: globalThis.__haoLxScriptId || null, action: 'set', timeoutIndex: String(id), timeout: ms || 0 })); } catch (e) {}
    return id;
  };
  globalThis.clearTimeout = function (id) {
    delete __haoTimeoutCallbacks[id];
    try { sendMessage('LxTimeout', JSON.stringify({ scriptId: globalThis.__haoLxScriptId || null, action: 'clear', timeoutIndex: String(id), timeout: 0 })); } catch (e) {}
  };
  var __b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function __b64encode(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i += 3) {
      var b0 = bytes[i], b1 = i + 1 < bytes.length ? bytes[i + 1] : 0, b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
      out += __b64chars[b0 >> 2] + __b64chars[((b0 & 3) << 4) | (b1 >> 4)];
      out += i + 1 < bytes.length ? __b64chars[((b1 & 15) << 2) | (b2 >> 6)] : '=';
      out += i + 2 < bytes.length ? __b64chars[b2 & 63] : '=';
    }
    return out;
  }
  function __b64decode(s) {
    s = String(s).replace(/[^A-Za-z0-9+/=]/g, '');
    var bytes = [];
    var buf = 0, bits = 0;
    for (var i = 0; i < s.length; i++) {
      var c = s[i];
      if (c === '=') break;
      var v = __b64chars.indexOf(c);
      if (v < 0) continue;
      buf = (buf << 6) | v; bits += 6;
      if (bits >= 8) { bits -= 8; bytes.push((buf >> bits) & 255); }
    }
    return bytes;
  }
  function __utf8Encode(str) {
    var utf8 = unescape(encodeURIComponent(str));
    var bytes = [];
    for (var i = 0; i < utf8.length; i++) bytes.push(utf8.charCodeAt(i) & 255);
    return bytes;
  }
  function __utf8Decode(bytes) {
    var s = '';
    for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
    try { return decodeURIComponent(escape(s)); } catch (e) { return s; }
  }
  function __bufFrom(data, encoding) {
    encoding = encoding || 'utf-8';
    var bytes;
    if (encoding === 'base64') bytes = __b64decode(data);
    else if (encoding === 'hex') {
      var h = String(data); bytes = [];
      for (var i = 0; i + 1 < h.length; i += 2) bytes.push(parseInt(h.substring(i, i + 2), 16));
    } else bytes = __utf8Encode(String(data));
    return { __haoBuf: true, bytes: bytes };
  }
  function __bufToString(buf, encoding) {
    encoding = encoding || 'utf-8';
    var bytes = (buf && buf.bytes) ? buf.bytes : [];
    if (encoding === 'base64') return __b64encode(bytes);
    if (encoding === 'hex') {
      var s = '';
      for (var i = 0; i < bytes.length; i++) { var x = bytes[i].toString(16); s += x.length === 1 ? '0' + x : x; }
      return s;
    }
    return __utf8Decode(bytes);
  }
  // btoa / atob / Buffer (M-P2-2): QuickJS provides none of these,
  // and two scripts fall back to them (helloworld's token builder
  // uses btoa; xinghai's safeBase64Encode uses Buffer.from +
  // isBuffer). They used to be unreachable because lx.utils.buffer
  // exists — but a fallback that silently yields '' / the raw string
  // is worse than a working shim. Reuses __b64encode / __b64decode /
  // __bufFrom / __bufToString above. btoa/atob use binary-string
  // semantics (one char per byte), matching the browser.
  function __btoa(s) {
    s = String(s);
    var bytes = [];
    for (var i = 0; i < s.length; i++) bytes.push(s.charCodeAt(i) & 255);
    return __b64encode(bytes);
  }
  function __atob(s) {
    var bytes = __b64decode(s);
    var out = '';
    for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]);
    return out;
  }
  globalThis.btoa = __btoa;
  globalThis.atob = __atob;
  globalThis.Buffer = {
    from: function (data, encoding) {
      var buf;
      if (data && data.__haoBuf) {
        buf = data;
      } else if (data && typeof data === 'object' && typeof data.length === 'number') {
        var bytes = [];
        for (var i = 0; i < data.length; i++) bytes.push(data[i] & 255);
        buf = { __haoBuf: true, bytes: bytes };
      } else {
        buf = __bufFrom(data, encoding);
      }
      if (buf.toString === Object.prototype.toString) {
        buf.toString = function (enc) { return __bufToString(buf, enc || 'utf-8'); };
      }
      return buf;
    },
    isBuffer: function (o) { return !!(o && o.__haoBuf); },
  };
  globalThis.lx = {
    EVENT_NAMES: { inited: 'inited', request: 'request', updateAlert: 'updateAlert', showConfigView: 'showConfigView' },
    request: __request,
    on: __on,
    send: __send,
    utils: { buffer: { from: __bufFrom, bufToString: __bufToString } },
    env: 'mobile',
    version: '1.0.4'
  };
  globalThis.__haoLxInstalled = true;
})();
var lx = globalThis.lx;
"""#
}

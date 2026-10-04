// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
// Built from apps/cyfr/assets/js/toolkit by `mix esbuild toolkit_worker`.
(() => {
  // js/sdk/wire.js
  var VERSION = 1;
  var BEARER_HEADER = "authorization";
  var ROUTES = Object.freeze({
    invoke: "/_f/v1/invoke",
    action: "/_f/v1/action",
    stream_open: "/_f/v1/stream"
  });
  var VERBS = Object.freeze(["open", "close", "title", "ready", "credential"]);
  var isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
  function bearer(credential) {
    if (typeof credential !== "string" || credential === "" || /\s/.test(credential)) {
      throw new TypeError("a frame credential is a non-empty string without whitespace");
    }
    return "Bearer " + credential;
  }
  function request(kind, fields, publicIdentity = null) {
    let body;
    switch (kind) {
      case "invoke":
        body = { v: VERSION, ref: fields.ref, operation: fields.operation, args: fields.args };
        break;
      case "action":
        body = { v: VERSION, operation: fields.operation, args: fields.args };
        break;
      case "stream_open":
        body = { v: VERSION, stream: fields.stream, subject: fields.subject };
        break;
      default:
        throw new TypeError("unknown request kind: " + kind);
    }
    if (publicIdentity) body.public = publicIdentity;
    return body;
  }
  var STREAM_CONTENT_TYPE = "text/event-stream";
  function sseParser(onEvent) {
    let buffer = "";
    let pendingCR = false;
    let frame = { id: null, event: "message", data: [] };
    const dispatch = () => {
      const { id, event, data } = frame;
      frame = { id: null, event: "message", data: [] };
      if (data.length === 0) return;
      let payload;
      try {
        payload = JSON.parse(data.join("\n"));
      } catch (_error) {
        return;
      }
      onEvent({ id, event, data: payload });
    };
    const line = (text) => {
      if (text === "") return dispatch();
      if (text.startsWith(":")) return;
      const colon = text.indexOf(":");
      const field = colon === -1 ? text : text.slice(0, colon);
      let value = colon === -1 ? "" : text.slice(colon + 1);
      if (value.startsWith(" ")) value = value.slice(1);
      if (field === "data") frame.data.push(value);
      else if (field === "event") frame.event = value;
      else if (field === "id") frame.id = /^\d+$/.test(value) ? Number(value) : null;
    };
    return {
      // Lines end with LF, CRLF or CR, and a chunk may end anywhere, a CRLF
      // pair split between two chunks included.
      push(text) {
        if (pendingCR && text.startsWith("\n")) text = text.slice(1);
        pendingCR = false;
        buffer += text;
        let match;
        while ((match = /\r\n|\r|\n/.exec(buffer)) !== null) {
          if (match[0] === "\r" && match.index === buffer.length - 1) {
            pendingCR = true;
          }
          line(buffer.slice(0, match.index));
          buffer = buffer.slice(match.index + match[0].length);
        }
      },
      // A stream that ends mid-event dispatches nothing more: an event is
      // complete only at its blank line.
      end() {
        buffer = "";
        frame = { id: null, event: "message", data: [] };
      }
    };
  }
  function decodeAnswer(kind, body) {
    const invalid2 = { ok: false, invalid: true };
    if (!isObject(body) || body.v !== VERSION || !(kind in ROUTES)) return invalid2;
    const keys = Object.keys(body);
    if (body.ok === true && keys.length === 3) {
      if ((kind === "invoke" || kind === "action") && "result" in body) {
        return { ok: true, value: body.result };
      }
      if (kind === "stream_open" && isObject(body.stream)) return decodeGrant(body.stream);
      return invalid2;
    }
    if (body.ok === false && keys.length === 3 && isObject(body.error)) {
      const { class: cls, message, stage } = body.error;
      if (Object.keys(body.error).length === 3 && typeof cls === "string" && cls !== "" && typeof message === "string" && (stage === "admission" || stage === "execution")) {
        return { ok: false, refusal: { class: cls, message, stage } };
      }
    }
    return invalid2;
  }
  function decodeGrant(stream) {
    const { grant_id, stream: name, subject, projection, deadline } = stream;
    const at = typeof deadline === "string" ? new Date(deadline) : null;
    if (Object.keys(stream).length === 5 && typeof grant_id === "string" && typeof name === "string" && (subject === null || typeof subject === "string") && Array.isArray(projection) && projection.every((field) => typeof field === "string") && at !== null && !Number.isNaN(at.getTime())) {
      return { ok: true, value: { grant_id, stream: name, subject, projection, deadline: at } };
    }
    return { ok: false, invalid: true };
  }

  // js/toolkit/wire.js
  var TO_PRISM_VERBS = Object.freeze(["ready", "tree", "open", "press", "failed"]);
  var TO_TOOLKIT_VERBS = Object.freeze(["boot", "posture", "covered", "installed", "state"]);
  var TOOLKIT_MAJORS = Object.freeze([1]);
  var MODES = ["live", "validation"];
  var MAX_STREAMS = 64;
  var STREAM_ROUTE = "stream";
  var FEED_STREAM = "feed.results";
  var NAME = /^[a-z0-9][a-z0-9-]{0,47}$/;
  var BINDING_ID = /^feed_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
  var STREAM_NAME = /^[a-z][a-z0-9_]{0,62}(\.[a-z][a-z0-9_]{0,62})+$/;
  var ELIXIR_SPACE = "[\\t\\n\\v\\f\\r \\u0085\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000]";
  var TRIM = new RegExp(`^${ELIXIR_SPACE}+|${ELIXIR_SPACE}+$`, "g");
  var LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;
  var CONTROL = /[\u0000-\u001F\u007F-\u009F]/;
  var isPlainObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value) && Object.prototype.toString.call(value) === "[object Object]";
  var isText = (value) => typeof value === "string" && !LONE_SURROGATE.test(value);
  var codePoints = (value) => Array.from(value).length;
  var isLabel = (value, min, max) => isText(value) && !CONTROL.test(value) && codePoints(value) >= min && codePoints(value) <= max;
  var isName = (value) => typeof value === "string" && NAME.test(value);
  var isBindingId = (value) => typeof value === "string" && BINDING_ID.test(value);
  var isStreamName = (value) => typeof value === "string" && STREAM_NAME.test(value);
  var bounded = (list, max, each) => Array.isArray(list) && list.length <= max && list.every(each);
  function isStreams(streams) {
    if (!bounded(streams, MAX_STREAMS, isStream)) return false;
    const pairs = new Set(streams.map(pairKey));
    return pairs.size === streams.length;
  }
  var isStream = (stream) => isPlainObject(stream) && sameKeys(stream, ["name", "subject"]) && isStreamName(stream.name) && (stream.subject === null || isText(stream.subject));
  var pairKey = ({ name, subject }) => JSON.stringify([name, subject]);
  var sameKeys = (object, keys) => {
    const present = Object.keys(object).sort();
    return present.length === keys.length && present.every((key, i) => key === keys[i]);
  };
  var ROLES = Object.freeze({ module: "cyfr-toolkit-module", streams: "cyfr-toolkit-streams" });
  var MODULE_KINDS = ["posture", "covered", "installed"];
  var ON_KINDS = Object.freeze([...MODULE_KINDS]);
  var toModule = Object.freeze({
    boot: (mode, moduleUrl, port) => ({ t: "boot", mode, module_url: moduleUrl, port }),
    value: (kind, value) => ({ t: kind, value }),
    surface: (id, canvas) => ({ t: "surface", id, canvas }),
    stream: (m) => ({ t: "stream", m })
  });
  var toStreams = Object.freeze({
    boot: (credential, dataUrl, streams, port) => ({ t: "boot", credential, data_url: dataUrl, streams, port })
  });
  var fromModule = Object.freeze({
    tree: (json) => ({ t: "tree", json }),
    failed: (stage) => ({ t: "failed", stage })
  });
  var fromStreams = Object.freeze({
    relay: (m, record = null) => ({ t: "relay", m, record }),
    lost: () => ({ t: "lost" })
  });
  var request2 = Object.freeze({
    open: (sub, name, subject) => ({ t: "open", sub, name, subject }),
    close: (sub) => ({ t: "close", sub })
  });
  var isSub = (sub) => Number.isSafeInteger(sub) && sub >= 0;
  function decodeRequest(data) {
    if (!isPlainObject(data) || !isSub(data.sub)) return null;
    if (data.t === "open" && sameKeys(data, ["name", "sub", "subject", "t"])) {
      if (typeof data.name !== "string" || !(data.subject === null || typeof data.subject === "string")) return null;
      return { kind: "open", sub: data.sub, name: data.name, subject: data.subject };
    }
    if (data.t === "close" && sameKeys(data, ["sub", "t"])) return { kind: "close", sub: data.sub };
    return null;
  }
  var answer = Object.freeze({
    opened: (sub) => ({ t: "opened", sub }),
    refused: (sub, code, message, stage = null) => ({ t: "refused", sub, code, message, stage }),
    event: (sub, event) => ({ t: "event", sub, event }),
    closed: (sub, error = null) => ({ t: "closed", sub, error })
  });
  function decodeAnswer2(data) {
    if (!isPlainObject(data) || !isSub(data.sub)) return null;
    switch (data.t) {
      case "opened":
        return sameKeys(data, ["sub", "t"]) ? data : null;
      case "refused":
        return sameKeys(data, ["code", "message", "stage", "sub", "t"]) && typeof data.code === "string" && typeof data.message === "string" && (data.stage === null || typeof data.stage === "string") ? data : null;
      case "event":
        return sameKeys(data, ["event", "sub", "t"]) && isPlainObject(data.event) ? data : null;
      case "closed":
        return sameKeys(data, ["error", "sub", "t"]) && (data.error === null || typeof data.error === "string") ? data : null;
      default:
        return null;
    }
  }
  function decodeToModule(data) {
    if (!isPlainObject(data)) return null;
    if (data.t === "boot" && sameKeys(data, ["mode", "module_url", "port", "t"])) {
      return MODES.includes(data.mode) && typeof data.module_url === "string" && isPort(data.port) ? data : null;
    }
    if (MODULE_KINDS.includes(data.t) && sameKeys(data, ["t", "value"])) return data;
    if (data.t === "surface" && sameKeys(data, ["canvas", "id", "t"]) && isName(data.id)) return data;
    if (data.t === "stream" && sameKeys(data, ["m", "t"]) && decodeAnswer2(data.m) !== null) return data;
    return null;
  }
  function decodeToStreams(data) {
    if (!isPlainObject(data) || data.t !== "boot") return null;
    if (!sameKeys(data, ["credential", "data_url", "port", "streams", "t"])) return null;
    if (typeof data.credential !== "string" || data.credential === "" || typeof data.data_url !== "string") return null;
    return isStreams(data.streams) && isPort(data.port) ? data : null;
  }
  var isPort = (port) => port !== null && typeof port === "object" && typeof port.postMessage === "function";
  var MAX_ACTIONS = 8;
  var BINDING_LABEL_MAX = 80;
  var ACTION_LABEL_MAX = 40;
  function recordFromEnvelope(data, feed) {
    if (!isPlainObject(data) || !isName(feed) || data.feed !== feed) return null;
    return decodeRecord({
      feed,
      binding: data.binding,
      revision: data.revision,
      label: data.label,
      actions: data.actions
    });
  }
  function decodeRecord(record) {
    if (!isPlainObject(record) || !sameKeys(record, ["actions", "binding", "feed", "label", "revision"])) return null;
    const { feed, binding, revision, label, actions } = record;
    if (!isName(feed) || !isBindingId(binding)) return null;
    if (!Number.isSafeInteger(revision) || revision < 0) return null;
    if (!isLabel(label, 1, BINDING_LABEL_MAX)) return null;
    if (!Array.isArray(actions) || actions.length > MAX_ACTIONS) return null;
    const names = /* @__PURE__ */ new Set();
    const read = [];
    for (const action of actions) {
      if (!isPlainObject(action) || !isName(action.name) || names.has(action.name)) return null;
      if (!isLabel(action.label, 1, ACTION_LABEL_MAX)) return null;
      names.add(action.name);
      read.push({ name: action.name, label: action.label });
    }
    return { feed, binding, revision, label, actions: read };
  }

  // js/toolkit/worker.js
  var CanvasError = class extends Error {
    constructor(message, code, stage) {
      super(message);
      this.name = "CyfrError";
      this.code = code;
      if (stage) this.stage = stage;
    }
  };
  var invalid = (sentence) => Promise.reject(new CanvasError(sentence, "invalid_argument"));
  function sealClose(scope) {
    for (let object = scope; object !== null; object = Object.getPrototypeOf(object)) {
      const descriptor = Object.getOwnPropertyDescriptor(object, "close");
      if (descriptor && descriptor.configurable) delete object.close;
    }
  }
  function startModuleWorker(scope, { importModule }) {
    const post = scope.postMessage.bind(scope);
    const listen = scope.addEventListener.bind(scope);
    sealClose(scope);
    let booted = false;
    let port = null;
    let failed = false;
    let nextSub = 0;
    const subs = /* @__PURE__ */ new Map();
    const latest = /* @__PURE__ */ new Map();
    const handlers = new Map(ON_KINDS.map((kind) => [kind, []]));
    const surfaces = /* @__PURE__ */ new Map();
    const waiting = /* @__PURE__ */ new Map();
    function fail(stage) {
      if (failed) return;
      failed = true;
      post(fromModule.failed(stage));
    }
    function call(fn, value) {
      try {
        fn(value);
      } catch (_error) {
        fail("runtime");
      }
    }
    listen("error", () => fail("runtime"));
    listen("unhandledrejection", () => fail("runtime"));
    listen("message", (event) => {
      if (event.isTrusted !== true) return;
      const message = decodeToModule(event.data);
      if (message === null) return;
      if (!booted) {
        if (message.t === "boot") boot(message);
        return;
      }
      if (message.t === "surface") return surface(message.id, message.canvas);
      if (message.t === "stream") return onAnswer(message.m);
      if (handlers.has(message.t)) {
        latest.set(message.t, message.value);
        for (const fn of handlers.get(message.t)) call(fn, message.value);
      }
    });
    function boot(message) {
      booted = true;
      port = message.port;
      port.onmessage = (event) => {
        const m = decodeAnswer2(event.data);
        if (m !== null) onAnswer(m);
      };
      let loading;
      try {
        loading = importModule(message.module_url);
      } catch (_error) {
        return fail("load");
      }
      Promise.resolve(loading).then(load, () => fail("load"));
    }
    function load(namespace) {
      let main;
      let result;
      try {
        main = namespace && namespace.default;
        if (typeof main !== "function") return fail("load");
        result = main(canvas);
      } catch (_error) {
        return fail("load");
      }
      Promise.resolve(result).then(void 0, () => fail("runtime"));
    }
    function surface(id, offscreen) {
      surfaces.set(id, offscreen);
      const resolvers = waiting.get(id) || [];
      waiting.delete(id);
      for (const resolve of resolvers) resolve(offscreen);
    }
    function onAnswer(m) {
      const entry = subs.get(m.sub);
      if (!entry) return;
      switch (m.t) {
        case "opened":
          if (entry.open) return;
          entry.open = true;
          return entry.resolve(entry.handle);
        case "refused":
          subs.delete(m.sub);
          return entry.reject(new CanvasError(m.message, m.code, m.stage));
        case "event":
          if (entry.open) call(entry.onEvent, m.event);
          return;
        case "closed":
          subs.delete(m.sub);
          if (!entry.open) return entry.reject(new CanvasError("The stream could not be opened.", m.error || "unavailable"));
          if (m.error) return entry.end(new CanvasError("The endpoint could not be reached.", m.error));
          return entry.end(null);
        default:
          return;
      }
    }
    function openStream(name, subject, onEvent) {
      const sub = nextSub++;
      return new Promise((resolve, reject) => {
        let end;
        const closed = new Promise((settle, broke) => {
          end = (error) => error ? broke(error) : settle();
        });
        closed.catch(() => {
        });
        const handle = Object.freeze({
          closed,
          close() {
            if (!subs.has(sub)) return;
            subs.delete(sub);
            port.postMessage(request2.close(sub));
            end(null);
          }
        });
        subs.set(sub, { onEvent, resolve, reject, end, handle, open: false });
        port.postMessage(request2.open(sub, name, subject));
      });
    }
    const canvas = Object.freeze({
      /** Draw `tree`: an element tree of toolkit major 1. */
      render(tree) {
        let json = null;
        try {
          json = JSON.stringify(tree);
        } catch (_error) {
          json = null;
        }
        post(fromModule.tree(typeof json === "string" ? json : null));
      },
      /**
       * Open a stream the canvas declares and deliver its events, as the SDK's
       * `cyfr.stream`: resolves to `{closed, close()}` once open, calls
       * `onEvent({id, event, data})` for each event, and rejects with the
       * refusal's `code` and `stage`.
       */
      stream(name, subject, onEvent) {
        if (typeof name !== "string" || name === "") return invalid("stream must be a stream name");
        if (subject !== null && typeof subject !== "string") return invalid("subject must be a literal subject or null");
        if (typeof onEvent !== "function") return invalid("onEvent must be a function");
        return openStream(name, subject, onEvent);
      },
      /** Call `fn` with each `posture`, `covered` or `installed` value, the latest one first. */
      on(kind, fn) {
        if (!handlers.has(kind)) throw new TypeError("canvas.on takes posture, covered or installed");
        if (typeof fn !== "function") throw new TypeError("canvas.on takes a function");
        handlers.get(kind).push(fn);
        if (latest.has(kind)) {
          const value = latest.get(kind);
          queueMicrotask(() => call(fn, value));
        }
      },
      /** The `OffscreenCanvas` of a drawn `surface` element, once it is drawn. */
      surface(id) {
        if (surfaces.has(id)) return Promise.resolve(surfaces.get(id));
        return new Promise((resolve) => {
          waiting.set(id, [...waiting.get(id) || [], resolve]);
        });
      }
    });
  }
  function startStreamsWorker(scope, { fetchFn }) {
    const post = scope.postMessage.bind(scope);
    let booted = false;
    let credential = null;
    let streamUrl = null;
    let declared = /* @__PURE__ */ new Set();
    let port = null;
    const subs = /* @__PURE__ */ new Map();
    scope.addEventListener("message", (event) => {
      if (event.isTrusted !== true || booted) return;
      const boot = decodeToStreams(event.data);
      if (boot === null) return;
      booted = true;
      credential = boot.credential;
      streamUrl = boot.data_url + STREAM_ROUTE;
      declared = new Set(boot.streams.map(pairKey));
      port = boot.port;
      port.onmessage = (message) => onRequest(message.data);
      if (typeof port.addEventListener === "function") port.addEventListener("close", () => post(fromStreams.lost()));
    });
    function onRequest(data) {
      const req = decodeRequest(data);
      if (req === null) return;
      if (req.kind === "close") {
        const sub2 = subs.get(req.sub);
        if (sub2) {
          subs.delete(req.sub);
          sub2.closing = true;
          sub2.controller.abort();
        }
        return;
      }
      const viaHost = req.name === FEED_STREAM;
      const send = (m, record = null) => viaHost ? post(fromStreams.relay(m, record)) : port.postMessage(m);
      if (subs.has(req.sub)) return send(answer.refused(req.sub, "invalid_argument", "That stream is already open."));
      if (!declared.has(pairKey(req))) {
        return send(answer.refused(req.sub, "forbidden", "This canvas does not declare that stream.", "admission"));
      }
      const sub = { controller: new AbortController(), closing: false };
      subs.set(req.sub, sub);
      open(req, sub, send, viaHost).catch(() => {
        sub.controller.abort();
        if (subs.get(req.sub) === sub) subs.delete(req.sub);
        if (!sub.closing) send(answer.closed(req.sub, "unavailable"));
        sub.closing = true;
      });
    }
    async function open(req, sub, send, viaHost) {
      const ended = (error) => {
        if (subs.get(req.sub) === sub) subs.delete(req.sub);
        if (!sub.closing) send(answer.closed(req.sub, error));
      };
      const refused = (code, message, stage = null) => {
        if (subs.get(req.sub) === sub) subs.delete(req.sub);
        if (!sub.closing) send(answer.refused(req.sub, code, message, stage));
      };
      let response;
      try {
        response = await fetchFn(streamUrl, {
          method: "POST",
          headers: { "content-type": "application/json", [BEARER_HEADER]: bearer(credential) },
          body: JSON.stringify(request("stream_open", { stream: req.name, subject: req.subject })),
          credentials: "omit",
          cache: "no-store",
          redirect: "error",
          signal: sub.controller.signal
        });
      } catch (_error) {
        return refused("unavailable", "The endpoint could not be reached.");
      }
      const type = (response.headers.get("content-type") || "").split(";")[0].trim();
      if (type !== STREAM_CONTENT_TYPE) {
        let body = null;
        try {
          body = await response.json();
        } catch (_error) {
          body = null;
        }
        sub.controller.abort();
        const decoded = decodeAnswer("stream_open", body);
        if (decoded.refusal) return refused(decoded.refusal.class, decoded.refusal.message, decoded.refusal.stage);
        return refused("invalid_answer", "The endpoint's answer could not be read.");
      }
      if (sub.closing) return sub.controller.abort();
      send(answer.opened(req.sub));
      const parser = sseParser((event) => {
        if (sub.closing) return;
        const record = viaHost ? recordFromEnvelope(event.data, req.subject) : null;
        send(answer.event(req.sub, event), record);
      });
      const decoder = new TextDecoder();
      try {
        const reader = response.body.getReader();
        for (; ; ) {
          const { done, value } = await reader.read();
          if (done) break;
          parser.push(decoder.decode(value, { stream: true }));
        }
        parser.push(decoder.decode());
        ended(null);
      } catch (_error) {
        sub.controller.abort();
        ended("unavailable");
      } finally {
        parser.end();
      }
    }
  }
  if (typeof window === "undefined" && typeof self === "object" && self !== null) {
    if (self.name === ROLES.module) {
      startModuleWorker(self, { importModule: (url) => import(url) });
    } else if (self.name === ROLES.streams) {
      startStreamsWorker(self, { fetchFn: self.fetch.bind(self) });
    }
  }
})();

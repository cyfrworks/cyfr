// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
// Built from apps/cyfr/assets/js/sdk by `mix esbuild sdk`.
(() => {
  // js/sdk/wire.js
  var VERSION = 1;
  var BEARER_HEADER = "authorization";
  var ROUTES = Object.freeze({
    invoke: "/_f/v1/invoke",
    action: "/_f/v1/action",
    stream_open: "/_f/v1/stream"
  });
  var VERBS = Object.freeze(["open", "close", "title", "ready", "credential", "press", "failed"]);
  var STAGES = Object.freeze(["load", "runtime"]);
  var HANDSHAKE = "cyfr:handshake";
  var CREDENTIAL = "cyfr:credential";
  var CREDENTIAL_CLOSED = "cyfr:credential-closed";
  function decodeCredentialClosed(data, frame) {
    if (!isObject(data) || data.v !== VERSION || data.type !== CREDENTIAL_CLOSED) return { ok: false };
    if (!only(data, ["v", "type", "frame", "saved"]) || data.frame !== frame) return { ok: false };
    if (typeof data.saved !== "boolean") return { ok: false };
    return { ok: true, saved: data.saved };
  }
  var FRAME_ID = /^[A-Za-z0-9_-]{8,64}$/;
  var TINCTURE_REF = /^(t|tincture):\S+$/;
  var STREAM_NAME = /^[a-z][a-z0-9_]{0,62}(\.[a-z][a-z0-9_]{0,62})+$/;
  var LONE_SURROGATE = new RegExp("[\\uD800-\\uDBFF](?![\\uDC00-\\uDFFF])|(?<![\\uD800-\\uDBFF])[\\uDC00-\\uDFFF]");
  var isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
  var only = (object, keys) => Object.keys(object).every((key) => keys.includes(key));
  var sameKeys = (object, keys) => {
    const present = Object.keys(object).sort();
    const wanted = [...keys].sort();
    return present.length === wanted.length && present.every((key, i) => key === wanted[i]);
  };
  var isText = (value) => typeof value === "string" && !LONE_SURROGATE.test(value);
  var isTinctureRef = (ref) => typeof ref === "string" && TINCTURE_REF.test(ref);
  function isFrameId(id) {
    return typeof id === "string" && FRAME_ID.test(id);
  }
  function bearer(credential) {
    if (typeof credential !== "string" || credential === "" || /\s/.test(credential)) {
      throw new TypeError("a frame credential is a non-empty string without whitespace");
    }
    return "Bearer " + credential;
  }
  function request(kind, fields, publicIdentity2 = null) {
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
    if (publicIdentity2) body.public = publicIdentity2;
    return body;
  }
  var ATHANOR_SEGMENT = /^@?[a-z0-9]+(-[a-z0-9]+)*$/;
  var PUBLISHER_SEGMENT = /^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/;
  var NAME_SEGMENT = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/;
  function publicIdentity(pathname) {
    if (typeof pathname !== "string") return null;
    const [empty, prefix, ...rest] = pathname.split("/");
    if (empty !== "" || prefix !== "t" || rest.length < 3) return null;
    let athanor, publisher, name;
    try {
      ;
      [athanor, publisher, name] = rest.slice(0, 3).map(decodeURIComponent);
    } catch (_error) {
      return null;
    }
    return ATHANOR_SEGMENT.test(athanor) && PUBLISHER_SEGMENT.test(publisher) && NAME_SEGMENT.test(name) ? { athanor, publisher, name } : null;
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
    const invalid = { ok: false, invalid: true };
    if (!isObject(body) || body.v !== VERSION || !(kind in ROUTES)) return invalid;
    const keys = Object.keys(body);
    if (body.ok === true && keys.length === 3) {
      if ((kind === "invoke" || kind === "action") && "result" in body) {
        return { ok: true, value: body.result };
      }
      if (kind === "stream_open" && isObject(body.stream)) return decodeGrant(body.stream);
      return invalid;
    }
    if (body.ok === false && keys.length === 3 && isObject(body.error)) {
      const { class: cls, message, stage } = body.error;
      if (Object.keys(body.error).length === 3 && typeof cls === "string" && cls !== "" && typeof message === "string" && (stage === "admission" || stage === "execution")) {
        return { ok: false, refusal: { class: cls, message, stage } };
      }
    }
    return invalid;
  }
  function decodeGrant(stream) {
    const { grant_id, stream: name, subject, projection, deadline } = stream;
    const at = typeof deadline === "string" ? new Date(deadline) : null;
    if (Object.keys(stream).length === 5 && typeof grant_id === "string" && typeof name === "string" && (subject === null || typeof subject === "string") && Array.isArray(projection) && projection.every((field) => typeof field === "string") && at !== null && !Number.isNaN(at.getTime())) {
      return { ok: true, value: { grant_id, stream: name, subject, projection, deadline: at } };
    }
    return { ok: false, invalid: true };
  }
  function shellMessage(verb, frame, args = {}) {
    if (!VERBS.includes(verb)) throw new TypeError("unknown shell verb: " + verb);
    return { v: VERSION, verb, frame, args };
  }
  var DATA_PREFIX = "/_f/v1/o/";
  var STREAM_ROUTE = "stream";
  function dataPath(frame) {
    if (!isFrameId(frame)) throw new TypeError("a frame id is 8 to 64 URL-safe characters");
    return DATA_PREFIX + frame + "/";
  }
  function streamPath(frame) {
    return dataPath(frame) + STREAM_ROUTE;
  }
  var MODES = Object.freeze(["live", "validation"]);
  var TO_FRAME_VERBS = Object.freeze(["canvas", "posture", "covered", "installed", "state"]);
  var CANVAS_EVENTS = Object.freeze(["installed", "posture", "covered", "state"]);
  var POSTURES = ["desk", "hand"];
  var SHELL_STATES = ["live", "frozen"];
  var MAX_STREAMS = 64;
  var MAX_RECTS = 64;
  var RECT_KEYS = ["x", "y", "width", "height"];
  var MAX_TINCTURES = 512;
  var MAX_NAME = 128;
  var pairKey = ({ name, subject }) => JSON.stringify([name, subject]);
  var bounded = (list, max, each) => Array.isArray(list) && list.length <= max && list.every(each);
  var isStream = (stream) => isObject(stream) && sameKeys(stream, ["name", "subject"]) && typeof stream.name === "string" && STREAM_NAME.test(stream.name) && (stream.subject === null || isText(stream.subject));
  var isStreams = (streams) => bounded(streams, MAX_STREAMS, isStream) && new Set(streams.map(pairKey)).size === streams.length;
  var isRect = (rect) => isObject(rect) && sameKeys(rect, RECT_KEYS) && RECT_KEYS.every((key) => typeof rect[key] === "number" && Number.isFinite(rect[key]) && rect[key] >= 0);
  var codePoints = (value) => Array.from(value).length;
  var isInstalled = (tincture) => isObject(tincture) && sameKeys(tincture, ["ref", "name"]) && isTinctureRef(tincture.ref) && isText(tincture.name) && codePoints(tincture.name) >= 1 && codePoints(tincture.name) <= MAX_NAME;
  function canvasError(block, frame) {
    if (!isObject(block) || !sameKeys(block, ["mode", "data_path", "streams"])) {
      return "a canvas is exactly mode, data_path and streams";
    }
    if (!MODES.includes(block.mode)) return "a canvas's mode is live or validation";
    if (block.data_path !== dataPath(frame)) return "a canvas's data path is its frame's";
    if (!isStreams(block.streams)) {
      return `a canvas names at most ${MAX_STREAMS} distinct streams of name and subject`;
    }
    return null;
  }
  function toFrameArgsError(verb, args, frame) {
    switch (verb) {
      case "canvas":
        return canvasError(args, frame);
      case "posture":
        return sameKeys(args, ["posture"]) && POSTURES.includes(args.posture) ? null : "posture is desk or hand";
      case "covered":
        return sameKeys(args, ["rects"]) && bounded(args.rects, MAX_RECTS, isRect) ? null : `covered names at most ${MAX_RECTS} rects of x, y, width and height`;
      case "installed":
        return sameKeys(args, ["tinctures"]) && bounded(args.tinctures, MAX_TINCTURES, isInstalled) ? null : `installed names at most ${MAX_TINCTURES} tinctures of ref and name`;
      case "state":
        return sameKeys(args, ["state"]) && SHELL_STATES.includes(args.state) ? null : "state is live or frozen";
      default:
        return "unknown verb";
    }
  }
  function decodeToFrame(message) {
    if (!isObject(message)) return { ok: false, error: "the message must be an object" };
    if (!sameKeys(message, ["v", "verb", "frame", "args"])) {
      return { ok: false, error: "the message is v, verb, frame and args" };
    }
    if (message.v !== VERSION) return { ok: false, error: "the message carries no wire version 1" };
    if (!TO_FRAME_VERBS.includes(message.verb)) return { ok: false, error: "unknown verb" };
    if (!isFrameId(message.frame)) return { ok: false, error: "frame must be a frame id" };
    if (!isObject(message.args)) return { ok: false, error: "args must be an object" };
    const error = toFrameArgsError(message.verb, message.args, message.frame);
    if (error) return { ok: false, error };
    return { ok: true, message: { v: VERSION, verb: message.verb, frame: message.frame, args: message.args } };
  }

  // js/sdk/client.js
  var HANDSHAKE_TIMEOUT_MS = 3e4;
  var MAX_QUEUED_VERBS = 32;
  var BENIGN_ERRORS = Object.freeze([
    "ResizeObserver loop completed with undelivered notifications.",
    "ResizeObserver loop limit exceeded"
  ]);
  var heard = (verb, args) => verb === "covered" ? args.rects : verb === "installed" ? args.tinctures : verb === "posture" ? args.posture : args.state;
  var CyfrError = class extends Error {
    constructor(message, code, stage) {
      super(message);
      this.name = "CyfrError";
      this.code = code;
      if (stage) this.stage = stage;
    }
  };
  var isPlainObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
  var unreadable = () => new CyfrError("The endpoint's answer could not be read.", "invalid_answer");
  var unreachable = () => new CyfrError("The endpoint could not be reached.", "unavailable");
  var unanswered = (status, rejection) => status >= 500 ? new CyfrError(rejection.code === "invalid_answer" ? unreachable().message : rejection.message, "unavailable") : rejection;
  function createClient({ win, fetchFn, base, handshakeTimeoutMs = HANDSHAKE_TIMEOUT_MS }) {
    const framed = win.parent !== win && win.parent !== null && win.parent !== void 0;
    const standalone = framed ? null : publicIdentity(win.location && win.location.pathname);
    let frame = null;
    let port = null;
    let credential = null;
    let kind = null;
    let canvas = null;
    let readyCalled = false;
    let failure = null;
    let prompt = null;
    const queued = [];
    const latest = /* @__PURE__ */ new Map();
    const handlers = new Map(CANVAS_EVENTS.map((event) => [event, /* @__PURE__ */ new Set()]));
    const unshown = [];
    let settle;
    const credentialArrived = new Promise((resolve) => {
      settle = resolve;
    });
    function onWindowMessage(event) {
      if (!framed || port !== null || event.source !== win.parent) return;
      const data = event.data;
      if (!isPlainObject(data) || data.v !== VERSION || data.type !== HANDSHAKE) return;
      if (!isFrameId(data.frame) || !event.ports || event.ports.length !== 1) return;
      frame = data.frame;
      port = event.ports[0];
      port.onmessage = onPortMessage;
    }
    function onPortMessage(event) {
      const data = event.data;
      if (!isPlainObject(data)) return;
      const closed = decodeCredentialClosed(data, frame);
      if (closed.ok) {
        const waiting = prompt;
        prompt = null;
        if (waiting) waiting({ saved: closed.saved });
        return;
      }
      const told = decodeToFrame(data);
      if (told.ok) {
        if (told.message.frame === frame) onTold(told.message);
        return;
      }
      if (data.v !== VERSION || data.type !== CREDENTIAL || data.frame !== frame) return;
      if (typeof data.credential !== "string" || data.credential === "") return;
      const first = credential === null;
      credential = data.credential;
      if (kind === null) known("frame");
      if (first) settle();
    }
    function onTold({ verb: told, args }) {
      if (told === "canvas") {
        if (kind !== null) return;
        canvas = { streams: new Set(args.streams.map(pairKey)) };
        return known("canvas");
      }
      if (kind !== "canvas") return;
      const value = heard(told, args);
      latest.set(told, value);
      if (told === "state" && value === "live") for (const resolve of unshown.splice(0)) resolve();
      for (const entry of handlers.get(told)) deliver(told, entry, value);
    }
    function shown() {
      return latest.get("state") === "live" ? Promise.resolve() : new Promise((resolve) => unshown.push(resolve));
    }
    function deliver(event, entry, value) {
      queueMicrotask(() => {
        if (handlers.get(event).has(entry)) entry.handler(value);
      });
    }
    function known(which) {
      kind = which;
      for (const [name, args] of queued.splice(0)) send(name, args);
    }
    function post(name, args) {
      port.postMessage(shellMessage(name, frame, args));
    }
    function send(name, args) {
      if (kind === "canvas" ? name === "ready" && failure === "load" : name === "press" || name === "failed") return;
      post(name, args);
    }
    function verb(name, args = {}) {
      if (!framed) return;
      if (kind !== null) send(name, args);
      else if (queued.length < MAX_QUEUED_VERBS || name === "failed") queued.push([name, args]);
    }
    function onPageError(event) {
      if (failure !== null) return;
      if (event && BENIGN_ERRORS.includes(event.message)) return;
      failure = readyCalled ? "runtime" : "load";
      verb("failed", { stage: failure });
    }
    function identity() {
      if (standalone) return Promise.resolve({ public: standalone });
      if (credential !== null) return Promise.resolve({ credential });
      if (!framed) {
        return Promise.reject(new CyfrError("This page is not a frame the shell opened.", "no_frame"));
      }
      return new Promise((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new CyfrError("The shell did not hand this frame its credential.", "no_frame")),
          handshakeTimeoutMs
        );
        credentialArrived.then(() => {
          clearTimeout(timer);
          resolve({ credential });
        });
      });
    }
    function routeOf(requestKind, fields) {
      if (canvas === null || requestKind !== "stream_open") return ROUTES[requestKind];
      if (!canvas.streams.has(pairKey({ name: fields.stream, subject: fields.subject }))) {
        throw new CyfrError("This canvas does not declare that stream.", "forbidden", "admission");
      }
      return streamPath(frame);
    }
    async function postRequest(requestKind, fields, signal) {
      let who = await identity();
      const path = routeOf(requestKind, fields);
      if (canvas !== null && requestKind === "stream_open") {
        await shown();
        who = await identity();
      }
      const headers = { "content-type": "application/json" };
      if (who.credential) headers[BEARER_HEADER] = bearer(who.credential);
      try {
        return await fetchFn(new URL(path, base).toString(), {
          method: "POST",
          headers,
          body: JSON.stringify(request(requestKind, fields, who.public || null)),
          credentials: "omit",
          cache: "no-store",
          redirect: "error",
          signal
        });
      } catch (_error) {
        throw unreachable();
      }
    }
    async function answer(requestKind, response) {
      let body;
      try {
        body = await response.json();
      } catch (_error) {
        throw unreadable();
      }
      const decoded = decodeAnswer(requestKind, body);
      if (decoded.ok) return decoded.value;
      if (decoded.refusal) {
        const { message, class: code, stage } = decoded.refusal;
        throw new CyfrError(message, code, stage);
      }
      throw unreadable();
    }
    async function call(requestKind, fields) {
      return answer(requestKind, await postRequest(requestKind, fields));
    }
    async function openStream(fields, onEvent) {
      const controller = new AbortController();
      const response = await postRequest("stream_open", fields, controller.signal);
      const type = (response.headers.get("content-type") || "").split(";")[0].trim();
      if (type !== STREAM_CONTENT_TYPE) {
        let rejection = unreadable();
        try {
          await answer("stream_open", response);
        } catch (error) {
          rejection = error;
        } finally {
          controller.abort();
        }
        throw unanswered(response.status, rejection);
      }
      const parser = sseParser((event) => {
        try {
          onEvent(event);
        } catch (_error) {
        }
      });
      let closing = false;
      const closed = (async () => {
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        try {
          for (; ; ) {
            const { done, value } = await reader.read();
            if (done) break;
            parser.push(decoder.decode(value, { stream: true }));
          }
          parser.push(decoder.decode());
        } catch (_error) {
          if (!closing) throw unreachable();
        } finally {
          parser.end();
        }
      })();
      closed.catch(() => {
      });
      return {
        /** Settles when the stream ends; rejects if the connection broke. */
        closed,
        /** End the stream: the request is aborted and no further event is delivered. */
        close() {
          closing = true;
          controller.abort();
        }
      };
    }
    const invalid = (sentence) => Promise.reject(new CyfrError(sentence, "invalid_argument"));
    const api = {
      /** The frame id the shell handed this frame, or null before the handshake. */
      get frame() {
        return frame;
      },
      /** The public tincture a top-level `/t/…` page names itself as, or null. */
      get public() {
        return standalone;
      },
      /**
       * Run an operation of a component the tincture declares.
       * @param {string} ref - a component reference, e.g. "c:local.weather:1.0.0"
       * @param {string} operation - the operation's name
       * @param {object} [args] - its arguments
       * @returns {Promise<any>} the result; a refusal rejects with a CyfrError
       */
      invoke(ref, operation, args = {}) {
        if (typeof ref !== "string" || ref === "") return invalid("ref must be a component reference");
        if (typeof operation !== "string" || operation === "") return invalid("operation must be a name");
        if (!isPlainObject(args)) return invalid("args must be an object");
        return call("invoke", { ref, operation, args });
      },
      /**
       * Run a system action the tincture declares.
       * @param {string} name - the action, "tool.action"
       * @param {object} [args] - its arguments
       */
      action(name, args = {}) {
        if (typeof name !== "string" || name === "") return invalid("an action is tool.action");
        if (!isPlainObject(args)) return invalid("args must be an object");
        return call("action", { operation: name, args });
      },
      /**
       * Open a stream the tincture declares and deliver its events. On a
       * canvas it opens on the canvas's data path, and a pair the canvas does
       * not declare is refused as `forbidden` before anything is sent; asked
       * for while the canvas is hidden, it sends nothing and opens once the
       * canvas is shown.
       * @param {string} name - the stream's name
       * @param {string|null} subject - a literal subject, or null for a stream that takes none
       * @param {function} onEvent - called with {id, event, data} per event
       * @returns {Promise<{close: function, closed: Promise}>} once the stream is open;
       *   a refusal rejects with a CyfrError of its class. An open the endpoint
       *   gave no answer on (it could not be reached, the connection broke or
       *   timed out, or it answered a server error) rejects `unavailable`, and
       *   may succeed if opened again later; opened again after any other
       *   refusal, it meets the same refusal until something changes.
       */
      stream(name, subject, onEvent) {
        if (typeof name !== "string" || name === "") return invalid("stream must be a stream name");
        if (subject !== null && typeof subject !== "string") {
          return invalid("subject must be a literal subject or null");
        }
        if (typeof onEvent !== "function") return invalid("onEvent must be a function");
        return openStream({ stream: name, subject }, onEvent);
      },
      /**
       * Ask the shell to open a tincture: a tincture reference, e.g. "t:local.weather".
       * From a canvas the shell acts on it only within moments of the person's
       * own input, never from a script on its own.
       */
      open(ref) {
        verb("open", { ref });
      },
      /**
       * On a canvas, press a feed's action: the binding id a `feed.results`
       * event carries, and the action's name. The shell acts on it only within
       * moments of the person's own input, never from a script on its own, and
       * only for a feed the canvas declares.
       */
      press(binding, action) {
        verb("press", { binding, action });
      },
      /**
       * On a canvas, hear what the shell tells it: `installed` (the installed
       * tinctures, `[{ref, name}]`), `posture` (`desk` or `hand`), `covered`
       * (the rects of it, `{x, y, width, height}` in its own pixels, that the
       * shown apps cover) or `state` (`live` or `frozen`). The latest value,
       * if one has come, is handed to a new handler first.
       * @returns {function} stops the handler hearing more
       */
      on(event, handler) {
        if (!CANVAS_EVENTS.includes(event)) throw new TypeError("cyfr.on takes installed, posture, covered or state");
        if (typeof handler !== "function") throw new TypeError("cyfr.on takes a function");
        const entry = { handler };
        handlers.get(event).add(entry);
        if (latest.has(event)) deliver(event, entry, latest.get(event));
        return () => {
          handlers.get(event).delete(entry);
        };
      },
      /** Close this frame. */
      close() {
        verb("close");
      },
      /** Set this frame's title. */
      title(title) {
        verb("title", { title });
      },
      /** Tell the shell the tincture is ready. */
      ready() {
        readyCalled = true;
        verb("ready");
      },
      /**
       * Ask the person for a secret through the shell's own prompt, stored in
       * the vault as the entry `name`. The frame never sees the value.
       * @param {string} name - the vault entry's name
       * @returns {Promise<{saved: boolean}>} once the prompt closes: whether an
       *   entry was saved, and nothing else. One prompt at a time: a second ask
       *   while one is open rejects as `pending`.
       */
      credential(name) {
        if (typeof name !== "string" || name === "") return invalid("a vault entry has a name");
        if (!framed) {
          return Promise.reject(new CyfrError("This page is not a frame the shell opened.", "no_frame"));
        }
        if (prompt !== null) {
          return Promise.reject(new CyfrError("A credential prompt is already open.", "pending"));
        }
        return new Promise((resolve) => {
          prompt = resolve;
          verb("credential", { name });
        });
      }
    };
    return { api: Object.freeze(api), onWindowMessage, onPageError };
  }

  // js/sdk/index.js
  var client = createClient({
    win: window,
    fetchFn: window.fetch.bind(window),
    base: document.baseURI
  });
  window.addEventListener("message", client.onWindowMessage);
  window.addEventListener("error", client.onPageError);
  window.addEventListener("unhandledrejection", client.onPageError);
  window.cyfr = client.api;
})();

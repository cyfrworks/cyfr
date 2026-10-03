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
  var VERBS = Object.freeze(["open", "close", "title", "ready", "credential"]);
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
  var isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
  var only = (object, keys) => Object.keys(object).every((key) => keys.includes(key));
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

  // js/sdk/client.js
  var HANDSHAKE_TIMEOUT_MS = 3e4;
  var MAX_QUEUED_VERBS = 32;
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
  function createClient({ win, fetchFn, base, handshakeTimeoutMs = HANDSHAKE_TIMEOUT_MS }) {
    const framed = win.parent !== win && win.parent !== null && win.parent !== void 0;
    const standalone = framed ? null : publicIdentity(win.location && win.location.pathname);
    let frame = null;
    let port = null;
    let credential = null;
    let prompt = null;
    const queued = [];
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
      for (const [verb2, args] of queued.splice(0)) post(verb2, args);
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
      if (credential !== null) return;
      if (data.v !== VERSION || data.type !== CREDENTIAL || data.frame !== frame) return;
      if (typeof data.credential !== "string" || data.credential === "") return;
      credential = data.credential;
      settle();
    }
    function post(verb2, args) {
      port.postMessage(shellMessage(verb2, frame, args));
    }
    function verb(name, args = {}) {
      if (!framed) return;
      if (port !== null) post(name, args);
      else if (queued.length < MAX_QUEUED_VERBS) queued.push([name, args]);
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
    async function postRequest(kind, fields, signal) {
      const who = await identity();
      const headers = { "content-type": "application/json" };
      if (who.credential) headers[BEARER_HEADER] = bearer(who.credential);
      try {
        return await fetchFn(new URL(ROUTES[kind], base).toString(), {
          method: "POST",
          headers,
          body: JSON.stringify(request(kind, fields, who.public || null)),
          credentials: "omit",
          cache: "no-store",
          redirect: "error",
          signal
        });
      } catch (_error) {
        throw unreachable();
      }
    }
    async function answer(kind, response) {
      let body;
      try {
        body = await response.json();
      } catch (_error) {
        throw unreadable();
      }
      const decoded = decodeAnswer(kind, body);
      if (decoded.ok) return decoded.value;
      if (decoded.refusal) {
        const { message, class: code, stage } = decoded.refusal;
        throw new CyfrError(message, code, stage);
      }
      throw unreadable();
    }
    async function send(kind, fields) {
      return answer(kind, await postRequest(kind, fields));
    }
    async function openStream(fields, onEvent) {
      const controller = new AbortController();
      const response = await postRequest("stream_open", fields, controller.signal);
      const type = (response.headers.get("content-type") || "").split(";")[0].trim();
      if (type !== STREAM_CONTENT_TYPE) {
        try {
          await answer("stream_open", response);
        } finally {
          controller.abort();
        }
        throw unreadable();
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
        return send("invoke", { ref, operation, args });
      },
      /**
       * Run a system action the tincture declares.
       * @param {string} name - the action, "tool.action"
       * @param {object} [args] - its arguments
       */
      action(name, args = {}) {
        if (typeof name !== "string" || name === "") return invalid("an action is tool.action");
        if (!isPlainObject(args)) return invalid("args must be an object");
        return send("action", { operation: name, args });
      },
      /**
       * Open a stream the tincture declares and deliver its events.
       * @param {string} name - the stream's name
       * @param {string|null} subject - a literal subject, or null for a stream that takes none
       * @param {function} onEvent - called with {id, event, data} per event
       * @returns {Promise<{close: function, closed: Promise}>} once the stream is open;
       *   a refusal rejects with a CyfrError
       */
      stream(name, subject, onEvent) {
        if (typeof name !== "string" || name === "") return invalid("stream must be a stream name");
        if (subject !== null && typeof subject !== "string") {
          return invalid("subject must be a literal subject or null");
        }
        if (typeof onEvent !== "function") return invalid("onEvent must be a function");
        return openStream({ stream: name, subject }, onEvent);
      },
      /** Ask the shell to open a tincture: a tincture reference, e.g. "t:local.weather". */
      open(ref) {
        verb("open", { ref });
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
    return { api: Object.freeze(api), onWindowMessage };
  }

  // js/sdk/index.js
  var client = createClient({
    win: window,
    fetchFn: window.fetch.bind(window),
    base: document.baseURI
  });
  window.addEventListener("message", client.onWindowMessage);
  window.cyfr = client.api;
})();

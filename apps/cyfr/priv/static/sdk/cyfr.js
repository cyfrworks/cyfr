// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
// Built from apps/cyfr/assets/js/sdk by `mix esbuild sdk`.
(() => {
  var __defProp = Object.defineProperty;
  var __defProps = Object.defineProperties;
  var __getOwnPropDescs = Object.getOwnPropertyDescriptors;
  var __getOwnPropSymbols = Object.getOwnPropertySymbols;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __propIsEnum = Object.prototype.propertyIsEnumerable;
  var __defNormalProp = (obj, key, value) => key in obj ? __defProp(obj, key, { enumerable: true, configurable: true, writable: true, value }) : obj[key] = value;
  var __spreadValues = (a, b) => {
    for (var prop in b || (b = {}))
      if (__hasOwnProp.call(b, prop))
        __defNormalProp(a, prop, b[prop]);
    if (__getOwnPropSymbols)
      for (var prop of __getOwnPropSymbols(b)) {
        if (__propIsEnum.call(b, prop))
          __defNormalProp(a, prop, b[prop]);
      }
    return a;
  };
  var __spreadProps = (a, b) => __defProps(a, __getOwnPropDescs(b));

  // js/sdk/wire.js
  var VERSION = 1;
  var BEARER_HEADER = "authorization";
  var ROUTES = Object.freeze({
    invoke: "/_f/v1/invoke",
    action: "/_f/v1/action"
  });
  var VERBS = Object.freeze([
    "open",
    "close",
    "title",
    "ready",
    "credential",
    "press",
    "failed",
    "grant",
    "prefs",
    "ask",
    "settings",
    "request"
  ]);
  var CANVAS_VERBS = Object.freeze(["press", "failed", "grant", "prefs", "ask", "settings"]);
  var PERSON_VERBS = Object.freeze(["open", "press", "grant", "prefs", "ask", "settings", "request"]);
  var SUBJECT_KINDS = Object.freeze(["run", "thread", "schedule", "component", "file"]);
  var PRESS_OUTCOMES = Object.freeze(["accepted", "refused", "cancelled"]);
  var PREFS_OUTCOMES = Object.freeze(["saved", "stale", "refused", "cancelled"]);
  var CANCEL_REASONS = Object.freeze(["too_soon"]);
  var REQUEST_OUTCOMES = Object.freeze(["approved", "refused", "cancelled"]);
  var REQUEST_CANCEL_REASONS = Object.freeze(["too_soon", "busy", "expired", "dismissed"]);
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
  var COMPONENT_REF = /^(c|catalyst|r|reagent|f|formula|t|tincture):\S+$/;
  var DESKTOP_ID = /^[a-z][a-z0-9_-]{0,62}$/;
  var SUBJECT_ID = /^[A-Za-z0-9][A-Za-z0-9_.:@/-]{0,255}$/;
  var OPERATION = /^[a-z][a-z0-9_-]{0,62}\.[a-z][a-z0-9_-]{0,62}$/;
  var GRANT_OPERATION = "grant";
  var REQUEST_ID = /^req_[A-Za-z0-9_-]{16,64}$/;
  var MAX_PRESS_VALUE = 256;
  var MAX_CALL = 2147483647;
  var ACCENT = /^#[0-9a-f]{6}$/;
  var LOCALE = /^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8}){0,7}$/;
  var TIME_ZONE = /^[A-Za-z][A-Za-z0-9_+-]{0,31}(\/[A-Za-z0-9][A-Za-z0-9_+-]{0,31}){0,2}$/;
  var APPEARANCE_MODES = ["light", "dark"];
  var MAX_SAFE_AREA = 512;
  var MAX_PERSON_NAME = 128;
  var REFUSAL_CLASS = /^[a-z][a-z_]{0,63}$/;
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
  var codePointCount = (value) => Array.from(value).length;
  var isControl = (character) => {
    const code = character.codePointAt(0);
    return code <= 31 || code >= 127 && code <= 159;
  };
  var isBoundedText = (value, max) => isText(value) && value !== "" && codePointCount(value) <= max && !Array.from(value).some(isControl);
  var isDesktopId = (id) => typeof id === "string" && DESKTOP_ID.test(id);
  var isPressValue = (value) => isBoundedText(value, MAX_PRESS_VALUE);
  var isCall = (call) => Number.isInteger(call) && call >= 1 && call <= MAX_CALL;
  var isGrantArgs = (args) => isObject(args) && sameKeys(args, ["ref"]) && typeof args.ref === "string" && COMPONENT_REF.test(args.ref);
  var isRequest = (operation, args) => operation === GRANT_OPERATION ? isGrantArgs(args) : typeof operation === "string" && OPERATION.test(operation) && isObject(args);
  var isSubject = (subject) => isObject(subject) && sameKeys(subject, ["kind", "id"]) && SUBJECT_KINDS.includes(subject.kind) && typeof subject.id === "string" && SUBJECT_ID.test(subject.id);
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
      default:
        throw new TypeError("unknown request kind: " + kind);
    }
    if (publicIdentity2) body.public = publicIdentity2;
    return body;
  }
  var ATHANOR_SEGMENT = /^@[a-z0-9]+(-[a-z0-9]+)*$/;
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
  var isRefusal = (error) => isObject(error) && sameKeys(error, ["class", "message", "stage"]) && typeof error.class === "string" && error.class !== "" && typeof error.message === "string" && (error.stage === "admission" || error.stage === "execution");
  function decodeAnswer(kind, body) {
    const invalid = { ok: false, invalid: true };
    if (!isObject(body) || body.v !== VERSION || !(kind in ROUTES)) return invalid;
    if (sameKeys(body, ["v", "ok", "result"]) && body.ok === true) return { ok: true, value: body.result };
    if (sameKeys(body, ["v", "ok", "error"]) && body.ok === false && isRefusal(body.error)) {
      const { class: cls, message, stage } = body.error;
      return { ok: false, refusal: { class: cls, message, stage } };
    }
    return invalid;
  }
  var SOCKET_PATH = "/_f/v1/socket";
  var CLOSE_CODES = Object.freeze({ unreadable: 4400, too_big: 1009, replaced: 4409, idle: 1e3 });
  var REFUSAL_EVENT = "refusal";
  var DELIVERY_EVENTS = Object.freeze(["snapshot", "resync", "unavailable", "stale", "denied"]);
  var STREAM_STATES = Object.freeze(["live", "unavailable", "suspended", "stale", "denied", "ended"]);
  var ENDED_REASONS = Object.freeze(["frame_suspended"]);
  var NO_ANSWER_CLASSES = Object.freeze([
    "cancelled",
    "corrupt",
    "internal",
    "setup_required",
    "timeout",
    "uncertain",
    "unavailable"
  ]);
  function subscribeMessage(sub, credential, stream, subject) {
    return { v: VERSION, type: "subscribe", sub, credential, stream, subject };
  }
  function unsubscribeMessage(sub) {
    return { v: VERSION, type: "unsubscribe", sub };
  }
  var isEvent = ({ stream, subject, id }) => typeof stream === "string" && (subject === null || typeof subject === "string") && (id === null || Number.isInteger(id) && id >= 0);
  var isTime = (at) => typeof at === "string" && at !== "" && !Number.isNaN(Date.parse(at));
  function decodeConnectionMessage(message) {
    if (!isObject(message) || message.v !== VERSION || !isCall(message.sub)) return { ok: false };
    const head = ["v", "type", "sub"];
    let read;
    switch (message.type) {
      case "subscribed":
        read = sameKeys(message, head);
        break;
      case "event":
        read = sameKeys(message, [...head, "stream", "subject", "id", "data"]) && isEvent(message);
        break;
      case "snapshot":
      case "stale":
        read = sameKeys(message, [...head, "at"]) && isTime(message.at);
        break;
      case "resync":
        read = sameKeys(message, head);
        break;
      case "ended":
        read = sameKeys(message, head) || sameKeys(message, [...head, "error"]) && isRefusal(message.error) || sameKeys(message, [...head, "error", "reason"]) && isRefusal(message.error) && ENDED_REASONS.includes(message.reason);
        break;
      default:
        read = false;
    }
    return read ? { ok: true, message } : { ok: false };
  }
  function shellMessage(verb, frame, args = {}) {
    if (!VERBS.includes(verb)) throw new TypeError("unknown shell verb: " + verb);
    return { v: VERSION, verb, frame, args };
  }
  var DATA_PREFIX = "/_f/v1/o/";
  var SOCKET_ROUTE = "socket";
  function dataPath(frame) {
    if (!isFrameId(frame)) throw new TypeError("a frame id is 8 to 64 URL-safe characters");
    return DATA_PREFIX + frame + "/";
  }
  function socketPath(frame) {
    return dataPath(frame) + SOCKET_ROUTE;
  }
  var MODES = Object.freeze(["live", "validation"]);
  var TO_FRAME_VERBS = Object.freeze([
    "canvas",
    "posture",
    "covered",
    "installed",
    "state",
    "pressed",
    "prefs",
    "requested",
    "decided",
    "subject"
  ]);
  var TOLD_VERBS = Object.freeze(["posture", "covered", "installed", "state"]);
  var ANSWER_OF = Object.freeze({
    press: Object.freeze(["pressed", "requested", "decided"]),
    prefs: Object.freeze(["prefs"]),
    request: Object.freeze(["requested", "decided"])
  });
  var ANSWER_VERBS = Object.freeze([...new Set(Object.values(ANSWER_OF).flat())]);
  var CANVAS_EVENTS = Object.freeze(["installed", "posture", "covered", "state", "desktop", "subject"]);
  var POSTURES = ["desk", "hand"];
  var SHELL_STATES = ["live", "frozen"];
  var MAX_STREAMS = 64;
  var MAX_RECTS = 64;
  var RECT_KEYS = ["x", "y", "width", "height"];
  var MAX_TINCTURES = 512;
  var MAX_NAME = 128;
  var MAX_ICON = 16;
  var pairKey = ({ name, subject }) => JSON.stringify([name, subject]);
  var bounded = (list, max, each) => Array.isArray(list) && list.length <= max && list.every(each);
  var isStream = (stream) => isObject(stream) && sameKeys(stream, ["name", "subject"]) && typeof stream.name === "string" && STREAM_NAME.test(stream.name) && (stream.subject === null || isText(stream.subject));
  var isStreams = (streams) => bounded(streams, MAX_STREAMS, isStream) && new Set(streams.map(pairKey)).size === streams.length;
  var isRect = (rect) => isObject(rect) && sameKeys(rect, RECT_KEYS) && RECT_KEYS.every((key) => typeof rect[key] === "number" && Number.isFinite(rect[key]) && rect[key] >= 0);
  var codePoints = (value) => Array.from(value).length;
  var isIcon = (icon) => icon === null || isText(icon) && codePoints(icon) >= 1 && codePoints(icon) <= MAX_ICON;
  var isInstalled = (tincture) => isObject(tincture) && sameKeys(tincture, ["ref", "name", "icon", "open"]) && isTinctureRef(tincture.ref) && isText(tincture.name) && codePoints(tincture.name) >= 1 && codePoints(tincture.name) <= MAX_NAME && isIcon(tincture.icon) && typeof tincture.open === "boolean";
  var isRevision = (revision) => Number.isInteger(revision) && revision >= 0;
  var isPrefs = (prefs) => isObject(prefs) && sameKeys(prefs, ["document", "revision"]) && isObject(prefs.document) && isRevision(prefs.revision);
  var SIDES = ["top", "right", "bottom", "left"];
  var isSafeAreas = (areas) => isObject(areas) && sameKeys(areas, SIDES) && SIDES.every((side) => Number.isInteger(areas[side]) && areas[side] >= 0 && areas[side] <= MAX_SAFE_AREA);
  var isAppearance = (appearance) => isObject(appearance) && sameKeys(appearance, ["mode", "accent", "locale", "time_zone", "safe_areas"]) && APPEARANCE_MODES.includes(appearance.mode) && typeof appearance.accent === "string" && ACCENT.test(appearance.accent) && typeof appearance.locale === "string" && appearance.locale.length <= 64 && LOCALE.test(appearance.locale) && typeof appearance.time_zone === "string" && TIME_ZONE.test(appearance.time_zone) && isSafeAreas(appearance.safe_areas);
  var isPerson = (person) => isObject(person) && sameKeys(person, ["name"]) && (person.name === null || isBoundedText(person.name, MAX_PERSON_NAME));
  var CANVAS_KEYS = ["mode", "data_path", "streams", "prefs", "appearance", "person"];
  function canvasError(block, frame) {
    if (!isObject(block) || !sameKeys(block, CANVAS_KEYS)) {
      return "a canvas is exactly mode, data_path, streams, prefs, appearance and person";
    }
    if (!MODES.includes(block.mode)) return "a canvas's mode is live or validation";
    if (block.data_path !== dataPath(frame)) return "a canvas's data path is its frame's";
    if (!isStreams(block.streams)) {
      return `a canvas names at most ${MAX_STREAMS} distinct streams of name and subject`;
    }
    if (!isPrefs(block.prefs)) return "a canvas's prefs are exactly a document and its revision";
    if (!isAppearance(block.appearance)) {
      return "a canvas's appearance is exactly mode, accent, locale, time_zone and safe_areas";
    }
    if (!isPerson(block.person)) return "a canvas's person is exactly a name, or none";
    return null;
  }
  var isOutcome = (args, outcomes, cancelReasons = CANCEL_REASONS) => {
    if (!outcomes.includes(args.outcome)) return false;
    if (args.outcome === "refused") return typeof args.reason === "string" && REFUSAL_CLASS.test(args.reason);
    if (args.outcome === "cancelled") return !("reason" in args) || cancelReasons.includes(args.reason);
    return !("reason" in args);
  };
  var withReason = (args, keys) => "reason" in args ? [...keys, "reason"] : keys;
  function pressedError(args) {
    const keys = withReason(args, ["control", "call", "outcome"]);
    return sameKeys(args, keys) && isDesktopId(args.control) && isCall(args.call) && isOutcome(args, PRESS_OUTCOMES) ? null : "pressed is exactly a control, its call and its outcome, with a reason when refused or cancelled too soon";
  }
  function prefsAnswerError(args) {
    const keys = withReason(args, ["call", "outcome", "document", "revision"]);
    return sameKeys(args, keys) && isCall(args.call) && isObject(args.document) && isRevision(args.revision) && isOutcome(args, PREFS_OUTCOMES) ? null : "prefs is exactly a call, an outcome, a document and its revision, with a reason when refused or cancelled too soon";
  }
  function decidedError(args) {
    return sameKeys(args, withReason(args, ["call", "outcome"])) && isCall(args.call) && isOutcome(args, REQUEST_OUTCOMES, REQUEST_CANCEL_REASONS) ? null : "decided is exactly a call and its outcome, with a reason when refused and perhaps when cancelled";
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
        return sameKeys(args, ["tinctures"]) && bounded(args.tinctures, MAX_TINCTURES, isInstalled) ? null : `installed names at most ${MAX_TINCTURES} tinctures of ref, name, icon and open`;
      case "state":
        return sameKeys(args, ["state"]) && SHELL_STATES.includes(args.state) ? null : "state is live or frozen";
      case "pressed":
        return pressedError(args);
      case "prefs":
        return prefsAnswerError(args);
      case "requested":
        return sameKeys(args, ["call", "request"]) && isCall(args.call) && typeof args.request === "string" && REQUEST_ID.test(args.request) ? null : "requested is exactly a call and its request's id";
      case "decided":
        return decidedError(args);
      case "subject":
        return isSubject(args) ? null : "subject is exactly a kind and an id";
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
  var REOPEN_FIRST_MS = 1e3;
  var REOPEN_MOST_MS = 3e4;
  var ANSWER_TIMEOUT_MS = 3e4;
  var DECISION_TIMEOUT_MS = 10 * 60 * 1e3;
  var BINDING_ID = /^feed_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
  var ACTION_NAME = /^[a-z0-9][a-z0-9-]{0,47}$/;
  var BENIGN_ERRORS = Object.freeze([
    "ResizeObserver loop completed with undelivered notifications.",
    "ResizeObserver loop limit exceeded"
  ]);
  var heard = (verb, args) => verb === "covered" ? args.rects : verb === "installed" ? args.tinctures : verb === "posture" ? args.posture : args.state;
  var UNCERTAIN = Object.freeze({ outcome: "refused", reason: "uncertain" });
  var CANCELLED = Object.freeze({ outcome: "cancelled" });
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
  var noFrame = () => new CyfrError("This page is not a frame the shell opened.", "no_frame");
  var refusedOpen = (error) => error === null ? unreachable() : NO_ANSWER_CLASSES.includes(error.class) ? new CyfrError(error.message, "unavailable") : new CyfrError(error.message, error.class, error.stage);
  var SOCKET_SCHEMES = Object.freeze({ "http:": "ws:", "https:": "wss:" });
  function createClient({
    win,
    fetchFn,
    socketFn = (url) => new win.WebSocket(url),
    base,
    handshakeTimeoutMs = HANDSHAKE_TIMEOUT_MS
  }) {
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
    const withheld = /* @__PURE__ */ new Set();
    let connection = null;
    let nextSubscription = 1;
    let desktop = null;
    let subject = null;
    let nextCall = 1;
    const calls = /* @__PURE__ */ new Map();
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
      const told2 = decodeToFrame(data);
      if (told2.ok) {
        if (told2.message.frame === frame) onTold(told2.message);
        return;
      }
      if (data.v !== VERSION || data.type !== CREDENTIAL || data.frame !== frame) return;
      if (typeof data.credential !== "string" || data.credential === "") return;
      const first = credential === null;
      credential = data.credential;
      if (kind === null) known("frame");
      if (first) settle();
    }
    function onTold({ verb: told2, args }) {
      if (told2 === "subject") {
        if (kind === "canvas") return;
        subject = Object.freeze({ kind: args.kind, id: args.id });
        if (kind === null) return;
        latest.set("subject", subject);
        for (const entry of handlers.get("subject")) deliver("subject", entry, subject);
        return;
      }
      if (told2 === "canvas") {
        if (kind !== null) return;
        canvas = { streams: new Set(args.streams.map(pairKey)) };
        desktop = { prefs: args.prefs, appearance: args.appearance, person: args.person };
        known("canvas");
        return tellDesktop();
      }
      if (told2 === "requested") return asked(args.call, args.request);
      if (told2 === "decided") return answered(told2, args.call, answerOf(args));
      if (kind !== "canvas") return;
      if (told2 === "pressed") return answered(told2, args.call, answerOf(args));
      if (told2 === "prefs") {
        const settle2 = take(told2, args.call);
        if (!settle2) return;
        desktop = __spreadProps(__spreadValues({}, desktop), { prefs: { document: args.document, revision: args.revision } });
        tellDesktop();
        return settle2(answerOf(args));
      }
      const value = heard(told2, args);
      latest.set(told2, value);
      if (told2 === "state" && value === "live") {
        for (const resolve of unshown.splice(0)) resolve();
        thawed();
      }
      for (const entry of handlers.get(told2)) deliver(told2, entry, value);
    }
    function tellDesktop() {
      const value = desktopValue();
      latest.set("desktop", value);
      for (const entry of handlers.get("desktop")) deliver("desktop", entry, value);
    }
    function desktopValue() {
      return desktop === null ? null : Object.freeze(__spreadValues({}, desktop));
    }
    function answerOf(args) {
      const answer = { outcome: args.outcome };
      if ("reason" in args) answer.reason = args.reason;
      if ("document" in args) Object.assign(answer, { document: args.document, revision: args.revision });
      return Object.freeze(answer);
    }
    function answered(verb2, call2, answer) {
      const settle2 = take(verb2, call2);
      if (settle2) settle2(answer);
    }
    function take(verb2, call2) {
      const waiting = calls.get(call2);
      if (!waiting || !waiting.answers.includes(verb2)) return null;
      calls.delete(call2);
      return waiting.settle;
    }
    function asked(call2, request2) {
      const waiting = calls.get(call2);
      if (!waiting || !waiting.answers.includes("requested") || waiting.asked) return;
      waiting.asked = true;
      waiting.requested(request2);
    }
    function awaitAnswer(name, args, onRequested = () => {
    }) {
      const call2 = nextCall++;
      return new Promise((resolve) => {
        let timer = null;
        const settle2 = (answer) => {
          clearTimeout(timer);
          onRequested(null);
          resolve(answer);
        };
        const wait = (ms) => {
          clearTimeout(timer);
          timer = setTimeout(() => {
            calls.delete(call2);
            settle2(UNCERTAIN);
          }, ms);
        };
        wait(ANSWER_TIMEOUT_MS);
        calls.set(call2, {
          answers: ANSWER_OF[name],
          asked: false,
          requested: (request2) => {
            wait(DECISION_TIMEOUT_MS);
            onRequested(request2);
          },
          settle: settle2
        });
        verb(name, __spreadProps(__spreadValues({}, args), { call: call2 }));
      });
    }
    function requestHandle(decision, requested) {
      decision.requested = requested;
      return decision;
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
      if (kind === "canvas" ? name === "ready" && failure === "load" : CANVAS_VERBS.includes(name)) {
        if (name === "press" && "control" in args) answered("pressed", args.call, CANCELLED);
        if (name === "prefs") answered("prefs", args.call, CANCELLED);
        return;
      }
      post(name, args);
    }
    function verb(name, args = {}) {
      if (!framed) return;
      if (kind !== null) send(name, args);
      else if (queued.length < MAX_QUEUED_VERBS || name === "failed") queued.push([name, args]);
    }
    function onPageError(event) {
      if (failure !== null || readyCalled) return;
      if (event && BENIGN_ERRORS.includes(event.message)) return;
      failure = "load";
      verb("failed", { stage: failure });
    }
    function identity() {
      if (standalone) return Promise.resolve({ public: standalone });
      if (credential !== null) return Promise.resolve({ credential });
      if (!framed) return Promise.reject(noFrame());
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
    async function call(requestKind, fields) {
      const who = await identity();
      const headers = { "content-type": "application/json" };
      if (who.credential) headers[BEARER_HEADER] = bearer(who.credential);
      let response;
      try {
        response = await fetchFn(new URL(ROUTES[requestKind], base).toString(), {
          method: "POST",
          headers,
          body: JSON.stringify(request(requestKind, fields, who.public || null)),
          credentials: "omit",
          cache: "no-store",
          redirect: "error"
        });
      } catch (_error) {
        throw unreachable();
      }
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
    function subscribe(name, subject2, onEvent) {
      const subscription = {
        name,
        subject: subject2,
        onEvent,
        state: "waiting",
        held: null,
        number: null,
        sent: false,
        delivery: "live",
        opened: false,
        tries: 0,
        timer: null,
        missed: false,
        last: null
      };
      const opened = new Promise((resolve, reject) => Object.assign(subscription, { resolve, reject }));
      const closed = new Promise((resolve, reject) => subscription.closed = { resolve, reject });
      closed.catch(() => {
      });
      const close = () => unsubscribe(subscription);
      subscription.handle = {
        /** Settles when the stream ends; rejects if the connection broke. */
        closed,
        /** End the stream: nothing more of it is delivered. */
        close,
        /**
         * On a canvas, the stream's state: `live`, `unavailable` (it opens
         * again at the time its last `unavailable` event named), `suspended`
         * (the canvas is hidden; it opens again once shown), `stale`,
         * `denied` or `ended`.
         */
        get state() {
          return subscription.delivery;
        }
      };
      sendable(subscription).then(
        () => attach(subscription),
        (error) => refuse(subscription, error)
      );
      opened.close = close;
      return opened;
    }
    async function sendable({ name, subject: subject2 }) {
      if (!framed) throw noFrame();
      await identity();
      if (canvas === null) return;
      if (!canvas.streams.has(pairKey({ name, subject: subject2 }))) {
        throw new CyfrError("This canvas does not declare that stream.", "forbidden", "admission");
      }
      await shown();
    }
    function refuse(subscription, error) {
      if (subscription.state !== "waiting") return;
      if (subscription.opened) return deny(subscription, { class: error.code, message: error.message, stage: error.stage || "admission" });
      subscription.state = "over";
      subscription.reject(error);
    }
    function attach(subscription) {
      if (subscription.state !== "waiting") return;
      subscription.missed = false;
      let held;
      try {
        held = connect();
      } catch (_error) {
        if (subscription.opened) return reopen(subscription);
        return refuse(subscription, unreachable());
      }
      subscription.state = "asked";
      subscription.held = held;
      subscription.number = nextSubscription++;
      held.subscriptions.set(subscription.number, subscription);
      if (held.open) ask(held, subscription);
    }
    function connect() {
      if (connection !== null) return connection;
      const url = new URL(canvas !== null ? socketPath(frame) : SOCKET_PATH, base);
      url.protocol = SOCKET_SCHEMES[url.protocol] || url.protocol;
      const held = { socket: socketFn(url.toString()), open: false, subscriptions: /* @__PURE__ */ new Map() };
      held.socket.onopen = () => {
        held.open = true;
        for (const subscription of held.subscriptions.values()) ask(held, subscription);
      };
      held.socket.onmessage = (event) => onConnectionMessage(held, event.data);
      held.socket.onclose = (event) => lost(held, event && event.code);
      held.socket.onerror = () => lost(held);
      connection = held;
      return held;
    }
    function ask(held, subscription) {
      const { number, name, subject: subject2 } = subscription;
      subscription.sent = true;
      held.socket.send(JSON.stringify(subscribeMessage(number, credential, name, subject2)));
    }
    function onConnectionMessage(held, data) {
      let message;
      try {
        message = JSON.parse(data);
      } catch (_error) {
        return;
      }
      const decoded = decodeConnectionMessage(message);
      const subscription = decoded.ok ? held.subscriptions.get(decoded.message.sub) : void 0;
      if (subscription === void 0) return;
      if (message.type === "subscribed") {
        if (subscription.state !== "asked") return;
        subscription.state = "open";
        subscription.delivery = "live";
        if (subscription.opened) return told(subscription, "resync");
        subscription.opened = true;
        subscription.resolve(subscription.handle);
      } else if (message.type === "event") {
        if (subscription.state === "open") hear(subscription, heardEvent(message));
      } else if (message.type === "ended") {
        held.subscriptions.delete(subscription.number);
        if (message.reason === "frame_suspended" && canvas !== null && subscription.opened) return suspend(subscription);
        end(subscription, "error" in message ? message.error : null, null);
      } else if (subscription.state === "open" && canvas !== null) {
        if (message.type === "snapshot") Object.assign(subscription, { delivery: "live", tries: 0 });
        if (message.type === "stale") subscription.delivery = "stale";
        told(subscription, message.type, null, "at" in message ? message.at : null);
      }
    }
    function heardEvent({ id, stream, data }) {
      if (canvas === null) return { id, event: stream, data };
      const revision = isPlainObject(data) && Number.isInteger(data.revision) ? data.revision : null;
      const at = isPlainObject(data) && typeof data.at === "string" ? data.at : null;
      return { id, event: stream, data, revision, at };
    }
    function told(subscription, name, data = null, at = null) {
      hear(subscription, { id: null, event: name, data, revision: null, at });
    }
    function lost(held, code) {
      if (connection === held) connection = null;
      const carried = [...held.subscriptions.values()];
      held.subscriptions.clear();
      const final = [CLOSE_CODES.unreadable, CLOSE_CODES.too_big, CLOSE_CODES.replaced].includes(code);
      for (const subscription of carried) {
        if (final && subscription.opened) {
          Object.assign(subscription, { state: "over", delivery: "ended" });
          subscription.closed.reject(unreachable());
        } else {
          end(subscription, null, unreachable());
        }
      }
    }
    function end(subscription, error, broke) {
      const was = subscription.state;
      subscription.state = "over";
      if (canvas !== null && subscription.opened) {
        if (broke !== null || error !== null && NO_ANSWER_CLASSES.includes(error.class)) return reopen(subscription);
        if (error === null && was === "asked") return reopen(subscription);
        if (error !== null) return deny(subscription, error);
        subscription.delivery = "ended";
        return subscription.closed.resolve();
      }
      if (was === "asked") return subscription.reject(broke || refusedOpen(error));
      subscription.delivery = "ended";
      if (error !== null) hear(subscription, { id: null, event: REFUSAL_EVENT, data: error });
      if (broke) subscription.closed.reject(broke);
      else subscription.closed.resolve();
    }
    function deny(subscription, error) {
      subscription.state = "over";
      subscription.delivery = "denied";
      told(subscription, "denied", error);
      subscription.closed.resolve();
    }
    function reopen(subscription) {
      const wait = later(subscription, "unavailable");
      told(subscription, "unavailable", { retry_at: new Date(Date.now() + wait).toISOString() });
    }
    function suspend(subscription) {
      later(subscription, "suspended");
    }
    function later(subscription, delivery) {
      const wait = Math.min(REOPEN_FIRST_MS * 2 ** subscription.tries, REOPEN_MOST_MS);
      subscription.tries += 1;
      Object.assign(subscription, { state: "waiting", held: null, number: null, sent: false, delivery });
      subscription.timer = setTimeout(() => {
        subscription.timer = null;
        if (subscription.state !== "waiting") return;
        sendable(subscription).then(
          () => attach(subscription),
          (error) => refuse(subscription, error)
        );
      }, wait);
      return wait;
    }
    function hear(subscription, event) {
      if (canvas !== null && latest.get("state") === "frozen") {
        if (subscription.state === "over") subscription.last = event;
        else subscription.missed = true;
        withheld.add(subscription);
        return;
      }
      try {
        subscription.onEvent(event);
      } catch (_error) {
      }
    }
    function thawed() {
      for (const subscription of [...withheld]) {
        withheld.delete(subscription);
        if (subscription.state === "over" && subscription.last) {
          const last = subscription.last;
          subscription.last = null;
          hear(subscription, last);
        } else if (subscription.state === "open" && subscription.missed) {
          const { held, number } = subscription;
          held.subscriptions.delete(number);
          held.socket.send(JSON.stringify(unsubscribeMessage(number)));
          Object.assign(subscription, { state: "waiting", held: null, number: null, sent: false });
          attach(subscription);
        }
      }
    }
    function unsubscribe(subscription) {
      const was = subscription.state;
      subscription.last = null;
      if (was === "over") return;
      subscription.state = "over";
      subscription.delivery = "ended";
      if (subscription.timer !== null) clearTimeout(subscription.timer);
      if (subscription.held !== null) {
        subscription.held.subscriptions.delete(subscription.number);
        if (subscription.sent) subscription.held.socket.send(JSON.stringify(unsubscribeMessage(subscription.number)));
      }
      if (was === "open" || subscription.opened) subscription.closed.resolve();
      else subscription.reject(new CyfrError("The stream was closed before it opened.", "cancelled"));
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
       * On a canvas, its desktop as the shell told it: `prefs` (the person's
       * preferences document for this canvas and its `revision`),
       * `appearance` (`mode`, `accent`, `locale`, `time_zone`, `safe_areas`)
       * and `person` (`name`, their display name, or null). Null until the
       * canvas's open arrives; `cyfr.on("desktop", …)` hears it then and
       * after each write.
       */
      get desktop() {
        return desktopValue();
      },
      /**
       * On an app opened on a subject, that subject, `{kind, id}`, or null;
       * an app opened again on another hears it through `cyfr.on("subject")`.
       */
      get subject() {
        return subject;
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
       * Open a stream the tincture declares and deliver its events, over the
       * frame's one stream connection. On a canvas, a pair the canvas does
       * not declare is refused as `forbidden` before anything is sent; asked
       * for while the canvas is hidden, it sends nothing and opens once the
       * canvas is shown. A page that is not a frame, a public page among
       * them, opens no stream: it is refused as `no_frame`.
       * @param {string} name - the stream's name
       * @param {string|null} subject - a literal subject, or null for a stream that takes none
       * @param {function} onEvent - called with {id, event, data} per event; a stream the
       *   endpoint ends with a refusal delivers it last, as {id: null, event: "refusal", data}.
       *   On a canvas, a stream keeps the delivery contract (`Compendium.Canvas.catalog`):
       *   each event also carries the change's `revision` and `at`, and the handler hears
       *   `snapshot` (`at`, its picture is whole), `resync` (a fresh picture follows and
       *   replaces it), `stale` (`at`, the picture's time), `unavailable` (`data.retry_at`,
       *   when the SDK opens it again, after a lost connection or an end for want of an
       *   answer) and `denied` (`data`, the refusal; the stream ended), each as
       *   {id: null, event, data, revision: null, at}. A stream open when the canvas is
       *   hidden hears nothing while it is hidden, its handle's state `suspended`, and
       *   opens again once the canvas is shown, its fresh picture announced by `resync`
       * @returns {Promise<{close: function, closed: Promise, state: string}>} once the stream is open,
       *   carrying `close()` itself, the handle's: closed before it opened, the
       *   promise rejects `cancelled`. A refusal rejects with a CyfrError of
       *   its class. An open that got no answer (the connection could not
       *   open, or broke or closed before an answer, or the endpoint could not
       *   answer) rejects `unavailable`, and may succeed if opened again later;
       *   opened again after any other refusal, it meets the same refusal
       *   until something changes.
       */
      stream(name, subject2, onEvent) {
        if (typeof name !== "string" || name === "") return invalid("stream must be a stream name");
        if (subject2 !== null && typeof subject2 !== "string") {
          return invalid("subject must be a literal subject or null");
        }
        if (typeof onEvent !== "function") return invalid("onEvent must be a function");
        return subscribe(name, subject2, onEvent);
      },
      /**
       * Ask the shell to open a tincture: a tincture reference, e.g.
       * "t:local.weather", and optionally what to open it on, `{kind, id}`,
       * a kind the app declares in `tincture.subjects` (run, thread,
       * schedule, component or file). The app is handed the subject at its
       * open (`cyfr.subject`); opening it does nothing more. From a canvas
       * the shell acts on it only for an input of the person's, never from a
       * script on its own.
       */
      open(ref, on = null) {
        if (on !== null && !isSubject(on)) return;
        verb("open", on === null ? { ref } : { ref, subject: on });
      },
      /**
       * On a canvas, press a control it declares: the control's id, and for
       * a control with a pick the value picked, one the picked stream
       * publishes. The shell runs it as the person, only for an input of the
       * person's, and answers its outcome: `{outcome: "accepted"}`,
       * `{outcome: "refused", reason}` with the refusal's class, or
       * `{outcome: "cancelled"}` when no input of the person's carried it or
       * the canvas was not shown, with `reason: "too_soon"` when it came
       * within a few seconds of the last spend of the activation. A control
       * whose operation the person approves first settles once they decide,
       * as `cyfr.request` does: `{outcome: "approved"}`, `{outcome:
       * "refused", reason}` (`declined` when the person refused it, or a
       * refusal's class) or `{outcome: "cancelled"}`, perhaps with its
       * `reason`. Nothing is tried again.
       *
       * Its first argument a binding id (as a `feed.results` event carries
       * one) and its second an action's name, it presses that feed's action
       * instead, answering nothing.
       * @returns {Promise<{outcome: string, reason?: string}> | undefined}
       */
      press(control, value = null) {
        if (typeof control === "string" && BINDING_ID.test(control) && typeof value === "string" && ACTION_NAME.test(value)) {
          verb("press", { binding: control, action: value });
          return void 0;
        }
        if (!isDesktopId(control)) return invalid("a control is named by its id");
        if (value !== null && !isPressValue(value)) return invalid("a pressed value is text of 1 to 256 code points");
        if (!framed) return Promise.resolve(CANCELLED);
        return awaitAnswer("press", value === null ? { control } : { control, value });
      },
      /**
       * On a canvas, write the person's preferences for it: `document`,
       * `{widgets: {<id>: {on, rect, <field>…}}, desktop: {<field>…}}`, each
       * widget it names replacing that widget's whole entry, over the
       * revision the canvas holds. Answers `{outcome, document, revision}`:
       * `saved`, `stale` (another write came first; the document is the
       * current one, to write over), `refused` with its `reason`, or
       * `cancelled` when no input of the person's carried it, with `reason`
       * `too_soon` when it came within a few seconds of the last spend.
       * @returns {Promise<{outcome: string, document: object, revision: number, reason?: string}>}
       */
      prefs(document2) {
        if (document2 === null || typeof document2 !== "object" || Array.isArray(document2)) {
          return invalid("preferences are an object");
        }
        if (!framed) return Promise.resolve(CANCELLED);
        return awaitAnswer("prefs", { document: document2 });
      },
      /**
       * On a canvas, ask AQUA about one of its widgets, by the widget's id:
       * AQUA's panel opens with a sentence CYFR writes naming the widget and
       * the desktop, after the person's draft, and sends nothing. Only for
       * an input of the person's.
       */
      ask(widget) {
        verb("ask", { widget });
      },
      /**
       * On a canvas, open one of CYFR's own pages by its key, e.g.
       * "schedules" or "vault", and optionally at one record on it, by its
       * id, e.g. a thread's. Only for an input of the person's.
       */
      settings(page, ref = null) {
        verb("settings", ref === null ? { page } : { page, ref });
      },
      /**
       * Ask the person for an act only they may do: an operation by its
       * name, "tool.action", with its arguments, or "grant" with `{ref}`, a
       * component reference, e.g. "c:local.openai". The person decides in
       * CYFR's own prompt, never in the frame, and the frame performs
       * nothing: CYFR runs what they approve. Which operations a frame may
       * ask for, and what the person is shown, are CYFR's. Only for an input
       * of the person's, from any frame.
       * @param {string} operation - "tool.action", or "grant"
       * @param {object} [args] - its arguments; for "grant" exactly `{ref}`
       * @returns {Promise<{outcome: string, reason?: string}> & {requested: Promise<string|null>}}
       *   the decision: `{outcome: "approved"}` once it ran, `{outcome:
       *   "refused", reason}` (`declined` when the person refused it, or a
       *   refusal's class when CYFR did), or `{outcome: "cancelled"}`, as
       *   when no input of the person's carried it, with `reason`
       *   `too_soon`, `busy`, `expired` or `dismissed` when CYFR says why.
       *   One that got no answer settles refused `uncertain`.
       *   `requested` resolves with the request's id once the person is
       *   asked, or with null when it was decided without asking them.
       *   Arguments outside the wire reject `invalid_argument`.
       */
      request(operation, args = {}) {
        if (!isRequest(operation, args)) {
          const refused = invalid("a request names tool.action with an object of arguments, or grant with exactly a ref");
          return requestHandle(refused, Promise.resolve(null));
        }
        if (!framed) return requestHandle(Promise.resolve(CANCELLED), Promise.resolve(null));
        let heard2;
        const requested = new Promise((resolve) => heard2 = resolve);
        return requestHandle(awaitAnswer("request", { operation, args }, heard2), requested);
      },
      /**
       * On a canvas, ask the person to grant a component: a component
       * reference, e.g. "c:local.openai". The person confirms in CYFR's own
       * prompt, never in the canvas. The shell acts on it only within moments
       * of the person's own input, never from a script on its own, and only
       * for a component the athanor has installed.
       */
      grant(ref) {
        verb("grant", { ref });
      },
      /**
       * On a canvas, hear what the shell tells it: `installed` (the installed
       * tinctures, `[{ref, name, icon, open}]`), `posture` (`desk` or
       * `hand`), `covered` (the rects of it, `{x, y, width, height}` in its
       * own pixels, that the shown apps cover), `state` (`live` or
       * `frozen`) or `desktop` (as `cyfr.desktop` reads it); on an app,
       * `subject`, what it was opened on again. The latest value, if one has
       * come, is handed to a new handler first.
       * @returns {function} stops the handler hearing more
       */
      on(event, handler) {
        if (!CANVAS_EVENTS.includes(event)) {
          throw new TypeError("cyfr.on takes installed, posture, covered, state, desktop or subject");
        }
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
        if (!framed) return Promise.reject(noFrame());
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
  var Socket = window.WebSocket;
  var client = createClient({
    win: window,
    fetchFn: window.fetch.bind(window),
    socketFn: (url) => new Socket(url),
    base: document.baseURI
  });
  window.addEventListener("message", client.onWindowMessage);
  window.addEventListener("error", client.onPageError);
  window.addEventListener("unhandledrejection", client.onPageError);
  window.cyfr = client.api;
})();

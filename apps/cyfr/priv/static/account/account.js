// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
// Built from apps/cyfr/assets/account by `mix esbuild account`.
(() => {
  var __defProp = Object.defineProperty;
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };

  // account/base64url.js
  function b64url(bytes2) {
    const view = bytes2 instanceof ArrayBuffer ? new Uint8Array(bytes2) : new Uint8Array(bytes2.buffer, bytes2.byteOffset, bytes2.byteLength);
    let binary2 = "";
    for (const byte of view) binary2 += String.fromCharCode(byte);
    return btoa(binary2).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }
  function fromB64url(text2) {
    if (typeof text2 !== "string" || !/^[A-Za-z0-9_-]*$/.test(text2)) throw new TypeError("not unpadded base64url");
    const base64 = text2.replace(/-/g, "+").replace(/_/g, "/");
    const binary2 = atob(base64 + "=".repeat((4 - base64.length % 4) % 4));
    const bytes2 = new Uint8Array(binary2.length);
    for (let i = 0; i < binary2.length; i++) bytes2[i] = binary2.charCodeAt(i);
    return bytes2;
  }

  // account/encoding.js
  var Refusal = class extends Error {
    constructor(reason, detail = {}) {
      super(detail.field ? `${reason}: ${detail.field}` : reason);
      this.reason = reason;
      this.detail = detail;
    }
    /** The refusal as the vectors spell it: `{reason}` plus `field` or `kind` when it names one. */
    toJSON() {
      return { reason: this.reason, ...this.detail };
    }
  };
  var refuse = (reason, detail) => {
    throw new Refusal(reason, detail);
  };
  var invalid = (field) => refuse("invalid_field", { field });
  var MAX_INTEGER = Number.MAX_SAFE_INTEGER;
  var DEFAULT_PORTS = { http: 80, https: 443 };
  var HOST = /^(?=.{1,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/;
  var DIGEST = /^sha256:[0-9a-f]{64}$/;
  var IDENTIFIER = /^per_[0-9a-f]{64}$/;
  var PATH = /^(?:\/[A-Za-z0-9._~!$&'()*+,;=:@%-]+)*$/;
  var ORIGIN = /^(https?):\/\/([^/:?#@]+)(?::(0|[1-9][0-9]{0,4}))?/;
  var MAX_URL_BYTES = 2048;
  var MAX_HOME_BYTES = 300;
  var utf8 = (text2) => new TextEncoder().encode(text2);
  var b64 = b64url;
  function unb64(value, min, max = min) {
    if (typeof value !== "string") return null;
    let bytes2;
    try {
      bytes2 = fromB64url(value);
    } catch (_error) {
      return null;
    }
    if (bytes2.length < min || bytes2.length > max || b64url(bytes2) !== value) return null;
    return bytes2;
  }
  function hex(bytes2) {
    return Array.from(bytes2, (byte) => byte.toString(16).padStart(2, "0")).join("");
  }
  function fromHex(text2) {
    return new Uint8Array(text2.match(/../g).map((pair) => parseInt(pair, 16)));
  }
  async function sha256(bytes2) {
    return new Uint8Array(await crypto.subtle.digest("SHA-256", typeof bytes2 === "string" ? utf8(bytes2) : bytes2));
  }
  async function digestOf(bytes2) {
    return "sha256:" + hex(await sha256(bytes2));
  }
  function concat(...parts) {
    const out = new Uint8Array(parts.reduce((size, part) => size + part.length, 0));
    let at = 0;
    for (const part of parts) {
      out.set(part, at);
      at += part.length;
    }
    return out;
  }
  var isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
  var isDigest = (value) => typeof value === "string" && DIGEST.test(value);
  var isIdentifier = (value) => typeof value === "string" && IDENTIFIER.test(value);
  var isHost = (value) => typeof value === "string" && HOST.test(value);
  var isMs = (value) => Number.isSafeInteger(value) && value >= 0 && value <= MAX_INTEGER;
  function jcs(value) {
    return write(value, []);
  }
  function write(value, path) {
    if (typeof value === "boolean" || typeof value === "string") return JSON.stringify(value);
    if (typeof value === "number" && Number.isSafeInteger(value)) return JSON.stringify(value);
    if (Array.isArray(value)) return "[" + value.map((item) => write(item, path)).join(",") + "]";
    if (isObject(value)) {
      const names = Object.keys(value).sort();
      return "{" + names.map((name) => JSON.stringify(name) + ":" + write(value[name], path.length ? path : [name])).join(",") + "}";
    }
    return invalid(path[0] ?? "");
  }
  function fields(map, required, optional = []) {
    const allowed = /* @__PURE__ */ new Set([...required, ...optional]);
    const unknown = Object.keys(map).sort().find((name) => !allowed.has(name));
    if (unknown !== void 0) refuse("unknown_field", { field: unknown });
    const missing = required.find((name) => !Object.hasOwn(map, name));
    if (missing !== void 0) refuse("missing_field", { field: missing });
  }
  function check(map, field, valid) {
    return valid(map[field]) ? map[field] : invalid(field);
  }
  function binary(map, field, min, max = min) {
    return unb64(map[field], min, max) ?? invalid(field);
  }
  function protocol(map, expected) {
    if (!Object.hasOwn(map, "protocol")) refuse("missing_field", { field: "protocol" });
    if (map.protocol !== expected) refuse("wrong_protocol");
  }
  function splitOrigin(value) {
    const match = ORIGIN.exec(value);
    if (!match || !HOST.test(match[2])) return null;
    const [whole, scheme, host, port] = match;
    if (port !== void 0 && (Number(port) > 65535 || Number(port) === DEFAULT_PORTS[scheme])) return null;
    return { origin: whole, host, rest: value.slice(whole.length) };
  }
  function isHome(value) {
    if (typeof value !== "string" || utf8(value).length > MAX_HOME_BYTES) return false;
    const split = splitOrigin(value);
    return split !== null && split.rest === "";
  }
  function isDirectoryUrl(value) {
    if (typeof value !== "string" || utf8(value).length > MAX_URL_BYTES) return false;
    const split = splitOrigin(value);
    return split !== null && PATH.test(split.rest) && !/%(?![0-9A-Fa-f]{2})/.test(split.rest);
  }
  function directoryOrigin(url) {
    const { origin, host } = splitOrigin(url);
    return { origin, host };
  }

  // account/webauthn.js
  var FIXED_BYTES = 37;
  var USER_PRESENT = 1;
  var USER_VERIFIED = 4;
  async function verifyAssertion(assertion, pub, challenge2, origin, rpId) {
    const client = clientData(assertion.client_data);
    if (!client) return "malformed";
    if (client.type !== "webauthn.get") return "wrong_type";
    if (client.challenge !== b64(challenge2)) return "wrong_challenge";
    if (client.origin !== origin) return "wrong_origin";
    if (client.crossOrigin === true) return "cross_origin";
    const data = assertion.authenticator_data;
    if (data.length < FIXED_BYTES) return "malformed";
    if (!same(data.subarray(0, 32), await sha256(rpId))) return "wrong_rp";
    if ((data[32] & USER_PRESENT) === 0) return "user_not_present";
    if ((data[32] & USER_VERIFIED) === 0) return "user_not_verified";
    return await signed(assertion, pub) ? "ok" : "bad_signature";
  }
  function clientData(bytes2) {
    try {
      const client = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes2));
      return isObject(client) ? client : null;
    } catch (_error) {
      return null;
    }
  }
  function same(a, b) {
    return a.length === b.length && a.every((byte, i) => byte === b[i]);
  }
  async function signed(assertion, pub) {
    const raw = derToRaw(assertion.signature);
    if (!raw) return false;
    const message = concat(assertion.authenticator_data, await sha256(assertion.client_data));
    try {
      const key = await crypto.subtle.importKey("raw", pub, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
      return await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, raw, message);
    } catch (_error) {
      return false;
    }
  }
  function derToRaw(der) {
    if (der.length < 8 || der[0] !== 48 || der[1] !== der.length - 2) return null;
    const r = integer(der, 2);
    const s = r && integer(der, r.next);
    if (!s || s.next !== der.length) return null;
    return concat(r.value, s.value);
  }
  function integer(der, at) {
    if (der[at] !== 2) return null;
    const size = der[at + 1];
    if (size < 1 || size > 33 || at + 2 + size > der.length) return null;
    let value = der.subarray(at + 2, at + 2 + size);
    if (value[0] >= 128) return null;
    if (value[0] === 0 && value.length > 1) {
      if (value[1] < 128) return null;
      value = value.subarray(1);
    }
    if (value.length > 32) return null;
    const padded = new Uint8Array(32);
    padded.set(value, 32 - value.length);
    return { value: padded, next: at + 2 + size };
  }

  // account/identity.js
  var PROTOCOL = "cyfr-identity/v2";
  var MAX_ENTRY_BYTES = 16384;
  var MAX_RECOVERY = 8;
  var MAX_KEYS = 64;
  var KINDS = ["genesis", "add_key", "remove_key", "recover", "add_recovery"];
  var KEY_BYTES = 32;
  var SIGNATURE_BYTES = 64;
  var POINT_BYTES = 65;
  var MAX_CREDENTIAL_ID_BYTES = 1023;
  var MAX_ASSERTION_BYTES = 16384;
  var SIGNER = /^(?:recovery:)?sha256:[0-9a-f]{64}$/;
  var COMMON = ["protocol", "kind", "seq", "at", "signer"];
  var KIND_FIELDS = {
    genesis: ["directory", "recovery"],
    add_key: ["prev", "key"],
    remove_key: ["prev", "kid"],
    recover: ["prev", "keys", "recovery"],
    add_recovery: ["prev", "recovery"]
  };
  var PKCS8_ED25519 = [48, 46, 2, 1, 0, 48, 5, 6, 3, 43, 101, 112, 4, 34, 4, 32];
  var kid = (pub) => digestOf(pub);
  var recoverySigner = async (pub) => "recovery:" + await kid(pub);
  async function ed25519Key(seed) {
    if (!(seed instanceof Uint8Array) || seed.length !== KEY_BYTES) return null;
    const pkcs8 = new Uint8Array([...PKCS8_ED25519, ...seed]);
    const exported = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "Ed25519" }, true, ["sign"]);
    const pub = unb64((await crypto.subtle.exportKey("jwk", exported)).x, KEY_BYTES);
    const key = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "Ed25519" }, false, ["sign"]);
    pkcs8.fill(0);
    return { pub, sign: async (bytes2) => new Uint8Array(await crypto.subtle.sign("Ed25519", key, bytes2)) };
  }
  function userId(identifier2) {
    return isIdentifier(identifier2) ? fromHex(identifier2.slice(4)) : null;
  }
  function identifierForUserId(bytes2) {
    return bytes2 instanceof Uint8Array && bytes2.length === 32 ? "per_" + hex(bytes2) : null;
  }
  async function keyOf({ pub, credentialId }) {
    return credentialId ? { kid: await kid(pub), alg: "es256", kind: "passkey", pub: b64(pub), credential_id: b64(credentialId) } : { kid: await kid(pub), alg: "ed25519", kind: "device", pub: b64(pub) };
  }
  function genesis({ directory: directory2, recovery: recovery2, at, signer }) {
    return { protocol: PROTOCOL, kind: "genesis", seq: 0, at, signer, directory: directory2, recovery: recovery2 };
  }
  function next(state, kind, own, { at, signer }) {
    return { protocol: PROTOCOL, kind, prev: state.head, seq: state.seq + 1, at, signer, ...own };
  }
  function signingBytes(entry) {
    const { sig: _sig, ...unsigned } = entry;
    return utf8(jcs(unsigned));
  }
  var challenge = (entry) => sha256(signingBytes(entry));
  async function signWith(entry, key) {
    return { ...entry, sig: b64(await key.sign(signingBytes(entry))) };
  }
  function attach(entry, assertion) {
    return { ...entry, sig: assertionJSON(assertion) };
  }
  function assertionJSON({ authenticator_data, client_data, signature: signature2 }) {
    return { authenticator_data: b64(authenticator_data), client_data: b64(client_data), signature: b64(signature2) };
  }
  var hash = (entry) => digestOf(utf8(jcs(entry)));
  async function identifier(genesisEntry) {
    return "per_" + hex(await sha256(utf8(jcs(genesisEntry))));
  }
  async function walk(entries) {
    if (!Array.isArray(entries) || entries.length === 0) return { error: { index: 0, reason: "empty" } };
    let state;
    for (const [index, entry] of entries.entries()) {
      try {
        state = index === 0 ? await begin(entry) : await extend(state, entry);
      } catch (error) {
        if (error instanceof Refusal) return { error: { index, ...error.toJSON() } };
        throw error;
      }
    }
    return { state };
  }
  async function extend(state, map) {
    const entry = await read(map);
    if (entry.kind === "genesis") refuse("unexpected_genesis");
    if (map.prev !== state.head || map.seq !== state.seq + 1) refuse("broken_link");
    await authorized(map, state);
    await signed2(entry, await signerKey(map.signer, state), state.directory);
    const after = await applied(map, state);
    return { ...after, head: await hash(map), seq: map.seq };
  }
  async function begin(map) {
    const entry = await read(map);
    if (entry.kind !== "genesis") refuse("not_genesis");
    const pub = await listedRecovery(map.recovery, map.signer);
    await signed2(entry, pub && { recovery: pub }, map.directory);
    return {
      identifier: await identifier(map),
      directory: map.directory,
      head: await hash(map),
      seq: 0,
      keys: [],
      recovery: map.recovery
    };
  }
  async function authorized(map, state) {
    const { kind, signer } = map;
    if (signer.startsWith("recovery:")) {
      if (await listedRecovery(state.recovery, signer)) return;
    } else if (kind === "add_key" || kind === "remove_key" && signer !== map.kid) {
      if (listed(state, signer)) return;
    }
    refuse("wrong_signer");
  }
  var listed = (state, kidValue) => state.keys.find((key) => key.kid === kidValue);
  async function listedRecovery(recovery2, signer) {
    for (const pub of recovery2) if (await recoverySigner(unb64(pub, KEY_BYTES)) === signer) return unb64(pub, KEY_BYTES);
    return null;
  }
  async function signerKey(signer, state) {
    if (signer.startsWith("recovery:")) {
      const pub = await listedRecovery(state.recovery, signer);
      return pub && { recovery: pub };
    }
    const key = listed(state, signer);
    return key && { key };
  }
  async function signed2(entry, signer, directory2) {
    const sig = entry.sig;
    let ok = false;
    if (signer?.recovery && sig instanceof Uint8Array) ok = await ed25519(entry.map, sig, signer.recovery);
    else if (signer?.key?.alg === "ed25519" && sig instanceof Uint8Array) ok = await ed25519(entry.map, sig, unb64(signer.key.pub, KEY_BYTES));
    else if (signer?.key?.alg === "es256" && sig && !(sig instanceof Uint8Array)) {
      const { origin, host } = directoryOrigin(directory2);
      ok = await verifyAssertion(sig, unb64(signer.key.pub, POINT_BYTES), await challenge(entry.map), origin, host) === "ok";
    }
    if (!ok) refuse("wrong_signer");
  }
  async function ed25519(map, sig, pub) {
    try {
      const key = await crypto.subtle.importKey("raw", pub, { name: "Ed25519" }, false, ["verify"]);
      return await crypto.subtle.verify("Ed25519", key, sig, signingBytes(map));
    } catch (_error) {
      return false;
    }
  }
  async function applied(map, state) {
    switch (map.kind) {
      case "add_key":
        if (listed(state, map.key.kid)) refuse("duplicate_key");
        return { ...state, keys: [...state.keys, map.key] };
      case "remove_key":
        if (!listed(state, map.kid)) invalid("kid");
        return { ...state, keys: state.keys.filter((key) => key.kid !== map.kid) };
      case "recover":
        if (new Set(map.keys.map((key) => key.kid)).size !== map.keys.length) refuse("duplicate_key");
        return { ...state, keys: map.keys, recovery: map.recovery };
      case "add_recovery": {
        const after = new Set(map.recovery);
        if (!state.recovery.every((pub) => after.has(pub)) || map.recovery.length <= state.recovery.length) invalid("recovery");
        return { ...state, recovery: map.recovery };
      }
    }
  }
  async function read(map) {
    if (!isObject(map)) invalid("entry");
    if (utf8(jcs(map)).length > MAX_ENTRY_BYTES) refuse("too_large");
    protocol(map, PROTOCOL);
    if (!Object.hasOwn(map, "kind")) refuse("missing_field", { field: "kind" });
    if (!KINDS.includes(map.kind)) refuse("unknown_kind", { kind: map.kind });
    const kind = map.kind;
    fields(map, [...COMMON, ...KIND_FIELDS[kind], "sig"]);
    check(map, "seq", kind === "genesis" ? (seq) => seq === 0 : isMs);
    check(map, "at", isMs);
    check(map, "signer", (signer) => typeof signer === "string" && SIGNER.test(signer));
    if (kind !== "genesis") check(map, "prev", isDigest);
    if (kind === "genesis") {
      check(map, "directory", isDirectoryUrl);
      recovery(map);
    } else if (kind === "add_key") {
      if (!await decodeKey(map.key)) invalid("key");
    } else if (kind === "remove_key") {
      check(map, "kid", isDigest);
    } else if (kind === "recover") {
      await keys(map);
      recovery(map);
    } else {
      recovery(map);
    }
    return { map, kind, sig: signature(map.sig) };
  }
  function recovery(map) {
    const list = map.recovery;
    if (!Array.isArray(list) || list.length === 0 || list.length > MAX_RECOVERY) invalid("recovery");
    if (list.some((pub) => !unb64(pub, KEY_BYTES)) || new Set(list).size !== list.length) invalid("recovery");
  }
  async function keys(map) {
    const list = map.keys;
    if (!Array.isArray(list) || list.length > MAX_KEYS) invalid("keys");
    for (const key of list) if (!await decodeKey(key)) invalid("keys");
  }
  async function decodeKey(map) {
    if (!isObject(map)) return false;
    try {
      if (map.alg === "ed25519" && map.kind === "device") {
        fields(map, ["kid", "alg", "kind", "pub"]);
        const pub = unb64(map.pub, KEY_BYTES);
        return pub !== null && map.kid === await kid(pub);
      }
      if (map.alg === "es256" && map.kind === "passkey") {
        fields(map, ["kid", "alg", "kind", "pub", "credential_id"]);
        const pub = unb64(map.pub, POINT_BYTES);
        return pub !== null && pub[0] === 4 && unb64(map.credential_id, 1, MAX_CREDENTIAL_ID_BYTES) !== null && map.kid === await kid(pub);
      }
    } catch (error) {
      if (error instanceof Refusal) return false;
      throw error;
    }
    return false;
  }
  function signature(sig) {
    if (typeof sig === "string") return unb64(sig, SIGNATURE_BYTES) ?? invalid("sig");
    if (!isObject(sig)) invalid("sig");
    try {
      fields(sig, ["authenticator_data", "client_data", "signature"]);
      return {
        authenticator_data: binary(sig, "authenticator_data", 1, MAX_ASSERTION_BYTES),
        client_data: binary(sig, "client_data", 1, MAX_ASSERTION_BYTES),
        signature: binary(sig, "signature", 1, MAX_ASSERTION_BYTES)
      };
    } catch (error) {
      if (error instanceof Refusal) invalid("sig");
      throw error;
    }
  }

  // account/ceremony.js
  var ES256 = -7;
  var P256_SPKI = [
    48,
    89,
    48,
    19,
    6,
    7,
    42,
    134,
    72,
    206,
    61,
    2,
    1,
    6,
    8,
    42,
    134,
    72,
    206,
    61,
    3,
    1,
    7,
    3,
    66,
    0
  ];
  function bytes(buffer) {
    if (!buffer) return null;
    return buffer instanceof ArrayBuffer ? new Uint8Array(buffer.slice(0)) : new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength).slice();
  }
  function passkeys(credentials, rpId) {
    return {
      rpId,
      /**
       * An assertion over `challenge` (bytes) by a passkey of this host,
       * restricted to the credential ids in `allow` when given. Resolves to
       * the identifier its user handle names (null when it names none), the
       * credential's raw id and the three signed byte fields.
       */
      async assert({ challenge: challenge2, allow }) {
        const publicKey = { challenge: challenge2, rpId, userVerification: "required" };
        if (allow) publicKey.allowCredentials = allow.map((id) => ({ type: "public-key", id }));
        const credential = await credentials.get({ publicKey });
        const response = credential.response;
        const userHandle = bytes(response.userHandle);
        return {
          identifier: userHandle ? identifierForUserId(userHandle) : null,
          credentialId: bytes(credential.rawId),
          authenticatorData: bytes(response.authenticatorData),
          clientData: bytes(response.clientDataJSON),
          signature: bytes(response.signature)
        };
      },
      /**
       * A new discoverable passkey for the account whose identifier's digest
       * bytes are `userId`, shown as `name`. Resolves to its raw credential
       * id and its 65-byte P-256 point; rejects for any other algorithm.
       */
      async create({ userId: userId2, name, challenge: challenge2 }) {
        const credential = await credentials.create({
          publicKey: {
            challenge: challenge2,
            rp: { id: rpId, name: "CYFR" },
            user: { id: userId2, name, displayName: name },
            pubKeyCredParams: [{ type: "public-key", alg: ES256 }],
            authenticatorSelection: { residentKey: "required", requireResidentKey: true, userVerification: "required" },
            attestation: "none"
          }
        });
        const response = credential.response;
        const spki = bytes(response.getPublicKey());
        const p256 = response.getPublicKeyAlgorithm() === ES256 && spki?.length === P256_SPKI.length + 65 && P256_SPKI.every((byte, i) => spki[i] === byte);
        if (!p256) throw new Error("the passkey is not a P-256 key");
        return { credentialId: bytes(credential.rawId), pub: spki.subarray(P256_SPKI.length) };
      }
    };
  }

  // account/pages/add.js
  var add_exports = {};
  __export(add_exports, {
    adding: () => adding,
    readDevice: () => readDevice,
    run: () => run
  });

  // account/registry.js
  var PROTOCOL2 = "cyfr-registry-request/v2";
  var HANDLE_PROTOCOL = "cyfr-handle/v1";
  var MAX_BYTES = 16384;
  var NONCE_BYTES = 16;
  var LIFETIME_MS = 12e4;
  var ROUTES = {
    "handle.claim": "/v1/namespaces/personal/claim",
    "policy.accept": "/v1/legal/accept"
  };
  var ENVELOPE = ["protocol", "registry", "operation", "identifier", "nonce", "expires_at", "body"];
  var PERSONAL = /^[a-z0-9]+(-[a-z0-9]+)*$/;
  var PUBLISHER_LABEL = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;
  var LABEL = /^[\x20-\x7E]{1,64}$/;
  var BLANK = /^[ \t\r\n]*$/;
  var control = (value) => Array.from(value).some((char) => char.charCodeAt(0) < 32 || char.charCodeAt(0) === 127);
  var text = (max) => (value) => typeof value === "string" && value !== "" && utf8(value).length <= max && !control(value);
  var slug = (value) => typeof value === "string" && value.includes(".") && value.length <= 253 && value.split(".").every((label) => PUBLISHER_LABEL.test(label));
  var BODIES = {
    "handle.claim": ["handle"],
    "tokens.mint": ["label"],
    "policy.accept": ["policy_version"],
    "appeal.file": ["action_type", "action_ref", "argument"],
    "publisher.claim": ["slug"],
    "publisher.verify": ["slug", "label"]
  };
  var VALID = {
    handle: (value) => isHandle(value),
    label: (value) => typeof value === "string" && LABEL.test(value),
    policy_version: text(128),
    action_type: (value) => value === "takedown" || value === "ban",
    action_ref: text(256),
    argument: (value) => typeof value === "string" && utf8(value).length <= 4e3 && !BLANK.test(value),
    slug
  };
  var REFUSALS = {
    REQUEST_MALFORMED: "request_malformed",
    WRONG_PROTOCOL: "wrong_protocol",
    WRONG_REGISTRY: "wrong_registry",
    UNKNOWN_OPERATION: "unknown_operation",
    REQUEST_EXPIRED: "expired",
    EXPIRY_TOO_FAR: "expiry_too_far",
    UNKNOWN_IDENTITY: "unknown_identity",
    DIRECTORY_UNAVAILABLE: "directory_unavailable",
    WRONG_DIRECTORY: "wrong_directory",
    BAD_SIGNATURE: "bad_signature",
    REPLAYED: "replayed",
    IDENTITY_BANNED: "banned",
    NOT_APPELLANT_OF_RECORD: "not_appellant",
    ACTION_NOT_FOUND: "action_not_found",
    APPEAL_TOO_EARLY: "appeal_too_early",
    NAMESPACE_UNOWNED: "namespace_unowned",
    SLUG_TAKEN: "handle_taken",
    ALREADY_CLAIMED: "has_other_handle",
    INVALID_USERNAME: "handle_invalid",
    RESERVED: "handle_reserved",
    NAMESPACE_RESERVED: "namespace_reserved",
    CLAIM_NOT_PENDING: "claim_not_pending",
    DNS_UNVERIFIED: "dns_unverified",
    DNS_TIMEOUT: "dns_timeout",
    POLICY_ACCEPTANCE_REQUIRED: "policy_required",
    RATE_LIMITED: "rate_limited",
    HANDLE_NOT_FOUND: "handle_not_found"
  };
  function isHandle(value) {
    return typeof value === "string" && value.length <= 39 && PERSONAL.test(value);
  }
  function readToSign(map) {
    if (!isObject(map)) throw new Refusal("request_malformed");
    fields(map, ENVELOPE);
    jcs(map);
    check(map, "protocol", (value) => typeof value === "string");
    check(map, "registry", isHost);
    check(map, "operation", (value) => typeof value === "string");
    check(map, "identifier", isIdentifier);
    binary(map, "nonce", NONCE_BYTES);
    check(map, "expires_at", isMs);
    check(map, "body", isObject);
    if (map.protocol !== PROTOCOL2) throw new Refusal("wrong_protocol");
    const keys2 = BODIES[map.operation];
    if (!keys2) throw new Refusal("unknown_operation");
    fields(map.body, keys2);
    for (const key of keys2) check(map.body, key, VALID[key]);
    return map;
  }
  function compose({ registry: registry2, operation, identifier: identifier2, signer, nonce, now, body }) {
    return {
      protocol: PROTOCOL2,
      registry: registry2,
      operation,
      identifier: identifier2,
      signer,
      nonce: b64(nonce),
      expires_at: now + LIFETIME_MS,
      body
    };
  }
  function signingBytes2(request) {
    const { sig: _sig, ...unsigned } = request;
    return utf8(jcs(unsigned));
  }
  async function signWith2(request, key) {
    const signed3 = { ...request, sig: b64(await key.sign(signingBytes2(request))) };
    return sent(signed3);
  }
  function sent(signed3) {
    const bytes2 = jcs(signed3);
    if (utf8(bytes2).length > MAX_BYTES) throw new Refusal("request_malformed");
    return bytes2;
  }
  function refusal(bytes2) {
    const envelope = parse(bytes2);
    const first = isObject(envelope) && Array.isArray(envelope.errors) ? envelope.errors[0] : null;
    if (!isObject(first) || !Object.hasOwn(REFUSALS, first.code) || typeof first.message !== "string") return "malformed_answer";
    try {
      jcs(envelope);
    } catch (_error) {
      return "malformed_answer";
    }
    return REFUSALS[first.code];
  }
  function handleAnswer(bytes2, handle, registry2) {
    const answer2 = parse(bytes2);
    if (isObject(answer2) && Object.hasOwn(answer2, "errors")) return { error: refusal(bytes2) };
    try {
      if (!isObject(answer2)) throw new Refusal("malformed_answer");
      fields(answer2, ["protocol", "registry", "handle", "identifier", "directory"]);
      const ok = answer2.protocol === HANDLE_PROTOCOL && answer2.registry === registry2 && answer2.handle === handle && isHost(registry2) && isHandle(handle) && isIdentifier(answer2.identifier) && isDirectoryUrl(answer2.directory);
      if (!ok) throw new Refusal("malformed_answer");
    } catch (error) {
      if (error instanceof Refusal) return { error: "malformed_answer" };
      throw error;
    }
    const { protocol: _protocol, ...result } = answer2;
    return { answer: result };
  }
  function parse(bytes2) {
    try {
      return JSON.parse(bytes2);
    } catch (_error) {
      return null;
    }
  }

  // account/network.js
  var MAX_PAGES = 64;
  var Unreachable = class extends Error {
    constructor() {
      super("unreachable");
    }
  };
  async function call(fetchFn, url, { method = "GET", body } = {}) {
    let response;
    let text2;
    try {
      response = await fetchFn(url, {
        method,
        body,
        headers: body ? { "content-type": "application/json" } : {},
        credentials: "omit",
        cache: "no-store",
        referrerPolicy: "no-referrer"
      });
      text2 = await response.text();
    } catch (_error) {
      throw new Unreachable();
    }
    if (response.status >= 500) throw new Unreachable();
    let json;
    try {
      json = JSON.parse(text2);
    } catch (_error) {
      json = null;
    }
    return { status: response.status, text: text2, json };
  }
  async function readConfig(origin, fetchFn) {
    const { status, json } = await call(fetchFn, `${origin}/account/config.json`);
    const valid = status === 200 && isObject(json) && isDirectoryUrl(json.directory) && isHome(json.registry) && (json.policy === null || isPolicy(json.policy));
    if (!valid) refuse("bad_config");
    return { directory: json.directory, registry: json.registry, policy: json.policy };
  }
  function isPolicy(policy) {
    return isObject(policy) && typeof policy.version === "string" && policy.version !== "" && typeof policy.url === "string" && /^https?:\/\//.test(policy.url);
  }
  function directory(url, fetchFn) {
    const base = `${url}/directory/v1`;
    async function write2(path, entry) {
      const { status, json } = await call(fetchFn, `${base}${path}`, { method: "POST", body: jcs(entry) });
      if (status === 200 && isObject(json) && ["created", "exists", "accepted"].includes(json.result)) return json;
      const { error, ...detail } = isObject(json) ? json : {};
      return refuse(typeof error === "string" ? error : "unexpected", detail);
    }
    return {
      url,
      /**
       * The account's log read from its genesis, page by page, and walked:
       * `{state, entries}`. Throws `gone` for a tombstoned account,
       * `not_found` for one the directory does not hold, and the walk's
       * refusal for a log that does not verify or does not reach its head.
       */
      async read(identifier2) {
        const entries = [];
        let after = -1;
        for (let pages = 0; pages < MAX_PAGES; pages++) {
          const { status, json } = await call(fetchFn, `${base}/${identifier2}?after=${after}`);
          if (status === 410) refuse("gone");
          if (status === 404) refuse("not_found");
          if (status !== 200 || !isObject(json) || json.identifier !== identifier2 || json.from !== after + 1 || !Array.isArray(json.entries)) refuse("invalid_page");
          entries.push(...json.entries);
          if (json.next === null) {
            const walked = await walk(entries);
            if (walked.error) refuse("unverified", walked.error);
            const { state } = walked;
            if (state.identifier !== identifier2 || state.head !== json.head || state.seq + 1 !== json.length) refuse("invalid_page");
            return { state, entries };
          }
          if (json.next !== after + json.entries.length || json.entries.length === 0) refuse("invalid_page");
          after = json.next;
        }
        return refuse("invalid_page");
      },
      /** Register a genesis: resolves to the directory's answer, `created` or `exists`. */
      register: (genesis2) => write2("/register", genesis2),
      /** Append one entry: resolves to `accepted` or `exists`; throws `stale_head`, `duplicate_key` and the rest. */
      append: (identifier2, entry) => write2(`/${identifier2}/append`, entry)
    };
  }
  function registry(origin, fetchFn) {
    const host = new URL(origin).hostname;
    return {
      host,
      /** Who holds `name`: `{answer}`, or `{error}` (`handle_not_found` for a free name). */
      async handle(name) {
        const { text: text2 } = await call(fetchFn, `${origin}/v1/handles/${encodeURIComponent(name)}`);
        return handleAnswer(text2, name, host);
      },
      /** Send a signed operation's bytes: resolves to the registry's answer, or throws its refusal. */
      async send(operation, bytes2) {
        const { status, text: text2, json } = await call(fetchFn, `${origin}${ROUTES[operation]}`, { method: "POST", body: bytes2 });
        if (status >= 200 && status < 300) return json;
        throw new Refusal(refusal(text2));
      }
    };
  }

  // account/pages/common.js
  async function here(env2) {
    const config = await readConfig(env2.origin, env2.fetch);
    if (new URL(config.directory).origin !== env2.origin) refuse("bad_config");
    return { config, directory: directory(config.directory, env2.fetch), registry: registry(config.registry, env2.fetch) };
  }
  async function namedByPasskey(env2, dir) {
    const picked = await env2.passkeys.assert({ challenge: env2.random(32) });
    if (!picked.identifier) refuse("no_account");
    const { state, entries } = await dir.read(picked.identifier);
    const passkey = state.keys.find((key) => key.kind === "passkey" && key.credential_id === b64(picked.credentialId));
    if (!passkey) refuse("unknown_passkey");
    return { identifier: picked.identifier, state, entries, passkey, credentialId: picked.credentialId };
  }
  async function signedByPasskey(env2, session, entry) {
    const made = await env2.passkeys.assert({ challenge: await challenge(entry), allow: [session.credentialId] });
    return attach(entry, { authenticator_data: made.authenticatorData, client_data: made.clientData, signature: made.signature });
  }
  async function appendOnce(dir, identifier2, entry, retry) {
    if (retry) {
      const read2 = await dir.read(identifier2);
      const held = read2.entries[entry.seq];
      if (held && jcs(held) === jcs(entry)) return read2;
    }
    await dir.append(identifier2, entry);
    return dir.read(identifier2);
  }
  var shortCode = (kid2) => kid2.slice("sha256:".length, "sha256:".length + 16);
  function addedAt(entries) {
    const at = /* @__PURE__ */ new Map();
    for (const entry of entries) {
      if (entry.kind === "add_key") at.set(entry.key.kid, entry.at);
      if (entry.kind === "recover") for (const key of entry.keys) at.set(key.kid, entry.at);
    }
    return at;
  }
  var KINDS2 = { passkey: "Passkey", device: "Device" };
  function keyLabel({ kind, code, added, current }) {
    const date = added === void 0 ? "" : `, added ${new Date(added).toLocaleDateString()}`;
    return `${KINDS2[kind]} ${code}${current ? " (this passkey)" : ""}${date}`;
  }

  // account/view.js
  var WORDS = {
    unreachable: "CYFR could not be reached. Check your connection and try again.",
    expired: "This request has expired. Go back to your CYFR and start again.",
    too_large: "This link is not one this page can answer.",
    invalid_fragment: "This link is not one this page can answer.",
    bad_link: "This link is not one this page can answer.",
    bad_config: "This page is not set up correctly. Try again later.",
    gone: "This account no longer exists.",
    not_found: "This account is not known here.",
    no_account: "That passkey does not belong to an account here.",
    unknown_passkey: "That passkey is no longer on its account. Use another passkey, or your recovery code.",
    no_passkey: "This account has no passkey. Add one with your recovery code first.",
    name_taken: "That name is taken. Choose another.",
    name_invalid: "A name is 1 to 39 lowercase letters, digits and single hyphens, starting and ending with a letter or digit.",
    policy_changed: "The terms changed. Accept the new terms to finish.",
    name_elsewhere: "That name is not this account's. Type the name of the account this code recovers.",
    not_a_code: "That is not a recovery code. Check what you typed.",
    typo: "That recovery code has a typo. Check each group and try again.",
    code_replaced: "That recovery code no longer works for its account.",
    other_code: "That recovery code is for another account.",
    stale_head: "Your account changed while this page was open. Start again.",
    duplicate_key: "That is already on your account.",
    cancelled: "The passkey was not used. Try again when you are ready."
  };
  function words(error) {
    if (error instanceof Unreachable) return WORDS.unreachable;
    if (error instanceof Refusal) return WORDS[error.reason] ?? "Something went wrong. Try again.";
    if (error?.name === "NotAllowedError" || error?.name === "AbortError") return WORDS.cancelled;
    return "Something went wrong. Try again.";
  }
  var $ = (doc, id) => doc.getElementById(id);
  function only(doc, id) {
    for (const section of doc.querySelectorAll("main > section")) section.hidden = section.id !== id;
  }
  function say(doc, id, text2) {
    const element = $(doc, id);
    element.textContent = text2;
    element.hidden = text2 === "";
  }
  async function attempt(doc, button, errorId, action) {
    button.disabled = true;
    say(doc, errorId, "");
    try {
      await action();
    } catch (error) {
      say(doc, errorId, words(error));
    } finally {
      button.disabled = false;
    }
  }
  function drawCode(doc, slot, code) {
    const groups = code.split("-");
    slot.replaceChildren(
      ...groups.flatMap((group, i) => i < groups.length - 1 ? [doc.createTextNode(`${group}-`), doc.createElement("wbr")] : [doc.createTextNode(group)])
    );
  }
  async function copyCode(button, code, clipboard = globalThis.navigator?.clipboard) {
    try {
      await clipboard.writeText(code);
      button.textContent = "Copied";
    } catch (_error) {
    }
  }

  // account/pages/add.js
  async function readDevice(params) {
    const pub = unb64(params.get("key"), 32);
    if (!pub || params.get("alg") !== "ed25519" || params.get("kind") !== "device") refuse("bad_link");
    const key = await keyOf({ pub });
    if (shortCode(key.kid) !== params.get("code")) refuse("bad_link");
    return key;
  }
  function adding(env2, place, device) {
    let session = null;
    let signed3 = null;
    return {
      async sign() {
        session = await namedByPasskey(env2, place.directory);
        if (session.state.keys.some((key) => key.kid === device.kid)) return "listed";
        const entry = next(session.state, "add_key", { key: device }, { at: env2.now(), signer: session.passkey.kid });
        signed3 = await signedByPasskey(env2, session, entry);
        return "signed";
      },
      send: () => place.directory.append(session.identifier, signed3)
    };
  }
  async function run(doc, env2) {
    let device;
    let place;
    try {
      device = await readDevice(new URLSearchParams(env2.location.hash.slice(1)));
      place = await here(env2);
    } catch (error) {
      say(doc, "refused-text", words(error));
      only(doc, "refused");
      return;
    }
    $(doc, "device-code").textContent = shortCode(device.kid);
    only(doc, "ask");
    const flow = adding(env2, place, device);
    const send = async () => {
      await flow.send();
      only(doc, "added");
    };
    const button = $(doc, "add");
    button.addEventListener(
      "click",
      () => attempt(doc, button, "ask-error", async () => {
        if (await flow.sign() === "listed") return only(doc, "added");
        only(doc, "sending");
        await attempt(doc, $(doc, "retry"), "sending-error", send);
      })
    );
    const retry = $(doc, "retry");
    retry.addEventListener("click", () => attempt(doc, retry, "sending-error", send));
  }

  // account/pages/devices.js
  var devices_exports = {};
  __export(devices_exports, {
    listing: () => listing,
    removal: () => removal,
    run: () => run2
  });
  function listing(session) {
    const at = addedAt(session.entries);
    return session.state.keys.map((key) => ({
      kid: key.kid,
      kind: key.kind,
      code: shortCode(key.kid),
      added: at.get(key.kid),
      current: key.kid === session.passkey.kid
    }));
  }
  function removal(env2, session, kid2) {
    return signedByPasskey(env2, session, next(session.state, "remove_key", { kid: kid2 }, { at: env2.now(), signer: session.passkey.kid }));
  }
  async function run2(doc, env2) {
    let place;
    try {
      place = await here(env2);
    } catch (error) {
      say(doc, "refused-text", words(error));
      only(doc, "refused");
      return;
    }
    only(doc, "ask");
    let session = null;
    let pending = null;
    const draw = () => {
      const rows = listing(session).map((key) => {
        const row = doc.createElement("li");
        const label = doc.createElement("span");
        label.textContent = keyLabel(key);
        row.append(label);
        if (!key.current) {
          const remove = doc.createElement("button");
          remove.type = "button";
          remove.textContent = "Remove";
          remove.addEventListener(
            "click",
            () => attempt(doc, remove, "list-error", async () => {
              const retry = pending?.kid === key.kid;
              if (!retry) pending = { kid: key.kid, entry: await removal(env2, session, key.kid) };
              session = { ...session, ...await appendOnce(place.directory, session.identifier, pending.entry, retry) };
              pending = null;
              draw();
            })
          );
          row.append(remove);
        }
        return row;
      });
      $(doc, "keys").replaceChildren(...rows);
      only(doc, "list");
    };
    const open = $(doc, "open");
    open.addEventListener(
      "click",
      () => attempt(doc, open, "ask-error", async () => {
        session = await namedByPasskey(env2, place.directory);
        draw();
      })
    );
  }

  // account/pages/new.js
  var new_exports = {};
  __export(new_exports, {
    Creation: () => Creation,
    run: () => run4
  });

  // account/attempts.js
  var PREFIX = "cyfr-account-attempt:";
  var LIFETIME_MS2 = 24 * 60 * 60 * 1e3;
  function attempts(storage2, now) {
    const keys2 = () => {
      try {
        return Array.from({ length: storage2.length }, (_, i) => storage2.key(i)).filter((key) => key?.startsWith(PREFIX));
      } catch (_error) {
        return [];
      }
    };
    const drop = (key) => {
      try {
        storage2.removeItem(key);
      } catch (_error) {
      }
    };
    return {
      /** The attempts still open, oldest first; expired or unreadable ones are removed. */
      list() {
        const open = [];
        for (const key of keys2()) {
          let attempt2;
          try {
            attempt2 = JSON.parse(storage2.getItem(key));
          } catch (_error) {
            attempt2 = null;
          }
          if (attempt2 && typeof attempt2.created_at === "number" && now() - attempt2.created_at < LIFETIME_MS2) open.push(attempt2);
          else drop(key);
        }
        return open.sort((a, b) => a.created_at - b.created_at);
      },
      save(attempt2) {
        try {
          storage2.setItem(PREFIX + attempt2.identifier, JSON.stringify(attempt2));
        } catch (_error) {
        }
      },
      remove(identifier2) {
        drop(PREFIX + identifier2);
      }
    };
  }

  // account/recovery_code.js
  var PROTOCOL3 = "cyfr-recovery-code/v1";
  var PREFIX2 = "CYFR";
  var ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
  var DIGEST_BYTES = 32;
  var SECRET_BYTES = 32;
  var CHECK_BYTES = 6;
  var SYMBOLS = (DIGEST_BYTES + SECRET_BYTES + CHECK_BYTES) * 8 / 5;
  var GROUP = 8;
  async function encodeRecoveryCode(identifier2, secret, crypto2 = globalThis.crypto) {
    if (!/^per_[0-9a-f]{64}$/.test(identifier2)) throw new TypeError("not an identifier");
    if (!(secret instanceof Uint8Array) || secret.length !== SECRET_BYTES) throw new TypeError("not a secret");
    const digest2 = new Uint8Array(identifier2.slice(4).match(/../g).map((pair) => parseInt(pair, 16)));
    const check2 = new Uint8Array(await crypto2.subtle.digest("SHA-256", checked(digest2, secret))).subarray(0, CHECK_BYTES);
    const bytes2 = new Uint8Array([...digest2, ...secret, ...check2]);
    let symbols2 = "";
    let held = 0;
    let bits = 0;
    for (const byte of bytes2) {
      held = held << 8 | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        symbols2 += ALPHABET[held >> bits & 31];
        held &= (1 << bits) - 1;
      }
    }
    return [PREFIX2, ...symbols2.match(new RegExp(`.{${GROUP}}`, "g"))].join("-");
  }
  async function decodeRecoveryCode(text2, crypto2 = globalThis.crypto) {
    if (typeof crypto2?.subtle?.digest !== "function") throw new TypeError("no WebCrypto");
    const bytes2 = symbols(text2);
    if (!bytes2) return { error: "not_a_code" };
    const digest2 = bytes2.subarray(0, DIGEST_BYTES);
    const secret = bytes2.subarray(DIGEST_BYTES, DIGEST_BYTES + SECRET_BYTES);
    const check2 = bytes2.subarray(DIGEST_BYTES + SECRET_BYTES);
    const expected = new Uint8Array(await crypto2.subtle.digest("SHA-256", checked(digest2, secret))).subarray(0, CHECK_BYTES);
    if (!check2.every((byte, i) => byte === expected[i])) return { error: "typo" };
    return { identifier: `per_${hex2(digest2)}`, secret: b64url(secret) };
  }
  function symbols(text2) {
    if (typeof text2 !== "string") return null;
    const stripped = text2.replace(/[ \t\n\r-]/g, "");
    if (/[\u0080-\uffff]/.test(stripped)) return null;
    const upper = stripped.replace(/[a-z]/g, (letter) => letter.toUpperCase());
    if (!upper.startsWith(PREFIX2)) return null;
    const body = upper.slice(PREFIX2.length).replace(/O/g, "0").replace(/[IL]/g, "1");
    if (body.length !== SYMBOLS) return null;
    const bytes2 = new Uint8Array(SYMBOLS * 5 / 8);
    let held = 0;
    let bits = 0;
    let at = 0;
    for (const symbol of body) {
      const value = ALPHABET.indexOf(symbol);
      if (value < 0) return null;
      held = held << 5 | value;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        bytes2[at++] = held >> bits & 255;
        held &= (1 << bits) - 1;
      }
    }
    return bytes2;
  }
  function checked(digest2, secret) {
    const protocol2 = new TextEncoder().encode(PROTOCOL3);
    const bytes2 = new Uint8Array(protocol2.length + 1 + digest2.length + secret.length);
    bytes2.set(protocol2);
    bytes2.set(digest2, protocol2.length + 1);
    bytes2.set(secret, protocol2.length + 1 + digest2.length);
    return bytes2;
  }
  function hex2(bytes2) {
    return Array.from(bytes2, (byte) => byte.toString(16).padStart(2, "0")).join("");
  }

  // account/recovery.js
  var SECRET_BYTES2 = 32;
  async function recoveryKey(secret) {
    const key = await ed25519Key(secret);
    return { ...key, pubText: b64(key.pub), signer: await recoverySigner(key.pub) };
  }
  async function drawRecovery(random) {
    const secret = random(SECRET_BYTES2);
    const key = await recoveryKey(secret);
    return { secret, key };
  }
  var codeFor = (identifier2, secret) => encodeRecoveryCode(identifier2, secret);
  async function readCode(text2) {
    const read2 = await decodeRecoveryCode(text2);
    if (read2.error) throw new Refusal(read2.error);
    return { identifier: read2.identifier, key: await recoveryKey(fromB64url(read2.secret)) };
  }

  // account/pages/sign.js
  var sign_exports = {};
  __export(sign_exports, {
    describe: () => describe,
    readSigned: () => readSigned,
    run: () => run3,
    sign: () => sign
  });

  // account/sign_in.js
  var PROTOCOL4 = "cyfr-sign-in/v1";
  var CHALLENGE_BYTES = 32;
  var MAX_FRAGMENT_BYTES = 32768;
  var REQUIRED = ["protocol", "purpose", "audience", "challenge", "expires_at", "return"];
  var BY_PURPOSE = { sign_in: [], confirm: ["subject"], registry: ["registry_request"] };
  function readRequest(map) {
    if (!isObject(map)) refuse("invalid_field", { field: "request" });
    protocol(map, PROTOCOL4);
    if (!Object.hasOwn(map, "purpose")) refuse("missing_field", { field: "purpose" });
    if (!Object.hasOwn(BY_PURPOSE, map.purpose)) refuse("invalid_field", { field: "purpose" });
    fields(map, [...REQUIRED, ...BY_PURPOSE[map.purpose]]);
    check(map, "audience", isHome);
    binary(map, "challenge", CHALLENGE_BYTES);
    check(map, "expires_at", isMs);
    check(map, "return", (value) => isDirectoryUrl(value) && directoryOrigin(value).origin === map.audience);
    if (Object.hasOwn(map, "subject")) check(map, "subject", isDigest);
    if (Object.hasOwn(map, "registry_request")) {
      try {
        readToSign(map.registry_request);
      } catch (error) {
        if (error instanceof Refusal) refuse("invalid_field", { field: "registry_request" });
        throw error;
      }
    }
    return map;
  }
  function digest(request, signer) {
    if (request.purpose === "registry") return sha256(utf8(jcs({ ...request.registry_request, signer })));
    return sha256(utf8(jcs(request)));
  }
  function answer(request, { identifier: identifier2, credentialId, authenticatorData, clientData: clientData2, signature: signature2 }, signer) {
    return {
      challenge: request.challenge,
      identifier: identifier2,
      credential_id: b64(credentialId),
      authenticator_data: b64(authenticatorData),
      client_data: b64(clientData2),
      signature: b64(signature2),
      ...request.purpose === "registry" ? { signer } : {}
    };
  }
  function fragment(object) {
    return b64(utf8(jcs(object)));
  }
  function parseFragment(text2) {
    if (typeof text2 !== "string") refuse("invalid_fragment");
    if (text2.length > MAX_FRAGMENT_BYTES || utf8(text2).length > MAX_FRAGMENT_BYTES) refuse("too_large");
    try {
      const bytes2 = fromB64url(text2);
      if (b64(bytes2) !== text2) refuse("invalid_fragment");
      const json = new TextDecoder("utf-8", { fatal: true }).decode(bytes2);
      const object = JSON.parse(json);
      if (!isObject(object) || jcs(object) !== json) refuse("invalid_fragment");
      return object;
    } catch (_error) {
      return refuse("invalid_fragment");
    }
  }

  // account/pages/sign.js
  var OPERATIONS = {
    "handle.claim": ({ handle }, at) => `Claim the name @${handle} at ${at}`,
    "policy.accept": ({ policy_version }, at) => `Accept the terms (version ${policy_version}) at ${at}`,
    "tokens.mint": ({ label }, at) => `Create a publishing token named \u201C${label}\u201D at ${at}`,
    "appeal.file": ({ action_type, action_ref, argument }, at) => `Appeal the ${action_type} ${action_ref} at ${at}, saying: \u201C${argument}\u201D`,
    "publisher.claim": ({ slug: slug2 }, at) => `Claim the publisher name ${slug2} at ${at}`,
    "publisher.verify": ({ slug: slug2, label }, at) => `Confirm the publisher name ${slug2} at ${at}, with a publishing token named \u201C${label}\u201D`
  };
  function describe(request) {
    if (request.purpose === "sign_in") return `Sign in to ${request.audience}`;
    if (request.purpose === "confirm") return `Confirm a change at ${request.audience}`;
    const { operation, body, registry: registry2 } = request.registry_request;
    return OPERATIONS[operation](body, registry2);
  }
  function readSigned(text2, now) {
    const request = readRequest(parseFragment(text2));
    if (now >= request.expires_at) refuse("expired");
    return request;
  }
  async function sign(request, env2) {
    if (request.purpose !== "registry") {
      const assertion2 = await env2.passkeys.assert({ challenge: await digest(request) });
      if (!assertion2.identifier) refuse("no_account");
      return `${request.return}#${fragment(answer(request, assertion2))}`;
    }
    const place = await here(env2);
    const { state } = await place.directory.read(request.registry_request.identifier);
    const listed2 = state.keys.filter((key) => key.kind === "passkey");
    if (listed2.length === 0) refuse("no_passkey");
    let chosen = listed2[0];
    if (listed2.length > 1) {
      const picked = await env2.passkeys.assert({ challenge: env2.random(32), allow: listed2.map((key) => fromB64url(key.credential_id)) });
      chosen = listed2.find((key) => key.credential_id === b64(picked.credentialId));
      if (!chosen) refuse("unknown_passkey");
    }
    const assertion = await env2.passkeys.assert({ challenge: await digest(request, chosen.kid), allow: [fromB64url(chosen.credential_id)] });
    const identifier2 = assertion.identifier ?? request.registry_request.identifier;
    return `${request.return}#${fragment(answer(request, { ...assertion, identifier: identifier2 }, chosen.kid))}`;
  }
  function run3(doc, env2) {
    let request;
    try {
      request = readSigned(env2.location.hash.slice(1), env2.now());
    } catch (error) {
      say(doc, "refused-text", error instanceof Refusal ? words(error) : words(new Refusal("bad_link")));
      only(doc, "refused");
      return;
    }
    $(doc, "what").textContent = describe(request);
    only(doc, "ask");
    const button = $(doc, "use-passkey");
    button.addEventListener(
      "click",
      () => attempt(doc, button, "ask-error", async () => {
        if (env2.now() >= request.expires_at) refuse("expired");
        env2.navigate(await sign(request, env2));
      })
    );
  }

  // account/pages/new.js
  var STEPS = ["register", "append", "name", "done"];
  var Creation = class _Creation {
    /** A creation at this page's directory. */
    static async open(env2) {
      return new _Creation(env2, await here(env2));
    }
    constructor(env2, { config, directory: directory2, registry: registry2 }) {
      this.env = env2;
      this.config = config;
      this.directory = directory2;
      this.registry = registry2;
      this.attempts = attempts(env2.storage, env2.now);
      this.key = null;
      this.attempt = null;
    }
    /** Whether `name` can be claimed: resolves, or throws `name_invalid` or `name_taken`. */
    async check(name) {
      if (!isHandle(name)) refuse("name_invalid");
      const found = await this.registry.handle(name);
      if (found.answer) refuse("name_taken");
      if (found.error !== "handle_not_found") refuse(found.error);
    }
    /** Draw the recovery secret, sign the genesis with its key, and resolve to the code to show. */
    async begin(name) {
      const { secret, key } = await drawRecovery(this.env.random);
      const first = await signWith(genesis({ directory: this.config.directory, recovery: [key.pubText], at: this.env.now(), signer: key.signer }), key);
      const identifier2 = await identifier(first);
      this.key = key;
      const accepted = this.config.policy?.version ?? null;
      this.attempt = { identifier: identifier2, name, accepted, genesis: first, step: "passkey", created_at: this.env.now() };
      const code = await codeFor(identifier2, secret);
      secret.fill(0);
      return code;
    }
    /** "I saved it": create the passkey, sign its `add_key` and the two registry requests, and keep them all. */
    async savedCode() {
      const { identifier: identifier2, name, accepted, genesis: first } = this.attempt;
      const { credentialId, pub } = await this.env.passkeys.create({ userId: userId(identifier2), name: `@${name}`, challenge: this.env.random(32) });
      const { state } = await walk([first]);
      const entry = next(state, "add_key", { key: await keyOf({ pub, credentialId }) }, { at: this.env.now(), signer: this.key.signer });
      this.keep({
        add_key: await signWith(entry, this.key),
        accept: accepted === null ? null : await this.signed("policy.accept", { policy_version: accepted }),
        claim: await this.signed("handle.claim", { handle: name }),
        step: "register"
      });
    }
    /** Continue an attempt kept in this browser with the code the person typed. */
    async resume(kept, text2) {
      const { identifier: identifier2, key } = await readCode(text2);
      if (identifier2 !== kept.identifier) refuse("other_code");
      this.key = key;
      this.attempt = kept;
    }
    /** A new name for an account whose name was taken meanwhile; its claim is signed when sent. */
    rename(name) {
      if (!isHandle(name)) refuse("name_invalid");
      this.keep({ name, claim: null });
    }
    /** The person accepted the policy this page's configuration names now, the registry having asked for it. */
    acceptPolicy() {
      this.keep({ accepted: this.config.policy.version, accept: null });
    }
    keep(fields2) {
      this.attempt = { ...this.attempt, ...fields2 };
      this.attempts.save(this.attempt);
    }
    /** Submit from the step reached, saving each step as it completes; resolves once the name is the account's. */
    async submit() {
      while (this.attempt.step !== "done") {
        await this[this.attempt.step]();
        this.attempt = { ...this.attempt, step: STEPS[STEPS.indexOf(this.attempt.step) + 1] };
        if (this.attempt.step === "done") this.attempts.remove(this.attempt.identifier);
        else this.attempts.save(this.attempt);
      }
      this.key = null;
    }
    async register() {
      await this.directory.register(this.attempt.genesis);
    }
    async append() {
      await this.directory.append(this.attempt.identifier, this.attempt.add_key);
    }
    async name() {
      const { identifier: identifier2, name } = this.attempt;
      const found = await this.registry.handle(name);
      if (found.answer) {
        if (found.answer.identifier === identifier2) return;
        refuse("name_taken");
      }
      if (found.error !== "handle_not_found") refuse(found.error);
      const { accepted, accept } = this.attempt;
      if (accepted !== null && !accept?.done) {
        await this.send("accept", "policy.accept", { policy_version: accepted });
        this.keep({ accept: { ...this.attempt.accept, done: true } });
      }
      try {
        await this.send("claim", "handle.claim", { handle: name });
      } catch (error) {
        if (error instanceof Refusal && error.reason === "handle_taken") refuse("name_taken");
        if (error instanceof Refusal && error.reason === "policy_required") refuse("policy_changed");
        throw error;
      }
    }
    // Send the kept request `field` once: it is marked sent, and saved,
    // before it goes, and one sent before or past its expiry is signed again
    // with the same body.
    async send(field, operation, body) {
      let kept = this.attempt[field];
      if (!kept || kept.sent || this.env.now() >= kept.expires_at) kept = await this.signed(operation, body);
      this.keep({ [field]: { ...kept, sent: true } });
      return this.registry.send(operation, kept.bytes);
    }
    // A registry request signed by the recovery key: the bytes sent and when they expire.
    async signed(operation, body) {
      const request = compose({
        registry: this.registry.host,
        operation,
        identifier: this.attempt.identifier,
        signer: this.key.signer,
        nonce: this.env.random(16),
        now: this.env.now(),
        body
      });
      return { bytes: await signWith2(request, this.key), expires_at: request.expires_at };
    }
  };
  async function run4(doc, env2) {
    const params = new URLSearchParams(env2.location.hash.slice(1));
    let request = null;
    let creation;
    try {
      if (params.get("request")) request = readSigned(params.get("request"), env2.now());
      if (request && request.purpose !== "sign_in") refuse("bad_link");
      creation = await Creation.open(env2);
    } catch (error) {
      say(doc, "refused-text", words(error));
      only(doc, "refused");
      return;
    }
    const nameInput = $(doc, "name");
    nameInput.value = params.get("name") ?? "";
    const { policy } = creation.config;
    const accept = $(doc, "accept");
    if (policy) $(doc, "policy-link").href = policy.url;
    else $(doc, "acceptance").hidden = true;
    const create = $(doc, "create");
    const ready = () => create.disabled = !((accept.checked || !policy) && nameInput.value.trim());
    nameInput.addEventListener("input", ready);
    accept.addEventListener("change", ready);
    ready();
    const finish = () => {
      if (!request) return only(doc, "done");
      $(doc, "continue").textContent = `Continue to ${request.audience}`;
      only(doc, "done-return");
    };
    const proceed = async () => {
      only(doc, "working");
      say(doc, "working-error", "");
      $(doc, "retry").hidden = true;
      try {
        await creation.submit();
        finish();
      } catch (error) {
        if (error instanceof Refusal && error.reason === "name_taken") {
          $(doc, "rename-name").value = "";
          only(doc, "rename");
          return;
        }
        if (error instanceof Refusal && error.reason === "policy_changed" && creation.config.policy) {
          $(doc, "policy-again-link").href = creation.config.policy.url;
          $(doc, "accept-again").checked = false;
          only(doc, "policy-again");
          return;
        }
        say(doc, "working-error", words(error));
        $(doc, "retry").hidden = false;
      }
    };
    const kept = creation.attempts.list();
    if (kept.length > 0) {
      $(doc, "resume-name").textContent = `@${kept[kept.length - 1].name}`;
      only(doc, "resume");
    } else {
      only(doc, "choose");
    }
    const resume = $(doc, "resume-continue");
    resume.addEventListener(
      "click",
      () => attempt(doc, resume, "resume-error", async () => {
        await creation.resume(kept[kept.length - 1], $(doc, "resume-code").value);
        $(doc, "resume-code").value = "";
        await proceed();
      })
    );
    $(doc, "resume-new").addEventListener("click", () => only(doc, "choose"));
    create.addEventListener(
      "click",
      () => attempt(doc, create, "choose-error", async () => {
        const name = nameInput.value.trim().toLowerCase();
        await creation.check(name);
        const code = await creation.begin(name);
        drawCode(doc, $(doc, "code"), code);
        $(doc, "copy").onclick = () => copyCode($(doc, "copy"), code);
        only(doc, "show-code");
      })
    );
    $(doc, "print").addEventListener("click", () => env2.print());
    const saved = $(doc, "saved");
    saved.addEventListener(
      "click",
      () => attempt(doc, saved, "code-error", async () => {
        await creation.savedCode();
        $(doc, "code").replaceChildren();
        await proceed();
      })
    );
    $(doc, "retry").addEventListener("click", proceed);
    const rename = $(doc, "rename-submit");
    rename.addEventListener(
      "click",
      () => attempt(doc, rename, "rename-error", async () => {
        const name = $(doc, "rename-name").value.trim().toLowerCase();
        await creation.check(name);
        creation.rename(name);
        await proceed();
      })
    );
    const acceptAgain = $(doc, "accept-again");
    const again = $(doc, "policy-again-submit");
    const readyAgain = () => again.disabled = !acceptAgain.checked;
    acceptAgain.addEventListener("change", readyAgain);
    readyAgain();
    again.addEventListener(
      "click",
      () => attempt(doc, again, "policy-again-error", async () => {
        creation.acceptPolicy();
        await proceed();
      })
    );
    const go = $(doc, "continue");
    go.addEventListener(
      "click",
      () => attempt(doc, go, "return-error", async () => {
        if (env2.now() >= request.expires_at) refuse("expired");
        env2.navigate(await sign(request, env2));
      })
    );
  }

  // account/pages/recover.js
  var recover_exports = {};
  __export(recover_exports, {
    Recovery: () => Recovery,
    run: () => run5
  });
  var Recovery = class _Recovery {
    /** The account a typed code recovers; throws `not_a_code`, `typo` or `code_replaced`. */
    static async open(env2, place, text2) {
      const { identifier: identifier2, key } = await readCode(text2);
      const read2 = await place.directory.read(identifier2);
      if (!read2.state.recovery.includes(key.pubText)) refuse("code_replaced");
      return new _Recovery(env2, place, identifier2, key, read2);
    }
    constructor(env2, place, identifier2, key, { state, entries }) {
      Object.assign(this, { env: env2, place, identifier: identifier2, key, state, entries, fresh: null, pending: null });
    }
    /** A new passkey for the account, labelled with its name, which must be this account's. */
    async addPasskey(name) {
      if (!isHandle(name)) refuse("name_invalid");
      const found = await this.place.registry.handle(name);
      if (found.answer?.identifier !== this.identifier) refuse("name_elsewhere");
      const { credentialId, pub } = await this.env.passkeys.create({ userId: userId(this.identifier), name: `@${name}`, challenge: this.env.random(32) });
      return this.submit(await this.sign("add_key", { key: await keyOf({ pub, credentialId }) }));
    }
    removeKey(kid2) {
      return this.sign("remove_key", { kid: kid2 }).then((entry) => this.submit(entry));
    }
    /** Draw a new code; it is shown and saved before `addCode` or `replace` names it. */
    async drawCode() {
      this.fresh = await drawRecovery(this.env.random);
      const code = await codeFor(this.identifier, this.fresh.secret);
      this.fresh.secret.fill(0);
      return code;
    }
    async addCode() {
      return this.submit(await this.sign("add_recovery", { recovery: [...this.state.recovery, this.fresh.key.pubText] }));
    }
    /** Every key removed and the new code the only one: the account starts again from that code. */
    async replace() {
      return this.submit(await this.sign("recover", { keys: [], recovery: [this.fresh.key.pubText] }));
    }
    sign(kind, own) {
      return signWith(next(this.state, kind, own, { at: this.env.now(), signer: this.key.signer }), this.key);
    }
    /**
     * Append `entry`, then read the log again; with no entry, retry the one
     * still pending. An entry stays pending until a read shows it: after a
     * lost response, or a read that failed (`appendOnce`).
     */
    async submit(entry) {
      const retry = entry === void 0;
      if (!retry) this.pending = entry;
      const { kind } = this.pending;
      const read2 = await appendOnce(this.place.directory, this.identifier, this.pending, retry);
      this.pending = null;
      if (kind === "recover") this.key = this.fresh.key;
      if (kind === "recover" || kind === "add_recovery") this.fresh = null;
      Object.assign(this, read2);
    }
    /** The account's keys as the page lists them. */
    keys() {
      const at = addedAt(this.entries);
      return this.state.keys.map((key) => ({ kid: key.kid, kind: key.kind, code: shortCode(key.kid), added: at.get(key.kid) }));
    }
  };
  async function run5(doc, env2) {
    let place;
    try {
      place = await here(env2);
    } catch (error) {
      say(doc, "refused-text", words(error));
      only(doc, "refused");
      return;
    }
    only(doc, "enter");
    let recovery2 = null;
    let afterSaved = null;
    const draw = () => {
      const rows = recovery2.keys().map((key) => {
        const row = doc.createElement("li");
        const label = doc.createElement("span");
        label.textContent = keyLabel(key);
        const remove = doc.createElement("button");
        remove.type = "button";
        remove.textContent = "Remove";
        remove.addEventListener("click", () => act(remove, () => recovery2.removeKey(key.kid)));
        row.append(label, remove);
        return row;
      });
      $(doc, "keys").replaceChildren(...rows);
      $(doc, "no-keys").hidden = rows.length > 0;
      only(doc, "account");
    };
    const act = (button, action) => attempt(doc, button, "account-error", async () => {
      $(doc, "retry").hidden = true;
      try {
        await action();
      } catch (error) {
        $(doc, "retry").hidden = !recovery2.pending;
        throw error;
      }
      draw();
    });
    const enter = $(doc, "enter-code");
    enter.addEventListener(
      "click",
      () => attempt(doc, enter, "enter-error", async () => {
        recovery2 = await Recovery.open(env2, place, $(doc, "code-input").value);
        $(doc, "code-input").value = "";
        draw();
      })
    );
    const addPasskey = $(doc, "add-passkey");
    addPasskey.addEventListener("click", () => act(addPasskey, () => recovery2.addPasskey($(doc, "passkey-name").value.trim().toLowerCase())));
    const showCode = async (then) => {
      const code = await recovery2.drawCode();
      drawCode(doc, $(doc, "code"), code);
      $(doc, "copy").textContent = "Copy";
      $(doc, "copy").onclick = () => copyCode($(doc, "copy"), code);
      afterSaved = then;
      only(doc, "show-code");
    };
    const addCode = $(doc, "add-code");
    addCode.addEventListener("click", () => attempt(doc, addCode, "account-error", () => showCode(() => recovery2.addCode())));
    const replace = $(doc, "replace");
    replace.addEventListener("click", () => attempt(doc, replace, "account-error", () => showCode(() => recovery2.replace())));
    $(doc, "print").addEventListener("click", () => env2.print());
    const saved = $(doc, "saved");
    saved.addEventListener("click", () => {
      $(doc, "code").replaceChildren();
      draw();
      act(saved, afterSaved);
    });
    const retry = $(doc, "retry");
    retry.addEventListener("click", () => act(retry, () => recovery2.submit()));
  }

  // account/main.js
  var PAGES = { new: new_exports, sign: sign_exports, add: add_exports, recover: recover_exports, devices: devices_exports };
  function storage() {
    try {
      return window.localStorage;
    } catch (_error) {
      return null;
    }
  }
  var env = {
    origin: window.location.origin,
    location: window.location,
    passkeys: passkeys(navigator.credentials, window.location.hostname),
    fetch: (url, init) => window.fetch(url, init),
    storage: storage(),
    now: () => Date.now(),
    random: (size) => crypto.getRandomValues(new Uint8Array(size)),
    navigate: (url) => window.location.assign(url),
    print: () => window.print()
  };
  PAGES[document.body.dataset.page]?.run(document, env);
  if ("serviceWorker" in navigator) navigator.serviceWorker.register("sw.js", { scope: "./" }).catch(() => {
  });
})();

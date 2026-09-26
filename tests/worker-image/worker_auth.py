# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""`Prima.WorkerAuth` and `Prima.Assignment` as the worker image tests spell
them, so a scripted control plane can mint what CYFR mints and verify what
a worker sends, with nothing but the standard library.

Every key is HMAC-SHA256 of the root over a label and field values one per
line (`Prima.MacEnvelope`); a header is `v1 kind=<kind> name=value … body=<hex>
mac=<b64url>` signed over the envelope's canonical string; a sealed value is
`base64url(iv ‖ tag ‖ ciphertext)` under AES-256-GCM with the label and
fields as additional data; an assignment token is `base64url(jcs) "."
base64url(mac)` under the assign key. AES-GCM is written out here rather
than imported, so the suite runs wherever `python3` does.

The wire (`Prima.WorkerWire`) is versioned: a header's first token is the
version token `v1`, and one spelling another version (`v` and a decimal
number) is `unknown_version` before the body is read; every body and answer
carries `"v": 1` as its first member, and a body without it, or at another
version, is `unknown_version` once opened and before its `op` is read. A
guest's outbound target is an `egress_pin` host call answered with a
`Prima.PinnedTarget` or refused by name (`read_pin_request`, `read_pin`).

`check_vectors` reproduces every value of `tests/fixtures/worker_auth.json`
(the primitives) and of the message vectors `host_api.json` and
`worker_api.json` beside it (every call, request and answer, sealed and
signed from the fixed keys), which every side of the protocol consumes, and
refuses to serve otherwise. `python3 worker_auth.py --self-check` runs it.
"""

import base64
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import sys
import time
import urllib.parse

PREFIX = "cyfr-opus/v1"
VERSION = 1
VERSION_TOKEN = "v1"
ANY_VERSION_TOKEN = re.compile(r"v(0|[1-9][0-9]*)")
ATTEMPT_FIELDS = ("athanor_id", "execution_id", "attempt", "fence", "generation", "service")
CALL_FIELDS = ATTEMPT_FIELDS + ("boot", "runner", "member", "ts", "nonce")
DISPATCH_FIELDS = ("service", "boot", "ts", "nonce")
INTEGER_FIELDS = {"fence", "generation", "ts"}
WINDOW_MS = 30_000
CLAIM_WINDOW_MS = 30_000
TEXT = re.compile(r"^[\x21-\x7E]{1,256}$")
BODY_HASH = re.compile(r"^[0-9a-f]{64}$")


# ---------------------------------------------------------------------------
# Encodings
# ---------------------------------------------------------------------------


def b64url(data):
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def unb64url(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def digest(data):
    """A component digest as CYFR spells it: `sha256:` and the lowercase hex."""
    return "sha256:" + sha256_hex(data)


def jcs(value):
    """RFC 8785 over CYFR's restricted domain (strings, integers, booleans,
    arrays, string-keyed objects): sorted keys, no whitespace, the seven
    two-character escapes and \\u00xx for the other C0 controls."""
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None or isinstance(value, float):
        raise ValueError("JCS admits no null or float")
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, (list, tuple)):
        return "[" + ",".join(jcs(v) for v in value) + "]"
    if isinstance(value, dict):
        keys = sorted(value.keys(), key=lambda k: k.encode("utf-16-be"))
        return "{" + ",".join(json.dumps(k, ensure_ascii=False) + ":" + jcs(value[k]) for k in keys) + "}"
    raise ValueError(f"JCS admits no {type(value).__name__}")


def write_value(name, value):
    if name in INTEGER_FIELDS:
        if not isinstance(value, int) or value < 0 or value > 9_007_199_254_740_991:
            raise ValueError(f"{name} is not a field integer")
        text = str(value)
    else:
        if not isinstance(value, str):
            raise ValueError(f"{name} is not a field string")
        text = value
    if not TEXT.match(text):
        raise ValueError(f"{name} is not field text")
    return text


def lines(label, names, fields):
    return "\n".join([label] + [write_value(n, fields[n]) for n in names])


# ---------------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------------


def derive(key, text):
    return hmac.new(key, text.encode(), hashlib.sha256).digest()


def decode_root(text):
    if isinstance(text, str) and re.fullmatch(r"[0-9a-fA-F]{64}", text):
        return bytes.fromhex(text)
    return None


def assign_key(root):
    return derive(root, f"{PREFIX}/assign")


def worker_key(root, service):
    return derive(root, lines(f"{PREFIX}/worker", ("service",), {"service": service}))


def dispatch_key(wkey):
    return derive(wkey, f"{PREFIX}/dispatch")


def dispatch_seal_key(wkey):
    return derive(wkey, f"{PREFIX}/dseal")


def attempt_call_key(root, attempt):
    return derive(root, lines(f"{PREFIX}/call", ATTEMPT_FIELDS, attempt))


def attempt_seal_key(root, attempt):
    return derive(root, lines(f"{PREFIX}/seal", ATTEMPT_FIELDS, attempt))


# ---------------------------------------------------------------------------
# Headers
# ---------------------------------------------------------------------------


def canonical(kind, names, fields, body_hash):
    return "\n".join([f"{PREFIX}/{kind}"] + [write_value(n, fields[n]) for n in names] + [body_hash])


def header(kind, names, key, fields, body):
    body_hash = sha256_hex(body)
    mac = b64url(hmac.new(key, canonical(kind, names, fields, body_hash).encode(), hashlib.sha256).digest())
    pairs = " ".join(f"{n}={write_value(n, fields[n])}" for n in names)
    return f"v1 kind={kind} {pairs} body={body_hash} mac={mac}"


def header_version(text):
    """None for a header at this wire's version; `unknown_version` for one
    whose first token spells another (`v` and a decimal number), which a
    listener answers before it reads the body; `malformed` for a header
    with no version token at all (`V1`, `Bearer`, nothing)."""
    if not isinstance(text, str):
        return "malformed"
    token = text.split(" ")[0]
    if token == VERSION_TOKEN:
        return None
    return "unknown_version" if ANY_VERSION_TOKEN.fullmatch(token) else "malformed"


def parse(kind, names, text):
    """The fields, body hash and MAC of a header of `kind`, or None."""
    if not isinstance(text, str):
        return None
    tokens = text.split(" ")
    if tokens[0] != "v1":
        return None
    pairs = {}
    for token in tokens[1:]:
        name, sep, value = token.partition("=")
        if not sep or not name or name in pairs:
            return None
        pairs[name] = value
    if sorted(pairs) != sorted(list(names) + ["kind", "body", "mac"]):
        return None
    if pairs["kind"] != kind or not TEXT.match(pairs["mac"]) or not BODY_HASH.match(pairs["body"]):
        return None
    fields = {}
    for name in names:
        value = pairs[name]
        if not TEXT.match(value):
            return None
        if name in INTEGER_FIELDS:
            if not re.fullmatch(r"0|[1-9][0-9]*", value) or int(value) > 9_007_199_254_740_991:
                return None
            fields[name] = int(value)
        else:
            fields[name] = value
    return fields, pairs["body"], pairs["mac"]


def verify_header(kind, names, key, fields, body_hash, mac):
    expected = b64url(hmac.new(key, canonical(kind, names, fields, body_hash).encode(), hashlib.sha256).digest())
    return hmac.compare_digest(expected, mac)


def within_window(ts, now):
    return abs(ts - now) <= WINDOW_MS


def host_call_header(call_key, call, body):
    return header("call", CALL_FIELDS, call_key, call, body)


def request_header(dkey, request, body):
    return header("request", DISPATCH_FIELDS, dkey, request, body)


def report_header(dkey, report, body):
    return header("report", DISPATCH_FIELDS, dkey, report, body)


def verify_host_call_header(root, text, now, generation, member):
    """The call's fields and the body hash its header names, or the refusal
    name, from the header alone and in the contract's order: another
    version, a header that does not parse, a timestamp outside the window, a
    MAC that is not the call key's, another generation, another member. A
    call names the member it is addressed to — the one that issued its
    attempt's assignment — and no other member answers it."""
    refusal = header_version(text)
    if refusal:
        return None, refusal
    parsed = parse("call", CALL_FIELDS, text)
    if parsed is None:
        return None, "malformed"
    call, body_hash, mac = parsed
    if not within_window(call["ts"], now):
        return None, "outside_window"
    if not verify_header("call", CALL_FIELDS, attempt_call_key(root, call), call, body_hash, mac):
        return None, "bad_mac"
    if call["generation"] != generation:
        return None, "generation_mismatch"
    if call["member"] != member:
        return None, "member_mismatch"
    return (call, body_hash), None


def verify_body(body_hash, body):
    """Whether `body` is the bytes a verified header named."""
    return hmac.compare_digest(body_hash, sha256_hex(body))


def verify_host_call(root, text, body, now, generation, member):
    """The call's fields, or the refusal name: the header's refusals, then a
    body that is not the one the header named (`bad_mac`)."""
    verified, refusal = verify_host_call_header(root, text, now, generation, member)
    if refusal:
        return None, refusal
    call, body_hash = verified
    if not verify_body(body_hash, body):
        return None, "bad_mac"
    return call, None


def verify_report_header(root, text, now):
    """A report's fields and the body hash its header names, or the refusal
    name, from the header alone: another version, a header that does not
    parse, a timestamp outside the window, a MAC that is not the dispatch
    key of the service it names."""
    refusal = header_version(text)
    if refusal:
        return None, refusal
    parsed = parse("report", DISPATCH_FIELDS, text)
    if parsed is None:
        return None, "malformed"
    report, body_hash, mac = parsed
    if not within_window(report["ts"], now):
        return None, "outside_window"
    key = dispatch_key(worker_key(root, report["service"]))
    if not verify_header("report", DISPATCH_FIELDS, key, report, body_hash, mac):
        return None, "bad_mac"
    return (report, body_hash), None


def verify_report(root, text, body, now):
    verified, refusal = verify_report_header(root, text, now)
    if refusal:
        return None, refusal
    report, body_hash = verified
    if not verify_body(body_hash, body):
        return None, "bad_mac"
    return report, None


def verify_request(dkey, text, body, now):
    """A request CYFR sends a worker service, verified as the service
    verifies it under its dispatch key, or the refusal name."""
    refusal = header_version(text)
    if refusal:
        return None, refusal
    parsed = parse("request", DISPATCH_FIELDS, text)
    if parsed is None:
        return None, "malformed"
    request, body_hash, mac = parsed
    if not within_window(request["ts"], now):
        return None, "outside_window"
    if not verify_header("request", DISPATCH_FIELDS, dkey, request, body_hash, mac):
        return None, "bad_mac"
    if not verify_body(body_hash, body):
        return None, "bad_mac"
    return request, None


# ---------------------------------------------------------------------------
# Bodies and answers (`Prima.WorkerWire`)
# ---------------------------------------------------------------------------


def request_body(op, args):
    """The body of a call or request: `v` first, then `op` and `args`."""
    return json.dumps({"v": VERSION, "op": op, "args": args}, separators=(",", ":"))


def answer_body(answer):
    """An answer as the wire writes it: `v` first, then `ok` or `error` and its fields."""
    return json.dumps({"v": VERSION, **answer}, separators=(",", ":"))


def _versioned(decoded):
    v = decoded.get("v")
    return isinstance(v, int) and not isinstance(v, bool) and v == VERSION


def read_body(op, body):
    """The args of an opened body posted at `op`'s route, or the refusal
    name: `malformed` for a body that is not a JSON object,
    `unknown_version` for one without `v` or at another version (read
    before its `op`), and `malformed` for an `op` that is not the route's or
    `args` that are not an object."""
    try:
        decoded = json.loads(body)
    except (ValueError, TypeError):
        return None, "malformed"
    if not isinstance(decoded, dict):
        return None, "malformed"
    if not _versioned(decoded):
        return None, "unknown_version"
    if decoded.get("op") != op or not isinstance(decoded.get("args"), dict):
        return None, "malformed"
    return decoded["args"], None


def read_answer(text):
    """An answer's `ok` value as `("ok", value)`, its refusal as `("error",
    name, fields)`, or None for an answer the wire counts as lost: not a
    JSON object, without `v` or at another version, or neither `ok` nor
    `error`."""
    try:
        decoded = json.loads(text)
    except (ValueError, TypeError):
        return None
    if not isinstance(decoded, dict) or not _versioned(decoded):
        return None
    if "ok" in decoded and set(decoded) == {"v", "ok"}:
        return ("ok", decoded["ok"])
    if isinstance(decoded.get("error"), str):
        return ("error", decoded["error"], {k: v for k, v in decoded.items() if k not in ("v", "error")})
    return None


def first_member(text):
    """The name of a JSON object's first member as written."""
    match = re.match(r'^\{"([^"]*)"', text)
    return match.group(1) if match else None


# ---------------------------------------------------------------------------
# Pinned targets (`Prima.PinnedTarget`)
# ---------------------------------------------------------------------------

PIN_PURPOSES = ("fetch", "stream", "redirect")
PIN_REFUSALS = ("denied", "metadata", "resolution", "redirect_credentials", "malformed")
PIN_MEMBERS = {"id", "ip", "family", "scheme", "port", "host", "expires_at"}
PIN_ID = re.compile(r"[A-Za-z0-9_-]{1,128}")
_LABEL = r"[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?"
HOSTNAME = re.compile(r"(?=.{1,253}\Z)" + _LABEL + r"(?:\." + _LABEL + r")*\.?")
DEFAULT_PORTS = {"http": 80, "https": 443}


def parse_url(url):
    """`(scheme, host, port)` of an `http` or `https` URL with a host, the
    scheme lowercased, the host lowercased and an IPv6 literal bracketed, as
    a pin names them, the port the scheme's default when the URL names none;
    None otherwise."""
    if not isinstance(url, str):
        return None
    try:
        parts = urllib.parse.urlsplit(url)
        port = parts.port
    except ValueError:
        return None
    scheme = parts.scheme.lower()
    if scheme not in DEFAULT_PORTS or not parts.hostname:
        return None
    host = parts.hostname.lower()
    try:
        if ipaddress.ip_address(host).version == 6:
            host = f"[{host}]"
    except ValueError:
        pass
    port = port if port is not None else DEFAULT_PORTS[scheme]
    if not 1 <= port <= 65_535:
        return None
    return scheme, host, port


def read_pin_request(args):
    """An `egress_pin` call's args, read: `(url, purpose, from)` for exactly
    `url` and `purpose`, and `from` (a pin id) for a `redirect` alone; None
    for anything else, which is `malformed`."""
    if not isinstance(args, dict):
        return None
    url, purpose = args.get("url"), args.get("purpose")
    if purpose not in PIN_PURPOSES or parse_url(url) is None:
        return None
    if purpose == "redirect":
        from_ = args.get("from")
        if set(args) != {"url", "purpose", "from"} or not isinstance(from_, str) or not PIN_ID.fullmatch(from_):
            return None
        return url, purpose, from_
    if set(args) != {"url", "purpose"}:
        return None
    return url, purpose, None


def _pin_host(host):
    if not isinstance(host, str):
        return False
    if host.startswith("[") and host.endswith("]") and len(host) > 2:
        try:
            return ipaddress.ip_address(host[1:-1]).version == 6
        except ValueError:
            return False
    return bool(HOSTNAME.fullmatch(host))


def read_pin(wire):
    """The pin a JSON answer's `ok` spells, or None: exactly its seven
    members, an id, an IP literal whose family is `family`, an `http` or
    `https` scheme, a port of 1 to 65535, a hostname or bracketed IPv6
    literal and an expiry of 0 to 2^53 - 1."""
    if not isinstance(wire, dict) or set(wire) != PIN_MEMBERS:
        return None
    try:
        family = ipaddress.ip_address(wire["ip"]).version if isinstance(wire["ip"], str) else None
    except ValueError:
        family = None
    port, expires_at = wire["port"], wire["expires_at"]
    if (
        not isinstance(wire["id"], str)
        or not PIN_ID.fullmatch(wire["id"])
        or family is None
        or wire["family"] != family
        or isinstance(wire["family"], bool)
        or wire["scheme"] not in DEFAULT_PORTS
        or not _count(port)
        or not 1 <= port <= 65_535
        or not _pin_host(wire["host"])
        or not _count(expires_at)
        or expires_at > MAX_INTEGER
    ):
        return None
    return wire


# ---------------------------------------------------------------------------
# AES-256-GCM (NIST SP 800-38D), for the sealed values
# ---------------------------------------------------------------------------

_SBOX = [0] * 256
_INV = [0] * 256


def _build_sbox():
    p = q = 1
    while True:
        # p * 3 in GF(2^8), q / 3
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ (q << 1) ^ (q << 2) ^ (q << 3) ^ (q << 4)
        x = (x ^ (x >> 8) ^ 0x63) & 0xFF
        _SBOX[p] = x
        _INV[x] = p
        if p == 1:
            break
    _SBOX[0] = 0x63
    _INV[0x63] = 0


_build_sbox()


def _xtime(b):
    return ((b << 1) ^ 0x1B) & 0xFF if b & 0x80 else b << 1


def _expand_key(key):
    words = [list(key[i : i + 4]) for i in range(0, 32, 4)]
    rcon = 1
    for i in range(8, 60):
        word = list(words[i - 1])
        if i % 8 == 0:
            word = word[1:] + word[:1]
            word = [_SBOX[b] for b in word]
            word[0] ^= rcon
            rcon = _xtime(rcon)
        elif i % 8 == 4:
            word = [_SBOX[b] for b in word]
        words.append([a ^ b for a, b in zip(words[i - 8], word)])
    return [sum(words[r * 4 : r * 4 + 4], []) for r in range(15)]


def _encrypt_block(round_keys, block):
    state = [b ^ k for b, k in zip(block, round_keys[0])]
    for r in range(1, 15):
        state = [_SBOX[b] for b in state]
        state = [state[(i + 4 * (i % 4)) % 16] for i in range(16)]
        if r != 14:
            mixed = []
            for c in range(4):
                a = state[c * 4 : c * 4 + 4]
                t = a[0] ^ a[1] ^ a[2] ^ a[3]
                mixed += [
                    a[0] ^ t ^ _xtime(a[0] ^ a[1]),
                    a[1] ^ t ^ _xtime(a[1] ^ a[2]),
                    a[2] ^ t ^ _xtime(a[2] ^ a[3]),
                    a[3] ^ t ^ _xtime(a[3] ^ a[0]),
                ]
            state = mixed
        state = [b ^ k for b, k in zip(state, round_keys[r])]
    return bytes(state)


def _gf_mul(x, y):
    r = 0
    v = x
    for i in range(128):
        if (y >> (127 - i)) & 1:
            r ^= v
        v = (v >> 1) ^ (0xE1 << 120) if v & 1 else v >> 1
    return r


def _ghash(h, aad, ciphertext):
    def blocks(data):
        for i in range(0, len(data), 16):
            yield int.from_bytes(data[i : i + 16].ljust(16, b"\0"), "big")

    y = 0
    for block in list(blocks(aad)) + list(blocks(ciphertext)):
        y = _gf_mul(y ^ block, h)
    length = ((len(aad) * 8) << 64) | (len(ciphertext) * 8)
    return _gf_mul(y ^ length, h)


def aes_gcm(key, iv, data, aad, encrypt):
    """AES-256-GCM with a 96-bit IV and a 128-bit tag: encrypt answers
    (ciphertext, tag); decrypt takes (ciphertext, tag) as `data` and answers
    the plaintext or None."""
    round_keys = _expand_key(key)
    h = int.from_bytes(_encrypt_block(round_keys, bytes(16)), "big")
    j0 = iv + b"\0\0\0\1"
    base = int.from_bytes(j0, "big")

    def keystream(n):
        out = b""
        for i in range(n):
            counter = (base & ~0xFFFFFFFF) | ((base + 1 + i) & 0xFFFFFFFF)
            out += _encrypt_block(round_keys, counter.to_bytes(16, "big"))
        return out

    if encrypt:
        stream = keystream((len(data) + 15) // 16)
        ciphertext = bytes(a ^ b for a, b in zip(data, stream))
        tag = _ghash(h, aad, ciphertext) ^ int.from_bytes(_encrypt_block(round_keys, j0), "big")
        return ciphertext, tag.to_bytes(16, "big")
    ciphertext, tag = data
    expected = _ghash(h, aad, ciphertext) ^ int.from_bytes(_encrypt_block(round_keys, j0), "big")
    if not hmac.compare_digest(expected.to_bytes(16, "big"), tag):
        return None
    stream = keystream((len(ciphertext) + 15) // 16)
    return bytes(a ^ b for a, b in zip(ciphertext, stream))


def seal(key, label, names, fields, plaintext, iv=None):
    iv = iv or secrets.token_bytes(12)
    ciphertext, tag = aes_gcm(key, iv, plaintext, lines(label, names, fields).encode(), True)
    return b64url(iv + tag + ciphertext)


def open_sealed(key, label, names, fields, sealed):
    try:
        raw = unb64url(sealed)
    except (ValueError, TypeError):
        return None
    if len(raw) < 28:
        return None
    return aes_gcm(key, raw[:12], (raw[28:], raw[12:28]), lines(label, names, fields).encode(), False)


def seal_call(seal_key, direction, call, plaintext, iv=None):
    return seal(seal_key, f"{PREFIX}/call-{direction}", CALL_FIELDS, call, plaintext, iv)


def open_call(seal_key, direction, call, sealed):
    return open_sealed(seal_key, f"{PREFIX}/call-{direction}", CALL_FIELDS, call, sealed)


def seal_attempt_keys(dseal_key, attempt, call_key, seal_key, iv=None):
    named = {name: attempt[name] for name in ATTEMPT_FIELDS}
    sealed = seal(dseal_key, f"{PREFIX}/attempt-keys", ATTEMPT_FIELDS, named, call_key + seal_key, iv)
    return b64url(jcs(named).encode()) + "." + sealed


# ---------------------------------------------------------------------------
# Assignments
# ---------------------------------------------------------------------------


def sign_assignment(wire, akey):
    payload = jcs(wire).encode()
    return b64url(payload) + "." + b64url(hmac.new(akey, payload, hashlib.sha256).digest())


def read_assignment(token):
    payload64, _, _ = token.partition(".")
    return json.loads(unb64url(payload64))


# ---------------------------------------------------------------------------
# A worker service's status (`Prima.WorkerAPI.read_status/1`)
# ---------------------------------------------------------------------------

STATUS_MEMBERS = {"service", "boot", "runners", "attempts", "memory_bytes", "refusal"}
RUNNER_STATES = {"fresh", "idle", "busy", "tainted"}
REASON = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
CONTROL = re.compile(r"[\x00-\x1F\x7F]")
MAX_MESSAGE_BYTES = 1024
MAX_INTEGER = 2**53 - 1


def _count(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def read_status(wire):
    """The status a JSON answer spells, or None: exactly its six members, a count for every runner state and no other, attempt id strings, a memory bound of 1 to 2^53 - 1 or null, and a refusal of a reason code and a sentence of 1 to 1024 bytes without a control character, or null."""
    if not isinstance(wire, dict) or set(wire) != STATUS_MEMBERS:
        return None
    runners, refusal, bound = wire["runners"], wire["refusal"], wire["memory_bytes"]
    if not isinstance(wire["service"], str) or not isinstance(wire["boot"], str):
        return None
    if not isinstance(runners, dict) or set(runners) != RUNNER_STATES or not all(_count(c) for c in runners.values()):
        return None
    if not isinstance(wire["attempts"], list) or not all(isinstance(a, str) for a in wire["attempts"]):
        return None
    if bound is not None and not (_count(bound) and 0 < bound <= MAX_INTEGER):
        return None
    if refusal is not None:
        if not isinstance(refusal, dict) or set(refusal) != {"reason", "message"}:
            return None
        reason, message = refusal["reason"], refusal["message"]
        if not isinstance(reason, str) or not REASON.match(reason):
            return None
        if not isinstance(message, str) or not 1 <= len(message.encode()) <= MAX_MESSAGE_BYTES or CONTROL.search(message):
            return None
    return wire


def nonce():
    return b64url(secrets.token_bytes(18))


def now_ms():
    return int(time.time() * 1000)


def new_id(prefix):
    return f"{prefix}_{secrets.token_hex(12)}"


# ---------------------------------------------------------------------------
# The vectors
# ---------------------------------------------------------------------------


def check_vectors(path):
    """Reproduce every value of the vector file, or raise naming the first that differs."""
    with open(path) as f:
        v = json.load(f)
    root = decode_root(v["root_hex"])
    assert root is not None, "root_hex"
    for text in v["root_text"]["valid"]:
        assert decode_root(text) == root, f"root text {text!r} should decode"
    for text in v["root_text"]["invalid"]:
        assert decode_root(text) is None, f"root text {text!r} should be refused"

    service, attempt, boot, member = v["service"], v["attempt"], v["boot"], v["member"]
    keys = v["keys"]
    assert assign_key(root).hex() == keys["assign_hex"], "assign key"
    wkey = worker_key(root, service)
    assert wkey.hex() == keys["worker_hex"], "worker key"
    assert dispatch_key(wkey).hex() == keys["dispatch_hex"], "dispatch key"
    assert dispatch_seal_key(wkey).hex() == keys["dispatch_seal_hex"], "dispatch seal key"
    ckey, skey = attempt_call_key(root, attempt), attempt_seal_key(root, attempt)
    assert ckey.hex() == keys["attempt_call_hex"], "attempt call key"
    assert skey.hex() == keys["attempt_seal_hex"], "attempt seal key"

    call = dict(attempt, boot=boot, runner=v["call"]["runner"], member=member, ts=v["call"]["ts"], nonce=v["call"]["nonce"])
    body = v["call"]["body"].encode()
    generation, ts, header_text = attempt["generation"], v["call"]["ts"], v["call"]["header"]
    assert canonical("call", CALL_FIELDS, call, sha256_hex(body)) == v["call"]["canonical"], "call canonical"
    assert host_call_header(ckey, call, body) == header_text, "call header"
    verified, refusal = verify_host_call(root, header_text, body, ts, generation, member)
    assert refusal is None and verified == call, f"call verifies ({refusal})"
    assert verify_host_call(root, header_text, body, ts, generation + 1, member)[1] == "generation_mismatch"
    assert verify_host_call(root, header_text, body, ts, generation, member + "x")[1] == "member_mismatch"
    assert verify_host_call(root, header_text, body + b" ", ts, generation, member)[1] == "bad_mac"
    assert verify_host_call(root, header_text, body, ts + WINDOW_MS + 1, generation, member)[1] == "outside_window"

    for kind, fn in (("request", request_header), ("report", report_header)):
        vec = v[kind]
        fields = {"service": service, "boot": boot, "ts": vec["ts"], "nonce": vec["nonce"]}
        vbody = vec["body"].encode()
        assert canonical(kind, DISPATCH_FIELDS, fields, sha256_hex(vbody)) == vec["canonical"], f"{kind} canonical"
        assert fn(dispatch_key(wkey), fields, vbody) == vec["header"], f"{kind} header"
    report, refusal = verify_report(root, v["report"]["header"], v["report"]["body"].encode(), v["report"]["ts"])
    assert refusal is None and report["service"] == service, "report verifies"
    # A report names the member whose attempts its runner held in its
    # args rather than its header: the header's kind is shared with the
    # requests CYFR sends a worker, which name no member.
    assert json.loads(v["report"]["body"])["args"]["member"] == member, "the report names its member"

    sealed = seal_attempt_keys(dispatch_seal_key(wkey), attempt, ckey, skey, bytes.fromhex(v["sealed_attempt_keys"]["iv_hex"]))
    assert sealed == v["sealed_attempt_keys"]["sealed"], "sealed attempt keys"
    named, _, box = sealed.partition(".")
    assert open_sealed(dispatch_seal_key(wkey), f"{PREFIX}/attempt-keys", ATTEMPT_FIELDS, attempt, box) == ckey + skey, "attempt keys open"

    sc = v["sealed_call"]
    assert seal_call(skey, "body", call, body, bytes.fromhex(sc["body_iv_hex"])) == sc["body_sealed"], "sealed body"
    assert open_call(skey, "body", call, sc["body_sealed"]) == body, "sealed body opens"
    answer = sc["answer"].encode()
    assert seal_call(skey, "answer", call, answer, bytes.fromhex(sc["answer_iv_hex"])) == sc["answer_sealed"], "sealed answer"
    assert open_call(skey, "answer", call, sc["answer_sealed"]) == answer, "sealed answer opens"
    assert open_call(skey, "body", call, sc["answer_sealed"]) is None, "a direction opens only its own"

    a = v["assignment"]
    wire = json.loads(a["payload"])
    assert wire["member"] == member, "the assignment names its member"
    assert wire["host_url"] == v["host_url"], "the assignment names its member's address"
    assert jcs(wire) == a["payload"], "assignment JCS"
    assert sign_assignment(wire, assign_key(root)) == a["token"], "assignment token"
    assert read_assignment(a["token"]) == wire, "assignment reads"

    assert header_version(header_text) is None, "the call header is at this version"
    for token, refusal in (("v2", "unknown_version"), ("v0", "unknown_version"), ("v10", "unknown_version"),
                           ("V1", "malformed"), ("v01", "malformed"), ("Bearer", "malformed")):
        other = token + header_text[len("v1"):]
        assert verify_host_call(root, other, body, ts, generation, member)[1] == refusal, f"a {token} header is {refusal}"
    assert header_version("") == "malformed", "an empty header is malformed"

    fixtures = os.path.dirname(path)
    check_host_api(os.path.join(fixtures, "host_api.json"), v)
    check_worker_api(os.path.join(fixtures, "worker_api.json"), v)
    return True


def _check_answer(text, what):
    assert first_member(text) == "v", f"{what}: v is the answer's first member"
    assert read_answer(text) is not None, f"{what}: the answer reads"


def check_host_api(path, primitives):
    """Reproduce every call of the HostAPI message vectors from its fields
    under the fixed keys: its body, its seal in the body direction, its
    header over the sealed bytes, its answer's seal in the answer direction;
    and every refusal, pre-body and after the body, by name."""
    with open(path, encoding="utf-8") as f:
        v = json.load(f)
    keys = v["keys"]
    root = decode_root(keys["root_hex"])
    assert keys["root_hex"] == primitives["root_hex"], "host_api: the root is worker_auth.json's"
    assert {k: x for k, x in keys.items() if k != "root_hex"} == primitives["keys"], "host_api: the keys are worker_auth.json's"
    assert v["version"] == VERSION and v["auth_header"] == "x-cyfr-auth" and v["window_ms"] == WINDOW_MS, "host_api: version, header, window"
    standing = v["standing"]
    generation, member = standing["generation"], standing["member"]
    assert set(v["routes"]) == set(v["retries"]) == set(v["timeouts_ms"]), "host_api: every callback has a route, a retry class and a timeout"
    for callback, route in v["routes"].items():
        assert route == f"/host/v1/{callback}", f"host_api: {callback}'s route"
    assert "egress_pin" in v["routes"], "host_api: egress_pin is a callback"

    def reproduce(call, what, callback):
        fields = call["fields"]
        body = call["body"].encode()
        assert first_member(call["body"]) == "v", f"{what}: v is the body's first member"
        args, refusal = read_body(callback, call["body"])
        assert refusal is None, f"{what}: the body reads ({refusal})"
        assert call["body"] == request_body(callback, args), f"{what}: the body is the wire's writing"
        ckey, skey = attempt_call_key(root, fields), attempt_seal_key(root, fields)
        sealed = seal_call(skey, "body", fields, body, bytes.fromhex(call["body_iv_hex"]))
        assert sealed == call["body_sealed"], f"{what}: the sealed body"
        assert open_call(skey, "body", fields, sealed) == body, f"{what}: the sealed body opens"
        assert host_call_header(ckey, fields, sealed.encode()) == call["header"], f"{what}: the header"
        verified, refusal = verify_host_call(root, call["header"], sealed.encode(), fields["ts"], generation, member)
        assert refusal is None and verified == fields, f"{what}: the call verifies ({refusal})"
        if "answer" in call:
            answer = call["answer"].encode()
            sealed_answer = seal_call(skey, "answer", fields, answer, bytes.fromhex(call["answer_iv_hex"]))
            assert sealed_answer == call["answer_sealed"], f"{what}: the sealed answer"
            assert open_call(skey, "answer", fields, sealed_answer) == answer, f"{what}: the sealed answer opens"
            _check_answer(call["answer"], what)
        return args

    callbacks = [call["callback"] for call in v["calls"]]
    assert sorted(callbacks) == sorted(c for c in v["routes"] if c != "runner_exited"), "host_api: one call per host callback"
    for call in v["calls"]:
        reproduce(call, f"host_api {call['callback']}", call["callback"])
        for refusal in call["refusals"]:
            _check_answer(refusal["answer"], f"host_api {call['callback']} refusal")
            assert read_answer(refusal["answer"])[0] == "error", f"host_api {call['callback']}: a refusal is an error"

    for case in v["egress_pin_cases"]:
        what = f"host_api egress_pin {case['name']}"
        args = reproduce(case, what, case["callback"])
        assert case["callback"] == "egress_pin" and read_pin_request(args) is not None, f"{what}: the args read"
        answer = read_answer(case["answer"])
        if answer[0] == "ok":
            pin = read_pin(answer[1])
            assert pin is not None, f"{what}: the answer is a pinned target"
            scheme, host, port = parse_url(args["url"])
            assert (pin["scheme"], pin["host"], pin["port"]) == (scheme, host, port), f"{what}: the pin names the URL's origin"
        else:
            assert answer[1] in PIN_REFUSALS and answer[1] == case["name"], f"{what}: refused by its name"
    names = {case["name"] for case in v["egress_pin_cases"]}
    assert {"fetch", "stream", "redirect"} | set(PIN_REFUSALS) - {"malformed"} <= names, "host_api: every pin case"

    for refusal in v["pre_body_refusals"]:
        what = f"host_api pre-body {refusal['name']}"
        st = refusal["standing"]
        verified, got = verify_host_call_header(root, refusal["header"], refusal["now"], st["generation"], st["member"])
        if refusal["error"] == "replayed":
            # The nonce is the listener's memory, not the header's: the
            # header verifies, and names the nonce and attempt of a call
            # that is never retried, presented within the window.
            assert got is None, f"{what}: the header verifies"
            call = verified[0]
            storage = next(c for c in v["calls"] if c["callback"] == "storage")["fields"]
            assert v["retries"]["storage"] == "never", f"{what}: storage is never retried"
            assert (call["attempt"], call["nonce"]) == (storage["attempt"], storage["nonce"]), f"{what}: the storage call's nonce"
            assert within_window(storage["ts"], refusal["now"]), f"{what}: within the window"
        else:
            assert got == refusal["error"], f"{what}: refused {refusal['error']}, not {got}"
        assert refusal["status"] == 401, f"{what}: answered 401"

    for refusal in v["body_refusals"]:
        assert read_body("renew", refusal["body"]) == (None, refusal["error"]), f"host_api body {refusal['name']}: {refusal['error']}"

    report = v["report"]
    body = report["body"].encode()
    wkey = worker_key(root, report["fields"]["service"])
    assert report_header(dispatch_key(wkey), report["fields"], body) == report["header"], "host_api report: the header"
    verified, refusal = verify_report(root, report["header"], body, report["fields"]["ts"])
    assert refusal is None and verified == report["fields"], "host_api report: verifies"
    args, refusal = read_body("runner_exited", report["body"])
    assert refusal is None and args["member"] == member, "host_api report: names the member"
    _check_answer(report["answer"], "host_api report")
    cross = report["cross_member"]
    assert report_header(dispatch_key(wkey), cross["fields"], cross["body"].encode()) == cross["header"], "host_api cross-member report: the header"
    args, refusal = read_body("runner_exited", cross["body"])
    assert refusal is None and args["member"] != member and cross["error"] == "lost", "host_api cross-member report: another member's is lost"

    first, second = v["retry_identity"]["first"], v["retry_identity"]["second"]
    reproduce(first, "host_api retry first", "admit_child")
    reproduce(second, "host_api retry second", "admit_child")
    assert first["body"] == second["body"] and first["fields"]["nonce"] != second["fields"]["nonce"], "host_api retry: one body, fresh nonces"
    return True


def check_worker_api(path, primitives):
    """Reproduce every WorkerAPI request from its fields under the fixed
    dispatch key, and read every answer and refusal; and every status
    vector reads or is refused as it says."""
    with open(path, encoding="utf-8") as f:
        v = json.load(f)
    root = decode_root(primitives["root_hex"])
    dkey = dispatch_key(worker_key(root, primitives["service"]))
    assert v["version"] == VERSION, "worker_api: version"
    assert set(v["routes"]) == set(v["retries"]) == set(v["timeouts_ms"]) == {"start", "kill", "status"}, "worker_api: the three requests"
    for request in v["requests"]:
        what = f"worker_api {request['callback']}"
        body = request["body"].encode()
        assert v["routes"][request["callback"]] == f"/worker/v1/{request['callback']}", f"{what}: route"
        assert first_member(request["body"]) == "v", f"{what}: v is the body's first member"
        args, refusal = read_body(request["callback"], request["body"])
        assert refusal is None and request["body"] == request_body(request["callback"], args), f"{what}: the body"
        assert request_header(dkey, request["fields"], body) == request["header"], f"{what}: the header"
        verified, refusal = verify_request(dkey, request["header"], body, request["fields"]["ts"])
        assert refusal is None and verified == request["fields"], f"{what}: verifies ({refusal})"
        other = "v2" + request["header"][len("v1"):]
        assert verify_request(dkey, other, body, request["fields"]["ts"])[1] == "unknown_version", f"{what}: a v2 header"
        _check_answer(request["answer"], what)
        for refusal in request["refusals"]:
            _check_answer(refusal["answer"], f"{what} refusal")
    status = v["status"]
    for vec in status["valid"]:
        assert read_status(vec["wire"]) == vec["wire"], f"status reads: {vec['why']}"
    for vec in status["invalid"]:
        assert read_status(vec["wire"]) is None, f"status refused: {vec['why']}"
    return True


USAGE = """usage: worker_auth.py [--self-check]

Reproduces every vector of tests/fixtures/worker_auth.json, host_api.json
and worker_api.json from the fixed keys, and exits non-zero naming the first
that differs."""


if __name__ == "__main__":
    if sys.argv[1:] not in ([], ["--self-check"]):
        sys.exit(USAGE)
    here = os.path.dirname(os.path.abspath(__file__))
    check_vectors(os.path.join(here, "..", "fixtures", "worker_auth.json"))
    print("ok: every vector of tests/fixtures/worker_auth.json, host_api.json and worker_api.json reproduces")

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
`Prima.PinnedTarget` or refused by name (`read_pin_request`, `read_pin`),
under the egress policy's pure matchers as `Prima.Network` answers them
(`domain_allowed`, `same_origin`, `credential_header`). An attached
request's answer is a stream of sealed frames (`Prima.WorkerAuth`'s
`seal_frame/7`, `read_frame/2`): `seal_frame`, `split_frames` and
`read_frame` spell them, for the runner's `call_id` (`valid_call_id`).

`check_vectors` reproduces every value of `tests/fixtures/worker_auth.json`
(the primitives) and of the message vectors `host_api.json` and
`worker_api.json` beside it (every call, request and answer, sealed and
signed from the fixed keys, and every egress policy answer derived from
its case), which every side of the protocol consumes, and refuses to serve
otherwise. `python3 worker_auth.py --self-check` runs it.
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
INTEGER_FIELDS = {"fence", "generation", "ts", "seq"}
FRAME_FIELDS = ("call_id", "seq", "kind")
FRAME_KIND_BYTES = {"head": ord("h"), "chunk": ord("c"), "end": ord("e"), "error": ord("x")}
MAX_FRAME_BYTES = 65_536
MAX_CHUNK_BYTES = 32_768
MAX_FRAME_MESSAGE_BYTES = 512
CALL_ID = re.compile(r"[A-Za-z0-9_-]{22}")
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
# The egress policy's pure matchers, as `Prima.Network` answers them
# ---------------------------------------------------------------------------

CREDENTIAL_HEADERS = {"authorization", "cookie", "proxy-authorization", "x-api-key", "x-auth-token",
                      "x-access-token", "x-csrf-token"}
CREDENTIAL_SUFFIXES = ("-token", "-key", "-secret")
HEADER_NAME = re.compile(r"[!#$%&'*+\-.^_`|~0-9A-Za-z]+")


def _fold_host(host):
    """A host case-folded with one trailing dot dropped."""
    return (host[:-1] if host.endswith(".") else host).lower()


def domain_allowed(host, patterns):
    """`Prima.Network.domain_allowed?/2`: "*" matches any host,
    "*.example.com" every name below example.com, any other pattern exactly;
    an empty host, or no pattern, matches nothing."""
    host = _fold_host(host or "")
    if not host:
        return False
    for pattern in patterns:
        if pattern == "*":
            return True
        if pattern.startswith("*."):
            base = _fold_host(pattern[2:])
            if base and host.endswith("." + base):
                return True
        elif _fold_host(pattern) == host:
            return True
    return False


def origin(url):
    """A URL's scheme, host and effective port, an IPv6 literal compared by
    its address; None for a URL that has none."""
    parsed = parse_url(url)
    if parsed is None:
        return None
    scheme, host, port = parsed
    host = _fold_host(host[1:-1] if host.startswith("[") else host)
    if ":" in host:
        try:
            host = ipaddress.IPv6Address(host).compressed
        except ValueError:
            return None
    return scheme, host, port


def same_origin(a, b):
    """`Prima.Network.same_origin?/2`."""
    return origin(a) is not None and origin(a) == origin(b)


def credential_header(name):
    """`Prima.Network.credential_header?/1`."""
    name = name.lower()
    return name in CREDENTIAL_HEADERS or name.endswith(CREDENTIAL_SUFFIXES)


def attached_header_refusal(name, reserved):
    """How `Prima.AttachedRequest` refuses a request header beside a named
    connection: `credential_header_refused` for a name of the credential
    roster (`Prima.Network.credential_headers/0`), `invalid_request` for
    one of `reserved`, the headers that route or frame the request or
    override its method or target (`header_rosters`), in any case; None
    for the guest's own header, `Idempotency-Key` included."""
    name = name.lower()
    if name in CREDENTIAL_HEADERS:
        return "credential_header_refused"
    if name in reserved:
        return "invalid_request"
    return None


def header_rosters(v):
    """host_api.json's framing_headers and override_headers
    (`Prima.Network.framing_headers/0` and `override_headers/0`): each a
    list of distinct lowercase RFC 9110 tokens, the two disjoint and
    neither naming a credential header. Their union is what an attached
    request may not set."""
    framing, override = v["framing_headers"], v["override_headers"]
    for what, roster in (("framing_headers", framing), ("override_headers", override)):
        assert roster and len(set(roster)) == len(roster), f"host_api {what}: distinct names"
        for name in roster:
            assert isinstance(name, str) and name == name.lower() and HEADER_NAME.fullmatch(name), \
                f"host_api {what}: {name!r} is a lowercase token"
    assert not set(framing) & set(override), "host_api: the rosters are disjoint"
    assert not (set(framing) | set(override)) & CREDENTIAL_HEADERS, "host_api: no roster names a credential header"
    assert "host" in framing and "x-forwarded-host" in override and "forwarded" in override, \
        "host_api: the rosters name the Host header and a forwarded origin"
    return frozenset(framing) | frozenset(override)


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


# ---------------------------------------------------------------------------
# Attached answer frames (`Prima.WorkerAuth.seal_frame/7`, `read_frame/2`)
# ---------------------------------------------------------------------------


def valid_call_id(call_id):
    """Whether `call_id` is 16 bytes as unpadded base64url, spelled exactly
    as encoding those bytes spells them (`Prima.AttachedRequest`)."""
    if not isinstance(call_id, str) or not CALL_ID.fullmatch(call_id):
        return False
    try:
        raw = unb64url(call_id)
    except (ValueError, TypeError):
        return False
    return len(raw) == 16 and b64url(raw) == call_id


def _frame_message(call_id, seq, kind):
    return {"call_id": call_id, "seq": seq, "kind": kind}


def seal_frame(seal_key, call_id, seq, kind, plaintext, iv=None):
    """One answer frame as it crosses: a 4-byte big-endian length, the kind
    byte in clear and the plaintext sealed under the attempt seal key with
    call_id, seq and kind as additional data; None for a chunk past its
    bound or a frame past the frame bound."""
    if kind == "chunk" and len(plaintext) > MAX_CHUNK_BYTES:
        return None
    sealed = seal(seal_key, f"{PREFIX}/frame-answer", FRAME_FIELDS, _frame_message(call_id, seq, kind), plaintext, iv)
    body = bytes([FRAME_KIND_BYTES[kind]]) + sealed.encode()
    if len(body) > MAX_FRAME_BYTES:
        return None
    return len(body).to_bytes(4, "big") + body


def open_frame(seal_key, call_id, seq, kind, sealed):
    """The plaintext of a frame's sealed value read as `kind` at `seq` of
    the call `call_id`, or None."""
    return open_sealed(seal_key, f"{PREFIX}/frame-answer", FRAME_FIELDS, _frame_message(call_id, seq, kind), sealed)


def split_frames(data):
    """`(frames, rest, refusal)`: the complete frames of a length-prefixed
    stream, each its kind byte and sealed value, the bytes after them, and
    `frame_too_large` or `malformed` for a length past the bound or below
    two bytes, as soon as the length is in."""
    frames = []
    while len(data) >= 4:
        length = int.from_bytes(data[:4], "big")
        if length > MAX_FRAME_BYTES:
            return frames, data, "frame_too_large"
        if length < 2:
            return frames, data, "malformed"
        if len(data) < 4 + length:
            break
        frames.append(data[4 : 4 + length])
        data = data[4 + length :]
    return frames, data, None


def frame_reader(seal_key, call_id):
    return {"seal_key": seal_key, "call_id": call_id, "seq": 0, "state": "head"}


_IN_SEQUENCE = {"head": {"head", "error"}, "body": {"chunk", "end", "error"}, "done": set()}


def _read_plaintext(kind, plaintext):
    if kind == "head":
        try:
            head = json.loads(plaintext)
        except (ValueError, TypeError):
            return None
        ok = (
            isinstance(head, dict) and set(head) == {"status", "headers"}
            and isinstance(head["status"], int) and not isinstance(head["status"], bool)
            and 100 <= head["status"] <= 599 and isinstance(head["headers"], list)
            and all(isinstance(p, list) and len(p) == 2 and all(isinstance(x, str) for x in p) for p in head["headers"])
        )
        return {"kind": "head", "status": head["status"], "headers": head["headers"]} if ok else None
    if kind == "chunk":
        return {"kind": "chunk", "body": plaintext} if len(plaintext) <= MAX_CHUNK_BYTES else "frame_too_large"
    if kind == "end":
        return {"kind": "end"} if plaintext == b"" else None
    try:
        error = json.loads(plaintext)
    except (ValueError, TypeError):
        return None
    ok = (
        isinstance(error, dict) and set(error) == {"type", "message"}
        and isinstance(error["type"], str) and error["type"] != "" and isinstance(error["message"], str)
        and len(error["message"].encode()) <= MAX_FRAME_MESSAGE_BYTES
    )
    return {"kind": "error", "type": error["type"], "message": error["message"]} if ok else None


def read_frame(reader, frame):
    """`(read, refusal)`: one frame (kind byte and sealed value) read as
    the reader's next, the reader advanced; or the refusal that ends the
    answer as an error, in `Prima.WorkerAuth.read_frame/2`'s order:
    malformed, unknown_kind, out_of_sequence, unsealable, then a plaintext
    its kind does not carry."""
    if len(frame) < 2:
        return None, "malformed"
    kinds = {byte: kind for kind, byte in FRAME_KIND_BYTES.items()}
    kind = kinds.get(frame[0])
    if kind is None:
        return None, "unknown_kind"
    if kind not in _IN_SEQUENCE[reader["state"]]:
        return None, "out_of_sequence"
    plaintext = open_frame(reader["seal_key"], reader["call_id"], reader["seq"], kind, frame[1:].decode("ascii", "replace"))
    if plaintext is None:
        return None, "unsealable"
    read = _read_plaintext(kind, plaintext)
    if read is None or isinstance(read, str):
        return None, read or "malformed"
    reader["seq"] += 1
    reader["state"] = "body" if kind in ("head", "chunk") else "done"
    return read, None


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

    sf = v["sealed_frames"]
    assert sf["label"] == f"{PREFIX}/frame-answer" and valid_call_id(sf["call_id"]), "sealed frames: label and call id"
    reader = frame_reader(skey, sf["call_id"])
    for frame in sf["frames"]:
        plaintext = base64.b64decode(frame["plaintext_b64"])
        framed = seal_frame(skey, sf["call_id"], frame["seq"], frame["kind"], plaintext, bytes.fromhex(frame["iv_hex"]))
        assert framed is not None and framed.hex() == frame["frame_hex"], f"sealed frame {frame['seq']}"
        assert framed[5:].decode() == frame["sealed"], f"sealed frame {frame['seq']}: its sealed value"
        assert open_frame(skey, sf["call_id"], frame["seq"], frame["kind"], frame["sealed"]) == plaintext, f"sealed frame {frame['seq']} opens"
        assert open_frame(skey, sf["call_id"], frame["seq"] + 1, frame["kind"], frame["sealed"]) is None, "a frame opens only at its place"
        read, refusal = read_frame(reader, framed[4:])
        assert refusal is None and read["kind"] == frame["kind"], f"sealed frame {frame['seq']} reads ({refusal})"
    assert reader["state"] == "done", "sealed frames: the answer ends"

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
    every egress policy answer from its case; and every refusal, pre-body
    and after the body, by name."""
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
    assert v["retries"]["attached_fetch"] == "never", "host_api: an attached request is never retried"

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
        args = reproduce(call, f"host_api {call['callback']}", call["callback"])
        for refusal in call["refusals"]:
            _check_answer(refusal["answer"], f"host_api {call['callback']} refusal")
            assert read_answer(refusal["answer"])[0] == "error", f"host_api {call['callback']}: a refusal is an error"
        if call["callback"] == "attached_fetch":
            check_attached_call(call, args, root, header_rosters(v))

    check_frame_cases(v["frame_cases"], root, v["calls"][0]["fields"])

    for case in v["egress_pin_internal_purposes"]:
        what = f"host_api egress_pin internal purpose {case['name']}"
        args = reproduce(case, what, case["callback"])
        assert args["purpose"] == case["name"] and case["name"] not in PIN_PURPOSES, f"{what}: a purpose no runner asks for"
        assert read_pin_request(args) is None, f"{what}: the args do not read"
        assert read_answer(case["answer"])[:2] == ("error", "malformed"), f"{what}: refused malformed"

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

    # The egress policy's cases, in the order one attempt makes them: each
    # call reproduced as a pin case is, and each answer derived from its
    # expect: the URL's host against domains, a redirect's URL against the
    # URL of the pin it names as from, a pin answered only where both hold,
    # `denied` outside domains and `redirect_credentials` on another origin;
    # and a hop's headers_after as headers_before without every header that
    # carries a credential.
    pinned, outcomes = {}, set()
    for case in v["egress_policy_cases"]:
        what = f"host_api egress_policy {case['name']}"
        assert case["callback"] == "egress_pin", f"{what}: an egress_pin call"
        args = reproduce(case, what, case["callback"])
        assert read_pin_request(args) is not None, f"{what}: the args read"
        url, expect = args["url"], case["expect"]
        allowed = domain_allowed(urllib.parse.urlsplit(url).hostname, case["domains"])
        assert expect["domain_allowed"] == allowed, f"{what}: the host against the domains"
        same = True
        if args["purpose"] == "redirect":
            assert args["from"] in pinned, f"{what}: from names a pin an earlier case was answered"
            same = same_origin(url, pinned[args["from"]])
            assert expect["same_origin"] == same, f"{what}: the origin against its pin's"
        answer = read_answer(case["answer"])
        if allowed and same:
            assert answer[0] == "ok", f"{what}: pinned"
            pin = read_pin(answer[1])
            assert pin is not None, f"{what}: the answer is a pinned target"
            assert (pin["scheme"], pin["host"], pin["port"]) == parse_url(url), f"{what}: the pin names the URL's origin"
            pinned[pin["id"]] = url
            outcomes.add("pinned")
        else:
            refusal = "denied" if not allowed else "redirect_credentials"
            assert answer[0] == "error" and answer[1] == refusal, f"{what}: refused as {refusal}"
            outcomes.add(refusal)
        if "headers_before" in case:
            kept = [pair for pair in case["headers_before"] if not credential_header(pair[0])]
            assert kept == case["headers_after"], f"{what}: the headers a hop to another origin keeps"
            outcomes.add("stripped")
    assert outcomes == {"pinned", "denied", "redirect_credentials", "stripped"}, "host_api: every egress policy outcome"

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

    # A child's connection crosses as an optional member of its args: absent
    # for the edge's default, else the account's name. A key names one child
    # and the connection it was admitted with, so a repeat naming another is
    # refused invalid_request.
    cases = {case["name"]: case for case in v["connection_cases"]}
    assert [case["name"] for case in v["connection_cases"]] == ["omitted", "named", "reused"], "host_api connection: the cases, in order"
    args = {}
    for name, case in cases.items():
        what = f"host_api connection {name}"
        assert case["callback"] == "admit_child", f"{what}: an admit_child call"
        args[name] = reproduce(case, what, "admit_child")
        connection = args[name].get("connection")
        assert connection is None or (isinstance(connection, str) and connection != ""), f"{what}: absent or an account's name"
        assert re.fullmatch(r"[A-Za-z0-9_-]{1,128}", args[name]["child_key"]), f"{what}: a child key"
    assert "connection" not in args["omitted"], "host_api connection omitted: names none"
    assert read_answer(cases["omitted"]["answer"])[0] == "ok", "host_api connection omitted: admitted"
    assert args["named"]["connection"] == args["reused"]["connection"] == "Work", "host_api connection: the account"
    assert args["named"]["child_key"] != args["omitted"]["child_key"], "host_api connection named: a key of its own"
    assert {k: x for k, x in args["reused"].items() if k != "connection"} == args["omitted"], "host_api connection reused: omitted's call naming an account"
    named = read_answer(cases["named"]["answer"])
    assert named[:2] == ("error", "guest_error") and named[2]["type"] == "connection_not_granted", "host_api connection named: refused connection_not_granted"
    reused = read_answer(cases["reused"]["answer"])
    assert reused[:2] == ("error", "guest_error") and reused[2]["type"] == "invalid_request", "host_api connection reused: invalid_request"
    assert v["retries"]["admit_child"] == "keyed", "host_api connection: admit_child is keyed"
    return True


def check_attached_call(call, args, root, reserved):
    """An attached request carries no single answer: admitted, it is
    answered with frames. Its refusals are sealed guest errors naming its
    call id."""
    what = "host_api attached_fetch"
    assert "answer" not in call, f"{what}: no single answer"
    assert valid_call_id(args.get("call_id")), f"{what}: its call id"
    assert all(attached_header_refusal(name, reserved) is None for name, _value in args["headers"]), f"{what}: no refused header"
    assert attached_header_refusal("Proxy-Authorization", reserved) == "credential_header_refused", f"{what}: the roster"
    assert attached_header_refusal("HOST", reserved) == "invalid_request", f"{what}: a framing header"
    assert attached_header_refusal("X-Forwarded-Host", reserved) == "invalid_request", f"{what}: an override header"
    assert attached_header_refusal("Idempotency-Key", reserved) is None, f"{what}: no suffix rule"
    fields = call["fields"]
    skey = attempt_seal_key(root, fields)
    for refusal in call["refusals"]:
        answer = refusal["answer"].encode()
        sealed = seal_call(skey, "answer", fields, answer, bytes.fromhex(refusal["answer_iv_hex"]))
        assert sealed == refusal["answer_sealed"], f"{what}: the sealed refusal"
        assert open_call(skey, "answer", fields, sealed) == answer, f"{what}: the sealed refusal opens"
        name, fields_ = read_answer(refusal["answer"])[1:]
        assert name == "guest_error" and fields_["call_id"] == args["call_id"] == refusal["call_id"], f"{what}: a guest error naming its call id"
        assert set(fields_) == {"type", "message", "call_id"}, f"{what}: type, message and call id"


def check_frame_cases(cases, root, fields):
    """Every frame case: its sealed frames reproduce, and read one frame at a
    time by a reader for the case's call id, they give the expected frames
    and end with the expected refusal."""
    skey = attempt_seal_key(root, fields)
    assert cases["max_frame_bytes"] == MAX_FRAME_BYTES and cases["max_chunk_bytes"] == MAX_CHUNK_BYTES, "frame_cases: bounds"
    assert valid_call_id(cases["call_id"]) and valid_call_id(cases["other_call_id"]), "frame_cases: call ids"
    names = set()
    for case in cases["cases"]:
        what = f"host_api frame case {case['name']}"
        names.add(case["name"])
        stream = b""
        for frame in case["frames"]:
            data = bytes.fromhex(frame["frame_hex"])
            stream += data
            sealed_for = frame.get("sealed_for")
            if sealed_for:
                framed = seal_frame(skey, sealed_for["call_id"], sealed_for["seq"], sealed_for["kind"],
                                    base64.b64decode(sealed_for["plaintext_b64"]), bytes.fromhex(sealed_for["iv_hex"]))
                assert framed == data, f"{what}: a frame reproduces"
        frames, rest, refusal = split_frames(stream)
        reader = frame_reader(skey, cases["call_id"])
        read = []
        if refusal is None:
            assert rest == b"", f"{what}: whole frames"
            for frame in frames:
                one, refusal = read_frame(reader, frame)
                if refusal:
                    break
                if one["kind"] == "chunk":
                    one = {"kind": "chunk", "body_b64": base64.b64encode(one["body"]).decode()}
                read.append(one)
        assert read == case["expect"]["read"], f"{what}: the frames read"
        assert refusal == case["expect"]["error"], f"{what}: refused {case['expect']['error']}, not {refusal}"
    assert {"head_chunk_end", "error_after_head", "out_of_sequence", "another_call", "bad_tag", "oversize"} <= names, "frame_cases: every case"
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

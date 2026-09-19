# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""`Cyfr.WorkerAuth` and `Cyfr.Assignment` as the worker image tests spell
them, so a scripted control plane can mint what CYFR mints and verify what
a worker sends, with nothing but the standard library.

Every key is HMAC-SHA256 of the root over a label and field values one per
line (`Cyfr.MacEnvelope`); a header is `v1 kind=<kind> name=value … body=<hex>
mac=<b64url>` signed over the envelope's canonical string; a sealed value is
`base64url(iv ‖ tag ‖ ciphertext)` under AES-256-GCM with the label and
fields as additional data; an assignment token is `base64url(jcs) "."
base64url(mac)` under the assign key. AES-GCM is written out here rather
than imported, so the suite runs wherever `python3` does; `check_vectors`
reproduces every value of `tests/fixtures/worker_auth.json`, the one vector
file every side of the protocol consumes, and refuses to serve otherwise.
"""

import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import time

PREFIX = "cyfr-worker/v1"
ATTEMPT_FIELDS = ("athanor_id", "execution_id", "attempt", "fence", "generation", "service")
CALL_FIELDS = ATTEMPT_FIELDS + ("boot", "runner", "ts", "nonce")
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


def verify_host_call(root, text, body, now, generation):
    """The call's fields, or the refusal name, in the contract's order."""
    parsed = parse("call", CALL_FIELDS, text)
    if parsed is None:
        return None, "malformed"
    call, body_hash, mac = parsed
    if not within_window(call["ts"], now):
        return None, "outside_window"
    if not verify_header("call", CALL_FIELDS, attempt_call_key(root, call), call, body_hash, mac):
        return None, "bad_mac"
    if not hmac.compare_digest(body_hash, sha256_hex(body)):
        return None, "bad_mac"
    if call["generation"] != generation:
        return None, "generation_mismatch"
    return call, None


def verify_report(root, text, body, now):
    parsed = parse("report", DISPATCH_FIELDS, text)
    if parsed is None:
        return None, "malformed"
    report, body_hash, mac = parsed
    if not within_window(report["ts"], now):
        return None, "outside_window"
    key = dispatch_key(worker_key(root, report["service"]))
    if not verify_header("report", DISPATCH_FIELDS, key, report, body_hash, mac):
        return None, "bad_mac"
    if not hmac.compare_digest(body_hash, sha256_hex(body)):
        return None, "bad_mac"
    return report, None


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
# A worker service's status (`Cyfr.WorkerAPI.read_status/1`)
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

    service, attempt, boot = v["service"], v["attempt"], v["boot"]
    keys = v["keys"]
    assert assign_key(root).hex() == keys["assign_hex"], "assign key"
    wkey = worker_key(root, service)
    assert wkey.hex() == keys["worker_hex"], "worker key"
    assert dispatch_key(wkey).hex() == keys["dispatch_hex"], "dispatch key"
    assert dispatch_seal_key(wkey).hex() == keys["dispatch_seal_hex"], "dispatch seal key"
    ckey, skey = attempt_call_key(root, attempt), attempt_seal_key(root, attempt)
    assert ckey.hex() == keys["attempt_call_hex"], "attempt call key"
    assert skey.hex() == keys["attempt_seal_hex"], "attempt seal key"

    call = dict(attempt, boot=boot, runner=v["call"]["runner"], ts=v["call"]["ts"], nonce=v["call"]["nonce"])
    body = v["call"]["body"].encode()
    assert canonical("call", CALL_FIELDS, call, sha256_hex(body)) == v["call"]["canonical"], "call canonical"
    assert host_call_header(ckey, call, body) == v["call"]["header"], "call header"
    verified, refusal = verify_host_call(root, v["call"]["header"], body, v["call"]["ts"], attempt["generation"])
    assert refusal is None and verified == call, f"call verifies ({refusal})"
    assert verify_host_call(root, v["call"]["header"], body, v["call"]["ts"], attempt["generation"] + 1)[1] == "generation_mismatch"
    assert verify_host_call(root, v["call"]["header"], body + b" ", v["call"]["ts"], attempt["generation"])[1] == "bad_mac"
    assert verify_host_call(root, v["call"]["header"], body, v["call"]["ts"] + WINDOW_MS + 1, attempt["generation"])[1] == "outside_window"

    for kind, fn in (("request", request_header), ("report", report_header)):
        vec = v[kind]
        fields = {"service": service, "boot": boot, "ts": vec["ts"], "nonce": vec["nonce"]}
        vbody = vec["body"].encode()
        assert canonical(kind, DISPATCH_FIELDS, fields, sha256_hex(vbody)) == vec["canonical"], f"{kind} canonical"
        assert fn(dispatch_key(wkey), fields, vbody) == vec["header"], f"{kind} header"
    report, refusal = verify_report(root, v["report"]["header"], v["report"]["body"].encode(), v["report"]["ts"])
    assert refusal is None and report["service"] == service, "report verifies"

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
    assert jcs(wire) == a["payload"], "assignment JCS"
    assert sign_assignment(wire, assign_key(root)) == a["token"], "assignment token"
    assert read_assignment(a["token"]) == wire, "assignment reads"

    for vec in v["status"]["valid"]:
        assert read_status(vec["wire"]) == vec["wire"], f"status reads: {vec['why']}"
    for vec in v["status"]["invalid"]:
        assert read_status(vec["wire"]) is None, f"status refused: {vec['why']}"
    return True


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    check_vectors(os.path.join(here, "..", "fixtures", "worker_auth.json"))
    print("ok: every vector of tests/fixtures/worker_auth.json reproduces")

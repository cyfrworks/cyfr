#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The backends service under docker compose, and a control plane that signs as CYFR does.

A Stack runs docker-compose.yml's `locus-backends` service layered with
compose.locus-backends.yml, which adds only the image under test, a
loopback port, the probe backend (probe-backend.mjs), the residue canary,
the pool's uid range and the per-backend memory bound, and lets compose name
the container after the project. Everything else (the backends key from
CYFR_LOCUS_BACKENDS_KEY, capabilities, security options, read-only root,
`ipc: none`, tmpfs mounts, limits, the network) is the shipped service.

A Controller is the control plane's side of the backends wire
(`Prima.LocusBackends`), reimplemented here from its vector file,
tests/fixtures/locus_backends.json: control messages signed under the
control key with a rising sequence, backend environments sealed to the
owner and the service lifetime `hello` learned, and MCP requests signed
under each owner's key. Every request can be given its own timestamp,
nonce, sequence, boot or key, and every signed invoke is kept so it can be
sent again unchanged. The signing and sealing here must reproduce the vector
file: `check_vectors` runs when this module is loaded, before any container
starts, and `python3 tests/locus-backends-image/harness.py --self-check`
runs it alone, with no Docker.

Prerequisites of the suites that import this module: Docker Engine 28 or
later on a cgroup v2 host (the service bounds every backend with a cgroup of
its own, `writable-cgroups=true`), the Compose plugin, the image under test
built from Dockerfile.locus and named as the suites' one argument, and the
golang:1.26.6-alpine image for the residue canary. A missing prerequisite
fails the suite; nothing is skipped.
"""

import base64
import hashlib
import hmac
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SERVICE = "locus-backends"
PORT = 4101
# Prefixed to every compose project and container of a run, for a host that
# tells one run's Docker objects from another's by name.
PROJECT_PREFIX = os.environ.get("STACK_PROJECT_PREFIX", "")
POOL_FIRST, POOL_LAST = 20001, 20032
RELEASE_UID = 10001
RELEASE_USER = "locus"
HOME_ROOT = "/var/lib/locus/homes"
RUN_DIR = "/run/locus"
PROBE = "node /probe/probe-backend.mjs"
# cyfr-keeper's effective, permitted and bounding sets: SETUID, SETGID and
# KILL alone.
KEEPER_CAPS = "00000000000000e0"
# The MCP revision a signed invoke declares (Prima.MCP.Protocol).
MCP_VERSION = "2026-07-28"

with open(os.path.join(ROOT, "tests", "fixtures", "locus_backends.json"), encoding="utf-8") as _vectors:
    WIRE = json.load(_vectors)

VERSION = WIRE["version"]
LABEL = WIRE["label"]
AUTH_HEADER = WIRE["auth_header"]
BOOT_HEADER = WIRE["boot_header"]
ROUTES = WIRE["routes"]
STATUSES = WIRE["statuses"]
BOUNDS = WIRE["bounds"]
WINDOW_MS = WIRE["window_ms"]


def pool_user(uid):
    """The name the image gives a backend uid: uid 20000+N is locus-backendNN (Dockerfile.locus)."""
    return f"locus-backend{uid - 20000:02d}"


def run(*args, check=True, env=None, timeout=None):
    result = subprocess.run(args, capture_output=True, text=True, env=env, timeout=timeout)
    if check and result.returncode != 0:
        sys.exit(f"FAIL: {' '.join(args)} exited {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


def expect(condition, message, detail=None):
    if not condition:
        text = detail if isinstance(detail, str) else json.dumps(detail, indent=2, default=str)
        sys.exit(f"FAIL: {message}\n{(text or '')[:6000]}")
    print(f"ok: {message}", flush=True)


def eventually(check, what, timeout_s=15):
    """The first truthy answer of `check`, polled until `timeout_s` passes; the suite fails after it."""
    deadline = time.monotonic() + timeout_s
    while True:
        value = check()
        if value:
            return value
        if time.monotonic() > deadline:
            sys.exit(f"FAIL: timed out waiting for {what}")
        time.sleep(0.1)


def now_ms():
    return int(time.time() * 1000)


def wire_json(value):
    """A body as every end writes it: keys sorted, no whitespace."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def unb64url(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


# ————— AES-256-GCM, as the seal is (Prima.MacEnvelope.seal/6) —————
#
# The standard library has no AES, and the suites take no third-party
# package, so the block cipher and GCM are written out here and held to the
# vector file's sealed value by `check_vectors`.

_SBOX = bytearray(256)


def _build_sbox():
    p = q = 1
    while True:
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ ((q << 1) | (q >> 7)) ^ ((q << 2) | (q >> 6)) ^ ((q << 3) | (q >> 5)) ^ ((q << 4) | (q >> 4))
        _SBOX[p] = (x ^ 0x63) & 0xFF
        if p == 1:
            break
    _SBOX[0] = 0x63


_build_sbox()


def _xtime(a):
    return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else a << 1


def _expand_key(key):
    words = [list(key[i:i + 4]) for i in range(0, 32, 4)]
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
    return [sum(words[r * 4:r * 4 + 4], []) for r in range(15)]


def _encrypt_block(round_keys, block):
    s = [b ^ k for b, k in zip(block, round_keys[0])]
    for r in range(1, 15):
        s = [_SBOX[b] for b in s]
        s = [s[(c * 4 + row + row * 4) % 16] for c in range(4) for row in range(4)]
        if r != 14:
            mixed = []
            for c in range(4):
                a = s[c * 4:c * 4 + 4]
                t = a[0] ^ a[1] ^ a[2] ^ a[3]
                mixed += [a[i] ^ t ^ _xtime(a[i] ^ a[(i + 1) % 4]) for i in range(4)]
            s = mixed
        s = [b ^ k for b, k in zip(s, round_keys[r])]
    return bytes(s)


def _gf_mult(x, y):
    r = 0
    for i in range(127, -1, -1):
        if (y >> i) & 1:
            r ^= x
        x = (x >> 1) ^ (0xE1 << 120) if x & 1 else x >> 1
    return r


def _ghash(h, aad, ciphertext):
    def blocks(data):
        padded = data + b"\x00" * (-len(data) % 16)
        return [int.from_bytes(padded[i:i + 16], "big") for i in range(0, len(padded), 16)]

    y = 0
    lengths = ((len(aad) * 8) << 64) | (len(ciphertext) * 8)
    for block in blocks(aad) + blocks(ciphertext) + [lengths]:
        y = _gf_mult(y ^ block, h)
    return y.to_bytes(16, "big")


def _gcm_ctr(round_keys, iv, data):
    out = bytearray()
    counter = 2
    for i in range(0, len(data), 16):
        stream = _encrypt_block(round_keys, iv + counter.to_bytes(4, "big"))
        out += bytes(a ^ b for a, b in zip(data[i:i + 16], stream))
        counter += 1
    return bytes(out)


def aes_gcm_encrypt(key, iv, plaintext, aad):
    """(ciphertext, tag) of AES-256-GCM with a 12-byte IV and a 16-byte tag."""
    round_keys = _expand_key(key)
    h = int.from_bytes(_encrypt_block(round_keys, b"\x00" * 16), "big")
    ciphertext = _gcm_ctr(round_keys, iv, plaintext)
    s = _ghash(h, aad, ciphertext)
    j0 = _encrypt_block(round_keys, iv + b"\x00\x00\x00\x01")
    return ciphertext, bytes(a ^ b for a, b in zip(s, j0))


def aes_gcm_decrypt(key, iv, ciphertext, aad, tag):
    round_keys = _expand_key(key)
    h = int.from_bytes(_encrypt_block(round_keys, b"\x00" * 16), "big")
    s = _ghash(h, aad, ciphertext)
    j0 = _encrypt_block(round_keys, iv + b"\x00\x00\x00\x01")
    if not hmac.compare_digest(bytes(a ^ b for a, b in zip(s, j0)), tag):
        raise ValueError("unsealable")
    return _gcm_ctr(round_keys, iv, ciphertext)


# ————— the wire's keys, signatures and seals —————


def derive(key, *lines):
    """HMAC-SHA256 of `key` over the lines, one per line (Prima.MacEnvelope.derive)."""
    return hmac.new(key, "\n".join(str(line) for line in lines).encode(), hashlib.sha256).digest()


def control_key(key):
    return derive(key, f"{LABEL}/control")


def seal_key(key):
    return derive(key, f"{LABEL}/seal")


def owner_key(key, athanor, server, generation, epoch):
    return derive(key, f"{LABEL}/owner", athanor, server, generation, epoch)


def canonical(kind, values, body):
    return "\n".join([f"{LABEL}/{kind}", *[str(v) for v in values], hashlib.sha256(body).hexdigest()])


def mac(signing_key, text):
    return b64url(hmac.new(signing_key, text.encode(), hashlib.sha256).digest())


def control_header(signing_key, fields, body):
    """The `x-cyfr-auth` value of a control message: generation, seq, both lifetimes and ts."""
    values = [fields["generation"], fields["seq"], fields["cyfr_boot"], fields["boot"], fields["ts"]]
    signature = mac(signing_key, canonical("control", values, body))
    return (f"v1 kind=control gen={fields['generation']} seq={fields['seq']} cyfr_boot={fields['cyfr_boot']} "
            f"boot={fields['boot']} ts={fields['ts']} body={hashlib.sha256(body).hexdigest()} mac={signature}")


def invoke_header(signing_key, fields, body):
    """The `x-cyfr-auth` value of an invoke: the owner's fields, the lifetime, ts and a nonce."""
    names = ["athanor", "server", "generation", "epoch", "boot", "ts", "nonce"]
    signature = mac(signing_key, canonical("invoke", [fields[n] for n in names], body))
    return (f"v1 kind=invoke athanor={fields['athanor']} server={fields['server']} gen={fields['generation']} "
            f"epoch={fields['epoch']} boot={fields['boot']} ts={fields['ts']} nonce={fields['nonce']} "
            f"body={hashlib.sha256(body).hexdigest()} mac={signature}")


def seal(sealing_key, owner, boot, plaintext, iv=None):
    """A sync's environment sealed to its owner (athanor, server, generation, epoch) and the service lifetime."""
    iv = iv or secrets.token_bytes(12)
    aad = "\n".join([f"{LABEL}/seal", owner["athanor"], owner["server"], str(owner["generation"]),
                     str(owner["epoch"]), boot]).encode()
    ciphertext, tag = aes_gcm_encrypt(sealing_key, iv, plaintext, aad)
    return b64url(iv + tag + ciphertext)


def open_sealed(sealing_key, owner, boot, sealed):
    data = unb64url(sealed)
    aad = "\n".join([f"{LABEL}/seal", owner["athanor"], owner["server"], str(owner["generation"]),
                     str(owner["epoch"]), boot]).encode()
    return aes_gcm_decrypt(sealing_key, data[:12], data[28:], aad, data[12:28])


def check_vectors():
    """The keys, control and invoke signatures, bodies and seal here reproduce the vector file's."""
    key = bytes.fromhex(WIRE["key_hex"])
    owner = WIRE["owner"]
    wrong = {}

    def compare(name, ours, theirs):
        if ours != theirs:
            wrong[name] = {"ours": ours, "vector": theirs}

    compare("control_key", control_key(key).hex(), WIRE["control_key_hex"])
    compare("seal_key", seal_key(key).hex(), WIRE["seal_key_hex"])
    compare("owner_key", owner_key(key, owner["athanor"], owner["server"], owner["generation"],
                                   owner["epoch"]).hex(), WIRE["owner_key_hex"])

    for kind in ["hello", "reconcile", "sync", "renew", "release", "status"]:
        vector = WIRE[kind]
        body = vector["body"].encode()
        fields = vector["fields"]
        values = [fields["generation"], fields["seq"], fields["cyfr_boot"], fields["boot"], fields["ts"]]
        compare(f"{kind}.body", wire_json(json.loads(vector["body"])).decode(), vector["body"])
        compare(f"{kind}.answer", wire_json(json.loads(vector["answer"])).decode(), vector["answer"])
        compare(f"{kind}.canonical", canonical("control", values, body), vector["canonical"])
        compare(f"{kind}.header", control_header(control_key(key), fields, body), vector["header"])

    vector = WIRE["invoke"]
    body = vector["body"].encode()
    fields = vector["fields"]
    signing = owner_key(key, fields["athanor"], fields["server"], fields["generation"], fields["epoch"])
    names = ["athanor", "server", "generation", "epoch", "boot", "ts", "nonce"]
    compare("invoke.canonical", canonical("invoke", [fields[n] for n in names], body), vector["canonical"])
    compare("invoke.header", invoke_header(signing, fields, body), vector["header"])

    vector = WIRE["seal"]
    sealed = seal(seal_key(key), owner, vector["boot"], vector["plaintext"].encode(), bytes.fromhex(vector["iv_hex"]))
    compare("seal", sealed, vector["sealed"])
    compare("open", open_sealed(seal_key(key), owner, vector["boot"], vector["sealed"]).decode(), vector["plaintext"])
    try:
        open_sealed(seal_key(key), {**owner, "epoch": owner["epoch"] + 1}, vector["boot"], vector["sealed"])
        wrong["open.another_owner"] = "a seal opened for another owner"
    except ValueError:
        pass

    for code, status in STATUSES.items():
        refusal = next((r for r in WIRE["refusals"] if r["code"] == code), None)
        compare(f"refusal.{code}", (refusal or {}).get("status"), status)

    if wrong:
        sys.exit("FAIL: harness.py does not speak the backends wire as tests/fixtures/locus_backends.json says\n"
                 + json.dumps(wrong, indent=2))


check_vectors()


# ————— HTTP —————


def post(url, headers, body, timeout=60):
    """POSTs `body`, whatever the answer's status: (status, JSON or text or None, the boot it names)."""
    request = urllib.request.Request(url, data=body, method="POST", headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, _decode(response.read()), response.headers.get(BOOT_HEADER)
    except urllib.error.HTTPError as error:
        return error.code, _decode(error.read()), error.headers.get(BOOT_HEADER)


def _decode(data):
    if not data:
        return None
    try:
        return json.loads(data)
    except ValueError:
        return data.decode(errors="replace")


class Request:
    """One signed invoke, kept so it can be sent again byte for byte."""

    def __init__(self, url, headers, body):
        self.url, self.headers, self.body = url, headers, body


class Controller:
    """The control plane's side of the wire, signing as `Emissary.External.Backends` and its servers do."""

    def __init__(self, base, key, generation=1, cyfr_boot=None):
        self.base = base
        self.key = key
        self.generation = generation
        self.cyfr_boot = cyfr_boot or f"boot_{secrets.token_hex(8)}"
        self.seq = 0
        self.boot = None

    def control(self, message, generation=None, seq=None, boot=None, ts=None, key=None, version=VERSION):
        """Posts a control message at the protocol version: (status, answer, boot)."""
        body = wire_json({**message, "version": version})
        if seq is None:
            self.seq += 1
            seq = self.seq
        fields = {
            "generation": generation or self.generation,
            "seq": seq,
            "cyfr_boot": self.cyfr_boot,
            "boot": boot or ("-" if message["type"] == "hello" else self.boot),
            "ts": ts or now_ms(),
        }
        header = control_header(key or control_key(self.key), fields, body)
        return post(self.base + ROUTES["control"], {"content-type": "application/json", AUTH_HEADER: header}, body)

    def hello(self, **options):
        answer = self.control({"type": "hello", "g": options.get("generation") or self.generation,
                               "cyfr_boot": self.cyfr_boot}, **options)
        if answer[0] == 200:
            self.boot = answer[1]["boot"]
        return answer

    def reconcile(self, keep, **options):
        return self.control({"type": "reconcile", "keep": keep}, **options)

    def sync(self, owner, backends, lease_ms=30_000, idle_ms=900_000, sealed=None, **options):
        """Syncs `owner` ({athanor, server, e}); `backends` are [{name, command, env}], sealed here."""
        generation = options.get("generation") or self.generation
        env = {b["name"]: b.get("env") or {} for b in backends}
        if sealed is None:
            sealed = seal(seal_key(self.key), {"athanor": owner["athanor"], "server": owner["server"],
                                               "generation": generation, "epoch": owner["e"]},
                          options.get("boot") or self.boot, wire_json(env))
        return self.control({
            "type": "sync",
            "owner": {"athanor": owner["athanor"], "server": owner["server"]},
            "e": owner["e"],
            "lease_ms": lease_ms,
            "idle_ms": idle_ms,
            "backends": [{"name": b["name"], "command": b["command"], "env_names": sorted((b.get("env") or {}).keys())}
                         for b in backends],
            "sealed": sealed,
        }, **options)

    def renew(self, owners, lease_ms=30_000, **options):
        return self.control({"type": "renew", "lease_ms": lease_ms, "owners": owners}, **options)

    def release(self, owners, **options):
        return self.control({"type": "release", "owners": owners}, **options)

    def status(self, owners, **options):
        return self.control({"type": "status", "owners": [{"athanor": o["athanor"], "server": o["server"]}
                                                          for o in owners]}, **options)

    def running(self, owner, lease_ms=30_000, timeout_s=60):
        """Renews `owner` until the service reports it running, and answers its renewed entry."""
        ref = {"athanor": owner["athanor"], "server": owner["server"], "e": owner["e"]}
        deadline = time.monotonic() + timeout_s
        while True:
            status, answer, _boot = self.renew([ref], lease_ms)
            renewed = (answer or {}).get("renewed") if isinstance(answer, dict) else None
            if status != 200 or not renewed:
                sys.exit(f"FAIL: the service does not run {ref}: {status} {answer}")
            if renewed[0]["state"] == "running":
                return renewed[0]
            if time.monotonic() > deadline:
                sys.exit(f"FAIL: {ref} is still {renewed[0]['state']}")
            time.sleep(0.1)

    def report(self, owner):
        """The service's status report of `owner`, or None when it runs none."""
        status, answer, _boot = self.status([owner])
        expect(status == 200, "a status is answered", answer)
        return (answer["owners"] or [None])[0]

    def sign_invoke(self, owner, method, params=None, id=1, generation=None, boot=None, ts=None, nonce=None,
                    key=None, notification=False):
        """Signs one MCP request for `owner` as a server process does, without sending it."""
        params = dict(params or {})
        params["_meta"] = {
            "io.modelcontextprotocol/protocolVersion": MCP_VERSION,
            "io.modelcontextprotocol/clientCapabilities": {},
        }
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notification:
            message["id"] = id
        body = wire_json(message)
        fields = {
            "athanor": owner["athanor"],
            "server": owner["server"],
            "generation": generation or self.generation,
            "epoch": owner["e"],
            "boot": boot or self.boot,
            "ts": ts or now_ms(),
            "nonce": nonce or f"n_{secrets.token_hex(12)}",
        }
        signing = key or owner_key(self.key, fields["athanor"], fields["server"], fields["generation"], fields["epoch"])
        headers = {
            "content-type": "application/json",
            "mcp-protocol-version": MCP_VERSION,
            "mcp-method": method,
            AUTH_HEADER: invoke_header(signing, fields, body),
        }
        if isinstance(params.get("name"), str):
            headers["mcp-name"] = params["name"]
        return Request(self.base + ROUTES["mcp"], headers, body)

    def invoke(self, owner, method, params=None, **options):
        """Signs and posts one MCP request: (status, answer, boot, request)."""
        request = self.sign_invoke(owner, method, params, **options)
        return (*post(request.url, request.headers, request.body), request)

    def resend(self, request, base=None):
        url = base + ROUTES["mcp"] if base else request.url
        return (*post(url, request.headers, request.body), request)

    def call(self, owner, name, arguments=None):
        """A tool's result: (status, the JSON-RPC answer)."""
        status, answer, _boot, _request = self.invoke(owner, "tools/call", {"name": name, "arguments": arguments or {}})
        return status, answer

    def tool(self, owner, name, arguments=None):
        """A tool's first text content parsed as JSON; the suite fails on a refusal or a tool error."""
        status, answer = self.call(owner, name, arguments)
        result = (answer or {}).get("result") if isinstance(answer, dict) else None
        if status != 200 or not result or result.get("isError"):
            sys.exit(f"FAIL: {name}: {status} {answer}")
        return json.loads(result["content"][0]["text"])


# ————— the service under compose —————


def build_canary():
    """Builds tests/fixtures/residue-canary.go for Linux on this host's architecture."""
    out = tempfile.mkdtemp(prefix="cyfr-canary-")
    # The read-only fixture mount must be traversable by pooled backend uids.
    os.chmod(out, 0o755)
    run(
        "docker", "run", "--rm", "--name", f"{PROJECT_PREFIX}cyfr-canary-build-{os.getpid()}",
        "-v", f"{os.path.join(ROOT, 'tests', 'fixtures')}:/src:ro", "-v", f"{out}:/out",
        "-e", "CGO_ENABLED=0", "-e", "GOCACHE=/tmp/go-cache", "-e", "GOFLAGS=-buildvcs=false",
        "-w", "/src", "golang:1.26.6-alpine", "go", "build", "-o", "/out/canary", "residue-canary.go",
    )
    return out


def require_docker():
    """Docker Engine 28 or later on cgroup v2, which writable-cgroups=true needs; the suite fails without."""
    version = run("docker", "version", "--format", "{{.Server.Version}}", check=False)
    cgroup = run("docker", "info", "--format", "{{.CgroupVersion}}", check=False)
    if version.returncode != 0:
        sys.exit(f"FAIL: no Docker Engine answers: {version.stderr}")
    major = int((version.stdout.strip().split(".") or ["0"])[0] or 0)
    if major < 28 or cgroup.stdout.strip() != "2":
        sys.exit(f"FAIL: Docker Engine {version.stdout.strip()} on cgroup v{cgroup.stdout.strip()}: "
                 "writable-cgroups=true, which bounds every backend, needs Docker Engine 28 or later on cgroup v2")


class Stack:
    def __init__(self, project, image, canary_dir=None):
        self.project = PROJECT_PREFIX + project
        self.image = image
        self.canary_dir = canary_dir or HERE
        # The backends key of this run: compose gives it to the service as
        # LOCUS_BACKENDS_KEY, from the name cyfr's .env holds it under.
        self.key = secrets.token_bytes(32)
        self.project_dir = tempfile.mkdtemp(prefix=f"{self.project}-")
        # The rest of the stack's definition names a project .env.
        open(os.path.join(self.project_dir, ".env"), "w").close()
        self.base = None
        self.container = None
        self.pool = f"{POOL_FIRST}-{POOL_LAST}"
        self.memory_bytes = None

    def env(self, **extra):
        return {
            **os.environ,
            "BACKENDS_IMAGE": self.image,
            "PROBE_DIR": HERE,
            "CANARY_DIR": self.canary_dir,
            "CYFR_LOCUS_BACKENDS_KEY": self.key.hex(),
            "BACKENDS_POOL": self.pool,
            "LOCUS_BACKENDS_MEMORY_BYTES": str(self.memory_bytes or ""),
            **extra,
        }

    def compose(self, *args, check=True, env=None):
        files = [os.path.join(ROOT, "docker-compose.yml"), os.path.join(HERE, "compose.locus-backends.yml")]
        return run(
            "docker", "compose", "--project-name", self.project, "--project-directory", self.project_dir,
            *[arg for file in files for arg in ("-f", file)], *args,
            env=env or self.env(), check=check,
        )

    def up(self, pool=None, memory_bytes=None):
        """(Re)creates the service with this pool and memory bound, and waits for the wire's health answer."""
        self.pool = pool or f"{POOL_FIRST}-{POOL_LAST}"
        self.memory_bytes = memory_bytes
        self.compose("up", "--detach", "--no-build", "--force-recreate", SERVICE)
        self.container = self.compose("ps", "--quiet", SERVICE).stdout.strip()
        expect(self.container, "compose started the locus-backends container")
        return self.published()

    def published(self):
        """Reads the published port (a restart may change it) and waits for the health answer."""
        address = self.compose("port", SERVICE, str(PORT)).stdout.strip().splitlines()[0]
        self.base = f"http://{address}"
        wait_healthy(self.base, self.logs)
        return self.base

    def controller(self, **options):
        return Controller(self.base, self.key, **options)

    def logs(self):
        return self.compose("logs", "--no-color", SERVICE, check=False).stdout

    def down(self):
        if os.environ.get("CI"):
            print(self.logs())
        self.compose("down", "--volumes", "--remove-orphans", check=False)
        shutil.rmtree(self.project_dir, ignore_errors=True)

    def exec(self, script, user=None, target=None):
        user_args = ["-u", user] if user else []
        return run("docker", "exec", *user_args, target or self.container, "sh", "-c", script, check=False)

    def processes(self, target=None):
        """Every process in the container: pid, session, uids, capability sets, no_new_privs and command line."""
        script = r"""
          for d in /proc/[0-9]*; do
            status="$(cat "$d/status" 2>/dev/null)" || continue
            stat="$(cat "$d/stat" 2>/dev/null)" || continue
            cmd="$(tr '\0\n|' '   ' < "$d/cmdline" 2>/dev/null)"
            uids="$(printf '%s\n' "$status" | awk '/^Uid:/ {print $2","$3","$4","$5}')"
            eff="$(printf '%s\n' "$status" | awk '/^CapEff:/ {print $2}')"
            prm="$(printf '%s\n' "$status" | awk '/^CapPrm:/ {print $2}')"
            bnd="$(printf '%s\n' "$status" | awk '/^CapBnd:/ {print $2}')"
            nnp="$(printf '%s\n' "$status" | awk '/^NoNewPrivs:/ {print $2}')"
            sid="$(printf '%s\n' "${stat##*) }" | awk '{print $4}')"
            printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "${d#/proc/}" "$sid" "$uids" "$eff" "$prm" "$bnd" "$nnp" "$cmd"
          done"""
        out = []
        for line in self.exec(script, target=target).stdout.splitlines():
            pid, sid, uids, eff, prm, bnd, nnp, cmd = line.split("|", 7)
            if uids:
                out.append({"pid": int(pid), "sid": int(sid or 0), "uids": [int(u) for u in uids.split(",")],
                            "cap_eff": eff, "cap_prm": prm, "cap_bnd": bnd, "no_new_privs": nnp == "1",
                            "cmd": cmd.strip()})
        return out

    def under_uid(self, uid, target=None):
        return [p for p in self.processes(target) if uid in p["uids"]]

    def pool_processes(self, target=None):
        return [p for p in self.processes(target) if any(POOL_FIRST <= u <= POOL_LAST for u in p["uids"])]


def wait_healthy(base, logs=lambda: ""):
    body = wire_json({"version": VERSION})
    for _ in range(90):
        try:
            status, answer, _boot = post(base + ROUTES["health"], {"content-type": "application/json"}, body, 2)
            if status == 200 and isinstance(answer, dict) and answer.get("version") == VERSION:
                return answer
        except (OSError, ValueError):
            pass
        time.sleep(1)
    sys.exit(f"FAIL: the backends service never answered POST {ROUTES['health']}\n" + logs())


def raw_head(base, route, header, declared):
    """Sends a request's head and a little of a large declared body, and reads the status it is answered with."""
    host, port = base.removeprefix("http://").rsplit(":", 1)
    with socket.create_connection((host, int(port)), timeout=5) as sock:
        sock.sendall(f"POST {route} HTTP/1.1\r\nhost: {host}\r\ncontent-type: application/json\r\n"
                     f"content-length: {declared}\r\n{AUTH_HEADER}: {header}\r\n\r\n".encode())
        sock.sendall(b"{" * 1024)
        head = b""
        while b"\r\n" not in head:
            chunk = sock.recv(4096)
            if not chunk:
                break
            head += chunk
    return int(head.split(b" ")[1])


def probe(name="probe", env=None):
    return {"name": name, "command": PROBE, "env": env or {}}


def owner_of(label, e=1):
    return {"athanor": f"ath_{label}", "server": f"mcp_{label}", "e": e}


if __name__ == "__main__":
    if sys.argv[1:] != ["--self-check"]:
        sys.exit("usage: harness.py --self-check")
    print("ok: harness.py derives the keys, signs every control message and invoke, and seals and opens "
          "the environment as tests/fixtures/locus_backends.json says")

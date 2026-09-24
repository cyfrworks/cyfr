# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The builds service under docker compose, for the builder image tests.

A Stack runs docker-compose.yml's `locus-builds` service (profile
`locus-builds`) layered with compose.locus-builds.yml, which adds only the
image under test, a loopback port, the residue canary, the pool's uid range
and the build deadline, and lets compose name the container after the
project. Everything else (capabilities, security options, read-only root,
`ipc: none`, tmpfs mounts, limits) is the shipped service. `up` can also
start it without the `writable-cgroups=true` option
(compose.no-writable-cgroups.yml), as a deployment that lacks it would.

The Stack is a client of the build wire (`Prima.BuilderProtocol`): it signs
every build request under `cyfr-locus/v1` with a builds key it makes for
the run, which compose hands the service as LOCUS_BUILDS_KEY. What the wire
fixes (its version, label, header, routes and statuses) is read from the
wire's vector file, tests/fixtures/locus_builds.json, and the signing here
must reproduce that file's request vector: `check_signing` runs when this
module is loaded, before any container starts, and
`python3 tests/builder-image/stack.py` runs it alone.
"""

import base64
import hashlib
import hmac
import http.client
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SERVICE = "locus-builds"
PROFILE = "locus-builds"
# Prefixed to every compose project and container of a run, for a host
# that tells one run's Docker objects from another's by name.
PROJECT_PREFIX = os.environ.get("STACK_PROJECT_PREFIX", "")
POOL_FIRST, POOL_LAST = 30001, 30016
RELEASE_UID = 10001
RELEASE_USER = "cyfr-builder"
RELEASE_BIN = "/app/bin/locus"
HOME_ROOT = "/var/lib/cyfr-builder/homes"

with open(os.path.join(ROOT, "tests", "fixtures", "locus_builds.json"), encoding="utf-8") as _vectors:
    WIRE = json.load(_vectors)

VERSION = WIRE["version"]
LABEL = WIRE["label"]
AUTH_HEADER = WIRE["auth_header"]
ROUTES = WIRE["routes"]
STATUSES = WIRE["statuses"]


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


# ————— the wire's signature —————


def request_key(key_hex):
    """The key build requests are signed with: the service key's HMAC-SHA256 over the service's label."""
    return hmac.new(bytes.fromhex(key_hex), LABEL.encode(), hashlib.sha256).digest()


def canonical(ts, nonce, body):
    """What a request's signature covers: `<label>/request`, ts, nonce and the body's hex SHA-256, one per line."""
    return "\n".join([f"{LABEL}/request", str(ts), nonce, hashlib.sha256(body).hexdigest()])


def auth_header(signing_key, ts, nonce, body):
    """The `x-cyfr-auth` value for `body`: the fields, the body's hash and the unpadded base64url MAC."""
    mac = hmac.new(signing_key, canonical(ts, nonce, body).encode(), hashlib.sha256).digest()
    mac = base64.urlsafe_b64encode(mac).rstrip(b"=").decode()
    return f"v1 kind=request ts={ts} nonce={nonce} body={hashlib.sha256(body).hexdigest()} mac={mac}"


def check_signing():
    """The signing above reproduces the vector file's request: its key, canonical string, MAC and header."""
    vector = WIRE["request"]
    body = vector["body"].encode()
    key = request_key(WIRE["key_hex"])
    header = auth_header(key, vector["ts"], vector["nonce"], body)
    wrong = {
        "request_key": (key.hex(), WIRE["request_key_hex"]),
        "canonical": (canonical(vector["ts"], vector["nonce"], body), vector["canonical"]),
        "mac": (header.rsplit("mac=", 1)[1], vector["mac"]),
        "header": (header, vector["header"]),
    }
    wrong = {name: {"signed": ours, "vector": theirs} for name, (ours, theirs) in wrong.items() if ours != theirs}
    if wrong:
        sys.exit("FAIL: stack.py does not sign a build request as tests/fixtures/locus_builds.json says\n"
                 + json.dumps(wrong, indent=2))


check_signing()


def build_canary():
    """Builds tests/fixtures/residue-canary.go for Linux on this host's architecture."""
    out = tempfile.mkdtemp(prefix="cyfr-canary-")
    # The read-only fixture mount must be traversable by pooled build UIDs.
    os.chmod(out, 0o755)
    run(
        "docker", "run", "--rm", "--name", f"{PROJECT_PREFIX}cyfr-canary-build-{os.getpid()}",
        "-v", f"{os.path.join(ROOT, 'tests', 'fixtures')}:/src:ro", "-v", f"{out}:/out",
        "-e", "CGO_ENABLED=0", "-e", "GOCACHE=/tmp/go-cache", "-e", "GOFLAGS=-buildvcs=false",
        "-w", "/src", "golang:1.26.6-alpine", "go", "build", "-o", "/out/canary", "residue-canary.go",
    )
    return out


class Stack:
    def __init__(self, project, image, canary_dir):
        self.project = PROJECT_PREFIX + project
        self.image = image
        self.canary_dir = canary_dir
        # The builds key of this run: compose gives it to the service as
        # LOCUS_BUILDS_KEY, from the name the server's .env holds it under.
        self.key = secrets.token_hex(32)
        self.project_dir = tempfile.mkdtemp(prefix=f"{self.project}-")
        # The rest of the stack's definition names a project .env.
        open(os.path.join(self.project_dir, ".env"), "w").close()
        self.base = None

    def env(self):
        return {
            **os.environ,
            "BUILDER_IMAGE": self.image,
            "CANARY_DIR": self.canary_dir,
            "CYFR_LOCUS_BUILDS_KEY": self.key,
            "BUILD_POOL": self.pool,
            "LOCUS_BUILDS_TIMEOUT_MS": str(self.timeout_ms or ""),
        }

    pool = f"{POOL_FIRST}-{POOL_LAST}"
    timeout_ms = None
    writable_cgroups = True

    def compose(self, *args, check=True):
        files = [os.path.join(ROOT, "docker-compose.yml"), os.path.join(HERE, "compose.locus-builds.yml")]
        if not self.writable_cgroups:
            files.append(os.path.join(HERE, "compose.no-writable-cgroups.yml"))
        return run(
            "docker", "compose", "--project-name", self.project, "--project-directory", self.project_dir,
            *[arg for file in files for arg in ("-f", file)],
            "--profile", PROFILE, *args,
            env=self.env(), check=check,
        )

    def up(self, pool=f"{POOL_FIRST}-{POOL_LAST}", timeout_ms=None, writable_cgroups=True):
        """(Re)creates the service with this pool and build deadline and waits for the wire's health answer.

        `writable_cgroups=False` starts it as a deployment without the
        `writable-cgroups=true` security option would.
        """
        self.pool = pool
        self.timeout_ms = timeout_ms
        self.writable_cgroups = writable_cgroups
        self.compose("up", "--detach", "--no-build", "--force-recreate", SERVICE)
        self.container = self.compose("ps", "--quiet", SERVICE).stdout.strip()
        address = self.compose("port", SERVICE, "4100").stdout.strip().splitlines()[0]
        self.base = f"http://{address}"
        body = json.dumps({"version": VERSION}).encode()
        for _ in range(90):
            try:
                status, lines = self.post(ROUTES["health"], body, timeout=2)
                if status == 200 and len(lines) == 1 and lines[0].get("type") == "health":
                    self.health = lines[0]
                    return
            except (OSError, ValueError):
                pass
            time.sleep(1)
        sys.exit(f"FAIL: the builds service never answered POST {ROUTES['health']}\n" + self.logs())

    def logs(self):
        return self.compose("logs", "--no-color", SERVICE, check=False).stdout

    def down(self):
        if os.environ.get("CI"):
            print(self.logs())
        self.compose("down", "--volumes", "--remove-orphans", check=False)
        shutil.rmtree(self.project_dir, ignore_errors=True)

    def exec(self, script, user=None):
        user_args = ["-u", user] if user else []
        return run("docker", "exec", *user_args, self.container, "sh", "-c", script, check=False)

    def processes(self):
        """Every process in the container as (pid, uids, cap_eff, command line)."""
        script = r"""
          for d in /proc/[0-9]*; do
            s="$(cat "$d/status" 2>/dev/null)" || continue
            uids="$(printf '%s\n' "$s" | awk '/^Uid:/ {print $2","$3","$4","$5}')"
            eff="$(printf '%s\n' "$s" | awk '/^CapEff:/ {print $2}')"
            cmd="$(tr '\0\n|' '   ' < "$d/cmdline" 2>/dev/null)"
            printf '%s|%s|%s|%s\n' "${d#/proc/}" "$uids" "$eff" "$cmd"
          done"""
        out = []
        for line in self.exec(script).stdout.splitlines():
            pid, uids, eff, cmd = line.split("|", 3)
            if uids:
                out.append({"pid": int(pid), "uids": [int(u) for u in uids.split(",")], "cap_eff": eff, "cmd": cmd.strip()})
        return out

    def pool_processes(self):
        return [p for p in self.processes() if any(POOL_FIRST <= u <= POOL_LAST for u in p["uids"])]

    def homes(self):
        """The entries of the home root, read as root inside the container."""
        return self.exec(f"ls -A {HOME_ROOT}").stdout.split()

    def post(self, route, body, headers=None, timeout=900):
        """POSTs `body` and reads the answer's lines, whatever its status: (HTTP status, lines)."""
        request = urllib.request.Request(
            self.base + route, data=body, method="POST", headers={"content-type": "application/json", **(headers or {})})
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.status, [json.loads(line) for line in response if line.strip()]
        except urllib.error.HTTPError as error:
            return error.code, [json.loads(line) for line in error.read().splitlines() if line.strip()]
        except http.client.HTTPException as error:
            raise ConnectionError(f"the answer broke off: {error!r}") from error

    def build_lines(self, sources, language, target_type, resolve=False, version=VERSION, athanor_id=None, key=None):
        """Signs and POSTs a build, and reads its answer: (HTTP status, progress lines, terminal line).

        Each build is for an athanor of its own unless one is named, so
        concurrent builds do not meet the per-athanor cap. `version` is the
        protocol version the body presents and `key` the builds key it is
        signed with, this run's by default.
        """
        body = json.dumps({
            "version": version,
            "athanor_id": athanor_id or f"ath_{uuid.uuid4()}",
            "language": language,
            "target_type": target_type,
            "resolve": resolve,
            # Past the builder's own ceiling, so the ceiling is the budget.
            "deadline": int(time.time() * 1000) + 900_000,
            "sources": [{"path": path, "base64": base64.b64encode(text.encode()).decode()} for path, text in sources.items()],
        }).encode()
        header = auth_header(request_key(key or self.key), int(time.time() * 1000), secrets.token_urlsafe(16), body)
        status, lines = self.post(ROUTES["build"], body, {AUTH_HEADER: header})
        if not lines or lines[-1].get("type") not in ("result", "refusal"):
            raise ConnectionError(f"HTTP {status}: the answer ended without a terminal line after {len(lines)} lines")
        return status, lines[:-1], lines[-1]

    def build(self, *args, **kwargs):
        """A build's end as (status, terminal line), the terminal line deciding as the wire says it does.

        The status is 200 for a result and the wire's status for a
        refusal's class: the HTTP status itself when the builder refused
        before it began, and the same number when the refusal closed a
        stream that opened with 200.
        """
        _http_status, _progress, terminal = self.build_lines(*args, **kwargs)
        return (200 if terminal["type"] == "result" else STATUSES[terminal["class"]]), terminal


def tincture(build_script, files=None):
    """A tincture whose `npm run build` runs build.sh, which must fill dist/."""
    sources = {
        "package.json": json.dumps({"name": "image-test", "private": True, "version": "0.0.1", "scripts": {"build": "sh build.sh"}}),
        "build.sh": build_script,
    }
    sources.update(files or {})
    return sources


def output_bytes(answer, name):
    """One output of a result, its digest checked against its bytes; None where the result has none."""
    for output in answer.get("outputs") or []:
        if output["path"] == name:
            data = base64.b64decode(output["base64"])
            digest = "sha256:" + hashlib.sha256(data).hexdigest()
            if output["digest"] != digest:
                sys.exit(f"FAIL: the result names {output['digest']} as the digest of {name}, whose bytes' is {digest}")
            return data
    return None


def output_file(answer, name):
    """The text of one output of a result, or None where the result has none."""
    data = output_bytes(answer, name)
    return data.decode() if data is not None else None


def diagnostics(answer):
    """A terminal line's log lines as one text."""
    return "\n".join(answer.get("diagnostics") or [])


def brief(answer):
    """A terminal line to print: its outputs by path and size, its log cut to its end."""
    if not isinstance(answer, dict):
        return answer
    shown = dict(answer)
    if "outputs" in shown:
        shown["outputs"] = {output["path"]: f"{len(output['base64']) * 3 // 4} bytes" for output in shown["outputs"]}
    shown["diagnostics"] = (shown.get("diagnostics") or [])[-40:]
    return shown


if __name__ == "__main__":
    print("ok: stack.py signs the request of tests/fixtures/locus_builds.json as the vector file says")

# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The builds service under docker compose, for the builder image tests.

A Stack runs docker-compose.yml's `locus` service behind its egress guard
with the builds key alone, so the keeper starts the builds role and no
other, layered with compose.builds.yml, which adds only the image under
test, the residue canary, the pool's uid range and the build deadline, on
the guard a loopback port and a tools directory first on its PATH, a
stand-in for cyfr and IPv6 on the locus network, and lets compose name the
containers after the project. Everything else (capabilities, security
options, read-only root, `ipc: none`, tmpfs mounts, bounds, the guard's
rules and Locus's wait for the guard's health) is the shipped stack. The
builds role listens in a space the guard forwards its port to, so its port
is read on the guard. `up`
can also start it without the `writable-cgroups=true` option
(compose.no-writable-cgroups.yml), as a deployment that lacks it would,
and a Stack made with a tools directory holding an `ip6tables` that fails
starts a guard whose rules fail (`up_refused`).

The Stack is a client of the build wire (`Prima.BuilderProtocol`): it signs
every build request under `cyfr-locus/v1` with a builds key it makes for
the run, which compose hands the service as LOCUS_BUILDS_KEY. What the wire
fixes (its version, label, header, routes and statuses) is read from the
wire's vector file, tests/fixtures/locus_builds.json, and the signing here
must reproduce that file's request vector: `check_signing` runs when this
module is loaded, before any container starts, and
`python3 tests/builder-image/stack.py` runs it alone. An answer is read as a
client reads it (`read_answer`): its progress lines are the build's log,
each `stage: message`; its output lines carry the files in order, held to
the wire's rules (each line the next `seq` and of at least one byte, a
file's lines together, a path never come back to, the wire's bounds on
files and bytes); and only a result that names every file sent, each at
the size and digest of its bytes, and any other only as a file of no
bytes, keeps them. The first result or refusal ends the answer: nothing
after it is read, and a refusal keeps nothing of the lines before it. A
line that breaks a rule fails the suite as a `WireError`, named by the
wire's error.

The command runner, the teardown on a signal and the part of the Stack that
does not depend on the service come from tests/imagesuite.py.

The builds role's facts and the release's (its service, profile, pool,
port, user, binary and directories) are read from the role table's vector
file, tests/fixtures/locus_roles.json (`Prima.LocusRoles`), when this
module is loaded: the suites take them from here and spell none.
"""

import base64
import hashlib
import hmac
import http.client
import json
import os
import secrets
import shutil
import sys
import time
import urllib.error
import urllib.request
import uuid

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
if os.path.join(ROOT, "tests") not in sys.path:
    sys.path.append(os.path.join(ROOT, "tests"))

import imagesuite  # noqa: E402
from imagesuite import PROJECT_PREFIX, listing, read_output, run  # noqa: E402

imagesuite.stop_on_signals()

with open(os.path.join(ROOT, "tests", "fixtures", "locus_roles.json"), encoding="utf-8") as _roles:
    _TABLE = json.load(_roles)

RELEASE = _TABLE["release"]
ROLE = next((role for role in _TABLE["roles"] if role["name"] == "builds"), None)
if ROLE is None:
    sys.exit("FAIL: tests/fixtures/locus_roles.json names no builds role")

SERVICE = RELEASE["service"]
GUARD = RELEASE["guard"]
NETWORK = RELEASE["network"]
POOL_FIRST, POOL_LAST = ROLE["first_uid"], ROLE["last_uid"]
PORT = ROLE["port"]
ENDPOINT_ADDRESS = RELEASE["endpoint_address"]
# The stand-in for cyfr the overlay starts, under cyfr's name and at cyfr's
# fixed address on the locus network, where it answers as core's host API
# (the guard is given CYFR_GUARD_HOST_API at that address and the suite's
# CYFR_HOST_API_PORT), and at cyfr's fixed endpoint address.
STAND_IN = "cyfr-stand-in"
BUILDS_SUBNET = RELEASE["subnet"]
HOST_API_ADDRESS = RELEASE["host_api_address"]
HOST_API_PORT = 4000
# The builds role's process: its user and uid, the release it runs, its
# run folder and its spawns' homes' root.
RELEASE_UID = ROLE["uid"]
RELEASE_USER = ROLE["user"]
RELEASE_BIN = RELEASE["bin"]
HOME_ROOT = ROLE["home_root"]
RUN_DIR = ROLE["run_dir"]

with open(os.path.join(ROOT, "tests", "fixtures", "locus_builds.json"), encoding="utf-8") as _vectors:
    WIRE = json.load(_vectors)

VERSION = WIRE["version"]
LABEL = WIRE["label"]
AUTH_HEADER = WIRE["auth_header"]
ROUTES = WIRE["routes"]
STATUSES = WIRE["statuses"]
BOUNDS = WIRE["bounds"]
TERMINAL = ("result", "refusal")


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
    """Builds tests/fixtures/residue-canary.go, and tests/builder-image/guard-role-space.go beside it, for Linux on this
    host's architecture."""
    # The read-only fixture mount must be traversable by pooled build UIDs.
    out = imagesuite.temporary_directory("cyfr-canary-", 0o755)
    run(
        "docker", "run", "--rm", "--name", f"{PROJECT_PREFIX}cyfr-canary-build-{os.getpid()}",
        "-v", f"{os.path.join(ROOT, 'tests', 'fixtures')}:/src:ro", "-v", f"{HERE}:/here:ro", "-v", f"{out}:/out",
        "-e", "CGO_ENABLED=0", "-e", "GOCACHE=/tmp/go-cache", "-e", "GOFLAGS=-buildvcs=false",
        "-w", "/src", "golang:1.27.2-alpine", "sh", "-c",
        "go build -o /out/canary residue-canary.go && go build -o /out/guard-role-space /here/guard-role-space.go",
    )
    return out


class Stack(imagesuite.Stack):
    def __init__(self, project, image, canary_dir, guard_tools_dir=None, names=False):
        super().__init__(project)
        # With names, the guard's resolver asks the suites' name listener
        # (compose.names.yml), which starts beside it.
        self.names = names
        self.image = image
        self.canary_dir = canary_dir
        # The service names the keeper's seccomp profile beside the
        # project's .env, which compose reads from the project directory, as
        # a scaffolded project holds it.
        shutil.copyfile(os.path.join(ROOT, "apps", "locus", "keeper", "seccomp", "keeper.json"),
                        os.path.join(self.project_dir, "keeper.seccomp.json"))
        # The directory first on the guard's PATH: empty, so the guard runs
        # the image's own tools, unless a test gives it one.
        self.guard_tools_dir = guard_tools_dir or imagesuite.temporary_directory("cyfr-guard-tools-", 0o755)
        # The builds key of this run: compose gives it to the service as
        # LOCUS_BUILDS_KEY, from the name the server's .env holds it under.
        self.key = secrets.token_hex(32)
        self.base = None
        self.container = None
        self.guard = None

    def env(self):
        return {
            **os.environ,
            "BUILDER_IMAGE": self.image,
            "CYFR_LOCUS_APPARMOR": imagesuite.APPARMOR,
            "CANARY_DIR": self.canary_dir,
            "GUARD_TOOLS_DIR": self.guard_tools_dir,
            "NAME_LISTENER_DIR": os.path.join(ROOT, "tests", "locus-backends-image"),
            "ENDPOINT_ADDRESS": ENDPOINT_ADDRESS,
            "HOST_API_ADDRESS": HOST_API_ADDRESS,
            "CYFR_HOST_API_PORT": str(HOST_API_PORT),
            "CYFR_LOCUS_BUILDS_KEY": self.key,
            "BUILD_POOL": self.pool,
            "LOCUS_BUILDS_TIMEOUT_MS": str(self.timeout_ms or ""),
        }

    pool = f"{POOL_FIRST}-{POOL_LAST}"
    timeout_ms = None
    writable_cgroups = True

    def compose(self, *args, check=True):
        files = [os.path.join(ROOT, "docker-compose.yml"), os.path.join(HERE, "compose.builds.yml")]
        if not self.writable_cgroups:
            files.append(os.path.join(HERE, "compose.no-writable-cgroups.yml"))
        if self.names:
            files.append(os.path.join(HERE, "compose.names.yml"))
        return run(
            "docker", "compose", "--project-name", self.project, "--project-directory", self.project_dir,
            *[arg for file in files for arg in ("-f", file)],
            *args,
            env=self.env(), check=check,
        )

    def up(self, pool=f"{POOL_FIRST}-{POOL_LAST}", timeout_ms=None, writable_cgroups=True, stand_in=False):
        """(Re)creates the service with this pool and build deadline, behind its guard, and waits for the wire's health answer.

        `writable_cgroups=False` starts it as a deployment without the
        `writable-cgroups=true` security option would; `stand_in` starts
        the stand-in for cyfr beside it.
        """
        self.pool = pool
        self.timeout_ms = timeout_ms
        self.writable_cgroups = writable_cgroups
        self.compose("up", "--detach", "--no-build", "--force-recreate", SERVICE, *([STAND_IN] if stand_in else []),
                     *(["name-listener"] if self.names else []))
        self.container = self.compose("ps", "--quiet", SERVICE).stdout.strip()
        self.guard = self.compose("ps", "--quiet", GUARD).stdout.strip()
        # The builder listens in the guard's namespace: the port is the guard's.
        address = self.compose("port", GUARD, str(PORT)).stdout.strip().splitlines()[0]
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

    def up_refused(self):
        """Starts the service as `up` does and answers compose's refusal: the result of an `up` that must not succeed."""
        self.pool = f"{POOL_FIRST}-{POOL_LAST}"
        self.timeout_ms = None
        self.writable_cgroups = True
        return self.compose("up", "--detach", "--no-build", "--force-recreate", SERVICE, check=False)

    def logs(self):
        return read_output(self.compose("logs", "--no-color", SERVICE, check=False), "the builds service's log")

    def guard_logs(self):
        return read_output(self.compose("logs", "--no-color", GUARD, check=False), "the builds guard's log")

    def names_heard(self):
        """The names the suites' name listener was asked, in order (`Stack(names=True)`)."""
        text = read_output(self.compose("logs", "--no-color", "--no-log-prefix", "name-listener", check=False),
                           "the name listener's log")
        return [line.split(" ", 1)[1].strip() for line in text.splitlines() if line.startswith("heard ")]

    def exec(self, script, user=None):
        user_args = ["-u", user] if user else []
        return run("docker", "exec", *user_args, self.container, "sh", "-c", script, check=False)

    def guard_exec(self, script):
        return run("docker", "exec", self.guard, "sh", "-c", script, check=False)

    def guard_counters(self):
        """The packets each of the guard's rules has matched, by the rule's text, both families."""
        saved = read_output(self.guard_exec("iptables-save -c -t filter && ip6tables-save -c -t filter"),
                            "the builds guard's rule counters")
        return guard_counters(saved)

    def inspect(self, container):
        return json.loads(run("docker", "inspect", container).stdout)[0]

    def beside(self, network, *command):
        """`command` run in a container of the image under test on `network`, outside the guard's namespace: a control."""
        return run("docker", "run", "--rm", "--name", f"{self.project}-beside-{os.getpid()}", "--network", f"{self.project}_{network}",
                   "--entrypoint", command[0], self.image, *command[1:], check=False, timeout=60)

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
        for line in listing(self.exec(script), "the process listing").splitlines():
            pid, uids, eff, cmd = line.split("|", 3)
            if uids:
                out.append({"pid": int(pid), "uids": [int(u) for u in uids.split(",")], "cap_eff": eff, "cmd": cmd.strip()})
        return out

    def pool_processes(self):
        return [p for p in self.processes() if any(POOL_FIRST <= u <= POOL_LAST for u in p["uids"])]

    def homes(self):
        """The entries of the home root, read as root inside the container."""
        return listing(self.exec(f"ls -A {HOME_ROOT}"), "the home root's listing").split()

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
        progress, terminal = read_answer(lines)
        return status, progress, terminal

    def build(self, *args, **kwargs):
        """A build's end as (status, terminal line), the terminal line deciding as the wire says it does.

        The status is 200 for a result and the wire's status for a
        refusal's class: the HTTP status itself when the builder refused
        before it began, and the same number when the refusal closed a
        stream that opened with 200.
        """
        _http_status, _progress, terminal = self.build_lines(*args, **kwargs)
        return (200 if terminal["type"] == "result" else STATUSES[terminal["class"]]), terminal


def guard_counters(saved):
    """The packet count of each rule of `iptables-save -c` output, by the rule's text (its chain and matches), both families as given."""
    counters = {}
    for line in saved.splitlines():
        if line.startswith("[") and "] -A " in line:
            count, rule = line.split("] ", 1)
            counters[rule] = counters.get(rule, 0) + int(count[1:].split(":")[0])
    return counters


# A probe of one connection per target, run by node under a spawn's uid:
# for each `host:port` after the argument `targets` (an IPv6 host in
# brackets, a zone allowed), the code the kernel answers the connect with,
# or `connected`. One attempt per target, at the first address a name
# resolves to (no happy eyeballs). The guard answers a refusal at once with
# an administratively-prohibited ICMP, EHOSTUNREACH over IPv4 and EACCES
# over IPv6; a closed port answers ECONNREFUSED, an unrouted address
# ENETUNREACH, and a black hole times out, so each outcome tells the rule's
# answer from every other. A link-local IPv6 destination is the exception:
# the kernel delivers no ICMPv6 error for it, so the refused connect times
# out, and the guard's rule is shown by its counter.
CONNECT_PROBE = r"""
const net = require("net");
(async () => {
  const lines = [];
  for (const target of process.argv.slice(process.argv.indexOf("targets") + 1)) {
    const at = target.lastIndexOf(":");
    const host = target.slice(0, at).replace(/^\[|\]$/g, "");
    const port = Number(target.slice(at + 1));
    const code = await new Promise((resolve) => {
      const socket = net.connect({ host, port, timeout: 4000, autoSelectFamily: false });
      socket.on("connect", () => { socket.destroy(); resolve("connected"); });
      socket.on("error", (error) => resolve(error.code || String(error)));
      socket.on("timeout", () => { socket.destroy(); resolve("ETIMEDOUT"); });
    });
    lines.push(`${target}=${code}`);
  }
  console.log(lines.join("\n"));
})();
"""
REFUSED = ("EHOSTUNREACH", "EACCES")


def tincture(build_script, files=None):
    """A tincture whose `npm run build` runs build.sh, which must fill dist/.

    It ships the lockfile of a package that installs nothing: a tincture
    builds only from its lockfile.
    """
    sources = {
        "package.json": json.dumps({"name": "image-test", "private": True, "version": "0.0.1", "scripts": {"build": "sh build.sh"}}),
        "package-lock.json": json.dumps({
            "name": "image-test", "version": "0.0.1", "lockfileVersion": 3, "requires": True,
            "packages": {"": {"name": "image-test", "version": "0.0.1"}},
        }),
        "build.sh": build_script,
    }
    sources.update(files or {})
    return sources


class WireError(SystemExit):
    """An answer that breaks the wire's rules: it fails the suite as `sys.exit` does, and `error` names the wire's error."""

    def __init__(self, error, message):
        super().__init__(f"FAIL: {message}")
        self.error = error


def read_answer(lines):
    """An answer's lines as a client keeps them: (its progress lines, its terminal line).

    The lines are read up to the first result or refusal, and none after
    it. The terminal line is given the build's log as `diagnostics` and,
    for a result, the files it names as `files`: those the output lines
    carried, once checked against what the result names, and empty for a
    file of no bytes, which only the result names. A line that breaks the
    wire's rules raises a `WireError`; lines with no terminal line are an
    answer that broke off.
    """
    progress, files, current, seq, total = [], {}, None, 0, 0
    for line in lines:
        if line.get("type") in TERMINAL:
            break
        if line.get("type") == "progress":
            progress.append(line)
            continue
        if line.get("type") != "output":
            sys.exit(f"FAIL: a {line.get('type')} line came before the terminal line")
        seq += 1
        path, data = line["path"], base64.b64decode(line["bytes"])
        if not data:
            raise WireError("empty_chunk", f"an output line of {path} carries no bytes")
        if line["seq"] != seq:
            raise WireError("out_of_order", f"output line {line['seq']} came where line {seq} was due")
        if path != current:
            if path in files:
                raise WireError("path_revisited", f"{path} was sent again after another file")
            if len(files) >= BOUNDS["max_output_files"]:
                raise WireError("too_many", f"the output lines name more than {BOUNDS['max_output_files']} files")
            current, files[path] = path, bytearray()
        total += len(data)
        if total > BOUNDS["max_output_bytes"]:
            raise WireError("too_large", f"the output lines total {total} bytes; at most {BOUNDS['max_output_bytes']} are read")
        files[path] += data
    else:
        raise ConnectionError(f"the answer ended without a terminal line after {len(lines)} lines")
    terminal = dict(line)
    terminal["diagnostics"] = [f"{line['stage']}: {line['message']}" for line in progress]
    if terminal.get("type") == "result":
        terminal["files"] = named_files(terminal["outputs"], files)
    return progress, terminal


def named_files(outputs, files):
    """The files a result names, by path: every file the output lines sent, at its size and digest, and any other
    as a file of no bytes."""
    named = {}
    for output in outputs:
        if output["path"] in named:
            raise WireError("duplicate_path", f"the result names {output['path']} twice")
        named[output["path"]] = output
    unsent = next((path for path, output in named.items() if output["size"] > 0 and path not in files), None)
    if unsent:
        raise WireError("unsent", f"the result names {unsent}, which no output line sent")
    unnamed = next((path for path in files if path not in named), None)
    if unnamed:
        raise WireError("unnamed", f"{unnamed} was sent and the result does not name it")
    kept = {path: bytes(files.get(path, b"")) for path in named}
    for path, output in named.items():
        digest = "sha256:" + hashlib.sha256(kept[path]).hexdigest()
        if output["size"] != len(kept[path]):
            raise WireError("size_mismatch", f"the result names {output} for {path}, whose bytes are {len(kept[path])}")
        if output["digest"] != digest:
            raise WireError("digest_mismatch", f"the result names {output} for {path}, whose bytes are of {digest}")
    return kept


def output_bytes(answer, name):
    """One file of a result, as its output lines carried it; None where the result has none."""
    return (answer.get("files") or {}).get(name)


def output_file(answer, name):
    """The text of one output of a result, or None where the result has none."""
    data = output_bytes(answer, name)
    return data.decode() if data is not None else None


def diagnostics(answer):
    """A build's log, its progress lines as a person reads them, as one text."""
    return "\n".join(answer.get("diagnostics") or [])


def brief(answer):
    """A terminal line to print: its files by path and size, its log cut to its end."""
    if not isinstance(answer, dict):
        return answer
    shown = dict(answer)
    shown.pop("files", None)
    if "outputs" in shown:
        shown["outputs"] = {output["path"]: f"{output['size']} bytes" for output in shown["outputs"]}
    shown["diagnostics"] = (shown.get("diagnostics") or [])[-40:]
    return shown


if __name__ == "__main__":
    print("ok: stack.py signs the request of tests/fixtures/locus_builds.json as the vector file says")

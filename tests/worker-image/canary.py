#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The credential canary (scenario `credential_canary`): a credential CYFR
attaches to a guest's request reaches neither the runner nor the worker
service, run as docker-compose.yml's opus service against the scripted
control plane (control_plane.py).

The hostile `credential_canary` catalyst
(apps/opus/test/support/test_wasm/hostile/) sends its input as its one
request, naming its connection, to an upstream on this machine that
reflects the request's headers and body. The control plane attaches a
canary value to the request by the connection's rule, as CYFR does, and
masks the value out of the answer. The guest reads the reflected answer,
asks its vault for the attached field (refused as `disclosure_refused`)
and writes everything it saw to one event and to its output. While the
attempt's close (`complete`) is held at the control plane, the suite's
privileged observer (`Stack.observe`'s `docker exec --privileged`, as
root: the service's own root holds no capability that reads another
uid's memory or home) reads

- the runner's process memory: every readable mapping of /proc/PID/mem;
- the worker service's process memory, the same way;
- every file under the runner's tmpfs home;

and then the attempt is killed, so the service reports the runner's exit.
The canary appears in none of these, nor in the container's log (the
service's, with each runner's output), the exit report, the attach
answer, the event or the output, nor in anything the runner or the
service sent the control plane; the upstream's log shows it, so the value
was attached and went nowhere else.

A positive control runs the same guest on another athanor, with another
canary value planted in a disclosed field, which its runner is handed at
attach and its guest reads and writes out: the same dump of that runner's
memory finds it, as do the attach answer, the event and the output, so a
clean dump is one that reads what it claims to.

Usage: tests/worker-image/canary.py IMAGE
"""

import http.server
import json
import os
import secrets
import shutil
import subprocess
import sys
import threading

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import memory  # noqa: E402
import runners  # noqa: E402
from control_plane import ZERO_AUTHORITY, ControlPlane  # noqa: E402
from stack import ROOT, SERVICE, Stack, expect, run  # noqa: E402

GUEST = os.path.join(ROOT, "apps", "opus", "test", "support", "test_wasm", "hostile", "credential_canary.wasm")
REF = "catalyst:local.credential-canary:0.1.0"
# The host the guest's request names: `.test` resolves nowhere, and the
# control plane makes an attached request to this machine at the URL's port.
HOST = "origin.test"
CONNECTION = "api_key"
RULE = {"in": "header", "name": "x-api-key", "template": "{value}"}
# The field the connection attaches, which the guest asks its vault for.
FIELD = "CANARY_KEY"
MASK = "[REDACTED]"
BOOT_S = 60
# The memory a dump must have read to count: a runner's VM alone holds
# well over a hundred MiB.
MIN_DUMP_BYTES = 32 << 20

# Every readable mapping of process $1, as /proc/$1/maps lists it, written
# to stdout; what was read is counted on stderr. A mapping the kernel will
# not read whole (a guard page, a device) is skipped and not counted.
DUMP_MEMORY = r"""
pid=$1
regions=0
bytes=0
while read -r range perms _rest; do
  case "$perms" in r*) ;; *) continue ;; esac
  start=$((0x${range%-*}))
  end=$((0x${range#*-}))
  if dd if=/proc/$pid/mem bs=1048576 iflag=skip_bytes,count_bytes skip=$start count=$((end - start)) 2>/dev/null; then
    regions=$((regions + 1))
    bytes=$((bytes + end - start))
  fi
done < /proc/$pid/maps
echo "regions=$regions bytes=$bytes" >&2
"""

# Every file under the home $1, written to stdout; on stderr, their count
# and the count of every entry the home holds, or that there is no such
# home.
DUMP_HOME = r"""
[ -d "$1" ] || { echo "no home $1" >&2; exit 3; }
find "$1" -type f -exec cat {} + 2>/dev/null
echo "files=$(find "$1" -type f | wc -l) entries=$(find "$1" | wc -l)" >&2
"""


def authority(attached):
    """The guest's authority: egress to the upstream's host for POST over plain HTTP, and a vault bound to an entry
    projecting FIELD, which CYFR attaches (handing the runner nothing) or, for the positive control, discloses."""
    vault = {
        "entry_id": "ent_worker_image_canary",
        "binding_digest": "sha256:" + "0" * 64,
        "scope": "athanor",
        "binding_key": "catalyst:local.credential-canary|@ingress|default",
        "destination": {"hosts": [HOST], "scheme": "http"},
        "projection": {"fields": [FIELD], "scopes": []},
    }
    if attached:
        vault["attach"] = RULE
    return {**ZERO_AUTHORITY,
            "resources": {"egress": {"domains": [HOST], "methods": ["POST"], "schemes": ["http"]}, "vault": vault}}


class Reflector:
    """The upstream, on this machine: every request it receives is logged whole, and answered 200 with a JSON
    body that reflects the request's method, path, headers and body."""

    def __init__(self):
        reflector = self
        self.lock = threading.Lock()
        self.log = []

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def reflect(self):
                length = int(self.headers.get("content-length") or 0)
                body = self.rfile.read(length) if length else b""
                request = {"method": self.command, "path": self.path, "headers": [[k, v] for k, v in self.headers.items()],
                           "body": body.decode(errors="replace")}
                with reflector.lock:
                    reflector.log.append(request)
                encoded = json.dumps({"reflected": request}).encode()
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def do_GET(self):
                self.reflect()

            def do_POST(self):
                self.reflect()

        class Server(http.server.ThreadingHTTPServer):
            daemon_threads = True
            allow_reuse_address = True

        self.server = Server(("0.0.0.0", 0), Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()

    def seen(self):
        with self.lock:
            return list(self.log)

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)


def scan(stack, script, arg, needles):
    """`script` run with `arg` by the privileged observer, its output searched as it streams for each needle:
    answers each needle's count, the bytes read and what the script counted on stderr."""
    command = ["docker", "exec", "--privileged", stack.container, "sh", "-c", script, "sh", str(arg)]
    found = {needle: 0 for needle in needles}
    keep = max(len(needle) for needle in needles) - 1
    total = 0
    tail = b""
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
        while True:
            chunk = process.stdout.read(1 << 20)
            if not chunk:
                break
            total += len(chunk)
            # A needle across two chunks is found in the window; one wholly
            # inside the kept tail was already counted, and the tail is
            # shorter than any needle.
            window = tail + chunk
            for needle in needles:
                found[needle] += window.count(needle)
            tail = window[-keep:] if keep else b""
        said = process.stderr.read().decode(errors="replace").strip()
    return found, total, said


def recorded_attach(plane, execution_id):
    """The attempt's attach is answered as the plane answers it, and the answer is kept on its record."""

    def answer(args, caller, entry):
        entry["answer"] = plane.default("attach", args, caller)
        return entry["answer"]

    plane.script("attach", answer, execution_id)


def run_guest(stack, plane, reflector, athanor, attached_value, disclosed_value=None):
    """Runs the canary guest for `athanor`, the connection attaching `attached_value` and, for the positive
    control, FIELD disclosed as `disclosed_value`. While its close is held, its runner's memory, the service's
    memory and its runner's home are read for every value named; then the attempt is killed and its runner's
    exit reported. Answers what the case reads."""
    marker = "canary-body-" + secrets.token_hex(8)
    request = {"connection": CONNECTION, "method": "POST", "url": f"http://{HOST}:{reflector.port}/reflect",
               "headers": {"content-type": "text/plain"}, "body": marker}
    attached = {CONNECTION: {"value": attached_value, "attach": RULE, "hosts": [HOST]}}
    attempt = plane.mint(stack.boot, "catalyst", REF, memory.wasm(GUEST), request, athanor, 120_000,
                         authority=authority(attached=disclosed_value is None), attached=attached,
                         secrets={FIELD: disclosed_value} if disclosed_value else None)
    execution_id = attempt["execution_id"]
    recorded_attach(plane, execution_id)
    release = memory.held(plane, "complete", execution_id)
    needles = [value.encode() for value in (attached_value, disclosed_value) if value] + [marker.encode()]
    try:
        expect(stack.start(attempt)[1] == {"v": 1, "ok": True}, f"{athanor}: the canary guest starts")
        runner = memory.attached_runner(stack, plane, attempt)
        complete = plane.wait_seen("complete", execution_id, BOOT_S)[0]
        service_pid = stack.service_beam_pid()
        runner_memory = scan(stack, DUMP_MEMORY, runner["pid"], needles)
        service_memory = scan(stack, DUMP_MEMORY, service_pid, needles)
        home = scan(stack, DUMP_HOME, runner["home"], needles)
        expect(stack.kill(execution_id)[1] == {"v": 1, "ok": True},
               f"{athanor}: with every dump read, the attempt is killed while its close is held")
        exits = runners.exit_reports(plane, attempt, 15)
        runners.wait_gone(stack, runner, stack.release_grace_ms / 1000 + 10, "the canary runner's process to be gone")
    finally:
        release.set()
    return {
        "attempt": attempt,
        "marker": marker,
        "runner": runner,
        "runner_memory": runner_memory,
        "service_memory": service_memory,
        "home": home,
        "output": complete["args"]["outcome"]["output"],
        "events": [json.loads(delta["event"]) for push in plane.seen("push_deltas", execution_id)
                   for delta in push["args"].get("deltas", [])],
        "attach_answer": plane.seen("attach", execution_id)[0]["answer"],
        "exits": exits,
        "sent": plane.seen(None, execution_id),
        "logs": stack.logs(),
    }


def where(value, seen):
    """Every place `value` shows of what a case read."""
    needle = value.encode()
    found = []
    for name in ("runner_memory", "service_memory", "home"):
        if seen[name][0].get(needle, 0):
            found.append(f"{name} ({seen[name][0][needle]} times)")
    for name in ("output", "events", "attach_answer", "exits", "sent"):
        if value in json.dumps(seen[name], default=str):
            found.append(name)
    if value in seen["logs"]:
        found.append("logs")
    return found


def dumped(label, seen):
    """The dumps read what they claim: the runner's memory and the service's are whole VMs, the home holds files."""
    for name in ("runner_memory", "service_memory"):
        _found, total, said = seen[name]
        expect(total >= MIN_DUMP_BYTES and said.startswith("regions="),
               f"{label}: the {name.replace('_', ' ')} dump read {total} bytes ({said})", said)
    _found, total, said = seen["home"]
    expect(said.startswith("files="), f"{label}: the runner's home dump read {total} bytes of its files ({said})", said)


def test_credential_canary(stack, plane, reflector):
    """scenario credential_canary: an attached canary is in none of the places a runner or the service can
    hold or say it, and in the upstream's log."""
    canary = "sk-canary-" + secrets.token_hex(16)
    seen = run_guest(stack, plane, reflector, "ath_canary", canary)
    label = "credential_canary"
    dumped(label, seen)

    received = [r for r in reflector.seen() if seen["marker"] in r["body"]]
    expect(len(received) == 1 and [RULE["name"], canary] in [[k.lower(), v] for k, v in received[0]["headers"]],
           f"{label}: the upstream's log shows the canary, attached as {RULE['name']} by the connection's rule",
           [{**r, "headers": [[k, v.replace(canary, "<canary>")] for k, v in r["headers"]]} for r in received])

    output = seen["output"]
    data = output.get("data") if isinstance(output, dict) else None
    fetched = (data or {}).get("fetched") or {}
    reflected = json.loads(fetched.get("body") or "{}").get("reflected", {})
    expect(output.get("status") == 200 and fetched.get("status") == 200 and reflected.get("body") == seen["marker"]
           and [RULE["name"], MASK] in [[k.lower(), v] for k, v in reflected.get("headers", [])],
           f"{label}: the guest read the reflected request, the attached header masked as {MASK}", data)
    read = (data or {}).get("read") or {}
    expect(read.get("ok") is False and str(read.get("value", "")).startswith(f"disclosure_refused: {FIELD}"),
           f"{label}: its vault read of {FIELD} was refused as attached ({read.get('value')})", read)
    expect(seen["events"] == [data], f"{label}: its one event carries what its output does", seen["events"])
    denials = [(r["args"]["type"], r["args"]["message"]) for r in seen["sent"] if r["op"] == "record_denial"]
    expect(denials == [("disclosure_refused", FIELD)], f"{label}: the refusal was reported as disclosure_refused", denials)
    expect(seen["attach_answer"] == {"ok": {}}, f"{label}: its runner's attach was handed nothing", seen["attach_answer"])
    expect(len(seen["exits"]) == 1 and seen["exits"][0]["args"]["runner"] == seen["runner"]["runner"],
           f"{label}: the service reported the runner's exit holding the attempt", seen["exits"])
    expect(seen["runner_memory"][0][seen["marker"].encode()] > 0,
           f"{label}: the runner's memory holds what its guest read (the reflected body's marker, "
           f"{seen['runner_memory'][0][seen['marker'].encode()]} times)")

    found = where(canary, seen)
    expect(found == [],
           f"{label}: the canary is in none of the runner's memory, the service's memory, the runner's home, the "
           "container's log, the exit report, the attach answer, the event, the output or anything sent to the "
           "control plane", found)


def test_positive_control(stack, plane, reflector):
    """The positive control: a canary planted in a disclosed field is found by the same dump."""
    planted = "sk-planted-" + secrets.token_hex(16)
    attached = "sk-control-attached-" + secrets.token_hex(16)
    seen = run_guest(stack, plane, reflector, "ath_canary_control", attached, disclosed_value=planted)
    label = "positive control"
    dumped(label, seen)

    data = seen["output"].get("data") if isinstance(seen["output"], dict) else None
    read = (data or {}).get("read") or {}
    expect(read == {"ok": True, "value": planted}, f"{label}: the guest read the planted field {FIELD} and wrote it out",
           {**read, "value": str(read.get("value")).replace(planted, "<planted>")})
    found = where(planted, seen)
    count = seen["runner_memory"][0][planted.encode()]
    print(f"positive-control record: the value planted in {FIELD} was found {count} times in runner "
          f"{seen['runner']['runner']}'s {seen['runner_memory'][1]} bytes of memory ({seen['runner_memory'][2]}); "
          f"found in: {', '.join(found)}", flush=True)
    expect(count > 0 and {"attach_answer", "events", "output"} <= set(found),
           f"{label}: the dump of its runner's memory finds the planted value, as do the attach answer, the event and "
           "the output: the canary check reads what it claims to", found)


def prerequisites(image):
    for tool in ("docker",):
        if shutil.which(tool) is None:
            sys.exit(f"FAIL: prerequisite missing: {tool} is not on PATH")
    if run("docker", "compose", "version", check=False).returncode != 0:
        sys.exit("FAIL: prerequisite missing: docker compose does not answer")
    if run("docker", "image", "inspect", image, check=False).returncode != 0:
        sys.exit(f"FAIL: prerequisite missing: the image {image} is not built")
    if not os.path.isfile(GUEST):
        sys.exit(f"FAIL: prerequisite missing: the canary guest {GUEST}")


def main(image):
    prerequisites(image)
    plane = ControlPlane(secrets.token_bytes(32), SERVICE).serve()
    reflector = Reflector()
    stack = Stack("cyfr-opus-canary", image, plane)
    try:
        stack.up()
        test_credential_canary(stack, plane, reflector)
        test_positive_control(stack, plane, reflector)
    finally:
        stack.down()
        reflector.stop()
        plane.stop()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])

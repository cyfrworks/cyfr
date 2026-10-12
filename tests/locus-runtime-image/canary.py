#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The credential canary (scenario `credential_canary`): a credential CYFR
attaches to a guest's request reaches neither the runner nor the worker
service, run as docker-compose.yml's locus-runtime service against the scripted
control plane (control_plane.py).

The hostile `credential_canary` catalyst
(apps/locus/test/support/runtime/test_wasm/hostile/) sends its input as its one
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
- every entry under the runner's tmpfs home, recursively: its name (a
  file's, a directory's or a symlink's), a symlink's target and a regular
  file's contents;

each observer's exit status and account checked (`memory_verdict`,
`home_verdict`): an observer that fails, a home walk that does not
finish and a mapping that could not be read for any reason but the
kernel's own refusal (`kernel_omission`) fail the canary, and every
mapping not read is listed with the verdict;

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
clean dump is one that reads what it claims to. Before its home is read,
values are planted there as a directory's name, a file's contents inside
it, a file's name and a symlink's target, and the same home dump finds
each. The control's verdicts are given before the canary's, so a clean
home is reported only beside a home check shown to find what is there.

Usage: tests/locus-runtime-image/canary.py IMAGE
"""

import http.server
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import memory  # noqa: E402
import runners  # noqa: E402
from control_plane import ZERO_AUTHORITY, ControlPlane  # noqa: E402
from stack import ROOT, SERVICE, Stack, expect, run  # noqa: E402

GUEST = os.path.join(ROOT, "apps", "locus", "test", "support", "runtime", "test_wasm", "hostile", "credential_canary.wasm")
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
# to stdout. On stderr, one line for each readable mapping dd could not
# read, `omitted RANGE PERMS PATH` while the process still maps it and
# `vanished RANGE PERMS PATH` once it does not (the process unmapped or
# shrank it during the dump: whatever it still maps readable within the
# range is read again), then the account: `regions=` mappings read whole,
# `bytes=` every byte dd wrote (a partial read's and a second read's too),
# `unreadable=` mappings not mapped readable (guard pages among them),
# never read, and the two counts of lines. A process that is gone at the
# start or the end, or a dd that reports no byte count, exits non-zero.
DUMP_MEMORY = r"""
pid=$1
maps=$(cat /proc/$pid/maps) || { echo "no process $pid" >&2; exit 3; }
exec 3>&1
regions=0 bytes=0 unreadable=0 omitted=0 vanished=0
# Bytes $1 to $2 of the process to fd 3, the observer's stdout, adding what
# dd wrote to `bytes`; dd's report and status go to this capture. Fails as
# dd does.
read_range() {
  report=$(dd if=/proc/$pid/mem bs=1048576 iflag=skip_bytes,count_bytes skip=$1 count=$(($2 - $1)) 2>&1 >&3; echo "status=$?")
  copied=$(printf '%s\n' "$report" | sed -n 's/^\([0-9][0-9]*\) bytes.*/\1/p')
  [ -n "$copied" ] || { echo "dd reported no byte count at $1" >&2; exit 4; }
  bytes=$((bytes + copied))
  [ "${report##*status=}" = 0 ]
}
while read -r range perms _offset _device _inode path; do
  case "$perms" in r*) ;; *) unreadable=$((unreadable + 1)); continue ;; esac
  start=$((0x${range%-*}))
  end=$((0x${range#*-}))
  if read_range "$start" "$end"; then
    regions=$((regions + 1))
  elif grep -q "^$range " /proc/$pid/maps; then
    omitted=$((omitted + 1)); echo "omitted $range $perms $path" >&2
  else
    vanished=$((vanished + 1)); echo "vanished $range $perms $path" >&2
    while read -r now now_perms _rest; do
      case "$now_perms" in r*) ;; *) continue ;; esac
      from=$((0x${now%-*})); to=$((0x${now#*-}))
      [ "$from" -lt "$end" ] && [ "$to" -gt "$start" ] || continue
      [ "$from" -ge "$start" ] || from=$start
      [ "$to" -le "$end" ] || to=$end
      read_range "$from" "$to" || :
    done < /proc/$pid/maps
  fi
done <<EOF
$maps
EOF
cat /proc/$pid/maps > /dev/null || { echo "process $pid ended during the dump" >&2; exit 5; }
echo "regions=$regions bytes=$bytes unreadable=$unreadable omitted=$omitted vanished=$vanished" >&2
"""

# The kernel's own pages that /proc/PID/mem refuses to read although they
# are mapped readable (`kernel_omission`).
KERNEL_PAGES = ("[vvar]", "[vvar_vclock]", "[vsyscall]")

# Every entry under the home $1, recursively, written to stdout: each
# entry's path, which names every file, directory and symlink; each
# symlink's target; and each regular file's contents. A symlink is read,
# never followed. On stderr, the counts of regular files, symlinks and
# entries and nothing else; a walk or a read that fails says so on stderr
# and exits non-zero.
DUMP_HOME = r"""
[ -d "$1" ] || { echo "no home $1" >&2; exit 3; }
find "$1" -mindepth 1 || exit 4
find "$1" -type l -printf '%l\n' || exit 5
find "$1" -type f -exec cat -- {} + || exit 6
files=$(find "$1" -type f -printf x) || exit 7
links=$(find "$1" -type l -printf x) || exit 7
entries=$(find "$1" -mindepth 1 -printf x) || exit 7
echo "files=${#files} links=${#links} entries=${#entries}" >&2
"""

# The positive control's plants in the home $1: a directory named $2
# holding a file whose contents are $3, a file named $4, and a symlink
# whose target is $5. HOME_UNPLANT takes them out again.
HOME_PLANT = r"""
mkdir "$1/$2" && printf %s "$3" > "$1/$2/contents" && : > "$1/$4" && ln -s "$5" "$1/canary-plant-link"
"""
HOME_UNPLANT = r"""
rm -rf "$1/$2" "$1/$4" "$1/canary-plant-link"
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

        # Loopback: the control plane, on this machine, makes the attached
        # request (control_plane.py), and nothing else needs to reach it.
        self.server = Server(("127.0.0.1", 0), Handler)
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


def count_stream(chunks, needles):
    """Each needle's count over the bytes of `chunks` taken together, as `bytes.count` gives it over the whole, and
    the bytes read, keeping only a window of the stream: the previous chunk's last bytes, one fewer than the
    longest needle, before the next chunk. A needle across the boundary between two chunks is then whole in the
    window. A needle's search in a window resumes after its last counted match, so a match is counted once
    although its bytes stay in the window, and matches never overlap."""
    keep = max(len(needle) for needle in needles) - 1
    found = dict.fromkeys(needles, 0)
    # The stream offset each needle's search resumes at.
    resume = dict.fromkeys(needles, 0)
    total = 0
    tail = b""
    for chunk in chunks:
        offset = total - len(tail)
        window = tail + chunk
        total += len(chunk)
        for needle in found:
            at = window.find(needle, max(resume[needle] - offset, 0))
            while at != -1:
                found[needle] += 1
                resume[needle] = offset + at + len(needle)
                at = window.find(needle, at + len(needle))
        tail = window[-keep:] if keep else b""
    return found, total


def scan(stack, script, arg, needles):
    """`script` run with `arg` by the privileged observer, as `observe` answers it."""
    return observe(["docker", "exec", "--privileged", stack.container, "sh", "-c", script, "sh", str(arg)], needles)


def observe(command, needles, chunk_size=1 << 20):
    """`command` run, its output searched as it streams for each needle: answers each needle's count, the bytes
    read, what it said on stderr, each needle shown as `<value>`, and its exit status, read once it has exited."""
    # stderr to a file, so a long account cannot fill a pipe the observer then blocks on.
    with tempfile.TemporaryFile() as errors:
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors) as process:
            found, total = count_stream(iter(lambda: process.stdout.read(chunk_size), b""), needles)
            status = process.wait()
        errors.seek(0)
        said = errors.read().decode(errors="replace").strip()
    for needle in needles:
        said = said.replace(needle.decode(errors="replace"), "<value>")
    return found, total, said, status


def kernel_omission(path):
    """Whether /proc/PID/mem refuses, of its own accord, a mapping of `path` mapped readable: the kernel's own
    pages and a device's mapping."""
    return path in KERNEL_PAGES or path.startswith("/dev/")


def memory_verdict(status, total, said):
    """What is wrong with a memory dump, by its observer's `status`, the `total` bytes it wrote and what it `said`
    (DUMP_MEMORY), and the mappings it did not read: the observer exited non-zero, its account is missing, its
    lines do not add up to its counts, its bytes are not the bytes read or fewer than MIN_DUMP_BYTES, or it could
    not read a mapping still mapped that is not a `kernel_omission`. Answers (problems, the mappings not read)."""
    problems = []
    if status != 0:
        problems.append(f"the observer exited {status}")
    lines = [line.strip() for line in said.splitlines()]
    account = re.fullmatch(r"regions=(\d+) bytes=(\d+) unreadable=(\d+) omitted=(\d+) vanished=(\d+)",
                           lines[-1]) if lines else None
    if account is None:
        return problems + ["the observer gave no account of what it read"], []
    _regions, claimed, _unreadable, omitted, vanished = (int(n) for n in account.groups())
    listed = [re.fullmatch(r"(omitted|vanished) (\S+) (\S+) ?(.*)", line) for line in lines[:-1]]
    for line, entry in zip(lines[:-1], listed):
        if entry is None:
            problems.append(f"the observer said: {line}")
    listed = [entry for entry in listed if entry]
    for kind, count in (("omitted", omitted), ("vanished", vanished)):
        if sum(1 for entry in listed if entry[1] == kind) != count:
            problems.append(f"the observer counted {count} {kind} mappings but listed others")
    if claimed != total:
        problems.append(f"the observer counted {claimed} bytes but wrote {total}")
    if total < MIN_DUMP_BYTES:
        problems.append(f"the dump read {total} bytes, fewer than {MIN_DUMP_BYTES}")
    for entry in listed:
        if entry[1] == "omitted" and not kernel_omission(entry[4]):
            problems.append(f"the observer could not read {entry[0]}")
    return problems, [entry[0] for entry in listed]


def home_verdict(status, said):
    """What is wrong with a home dump, by its observer's `status` and what it `said` (DUMP_HOME): the walk is whole
    only if the observer exited 0 and said its counts and nothing else."""
    problems = []
    if status != 0:
        problems.append(f"the observer exited {status}")
    if not re.fullmatch(r"files=\d+ links=\d+ entries=\d+", said):
        problems.append(f"the observer said: {said}")
    return problems


def recorded_attach(plane, execution_id):
    """The attempt's attach is answered as the plane answers it, and the answer is kept on its record."""

    def answer(args, caller, entry):
        entry["answer"] = plane.default("attach", args, caller)
        return entry["answer"]

    plane.script("attach", answer, execution_id)


def run_guest(stack, plane, reflector, athanor, attached_value, disclosed_value=None, plants=None):
    """Runs the canary guest for `athanor`, the connection attaching `attached_value` and, for the positive
    control, FIELD disclosed as `disclosed_value` and `plants` (`plant_values/0`) planted in its runner's home.
    While its close is held, its runner's memory, the service's memory and its runner's home are read for every
    value named; then the attempt is killed and its runner's exit reported. Answers what the case reads."""
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
    planted = list((plants or {}).values())
    needles = [value.encode() for value in (attached_value, disclosed_value, *planted) if value] + [marker.encode()]
    try:
        expect(stack.start(attempt)[1] == {"v": 1, "ok": True}, f"{athanor}: the canary guest starts")
        runner = memory.attached_runner(stack, plane, attempt)
        complete = plane.wait_seen("complete", execution_id, BOOT_S)[0]
        service_pid = stack.service_beam_pid()
        runner_memory = scan(stack, DUMP_MEMORY, runner["pid"], needles)
        service_memory = scan(stack, DUMP_MEMORY, service_pid, needles)
        if plants:
            plant(stack, HOME_PLANT, runner["home"], plants)
        try:
            home = scan(stack, DUMP_HOME, runner["home"], needles)
        finally:
            if plants:
                plant(stack, HOME_UNPLANT, runner["home"], plants)
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


def plant_values():
    """The values the positive control plants in its runner's home, by what holds each."""
    return {kind: f"sk-home-{kind.replace(' ', '-')}-{secrets.token_hex(12)}"
            for kind in ("directory name", "file contents", "file name", "symlink target")}


def plant(stack, script, home, plants):
    """`script` (HOME_PLANT or HOME_UNPLANT) run as root in the runner's home with the plants as its arguments."""
    run("docker", "exec", "--privileged", stack.container, "sh", "-c", script, "sh", str(home),
        plants["directory name"], plants["file contents"], plants["file name"], plants["symlink target"])


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
    """The dumps read what they claim: the runner's memory and the service's are whole VMs, every mapping not read
    named, and the home's entries were walked to the end (that the walk finds what a home holds is the positive
    control's)."""
    for name in ("runner_memory", "service_memory"):
        _found, total, said, status = seen[name]
        problems, omissions = memory_verdict(status, total, said)
        account = said.splitlines()[-1] if said else ""
        expect(problems == [],
               f"{label}: the {name.replace('_', ' ')} dump read {total} bytes ({account}); not read: "
               f"{', '.join(omissions) or 'nothing'}", {"problems": problems, "said": said})
    _found, total, said, status = seen["home"]
    expect(home_verdict(status, said) == [],
           f"{label}: the runner's home dump read {total} bytes of its entries' names, links and files ({said})",
           {"problems": home_verdict(status, said), "said": said})


def run_credential_canary(stack, plane, reflector):
    """scenario credential_canary's run: the guest with an attached canary. Answers the canary and what was read."""
    canary = "sk-canary-" + secrets.token_hex(16)
    return canary, run_guest(stack, plane, reflector, "ath_canary", canary)


def check_credential_canary(reflector, canary, seen):
    """scenario credential_canary: an attached canary is in none of the places a runner or the service can
    hold or say it, and in the upstream's log."""
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


def run_positive_control(stack, plane, reflector):
    """The positive control's run: another canary disclosed, and values planted in its runner's home."""
    planted = "sk-planted-" + secrets.token_hex(16)
    attached = "sk-control-attached-" + secrets.token_hex(16)
    plants = plant_values()
    seen = run_guest(stack, plane, reflector, "ath_canary_control", attached, disclosed_value=planted, plants=plants)
    return planted, plants, seen


def check_positive_control(planted, plants, seen):
    """The positive control: a canary planted in a disclosed field is found by the same dump, and each value
    planted in the runner's home by the same home dump."""
    label = "positive control"
    dumped(label, seen)

    data = seen["output"].get("data") if isinstance(seen["output"], dict) else None
    read = (data or {}).get("read") or {}
    expect(read == {"ok": True, "value": planted}, f"{label}: the guest read the planted field {FIELD} and wrote it out",
           {**read, "value": str(read.get("value")).replace(planted, "<planted>")})
    found = where(planted, seen)
    count = seen["runner_memory"][0][planted.encode()]
    print(f"positive-control record: the value planted in {FIELD} was found {count} times in runner "
          f"{seen['runner']['runner']}'s {seen['runner_memory'][1]} bytes of memory "
          f"({seen['runner_memory'][2].splitlines()[-1]}); found in: {', '.join(found)}", flush=True)
    expect(count > 0 and {"attach_answer", "events", "output"} <= set(found),
           f"{label}: the dump of its runner's memory finds the planted value, as do the attach answer, the event and "
           "the output: the canary check reads what it claims to", found)
    home_found, _total, said, _status = seen["home"]
    for kind, value in plants.items():
        expect(home_found[value.encode()] > 0,
               f"{label}: the runner's home dump finds the value planted as a {kind} ({said})")


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
    stack = Stack("cyfr-locus-runtime-canary", image, plane)
    try:
        stack.up()
        canary, canary_seen = run_credential_canary(stack, plane, reflector)
        control = run_positive_control(stack, plane, reflector)
        # The control's verdicts first: the dumps are shown to find what is
        # there before the canary's clean dumps are believed.
        check_positive_control(*control)
        check_credential_canary(reflector, canary, canary_seen)
    finally:
        stack.down()
        reflector.stop()
        plane.stop()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])

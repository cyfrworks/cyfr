# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""What the image suites' three harnesses share.

tests/builder-image/stack.py, tests/locus-runtime-image/stack.py and
tests/locus-backends-image/harness.py each run the Locus image behind its
guard under docker compose, holding the key of its role alone. They share
the command runner (`run`), the teardown on a signal (`stop_on_signals`),
the temporary directories removed at exit (`temporary_directory`), the
default bridge's gateway (`bridge_gateway`), the reading of a guard's
failure from its inspect record (`guard_failed`), and the part of a
compose stack that does not depend on the service (`Stack`: its project
name, its project directory holding the seccomp profiles docker-compose.yml
names, and `down`). What differs between them (compose files, services,
their logs) stays in each harness's own subclass.

Importing this module calls no Docker and binds nothing: CI's static job
imports the runtime harness on every change.
"""

import atexit
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

# Prefixed to every compose project and container of a run, and so to its
# project directory and network, for a host that tells one run's Docker
# objects from another's by name.
PROJECT_PREFIX = os.environ.get("PROOF_RUN_PREFIX", "")

# The name of this tree's AppArmor profile, which a Locus container runs
# under (docker-compose.yml's CYFR_LOCUS_APPARMOR): the file cyfr's package
# apparmor holds it in.
_ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
with open(os.path.join(_ROOT, "apps", "codex", "internal", "apparmor", "name")) as _name:
    APPARMOR = _name.read().strip()

# The seccomp profiles docker-compose.yml names beside it, each by the name a
# scaffolded project holds it under, at the path this tree tracks it: the
# keeper's, which Locus runs under, and the container profile, which its
# guard and every other service run under.
SECCOMP_PROFILES = {
    "keeper.seccomp.json": os.path.join(_ROOT, "apps", "locus", "keeper", "seccomp", "keeper.json"),
    "container.seccomp.json": os.path.join(_ROOT, "apps", "locus", "keeper", "seccomp", "container.json"),
}


def seccomp_profile_named(inline):
    """The name, of SECCOMP_PROFILES, of the profile Docker reports inline as
    `inline` (its JSON); exits naming the failure when it is none of them."""
    profile = json.loads(inline)
    for name, path in SECCOMP_PROFILES.items():
        with open(path) as f:
            if json.load(f) == profile:
                return name
    sys.exit("FAIL: a container runs under a seccomp profile that is none of " + ", ".join(SECCOMP_PROFILES))


def run_name(name):
    """`--name NAME` for a one-off container a suite starts, under
    PROOF_RUN_PREFIX (NAME carries PROJECT_PREFIX, or a stack's project),
    or no argument without it, so the container runs unnamed as CI runs
    it."""
    return ["--name", name] if PROJECT_PREFIX else []

# How long `docker compose down` gives each container to stop once the
# suite was signalled. heavy-check sends TERM at its hold deadline and KILL
# its grace later (30 s by default); a down that waited out Locus's own
# stop_grace_period (40 s) would be killed midway and leave the project
# behind.
SIGNALLED_STOP_S = 10

# How many times `down` runs `docker compose down` on a project before it
# reports the teardown failed, and how long it waits between attempts: a
# daemon that answers again within a few seconds loses no project.
DOWN_ATTEMPTS = 3
DOWN_RETRY_S = 2

# The signal the suite was stopped by, once one arrived.
_signalled = []
# Every stack not yet torn down and every temporary directory not yet
# removed, oldest first, for the exit hook. A stack stays here until its
# `docker compose down` succeeds.
_stacks = []
_guards = []
_directories = []
# Set while the exit hook runs: a teardown that fails there is reported by
# the exit status, not by a SystemExit an exit hook cannot raise.
_exiting = []


def run(*args, check=True, env=None, timeout=None):
    result = subprocess.run(args, capture_output=True, text=True, env=env, timeout=timeout)
    if check and result.returncode != 0:
        sys.exit(f"FAIL: {' '.join(args)} exited {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


def _on_signal(signum, _frame):
    # The first signal unwinds the suite, so every `finally` runs its
    # teardown. A later one arrives while that teardown runs (a cancel sent
    # twice, or heavy-check's TERM to the rest of the session) and must not
    # abort it midway: it is ignored, and KILL is what ends a teardown that
    # hangs.
    if _signalled:
        return
    _signalled.append(signum)
    raise SystemExit(128 + signum)


def stop_on_signals():
    """TERM and INT end the suite as `sys.exit(128 + signal)` does, so its teardown runs.

    Installed from the main thread only, as Python requires; each harness
    calls it when it is imported.
    """
    if threading.current_thread() is threading.main_thread():
        for signum in (signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, _on_signal)


def signalled():
    """Whether a TERM or INT has arrived."""
    return bool(_signalled)


def temporary_directory(prefix, mode=None):
    """A new temporary directory, removed at exit if the suite has not removed it by then."""
    path = tempfile.mkdtemp(prefix=PROJECT_PREFIX + prefix)
    _directories.append(path)
    if mode is not None:
        os.chmod(path, mode)
    return path


def remove_directory(path):
    shutil.rmtree(path, ignore_errors=True)
    if path in _directories:
        _directories.remove(path)


def bridge_gateway():
    """The default bridge's gateway address: the address compose's `host-gateway` resolves to.

    A listener a container reaches binds it, so nothing beyond this
    machine and its containers reaches the listener. It is read before
    any container exists, since a container's environment names it.
    """
    gateway = run("docker", "network", "inspect", "bridge", "-f", "{{(index .IPAM.Config 0).Gateway}}").stdout.strip()
    if not gateway:
        sys.exit("FAIL: docker network inspect bridge names no gateway")
    return gateway


def guard_failed(inspected):
    """Whether `docker inspect`'s record of an egress guard says it never turned healthy and failed.

    Its health is not healthy, and its process exited 1 or Docker has
    restarted it. RestartCount is the record's own field beside State,
    not State's: a guard inspected between one exit and the next start
    reports State running and restarting with ExitCode 0, and only the
    count says it failed.
    """
    state = inspected["State"]
    return state.get("Health", {}).get("Status") != "healthy" and (state.get("ExitCode") == 1 or inspected["RestartCount"] >= 1)


# Docker's refusals of a call on a container whose main process is not running: the container is stopped, or it is
# between one exit of its main process and the next start.
NO_PROCESS_REFUSALS = ("is not running", "is restarting, wait until the container is running")


def listing(done, what):
    """The stdout of `done`, a docker call on a container made with check=False, read as what the container holds.

    A failed call answers nothing about the container's processes or its home
    root, so it fails the observation. The one exception is Docker's refusal
    of the call itself: a container whose main process is not running holds
    no process, and its home root, a tmpfs mount of each role, goes with it.
    The refusal is read from the call, since an inspection made afterwards
    may find the restart already over.
    """
    if done.returncode == 0:
        return done.stdout
    if any(refusal in done.stderr for refusal in NO_PROCESS_REFUSALS):
        return ""
    sys.exit(f"FAIL: {what} exited {done.returncode}\n{done.stderr.strip()}")


def read_word(done, words, what):
    """The word a probe printed in a successful exec, which must be one of `words`; anything else fails.

    A probe such as `test -e PATH && echo present || echo absent` answers in
    its output, so a failed exec is no answer whatever its status, and output
    of neither word is none either.
    """
    answer = done.stdout.strip()
    if done.returncode != 0 or answer not in words:
        sys.exit(f"FAIL: {what} answered {answer!r} with status {done.returncode}\n{done.stderr.strip()}")
    return answer


def read_output(done, what):
    """The stdout of a command that exits 0: a table or a listing is an answer only when its command ran to the end.

    Any other status, a failed docker exec's included, fails the observation.
    """
    if done.returncode != 0:
        sys.exit(f"FAIL: {what} exited {done.returncode}\n{done.stderr.strip()}")
    return done.stdout


def read_listing(done, what):
    """The rows of a listing in word form, from a command that exits 0: `present` and its rows, or `absent` alone.

    Absence is the word `absent` from a successful exec. A failed exec, and
    output that answers neither word, or `present` with no rows, are no answer.
    """
    lines = read_output(done, what).splitlines()
    if lines == ["absent"]:
        return []
    if lines and lines[0] == "present" and len(lines) > 1:
        return lines[1:]
    sys.exit(f"FAIL: {what} printed no listing in word form\n{done.stdout!r}")


def parse_counters(text, names, what):
    """The `name count` lines of a cgroup file, as a dict, with each of `names` among them.

    A counter that is not there is no answer, so it fails rather than being
    read as zero.
    """
    counters = {}
    for line in text.splitlines():
        fields = line.split()
        if len(fields) != 2 or not fields[1].isdigit():
            sys.exit(f"FAIL: {what} printed a line that is no counter: {line!r}")
        counters[fields[0]] = int(fields[1])
    missing = [name for name in names if name not in counters]
    if missing:
        sys.exit(f"FAIL: {what} holds no counter {missing}: {counters}")
    return counters


def read_counters(done, names, what):
    """The counters of a cgroup file from a command that exits 0 (parse_counters)."""
    return parse_counters(read_output(done, what), names, what)


def no_kills(events):
    """Whether a cgroup's events count no OOM and no OOM kill: both counters must be read, never defaulted."""
    return events["oom"] == 0 and events["oom_kill"] == 0


class Stack:
    """A compose project of the suite's own: its name, its project directory and its teardown.

    The project is named from `PROOF_RUN_PREFIX` and `project`; its
    directory is a new temporary directory holding an empty `.env`, which
    the stack's definition names, and the seccomp profiles under the names
    docker-compose.yml reads them by from the project directory, as a
    scaffolded project holds them. A subclass gives `compose` and `logs`.
    """

    def __init__(self, project):
        self.project = PROJECT_PREFIX + project
        self.project_dir = tempfile.mkdtemp(prefix=f"{self.project}-")
        _stacks.append(self)
        open(os.path.join(self.project_dir, ".env"), "w").close()
        for name, path in SECCOMP_PROFILES.items():
            shutil.copyfile(path, os.path.join(self.project_dir, name))

    def compose(self, *args, check=True):
        raise NotImplementedError

    def logs(self):
        raise NotImplementedError

    def down(self):
        """Removes the project, its volumes and its directory, whether or not the stack came up.

        `docker compose down` runs up to DOWN_ATTEMPTS times until it
        succeeds. The directory goes only after compose has succeeded, since
        compose reads the project's .env from it; until then the stack stays
        registered, so a down that fails or that a signal interrupts is run
        again at exit. A teardown that fails every attempt says so on stderr
        and fails the run: by SystemExit when nothing else is failing it,
        and by the exit status when it fails again at exit.
        """
        if os.environ.get("CI"):
            try:
                print(self.logs())
            except SystemExit as unread:
                # A failed read of the logs is reported here, and the teardown goes on.
                print(unread, file=sys.stderr, flush=True)
        stop = ["--timeout", str(SIGNALLED_STOP_S)] if signalled() else []
        for attempt in range(1, DOWN_ATTEMPTS + 1):
            result = self.compose("down", "--volumes", "--remove-orphans", *stop, check=False)
            if result.returncode == 0:
                shutil.rmtree(self.project_dir, ignore_errors=True)
                if self in _stacks:
                    _stacks.remove(self)
                return
            print(f"docker compose down of {self.project} exited {result.returncode} "
                  f"(attempt {attempt} of {DOWN_ATTEMPTS})\n{result.stdout}{result.stderr}", file=sys.stderr, flush=True)
            if attempt < DOWN_ATTEMPTS:
                time.sleep(DOWN_RETRY_S)
        message = (f"FAIL: docker compose down of {self.project} failed {DOWN_ATTEMPTS} times; "
                   "its containers, networks and volumes may be left behind")
        print(message, file=sys.stderr, flush=True)
        if not _exiting and sys.exc_info()[0] is None:
            sys.exit(message)


# What cyfr-locus says as it refuses its boot where it can make no cgroup
# group: a container started without `writable-cgroups=true`.
NO_GROUPS = "refusing to start: every role and spawn is held in a cgroup group of its own, and none can be made here"


def refused_unbounded(container, logs, timeout_s=60):
    """Waits until the container's keeper has refused its boot for want of a cgroup group, the container exited or
    restarting: answers its logs. Fails the suite past `timeout_s`, or where a spawn was ever started."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        text = logs()
        if NO_GROUPS in text:
            inspected = json.loads(run("docker", "inspect", container).stdout)[0]
            if inspected["RestartCount"] >= 1 or not inspected["State"]["Running"]:
                if re.search(r"spawn \S+: uid \d+", text):
                    sys.exit(f"FAIL: a spawn started where no bound can be made\n{text[-3000:]}")
                return text
        time.sleep(0.5)
    sys.exit(f"FAIL: cyfr-locus did not refuse its boot for want of a cgroup group within {timeout_s} s\n{logs()[-3000:]}")


def role_spec(role):
    """A role of the role table, as a harness reads it, as cyfr-locus's `--role` takes it:
    `<name>:<uid>:<port>:<pool>`, then `:private`, `:kept` and `:floor` where the role is each."""
    return (f"{role['name']}:{role['uid']}:{role['port']}:{role['pool']}"
            + (":private" if role["private"] else "") + (":kept" if role["kept_root"] else "")
            + (":floor" if role["floor"] else ""))


# Where a container's cgroup namespace is mounted, and the pool's tree the
# keeper makes in it (apps/locus/keeper/internal/cgroup): each role's leaf
# in service holds its process and its relays, and its spawns' groups lie in
# its group in work, the floor's role's beside rest and every other's in it.
CGROUP = "/sys/fs/cgroup"


def service_leaf(role):
    """The role's leaf: its process and its relays."""
    return f"{CGROUP}/service/{role['name']}"


def work_group(role):
    """The role's group in work, which holds its spawns' groups."""
    return f"{CGROUP}/work/{role['name']}" if role["floor"] else f"{CGROUP}/work/rest/{role['name']}"


def bound_group(role):
    """The group whose memory.max bounds the role's spawns together: work for the floor's role, rest for the rest."""
    return f"{CGROUP}/work" if role["floor"] else f"{CGROUP}/work/rest"


def role_mounts(release, role, home_size=None):
    """The tmpfs mounts a keeper serving `role` alone needs, as `docker run` arguments: the release's run
    directory, root's and 0711, the role's own run folder, its uid's and 0700, and its spawns' homes' root, 1733."""
    return ["--tmpfs", f"{release['run_dir']}:mode=0711,size={release['run_size']}",
            "--tmpfs", f"{role['run_dir']}:uid={role['uid']},gid={role['uid']},mode=0700,size={role['run_size']}",
            "--tmpfs", f"{role['home_root']}:mode=1733,exec,size={home_size or role['home_size']}"]


class Guard:
    """An egress guard of the suite's own, for a keeper a suite starts from the image by `docker run`: cyfr-locus
    requires one (`--guard`) to route each role process's space. The guard runs on a network of its own, healthy
    before `__init__` returns, and serves its control on a volume of its own; `keeper_args` puts a container in the
    guard's network namespace with the control mounted read-only, and `down` removes all three. The container is
    named only under PROOF_RUN_PREFIX (`run_name`) and known by its id; `runner` is the `run` its calls go through."""

    CONTROL_DIR = "/run/cyfr-guard-control"
    CONTROL = f"{CONTROL_DIR}/guard.sock"

    def __init__(self, image, name, env=(), extra=(), runner=None):
        self.run = runner or run
        self.name = PROJECT_PREFIX + name
        self.network = f"{self.name}-net"
        self.volume = f"{self.name}-control"
        self.id = None
        _guards.append(self)
        self.run("docker", "network", "create", self.network)
        self.run("docker", "volume", "create", self.volume)
        gateway = self.run("docker", "network", "inspect", self.network, "--format",
                           "{{(index .IPAM.Config 0).Gateway}}").stdout.strip()
        self.id = self.run(
            "docker", "run", "--detach", *run_name(self.name), "--init", "--cap-drop", "ALL", "--cap-add", "NET_ADMIN",
            "--security-opt", "no-new-privileges:true", "--read-only", "--ipc", "none",
            "--sysctl", "net.ipv4.ip_forward=1", "--sysctl", "net.ipv4.icmp_ratelimit=0",
            "--tmpfs", "/run/cyfr-guard:mode=0755,size=1m",
            "-e", f"CYFR_GUARD_CONTROL_PLANE={gateway}", "-e", "CYFR_PRIVATE_EGRESS_TARGETS=",
            "-e", f"CYFR_GUARD_CONTROL={self.CONTROL}", *[arg for pair in env for arg in ("-e", pair)],
            "-v", f"{self.volume}:{self.CONTROL_DIR}", "--network", self.network,
            "--health-cmd", "cyfr-guard check", "--health-interval", "1s", "--health-timeout", "3s",
            "--health-retries", "3", *extra, "--entrypoint", "cyfr-guard", image).stdout.strip()
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            health = self.run("docker", "inspect", "--format", "{{.State.Health.Status}}", self.id, check=False)
            if health.stdout.strip() == "healthy":
                return
            time.sleep(0.5)
        logs = self.run("docker", "logs", "--tail", "40", self.id, check=False)
        sys.exit(f"FAIL: the guard {self.name} was not healthy within 60 s\n{logs.stdout}{logs.stderr}")

    def keeper_args(self):
        return ["--network", f"container:{self.id}", "-v", f"{self.volume}:{self.CONTROL_DIR}:ro"]

    def down(self):
        if self.id:
            self.run("docker", "rm", "--force", self.id, check=False)
        self.run("docker", "network", "rm", self.network, check=False)
        self.run("docker", "volume", "rm", self.volume, check=False)
        if self in _guards:
            _guards.remove(self)


@atexit.register
def _leftovers():
    # A stack made before its `try` began, or one whose `down` a signal
    # interrupted, and a directory made before the `try` that removes it,
    # are removed here, however the suite ends short of os._exit. A first
    # signal arriving here interrupts one stack's teardown, which runs once
    # more: every later signal is ignored. A stack whose down still fails
    # fails the run's exit status: the suite cannot pass with a project left
    # behind.
    _exiting.append(True)
    failed = []
    for stack in reversed(list(_stacks)):
        for attempt in (1, 2):
            try:
                stack.down()
                break
            except (Exception, SystemExit) as error:
                if attempt == 2:
                    print(f"teardown of {stack.project} failed: {error!r}", file=sys.stderr)
        if stack in _stacks:
            failed.append(stack.project)
            _stacks.remove(stack)
            shutil.rmtree(stack.project_dir, ignore_errors=True)
    for guard in reversed(list(_guards)):
        guard.down()
    for path in list(_directories):
        remove_directory(path)
    if failed:
        print(f"FAIL: the teardown of {', '.join(failed)} failed; the run fails", file=sys.stderr, flush=True)
        sys.stdout.flush()
        os._exit(128 + _signalled[0] if _signalled else 1)

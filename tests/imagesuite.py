# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""What the image suites' three harnesses share.

tests/builder-image/stack.py, tests/locus-runtime-image/stack.py and
tests/locus-backends-image/harness.py each run one service of the Locus
image under docker compose. They share the command runner (`run`), the
teardown on a signal (`stop_on_signals`), the temporary directories
removed at exit (`temporary_directory`), the default bridge's gateway
(`bridge_gateway`), the reading of a guard's failure from its inspect
record (`guard_failed`), and the part of a compose stack that does not
depend on the service (`Stack`: its project name, its project directory
and `down`). What differs between them (compose files, services, the
seccomp copy, their logs) stays in each harness's own subclass.

Importing this module calls no Docker and binds nothing: the gate's static
step imports the runtime harness on every commit.
"""

import atexit
import os
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


def run_name(name):
    """`--name NAME` for a one-off container a suite starts, under
    PROOF_RUN_PREFIX (NAME carries PROJECT_PREFIX, or a stack's project),
    or no argument without it, so the container runs unnamed as CI runs
    it."""
    return ["--name", name] if PROJECT_PREFIX else []

# How long `docker compose down` gives each container to stop once the
# suite was signalled. heavy-check sends TERM at its hold deadline and KILL
# its grace later (30 s by default); a down that waited out a service's own
# stop_grace_period (40 s for locus-runtime and locus-backends) would be
# killed midway and leave the project behind.
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


class Stack:
    """A compose project of the suite's own: its name, its project directory and its teardown.

    The project is named from `PROOF_RUN_PREFIX` and `project`; its
    directory is a new temporary directory holding an empty `.env`, which
    the stack's definition names. A subclass gives `compose` and `logs`.
    """

    def __init__(self, project):
        self.project = PROJECT_PREFIX + project
        self.project_dir = tempfile.mkdtemp(prefix=f"{self.project}-")
        _stacks.append(self)
        open(os.path.join(self.project_dir, ".env"), "w").close()

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
            print(self.logs())
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
    for path in list(_directories):
        remove_directory(path)
    if failed:
        print(f"FAIL: the teardown of {', '.join(failed)} failed; the run fails", file=sys.stderr, flush=True)
        sys.stdout.flush()
        os._exit(128 + _signalled[0] if _signalled else 1)

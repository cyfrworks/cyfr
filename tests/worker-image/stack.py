# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The opus service under docker compose, for the worker image tests.

A Stack runs docker-compose.yml's `opus` service layered with
compose.worker.yml, which adds only the image under test, a loopback port,
the host gateway the scripted control plane (control_plane.py, on this
machine) is reached through and the pool settings a test chooses.
Everything else — cyfr-spawn's capabilities, the read-only root,
`ipc: none`, the tmpfs mounts, the limits, the restart policy — is the
shipped service. What the container's processes, home root and CPU
accounting show is read as root inside it.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SERVICE = "wrk_image"
POOL_FIRST, POOL_LAST = 30101, 30108
SERVICE_UID = 10002
HOME_ROOT = "/var/lib/opus/homes"
SPAWNER_CAPS = "00000000000000e0"


def run(*args, check=True, env=None, timeout=None):
    result = subprocess.run(args, capture_output=True, text=True, env=env, timeout=timeout)
    if check and result.returncode != 0:
        sys.exit(f"FAIL: {' '.join(args)} exited {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


def expect(condition, message, detail=None):
    if not condition:
        text = detail if isinstance(detail, str) else json.dumps(detail, indent=2, default=str)
        sys.exit(f"FAIL: {message}\n{(text or '')[:8000]}")
    print(f"ok: {message}", flush=True)


def wait_until(predicate, timeout, what, interval=0.05):
    """The first truthy value of `predicate` within `timeout` seconds, or a failure naming `what`."""
    deadline = time.monotonic() + timeout
    while True:
        value = predicate()
        if value:
            return value
        if time.monotonic() > deadline:
            sys.exit(f"FAIL: timed out after {timeout}s waiting for {what}")
        time.sleep(interval)


class Stack:
    def __init__(self, project, image, plane, pool_size=2, idle_ttl_ms=30_000, watchdog_grace_ms=1_000, release_grace_ms=1_500):
        self.project = project
        self.image = image
        self.plane = plane
        self.pool_size = pool_size
        self.idle_ttl_ms = idle_ttl_ms
        self.watchdog_grace_ms = watchdog_grace_ms
        self.release_grace_ms = release_grace_ms
        self.project_dir = tempfile.mkdtemp(prefix=f"{project}-")
        # The rest of the stack's definition names a project .env.
        open(os.path.join(self.project_dir, ".env"), "w").close()
        self.container = None
        self.base = None
        self.boot = None

    def env(self):
        return {
            **os.environ,
            "OPUS_IMAGE": self.image,
            "OPUS_SERVICE_ID": SERVICE,
            "OPUS_SERVICE_KEY": self.plane.worker_key.hex(),
            "OPUS_HOST_URL": self.plane.container_url,
            "OPUS_POOL_SIZE": str(self.pool_size),
            "OPUS_IDLE_TTL_MS": str(self.idle_ttl_ms),
            "OPUS_WATCHDOG_GRACE_MS": str(self.watchdog_grace_ms),
            "OPUS_RELEASE_GRACE_MS": str(self.release_grace_ms),
        }

    def compose(self, *args, check=True):
        return run(
            "docker", "compose", "--project-name", self.project, "--project-directory", self.project_dir,
            "-f", os.path.join(ROOT, "docker-compose.yml"),
            "-f", os.path.join(HERE, "compose.worker.yml"),
            *args,
            env=self.env(), check=check,
        )

    def up(self):
        """(Re)creates the service, waits for its listener and for its pool to fill."""
        self.compose("up", "--detach", "--no-build", "--force-recreate", "opus")
        self.container = self.compose("ps", "--quiet", "opus").stdout.strip()
        self.wait_listener()
        self.wait_pool()

    def wait_listener(self, timeout=90):
        """The listener answers an unsigned status 401 (the image's liveness), then a signed one 200."""
        address = self.compose("port", "opus", "4200").stdout.strip().splitlines()[0]
        self.base = f"http://{address}"
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                urllib.request.urlopen(urllib.request.Request(f"{self.base}/worker/v1/status", data=b"{}", method="POST"), timeout=2)
            except urllib.error.HTTPError as error:
                if error.code == 401:
                    code, answer = self.status()
                    if code == 200:
                        self.boot = answer["ok"]["boot"]
                        return answer["ok"]
            except (OSError, ValueError):
                pass
            time.sleep(0.5)
        sys.exit("FAIL: the opus service never answered its status\n" + self.logs())

    def wait_pool(self, timeout=90):
        """Every fresh runner of the pool is up: a runner is a VM booting from nothing."""
        return wait_until(
            lambda: (lambda r: r if r and r["fresh"] >= self.pool_size else None)(self.runners()),
            timeout, f"the pool to hold {self.pool_size} fresh runners", interval=0.25,
        )

    def logs(self):
        return self.compose("logs", "--no-color", "opus", check=False).stdout

    def down(self):
        if os.environ.get("CI"):
            print(self.logs())
        self.compose("down", "--volumes", "--remove-orphans", check=False)
        shutil.rmtree(self.project_dir, ignore_errors=True)

    # ------------------------------------------------------------------
    # The service's requests
    # ------------------------------------------------------------------

    def status(self):
        return self.plane.status(self.base)

    def runners(self):
        code, answer = self.status()
        return answer["ok"]["runners"] if code == 200 else None

    def attempts(self):
        code, answer = self.status()
        return answer["ok"]["attempts"] if code == 200 else None

    def start(self, attempt):
        return self.plane.start(self.base, attempt)

    def kill(self, execution_id):
        return self.plane.kill(self.base, execution_id)

    # ------------------------------------------------------------------
    # Inside the container
    # ------------------------------------------------------------------

    def exec(self, script, user=None):
        user_args = ["-u", user] if user else []
        return run("docker", "exec", *user_args, self.container, "sh", "-c", script, check=False)

    def processes(self):
        """Every process in the container as pid, uids, effective capabilities and command line."""
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

    def runner_processes(self):
        """The runner VMs: each pooled uid's beam.smp with the runner id and home its environment names.

        Another uid's environ is readable only by that uid (or with
        CAP_SYS_PTRACE, which the container lacks), so it is read as the
        runner's own uid through setpriv, which root's SETUID and SETGID
        allow."""
        script = r"""
          for d in /proc/[0-9]*; do
            s="$(cat "$d/status" 2>/dev/null)" || continue
            uid="$(printf '%s\n' "$s" | awk '/^Uid:/ {print $2}')"
            [ "$uid" -ge FIRST ] && [ "$uid" -le LAST ] || continue
            tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -q 'beam.smp' || continue
            env="$(setpriv --reuid="$uid" --regid="$uid" --clear-groups sh -c "tr '\\0' '\\n' < $d/environ" 2>/dev/null)"
            runner="$(printf '%s\n' "$env" | sed -n 's/^OPUS_RUNNER_ID=//p')"
            home="$(printf '%s\n' "$env" | sed -n 's/^HOME=//p')"
            printf '%s|%s|%s|%s\n' "${d#/proc/}" "$uid" "$runner" "$home"
          done""".replace("FIRST", str(POOL_FIRST)).replace("LAST", str(POOL_LAST))
        out = []
        for line in self.exec(script).stdout.splitlines():
            pid, uid, runner, home = line.split("|", 3)
            out.append({"pid": int(pid), "uid": int(uid), "runner": runner, "home": home})
        return out

    def runner_process(self, runner_id):
        return next((p for p in self.runner_processes() if p["runner"] == runner_id), None)

    def uid_processes(self, uid):
        return [p for p in self.processes() if uid in p["uids"]]

    def service_beam_pid(self):
        return next((p["pid"] for p in self.processes() if p["uids"][0] == SERVICE_UID and "beam.smp" in p["cmd"]), None)

    def homes(self):
        """The entries of the home root, read as root inside the container."""
        return self.exec(f"ls -A {HOME_ROOT}").stdout.split()

    def cpu_usec(self):
        """The container's CPU time from its cgroup, in microseconds."""
        out = self.exec("awk '/^usage_usec/ {print $2}' /sys/fs/cgroup/cpu.stat").stdout.strip()
        return int(out)

    def cpu_share(self, window_s):
        """The container's CPU use over `window_s` seconds as a share of one CPU."""
        before = self.cpu_usec()
        t0 = time.monotonic()
        time.sleep(window_s)
        after = self.cpu_usec()
        return (after - before) / 1_000_000 / (time.monotonic() - t0)

    def container_state(self):
        raw = run("docker", "inspect", "--format", "{{json .State}}", self.container).stdout
        state = json.loads(raw)
        restarts = json.loads(run("docker", "inspect", "--format", "{{.RestartCount}}", self.container).stdout)
        return {"running": state["Running"], "status": state["Status"], "started_at": state["StartedAt"], "restarts": restarts}


class StatusSampler:
    """Polls the service's status from a thread of its own, keeping every sample."""

    def __init__(self, stack, interval=0.025):
        import threading

        self.stack = stack
        self.interval = interval
        self.samples = []
        self.stopping = threading.Event()
        self.thread = threading.Thread(target=self.poll, daemon=True)

    def start(self):
        self.thread.start()
        return self

    def poll(self):
        while not self.stopping.is_set():
            code, answer = self.stack.status()
            if code == 200:
                self.samples.append((time.monotonic(), answer["ok"]["runners"], answer["ok"]["attempts"]))
            self.stopping.wait(self.interval)

    def stop(self):
        self.stopping.set()
        self.thread.join(5)
        return self.samples

    def max_of(self, state):
        return max((s[1][state] for s in self.samples), default=0)

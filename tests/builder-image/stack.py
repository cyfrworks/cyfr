# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The builder service under docker compose, for the builder image tests.

A Stack runs docker-compose.yml's `builder` service (profile `builder`)
layered with compose.builder.yml, which adds only the image under test, a
loopback port, the residue canary and the pool's uid range. Everything
else — capabilities, read-only root, `ipc: none`, tmpfs mounts, limits —
is the shipped service.
"""

import base64
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
TOKEN = "builder-image-test"
POOL_FIRST, POOL_LAST = 30001, 30016
RELEASE_UID = 10001
HOME_ROOT = "/var/lib/cyfr-builder/homes"


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


def build_canary():
    """Builds tests/fixtures/residue-canary.go for Linux on this host's architecture."""
    out = tempfile.mkdtemp(prefix="cyfr-canary-")
    run(
        "docker", "run", "--rm",
        "-v", f"{os.path.join(ROOT, 'tests', 'fixtures')}:/src:ro", "-v", f"{out}:/out",
        "-e", "CGO_ENABLED=0", "-e", "GOCACHE=/tmp/go-cache", "-e", "GOFLAGS=-buildvcs=false",
        "-w", "/src", "golang:1.26.5-alpine", "go", "build", "-o", "/out/canary", "residue-canary.go",
    )
    return out


class Stack:
    def __init__(self, project, image, canary_dir):
        self.project = project
        self.image = image
        self.canary_dir = canary_dir
        self.project_dir = tempfile.mkdtemp(prefix=f"{project}-")
        # The rest of the stack's definition names a project .env.
        open(os.path.join(self.project_dir, ".env"), "w").close()
        self.base = None

    def env(self):
        return {
            **os.environ,
            "BUILDER_IMAGE": self.image,
            "CANARY_DIR": self.canary_dir,
            "CYFR_BUILDER_TOKEN": TOKEN,
            "BUILD_POOL": self.pool,
        }

    pool = f"{POOL_FIRST}-{POOL_LAST}"

    def compose(self, *args, check=True):
        return run(
            "docker", "compose", "--project-name", self.project, "--project-directory", self.project_dir,
            "-f", os.path.join(ROOT, "docker-compose.yml"),
            "-f", os.path.join(HERE, "compose.builder.yml"),
            "--profile", "builder", *args,
            env=self.env(), check=check,
        )

    def up(self, pool=f"{POOL_FIRST}-{POOL_LAST}"):
        """(Re)creates the builder with this pool and waits for /health."""
        self.pool = pool
        self.compose("up", "--detach", "--no-build", "--force-recreate", "builder")
        self.container = self.compose("ps", "--quiet", "builder").stdout.strip()
        address = self.compose("port", "builder", "4100").stdout.strip().splitlines()[0]
        self.base = f"http://{address}"
        for _ in range(90):
            try:
                with urllib.request.urlopen(f"{self.base}/health", timeout=2) as response:
                    self.health = json.loads(response.read())
                    return
            except (OSError, ValueError):
                time.sleep(1)
        sys.exit("FAIL: the builder never answered /health\n" + self.logs())

    def logs(self):
        return self.compose("logs", "--no-color", "builder", check=False).stdout

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

    def build(self, sources, language, target_type, resolve=False):
        body = json.dumps({
            "source_files": {path: base64.b64encode(text.encode()).decode() for path, text in sources.items()},
            "language": language,
            "target_type": target_type,
            "resolve": resolve,
        }).encode()
        request = urllib.request.Request(
            f"{self.base}/build", data=body, method="POST",
            headers={"authorization": f"Bearer {TOKEN}", "content-type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=900) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())


def tincture(build_script, files=None):
    """A tincture whose `npm run build` runs build.sh, which must fill dist/."""
    sources = {
        "package.json": json.dumps({"name": "image-test", "private": True, "version": "0.0.1", "scripts": {"build": "sh build.sh"}}),
        "build.sh": build_script,
    }
    sources.update(files or {})
    return sources


def output_file(answer, name):
    encoded = (answer.get("output_files") or {}).get(name)
    return base64.b64decode(encoded).decode() if encoded is not None else None

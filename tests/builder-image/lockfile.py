#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""A tincture builds only from its lockfile, and its install scripts get no credential.

Run against docker-compose.yml's locus-builds service, as the other builder
image suites are:

- A tincture whose package.json ships without its package-lock.json is
  refused as `malformed`, naming the lockfile, before anything runs: the
  answer carries no build log.
- A lockfile out of step with its package.json is refused by `npm ci`,
  which installs exactly what the lockfile pins and never resolves afresh:
  the build fails with npm's own account of it.
- An install script runs — `npm ci` runs the package's lifecycle scripts —
  under the build's pooled uid, in its own home, and finds no credential to
  take: not the service's builds key, nor any variable named for a key, a
  token, a secret or a password, nor an npm registry credential in npm's
  configuration or the home's `.npmrc`. The service's own environment,
  which holds LOCUS_BUILDS_KEY, is out of its reach.

Usage: tests/builder-image/lockfile.py IMAGE
"""

import json
import os
import re
import shutil
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from stack import HOME_ROOT, POOL_FIRST, POOL_LAST, Stack, brief, build_canary, diagnostics, expect, output_file  # noqa: E402

NAME = "lockfile-test"

# What an install script looks for, written where the build copies it into
# dist/: the environment, npm's view of its configuration, the home's own
# .npmrc, and whether the service's environment is readable.
PROBE = r"""
{
  echo "== env"
  env
  echo "== npm config"
  npm config list --json 2>&1 || true
  echo "== npmrc"
  cat "$HOME/.npmrc" 2>&1 || true
  echo "== service environ"
  for pid in $(ls /proc | grep -E '^[0-9]+$'); do
    cat "/proc/$pid/environ" 2>/dev/null | tr '\0' '\n' | grep -E '^LOCUS_BUILDS_KEY=' || true
  done
} > install-probe.txt 2>&1
"""


def package(scripts, dependencies=None):
    fields = {"name": NAME, "version": "0.0.1", "private": True, "scripts": scripts}
    if dependencies:
        fields["dependencies"] = dependencies
    return json.dumps(fields)


def lockfile(dependencies=None):
    """The lockfile npm writes for this package with `dependencies`, none of them installed."""
    root = {"name": NAME, "version": "0.0.1"}
    if dependencies:
        root["dependencies"] = dependencies
    return json.dumps({"name": NAME, "version": "0.0.1", "lockfileVersion": 3, "requires": True, "packages": {"": root}})


BUILD = "mkdir -p dist && cp install-probe.txt dist/install-probe.txt && echo built > dist/index.html"


def test_missing_lockfile(stack):
    sources = {"package.json": package({"postinstall": "touch ran", "build": BUILD}), "probe.sh": PROBE}
    status, answer = stack.build(sources, "javascript", "tincture")
    expect(status == 400 and answer.get("type") == "refusal" and answer.get("class") == "malformed",
           "a tincture without its lockfile is refused as malformed", brief(answer))
    expect("package-lock.json" in answer.get("reason", "") and "only from its lockfile" in answer.get("reason", ""),
           "the refusal names the lockfile", brief(answer))
    expect(not diagnostics(answer), "nothing ran: the refusal carries no build log", brief(answer))


def test_lockfile_out_of_step(stack):
    dependencies = {"left-pad": "^1.3.0"}
    sources = {
        "package.json": package({"build": BUILD}, dependencies),
        # The lockfile pins nothing the manifest asks for.
        "package-lock.json": lockfile(),
    }
    status, answer = stack.build(sources, "javascript", "tincture")
    expect(status == 422 and answer.get("class") == "failed",
           "a lockfile out of step with its package.json fails the build", brief(answer))
    log = diagnostics(answer)
    expect("npm ci" in log or "in sync" in log, "npm ci says why, and resolves nothing afresh", brief(answer))


def test_install_script_finds_no_credential(stack):
    sources = {
        "package.json": package({"postinstall": "sh probe.sh", "build": BUILD}),
        "package-lock.json": lockfile(),
        "probe.sh": PROBE,
    }
    status, answer = stack.build(sources, "javascript", "tincture")
    expect(status == 200, "a tincture with its lockfile builds, its install script run", brief(answer))

    probe = output_file(answer, "install-probe.txt") or ""
    expect("== env" in probe and "== npm config" in probe, "the install script ran and reported", probe)

    env = probe.split("== env", 1)[1].split("== npm config", 1)[0]
    names = [line.split("=", 1)[0] for line in env.splitlines() if "=" in line]
    home = next((line.split("=", 1)[1] for line in env.splitlines() if line.startswith("HOME=")), "")
    expect(home.startswith(HOME_ROOT + "/"), "it runs in the build's own home", env)

    expect(stack.key not in probe, "the service's builds key is nowhere the install script can look", probe)
    credential_names = [name for name in names if re.search(r"KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|AUTH", name, re.I)]
    expect(credential_names == [], "no variable of its environment is named for a credential", credential_names)

    config = probe.split("== npm config", 1)[1].split("== npmrc", 1)[0]
    expect("_authToken" not in config and '"_auth"' not in config and "_password" not in config,
           "npm's configuration holds no registry credential", config)

    npmrc = probe.split("== npmrc", 1)[1].split("== service environ", 1)[0]
    expect("_auth" not in npmrc, "the build's home holds no .npmrc credential", npmrc)

    environ = probe.split("== service environ", 1)[1]
    expect("LOCUS_BUILDS_KEY=" not in environ, "the service's own environment is out of the build's reach", environ)


def main(image):
    canary = build_canary()
    stack = Stack("locus-builds-lockfile", image, canary)
    try:
        stack.up(pool=f"{POOL_FIRST}-{POOL_LAST}")
        test_missing_lockfile(stack)
        test_lockfile_out_of_step(stack)
        test_install_script_finds_no_credential(stack)
    finally:
        stack.down()
        shutil.rmtree(canary, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])

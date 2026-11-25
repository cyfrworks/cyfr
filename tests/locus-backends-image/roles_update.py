#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""A kept home the three-container image made is the one Locus's own after the update.

A proof of the update from the three-container image, run by hand and not
by CI, its result recorded in the pull request. A kept home is made by the
three-container image's backends service (OLD_IMAGE, its compose file and
overlay from OLD_TREE) on the project's `homes` volume, a probe program
writing a file in it; that project is taken down, its volume kept; then the
one Locus (IMAGE, as roles.py starts it, all three keys) runs on the same
volume, and:

- the home opens under it with its file under its own uid, is listed, and
  is reset under that uid, opening again under it;
- after the backends role is killed and starts again alone, and after the
  container restarts, it opens so again;
- a new home draws a kept uid, never the home of before's.

It serves nothing on the host's port 4000 (every port is published on a
loopback port of Docker's choosing) and reaches no cyfr.run: the runtime's
host API is a control plane on this machine, and no program fetches
anything.

Prerequisites: harness.py's, a checkout of the three-container stack (a
worktree at the commit before the one Locus, named by OLD_TREE) and its
Locus image, built there (`scripts/image.sh locus`). Usage:

    OLD_TREE=/path/to/old/checkout tests/locus-backends-image/roles_update.py IMAGE OLD_IMAGE
"""

import json
import os
import secrets
import shutil
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from harness import (  # noqa: E402
    KEPT_FIRST, KEPT_LAST, KEPT_ROOT, POOL_FIRST, POOL_LAST, ROOT, VERSION, Controller, expect, probe, require_docker,
    run, wait_healthy,
)
from kept_home import sh, whoami  # noqa: E402
from roles import OWNER, SERVICE_ID, RolesStack, plane_module, serving, test_restart_alone  # noqa: E402

HOME = "mcp_roles-kept"


def old_home(stack, old_image, old_root):
    """A kept home the three-container image makes: its backends service on the project's `homes` volume, a probe
    program writing a file in its home. Answers the home's uid; the project is then taken down, the volume kept."""
    old = [os.path.join(old_root, "docker-compose.yml"),
           os.path.join(old_root, "tests", "locus-backends-image", "compose.locus-backends.yml")]
    env = stack.env(BACKENDS_IMAGE=old_image, PROBE_DIR=os.path.join(old_root, "tests", "locus-backends-image"))
    # The backends role as the three-container stack names it, from that stack's own role table.
    with open(os.path.join(old_root, "tests", "fixtures", "locus_roles.json"), encoding="utf-8") as table:
        then = next(role for role in json.load(table)["roles"] if role["name"] == "backends")

    def compose(*args, check=True):
        return run("docker", "compose", "--project-name", stack.project, "--project-directory", stack.project_dir,
                   *[arg for file in old for arg in ("-f", file)], *args, env=env, check=check)

    try:
        compose("up", "--detach", "--no-build", "--force-recreate", then["service"])
        guard = compose("ps", "--quiet", then["guard"]).stdout.strip()
        address = run("docker", "port", guard, str(then["port"])).stdout.strip().splitlines()[0]
        base = f"http://{address}"
        wait_healthy(base)
        c = Controller(base, stack.key)
        expect(c.hello()[0] == 200, "the three-container image's backends service is greeted")
        status, answer, _ = c.sync(OWNER, [probe(home="kept")])
        expect(status == 200, "under the three-container image an owner of a kept program is synced", answer)
        made = whoami(c, OWNER, home_id=HOME)
        sh(c, OWNER, 'echo made-before > "$HOME/before.txt"', home_id=HOME)
        expect(KEPT_FIRST <= made["uid"] <= KEPT_LAST and made["home"] == f"{KEPT_ROOT}/{HOME}",
               "the three-container image makes a kept home with a file, under a kept uid", made)
        c.close(OWNER, c.mcp(OWNER, "probe", home_id=HOME).session)
        return made["uid"]
    finally:
        compose("down", "--remove-orphans", check=False)


def opens_as_before(c, uid, what):
    seen = whoami(c, OWNER, home_id=HOME)
    read = sh(c, OWNER, 'cat "$HOME/before.txt"; stat -c %u "$HOME/before.txt"', home_id=HOME)
    expect(seen["uid"] == uid and seen["home"] == f"{KEPT_ROOT}/{HOME}" and read["stdout"] == f"made-before\n{uid}\n",
           f"{what}: the home the three-container image made opens with its file under its own uid {uid}",
           [seen, read])
    c.close(OWNER, c.mcp(OWNER, "probe", home_id=HOME).session)


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: roles_update.py IMAGE OLD_IMAGE")
    image, old_image = sys.argv[1:]
    require_docker()
    old_root = os.environ.get("OLD_TREE")
    expect(old_root and os.path.isfile(os.path.join(old_root, "tests", "locus-backends-image", "compose.locus-backends.yml")),
           "OLD_TREE names a checkout of the three-container stack", old_root)
    plane = plane_module.ControlPlane(secrets.token_bytes(32), SERVICE_ID).serve()
    stack = RolesStack("locus-roles-update", image, plane)
    seccomp = os.path.join(stack.project_dir, "keeper.seccomp.json")
    shutil.copyfile(os.path.join(old_root, "apps", "locus", "keeper", "seccomp", "keeper.json"), seccomp)
    try:
        uid = old_home(stack, old_image, old_root)
        shutil.copyfile(os.path.join(ROOT, "apps", "locus", "keeper", "seccomp", "keeper.json"), seccomp)
        c = serving(stack)

        opens_as_before(c, uid, "under the one container")
        status, listed, _ = c.control({"type": "homes"})
        expect(status == 200 and HOME in listed["homes"], "the home of before is listed", listed)
        status, reset, _ = c.home(OWNER["athanor"], HOME, "reset")
        expect((status, reset) == (200, {"version": VERSION, "home_id": HOME, "state": "empty"}),
               "the home of before is reset", reset)
        empty = whoami(c, OWNER, home_id=HOME)
        expect(empty["uid"] == uid, "after its reset the home opens under its own uid again", empty)
        sh(c, OWNER, 'echo made-before > "$HOME/before.txt"', home_id=HOME)
        c.close(OWNER, c.mcp(OWNER, "probe", home_id=HOME).session)

        test_restart_alone(stack, c, "backends")
        c = stack.controller()
        expect(c.hello()[0] == 200, "the backends role started again is greeted")
        status, answer, _ = c.sync(OWNER, [probe("scratch"), probe(home="kept")])
        expect(status == 200, "the owner is synced again", answer)
        opens_as_before(c, uid, "after the backends role restarts")

        run("docker", "restart", stack.container)
        stack.published()
        stack.healthy()
        c = stack.controller()
        expect(c.hello()[0] == 200, "the container started again is greeted")
        status, answer, _ = c.sync(OWNER, [probe("scratch"), probe(home="kept")])
        expect(status == 200, "the owner is synced after the container restarts", answer)
        opens_as_before(c, uid, "after the container restarts")

        fresh = whoami(c, OWNER, home_id="mcp_roles-fresh")
        expect(KEPT_FIRST <= fresh["uid"] <= KEPT_LAST and fresh["uid"] != uid
               and not POOL_FIRST <= fresh["uid"] <= POOL_LAST,
               f"a new home draws a kept uid, never the home of before's {uid}", fresh)
    finally:
        stack.down()
        plane.stop()


if __name__ == "__main__":
    main()

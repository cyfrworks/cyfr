#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""A kept home the three-container image made is left as it was by the update, and its program signs in again.

A proof of the update from the three-container image, run by hand and not
by CI, its result recorded in the pull request. A kept home is made by the
three-container image's backends service (OLD_IMAGE, its compose file and
overlay from OLD_TREE) on the project's `homes` volume, a probe program
writing a file in it; that project is taken down, its volume kept; then the
one Locus (IMAGE, as roles.py starts it, all three keys) runs on the same
volume, and:

- the program's row opens in a new home on its person's disk, empty of the
  file before (the program signs in again: nothing is carried over), under
  a kept uid that is not the home of before's, and is listed;
- the home of before stays on the volume, its file and its owner as they
  were, and no listing names it;
- after the backends role is killed and starts again alone, and after the
  container restarts, the row opens on its disk so again, what it wrote
  there kept, and the folder of before is still untouched;
- a new person's disk draws a kept uid, never the home of before's.

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
    KEPT_FIRST, KEPT_LAST, KEPT_ROOT, POOL_FIRST, POOL_LAST, ROOT, Controller, expect, home_of, owner_of, probe,
    require_docker, run, wait_healthy,
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


def opens_on_the_disk(c, stack, uid, what, holds):
    """The row opens on its person's disk, under the disk's uid, never the home of before's, holding `holds`; the
    folder of before is as it was. Answers the disk's uid."""
    seen = whoami(c, OWNER, home_id=HOME)
    read = sh(c, OWNER, 'cat "$HOME/before.txt" 2>/dev/null; cat "$HOME/after.txt" 2>/dev/null; true', home_id=HOME)
    expect(KEPT_FIRST <= seen["uid"] <= KEPT_LAST and seen["uid"] != uid and seen["home"] == home_of(OWNER, HOME)
           and read["stdout"] == holds,
           f"{what}: the row opens on its person's disk under a uid not the home of before's {uid}", [seen, read])
    before = stack.observe(f'stat -c %u {KEPT_ROOT}/{HOME} && cat {KEPT_ROOT}/{HOME}/before.txt')
    expect(before.stdout == f"{uid}\nmade-before\n",
           f"{what}: the home of before stays on the volume, its file and owner as they were", before.stdout + before.stderr)
    c.close(OWNER, c.mcp(OWNER, "probe", home_id=HOME).session)
    return seen["uid"]


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

        disk_uid = opens_on_the_disk(c, stack, uid, "under the one container", "")
        status, listed, _ = c.control({"type": "homes"})
        expect(status == 200 and listed["homes"].count(HOME) == 1, "the row's home on its disk is listed once", listed)
        sh(c, OWNER, 'echo made-after > "$HOME/after.txt"', home_id=HOME)
        c.close(OWNER, c.mcp(OWNER, "probe", home_id=HOME).session)

        test_restart_alone(stack, c, "backends")
        c = stack.controller()
        expect(c.hello()[0] == 200, "the backends role started again is greeted")
        status, answer, _ = c.sync(OWNER, [probe("scratch"), probe(home="kept")])
        expect(status == 200, "the owner is synced again", answer)
        expect(opens_on_the_disk(c, stack, uid, "after the backends role restarts", "made-after\n") == disk_uid,
               "the row's disk keeps its uid after the backends role restarts")

        run("docker", "restart", stack.container)
        stack.published()
        stack.healthy()
        c = stack.controller()
        expect(c.hello()[0] == 200, "the container started again is greeted")
        status, answer, _ = c.sync(OWNER, [probe("scratch"), probe(home="kept")])
        expect(status == 200, "the owner is synced after the container restarts", answer)
        expect(opens_on_the_disk(c, stack, uid, "after the container restarts", "made-after\n") == disk_uid,
               "the row's disk keeps its uid after the container restarts")

        stranger = owner_of("roles-fresh")
        status, answer, _ = c.sync(stranger, [probe(home="kept")])
        expect(status == 200, "a new person is synced", answer)
        fresh = whoami(c, stranger, home_id="mcp_roles-fresh")
        expect(KEPT_FIRST <= fresh["uid"] <= KEPT_LAST and fresh["uid"] not in (uid, disk_uid)
               and not POOL_FIRST <= fresh["uid"] <= POOL_LAST,
               f"a new person's disk draws a kept uid, never the home of before's {uid}", fresh)
    finally:
        stack.down()
        plane.stop()


if __name__ == "__main__":
    main()

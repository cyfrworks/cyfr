#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Builds the proof game in the Locus builds image, as a tincture build runs.

The builds service is docker-compose.yml's locus-builds service under
tests/builder-image/stack.py, and the request is the build wire's
(`Prima.BuilderProtocol`): the game's source files, the lockfile among them,
as a JavaScript tincture. The service runs `npm ci` and `npm run build` under
a pooled uid and answers dist/'s files; this writes the version the proof
publishes — the game's source tree with the answered dist/ beside it — into
OUT_DIR.

Usage: tests/tincture-proof/build.py IMAGE OUT_DIR
"""

import os
import shutil
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "builder-image"))

from stack import Stack, brief, build_canary, diagnostics, expect, output_bytes  # noqa: E402

GAME = os.path.join(HERE, "game")


def sources():
    files = {}
    for directory, _dirs, names in os.walk(GAME):
        for name in names:
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, GAME)
            if relative.startswith(("node_modules" + os.sep, "dist" + os.sep)):
                continue
            with open(path, encoding="utf-8") as handle:
                files[relative] = handle.read()
    return files


def main(image, out_dir):
    files = sources()
    expect("package-lock.json" in files, "the game ships its lockfile beside package.json", sorted(files))
    canary = build_canary()
    stack = Stack("locus-builds-tincture-proof", image, canary)
    try:
        stack.up()
        status, answer = stack.build(files, "javascript", "tincture")
        expect(status == 200, "the game builds from its lockfile in the builds image", brief(answer))
        outputs = {output["path"]: output_bytes(answer, output["path"]) for output in answer["outputs"]}
        expect("index.html" in outputs and any(p.startswith("assets/") and p.endswith(".js") for p in outputs),
               "the build answers the entry and its bundle", sorted(outputs))
        expect("sound.wav" in outputs, "the build answers the game's one sound", sorted(outputs))
        expect("third-party-notices.json" in outputs, "the bundle keeps its third-party notices", sorted(outputs))
    finally:
        stack.down()
        shutil.rmtree(canary, ignore_errors=True)

    shutil.rmtree(out_dir, ignore_errors=True)
    for relative, text in files.items():
        path = os.path.join(out_dir, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
    for relative, data in outputs.items():
        path = os.path.join(out_dir, "dist", relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(data)
    print(f"ok: the built version is in {out_dir} ({len(outputs)} files in dist/)")
    print("\n".join(diagnostics(answer).splitlines()[-12:]))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Smoke-test a builder image as docker-compose.yml's builder service.

Starts the image with the builder service's own settings (the `builder`
profile of docker-compose.yml, layered with
tests/builder-image/compose.builder.yml for the image and a loopback
port), then drives its /build endpoint through a component's life: a Rust
build that resolves its Cargo.lock, a dependency added without
re-resolving (refused by `--locked`), a re-resolve, a locked rebuild, a
compiler error that reports its diagnostics, and a tincture build through
npm and Vite. Finally no process of a build uid may be left running and
no build home may remain.

Usage: scripts/builder-smoke.py IMAGE
"""

import os
import shutil
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests", "builder-image"))

from stack import Stack, expect  # noqa: E402

LIB_RS = """#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::reagent::compute::Guest;

struct Smoke;
bindings::export!(Smoke with_types_in bindings);

impl Guest for Smoke {
    fn compute(input: String) -> String {
        input
    }
}
"""

TINCTURE = {
    "package.json": """{"name": "smoke-tincture", "private": true, "version": "0.0.1", "type": "module",
 "scripts": {"build": "vite build"}, "devDependencies": {"vite": "^6.0.0"}}""",
    "index.html": '<!doctype html><html><body><div id="app"></div>'
    '<script type="module" src="/src/main.js"></script></body></html>\n',
    "src/main.js": 'document.getElementById("app").textContent = "smoke";\n',
}


def cargo_toml(stack):
    """The release's own reagent manifest, printed between markers: eval can print runtime warnings."""
    result = stack.exec(
        """/app/bin/builder eval 'IO.puts("<<<" <> Locus.Builder.cargo_toml_for(:reagent) <> ">>>")'""",
        user="cyfr-builder",
    )
    out = result.stdout
    expect("<<<" in out and ">>>" in out, "the release prints its reagent manifest", result.stdout + result.stderr)
    return out.split("<<<", 1)[1].split(">>>", 1)[0]


def main(image):
    empty = tempfile.mkdtemp(prefix="cyfr-builder-smoke-")
    stack = Stack("cyfr-builder-smoke", image, empty)
    try:
        stack.up()
        manifest = cargo_toml(stack)

        sources = {"src/lib.rs": LIB_RS, "Cargo.toml": manifest}
        status, answer = stack.build(sources, "rust", "reagent")
        expect(status == 200 and answer.get("wasm_base64"), "a Rust reagent builds in the image", answer)
        lock = answer.get("lockfile") or ""
        expect('name = "wit-bindgen-rt"' in lock, "the build resolves and returns its Cargo.lock", answer)

        widened = manifest.replace("[dependencies]\n", '[dependencies]\nsmallvec = "1"\n', 1)
        status, answer = stack.build({**sources, "Cargo.toml": widened, "Cargo.lock": lock}, "rust", "reagent")
        expect(status == 422 and "--locked" in answer.get("error", ""), "a dependency the lock does not cover is refused", answer)

        status, answer = stack.build({**sources, "Cargo.toml": widened, "Cargo.lock": lock}, "rust", "reagent", resolve=True)
        resolved = answer.get("lockfile") or ""
        expect(status == 200 and 'name = "smallvec"' in resolved, "resolve re-resolves the lock", answer)

        status, answer = stack.build({**sources, "Cargo.toml": widened, "Cargo.lock": resolved}, "rust", "reagent")
        expect(status == 200 and answer.get("lockfile") == resolved, "a locked rebuild keeps its lock", answer)

        broken = {**sources, "src/lib.rs": LIB_RS.replace("input\n", "input +\n")}
        status, answer = stack.build(broken, "rust", "reagent")
        expect(status == 422 and "error" in answer.get("error", "").lower() and "lib.rs" in answer.get("error", ""),
               "a compiler error reports its diagnostics", answer)

        status, answer = stack.build(TINCTURE, "javascript", "tincture")
        expect(status == 200 and "index.html" in (answer.get("output_files") or {}), "a tincture builds through npm and Vite", answer)

        expect(stack.pool_processes() == [], "no process of a build uid outlives its build", stack.pool_processes())
        expect(stack.homes() == [], "no build home outlives its build", stack.homes())
        logs = stack.logs()
        expect("quarantined" not in logs and "outlived retirement" not in logs, "every build uid was retired clean", logs)
    finally:
        stack.down()
        shutil.rmtree(empty, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])

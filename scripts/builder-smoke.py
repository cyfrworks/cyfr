#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Smoke-test a builder image the way compose runs it.

Starts the image read-only with an exec-capable /tmp scratch, then drives
its /build endpoint through a component's life: a Rust build that resolves
its Cargo.lock, a dependency added without re-resolving (refused by
`--locked`), a re-resolve, a locked rebuild, a compiler error that reports
its diagnostics, and a tincture build through npm and Vite. Finally no
toolchain process may be left running in the container.

Usage: scripts/builder-smoke.py IMAGE
"""

import base64
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request

TOKEN = "builder-smoke"
PORT = 4199
NAME = "cyfr-builder-smoke"

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
    "package.json": json.dumps(
        {
            "name": "smoke-tincture",
            "private": True,
            "version": "0.0.1",
            "type": "module",
            "scripts": {"build": "vite build"},
            "devDependencies": {"vite": "^6.0.0"},
        }
    ),
    "index.html": '<!doctype html><html><body><div id="app"></div>'
    '<script type="module" src="/src/main.js"></script></body></html>\n',
    "src/main.js": 'document.getElementById("app").textContent = "smoke";\n',
}


def run(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True)


def build(sources, language, target_type, resolve=False):
    body = json.dumps(
        {
            "source_files": {path: base64.b64encode(text.encode()).decode() for path, text in sources.items()},
            "language": language,
            "target_type": target_type,
            "resolve": resolve,
        }
    ).encode()

    request = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/build",
        data=body,
        method="POST",
        headers={"authorization": f"Bearer {TOKEN}", "content-type": "application/json"},
    )

    try:
        with urllib.request.urlopen(request, timeout=900) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read())


def expect(condition, message, answer=None):
    if not condition:
        detail = json.dumps(answer, indent=2)[:4000] if answer is not None else ""
        sys.exit(f"FAIL: {message}\n{detail}")
    print(f"ok: {message}")


def main(image):
    run("docker", "rm", "-f", NAME, check=False)
    run(
        "docker", "run", "-d", "--name", NAME,
        "--read-only", "--tmpfs", "/tmp:size=2g,exec",
        "--memory", "3g",
        "-e", "CYFR_BUILDER_LISTEN=true", "-e", f"CYFR_BUILDER_TOKEN={TOKEN}",
        "-p", f"127.0.0.1:{PORT}:4100",
        image,
    )

    try:
        for _ in range(60):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=2):
                    break
            except OSError:
                time.sleep(1)
        else:
            sys.exit("FAIL: the builder never answered /health\n" + run("docker", "logs", NAME, check=False).stdout)

        # Written to a file: the release's eval can print runtime warnings
        # on stdout.
        run(
            "docker", "exec", NAME, "/app/bin/builder", "eval",
            'File.write!("/tmp/smoke-Cargo.toml", Locus.Builder.cargo_toml_for(:reagent))',
        )
        cargo_toml = run("docker", "exec", NAME, "cat", "/tmp/smoke-Cargo.toml").stdout

        sources = {"src/lib.rs": LIB_RS, "Cargo.toml": cargo_toml}
        status, answer = build(sources, "rust", "reagent")
        expect(status == 200 and answer.get("wasm_base64"), "a Rust reagent builds in the image", answer)
        lock = answer.get("lockfile") or ""
        expect('name = "wit-bindgen-rt"' in lock, "the build resolves and returns its Cargo.lock", answer)

        widened = cargo_toml.replace("[dependencies]\n", '[dependencies]\nsmallvec = "1"\n', 1)
        status, answer = build({**sources, "Cargo.toml": widened, "Cargo.lock": lock}, "rust", "reagent")
        expect(status == 422 and "--locked" in answer.get("error", ""), "a dependency the lock does not cover is refused", answer)

        status, answer = build({**sources, "Cargo.toml": widened, "Cargo.lock": lock}, "rust", "reagent", resolve=True)
        resolved = answer.get("lockfile") or ""
        expect(status == 200 and 'name = "smallvec"' in resolved, "resolve re-resolves the lock", answer)

        status, answer = build({**sources, "Cargo.toml": widened, "Cargo.lock": resolved}, "rust", "reagent")
        expect(status == 200 and answer.get("lockfile") == resolved, "a locked rebuild keeps its lock", answer)

        broken = {**sources, "src/lib.rs": LIB_RS.replace("input\n", "input +\n")}
        status, answer = build(broken, "rust", "reagent")
        expect(status == 422 and "error" in answer.get("error", "").lower() and "lib.rs" in answer.get("error", ""),
               "a compiler error reports its diagnostics", answer)

        status, answer = build(TINCTURE, "javascript", "tincture")
        expect(status == 200 and "index.html" in (answer.get("output_files") or {}), "a tincture builds through npm and Vite", answer)

        processes = run("docker", "exec", NAME, "ps", "-eo", "comm=").stdout.split()
        leftovers = [name for name in processes if name in ("cargo", "rustc", "cargo-component", "npm", "node", "esbuild", "sh")]
        expect(leftovers == [], "no toolchain process outlives its build", leftovers)
    finally:
        run("docker", "rm", "-f", NAME, check=False)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])

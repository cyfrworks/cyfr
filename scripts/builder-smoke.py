#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Smoke-test a builder image as docker-compose.yml's locus-builds service.

Starts the image with the locus-builds service's own settings (the
`locus-builds` profile of docker-compose.yml, layered with
tests/builder-image/compose.locus-builds.yml for the image and a loopback
port), then drives the build wire (`Prima.BuilderProtocol`, signed by
tests/builder-image/stack.py) through a component's life: a Rust build
that streams its progress and resolves its Cargo.lock, a dependency added
without re-resolving (refused by `--locked`), a re-resolve, a locked
rebuild, a compiler error that reports its diagnostics, and a tincture
build through npm and Vite; no process of a build uid may be left running
and no build home may remain. A request at another protocol version is
refused naming both ends' versions, one signed with another key is refused
as unauthorized, and the routes the wire replaced are no operation. Then,
with a 15 s build deadline, a build that outlives it, having started a
daemon that ignores SIGTERM, is refused as timed out with nothing of it
left.

Usage: scripts/builder-smoke.py IMAGE
"""

import json
import os
import secrets
import shutil
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests", "builder-image"))

from stack import (  # noqa: E402
    RELEASE_BIN, RELEASE_USER, VERSION, Stack, brief, diagnostics, expect, output_bytes, output_file, tincture,
)

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
        f"""{RELEASE_BIN} eval 'IO.puts("<<<" <> Locus.Builder.cargo_toml_for(:reagent) <> ">>>")'""",
        user=RELEASE_USER,
    )
    out = result.stdout
    expect("<<<" in out and ">>>" in out, "the release prints its reagent manifest", result.stdout + result.stderr)
    return out.split("<<<", 1)[1].split(">>>", 1)[0]


def main(image):
    empty = tempfile.mkdtemp(prefix="cyfr-builder-smoke-")
    stack = Stack("cyfr-builder-smoke", image, empty)
    try:
        stack.up()
        expect(stack.health.get("version") == VERSION and all(t["available"] for t in stack.health["toolchains"].values()),
               "the service answers the wire's health operation with both toolchains available", stack.health)
        manifest = cargo_toml(stack)

        sources = {"src/lib.rs": LIB_RS, "Cargo.toml": manifest}
        http_status, progress, answer = stack.build_lines(sources, "rust", "reagent")
        expect(http_status == 200 and answer["type"] == "result" and (output_bytes(answer, "component.wasm") or b"").startswith(b"\0asm"),
               "a Rust reagent builds in the image", brief(answer))
        stages = [line.get("stage") for line in progress]
        expect(all(line.get("type") == "progress" and line.get("version") == VERSION for line in progress)
               and stages[:2] == ["preparing", "compiling"] and "output" in stages and "validating" in stages,
               "its answer streams the build's progress before the one terminal line", stages)
        lock = output_file(answer, "Cargo.lock") or ""
        expect('name = "wit-bindgen-rt"' in lock, "the build resolves and returns its Cargo.lock", brief(answer))

        widened = manifest.replace("[dependencies]\n", '[dependencies]\nsmallvec = "1"\n', 1)
        status, answer = stack.build({**sources, "Cargo.toml": widened, "Cargo.lock": lock}, "rust", "reagent")
        expect(status == 422 and answer.get("class") == "failed" and "status" in answer["reason"] and "--locked" in diagnostics(answer),
               "a dependency the lock does not cover is refused", brief(answer))

        status, answer = stack.build({**sources, "Cargo.toml": widened, "Cargo.lock": lock}, "rust", "reagent", resolve=True)
        resolved = output_file(answer, "Cargo.lock") or ""
        expect(status == 200 and 'name = "smallvec"' in resolved, "resolve re-resolves the lock", brief(answer))

        status, answer = stack.build({**sources, "Cargo.toml": widened, "Cargo.lock": resolved}, "rust", "reagent")
        expect(status == 200 and output_file(answer, "Cargo.lock") == resolved, "a locked rebuild keeps its lock", brief(answer))

        broken = {**sources, "src/lib.rs": LIB_RS.replace("input\n", "input +\n")}
        status, answer = stack.build(broken, "rust", "reagent")
        expect(status == 422 and answer.get("class") == "failed" and "error" in diagnostics(answer).lower() and "lib.rs" in diagnostics(answer),
               "a compiler error reports its diagnostics", brief(answer))

        status, answer = stack.build(TINCTURE, "javascript", "tincture")
        expect(status == 200 and output_file(answer, "index.html"), "a tincture builds through npm and Vite", brief(answer))

        expect(stack.pool_processes() == [], "no process of a build uid outlives its build", stack.pool_processes())
        expect(stack.homes() == [], "no build home outlives its build", stack.homes())
        logs = stack.logs()
        expect("quarantined" not in logs and "outlived retirement" not in logs, "every build uid was retired clean", logs)

        test_refusals(stack, sources)
        test_deadline(stack)
    finally:
        stack.down()
        shutil.rmtree(empty, ignore_errors=True)


def test_refusals(stack, sources):
    http_status, _progress, answer = stack.build_lines(sources, "rust", "reagent", version=VERSION + 1)
    expect(http_status == 409 and answer.get("class") == "protocol_mismatch"
           and answer["reason"] == {"builder": VERSION, "client": VERSION + 1},
           "a request at another protocol version is refused naming both ends' versions", answer)

    http_status, _progress, answer = stack.build_lines(sources, "rust", "reagent", key=secrets.token_hex(32))
    expect(http_status == 401 and answer.get("class") == "unauthorized" and answer["reason"] == "bad_mac",
           "a request signed with another key is refused as unauthorized", answer)

    # What the wire replaced: the bearer-token POST /build and GET /health.
    for method, path in (("POST", "/build"), ("GET", "/health")):
        request = urllib.request.Request(stack.base + path, data=b"{}" if method == "POST" else None, method=method,
                                         headers={"authorization": f"Bearer {stack.key}"})
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                status, line = response.status, response.read()
        except urllib.error.HTTPError as error:
            status, line = error.code, error.read()
        expect(status == 400 and json.loads(line).get("class") == "malformed", f"{method} {path} is no operation of the service", line.decode())

    expect(stack.pool_processes() == [] and stack.homes() == [], "nothing was started for a refused request", stack.pool_processes())


def test_deadline(stack):
    stack.up(timeout_ms=15_000)
    overrun = tincture("setsid sh -c \"trap '' TERM; exec sleep 1000\" </dev/null >/dev/null 2>&1 &\nsleep 300\n")
    result = {}
    started = time.monotonic()
    worker = threading.Thread(target=lambda: result.update(answer=stack.build(overrun, "javascript", "tincture")))
    worker.start()

    daemon_seen = False
    while worker.is_alive():
        daemon_seen = daemon_seen or any("sleep 1000" in p["cmd"] for p in stack.pool_processes())
        time.sleep(0.5)
    worker.join()
    elapsed = time.monotonic() - started

    status, answer = result["answer"]
    expect(daemon_seen, "the overrunning build started its daemon under its uid")
    expect(status == 504 and answer.get("class") == "timeout" and answer["reason"] == {"budget_ms": 15_000} and elapsed < 60,
           "a build past its deadline is refused as timed out, naming its budget", {"elapsed": elapsed, "answer": brief(answer)})
    expect(stack.pool_processes() == [], "no process of it survives, its daemon included", stack.pool_processes())
    expect(stack.homes() == [], "its home is gone", stack.homes())


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])

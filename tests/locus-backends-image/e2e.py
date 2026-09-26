#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The backends image runs a stdio backend end to end, as docker-compose.yml's locus-backends service.

First driven only by requests signed as CYFR signs them (harness.py):

- `hello` learns the service's lifetime and pool, and `reconcile` of
  nothing keeps nothing.
- A synced owner's probe backend starts, the owner is reported running,
  and its tools are listed as `<backend>__<tool>`, every result naming the
  service (`cyfr-locus`) in its `_meta`.
- The backend's sealed credential reaches its environment and never leaves
  the service: a result, a tool's error, a command's output, the stderr tail
  a status reports and the service's own log carry `[REDACTED]` where it
  was; a literal variable is not masked.
- A backend no call used within the owner's idle period is retired: its
  process and uid gone, its tools still listed, reported `idle`; the next
  call wakes it under a new process, and it is ready again.
- A released owner runs nothing, and an invoke for it is `unknown_owner`.

Then driven by `cyfr` itself: docker-compose.yml's cyfr service, from the
app image (CYFR_IMAGE, `cyfr:push` as the workflow builds it), beside the
same locus-backends service, both with every setting compose gives them.
A person signed in on the server (tests/release-boot/fixture.exs) stores a
canary credential, a random token, in the vault under a name this suite
owns and defines a stdio server whose probe backend reads it from the
vault, both over `/mcp` with the person's session, and calls the backend's
tools as the console calls them (`/mcp` dispatches declared tools only):

- the probe's environment holds the canary; every answer the person sees
  carries it masked;
- after that round trip the canary appears in no request-log row
  (`mcp_logs`), no decision row (`decision_logs`, `policy_logs`) and
  neither container's log;
- the controller (`cyfr`) is killed while the service holds its owner: an
  invoke signed under that owner is still served until the owner's lease
  runs out, and within the lease (CYFR_LOCUS_BACKENDS_LEASE_MS, set short
  here) the service releases it — no process of its backend is left — and
  serves nothing under it again: the same invoke is refused `lapsed`, or
  `unknown_owner` once the service has forgotten the owner, and still
  refused a lease later.

Prerequisites: harness.py's, and the app image. Usage: tests/locus-backends-image/e2e.py IMAGE
"""

import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    HERE, MCP_VERSION, POOL_FIRST, POOL_LAST, ROOT, ROUTES, STATUSES, Controller, Stack, eventually, expect,
    owner_of, post, probe, require_docker, run, wire_json,
)

SECRET = "e2e-backend-secret-0123456789"
LITERAL = "debug-literal-kept"
IDLE_MS = 3_000
OWNER = owner_of("e2e")

# The app image the second half runs, as the workflow's job builds it.
CYFR_IMAGE = os.environ.get("CYFR_IMAGE", "cyfr:push")
# The lease cyfr asks for each owner: short, so a dead controller's owner
# lapses within the suite's patience.
LEASE_MS = 6_000
CYFR_PORT = 4000
FIXTURE = os.path.join(ROOT, "tests", "release-boot", "fixture.exs")


def text_of(answer):
    return json.dumps(answer)


def scripted_controller(image):
    stack = Stack("locus-backends-e2e", image)
    try:
        stack.up()
        c = stack.controller()

        status, hello, boot = c.hello()
        expect(status == 200 and hello["boot"] == boot and hello["pool"] == {"size": POOL_LAST - POOL_FIRST + 1,
                                                                            "free": POOL_LAST - POOL_FIRST + 1},
               "hello names the service's lifetime and its whole pool free", hello)
        status, reconciled, _ = c.reconcile([])
        expect(status == 200 and reconciled["released"] == [], "a reconcile of nothing keeps nothing", reconciled)

        env = {"PROBE_SECRET": SECRET, "LOG_LEVEL": LITERAL}
        status, synced, _ = c.sync(OWNER, [probe(env=env)], idle_ms=IDLE_MS)
        expect(status == 200 and synced["backends"][0]["name"] == "probe",
               "a sync of one probe backend is admitted at once", synced)
        c.running(OWNER)
        report = c.report(OWNER)
        expect(report["backends"][0]["status"] == "ready" and report["e"] == OWNER["e"],
               "the owner runs at its version, its backend ready", report)

        status, listed, _, _ = c.invoke(OWNER, "tools/list")
        names = sorted(tool["name"] for tool in listed["result"]["tools"])
        expect(status == 200 and "probe__whoami" in names and "probe__echo_env" in names,
               "the backend's tools are listed as <backend>__<tool>", names)
        server = listed["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]
        expect(server["name"] == "cyfr-locus", "every result names the service", server)

        who = c.tool(OWNER, "probe__whoami")
        environ = stack.exec(f"tr '\\0' '\\n' < /proc/{who['pid']}/environ", user=str(who["uid"])).stdout
        expect(f"PROBE_SECRET={SECRET}" in environ, "the sealed credential reaches the backend's environment")

        # Every way out of the service masks it.
        echoed = c.tool(OWNER, "probe__echo_env", {"name": "PROBE_SECRET", "stderr": True})
        expect(echoed == {"value": "[REDACTED]"}, "a result carries the credential masked", echoed)
        literal = c.tool(OWNER, "probe__echo_env", {"name": "LOG_LEVEL"})
        expect(literal == {"value": LITERAL}, "a literal variable is not masked", literal)

        status, failed = c.call(OWNER, "probe__fail", {"name": "PROBE_SECRET"})
        expect(status == 200 and SECRET not in text_of(failed) and "[REDACTED]" in text_of(failed),
               "a tool's error carries the credential masked", failed)

        ran = c.tool(OWNER, "probe__run", {"argv": ["/bin/sh", "-c",
                                                    'echo "$PROBE_SECRET"; echo "Bearer $PROBE_SECRET" >&2']})
        expect(SECRET not in text_of(ran) and ran["stdout"].strip() == "[REDACTED]"
               and ran["stderr"].strip() == "Bearer [REDACTED]",
               "a command's output carries the credential masked, whole and after a scheme", ran)

        report = eventually(lambda: (lambda r: r if "[REDACTED]" in r["backends"][0]["stderr_tail"] else None)(
            c.report(OWNER)), "the stderr tail to hold the masked credential")
        expect(SECRET not in text_of(report), "a status's stderr tail carries the credential masked",
               report["backends"][0]["stderr_tail"][-400:])

        # Idle: no call for the idle period retires the process and keeps the tools.
        uid, pid = who["uid"], who["pid"]
        idle = eventually(lambda: (lambda r: r if r["backends"][0]["status"] == "idle" else None)(c.report(OWNER)),
                          "the backend to be retired idle", timeout_s=IDLE_MS / 1000 + 20)
        expect(idle["backends"][0]["tools"] > 0, "an idle backend keeps its tools", idle)
        eventually(lambda: not stack.under_uid(uid), f"no process of uid {uid} once idle")
        status, listed, _, _ = c.invoke(OWNER, "tools/list")
        expect(status == 200 and "probe__whoami" in [t["name"] for t in listed["result"]["tools"]],
               "an idle backend's tools stay listed", listed)

        woken = c.tool(OWNER, "probe__whoami")
        expect(woken["pid"] != pid and POOL_FIRST <= woken["uid"] <= POOL_LAST,
               "the next call wakes the backend under a new process", woken)
        report = c.report(OWNER)
        expect(report["backends"][0]["status"] == "ready", "a woken backend is ready", report)

        status, released, _ = c.release([OWNER])
        expect(status == 200 and [(o["server"], o["e"]) for o in released["released"]] == [(OWNER["server"],
                                                                                          OWNER["e"])],
               "a release names the version it released", released)
        eventually(lambda: not stack.pool_processes(), "no pooled process once released")
        status, refused, _, _ = c.invoke(OWNER, "tools/list")
        expect(status == STATUSES["unknown_owner"] and refused == {"version": 1, "error": "unknown_owner"},
               "an invoke for a released owner is unknown_owner", refused)

        time.sleep(1)
        expect(SECRET not in stack.logs(), "the credential never reaches the service's log")
    finally:
        stack.down()


# ————— cyfr as the controller —————

# Layered over docker-compose.yml and compose.locus-backends.yml: the cyfr
# service keeps every setting compose gives it but its image, a loopback
# port of the system's choosing, a volume of this run's own for its data
# (so nothing lands in the checkout) and the backends lease this suite
# waits out. Written here, beside the project's .env, per run.
CYFR_OVERRIDE = f"""
services:
  cyfr:
    image: ${{CYFR_IMAGE:?set CYFR_IMAGE}}
    container_name: !reset null
    pull_policy: never
    ports: !override
      - "127.0.0.1::{CYFR_PORT}"
    volumes: !override
      - cyfr-data:/app/data
    environment:
      - CYFR_LOCUS_BACKENDS_LEASE_MS={LEASE_MS}
volumes:
  cyfr-data: {{}}
"""


class CyfrStack(Stack):
    """locus-backends as the Stack runs it, and cyfr beside it as its controller."""

    def __init__(self, image, cyfr_image):
        super().__init__("locus-backends-cyfr", image)
        self.cyfr_image = cyfr_image
        self.override = os.path.join(self.project_dir, "compose.cyfr.yml")
        with open(self.override, "w", encoding="utf-8") as handle:
            handle.write(CYFR_OVERRIDE)
        # The deployment file `cyfr init` writes, minted for this run: cyfr
        # reads it (env_file), and compose hands the backends key to
        # locus-backends from it as well as from the Stack's environment.
        with open(os.path.join(self.project_dir, ".env"), "w", encoding="utf-8") as handle:
            handle.write("\n".join([
                f"CYFR_SECRET_KEY_BASE={secrets.token_urlsafe(48)}",
                f"CYFR_LOCUS_BACKENDS_KEY={self.key.hex()}",
                f"CYFR_OPUS_KEY={secrets.token_hex(32)}",
                "CYFR_LOCUS_BUILDS_URL=",
                "CYFR_LOCUS_BUILDS_KEY=",
                "CYFR_CORS_ALLOWED_ORIGINS=",
                "CYFR_AUTO_MIGRATE=true",
                "CYFR_GITHUB_CLIENT_ID=Ov23lib66tiIwXkgUpwm",
                "CYFR_PLATFORM_ADMIN_EMAILS=operator@example.com",
                "",
            ]))
        self.cyfr = None
        self.cyfr_base = None

    def env(self, **extra):
        return super().env(CYFR_IMAGE=self.cyfr_image, **extra)

    def compose(self, *args, check=True, env=None):
        files = [os.path.join(ROOT, "docker-compose.yml"), os.path.join(HERE, "compose.locus-backends.yml"),
                 self.override]
        return run(
            "docker", "compose", "--project-name", self.project, "--project-directory", self.project_dir,
            *[arg for file in files for arg in ("-f", file)], *args,
            env=env or self.env(), check=check,
        )

    def up_both(self):
        self.up()
        self.compose("up", "--detach", "--no-build", "--no-deps", "cyfr")
        self.cyfr = self.compose("ps", "--quiet", "cyfr").stdout.strip()
        expect(self.cyfr, "compose started the cyfr container")
        address = self.compose("port", "cyfr", str(CYFR_PORT)).stdout.strip().splitlines()[0]
        self.cyfr_base = f"http://{address}"
        eventually(lambda: http_status(self.cyfr_base + "/api/health/ready") == 200,
                   "cyfr to answer /api/health/ready", timeout_s=180)

    def cyfr_logs(self):
        return self.compose("logs", "--no-color", "cyfr", check=False).stdout

    def rpc(self, expression):
        """Evaluates `expression` in the running cyfr release (`bin/cyfr rpc`) and answers its output."""
        result = run("docker", "exec", "-u", "app", self.cyfr, "/app/bin/cyfr", "rpc", expression, check=False)
        expect(result.returncode == 0, "the release answers an rpc", result.stdout + result.stderr)
        return result.stdout

    def fixture(self, *args):
        """One command of tests/release-boot/fixture.exs, evaluated inside cyfr: its JSON answer."""
        quoted = ", ".join(json.dumps(arg) for arg in args)
        out = self.rpc(f'{{answer, _}} = Code.eval_file("/tmp/fixture.exs"); IO.puts(answer.([{quoted}]))')
        line = [x for x in out.splitlines() if x.startswith("FIXTURE=")]
        expect(line, f"the fixture answers {args[0]}", out)
        return json.loads(line[-1][len("FIXTURE="):])

    def down(self):
        if os.environ.get("CI"):
            print(self.cyfr_logs())
        super().down()


def http_status(url):
    try:
        with urllib.request.urlopen(url, timeout=3) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code
    except OSError:
        return None


class Person:
    """A signed-in person's MCP client, as the CLI speaks /mcp: stateless, a bearer session, the routing headers."""

    def __init__(self, base, token):
        self.base, self.token, self.id = base, token, 0

    def call(self, tool, arguments):
        self.id += 1
        body = json.dumps({
            "jsonrpc": "2.0", "id": self.id, "method": "tools/call",
            "params": {"name": tool, "arguments": arguments, "_meta": {
                "io.modelcontextprotocol/protocolVersion": MCP_VERSION,
                "io.modelcontextprotocol/clientInfo": {"name": "locus-backends-e2e", "version": "0"},
                "io.modelcontextprotocol/clientCapabilities": {},
            }},
        }).encode()
        request = urllib.request.Request(self.base + "/mcp", data=body, method="POST", headers={
            "authorization": f"Bearer {self.token}", "content-type": "application/json",
            "accept": "application/json, text/event-stream", "mcp-protocol-version": MCP_VERSION,
            "mcp-method": "tools/call", "mcp-name": tool,
        })
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read() or b"null")

    def tool(self, tool, arguments):
        """A tool's answer, parsed; the suite fails on a refusal."""
        status, answer = self.call(tool, arguments)
        result = (answer or {}).get("result") if isinstance(answer, dict) else None
        if status != 200 or not result or result.get("isError"):
            sys.exit(f"FAIL: {tool} {arguments.get('action', '')}: {status} {json.dumps(answer)[:3000]}")
        text = result["content"][0]["text"]
        try:
            return json.loads(text)
        except ValueError:
            return text


def cyfr_controller(image):
    canary = f"canary-{secrets.token_hex(24)}"
    entry = f"e2e-canary-{secrets.token_hex(4)}"
    stack = CyfrStack(image, CYFR_IMAGE)
    try:
        stack.up_both()
        run("docker", "cp", FIXTURE, f"{stack.cyfr}:/tmp/fixture.exs")
        signed_in = stack.fixture("person", "operator@example.com", "locus-backends-e2e")
        person = Person(stack.cyfr_base, signed_in["token"])
        expect(signed_in["athanor_id"], "a person is signed in on cyfr, in an athanor of their own", signed_in)

        person.tool("vault", {"action": "create", "name": entry, "kind": "api_key", "fields": {"api_key": canary}})
        created = person.tool("mcp_servers", {"action": "create", "name": "e2e-probe", "config": {
            "transport": "stdio",
            "console": True,
            "backends": [{"name": "probe", "command": "node /probe/probe-backend.mjs",
                          "env": {"PROBE_SECRET": f"vault:{entry}", "LOG_LEVEL": LITERAL}}],
        }})
        print(f"created: {json.dumps(created)[:400]}", flush=True)

        # The backend runs on the service under the owner cyfr synced.
        processes = eventually(lambda: stack.pool_processes(), "cyfr's owner to run its backend", timeout_s=60)
        environ = stack.exec(f"tr '\\0' '\\n' < /proc/{processes[0]['pid']}/environ",
                             user=str(processes[0]["uids"][0])).stdout
        expect(f"PROBE_SECRET={canary}" in environ,
               "the canary reaches the backend's environment from the vault, through cyfr's seal")

        # A proxied tool is `<server>:<tool>`, which the console calls for
        # the person through the gate (/mcp dispatches declared tools only);
        # the server opted into that plane with `console`.
        def console(tool, arguments):
            return stack.fixture("console", signed_in["token"], tool, json.dumps(arguments))

        echoed = console("e2e-probe:probe__echo_env", {"name": "PROBE_SECRET", "stderr": True})
        expect("ok" in echoed and canary not in text_of(echoed) and "[REDACTED]" in text_of(echoed),
               "the person sees the canary masked in the tool's answer", echoed)
        failed = console("e2e-probe:probe__fail", {"name": "PROBE_SECRET"})
        expect(canary not in text_of(failed), "a tool's error through cyfr carries no canary", failed)
        ran = console("e2e-probe:probe__run", {"argv": ["/bin/sh", "-c", 'echo "$PROBE_SECRET"; echo "$PROBE_SECRET" >&2']})
        expect("ok" in ran and canary not in text_of(ran), "a command's output through cyfr carries no canary", ran)
        # And the person's own client over /mcp: the server's definition, read back.
        got = person.tool("mcp_servers", {"action": "get", "name": "e2e-probe"})
        expect(canary not in text_of(got), "the server's definition over /mcp carries no canary", got)

        time.sleep(1)
        rows = stack.rpc(
            'for t <- ~w(mcp_logs decision_logs policy_logs) do '
            '%{rows: rows} = Arca.Repo.query!("SELECT * FROM #{t}"); '
            'IO.puts("TABLE #{t} #{length(rows)} " <> inspect(rows, limit: :infinity, printable_limit: :infinity)) '
            'end')
        counts = {line.split()[1]: int(line.split()[2]) for line in rows.splitlines() if line.startswith("TABLE ")}
        expect(counts.get("mcp_logs", 0) > 0 and counts.get("decision_logs", 0) > 0,
               "the round trip wrote request-log and decision rows", counts)
        expect(canary not in rows, "the canary is in no request-log row and no decision row", counts)
        expect(canary not in stack.logs(), "the canary is not in locus-backends' log")
        expect(canary not in stack.cyfr_logs(), "the canary is not in cyfr's log")

        # The owner as the service holds it, read before the controller dies.
        server = json.loads([x for x in stack.rpc(
            '%{rows: [[id, athanor, epoch]]} = Arca.Repo.query!('
            '"SELECT id, athanor_id, epoch FROM mcp_servers WHERE name = \'e2e-probe\'"); '
            '{:ok, g} = with(:none <- Arca.ControlPlane.generation(), do: {:ok, 1}); '
            'IO.puts("OWNER=" <> Jason.encode!(%{server: id, athanor: athanor, e: epoch, g: g}))'
        ).splitlines() if x.startswith("OWNER=")][-1][len("OWNER="):])
        owner = {"athanor": server["athanor"], "server": server["server"], "e": server["e"]}
        _status, _health, boot = post(stack.base + ROUTES["health"], {"content-type": "application/json"},
                                      wire_json({"version": 1}))
        controller = Controller(stack.base, stack.key, generation=server["g"])
        controller.boot = boot

        def served():
            status, answer, _boot, _request = controller.invoke(owner, "tools/list")
            return status, answer

        status, answer = served()
        expect(status == 200 and any(t["name"] == "probe__echo_env" for t in answer["result"]["tools"]),
               "an invoke signed under cyfr's owner is served while cyfr holds it", answer)

        # The controller dies with its owner held.
        killed_at = time.monotonic()
        run("docker", "kill", stack.cyfr)
        status, answer = served()
        expect(status == 200, "the dead controller's owner is still served inside its lease", answer)

        eventually(lambda: not stack.pool_processes(), "the service to release the dead controller's owner",
                   timeout_s=LEASE_MS / 1000 + 10)
        released_after = time.monotonic() - killed_at
        # The lease runs from the last renewal, before the kill; the
        # service's sweep ticks every second and retires the backend after.
        expect(released_after <= LEASE_MS / 1000 + 3,
               f"the owner is released once its lease runs out ({released_after:.1f}s after the kill, lease "
               f"{LEASE_MS / 1000:.0f}s, bound {LEASE_MS / 1000 + 3:.0f}s)")
        # Refused as the lease's lapse, or once the service has forgotten
        # the owner, as an owner it does not know: either way, not served.
        status, answer = served()
        expect(isinstance(answer, dict) and answer.get("error") in ("lapsed", "unknown_owner")
               and status == STATUSES[answer["error"]] and answer == {"version": 1, "error": answer["error"]},
               "nothing is served under the dead controller's owner once released", answer)
        time.sleep(LEASE_MS / 1000)
        status, answer = served()
        expect(status != 200 and "result" not in (answer or {}),
               "nor a lease later", answer)
        expect(canary not in stack.logs(), "the canary is not in locus-backends' log after the release")
    finally:
        stack.down()


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: e2e.py IMAGE")
    require_docker()
    image = run("docker", "image", "inspect", "--format", "{{.Id}}", CYFR_IMAGE, check=False)
    if image.returncode != 0:
        sys.exit(f"FAIL: the app image {CYFR_IMAGE} is not on this host (build it, or set CYFR_IMAGE)")
    scripted_controller(sys.argv[1])
    cyfr_controller(sys.argv[1])


if __name__ == "__main__":
    main()

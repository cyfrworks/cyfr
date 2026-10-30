#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The cyfr.run stand-in's self-test, each check against a stand-in of its
# own on 127.0.0.1, every resource in one temporary directory removed on
# exit:
#   - the registry: tests/fixtures/registry_wire.json's claim and resolve, a
#     taken name, an unknown name and a malformed body; a stand-in started
#     without --directory names its own directory routes, one started with
#     --directory names that URL;
#   - the directory: every scenario of tests/fixtures/directory_wire.json but
#     the three of production limits, each step but those whose expected
#     answer is `unverified` (the stand-in checks no signature, and a step
#     refused that way changes nothing at a directory);
#   - forwarding against a local fake upstream that records every header it
#     receives: a GET copies only Accept and User-Agent, an upstream 3xx
#     answers 502 and is not followed, any other method on a route the
#     stand-in does not own answers 405 and reaches nothing, and without
#     --upstream nothing is forwarded;
#   - a stop on SIGTERM, a restart from the state file, and a refusal to
#     start on a state file that names another directory.
# Usage: python3 -I tests/registry-stand-in/standin_test.py

import http.client
import http.server
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
STANDIN = os.path.join(HERE, "standin.py")
REGISTRY = json.load(open(os.path.join(ROOT, "tests", "fixtures", "registry_wire.json"), encoding="utf-8"))
DIRECTORY = json.load(open(os.path.join(ROOT, "tests", "fixtures", "directory_wire.json"), encoding="utf-8"))
LIMITS = {"sixth genesis from one source", "identity capacity", "log capacity and recovery reserve"}
REDIRECTED = "cyfr.run answered with a redirect, which the stand-in does not follow."

failures = []
checks = 0
scratch = tempfile.mkdtemp(prefix="cyfr-standin-test.")
running = []


def check(held, what, detail=""):
    global checks
    checks += 1
    if held:
        print("PASS: " + what)
    else:
        failures.append(what)
        print("FAIL: " + what + (("\n  " + str(detail)) if detail else ""))


def jcs(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


class StandIn:
    def __init__(self, name, *extra, state=None):
        self.dir = os.path.join(scratch, name)
        os.makedirs(self.dir, exist_ok=True)
        self.state = state or os.path.join(self.dir, "state.json")
        ready = os.path.join(self.dir, "ready")
        if os.path.exists(ready):
            os.remove(ready)
        self.log = open(os.path.join(self.dir, "log"), "a")
        self.process = subprocess.Popen(
            [sys.executable, "-I", STANDIN, "--address", "127.0.0.1", "--port", "0", "--state", self.state,
             "--ready-file", ready, *extra],
            stdout=self.log, stderr=self.log)
        running.append(self.process)
        for _ in range(100):
            if os.path.exists(ready) or self.process.poll() is not None:
                break
            time.sleep(0.05)
        self.port = int(open(ready).read()) if os.path.exists(ready) else None

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        data = body if isinstance(body, (bytes, type(None))) else (body if isinstance(body, str) else jcs(body)).encode()
        connection.request(method, path, body=data, headers=dict({"Content-Type": "application/json"}, **(headers or {})))
        response = connection.getresponse()
        text = response.read().decode("utf-8", "replace")
        connection.close()
        return response.status, text, {k.lower(): v for k, v in response.getheaders()}

    def stop(self, signum=signal.SIGTERM):
        self.process.send_signal(signum)
        try:
            return self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            return None


def code_of(text):
    try:
        return json.loads(text)["errors"][0]["code"]
    except (ValueError, KeyError, IndexError, TypeError):
        return None


def request_of(name, **body):
    request = dict(REGISTRY["requests"][name]["request"])
    if body:
        request["body"] = dict(request["body"], **body)
    return request


def answer_named(name):
    return next(a for a in REGISTRY["answers"] if a["name"] == name)


# ---- the registry -------------------------------------------------------------

def registry_checks():
    own = StandIn("registry-own")
    base = "http://127.0.0.1:%d" % own.port
    status, text, _ = own.request("GET", "/v1/legal/version")
    version = json.loads(text)["policy_version"] if status == 200 else None
    check(status == 200 and isinstance(version, str), "the registry answers its policy version", text)

    claim = request_of("handle_claim")
    status, text, _ = own.request("POST", "/v1/namespaces/personal/claim", claim)
    check(status == 412 and code_of(text) == "POLICY_ACCEPTANCE_REQUIRED",
          "a claim before the policy's acceptance is refused for it", (status, text))

    status, text, _ = own.request("POST", "/v1/legal/accept", request_of("policy_accept", policy_version=version))
    check(status == 201, "the vectors' policy.accept, at the current version, is accepted", (status, text))

    status, text, _ = own.request("POST", "/v1/namespaces/personal/claim", claim)
    expected = dict(answer_named("an answer")["result"], registry="127.0.0.1", directory=base)
    want = jcs(dict(expected, protocol="cyfr-handle/v1"))
    check(status == 201 and text == want,
          "the vectors' handle.claim is claimed, answered in cyfr-handle/v1 naming the stand-in's own directory",
          (status, text, want))

    status, again, _ = own.request("POST", "/v1/namespaces/personal/claim", claim)
    check(status == 201 and again == text, "a repeated claim by the same identifier answers the same", (status, again))

    status, text, _ = own.request("GET", "/v1/handles/alice")
    check(status == 200 and text == want, "the claimed name resolves to the vectors' answer, rehosted", (status, text))

    other = request_of("handle_claim")
    other["identifier"] = "per_" + "b" * 64
    own.request("POST", "/v1/legal/accept", dict(request_of("policy_accept", policy_version=version), identifier=other["identifier"]))
    status, text, _ = own.request("POST", "/v1/namespaces/personal/claim", other)
    check(status == 409 and code_of(text) == "SLUG_TAKEN", "a name another identifier holds is taken", (status, text))

    status, text, _ = own.request("GET", "/v1/handles/bob")
    check(status == 404 and code_of(text) == "HANDLE_NOT_FOUND", "an unknown name is not found", (status, text))

    for body in ["not json", "[]", jcs(dict(claim, extra=1)), jcs(dict(claim, body={"handle": "alice", "x": 1}))]:
        status, text, _ = own.request("POST", "/v1/namespaces/personal/claim", body)
        check(status == 400 and code_of(text) == "REQUEST_MALFORMED", "a malformed claim is refused: %s" % body[:40], (status, text))

    status, text, _ = own.request("POST", "/v1/namespaces/personal/claim", request_of("handle_claim", handle="Alice"))
    check(status == 400 and code_of(text) == "INVALID_USERNAME", "a name outside the grammar is refused", (status, text))
    own.stop()

    pinned = StandIn("registry-pinned", "--directory", "https://dir.test")
    pinned.request("POST", "/v1/legal/accept", request_of("policy_accept", policy_version=version))
    status, text, _ = pinned.request("POST", "/v1/namespaces/personal/claim", claim)
    check(status == 201 and json.loads(text).get("directory") == "https://dir.test",
          "a stand-in started with --directory names that directory in its answers", (status, text))
    pinned.stop()


# ---- the directory ------------------------------------------------------------

def directory_checks():
    for scenario in DIRECTORY["scenarios"]:
        if scenario["name"] in LIMITS:
            continue
        name = scenario["name"]
        standin = StandIn("directory-%d" % DIRECTORY["scenarios"].index(scenario), "--directory", DIRECTORY["directory"])
        problems = []
        for index, step in enumerate(scenario["steps"], 1):
            expect = step["expect"]
            if expect.get("body", {}).get("error") == "unverified":
                continue
            request = step["request"]
            path = request["path"]
            if request.get("query"):
                path += "?" + "&".join("%s=%s" % kv for kv in request["query"].items())
            body = None if request.get("body") is None else request["body"]
            status, text, headers = standin.request(request["method"], path, body)
            where = "step %d, %s %s" % (index, request["method"], request["path"])
            if status != expect["status"]:
                problems.append("%s: status %d, not %d: %s" % (where, status, expect["status"], text[:200]))
                continue
            if status == 413:
                continue
            answer = json.loads(text)
            for field, value in expect.get("body", {}).items():
                if answer.get(field, "<absent>") != value:
                    problems.append("%s: %s is %r, not %r" % (where, field, answer.get(field, "<absent>"), value))
            for header, value in expect.get("headers", {}).items():
                if headers.get(header.lower()) != value:
                    problems.append("%s: header %s is %r" % (where, header, headers.get(header.lower())))
            for entry in answer.get("entries", []) + ([answer["entry"]] if "entry" in answer else []):
                if jcs(entry) not in text:
                    problems.append("%s: an entry is not on the wire as its canonical bytes" % where)
        check(not problems, "directory: " + name, "\n  ".join(problems))
        standin.stop()


# ---- forwarding -------------------------------------------------------------

class Upstream(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def record(self):
        self.server.seen.append((self.command, self.path, [(k, v) for k, v in self.headers.items()]))

    def do_GET(self):
        self.record()
        if self.path.startswith("/moved"):
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:%d/elsewhere" % self.server.server_address[1])
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = b'{"components":[]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_POST = do_PUT = do_PATCH = do_DELETE = do_GET


def forwarding_checks():
    fake = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
    fake.seen = []
    threading.Thread(target=fake.serve_forever, daemon=True).start()
    upstream = "http://127.0.0.1:%d" % fake.server_address[1]

    forwarding = StandIn("forwarding", "--upstream", upstream)
    secrets = {"Authorization": "Bearer stand-in-secret", "Cookie": "session=stand-in-cookie",
               "Proxy-Authorization": "Basic c3RhbmQ6aW4=", "X-Other": "other"}
    status, text, _ = forwarding.request(
        "GET", "/v1/components/search?q=x", None,
        dict({"Accept": "application/json", "User-Agent": "cyfr-test/1"}, **secrets))
    seen = list(fake.seen)
    names = sorted(k.lower() for k, _ in seen[0][2]) if seen else []
    values = {k.lower(): v for k, v in seen[0][2]} if seen else {}
    check(status == 200 and text == '{"components":[]}' and len(seen) == 1 and seen[0][1] == "/v1/components/search?q=x",
          "a GET of a route the stand-in does not own is forwarded upstream and answered", (status, text, seen))
    check(names == ["accept", "host", "user-agent"] and values.get("accept") == "application/json"
          and values.get("user-agent") == "cyfr-test/1",
          "the forwarded GET carries only Accept and User-Agent", seen)
    check(not any(secret in str(seen) for secret in secrets.values()),
          "no credential, cookie or other header reaches the upstream", seen)

    fake.seen.clear()
    status, text, _ = forwarding.request("GET", "/moved/somewhere")
    check(status == 502 and text == REDIRECTED, "an upstream 3xx answers 502 with the stated sentence", (status, text))
    check([s[1] for s in fake.seen] == ["/moved/somewhere"], "the redirect is not followed", fake.seen)

    fake.seen.clear()
    for method in ["POST", "PUT", "PATCH", "DELETE"]:
        status, _, _ = forwarding.request(method, "/v1/tokens/mint", "{}")
        check(status == 405, "%s on a route the stand-in does not own answers 405" % method, status)
    check(fake.seen == [], "no other method reaches the upstream", fake.seen)
    forwarding.stop()

    alone = StandIn("no-upstream")
    status, _, _ = alone.request("GET", "/v1/components/search?q=x")
    check(status == 404 and fake.seen == [], "without --upstream nothing is forwarded", (status, fake.seen))
    alone.stop()
    fake.shutdown()


# ---- stopping and restarting ----------------------------------------------------

def lifecycle_checks():
    state = os.path.join(scratch, "restart-state.json")
    first = StandIn("restart-1", "--directory", "https://dir.test", state=state)
    genesis = json.loads(DIRECTORY["entries"]["genesis-alice"])
    first.request("POST", "/directory/v1/genesis", genesis)
    version = json.loads(first.request("GET", "/v1/legal/version")[1])["policy_version"]
    first.request("POST", "/v1/legal/accept", request_of("policy_accept", policy_version=version))
    first.request("POST", "/v1/namespaces/personal/claim", request_of("handle_claim"))
    log = first.request("GET", "/directory/v1/per_778af29253df902c12fff9d3999243709f16f1e4147d49df4465057a599b5dd9")
    code = first.stop(signal.SIGTERM)
    check(code == 0, "the stand-in stops on SIGTERM", code)
    saved = json.load(open(state))
    check(saved.get("directory") == "https://dir.test" and saved.get("names") == {"alice": request_of("handle_claim")["identifier"]},
          "the state file records the directory it serves and the names", saved.get("directory"))

    second = StandIn("restart-2", "--directory", "https://dir.test", state=state)
    status, text, _ = second.request("GET", "/v1/handles/alice")
    check(status == 200 and json.loads(text)["handle"] == "alice", "a restart from the state file keeps the names", (status, text))
    again = second.request("GET", "/directory/v1/per_778af29253df902c12fff9d3999243709f16f1e4147d49df4465057a599b5dd9")
    check(again[:2] == log[:2], "a restart from the state file keeps the logs", (again[:2], log[:2]))
    second.stop()

    elsewhere = StandIn("restart-3", "--directory", "https://other.test", state=state)
    code = elsewhere.process.wait(timeout=10)
    check(code not in (0, None) and elsewhere.port is None,
          "a state file naming another directory refuses the start", code)


try:
    registry_checks()
    directory_checks()
    forwarding_checks()
    lifecycle_checks()
finally:
    for process in running:
        if process.poll() is None:
            process.kill()
            process.wait()
    subprocess.run(["rm", "-rf", scratch])

print("%d/%d passed" % (checks - len(failures), checks))
sys.exit(1 if failures else 0)

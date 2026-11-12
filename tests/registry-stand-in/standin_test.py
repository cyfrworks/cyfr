#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The cyfr.run stand-in's self-test, each check against a stand-in of its
# own on 127.0.0.1, every resource in one temporary directory removed on
# exit:
#   - the registry: tests/fixtures/registry_wire.json's claim and resolve, a
#     taken name, an unknown name and a malformed body, and the account
#     service's configuration (/account/config.json); a stand-in started
#     without --directory names its own directory routes, one started with
#     --directory names that URL;
#   - the directory: every scenario of tests/fixtures/directory_wire.json but
#     the three of production limits, each step but those whose expected
#     answer is `unverified` for a signature (the stand-in checks none, and
#     a step refused that way changes nothing at a directory), a tombstone
#     step made through the stand-in's own operator route;
#   - the names: every scenario of directory_wire.json's handles section,
#     a claim signed by nothing (the stand-in checks no signature) after its
#     identifier accepts the policy;
#   - the account log's grammar: every chain of tests/fixtures/identity.json
#     with an entry naming a passkey's maker (`aaguid`) is posted entry by
#     entry, and its last entry is accepted, or refused with the field the
#     chain names; none of them turns on a signature;
#   - forwarding against a local fake upstream that records every header it
#     receives: a GET copies only Accept and User-Agent, an upstream 3xx
#     answers 502 and is not followed, any other method on a route the
#     stand-in does not own answers 405 and reaches nothing, and without
#     --upstream nothing is forwarded;
#   - a stop on SIGTERM, a restart from the state file, and a refusal to
#     start on a state file that names another directory.
# Usage: python3 -I tests/registry-stand-in/standin_test.py

import hashlib
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
IDENTITY = json.load(open(os.path.join(ROOT, "tests", "fixtures", "identity.json"), encoding="utf-8"))
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

    def request(self, method, path, body=None, headers=None, raw=False):
        """The answer's status, its body (the bytes as sent when raw, else
        their text) and its headers."""
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        data = body if isinstance(body, (bytes, type(None))) else (body if isinstance(body, str) else jcs(body)).encode()
        connection.request(method, path, body=data, headers=dict({"Content-Type": "application/json"}, **(headers or {})))
        response = connection.getresponse()
        sent = response.read()
        connection.close()
        text = sent if raw else sent.decode("utf-8", "replace")
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

    status, text, _ = own.request("GET", "/account/config.json")
    want = jcs({"directory": base, "registry": base, "policy": {"version": version, "url": base + "/v1/legal/version"}})
    check(status == 200 and text == want,
          "the account service's configuration names its own directory, itself as the registry and its policy",
          (status, text, want))

    claim = request_of("handle_claim")
    status, text, _ = own.request("POST", "/v1/namespaces/personal/claim", claim)
    check(status == 412 and code_of(text) == "POLICY_ACCEPTANCE_REQUIRED",
          "a claim before the policy's acceptance is refused for it", (status, text))

    status, text, _ = own.request("POST", "/v1/legal/accept", request_of("policy_accept", policy_version=version))
    check(status == 201, "the vectors' policy.accept, at the current version, is accepted", (status, text))

    status, text, _ = own.request("POST", "/v1/namespaces/personal/claim", claim)
    claimed = jcs({"handle": "alice", "identifier": claim["identifier"]})
    check(status == 201 and text == claimed, "the vectors' handle.claim is claimed, answered with its name and identifier",
          (status, text, claimed))

    status, again, _ = own.request("POST", "/v1/namespaces/personal/claim", claim)
    check(status == 200 and again == claimed, "a repeated claim by the same identifier answers 200 and the same", (status, again))

    expected = dict(answer_named("an answer")["result"], registry="127.0.0.1", directory=base)
    want = jcs(dict(expected, protocol="cyfr-handle/v1"))

    status, text, _ = own.request("GET", "/v1/handles/alice")
    check(status == 200 and text == want, "the claimed name resolves to the vectors' answer, rehosted", (status, text))

    other = request_of("handle_claim")
    other["identifier"] = "per_" + "b" * 64
    own.request("POST", "/v1/legal/accept", dict(request_of("policy_accept", policy_version=version), identifier=other["identifier"]))
    status, text, _ = own.request("POST", "/v1/namespaces/personal/claim", other)
    check(status == 409 and code_of(text) == "SLUG_TAKEN", "a name another identifier holds is taken", (status, text))

    reserved = dict(request_of("handle_claim"), body={"handle": "admin"})
    status, text, _ = own.request("POST", "/v1/namespaces/personal/claim", reserved)
    check(status == 400 and code_of(text) == "RESERVED", "the reserved name's claim is refused as reserved", (status, text))
    status, text, _ = own.request("GET", "/v1/handles/admin")
    check(status == 404 and code_of(text) == "HANDLE_NOT_FOUND", "the reserved name is not found", (status, text))

    status, text, _ = own.request("GET", "/v1/handles/bob")
    check(status == 404 and code_of(text) == "HANDLE_NOT_FOUND", "an unknown name is not found", (status, text))

    status, text, _ = own.request("GET", "/v1/identities/%s/handle" % claim["identifier"])
    check(status == 200 and text == want, "the identifier's name is answered as the name's own answer", (status, text))
    status, text, _ = own.request("GET", "/v1/identities/%s/handle" % other["identifier"])
    check(status == 404 and code_of(text) == "HANDLE_NOT_FOUND", "an identifier holding no name is not found", (status, text))

    for body in ["not json", "[]", jcs(dict(claim, extra=1)), jcs(dict(claim, body={"handle": "alice", "x": 1}))]:
        status, text, _ = own.request("POST", "/v1/namespaces/personal/claim", body)
        check(status == 400 and code_of(text) == "REQUEST_MALFORMED", "a malformed claim is refused: %s" % body[:40], (status, text))

    status, text, _ = own.request("POST", "/v1/namespaces/personal/claim", request_of("handle_claim", handle="Alice"))
    check(status == 400 and code_of(text) == "INVALID_USERNAME", "a name outside the grammar is refused", (status, text))
    own.stop()

    pinned = StandIn("registry-pinned", "--directory", "https://dir.test")
    status, text, _ = pinned.request("GET", "/account/config.json")
    check(status == 200 and json.loads(text).get("directory") == "https://dir.test"
          and json.loads(text).get("registry") == "http://127.0.0.1:%d" % pinned.port,
          "a stand-in started with --directory names that directory, and itself as the registry", (status, text))
    pinned.request("POST", "/v1/legal/accept", request_of("policy_accept", policy_version=version))
    pinned.request("POST", "/v1/namespaces/personal/claim", claim)
    status, text, _ = pinned.request("GET", "/v1/handles/alice")
    check(status == 200 and json.loads(text).get("directory") == "https://dir.test",
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
            if "tombstone" in step:
                status, text, _ = standin.request("POST", "/stand-in/tombstone/" + step["tombstone"])
                if status != 200:
                    problems.append("step %d, tombstone: status %d: %s" % (index, status, text[:200]))
                continue
            expect = step["expect"]
            body = expect.get("body", {})
            if body.get("error") == "unverified" and body.get("reason") != "broken_link":
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
            for entry in answer.get("entries", []):
                if jcs(entry) not in text:
                    problems.append("%s: an entry is not on the wire as its canonical bytes" % where)
        check(not problems, "directory: " + name, "\n  ".join(problems))
        standin.stop()


# ---- the names -----------------------------------------------------------------

def name_checks():
    handles = DIRECTORY["handles"]
    for number, scenario in enumerate(handles["scenarios"]):
        standin = StandIn("names-%d" % number, "--directory", DIRECTORY["directory"])
        _, text, _ = standin.request("GET", "/v1/legal/version")
        version = json.loads(text)["policy_version"]
        problems = []
        for index, step in enumerate(scenario["steps"], 1):
            where = "step %d" % index
            if "register" in step:
                status, text, _ = standin.request("POST", "/directory/v1/register", DIRECTORY["entries"][step["register"]])
                if status != 200:
                    problems.append("%s, register: status %d: %s" % (where, status, text[:200]))
                continue
            if "tombstone" in step:
                status, text, _ = standin.request("POST", "/stand-in/tombstone/" + step["tombstone"])
                if status != 200:
                    problems.append("%s, tombstone: status %d: %s" % (where, status, text[:200]))
                continue
            if "claim" in step:
                claim = step["claim"]
                for operation, path, body in [("policy.accept", "/v1/legal/accept", {"policy_version": version}),
                                              ("handle.claim", "/v1/namespaces/personal/claim", {"handle": claim["handle"]})]:
                    status, sent, _ = standin.request("POST", path, unsigned(handles["registry"], operation, claim["identifier"], body),
                                                      raw=True)
                where += ", claim " + claim["handle"]
            else:
                status, sent, _ = standin.request(step["request"]["method"], step["request"]["path"], raw=True)
                where += ", %s %s" % (step["request"]["method"], step["request"]["path"])
            text = sent.decode("utf-8", "replace")
            expect = step["expect"]
            if status != expect["status"]:
                problems.append("%s: status %d, not %d: %s" % (where, status, expect["status"], text[:200]))
            elif "answer" in expect:
                # The stand-in names its own address as the registry, the host
                # CYFR asks it at.
                answer = dict(expect["answer"])
                if "registry" in answer:
                    answer["registry"] = "127.0.0.1"
                if json.loads(text) != answer:
                    problems.append("%s: answered %s, not %s" % (where, text[:200], jcs(answer)))
            elif not refusal_of(sent, expect["code"]):
                problems.append("%s: refused %s, not with the code %s in every client's grammar" % (where, text[:200], expect["code"]))
        check(not problems, "names: " + scenario["name"], "\n  ".join(problems))
        standin.stop()


# Whether `sent`, an answer's bytes as sent, are the refusal `code` in the
# grammar every client reads it by (the fixture's handles comment): valid
# UTF-8, an object whose errors is a non-empty array, its first an object with
# this code and a string message, the whole in JCS's domain (no null, every
# number an integer of at most 2^53 - 1 in magnitude) and no string, key or
# value, holding an unpaired surrogate (json.loads keeps a lone \u escape as
# one).
def refusal_of(sent, code):
    try:
        envelope = json.loads(sent.decode("utf-8"))
    except ValueError:
        return False
    errors = envelope.get("errors") if isinstance(envelope, dict) else None
    first = errors[0] if isinstance(errors, list) and errors else None
    return (isinstance(first, dict) and first.get("code") == code and isinstance(first.get("message"), str)
            and jcs_value(envelope))


def jcs_value(value):
    if isinstance(value, dict):
        return all(jcs_value(k) and jcs_value(v) for k, v in value.items())
    if isinstance(value, list):
        return all(jcs_value(v) for v in value)
    if isinstance(value, str):
        return not any(0xD800 <= ord(c) <= 0xDFFF for c in value)
    if isinstance(value, bool):
        return True
    return isinstance(value, int) and abs(value) <= 2 ** 53 - 1


def grammar_checks():
    cases = [
        (b'{"errors":[{"code":"SLUG_TAKEN","message":"refused"}]}', True),
        (b'{"extra":{"ok":1},"errors":[{"code":"SLUG_TAKEN","message":"refused","x":true},7]}', True),
        (b'{"errors":[{"code":"SLUG_TAKEN","message":"\\\\ud800 \\ud83d\\ude00"}]}', True),
        (b'{"errors":[]}', False),
        (b'{"errors":[{"code":4,"message":"refused"}]}', False),
        (b'{"errors":[{"code":"SLUG_TAKEN","message":false}]}', False),
        (b'{"errors":[{"code":"OTHER","message":"refused"}]}', False),
        (b'{"errors":[{"code":"SLUG_TAKEN","message":"refused"}],"extra":null}', False),
        (b'{"errors":[{"code":"SLUG_TAKEN","message":"refused"},null]}', False),
        (b'{"errors":[{"code":"SLUG_TAKEN","message":"refused"}],"extra":9007199254740992}', False),
        (b'{"errors":[{"code":"SLUG_TAKEN","message":"refused"}],"extra":0.5}', False),
        (b'{"errors":[{"code":"SLUG_TAKEN","message":"\\ud800"}]}', False),
        (b'{"errors":[{"code":"SLUG_TAKEN","message":"\\udc00"}]}', False),
        (b'{"errors":[{"code":"SLUG_TAKEN","message":"refused"}],"\\ud800":1}', False),
        (b'{"errors":[{"code":"SLUG_TAKEN","message":"\xed\xa0\x80"}]}', False),
    ]
    for sent, read in cases:
        check(refusal_of(sent, "SLUG_TAKEN") == read, "the refusal grammar %s %s" % ("reads" if read else "refuses", sent))


# A request in the signed shape whose signature is nothing.
def unsigned(registry, operation, identifier, body):
    return {"protocol": "cyfr-registry-request/v2", "registry": registry, "operation": operation,
            "identifier": identifier, "signer": "unsigned", "nonce": "AAAAAAAAAAAAAAAAAAAAAA",
            "expires_at": int(time.time() * 1000) + 120000, "body": body, "sig": "unsigned"}


# ---- the account log's grammar ------------------------------------------------

def identity_checks():
    entries = IDENTITY["entries"]
    chains = [c for c in IDENTITY["chains"] if any("aaguid" in entries[n]["entry"] for n in c["entries"])]
    check(len(chains) >= 4, "identity.json holds the chains of a passkey's maker", [c["name"] for c in chains])
    for number, chain in enumerate(chains):
        standin = StandIn("identity-%d" % number, "--directory", IDENTITY["directory"])
        genesis, *rest = [entries[n]["entry"] for n in chain["entries"]]
        status, text, _ = standin.request("POST", "/directory/v1/register", genesis)
        identifier = json.loads(text).get("identifier") if status == 200 else None
        answers = [standin.request("POST", "/directory/v1/%s/append" % identifier, entry)[:2] for entry in rest]
        held = status == 200 and all(s == 200 for s, _ in answers[:-1])
        last_status, last_text = answers[-1]
        error = chain.get("error")
        if error is None:
            held = held and last_status == 200 and json.loads(last_text).get("result") == "accepted"
        else:
            want = {"error": "invalid", "reason": error["reason"], "field": error["field"]}
            held = held and last_status == 422 and json.loads(last_text) == want
        check(held, "identity: " + chain["name"], (status, text, answers))
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
    for method in ["POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "TRACE", "CONNECT", "PROPFIND"]:
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
    alice = "per_" + hashlib.sha256(DIRECTORY["entries"]["genesis-alice"].encode()).hexdigest()
    first.request("POST", "/directory/v1/register", genesis)
    version = json.loads(first.request("GET", "/v1/legal/version")[1])["policy_version"]
    first.request("POST", "/v1/legal/accept", request_of("policy_accept", policy_version=version))
    first.request("POST", "/v1/namespaces/personal/claim", request_of("handle_claim"))
    log = first.request("GET", "/directory/v1/" + alice)
    code = first.stop(signal.SIGTERM)
    check(code == 0, "the stand-in stops on SIGTERM", code)
    saved = json.load(open(state))
    check(saved.get("directory") == "https://dir.test" and saved.get("names") == {"alice": request_of("handle_claim")["identifier"]},
          "the state file records the directory it serves and the names", saved.get("directory"))

    second = StandIn("restart-2", "--directory", "https://dir.test", state=state)
    status, text, _ = second.request("GET", "/v1/handles/alice")
    check(status == 200 and json.loads(text)["handle"] == "alice", "a restart from the state file keeps the names", (status, text))
    again = second.request("GET", "/directory/v1/" + alice)
    check(again[:2] == log[:2], "a restart from the state file keeps the logs", (again[:2], log[:2]))
    second.stop()

    elsewhere = StandIn("restart-3", "--directory", "https://other.test", state=state)
    code = elsewhere.process.wait(timeout=10)
    check(code not in (0, None) and elsewhere.port is None,
          "a state file naming another directory refuses the start", code)


try:
    registry_checks()
    directory_checks()
    grammar_checks()
    name_checks()
    identity_checks()
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

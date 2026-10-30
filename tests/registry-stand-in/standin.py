#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The cyfr.run stand-in, a tool for the dev loop (scripts/dev-stack.sh) and
# the proofs only. It answers for cyfr.run's registry and its identity
# directory on one plain-HTTP listener, and it checks no signature on any
# registry request or directory entry: a request is read for its fields
# alone. CYFR's client verifies every chain it reads
# (Sanctum.Directory.Client, resolve/3), so honest use behaves as at
# cyfr.run. The identity and join proofs, with their real directory nodes
# (tests/identity-proof/cells.sh), keep the production directory proven.
#
#   python3 -I tests/registry-stand-in/standin.py --address A --port P \
#     --state FILE --ready-file R [--directory URL] [--upstream URL]
#
# It listens on A:P (P 0 takes a free port) and writes the port it took,
# and a line feed, to R once it serves. It stops on SIGTERM and SIGINT.
#
# The registry (the shapes of tests/fixtures/registry_wire.json):
#   GET  /v1/handles/{h}               the handle's answer, cyfr-handle/v1,
#                                      or HANDLE_NOT_FOUND
#   GET  /v1/legal/version             {"policy_version", "policies"}
#   POST /v1/legal/accept              a signed policy.accept
#   POST /v1/namespaces/personal/claim a signed handle.claim; a name another
#                                      identifier holds is SLUG_TAKEN
# A signed request carries no directory, so, as the real registry reads
# every identity at its one configured directory, every handle answer names
# the stand-in's one directory: --directory URL, else its own directory
# routes at http://A:P. The registry it names is A, the host CYFR asks.
#
# The directory (the shapes of tests/fixtures/directory_wire.json):
#   POST /directory/v1/genesis, GET /directory/v1/{identifier}?after=N,
#   POST /directory/v1/{identifier}/entries (a rotation) and
#   POST /directory/v1/{identifier}/recover (a recovery).
# An exact repeat of a write answers as the first did. It decides every
# refusal the vectors name that needs no signature: stale_head,
# request_id_reused, stale_policy, wrong_identifier, wrong_directory (a
# genesis naming another directory than its own), a body over 16 KiB
# (413) and not_found.
#
# Forwarding, for the dev loop alone: with --upstream URL a GET of a route
# it does not own goes to that URL with only Accept and User-Agent copied,
# following no redirect (an upstream 3xx answers 502). Any other method on
# a route it does not own answers 405 and goes nowhere. Without --upstream
# nothing leaves the machine.
#
# The state file holds the policy acceptances, the names, the logs and the
# recorded recoveries, written after every write, and the directory URL
# the stand-in serves under "directory", recorded when the file is made; a
# start naming another directory than the file's refuses.

import argparse
import hashlib
import http.client
import http.server
import json
import os
import re
import signal
import sys
import threading
import urllib.parse

MAX_BODY = 16_384
MAX_ENTRY = 16_384
PAGE_BYTES = 65_536 - 1_024
MAX_POSITION = 2_147_483_647
POLICY_VERSION = "stand-in-1"
PROTOCOL = "cyfr-identity/v1"
REQUEST_PROTOCOL = "cyfr-registry-request/v1"
HANDLE_PROTOCOL = "cyfr-handle/v1"
REDIRECTED = "cyfr.run answered with a redirect, which the stand-in does not follow."

IDENTIFIER = re.compile(r"^per_[0-9a-f]{64}$")
HANDLE = re.compile(r"^[a-z0-9](?:[a-z0-9]|-(?=[a-z0-9])){0,38}$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
POSITION = re.compile(r"^-?[0-9]{1,10}$")
ENVELOPE = ["body", "expires_at", "identifier", "key_epoch", "nonce", "operation", "protocol", "registry", "sig"]
GENESIS = ["protocol", "kind", "live_key", "operational_key", "recovery_keys", "directory", "revision", "sig"]
ROTATE = ["protocol", "kind", "prev", "live_key", "sig"]
RECOVER = ["protocol", "identifier", "directory", "live_key", "operational_key", "expected_revision", "request_id", "sig"]


def jcs(value):
    """The canonical JSON of a value made of objects, arrays, strings and integers."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha256(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class Refused(Exception):
    def __init__(self, status, body, raw=None):
        super().__init__(status)
        self.status, self.body, self.raw = status, body, raw


def registry_refusal(status, code, message="refused", **extra):
    return Refused(status, dict({"errors": [{"code": code, "message": message}]}, **extra))


def invalid(reason, field=None):
    body = {"error": "invalid", "reason": reason}
    if field is not None:
        body["field"] = field
    return Refused(422, body)


def fields(value, required, optional=()):
    """Exactly the required keys, and the optional ones, in Prima.Identity's
    order: the first unknown key by name, then the first missing one."""
    for key in sorted(value):
        if key not in required and key not in optional:
            raise invalid("unknown_field", key)
    for key in required:
        if key not in value:
            raise invalid("missing_field", key)


class State:
    def __init__(self, path, directory):
        self.path, self.lock = path, threading.Lock()
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                self.data = json.load(f)
            if self.data.get("directory") != directory:
                raise SystemExit(
                    "standin: %s serves the directory %s, not %s; delete it to start afresh."
                    % (path, self.data.get("directory"), directory)
                )
        else:
            self.data = {"directory": directory, "accepted": {}, "names": {}, "logs": {}}
            self.save()

    def save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.data, f, sort_keys=True, indent=1)
        os.replace(tmp, self.path)


class StandIn:
    def __init__(self, state, address, directory, upstream):
        self.state, self.address, self.directory, self.upstream = state, address, directory, upstream

    # ---- the registry -------------------------------------------------------

    def answer_for(self, handle, identifier):
        return {
            "directory": self.directory,
            "handle": handle,
            "identifier": identifier,
            "protocol": HANDLE_PROTOCOL,
            "registry": self.address,
        }

    def signed(self, raw, operation, body_keys):
        """The signed request's identifier and body, its fields checked and
        its signature not."""
        if len(raw) > MAX_BODY:
            raise registry_refusal(400, "REQUEST_MALFORMED")
        try:
            request = json.loads(raw)
        except ValueError:
            raise registry_refusal(400, "REQUEST_MALFORMED")
        if not isinstance(request, dict) or sorted(request) != ENVELOPE:
            raise registry_refusal(400, "REQUEST_MALFORMED")
        if request["protocol"] != REQUEST_PROTOCOL:
            raise registry_refusal(400, "WRONG_PROTOCOL")
        if request["operation"] != operation:
            raise registry_refusal(400, "UNKNOWN_OPERATION")
        body = request["body"]
        if not isinstance(request["identifier"], str) or not IDENTIFIER.match(request["identifier"]):
            raise registry_refusal(400, "REQUEST_MALFORMED")
        if not isinstance(body, dict) or sorted(body) != sorted(body_keys):
            raise registry_refusal(400, "REQUEST_MALFORMED")
        return request["identifier"], body

    def handle(self, handle):
        with self.state.lock:
            identifier = self.state.data["names"].get(handle)
        if identifier is None:
            raise registry_refusal(404, "HANDLE_NOT_FOUND")
        return 200, jcs(self.answer_for(handle, identifier))

    def accept(self, raw):
        identifier, body = self.signed(raw, "policy.accept", ["policy_version"])
        if body["policy_version"] != POLICY_VERSION:
            raise registry_refusal(412, "POLICY_ACCEPTANCE_REQUIRED", "accept the policy", required_version=POLICY_VERSION)
        with self.state.lock:
            self.state.data["accepted"][identifier] = POLICY_VERSION
            self.state.save()
        return 201, jcs({"identifier": identifier, "policy_version": POLICY_VERSION})

    def claim(self, raw):
        identifier, body = self.signed(raw, "handle.claim", ["handle"])
        handle = body["handle"]
        if not isinstance(handle, str) or not HANDLE.match(handle):
            raise registry_refusal(400, "INVALID_USERNAME")
        with self.state.lock:
            data = self.state.data
            if data["accepted"].get(identifier) != POLICY_VERSION:
                raise registry_refusal(412, "POLICY_ACCEPTANCE_REQUIRED", "accept the policy", required_version=POLICY_VERSION)
            holder = data["names"].get(handle)
            if holder is not None and holder != identifier:
                raise registry_refusal(409, "SLUG_TAKEN")
            if holder is None and identifier in data["names"].values():
                raise registry_refusal(409, "ALREADY_CLAIMED")
            data["names"][handle] = identifier
            self.state.save()
        return 201, jcs(self.answer_for(handle, identifier))

    # ---- the directory ------------------------------------------------------

    def entry_body(self, raw):
        if len(raw) > MAX_BODY:
            raise Refused(413, {})
        try:
            value = json.loads(raw)
        except ValueError:
            raise invalid("malformed")
        if not isinstance(value, dict):
            raise invalid("malformed")
        if len(jcs(value).encode("utf-8")) > MAX_ENTRY:
            raise invalid("too_large")
        if "protocol" not in value:
            raise invalid("missing_field", "protocol")
        if value["protocol"] != PROTOCOL:
            raise invalid("wrong_protocol")
        return value

    def entry(self, raw, kind):
        value = self.entry_body(raw)
        if "kind" not in value:
            raise invalid("missing_field", "kind")
        if value["kind"] not in ("genesis", "rotate", "recover"):
            raise invalid("unknown_kind")
        if value["kind"] != kind:
            raise invalid("not_" + kind)
        if kind == "genesis":
            fields(value, GENESIS)
            if not isinstance(value["directory"], str):
                raise invalid("invalid_field", "directory")
            if value["revision"] != 0 or isinstance(value["revision"], bool):
                raise invalid("invalid_field", "revision")
        else:
            fields(value, ROTATE)
            if not isinstance(value["prev"], str) or not DIGEST.match(value["prev"]):
                raise invalid("invalid_field", "prev")
        return value

    def log(self, identifier):
        log = self.state.data["logs"].get(identifier) if IDENTIFIER.match(identifier) else None
        if log is None:
            raise Refused(404, {"error": "not_found"})
        return log

    @staticmethod
    def accepted(identifier, log, seq, with_entry=False):
        body = '{"entry_hash":%s,"identifier":%s,"seq":%d' % (
            json.dumps(log["hashes"][seq]),
            json.dumps(identifier),
            seq,
        )
        if with_entry:
            body += ',"entry":' + log["entries"][seq]
        return 200, body + "}"

    def genesis(self, raw):
        genesis = self.entry(raw, "genesis")
        if genesis["directory"] != self.directory:
            raise Refused(422, {"error": "wrong_directory"})
        canonical = jcs(genesis)
        digest = sha256(canonical)
        identifier = "per_" + digest
        with self.state.lock:
            logs = self.state.data["logs"]
            if identifier not in logs:
                logs[identifier] = {
                    "entries": [canonical],
                    "hashes": ["sha256:" + digest],
                    "revision": 0,
                    "directory": genesis["directory"],
                    "requests": {},
                }
                self.state.save()
            return self.accepted(identifier, logs[identifier], 0)

    def rotate(self, identifier, raw):
        with self.state.lock:
            log = self.log(identifier)
            rotation = self.entry(raw, "rotate")
            canonical = jcs(rotation)
            entry_hash = "sha256:" + sha256(canonical)
            head = log["hashes"][-1]
            # An exact retry of the head answers as the first append did.
            if entry_hash == head:
                return self.accepted(identifier, log, len(log["hashes"]) - 1)
            if rotation["prev"] != head:
                raise Refused(409, {"error": "stale_head", "head": head})
            log["entries"].append(canonical)
            log["hashes"].append(entry_hash)
            self.state.save()
            return self.accepted(identifier, log, len(log["hashes"]) - 1)

    def recover(self, identifier, raw):
        with self.state.lock:
            log = self.log(identifier)
            request = self.entry_body(raw)
            fields(request, RECOVER, ["recovery_keys"])
            if not isinstance(request["expected_revision"], int) or isinstance(request["expected_revision"], bool) \
                    or request["expected_revision"] < 0:
                raise invalid("invalid_field", "expected_revision")
            if not isinstance(request["request_id"], str) or not request["request_id"]:
                raise invalid("invalid_field", "request_id")
            if request["identifier"] != identifier:
                raise Refused(422, {"error": "wrong_identifier"})
            digest = sha256(jcs(request))
            recorded = log["requests"].get(request["request_id"])
            if recorded is not None:
                if recorded["digest"] != digest:
                    raise Refused(409, {"error": "request_id_reused"})
                if recorded["outcome"] == "accepted":
                    return self.accepted(identifier, log, recorded["seq"], with_entry=True)
                raise Refused(409, {"error": "stale_policy", "recorded": recorded["body"]})
            if request["directory"] != log["directory"]:
                raise Refused(422, {"error": "unverified", "reason": "directory_changed"})
            expected, revision = request["expected_revision"], log["revision"]
            if expected > revision:
                raise Refused(422, {"error": "unverified", "reason": "stale_revision"})
            if expected < revision:
                body = {"outcome": "stale_policy", "expected_revision": expected, "revision": revision}
                log["requests"][request["request_id"]] = {"digest": digest, "outcome": "stale_policy", "body": body}
                self.state.save()
                raise Refused(409, {"error": "stale_policy", "recorded": body})
            entry = jcs({"protocol": PROTOCOL, "kind": "recover", "prev": log["hashes"][-1], "request": request})
            log["entries"].append(entry)
            log["hashes"].append("sha256:" + sha256(entry))
            log["revision"] = revision + 1
            seq = len(log["hashes"]) - 1
            log["requests"][request["request_id"]] = {"digest": digest, "outcome": "accepted", "seq": seq}
            self.state.save()
            return self.accepted(identifier, log, seq, with_entry=True)

    def page(self, identifier, query):
        after = query.get("after", ["-1"])
        if len(after) != 1 or not POSITION.match(after[0]) or not -1 <= int(after[0]) <= MAX_POSITION:
            raise invalid("invalid_field", "after")
        after = int(after[0])
        with self.state.lock:
            log = self.log(identifier)
            entries, used = [], 0
            for entry in log["entries"][after + 1:]:
                size = len(entry.encode("utf-8")) + 1
                if entries and used + size > PAGE_BYTES:
                    break
                entries.append(entry)
                used += size
            last = after + len(entries)
            head_seq = len(log["hashes"]) - 1
            body = '{"entries":[%s],"from":%d,"head":%s,"identifier":%s,"length":%d,"next":%s}' % (
                ",".join(entries),
                after + 1,
                json.dumps(log["hashes"][-1]),
                json.dumps(identifier),
                head_seq + 1,
                json.dumps(last if last < head_seq else None),
            )
        return 200, body

    # ---- routing ------------------------------------------------------------

    def route(self, method, path, query, read_body):
        """The answer of an owned route, (status, text); None for a route
        the stand-in does not own; Refused for a method an owned route does
        not take."""
        parts = path.split("/")[1:]
        routes = {
            ("v1", "legal", "version"): ("GET", lambda: (200, jcs({"policies": [], "policy_version": POLICY_VERSION}))),
            ("v1", "legal", "accept"): ("POST", lambda: self.accept(read_body())),
            ("v1", "namespaces", "personal", "claim"): ("POST", lambda: self.claim(read_body())),
            ("directory", "v1", "genesis"): ("POST", lambda: self.genesis(read_body())),
        }
        owned = routes.get(tuple(parts))
        if owned is None and len(parts) == 3 and parts[:2] == ["v1", "handles"]:
            owned = ("GET", lambda: self.handle(parts[2]))
        if owned is None and len(parts) == 3 and parts[:2] == ["directory", "v1"] and parts[2] != "genesis":
            owned = ("GET", lambda: self.page(parts[2], query))
        if owned is None and len(parts) == 4 and parts[:2] == ["directory", "v1"] and parts[3] == "entries":
            owned = ("POST", lambda: self.rotate(parts[2], read_body()))
        if owned is None and len(parts) == 4 and parts[:2] == ["directory", "v1"] and parts[3] == "recover":
            owned = ("POST", lambda: self.recover(parts[2], read_body()))
        if owned is None:
            return None
        if method != owned[0]:
            raise Refused(405, {"error": "method_not_allowed"})
        return owned[1]()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    server_version = "cyfr-run-stand-in"
    sys_version = ""

    def log_message(self, format, *args):
        sys.stderr.write("standin: %s %s\n" % (self.address_string(), format % args))

    def send(self, status, text, content_type="application/json", allow=None):
        data = text.encode("utf-8") if isinstance(text, str) else text
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        if allow:
            self.send_header("Allow", allow)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            # Read past the bound only so far as the refusal needs: the
            # answer closes the connection.
            return b"x" * (MAX_BODY + 1)
        return self.rfile.read(length)

    def dispatch(self):
        stand_in = self.server.stand_in
        url = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(url.query, keep_blank_values=True)
        try:
            answer = stand_in.route(self.command, url.path, query, lambda: self.read_body().decode("utf-8", "replace"))
        except Refused as refused:
            if refused.status == 413:
                return self.send(413, "request body too large", "text/plain")
            text = jcs(refused.body)
            if "errors" in refused.body:
                text += "\n"
            return self.send(refused.status, text)
        if answer is not None:
            return self.send(*answer)
        if self.command != "GET":
            return self.send(405, jcs({"error": "method_not_allowed"}), allow="GET")
        if stand_in.upstream is None:
            return self.send(404, jcs({"error": "not_found"}))
        self.forward(stand_in.upstream, url)

    def forward(self, upstream, url):
        target = urllib.parse.urlsplit(upstream)
        path = (target.path.rstrip("/") + url.path) + ("?" + url.query if url.query else "")
        connection_class = http.client.HTTPSConnection if target.scheme == "https" else http.client.HTTPConnection
        connection = connection_class(target.hostname, target.port, timeout=30)
        try:
            connection.putrequest("GET", path, skip_accept_encoding=True)
            for name in ("Accept", "User-Agent"):
                value = self.headers.get(name)
                if value is not None:
                    connection.putheader(name, value)
            connection.endheaders()
            response = connection.getresponse()
            body = response.read()
        except OSError:
            return self.send(502, "cyfr.run did not answer.", "text/plain")
        finally:
            connection.close()
        if 300 <= response.status < 400:
            return self.send(502, REDIRECTED, "text/plain")
        self.send(response.status, body, response.getheader("Content-Type") or "application/octet-stream")

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = dispatch


def main(argv):
    parser = argparse.ArgumentParser(description="The cyfr.run stand-in for the dev loop and the proofs.")
    parser.add_argument("--address", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--directory")
    parser.add_argument("--upstream")
    args = parser.parse_args(argv)

    server = http.server.ThreadingHTTPServer((args.address, args.port), Handler)
    server.daemon_threads = True
    port = server.server_address[1]
    directory = args.directory or "http://%s:%d" % (args.address, port)
    state = State(args.state, directory)
    server.stand_in = StandIn(state, args.address, directory, args.upstream)

    def stop(_signum, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    tmp = args.ready_file + ".tmp"
    with open(tmp, "w") as f:
        f.write("%d\n" % port)
    os.replace(tmp, args.ready_file)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main(sys.argv[1:])

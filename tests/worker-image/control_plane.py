# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""CYFR's host API as the worker image tests script it: the host routes
`Cyfr.WorkerWire` names, served on the host machine where the container
reaches them as `host.docker.internal`, each request verified as CYFR
verifies it (`Cyfr.WorkerAuth`: a runner's call under the attempt's call
key, its sealed body opened and its answer sealed back; a worker service's
plain report under the service's dispatch key) under the tests' own root,
recorded with its time, and answered from a script.

`mint` makes an attempt as CYFR would — its keys, a signed assignment, the
keys sealed for the worker service, the artifact the runner fetches by the
assignment's digest and the vault fields its attach answers — and `start`,
`kill` and `status` post `Cyfr.WorkerAPI` requests to the service signed
with its dispatch key. `script` sets what an operation answers for one
execution or for all: a value the runner reads as `{"ok": value}`, a
refusal, `DROP` (a 500 with no body: an answer that never arrives, which
the runner's client counts as lost) or a function of the request that
answers any of those. `stop` closes the listener and the connections its
clients keep alive, so the next call is refused at the socket, and `serve`
opens it again on the same port.
"""

import base64
import http.server
import json
import socket
import threading
import time
import urllib.error
import urllib.request

import worker_auth as auth

DROP = object()
LEASE_MS = 60_000
# The authority every minted assignment carries: `Cyfr.Authority.zero/0` as
# `tests/fixtures/worker_auth.json` spells it on the wire.
ZERO_AUTHORITY = {
    "activation": {},
    "budget": {"id": "bgt_AAAAAAAAAAHKmY6r"},
    "chain": [],
    "cursor": "unbound",
    "depth": 0,
    "invoke_mode": "open_inert",
}
ACTOR = {"authenticated": True, "user_id": "usr_worker_image_test"}


class Refused(Exception):
    pass


class ControlPlane:
    def __init__(self, root, service, generation=1, port=0):
        self.root = root
        self.service = service
        self.generation = generation
        self.worker_key = auth.worker_key(root, service)
        self.dispatch_key = auth.dispatch_key(self.worker_key)
        self.dispatch_seal_key = auth.dispatch_seal_key(self.worker_key)
        self.boot = auth.new_id("boot")  # CYFR's own boot, as its requests present it
        self.port = port
        self.lock = threading.Condition()
        self.requests = []
        self.scripts = {}
        self.artifacts = {}
        self.secrets = {}
        self.connections = set()
        self.server = None
        self.thread = None
        self.epoch = time.monotonic()

    # ------------------------------------------------------------------
    # Serving
    # ------------------------------------------------------------------

    def serve(self):
        plane = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def setup(self):
                super().setup()
                with plane.lock:
                    plane.connections.add(self.connection)

            def finish(self):
                with plane.lock:
                    plane.connections.discard(self.connection)
                try:
                    super().finish()
                except OSError:
                    pass

            def do_POST(self):
                plane.handle(self)

        class Server(http.server.ThreadingHTTPServer):
            daemon_threads = True
            allow_reuse_address = True

        self.server = Server(("0.0.0.0", self.port), Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()
        return self

    def stop(self):
        """Close the listener and every connection a client keeps alive: every
        later call is refused at the socket, as when CYFR is gone."""
        server, self.server = self.server, None
        if server:
            server.shutdown()
            server.server_close()
            self.thread.join(5)
        with self.lock:
            connections, self.connections = list(self.connections), set()
        for connection in connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    @property
    def container_url(self):
        return f"http://host.docker.internal:{self.port}"

    def elapsed(self):
        return time.monotonic() - self.epoch

    # ------------------------------------------------------------------
    # Scripting and recording
    # ------------------------------------------------------------------

    def script(self, op, answer, execution_id=None):
        """What `op` answers: for `execution_id`'s calls, or for every call when None."""
        with self.lock:
            self.scripts[(op, execution_id)] = answer

    def unscript(self, op, execution_id=None):
        with self.lock:
            self.scripts.pop((op, execution_id), None)

    def seen(self, op=None, execution_id=None):
        """The recorded requests, oldest first, filtered by op and execution."""
        with self.lock:
            out = list(self.requests)
        return [
            r
            for r in out
            if (op is None or r["op"] == op)
            and (execution_id is None or r.get("execution_id") == execution_id)
        ]

    def wait_for(self, predicate, timeout, what):
        deadline = time.monotonic() + timeout
        with self.lock:
            while True:
                value = predicate()
                if value:
                    return value
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"timed out waiting for {what}")
                self.lock.wait(min(remaining, 0.25))

    def wait_seen(self, op, execution_id, timeout, count=1):
        """At least `count` requests of `op`, each answered (or held by its script): a request is recorded before its answer is."""

        def settled():
            seen = self.seen(op, execution_id)
            return len(seen) >= count and all("answered" in r or "held" in r for r in seen) and seen

        return self.wait_for(settled, timeout, f"{count} {op} of {execution_id}")

    def record(self, entry):
        entry["t"] = self.elapsed()
        entry["at"] = time.time()
        with self.lock:
            self.requests.append(entry)
            self.lock.notify_all()

    # ------------------------------------------------------------------
    # One request
    # ------------------------------------------------------------------

    def handle(self, handler):
        now = auth.now_ms()
        path = handler.path
        length = int(handler.headers.get("content-length") or 0)
        body = handler.rfile.read(length) if length else b""
        header = handler.headers.get("x-cyfr-auth")
        op = path[len("/host/v1/") :] if path.startswith("/host/v1/") else None
        if op is None:
            return self.answer_plain(handler, 404, {"error": "not_found"})

        if op == "runner_exited":
            report, refusal = auth.verify_report(self.root, header, body, now)
            if refusal:
                self.record({"op": op, "refused": refusal})
                return self.answer_plain(handler, 401, {"error": "lost"})
            args = self.args(body, op)
            entry = {"op": op, "report": report, "args": args, "attempts": args.get("attempts", [])}
            self.record(entry)
            answer = self.encode(self.answer_for(op, args, report, entry))
            entry["answered"] = "ok" if "ok" in answer else answer.get("error")
            entry["answered_t"] = self.elapsed()
            return self.answer_plain(handler, 200, answer)

        call, refusal = auth.verify_host_call(self.root, header, body, now, self.generation)
        if refusal:
            self.record({"op": op, "refused": refusal})
            return self.answer_plain(handler, 401, {"error": "lost"})
        seal_key = auth.attempt_seal_key(self.root, call)
        plain = auth.open_call(seal_key, "body", call, body.decode())
        if plain is None:
            self.record({"op": op, "refused": "unsealable", "execution_id": call["execution_id"]})
            return self.answer_plain(handler, 401, {"error": "lost"})
        args = self.args(plain, op)
        entry = {"op": op, "caller": call, "args": args, "execution_id": call["execution_id"], "runner": call["runner"]}
        self.record(entry)
        answer = self.answer_for(op, args, call, entry)
        if answer is DROP:
            entry["answered"] = "dropped"
            handler.send_response(500)
            handler.send_header("content-length", "0")
            handler.end_headers()
            return None
        encoded = json.dumps(self.encode(answer), separators=(",", ":")).encode()
        sealed = auth.seal_call(seal_key, "answer", call, encoded).encode()
        entry["answered"] = "ok" if "ok" in self.encode(answer) else self.encode(answer).get("error")
        entry["answered_t"] = self.elapsed()
        try:
            handler.send_response(200)
            handler.send_header("content-type", "application/json")
            handler.send_header("content-length", str(len(sealed)))
            handler.end_headers()
            handler.wfile.write(sealed)
            handler.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError) as error:
            entry["answered"] = f"unread: {type(error).__name__}"
        return None

    @staticmethod
    def args(body, op):
        try:
            decoded = json.loads(body)
        except ValueError:
            return {}
        if decoded.get("op") != op or not isinstance(decoded.get("args"), dict):
            return {}
        return decoded["args"]

    def answer_for(self, op, args, caller, entry):
        with self.lock:
            scripted = self.scripts.get((op, entry.get("execution_id")), self.scripts.get((op, None)))
        if callable(scripted):
            return scripted(args, caller, entry)
        if scripted is not None:
            return scripted
        return self.default(op, args, caller)

    def default(self, op, args, caller):
        if op == "attach":
            return {"ok": self.secrets.get(caller["execution_id"], {})}
        if op == "renew":
            until = auth.now_ms() + LEASE_MS
            return {"ok": {attempt: {"lease_until": until} for attempt in args.get("attempts", [])}}
        if op == "push_deltas":
            return {"ok": [json.dumps({"ok": True}) for _ in args.get("deltas", [])]}
        if op == "complete":
            return {"ok": args.get("outcome", {}).get("output")}
        if op == "fail":
            return {"ok": args.get("outcome", {}).get("error", "")}
        if op == "fetch_artifact":
            bytes_ = self.artifacts.get(args.get("digest"))
            if bytes_ is None:
                return {"error": "not_found"}
            return {"ok": base64.b64encode(bytes_).decode()}
        if op in ("take_rate", "record_denial", "release_child", "runner_exited"):
            return {"ok": True}
        return {"error": "guest_error", "type": "dispatch_error", "message": "The scripted control plane has no answer for this call."}

    @staticmethod
    def encode(answer):
        return answer if isinstance(answer, dict) else {"ok": answer}

    @staticmethod
    def answer_plain(handler, status, answer):
        encoded = json.dumps(answer, separators=(",", ":")).encode()
        try:
            handler.send_response(status)
            handler.send_header("content-type", "application/json")
            handler.send_header("content-length", str(len(encoded)))
            handler.end_headers()
            handler.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    # ------------------------------------------------------------------
    # Minting
    # ------------------------------------------------------------------

    def mint(self, boot, component_type, ref, wasm, input_, athanor_id, timeout_ms, intercepted=(), secrets=None, parent=None, lease_ms=LEASE_MS, authority=None):
        """An attempt on this control plane, as CYFR mints one for the worker service on `boot`, under `authority` (the zero authority when None)."""
        now = auth.now_ms()
        execution_id = auth.new_id("exec")
        attempt_id = auth.new_id("att")
        input_json = json.dumps(input_, separators=(",", ":"))
        artifact_digest = auth.digest(wasm)
        attempt = {
            "athanor_id": athanor_id,
            "execution_id": execution_id,
            "attempt": attempt_id,
            "fence": 1,
            "generation": self.generation,
            "service": self.service,
        }
        wire = {
            "v": 1,
            "generation": self.generation,
            "service": self.service,
            "boot": boot,
            "issued_at": now,
            "claim_by": now + auth.CLAIM_WINDOW_MS,
            "execution_id": execution_id,
            "attempt": attempt_id,
            "fence": 1,
            "root_execution_id": parent["root_execution_id"] if parent else execution_id,
            "athanor_id": athanor_id,
            "actor": ACTOR,
            "authority": authority or ZERO_AUTHORITY,
            "component": {"ref": ref, "type": component_type, "digest": artifact_digest, "declared_needs": []},
            "input_digest": auth.digest(input_json.encode()),
            "timeout_ms": timeout_ms,
            "deadline": now + timeout_ms,
            "lease_until": now + lease_ms,
            "intercepted": list(intercepted),
        }
        if parent:
            wire["parent_execution_id"] = parent["execution_id"]
        call_key = auth.attempt_call_key(self.root, attempt)
        seal_key = auth.attempt_seal_key(self.root, attempt)
        token = auth.sign_assignment(wire, auth.assign_key(self.root))
        sealed = auth.seal_attempt_keys(self.dispatch_seal_key, attempt, call_key, seal_key)
        self.artifacts[artifact_digest] = wasm
        if secrets:
            self.secrets[execution_id] = dict(secrets)
        return {
            **attempt,
            "boot": boot,
            "token": token,
            "sealed_keys": sealed,
            "input": input_json,
            "digest": artifact_digest,
            "issued_at": now,
            "deadline": wire["deadline"],
            "lease_until": wire["lease_until"],
            "timeout_ms": timeout_ms,
            "call_key": call_key,
            "seal_key": seal_key,
            "root_execution_id": wire["root_execution_id"],
        }

    def child_answer(self, child):
        """The `admit_child` answer for a minted `child`: its assignment, its keys sealed with the parent's seal key, its input and no secrets."""

        def answer(args, caller, entry):
            parent_seal = auth.attempt_seal_key(self.root, caller)
            sealed = auth.seal_attempt_keys(parent_seal, child, child["call_key"], child["seal_key"])
            return {"ok": {"assignment": child["token"], "attempt_keys": sealed, "input": child["input"], "secrets": {}}}

        return answer

    # ------------------------------------------------------------------
    # The worker service's requests
    # ------------------------------------------------------------------

    def request(self, base_url, op, args, timeout=35):
        body = json.dumps({"op": op, "args": args}, separators=(",", ":")).encode()
        fields = {"service": self.service, "boot": self.boot, "ts": auth.now_ms(), "nonce": auth.nonce()}
        header = auth.request_header(self.dispatch_key, fields, body)
        request = urllib.request.Request(
            f"{base_url}/worker/v1/{op}",
            data=body,
            method="POST",
            headers={"x-cyfr-auth": header, "content-type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                return error.code, json.loads(raw)
            except ValueError:
                return error.code, {"raw": raw.decode(errors="replace")}
        except (urllib.error.URLError, socket.timeout, OSError) as error:
            return None, {"unreachable": str(error)}

    def status(self, base_url):
        return self.request(base_url, "status", {}, timeout=10)

    def start(self, base_url, attempt):
        return self.request(base_url, "start", {"assignment": attempt["token"], "input": attempt["input"], "sealed_keys": attempt["sealed_keys"]})

    def kill(self, base_url, execution_id):
        return self.request(base_url, "kill", {"execution_id": execution_id}, timeout=10)

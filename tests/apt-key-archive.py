#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# A stand-in for Debian's archive on 127.0.0.1, which tests/apt-key-test.sh
# points scripts/apt-key.sh at through APT_KEY_MIRROR:
#   python3 -I tests/apt-key-archive.py STATE_DIR RELEASE_DIR
#
# It writes the port it listens on to STATE_DIR/port once it listens. Each
# request for a suite's InRelease gets the next word of STATE_DIR/answers,
# the last one repeated: release (RELEASE_DIR/<suite>.InRelease), redirect
# (a 302 to that file under /cdn/, as Debian's mirror redirects to its
# delivery network), page (a 200 with a page that is no release file) or
# fail (a 503). Every path asked is appended to STATE_DIR/log.
import http.server
import os
import sys

state, releases = sys.argv[1], sys.argv[2]
SUITES = {
    "/debian/dists/trixie/InRelease": "trixie",
    "/debian/dists/trixie-updates/InRelease": "trixie-updates",
    "/debian-security/dists/trixie-security/InRelease": "trixie-security",
}


def release(suite):
    with open(os.path.join(releases, suite + ".InRelease"), "rb") as f:
        return f.read()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, code, body, headers=()):
        self.send_response(code)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        with open(os.path.join(state, "log"), "a") as log:
            log.write(self.path + "\n")
        if self.path.startswith("/cdn/") and self.path[len("/cdn/") :] in SUITES.values():
            return self.answer(200, release(self.path[len("/cdn/") :]))
        suite = SUITES.get(self.path)
        if suite is None:
            return self.answer(404, b"not found")
        with open(os.path.join(state, "answers")) as f:
            answers = f.read().split()
        with open(os.path.join(state, "asked"), "a+") as f:
            f.seek(0)
            n = len(f.read().splitlines())
            f.write(self.path + "\n")
        word = answers[min(n, len(answers) - 1)]
        if word == "release":
            return self.answer(200, release(suite))
        if word == "redirect":
            return self.answer(
                302, b"<html><body>302 Found</body></html>", [("Location", "/cdn/" + suite), ("Content-Type", "text/html")]
            )
        if word == "page":
            return self.answer(200, b"<html><body>Service notice</body></html>", [("Content-Type", "text/html")])
        return self.answer(503, b"busy")


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(state, "port.tmp"), "w") as f:
    f.write(str(server.server_address[1]))
os.rename(os.path.join(state, "port.tmp"), os.path.join(state, "port"))
server.serve_forever()

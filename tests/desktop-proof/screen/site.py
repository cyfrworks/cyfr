# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The idle proof's pages (idle.sh): one that plays nothing, one that plays
video with sound at a tap, and one whose sandboxed frame does. A page
names where it stands in its title, which is the window's: waiting for
its tap, tapped, then ready once it has played for long enough for the
engine to take its idle inhibitor."""

import http.server

PLAY = """
async function play() {
  const c = document.createElement("canvas"); c.width = 640; c.height = 360
  const g = c.getContext("2d"); let n = 0
  setInterval(() => { g.fillStyle = n++ % 2 ? "red" : "blue"; g.fillRect(0, 0, 640, 360) }, 100)
  const a = new AudioContext(), o = a.createOscillator(), d = a.createMediaStreamDestination()
  o.connect(d); o.start(); await a.resume()
  const v = document.querySelector("video")
  v.srcObject = new MediaStream([...c.captureStream(10).getTracks(), ...d.stream.getTracks()])
  await v.play()
  await new Promise((done) => setTimeout(done, 3000))
}
"""

VIDEO = "<video width=640 height=360></video>"


def document_of(title, script, body=""):
    return (f"<!doctype html><title>{title}</title><body style='margin:0;height:100vh'>{body}"
            f"<script>{script}</script>").encode()


def say(case, stand):
    return f'document.title = "cyfr-proof-{case}-{stand}"'


PAGES = {
    "/still": (document_of("cyfr-proof-still-waiting",
                           "addEventListener('click', () => { " + say("still", "tapped") +
                           "; setTimeout(() => { " + say("still", "ready") + " }, 3000) }, {once: true})"), None),
    "/page": (document_of("cyfr-proof-page-waiting",
                          PLAY + "addEventListener('click', () => { " + say("page", "tapped") +
                          "; play().then(() => { " + say("page", "ready") + " }) }, {once: true})", VIDEO), None),
    "/frame": (document_of("cyfr-proof-frame-loading",
                           "addEventListener('message', (e) => { if (e.origin === 'null' && "
                           "['waiting', 'tapped', 'ready'].includes(e.data)) document.title = 'cyfr-proof-frame-' + e.data })",
                           '<iframe src="/app" sandbox="allow-scripts" '
                           'style="border:0;width:100%;height:100vh"></iframe>'), None),
    "/app": (document_of("app",
                         PLAY + "parent.postMessage('waiting', '*'); addEventListener('click', () => { "
                         "parent.postMessage('tapped', '*'); play().then(() => parent.postMessage('ready', '*')) }, {once: true})",
                         VIDEO),
             "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; sandbox allow-scripts"),
}


class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body, policy = PAGES.get(self.path, (None, None))
        self.send_response(200 if body else 404)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        if policy:
            self.send_header("Content-Security-Policy", policy)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Pages)
print(f"http://127.0.0.1:{server.server_address[1]}", flush=True)
server.serve_forever()

# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The idle proof's pages (idle.sh): one that plays nothing, one that plays
video at a tap and stops at the next, and one whose sandboxed
frame does. A page names where it stands in its title, which is the
window's: waiting for its tap, started, then stopped."""

import http.server

PLAY = """
const video = () => document.querySelector("video")
async function play() {
  const c = document.createElement("canvas"); c.width = 640; c.height = 360
  const g = c.getContext("2d"); let n = 0
  setInterval(() => { g.fillStyle = n++ % 2 ? "red" : "blue"; g.fillRect(0, 0, 640, 360) }, 100)
  const a = new AudioContext(), o = a.createOscillator(), d = a.createMediaStreamDestination()
  o.connect(d); o.start(); await a.resume()
  video().srcObject = new MediaStream([...c.captureStream(10).getTracks(), ...d.stream.getTracks()])
  await video().play()
}
// The first tap starts the playback and the next ends it.
function taps(tell) {
  let began = false, playing = false
  addEventListener("click", async () => {
    if (playing) { playing = false; video().pause(); return tell("stopped") }
    if (began) return
    began = true
    await play()
    playing = true
    tell("started")
  })
}
"""

VIDEO = "<video width=640 height=360></video>"


def document_of(title, script, body=""):
    return (f"<!doctype html><title>{title}</title><body style='margin:0;height:100vh'>{body}"
            f"<script>{script}</script>").encode()


PAGES = {
    "/still": (document_of("cyfr-proof-still-waiting",
                           "addEventListener('click', () => { document.title = 'cyfr-proof-still-started' })"), None),
    "/page": (document_of("cyfr-proof-page-waiting",
                          PLAY + "taps((stand) => { document.title = 'cyfr-proof-page-' + stand })", VIDEO), None),
    "/frame": (document_of("cyfr-proof-frame-loading",
                           "addEventListener('message', (e) => { if (e.origin === 'null' && "
                           "['waiting', 'started', 'stopped'].includes(e.data)) document.title = 'cyfr-proof-frame-' + e.data })",
                           '<iframe src="/app" sandbox="allow-scripts" '
                           'style="border:0;width:100%;height:100vh"></iframe>'), None),
    "/app": (document_of("app",
                         PLAY + "taps((stand) => parent.postMessage(stand, '*')); parent.postMessage('waiting', '*')",
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

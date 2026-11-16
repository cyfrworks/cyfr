#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Aqua's browser in the backends image: cyfr-browser driving a Chrome it fetches into its kept home, framed over its terminal.

Run as docker-compose.yml's locus-backends service, driven only by requests
signed as CYFR signs them (harness.py). The browser is a kept program whose
command is cyfr-browser, opened as a terminal session in its kept home, as
the person's browser row is; this suite stands in for its one host,
Opus.Browser, speaking the driver's framing from its vector file,
tests/fixtures/browser_frames.json, whose cases it reproduces before any
container starts:

- The first exchange: the driver says hello once Chrome answers; a put of
  a page of about a megabyte of html and a `read` whose text is over a megabyte
  arrive whole, in numbered chunks, every chunk acknowledged and every
  frame's digest checked.
- With the host not acknowledging, the driver's output stops after the one
  unacknowledged chunk, and nothing is lost once the host acknowledges.
- A forced tail: the host acknowledges chunks blindly while the driver
  pours a response out, then keeps only the last 256 KiB of what the
  session printed, as Opus.Programs.Terminal hands a replacement tail; it
  takes no cut frame as whole, asks `again` from the first chunk it lacks,
  and gets the response whole. A driver started with a short --keep-ms
  answers `gone` for a response asked for again after that time, and for an
  id it never had.
- A cast (C12) over the same session: a window's images one at a time, the
  next only after the host's `seen`; with the host not acknowledging an
  image, no further one comes and a read of over a megabyte still arrives
  whole; a forced tail while the cast and a poured response share the
  output takes no cut image or chunk as whole, wherever it cuts (a header,
  an image's body, a chunk), and once the host ends the cast and asks for
  another, and asks the response again, the cast goes on and the response
  arrives whole; the person's mouse and keys land at the place of the image
  they point at, at a phone's width and at 720p alike, and nowhere else.
- Each operation once: open (a public page unless CYFR_TEST_OFFLINE=1, an
  address the guard refuses, and an address of another scheme), five
  failed opens that leave no window, page (a put of one file),
  read, click (a button whose click changes the page, seen by the next
  read), type, key, screenshot (a PNG that decodes) and close, with the
  errors no_window, bad_ref and bad_key.
- Pages put into the Chrome (C15), in a session that logs Chrome's
  network: a put of several files, handed over in parts as Opus.Browser
  hands it, loads under the reserved origin, its entry, a classic script,
  a module and its import, a stylesheet, a WebAssembly file, an image and
  a frame's file each answered by the driver from the put; the page is a
  secure context; its POSTs to invoke and action arrive as calls with
  their bodies' bytes in base64, named by their window, and the host's
  answers are the page's; a frame of the reserved origin inside the page
  calls, and a frame of another origin (data:) does not; a socket and an
  event stream fail and the page goes on; a service worker's registration
  is refused; a dedicated worker is delivered its window's files and makes
  no call, nor does a shared worker; a page of one file loads the same
  way; a window the driver did not put, of the page's own origin, opened
  by the person's click, makes no call; a window with no put is answered
  nothing for the reserved origin; a plain page with no head tag, handed
  as the host hands it (the vector file's plain_entry), has window.cyfr
  and loads a file named relative to its <base>; a put past its bound in
  bytes or files is refused; and over the session nothing left the box, no
  file the driver answered reached Chrome's network stack, and Chrome
  never asked a resolver for the reserved name.
- Another program in another kept home, under another uid, cannot read the
  browser's profile, nothing of the browser's uid listens on a TCP port,
  and Chrome runs on its debugging pipe with no debugging port.
- A driver whose Chrome cannot start says hello with an error and exits 1.
- Chrome reaches nothing by itself: its own network log over a start with
  nothing asked shows no URL requested, no host resolved and no connection.
- Its Chrome is fetched as a program fetches itself, and the image holds
  none: the first start in a fresh home fetches Chrome for Testing's
  current stable from Google and runs it, published whole in one version
  folder; a restart reuses it and fetches nothing; with a source that
  cannot be reached a home that holds no Chrome refuses in one sentence
  and one that holds a Chrome starts it; a truncated archive is never
  published; and the home holds one Chrome and its profile well within
  its 2 GiB bound, with room for a second being staged.

It prints, without gating, Chrome's memory with one, three and six windows
(the summed PSS of its processes and the session cgroup's memory.current),
the time and frame count of the megabyte read, puts of one, eight and
thirty-two MiB handed over the session and the time their largest file is
answered whole in, what a shared worker and srcdoc and sandboxed frames
saw, the first start's time and
the home's bytes, and, at a phone's width (390 by 844) and at 720p, a
cast's images a second on a page that changes every frame, their size, and
the delay from a press to the first image that shows it.

With --first-start it proves one thing alone, for an image of another
architecture, which the release workflow's arm64 job starts: a first start
fetches this machine's Chrome, built for its architecture, and a public
page loads in it.

Prerequisites: harness.py's, and the public network, from which the first
start fetches Chrome. Usage: tests/locus-backends-image/browser.py [--first-start] IMAGE
"""

import base64
import hashlib
import json
import os
import struct
import sys
import time
import zlib

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    BOUNDS, KEPT_FIRST, KEPT_LAST, KEPT_ROOT, PORT, ROOT, Stack, eventually, expect, owner_of, probe,
    require_docker, unb64,
)
import imagesuite  # noqa: E402

with open(os.path.join(ROOT, "tests", "fixtures", "browser_frames.json"), encoding="utf-8") as _frames:
    FRAMES = json.load(_frames)

START = FRAMES["start"].encode()
HEADER_BYTES = len(START) + 8 + 16
MAX_TO_HOST = FRAMES["max_to_host"]
MAX_TO_DRIVER = FRAMES["max_to_driver"]
# The tail Opus.Programs.Terminal hands in place of what it held when more
# came meanwhile than it keeps.
TAIL_BYTES = 256 * 1024
# The bytes one terminal input carries at most.
INPUT_BYTES = BOUNDS["max_chunk_bytes"]
# A put's bound and the bytes one part carries, and a call's body's bound.
PUT = FRAMES["put"]
CALL = FRAMES["call"]
# Where a put's files sit: the reserved origin, under a public tincture's address.
RESERVED = "https://cyfr.invalid"
ATHANOR = "ath_browser"


def root_of(name):
    return f"/t/{ATHANOR}/local/{name}"

OWNER = owner_of("browser")
# The browser's home is named as a real row's is, mcp_ and a UUID: Chrome's
# profile lock is a socket in its temporary folder, and a home this long
# leaves no room for it there unless the driver names that folder short.
BROWSER_HOME = "mcp_01890000-0000-7000-8000-00000000b005"
FETCHLESS_HOME, BROKEN_HOME, OTHER_HOME = (f"mcp_browser-{name}" for name in ("fetchless", "broken", "other"))
# The bound Opus.Programs.Definition.browser/1 gives the browser's home.
HOME_MAX_BYTES = 2 << 30
PROGRAMS = [
    {"name": "browser", "command": "cyfr-browser", "env": {}, "home": "kept", "memory_bytes": 1536 << 20,
     "home_max_bytes": HOME_MAX_BYTES},
    probe(home="kept"),
]
# A list no resolver answers for: .invalid never resolves.
UNREACHABLE = "https://cyfr-browser-source.invalid/LATEST_RELEASE_STABLE"
NOT_DOWNLOADED = "The browser could not be downloaded; try again in a moment."
# How long a start with nothing asked is watched for traffic of Chrome's own.
QUIET_S = 30
SHORT_KEEP_MS = 3000
# The owner's lease is renewed this often, as CYFR's box renews it: the first start fetches Chrome, and the suite
# outlasts one lease (at most 60 s).
RENEW_S = 10
_renewed = [0.0]


def keep_lease(c):
    """Renews the owner's lease when RENEW_S have passed since the last renewal."""
    if time.monotonic() - _renewed[0] >= RENEW_S:
        c.running(OWNER)
        _renewed[0] = time.monotonic()


# ————— the framing, as the vector file defines it —————


def encode(body):
    """One body framed."""
    return START + b"%08x" % len(body) + hashlib.sha256(body).hexdigest()[:16].encode() + body + b"\n"


def wire(message):
    """A message's body as the host writes it: compact JSON, which escapes every byte below 0x20."""
    return json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode()


def header_byte(i, c):
    if i < len(START):
        return c == START[i]
    return c in b"0123456789abcdef"


class Reader:
    """Takes whole frames out of a byte stream cut anywhere, as the vector file's comment says."""

    def __init__(self, maximum):
        self.max = maximum
        self.buf = b""

    def feed(self, data):
        self.buf += data
        bodies = []
        while True:
            start = self.buf.find(START[:1])
            if start < 0:
                self.buf = b""
                return bodies
            self.buf = self.buf[start:]
            body, used = self._take()
            if used == 0:
                return bodies
            if body is not None:
                bodies.append(body)
            self.buf = self.buf[used:]

    def _take(self):
        b = self.buf
        for i in range(1, min(HEADER_BYTES, len(b))):
            if not header_byte(i, b[i]):
                return None, 1
        if len(b) < HEADER_BYTES:
            return None, 0
        length = int(b[len(START):len(START) + 8], 16)
        if length == 0 or length > self.max:
            return None, 1
        end = HEADER_BYTES + length
        if b.find(START[:1], HEADER_BYTES, min(len(b), end)) >= 0:
            return None, 1
        if len(b) <= end:
            return None, 0
        if b[end] != 0x0A:
            return None, 1
        body = b[HEADER_BYTES:end]
        if hashlib.sha256(body).hexdigest()[:16].encode() != b[len(START) + 8:HEADER_BYTES]:
            return None, 1
        return body, end + 1


def check_frames():
    """The framing here reproduces every encode and decode case of the vector file."""
    wrong = {}
    for case in FRAMES["encode"]:
        if encode(case["body"].encode()) != case["frame"].encode():
            wrong[f"encode: {case['name']}"] = encode(case["body"].encode()).decode()
    for case in FRAMES["decode"]:
        reader = Reader(case["max"])
        taken = [body.decode() for piece in case["stream"] for body in reader.feed(piece.encode())]
        if taken != case["frames"] or reader.buf != case["rest"].encode():
            wrong[f"decode: {case['name']}"] = {"taken": taken, "rest": reader.buf.decode()}
    if wrong:
        sys.exit("FAIL: browser.py does not frame as tests/fixtures/browser_frames.json says\n"
                 + json.dumps(wrong, indent=2))


check_frames()


# ————— the host of the driver's session —————


class Host:
    """Opus.Browser's side of one driver session: framed messages in and out over the terminal's bytes."""

    def __init__(self, stack, c, home, argv=()):
        self.stack, self.c = stack, c
        status, opened = c.open(OWNER, "browser", key=home, mode="terminal", argv=list(argv), rows=24, cols=80,
                                home_id=home)
        expect(status == 200 and opened["status"] == "running", f"the browser opens as a terminal in {home}", opened)
        self.session = opened["session"]
        self.after = 0
        self.reader = Reader(MAX_TO_HOST)
        self.inbox = []
        self.running = True
        self.exit_code = None

    def raw(self, wait_ms=2_000):
        """The bytes the session printed since the last read, none dropped."""
        keep_lease(self.c)
        status, answer = self.c.output(OWNER, self.session, self.after, wait_ms)
        if status != 200:
            sys.exit(f"FAIL: an output of the browser's session is refused: {status} {answer}")
        if answer.get("dropped"):
            sys.exit(f"FAIL: the service dropped the browser's output: {answer['dropped']} chunks")
        data = b""
        for chunk in answer["chunks"]:
            data += unb64(chunk["bytes"])
            self.after = chunk["seq"]
        self.running, self.exit_code = answer["running"], answer.get("exit_code")
        return data

    def read(self, wait_ms=2_000):
        """Reads the session once, keeping every message it completes in the inbox."""
        self.inbox += [json.loads(body) for body in self.reader.feed(self.raw(wait_ms))]

    def write(self, data):
        for i in range(0, len(data), INPUT_BYTES):
            status, answer = self.c.input(OWNER, self.session, data[i:i + INPUT_BYTES])
            if status != 200 or answer.get("status") != "running":
                _, state = self.c.output(OWNER, self.session, self.after, 0)
                state = {k: v for k, v in (state or {}).items() if k != "chunks"}
                sys.exit(f"FAIL: input {i // INPUT_BYTES} of {-(-len(data) // INPUT_BYTES)} to the browser's session "
                         f"is refused: {status} {answer}; the session: {state}\n"
                         + "\n".join(self.stack.logs().splitlines()[-30:]))

    def send(self, message):
        self.write(encode(wire(message)))

    def take(self, want, what, timeout_s=60):
        """The first message `want` accepts, read until it arrives; the inbox keeps the others."""
        deadline = time.monotonic() + timeout_s
        while True:
            for message in self.inbox:
                if want(message):
                    self.inbox.remove(message)
                    return message
            if not self.running or time.monotonic() > deadline:
                sys.exit(f"FAIL: {what} never arrived (running: {self.running}): {self.inbox[-5:]}")
            self.read()

    def hello(self):
        return self.take(lambda m: m["t"] == "hello", "the driver's hello")

    def response(self, id, parts=None, timeout_s=60):
        """Response `id` whole, every chunk acknowledged as it arrives: (its answer, its text's bytes, frames read).

        `parts` holds chunks already taken, by seq; chunks arrive in order
        from where the driver was asked to send.
        """
        parts = dict(parts or {})
        frames = 0
        expected = None
        while True:
            m = self.take(lambda m: m["t"] in ("res", "gone") and m["id"] == id, f"response {id}", timeout_s)
            if m["t"] == "gone":
                return {"gone": True}, b"", frames
            if expected is not None and m["seq"] != expected:
                sys.exit(f"FAIL: response {id} sent chunk {m['seq']} after {expected - 1}")
            frames += 1
            parts[m["seq"]] = base64.b64decode(m["part"], validate=True)
            self.send({"t": "ack", "id": id, "seq": m["seq"]})
            expected = m["seq"] + 1
            if m["seq"] == m["of"] - 1:
                if sorted(parts) != list(range(m["of"])):
                    sys.exit(f"FAIL: response {id} ended holding chunks {sorted(parts)} of {m['of']}")
                text = b"".join(parts[seq] for seq in range(m["of"]))
                return json.loads(text), text, frames

    def image(self, cast, what, timeout_s=30):
        return self.take(lambda m: m["t"] == "image" and m["id"] == cast, what, timeout_s)

    def quiet(self, seconds, want):
        """Reads for `seconds`; the messages `want` accepts that came meanwhile."""
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            self.read(500)
        came = [m for m in self.inbox if want(m)]
        return came

    def drop_images(self):
        """Takes every image the inbox holds out of it, each acknowledged, so its cast goes on."""
        for m in [m for m in self.inbox if m["t"] == "image"]:
            self.inbox.remove(m)
            self.send({"t": "seen", "id": m["id"], "seq": m["seq"]})

    def settle(self, cast):
        """Acknowledges every image of `cast` until none comes for 300 ms."""
        while True:
            self.read(300)
            images = [m for m in self.inbox if m["t"] == "image" and m["id"] == cast]
            if not images:
                return
            for m in images:
                self.inbox.remove(m)
                self.send({"t": "seen", "id": cast, "seq": m["seq"]})

    def ask(self, id, win, op, args=None):
        self.send({"t": "req", "id": id, "win": win, "op": op, "args": args or {}})
        return self.response(id)[0]

    def send_put(self, id, win, files, root, entry="index.html"):
        """Hands a put over as Opus.Browser does: its `page` request naming each file's path, type and size, then the
        files' bytes end to end in `part`s of at most PUT["part_bytes"], in order."""
        data = b"".join(body for _path, _type, body in files)
        parts = [data[i:i + PUT["part_bytes"]] for i in range(0, len(data), PUT["part_bytes"])]
        self.send({"t": "req", "id": id, "win": win, "op": "page", "of": len(parts), "args": {
            "root": root, "entry": entry, "files": [{"path": path, "type": typ, "size": len(body)}
                                                    for path, typ, body in files]}})
        self.write(b"".join(encode(wire({"t": "part", "id": id, "seq": seq, "part": base64.b64encode(part).decode()}))
                            for seq, part in enumerate(parts)))

    def put(self, id, win, files, root, entry="index.html"):
        self.send_put(id, win, files, root, entry)
        return self.response(id)[0]

    def put_html(self, id, win, html, name="page"):
        """A page of one file, its entry."""
        return self.put(id, win, [("index.html", "text/html", html.encode())], root_of(name))

    def close(self):
        status, closed = self.c.close(OWNER, self.session)
        expect(status == 200, "the browser's session is closed", closed)


def ok(answer, what):
    expect("ok" in answer, what, answer)
    return answer["ok"]


def refused(answer, code, what):
    expect(answer.get("error", {}).get("code") == code and answer["error"]["message"].endswith("."), what, answer)


# ————— pages —————


def megabyte_page():
    """About a megabyte of html whose read is over a megabyte of text: short paragraphs, each its own line."""
    paragraphs = [f"<p>Paragraph {i:05d}: the browser reads every line of a long page and none is lost.</p>"
                  for i in range(12_000)]
    return "<title>A long page</title>" + "".join(paragraphs)


def article(n):
    """A realistic page: a site's header and navigation, an article with headings, lists, a table and a form, a footer."""
    words = ("the river runs past the old mill where the town keeps its records and the people meet on market days "
             "to trade grain wool and news of the valley").split()
    def sentence(i, length=18):
        return " ".join(words[(i * 7 + k) % len(words)] for k in range(length)).capitalize() + "."
    parts = [f"<title>Valley news {n}</title><style>body{{font-family:'Liberation Sans',sans-serif;margin:0}}"
             "header,footer{background:#234;color:#fff;padding:12px}nav a{color:#cde;margin-right:10px}"
             "main{max-width:860px;margin:auto;padding:16px}table{border-collapse:collapse}"
             "td,th{border:1px solid #999;padding:4px}.card{box-shadow:0 1px 4px #0003;padding:8px;margin:8px 0}</style>",
             "<header><h1>The Valley Gazette</h1><nav>"
             + "".join(f"<a href='/section/{i}'>Section {i}</a>" for i in range(30)) + "</nav></header><main>",
             f"<article><h2>Edition {n}</h2>"]
    for section in range(12):
        parts.append(f"<h3>Part {section}</h3>")
        parts += [f"<p>{sentence(section * 10 + p)} {sentence(section * 10 + p + 3)} {sentence(section + p, 25)}</p>"
                  for p in range(6)]
        parts.append("<ul>" + "".join(f"<li>{sentence(section + li, 8)}</li>" for li in range(5)) + "</ul>")
        parts.append(f"<div class=card><svg width=120 height=60><rect width=120 height=60 fill='#{section:02x}6a9c'/>"
                     f"<circle cx=60 cy=30 r={10 + section} fill='#fc3'/></svg> {sentence(section, 12)}</div>")
    parts.append("<table><tr><th>Market</th><th>Grain</th><th>Wool</th><th>Day</th></tr>"
                 + "".join(f"<tr><td>Town {r}</td><td>{r * 3}</td><td>{r * 5}</td><td>Day {r % 7}</td></tr>"
                           for r in range(25)) + "</table>")
    parts.append("<form><label>Name <input name=name></label><label>Town <select><option>North</option>"
                 "<option>South</option></select></label><label><input type=checkbox> Subscribe</label>"
                 "<button type=button>Send</button></form></article></main>")
    parts.append("<footer>" + "".join(f"<a href='/about/{i}'>About {i}</a> " for i in range(15)) + "</footer>")
    return "".join(parts)


# A page that changes every frame, so Chrome casts as fast as it is let.
ANIMATED_PAGE = ("<title>Animated</title><body style='margin:0'><div id=b style='width:100vw;height:100vh'></div>"
                 "<script>let n=0;(function f(){n++;document.getElementById('b').style.background="
                 "'hsl('+(n%360)+',70%,50%)';document.getElementById('b').textContent=n;requestAnimationFrame(f)})()"
                 "</script></body>")

# A page that writes where a press landed, and its size, into its title, and changes its colour, under a field at
# its top left; it changes nowhere else, so the first image after a press shows it.
INPUT_PAGE = ("<title>input</title><body style='margin:0;background:#f80'>"
              "<div style='position:fixed;left:0;top:0;width:100vw;height:100vh' "
              "onmousedown=\"document.title='at '+event.clientX+','+event.clientY+' of '+innerWidth+'x'+innerHeight;"
              "document.body.style.background=document.body.style.background=='rgb(0, 128, 255)'?'#f80':'#0080ff'\">"
              "</div><input id=f aria-label=Field style='position:fixed;left:0;top:0;width:200px;height:40px'></body>")

PROBE_PAGE = ("<title>Probe page</title><h1 id=h>Before</h1>"
              "<button onclick=\"document.getElementById('h').textContent='After'\">Change</button>"
              "<label>Name <input id=name></label><a href='#second'>Second</a>")


def ref_of(text, role, name):
    """The ref a read gives the node of `role` and `name`."""
    for line in text.splitlines():
        line = line.strip()
        prefix_end = line.find("] ")
        if line.startswith("[") and line[prefix_end + 2:].startswith(f'{role} "{name}"'):
            return line[1:prefix_end]
    sys.exit(f"FAIL: the read gives no ref to {role} {name!r}:\n{text}")


def png_size(data):
    """The width and height of a PNG that decodes: every chunk's CRC holds and its pixels inflate to their size."""
    expect(data[:8] == b"\x89PNG\r\n\x1a\n", "the screenshot is a PNG")
    at, idat, header = 8, b"", None
    while at < len(data):
        length, kind = struct.unpack(">I4s", data[at:at + 8])
        chunk = data[at + 8:at + 8 + length]
        crc, = struct.unpack(">I", data[at + 8 + length:at + 12 + length])
        if zlib.crc32(kind + chunk) != crc:
            sys.exit(f"FAIL: the PNG's {kind!r} chunk fails its CRC")
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", chunk)
        elif kind == b"IDAT":
            idat += chunk
        at += 12 + length
    width, height, depth, color, _compression, _filter, interlace = header
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color]
    pixels = zlib.decompress(idat)
    expect(depth == 8 and interlace == 0 and len(pixels) == height * (1 + width * channels),
           "the PNG's pixels inflate to its width and height", [width, height, depth, color, len(pixels)])
    return width, height


# ————— what the box holds —————


def store(home):
    """Where the driver keeps a home's Chrome."""
    return f"{KEPT_ROOT}/{home}/cyfr-browser"


def is_chrome(cmd):
    """Whether a command line is a Chrome the driver started from a kept home's versions."""
    program = cmd.split(" ", 1)[0]
    return program.startswith(KEPT_ROOT + "/") and "/cyfr-browser/versions/" in program


def chrome_processes(stack, uid):
    return [p for p in stack.processes() if uid in p["uids"] and is_chrome(p["cmd"])]


def home_uid(stack, home):
    """The uid a kept home belongs to, read from its folder, which the release's user lists."""
    return imagesuite.read_output(stack.exec(f"stat -c %u {KEPT_ROOT}/{home}"), f"{home}'s owner").strip()


def as_home(stack, home, script, what):
    """`script` run as the home's own uid, which alone enters it."""
    return imagesuite.read_output(stack.exec(script, user=home_uid(stack, home)), what)


def in_store(stack, home):
    """What a home's store holds, as its uid reads it: its versions with each one's inode, the last check's mtime, and
    any staging folder or partial download."""
    listing = as_home(stack, home, (
        f"cd {store(home)} 2>/dev/null || exit 0; for v in versions/*; do [ -e \"$v\" ] && "
        f"echo \"version ${{v#versions/}} $(stat -c %i \"$v\") $([ -x \"$v/chrome\" ] && echo runs)\"; done; "
        f"[ -e checked ] && echo \"checked $(stat -c %Y checked)\"; "
        f"for d in .staging-* .partial-*; do [ -e \"$d\" ] && echo \"staging $d\"; done; true"), f"{home}'s store")
    found = {"versions": {}, "checked": None, "staging": []}
    for line in listing.splitlines():
        kind, *rest = line.split()
        if kind == "version":
            found["versions"][rest[0]] = {"inode": rest[1], "runs": rest[2:] == ["runs"]}
        elif kind == "checked":
            found["checked"] = int(rest[0])
        elif kind == "staging":
            found["staging"].append(rest[0])
    return found


def home_bytes(stack, home, path=""):
    return int(as_home(stack, home, f"du -sb {KEPT_ROOT}/{home}{path}", f"{home}'s bytes").split()[0])


def memory(stack, uid, driver):
    """Chrome's summed PSS, the session cgroup's memory.current, in MiB, and the uid's threads and the most
    descriptors one of its processes holds, which its nproc and nofile limits bound.

    Read as the kept home's uid and gid, which are one number: a process's memory maps are readable only to
    a reader whose ids all match its own.
    """
    ids = f"{uid}:{uid}"
    pids = [p["pid"] for p in chrome_processes(stack, uid)]
    pss = imagesuite.read_output(stack.exec(
        f"for p in {' '.join(map(str, pids))}; do awk '/^Pss:/ {{print $2}}' /proc/$p/smaps_rollup 2>/dev/null; done; true",
        user=ids), "Chrome's PSS").split()
    path = imagesuite.read_output(stack.exec(f"sed -n 's/^0:://p' /proc/{driver}/cgroup"), "the session's cgroup").strip()
    current = stack.exec(f"cat /sys/fs/cgroup{path}/memory.current; grep -E '^(anon|file) ' /sys/fs/cgroup{path}/memory.stat")
    if current.returncode == 0:
        lines = current.stdout.split("\n")
        parts = dict(line.split() for line in lines[1:] if line.strip())
        # The file part holds the page cache of the Chrome the first start wrote, which the kernel reclaims first.
        cgroup = (f"{int(lines[0]) / 2**20:.0f} MiB (anon {int(parts['anon']) / 2**20:.0f}, "
                  f"file {int(parts['file']) / 2**20:.0f})")
    else:
        cgroup = "unreadable"
    every = " ".join(str(p["pid"]) for p in stack.under_uid(uid))
    counts = imagesuite.read_output(stack.exec(
        f"for p in {every}; do echo $(ls /proc/$p/task 2>/dev/null | wc -l) $(ls /proc/$p/fd 2>/dev/null | wc -l); done",
        user=ids), "the uid's threads and descriptors").split("\n")
    threads = sum(int(line.split()[0]) for line in counts if line.strip())
    descriptors = max(int(line.split()[1]) for line in counts if line.strip())
    return (f"PSS {sum(int(k) for k in pss) / 1024:.0f} MiB over {len(pss)} of its {len(pids)} processes, "
            f"cgroup memory.current {cgroup}; the uid's threads {threads}, most descriptors of one process {descriptors}")


def truncated_archive():
    """A chrome build's archive as Chrome for Testing packs it, cut short of its central directory."""
    import io
    import zipfile
    whole = io.BytesIO()
    with zipfile.ZipFile(whole, "w", zipfile.ZIP_DEFLATED) as z:
        for platform in ("linux64", "linux-arm64"):
            info = zipfile.ZipInfo(f"chrome-{platform}/chrome")
            info.external_attr = 0o100755 << 16
            z.writestr(info, b"#!/bin/sh\nexit 0\n" + os.urandom(65536))
    data = whole.getvalue()
    return data[:len(data) // 2]


def net_log_leaving(text):
    """What a Chrome network log shows leaving: the URLs requested, the hosts resolved and the addresses connected to.

    A log Chrome did not close is read up to its last whole event.
    """
    text = text.rstrip()
    try:
        log = json.loads(text)
    except json.JSONDecodeError:
        log = json.loads(text.rstrip(",") + "]}")
    names = {number: name for name, number in log["constants"]["logEventTypes"].items()}
    found = set()
    for event in log.get("events", []):
        kind, params = names.get(event.get("type")), event.get("params") or {}
        if kind == "URL_REQUEST_START_JOB" and "url" in params:
            found.add(("url", params["url"]))
        elif kind in ("HOST_RESOLVER_MANAGER_REQUEST", "HOST_RESOLVER_MANAGER_JOB", "HOST_RESOLVER_DNS_TASK") \
                and "host" in params:
            found.add(("host", params["host"]))
        elif kind in ("TCP_CONNECT_ATTEMPT", "TCP_CONNECT") and "address" in params:
            found.add(("connect", params["address"]))
    return sorted(found)


def tcp_listeners(stack):
    """Every listening TCP socket of the box's namespace, both families: (port, uid)."""
    table = imagesuite.read_output(stack.exec("cat /proc/net/tcp /proc/net/tcp6"), "the TCP tables")
    listening = []
    for line in table.splitlines():
        fields = line.split()
        if len(fields) > 7 and fields[3] == "0A":
            listening.append((int(fields[1].rsplit(":", 1)[1], 16), int(fields[7])))
    return listening


# The ELF machine of a binary built for each `uname -m` a box may report.
ELF_MACHINE = {"x86_64": "3e00", "aarch64": "b700"}


# ————— pages put into the Chrome, and their calls (C15) —————

# A WebAssembly module whose one export adds two i32s, and a PNG of one pixel.
ADD_WASM = bytes.fromhex("0061736d0100000001070160027f7f017f030201000707010361646400000a09010700200020016a0b")
PIXEL_PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")

# A frame answers its parent's message by posting a call of its own, as a simple request, which no preflight
# precedes, and says how it went.
FRAME_POST = ("addEventListener('message', async e => { let result; try { const r = await fetch('" + RESERVED
              + "/_f/v1/invoke', {method: 'POST', mode: 'no-cors', body: JSON.stringify({from: FROM})});"
              " result = r.type + ' ' + r.status + (r.type === 'opaque' ? '' : ' ' + await r.text()) }"
              " catch (err) { result = 'rejected ' + err.name } parent.postMessage({id: e.data.id, result}, '*') })")


def html_attribute(text):
    return text.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace(">", "&gt;")


def proof_site(root):
    """A built site of several files under `root`, its entry naming its own directory in a <base> as the host's
    head tags do: a classic script, a module that imports another, a stylesheet, a WebAssembly file, an image, a
    frame of one of its files, frames of no origin of its own (data:, srcdoc, a sandbox), a dedicated, a shared and
    a service worker, a socket and an event stream. On load its proof script runs each, every step bounded, and
    writes what it saw into the title."""
    from urllib.parse import quote
    data_frame = "data:text/html," + quote(f"<script>const FROM = 'data'; {FRAME_POST}</script>")
    srcdoc = html_attribute(f"<script>const FROM = 'srcdoc'; {FRAME_POST}</script>")
    entry = (f'<!doctype html><html><head><base href="{root}/"><title>loading</title>'
             '<link rel=stylesheet href="style.css"><script src="app.js"></script>'
             '<script type=module src="main.mjs"></script></head>'
             '<body><h1 id=h>A site</h1><img id=img src="pic.png" alt="">'
             '<iframe id=same src="frame.html"></iframe>'
             f'<iframe id=data src="{html_attribute(data_frame)}"></iframe>'
             f'<iframe id=srcdoc srcdoc="{srcdoc}"></iframe>'
             '<iframe id=sandboxed sandbox="allow-scripts" src="frame.html"></iframe>'
             '<script src="proof.js"></script></body></html>')
    proof = """
const out = {};
const bounded = (p, ms = 8000) => Promise.race([p, new Promise(r => setTimeout(() => r('timeout'), ms))]);
const step = async (name, p) => { try { out[name] = await bounded(p) } catch (e) { out[name] = 'rejected ' + (e && e.name) } };
const post = async (path, from) => { const r = await fetch(path, {method: 'POST', headers: {'content-type': 'application/json'},
  body: JSON.stringify({from})}); return r.status + ' ' + await r.text() };
const ask = id => new Promise(resolve => { const asked = Math.random();
  addEventListener('message', function on(e) { if (e.data && e.data.id === asked) { removeEventListener('message', on); resolve(e.data.result) } });
  document.getElementById(id).contentWindow.postMessage({id: asked}, '*') });
addEventListener('load', async () => {
  out.secure = window.isSecureContext;
  out.classic = window.classic === 1;
  out.module = window.moduleValue === 42;
  out.css = getComputedStyle(document.getElementById('h')).color;
  out.image = document.getElementById('img').naturalWidth;
  out.frameFile = document.getElementById('same').contentWindow.kind;
  await step('wasm', WebAssembly.instantiateStreaming(fetch('add.wasm')).then(m => m.instance.exports.add(2, 3)));
  await step('post', post('/_f/v1/invoke', 'page'));
  await step('action', post('/_f/v1/action', 'page-action'));
  await step('frame', ask('same'));
  await step('data', ask('data'));
  await step('srcdoc', ask('srcdoc'));
  await step('sandboxed', ask('sandboxed'));
  await step('socket', new Promise(r => { const w = new WebSocket('wss://cyfr.invalid/socket'); w.onerror = () => r('error'); w.onopen = () => r('open') }));
  await step('events', new Promise(r => { const e = new EventSource('events'); e.onerror = () => { r('error ' + e.readyState); e.close() }; e.onopen = () => r('open') }));
  await step('worker', new Promise(r => { const w = new Worker('worker.js'); w.onmessage = e => r(e.data); w.onerror = () => r('error') }));
  await step('shared', new Promise(r => { const w = new SharedWorker('shared.js'); w.port.onmessage = e => r(e.data); w.onerror = () => r('error') }));
  await step('serviceWorker', navigator.serviceWorker.register('sw.js').then(() => 'registered', e => 'rejected ' + e.name));
  out.after = 'responsive';
  document.title = 'done ' + JSON.stringify(out);
});
"""
    worker = """(async () => { const out = {};
  try { const r = await fetch(LIB); out.get = r.status + ' ' + (await r.text()) } catch (e) { out.get = 'rejected ' + e.name }
  try { const r = await fetch('/_f/v1/invoke', {method: 'POST', body: JSON.stringify({from: FROM})}); out.post = r.status + ' ' + await r.text() }
  catch (e) { out.post = 'rejected ' + e.name }
  return out })()"""
    return [
        ("index.html", "text/html", entry.encode()),
        ("proof.js", "text/javascript", proof.encode()),
        ("app.js", "text/javascript", b"window.classic = 1;"),
        ("main.mjs", "text/javascript", b"import {v} from './lib.mjs'; window.moduleValue = v;"),
        ("lib.mjs", "text/javascript", b"export const v = 42;"),
        ("style.css", "text/css", b"h1 { color: rgb(1, 2, 3) }"),
        ("add.wasm", "application/wasm", ADD_WASM),
        ("pic.png", "image/png", PIXEL_PNG),
        ("frame.html", "text/html",
         f"<!doctype html><title>frame</title><script>window.kind = 'frame'; const FROM = self.origin === 'null' ? "
         f"'sandboxed' : 'frame'; {FRAME_POST}</script>".encode()),
        ("worker.js", "text/javascript",
         f"const FROM = 'worker', LIB = 'lib.mjs'; {worker}.then(out => postMessage(out));".encode()),
        ("shared.js", "text/javascript",
         f"const FROM = 'shared', LIB = 'shared-lib.mjs'; onconnect = e => {worker}.then(out => e.ports[0].postMessage(out));"
         .encode()),
        ("shared-lib.mjs", "text/javascript", b"export const v = 43;"),
        ("sw.js", "text/javascript", b"addEventListener('fetch', () => {});"),
    ]


# A page that, when clicked, opens a window of its own origin that the driver did not put, whose script posts a call.
POPUP_PAGE = ("<title>popup</title><body style='margin:0'><div id=d style='width:100vw;height:100vh' onclick=\"popup()\">"
              "</div><script>function popup() { const w = window.open('', '_blank'); if (!w) { document.title = 'popup "
              "blocked'; return } addEventListener('message', e => { document.title = 'popup ' + e.data });"
              " w.document.write('<script>fetch(\\'" + RESERVED + "/_f/v1/invoke\\', {method: \\'POST\\', mode: "
              "\\'no-cors\\', body: \\'{\"from\":\"popup\"}\\'}).then(r => opener.postMessage(r.type + \\' \\' + r.status, "
              "\\'*\\'), e => opener.postMessage(\\'rejected \\' + e.name, \\'*\\'))<\\/script>'); w.document.close() }"
              "</script></body>")

ONE_PAGE = "<title>one</title><script>document.title = 'one ' + isSecureContext + ' ' + location.href</script>"


def measured_site(root, total):
    """A built site of `total` bytes in several files under `root`, raw bytes most of it, its entry fetching the
    largest and writing into its title its status, length, the milliseconds it took and its SHA-256."""
    entry = (b'<!doctype html><base href="' + root.encode() + b'/"><title>loading</title><script>(async () => {'
             b" const t0 = performance.now();"
             b" const r = await fetch('big.bin'); const b = await r.arrayBuffer(); const ms = performance.now() - t0;"
             b" const d = [...new Uint8Array(await crypto.subtle.digest('SHA-256', b))].map(x => x.toString(16)"
             b".padStart(2, '0')).join(''); document.title = 'big ' + r.status + ' ' + b.byteLength + ' ' +"
             b" Math.round(ms) + ' ' + d })()</script>")
    files = [("index.html", "text/html", entry), ("style.css", "text/css", b"body { margin: 0 }"),
             ("app.js", "text/javascript", b"/*" + b"x" * (total // 64) + b"*/"),
             ("asset.bin", "application/octet-stream", os.urandom(total // 16))]
    files.append(("big.bin", "application/octet-stream", os.urandom(total - sum(len(body) for _p, _t, body in files))))
    return files


def answer_calls(p, seen):
    """Answers every call the inbox holds with its sender's name, keeping each in `seen` with its body's bytes, which
    travel in base64, as `text`."""
    for m in [m for m in p.inbox if m["t"] == "call"]:
        p.inbox.remove(m)
        m["text"] = base64.b64decode(m["body"], validate=True).decode(errors="replace")
        seen.append(m)
        try:
            sender = json.loads(m["text"]).get("from")
        except (ValueError, AttributeError):
            sender = None
        p.send({"t": "answer", "id": m["id"], "status": 200, "body": json.dumps({"echo": sender})})


def titled(p, win, prefix, ids, seen, timeout_s=150):
    """The rest of the title of the page in `win` once it begins with `prefix`, its calls answered meanwhile."""
    deadline = time.monotonic() + timeout_s
    while True:
        p.read(300)
        answer_calls(p, seen)
        title = ok(p.ask(next(ids), win, "read"), f"the page in {win} is read")["title"]
        answer_calls(p, seen)
        if title.startswith(prefix):
            return title[len(prefix):]
        if time.monotonic() > deadline:
            sys.exit(f"FAIL: the page in {win} never titled itself {prefix!r}: {title!r}")
        time.sleep(0.3)


def net_log_of_pages(text):
    """What a Chrome network log shows of a session: the lookups and connections made, which leave the box (a DNS
    query, a TCP connection, a QUIC session); the URLs that reached Chrome's network stack and the hosts it was asked
    to resolve, which do not; and the addresses a UDP socket was connected to, which sends nothing, as the
    resolver's check of whether IPv6 is reachable does."""
    text = text.rstrip()
    try:
        log = json.loads(text)
    except json.JSONDecodeError:
        log = json.loads(text.rstrip(",") + "]}")
    names = {number: name for name, number in log["constants"]["logEventTypes"].items()}
    left, urls, asked, udp = set(), set(), set(), set()
    for event in log.get("events", []):
        kind, params = names.get(event.get("type")), event.get("params") or {}
        if kind in ("HOST_RESOLVER_MANAGER_JOB", "HOST_RESOLVER_DNS_TASK", "HOST_RESOLVER_SYSTEM_TASK", "DNS_TRANSACTION",
                    "DNS_TRANSACTION_QUERY", "TCP_CONNECT", "TCP_CONNECT_ATTEMPT", "QUIC_SESSION"):
            left.add((kind, json.dumps(params, sort_keys=True)[:200]))
        elif kind == "URL_REQUEST_START_JOB" and "url" in params:
            urls.add(params["url"])
        elif kind == "HOST_RESOLVER_MANAGER_REQUEST" and "host" in params:
            asked.add(params["host"])
        elif kind == "UDP_CONNECT" and "address" in params:
            udp.add(params["address"])
    return sorted(left), sorted(urls), sorted(asked), sorted(udp)


def pages(stack, c, uid):
    """Pages put into the Chrome and their calls (C15), in a session that logs Chrome's network."""
    net_log = f"{KEPT_ROOT}/{BROWSER_HOME}/pages-netlog.json"
    p = Host(stack, c, BROWSER_HOME, ["--net-log", net_log])
    expect("error" not in p.hello(), "a session that logs Chrome's network says hello")
    ids = iter(range(5000, 9000))
    seen = []

    # The first proof: a put of several files, and what its page does under the reserved origin.
    site = proof_site(root_of("site"))
    shown = ok(p.put(next(ids), "thr_site", site, root_of("site")), "a put of several files loads")
    expect(shown == {"url": RESERVED + root_of("site"), "title": "loading"},
           "it answers its entry's address under the reserved origin", shown)
    out = json.loads(titled(p, "thr_site", "done ", ids, seen))
    print(f"proof: the put page saw {json.dumps(out, sort_keys=True)}", flush=True)
    print(f"proof: the calls passed up: {json.dumps([{k: m[k] for k in ('win', 'op', 'body', 'text')} for m in seen])}",
          flush=True)
    senders = [json.loads(m["text"]).get("from") for m in seen]
    for what, held in (
            ("the navigation to the reserved origin is answered with the entry", shown["title"] == "loading"),
            ("a classic script is answered", out["classic"] is True),
            ("a module and the module it imports are answered", out["module"] is True),
            ("a stylesheet is answered", out["css"] == "rgb(1, 2, 3)"),
            ("a WebAssembly file is answered, as its type, and runs", out["wasm"] == 5),
            ("an image is answered", out["image"] == 1),
            ("the page is a secure context", out["secure"] is True),
            ("a file is answered to a frame inside the put page", out["frameFile"] == "frame")):
        expect(held, f"proof: {what}", out)
    page_call = next((m for m in seen if json.loads(m["text"]).get("from") == "page"), None)
    expect(page_call is not None and page_call["win"] == "thr_site" and page_call["op"] == "invoke"
           and page_call["body"] == base64.b64encode(b'{"from":"page"}').decode() and out["post"] == '200 {"echo": "page"}',
           "proof: a POST to invoke arrives with its body, named by its window, and its answer is the page's", [seen, out])
    expect(any(m["op"] == "action" and m["text"] == '{"from":"page-action"}' for m in seen)
           and out["action"] == '200 {"echo": "page-action"}', "a POST to action is a call of op action", [seen, out])
    expect("frame" in senders and out["frame"] == 'basic 200 {"echo": "frame"}',
           "a call from a frame of the reserved origin inside the page is passed up", [seen, out])
    expect("data" not in senders and out["data"] == "rejected TypeError",
           "a call from a frame of another origin inside the page is not passed up, and fails", [seen, out])
    expect(out["socket"] == "error" and out["events"] == "error 2" and out["after"] == "responsive",
           "proof: a socket and an event stream fail, and the page goes on", out)
    expect(out["serviceWorker"] == "rejected TypeError",
           "proof: a service worker's registration is refused, and the page goes on", out)
    expect(isinstance(out["worker"], dict) and out["worker"]["get"] == "200 export const v = 42;"
           and out["worker"]["post"] == "rejected TypeError" and "worker" not in senders,
           "proof: a dedicated worker is delivered its window's files and makes no call", out)
    expect("shared" not in senders, "a shared worker makes no call", [seen, out])
    print(f"measure: a shared worker saw {json.dumps(out['shared'])}; a srcdoc frame's call "
          f"{'was' if 'srcdoc' in senders else 'was not'} passed up ({out['srcdoc']}); a sandboxed frame of a put file's "
          f"{'was' if 'sandboxed' in senders else 'was not'} ({out['sandboxed']})", flush=True)

    # A page of one file loads the same way.
    shown = ok(p.put_html(next(ids), "thr_one", ONE_PAGE, "one"), "a page of one file is put")
    expect(shown["url"] == RESERVED + root_of("one") and shown["title"] == f"one true {RESERVED}{root_of('one')}",
           "a page of one file loads under the reserved origin, a secure context", shown)

    # A plain page with no head tag, as the host hands it: its entry after Compendium.plain_entry/1 and
    # tincture_head_tags/3, the SDK's source in its script, has window.cyfr and loads a file named relative to its
    # <base>.
    plain = FRAMES["plain_entry"]
    with open(os.path.join(ROOT, "apps", "cyfr", "priv", "static", "sdk", "cyfr.js"), "rb") as sdk:
        entry = plain["entry"].encode().replace(b"{sdk}", sdk.read())
    expect(plain["href"] == root_of("plain") + "/", "the plain entry's base names the put's root", plain["href"])
    ok(p.put(next(ids), "thr_plain", [("index.html", "text/html", entry), ("pic.png", "image/png", PIXEL_PNG)],
             root_of("plain")), "a plain page with no head tag is put with the SDK and a <base>")
    seen_plain = titled(p, "thr_plain", "object ", ids, seen, 30)
    expect(seen_plain == "1", "a plain page with no head tag has window.cyfr and loads a file named relative to its "
           "<base>", seen_plain)

    # A site in another window: a window the driver did not put, of the page's own origin, opened by the person's click.
    ok(p.put_html(next(ids), "thr_popup", POPUP_PAGE, "popup"), "a page that opens a window on a click is put")
    cast = next(ids)
    ok(p.ask(cast, "thr_popup", "cast", {"width": 1280, "height": 720}), "the page is cast")
    first = p.image(cast, "the page's first image")
    p.send({"t": "seen", "id": cast, "seq": first["seq"]})
    p.send({"t": "input", "id": cast, "evs": [{"k": "mouse", "type": t, "x": 0.5, "y": 0.5, "button": "left",
                                               "clicks": 1, "mods": 0} for t in ("down", "up")]})
    opened = titled(p, "thr_popup", "popup ", ids, seen, 30)
    p.send({"t": "uncast", "id": cast})
    p.drop_images()
    expect(opened == "rejected TypeError" and "popup" not in [json.loads(m["text"]).get("from") for m in seen],
           "a call from a window the driver did not put, of the reserved origin, is not passed up", [opened, seen])

    # A window with no put is answered nothing for the reserved origin: its request fails, as no response would
    # (an empty 404 fails the open too, but as a response).
    nothing = p.ask(next(ids), "thr_noput", "open", {"url": RESERVED + root_of("site")})
    refused(nothing, "unreachable", "a window with no put is answered nothing for the reserved origin")
    expect("net::ERR_BLOCKED_BY_CLIENT" in nothing["error"]["message"],
           "its request was failed, with no response", nothing)

    # The put's bound, and what the session carries within it.
    refused(p.ask(next(ids), "thr_measure", "page", {"root": root_of("over"), "entry": "index.html", "files": [
        {"path": "index.html", "type": "text/html", "size": PUT["max_bytes"] + 1}]}), "too_large",
        "a put of a byte past its bound is refused before any part")
    refused(p.ask(next(ids), "thr_measure", "page", {"root": root_of("over"), "entry": "f0", "files": [
        {"path": f"f{n}", "type": "text/plain", "size": 0} for n in range(PUT["max_files"] + 1)]}), "too_large",
        "a put of a file past its bound is refused")
    for mib in (1, 8, 32):
        files = measured_site(root_of(f"site{mib}"), mib << 20)
        keep_lease(c)
        id = next(ids)
        started = time.monotonic()
        p.send_put(id, "thr_measure", files, root_of(f"site{mib}"))
        handed_s = time.monotonic() - started
        shown = ok(p.response(id, timeout_s=300)[0], f"a put of {mib} MiB loads")
        put_s = time.monotonic() - started
        status, length, ms, digest = titled(p, "thr_measure", "big ", ids, seen, 120).split()
        big = files[-1][2]
        expect(status == "200" and int(length) == len(big) and digest == hashlib.sha256(big).hexdigest(),
               f"the largest file of the {mib} MiB put, {len(big)} bytes, is answered whole", [status, length, digest])
        print(f"measure: a put of {mib} MiB in {len(files)} files was handed over the session in {handed_s:.2f} s and "
              f"loaded in {put_s:.2f} s; its largest file, {len(big)} bytes, was answered whole in {ms} ms", flush=True)

    # A put at its bound in files: an entry and the rest small scripts, its last file fetched.
    root = root_of("files")
    many = [("index.html", "text/html", (f'<!doctype html><base href="{root}/"><title>loading</title><script>'
                                         f"fetch('f{PUT['max_files'] - 1}.js').then(r => r.text()).then(t => "
                                         "document.title = 'last ' + t)</script>").encode())]
    many += [(f"f{n}.js", "text/javascript", f"// {n}".encode()) for n in range(1, PUT["max_files"])]
    id = next(ids)
    started = time.monotonic()
    p.send_put(id, "thr_measure", many, root)
    shown = ok(p.response(id, timeout_s=300)[0], f"a put of {len(many)} files loads")
    put_s = time.monotonic() - started
    last = titled(p, "thr_measure", "last ", ids, seen, 60)
    expect(len(many) == PUT["max_files"] and last == f"// {PUT['max_files'] - 1}",
           "a put at its bound in files loads, and its last file is answered", [len(many), last])
    print(f"measure: a put of {len(many)} files, the bound, was handed over and loaded in {put_s:.2f} s", flush=True)

    closed = ok(p.ask(next(ids), "", "close_all"), "every window of the session is closed")
    p.close()
    eventually(lambda: not stack.under_uid(uid), "the page session's processes to end")
    left, urls, asked, udp = net_log_of_pages(as_home(stack, BROWSER_HOME, f"cat {net_log}", "Chrome's network log"))
    as_home(stack, BROWSER_HOME, f"rm {net_log}", "the network log removed")
    expect(left == [], "over the page session nothing left the box: no DNS query, TCP connection or QUIC session", left)
    # What the page and its frames loaded, and what its dedicated worker fetched; not what its shared worker asked for.
    delivered = [RESERVED + root_of("site")] + [f"{RESERVED}{root_of('site')}/{path}" for path, _t, _b in site
                                                if path != "shared-lib.mjs"]
    expect(not [u for u in urls if u in delivered], "no file the driver answered reached Chrome's network stack", urls)
    expect(all("cyfr.invalid" not in host for host in asked),
           "Chrome never asked a resolver for the reserved name: its rule answered each lookup", asked)
    print(f"proof: of the page session, these reached Chrome's network stack and failed there, the reserved name "
          f"never resolved ({len(asked)} lookups answered by its rule: {asked}): {urls}; UDP sockets connected, "
          f"which send nothing: {udp}; windows closed {closed}", flush=True)


def first_start(stack, c):
    """A first start fetches this machine's Chrome, built for its architecture, and a public page loads in it."""
    started = time.monotonic()
    b = Host(stack, c, BROWSER_HOME)
    hello = b.hello()
    first_start_s = time.monotonic() - started
    expect("error" not in hello, "the first start fetches Chrome and says hello", hello)
    fetched = in_store(stack, BROWSER_HOME)
    expect(len(fetched["versions"]) == 1 and all(v["runs"] for v in fetched["versions"].values()),
           "one Chrome is published whole in the home", fetched)
    version = next(iter(fetched["versions"]))
    machine = imagesuite.read_output(stack.exec("uname -m"), "the box's machine").strip()
    elf = as_home(stack, BROWSER_HOME, f"od -An -tx1 -j18 -N2 {store(BROWSER_HOME)}/versions/{version}/chrome",
                  "the Chrome's ELF machine").replace(" ", "").strip()
    expect(ELF_MACHINE.get(machine) == elf, f"the fetched Chrome is built for this box's {machine}", [machine, elf])
    opened = ok(b.ask(1, "thr_first", "open", {"url": "https://example.com/"}), "a public page opens")
    expect(opened == {"url": "https://example.com/", "title": "Example Domain"}, "it loads, with its address and title",
           opened)
    print(f"measure: the first start fetched Chrome {version} for {machine} and said hello in {first_start_s:.1f} s",
          flush=True)
    b.close()


def main():
    args = sys.argv[1:]
    only_first_start = args[:1] == ["--first-start"]
    if only_first_start:
        args = args[1:]
    if len(args) != 1:
        sys.exit("usage: browser.py [--first-start] IMAGE")
    require_docker()
    stack = Stack("locus-backends-browser", args[0])
    try:
        stack.up()
        c = stack.controller()
        expect(c.hello()[0] == 200, "the service is greeted")
        status, answer, _ = c.sync(OWNER, PROGRAMS)
        expect(status == 200, "an owner of the browser and a probe, both kept, is synced", answer)
        _renewed[0] = time.monotonic()
        if only_first_start:
            first_start(stack, c)
            return

        # ————— the first exchange, on the Chrome the first start fetches —————
        in_image = imagesuite.read_word(stack.exec(
            "for p in /usr/lib/chromium /usr/bin/chromium /opt/google/chrome /usr/bin/google-chrome; do "
            "[ -e $p ] && { echo present; exit 0; }; done; echo absent"), ("present", "absent"), "a Chrome in the image")
        expect(in_image == "absent", "the image holds no Chrome", in_image)
        started = time.monotonic()
        b = Host(stack, c, BROWSER_HOME)
        hello = b.hello()
        first_start_s = time.monotonic() - started
        expect(hello == {"t": "hello", "v": 1, "chunk": 49152, "keep_ms": 120000},
               "the driver says hello once Chrome answers, with its chunk and keep", hello)
        fetched = in_store(stack, BROWSER_HOME)
        expect(len(fetched["versions"]) == 1 and all(v["runs"] for v in fetched["versions"].values())
               and fetched["checked"] is not None and not fetched["staging"],
               "the first start fetched one Chrome into the home, published whole, and runs it", fetched)
        version = next(iter(fetched["versions"]))
        print(f"measure: the first start fetched Chrome {version} and said hello in {first_start_s:.1f} s", flush=True)
        html = megabyte_page()
        started = time.monotonic()
        shown = ok(b.put_html(1, "thr_big", html, "long"), "a page of about a megabyte of html is put")
        page_s = time.monotonic() - started
        expect(shown == {"url": RESERVED + root_of("long"), "title": "A long page"},
               "the page answers its address under the reserved origin and its title", shown)
        started = time.monotonic()
        b.send({"t": "req", "id": 2, "win": "thr_big", "op": "read", "args": {}})
        answer, reference, frames = b.response(2)
        read_s = time.monotonic() - started
        text = ok(answer, "the megabyte read answers")["text"]
        of = -(-len(reference) // hello["chunk"])
        expect(len(text.encode()) > 1_000_000 and frames == of > 1
               and "Paragraph 00000:" in text and "Paragraph 11999:" in text,
               "a read of over a megabyte arrives whole in numbered chunks, each acknowledged",
               [len(text), frames, of])
        print(f"measure: a page of {len(html)} bytes of html took {page_s:.2f} s; its read, {len(reference)} bytes "
              f"of response text, took {read_s:.2f} s in {frames} frames", flush=True)

        # ————— no acknowledgement, no more output —————
        b.send({"t": "req", "id": 3, "win": "thr_big", "op": "read", "args": {}})
        first = b.take(lambda m: m["t"] == "res" and m["id"] == 3, "the first chunk of an unacknowledged read")
        held = time.monotonic() + 4
        while time.monotonic() < held:
            b.read(1_000)
        expect(first["seq"] == 0 and not [m for m in b.inbox if m["t"] == "res"],
               "with the host not acknowledging, the driver's output stops after the one chunk", b.inbox)
        b.inbox.insert(0, first)
        answer, text3, _frames = b.response(3)
        expect(text3 == reference, "acknowledged, the response arrives whole: nothing was lost")

        # ————— a forced tail —————
        # The host acknowledges every chunk but the last blindly, so the
        # driver pours the response out; the ack of the last chunk is the
        # host's word that it holds the response whole, after which the
        # driver drops it, so a host that has read nothing never sends it.
        b.send({"t": "req", "id": 4, "win": "thr_big", "op": "read", "args": {}})
        poured = bytearray()
        eventually(lambda: poured.extend(b.raw()) or b'{"t":"res","id":4,"seq":0,' in poured,
                   "the first chunk of the read poured out", 60)
        b.write(b"".join(encode(wire({"t": "ack", "id": 4, "seq": seq})) for seq in range(of - 1)))
        eventually(lambda: not poured.extend(more := b.raw(2_000)) and not more,
                   "the driver to stop pouring the response out", 60)
        tail = bytes(poured[-TAIL_BYTES:])
        taken = [json.loads(body) for body in Reader(MAX_TO_HOST).feed(tail)]
        seqs = [m["seq"] for m in taken if m["t"] == "res" and m["id"] == 4]
        # A body holds no 0x1E, so each START in the tail begins a frame: the
        # host takes exactly the frames that begin there, and not the one cut
        # before the first of them.
        expect(len(poured) > TAIL_BYTES and len(taken) == len(seqs) == tail.count(START)
               and seqs == list(range(of - len(seqs), of)) and 0 < len(seqs) < of,
               "of the poured response's last 256 KiB the host takes the frames whole there and no cut one",
               [len(poured), seqs, of, tail.find(START)])
        held = {m["seq"]: base64.b64decode(m["part"], validate=True) for m in taken}
        lacking = min(set(range(of)) - set(held))
        b.send({"t": "again", "id": 4, "seq": lacking})
        answer, text4, _frames = b.response(4, held)
        expect(lacking == 0 and text4 == reference, "asked again from the first chunk it lacks, the host gets it whole")

        # ————— a cast over the same session —————
        ok(b.put_html(300, "thr_article", article(0)), "a realistic page is shown")
        for size, (width, height), cast in (("a phone's width", (390, 844), 301), ("720p", (1280, 720), 302)):
            ok(b.ask(cast, "thr_article", "cast", {"width": width, "height": height}), f"the realistic page cast at {size}")
            shown = b.image(cast, f"the realistic page's image at {size}")
            print(f"measure: a cast at {size} ({width}x{height}) of a realistic page: its image is "
                  f"{len(base64.b64decode(shown['jpeg'], validate=True)) / 1024:.1f} KiB", flush=True)
            b.send({"t": "uncast", "id": cast})
        b.quiet(1, lambda m: False)
        b.drop_images()
        ok(b.put_html(303, "thr_cast", ANIMATED_PAGE), "an animated page is shown")
        for size, (width, height), cast in (("a phone's width", (390, 844), 304), ("720p", (1280, 720), 305)):
            expect(ok(b.ask(cast, "thr_cast", "cast", {"width": width, "height": height}), f"a cast at {size}") == {},
                   f"a cast at {size} answers that it casts")
            started = time.monotonic()
            sizes, seqs = [], []
            while time.monotonic() - started < 5:
                m = b.image(cast, f"an image of the cast at {size}")
                sizes.append(len(base64.b64decode(m["jpeg"], validate=True)))
                seqs.append(m["seq"])
                b.send({"t": "seen", "id": cast, "seq": m["seq"]})
            rate = len(sizes) / (time.monotonic() - started)
            expect(len(sizes) > 5 and max(sizes) <= MAX_TO_HOST * 3 // 4 and seqs == list(range(1, len(seqs) + 1)),
                   f"the cast at {size} sends images one at a time, in order, each within the bound",
                   [len(sizes), max(sizes), seqs[:5]])
            print(f"measure: a cast at {size} ({width}x{height}) of a page that changes every frame sent "
                  f"{rate:.1f} images a second, each {sum(sizes) / len(sizes) / 1024:.1f} KiB on average "
                  f"({max(sizes) / 1024:.1f} KiB at most)", flush=True)
            if cast == 304:
                b.send({"t": "uncast", "id": cast})
                b.quiet(1, lambda m: False)
                b.inbox = [m for m in b.inbox if not (m["t"] == "image" and m["id"] == cast)]

        # With the host not acknowledging an image, no further image comes, and a read still arrives whole.
        cast = 305
        stalled = b.image(cast, "the image left unacknowledged")
        b.inbox = [m for m in b.inbox if m["t"] != "image"]
        b.send({"t": "req", "id": 306, "win": "thr_big", "op": "read", "args": {}})
        answer, text43, _frames = b.response(306)
        expect(text43 == reference, "a read beside an unacknowledged image arrives whole")
        expect(not b.quiet(3, lambda m: m["t"] == "image"),
               "with an image unacknowledged, the driver sends no further image", b.inbox[-3:])
        b.send({"t": "seen", "id": cast, "seq": stalled["seq"]})
        expect(b.image(cast, "the image after the stalled one was seen")["seq"] == stalled["seq"] + 1,
               "acknowledged, the cast goes on with the next image")

        # A forced tail with the cast and a poured response sharing the output: the host acknowledges every image
        # as it reads it and every chunk but the last blindly, then keeps only the last 256 KiB of what it read.
        b.inbox = [m for m in b.inbox if m["t"] != "image"]
        b.send({"t": "seen", "id": cast, "seq": stalled["seq"] + 1})
        b.send({"t": "req", "id": 307, "win": "thr_big", "op": "read", "args": {}})
        poured, scan = bytearray(), Reader(MAX_TO_HOST)
        acked = False
        while True:
            more = b.raw(2_000)
            poured.extend(more)
            done = False
            for body in scan.feed(more):
                m = json.loads(body)
                if m["t"] == "image" and m["id"] == cast:
                    b.send({"t": "seen", "id": cast, "seq": m["seq"]})
                elif m["t"] == "res" and m["id"] == 307 and not acked:
                    b.write(b"".join(encode(wire({"t": "ack", "id": 307, "seq": seq})) for seq in range(of - 1)))
                    acked = True
                elif m["t"] == "res" and m["id"] == 307 and m["seq"] == of - 1:
                    done = True
            if done:
                break
        starts = [i for i in range(len(poured)) if poured[i:i + len(START)] == START]
        kinds = {}
        for at in starts:
            body_at = at + HEADER_BYTES
            kind = json.loads(Reader(MAX_TO_HOST).feed(bytes(poured[at:]))[0])["t"]
            kinds.setdefault(kind, at)
        expect("image" in kinds and "res" in kinds, "images and chunks share the poured output", sorted(kinds))
        # Wherever a tail begins, in a header, in an image's body or in a chunk's, the host takes exactly the
        # frames that begin after it.
        for name, cut in (("an image's header", kinds["image"] + 5), ("an image's body", kinds["image"] + HEADER_BYTES + 40),
                          ("a chunk's body", kinds["res"] + HEADER_BYTES + 40)):
            taken = Reader(MAX_TO_HOST).feed(bytes(poured[cut:]))
            expect(len(taken) == len([at for at in starts if at >= cut]),
                   f"a tail beginning in {name} takes every frame after the cut and not the one cut",
                   [len(taken), len([at for at in starts if at >= cut])])
        tail = bytes(poured[-TAIL_BYTES:])
        taken = [json.loads(body) for body in Reader(MAX_TO_HOST).feed(tail)]
        expect(len(poured) > TAIL_BYTES and len(taken) == tail.count(START),
               "of the shared output's last 256 KiB the host takes the frames whole there and no cut one",
               [len(poured), len(taken), tail.count(START)])
        cut_kind = json.loads(Reader(MAX_TO_HOST).feed(bytes(poured[max(at for at in starts if at < len(poured) - TAIL_BYTES):]))[0])["t"]
        # The host ends the cast and asks for another, and asks the response again from the first chunk it lacks.
        b.inbox = []
        b.send({"t": "uncast", "id": cast})
        held = {m["seq"]: base64.b64decode(m["part"], validate=True) for m in taken if m["t"] == "res" and m["id"] == 307}
        lacking = min(set(range(of)) - set(held))
        b.send({"t": "again", "id": 307, "seq": lacking})
        answer, text44, _frames = b.response(307, held)
        expect(text44 == reference, "asked again from the first chunk it lacks, the response arrives whole")
        expect(ok(b.ask(308, "thr_cast", "cast", {"width": 1280, "height": 720}), "a cast anew") == {},
               "the cast asked for anew answers that it casts")
        expect(b.image(308, "the new cast's first image")["seq"] == 1, "the new cast goes on with its first image")
        print(f"measure: the tail of a shared output of {len(poured)} bytes began in a {cut_kind} frame", flush=True)
        b.send({"t": "uncast", "id": 308})

        # The person's input lands where the image they point at shows, at a phone's width and at 720p alike.
        ok(b.put_html(309, "thr_input", INPUT_PAGE), "a page that writes where a press lands is shown")
        # A window made after it takes Chrome's focus: the keys sent to this one still reach its page.
        ok(b.put_html(316, "thr_focus", PROBE_PAGE), "a window made after it is shown")
        read_ids = iter(range(1000, 2000))
        for size, (width, height), cast in (("a phone's width", (390, 844), 310), ("720p", (1280, 720), 311)):
            ok(b.ask(cast, "thr_input", "cast", {"width": width, "height": height}), f"the input page cast at {size}")
            first = b.image(cast, f"the input page's image at {size}")
            b.send({"t": "seen", "id": cast, "seq": first["seq"]})
            press = [{"k": "mouse", "type": t, "x": 0.25, "y": 0.5, "button": "left", "clicks": 1, "mods": 0}
                     for t in ("down", "up")]
            b.send({"t": "input", "id": cast, "evs": press})
            title = ""
            deadline = time.monotonic() + 10
            while not title.startswith("at ") and time.monotonic() < deadline:
                title = ok(b.ask(next(read_ids), "thr_input", "read"), "the input page is read")["title"]
                b.drop_images()
                time.sleep(0.2)
            place, _, viewport = title[3:].partition(" of ")
            x, y = (int(float(v)) for v in place.split(","))
            vw, vh = (int(v) for v in viewport.split("x"))
            expect(abs(x - vw * 0.25) <= 1 and abs(y - vh * 0.5) <= 1,
                   f"at {size} a press at a quarter across and half down lands there on the page", [title])
            field = [{"k": "mouse", "type": t, "x": 100 / vw, "y": 20 / vh, "button": "left", "clicks": 1, "mods": 0}
                     for t in ("down", "up")]
            keys = [{"k": "key", "type": t, "key": c, "code": f"Key{c.upper()}", "text": c if t == "down" else "",
                     "vk": ord(c.upper()), "mods": 0} for c in ("h", "i") for t in ("down", "up")]
            b.send({"t": "input", "id": cast, "evs": field + keys})
            want = 'textbox "Field" = "hi"' if cast == 310 else 'textbox "Field" = "hihi"'
            deadline = time.monotonic() + 10
            text = ""
            while want not in text and time.monotonic() < deadline:
                text = ok(b.ask(next(read_ids), "thr_input", "read"), "the field is read")["text"]
                b.drop_images()
                time.sleep(0.2)
            expect(want in text, f"at {size} the keys typed into the field the press focused", text)
            # The delay from a press to the first image that shows it: the page changes only on a press.
            b.drop_images()
            b.settle(cast)
            delays = []
            for _ in range(10):
                pad = [{"k": "mouse", "type": t, "x": 0.75, "y": 0.75, "button": "left", "clicks": 1, "mods": 0}
                       for t in ("down", "up")]
                pressed = time.monotonic()
                b.send({"t": "input", "id": cast, "evs": pad})
                m = b.image(cast, f"the image after a press at {size}", 10)
                delays.append((time.monotonic() - pressed) * 1000)
                b.send({"t": "seen", "id": cast, "seq": m["seq"]})
                b.settle(cast)
            delays.sort()
            print(f"measure: at {size} ({width}x{height}) the first image after a press arrived in "
                  f"{delays[len(delays) // 2]:.0f} ms (median of {len(delays)}), {delays[-1]:.0f} ms at most, "
                  "the press's input and the image both carried over the session", flush=True)
            b.send({"t": "uncast", "id": cast})
        # Input for a cast that ended goes nowhere.
        b.send({"t": "input", "id": 311, "evs": keys})
        time.sleep(1)
        expect('textbox "Field" = "hihi"' in ok(b.ask(312, "thr_input", "read"), "the field is read again")["text"],
               "input for a cast that ended reaches no window")
        b.drop_images()
        for n, win in enumerate(("thr_article", "thr_cast", "thr_input", "thr_focus")):
            expect(ok(b.ask(320 + n, win, "close"), f"the window {win} is closed") == {"closed": True},
                   f"the cast's window {win} is closed, so the windows counted below are the operations' own")

        # ————— each operation —————
        refused(b.ask(10, "thr_ops", "read"), "no_window", "a read before any page has no window")
        refused(b.ask(11, "thr_ops", "open", {"url": "file:///etc/passwd"}), "bad_url", "an open of a file is refused")
        refused(b.ask(12, "thr_ops", "open", {"url": "http://169.254.169.254/"}), "unreachable",
                "an open of an address the guard refuses answers that the page could not be loaded")
        # An open that fails leaves no window of its own, so the host's
        # count of the windows that showed a page counts every one standing.
        for n in range(5):
            refused(b.ask(30 + n, f"thr_fail{n}", "open", {"url": "http://169.254.169.254/"}), "unreachable",
                    f"a failed open in window thr_fail{n} answers that the page could not be loaded")
        for n in range(5):
            refused(b.ask(35 + n, f"thr_fail{n}", "read"), "no_window", f"the failed open left no window thr_fail{n}")
        if os.environ.get("CYFR_TEST_OFFLINE") == "1":
            print("skip: an open of a public page needs the public network (CYFR_TEST_OFFLINE=1)", flush=True)
        else:
            opened = ok(b.ask(13, "thr_ops", "open", {"url": "https://example.com/"}), "a public page opens")
            expect(opened == {"url": "https://example.com/", "title": "Example Domain"},
                   "the open answers once the page has loaded, with its address and title", opened)
        shown = ok(b.put_html(14, "thr_ops", PROBE_PAGE), "a page Aqua wrote is shown")
        expect(shown["title"] == "Probe page", "it answers its title", shown)
        text = ok(b.ask(15, "thr_ops", "read"), "the page is read")["text"]
        expect('heading "Before"' in text, "the read has the page's heading", text)
        button, field = ref_of(text, "button", "Change"), ref_of(text, "textbox", "Name")
        clicked = ok(b.ask(16, "thr_ops", "click", {"ref": button}), "the button is clicked")
        expect(clicked["title"] == "Probe page", "a click answers where the window is", clicked)
        text = ok(b.ask(17, "thr_ops", "read"), "the page is read again")["text"]
        expect('heading "After"' in text, "the next read sees what the click changed", text)
        expect(ok(b.ask(18, "thr_ops", "type", {"ref": field, "text": "hello"}), "text is typed") == {},
               "a type answers nothing more")
        expect(ok(b.ask(19, "thr_ops", "key", {"key": "Backspace"}), "a key is pressed") == {},
               "a key answers nothing more")
        text = ok(b.ask(20, "thr_ops", "read"), "the page is read a third time")["text"]
        expect(f'[{field}] textbox "Name" = "hell"' in text, "the typed text and the key reached the field", text)
        refused(b.ask(21, "thr_ops", "key", {"key": "F13"}), "bad_key", "a key the browser does not press is refused")
        refused(b.ask(22, "thr_ops", "click", {"ref": "999999"}), "bad_ref", "a ref no node has is refused")
        refused(b.ask(23, "thr_ops", "dance"), "bad_request", "an operation the browser does not do is refused")
        shot = ok(b.ask(24, "thr_ops", "screenshot"), "a screenshot is taken")
        expect(png_size(base64.b64decode(shot["png"], validate=True)) == (shot["width"], shot["height"])
               and shot["width"] == 1280, "the screenshot is a PNG of the window's size", [shot["width"], shot["height"]])
        expect(ok(b.ask(25, "thr_ops", "close"), "the window is closed") == {"closed": True}, "close answers it closed")
        expect(ok(b.ask(26, "thr_ops", "close"), "a closed window is closed again") == {"closed": False},
               "closing it again answers there was none")
        refused(b.ask(27, "thr_ops", "read"), "no_window", "a closed window has no page to read")

        # ————— what the box holds —————
        processes = [p for p in stack.processes() if is_chrome(p["cmd"])]
        uid = processes[0]["uids"][0]
        driver = next(p["pid"] for p in stack.under_uid(uid) if p["cmd"].startswith("cyfr-browser"))
        expect(KEPT_FIRST <= uid <= KEPT_LAST and all(p["uids"] == [uid] * 4 for p in processes),
               "every Chrome process runs under the browser's kept uid", processes)
        main_chrome = next(p for p in processes if "--type=" not in p["cmd"])
        expect("--remote-debugging-pipe" in main_chrome["cmd"] and "--remote-debugging-port" not in main_chrome["cmd"]
               and f"--user-data-dir={KEPT_ROOT}/{BROWSER_HOME}/chrome" in main_chrome["cmd"],
               "Chrome runs on its debugging pipe with its profile in the kept home, and no debugging port",
               main_chrome["cmd"])
        profile = f"{KEPT_ROOT}/{BROWSER_HOME}/chrome"
        found = imagesuite.read_word(stack.exec(f"test -d {profile}/Default && echo present || echo absent",
                                                user=str(uid)), ("present", "absent"), "the profile")
        expect(found == "present", "the browser's uid holds Chrome's profile in its kept home")
        other = c.mcp(OWNER, "probe", key="other", home_id=OTHER_HOME)
        status, whoami = other.call("whoami", {})
        other_uid = json.loads(whoami["result"]["content"][0]["text"])["uid"]
        expect(other_uid != uid and KEPT_FIRST <= other_uid <= KEPT_LAST, "another kept home has another uid",
               [uid, other_uid])
        for path in [profile, f"{profile}/Default/Cookies", f"{KEPT_ROOT}/{BROWSER_HOME}"]:
            status, answer = other.call("read_path", {"path": path})
            read = answer["result"]["content"][0]["text"]
            expect('"ok":false' in read and "EACCES" in read, f"a program in another kept home cannot read {path}", read)
        listening = tcp_listeners(stack)
        expect(any(port == PORT for port, _ in listening), "the TCP tables show the service's own listener", listening)
        expect(not [port for port, owner in listening if owner == uid],
               "nothing of the browser's uid listens on a TCP port", listening)

        # ————— memory with one, three and six windows —————
        expect(ok(b.ask(99, "thr_big", "close"), "the megabyte page's window is closed") == {"closed": True},
               "the window measured apart from those below is closed")
        for count in (1, 3, 6):
            keep_lease(c)
            for n in range(count):
                ok(b.put_html(100 + count * 10 + n, f"thr_m{n}", article(n)), f"window {n} shows a page")
            time.sleep(2)
            print(f"measure: Chrome with {count} window{'s' if count > 1 else ''} of a realistic page: "
                  f"{memory(stack, uid, driver)}", flush=True)
        closed = ok(b.ask(200, "", "close_all"), "every window is closed")
        expect(closed == {"closed": 6}, "closing every window answers how many there were", closed)
        b.close()
        eventually(lambda: not stack.under_uid(uid), "the browser's processes to end with its session")

        pages(stack, c, uid)

        expect(not [p for p in chrome_processes(stack, uid) if version not in p["cmd"]],
               "the Chrome that ran is the one the home holds", version)

        # ————— a short keep, on a restart that fetches nothing —————
        s = Host(stack, c, BROWSER_HOME, ["--keep-ms", str(SHORT_KEEP_MS)])
        expect(s.hello()["keep_ms"] == SHORT_KEEP_MS, "a driver started with --keep-ms says so")
        expect(in_store(stack, BROWSER_HOME) == fetched,
               "a restart reuses the home's Chrome: the same version folder, no check of the list, nothing staged",
               [fetched, in_store(stack, BROWSER_HOME)])
        s.send_put(1, "thr_short", [("index.html", "text/html", PROBE_PAGE.encode())], root_of("page"))
        first = s.take(lambda m: m["t"] == "res" and m["id"] == 1, "the unacknowledged response")
        s.send({"t": "again", "id": 1, "seq": 0})
        again = s.take(lambda m: m["t"] == "res" and m["id"] == 1, "the response sent again")
        expect(again == first, "again within the keep sends the response again", [first, again])
        time.sleep(SHORT_KEEP_MS / 1000 + 1.5)
        s.send({"t": "again", "id": 1, "seq": 0})
        expect(s.take(lambda m: m["t"] in ("res", "gone"), "the answer to again past the keep") == {"t": "gone", "id": 1},
               "a response asked for again after its keep is gone")
        s.send({"t": "again", "id": 77, "seq": 0})
        expect(s.take(lambda m: m["t"] in ("res", "gone"), "the answer to again for an unknown id") == {"t": "gone", "id": 77},
               "a response the driver never had is gone")
        s.close()
        eventually(lambda: not stack.under_uid(uid), "the short keep's processes to end with its session")

        # ————— a profile with open pages starts empty —————
        # A Chrome that ends abruptly with a page open, as a crash or its memory bound leaves a profile, in a profile
        # set to continue where it left off: a later start loads nothing on its own account, so no session it
        # writes holds that page.
        if os.environ.get("CYFR_TEST_OFFLINE") == "1":
            print("skip: a profile's last session needs a public page to hold (CYFR_TEST_OFFLINE=1)", flush=True)
        else:
            token = f"cyfr-restore-{os.urandom(6).hex()}"
            profile_dir = f"{KEPT_ROOT}/{BROWSER_HOME}/chrome/Default"
            sessions = lambda: set(as_home(stack, BROWSER_HOME, f"ls {profile_dir}/Sessions 2>/dev/null; true",
                                           "the profile's sessions").split())
            holding = lambda names: [n for n in names if as_home(
                stack, BROWSER_HOME, f"grep -a -c {token} {profile_dir}/Sessions/{n} || true", "a session's pages").strip() != "0"]
            as_home(stack, BROWSER_HOME,
                    f"cd {profile_dir} && if grep -q '\"session\":{{' Preferences; "
                    f"then sed -i 's/\"session\":{{/\"session\":{{\"restore_on_startup\":1,/' Preferences; "
                    f"else sed -i 's/^{{/{{\"session\":{{\"restore_on_startup\":1}},/' Preferences; fi",
                    "the profile set to continue where it left off")
            r = Host(stack, c, BROWSER_HOME)
            expect("error" not in r.hello(), "a session that will end with a page open starts")
            ok(r.ask(1, "thr_restore", "open", {"url": f"https://example.com/?{token}"}), "a page is open")
            eventually(lambda: holding(sessions()), "the profile's session to hold the open page", 30)
            main_pids = [p["pid"] for p in chrome_processes(stack, uid) if "--type=" not in p["cmd"]]
            as_home(stack, BROWSER_HOME, f"kill -9 {' '.join(map(str, main_pids))}", "Chrome ended abruptly")
            eventually(lambda: (r.read(1_000), not r.running)[1], "the driver to end with its Chrome")
            eventually(lambda: not stack.under_uid(uid), "that session's processes to end")
            before = sessions()
            expect(holding(before), "the profile's last session holds the open page", sorted(before))
            again = Host(stack, c, BROWSER_HOME)
            expect("error" not in again.hello(), "the profile with an open page starts")
            time.sleep(5)
            written = sessions() - before
            expect(not holding(written), "a later start reopens none of the last session's pages", sorted(written))
            again.close()
            eventually(lambda: not stack.under_uid(uid), "the later session's processes to end")

        # ————— it reaches nothing by itself —————
        # Chrome's own network log over a start with nothing asked of it: no request leaves.
        net_log = f"{KEPT_ROOT}/{BROWSER_HOME}/netlog.json"
        n = Host(stack, c, BROWSER_HOME, ["--net-log", net_log])
        expect("error" not in n.hello(), "a start that logs Chrome's network says hello")
        idle_until = time.monotonic() + QUIET_S
        while time.monotonic() < idle_until:
            n.read(1_000)
        n.close()
        eventually(lambda: not stack.under_uid(uid), "that session's processes to end")
        leaving = net_log_leaving(as_home(stack, BROWSER_HOME, f"cat {net_log}", "Chrome's network log"))
        expect(leaving == [], f"over {QUIET_S} s with nothing asked, Chrome reaches nothing by itself", leaving)
        as_home(stack, BROWSER_HOME, f"rm {net_log}", "the network log removed")
        print(f"measure: Chrome's network log over {QUIET_S} s of a start with nothing asked: no request", flush=True)

        # ————— its Chrome, fetched —————
        # A day after the last check, with a list that cannot be reached: the home's Chrome starts.
        as_home(stack, BROWSER_HOME, f"touch -d '2 days ago' {store(BROWSER_HOME)}/checked",
                "the last check made two days old")
        before = in_store(stack, BROWSER_HOME)
        u = Host(stack, c, BROWSER_HOME, ["--source", UNREACHABLE])
        expect("error" not in u.hello(), "with its list unreachable, a home that holds a Chrome says hello")
        shown = ok(u.put_html(1, "thr_unreachable", PROBE_PAGE), "and its Chrome shows a page")
        expect(shown["title"] == "Probe page", "the page answers its title", shown)
        after = in_store(stack, BROWSER_HOME)
        expect(after["versions"] == before["versions"] and not after["staging"]
               and after["checked"] > before["checked"],
               "the list was asked, did not answer, and the Chrome in the home started unchanged", [before, after])
        u.close()
        eventually(lambda: not stack.under_uid(uid), "that session's processes to end")

        # The home holds its Chrome and its profile, with room for a second Chrome and its archive being staged.
        used = home_bytes(stack, BROWSER_HOME)
        chrome_bytes = home_bytes(stack, BROWSER_HOME, f"/cyfr-browser/versions/{version}")
        report = c.program(OWNER, "browser")
        expect(not report["over_cap"] and used + 2 * chrome_bytes < HOME_MAX_BYTES,
               "the home holds one Chrome and its profile within its bound, with room for a second being staged",
               [used, chrome_bytes, HOME_MAX_BYTES, report])
        print(f"measure: the home holds {used / 1e6:.0f} MB, its Chrome {chrome_bytes / 1e6:.0f} MB, "
              f"of a {HOME_MAX_BYTES >> 20} MiB bound", flush=True)

        # A fresh home whose list cannot be reached: one sentence, and nothing kept.
        f = Host(stack, c, FETCHLESS_HOME, ["--source", UNREACHABLE])
        said = f.hello()
        expect(said.get("error") == NOT_DOWNLOADED, "a home with no Chrome and no list says it could not be downloaded",
               said)
        eventually(lambda: (f.read(1_000), not f.running)[1], "the refusing driver's session to end")
        expect(f.exit_code == 1 and not in_store(stack, FETCHLESS_HOME)["versions"]
               and not in_store(stack, FETCHLESS_HOME)["staging"], "it exits 1 and the home holds no Chrome",
               [f.exit_code, in_store(stack, FETCHLESS_HOME)])

        # The same home, offered a truncated archive where the storage would hold it: never published.
        archive = base64.b64encode(truncated_archive()).decode()
        source = f"{KEPT_ROOT}/{FETCHLESS_HOME}/source"
        as_home(stack, FETCHLESS_HOME,
                f"mkdir {source} && printf 999.0.0.1 > {source}/LATEST_RELEASE_STABLE && for p in linux64 linux-arm64; do "
                f"mkdir -p {source}/999.0.0.1/$p && echo {archive} | base64 -d > {source}/999.0.0.1/$p/chrome-$p.zip; done",
                "the truncated archive and its list written")
        t = Host(stack, c, FETCHLESS_HOME, ["--source", f"file://{source}/LATEST_RELEASE_STABLE",
                                            "--storage", f"file://{source}"])
        said = t.hello()
        expect(said.get("error") == NOT_DOWNLOADED, "a truncated archive is not a Chrome: the same sentence", said)
        eventually(lambda: (t.read(1_000), not t.running)[1], "that driver's session to end")
        kept = in_store(stack, FETCHLESS_HOME)
        expect(not kept["versions"] and not kept["staging"], "and nothing of it is published or left staged", kept)

        # ————— a Chrome that cannot start —————
        broken = Host(stack, c, BROKEN_HOME, ["--chrome", "/nonexistent/chromium"])
        said = broken.hello()
        expect(set(said) == {"t", "v", "chunk", "keep_ms", "error"} and said["error"].endswith("."),
               "a driver whose Chrome cannot start says hello with an error", said)
        eventually(lambda: (broken.read(1_000), not broken.running)[1], "the broken driver's session to end")
        expect(broken.exit_code == 1, "and exits 1", broken.exit_code)
    finally:
        stack.down()


if __name__ == "__main__":
    main()

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

- The first exchange: the driver says hello once Chrome answers; a `page`
  of about a megabyte of html and a `read` whose text is over a megabyte
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
- Each operation once: open (a public page unless CYFR_TEST_OFFLINE=1, an
  address the guard refuses, and an address of another scheme), five
  failed opens that leave no window, page,
  read, click (a button whose click changes the page, seen by the next
  read), type, key, screenshot (a PNG that decodes) and close, with the
  errors no_window, bad_ref and bad_key.
- Another program in another kept home, under another uid, cannot read the
  browser's profile, nothing of the browser's uid listens on a TCP port,
  and Chrome runs on its debugging pipe with no debugging port.
- A driver whose Chrome cannot start says hello with an error and exits 1.
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
the time and frame count of the megabyte read, the first start's time and
the home's bytes.

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

OWNER = owner_of("browser")
BROWSER_HOME, FETCHLESS_HOME, BROKEN_HOME, OTHER_HOME = (
    f"mcp_browser-{name}" for name in ("chrome", "fetchless", "broken", "other"))
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

    def ask(self, id, win, op, args=None):
        self.send({"t": "req", "id": id, "win": win, "op": op, "args": args or {}})
        return self.response(id)[0]

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
        shown = ok(b.ask(1, "thr_big", "page", {"html": html}), "a page of about a megabyte of html is shown")
        page_s = time.monotonic() - started
        expect(shown == {"url": "about:blank", "title": "A long page"}, "the page answers its address and title", shown)
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
        shown = ok(b.ask(14, "thr_ops", "page", {"html": PROBE_PAGE}), "a page Aqua wrote is shown")
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
                ok(b.ask(100 + count * 10 + n, f"thr_m{n}", "page", {"html": article(n)}), f"window {n} shows a page")
            time.sleep(2)
            print(f"measure: Chrome with {count} window{'s' if count > 1 else ''} of a realistic page: "
                  f"{memory(stack, uid, driver)}", flush=True)
        closed = ok(b.ask(200, "", "close_all"), "every window is closed")
        expect(closed == {"closed": 6}, "closing every window answers how many there were", closed)
        b.close()
        eventually(lambda: not stack.under_uid(uid), "the browser's processes to end with its session")

        expect(not [p for p in chrome_processes(stack, uid) if version not in p["cmd"]],
               "the Chrome that ran is the one the home holds", version)

        # ————— a short keep, on a restart that fetches nothing —————
        s = Host(stack, c, BROWSER_HOME, ["--keep-ms", str(SHORT_KEEP_MS)])
        expect(s.hello()["keep_ms"] == SHORT_KEEP_MS, "a driver started with --keep-ms says so")
        expect(in_store(stack, BROWSER_HOME) == fetched,
               "a restart reuses the home's Chrome: the same version folder, no check of the list, nothing staged",
               [fetched, in_store(stack, BROWSER_HOME)])
        s.send({"t": "req", "id": 1, "win": "thr_short", "op": "page", "args": {"html": PROBE_PAGE}})
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

        # ————— its Chrome, fetched —————
        # A day after the last check, with a list that cannot be reached: the home's Chrome starts.
        as_home(stack, BROWSER_HOME, f"touch -d '2 days ago' {store(BROWSER_HOME)}/checked",
                "the last check made two days old")
        before = in_store(stack, BROWSER_HOME)
        u = Host(stack, c, BROWSER_HOME, ["--source", UNREACHABLE])
        expect("error" not in u.hello(), "with its list unreachable, a home that holds a Chrome says hello")
        shown = ok(u.ask(1, "thr_unreachable", "page", {"html": PROBE_PAGE}), "and its Chrome shows a page")
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

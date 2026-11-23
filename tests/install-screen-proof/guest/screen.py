#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Reading the install-and-screen proof's guest display and pressing what
# it shows, run inside the QEMU container (tests/install-screen-proof/
# Dockerfile) as a person at the box would: by what is on the screen, with
# the guest's USB tablet (QMP's absolute pointer) and nothing of the page's
# insides. Each reading is a fresh screendump read by tesseract.
#   screen.py SOCKET shows TEXT
#       exits 0 when TEXT, one or more words, is on the display
#   screen.py SOCKET press TEXT [last]
#       presses the middle of TEXT where it is on the display (its last
#       place with last), printing where; exits 1 when it is not there
#   screen.py SOCKET tap CHARACTERS
#       taps each character, then Enter for a newline, on the on-screen
#       keyboard's keys, read from the display: a character no key shows
#       is looked for on the keyboard's next layers, reached by its layer
#       key, the bottom row's first; exits 1 when one is on no layer
#   screen.py SOCKET hides TEXT SECONDS
#       presses TEXT and prints the milliseconds until what the display
#       showed above the keyboard is gone, timed from the press; exits 1
#       when it is not gone within SECONDS
#   screen.py SOCKET words
#       prints every word the display shows, with where, for the evidence
# A display, a QMP or a tesseract that fails exits 2, so that no failed
# read passes for words not shown.
# Words are read on the display's grey, on its inverse and on its bright
# pixels alone, twice its size: light text on dark, dark on light and
# white on colour alike. A key is a uniform
# grey box in the display's bottom third, its label cropped to its own
# bright pixels and read alone. Digits, words and Enter read reliably;
# single letters do not (i, l and j; g and q), so nothing here relies on
# a letter key, and a digit is tapped only on a layer that shows all ten,
# a letter key read as a digit apart.
import os
import subprocess
import sys
import tempfile
import time

from PIL import Image, ImageOps

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qmp import Qmp, QmpError  # noqa: E402


def dump(qmp):
    """The display now, as an RGB image."""
    path = os.path.join(tempfile.gettempdir(), f"screen-{os.getpid()}.ppm")
    qmp.call("screendump", {"filename": path, "format": "ppm"})
    try:
        with Image.open(path) as img:
            return img.convert("RGB")
    finally:
        os.unlink(path)


def tesseract(img, psm):
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "read.png")
        img.save(path)
        out = subprocess.run(["tesseract", path, "-", "--psm", str(psm), "tsv"],
                             capture_output=True, text=True, check=True).stdout
    rows = []
    for line in out.splitlines()[1:]:
        f = line.split("\t")
        if len(f) == 12 and f[11].strip() and float(f[10]) >= 0:
            rows.append((f[11].strip(), int(f[6]), int(f[7]), int(f[8]), int(f[9]), (f[2], f[3], f[4])))
    return rows


def words(img, scale=2):
    """Each word the display shows, in reading order per line: (text, x0, y0,
    x1, y1, line) in display pixels."""
    grey = img.convert("L").resize((img.width * scale, img.height * scale), Image.LANCZOS)
    found = []
    # The grey, its inverse, and its bright pixels alone, black on white
    # (white on a coloured button).
    for n, variant in enumerate((grey, ImageOps.invert(grey), grey.point(lambda v: 0 if v > 200 else 255))):
        for text, x, y, w, h, line in tesseract(variant, 11):
            found.append((text, x // scale, y // scale, (x + w) // scale, (y + h) // scale, (n,) + line))
    return found


def plain(text):
    return "".join(c for c in text.lower() if c.isalnum())


def places(img, phrase):
    """Each place the display shows phrase: its words, in order, on one line."""
    want = [plain(w) for w in phrase.split()]
    lines = {}
    for w in words(img):
        lines.setdefault(w[5], []).append(w)
    found = []
    for ws in lines.values():
        texts = [plain(w[0]) for w in ws]
        for i in range(len(ws) - len(want) + 1):
            if texts[i:i + len(want)] == want:
                span = ws[i:i + len(want)]
                found.append((min(w[1] for w in span), min(w[2] for w in span),
                              max(w[3] for w in span), max(w[4] for w in span)))
    return sorted(set(found), key=lambda b: (b[1], b[0]))


def keys(img):
    """The on-screen keyboard's keys, each (label, x0, y0, x1, y1)."""
    W, H = img.size
    px = img.load()

    def grey(x, y):
        r, g, b = px[x, y]
        return r == g == b and 25 <= r <= 70

    boxes = []
    for y in range(H * 2 // 3, H, 2):
        for x in range(0, W, 2):
            if not grey(x, y) or any(b[0] <= x <= b[2] and b[1] <= y <= b[3] for b in boxes):
                continue
            x1, y1 = x, y
            while x1 + 1 < W and grey(x1 + 1, y):
                x1 += 1
            while y1 + 1 < H and grey(x, y1 + 1):
                y1 += 1
            if x1 - x >= 20 and y1 - y >= 15:
                boxes.append((x, y, x1, y1))
    out = []
    for x0, y0, x1, y1 in boxes:
        inner = img.crop((x0 + 4, y0 + 4, x1 - 3, y1 - 3)).convert("L")
        box = inner.point(lambda v: 255 if v > 110 else 0).getbbox()
        if box is None:
            out.append(("", x0, y0, x1, y1))
            continue
        glyph = ImageOps.invert(inner.crop(box))
        glyph = glyph.resize((glyph.width * 6, glyph.height * 6), Image.LANCZOS).point(lambda v: 0 if v < 150 else 255)
        glyph = ImageOps.expand(glyph, border=40, fill=255)
        read = tesseract(glyph, 10 if box[2] - box[0] < 20 else 7)
        out.append((" ".join(t for t, *_ in read), x0, y0, x1, y1))
    return out


def point(qmp, img, x, y):
    W, H = img.size
    qmp.call("input-send-event", {"events": [
        {"type": "abs", "data": {"axis": "x", "value": round(x * 32767 / (W - 1))}},
        {"type": "abs", "data": {"axis": "y", "value": round(y * 32767 / (H - 1))}}]})


def press(qmp, img, x, y):
    """A press and release of the tablet's left button at (x, y), then the
    pointer moved to the display's bottom right corner, where its arrow is
    drawn off the display, as a finger lifts: left where it pressed, it
    covers the words the next read looks for."""
    point(qmp, img, x, y)
    time.sleep(0.05)
    qmp.call("input-send-event", {"events": [{"type": "btn", "data": {"down": True, "button": "left"}}]})
    time.sleep(0.08)
    qmp.call("input-send-event", {"events": [{"type": "btn", "data": {"down": False, "button": "left"}}]})
    time.sleep(0.05)
    point(qmp, img, img.width - 1, img.height - 1)


def middle(box):
    return (box[0] + box[2]) // 2, (box[1] + box[3]) // 2


DIGITS = set("0123456789")


def tap(qmp, characters):
    for c in characters:
        label = "enter" if c == "\n" else plain(c)
        for _ in range(4):
            img = dump(qmp)
            ks = keys(img)
            match = [k for k in ks if plain(k[0]) == label]
            if label in DIGITS and {k[0] for k in ks} & DIGITS != DIGITS:
                match = []
            if match:
                press(qmp, img, *middle(match[0][1:]))
                time.sleep(0.25)
                break
            bottom = max(k[2] for k in ks) if ks else None
            row = sorted((k for k in ks if k[2] == bottom), key=lambda k: k[1])
            if not row:
                raise QmpError("the display shows no on-screen keyboard")
            press(qmp, img, *middle(row[0][1:]))
            time.sleep(0.5)
        else:
            raise QmpError(f"no key of the keyboard's layers shows {c!r}")


def ink(img, band):
    """The display's pixels above the keyboard (band rows) that are not its
    commonest colour: what it shows there."""
    top = img.crop((0, 0, img.width, band)).reduce(4)
    colours = top.getcolors(top.width * top.height)
    ground = max(colours)[1]
    data = top.getdata()
    return {i for i, p in enumerate(data) if p != ground}, data


def hides(qmp, phrase, seconds):
    img = dump(qmp)
    found = places(img, phrase)
    if not found:
        raise QmpError(f"the display does not show {phrase!r}")
    band = min((k[2] for k in keys(img)), default=img.height) - 1
    shown, before = ink(img, band)
    pressed = time.monotonic()
    press(qmp, img, *middle(found[0]))
    while time.monotonic() - pressed < seconds:
        now = dump(qmp).crop((0, 0, img.width, band)).reduce(4).getdata()
        kept = sum(1 for i in shown if now[i] == before[i])
        # Pressing changes the label's own pixels at most; a hide takes
        # what was shown, so less than half of it is still there.
        if kept * 2 < len(shown):
            print(round((time.monotonic() - pressed) * 1000))
            return True
    return False


def main(argv):
    if len(argv) < 3:
        print("usage: screen.py SOCKET shows TEXT | press TEXT [last] | tap CHARACTERS | hides TEXT SECONDS | words", file=sys.stderr)
        return 64
    try:
        qmp = Qmp(argv[1], float(os.environ.get("QMP_WAIT", "30")))
        command = argv[2]
        if command == "shows" and len(argv) == 4:
            return 0 if places(dump(qmp), argv[3]) else 1
        if command == "press" and len(argv) in (4, 5):
            img = dump(qmp)
            found = places(img, argv[3])
            if not found:
                print(f"screen.py: the display does not show {argv[3]!r}", file=sys.stderr)
                return 1
            x, y = middle(found[-1] if argv[4:] == ["last"] else found[0])
            press(qmp, img, x, y)
            print(f"{x} {y}")
            return 0
        if command == "tap" and len(argv) == 4:
            tap(qmp, argv[3].replace("\\n", "\n"))
            return 0
        if command == "hides" and len(argv) == 5:
            return 0 if hides(qmp, argv[3], float(argv[4])) else 1
        if command == "words" and len(argv) == 3:
            for w in words(dump(qmp)):
                print(f"{w[1]},{w[2]} {w[3]},{w[4]} {w[0]}")
            return 0
        print(f"screen.py: unknown command {command!r}", file=sys.stderr)
        return 64
    except (OSError, QmpError, ValueError, subprocess.CalledProcessError) as error:
        print(f"screen.py: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

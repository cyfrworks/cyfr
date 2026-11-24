# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Reading the box's screen and pressing what it shows, run inside labwc
as the box's account (box.sh): by what is on the output, read by tesseract
on grim's picture of it, and pressed by tap.py's virtual pointer, with
nothing of a page's insides.

  screen.py shows TEXT     exits 0 when TEXT, one or more words, is shown
  screen.py bar TEXT       exits 0 when TEXT is shown within the output's
                           top BAR pixels, Prism's top bar, where the
                           device's pages show nothing: Prism's Lock read
                           there is Prism shown, not the device's own Lock
  screen.py press TEXT     presses the middle of TEXT where it is shown
                           first, top to bottom; exits 1 when it is not
  screen.py words LIST     prints the six words of LIST (one word a line,
                           BIP-0039's English) a line shows and nothing else,
                           the passphrase a box without a chip shows once,
                           as two readings of the output agree on them;
                           exits 1 when they do not
A picture or a tesseract that fails exits 2, so that no failed read
passes for words not shown. Words are read on the output's grey, on its
inverse and on its bright pixels alone, twice its size: the app's light
words on its dark pages and white on its buttons' colour alike; a word is
compared by its letters and digits alone."""

import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageOps

HERE = os.path.dirname(os.path.abspath(__file__))
# Prism's top bar, 48 pixels high at the top of the content.
BAR = 48


def picture():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "screen.png")
        subprocess.run(["grim", "-t", "png", path], check=True, capture_output=True)
        with Image.open(path) as img:
            return img.convert("RGB")


def tesseract(img):
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "read.png")
        img.save(path)
        out = subprocess.run(["tesseract", path, "-", "--psm", "11", "tsv"],
                             capture_output=True, text=True, check=True).stdout
    rows = []
    for line in out.splitlines()[1:]:
        f = line.split("\t")
        if len(f) == 12 and f[11].strip() and float(f[10]) >= 0:
            rows.append((f[11].strip(), int(f[6]), int(f[7]), int(f[8]), int(f[9]), (f[2], f[3], f[4])))
    return rows


def words(img, scale=2):
    """Each word shown, in reading order per line: (text, x0, y0, x1, y1,
    line) in output pixels."""
    grey = img.convert("L").resize((img.width * scale, img.height * scale), Image.LANCZOS)
    found = []
    # The grey, its inverse, and its bright pixels alone, black on white
    # (white on a coloured button).
    for n, variant in enumerate((grey, ImageOps.invert(grey), grey.point(lambda v: 0 if v > 200 else 255))):
        for text, x, y, w, h, line in tesseract(variant):
            found.append((text, x // scale, y // scale, (x + w) // scale, (y + h) // scale, (n,) + line))
    return found


def plain(text):
    return "".join(c for c in text.lower() if c.isalnum())


def lines(img):
    by = {}
    for w in words(img):
        by.setdefault(w[5], []).append(w)
    return by.values()


def places(img, phrase):
    """Each place phrase is shown: its words, in order, on one line."""
    want = [plain(w) for w in phrase.split()]
    found = []
    for ws in lines(img):
        texts = [plain(w[0]) for w in ws]
        for i in range(len(ws) - len(want) + 1):
            if texts[i:i + len(want)] == want:
                span = ws[i:i + len(want)]
                found.append((min(w[1] for w in span), min(w[2] for w in span),
                              max(w[3] for w in span), max(w[4] for w in span)))
    return sorted(set(found), key=lambda b: (b[1], b[0]))


def passphrase(img, listed):
    """The line that is six listed words and nothing else, as at least two
    of the readings agree on it, or None: prose of listed words runs on
    within its line ("keep this device where only people you trust")."""
    seen = {}
    for ws in lines(img):
        texts = [plain(w[0]) for w in ws]
        if len(texts) == 6 and all(t in listed for t in texts):
            seen.setdefault(" ".join(texts), set()).add(ws[0][5][0])
    agreed = [p for p, readings in seen.items() if len(readings) >= 2]
    return agreed[0] if len(agreed) == 1 else None


def tap(img, x, y):
    """tap.py takes a 1280x720 output's place."""
    subprocess.run([sys.executable, "-I", os.path.join(HERE, "tap.py"),
                    str(x * 1280 // img.width), str(y * 720 // img.height)], check=True)


def main(argv):
    try:
        img = picture()
        if argv[:1] == ["shows"] and len(argv) == 2:
            return 0 if places(img, argv[1]) else 1
        if argv[:1] == ["bar"] and len(argv) == 2:
            return 0 if any(y1 <= BAR for _, _, _, y1 in places(img, argv[1])) else 1
        if argv[:1] == ["press"] and len(argv) == 2:
            found = places(img, argv[1])
            if not found:
                return 1
            x0, y0, x1, y1 = found[0]
            tap(img, (x0 + x1) // 2, (y0 + y1) // 2)
            print(f"pressed {argv[1]!r} at {(x0 + x1) // 2},{(y0 + y1) // 2}")
            return 0
        if argv[:1] == ["words"] and len(argv) == 2:
            with open(argv[1]) as f:
                listed = {w.strip() for w in f if w.strip()}
            said = passphrase(img, listed)
            if said is None:
                return 1
            print(said)
            return 0
    except (OSError, subprocess.CalledProcessError) as e:
        print(f"screen.py: {e}", file=sys.stderr)
        return 2
    print("usage: screen.py shows TEXT | bar TEXT | press TEXT | words LIST", file=sys.stderr)
    return 64


sys.exit(main(sys.argv[1:]))

// A small proportional pixel face drawn for this village: caps 7 rows, descenders 2 more.
// Each glyph is its rows, top to bottom; its width is the row length. Strings render through a cache
// of offscreen canvases so a frame never repaints glyph by glyph.
(function () {
  const G = `
A .###. #...# #...# ##### #...# #...# #...#
B ####. #...# #...# ####. #...# #...# ####.
C .###. #...# #.... #.... #.... #...# .###.
D ####. #...# #...# #...# #...# #...# ####.
E ##### #.... #.... ####. #.... #.... #####
F ##### #.... #.... ####. #.... #.... #....
G .###. #...# #.... #.### #...# #...# .####
H #...# #...# #...# ##### #...# #...# #...#
I ### .#. .#. .#. .#. .#. ###
J ..## ...# ...# ...# ...# #..# .##.
K #...# #..#. #.#.. ##... #.#.. #..#. #...#
L #... #... #... #... #... #... ####
M #...# ##.## #.#.# #.#.# #...# #...# #...#
N #...# ##..# #.#.# #..## #...# #...# #...#
O .###. #...# #...# #...# #...# #...# .###.
P ####. #...# #...# ####. #.... #.... #....
Q .###. #...# #...# #...# #.#.# #..#. .##.#
R ####. #...# #...# ####. #.#.. #..#. #...#
S .###. #...# #.... .###. ....# #...# .###.
T ##### ..#.. ..#.. ..#.. ..#.. ..#.. ..#..
U #...# #...# #...# #...# #...# #...# .###.
V #...# #...# #...# #...# #...# .#.#. ..#..
W #...# #...# #...# #.#.# #.#.# ##.## #...#
X #...# #...# .#.#. ..#.. .#.#. #...# #...#
Y #...# #...# .#.#. ..#.. ..#.. ..#.. ..#..
Z ##### ....# ...#. ..#.. .#... #.... #####
a .... .... .##. ...# .### #..# .###
b #... #... ###. #..# #..# #..# ###.
c .... .... .### #... #... #... .###
d ...# ...# .### #..# #..# #..# .###
e .... .... .##. #..# #### #... .###
f ..## .#.. ###. .#.. .#.. .#.. .#..
g .... .... .### #..# #..# #..# .### ...# ###.
h #... #... ###. #..# #..# #..# #..#
i # . # # # # #
j .# .. .# .# .# .# .# .# #.
k #... #... #..# #.#. ##.. #.#. #..#
l #. #. #. #. #. #. .#
m ..... ..... ##.#. #.#.# #.#.# #.#.# #.#.#
n .... .... ###. #..# #..# #..# #..#
o .... .... .##. #..# #..# #..# .##.
p .... .... ###. #..# #..# #..# ###. #... #...
q .... .... .### #..# #..# #..# .### ...# ...#
r ... ... #.# ##. #.. #.. #..
s .... .... .### #... .##. ...# ###.
t .#. .#. ### .#. .#. .#. ..#
u .... .... #..# #..# #..# #..# .###
v ..... ..... #...# #...# #...# .#.#. ..#..
w ..... ..... #...# #...# #.#.# #.#.# .#.#.
x .... .... #..# #..# .##. #..# #..#
y .... .... #..# #..# #..# #..# .### ...# ###.
z .... .... #### ...# .##. #... ####
0 .###. #...# #..## #.#.# ##..# #...# .###.
1 ..#.. .##.. ..#.. ..#.. ..#.. ..#.. .###.
2 .###. #...# ....# ...#. ..#.. .#... #####
3 ##### ...#. ..#.. ...#. ....# #...# .###.
4 ...#. ..##. .#.#. #..#. ##### ...#. ...#.
5 ##### #.... ####. ....# ....# #...# .###.
6 ..##. .#... #.... ####. #...# #...# .###.
7 ##### ....# ...#. ..#.. .#... .#... .#...
8 .###. #...# #...# .###. #...# #...# .###.
9 .###. #...# #...# .#### ....# ...#. .##..
. . . . . . . #
, .. .. .. .. .. .. .# #.
: . . # . . # .
; .. .. .# .. .. .# #.
- .... .... .... #### .... .... ....
+ ..... ..#.. ..#.. ##### ..#.. ..#.. .....
/ ...# ...# ..#. ..#. .#.. .#.. #... #...
' # # . . . . .
" #.# #.# ... ... ... ... ...
! # # # # # . #
? .###. #...# ....# ...#. ..#.. ..... ..#..
( .# #. #. #. #. #. .#
) #. .# .# .# .# .# #.
% ##..# ##..# ...#. ..#.. .#... #..## #..##
° .##. #..# #..# .##. .... .... ....
· . . . # . . .
→ ...... ...#.. ....#. ###### ....#. ...#.. ......
← ...... ..#... .#.... ###### .#.... ..#... ......
✓ ...... .....# ....## #..##. ###... .#.... ......
× ..... #...# .#.#. ..#.. .#.#. #...# .....
♪ .### .#.# .#.. .#.. ##.. ##.. ....
▶ #... ##.. ###. #### ###. ##.. #...
= .... .... #### .... #### .... ....
_ ..... ..... ..... ..... ..... ..... ..... #####
* ..... #.#.# .###. ##### .###. #.#.# .....
< ..# .#. #.. #.. #.. .#. ..#
> #.. .#. ..# ..# ..# .#. #..
& .##.. #..#. .##.. .#... #.#.# #..#. .##.#
# .#.#. ##### .#.#. .#.#. ##### .#.#. .....
@ .###. #...# #.### #.#.# #.### #.... .####
`;
  const glyphs = new Map();
  for (const line of G.split('\n')) {
    if (!line.trim()) continue;
    const parts = line.split(' ');
    const ch = parts[0];
    const rows = parts.slice(1).filter(Boolean);
    glyphs.set(ch, { w: rows[0].length, rows });
  }
  glyphs.set(' ', { w: 3, rows: ['...'] });
  const alias = { '–': '-', '—': '-', '’': "'", '‘': "'", '“': '"', '”': '"', '…': '.', 'é': 'e', 'á': 'a' };
  const FONT_H = 9, ASC = 7;

  function glyph(ch) { return glyphs.get(ch) || glyphs.get(alias[ch]) || glyphs.get('?'); }
  function measure(str) {
    let w = 0;
    for (const ch of str) w += glyph(ch).w + 1;
    return Math.max(0, w - 1);
  }
  const cache = new Map();
  // Renders `str` once into its own canvas at scale `s` (whole pixels), in `color`; bold doubles columns.
  function render(str, color, s = 1, bold = false) {
    const key = str + '|' + color + '|' + s + '|' + (bold ? 1 : 0);
    let c = cache.get(key);
    if (c) return c;
    const w = measure(str) + (bold ? 1 : 0);
    c = document.createElement('canvas');
    c.width = Math.max(1, w * s); c.height = FONT_H * s;
    const g = c.getContext('2d');
    g.fillStyle = color;
    let x = 0;
    for (const ch of str) {
      const gl = glyph(ch);
      gl.rows.forEach((row, y) => {
        for (let i = 0; i < row.length; i++) if (row[i] === '#') {
          g.fillRect((x + i) * s, y * s, s, s);
          if (bold) g.fillRect((x + i + 1) * s, y * s, s, s);
        }
      });
      x += gl.w + 1;
    }
    if (cache.size > 1500) cache.clear();
    cache.set(key, c);
    return c;
  }
  // Draws text at (x, y) = top-left of the cap line. Options: s scale, shadow colour, align, bold.
  function text(ctx, str, x, y, color, o = {}) {
    const s = o.s || 1;
    str = String(str);
    const w = (measure(str) + (o.bold ? 1 : 0)) * s;
    if (o.align === 'center') x -= Math.floor(w / 2);
    else if (o.align === 'right') x -= w;
    x = Math.round(x); y = Math.round(y);
    if (o.shadow) ctx.drawImage(render(str, o.shadow, s, o.bold), x, y + s);
    if (o.outline) {
      const r = render(str, o.outline, s, o.bold);
      ctx.drawImage(r, x - s, y); ctx.drawImage(r, x + s, y); ctx.drawImage(r, x, y - s); ctx.drawImage(r, x, y + s);
    }
    ctx.drawImage(render(str, color, s, o.bold), x, y);
    return w;
  }
  // Greedy word wrap to a pixel width at scale s.
  function wrap(str, maxW, s = 1) {
    const out = [];
    for (const para of String(str).split('\n')) {
      let line = '';
      for (const word of para.split(' ')) {
        const t = line ? line + ' ' + word : word;
        if (measure(t) * s <= maxW || !line) line = t; else { out.push(line); line = word; }
      }
      out.push(line);
    }
    return out;
  }
  window.PixelFont = { text, measure: (s, k = 1) => measure(String(s)) * k, wrap, H: FONT_H, ASC };
})();

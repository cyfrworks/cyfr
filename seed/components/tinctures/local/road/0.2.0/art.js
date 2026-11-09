// Pixel art for the village: palette, sprites, and one painter per building. Everything is drawn in
// logical pixels; the canvas is scaled up with nearest-neighbour so a pixel stays a pixel. Every
// painter draws only what its state hands it; scene.js derives that state from the streams.
(function () {
  const P = {
    ink: '#1d1a17', paper: '#f4ecd6', paper2: '#e5d6b2', paperD: '#c9b68d',
    wood: '#6b4a2f', woodD: '#45301e', woodL: '#93694a',
    white: '#f4f1e8', whiteS: '#dcd5c4', whiteD: '#b5ad9b',
    ochre: '#e3b04b', ochreS: '#bf8d2e', pink: '#e7a198', pinkS: '#c47c72', mint: '#a9d8bd', mintS: '#7cb497',
    blue: '#2c64ad', blueL: '#c3d7f0', blueD: '#1b3f75',
    roof: '#c4553a', roofD: '#8a3424', roofL: '#de7c57',
    stone: '#aaa08e', stoneD: '#7a7161', stoneL: '#cbc2b0',
    grass: '#9ab35e', grassD: '#6c8a43', grassL: '#bfd27f', earth: '#b8936a', olive: '#5f7a45', oliveD: '#3f5530',
    river: '#3f84b5', riverL: '#86bfe0', riverD: '#2b5f88', far: '#8fa7b8', farD: '#71889b',
    tram: '#f2c230', tramD: '#b88d14', tramL: '#ffe58a',
    cobW: '#ebe6d8', cobK: '#3b3a3c', cobM: '#c8c1b1', cobD: '#a49d8d',
    red: '#d9443c', redD: '#9b2b25', amber: '#f2a33a', amberD: '#b9741c', green: '#5ab45b', greenD: '#357a37',
    aqua: '#36c9c0', aquaD: '#1f8f8a', aquaL: '#a5f2ea',
    capy: '#a8774c', capyD: '#7a5333', capyL: '#c99a6c', capyK: '#47301d', hat: '#7b4bb8', hatD: '#55308a', star: '#ffd75e',
    lamp: '#ffd76a', glow: 'rgba(255,214,120,0.28)', win: '#33425a', winL: '#ffcf6b', iron: '#2c2a2b',
  };

  const fill = (g, x, y, w, h, c) => { g.fillStyle = c; g.fillRect(Math.round(x), Math.round(y), w, h); };

  // ---- sprites -------------------------------------------------------------------------------
  const spriteCache = new Map();
  function sprite(g, rows, map, x, y, flip = false, key = null) {
    const k = key ? key + (flip ? '/f' : '') : null;
    let c = k && spriteCache.get(k);
    if (!c) {
      c = document.createElement('canvas');
      c.width = rows[0].length; c.height = rows.length;
      const cg = c.getContext('2d');
      rows.forEach((row, j) => {
        for (let i = 0; i < row.length; i++) {
          const col = map[row[i]];
          if (col) { cg.fillStyle = col; cg.fillRect(flip ? row.length - 1 - i : i, j, 1, 1); }
        }
      });
      if (k) spriteCache.set(k, c);
    }
    g.drawImage(c, Math.round(x), Math.round(y));
    return c;
  }

  // The timekeeper: CYFR's capybara in its wizard hat, facing right. 26 x 18, feet on the ground line.
  const CAPY_TOP = [
    '...................H......',
    '..................hH......',
    '..................hhs.....',
    '.................hhhH.....',
    '.................hhhhH....',
    '...............HHHHHHHH...',
    '.......lllll....dllllll...',
    '.....lbbbbbbbll.dbbbbbbb..',
    '...lbbbbbbbbbbbbbbbbbbbbb.',
    '..lbbbbbbbbbbbbbbbbbbkbbb.',
    '..bbbbbbbbbbbbbbbbbbbbbbbb',
    '.lbbbbbbbbbbbbbbbbbbbbbbbk',
    '.bbbbbbbbbbbbbbbbbbbbbbbb.',
    '.bbbbbbbbbbbbbbbbbbbddddd.',
    '.dbbbbbbbbbbbbbbbbbbd.....',
    '..dddddddddddddddddd......',
  ];
  const CAPY_LEGS = {
    stand: ['...dd..dd......dd..dd.....', '...kk..kk......kk..kk.....'],
    run1: ['..dd.....dd...dd.....dd...', '.kk.......kk.kk.......kk..'],
    run2: ['.....dddd.......dddd......', '.....kk.kk......kk.kk.....'],
    jump: ['....dddd.......dddd.......', '..........................'],
  };
  const CAPY_BLINK = CAPY_TOP.map((r, i) => (i === 9 ? r.replace('k', 'b') : r));
  const capyMap = { b: P.capy, l: P.capyL, d: P.capyD, k: P.capyK, h: P.hat, H: P.hatD, s: P.star };
  function capybara(g, x, y, o = {}) {
    const legs = CAPY_LEGS[o.pose || 'stand'];
    const rows = (o.blink ? CAPY_BLINK : CAPY_TOP).concat(legs);
    const bob = o.pose === 'run2' ? -1 : 0;
    if (o.flop) { sprite(g, rows.slice().reverse(), capyMap, x - 13, y - 18 + 4, o.flip, 'capy-flop'); return; }
    sprite(g, rows, capyMap, x - 13, y - 18 + bob, o.flip, 'capy-' + (o.pose || 'stand') + (o.blink ? '-b' : ''));
  }

  // Villagers: one body, palette per person. 8 x 13, feet on the ground line.
  const VILL = {
    stand: ['..hhhh..', '.hhhhhh.', '.hkkkkh.', '.kekkek.', '..kkkk..', '.ssssss.', 'ssssssss', 'kssssssk', '.ssssss.', '.pppppp.', '.pp..pp.', '.pp..pp.', '.oo..oo.'],
    walk1: ['..hhhh..', '.hhhhhh.', '.hkkkkh.', '.kekkek.', '..kkkk..', '.ssssss.', 'ssssssss', 'kssssssk', '.ssssss.', '.pppppp.', '.pp.pp..', 'pp...pp.', 'oo....oo'],
    walk2: ['..hhhh..', '.hhhhhh.', '.hkkkkh.', '.kekkek.', '..kkkk..', '.ssssss.', 'ssssssss', 'kssssssk', '.ssssss.', '.pppppp.', '..pppp..', '..pp.pp.', '..oo.oo.'],
    sit: ['........', '........', '..hhhh..', '.hhhhhh.', '.hkkkkh.', '.kekkek.', '..kkkk..', '.ssssss.', 'ssssssss', 'kssssssk', '.ssssss.', 'pppppppp', 'oo....oo'],
    wave: ['..hhhh.k', '.hhhhhhk', '.hkkkkhs', '.kekkeks', '..kkkk.s', '.sssssss', 'sssssss.', 'kssssss.', '.ssssss.', '.pppppp.', '.pp..pp.', '.pp..pp.', '.oo..oo.'],
  };
  function villager(g, x, y, look, pose = 'stand', flip = false) {
    const map = { h: look.hair, k: look.skin, e: P.ink, s: look.shirt, p: look.pants, o: P.woodD };
    sprite(g, VILL[pose], map, x - 4, y - 13, flip, 'v-' + look.id + '-' + pose);
  }

  // Small icons, 7 x 7, used in bubbles, windows and the road.
  const ICON = {
    scroll: ['.#####.', '#.....#', '.#.#.#.', '.#...#.', '.#.#.#.', '#.....#', '.#####.'],
    key: ['.##....', '#..#...', '#..####', '.##.#.#', '.......', '.......', '.......'],
    bang: ['..#....', '..#....', '..#....', '..#....', '.......', '..#....', '.......'],
    parcel: ['.......', '#######', '#..#..#', '#######', '#..#..#', '#######', '.......'],
  };
  function icon(g, name, x, y, c) {
    const rows = ICON[name]; if (!rows) return;
    g.fillStyle = c;
    rows.forEach((r, j) => { for (let i = 0; i < r.length; i++) if (r[i] === '#') g.fillRect(x + i, y + j, 1, 1); });
  }

  // ---- building pieces -----------------------------------------------------------------------
  function roofTiles(g, x, y, w, h, over = 2) {
    fill(g, x - over, y, w + over * 2, h, P.roof);
    for (let j = 0; j < h; j += 3) fill(g, x - over, y + j + 2, w + over * 2, 1, P.roofD);
    for (let j = 0; j < h; j += 3) for (let i = (j / 3) % 2 ? 2 : 0; i < w + over * 2; i += 4) fill(g, x - over + i, y + j, 1, 2, P.roofL);
    fill(g, x - over, y + h, w + over * 2, 1, P.roofD);
  }
  // A blue-and-white tile field: 4 x 4 tiles with a cross motif.
  function azulejo(g, x, y, w, h) {
    fill(g, x, y, w, h, P.blueL);
    for (let j = 0; j < h; j += 4) for (let i = 0; i < w; i += 4) {
      fill(g, x + i + 1, y + j + 1, Math.min(2, w - i - 1), Math.min(2, h - j - 1), P.blue);
      if (i + 3 < w && j + 3 < h) fill(g, x + i + 3, y + j + 3, 1, 1, P.blueD);
    }
  }
  function windowAt(g, x, y, w, h, lights, lit = 'night', shutter = P.mintS) {
    fill(g, x - 1, y - 1, w + 2, h + 2, P.whiteD);
    fill(g, x, y, w, h, P.win);
    fill(g, x, y, w, 1, '#4b5d78');
    if (w > 4) fill(g, x + (w >> 1), y, 1, h, P.whiteD);
    fill(g, x - 2, y, 1, h, shutter); fill(g, x + w + 1, y, 1, h, shutter);
    lights && lights.push({ x, y, w, h, when: lit });
  }
  function door(g, x, y, w, h, c, open = false) {
    fill(g, x - 1, y - 1, w + 2, h + 1, P.stoneD);
    fill(g, x, y, w, h, open ? P.ink : c);
    if (!open) { fill(g, x, y, 1, h, P.woodD); fill(g, x + w - 2, y + (h >> 1), 1, 1, P.lamp); }
  }
  function sign(g, x, y, w, h, c = P.wood) {
    fill(g, x, y, w, h, c); fill(g, x, y + h - 1, w, 1, P.woodD); fill(g, x, y, w, 1, P.woodL);
  }
  function lantern(g, x, y, on, lights) {
    fill(g, x, y, 1, 2, P.iron); fill(g, x - 1, y + 2, 3, 4, on ? P.lamp : P.whiteD); fill(g, x - 1, y + 6, 3, 1, P.iron);
    if (on && lights) lights.push({ x: x - 1, y: y + 2, w: 3, h: 4, when: 'always', glow: 4 });
  }

  // Each building: width, height, and a painter (g, x, ground, st, lights, t).
  const B = {};

  B.house = { w: 62, h: 54, paint(g, x, gy, st, L) {
    const y = gy - 54;
    roofTiles(g, x + 2, y, 58, 7);
    fill(g, x + 50, y - 6, 5, 7, P.stoneD); fill(g, x + 49, y - 7, 7, 2, P.stone);
    fill(g, x + 2, y + 8, 58, 46, P.white);
    azulejo(g, x + 4, y + 9, 54, 18);
    fill(g, x + 2, y + 27, 58, 2, P.ochre);
    windowAt(g, x + 9, y + 12, 7, 10, L, 'night'); windowAt(g, x + 27, y + 12, 7, 10, L, 'dusk'); windowAt(g, x + 45, y + 12, 7, 10, L, 'night');
    for (const bx of [x + 7, x + 25, x + 43]) { fill(g, bx, y + 22, 11, 1, P.iron); for (let i = 0; i < 11; i += 2) fill(g, bx + i, y + 23, 1, 3, P.iron); fill(g, bx, y + 26, 11, 1, P.iron); }
    fill(g, x + 2, y + 52, 58, 2, P.whiteD);
    windowAt(g, x + 8, y + 34, 9, 10, L, 'dusk');
    windowAt(g, x + 45, y + 34, 9, 10, L, 'night');
    // the name plaque, then the entrance the visitors queue at
    if (st.name && window.PixelFont) { const w = PixelFont.measure(st.name); fill(g, x + 31 - (w >> 1) - 2, y + 30, w + 4, 10, P.blueD); PixelFont.text(g, st.name, x + 31 - (w >> 1), y + 31, P.white); }
    door(g, x + 25, y + 41, 12, 13, P.greenD, st.doorOpen);
    fill(g, x + 24, y + 40, 14, 1, P.stoneD);
    // pots on the step
    fill(g, x + 21, y + 49, 3, 5, P.roof); fill(g, x + 20, y + 46, 5, 3, P.grassD); fill(g, x + 21, y + 45, 1, 1, P.red); fill(g, x + 23, y + 46, 1, 1, P.pink);
  }, door: 31 };

  B.post = { w: 46, h: 30, paint(g, x, gy, st) {
    // five mailboxes on a rail: aqua for threads with AQUA, ochre for threads with people
    const y = gy - 30;
    fill(g, x + 1, y + 6, 44, 2, P.woodD);
    fill(g, x + 3, y + 8, 2, 22, P.woodD); fill(g, x + 41, y + 8, 2, 22, P.woodD);
    roofTiles(g, x + 2, y + 1, 42, 4, 1);
    (st.threads || []).slice(0, 5).forEach((t, i) => {
      const bx = x + 4 + i * 8, by = y + 11;
      const c = t.kind === 'own' ? P.aqua : P.ochre, cd = t.kind === 'own' ? P.aquaD : P.ochreS;
      fill(g, bx, by, 7, 9, c); fill(g, bx, by, 7, 1, cd); fill(g, bx, by + 8, 7, 1, cd);
      fill(g, bx + 1, by + 3, 5, 1, P.ink);
      for (let u = 0; u < Math.min(t.unread, 3); u++) fill(g, bx + 1 + u * 2, by + 1 - u, 2, 3, P.white);
      if (t.waits_on_you) { fill(g, bx + 6, by - 6, 1, 7, P.iron); fill(g, bx + 7, by - 6, 3, 3, P.red); }
      for (let p = 0; p < Math.min(t.people, 5); p++) fill(g, bx + 1 + p, by + 11, 1, 1, t.kind === 'own' ? P.aquaD : P.wood);
      fill(g, bx + 3, by + 9, 1, 10, P.woodD);
    });
  } };

  B.crew = { w: 40, h: 42, paint(g, x, gy, st, L) {
    const y = gy - 42;
    roofTiles(g, x + 2, y + 2, 36, 8);
    fill(g, x + 3, y + 10, 34, 32, P.mint);
    fill(g, x + 3, y + 10, 34, 2, P.mintS);
    windowAt(g, x + 7, y + 16, 7, 8, L, 'dusk', P.blue);
    door(g, x + 21, y + 22, 10, 20, P.blue, st.out);
    // compass over the door: the crew's mark
    fill(g, x + 24, y + 14, 5, 5, P.white); fill(g, x + 26, y + 14, 1, 5, P.red); fill(g, x + 24, y + 16, 5, 1, P.ink);
    // one lantern per crew member, lit while ready, at most four; two dark ones while none is known
    const n = Math.max(2, Math.min(4, st.total));
    for (let i = 0; i < n; i++) lantern(g, x + 9 + i * 6 - (n > 2 ? 3 : 0), y + 27, i < st.ready, L);
    fill(g, x + 3, y + 40, 34, 2, P.mintS);
  } };

  B.market = { w: 68, h: 54, paint(g, x, gy, st, L) {
    const y = gy - 54;
    roofTiles(g, x + 2, y, 64, 6);
    fill(g, x + 2, y + 7, 64, 47, P.pink);
    fill(g, x + 2, y + 7, 64, 2, P.pinkS); fill(g, x + 2, y + 29, 64, 2, P.pinkS);
    (st.apps || []).slice(0, 6).forEach((a, i) => {
      const col = i % 3, row = Math.floor(i / 3);
      const wx = x + 6 + col * 21, wy = y + 11 + row * 22;
      fill(g, wx - 1, wy - 1, 17, 17, P.white);
      fill(g, wx, wy, 15, 15, a.open ? P.winL : P.win);
      // the app's initial: an installed app names an emoji or nothing, and neither is pixel art
      if (window.PixelFont) PixelFont.text(g, a.letter, wx + 8, wy + 4, a.open ? P.wood : P.whiteS, { align: 'center' });
      if (a.open) { for (let i2 = 0; i2 < 17; i2 += 2) fill(g, wx - 1 + i2, wy - 3, 2, 2, i2 % 4 ? P.red : P.white); L.push({ x: wx, y: wy, w: 15, h: 15, when: 'always', glow: 3, quiet: true }); }
      // a crate at the window: an update of the app is ready
      if (a.update) { fill(g, wx + 10, wy + 12, 7, 6, P.woodL); fill(g, wx + 10, wy + 12, 7, 1, P.wood); fill(g, wx + 13, wy + 13, 1, 4, P.ochre); fill(g, wx + 12, wy + 14, 3, 1, P.ochre); }
    });
  } };

  B.press = { w: 42, h: 44, paint(g, x, gy, st, L) {
    const y = gy - 44;
    fill(g, x + 30, y - 2, 6, 12, P.stoneD);
    roofTiles(g, x + 2, y + 6, 38, 6);
    fill(g, x + 3, y + 13, 36, 31, P.ochre);
    fill(g, x + 3, y + 13, 36, 2, P.ochreS);
    // the press seen through the big window
    fill(g, x + 6, y + 19, 30, 17, P.whiteD); fill(g, x + 7, y + 20, 28, 15, P.win);
    fill(g, x + 11, y + 24, 20, 8, P.stoneD); fill(g, x + 13, y + 22, 3, 3, P.iron); fill(g, x + 26, y + 22, 3, 3, P.iron);
    if (st.state === 'failed') {
      fill(g, x + 17, y + 26, 9, 6, P.white); fill(g, x + 19, y + 27, 2, 1, P.whiteD); fill(g, x + 22, y + 29, 3, 1, P.whiteD);
      fill(g, x + 33, y + 15, 3, 3, st.blink ? P.red : P.redD);
      fill(g, x + 1, y + 2, 1, 6, P.iron); fill(g, x - 4, y + 7, 11, 9, P.red); fill(g, x - 4, y + 15, 11, 1, P.redD);
      fill(g, x + 1, y + 9, 1, 4, '#fff8ec'); fill(g, x + 1, y + 14, 1, 1, '#fff8ec');
      for (let i = 0; i < 3; i++) fill(g, x + 31 + i * 2, y - 6 - i * 3, 3 + i, 2, i % 2 ? P.whiteD : P.stone);
    } else if (st.state === 'running') {
      fill(g, x + 15, y + 26, 12, 3, P.white); fill(g, x + 33, y + 15, 3, 3, st.blink ? P.amber : P.amberD);
    } else {
      fill(g, x + 30, y + 31, 4, 3, P.white); fill(g, x + 30, y + 30, 4, 1, P.whiteS); fill(g, x + 33, y + 15, 3, 3, P.green);
    }
    L.push({ x: x + 7, y: y + 20, w: 28, h: 15, when: 'dusk', quiet: true });
    door(g, x + 4, y + 37, 8, 7, P.wood);
    fill(g, x + 3, y + 42, 36, 2, P.ochreS);
  } };

  B.tower = { w: 24, h: 86, paint(g, x, gy, st) {
    const y = gy - 86;
    // roof spire and vane
    for (let i = 0; i < 10; i++) fill(g, x + 12 - Math.floor(i / 1.4) - 1, y + 4 + i, Math.floor(i / 1.4) * 2 + 2, 1, i % 3 ? P.roof : P.roofD);
    fill(g, x + 11, y, 1, 5, P.iron); fill(g, x + 12, y + 1, 3, 2, P.iron);
    fill(g, x + 3, y + 14, 18, 72, P.stoneL);
    for (let j = 18; j < 86; j += 6) for (let i = (j / 6) % 2 ? 3 : 6; i < 21; i += 7) fill(g, x + i, y + j, 4, 1, P.stone);
    fill(g, x + 3, y + 14, 18, 2, P.stone);
    // bell chamber
    fill(g, x + 6, y + 18, 12, 12, P.ink);
    const sw = st.ring ? Math.round(Math.sin(st.t * 18) * 2) : 0;
    fill(g, x + 9 + sw, y + 20, 6, 6, P.ochre); fill(g, x + 8 + sw, y + 25, 8, 2, P.ochreS); fill(g, x + 11 + sw, y + 27, 2, 1, P.ochreS);
    // clock face showing the time being looked at
    const cx = x + 12, cy = y + 42;
    fill(g, cx - 7, cy - 6, 15, 13, P.white); fill(g, cx - 6, cy - 7, 13, 15, P.white);
    fill(g, cx - 6, cy, 1, 1, P.ink); fill(g, cx + 6, cy, 1, 1, P.ink); fill(g, cx, cy - 6, 1, 1, P.ink); fill(g, cx, cy + 6, 1, 1, P.ink);
    const h = (st.minutes / 60) % 12, m = st.minutes % 60;
    hand(g, cx, cy, (h / 12) * Math.PI * 2, 3.5, P.ink);
    hand(g, cx, cy, (m / 60) * Math.PI * 2, 5.5, P.redD);
    fill(g, cx, cy, 1, 1, P.ink);
    windowAt(g, x + 10, y + 56, 4, 7, null);
    door(g, x + 8, y + 72, 8, 14, P.wood);
  } };
  function hand(g, cx, cy, a, len, c) {
    for (let r = 0; r <= len; r += 0.5) fill(g, cx + Math.round(Math.sin(a) * r), cy - Math.round(Math.cos(a) * r), 1, 1, c);
  }

  B.vault = { w: 40, h: 40, paint(g, x, gy, st) {
    const y = gy - 40;
    fill(g, x + 2, y + 2, 36, 38, P.stone);
    fill(g, x + 1, y, 38, 4, P.stoneD); fill(g, x + 2, y + 4, 36, 1, P.stoneL);
    for (let j = 8; j < 40; j += 5) for (let i = (j / 5) % 2 ? 2 : 6; i < 36; i += 9) fill(g, x + i, y + j, 5, 1, P.stoneD);
    (st.vault || []).slice(0, 4).forEach((v, i) => {
      const sx = x + 6 + (i % 2) * 16, sy = y + 8 + Math.floor(i / 2) * 15;
      fill(g, sx, sy, 12, 12, P.iron); fill(g, sx + 1, sy + 1, 10, 10, '#4a4648');
      fill(g, sx + 4, sy + 4, 4, 4, P.whiteD); fill(g, sx + 5, sy + 5, 2, 2, P.iron);
      const c = v.status === 'fine' ? P.green : v.status === 'expiring' ? P.amber : (st.blink ? P.red : P.redD);
      fill(g, sx + 9, sy + 1, 2, 2, c);
    });
  } };

  B.archive = { w: 42, h: 46, paint(g, x, gy, st, L) {
    const y = gy - 46;
    roofTiles(g, x + 2, y + 2, 38, 7);
    fill(g, x + 3, y + 10, 36, 36, P.white);
    fill(g, x + 3, y + 10, 36, 2, P.whiteS);
    // the shelf in the window: one spine per recent file, coloured by its kind; a parcel at the
    // entrance while something is offered to you
    fill(g, x + 7, y + 15, 28, 16, P.whiteD); fill(g, x + 8, y + 16, 26, 14, P.woodD);
    const kind = (t) => (/^image\//.test(t) ? P.aqua : /^text\//.test(t) ? P.ochre : t === 'application/pdf' ? P.red : P.whiteS);
    (st.recent || []).slice(0, 5).forEach((f, i) => { fill(g, x + 10 + i * 5, y + 18, 4, 11, kind(f.type)); fill(g, x + 10 + i * 5, y + 20, 4, 1, P.ink); });
    L.push({ x: x + 8, y: y + 16, w: 26, h: 14, when: 'dusk', quiet: true });
    door(g, x + 16, y + 34, 10, 12, P.blue);
    if (st.offers) { fill(g, x + 29, y + 39, 7, 6, P.woodL); fill(g, x + 29, y + 41, 7, 1, P.wood); fill(g, x + 32, y + 39, 1, 6, P.wood); }
  } };

  B.silo = { w: 22, h: 66, paint(g, x, gy, st, L) {
    const y = gy - 66;
    fill(g, x + 3, y + 10, 16, 56, P.whiteS);
    fill(g, x + 3, y + 10, 3, 56, P.white); fill(g, x + 16, y + 10, 3, 56, P.whiteD);
    for (let i = 0; i < 6; i++) fill(g, x + 4 + i, y + 9 - i, 14 - i * 2, 1, P.roofD);
    // the gauge window: storage used against its cap
    fill(g, x + 9, y + 16, 4, 44, P.iron);
    const f = st.cap > 0 ? Math.round(42 * Math.min(1, st.used / st.cap)) : 0;
    fill(g, x + 10, y + 17 + 42 - f, 2, f, P.ochre);
    for (let j = 0; j <= 42; j += 10.5) fill(g, x + 13, y + 17 + Math.round(j), 1, 1, P.ink);
    // the beacon, lit while a model is connected; an aqua flag while an update of CYFR is ready
    fill(g, x + 10, y - 1, 2, 4, P.iron);
    fill(g, x + 9, y - 4, 4, 3, st.model ? P.lamp : P.whiteD);
    if (st.model && L) L.push({ x: x + 9, y: y - 4, w: 4, h: 3, when: 'always', glow: 5 });
    if (st.update) { fill(g, x + 19, y + 18, 1, 14, P.iron); fill(g, x + 20, y + 18, 6, 4, P.aqua); }
  } };

  B.barn = { w: 44, h: 38, paint(g, x, gy, st) {
    const y = gy - 38;
    for (let i = 0; i < 12; i++) fill(g, x + 22 - i * 2 - 1, y + i, i * 4 + 2, 1, i % 3 ? P.roof : P.roofD);
    fill(g, x + 3, y + 12, 38, 26, P.redD);
    for (let i = 3; i < 41; i += 3) fill(g, x + i, y + 12, 1, 26, '#7e2620');
    fill(g, x + 12, y + 18, 20, 20, P.woodD);
    if (st.paused) {
      fill(g, x + 12, y + 18, 10, 20, P.wood); fill(g, x + 22, y + 18, 10, 20, P.woodL);
      fill(g, x + 9, y + 25, 26, 3, P.ochre); fill(g, x + 9, y + 25, 26, 1, P.ochreS);
    } else {
      fill(g, x + 13, y + 19, 18, 19, P.ink); fill(g, x + 15, y + 30, 6, 6, P.woodL); fill(g, x + 22, y + 32, 5, 4, P.woodL);
    }
  } };

  // ---- the hills' own buildings --------------------------------------------------------------
  // Portuguese windmill: a white drum, a dark cap, cloth sails with clay pots that whistle.
  function mill(g, cx, gy, angle, L) {
    const y = gy - 34;
    fill(g, cx - 8, y + 6, 16, 28, P.white); fill(g, cx + 4, y + 6, 4, 28, P.whiteS);
    fill(g, cx - 9, y + 32, 18, 2, P.whiteD);
    for (let i = 0; i < 6; i++) fill(g, cx - 9 + i, y + 6 - i, 18 - i * 2, 1, i < 2 ? P.woodD : P.wood);
    door(g, cx - 2, y + 24, 5, 10, P.blue);
    windowAt(g, cx - 2, y + 12, 4, 5, L, 'dusk', P.blue);
    // hub and eight spars, each with its triangular cloth and a clay pot at the tip
    const hx = cx + 1, hy = y + 4;
    for (let sp = 0; sp < 8; sp++) {
      const a = angle + (sp * Math.PI) / 4;
      for (let r = 4; r < 19; r++) {
        const span = 0.34 * (1 - (r - 4) / 22);
        for (let k = 1; k <= 4; k++) {
          const b = a + (span * k) / 4;
          fill(g, hx + Math.round(Math.cos(b) * r), hy + Math.round(Math.sin(b) * r), 1, 1, k === 4 || r === 18 ? P.whiteD : P.white);
        }
      }
      for (let r = 2; r < 21; r++) fill(g, hx + Math.round(Math.cos(a) * r), hy + Math.round(Math.sin(a) * r), 1, 1, P.woodD);
      fill(g, hx + Math.round(Math.cos(a) * 20), hy + Math.round(Math.sin(a) * 20), 2, 2, P.roof);
    }
    fill(g, hx - 1, hy - 1, 3, 3, P.ink);
  }

  function tram(g, x, gy, st) {
    // 34 x 22, faces left toward the stop when st.flip
    const y = gy - 22;
    fill(g, x + 15, y - 9, 1, 9, P.iron); fill(g, x + 16, y - 10, 6, 1, P.iron);
    fill(g, x + 2, y + 1, 30, 3, P.white); fill(g, x + 1, y + 4, 32, 14, P.tram);
    fill(g, x + 1, y + 4, 32, 1, P.tramL); fill(g, x + 1, y + 15, 32, 3, P.tramD);
    for (let i = 0; i < 4; i++) fill(g, x + 9 + i * 6, y + 6, 4, 6, st.lit ? P.winL : P.win);
    // destination blind
    fill(g, x + 1, y + 6, 7, 5, P.ink); fill(g, x + 2, y + 8, 5, 1, P.white);
    fill(g, x + 3, y + 18, 5, 4, P.iron); fill(g, x + 25, y + 18, 5, 4, P.iron);
    fill(g, x + 4, y + 19, 3, 2, P.whiteD); fill(g, x + 26, y + 19, 3, 2, P.whiteD);
    fill(g, x, y + 14, 1, 2, P.red);
  }

  function tunnel(g, x, gy, lit, L) {
    // a stone portal cut into the right hill, x = left edge, 34 wide
    const y = gy - 32;
    fill(g, x, y, 34, 32, P.stoneD);
    fill(g, x + 3, y + 3, 28, 29, P.stone);
    for (let i = 0; i < 12; i++) fill(g, x + 6 + i * 2 - (i > 5 ? (i - 5) * 0 : 0), y + 4, 2, 2, i % 2 ? P.stoneL : P.stone);
    fill(g, x + 7, y + 8, 20, 24, P.ink);
    fill(g, x + 9, y + 6, 16, 2, P.ink); fill(g, x + 11, y + 5, 12, 1, P.ink);
    lantern(g, x + 4, y + 10, lit, L); lantern(g, x + 29, y + 10, lit, L);
    if (lit) for (let i = 0; i < 3; i++) { fill(g, x + 12 + i * 4, y + 12 + i * 3, 2, 2, P.lamp); L.push({ x: x + 12 + i * 4, y: y + 12 + i * 3, w: 2, h: 2, when: 'always', glow: 2, quiet: true }); }
  }

  window.Art = { P, fill, sprite, capybara, villager, icon, B, mill, tram, tunnel, roofTiles, azulejo, windowAt, door, sign, lantern };
})();

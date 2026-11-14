/* The scene behind and below the signs: the city at night, the wires from the CYFR box, and the
 * wet street that reflects only the signs that burn. Plain canvas 2D and one SVG; it sleeps when
 * the page is hidden or frozen and draws a single still frame under reduced motion. */
(function () {
  'use strict';
  const $ = (q, el) => (el || document).querySelector(q);
  const $$ = (q, el) => [...(el || document).querySelectorAll(q)];
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const OUT_MS = 1400;

  let root, getState, sky, sctx, pud, pctx, wires, back, live = true, running = false, raf = 0, last = 0;
  let geo = { w: 0, h: 0, roof: [], grate: null };
  const pulses = [];
  const drips = [];
  let lastDrip = 0;
  const seenOut = new Map();
  const sprites = new Map();

  function rng(seed) { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); }
  const dprFor = () => Math.min(window.devicePixelRatio || 1, 1.5);
  const box = (el) => { const r = el.getBoundingClientRect(), o = root.getBoundingClientRect(); return { x: r.left - o.left, y: r.top - o.top, w: r.width, h: r.height }; };
  const phone = () => innerWidth < 600;

  function size(cv, w, h) {
    const d = dprFor();
    cv.width = Math.max(1, Math.round(w * d)); cv.height = Math.max(1, Math.round(h * d));
    cv.style.width = w + 'px'; cv.style.height = h + 'px';
    const c = cv.getContext('2d'); c.setTransform(d, 0, 0, d, 0, 0); return c;
  }

  // ---------- the still city, drawn once per layout ----------
  function drawBack() {
    const w = innerWidth, h = innerHeight;
    back = document.createElement('canvas');
    const c = size(back, w, h);
    const g = c.createLinearGradient(0, 0, 0, h);
    g.addColorStop(0, '#04050b'); g.addColorStop(0.35, '#0a0917'); g.addColorStop(1, '#06070c');
    c.fillStyle = g; c.fillRect(0, 0, w, h);

    const wall = $('#wall'), level = $('#level');
    const top = wall ? Math.max(30, box(wall).y) : 60;
    const r = rng(1110);
    // far towers
    let x = -20;
    while (x < w) {
      const tw = 30 + r() * 70, th = 40 + r() * (phone() ? 160 : 120);
      const ty = Math.max(4, top - th * 0.55);
      c.fillStyle = '#0b0d18'; c.fillRect(x, ty, tw, h);
      c.fillStyle = 'rgba(80,110,170,.10)';
      for (let yy = ty + 6; yy < ty + th * 2; yy += 7) for (let xx = x + 4; xx < x + tw - 4; xx += 6) if (r() < 0.08) c.fillRect(xx, yy, 2, 3);
      if (r() < 0.25) geo.roof.push({ x: x + tw / 2, y: ty - 6 });
      c.fillStyle = '#0b0d18'; if (r() < 0.4) c.fillRect(x + tw / 2 - 1, ty - 10, 2, 10);
      x += tw + 4 + r() * 10;
    }
    // near facades behind the signs
    x = 0;
    const shades = ['#0e1220', '#111626', '#0c101b', '#121726'];
    let i = 0;
    while (x < w) {
      const bw = 150 + r() * 220, roofY = top - 12 + r() * 34;
      c.fillStyle = shades[i++ % shades.length]; c.fillRect(x, roofY, bw, h - roofY);
      c.fillStyle = '#1b2132'; c.fillRect(x, roofY, bw, 3); c.fillRect(x, roofY, 2, h);
      for (let yy = roofY + 18; yy < h - 40; yy += 30) {
        c.fillStyle = 'rgba(30,37,54,.55)'; c.fillRect(x, yy - 6, bw, 2);
        for (let xx = x + 12; xx < x + bw - 22; xx += 26) {
          const lit = r();
          c.fillStyle = lit < 0.06 ? 'rgba(255,186,120,.20)' : lit < 0.1 ? 'rgba(120,200,255,.15)' : 'rgba(18,22,34,.95)';
          c.fillRect(xx, yy, 12, 16);
          if (lit < 0.1) { c.fillStyle = 'rgba(8,10,16,.6)'; c.fillRect(xx + 7, yy + 5, 4, 11); }
        }
      }
      c.fillStyle = '#171c2b'; c.fillRect(x + bw - 9, roofY, 4, h);
      for (let k = 0; k < 2; k++) {
        if (r() < 0.7) {
          const ax = x + 20 + r() * (bw - 70), ay = roofY + 50 + r() * (h * 0.5);
          c.fillStyle = '#171c2a'; c.fillRect(ax, ay, 34, 20);
          c.fillStyle = '#20263a'; c.fillRect(ax + 3, ay + 4, 28, 2); c.fillRect(ax + 3, ay + 9, 28, 2);
        }
      }
      x += bw;
    }
    // pavement
    if (level) {
      const lv = box(level);
      const ground = lv.y + lv.h;
      c.fillStyle = '#080a10'; c.fillRect(0, ground - 6, w, h);
      c.fillStyle = '#1a1f2d'; c.fillRect(0, ground - 6, w, 2);
      geo.grate = { x: w * 0.58, y: ground + 4 };
    }
  }

  // ---------- wires from the CYFR box to every part ----------
  function drawWires() {
    wires.innerHTML = '';
    if (phone()) return;
    const src = $('.junction');
    if (!src) return;
    const s = box(src);
    const header = $('#header');
    // The wires leave the box sideways, climb the gutter at the frame's edge where nothing covers
    // them, hang across the band under the sky, and drop onto each part.
    const tray = header ? box(header).y + box(header).h - 3 : 45;
    const ns = 'http://www.w3.org/2000/svg';
    const mk = (d, part) => {
      const p = document.createElementNS(ns, 'path');
      p.setAttribute('d', d); p.setAttribute('class', 'wire'); p.dataset.part = part;
      wires.appendChild(p); return p;
    };
    const gx = Math.max(5, s.x - 8), sy = s.y + 16;
    $$('#wall .part').forEach((el, i) => {
      const b = box(el);
      const tx = b.x + Math.min(40, b.w * 0.2), ty = b.y + 2;
      const sag = Math.min(5, (tx - gx) / 120) + (i % 3) * 1.5;
      mk('M' + s.x + ',' + (sy + i * 3) + ' H' + (gx - i * 0.5) + ' V' + tray + ' Q' + ((gx + tx) / 2) + ',' + (tray + sag) + ' ' + tx + ',' + tray + ' V' + ty, el.dataset.part);
    });
    const sx = gx;
    $$('#level .part').forEach((el, i) => {
      if (el.dataset.part === 'cyfr') return;
      const b = box(el);
      const tx = b.x + 24, ty = b.y + 2, y0 = s.y + 10;
      mk('M' + (s.x + s.w - 4) + ',' + y0 + ' Q' + ((s.x + s.w + tx) / 2) + ',' + (Math.max(y0, ty) + 22 + i * 4) + ' ' + tx + ',' + ty, el.dataset.part);
    });
    mk('M' + s.x + ',' + sy + ' H' + sx + ' V' + tray, 'cyfr');
  }

  function pulse(part, hue, done) {
    const path = !phone() && !reduced && running && $('.wire[data-part="' + part + '"]', wires);
    if (!path) return false;
    const ns = 'http://www.w3.org/2000/svg';
    const seg = document.createElementNS(ns, 'path');
    seg.setAttribute('d', path.getAttribute('d')); seg.setAttribute('class', 'wire-pulse');
    seg.style.stroke = hue; seg.style.color = hue;
    const L = path.getTotalLength();
    seg.style.strokeDasharray = '80 ' + (L + 100);
    wires.appendChild(seg);
    pulses.push({ seg, L, t0: performance.now(), dur: 800 + L * 1.05, done });
    return true;
  }

  // ---------- the moving layer ----------
  function litSigns() {
    const now = performance.now();
    return $$('[data-light]').filter((el) => el.offsetParent !== null && !el.closest('[data-covered]')).map((el) => {
      const kind = el.dataset.light, b = box(el), hue = el.style.getPropertyValue('--hue').trim() || '#fff';
      let a = 1;
      if (kind === 'out') { const id = el.dataset.att; if (!seenOut.has(id)) seenOut.set(id, now); a = Math.max(0, 1 - (now - seenOut.get(id)) / OUT_MS); }
      if (kind === 'sputter') a = (Math.sin(now / 47) + Math.sin(now / 131) > 1.3) ? 0.25 : 0.95;
      if (kind === 'asking') a = 0.5 + 0.3 * Math.sin(now / 420);
      return { b, hue, a };
    });
  }
  function sprite(hue) {
    if (sprites.has(hue)) return sprites.get(hue);
    const cv = document.createElement('canvas'); cv.width = 128; cv.height = 1;
    const c = cv.getContext('2d'), g = c.createLinearGradient(0, 0, 128, 0);
    g.addColorStop(0, 'rgba(0,0,0,0)'); g.addColorStop(0.35, hue); g.addColorStop(0.5, '#ffffff'); g.addColorStop(0.65, hue); g.addColorStop(1, 'rgba(0,0,0,0)');
    c.fillStyle = g; c.fillRect(0, 0, 128, 1); sprites.set(hue, cv); return cv;
  }

  function frame(t) {
    raf = 0;
    if (!running) return;
    if (t - last < 33) { raf = requestAnimationFrame(frame); return; }
    last = t;
    paint(t);
    raf = requestAnimationFrame(frame);
  }

  function paint(t) {
    const w = innerWidth, h = innerHeight;
    const st = getState ? getState() : null;
    const signs = litSigns();
    // sky: still city, the haze the lit signs throw into the mist, steam, rain
    if (back) sctx.drawImage(back, 0, 0, w, h);
    sctx.globalCompositeOperation = 'lighter';
    for (const s of signs) {
      const cx = s.b.x + s.b.w / 2, cy = s.b.y + s.b.h / 2, rad = Math.min(220, Math.max(120, Math.max(s.b.w, s.b.h) * 1.1));
      const g = sctx.createRadialGradient(cx, cy, 0, cx, cy, rad);
      g.addColorStop(0, hexA(s.hue, 0.20 * s.a)); g.addColorStop(0.5, hexA(s.hue, 0.06 * s.a)); g.addColorStop(1, hexA(s.hue, 0));
      sctx.fillStyle = g; sctx.fillRect(cx - rad, cy - rad, rad * 2, rad * 2);
    }
    sctx.globalCompositeOperation = 'source-over';
    for (const p of geo.roof.slice(0, 3)) {
      const on = Math.floor((t / 1000 + p.x) % 2.6) === 0;
      if (on) { sctx.fillStyle = 'rgba(255,70,60,.55)'; sctx.fillRect(p.x - 1.5, p.y - 1.5, 3, 3); }
    }
    if (geo.grate && !phone()) {
      for (let i = 0; i < 6; i++) {
        const k = ((t / 5200) + i / 6) % 1;
        const x = geo.grate.x + Math.sin(k * 6 + i) * 18 * k, y = geo.grate.y - k * 150, rr = 18 + k * 70;
        const g = sctx.createRadialGradient(x, y, 0, x, y, rr);
        g.addColorStop(0, 'rgba(200,210,235,' + (0.07 * (1 - k)) + ')'); g.addColorStop(1, 'rgba(200,210,235,0)');
        sctx.fillStyle = g; sctx.fillRect(x - rr, y - rr, rr * 2, rr * 2);
      }
    }
    const wf = st && window.Night ? Night.feedOf(st, 'weather') : null;
    const skyWord = wf ? String(Night.weatherOf(wf).sky) : '';
    if (/rain|drizzle|shower|storm/.test(skyWord)) {
      sctx.strokeStyle = 'rgba(170,190,230,.28)'; sctx.lineWidth = 1; sctx.beginPath();
      const r = rng(Math.floor(t / 33));
      for (let i = 0; i < 140; i++) { const x = r() * w, y = r() * h; sctx.moveTo(x, y); sctx.lineTo(x - 3, y + 14); }
      sctx.stroke();
    }
    // the wet street: reflections of what burns, nothing else
    if (pud && pctx) {
      const pb = box(pud), pw = pb.w, ph = pb.h;
      pctx.clearRect(0, 0, pw, ph);
      const g = pctx.createLinearGradient(0, 0, 0, ph);
      g.addColorStop(0, '#07080e'); g.addColorStop(1, '#040509');
      pctx.fillStyle = g; pctx.fillRect(0, 0, pw, ph);
      pctx.fillStyle = 'rgba(120,140,190,.05)';
      for (let y = 6; y < ph; y += 9) pctx.fillRect(0, y, pw, 1);
      pctx.globalCompositeOperation = 'lighter';
      const tt = t / 1000;
      for (const s of signs) {
        if (s.a <= 0.01) continue;
        const cx = s.b.x + s.b.w / 2 - pb.x;
        const sw = Math.max(26, Math.min(120, s.b.w * 0.5));
        const spr = sprite(s.hue);
        for (let y = 0; y < ph; y += 2) {
          const k = y / ph;
          const a = s.a * 0.78 * Math.pow(1 - k, 1.15) * (0.8 + 0.2 * Math.sin(tt * 2.1 + y * 0.31));
          const off = Math.sin(tt * 1.6 + y * 0.23) * (1 + y * 0.08);
          const ww = sw * (1 - k * 0.3);
          pctx.globalAlpha = a; pctx.drawImage(spr, cx - ww / 2 + off, y, ww, 2);
        }
      }
      pctx.globalAlpha = 1;
      for (const el of $$('.awning, .junction, .cubby')) {
        if (el.offsetParent === null || el.dataset.light) continue;
        const b = box(el), cx = b.x + b.w / 2 - pb.x;
        pctx.fillStyle = 'rgba(120,135,175,.05)'; pctx.fillRect(cx - b.w * 0.35, 0, b.w * 0.7, ph * 0.55);
      }
      if (t - lastDrip > 520) { lastDrip = t; drips.push({ x: Math.random() * pw, y: 10 + Math.random() * (ph - 30), t0: t }); if (drips.length > 8) drips.splice(0, 1); }
      pctx.lineWidth = 1;
      for (const d of drips) {
        const k = (t - d.t0) / 1400;
        if (k > 1) continue;
        pctx.strokeStyle = 'rgba(170,190,235,' + (0.32 * (1 - k)).toFixed(3) + ')';
        pctx.beginPath(); pctx.ellipse(d.x, d.y, 2 + k * 24, 0.6 + k * 5, 0, 0, Math.PI * 2); pctx.stroke();
      }
      for (const el of $$('.shop--open .window')) {
        if (el.offsetParent === null) continue;
        const b = box(el), cx = b.x + b.w / 2 - pb.x;
        const rg = pctx.createRadialGradient(cx, 0, 0, cx, 0, b.w * 0.6);
        rg.addColorStop(0, 'rgba(255,180,110,.10)'); rg.addColorStop(1, 'rgba(255,180,110,0)');
        pctx.fillStyle = rg; pctx.fillRect(cx - b.w, 0, b.w * 2, ph);
      }
      pctx.globalCompositeOperation = 'source-over';
    }
    // pulses along the wires
    for (let i = pulses.length - 1; i >= 0; i--) {
      const p = pulses[i], k = Math.min(1, (performance.now() - p.t0) / p.dur);
      p.seg.style.strokeDashoffset = String(80 - k * (p.L + 80));
      if (k >= 1) { p.seg.remove(); pulses.splice(i, 1); try { p.done && p.done(); } catch (e) { console.error(e); } }
    }
  }
  function hexA(hex, a) {
    const m = hex.replace('#', '');
    const n = parseInt(m.length === 3 ? m.split('').map((c) => c + c).join('') : m, 16);
    return 'rgba(' + (n >> 16 & 255) + ',' + (n >> 8 & 255) + ',' + (n & 255) + ',' + Math.max(0, Math.min(1, a)).toFixed(3) + ')';
  }

  // ---------- life cycle ----------
  let pending = 0, backKey = '';
  function relayout() {
    if (pending) return;
    pending = requestAnimationFrame(() => {
      pending = 0;
      const w = innerWidth, h = innerHeight;
      // The still city is drawn again only when the frame or the street's edges move.
      const wall = $('#wall'), level = $('#level');
      const key = [w, h, wall ? Math.round(box(wall).y) : 0, level ? Math.round(box(level).y + box(level).h) : 0].join(',');
      if (key !== backKey) {
        backKey = key;
        sctx = size(sky, w, h);
        geo = { w, h, roof: [], grate: null };
        drawBack();
        pud = $('#puddle');
        const pc = $('#puddle-c');
        if (pud && pc) { const pb = pud.getBoundingClientRect(); pctx = size(pc, pb.width, pb.height); }
      }
      drawWires();
      paint(performance.now());
      setTimeout(drawWires, 460);
    });
  }
  function wake() {
    const should = live && !document.hidden && !reduced;
    if (should && !running) { running = true; raf = requestAnimationFrame(frame); }
    if (!should && running) {
      running = false; cancelAnimationFrame(raf); raf = 0;
      while (pulses.length) { const p = pulses.pop(); p.seg.remove(); try { p.done && p.done(); } catch (e) { /* keep going */ } }
    }
  }

  window.Scene = {
    init(r, gs) {
      root = r; getState = gs;
      sky = $('#sky'); wires = $('#wires');
      relayout(); wake();
      addEventListener('resize', relayout);
      document.addEventListener('visibilitychange', wake);
      addEventListener('scroll', () => { if (!running) paint(performance.now()); }, { passive: true });
    },
    relayout,
    pulse,
    setLive(v) { live = v; wake(); },
  };
})();

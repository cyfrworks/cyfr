/* Patch cords: verlet ropes drawn on one canvas above the panel.
   A cord is pinned at its line's jack (end A); end B dangles in the hand, flies to a destination jack
   and seats there, or retracts into the shelf. The loop sleeps when every cord is still and stops
   while the page is hidden or frozen. Reduced motion settles each cord at once instead of swinging. */
(function () {
  const canvas = document.getElementById('cords');
  const ctx = canvas.getContext('2d');
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  const G = 2400, DAMP = 0.986, STEP = 1 / 120, ITER = 16;
  let W = 0, H = 0, DPR = 1, running = false, frozen = false, last = 0, still = 0, grab = null;
  const ropes = new Set();

  const center = (el) => {
    if (!el || !el.isConnected) return null;
    const r = el.getBoundingClientRect();
    if (!r.width) return null;
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  };
  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const ease = (t) => 1 - Math.pow(1 - t, 3);

  function resize() {
    DPR = Math.min(2, window.devicePixelRatio || 1);
    W = innerWidth; H = innerHeight;
    canvas.width = Math.round(W * DPR); canvas.height = Math.round(H * DPR);
    canvas.style.width = W + 'px'; canvas.style.height = H + 'px';
    ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
    wake();
  }

  class Rope {
    constructor(aEl, opts = {}) {
      this.aEl = aEl; this.bEl = null; this.n = opts.n || 22;
      this.len = opts.length || 84; this.targetLen = this.len;
      this.flight = null; this.pop = 0; this.dead = false; this.retracting = false; this.hold = false;
      this.color = opts.color || null;
      const a = center(aEl) || { x: W / 2, y: H / 2 };
      this.p = []; for (let i = 0; i < this.n; i++) this.p.push({ x: a.x + (i % 2) * 0.5, y: a.y + (i / (this.n - 1)) * this.len, px: a.x, py: a.y + (i / (this.n - 1)) * this.len });
      ropes.add(this);
      if (reduce.matches) this.settle(); else wake();
    }
    get seg() { return Math.max(0.3, this.len / (this.n - 1)); }
    // B flies to a jack and seats there; the cord lengthens so it droops between the two.
    patch(el, { slack = 1.12, extra = 34 } = {}) {
      const from = this.bPos(), to = center(el);
      if (!to) return;
      const a = center(this.aEl);
      this.bEl = el; this.retracting = false; this.slack = slack; this.extra = extra;
      this.targetLen = Math.hypot(to.x - a.x, to.y - a.y) * slack + extra;
      this.flight = { from, t: 0, dur: 0.5 };
      if (reduce.matches) { this.flight = null; this.len = this.targetLen; this.settle(); } else wake();
    }
    fit() {
      if (!this.bEl || this.retracting) return;
      const a = center(this.aEl), b = center(this.bEl);
      if (a && b) this.targetLen = Math.hypot(b.x - a.x, b.y - a.y) * (this.slack || 1.12) + (this.extra ?? 34);
    }
    unseat() { this.bEl = null; this.flight = null; this.targetLen = 84; wake(); }
    retract(done) {
      this.bEl = null; this.flight = null; this.retracting = true; this.targetLen = 0; this.done = done;
      if (reduce.matches) this.kill(); else wake();
    }
    kill() { this.dead = true; ropes.delete(this); this.done && this.done(); wake(); }
    bPos() { const q = this.p[this.n - 1]; return { x: q.x, y: q.y }; }
    pinB() {
      if (this.flight) {
        const to = center(this.bEl); if (!to) return null;
        const t = ease(Math.min(1, this.flight.t / this.flight.dur));
        const f = this.flight.from, lift = Math.min(120, Math.hypot(to.x - f.x, to.y - f.y) * 0.35);
        const mx = (f.x + to.x) / 2, my = Math.min(f.y, to.y) - lift;
        const u = 1 - t;
        return { x: u * u * f.x + 2 * u * t * mx + t * t * to.x, y: u * u * f.y + 2 * u * t * my + t * t * to.y };
      }
      return this.bEl ? center(this.bEl) : null;
    }
    step(dt) {
      if (this.flight) { this.flight.t += dt; if (this.flight.t >= this.flight.dur) this.flight = null; }
      const k = Math.min(1, dt * (this.retracting ? 7 : 5));
      this.len += (this.targetLen - this.len) * k;
      if (this.retracting && this.len < 3) { this.kill(); return 0; }
      const a = center(this.aEl);
      if (!a) { this.kill(); return 0; }
      const b = this.pinB();
      let motion = 0;
      for (let i = 0; i < this.n; i++) {
        const q = this.p[i];
        const vx = (q.x - q.px) * DAMP, vy = (q.y - q.py) * DAMP;
        q.px = q.x; q.py = q.y;
        q.x += vx; q.y += vy + G * dt * dt;
        motion += Math.abs(vx) + Math.abs(vy);
      }
      const L = this.seg;
      for (let it = 0; it < ITER; it++) {
        const f = this.p[0]; f.x = a.x; f.y = a.y;
        if (b) { const e = this.p[this.n - 1]; e.x = b.x; e.y = b.y; }
        if (grab && grab.rope === this) { const g = this.p[grab.i]; g.x = grab.x; g.y = grab.y; }
        for (let i = 0; i < this.n - 1; i++) {
          const p1 = this.p[i], p2 = this.p[i + 1];
          const dx = p2.x - p1.x, dy = p2.y - p1.y, d = Math.hypot(dx, dy) || 0.0001;
          const diff = (d - L) / d / 2;
          const pin1 = i === 0, pin2 = (i + 1 === this.n - 1 && b);
          if (pin1 && !pin2) { p2.x -= dx * diff * 2; p2.y -= dy * diff * 2; }
          else if (pin2 && !pin1) { p1.x += dx * diff * 2; p1.y += dy * diff * 2; }
          else if (!pin1 && !pin2) { p1.x += dx * diff; p1.y += dy * diff; p2.x -= dx * diff; p2.y -= dy * diff; }
        }
      }
      return motion + (this.flight ? 99 : 0) + Math.abs(this.targetLen - this.len);
    }
    settle() { for (let i = 0; i < 400; i++) this.step(STEP); draw(); }
  }

  /* ---------- drawing ---------- */
  function path(r) {
    const p = r.p;
    ctx.beginPath(); ctx.moveTo(p[0].x, p[0].y);
    for (let i = 1; i < p.length - 1; i++) ctx.quadraticCurveTo(p[i].x, p[i].y, (p[i].x + p[i + 1].x) / 2, (p[i].y + p[i + 1].y) / 2);
    ctx.lineTo(p[p.length - 1].x, p[p.length - 1].y);
  }
  function seatedPlug(x, y, s = 1) {
    ctx.save(); ctx.translate(x, y); ctx.scale(s, s);
    ctx.fillStyle = 'rgba(0,0,0,.22)'; ctx.beginPath(); ctx.arc(2.5, 3.5, 12, 0, 7); ctx.fill();
    ctx.fillStyle = css('--brass'); ctx.beginPath(); ctx.arc(0, 0, 12, 0, 7); ctx.fill();
    ctx.fillStyle = '#141414'; ctx.beginPath(); ctx.arc(0, 0, 9.5, 0, 7); ctx.fill();
    ctx.strokeStyle = 'rgba(255,255,255,.18)'; ctx.lineWidth = 1.4; ctx.beginPath(); ctx.arc(0, 0, 7, 3.6, 5.4); ctx.stroke();
    ctx.restore();
  }
  function freePlug(x, y, ang) {
    ctx.save(); ctx.translate(x, y); ctx.rotate(ang);
    ctx.fillStyle = 'rgba(0,0,0,.2)'; ctx.fillRect(-2, 3, 30, 10);
    ctx.fillStyle = '#141414'; roundRect(-1, -5, 20, 10, 4); ctx.fill();
    ctx.fillStyle = css('--brass'); ctx.fillRect(19, -3.5, 4, 7); ctx.fillRect(23, -2, 9, 4);
    ctx.beginPath(); ctx.arc(32, 0, 2.2, 0, 7); ctx.fill();
    ctx.restore();
  }
  function roundRect(x, y, w, h, r) { ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r); ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath(); }

  function draw() {
    ctx.clearRect(0, 0, W, H);
    const accent = css('--cord'), edge = css('--cord-edge');
    for (const r of ropes) {
      ctx.lineCap = 'round'; ctx.lineJoin = 'round';
      ctx.save(); ctx.translate(3, 5); path(r); ctx.strokeStyle = 'rgba(0,0,0,.16)'; ctx.lineWidth = 6; ctx.stroke(); ctx.restore();
      path(r); ctx.strokeStyle = edge; ctx.lineWidth = 6; ctx.stroke();
      path(r); ctx.strokeStyle = r.color || accent; ctx.lineWidth = 4; ctx.stroke();
      ctx.save(); ctx.translate(-0.9, -0.9); path(r); ctx.strokeStyle = 'rgba(255,255,255,.28)'; ctx.lineWidth = 1; ctx.stroke(); ctx.restore();
      const a = r.p[0], e = r.p[r.n - 1], e2 = r.p[r.n - 2];
      if (r.bEl && !r.flight) seatedPlug(e.x, e.y);
      else if (!r.retracting || r.len > 10) freePlug(e.x, e.y, Math.atan2(e.y - e2.y, e.x - e2.x));
      seatedPlug(a.x, a.y, r.retracting ? Math.max(0.4, r.len / 84) : 1);
      if (r.hold) { ctx.fillStyle = (performance.now() % 500) < 250 ? css('--lamp-amber') : 'transparent'; ctx.beginPath(); ctx.arc(e.x, e.y, 3, 0, 7); ctx.fill(); }
    }
  }

  /* ---------- loop ---------- */
  function frame(t) {
    if (!running) return;
    let dt = Math.min(0.05, (t - (last || t)) / 1000); last = t;
    let motion = 0, acc = dt;
    while (acc > 0.0001) { const h = Math.min(STEP, acc); for (const r of ropes) motion += r.step(h) || 0; acc -= h; }
    draw();
    const anyHold = [...ropes].some((r) => r.hold);
    still = motion < 0.06 * Math.max(1, ropes.size) && !grab && !anyHold ? still + 1 : 0;
    if (still > 45) { running = false; return; }
    requestAnimationFrame(frame);
  }
  function wake() {
    if (frozen || document.hidden) { draw(); return; }
    still = 0;
    if (!running) { running = true; last = 0; requestAnimationFrame(frame); }
  }

  /* ---------- poke: drag any cord and let go ---------- */
  let down = null, suppress = false;
  addEventListener('pointerdown', (e) => {
    down = null;
    if (reduce.matches) return;
    let best = null;
    for (const r of ropes) r.p.forEach((q, i) => { if (i === 0 || (i === r.n - 1 && r.bEl)) return; const d = Math.hypot(q.x - e.clientX, q.y - e.clientY); if (d < 22 && (!best || d < best.d)) best = { rope: r, i, d }; });
    if (best) down = { ...best, x0: e.clientX, y0: e.clientY, id: e.pointerId };
  }, true);
  addEventListener('pointermove', (e) => {
    if (!down || e.pointerId !== down.id) return;
    if (!grab && Math.hypot(e.clientX - down.x0, e.clientY - down.y0) > 6) { grab = { rope: down.rope, i: down.i, x: e.clientX, y: e.clientY }; suppress = true; wake(); }
    if (grab) { grab.x = e.clientX; grab.y = e.clientY; e.preventDefault(); }
  }, { capture: true, passive: false });
  const release = () => { down = null; if (grab) { grab = null; wake(); setTimeout(() => (suppress = false), 0); } };
  addEventListener('pointerup', release, true);
  addEventListener('pointercancel', release, true);
  addEventListener('click', (e) => { if (suppress) { e.stopPropagation(); e.preventDefault(); suppress = false; } }, true);

  addEventListener('resize', resize);
  addEventListener('scroll', wake, { passive: true, capture: true });
  document.addEventListener('visibilitychange', () => (document.hidden ? (running = false) : wake()));

  window.Cords = {
    pick(el, opts) { return new Rope(el, opts); },
    wire(aEl, bEl, opts = {}) { const r = new Rope(aEl, opts); r.bEl = bEl; r.slack = opts.slack || 1.15; r.extra = opts.extra ?? 28; r.fit(); r.len = r.targetLen; r.settle(); wake(); return r; },
    fit() { for (const r of ropes) r.fit(); wake(); },
    freeze(on) { frozen = on; if (on) running = false; else wake(); },
    wake, draw, ropes,
  };
  resize();
})();

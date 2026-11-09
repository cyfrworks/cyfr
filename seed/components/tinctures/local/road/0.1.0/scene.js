// The village. One canvas in logical pixels, scaled whole; a layer of transparent buttons over it
// carries every tap, keyboard focus and screen-reader name. The scene reads Road.state and never
// writes it; each choice asks CYFR once, on the person's tap. boot.js calls it, and shows the plain
// list instead when it throws.
window.RoadScene = function () {
  const { P, fill } = Art;
  const F = PixelFont;
  const R = Road, S = Road.state, PARTS = Road.PARTS, DAY = 1440;
  const on = R.partOn;
  // How far the road reaches either side of now, in minutes.
  const BEHIND = 36 * 60, AHEAD = 3 * DAY;

  // ---- time ----------------------------------------------------------------------------------
  const now = () => R.nowLocal();
  const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const WEEKDAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  const MONTHS =['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const wall = (m) => new Date(Math.floor(m) * 60000); // its UTC fields are the wall clock
  const dayIx = (m) => wall(m).getUTCDay();
  const pad = (n) => String(n).padStart(2, '0');
  const hm = (m) => { const d = ((Math.floor(m) % DAY) + DAY) % DAY; return pad(Math.floor(d / 60)) + ':' + pad(d % 60); };
  const dateLabel = (m) => { const d = wall(m); return DAYS[d.getUTCDay()] + ' ' + d.getUTCDate() + ' ' + MONTHS[d.getUTCMonth()]; };
  const dayWord = (m) => { const d = Math.floor(m / DAY), n = Math.floor(now() / DAY); return d === n ? 'today' : d === n - 1 ? 'yesterday' : d === n + 1 ? 'tomorrow' : DAYS[dayIx(m)]; };
  const when = (m) => { if (m == null) return 'some time'; const w = dayWord(m); return w === 'today' ? hm(m) : w + ' ' + hm(m); };
  const dur = (mins) => { mins = Math.round(Math.abs(mins)); const h = Math.floor(mins / 60), r = mins % 60; return h >= 48 ? Math.round(h / 24) + ' days' : h ? (r ? h + ' h ' + r + ' m' : h + ' h') : r + ' m'; };
  const rel = (m) => { const d = m - now(); return Math.abs(d) < 1 ? 'now' : d > 0 ? 'in ' + dur(d) : dur(d) + ' ago'; };

  // ---- what the streams say, as the scene reads it ------------------------------------------
  const attention = () => R.values(S.attention).map((a) => (a.since == null ? { ...a, since: now() } : a)).sort((a, b) => a.since - b.since);
  const schedules = () => R.values(S.schedules).sort((a, b) => (a.next ?? Infinity) - (b.next ?? Infinity));
  const sched = (id) => { const h = S.schedules.get(id); return h ? h.value : null; };
  const threads = () => R.values(S.threads).sort((a, b) => (b.waits - a.waits) || (b.last ?? 0) - (a.last ?? 0));
  const jobs = () => R.values(S.activity).sort((a, b) => (a.since ?? 0) - (b.since ?? 0));
  const vault = () => R.values(S.vault).sort((a, b) => a.fine - b.fine || a.name.localeCompare(b.name));
  const obj = (v) => typeof v === 'object' && v !== null && !Array.isArray(v);
  // A feed's result is the feed's own shape: read the fields a weather or a vpn feed names.
  function pick(r, keys, test) { for (const k of keys) if (test(r[k])) return r[k]; return null; }
  const isNum = Number.isFinite, isStr = (v) => typeof v === 'string' && v !== '';
  function weatherNow() {
    const f = S.feeds.weather; if (!f || !obj(f.result)) return null;
    const r = f.result;
    return { temp: pick(r, ['temp_c', 'temperature_c', 'temperature', 'temp'], isNum), place: pick(r, ['place', 'location', 'city', 'name'], isStr) || f.label || 'Weather',
      sky: pick(r, ['sky', 'condition', 'conditions', 'summary', 'description'], isStr) || '', wind: pick(r, ['wind_kmh', 'wind_speed_kmh', 'wind'], isNum),
      next: Array.isArray(r.next_hours) ? r.next_hours.filter(isNum).slice(0, 12) : [], at: f.at, actions: f.actions };
  }
  function vpnNow() {
    const f = S.feeds.vpn; if (!f || !obj(f.result)) return null;
    const r = f.result, st = String(pick(r, ['state', 'status'], isStr) || '');
    const since = isStr(r.since) && !Number.isNaN(Date.parse(r.since)) ? R.localOf(Date.parse(r.since)) : null;
    return { connected: /^(connected|up|on)$/i.test(st), state: st || 'unknown', server: pick(r, ['server', 'location', 'exit'], isStr) || '', since,
      servers: Array.isArray(r.servers) ? r.servers.filter(isStr).slice(0, 8) : [], mbps: pick(r, ['down_mbps', 'mbps', 'speed_mbps'], isNum), at: f.at, actions: f.actions, label: f.label };
  }

  // ---- canvas and layers ---------------------------------------------------------------------
  const stage = document.getElementById('stage');
  const cv = document.getElementById('village');
  const g = cv.getContext('2d');
  if (!g) throw new Error('This browser draws no 2d canvas.');
  const world = document.createElement('canvas');
  let wg = world.getContext('2d');
  const hitsEl = document.getElementById('hits');
  const live = document.getElementById('live');
  let W = 512, H = 300, SC = 2, L = null;

  function relayout() {
    const cw = stage.clientWidth || innerWidth, ch = stage.clientHeight || innerHeight;
    SC = cw >= 1280 && ch >= 760 && S.posture !== 'hand' ? 3 : cw < 300 ? 1 : 2;
    W = Math.floor(cw / SC); H = Math.floor(ch / SC);
    cv.width = W; cv.height = H; world.width = W; world.height = H;
    cv.style.width = W * SC + 'px'; cv.style.height = H * SC + 'px';
    hitsEl.style.width = W * SC + 'px'; hitsEl.style.height = H * SC + 'px';
    g.imageSmoothingEnabled = false; wg.imageSmoothingEnabled = false;
    L = layout(W, H);
    firingsDirty = true; hillsKey = '';
  }

  function layout(W, H) {
    const tall = H > W * 1.2;
    const safe = (S.appearance && obj(S.appearance.safe_areas)) ? S.appearance.safe_areas : {};
    const inset = (k) => Math.ceil((Number(safe[k]) || 0) / SC);
    const o = { tall };
    if (!tall) {
      const roadH = 76;
      o.road = { y0: H - roadH, y1: H };
      o.road.stand = o.road.y0 + 30;
      o.street = { y0: o.road.y0 - 22, y1: o.road.y0 };
      const fg = o.street.y0, bg = fg - 54;
      const x0 = 104, x1 = W - 106;
      o.rows = [{ ground: fg, x0, x1, maxH: 54 }, { ground: bg, x0: x0 + 6, x1: x1 - 2, maxH: 999 }];
      o.horizon = bg - 8;
      o.hillL = { x1: x0 + 18, peakX: 44, peakY: bg - 44, base: fg };
      o.mill = { x: o.hillL.peakX, y: o.hillL.peakY + 2 };
      o.board = { x: 4, y: o.hillL.peakY + 14, w: 84, h: 36 };
      o.hillR = { x0: x1 - 4, peakX: W - 30, peakY: bg - 30, base: fg };
      o.track = { y: fg, x0: x1 + 2, x1: W };
      o.tunnelX = W - 40; o.stopX = x1 + 6;
      o.nowX = Math.round(W * 0.3);
      o.ppm = 2;
      o.title = { x: 8 + inset('left'), y: 8 + inset('top'), s: 3 };
    } else {
      const roadH = 96;
      o.road = { y0: H - roadH, y1: H };
      o.road.stand = o.road.y0 + 32;
      o.street = { y0: o.road.y0 - 22, y1: o.road.y0 };
      const fg = o.street.y0;
      o.rows = [{ ground: fg, x0: 4, x1: W - 4, maxH: 56 }, { ground: fg - 56, x0: 4, x1: W - 4, maxH: 56 }, { ground: fg - 112, x0: 4, x1: W - 4, maxH: 999, tallFirst: true }];
      o.horizon = fg - 120;
      o.hillL = { x1: 120, peakX: 28, peakY: 94, base: fg - 112 };
      o.mill = { x: 28, y: 96 };
      o.board = { x: 58, y: 54, w: 78, h: 36, post: 40 };
      const ty = 130;
      o.hillR = { x0: 100, peakX: W - 20, peakY: ty - 26, base: fg - 112, plateau: ty };
      o.track = { y: ty, x0: 98, x1: W };
      o.tunnelX = W - 38; o.stopX = 104;
      o.tramBehind = true;
      o.nowX = Math.round(W * 0.34);
      o.ppm = 1.6;
      o.title = { x: 6 + inset('left'), y: 6 + inset('top'), s: 2 };
    }
    o.planX = W - 6 - inset('right');
    // the town: buildings flow into rows, front first, each into the first row with room for it
    const ids = ['house'];
    for (const p of R.order()) if (on(p)) ids.push(...PARTS[p].bld);
    const rows = o.rows.map((r) => ({ ...r, items: [] }));
    for (const id of ids) {
      const b = Art.B[id];
      const r = rows.find((r) => b.h <= r.maxH && r.items.reduce((s, x) => s + Art.B[x].w + 4, 0) + b.w <= r.x1 - r.x0);
      if (r) r.items.push(id);
    }
    o.blds = {};
    for (const r of rows) if (r.tallFirst) r.items.sort((a, b) => Art.B[b].h - Art.B[a].h);
    for (const r of rows) {
      const used = r.items.reduce((s, x) => s + Art.B[x].w, 0);
      const gap = r.items.length > 1 ? Math.min(14, Math.floor((r.x1 - r.x0 - used) / (r.items.length - 1))) : 0;
      let x = r.x0;
      for (const id of r.items) { o.blds[id] = { x, ground: r.ground, w: Art.B[id].w, h: Art.B[id].h }; x += Art.B[id].w + gap; }
    }
    o.townRows = rows;
    const house = o.blds.house;
    o.doorX = house ? house.x + Art.B.house.door : 40;
    o.queueY = o.street.y0 + 15;
    o.card = tall ? { x: 0, w: W, bottom: H } : { x: 6, w: W - 12, bottom: H - 6 };
    return o;
  }

  // ---- the firings on the road ---------------------------------------------------------------
  // A schedule's cron is CYFR's, read in UTC, its next run the server's own. What fires after
  // that is read from the cron; a cron this page cannot read shows its next run alone.
  const CRON_NAMES = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12, sun: 0, mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6 };
  const CRON_MACROS = { '@hourly': '0 * * * *', '@daily': '0 0 * * *', '@midnight': '0 0 * * *', '@weekly': '0 0 * * 0', '@monthly': '0 0 1 * *', '@yearly': '0 0 1 1 *', '@annually': '0 0 1 1 *' };
  function cronField(spec, lo, hi, dow) {
    if (spec === '*' || spec === '?') return null;
    const set = new Set();
    const num = (v) => { const n = CRON_NAMES[v.toLowerCase()] ?? (/^\d+$/.test(v) ? Number(v) : NaN); if (Number.isNaN(n)) throw new Error('cron'); return dow && n === 7 ? 0 : n; };
    for (const part of spec.split(',')) {
      const [range, step] = part.split('/');
      const st = step ? Number(step) : 1;
      if (!(st >= 1)) throw new Error('cron');
      let a, b;
      if (range === '*') { a = lo; b = hi; } else if (range.includes('-')) [a, b] = range.split('-').map(num); else { a = num(range); b = step ? hi : a; }
      for (let v = a; v <= b; v += st) set.add(dow && v === 7 ? 0 : v);
    }
    return set;
  }
  function parseCron(expr) {
    const parts = (CRON_MACROS[expr.trim()] || expr).trim().split(/\s+/);
    if (parts.length !== 5) return null;
    try { return { mi: cronField(parts[0], 0, 59), ho: cronField(parts[1], 0, 23), dom: cronField(parts[2], 1, 31), mo: cronField(parts[3], 1, 12), dow: cronField(parts[4], 0, 7, true) }; }
    catch (e) { return null; }
  }
  const has = (set, v) => set === null || set.has(v);
  function cronTimes(c, fromMs, toMs, cap) {
    const out = [];
    let t = Math.ceil(fromMs / 60000) * 60000;
    while (t <= toMs && out.length < cap) {
      const d = new Date(t);
      const dayOk = has(c.mo, d.getUTCMonth() + 1) && (c.dom === null && c.dow === null ? true : c.dom === null ? c.dow.has(d.getUTCDay()) : c.dow === null ? c.dom.has(d.getUTCDate()) : c.dom.has(d.getUTCDate()) || c.dow.has(d.getUTCDay()));
      if (!dayOk) { t = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1); continue; }
      if (!has(c.ho, d.getUTCHours())) { t = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), d.getUTCHours() + 1); continue; }
      if (has(c.mi, d.getUTCMinutes())) out.push(t);
      t += 60000;
    }
    return out;
  }
  const HURDLES = ['mill', 'paper', 'barrel', 'bell'];
  const hurdleOf = (sid) => { let h = 0; for (const ch of sid) h = (h * 31 + ch.charCodeAt(0)) >>> 0; return HURDLES[h % HURDLES.length]; };
  let firings = [], firingsDirty = true;
  function buildFirings() {
    firings = [];
    const n = Date.now(), end = n + (AHEAD + 60) * 60000;
    for (const r of R.values(S.scheduleRuns)) if (r.at != null) firings.push({ at: r.at, sid: r.sid, status: r.kind === 'failed' ? 'failed' : 'ok', cause: r.cause });
    for (const s of schedules()) {
      if (s.status !== 'active' && s.status !== 'paused') continue;
      const status = s.status === 'active' ? 'due' : 'paused';
      const c = s.cron ? parseCron(s.cron) : null;
      const from = status === 'due' && Number.isFinite(s.nextUtc) ? s.nextUtc : n;
      const times = c ? cronTimes(c, Math.max(from, n), end, 400) : [];
      if (status === 'due' && Number.isFinite(s.nextUtc) && s.nextUtc >= n - 60000 && !times.includes(s.nextUtc)) times.unshift(s.nextUtc);
      for (const t of times) firings.push({ at: R.localOf(t), sid: s.id, status });
    }
    // a failed run of no schedule stands where its failure is dated
    for (const a of attention()) if (a.kind === 'failed_run') firings.push({ at: a.since, sid: null, status: 'failed', ref: a.label });
    firings.sort((a, b) => a.at - b.at);
    firingsDirty = false;
  }

  // ---- view: the time being looked at -------------------------------------------------------
  const view = { off: 0, vel: 0, drag: null, idle: 0, follow: true, target: null };
  const viewT = () => now() + view.off;
  const xAt = (m) => L.nowX + (m - viewT()) * L.ppm;
  function jumpTo(m) { view.target = Math.max(-BEHIND, Math.min(AHEAD, m - now())); view.follow = false; view.idle = 0; wake(); }
  function setOff(off) { view.off = Math.max(-BEHIND, Math.min(AHEAD, off)); }

  // ---- characters ----------------------------------------------------------------------------
  const LOOKS = {
    failed_run: { id: 'news', hair: '#3b2a20', skin: '#e0b48f', shirt: '#46679c', pants: '#3a3a3d', bubble: 'bang', bc: P.red },
    failed_schedule: { id: 'bell', hair: '#5a3d2a', skin: '#d9a77f', shirt: P.ochreS, pants: '#3b3a2e', bubble: 'bang', bc: P.amberD },
    approval: { id: 'aqua', hair: '#1f3d4a', skin: '#cf9f7c', shirt: P.aqua, pants: '#2f5961', bubble: 'scroll', bc: P.aquaD },
    confirmation: { id: 'porter', hair: '#6a3a22', skin: '#f0c9a4', shirt: P.pinkS, pants: '#4a3b40', bubble: 'key', bc: P.amberD },
    file_offer: { id: 'sam', hair: '#1a1a1a', skin: '#a8714a', shirt: P.greenD, pants: '#2e3b52', bubble: 'parcel', bc: P.wood },
  };
  const lookOf = (kind) => LOOKS[kind] || LOOKS.confirmation;
  const EXPLORER = { id: 'explorer', hair: '#7a4b22', skin: '#e3b38c', shirt: '#c26b2e', pants: '#4b5a3a' };
  const visitors = new Map(); // attention id -> {x, leaving, wave}
  const explorer = { x: 0, dir: 1, inited: false };
  const capy = { jump: 0, trip: 0, lastT: null, blink: false };
  const fx = [];
  let ticker = null;
  let millAngle = 0, tramPos = 0, tramDir = 1, tramWait = 0, towerRing = 0;

  // ---- interaction state ---------------------------------------------------------------------
  let card = null, planSel = null;
  const pending = { weather: null, vpn: null, sched: new Set() };

  R.subscribe((ch) => {
    firingsDirty = true;
    if (ch.stream === 'feeds' && pending[ch.feed]) pending[ch.feed] = null;
    if (ch.stream === 'attention' && ch.removed) {
      const v = visitors.get(ch.removed);
      if (v) { v.leaving = true; v.wave = 1.6; }
      if (card === 'att:' + ch.removed) card = null;
      announce('Settled, and gone from your house.');
    }
    if (ch.stream === 'prefs' || ch.stream === 'posture' || ch.stream === 'installed') relayout();
    if (ch.stream === 'covered') setCovered(S.covered);
    wake();
  });

  function say(text) { ticker = { text, t: 3.2 }; announce(text); }
  function askAqua(widget, from) {
    if (from) fx.push({ kind: 'drop', x: from.x, y: from.y, tx: W - 10, ty: 4, t: 0 });
    R.ask(widget);
    say("AQUA's panel opens with a sentence about the " + PARTS[widget].name.toLowerCase() + '. Nothing is sent.');
  }
  function settings(page, words) { R.settings(page); say('Opening ' + words + '.'); }
  async function press(s) {
    pending.sched.add(s.id);
    const pause = s.status === 'active';
    say((pause ? 'Pausing ' : 'Resuming ') + s.name + '.');
    const failed = await R.press(pause ? R.PAUSE : R.RESUME, s.id);
    pending.sched.delete(s.id);
    if (failed) say(failed);
  }
  function pressFeed(feed, action, words) {
    pending[feed] = { action: action.name, until: performance.now() + 20000 };
    R.pressFeed(feed, action.name);
    say(words + ': ' + action.label + ' sent.');
  }
  async function write(widgets) { const failed = await R.write(widgets); if (failed) say(failed); }
  function announce(s) { live.textContent = ''; setTimeout(() => (live.textContent = s), 30); }
  function ring(x, y, c) { fx.push({ kind: 'ring', x, y, c, t: 0 }); }

  // ---- cards ---------------------------------------------------------------------------------
  // A card is a dialogue box in the village's own manner: a portrait, a title, plain lines, rows to
  // pick and choices. Each choice is one tap.
  function cardModel(key) {
    const i = key.indexOf(':'), kind = i < 0 ? key : key.slice(0, i), id = i < 0 ? '' : key.slice(i + 1);
    const n = now();
    const ask = (widget, part) => ({ label: 'Ask AQUA', aqua: true, run: () => askAqua(widget, partCentre(part || widget)) });
    if (kind === 'weather') {
      const w = weatherNow();
      if (!w) return { title: 'The windmill', portrait: 'mill', lines: ['No weather feed is bound by the name "weather", so the sails stand still.', 'Ask AQUA to bind one, and its forecast shows on the board.'], choices: [ask('weather')] };
      const base = Math.ceil(n / 60) * 60;
      return { title: 'Weather in ' + w.place, portrait: 'mill', lines: [
        temp(w.temp) + unitMark() + (w.sky ? ', ' + w.sky : '') + (w.wind != null ? ', wind ' + w.wind + ' km/h' : '') + '.',
        ...(w.next.length ? ['Next hours  ' + w.next.slice(0, 4).map((c, k) => hm(base + k * 60) + ' ' + temp(c)).join('   ')] : []),
        pending.weather ? 'Asked; waiting for the next result.' : 'Fetched ' + when(w.at) + '.',
      ], choices: [
        ...w.actions.map((a, k) => ({ label: a.label, primary: k === 0, disabled: !!pending.weather, run: () => pressFeed('weather', a, 'Weather') })),
        { label: R.units() === 'c' ? 'Show °F' : 'Show °C', run: () => write({ weather: R.entry('weather', { units: R.units() === 'c' ? 'f' : 'c' }) }) },
        ask('weather'),
      ] };
    }
    if (kind === 'vpn') {
      const v = vpnNow();
      if (!v) return { title: 'The tram line', portrait: 'tram', lines: ['No feed is bound by the name "vpn", so the tram waits in its depot.', 'Ask AQUA to bind one, and the tram runs while it is connected.'], choices: [ask('vpn')] };
      const line = pending.vpn ? 'Asked; waiting for the feed to say so.' : v.connected ? 'Connected' + (v.server ? ' to ' + v.server : '') + (v.since != null ? ' since ' + when(v.since) : '') + (v.mbps != null ? ', ' + v.mbps + ' Mbps down' : '') + '.' : 'Not connected (' + v.state + ').';
      return { title: v.label || 'VPN', portrait: 'tram', lines: [line, ...(v.servers.length ? ['Lines: ' + v.servers.join(', ') + '.'] : [])],
        choices: [...v.actions.map((a, k) => ({ label: a.label, primary: k === 0, disabled: !!pending.vpn, run: () => pressFeed('vpn', a, 'VPN') })), ask('vpn')] };
    }
    if (kind === 'att') {
      const h = S.attention.get(id); if (!h) return null;
      const a = h.value, since = 'Waiting since ' + when(a.since) + (a.since != null ? ', ' + dur(n - a.since) : '') + '.';
      const look = { failed_run: 'news', failed_schedule: 'bell', approval: 'aqua', file_offer: 'sam' }[a.kind] || 'porter';
      const open = (page, words) => (page ? [{ label: words, primary: true, run: () => settings(page, words.replace(/^Open /, 'the ').toLowerCase()) }] : []);
      if (a.kind === 'failed_run') return { title: a.label + ' failed', portrait: look, lines: ['Its last run failed, and no run of it has ended since.', since], choices: [...open(a.page, 'Open runs'), { label: 'Show on road', run: () => { jumpTo(a.since); closeCard(); } }, ask('attention', key)] };
      if (a.kind === 'failed_schedule') return { title: a.label + ' failed', portrait: look, lines: ['The schedule\'s last run failed or its outcome is uncertain.', since], choices: [...open(a.page, 'Open schedules'), { label: 'Show on road', run: () => { jumpTo(a.since); closeCard(); } }, ask('attention', key)] };
      if (a.kind === 'approval') return { title: 'Approval in ' + a.label, portrait: look, lines: ['AQUA is waiting on your answer in this thread.', since], choices: [...open(a.page, 'Open chat'), ask('attention', key)] };
      if (a.kind === 'file_offer') return { title: a.label + ' is offered to you', portrait: look, lines: ['A file waits for you to accept or decline it.', since], choices: [...open(a.page, 'Open files'), ask('attention', key)] };
      return { title: 'Confirm ' + a.label, portrait: look, lines: ['CYFR asks you to confirm this in its own prompt, wherever you are.', since], choices: [ask('attention', key)] };
    }
    if (kind === 'queue') {
      const list = attention();
      return { title: list.length ? list.length + ' waiting at your house' : 'Nobody waiting', portrait: 'house', lines: list.length ? [] : ['Everything that waited on you is done.'],
        rows: list.map((a) => ({ text: attLabel(a), sub: when(a.since), dot: lookOf(a.kind).bc, run: () => openCard('att:' + a.id) })), choices: [] };
    }
    if (kind === 'threads') return { title: 'Threads', portrait: 'post', lines: S.threads.size ? [] : ['No threads yet.'],
      rows: threads().map((t) => ({ text: t.title, sub: (t.waits ? 'waits on you, ' : '') + (t.own ? 'with AQUA' : t.people + (t.people === 1 ? ' person' : ' people')) + ', ' + when(t.last), dot: t.waits ? P.red : null,
        run: () => settings('chat', 'the chat') })), choices: [ask('threads')] };
    if (kind === 'crew') {
      const list = jobs();
      return { title: 'Crew', portrait: 'crew', lines: list.length ? list.map((j) => j.member + ' is at work' + (j.askedBy ? ', asked by ' + j.askedBy : '') + ', since ' + when(j.since) + (j.status ? ' (' + j.status + ')' : '') + '.') : ['Nobody is out on a job.'],
        choices: [{ label: 'Open activities', primary: true, run: () => settings('activities', 'activities') }, ask('activity')] };
    }
    if (kind === 'market') return { title: 'Apps', portrait: 'market', lines: S.installed.length ? [] : ['No apps are installed yet.'],
      rows: S.installed.map((a) => ({ text: a.name, sub: a.open ? 'open' : 'tap to open', run: () => { R.open(a.ref); say('Opening ' + a.name + '.'); } })),
      choices: [{ label: 'Components', run: () => settings('components', 'components') }, ask('components')] };
    if (kind === 'press') {
      const failed = attention().filter((a) => a.kind === 'failed_run');
      return { title: 'The press', portrait: 'news', lines: failed.length ? ['Its placard is red while a run failed and nothing has run since.'] : ['Every run that failed has run again since.'],
        rows: failed.map((a) => ({ text: a.label, sub: 'failed ' + when(a.since), dot: P.red, run: () => openCard('att:' + a.id) })),
        choices: [{ label: 'Open runs', primary: true, run: () => settings('executions', 'runs') }, ask('schedules', 'press')] };
    }
    if (kind === 'barn') {
      const paused = schedules().filter((s) => s.status === 'paused');
      return { title: 'The barn', portrait: 'barn', lines: [paused.length ? 'Planked shut while a schedule is paused.' : 'Open: no schedule is paused.'],
        rows: paused.map((s) => ({ text: s.name, sub: 'paused, last ' + when(s.last), dot: P.whiteD, run: () => openCard('sched:' + s.id) })), choices: [] };
    }
    if (kind === 'sched') {
      const s = sched(id); if (!s) return null;
      const busy = pending.sched.has(s.id);
      const next = s.status === 'active' && s.next != null ? 'next ' + when(s.next) : s.status;
      const canPress = s.status === 'active' || s.status === 'paused';
      return { title: s.name, portrait: 'tower', lines: [
        (s.cron ? cronWords(s.cron) + ', ' : '') + next + '.',
        s.runs + (s.runs === 1 ? ' run, ' : ' runs, ') + s.errors + (s.errors === 1 ? ' error' : ' errors') + (s.last != null ? ', last ' + when(s.last) : '') + '.'],
        choices: [
          ...(canPress ? [{ label: busy ? '...' : s.status === 'active' ? 'Pause' : 'Resume', primary: true, disabled: busy, run: () => press(s) }] : []),
          { label: 'Open schedules', run: () => settings('schedules', 'schedules') },
          ...(s.status === 'active' && s.next != null ? [{ label: 'Show on road', run: () => { jumpTo(s.next); closeCard(); } }] : []),
        ] };
    }
    if (kind === 'tower') return { title: 'Schedules', portrait: 'tower', lines: S.schedules.size ? [] : ['No schedules yet.'],
      rows: schedules().map((s) => ({ text: s.name, sub: s.status === 'active' ? 'next ' + when(s.next) : s.status, dot: s.status !== 'active' ? P.whiteD : s.errors ? P.amber : P.green, run: () => openCard('sched:' + s.id) })), choices: [ask('schedules', 'tower')] };
    if (kind === 'vault') return { title: 'Vault', portrait: 'vault', lines: ['Names and states only; no value ever shows here.'],
      rows: vault().map((v) => ({ text: v.name, sub: (v.type ? v.type + ', ' : '') + (v.fine ? 'fine' : 'needs re-authorisation'), dot: v.fine ? P.green : P.red, run: () => settings('vault', 'the vault') })),
      choices: [ask('vault')] };
    if (kind === 'plan') {
      const ids = ['attention', ...R.order(), 'weather', 'vpn'];
      const movable = planSel && PARTS[planSel].order;
      const done = { label: 'Done', primary: true, run: () => { planSel = null; closeCard(); } };
      return { title: 'Plan the village', portrait: 'plan', noClose: true, lines: ['Turn parts on or off. Pick one, then move it along the street.'],
        rows: ids.map((p) => ({ text: PARTS[p].name, sub: PARTS[p].what, toggle: on(p), sel: planSel === p, run: () => { planSel = planSel === p ? null : p; }, flip: () => write({ [p]: R.entry(p, { on: !on(p) }) }) })),
        choices: movable ? [{ label: '< Earlier', run: () => movePart(planSel, -1) }, { label: 'Later >', run: () => movePart(planSel, 1) }, done] : [done] };
    }
    return null;
  }
  function attLabel(a) {
    return a.kind === 'failed_run' || a.kind === 'failed_schedule' ? a.label + ' failed' : a.kind === 'approval' ? 'Approval in ' + a.label : a.kind === 'file_offer' ? a.label + ' offered' : 'Confirm ' + a.label;
  }
  function cronWords(c) {
    const p = (CRON_MACROS[c.trim()] || c).trim().split(/\s+/);
    if (p.length !== 5) return c;
    const [mi, ho, dom, mo, dw] = p;
    if (/^\*\/\d+$/.test(mi) && ho === '*' && dom === '*' && mo === '*' && dw === '*') return 'Every ' + mi.slice(2) + ' minutes';
    if (mi === '*' && ho === '*' && dom === '*' && mo === '*' && dw === '*') return 'Every minute';
    if (/^\d+$/.test(mi) && ho === '*' && dom === '*' && mo === '*' && dw === '*') return 'Every hour at :' + pad(Number(mi));
    if (/^\d+$/.test(mi) && /^\d+$/.test(ho) && dom === '*' && mo === '*') {
      // the cron's UTC hour on the person's clock, said only when it stays on the same day
      const t = Date.UTC(2026, 0, 4, Number(ho), Number(mi)), m = R.localOf(t);
      const at = hm(m), same = dayIx(m) === 0;
      if (dw === '*') return 'Every day at ' + at;
      if (dw === '1-5' && same) return 'Weekdays at ' + at;
      if (/^[0-7]$/.test(dw) && same) return WEEKDAYS[Number(dw) % 7] + 's at ' + at;
    }
    return 'cron ' + c + ' (UTC)';
  }
  function movePart(p, d) {
    const list = R.order(), i = list.indexOf(p), j = i + d;
    if (j < 0 || j >= list.length) return;
    const q = list[j];
    write({ [p]: R.entry(p, { order: j + 1 }), [q]: R.entry(q, { order: i + 1 }) });
  }
  function openCard(key) { const m = key && cardModel(key); if (!m) return; card = key; announce(m.title + '. ' + (m.lines || []).join(' ')); wake(); }
  function closeCard() { card = null; planSel = null; }
  function partCentre(part) {
    const b = L.blds;
    const at = { weather: L.mill && { x: L.mill.x, y: L.mill.y - 20 }, vpn: { x: L.stopX + 20, y: L.track.y - 20 }, activity: b.crew && { x: b.crew.x + 20, y: b.crew.ground - 30 },
      threads: b.post && { x: b.post.x + 20, y: b.post.ground - 20 }, components: b.market && { x: b.market.x + 30, y: b.market.ground - 30 }, vault: b.vault && { x: b.vault.x + 20, y: b.vault.ground - 20 },
      tower: b.tower && { x: b.tower.x + 12, y: b.tower.ground - 60 }, press: b.press && { x: b.press.x + 20, y: b.press.ground - 30 }, schedules: { x: L.nowX, y: L.road.stand - 10 } }[part];
    if (at) return at;
    if (part && part.startsWith('att:')) { const v = visitors.get(part.slice(4)); if (v) return { x: v.x, y: L.queueY - 20 }; }
    return { x: W / 2, y: H / 2 };
  }

  // ---- hit layer -----------------------------------------------------------------------------
  const hitPool = new Map();
  let hitSeen = new Set();
  function hit(id, x, y, w, h, label, onTap, o = {}) {
    hitSeen.add(id);
    let e = hitPool.get(id);
    if (!e) {
      e = document.createElement('button');
      e.type = 'button'; e.className = 'hit';
      e.addEventListener('click', (ev) => { ev.stopPropagation(); const f = e._tap; if (f) f(); wake(); });
      e.addEventListener('pointerdown', (ev) => ev.stopPropagation());
      hitPool.set(id, e); hitsEl.appendChild(e);
    }
    e._tap = onTap;
    // touch targets keep 22 logical px (44 css px) at the least, centred on the thing
    const mw = o.exact ? w : Math.max(w, 22), mh = o.exact ? h : Math.max(h, 22);
    const r = [Math.round((x - (mw - w) / 2) * SC), Math.round((y - (mh - h) / 2) * SC), Math.round(mw * SC), Math.round(mh * SC)].join(',');
    if (e._r !== r) { const [a, b, c, d] = r.split(','); e.style.cssText = `left:${a}px;top:${b}px;width:${c}px;height:${d}px`; e._r = r; }
    if (e._l !== label) { e.setAttribute('aria-label', label); e._l = label; }
    const dis = !!o.disabled;
    if (e.disabled !== dis) e.disabled = dis;
    if (o.pressed != null) e.setAttribute('aria-pressed', String(o.pressed)); else e.removeAttribute('aria-pressed');
    e.tabIndex = o.tab != null ? o.tab : 0;
    e.style.zIndex = o.z || 1;
  }
  function hitsDone() {
    for (const [id, e] of hitPool) if (!hitSeen.has(id)) { e.remove(); hitPool.delete(id); }
    hitSeen = new Set();
  }

  // ---- the road: drag to look back or ahead --------------------------------------------------
  const road = document.getElementById('road');
  road.setAttribute('aria-valuemin', String(-BEHIND));
  road.setAttribute('aria-valuemax', String(AHEAD));
  let lastMove = 0;
  road.addEventListener('pointerdown', (e) => {
    road.setPointerCapture(e.pointerId);
    view.drag = { x0: e.clientX, off0: view.off, moved: 0, last: e.clientX, lt: performance.now() };
    view.vel = 0; view.follow = false; view.target = null; wake();
  });
  road.addEventListener('pointermove', (e) => {
    const d = view.drag; if (!d) return;
    const dx = (e.clientX - d.x0) / SC;
    d.moved = Math.max(d.moved, Math.abs(dx));
    const t = performance.now();
    const inst = -((e.clientX - d.last) / SC) / L.ppm / Math.max(1, t - d.lt) * 16.7;
    view.vel = view.vel * 0.5 + inst * 0.5;
    d.last = e.clientX; d.lt = t; lastMove = t;
    setOff(d.off0 - dx / L.ppm);
  });
  const endDrag = (e) => {
    const d = view.drag; view.drag = null; if (!d) return;
    if (d.moved < 3) { view.vel = 0; tapRoad((e.clientX - stage.getBoundingClientRect().left) / SC); }
    else if (performance.now() - lastMove > 80) view.vel = 0;
    view.idle = 0;
  };
  road.addEventListener('pointerup', endDrag);
  road.addEventListener('pointercancel', endDrag);
  road.addEventListener('keydown', (e) => {
    const k = e.key; let d = 0;
    if (k === 'ArrowRight') d = 10; else if (k === 'ArrowLeft') d = -10; else if (k === 'PageUp') d = 60; else if (k === 'PageDown') d = -60;
    else if (k === 'Home') { view.target = 0; wake(); e.preventDefault(); return; }
    else if (k === 'Enter' || k === ' ') { const f = nearestFiring(viewT(), 8); if (f && f.sid) openCard('sched:' + f.sid); e.preventDefault(); return; }
    if (d) { view.follow = false; view.target = null; setOff(view.off + d); view.idle = 0; wake(); e.preventDefault(); }
  });
  function tapRoad(x) {
    if (Math.abs(x - L.nowX) < 12) return poke();
    const m = viewT() + (x - L.nowX) / L.ppm;
    const f = nearestFiring(m, 8 / L.ppm + 4);
    if (f && f.sid && sched(f.sid)) openCard('sched:' + f.sid);
    else if (f) jumpTo(f.at);
  }
  function nearestFiring(m, tol) {
    let best = null, bd = tol;
    for (const f of firings) { const d = Math.abs(f.at - m); if (d <= bd) { bd = d; best = f; } }
    return best;
  }
  function poke() { if (!capy.jump) { capy.jump = 0.55; fx.push({ kind: 'note', x: L.nowX + 8, y: L.road.stand - 20, t: 0 }); } }

  // ---- drawing helpers -----------------------------------------------------------------------
  const lerp = (a, b, k) => a + (b - a) * k;
  const hex = (c) => [1, 3, 5].map((i) => parseInt(c.slice(i, i + 2), 16));
  const mix = (a, b, k) => { const A = hex(a), B2 = hex(b); return '#' + A.map((v, i) => Math.round(lerp(v, B2[i], k)).toString(16).padStart(2, '0')).join(''); };
  const hash = (n) => { n = (n << 13) ^ n; return ((n * (n * n * 15731 + 789221) + 1376312589) & 0x7fffffff) / 0x7fffffff; };
  // Sunrise and sunset are not in the catalog: the sky is drawn with 07:00 and 18:30.
  const SUNRISE = 420, SUNSET = 1110;
  function daylight(T) {
    const d = ((T % DAY) + DAY) % DAY;
    const k = (a, b) => Math.max(0, Math.min(1, (d - a) / (b - a)));
    if (d < SUNRISE - 50 || d > SUNSET + 70) return { day: 0, warm: 0 };
    if (d < SUNRISE + 40) return { day: k(SUNRISE - 50, SUNRISE + 40), warm: 1 - Math.abs(k(SUNRISE - 50, SUNRISE + 40) - 0.5) * 2 };
    if (d > SUNSET - 40) return { day: 1 - k(SUNSET - 40, SUNSET + 70), warm: 1 - Math.abs(k(SUNSET - 40, SUNSET + 70) - 0.4) * 1.6 };
    return { day: 1, warm: 0 };
  }
  function skyColours(T) {
    const { day, warm } = daylight(T);
    return [mix(mix('#0c1530', '#4fa9e6', day), '#41508f', warm * 0.6), mix(mix('#22335f', '#bfe6fb', day), '#f39a62', warm * 0.75)];
  }
  function disc(cx, cy, r, c) { g.fillStyle = c; for (let y = -r; y <= r; y++) { const w = Math.floor(Math.sqrt(r * r - y * y)); g.fillRect(cx - w, cy + y, w * 2 + 1, 1); } }

  function drawSky(T, ts) {
    const [top, bot] = skyColours(T);
    const bands = 9, bh = Math.ceil((L.horizon + 30) / bands);
    for (let i = 0; i < bands; i++) {
      fill(g, 0, i * bh, W, bh, mix(top, bot, i / (bands - 1)));
      if (i < bands - 1) { g.fillStyle = mix(top, bot, (i + 1) / (bands - 1)); for (let x = (i % 2); x < W; x += 2) g.fillRect(x, i * bh + bh - 1, 1, 1); for (let x = ((i + 1) % 2); x < W; x += 4) g.fillRect(x, i * bh + bh - 2, 1, 1); }
    }
    fill(g, 0, bands * bh, W, H, bot);
    const { day } = daylight(T);
    if (day < 0.6) { g.fillStyle = 'rgba(255,255,240,' + (0.9 - day * 1.4) + ')'; for (let i = 0; i < 70; i++) g.fillRect(Math.floor(hash(i * 7 + 1) * W), Math.floor(hash(i * 13 + 5) * L.horizon * 0.9), 1, 1); }
    // the sun or the moon crosses the sky with the time being looked at
    const d = ((T % DAY) + DAY) % DAY;
    const arcTop = L.tall ? 34 : 26, arcLow = L.horizon - 6;
    const body = (k, r, c, rim) => { const x = Math.round(lerp(16, W - 16, k)), y = Math.round(arcLow - Math.sin(k * Math.PI) * (arcLow - arcTop)); disc(x, y, r, rim); disc(x, y, r - 1, c); return { x, y }; };
    if (d > SUNRISE - 20 && d < SUNSET + 20) body((d - SUNRISE + 20) / (SUNSET - SUNRISE + 40), 7, '#ffe27a', '#ffc94a');
    else { const nd = d > SUNSET ? d - SUNSET : d + DAY - SUNSET; const s = body(nd / (DAY - (SUNSET - SUNRISE)), 5, '#f1f0e4', '#c9c8bc'); fill(g, s.x + 1, s.y - 3, 3, 3, mix(top, bot, 0.3)); }
    // two gulls over the river
    if (day > 0.3) for (let i = 0; i < 2; i++) { const x = ((ts * (6 + i * 3) + i * 200) % (W + 40)) - 20, y = L.horizon - 40 - i * 14 + Math.sin(ts * 2 + i) * 2; g.fillStyle = '#f7f7f2'; g.fillRect(x, y, 2, 1); g.fillRect(x + 3, y, 2, 1); g.fillRect(x + 2, y + 1, 1, 1); }
  }

  function drawFar(ts) {
    const hz = L.horizon;
    for (let x = 0; x < W; x++) { const h = 6 + Math.round(Math.sin(x / 37) * 3 + Math.sin(x / 13) * 1.5); fill(wg, x, hz - h - 10, 1, h, P.far); if (hash(x) > 0.86) fill(wg, x, hz - h - 12, 1, 2, P.farD); }
    fill(wg, 0, hz - 10, W, 12, P.river);
    for (let i = 0; i < 26; i++) fill(wg, Math.floor((hash(i * 3 + 2) * W + ts * (2 + (i % 3))) % W), hz - 9 + (i % 5) * 2, 3, 1, P.riverL);
    fill(wg, 0, hz + 2, W, 1, P.riverD);
    // the ferry crossing, slowly
    const fxp = ((ts * 3) % (W + 60)) - 30;
    fill(wg, fxp, hz - 6, 16, 3, P.white); fill(wg, fxp + 2, hz - 9, 9, 3, P.whiteS); fill(wg, fxp + 4, hz - 11, 2, 2, P.red); fill(wg, fxp - 1, hz - 3, 18, 1, P.riverD);
  }

  function hillFill(c, x0, x1, yf, base) {
    for (let x = x0; x < x1; x++) {
      const y = Math.round(yf(x));
      if (y >= base) continue;
      fill(c, x, y, 1, base - y + 2, P.grass);
      fill(c, x, y, 1, 1, P.grassL);
      if (hash(x * 31) > 0.7) fill(c, x, y + 2 + Math.floor(hash(x) * 6), 1, 1, P.grassD);
      if (hash(x * 17 + 3) > 0.8) fill(c, x, y + 9 + Math.floor(hash(x + 9) * 14), 1, 1, P.earth);
    }
  }
  function tree(c, x, y) { fill(c, x, y - 3, 1, 4, P.woodD); fill(c, x - 3, y - 8, 7, 5, P.olive); fill(c, x - 2, y - 10, 5, 2, P.olive); fill(c, x - 3, y - 4, 7, 1, P.oliveD); }
  function cypress(c, x, y) { fill(c, x - 1, y - 12, 3, 12, P.oliveD); fill(c, x, y - 15, 1, 3, P.oliveD); fill(c, x - 1, y - 10, 1, 6, P.olive); }

  let hillsCache = null, hillsKey = '';
  function drawHills(lights) {
    const key = W + 'x' + H + on('weather');
    if (hillsKey !== key) {
      hillsCache = document.createElement('canvas'); hillsCache.width = W; hillsCache.height = H;
      paintHills(hillsCache.getContext('2d')); hillsKey = key;
    }
    wg.drawImage(hillsCache, 0, 0);
    if (on('weather')) Art.mill(wg, L.mill.x, L.mill.y, millAngle, lights);
  }
  function paintHills(c) {
    const hl = L.hillL, hr = L.hillR;
    const yl = (x) => { const k = (x - hl.peakX) / (x < hl.peakX ? hl.peakX + 30 : hl.x1 - hl.peakX); return hl.peakY + (hl.base - hl.peakY) * Math.min(1, k * k); };
    hillFill(c, 0, hl.x1, yl, hl.base + 40);
    if (on('weather')) { tree(c, hl.peakX + 26, Math.round(yl(hl.peakX + 26)) + 1); cypress(c, hl.peakX - 22, Math.round(yl(hl.peakX - 22)) + 1); }
    if (L.tall) {
      const yr = (x) => (x < hr.x0 + 12 ? hr.plateau + (hr.x0 + 12 - x) * 2 : x > W - 50 ? hr.plateau - Math.min(30, (x - (W - 50)) * 1.4) : hr.plateau);
      hillFill(c, hr.x0 - 20, W, yr, hl.base + 40);
    } else {
      const yr = (x) => { const k = (hr.peakX - x) / (hr.peakX - hr.x0); return x > hr.peakX ? hr.peakY : hr.peakY + (hr.base - hr.peakY) * Math.min(1, k * k); };
      hillFill(c, hr.x0, W, yr, hr.base + 40);
      cypress(c, W - 64, Math.round(yr(W - 64)) + 1);
    }
  }

  function drawTerrace(rowFront, rowBack) {
    // the stone retaining wall between two streets, with a band of tiles
    const y0 = rowBack.ground, y1 = rowFront.ground, x = rowFront.x0 - 6, w = rowFront.x1 - rowFront.x0 + 12;
    fill(wg, x, y0, w, y1 - y0, P.stone);
    for (let j = y0 + 3; j < y1; j += 5) for (let i = x + ((j / 5) % 2 ? 0 : 4); i < rowFront.x1 + 6; i += 9) fill(wg, i, j, 6, 1, P.stoneD);
    fill(wg, x, y0, w, 2, P.stoneL);
    Art.azulejo(wg, x, y0 + 4, w, 8);
    fill(wg, x, y0 + 12, w, 1, P.stoneD);
  }

  function buildingState(id, T, ts) {
    const blink = Math.floor(ts * 2) % 2 === 0;
    if (id === 'house') return { name: fit(S.person || 'your place', 54) };
    if (id === 'post') return { threads: threads().map((t) => ({ kind: t.own ? 'own' : 'shared', unread: 0, people: t.people, waits_on_you: t.waits && (t.last == null || t.last <= T) })) };
    if (id === 'crew') { const n = jobs().filter((j) => j.since == null || j.since <= T).length; return { out: n > 0, jobs: n }; }
    if (id === 'market') return { apps: S.installed.map((a) => ({ letter: (Array.from(a.name)[0] || '?').toUpperCase(), open: a.open })) };
    if (id === 'press') return { state: attention().some((a) => a.kind === 'failed_run' && a.since <= T) ? 'failed' : 'ok', blink };
    if (id === 'tower') { const ringing = firings.some((f) => f.sid && Math.abs(f.at - T) < 0.6 && f.status !== 'paused'); return { minutes: Math.floor(((T % DAY) + DAY) % DAY), ring: ringing || towerRing > 0, t: ts }; }
    if (id === 'vault') return { vault: vault().map((v) => ({ status: v.fine ? 'fine' : 'needs' })), blink };
    if (id === 'barn') return { paused: schedules().some((s) => s.status === 'paused') };
    return {};
  }

  // ---- the frame -----------------------------------------------------------------------------
  // The scene draws at most 30 times a second while shown and live; a frozen desktop draws once,
  // with frost at its edges, and stops until it is live again.
  let lastTs = performance.now(), running = false, lastRender = 0;
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  function wake() { if (running || document.hidden || !L) return; running = true; lastTs = performance.now(); requestAnimationFrame(frame); }
  function frame(tsMs) {
    if (document.hidden) { running = false; return; }
    if (S.frozen) { safely(() => render(tsMs / 1000)); running = false; return; }
    if (tsMs - lastRender < 32) { requestAnimationFrame(frame); return; }
    lastRender = tsMs;
    const dt = Math.min(0.1, (tsMs - lastTs) / 1000); lastTs = tsMs;
    const ts = tsMs / 1000;
    safely(() => { step(dt, ts); render(ts); });
    if (running) requestAnimationFrame(frame);
  }
  // A scene that cannot draw gives way to the plain list of the same data.
  function safely(f) {
    try { f(); } catch (e) { console.error(e); running = false; document.documentElement.classList.remove('scene'); RoadList.show(); }
  }

  function step(dt, ts) {
    if (!view.drag) {
      if (view.target != null) {
        const d = view.target - view.off;
        setOff(reduce ? view.target : view.off + d * Math.min(1, dt * 5));
        if (Math.abs(view.target - view.off) < 0.5) { setOff(view.target); view.target = null; if (Math.abs(view.off) < 0.6) { view.off = 0; view.follow = true; } }
      } else if (Math.abs(view.vel) > 0.05) {
        setOff(view.off + view.vel * dt * 60); view.vel *= Math.pow(0.05, dt);
      } else if (!view.follow) {
        view.idle += dt;
        if (view.idle > 40 && !card) view.target = 0;
      }
    }
    // crossing a firing makes the timekeeper hop it; a failed one trips it; a paused one lies flat
    const T = viewT();
    if (capy.lastT != null && Math.abs(T - capy.lastT) < 600) {
      const lo = Math.min(T, capy.lastT), hi = Math.max(T, capy.lastT);
      for (const f of firings) if (f.at > lo && f.at <= hi && f.sid) {
        if (f.status === 'failed') { capy.trip = 0.7; capy.jump = 0; }
        else if (f.status !== 'paused' && !capy.trip) capy.jump = 0.45;
        if (view.follow) towerRing = 1.5;
      }
    }
    capy.lastT = T;
    capy.jump = Math.max(0, capy.jump - dt); capy.trip = Math.max(0, capy.trip - dt);
    towerRing = Math.max(0, towerRing - dt);
    capy.blink = (ts % 4) < 0.12;
    for (const k of ['weather', 'vpn']) if (pending[k] && performance.now() > pending[k].until) pending[k] = null;
    if (reduce) return;
    const w = weatherNow(), wind = w && w.wind != null ? w.wind : 0;
    if (w && on('weather')) {
      millAngle += dt * (0.4 + wind / 12);
      if (Math.random() < dt * wind / 30) fx.push({ kind: 'note', x: L.mill.x + 14, y: L.mill.y - 12, t: 0, small: true });
    }
    // the tram shuttles between the stop and the tunnel while connected, at the feed's speed
    const v = vpnAt(T);
    const span = L.tunnelX + 6 - (L.stopX + 2);
    if (v && v.connected && !pending.vpn) {
      if (tramWait > 0) tramWait -= dt; else {
        tramPos += tramDir * dt * (10 + (v.mbps != null ? v.mbps : 60) / 3);
        if (tramPos >= span) { tramPos = span; tramDir = -1; tramWait = 1.2; }
        if (tramPos <= 0) { tramPos = 0; tramDir = 1; tramWait = 2; fx.push({ kind: 'ding', x: L.stopX + 4, y: L.track.y - 32, t: 0 }); }
      }
    } else { tramPos = Math.max(0, tramPos - dt * 30); tramDir = 1; }
    // the crew's walker crosses town while a job runs
    const crew = L.blds.crew;
    if (crew && on('activity')) {
      const x0 = crew.x + 26, x1 = L.tall ? W - 12 : L.stopX - 4;
      if (!explorer.inited) { explorer.x = x0 + 30; explorer.inited = true; }
      explorer.x += explorer.dir * dt * 9;
      if (explorer.x > x1) explorer.dir = -1;
      if (explorer.x < x0) explorer.dir = 1;
    }
  }
  // The vpn as it stood at T: the feed says only how it stands now and since when.
  const vpnAt = (T) => { const v = vpnNow(); return v && (T >= now() - 0.5 || (v.since != null && T >= v.since)) ? v : null; };

  function render(ts) {
    const T = viewT();
    if (firingsDirty) buildFirings();
    const lights = [];
    drawSky(T, reduce ? 0 : ts);
    wg.clearRect(0, 0, W, H);
    drawFar(reduce ? 0 : ts);
    drawHills(lights);
    if (L.tramBehind) drawTram(T, ts, lights);
    for (let r = L.townRows.length - 1; r >= 0; r--) {
      const row = L.townRows[r];
      for (const id of row.items) { const b = L.blds[id]; Art.B[id].paint(wg, b.x, b.ground, buildingState(id, T, ts), lights); }
      if (r > 0) drawTerrace(L.townRows[r - 1], row);
    }
    drawChimneySmoke(ts);
    if (!L.tramBehind) drawTram(T, ts, lights);
    drawStreet(lights);
    drawVisitors(T, ts);
    drawExplorer(T, ts);
    if (on('schedules')) drawRoad(T, ts);
    // night falls on the world, then the lights come on over it
    const { day, warm } = daylight(T);
    const night = 1 - day;
    if (night > 0.02 || warm > 0.05) {
      wg.globalCompositeOperation = 'source-atop';
      wg.fillStyle = warm > 0.05 && night < 0.6 ? `rgba(240,120,70,${warm * 0.18})` : `rgba(14,22,58,${night * 0.62})`;
      wg.fillRect(0, 0, W, H);
      wg.globalCompositeOperation = 'source-over';
    }
    g.drawImage(world, 0, 0);
    for (const l of lights) {
      const lit = l.when === 'always' || (l.when === 'dusk' && night > 0.35) || (l.when === 'night' && night > 0.7);
      if (!lit) continue;
      if (l.when !== 'always' || !l.quiet || night > 0.3) {
        if (l.glow && night > 0.2) { g.fillStyle = 'rgba(255,214,120,' + (0.18 * night) + ')'; g.fillRect(l.x - l.glow, l.y - l.glow, l.w + l.glow * 2, l.h + l.glow * 2); }
        if (l.when !== 'always' || night > 0.3) fill(g, l.x, l.y, l.w, l.h, P.winL);
        if (l.when === 'always' && !l.quiet) fill(g, l.x, l.y, l.w, l.h, P.lamp);
      }
    }
    drawEffects();
    drawOverlay(T, ts);
    drawCard(ts);
    if (S.frozen) drawFrost();
    declareHits(T);
  }

  function drawChimneySmoke(ts) {
    const h = L.blds.house; if (!h || reduce) return;
    const w = weatherNow(), wind = w && w.wind != null ? w.wind : 6;
    for (let i = 0; i < 5; i++) { const k = ((ts * 0.5 + i / 5) % 1); fill(wg, h.x + 52 + k * wind * 1.2, h.ground - 60 - k * 22, 2 + (k > 0.5 ? 1 : 0), 2, 'rgba(240,240,236,' + (0.7 - k * 0.6) + ')'); }
  }

  let blindText = null;
  function drawTram(T, ts, lights) {
    blindText = null;
    if (!on('vpn')) return;
    const ty = L.track.y;
    fill(wg, L.track.x0, ty, L.track.x1 - L.track.x0, 2, P.stoneD);
    fill(wg, L.track.x0, ty - 1, L.track.x1 - L.track.x0, 1, P.iron);
    fill(wg, L.track.x0, ty - 34, L.track.x1 - L.track.x0, 1, P.iron);
    for (let x = L.track.x0 + 4; x < L.track.x1; x += 30) fill(wg, x, ty - 34, 1, 34, P.iron);
    const v = vpnAt(T);
    const connected = !!(v && v.connected) && !pending.vpn;
    Art.tunnel(wg, L.tunnelX, ty, connected, lights);
    // the stop and its sign: speed down the line
    const sx = L.stopX;
    fill(wg, sx, ty - 30, 1, 30, P.iron); Art.sign(wg, sx - 2, ty - 38, 24, 10, connected ? P.greenD : P.woodD);
    const tx = sx + 2 + Math.round(tramPos);
    Art.tram(wg, tx, ty, { lit: connected });
    // the destination blind says which server; it rolls while the feed is asked
    const roll = v && v.servers.length ? v.servers : ['...', '..', '.'];
    const blind = pending.vpn ? roll[Math.floor(ts * 8) % roll.length] : connected ? (v.server || 'on') : '--';
    blindText = { x: tx + 4, y: ty - 16, s: fit(blind, 34), sign: connected ? (v.mbps != null ? v.mbps + 'Mb' : 'on') : pending.vpn ? '...' : 'off', sx };
    if (!connected && !pending.vpn) { fill(wg, L.tunnelX + 7, ty - 24, 20, 2, P.red); fill(wg, L.tunnelX + 7, ty - 22, 20, 1, P.white); }
  }

  function drawStreet(lights) {
    const s = L.street;
    // pavement with a calcada edge
    fill(wg, 0, s.y0, W, s.y1 - s.y0, P.cobM);
    for (let x = 0; x < W; x += 4) for (let y = s.y0 + 2; y < s.y1; y += 3) if (hash(x * 3 + y * 7) > 0.55) fill(wg, x + ((y / 3) % 2 ? 2 : 0), y, 2, 1, P.cobW);
    fill(wg, 0, s.y0, W, 1, P.cobD);
    fill(wg, 0, s.y1 - 2, W, 2, P.stoneD);
    for (const lx of [L.tall ? W - 8 : (L.blds.crew ? L.blds.crew.x - 4 : W / 2), L.tall ? 8 : L.stopX - 8]) {
      fill(wg, lx, s.y0 - 26, 1, 30, P.iron); fill(wg, lx - 1, s.y0 - 28, 3, 1, P.iron);
      fill(wg, lx - 1, s.y0 - 27, 3, 3, P.lamp);
      lights.push({ x: lx - 1, y: s.y0 - 27, w: 3, h: 3, when: 'dusk', glow: 6 });
    }
  }

  function drawVisitors(T, ts) {
    if (!on('attention')) { visitors.clear(); return; }
    const n = now();
    const present = attention().filter((a) => a.since <= T || T >= n - 0.5);
    const gap = L.tall ? 22 : 24;
    const room = Math.max(1, Math.floor(((L.tall ? W : L.stopX - 20) - L.doorX - 16) / gap));
    present.slice(0, room).forEach((a, i) => {
      let v = visitors.get(a.id);
      const tx = L.doorX + 16 + i * gap;
      if (!v) { v = { x: tx }; visitors.set(a.id, v); }
      v.tx = tx; v.present = true; v.a = a; v.leaving = false;
    });
    for (const [id, v] of visitors) {
      if (!v.present && !v.leaving) { visitors.delete(id); continue; }
      v.present = false;
      const look = lookOf(v.a.kind);
      let pose = 'stand', flip = true;
      if (v.leaving) {
        if (v.wave > 0) { v.wave -= 1 / 30; pose = 'wave'; flip = false; }
        else { v.x += 1.6; pose = Math.floor(ts * 6) % 2 ? 'walk1' : 'walk2'; flip = false; if (v.x > W + 10) { visitors.delete(id); continue; } }
      } else {
        const d = v.tx - v.x;
        if (Math.abs(d) > 0.5) { v.x += Math.sign(d) * Math.min(Math.abs(d), 1.6); pose = Math.floor(ts * 6) % 2 ? 'walk1' : 'walk2'; flip = d < 0; }
        else if (n - v.a.since > 240 && !reduce) pose = 'sit';
      }
      const y = L.queueY + (v.leaving ? 4 : 0);
      Art.villager(wg, v.x, y, look, pose, flip);
      // what each one carries, in a bubble
      if (!v.leaving || v.wave > 0) {
        const bx = Math.round(v.x - 5), by = y - 26 + (pose === 'sit' ? 2 : 0) + (reduce ? 0 : Math.round(Math.sin(ts * 2 + v.x) * 0.6));
        fill(wg, bx, by, 11, 10, P.white); fill(wg, bx + 1, by - 1, 9, 1, P.white); fill(wg, bx + 1, by + 10, 9, 1, P.white); fill(wg, bx + 4, by + 11, 2, 2, P.white);
        if (v.leaving) F.text(wg, '✓', bx + 3, by + 2, P.greenD);
        else Art.icon(wg, look.bubble, bx + 2, by + 2, look.bc);
      }
    }
  }

  let explorerAt = null;
  function drawExplorer(T, ts) {
    explorerAt = null;
    if (!on('activity') || !L.blds.crew) return;
    const job = jobs().find((j) => j.since == null || j.since <= T);
    if (!job) return;
    if (!explorer.inited) { explorer.x = L.blds.crew.x + 56; explorer.inited = true; }
    const x = Math.round(explorer.x), y = L.queueY + 1;
    Art.villager(wg, x, y, EXPLORER, reduce ? 'stand' : Math.floor(ts * 5) % 2 ? 'walk1' : 'walk2', explorer.dir < 0);
    // backpack and the map held up
    fill(wg, x + (explorer.dir < 0 ? 3 : -5), y - 8, 3, 5, P.woodD);
    fill(wg, x + (explorer.dir < 0 ? -6 : 3), y - 9, 3, 3, P.paper);
    explorerAt = { x, y, job };
  }

  // ---- the day road ---------------------------------------------------------------------------
  let calcada = null;
  function calcadaTile(h) {
    if (calcada && calcada.height === h) return calcada;
    calcada = document.createElement('canvas'); calcada.width = 32; calcada.height = h;
    const c = calcada.getContext('2d');
    c.fillStyle = P.cobW; c.fillRect(0, 0, 32, h);
    for (let x = 0; x < 32; x++) {
      c.fillStyle = P.cobK; c.fillRect(x, Math.round(h / 2 + Math.sin((x / 32) * Math.PI * 2) * (h / 2 - 3)) - 1, 1, 3);
      c.fillStyle = '#9b958a'; c.fillRect(x, Math.round(h / 2 + Math.sin((x / 32) * Math.PI * 2 + Math.PI) * (h / 2 - 3)), 1, 1);
    }
    for (let x = 0; x < 32; x += 2) for (let y = 0; y < h; y += 2) if (hash(x * 11 + y) > 0.7) { c.fillStyle = 'rgba(0,0,0,0.08)'; c.fillRect(x, y, 1, 1); }
    return calcada;
  }

  function drawHurdle(f, x, y, ts) {
    const k = f.sid ? hurdleOf(f.sid) : 'mark';
    const st = f.status;
    if (k === 'mark') { // a run of no schedule: a small stone with a coloured top
      fill(wg, x - 2, y - 4, 5, 4, P.stoneL); fill(wg, x - 2, y - 5, 5, 1, st === 'failed' ? P.red : P.green); return;
    }
    if (st === 'paused') { // lying down, grey: a firing that will not happen while paused
      fill(wg, x - 4, y - 4, 9, 4, P.whiteD); fill(wg, x - 4, y - 4, 9, 1, P.stoneD); fill(wg, x - 2, y - 3, 1, 3, P.stoneD); fill(wg, x + 2, y - 3, 1, 3, P.stoneD); return;
    }
    if (st === 'failed') { // knocked over, with its red tag
      fill(wg, x - 5, y - 3, 11, 3, k === 'paper' ? P.white : P.woodL); fill(wg, x - 5, y - 1, 11, 1, P.whiteD);
      fill(wg, x + 4, y - 9, 1, 6, P.iron); fill(wg, x + 5, y - 9, 4, 3, P.red); return;
    }
    if (k === 'mill') { fill(wg, x, y - 8, 1, 8, P.woodD); const a = (ts * 3 + x) % 2 < 1; fill(wg, x - 2, y - 10, 5, 1, a ? P.aqua : P.blue); fill(wg, x, y - 12, 1, 5, a ? P.blue : P.aqua); }
    if (k === 'paper') { fill(wg, x - 4, y - 6, 9, 6, P.white); fill(wg, x - 4, y - 4, 9, 1, P.whiteD); fill(wg, x, y - 6, 1, 6, P.roofD); }
    if (k === 'bell') { fill(wg, x, y - 13, 1, 13, P.woodD); fill(wg, x - 3, y - 13, 7, 1, P.woodD); fill(wg, x - 2, y - 11, 5, 4, P.ochre); fill(wg, x - 3, y - 7, 7, 1, P.ochreS); }
    if (k === 'barrel') { fill(wg, x - 3, y - 7, 7, 7, P.woodL); fill(wg, x - 3, y - 5, 7, 1, P.woodD); fill(wg, x - 3, y - 2, 7, 1, P.woodD); }
    if (st === 'ok') { fill(wg, x + 3, y - 14, 1, 6, P.iron); fill(wg, x + 4, y - 14, 3, 2, P.green); }
  }

  function drawRoad(T, ts) {
    const r = L.road, sy = r.stand, rh = L.tall ? 18 : 14;
    fill(wg, 0, r.y0, W, r.y1 - r.y0, P.grass);
    for (let x = 0; x < W; x += 3) if (hash(x * 5) > 0.6) fill(wg, x, r.y0 + 1 + Math.floor(hash(x) * 4), 1, 1, P.grassD);
    const tile = calcadaTile(rh);
    const off = Math.floor(((T * L.ppm) % 32 + 32) % 32);
    for (let x = -off; x < W; x += 32) wg.drawImage(tile, x, sy);
    fill(wg, 0, sy - 1, W, 1, P.cobD); fill(wg, 0, sy + rh, W, 2, P.stoneD);
    // the past is worn darker than the days still to come
    const xn = Math.round(xAt(now()));
    if (xn > 0) { wg.fillStyle = 'rgba(60,40,20,0.13)'; wg.fillRect(0, sy, Math.min(W, xn), rh); }
    // hours and days along the kerb
    const t0 = T - L.nowX / L.ppm, t1 = T + (W - L.nowX) / L.ppm;
    for (let h = Math.ceil(t0 / 60) * 60; h <= t1; h += 60) {
      const x = Math.round(xAt(h));
      const midnight = ((h % DAY) + DAY) % DAY === 0;
      fill(wg, x, sy + rh + 2, 1, midnight ? 6 : 3, P.ink);
      if (midnight) { fill(wg, x - 3, sy - 8, 7, 8, P.stoneL); fill(wg, x - 3, sy - 8, 7, 1, P.stone); }
    }
    for (const f of firings) if (f.at >= t0 - 10 && f.at <= t1 + 10) drawHurdle(f, Math.round(xAt(f.at)), sy, ts);
    // the timekeeper
    let pose = 'stand';
    const moving = Math.abs(view.vel) > 0.08 || (view.drag && Math.abs(view.vel) > 0.02) || view.target != null;
    if (capy.jump > 0) pose = 'jump'; else if (moving && !reduce) pose = Math.floor(ts * 12) % 2 ? 'run1' : 'run2';
    const backwards = view.vel < -0.02 || (view.target != null && view.target < view.off);
    const jy = capy.jump > 0 ? -Math.round(Math.sin((1 - capy.jump / 0.55) * Math.PI) * 10) : 0;
    Art.capybara(wg, L.nowX, sy + 1 + jy, { pose, flip: backwards, blink: capy.blink, flop: capy.trip > 0 });
    if (capy.trip > 0) for (let i = 0; i < 3; i++) { const a = ts * 6 + i * 2.1; fill(wg, L.nowX + Math.round(Math.cos(a) * 7), sy - 18 + Math.round(Math.sin(a) * 2), 1, 1, P.star); }
    // the real now, when the view has wandered away from it
    if (!view.follow && xn > -20 && xn < W + 20) { fill(wg, xn, sy - 22, 1, 22, P.iron); fill(wg, xn - 2, sy - 25, 5, 3, P.lamp); }
  }

  function drawEffects() {
    for (let i = fx.length - 1; i >= 0; i--) {
      const e = fx[i];
      e.t += 1 / 30;
      if (e.kind === 'note') { const k = e.t / 1.6; if (k > 1) { fx.splice(i, 1); continue; } F.text(g, '♪', e.x + k * 14, e.y - k * 14, e.small ? 'rgba(255,255,255,' + (0.7 - k * 0.7) + ')' : P.aquaD); }
      if (e.kind === 'ding') { const k = e.t / 0.9; if (k > 1) { fx.splice(i, 1); continue; } F.text(g, 'ding', e.x, e.y - k * 6, P.ink, { outline: P.tramL }); }
      if (e.kind === 'ring') { const k = e.t / 0.8; if (k > 1) { fx.splice(i, 1); continue; } const r = Math.round(4 + k * 14); g.fillStyle = e.c; for (let a = 0; a < 16; a++) g.fillRect(e.x + Math.round(Math.cos(a / 16 * 6.283) * r), e.y + Math.round(Math.sin(a / 16 * 6.283) * r), 1, 1); }
      if (e.kind === 'drop') { const k = e.t / 0.9; if (k > 1) { fx.splice(i, 1); continue; } const x = lerp(e.x, e.tx, k), y = lerp(e.y, e.ty, k) - Math.sin(k * Math.PI) * 30; fill(g, x, y, 2, 3, P.aqua); fill(g, x, y - 1, 1, 1, P.aquaL); }
    }
  }

  // ---- words over the scene ------------------------------------------------------------------
  function panel(x, y, w, h, fillc = P.paper, edge = P.ink) {
    fill(g, x + 1, y, w - 2, h, edge); fill(g, x, y + 1, w, h - 2, edge);
    fill(g, x + 1, y + 1, w - 2, h - 2, fillc);
    fill(g, x + 1, y + h - 2, w - 2, 1, mix(fillc, '#000000', 0.15));
  }
  function label(str, x, y, o = {}) {
    const w = F.measure(str, o.s || 1);
    const ax = o.align === 'center' ? x - w / 2 : o.align === 'right' ? x - w : x;
    panel(Math.round(ax) - 3, y - 3, w + 6, 9 * (o.s || 1) + 3, o.bg || P.paper, o.edge || P.ink);
    F.text(g, str, ax, y, o.c || P.ink, { s: o.s || 1 });
    return { x: Math.round(ax) - 3, y: y - 3, w: w + 6, h: 9 * (o.s || 1) + 3 };
  }
  const fit = (s, w) => { s = String(s); if (F.measure(s) <= w) return s; while (s.length > 1 && F.measure(s + '...') > w) s = s.slice(0, -1); return s + '...'; };
  const temp = (c) => (c == null ? '--' : R.units() === 'f' ? Math.round(c * 9 / 5 + 32) : Math.round(c)) + '°';
  const unitMark = () => (R.units() === 'f' ? 'F' : 'C');

  let ui = {};
  function drawOverlay(T, ts) {
    ui = {};
    const n = now(), away = Math.abs(T - n) >= 1;
    const tt = L.title;
    // title: whose place, the day, the time being looked at
    const sky = daylight(T).day > 0.5;
    const ink = sky ? '#10233d' : '#f4f1e8', sh = sky ? 'rgba(255,255,255,0.35)' : 'rgba(0,0,0,0.5)';
    F.text(g, fit(S.person || 'your place', (L.planX - 50 - tt.x) / tt.s), tt.x, tt.y, ink, { s: tt.s, shadow: sh });
    const ty = tt.y + tt.s * 9 + 3;
    F.text(g, dateLabel(T) + '  ' + hm(T), tt.x, ty, ink, { shadow: sh, bold: true });
    if (away) ui.rel = label((T > n ? 'looking ahead, ' : 'looking back, ') + rel(T), tt.x + 3, ty + 14, { bg: P.aquaL, c: P.ink });
    // the weather board on the mill's hill
    if (on('weather')) {
      const b = L.board, w = weatherNow(), post = b.post || 6;
      fill(g, b.x + 8, b.y + b.h, 2, post, P.woodD); fill(g, b.x + b.w - 10, b.y + b.h, 2, post, P.woodD);
      panel(b.x, b.y, b.w, b.h, '#2c3a33', P.woodD);
      if (w) {
        const liveNow = Math.abs(T - n) < 10;
        const t = liveNow || (T >= n && T < Math.ceil(n / 60) * 60) ? w.temp : T > n ? w.next[Math.floor((T - Math.ceil(n / 60) * 60) / 60)] ?? null : null;
        F.text(g, temp(t), b.x + 5, b.y + 4, '#f4f1e8', { s: 2 });
        const lx = b.x + 5 + F.measure(temp(t), 2) + 4;
        F.text(g, fit(w.place, b.x + b.w - lx - 3), lx, b.y + 4, '#f4f1e8');
        F.text(g, fit(liveNow ? w.sky : T > n ? (t == null ? 'no forecast' : 'forecast') : 'no record', b.x + b.w - lx - 3), lx, b.y + 13, '#bfd6c8');
        F.text(g, fit(liveNow ? (w.wind != null ? 'wind ' + w.wind + ' km/h' : 'now') : T > n ? 'at ' + hm(Math.floor(T / 60) * 60) : 'before ' + hm(w.at ?? n), b.w - 8), b.x + 5, b.y + 25, '#9fc0ae');
        if (pending.weather) F.text(g, '...', b.x + b.w - 14, b.y + 4, P.lamp);
      } else {
        F.text(g, '--°', b.x + 5, b.y + 4, '#f4f1e8', { s: 2 });
        F.text(g, 'no weather', b.x + 34, b.y + 6, '#bfd6c8');
        F.text(g, 'feed bound', b.x + 34, b.y + 15, '#9fc0ae');
      }
      const top = Math.min(b.y, L.mill.y - 56);
      ui.weather = { x: Math.min(b.x, L.mill.x - 22), y: top, w: Math.max(b.x + b.w, L.mill.x + 24) - Math.min(b.x, L.mill.x - 22), h: Math.max(b.y + b.h, L.mill.y) - top };
    }
    // the tram's blind and stop sign
    if (on('vpn') && blindText) {
      const bt = blindText;
      fill(g, bt.x - 4, bt.y - 1, F.measure(bt.s) + 4, 9, P.ink);
      F.text(g, bt.s, bt.x - 2, bt.y, '#f4f1e8');
      F.text(g, fit(bt.sign, 22), bt.sx + 1, L.track.y - 37, '#f4f1e8');
    }
    // the queue's count over the house: the figure the screen leads with
    if (on('attention') && L.blds.house) {
      const hb = L.blds.house, c = attention().filter((a) => a.since <= T || T >= n - 0.5).length;
      if (c) ui.count = label(c + ' waiting', hb.x + 31, hb.ground - 42, { align: 'center', bg: P.red, edge: P.redD, c: '#fff8ec' });
    }
    // the crew's walker says who is out, now and then
    if (explorerAt && ((ts % 12) < 5 || reduce)) {
      const words = explorerAt.job.member + ' at work';
      const lw = F.measure(words);
      const r = label(words, Math.max(6 + lw / 2, Math.min(W - 6 - lw / 2, explorerAt.x)), explorerAt.y - 30, { align: 'center', bg: '#fff3dc' });
      fill(g, explorerAt.x - 1, r.y + r.h, 3, 2, P.ink); fill(g, explorerAt.x, r.y + r.h - 1, 1, 2, '#fff3dc');
    }
    // the road: what the timekeeper stands on, what comes next, what lies off the edges
    if (on('schedules')) {
      const sy = L.road.stand, rh = L.tall ? 18 : 14;
      const t0 = T - L.nowX / L.ppm, t1 = T + (W - L.nowX) / L.ppm;
      for (let h = Math.ceil(t0 / 60) * 60; h <= t1; h += 60) {
        const midnight = ((h % DAY) + DAY) % DAY === 0;
        if (L.ppm * 60 < 60 && !midnight && (h / 60) % 2) continue;
        const s = midnight ? DAYS[dayIx(h)] + ' ' + wall(h).getUTCDate() : hm(h);
        F.text(g, s, Math.round(xAt(h)), sy + rh + 5, roadInk(T, midnight), { align: 'center', bold: midnight });
      }
      const capY = L.road.y0 + 3;
      const near = nearestFiring(T, 14 / L.ppm);
      const next = firings.find((f) => f.at > T + 0.5 && f.sid && f.status === 'due' && sched(f.sid));
      const onIt = near && Math.abs(near.at - T) < 6;
      const capLine = onIt ? firingWords(near) : next ? 'next ' + when(next.at) + ' ' + sched(next.sid).name : null;
      const signY = L.tall ? L.road.y1 - 12 : capY;
      const capText = capLine ? fit(capLine, W - 24) : null;
      const capRect = capText ? { x: Math.min(W - 6 - F.measure(capText) - 6, Math.max(6, L.nowX - 16)), w: F.measure(capText) + 6 } : null;
      // the next firing off the right edge, of a schedule that fires less than hourly
      const often = new Map();
      for (const f of firings) if (f.sid && f.status === 'due') often.set(f.sid, (often.get(f.sid) || 0) + 1);
      const beyond = firings.find((f) => f.at > t1 && f.sid && f.status === 'due' && sched(f.sid) && often.get(f.sid) <= (AHEAD / 60));
      const aheadTxt = beyond ? when(beyond.at) + (L.tall ? '' : ' ' + fit(sched(beyond.sid).name, 120)) + ' →' : null;
      const behind = firings.filter((f) => f.at < t0 && f.status === 'failed').pop();
      const behindTxt = behind ? '← ' + when(behind.at) + ' ' + (L.tall ? 'failed' : fit(behind.sid && sched(behind.sid) ? sched(behind.sid).name : behind.ref || 'a run', 100) + ' failed') : null;
      const clash = (ax, aw, bx, bw) => ax < bx + bw + 4 && bx < ax + aw + 4;
      const aheadX = aheadTxt ? W - 6 - F.measure(aheadTxt) - 6 : 0;
      const showAhead = aheadTxt && !(signY === capY && capRect && clash(aheadX, F.measure(aheadTxt) + 6, capRect.x, capRect.w));
      const showBehind = behindTxt && !(signY === capY && capRect && clash(3, F.measure(behindTxt) + 6, capRect.x, capRect.w)) && !(L.tall && showAhead && clash(3, F.measure(behindTxt) + 6, aheadX, F.measure(aheadTxt) + 6));
      if (capText) { ui.caption = label(capText, capRect.x + 3, capY, { bg: onIt && near.status === 'failed' ? '#ffd9d2' : P.paper }); ui.capFiring = onIt ? near : next; fill(g, L.nowX - 1, capY + 9, 3, 2, P.ink); }
      ui.ahead = showAhead ? { f: beyond, r: label(aheadTxt, W - 6, signY, { align: 'right', bg: P.paper2 }) } : null;
      ui.behind = showBehind ? { f: behind, r: label(behindTxt, 6, signY, { bg: '#ffd9d2' }) } : null;
      // the day's tally of firings, up to the time being looked at
      if (!L.tall) {
        const d0 = Math.floor(T / DAY) * DAY, upto = Math.min(T, n);
        const rs = R.values(S.scheduleRuns).filter((r) => r.at != null && r.at >= d0 && r.at <= upto);
        const bad = rs.filter((r) => r.kind === 'failed').length;
        const words = (dayWord(T) === 'today' ? 'Today' : DAYS[dayIx(T)]) + ': ' + (rs.length ? rs.length + (rs.length === 1 ? ' firing, ' : ' firings, ') + (rs.length - bad) + ' ran' + (bad ? ', ' + bad + ' failed' : '') : (T > n ? 'nothing has fired yet' : 'nothing fired'));
        const x = F.text(g, words, 8, L.road.y1 - 11, roadInk(T, false));
        if (bad) fill(g, 8 + x + 4, L.road.y1 - 9, 4, 4, P.red);
      }
      if (!view.follow) ui.now = label('Back to now', L.tall ? W / 2 : W - 6, L.road.y1 - 12, { align: L.tall ? 'center' : 'right', bg: P.aquaL });
    }
    // the planning sign
    ui.plan = label('Plan', L.planX, L.title.y + 1, { align: 'right', bg: P.paper2 });
    // a stream refused at its open says so, once, under the title
    const refused = Object.keys(S.refusals);
    if (refused.length && !card) label(fit('Not reading ' + refused.join(', ') + ': ' + S.refusals[refused[0]], W - 20), tt.x + 3, ty + (away ? 28 : 14), { bg: '#ffd9d2' });
    // what the last tap asked CYFR to do
    if (ticker && ticker.t > 0) { ticker.t -= 1 / 30; F.wrap(ticker.text, W - 24).slice(0, 3).forEach((ln, i) => label(ln, W / 2, (L.tall ? 44 : 34) + i * 13, { align: 'center', bg: '#fff8ec' })); }
  }
  const roadInk = (T, strong) => (daylight(T).day > 0.5 ? (strong ? P.ink : '#2d3b22') : (strong ? '#fff8ec' : '#d9d5c6'));
  function firingWords(f) {
    const s = f.sid ? sched(f.sid) : null, name = s ? s.name : f.ref || 'a run';
    if (f.status === 'failed') return when(f.at) + ' ' + name + ': failed' + (f.cause ? ', ' + f.cause.replace(/_/g, ' ') : '');
    if (f.status === 'ok') return when(f.at) + ' ' + name + ': ran';
    if (f.status === 'paused') return when(f.at) + ' ' + name + ': paused, will not run';
    return when(f.at) + ' ' + name;
  }

  // ---- the dialogue box ----------------------------------------------------------------------
  let cardBox = null;
  function drawCard(ts) {
    cardBox = null;
    if (!card) return;
    const m = cardModel(card);
    if (!m) { card = null; return; }
    const c = cardPlace(), pad = 8, port = 34;
    const tx = c.x + pad + port + 8, tw = c.w - (tx - c.x) - pad;
    const lines = [];
    for (const ln of m.lines) lines.push(...F.wrap(ln, tw));
    const all = m.rows || [];
    const cols = all.length > 6 && tw > 420 ? 3 : all.length > 3 && tw > 300 ? 2 : 1;
    const rowH = 22;
    // rows past what fits above the choices are left for the page their choice opens
    const maxRows = Math.max(1, Math.floor((H * 0.62 - 60 - lines.length * 11) / (rowH + 2))) * cols;
    const rows = all.slice(0, maxRows);
    const rowsH = Math.ceil(rows.length / cols) * (rowH + 2);
    const ch = m.noClose ? m.choices : [...m.choices, { label: 'Close', close: true }];
    const cw = ch.map((x) => F.measure(x.label) + 18);
    let cx = tx, cy = 0, chRows = 1; const chPos = [];
    for (let i = 0; i < ch.length; i++) { if (cx + cw[i] > c.x + c.w - pad && cx > tx) { cx = tx; cy += 26; chRows++; } chPos.push({ x: cx, y: cy, w: cw[i] }); cx += cw[i] + 6; }
    const h = pad + 14 + lines.length * 11 + (lines.length ? 4 : 0) + rowsH + chRows * 26 + pad - 2;
    let y = c.bottom - h;
    // keep clear of windows standing over the page: the top when the bottom is covered
    if (covered.length && overlapsCovered(c.x, y, c.w, h) && !overlapsCovered(c.x, 4, c.w, h)) y = 4;
    panel(c.x, y, c.w, h, P.paper, P.ink);
    fill(g, c.x + 2, y + 2, c.w - 4, 1, '#fffaf0');
    fill(g, c.x + pad, y + pad, port, port, P.paper2); fill(g, c.x + pad, y + pad + port - 1, port, 1, P.paperD);
    portrait(m.portrait, c.x + pad, y + pad, ts);
    F.text(g, fit(m.title, tw), tx, y + pad + 1, P.ink, { bold: true });
    let ly = y + pad + 15;
    for (const ln of lines) { F.text(g, ln, tx, ly, '#3a3128'); ly += 11; }
    if (lines.length) ly += 4;
    const box = { x: c.x, y, w: c.w, h, rows: [], choices: [] };
    const colW = Math.floor((tw - (cols - 1) * 8) / cols);
    rows.forEach((r, i) => {
      const rx = tx + (i % cols) * (colW + 8), ry = ly + Math.floor(i / cols) * (rowH + 2);
      fill(g, rx, ry, colW, rowH, r.sel ? P.aquaL : P.paper2);
      let ix = rx + 5;
      if (r.dot) { fill(g, ix, ry + 8, 5, 5, r.dot); ix += 9; }
      const room = colW - (ix - rx) - (r.toggle != null ? 40 : 6);
      F.text(g, fit(r.text, room), ix, ry + 3, P.ink, { bold: true });
      F.text(g, fit(r.sub, room), ix, ry + 12, '#5a4c3c');
      if (r.toggle != null) { const sx = rx + colW - 34; fill(g, sx, ry + 5, 28, 12, r.toggle ? P.green : P.whiteD); fill(g, r.toggle ? sx + 16 : sx + 2, ry + 7, 10, 8, P.white); F.text(g, r.toggle ? 'on' : 'off', r.toggle ? sx + 3 : sx + 13, ry + 7, r.toggle ? '#fff' : P.ink); box.rows.push({ i, x: rx, y: ry, w: colW - 38, h: rowH, r, tg: { x: sx - 3, y: ry, w: 34, h: rowH } }); }
      else box.rows.push({ i, x: rx, y: ry, w: colW, h: rowH, r });
    });
    ly += rowsH;
    ch.forEach((x, i) => {
      const p = chPos[i], bx = p.x, by = ly + p.y + 2;
      panel(bx, by, p.w, 22, x.disabled ? P.whiteS : x.primary ? P.ink : x.aqua ? P.aqua : P.paper2, x.disabled ? P.whiteD : P.ink);
      F.text(g, x.label, bx + 9, by + 7, x.disabled ? '#8a8172' : x.primary ? '#fff8ec' : P.ink);
      box.choices.push({ x: bx, y: by, w: p.w, h: 22, c: x });
    });
    cardBox = box;
  }
  // Where the box stands: full width at the foot, or beside a window that stands over the page.
  function cardPlace() {
    const c = L.card;
    if (!covered.length || !overlapsCovered(c.x, c.bottom - 120, c.w, 120)) return c;
    const free = [];
    for (const r of covered) { free.push({ x: 6, w: Math.floor(r.x) - 12 }); free.push({ x: Math.ceil(r.x + r.w) + 6, w: W - Math.ceil(r.x + r.w) - 12 }); }
    const ok = free.filter((f) => f.w >= 220 && !covered.some((r) => f.x < r.x + r.w && f.x + f.w > r.x)).sort((a, b) => b.w - a.w)[0];
    return ok ? { x: ok.x, w: ok.w, bottom: c.bottom } : c;
  }

  function portrait(kind, x, y, ts) {
    const cx = x + 17, gy = y + 31;
    if (kind === 'mill') { Art.mill(g, cx, gy, millAngle, null); return; }
    if (kind === 'tram') { Art.tram(g, x + 1, gy - 2, { lit: true }); return; }
    const look = { news: LOOKS.failed_run, bell: LOOKS.failed_schedule, aqua: LOOKS.approval, porter: LOOKS.confirmation, sam: LOOKS.file_offer, crew: EXPLORER }[kind];
    if (look) { g.save(); g.translate(cx, gy - 4); g.scale(2, 2); Art.villager(g, 0, 0, look, 'stand'); g.restore(); return; }
    if (kind === 'plan') { Art.capybara(g, cx, gy - 4, { pose: 'stand' }); return; }
    const sc = { house: 0.5, post: 0.7, market: 0.48, tower: 0.36, vault: 0.75, barn: 0.7 }[kind] || 0.5;
    if (Art.B[kind]) { g.save(); g.translate(cx - (Art.B[kind].w * sc) / 2, gy); g.scale(sc, sc); Art.B[kind].paint(g, 0, 0, buildingState(kind, viewT(), ts), []); g.restore(); }
  }

  function drawFrost() {
    g.fillStyle = 'rgba(220,240,255,0.18)'; g.fillRect(0, 0, W, H);
    g.fillStyle = 'rgba(255,255,255,0.85)';
    for (let i = 0; i < 160; i++) { const e = i % 4, k = hash(i * 9 + 1), d = Math.floor(hash(i * 5 + 3) * 14); const x = e === 0 ? d : e === 1 ? W - 1 - d : Math.floor(k * W), y = e === 2 ? d : e === 3 ? H - 1 - d : Math.floor(k * H); g.fillRect(x, y, 1, 1); }
    label('paused while hidden', W / 2, 6, { align: 'center', bg: '#e8f4ff' });
  }

  // ---- what the windows over the page cover ---------------------------------------------------
  let covered = [];
  function overlapsCovered(x, y, w, h) { return covered.some((r) => x < r.x + r.w && x + w > r.x && y < r.y + r.h && y + h > r.y); }
  function setCovered(list) { covered = list.map((r) => ({ x: r.x / SC, y: r.y / SC, w: r.width / SC, h: r.height / SC })); }

  // ---- taps ----------------------------------------------------------------------------------
  function declareHits(T) {
    const b = L.blds;
    const add = (key, id, lbl) => { const bb = b[id]; if (bb) hit(key, bb.x, bb.ground - bb.h, bb.w, bb.h, lbl, () => openCard(key), { exact: true, tab: covered.length && overlapsCovered(bb.x, bb.ground - bb.h, bb.w, bb.h) ? -1 : 0 }); };
    const list = attention();
    if (on('attention')) add('queue', 'house', list.length + ' waiting at your house. Open the list.');
    else add('queue', 'house', 'Your house');
    if (on('threads')) add('threads', 'post', 'Post boxes: ' + S.threads.size + ' threads, ' + threads().filter((t) => t.waits).length + ' waiting on you');
    if (on('activity')) add('crew', 'crew', 'Crew house: ' + S.activity.size + ' at work');
    if (on('components')) add('market', 'market', 'Market: ' + S.installed.length + ' apps');
    if (on('schedules')) { add('tower', 'tower', 'Bell tower: ' + S.schedules.size + ' schedules'); add('press', 'press', 'Press: runs that failed'); add('barn', 'barn', 'Barn: paused schedules'); }
    if (on('vault')) add('vault', 'vault', 'Strongroom: vault, ' + vault().filter((v) => !v.fine).length + ' need care');
    if (on('weather') && ui.weather) { const w = weatherNow(); hit('weather', ui.weather.x, ui.weather.y, ui.weather.w, ui.weather.h, w ? 'Weather in ' + w.place + ', ' + temp(w.temp) : 'Windmill: no weather feed', () => openCard('weather'), { exact: true }); }
    if (on('vpn')) { const v = vpnNow(); hit('vpn', L.stopX - 4, L.track.y - 40, L.tunnelX + 34 - L.stopX + 4, 40, 'Tram line: VPN ' + (v ? (v.connected ? 'connected' + (v.server ? ' to ' + v.server : '') : 'not connected') : 'feed not bound'), () => openCard('vpn'), { exact: true }); }
    if (on('attention')) for (const [id, v] of visitors) if (!v.leaving) hit('att:' + id, v.x - 9, L.queueY - 28, 18, 30, attLabel(v.a) + ', since ' + when(v.a.since), () => openCard('att:' + id), { z: 2 });
    if (explorerAt) hit('explorer', explorerAt.x - 8, explorerAt.y - 16, 16, 18, explorerAt.job.member + ' at work', () => openCard('crew'), { z: 2 });
    if (ui.count) hit('count', ui.count.x, ui.count.y, ui.count.w, ui.count.h, list.length + ' waiting', () => openCard('queue'), { z: 2, tab: -1 });
    if (ui.plan) hit('plan', ui.plan.x, ui.plan.y, ui.plan.w, ui.plan.h, 'Plan the village: turn parts on or off and move them', () => openCard('plan'), { z: 2 });
    if (on('schedules')) {
      road.style.cssText = `left:0;top:${(L.road.y0 - 26) * SC}px;width:${W * SC}px;height:${(L.road.y1 - L.road.y0 + 26) * SC}px`;
      road.setAttribute('aria-valuetext', dateLabel(T) + ' ' + hm(T) + (Math.abs(T - now()) >= 1 ? ', ' + rel(T) : ', now'));
      road.setAttribute('aria-valuenow', String(Math.round(T - now())));
      if (ui.caption) hit('cap', ui.caption.x, ui.caption.y, ui.caption.w, ui.caption.h, 'Show this firing', () => { const f = ui.capFiring; if (f && f.sid && sched(f.sid)) openCard('sched:' + f.sid); }, { z: 3, tab: -1 });
      if (ui.ahead) { const a = ui.ahead; hit('ahead', a.r.x, a.r.y, a.r.w, a.r.h, 'Go to ' + dateLabel(a.f.at) + ' ' + hm(a.f.at) + ', ' + sched(a.f.sid).name, () => jumpTo(a.f.at), { z: 3 }); }
      if (ui.behind) hit('behind', ui.behind.r.x, ui.behind.r.y, ui.behind.r.w, ui.behind.r.h, 'Go back to ' + when(ui.behind.f.at) + ', the failed run', () => jumpTo(ui.behind.f.at), { z: 3 });
      if (ui.now) hit('now', ui.now.x, ui.now.y, ui.now.w, ui.now.h, 'Back to now', () => { view.target = 0; }, { z: 3 });
      hit('capy', L.nowX - 10, L.road.stand - 16, 20, 16, 'The timekeeper. Poke it.', poke, { z: 3, tab: -1 });
    } else road.style.cssText = 'display:none';
    if (cardBox) {
      const cb = cardBox;
      hit('cardbg', cb.x, cb.y, cb.w, cb.h, '', () => {}, { exact: true, z: 5, tab: -1 });
      cb.rows.forEach((r) => { hit('row' + r.i, r.x, r.y, r.w, r.h, r.r.text + ', ' + r.r.sub, r.r.run, { exact: true, z: 6, pressed: r.r.toggle != null ? !!r.r.sel : null }); if (r.tg) hit('tg' + r.i, r.tg.x, r.tg.y, r.tg.w, r.tg.h, (r.r.toggle ? 'Turn off ' : 'Turn on ') + r.r.text, r.r.flip, { exact: true, z: 6, pressed: r.r.toggle }); });
      cb.choices.forEach((c, i) => hit('ch' + i + c.c.label, c.x, c.y, c.w, c.h, c.c.label, c.c.close ? closeCard : c.c.run, { exact: true, z: 6, disabled: c.c.disabled }));
    }
    hitsDone();
  }

  // ---- keys, visibility, start ----------------------------------------------------------------
  addEventListener('keydown', (e) => { if (e.key === 'Escape' && card) { closeCard(); wake(); e.preventDefault(); } });
  stage.addEventListener('pointerdown', () => { if (card) { closeCard(); wake(); } });
  document.addEventListener('visibilitychange', wake);
  addEventListener('resize', () => { relayout(); wake(); });

  relayout();
  document.documentElement.classList.add('scene');
  wake();
};

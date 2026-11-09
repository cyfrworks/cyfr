/* The street: the person's day as one tram line.
   Every stream carries a time; the time decides where a thing stands on the street.
   The tram's nose is now. The hill holds what has no time: the apps, the vault and CYFR.
   Everything here is read from the streams the manifest declares, through window.cyfr. */
(() => {
'use strict';

const sdk = window.cyfr || null;
const root = document.documentElement;
root.classList.add('js');
const $ = (s) => document.querySelector(s);
const motionQuery = matchMedia('(prefers-reduced-motion: reduce)');
let reduceMotion = motionQuery.matches;

/* ================= time: minutes from today's midnight, in the person's zone ================= */
const DAY = 1440;
const MINUTE = 60000;
let TZ;
let LOCALE;
let midnight = 0;
function zoneClock(ms) {
  try {
    const parts = new Intl.DateTimeFormat('en-GB', { timeZone: TZ, hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' }).formatToParts(new Date(ms));
    const get = (type) => Number((parts.find((p) => p.type === type) || {}).value || 0);
    return (get('hour') * 60 + get('minute')) * 60 + get('second');
  } catch (err) {
    const d = new Date(ms);
    return (d.getHours() * 60 + d.getMinutes()) * 60 + d.getSeconds();
  }
}
function setMidnight() {
  const ms = Date.now();
  midnight = ms - zoneClock(ms) * 1000 - (ms % 1000);
}
setMidnight();
const now = () => (Date.now() - midnight) / MINUTE;
function mins(iso) {
  if (typeof iso !== 'string') return null;
  const t = Date.parse(iso);
  return Number.isNaN(t) ? null : (t - midnight) / MINUTE;
}
const dayOf = (t) => Math.floor(t / DAY);
const two = (n) => String(n).padStart(2, '0');
function clock(t) { const m = ((Math.floor(t) % DAY) + DAY) % DAY; return two(Math.floor(m / 60)) + ':' + two(m % 60); }
function dateOf(d, options) {
  const at = new Date(midnight + (d * DAY + 720) * MINUTE);
  try { return at.toLocaleDateString(LOCALE, { ...options, timeZone: TZ }); } catch (err) { return at.toLocaleDateString(undefined, options); }
}
const dayName = (d) => dateOf(d, { weekday: 'short' });
function when(t) {
  if (t == null) return 'time not told';
  const d = dayOf(t);
  if (d === 0) return clock(t);
  if (Math.abs(d) <= 6) return dayName(d) + ' ' + clock(t);
  return dateOf(d, { day: 'numeric', month: 'short' });
}
const secs = (ms) => (typeof ms === 'number' && Number.isFinite(ms) ? (ms < 1000 ? Math.round(ms) + ' ms' : (ms / 1000).toFixed(1) + ' s') : '');

/* ================= what the streams hold ================= */
const D = {
  attention: new Map(),   // id -> {item, open}
  threads: new Map(),     // id -> {item, open}
  activity: new Map(),    // id -> {item, open}
  schedules: new Map(),   // schedule_id -> {item, open}
  runs: new Map(),        // execution_id -> {run, t, seq}
  occ: new Map(),         // occurrence_id -> {item, seq}
  apps: [],               // the installed apps, as the shell tells them
  refused: {},            // stream -> the sentence it was refused with
};
let seq = 0;
const MAX_RUNS = 40;
const MAX_OCC = 40;
let person = null;
let posture = null;
let coveredRects = [];
let shellState = 'live';
let prefsDoc = {};

const isItem = (v) => typeof v === 'object' && v !== null && !Array.isArray(v);
const text = (v) => (typeof v === 'string' ? v : typeof v === 'number' && Number.isFinite(v) ? String(v) : '');

// "formula:local.digest:0.4.0" without its version, and as a person reads it: "digest".
function componentRef(ref) { const p = ref.split(':'); return p.length === 3 ? p[0] + ':' + p[1] : ref; }
function componentName(ref) {
  const named = componentRef(ref).split(':')[1] || ref;
  return named.includes('.') ? named.slice(named.indexOf('.') + 1) : named;
}
const SHORT_REASONS = {
  needs_setup: 'needs setup', unavailable: 'unavailable', timed_out: 'timed out', cancelled: 'cancelled',
  rate_limited: 'rate limited', refused: 'refused', bad_input: 'bad input', not_found: 'not found', waits_for_you: 'waits for you',
  uncertain: 'outcome not known',
};
const shortReason = (cause) => SHORT_REASONS[cause] || 'failed';

/* Each stream's events folded into D. A live removal of a waiting item sends its villager to the tram. */
function foldAttention(item, open, live) {
  if (typeof item.id !== 'string') return;
  if (item.kind === 'removed') {
    if (D.attention.has(item.id) && live) board(item.id);
    D.attention.delete(item.id);
  } else {
    D.attention.set(item.id, { item, open });
  }
}
function foldKeyed(map, key, gone) {
  return (item, open) => {
    const id = item[key];
    if (typeof id !== 'string') return;
    if (gone(item)) map.delete(id); else map.set(id, { item, open });
  };
}
function foldRun(run, open, live) {
  const id = run.execution_id;
  if (typeof id !== 'string') return;
  const held = D.runs.get(id);
  // A start published while the stream opened can arrive after the refresh showed the run finished.
  if (held && held.run.kind !== 'started' && run.kind === 'started') return;
  let t = held ? held.t : null;
  if (t == null && live) t = now() - (run.kind !== 'started' && typeof run.duration_ms === 'number' ? run.duration_ms / MINUTE : 0);
  if (t == null) for (const o of D.occ.values()) if (o.item.execution_id === id) t = mins(o.item.scheduled_for);
  D.runs.set(id, { run, t, seq: ++seq });
  if (D.runs.size > MAX_RUNS) {
    const oldest = [...D.runs.entries()].sort((a, b) => a[1].seq - b[1].seq)[0];
    D.runs.delete(oldest[0]);
  }
}
function foldOcc(item) {
  const id = item.occurrence_id;
  if (typeof id !== 'string') return;
  D.occ.set(id, { item, seq: ++seq });
  const run = typeof item.execution_id === 'string' && D.runs.get(item.execution_id);
  if (run && run.t == null) run.t = mins(item.scheduled_for);
  if (D.occ.size > MAX_OCC) {
    const oldest = [...D.occ.entries()].sort((a, b) => a[1].seq - b[1].seq)[0];
    D.occ.delete(oldest[0]);
  }
}
const STREAMS = [
  { name: 'attention.changes', fold: foldAttention, sweep: D.attention },
  { name: 'threads.changes', fold: foldKeyed(D.threads, 'id', (i) => i.kind === 'removed'), sweep: D.threads },
  { name: 'activity.changes', fold: foldKeyed(D.activity, 'id', (i) => i.kind === 'ended'), sweep: D.activity },
  { name: 'schedules.changes', fold: foldKeyed(D.schedules, 'schedule_id', (i) => i.kind === 'removed'), sweep: D.schedules },
  { name: 'schedule_runs.changes', fold: foldOcc },
  { name: 'runs.changes', fold: foldRun },
];

// Pauses before opening an ended stream again, growing while opens fail.
const RETRY_MS = [2000, 5000, 15000, 60000];
// A reopened stream's refresh holds everything there is, so what an earlier open delivered and this one did not has gone.
const SWEEP_MS = 2500;

// Keeps one declared stream open: an ended stream is opened again after a pause and starts again with its
// refresh. Before it has ever opened, a refusal is final and an unanswered open is tried again.
function follow(spec) {
  let stopped = false;
  let opens = 0;
  let everOpened = false;
  let current = null;
  let timer = 0;
  async function open() {
    const n = ++opens;
    const stream = await sdk.stream(spec.name, null, ({ data }) => {
      if (stopped || !isItem(data)) return;
      try { spec.fold(data, n, data.refresh !== true); } catch (err) { /* a malformed event changes nothing */ }
      changed();
    });
    if (stopped) { stream.close(); return; }
    everOpened = true;
    current = stream;
    delete D.refused[spec.name];
    if (spec.sweep) {
      setTimeout(() => {
        if (stopped || n !== opens) return;
        for (const [id, held] of spec.sweep) if (held.open < n) spec.sweep.delete(id);
        changed();
      }, SWEEP_MS);
    }
    stream.closed.catch(() => {}).then(() => { current = null; retry(0); });
  }
  function failed(error, attempt) {
    if (stopped) return;
    const unanswered = isItem(error) && error.code === 'unavailable';
    if (!everOpened && !unanswered) {
      D.refused[spec.name] = (error && error.message) || 'This could not be opened.';
      changed();
    } else retry(attempt);
  }
  function retry(attempt) {
    if (stopped) return;
    clearTimeout(timer);
    timer = setTimeout(() => {
      open().catch((error) => failed(error, Math.min(attempt + 1, RETRY_MS.length - 1)));
    }, RETRY_MS[attempt]);
  }
  open().catch((error) => failed(error, 0));
  return () => { stopped = true; clearTimeout(timer); if (current) current.close(); };
}

let changeQueued = false;
function changed() {
  if (changeQueued) return;
  changeQueued = true;
  requestAnimationFrame(() => { changeQueued = false; rebuild(); });
}

/* ================= preferences: the parts on the street and the order of the hill ================= */
const PARTS = [
  ['sky', 'Sky and sun'], ['waiting', 'Waiting on you'], ['houses', 'Thread houses'], ['lamps', 'Run lamps'],
  ['stops', 'Schedule stops'], ['crew', 'Crew at work'], ['apps', 'Apps on the hill'], ['vault', 'Vault tower'], ['castle', 'CYFR castle'],
];
const HILL_MAX = 256;
let draft = null;   // the arrange sheet's unsaved choice: {parts, hill}
function storedOn(part) {
  const widgets = isItem(prefsDoc.widgets) ? prefsDoc.widgets : {};
  const entry = widgets[part];
  return !(isItem(entry) && entry.on === false);
}
const on = (part) => (draft ? draft.parts[part] !== false : storedOn(part));
const appKey = (ref) => ref.slice(ref.indexOf(':') + 1);
function hillKeys() {
  const keys = ['castle', 'vault', ...D.apps.map((a) => appKey(a.ref))];
  const saved = draft ? draft.hill : (isItem(prefsDoc.desktop) && typeof prefsDoc.desktop.hill === 'string' ? prefsDoc.desktop.hill.split(' ') : []);
  const ordered = saved.filter((k) => keys.includes(k));
  return [...ordered, ...keys.filter((k) => !ordered.includes(k))];
}
// The hill's order as the document keeps it: keys joined by spaces, as many as fit.
function hillString(keys) {
  let out = '';
  for (const k of keys) {
    const next = out ? out + ' ' + k : k;
    if (next.length > HILL_MAX) break;
    out = next;
  }
  return out;
}

/* ================= the desktop as the shell tells it ================= */
function applyDesktop(value) {
  if (!isItem(value)) return;
  if (isItem(value.prefs) && isItem(value.prefs.document)) prefsDoc = value.prefs.document;
  const a = isItem(value.appearance) ? value.appearance : {};
  if (a.mode === 'light' || a.mode === 'dark') root.dataset.theme = a.mode;
  if (typeof a.locale === 'string' && a.locale) { LOCALE = a.locale; root.lang = a.locale; }
  if (typeof a.time_zone === 'string' && a.time_zone && a.time_zone !== TZ) { TZ = a.time_zone; setMidnight(); }
  const safe = isItem(a.safe_areas) ? a.safe_areas : {};
  root.style.setProperty('--safe-top', (Number(safe.top) || 0) + 'px');
  root.style.setProperty('--safe-bottom', (Number(safe.bottom) || 0) + 'px');
  person = isItem(value.person) && typeof value.person.name === 'string' && value.person.name ? value.person.name : null;
}
function applyInstalled(list) {
  D.apps = Array.isArray(list) ? list.filter((a) => isItem(a) && typeof a.ref === 'string' && typeof a.name === 'string')
    .map((a) => ({ ref: a.ref, name: a.name, open: a.open === true })) : [];
}
function applyCovered(rects) {
  coveredRects = Array.isArray(rects) ? rects.filter((r) => isItem(r) && ['x', 'y', 'width', 'height'].every((k) => Number.isFinite(r[k])))
    .map((r) => [r.x, r.y, r.width, r.height]) : [];
}

/* ================= posture and layout ================= */
const stage = $('#stage'), cvs = $('#world'), labels = $('#labels'), boardEl = $('#board');
let g = null;
let L = null;

function postureNow() {
  if (posture === 'hand') return 'phone';
  if (posture === null && innerWidth < 700 && innerHeight > innerWidth) return 'phone';
  return innerWidth >= 1280 ? 'desk' : 'carried';
}

function layout() {
  const p = postureNow();
  root.classList.toggle('phone', p === 'phone');
  root.dataset.posture = p;
  const W = innerWidth, H = innerHeight;
  const scale = p === 'desk' ? 4 : 3;
  const safeBottom = parseFloat(getComputedStyle(root).getPropertyValue('--safe-bottom')) || 0;
  const boardH = (p === 'phone' ? Math.round(H * 0.5) : p === 'desk' ? 104 : 84) + safeBottom;
  const sceneH = H - boardH;
  const aw = Math.ceil(W / scale), ah = Math.ceil(sceneH / scale);
  // A window over the page: the street fits into the part left open.
  let vx0 = 0, vx1 = aw;
  for (const [x, y, w, h] of coveredRects) {
    if (y < sceneH && y + h > 0) {
      const a = Math.floor(x / scale), b = Math.ceil((x + w) / scale);
      if (a - vx0 >= vx1 - b) vx1 = Math.min(vx1, a); else vx0 = Math.max(vx0, b);
    }
  }
  if (vx1 - vx0 < 120) { vx0 = 0; vx1 = aw; }
  const vw = vx1 - vx0;
  const depotW = p === 'phone' ? 16 : Math.round(vw * 0.165);
  const termW = p === 'phone' ? 14 : Math.round(vw * 0.15);
  const nowX = vx0 + Math.round(vw * (p === 'phone' ? 0.66 : 0.72));
  const riverH = Math.round(ah * (p === 'phone' ? 0.16 : 0.15));
  const quayY = ah - riverH - 3;
  const roadY = quayY - 7;
  const paveY = roadY - 10;
  const houseH = p === 'phone' ? 40 : 46;
  const hillBase = paveY - houseH + 14;
  const ridge = Math.min(hillBase - 18, Math.round(ah * 0.40));
  L = {
    posture: p, W, H, scale, boardH, sceneH, aw, ah, vx0, vx1, depotW, termW, nowX,
    riverH, quayY, roadY, paveY, houseH, hillBase, ridge, sunY: Math.round(ridge * (p === 'desk' ? 0.42 : 0.36)), wireY: roadY - 30, k: 20,
  };
  timeScale();
  cvs.width = aw; cvs.height = ah;
  cvs.style.width = aw * scale + 'px'; cvs.style.height = ah * scale + 'px';
  stage.style.height = sceneH + 'px';
  boardEl.style.height = boardH + 'px';
  boardEl.style.paddingLeft = p !== 'phone' && vx0 ? (16 + vx0 * scale) + 'px' : '';
  boardEl.style.paddingRight = p !== 'phone' && vx1 < aw ? (16 + (aw - vx1) * scale) + 'px' : '';
  g = cvs.getContext('2d');
  if (!g) throw new Error('no canvas');
  skyKey = '';
  makeHill();
  makeFillers();
  rebuild();
}
// The day's stretch of street: from six (or two hours back) to seven (or two hours on).
function timeScale() {
  const n = now();
  L.dayStart = Math.min(360, Math.floor(n) - 120);
  L.dayEnd = Math.max(1140, Math.ceil(n) + 120);
  L.aL = (L.nowX - (L.vx0 + L.depotW)) / Math.log(1 + (n - L.dayStart) / L.k);
  L.aR = (L.vx1 - L.termW - L.nowX) / Math.log(1 + (L.dayEnd - n) / L.k);
}

/* x on the street for a time: logarithmic around now; earlier days gather at the left arch, later ones at the right */
function X(t) {
  const n = now();
  if (t < L.dayStart) return L.vx0 + Math.max(2, L.depotW - 4 - (L.dayStart - t) / (3 * DAY) * (L.depotW - 8));
  if (t > L.dayEnd) return L.vx1 - L.termW + 4 + Math.min(1, (t - L.dayEnd) / (6.5 * DAY)) * (L.termW - 8);
  const d = t - n;
  return d < 0 ? L.nowX - L.aL * Math.log(1 + -d / L.k) : L.nowX + L.aR * Math.log(1 + d / L.k);
}
function invX(x) {
  let lo = L.dayStart, hi = L.dayEnd;
  for (let i = 0; i < 30; i++) { const mid = (lo + hi) / 2; if (X(mid) < x) lo = mid; else hi = mid; }
  return (lo + hi) / 2;
}

/* ================= drawing primitives ================= */
function R(x, y, w, h, c) { g.fillStyle = c; g.fillRect(Math.round(x), Math.round(y), Math.round(w), Math.round(h)); }
function P(x, y, c) { R(x, y, 1, 1, c); }
function hex(c) { const n = parseInt(c.slice(1), 16); return [n >> 16, (n >> 8) & 255, n & 255]; }
function mix(a, b, f) { const A = hex(a), B = hex(b); return '#' + A.map((v, i) => Math.round(v + (B[i] - v) * f).toString(16).padStart(2, '0')).join(''); }
function rng(s0) { let s = s0 >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); }
function hash(str) { let h = 0; for (const ch of str) h = (h * 31 + ch.codePointAt(0)) >>> 0; return h; }

/* sky light for a minute of the day, four bands from the top down */
const SKY = [
  [0, '#141b3d', '#1a2349', '#202b56', '#2a3563'],
  [390, '#1b2350', '#283062', '#3f3b6c', '#5f4a74'],
  [450, '#3e5a9c', '#6d86c0', '#c99a98', '#eab48e'],
  [540, '#62aee3', '#82c4ec', '#a6d7f1', '#cbe7f3'],
  [960, '#5ea8de', '#7dbde8', '#a1d1ee', '#c6e3f0'],
  [1030, '#4f78bf', '#8aa0cf', '#e0a086', '#f2b884'],
  [1090, '#26306a', '#3b3d77', '#6e4a78', '#9a5a7c'],
  [1140, '#161d42', '#1d2550', '#26305d', '#2e3866'],
  [1440, '#141b3d', '#1a2349', '#202b56', '#2a3563'],
];
function skyAt(t, band) {
  const tod = ((t % DAY) + DAY) % DAY;
  for (let i = 1; i < SKY.length; i++) {
    if (tod <= SKY[i][0]) {
      const a = SKY[i - 1], b = SKY[i];
      return mix(a[band + 1], b[band + 1], (tod - a[0]) / (b[0] - a[0]));
    }
  }
  return SKY[0][band + 1];
}
const NIGHT = ['#121936', '#18204a', '#1c2552', '#222c5c'];
const isDay = (t) => { const tod = ((t % DAY) + DAY) % DAY; return tod > 420 && tod < 1110; };

let skyCan = null, skyKey = '';
function drawSky() {
  const key = L.aw + 'x' + L.ah + ':' + Math.floor(now()) + ':' + L.posture + ':' + on('sky');
  if (key !== skyKey) {
    skyKey = key;
    skyCan = skyCan || document.createElement('canvas');
    skyCan.width = L.aw; skyCan.height = L.ah;
    const s = skyCan.getContext('2d');
    const bandH = Math.ceil((L.ridge + 26) / 4);
    const plain = !on('sky');
    for (let x = 0; x < L.aw; x++) {
      let cols;
      const inDepot = x < L.vx0 + L.depotW, inTerm = x >= L.vx1 - L.termW;
      if (inDepot || inTerm || x < L.vx0 || x >= L.vx1) cols = NIGHT;
      else if (plain) cols = [0, 1, 2, 3].map((b) => skyAt(now(), b));
      else { const t = invX(x + 0.5); cols = [0, 1, 2, 3].map((b) => skyAt(t, b)); }
      for (let b = 0; b < 4; b++) {
        s.fillStyle = cols[b];
        s.fillRect(x, b * bandH, 1, b === 3 ? L.ah : bandH);
        if (b < 3) { // a dithered seam between bands
          s.fillStyle = cols[b + 1];
          for (let y = (b + 1) * bandH - 2; y < (b + 1) * bandH; y++) if ((x + y) % 2 === 0) s.fillRect(x, y, 1, 1);
        }
      }
    }
  }
  g.drawImage(skyCan, 0, 0);
}

/* ================= the hill (what has no time) ================= */
let hillY = [];
function makeHill() {
  hillY = [];
  for (let x = 0; x < L.aw; x++) {
    const v = Math.sin(x / 41) * 6 + Math.sin(x / 17 + 1.3) * 3 + Math.sin(x / 7.3) * 1;
    hillY.push(Math.round(L.ridge + v));
  }
}
function drawHill(t) {
  for (let x = 0; x < L.aw; x++) {
    const top = hillY[x];
    R(x, top, 1, L.paveY - top, '#7c9650');
    R(x, top, 1, 1, '#93ad5e');
    if ((x * 7) % 13 < 2) R(x, top + 3 + (x % 5), 1, 2, '#6a8444');
  }
  const r = rng(11);
  for (let x = 4; x < L.aw; x += 9 + Math.floor(r() * 9)) { // cypresses and terrace walls between the buildings
    if (hillBuildings.some((b) => x > b.x - 4 && x < b.x + b.w + 4)) continue;
    const y = hillY[x] + 4 + Math.floor(r() * 6), h = 7 + Math.floor(r() * 6);
    R(x, y - h, 3, h, '#3f5f3a'); R(x + 1, y - h - 2, 1, 2, '#3f5f3a'); R(x + 1, y, 1, 2, '#5a3b2a');
    if (r() > 0.55) R(x - 6, y + 3, 14, 2, '#cdbd9e');
  }
  for (const b of hillBuildings) b.draw(t);
}

const hillBuildings = [];
function placeHill() {
  hillBuildings.length = 0;
  const phone = L.posture === 'phone';
  const items = hillKeys().map(hillItem).filter((b) => b && on(b.part));
  const totalW = items.reduce((s, b) => s + b.w, 0);
  // The name plaque stands over the hill's left end: the hill starts past it.
  const plaque = phone ? 0 : Math.ceil(260 / L.scale) - L.vx0;
  const x0 = L.vx0 + (phone ? 3 : Math.max(L.depotW + 6, plaque)), x1 = L.vx1 - (phone ? 3 : L.termW + 6);
  const gap = items.length > 1 ? Math.max(1, (x1 - x0 - totalW) / (items.length - 1)) : 0;
  let x = items.length === 1 ? (x0 + x1 - totalW) / 2 : x0;
  for (const b of items) {
    if (x + b.w > L.vx1 - 2) break;
    b.x = Math.round(x); x += b.w + gap;
    const mid = Math.min(L.aw - 1, Math.max(0, b.x + (b.w >> 1)));
    b.base = Math.min(L.paveY - 6, hillY[mid] + 7);
    hillBuildings.push(b);
  }
}
function hillItem(key) {
  const phone = L.posture === 'phone';
  if (key === 'castle') return { id: 'castle', part: 'castle', w: phone ? 30 : 40, kind: 'castle', draw(t) { drawCastle(this, t); } };
  if (key === 'vault') return { id: 'vault', part: 'vault', w: 12, kind: 'vault', draw() { drawVault(this); } };
  const app = D.apps.find((a) => appKey(a.ref) === key);
  if (!app) return null;
  return { id: 'app:' + app.ref, part: 'apps', w: phone ? 11 : 16, app, kind: 'app', draw(t) { drawAppHouse(this, t); } };
}
const APP_WALLS = ['#e8a29a', '#f1d27a', '#9fd3b8', '#b9c3cf', '#e6b450', '#a9c7e8'];
function roof(x, y, w, c, dark) {
  R(x + 2, y, w - 4, 1, c); R(x + 1, y + 1, w - 2, 1, c); R(x, y + 2, w, 1, dark);
}
function drawAppHouse(b, t) {
  const app = b.app, phone = L.posture === 'phone';
  const w = b.w, h = phone ? 13 : 18, x = b.x, y = b.base - h;
  roof(x - 1, y - 3, w + 2, '#c4553a', '#8e3a28');
  R(x, y, w, h, APP_WALLS[hash(app.name) % APP_WALLS.length]);
  const lit = app.open ? (Math.floor(t / 700) % 7 === 0 ? '#ffe7a3' : '#ffd76a') : '#33465c';
  if (!phone) {
    R(x + 2, y + 3, 4, 4, lit); R(x + w - 6, y + 3, 4, 4, lit);
    R(x + (w >> 1) - 2, y + h - 7, 4, 7, app.open ? '#ffd76a' : '#5a3b2a');
    R(x + (w >> 1) - 3, y + 9, 7, 2, '#1f4593');
  } else {
    R(x + 2, y + 3, 3, 3, lit); R(x + w - 5, y + 3, 3, 3, lit);
    R(x + (w >> 1) - 1, y + h - 5, 3, 5, app.open ? '#ffd76a' : '#5a3b2a');
  }
  if (app.open) { // chimney smoke: the app is open
    R(x + w - 4, y - 6, 2, 3, '#8e3a28');
    if (!reduceMotion) {
      for (let i = 0; i < 3; i++) {
        const k = ((t / 900 + i / 3) % 1);
        P(x + w - 3 + Math.round(Math.sin(k * 6 + i) * 1.5 + k * 4), y - 7 - Math.round(k * 10), mix('#f3efe4', '#9fb8d8', k));
      }
    }
  }
}
function drawCastle(b, t) {
  const phone = L.posture === 'phone', x = b.x, base = b.base;
  const stone = '#cbbd9f', dark = '#a8997b';
  const w = b.w;
  R(x, base - 12, w, 12, stone);
  for (let i = 0; i < w; i += 3) R(x + i, base - 14, 2, 2, stone);
  R(x + 1, base - 22, 8, 22, stone); for (let i = 0; i < 8; i += 3) R(x + 1 + i, base - 24, 2, 2, stone);
  R(x + w - 8, base - 20, 8, 20, stone); for (let i = 0; i < 8; i += 3) R(x + w - 8 + i, base - 22, 2, 2, stone);
  const kx = x + (w >> 1) - 6;
  R(kx, base - 26, 12, 14, stone); for (let i = 0; i < 12; i += 3) R(kx + i, base - 28, 2, 2, stone);
  R(x, base - 3, w, 3, dark);
  R(kx + 4, base - 8, 4, 8, '#3a2c20'); R(kx + 5, base - 9, 2, 1, '#3a2c20');
  for (let i = 0; i < 3; i++) R(kx + 2 + i * 4, base - 22, 1, 3, '#3a2c20');
  // the flag: CYFR's cobalt and white
  R(kx + 6, base - 36, 1, 8, '#333');
  const wave = reduceMotion ? 0 : Math.floor(t / 300) % 2;
  R(kx + 7, base - 36, 5, 2, '#1f4593'); R(kx + 7 + wave, base - 34, 5, 1, '#f6f2e8');
  if (!phone) R(x + 4, base - 27, 2, 2, '#ffd76a');
}
function drawVault(b) {
  const x = b.x, base = b.base;
  R(x, base - 30, 12, 30, '#b9ad94');
  for (let i = 0; i < 12; i += 3) R(x + i, base - 32, 2, 2, '#b9ad94');
  R(x, base - 2, 12, 2, '#9a8e76');
  for (let i = 0; i < 4; i++) { const cx = x + 2 + (i % 2) * 5, cy = base - 26 + Math.floor(i / 2) * 9; R(cx, cy, 3, 5, '#2a241c'); }
  R(x + 4, base - 7, 4, 7, '#3a2c20');
}

/* ================= the street ================= */
const FILL = ['#efe2c4', '#e7c9a0', '#d9e2d0', '#ecd2c6', '#d6dfe8', '#f0e6cf'];
let fillers = [];
function makeFillers() {
  fillers = [];
  const r = rng(7);
  let x = -4;
  while (x < L.aw + 4) {
    const w = 14 + Math.floor(r() * 8), h = (L.houseH - 14) + Math.floor(r() * 12);
    fillers.push({ x, w, h, c: FILL[Math.floor(r() * FILL.length)], roofC: r() > 0.5 ? '#b65036' : '#a8432d', win: r() });
    x += w + Math.floor(r() * 2);
  }
}
function drawHouse(x, base, w, h, o) {
  const top = base - h;
  roof(x - 1, top - 3, w + 2, o.roof || '#c4553a', '#8e3a28');
  R(x, top, w, h, o.wall);
  if (o.tiles) { for (let yy = top + 1; yy < base - 9; yy += 2) for (let xx = x + ((yy >> 1) % 2); xx < x + w; xx += 2) P(xx, yy, o.tiles); }
  const floors = Math.max(1, Math.floor((h - 10) / 12));
  const winW = w >= 18 ? 4 : 3;
  const cols = [x + 3, x + w - 3 - winW];
  let k = 0;
  for (let f = 0; f < floors; f++) {
    const wy = top + 3 + f * 12;
    for (const wx of cols) {
      const someone = o.people && k < o.people;
      R(wx - 1, wy - 1, winW + 2, 8, '#f3efe4');
      R(wx, wy, winW, 6, o.lit ? '#ffd76a' : '#2f4256');
      if (o.shutters) { R(wx - 2, wy, 1, 6, o.shutters); R(wx + winW + 1, wy, 1, 6, o.shutters); }
      if (someone) { R(wx + 1, wy + 2, winW - 2, 3, o.skin[k % o.skin.length]); R(wx + 1, wy + 1, winW - 2, 1, '#3a2a20'); }
      k++;
    }
    if (f === 1 && w >= 18) { R(x + 1, wy + 7, w - 2, 1, '#2b2b2b'); for (let xx = x + 1; xx < x + w - 1; xx += 2) R(xx, wy + 5, 1, 2, '#2b2b2b'); }
  }
  R(x + (w >> 1) - 2, base - 8, 5, 8, o.entry || '#5a3b2a');
  R(x + (w >> 1) - 3, base - 9, 7, 1, '#f3efe4');
}
function drawFillers() {
  for (const f of fillers) drawHouse(f.x, L.paveY, f.w, f.h, { wall: f.c, roof: f.roofC, lit: false, shutters: f.win > 0.6 ? '#4f7d63' : null });
}

/* calçada: white limestone with the black wave */
function drawStreet(t) {
  R(0, L.paveY, L.aw, L.roadY - L.paveY, '#e8e1cf');
  for (let x = 0; x < L.aw; x++) {
    P(x, L.paveY + 3 + Math.round(Math.sin(x / 4.2) * 1.6), '#3f3d3a');
    P(x, L.paveY + 7 + Math.round(Math.sin(x / 4.2 + 2.2) * 1.2), '#3f3d3a');
  }
  R(0, L.roadY - 1, L.aw, 1, '#b9ae95');
  R(0, L.roadY, L.aw, L.quayY - L.roadY, '#9a8f7d');
  for (let x = 0; x < L.aw; x += 3) P(x + ((x >> 1) % 2), L.roadY + 1 + (x % 4 === 0 ? 4 : 0), '#877c6a');
  R(0, L.roadY + 2, L.aw, 1, '#5d5d5d'); R(0, L.roadY + 5, L.aw, 1, '#5d5d5d');
  const shift = reduceMotion ? 0 : Math.floor(t / 60) % 6;
  for (let x = shift; x < L.aw; x += 6) { P(x, L.roadY + 2, '#c4c4c4'); P(x + 3, L.roadY + 5, '#c4c4c4'); }
  R(0, L.wireY, L.aw, 1, '#3b3b3b');
  R(0, L.quayY, L.aw, 2, '#d3c8ae'); R(0, L.quayY + 2, L.aw, 1, '#8e826b');
}
function drawRiver(t) {
  const y0 = L.quayY + 3;
  R(0, y0, L.aw, L.ah - y0, '#2c6a90');
  for (let y = y0 + 2; y < L.ah; y += 3) for (let x = (y * 5) % 7; x < L.aw; x += 9) P(x, y, '#357aa3');
  if (reduceMotion) return;
  const r = rng(3);
  for (let i = 0; i < L.aw / 6; i++) {
    const sx = Math.floor(r() * L.aw), sy = y0 + 1 + Math.floor(r() * (L.ah - y0 - 2));
    const phase = (t / 1400 + r()) % 1;
    if (phase < 0.35) R((sx + Math.floor(t / 3000)) % L.aw, sy, phase < 0.15 ? 1 : 2, 1, '#cfeaf6');
  }
}

/* the sun stands over now by day, the moon by night; wisps drift over it */
function drawSun(t) {
  if (!on('sky')) return;
  const sx = L.nowX, sy = L.sunY;
  const r = L.posture === 'phone' ? 4 : 6;
  const day = isDay(now());
  const body = day ? '#ffd94a' : '#e9e6d6';
  for (let dy = -r; dy <= r; dy++) { const dx = Math.floor(Math.sqrt(r * r - dy * dy)); R(sx - dx, sy + dy, dx * 2 + 1, 1, body); }
  if (day) {
    R(sx - r + 2, sy - r + 2, 2, 2, '#fff1a8');
    const pulse = reduceMotion ? 0 : Math.floor(t / 500) % 2;
    const ray = r + 3 + pulse;
    for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) R(sx + dx * ray, sy + dy * ray, dx ? 2 : 1, dy ? 2 : 1, '#ffd94a');
    for (const [dx, dy] of [[1, 1], [-1, 1], [1, -1], [-1, -1]]) P(sx + dx * (ray - 2), sy + dy * (ray - 2), '#ffd94a');
  } else {
    for (let dy = -r; dy <= r; dy++) { const dx = Math.floor(Math.sqrt(r * r - dy * dy)); R(sx - dx + 3, sy + dy - 1, dx * 2 + 1, 1, skyAt(now(), 0)); }
  }
  const drift = reduceMotion ? 0 : (t / 1000) * 1.2;
  for (let i = 0; i < 3; i++) {
    const cx = ((i * 131 + drift) % (L.aw + 40)) - 20, cy = 8 + i * 9 + (i === 1 ? 4 : 0);
    R(cx, cy, 10 + i * 3, 1, 'rgba(255,255,255,.75)'); R(cx + 3, cy - 1, 5, 1, 'rgba(255,255,255,.6)');
  }
}
function drawGulls(t) {
  if (reduceMotion || !on('sky')) return;
  for (let i = 0; i < 3; i++) {
    const x = ((t / (90 + i * 25)) + i * 97) % (L.aw + 20) - 10;
    const y = 14 + i * 6 + Math.round(Math.sin(t / 900 + i) * 2);
    const up = Math.floor(t / 220 + i) % 2;
    P(x, y + up, '#f3efe4'); P(x + 1, y, '#f3efe4'); P(x + 2, y + 1, '#f3efe4'); P(x + 3, y, '#f3efe4'); P(x + 4, y + up, '#f3efe4');
  }
}

/* ================= sprites on the street ================= */
const LOOKS = [
  { skin: '#e2b48a', hair: '#3a2a20', shirt: '#c4553a', legs: '#2f3a52' },
  { skin: '#b07a52', hair: '#1c1612', shirt: '#2d5cb8', legs: '#3b3b3b' },
  { skin: '#f0c9a6', hair: '#a8743c', shirt: '#3f8a6a', legs: '#2f3a52' },
  { skin: '#8a5a3a', hair: '#1c1612', shirt: '#e6b450', legs: '#4a3a2a' },
];
function drawPerson(x, feet, look, t, walking, item, cap) {
  x = Math.round(x);
  const step = walking && !reduceMotion ? Math.floor(t / 160) % 2 : 0;
  const bob = !walking && !reduceMotion ? (Math.floor(t / 700) % 2) : 0;
  R(x - 2, feet - 3, 2, 3 - step, look.legs); R(x + 1, feet - 3, 2, 3 - (1 - step) * (walking ? 1 : 0), look.legs);
  R(x - 3, feet - 8 - bob, 6, 5 + bob, look.shirt);
  R(x - 2, feet - 12 - bob, 4, 4, look.skin);
  R(x - 2, feet - 13 - bob, 4, 2, cap || look.hair);
  if (cap) R(x + 2, feet - 12 - bob, 2, 1, cap);
  if (item === 'paper') { R(x + 3, feet - 9 - bob, 3, 4, '#ffffff'); P(x + 4, feet - 8 - bob, '#1f4593'); }
  if (item === 'key') { R(x + 3, feet - 7 - bob, 3, 1, '#e8b830'); R(x + 5, feet - 8 - bob, 1, 3, '#e8b830'); }
  if (item === 'parcel') { R(x + 2, feet - 9 - bob, 5, 4, '#a8743c'); R(x + 4, feet - 9 - bob, 1, 4, '#e9d9b0'); }
  if (item === 'news') { R(x + 3, feet - 9 - bob, 3, 4, '#eeeeee'); P(x + 4, feet - 8 - bob, '#c23a2e'); P(x + 4, feet - 6 - bob, '#c23a2e'); }
  if (item === 'map') { R(x + 3, feet - 9 - bob, 4, 3, '#f3efe4'); P(x + 4, feet - 8 - bob, '#2d5cb8'); P(x + 5, feet - 8 - bob, '#c23a2e'); }
}
function drawTram(xn, t) {
  const Lt = 34, x = Math.round(xn) - Lt, base = L.roadY + 6, yy = base - 22;
  for (let i = 0; i <= 12; i++) P(x + 9 + i, yy - Math.round(i * (yy - L.wireY) / 12), '#2b2b2b'); // the trolley pole up to the wire
  if (!reduceMotion && Math.floor(t / 1700) % 5 === 0 && Math.floor(t / 90) % 2 === 0) { P(x + 21, L.wireY - 1, '#bfe8ff'); P(x + 22, L.wireY + 1, '#ffffff'); }
  R(x + 2, yy, Lt - 4, 2, '#3a3a3a');
  R(x, yy + 2, Lt, 8, '#f3ecd6');
  for (let i = 0; i < 5; i++) { R(x + 3 + i * 6, yy + 3, 4, 5, '#2f4256'); P(x + 3 + i * 6, yy + 3, '#5d7894'); }
  R(x, yy + 10, Lt, 9, '#f4c22e'); R(x, yy + 17, Lt, 1, '#c99a12');
  R(x + Lt - 7, yy + 10, 4, 8, '#e3ad1c');
  R(x - 1, yy + 19, Lt + 2, 1, '#2b2b2b');
  R(x + Lt - 9, yy - 3, 9, 3, '#121212');
  R(xn, yy + 12, 1, 3, '#fff1a8');
  R(x + 4, base - 3, 6, 3, '#222'); R(x + Lt - 11, base - 3, 6, 3, '#222');
  P(x + 6, base - 2, '#777'); P(x + Lt - 9, base - 2, '#777');
}
function drawLampPost(e, t) {
  const x = Math.round(e.x), base = L.roadY - 1, h = 24;
  R(x, base - h, 1, h, '#2e4a3a'); R(x - 1, base - 2, 3, 2, '#2e4a3a');
  const heads = e.runs.slice(0, 3);
  heads.forEach((run, i) => {
    const hx = x + (heads.length === 1 ? -1 : [-4, 2, -1][i]), hy = base - h - (i === 2 ? 4 : 0);
    if (heads.length > 1 && i < 2) R(Math.min(x, hx + 1), base - h + 1, Math.abs(hx + 1 - x) + 1, 1, '#2e4a3a');
    let c = '#ffd96a', halo = '#fff3b8';
    if (run.state === 'failed') { c = '#3d3d3d'; halo = null; }
    if (run.state === 'cancelled') { c = '#9a9a9a'; halo = null; }
    if (run.state === 'running') c = !reduceMotion && Math.floor(t / 150) % 2 ? '#ffffff' : '#ffd96a';
    R(hx, hy, 3, 3, c);
    R(hx, hy - 1, 3, 1, '#2e4a3a');
    if (halo) { P(hx - 1, hy + 1, halo); P(hx + 3, hy + 1, halo); P(hx + 1, hy + 3, halo); }
    if (run.state === 'failed') { P(hx + 1, hy + 1, '#c23a2e'); P(hx + 1, hy + 4, '#c23a2e'); }
  });
}
function drawStop(e) {
  const x = Math.round(e.x), base = L.roadY - 1;
  R(x, base - 18, 1, 18, '#555');
  const paused = e.sched.status === 'paused';
  R(x - 3, base - 23, 7, 5, paused ? '#9a9a9a' : '#f4c22e');
  R(x - 2, base - 21, 5, 1, '#1c1d26');
  if (paused) { for (let i = 0; i < 7; i++) P(x - 3 + i, base - 23 + Math.floor(i * 5 / 7), '#7a4a2a'); }
}

/* ================= entities: the streams turned into things on the street ================= */
let ents = [];
let selected = null;
const leaving = new Map();     // attention id -> {from, start, dur, ent, done}

// The runs as lamps want them: each with a state and a time, the runs stream first, then the scheduled
// occurrences whose run it no longer holds.
function lampRuns() {
  const out = [];
  const seen = new Set();
  for (const { run, t } of D.runs.values()) {
    seen.add(run.execution_id);
    let at = t;
    if (at == null && run.kind === 'failed' && typeof run.reference === 'string') {
      const waiting = D.attention.get(run.reference);
      if (waiting && waiting.item.kind === 'failed_run') at = mins(waiting.item.since);
    }
    const error = isItem(run.error) ? run.error : null;
    out.push({
      id: run.execution_id, ref: text(run.reference), t: at,
      state: run.kind === 'completed' ? 'ok' : run.kind === 'failed' ? 'failed' : run.kind === 'cancelled' ? 'cancelled' : 'running',
      ms: run.duration_ms, cause: error ? text(error.cause) : '',
    });
  }
  for (const { item } of D.occ.values()) {
    if (typeof item.execution_id === 'string' && seen.has(item.execution_id)) continue;
    const s = D.schedules.get(item.schedule_id);
    const reason = isItem(item.reason) ? item.reason : null;
    out.push({
      id: item.occurrence_id, ref: s ? text(s.item.name) || text(s.item.reference) : 'a schedule', t: mins(item.scheduled_for),
      state: item.kind === 'failed' ? 'failed' : 'ok', ms: null, cause: reason ? text(reason.cause) : '', scheduled: true,
    });
  }
  return out;
}
// Things that would stand on each other: the latest keeps its place and each earlier one steps back
// (toward the earlier hours) until it stands clear, never past the left arch.
function spread(list, gap) {
  const floor = L.vx0 + L.depotW + 4;
  list.sort((a, b) => b.x - a.x);
  for (let i = 1; i < list.length; i++) {
    const room = (gap(list[i]) + gap(list[i - 1])) / 2;
    if (list[i - 1].x - list[i].x < room) list[i].x = Math.max(floor, list[i - 1].x - room);
  }
}
const looksFor = (id) => LOOKS[[...id].reduce((h, c) => h + c.charCodeAt(0), 0) % LOOKS.length];

function rebuild() {
  if (root.classList.contains('plain')) { renderFallback(); return; }
  if (!L) return;
  timeScale();
  ents = [];
  placeHill();
  const n = now();
  const phone = L.posture === 'phone';
  const add = (e) => { ents.push(e); return e; };
  if (on('houses')) {
    for (const { item: th } of D.threads.values()) {
      const t = mins(th.last_activity);
      if (t == null) continue;
      add({ id: 'thread-' + th.id, kind: 'thread', part: 'houses', t, th, x: X(t), w: phone ? 16 : 22 });
    }
  }
  if (on('lamps')) { // lamps, grouped when they stand within three pixels
    const runs = lampRuns();
    const timed = runs.filter((r) => r.t != null && r.t >= L.dayStart && r.t <= n + 1).sort((a, b) => a.t - b.t);
    let cur = null;
    for (const r of timed) {
      const x = X(r.t);
      if (cur && Math.abs(x - cur.x) < 4 && cur.runs.length < 3) cur.runs.push(r);
      else cur = add({ id: 'lamp-' + r.id, kind: 'lamp', part: 'lamps', t: r.t, x, runs: [r] });
    }
    const untimed = runs.filter((r) => r.t == null);
    if (untimed.length) add({ id: 'lamp-untold', kind: 'lamp', part: 'lamps', t: null, x: L.vx0 + L.depotW + 9, runs: untimed, untold: true });
  }
  if (on('stops')) { // the next firing; a paused stop stands boarded up at its last firing
    for (const { item: s } of D.schedules.values()) {
      const t = s.status === 'paused' ? mins(s.last_run_at) : mins(s.next_run_at);
      if (t == null) continue;
      add({ id: 'stop-' + s.schedule_id, kind: 'stop', part: 'stops', t, x: X(t), sched: s });
    }
  }
  if (on('waiting')) {
    for (const { item: a } of D.attention.values()) {
      const t = mins(a.since);
      const at = t == null ? n : t;
      // The tram's body covers the last minutes of the street: what waits from then queues behind its tail.
      const x = Math.min(L.nowX - 38, X(at) + (a.kind === 'failed_run' || a.kind === 'failed_schedule' ? 4 : -4));
      add({ id: 'ask-' + a.id, kind: 'ask', part: 'waiting', t: at, x, a, look: looksFor(a.id) });
    }
  }
  spread(ents.filter((e) => e.kind === 'thread'), (e) => e.w + 1);
  spread(ents.filter((e) => e.kind === 'ask'), () => 8);
  for (const [id, lv] of leaving) if (!ents.some((e) => e.id === id)) ents.push(lv.ent);
  if (on('crew')) {
    let i = 0;
    for (const { item: job } of D.activity.values()) {
      const t = mins(job.since);
      add({ id: 'crew-' + job.id, kind: 'crew', part: 'crew', t: t == null ? n : t, x: L.nowX + 7 + i * 9, job });
      i++;
    }
  }
  add({ id: 'tram', kind: 'tram', part: null, t: n, x: L.nowX });
  for (const b of hillBuildings) add({ id: b.id, kind: b.kind, part: b.part, x: b.x + b.w / 2, hill: b, app: b.app });
  if (selected && !ents.some((e) => e.id === selected) && selected !== 'earlier' && selected !== 'later') selected = null;
  renderLabels();
  renderBoard();
  if (!live()) paint(performance.now());
}

/* ================= the per-frame picture ================= */
let scrub = null;              // {t, x} while the street is being dragged
let tramX = null;              // the tram nose's animated position
function frame(t) {
  drawSky();
  drawSun(t);
  drawGulls(t);
  drawHill(t);
  drawFillers();
  const night = (x0, w) => { g.globalAlpha = 0.42; R(x0, 0, w, L.quayY, '#0e1430'); g.globalAlpha = 1; };
  for (const e of ents) if (e.kind === 'thread') drawThread(e, t);
  drawStreet(t);
  for (const e of ents) if (e.kind === 'crew') {
    for (let x = Math.round(Math.max(L.vx0 + L.depotW, X(e.t))); x < e.x - 3; x += 3) P(x, L.paveY + 8, '#b9b09a');
  }
  for (const e of ents) if (e.kind === 'ask') drawAsk(e, t);
  for (const e of ents) if (e.kind === 'crew') drawPerson(e.x, L.paveY + 9, LOOKS[1], t, true, 'map', '#4fc8bd');
  for (const e of ents) if (e.kind === 'stop') drawStop(e);
  for (const e of ents) if (e.kind === 'lamp') drawLampPost(e, t);
  drawArch(L.vx0 + L.depotW); drawArch(L.vx1 - L.termW);
  night(L.vx0, L.depotW); night(L.vx1 - L.termW, L.termW);
  if (L.vx0 > 0) night(0, L.vx0);
  if (L.vx1 < L.aw) night(L.vx1, L.aw - L.vx1);
  drawLitWindows();
  const target = scrub ? scrub.x : L.nowX;
  if (tramX == null) tramX = target;
  tramX += (target - tramX) * (reduceMotion ? 1 : 0.22);
  if (Math.abs(target - tramX) < 0.3) tramX = target;
  drawTram(tramX, t);
  drawRiver(t);
  drawSelection(t);
  moveLabels();
}
function drawArch(x) {
  x = Math.round(x); const base = L.paveY, top = base - 24;
  R(x - 6, top, 13, 4, '#e9dcc0'); R(x - 6, top + 4, 3, 20, '#e9dcc0'); R(x + 4, top + 4, 3, 20, '#e9dcc0');
  R(x - 5, top - 2, 11, 2, '#d8c9a8'); R(x - 1, top - 4, 3, 2, '#d8c9a8');
}
function drawLitWindows() {
  // the earlier and later days stay lit at night: their houses and stops glow through the dark
  for (const e of ents) {
    if (e.kind !== 'thread' || e.t >= L.dayStart) continue;
    const x = Math.round(e.x - e.w / 2), top = L.paveY - L.houseH;
    R(x + 3, top + 3, 4, 6, '#ffd76a'); R(x + e.w - 7, top + 15, 4, 6, '#ffd76a');
  }
  for (const e of ents) if (e.kind === 'stop' && (e.t < L.dayStart || e.t > L.dayEnd)) {
    const x = Math.round(e.x), base = L.roadY - 1;
    R(x - 3, base - 23, 7, 5, e.sched.status === 'paused' ? '#6d6d6d' : '#f4c22e'); R(x - 2, base - 21, 5, 1, '#1c1d26');
  }
}
const THREAD_WALLS = ['#e3b04b', '#e79b8f', '#93c59a', '#d6dfe8', '#ecd2c6'];
function drawThread(e) {
  const th = e.th, w = e.w, h = L.houseH, x = Math.round(e.x - w / 2);
  const shared = th.kind === 'shared';
  const people = Array.isArray(th.people) ? th.people.length : 0;
  drawHouse(x, L.paveY, w, h, {
    wall: shared ? THREAD_WALLS[hash(th.id) % THREAD_WALLS.length] : '#eef6f4',
    tiles: shared ? null : '#7fd1c7', shutters: shared ? '#3f7f5a' : '#2d5cb8',
    people: shared ? Math.max(0, people - 1) : 0, skin: ['#e2b48a', '#b07a52', '#f0c9a6', '#8a5a3a'],
    entry: th.waits_on_you ? '#f4c22e' : '#5a3b2a',
  });
  const top = L.paveY - h;
  if (th.waits_on_you) { // a banner from the balcony: this thread waits on you
    R(x + 5, top + 23, w - 10, 6, '#f4c22e'); R(x + (w >> 1), top + 24, 1, 3, '#1c1d26'); P(x + (w >> 1), top + 28, '#1c1d26');
  }
}
const ITEM_OF = { approval: 'paper', confirmation: 'key', failed_run: 'news', failed_schedule: 'news', file_offer: 'parcel' };
function drawAsk(e, t) {
  const lv = leaving.get(e.id);
  let x = e.x, walking = false;
  if (lv) {
    const k = Math.min(1, (performance.now() - lv.start) / lv.dur);
    x = lv.from + (L.nowX - 20 - lv.from) * k; walking = k < 1;
    if (k >= 1) return;
  }
  drawPerson(x, L.paveY + 9, e.look, t, walking, ITEM_OF[e.a.kind]);
  if (lv) { R(x - 2, L.paveY - 9, 5, 4, '#3d8a4f'); P(x - 1, L.paveY - 7, '#f3efe4'); P(x, L.paveY - 6, '#f3efe4'); P(x + 1, L.paveY - 7, '#f3efe4'); P(x + 2, L.paveY - 8, '#f3efe4'); }
  if (e.a.kind === 'confirmation' && !lv && !reduceMotion) { // the person's own dialog in CYFR: the villager waits with "…"
    const k = Math.floor(t / 300) % 4;
    for (let i = 0; i < 3; i++) if (i < k) P(x - 2 + i * 2, L.paveY - 7, '#1c1d26');
  }
  if (L.posture === 'phone' && !lv) { R(x - 1, L.paveY - 9, 3, 4, '#f4c22e'); P(x, L.paveY - 8, '#1c1d26'); P(x, L.paveY - 6, '#1c1d26'); }
}
function drawSelection(t) {
  if (!selected) return;
  const el = labels.querySelector(`[data-id="${CSS.escape(selected)}"]`);
  if (!el) return;
  const s = L.scale;
  const x = Math.round(parseFloat(el.style.left) / s), y = Math.round(parseFloat(el.style.top) / s);
  const w = Math.round(parseFloat(el.style.width) / s), h = Math.round(parseFloat(el.style.height) / s);
  if (!reduceMotion && Math.floor(t / 400) % 2) return;
  for (const [cx, cy, dx, dy] of [[x, y, 1, 1], [x + w - 1, y, -1, 1], [x, y + h - 1, 1, -1], [x + w - 1, y + h - 1, -1, -1]]) {
    R(Math.min(cx, cx + dx * 3), cy, 4, 1, '#f4c22e'); R(cx, Math.min(cy, cy + dy * 3), 1, 4, '#f4c22e');
  }
}

/* ================= labels and hit areas (the accessible layer) ================= */
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const KIND_WORD = { approval: 'an approval', confirmation: 'a confirmation', failed_run: 'a failed run', failed_schedule: 'a failed schedule', file_offer: 'a file offered' };

function hitBox(e) {
  const s = L.scale;
  const box = (x, y, w, h) => ({ x: x * s, y: y * s, w: w * s, h: h * s });
  switch (e.kind) {
    case 'thread': return box(e.x - e.w / 2, L.paveY - L.houseH - 3, e.w, L.houseH - 12);
    case 'ask': return box(e.x - 5, L.paveY - 6, 10, 16);
    case 'lamp': return box(e.x - 5, L.roadY - 30, 10, 29);
    case 'stop': return box(e.x - 4, L.roadY - 25, 9, 24);
    case 'crew': return box(e.x - 4, L.paveY - 5, 9, 15);
    case 'tram': return box(e.x - 34, L.roadY - 17, 34, 23);
    case 'castle': return box(e.hill.x, e.hill.base - 36, e.hill.w, 36);
    case 'vault': return box(e.hill.x - 1, e.hill.base - 33, 14, 33);
    default: return box(e.hill.x - 1, e.hill.base - 22, e.hill.w + 2, 22);
  }
}
function waitingWords(a) {
  const label = text(a.label);
  switch (a.kind) {
    case 'failed_run': {
      const name = componentName(text(a.id));
      const run = [...D.runs.values()].filter((r) => r.run.reference === a.id && r.run.kind === 'failed').sort((x, y) => y.seq - x.seq)[0];
      const cause = run && isItem(run.run.error) ? text(run.run.error.cause) : '';
      return { head: `${name} failed`, tail: cause && cause !== 'failed' ? shortReason(cause) : 'its last run', fail: true };
    }
    case 'failed_schedule': return { head: `${label || 'A schedule'} failed`, tail: 'its last run', fail: true };
    case 'approval': return { head: 'Approve in', tail: label || 'a thread' };
    case 'confirmation': return { head: 'Confirm in CYFR', tail: label || 'a change' };
    case 'file_offer': return { head: 'A file offered', tail: label || 'a file' };
    default: return { head: 'Waiting', tail: label };
  }
}
function threadSub(th) {
  const people = Array.isArray(th.people) ? th.people.length : 0;
  if (th.waits_on_you) return 'waits on you';
  if (th.kind === 'shared') return people === 2 ? 'a pair' : people + ' people';
  return 'with AQUA';
}
function labelFor(e) {
  const phone = L.posture === 'phone';
  switch (e.kind) {
    case 'thread': {
      if (phone || e.t < L.dayStart || e.t > L.dayEnd) return null;
      return { cls: 'quiet onwall', band: 'house', html: `<b>${esc(text(e.th.title) || 'A thread')}</b><small>${esc(threadSub(e.th))}</small>` };
    }
    case 'ask': {
      if (phone || leaving.has(e.id)) return null;
      const w = waitingWords(e.a);
      return { cls: w.fail ? 'ask fail' : 'ask', band: 'street', html: `<b>${esc(w.head)}</b><small>${esc(w.tail)}</small>` };
    }
    case 'crew': return phone ? null : { cls: '', band: 'street', html: `<b>${esc(text(e.job.member) || 'crew')} · since ${when(e.t)}</b><small>${esc(text(e.job.status) || 'working')}</small>` };
    case 'stop': {
      if (phone || e.t < L.dayStart || e.t > L.dayEnd) return null;
      const name = text(e.sched.name) || componentName(text(e.sched.reference));
      return { cls: 'quiet', band: 'street', html: `${when(e.t)} ${esc(name.split(' ')[0].toLowerCase())}` };
    }
    case 'lamp': return e.untold && !phone ? { cls: 'quiet', band: 'street', html: 'earlier runs' } : null;
    case 'tram': return null;
    case 'castle': return phone ? null : { cls: 'quiet', band: 'hill', html: '<b>CYFR</b><small>settings</small>' };
    case 'vault': return phone ? null : { cls: 'quiet', band: 'hill', html: '<b>Vault</b>' };
    default: return phone ? null : { cls: 'quiet', band: 'hill', html: `<b>${esc(e.app.name)}</b>${e.app.open ? '<small>open</small>' : ''}` };
  }
}
function ariaFor(e) {
  switch (e.kind) {
    case 'thread': return `Thread ${text(e.th.title)}, ${e.th.kind}, last active ${when(e.t)}${e.th.waits_on_you ? ', waits on you' : ''}`;
    case 'ask': { const w = waitingWords(e.a); return `Waiting on you: ${KIND_WORD[e.a.kind] || 'an item'}, ${w.head} ${w.tail}, since ${when(e.t)}`; }
    case 'lamp': return (e.untold ? 'Earlier runs, time not told: ' : 'Runs at ') + e.runs.map((r) => `${r.t == null ? '' : when(r.t) + ' '}${componentName(r.ref)} ${r.state}`).join('; ');
    case 'stop': return `Schedule ${text(e.sched.name)}, ${e.sched.status}, ${e.sched.status === 'paused' ? 'last ' : 'next '}${when(e.t)}`;
    case 'crew': return `Crew ${text(e.job.member)} ${text(e.job.status)} since ${when(e.t)}`;
    case 'tram': return `Now, ${clock(now())}. Arrow keys walk the day; Escape returns to now.`;
    case 'castle': return 'CYFR: open the settings';
    case 'vault': return 'The vault';
    default: return `App ${e.app.name}${e.app.open ? ', open' : ''}`;
  }
}

function plaqueTime() { return `${dateOf(0, { weekday: 'long', day: 'numeric', month: 'long' })} · ${clock(now())}`; }
function renderLabels() {
  const s = L.scale;
  const html = [];
  html.push(`<div class="plaque"><h1>${esc((person || 'your street').toLowerCase())}</h1><p id="plaque-time">${esc(plaqueTime())}</p></div>`);
  // hour stones on the kerb
  const ticks = [];
  let lastX = -99;
  for (let h = Math.ceil(L.dayStart / 60); h <= Math.floor(L.dayEnd / 60); h++) {
    const x = X(h * 60) * s;
    if (x - lastX < (L.posture === 'phone' ? 30 : 34) || Math.abs(x - L.nowX * s) < 30) continue;
    lastX = x; ticks.push(`<span class="tick" style="left:${x}px;top:${L.roadY * s + 2}px">${((h % 24) + 24) % 24}</span>`);
  }
  if (L.posture !== 'phone') {
    ticks.push(`<span class="tick day" style="left:${(L.vx0 + L.depotW / 2) * s}px;top:${L.roadY * s + 2}px">${esc(dayName(-2) + ' · ' + dayName(-1))}</span>`);
    ticks.push(`<span class="tick day" style="left:${(L.vx1 - L.termW / 2) * s}px;top:${L.roadY * s + 2}px">${esc(dayName(1) + ' →')}</span>`);
  }
  html.push(ticks.join(''));
  const order = ents.slice().sort((a, b) => (a.hill ? 0 : 1) - (b.hill ? 0 : 1) || a.x - b.x);
  for (const e of order) {
    const b = hitBox(e);
    const lab = labelFor(e);
    const plate = lab ? `<span class="plate ${lab.cls}${selected === e.id ? ' sel' : ''}" data-band="${lab.band}" data-align="${lab.align || 'center'}">${lab.html}</span>` : '';
    html.push(`<button class="hit" data-id="${esc(e.id)}" aria-label="${esc(ariaFor(e))}" style="left:${b.x}px;top:${b.y}px;width:${Math.max(b.w, 44)}px;height:${Math.max(b.h, 44)}px;margin-left:${b.w < 44 ? (b.w - 44) / 2 : 0}px;margin-top:${b.h < 44 ? (b.h - 44) / 2 : 0}px">${plate}</button>`);
  }
  if (L.posture !== 'phone') { // earlier and later days: one night plate each, a list of things to tap
    html.push(nightPlate('earlier', 'Earlier', dayItems('earlier'), (L.vx0 + 3) * s, (L.paveY - 3) * s, 'left'));
    html.push(nightPlate('later', 'Later', dayItems('later'), (L.vx1 - 3) * s, (L.paveY - 3) * s, 'right'));
  }
  html.push(`<span class="blind" id="blind" style="left:${L.nowX * s}px;top:${(L.roadY - 21) * s - 5}px">${clock(now())}</span>`);
  labels.innerHTML = html.join('');
  placePlates();
  labels.querySelectorAll('.hit').forEach((el) => {
    el.addEventListener('click', () => select(el.dataset.id));
    if (el.dataset.id === 'tram') el.addEventListener('keydown', tramKeys);
  });
  labels.querySelectorAll('[data-pick]').forEach((el) => el.addEventListener('click', () => select(el.dataset.pick)));
}
/* plates of one band never cover each other: each slides sideways up to a limit, else rises a lane */
function placePlates() {
  const box = labels.getBoundingClientRect();
  const bands = {};
  labels.querySelectorAll('.plate[data-band]').forEach((p) => { (bands[p.dataset.band] = bands[p.dataset.band] || []).push(p); });
  const blind = $('#blind');
  const houses = [];
  const ORDER = ['hill', 'house', 'street'];
  for (const [band, plates] of Object.entries(bands).sort((a, b) => ORDER.indexOf(a[0]) - ORDER.indexOf(b[0]))) {
    const lanes = [[], [], []];
    if (band === 'street' && blind) { const r = blind.getBoundingClientRect(); lanes[0].push([r.left - box.left - 4, r.right - box.left + 4]); }
    if (band === 'street') {
      const base = (L.paveY - 7) * L.scale;
      lanes.forEach((ivs, lane) => {
        const bottom = base - lane * 40, top = bottom - 36;
        for (const r of houses) if (r.bottom - box.top > top && r.top - box.top < bottom) ivs.push([r.left - box.left - 2, r.right - box.left + 2]);
      });
    }
    if (band === 'street') labels.querySelectorAll('.nightlist').forEach((n) => { const r = n.getBoundingClientRect(); for (const ln of lanes) ln.push([r.left - box.left, r.right - box.left]); });
    const items = plates.map((p) => {
      const hit = p.parentElement.getBoundingClientRect();
      return { p, hit, ax: hit.left - box.left + hit.width / 2, w: p.offsetWidth };
    }).sort((a, b) => a.ax - b.ax);
    const laneH = band === 'hill' ? 38 : 40;
    const maxShift = band === 'hill' ? 40 : band === 'street' ? 150 : 90;
    for (const it of items) {
      let want = it.ax - it.w / 2;
      want = Math.max(6, Math.min(L.W - 6 - it.w, want));
      let placed = null;
      for (let lane = 0; lane < lanes.length && !placed; lane++) {
        const ivs = lanes[lane];
        const cands = [want, ...ivs.map((v) => v[1] + 6), ...ivs.map((v) => v[0] - 6 - it.w)].filter((c) => c >= 6 && c + it.w <= L.W - 6);
        cands.sort((a, b) => Math.abs(a - want) - Math.abs(b - want));
        const ok = cands.find((c) => Math.abs(c - want) <= maxShift && ivs.every((v) => c + it.w + 6 <= v[0] || c >= v[1] + 6));
        if (ok != null) { placed = { lane, x: ok }; ivs.push([ok, ok + it.w]); }
      }
      // A plate with no room in any lane is not drawn over another: its thing stays tappable, and the board lists it.
      if (!placed) { it.p.hidden = true; continue; }
      it.p.style.left = (placed.x - (it.hit.left - box.left)) + 'px';
      it.p.style.transform = 'none';
      if (band === 'house') { it.p.style.top = (14 + placed.lane * 36) + 'px'; houses.push(it.p.getBoundingClientRect()); }
      else if (band === 'street') { // one baseline for the whole street, just over the heads
        const base = (L.paveY - 7) * L.scale - placed.lane * laneH;
        it.p.style.bottom = 'auto'; it.p.style.top = (base - it.p.offsetHeight - (it.hit.top - box.top)) + 'px';
      } else it.p.style.marginBottom = (2 + placed.lane * laneH) + 'px';
    }
  }
}
function itemText(e) {
  if (e.kind === 'thread') return text(e.th.title) || 'A thread';
  if (e.kind === 'stop') return (text(e.sched.name) || componentName(text(e.sched.reference))) + (e.sched.status === 'paused' ? ' (paused)' : '');
  if (e.kind === 'ask') { const w = waitingWords(e.a); return `${w.head} ${w.tail}`; }
  return '';
}
function dayItems(id) {
  const kinds = ['thread', 'stop', 'ask'];
  const pick = id === 'earlier' ? (e) => e.t < L.dayStart : (e) => e.t > L.dayEnd;
  return ents.filter((e) => e.t != null && kinds.includes(e.kind) && pick(e))
    .sort((a, b) => (id === 'earlier' ? b.t - a.t : a.t - b.t))
    .map((e) => ({ id: e.id, t: e.t, text: itemText(e) }));
}
function nightPlate(id, title, items, x, y, side) {
  if (!items.length) return '';
  let day = null;
  const rows = items.slice(0, 12).map((e) => {
    const d = dayOf(e.t);
    const head = d !== day ? `<b>${esc(dayName(d))}${d === -1 ? ' · yesterday' : d === 1 ? ' · tomorrow' : ' ' + esc(dateOf(d, { day: 'numeric' }))}</b>` : '';
    day = d;
    return `${head}<span class="nightrow"><span>${clock(e.t)}</span> ${esc(e.text)}</span>`;
  }).join('');
  const zone = (side === 'left' ? L.depotW : L.termW) * L.scale - 6;
  const pos = side === 'left' ? `left:${x}px` : `right:${L.W - x}px`;
  return `<button class="nightlist${selected === id ? ' sel' : ''}" data-pick="${id}" style="${pos};bottom:${L.sceneH - y}px;width:${zone}px;max-height:${y - 70}px;overflow:hidden" aria-label="${title}: ${esc(items.map((e) => when(e.t) + ' ' + e.text).join('; '))}">${rows}</button>`;
}
function moveLabels() {
  const s = L.scale;
  const blind = $('#blind');
  if (blind) { blind.style.left = tramX * s - 3 + 'px'; blind.textContent = scrub ? clock(scrub.t) : clock(now()); }
  for (const [id, lv] of leaving) {
    const el = labels.querySelector(`[data-id="${CSS.escape(id)}"]`);
    const k = Math.min(1, (performance.now() - lv.start) / lv.dur);
    if (el) el.style.left = ((lv.from + (L.nowX - 20 - lv.from) * k) - 5) * s + 'px';
    if (k >= 1 && !lv.done) {
      lv.done = true;
      ding();
      setTimeout(() => { leaving.delete(id); rebuild(); }, 50);
    }
  }
}
function ding(word) {
  if (!L) return;
  const d = document.createElement('span');
  d.className = 'ding'; d.textContent = word || 'ding';
  d.style.left = (L.nowX - 12) * L.scale + 'px'; d.style.top = (L.roadY - 34) * L.scale + 'px';
  labels.appendChild(d);
  setTimeout(() => d.remove(), 1200);
}
// A waiting item that was settled walks to the tram and boards it.
function board(attentionId) {
  const id = 'ask-' + attentionId;
  const e = ents.find((x) => x.id === id);
  if (!e || !L || L.posture === 'phone') return;
  const dur = reduceMotion ? 1 : Math.max(900, Math.abs(L.nowX - 20 - e.x) * 14);
  leaving.set(id, { from: e.x, start: performance.now(), dur, ent: e, done: false });
  if (selected === id) selected = null;
  if (!live()) { leaving.delete(id); }
}

/* ================= the board ================= */
let said = '';                 // what the board says of the last tap's outcome
const pending = new Set();     // schedules with a press on its way
function select(id) {
  said = '';
  selected = selected === id && id !== 'tram' ? null : id;
  if (id === 'tram') { ding(); selected = null; if (scrub) endScrub(); }
  renderLabels(); renderBoard();
}
const act = (label, fn, cls = '') => ({ label, fn, cls });
const ask = (widget) => act('Ask AQUA', () => sdk && sdk.ask(widget));
const page = (label, key, cls = '') => act(label, () => sdk && sdk.settings(key), cls);
const PAGE_LABEL = { chat: 'Open the chat', executions: 'Open runs', schedules: 'Open schedules', files: 'Open files' };

function scheduleControl(s) {
  if (s.status === 'active') return { control: 'pause-schedule', label: 'Pause', going: 'Pausing…' };
  if (s.status === 'paused') return { control: 'resume-schedule', label: 'Resume', going: 'Resuming…' };
  return null;
}
function scheduleAct(s) {
  const c = scheduleControl(s);
  if (!c) return null;
  const a = act(pending.has(s.schedule_id) ? c.going : c.label, () => pressSchedule(s), 'go');
  a.disabled = pending.has(s.schedule_id);
  return a;
}
async function pressSchedule(s) {
  const c = scheduleControl(s);
  if (!c || !sdk) return;
  pending.add(s.schedule_id);
  said = '';
  renderBoard();
  let answer;
  try { answer = await sdk.press(c.control, s.schedule_id); } catch (err) { answer = { outcome: 'refused', reason: (err && err.code) || 'refused' }; }
  pending.delete(s.schedule_id);
  if (answer.outcome === 'refused') said = `CYFR did not ${c.label.toLowerCase()} it: ${text(answer.reason) || 'refused'}.`;
  else if (answer.outcome === 'cancelled') said = `Not done: tap ${c.label} again.`;
  else ding(c.label === 'Pause' ? 'paused' : 'resumed');
  renderBoard();
}

function signFor(e) {
  switch (e.kind) {
    case 'ask': {
      const a = e.a, w = waitingWords(a);
      const dest = isItem(a.destination) ? a.destination : {};
      const base = { title: `${w.head} ${w.tail}`, facts: [['since', when(e.t)]], acts: [] };
      if (dest.kind === 'page' && PAGE_LABEL[dest.page]) base.acts.push(page(PAGE_LABEL[dest.page], dest.page, 'go'));
      if (a.kind === 'failed_schedule') {
        const held = D.schedules.get(a.id);
        const control = held && scheduleAct(held.item);
        if (control) base.acts.push(control);
      }
      if (a.kind === 'failed_run') base.facts.push(['reference', text(a.id)]);
      if (a.kind === 'confirmation') base.facts.push(['', 'CYFR asks you in its own dialog']);
      base.acts.push(ask('waiting'));
      return base;
    }
    case 'thread': {
      const th = e.th;
      const people = Array.isArray(th.people) ? th.people : [];
      return {
        title: text(th.title) || 'A thread',
        facts: [['kind', th.kind === 'own' ? 'own, with AQUA' : `shared, ${people.length} people`], ['last', when(e.t)], ...(th.waits_on_you ? [['', 'waits on you']] : [])],
        acts: [page('Open the chat', 'chat', 'go'), ask('houses')],
      };
    }
    case 'lamp': {
      const r = e.runs[e.runs.length - 1];
      const many = e.runs.length > 1;
      const title = e.untold ? `${e.runs.length} earlier ${e.runs.length === 1 ? 'run' : 'runs'}, time not told`
        : many ? `${e.runs.length} runs at ${when(e.runs[0].t)}–${when(r.t)}` : `${componentName(r.ref)} ${r.state} at ${when(r.t)}`;
      return {
        title,
        facts: e.runs.slice(0, 8).map((x) => [x.t == null ? '' : when(x.t), `${componentName(x.ref)} ${x.state}${secs(x.ms) ? ' ' + secs(x.ms) : ''}${x.state === 'failed' && x.cause && x.cause !== 'failed' ? ' · ' + shortReason(x.cause) : ''}`]),
        acts: [page('Open runs', 'executions', 'go'), ask('lamps')],
      };
    }
    case 'stop': {
      const s = e.sched, paused = s.status === 'paused';
      const control = scheduleAct(s);
      return {
        title: text(s.name) || text(s.reference),
        facts: [['cron', text(s.cron_expression)], [paused ? 'paused, last' : 'next', when(e.t)], ['runs', text(s.run_count) || '0'], ['errors', text(s.error_count) || '0']],
        acts: [...(control ? [control] : []), page('Open schedules', 'schedules'), ask('stops')],
      };
    }
    case 'crew': return {
      title: `${text(e.job.member) || 'Crew'} at work`,
      facts: [['for', text(e.job.asked_by)], ['since', when(e.t)], ['status', text(e.job.status)], ['for now', Math.max(0, Math.round(now() - e.t)) + ' min']],
      acts: [ask('crew')],
    };
    case 'days': {
      const items = dayItems(e.id);
      return { title: e.id === 'earlier' ? 'Earlier days' : 'Later days', facts: [], picks: items.map((i) => ({ id: i.id, label: `${when(i.t)} ${i.text}` })), acts: [] };
    }
    case 'castle': return { title: 'CYFR', facts: [['', 'its settings, updates and health']], acts: [page('Open settings', 'settings', 'go'), ask('castle')] };
    case 'vault': return { title: 'Vault', facts: [['', 'your keys and accounts']], acts: [page('Open the vault', 'vault', 'go'), ask('vault')] };
    default: {
      const app = e.app;
      return {
        title: app.name, facts: [['', app.open ? 'open' : 'on the hill']],
        acts: [act(`Open ${app.name}`, () => sdk && sdk.open(app.ref), 'go'), ask('apps')],
      };
    }
  }
}
function defaultSign() {
  const waiting = on('waiting') ? D.attention.size : 0;
  const next = [...D.schedules.values()].map((h) => h.item).filter((s) => s.status === 'active' && mins(s.next_run_at) != null)
    .sort((a, b) => mins(a.next_run_at) - mins(b.next_run_at));
  const job = [...D.activity.values()][0];
  const refused = Object.keys(D.refused);
  return {
    title: waiting ? `${waiting} ${waiting === 1 ? 'thing waits' : 'things wait'} on you` : 'Nothing waits on you',
    facts: [
      ...(next[0] ? [['next stop', `${when(mins(next[0].next_run_at))} ${(text(next[0].name) || text(next[0].reference)).toLowerCase()}`]] : []),
      ...(job && L.posture !== 'phone' ? [['crew', `${text(job.item.member)} is at work`]] : []),
      ...(refused.length ? [['not shown', refused.map((n) => n.split('.')[0]).join(', ')]] : []),
    ],
    acts: [act('Arrange', openPlan)],
  };
}
function scrubSign() {
  const near = ents.filter((e) => e.t != null && !e.hill && e.kind !== 'tram' && Math.abs(e.x - scrub.x) <= 8).sort((a, b) => a.t - b.t);
  return {
    title: `At ${clock(scrub.t)}`,
    facts: near.length ? near.map((e) => [when(e.t), ariaFor(e).split(',')[0]]) : [['', 'nothing stood here']],
    acts: [act('Back to now', endScrub, 'go')],
  };
}
function renderBoard() {
  if (!L) return;
  const e = selected && (selected === 'earlier' || selected === 'later' ? { id: selected, kind: 'days' } : ents.find((x) => x.id === selected));
  const sign = scrub ? scrubSign() : e ? signFor(e) : defaultSign();
  const facts = sign.facts.filter((f) => f[1] !== '' && f[1] != null).map(([k, v]) => `${k ? `<span class="k">${esc(k)}</span> ` : ''}${esc(v)}`).join(' · ');
  const picks = sign.picks ? `<div class="tickets">${sign.picks.map((p) => `<button class="ticket" data-pick="${esc(p.id)}">${esc(p.label)}</button>`).join('')}</div>` : '';
  const list = L.posture === 'phone' && !e && !scrub ? phoneList() : '';
  const acts = sign.acts.map((a, i) => `<button class="btn ${a.cls}" data-act="${i}" ${a.disabled ? 'disabled' : ''}>${esc(a.label)}</button>`).join('');
  const back = e ? '<button class="btn" data-back>Close</button>' : '';
  boardEl.innerHTML = `<div class="say"><h2>${esc(sign.title)}</h2>${facts ? `<p class="facts">${facts}</p>` : ''}${said ? `<p class="said">${esc(said)}</p>` : ''}${picks}${list}</div><div class="acts">${acts}${back}</div>`;
  boardEl.querySelectorAll('[data-act]').forEach((b) => b.addEventListener('click', () => sign.acts[+b.dataset.act].fn()));
  boardEl.querySelectorAll('[data-pick]').forEach((b) => b.addEventListener('click', () => select(b.dataset.pick)));
  const bk = boardEl.querySelector('[data-back]'); if (bk) bk.addEventListener('click', () => select(selected));
}
function phoneList() {
  const asks = ents.filter((e) => e.kind === 'ask' && !leaving.has(e.id)).sort((a, b) => a.t - b.t);
  const rows = asks.map((e) => {
    const w = waitingWords(e.a);
    return `<li><button class="${w.fail ? 'fail' : 'ask'}" data-pick="${esc(e.id)}"><span>${esc(w.head)}<small>${esc(w.tail)}</small></span><span class="when">${when(e.t)}</span></button></li>`;
  }).join('');
  const crew = ents.filter((e) => e.kind === 'crew');
  const houses = ents.filter((e) => e.kind === 'thread').sort((a, b) => b.t - a.t).slice(0, 4);
  const stops = ents.filter((e) => e.kind === 'stop').sort((a, b) => a.t - b.t).slice(0, 3);
  const row = (e, head, sub) => `<li><button data-pick="${esc(e.id)}"><span>${esc(head)}<small>${esc(sub)}</small></span><span class="when">${when(e.t)}</span></button></li>`;
  return `<ul class="list" aria-label="Waiting on you">${rows || '<li class="empty">Nothing waits on you.</li>'}</ul>
  <ul class="list">${crew.map((e) => row(e, `${text(e.job.member)} at work`, text(e.job.status))).join('')}${stops.map((e) => row(e, text(e.sched.name), e.sched.status)).join('')}${houses.map((e) => row(e, text(e.th.title), threadSub(e.th))).join('')}</ul>`;
}

/* ================= scrubbing the day ================= */
let down = null;
stage.addEventListener('pointerdown', (ev) => {
  if (ev.target.closest('.hit, .nightlist, .plaque')) return;
  down = { x: ev.clientX, id: ev.pointerId };
});
stage.addEventListener('pointermove', (ev) => {
  if (!down || ev.pointerId !== down.id || !L) return;
  if (!scrub && Math.abs(ev.clientX - down.x) < 8) return;
  if (!scrub) { stage.setPointerCapture(ev.pointerId); stage.classList.add('scrubbing'); }
  const ax = Math.max(L.vx0 + L.depotW + 2, Math.min(L.vx1 - L.termW - 2, ev.clientX / L.scale));
  scrub = { x: ax, t: invX(ax) };
  renderBoard();
});
const upHandler = (ev) => { if (down && ev.pointerId === down.id) { down = null; if (scrub) endScrub(); } };
stage.addEventListener('pointerup', upHandler);
stage.addEventListener('pointercancel', upHandler);
function endScrub() { scrub = null; stage.classList.remove('scrubbing'); ding(); renderBoard(); }
function tramKeys(ev) {
  if (ev.key === 'ArrowLeft' || ev.key === 'ArrowRight') {
    ev.preventDefault();
    const t0 = scrub ? scrub.t : now();
    const t = Math.max(L.dayStart, Math.min(L.dayEnd, t0 + (ev.key === 'ArrowLeft' ? -15 : 15)));
    scrub = { t, x: X(t) };
    renderBoard();
  } else if (ev.key === 'Escape' && scrub) { endScrub(); }
}

/* ================= arranging the street: the person's tap on Done writes the preferences ================= */
const plan = $('#plan');
let planSaid = '';
let saving = false;
function hillName(key) {
  if (key === 'castle') return 'CYFR castle';
  if (key === 'vault') return 'Vault';
  const app = D.apps.find((a) => appKey(a.ref) === key);
  return app ? app.name : key;
}
function openPlan() {
  if (!draft) draft = { parts: Object.fromEntries(PARTS.map(([k]) => [k, storedOn(k)])), hill: hillKeys() };
  renderPlan();
  rebuild();
}
function renderPlan() {
  const hill = draft.hill;
  plan.innerHTML = `<h2>Arrange the street</h2>
    <div class="grid">${PARTS.map(([k, label]) => `<label><input type="checkbox" data-part="${k}" ${draft.parts[k] !== false ? 'checked' : ''}> ${label}</label>`).join('')}</div>
    <h3>On the hill, left to right</h3>
    <div class="hill">${hill.map((k, i) => `<span><button data-move="${i}" data-d="-1" aria-label="Move ${esc(hillName(k))} left" ${i === 0 ? 'disabled' : ''}>◀</button><b>${esc(hillName(k))}</b><button data-move="${i}" data-d="1" aria-label="Move ${esc(hillName(k))} right" ${i === hill.length - 1 ? 'disabled' : ''}>▶</button></span>`).join('')}</div>
    <p style="margin:10px 0 0;font-size:15px">On the street, time decides where things stand. On the hill, you do.</p>
    <div class="foot"><p class="said" role="status">${esc(planSaid)}</p><button class="btn" data-reset>Reset</button><button class="btn" data-cancel>Cancel</button><button class="btn go" data-done ${saving ? 'disabled' : ''}>${saving ? 'Saving…' : 'Done'}</button></div>`;
  plan.hidden = false;
  plan.querySelectorAll('[data-part]').forEach((c) => c.addEventListener('change', () => { draft.parts[c.dataset.part] = c.checked; skyKey = ''; rebuild(); }));
  plan.querySelectorAll('[data-move]').forEach((b) => b.addEventListener('click', () => {
    const i = +b.dataset.move, j = i + +b.dataset.d;
    [draft.hill[i], draft.hill[j]] = [draft.hill[j], draft.hill[i]];
    renderPlan(); rebuild();
    const again = plan.querySelector(`[data-move="${j}"][data-d="${b.dataset.d}"]`) || plan.querySelector(`[data-move="${j}"]`); if (again) again.focus();
  }));
  plan.querySelector('[data-reset]').addEventListener('click', () => {
    draft = { parts: Object.fromEntries(PARTS.map(([k]) => [k, true])), hill: ['castle', 'vault', ...D.apps.map((a) => appKey(a.ref))] };
    planSaid = ''; skyKey = ''; renderPlan(); rebuild();
  });
  plan.querySelector('[data-cancel]').addEventListener('click', closePlan);
  plan.querySelector('[data-done]').addEventListener('click', savePlan);
}
function closePlan() { draft = null; planSaid = ''; plan.hidden = true; skyKey = ''; rebuild(); }
async function savePlan() {
  if (!sdk || saving) return;
  const document = {
    widgets: Object.fromEntries(PARTS.map(([k]) => [k, { on: draft.parts[k] !== false }])),
    desktop: { hill: hillString(draft.hill) },
  };
  saving = true; planSaid = ''; renderPlan();
  let answer;
  try { answer = await sdk.prefs(document); } catch (err) { answer = { outcome: 'refused', reason: (err && err.code) || 'refused' }; }
  saving = false;
  if (answer.outcome === 'saved') {
    if (isItem(answer.document)) prefsDoc = answer.document;
    closePlan();
    return;
  }
  if (answer.outcome === 'stale') {
    if (isItem(answer.document)) prefsDoc = answer.document;
    planSaid = 'Another of your screens saved first. Tap Done to keep these.';
  } else if (answer.outcome === 'cancelled') planSaid = 'Not saved: tap Done again.';
  else planSaid = `Not saved: ${text(answer.reason) || 'refused'}.`;
  renderPlan();
}

/* ================= the plain page: every list as text, when the drawing cannot run ================= */
function renderFallback() {
  const section = (title, items, empty) => `<section><h2>${esc(title)}</h2>${items.length ? `<ul>${items.map((i) => `<li>${esc(i)}</li>`).join('')}</ul>` : `<p class="empty">${esc(empty)}</p>`}</section>`;
  const at = (iso, word = '') => { const t = mins(iso); return t == null ? '' : `, ${word}${when(t)}`; };
  const waiting = [...D.attention.values()].map(({ item }) => { const w = waitingWords(item); return `${w.head} ${w.tail}${at(item.since)}`; });
  const threads = [...D.threads.values()].map(({ item }) => `${text(item.title) || 'A thread'} (${threadSub(item)})${at(item.last_activity)}`);
  const runs = lampRuns().map((r) => `${componentName(r.ref)} ${r.state}${r.t == null ? '' : ', ' + when(r.t)}${r.state === 'failed' && r.cause && r.cause !== 'failed' ? ' (' + shortReason(r.cause) + ')' : ''}`);
  const schedules = [...D.schedules.values()].map(({ item: s }) => `${text(s.name) || text(s.reference)}, ${s.status}${s.status === 'paused' ? '' : at(s.next_run_at, 'next ')}`);
  const crew = [...D.activity.values()].map(({ item: j }) => `${text(j.member)}, ${text(j.status)}${at(j.since, 'since ')}`);
  const apps = D.apps.map((a) => a.name + (a.open ? ' (open)' : ''));
  const refused = Object.entries(D.refused).map(([n, why]) => `<p class="note">${esc(n)}: ${esc(why)}</p>`).join('');
  $('#fallback h1').textContent = person ? `${person}'s street` : 'Your street';
  $('#fallback-when').textContent = `${plaqueTime()}. The street could not be drawn here, so here it is as lists.`;
  $('#fallback-lists').innerHTML = refused + [
    section('Waiting on you', waiting, 'Nothing waits on you.'), section('Threads', threads, 'No threads.'),
    section('Runs', runs, 'No runs yet.'), section('Schedules', schedules, 'No schedules.'),
    section('Crew at work', crew, 'No crew at work.'), section('Apps', apps, 'No apps installed.'),
  ].join('');
}
function fallBack(err) {
  root.classList.add('plain');
  stopLoop();
  renderFallback();
  if (err) console.error(err);
}

/* ================= the loop: at most 30 frames a second, none while hidden or frozen ================= */
let raf = 0, lastFrame = 0, lastMinute = -1;
const live = () => !document.hidden && shellState !== 'frozen';
function paint(ts) {
  if (!L || root.classList.contains('plain')) return;
  try { frame(ts); } catch (err) { fallBack(err); }
}
function loop(ts) {
  raf = 0;
  if (!live() || root.classList.contains('plain')) return;
  if (ts - lastFrame >= 33) {
    lastFrame = ts;
    if (now() >= DAY) setMidnight();
    const m = Math.floor(now());
    if (m !== lastMinute) {
      lastMinute = m;
      const pt = $('#plaque-time'); if (pt) pt.textContent = plaqueTime();
      skyKey = '';
      rebuild();
    }
    paint(ts);
  }
  raf = requestAnimationFrame(loop);
}
function startLoop() { if (!raf && live()) raf = requestAnimationFrame(loop); }
function stopLoop() { if (raf) cancelAnimationFrame(raf); raf = 0; }
document.addEventListener('visibilitychange', () => (live() ? startLoop() : stopLoop()));
motionQuery.addEventListener('change', (ev) => { reduceMotion = ev.matches; });
let resizeTimer = 0;
addEventListener('resize', () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(relayout, 80); });
function relayout() {
  if (root.classList.contains('plain')) return;
  try { layout(); paint(performance.now()); } catch (err) { fallBack(err); }
}

/* ================= go ================= */
function listen() {
  if (!sdk) return;
  try { applyDesktop(sdk.desktop); } catch (err) { /* the desktop event brings it */ }
  if (typeof sdk.on !== 'function') return;
  sdk.on('desktop', (value) => { applyDesktop(value); skyKey = ''; relayout(); });
  sdk.on('installed', (list) => { applyInstalled(list); changed(); });
  sdk.on('covered', (rects) => { applyCovered(rects); relayout(); });
  sdk.on('posture', (value) => { if (value === 'hand' || value === 'desk') { posture = value; relayout(); } });
  sdk.on('state', (value) => {
    shellState = value === 'frozen' ? 'frozen' : 'live';
    if (live()) startLoop(); else stopLoop();
  });
}
function openStreams() {
  if (!sdk || typeof sdk.stream !== 'function') return;
  for (const spec of STREAMS) follow(spec);
}
let readied = false;
function ready() {
  if (readied || !sdk || typeof sdk.ready !== 'function') return;
  readied = true;
  sdk.ready();
}
function boot() {
  try {
    listen();
    layout();
    paint(performance.now());
    startLoop();
  } catch (err) {
    fallBack(err);
  }
  openStreams();
  ready();
}
const fontsReady = document.fonts && document.fonts.ready ? Promise.race([document.fonts.ready, new Promise((r) => setTimeout(r, 1500))]) : Promise.resolve();
fontsReady.then(boot, boot);
})();

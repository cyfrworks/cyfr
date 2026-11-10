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
// Every stream the manifest declares, all open at once on the desktop's one connection, each held by the
// delivery contract: items by their key, the highest revision heard of each, a picture replaced whole at its
// snapshot. Each belongs to the part that shows it; a part switched off is only not drawn.
const STREAMS = [
  { name: 'attention.changes', part: 'waiting', key: 'id', removal: 'removed', leave: (id) => board(id) },
  { name: 'threads.changes', part: 'houses', key: 'id', removal: 'removed' },
  { name: 'runs.changes', part: 'lamps', key: 'execution_id', cap: 20 },
  { name: 'schedules.changes', part: 'stops', key: 'schedule_id', removal: 'removed' },
  { name: 'activity.changes', part: 'crew', key: 'id', removal: 'ended' },
  { name: 'files.changes', part: 'files', key: 'id', removal: 'removed' },
  { name: 'components.changes', part: 'apps', key: 'ref', removal: 'removed' },
  { name: 'vault.changes', part: 'vault', key: 'name', removal: 'removed' },
  { name: 'system.changes', part: 'castle', key: null },
  { name: 'feed.results', subject: 'weather', part: 'sky', key: 'binding' },
  { name: 'feed.results', subject: 'vpn', part: 'ferry', key: 'binding' },
];
const picture = () => ({ items: new Map(), revs: new Map() });
const H = {};   // stream id -> what it holds and how it stands
for (const spec of STREAMS) {
  spec.id = spec.subject ? 'feed:' + spec.subject : spec.name;
  H[spec.id] = { spec, ...picture(), next: null, state: 'live', at: null, retryAt: null, why: '', opens: 0, tries: 0, timer: 0 };
}
const all = (id) => [...H[id].items.values()];
const one = (id, key) => H[id].items.get(key);
let apps = [];          // the installed apps, as the shell tells them
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

// What one stream's handler hears. A change of an item goes to the picture being gathered, if one is, else to
// what is held; `snapshot` makes the gathered picture the held one; the states are the part's to show.
function hear(h, ev) {
  const { event, data, revision, at } = isItem(ev) ? ev : {};
  if (event === h.spec.name) { if (isItem(data)) take(h, data, revision); }
  else if (event === 'resync') h.next = picture();
  else if (event === 'snapshot') {
    if (h.next) Object.assign(h, h.next, { next: null });
    Object.assign(h, { state: 'live', at: mins(at), retryAt: null, tries: 0 });
  } else if (event === 'stale') Object.assign(h, { state: 'stale' }, mins(at) == null ? {} : { at: mins(at) });
  else if (event === 'unavailable') Object.assign(h, { state: 'unavailable', retryAt: isItem(data) ? mins(data.retry_at) : null });
  else if (event === 'denied') Object.assign(h, picture(), { state: 'denied', next: null });
  else return;
  changed();
}
// One item's change. A revision no higher than the one heard of that item is an older change or the same one
// twice. A removal keeps its revision, so an older change cannot bring the item back; only a live removal
// (none a picture drops) is seen leaving.
function take(h, data, revision) {
  const s = h.spec, into = h.next || h;
  const key = s.key ? data[s.key] : '';
  if (typeof key !== 'string') return;   // a notice, naming no item
  if (Number.isInteger(revision)) {
    const heard = into.revs.get(key);
    if (heard != null && revision <= heard) return;
    into.revs.set(key, revision);
  }
  if (s.removal && data.kind === s.removal) {
    if (into.items.delete(key) && into === h && s.leave) s.leave(key);
    return;
  }
  into.items.delete(key);
  into.items.set(key, data);
  if (s.cap && into.items.size > s.cap) { // the stream keeps the newest runs by their start, and so does the page
    let oldest = null;
    for (const [k, v] of into.items) { const t = mins(v.started_at) ?? -Infinity; if (!oldest || t < oldest[1]) oldest = [k, t]; }
    into.items.delete(oldest[0]);
  }
}

// Pauses before opening a stream again, growing while it repeats.
const RETRY_MS = [2000, 5000, 15000, 60000];
const pause = (h) => RETRY_MS[Math.min(h.tries++, RETRY_MS.length - 1)];
// Opens one declared stream, its first picture gathered apart. The SDK opens an opened stream again by itself;
// the page opens one again only when its first open got no answer, or when the endpoint ended it with no refusal.
function open(h) {
  clearTimeout(h.timer);
  h.timer = 0;
  const n = ++h.opens;
  h.next = picture();
  sdk.stream(h.spec.name, h.spec.subject || null, (ev) => { if (n === h.opens) hear(h, ev); }).then((handle) => {
    if (n !== h.opens) { handle.close(); return; }
    handle.closed.catch(() => {}).then(() => {
      if (n === h.opens && handle.state === 'ended') h.timer = setTimeout(() => open(h), pause(h));
    });
  }, (error) => {
    if (n !== h.opens) return;
    const code = isItem(error) ? error.code : '';
    if (code === 'unavailable') {
      const wait = pause(h);
      Object.assign(h, { state: 'unavailable', retryAt: now() + wait / MINUTE });
      h.timer = setTimeout(() => open(h), wait);
    } else if (h.state !== 'denied') Object.assign(h, { state: 'refused', why: code === 'forbidden' ? 'not granted' : 'could not be read' });
    changed();
  });
}
// How a part's streams stand, the worst of them, in the street's words; none while they are live.
const WORST = ['denied', 'refused', 'unavailable', 'stale'];
function noteOf(part) {
  const h = STREAMS.filter((s) => s.part === part).map((s) => H[s.id]).filter((x) => WORST.includes(x.state))
    .sort((a, b) => WORST.indexOf(a.state) - WORST.indexOf(b.state))[0];
  if (!h) return null;
  const words = h.state === 'denied' ? 'no longer granted' : h.state === 'refused' ? h.why
    : h.state === 'unavailable' ? (h.retryAt == null ? 'trying again soon' : `trying again at ${when(h.retryAt)}`)
      : (h.at == null ? 'an older picture' : `as of ${when(h.at)}`);
  return { state: h.state, words };
}
let notes = {};         // part -> its note, as of the last rebuild

let changeQueued = false;
function changed() {
  if (changeQueued) return;
  changeQueued = true;
  requestAnimationFrame(() => { changeQueued = false; rebuild(); });
}

/* ================= preferences: the parts on the street and the order of the hill ================= */
const PARTS = [
  ['sky', 'Sky and weather'], ['ferry', 'Ferry (VPN)'], ['waiting', 'Waiting on you'], ['houses', 'Thread houses'], ['lamps', 'Run lamps'],
  ['stops', 'Schedule stops'], ['crew', 'Crew at work'], ['files', 'Files'], ['apps', 'Apps on the hill'], ['vault', 'Vault tower'], ['castle', 'CYFR castle'],
];
const HILL_MAX = 256;
let draft = null;   // the arrange sheet's unsaved choice: {parts, hill, units}
function storedEntry(part) {
  const widgets = isItem(prefsDoc.widgets) ? prefsDoc.widgets : {};
  return isItem(widgets[part]) ? widgets[part] : {};
}
const storedOn = (part) => storedEntry(part).on !== false;
const on = (part) => (draft ? draft.parts[part] !== false : storedOn(part));
const storedUnits = () => (storedEntry('sky').units === 'f' ? 'f' : 'c');
const units = () => (draft ? draft.units : storedUnits());
const appKey = (ref) => ref.slice(ref.indexOf(':') + 1);
// The catalysts and formulas installed, as components.changes holds them: the hill's workshops, kept by their ref.
const workshops = () => all('components.changes').filter((c) => (c.type === 'catalyst' || c.type === 'formula') && typeof c.ref === 'string')
  .sort((a, b) => text(a.name).localeCompare(text(b.name)));
const defaultHill = () => ['castle', 'vault', ...apps.map((a) => appKey(a.ref)), ...workshops().map((c) => c.ref)];
function hillKeys() {
  const keys = defaultHill();
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
  apps = Array.isArray(list) ? list.filter((a) => isItem(a) && typeof a.ref === 'string' && typeof a.name === 'string')
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
  // On the desk and carried, the castle's cistern stands beside it.
  if (key === 'castle') return { id: 'castle', part: 'castle', w: phone ? 30 : 48, kind: 'castle', draw(t) { drawCastle(this, t); } };
  if (key === 'vault') return { id: 'vault', part: 'vault', w: 12, kind: 'vault', draw(t) { drawVault(this, t); } };
  const app = apps.find((a) => appKey(a.ref) === key);
  if (app) return { id: 'app:' + app.ref, part: 'apps', w: phone ? 11 : 16, app, comp: one('components.changes', app.ref), kind: 'app', draw(t) { drawAppHouse(this, t); } };
  // The workshops stay off the hand's small hill.
  const c = phone ? null : workshops().find((w) => w.ref === key);
  if (!c) return null;
  const last = lampRuns().filter((r) => r.root && r.t != null && componentRef(r.ref) === c.ref).sort((a, z) => z.t - a.t)[0];
  return { id: 'work:' + c.ref, part: 'apps', w: c.type === 'formula' ? 15 : 22, comp: c, failed: !!last && last.state === 'failed', kind: 'work', draw() { drawWorkshop(this); } };
}
const system = () => one('system.changes', '') || null;
const update = (c) => !!(c && c.update_available === true);
// Scaffolding: an update waits for this app or workshop.
function scaffold(x, y, w, h, base) {
  for (let yy = y - 1; yy < base; yy += 4) R(x - 2, yy, w + 4, 1, '#8a5a2e');
  R(x - 2, y - 2, 1, h + 2, '#8a5a2e'); R(x + w + 1, y - 2, 1, h + 2, '#8a5a2e');
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
  if (update(b.comp)) scaffold(x, y, w, h, b.base);
}
// A catalyst's workshop is a shed with a shutter, a formula's a green kiosk; a red mark when its last run failed.
function drawWorkshop(b) {
  const c = b.comp, x = b.x, base = b.base, w = b.w;
  if (c.type === 'formula') {
    R(x - 1, base - 14, w + 2, 2, '#2c5444'); R(x + 3, base - 16, w - 6, 2, '#2c5444');
    R(x, base - 12, w, 12, '#3f6e58');
    R(x + 2, base - 9, w - 4, 4, '#f3efe4');
    R(x + 3, base - 8, 3, 1, '#7a7a7a'); R(x + 8, base - 8, 3, 1, '#7a7a7a');
  } else {
    R(x - 1, base - 13, w + 2, 2, '#8e3a28');
    R(x, base - 11, w, 11, '#cdbd9e');
    R(x + 4, base - 8, w - 8, 8, '#8d8d8d');
    for (let yy = base - 7; yy < base; yy += 2) R(x + 4, yy, w - 8, 1, '#777');
  }
  if (b.failed) R(x + w - 5, base - 9, 2, 4, '#c23a2e');
  if (update(c)) scaffold(x, base - 12, w, 12, base);
}
// The castle is CYFR: its flag the health, its lantern the model, its guards the crew, its cistern the storage
// against the cap, a notice on the gate an update. Before CYFR tells how it stands, it flies CYFR's colours.
function drawCastle(b, t) {
  const phone = L.posture === 'phone', x = b.x, base = b.base, s = system();
  const stone = '#cbbd9f', dark = '#a8997b';
  const w = phone ? 30 : 40;
  R(x, base - 12, w, 12, stone);
  for (let i = 0; i < w; i += 3) R(x + i, base - 14, 2, 2, stone);
  R(x + 1, base - 22, 8, 22, stone); for (let i = 0; i < 8; i += 3) R(x + 1 + i, base - 24, 2, 2, stone);
  R(x + w - 8, base - 20, 8, 20, stone); for (let i = 0; i < 8; i += 3) R(x + w - 8 + i, base - 22, 2, 2, stone);
  const kx = x + (w >> 1) - 6;
  R(kx, base - 26, 12, 14, stone); for (let i = 0; i < 12; i += 3) R(kx + i, base - 28, 2, 2, stone);
  R(x, base - 3, w, 3, dark);
  R(kx + 4, base - 8, 4, 8, '#3a2c20'); R(kx + 5, base - 9, 2, 1, '#3a2c20');
  for (let i = 0; i < 3; i++) R(kx + 2 + i * 4, base - 22, 1, 3, '#3a2c20');
  R(kx + 6, base - 36, 1, 8, '#333');
  const wave = reduceMotion ? 0 : Math.floor(t / 300) % 2;
  if (!s) { // CYFR's cobalt and white
    R(kx + 7, base - 36, 5, 2, '#1f4593'); R(kx + 7 + wave, base - 34, 5, 1, '#f6f2e8');
    if (!phone) R(x + 4, base - 27, 2, 2, '#ffd76a');
    return;
  }
  const fc = s.health === 'ok' ? '#3d8a4f' : s.health == null ? '#1f4593' : '#c23a2e';
  R(kx + 7, base - 36, 5, 2, fc); R(kx + 7 + wave, base - 34, 5, 1, fc);
  R(x + 4, base - 27, 2, 2, s.model_connected === true ? (Math.floor(t / 500) % 6 === 0 && !reduceMotion ? '#fff3b8' : '#ffd76a') : '#555');
  const total = Math.min(3, Number.isInteger(s.crew_total) ? s.crew_total : 0);
  for (let i = 0; i < total; i++) {
    const gx = x + 12 + i * (phone ? 6 : 8), ready = i < (Number(s.crew_ready) || 0);
    R(gx, base - 17, 2, 3, ready ? '#1f4593' : '#888'); R(gx, base - 19, 2, 2, ready ? '#e2b48a' : '#888');
  }
  if (!phone && storageKnown(s) && capKnown(s)) {
    const cx = x + w + 1, ch = 12, fill = Math.round(ch * Math.min(1, s.storage_used / s.storage_cap));
    R(cx, base - ch - 1, 6, ch + 1, '#8e826b'); R(cx + 1, base - ch, 4, ch - 1, '#e9e3d3');
    R(cx + 1, base - 1 - fill, 4, fill, '#5aa6d6');
  }
  if (s.update_available === true) R(kx + 9, base - 8, 2, 3, '#f4c22e');
}
// The vault tower: one lit slit per entry, red (and blinking) for one that needs re-authorising; it grows a
// storey for every two entries past four. Dark slits before the vault tells its entries.
function drawVault(b, t) {
  const x = b.x, base = b.base, entries = vaultEntries().slice(0, 8);
  const top = towerTop(entries.length);
  R(x, base - top, 12, top, '#b9ad94');
  for (let i = 0; i < 12; i += 3) R(x + i, base - top - 2, 2, 2, '#b9ad94');
  R(x, base - 2, 12, 2, '#9a8e76');
  const slits = entries.length || 4;
  for (let i = 0; i < slits; i++) {
    const cx = x + 2 + (i % 2) * 5, cy = base - top + 4 + Math.floor(i / 2) * 9;
    R(cx, cy, 3, 5, '#2a241c');
    const v = entries[i];
    if (!v) continue;
    const fine = v.status === 'fine';
    R(cx, cy + 1, 3, 3, fine ? '#3d8a4f' : !reduceMotion && Math.floor(t / 450) % 2 ? '#7a1f17' : '#c23a2e');
  }
  R(x + 4, base - 7, 4, 7, '#3a2c20');
}
const vaultEntries = () => all('vault.changes').sort((a, b) => text(a.name).localeCompare(text(b.name)));
const towerTop = (n) => 30 + Math.max(0, Math.ceil(n / 2) - 2) * 9;

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

/* A feed's result is the feed's own shape: read the fields a weather or a vpn feed names. */
function latest(id) { return all(id).filter((f) => isItem(f.result)).sort((a, b) => (mins(b.at) ?? 0) - (mins(a.at) ?? 0))[0] || null; }
function pick(r, keys, test) { for (const k of keys) if (test(r[k])) return r[k]; return null; }
const isNum = Number.isFinite, isStr = (v) => typeof v === 'string' && v !== '';
function weatherNow() {
  const f = latest('feed:weather');
  if (!f) return null;
  const r = f.result;
  return {
    f, temp: pick(r, ['temp_c', 'temperature_c', 'temperature', 'temp'], isNum), place: pick(r, ['place', 'location', 'city', 'name'], isStr) || text(f.label) || 'Weather',
    sky: pick(r, ['sky', 'condition', 'conditions', 'summary', 'description'], isStr) || '', wind: pick(r, ['wind_kmh', 'wind_speed_kmh', 'wind'], isNum),
    next: Array.isArray(r.next_hours) ? r.next_hours.filter(isNum).slice(0, 4) : [], at: mins(f.at),
  };
}
function vpnNow() {
  const f = latest('feed:vpn');
  if (!f) return null;
  const r = f.result, state = String(pick(r, ['state', 'status'], isStr) || '');
  return {
    f, state: state || 'unknown', connected: /^(connected|up|on)$/i.test(state), connecting: /^connecting$/i.test(state),
    server: pick(r, ['server', 'location', 'exit'], isStr) || '', since: mins(r.since),
    servers: Array.isArray(r.servers) ? r.servers.filter(isStr).slice(0, 8) : [], mbps: pick(r, ['down_mbps', 'mbps', 'speed_mbps'], isNum),
  };
}
// A temperature the feed tells in °C, in the person's units.
const deg = (c) => (units() === 'f' ? Math.round(c * 9 / 5 + 32) + '°F' : Math.round(c) + '°');
// The forecast's coming hours step down the evening sky, lower as it cools: where each small sun stands.
function forecast(w) {
  const from = w.temp ?? w.next[0];
  return w.next.map((temp, i) => {
    const t = Math.ceil(now() / 60) * 60 + (i + 1) * 60;
    return { t, temp, x: Math.round(X(t)), y: Math.max(4, Math.min(L.ridge - 8, L.sunY + 2 + Math.round((from - temp) * 5) + i * 2)) };
  });
}

/* the sun stands over now by day, the moon by night; wisps drift over it with the wind */
let wx = null;          // the weather feed's latest result, as of the last rebuild
function drawSun(t) {
  if (!on('sky')) return;
  const w = wx;
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
  const drift = reduceMotion ? 0 : (t / 1000) * 1.2 * (w && w.wind != null ? Math.max(0.3, w.wind / 14) : 1);
  for (let i = 0; i < 3; i++) {
    const cx = ((i * 131 + drift) % (L.aw + 40)) - 20, cy = 8 + i * 9 + (i === 1 ? 4 : 0);
    R(cx, cy, 10 + i * 3, 1, 'rgba(255,255,255,.75)'); R(cx + 3, cy - 1, 5, 1, 'rgba(255,255,255,.6)');
  }
  if (!w || L.posture === 'phone') return;
  forecast(w).forEach(({ x, y }, i) => {
    R(x - 1, y - 1, 3, 3, mix('#ffd94a', '#f08a5a', i / 4)); P(x, y - 3, '#ffd94a'); P(x, y + 3, '#ffd94a'); P(x - 3, y, '#ffd94a'); P(x + 3, y, '#ffd94a');
  });
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
// A recent file stands on the pavement at its change: a picture on an easel, a PDF or a paper.
function drawFile(e) {
  const x = Math.round(e.x), feet = L.paveY + 8, type = text(e.file.type);
  if (type.startsWith('image/')) {
    R(x - 3, feet - 1, 1, 1, '#6b4a2a'); R(x + 3, feet - 1, 1, 1, '#6b4a2a'); R(x - 2, feet - 4, 1, 3, '#6b4a2a'); R(x + 2, feet - 4, 1, 3, '#6b4a2a');
    R(x - 4, feet - 11, 9, 7, '#6b4a2a'); R(x - 3, feet - 10, 7, 5, '#8fd0ee'); R(x - 3, feet - 7, 7, 2, '#7c9650'); P(x + 2, feet - 9, '#ffd94a');
  } else if (type === 'application/pdf') {
    R(x - 3, feet - 5, 7, 5, '#f3efe4'); P(x - 2, feet - 4, '#999'); P(x - 1, feet - 3, '#999'); P(x, feet - 2, '#999'); P(x + 1, feet - 3, '#999'); P(x + 2, feet - 4, '#999');
  } else {
    R(x - 3, feet - 5, 6, 5, '#f3efe4'); R(x - 2, feet - 4, 4, 1, '#999'); R(x - 2, feet - 2, 3, 1, '#999'); R(x + 3, feet - 5, 1, 5, '#d9cba6');
  }
}
// The VPN is the ferry: its wake runs from the pier it left at to now while it is connected.
function drawFerry(e, t) {
  const v = e.vpn, y = L.quayY + 3 + Math.round(L.riverH * 0.45);
  const pierX = Math.round(X(v.since != null ? v.since : now()));
  R(pierX - 4, L.quayY + 3, 8, 2, '#7a5a3a'); R(pierX - 4, L.quayY + 5, 1, 3, '#5a3b2a'); R(pierX + 3, L.quayY + 5, 1, 3, '#5a3b2a');
  const going = v.connected || v.connecting;
  const bob = reduceMotion ? 0 : Math.floor(t / 600) % 2;
  const fx = Math.round(e.x);
  if (going) for (let x = pierX + 4; x < fx - 12; x += 2) if ((x + Math.floor(t / 200)) % 5) P(x, y + 2, '#cfeaf6');
  const yy = y + bob + (going ? 0 : 1);
  R(fx - 12, yy, 24, 3, '#e0702f'); R(fx - 11, yy + 3, 22, 1, '#a84f1e');
  R(fx - 9, yy - 3, 17, 3, '#f3efe4');
  for (let i = 0; i < 4; i++) R(fx - 7 + i * 4, yy - 2, 2, 1, '#2f4256');
  R(fx + 1, yy - 6, 3, 3, '#2b2b2b');
  if (v.connecting && !reduceMotion) { const k = (t / 700) % 1; P(fx + 2 + Math.round(k * 3), yy - 8 - Math.round(k * 5), '#f3efe4'); P(fx + 1, yy - 9 - Math.round(k * 4), '#f3efe4'); }
  if (!going) R(fx - 13, yy + 1, 1, 4, '#5a3b2a');
}
// Each server the feed names is a buoy on the river, the one the ferry is on green.
function drawBuoy(e, t) {
  const x = Math.round(e.x), y = L.quayY + 3 + Math.round(L.riverH * 0.55);
  const bob = reduceMotion ? 0 : Math.floor(t / 650 + e.x) % 2;
  R(x - 2, y + bob, 5, 3, e.current ? '#3d8a4f' : '#c23a2e'); R(x - 2, y + 1 + bob, 5, 1, '#f3efe4');
  R(x, y - 6 + bob, 1, 6, '#2b2b2b');
  R(x + 1, y - 6 + bob, 4, 3, e.current ? '#3d8a4f' : '#f3efe4');
  P(x - 3, y + 3, '#cfeaf6'); P(x + 3, y + 3, '#cfeaf6');
}

/* ================= entities: the streams turned into things on the street ================= */
let ents = [];
let selected = null;
const leaving = new Map();     // attention id -> {from, start, dur, ent, done}

// The runs as lamps want them, each with a state and the time it started.
function lampRuns() {
  return all('runs.changes').map((run) => {
    const error = isItem(run.error) ? run.error : null;
    const t = mins(run.started_at), end = mins(run.ended_at);
    return {
      id: run.execution_id, ref: text(run.reference), t, root: run.parent_execution_id == null,
      state: run.kind === 'completed' ? 'ok' : run.kind === 'failed' ? 'failed' : run.kind === 'cancelled' ? 'cancelled' : 'running',
      ms: typeof run.duration_ms === 'number' ? run.duration_ms : t != null && end != null ? (end - t) * MINUTE : null, cause: error ? text(error.cause) : '',
    };
  });
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
  notes = Object.fromEntries(PARTS.map(([k]) => [k, noteOf(k)]));
  if (root.classList.contains('plain')) { renderFallback(); return; }
  if (!L) return;
  timeScale();
  ents = [];
  placeHill();
  const n = now();
  const phone = L.posture === 'phone';
  const add = (e) => { ents.push(e); return e; };
  if (on('houses')) {
    for (const th of all('threads.changes')) {
      const t = mins(th.last_activity);
      if (t == null) continue;
      add({ id: 'thread-' + th.id, kind: 'thread', part: 'houses', t, th, x: X(t), w: phone ? 16 : 22 });
    }
  }
  if (on('lamps')) { // lamps at each run's start today, grouped when they stand within three pixels
    const timed = lampRuns().filter((r) => r.t != null && r.t >= L.dayStart && r.t <= n + 1).sort((a, b) => a.t - b.t);
    let cur = null;
    for (const r of timed) {
      const x = X(r.t);
      if (cur && Math.abs(x - cur.x) < 4 && cur.runs.length < 3) cur.runs.push(r);
      else cur = add({ id: 'lamp-' + r.id, kind: 'lamp', part: 'lamps', t: r.t, x, runs: [r] });
    }
  }
  if (on('files')) { // the recent files on the pavement, at their change
    for (const file of all('files.changes')) {
      const t = mins(file.changed_at);
      if (file.kind === 'file' && t != null) add({ id: 'file-' + file.id, kind: 'file', part: 'files', t, x: X(t) + 6, file });
    }
  }
  if (on('stops')) { // the next firing; a paused stop stands boarded up at its last firing
    for (const s of all('schedules.changes')) {
      const t = s.status === 'paused' ? mins(s.last_run_at) : mins(s.next_run_at);
      if (t != null) add({ id: 'stop-' + s.schedule_id, kind: 'stop', part: 'stops', t, x: X(t), sched: s });
      // A paused schedule that never ran has no hour: it stands boarded up just past the left arch, to be resumed.
      else if (s.status === 'paused') add({ id: 'stop-' + s.schedule_id, kind: 'stop', part: 'stops', t: null, x: L.vx0 + L.depotW + 16, sched: s, untold: true });
    }
  }
  if (on('waiting')) {
    for (const a of all('attention.changes')) {
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
    for (const job of all('activity.changes')) {
      const t = mins(job.since);
      add({ id: 'crew-' + job.id, kind: 'crew', part: 'crew', t: t == null ? n : t, x: L.nowX + 7 + i * 9, job });
      i++;
    }
  }
  const v = on('ferry') ? vpnNow() : null;
  if (v) { // the ferry at now; the servers as buoys between the left arch and the pier it left at
    add({ id: 'ferry', kind: 'ferry', part: 'ferry', t: n, x: L.nowX - 2, vpn: v });
    if (!phone && v.servers.length) {
      const a = L.vx0 + L.depotW + 8;
      let b = X(v.since != null ? v.since : n) - 10;
      if (b - a < v.servers.length * 14) b = L.nowX - 30;
      v.servers.forEach((sv, i) => add({ id: 'server-' + sv, kind: 'server', part: 'ferry', x: a + (b - a) * (i + 0.5) / v.servers.length, server: sv, current: sv === v.server && (v.connected || v.connecting), vpn: v }));
    }
  }
  wx = on('sky') ? weatherNow() : null;
  if (wx) add({ id: 'sun', kind: 'sun', part: 'sky', t: n, x: L.nowX, weather: wx });
  add({ id: 'tram', kind: 'tram', part: null, t: n, x: L.nowX });
  for (const b of hillBuildings) add({ id: b.id, kind: b.kind, part: b.part, x: b.x + b.w / 2, hill: b, app: b.app, comp: b.comp });
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
  for (const e of ents) if (e.kind === 'file') drawFile(e);
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
  for (const e of ents) if (e.kind === 'server') drawBuoy(e, t);
  for (const e of ents) if (e.kind === 'ferry') drawFerry(e, t);
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
  for (const e of ents) if (e.kind === 'stop' && e.t != null && (e.t < L.dayStart || e.t > L.dayEnd)) {
    const x = Math.round(e.x), base = L.roadY - 1;
    R(x - 3, base - 23, 7, 5, e.sched.status === 'paused' ? '#6d6d6d' : '#f4c22e'); R(x - 2, base - 21, 5, 1, '#1c1d26');
  }
}
const THREAD_WALLS = ['#e3b04b', '#e79b8f', '#93c59a', '#d6dfe8', '#ecd2c6'];
function drawThread(e, t) {
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
  const unread = Math.min(Math.floor((w - 4) / 6), Number.isInteger(th.unread) ? th.unread : 0);
  if (unread > 0) { // laundry: one piece per unread message, moving with the wind
    R(x + 1, top + 14, w - 2, 1, '#d9d4c4');
    for (let i = 0; i < unread; i++) {
      const lx = x + 4 + i * 6, sway = reduceMotion ? 0 : Math.floor(t / 350 + i) % 2;
      R(lx + sway, top + 15, 4, 4, ['#f6f2e8', '#2d5cb8', '#c4553a'][i % 3]); P(lx + sway, top + 19, '#d9d4c4');
    }
  }
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
    case 'file': return box(e.x - 5, L.paveY - 4, 10, 13);
    case 'crew': return box(e.x - 4, L.paveY - 5, 9, 15);
    case 'ferry': return box(e.x - 13, L.quayY + 2, 26, L.riverH - 2);
    case 'server': return box(e.x - 6, L.quayY + 4, 12, L.riverH - 4);
    case 'sun': return box(e.x - 11, L.sunY - 11, 22, 22);
    case 'tram': return box(e.x - 34, L.roadY - 17, 34, 23);
    case 'castle': return box(e.hill.x, e.hill.base - 36, e.hill.w, 36);
    case 'vault': { const top = towerTop(Math.min(8, vaultEntries().length)) + 3; return box(e.hill.x - 1, e.hill.base - top, 14, top); }
    default: return box(e.hill.x - 1, e.hill.base - 22, e.hill.w + 2, 22);
  }
}
const destOf = (a) => (isItem(a.destination) ? a.destination : {});
// The offer a file_offer item waits on, as files.changes holds it, with its sender.
function offerOf(a) {
  const f = one('files.changes', text(destOf(a).ref) || text(a.id));
  return f && f.kind === 'offer' ? f : null;
}
function waitingWords(a) {
  const label = text(a.label);
  switch (a.kind) {
    case 'failed_run': {
      const run = one('runs.changes', text(destOf(a).ref));
      const cause = run && isItem(run.error) ? text(run.error.cause) : '';
      return { head: `${componentName(text(a.id))} failed`, tail: cause && cause !== 'failed' ? shortReason(cause) : 'its last run', fail: true };
    }
    case 'failed_schedule': return { head: `${label || 'A schedule'} failed`, tail: 'its last run', fail: true };
    case 'approval': return { head: 'Approve in', tail: label || 'a thread' };
    case 'confirmation': return { head: 'Confirm in CYFR', tail: label || 'a change' };
    case 'file_offer': { const from = offerOf(a) && text(offerOf(a).from); return { head: from ? `${from} offers` : 'A file offered', tail: label || 'a file' }; }
    default: return { head: 'Waiting', tail: label };
  }
}
function threadSub(th) {
  const people = Array.isArray(th.people) ? th.people.length : 0;
  if (th.waits_on_you) return 'waits on you';
  const many = `${people} ${people === 1 ? 'person' : 'people'}`;
  if (th.unread > 0) return `${th.unread} unread · ${many}`;
  if (th.kind === 'shared') return people === 2 ? 'a pair' : many;
  return 'with AQUA';
}
const HEALTH = { ok: 'healthy', degraded: 'degraded', low_storage: 'low on storage' };
// Bytes as storage is read: "38" (GB).
function gb(n) { const v = n / 1e9; return String(v >= 10 ? Math.round(v) : v >= 1 ? Math.round(v * 10) / 10 : Math.round(v * 100) / 100); }
const storageKnown = (s) => Number.isFinite(s.storage_used) && s.storage_used >= 0;
const capKnown = (s) => Number.isFinite(s.storage_cap) && s.storage_cap > 0;
function vaultWords() {
  const entries = vaultEntries(), bad = entries.filter((v) => v.status !== 'fine').length;
  return entries.length ? (bad ? `${bad} to see` : 'all fine') : '';
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
    case 'crew': return phone ? null : { cls: '', band: 'street', html: `<b>${esc(text(e.job.member) || 'crew')} · since ${when(e.t)}</b><small>${esc(text(e.job.title) || text(e.job.status) || 'working')}</small>` };
    case 'stop': {
      if (phone || (!e.untold && (e.t < L.dayStart || e.t > L.dayEnd))) return null;
      if (e.untold) return { cls: 'quiet', band: 'street', html: `${esc((text(e.sched.name) || 'a stop').split(' ')[0].toLowerCase())} paused` };
      const name = text(e.sched.name) || componentName(text(e.sched.reference));
      return { cls: 'quiet', band: 'street', html: `${when(e.t)} ${esc(name.split(' ')[0].toLowerCase())}` };
    }
    case 'file': return phone || e.t < L.dayStart ? null : { cls: 'quiet', band: 'street', html: esc(text(e.file.name) || 'a file') };
    case 'ferry': {
      const v = e.vpn;
      const state = v.connected ? [v.server, v.mbps != null ? v.mbps + ' Mb/s' : ''].filter(Boolean).join(' · ') : v.connecting ? `to ${v.server}…` : 'not connected';
      if (phone) return { cls: '', band: 'river', align: 'west', html: `<b>VPN</b> ${esc(state)}` };
      const since = v.since == null ? '' : v.connected ? 'since ' + when(v.since) : v.connecting ? 'connecting' : 'off since ' + when(v.since);
      return { cls: '', band: 'river', align: 'side', html: `<b>VPN ${esc(state)}</b>${since ? `<small>${esc(since)}</small>` : ''}` };
    }
    case 'server': return { cls: e.current ? '' : 'quiet', band: 'river', html: `${esc(e.server)}${e.current ? ' · ' + (e.vpn.connecting ? 'going' : 'now') : ''}` };
    case 'sun': {
      const w = e.weather, temp = w.temp != null ? ' ' + deg(w.temp) : '';
      if (phone) return { cls: 'quiet', band: 'sky', align: 'side', html: esc(w.place + temp) };
      const small = [w.wind != null ? `wind ${w.wind} km/h` : '', w.at != null ? `at ${when(w.at)}` : ''].filter(Boolean).join(' · ');
      return { cls: 'sky', band: 'sky', align: 'west', html: `<b>${esc(w.place + temp + (w.sky ? ' ' + w.sky : ''))}</b>${small ? `<small>${small}</small>` : ''}` };
    }
    case 'lamp': return null;
    case 'tram': return null;
    case 'castle': {
      if (phone) return null;
      const s = system(), note = notes.castle;
      if (!s) return { cls: 'quiet', band: 'hill', html: `<b>CYFR</b><small>${esc(note ? note.words : 'settings')}</small>` };
      const store = storageKnown(s) ? (capKnown(s) ? `${gb(s.storage_used)}/${gb(s.storage_cap)} GB` : `${gb(s.storage_used)} GB used`) : '';
      const small = [HEALTH[s.health], store, s.update_available === true ? 'update' : ''].filter(Boolean).join(' · ');
      return { cls: 'quiet', band: 'hill', html: `<b>CYFR${s.version ? ' ' + esc(s.version) : ''}</b>${small ? `<small>${esc(small)}</small>` : ''}` };
    }
    case 'vault': {
      if (phone) return null;
      const small = vaultWords() || (notes.vault ? notes.vault.words : '');
      return { cls: 'quiet', band: 'hill', html: `<b>Vault</b>${small ? `<small>${esc(small)}</small>` : ''}` };
    }
    case 'work': return phone ? null : { cls: 'quiet', band: 'hill', html: `<b>${esc(text(e.comp.name) || componentName(e.comp.ref))}</b>${update(e.comp) ? '<small>update</small>' : ''}` };
    default: {
      if (phone) return null;
      const sub = e.app.open ? 'open' : update(e.comp) ? 'update' : '';
      return { cls: 'quiet', band: 'hill', html: `<b>${esc(e.app.name)}</b>${sub ? `<small>${sub}</small>` : ''}` };
    }
  }
}
function ariaFor(e) {
  switch (e.kind) {
    case 'thread': return `Thread ${text(e.th.title)}, ${e.th.kind}, last active ${when(e.t)}${e.th.unread > 0 ? `, ${e.th.unread} unread` : ''}${e.th.waits_on_you ? ', waits on you' : ''}`;
    case 'ask': { const w = waitingWords(e.a); return `Waiting on you: ${KIND_WORD[e.a.kind] || 'an item'}, ${w.head} ${w.tail}, since ${when(e.t)}`; }
    case 'lamp': return 'Runs at ' + e.runs.map((r) => `${when(r.t)} ${componentName(r.ref)} ${r.state}`).join('; ');
    case 'stop': return `Schedule ${text(e.sched.name)}, ${e.sched.status}${e.untold ? ', never ran' : `, ${e.sched.status === 'paused' ? 'last ' : 'next '}${when(e.t)}`}`;
    case 'file': return `File ${text(e.file.name)}, changed ${when(e.t)}`;
    case 'crew': return `Crew ${text(e.job.member)} ${text(e.job.status)} since ${when(e.t)}${text(e.job.title) ? ': ' + text(e.job.title) : ''}`;
    case 'ferry': return `VPN ${e.vpn.state}${e.vpn.server ? ' to ' + e.vpn.server : ''}`;
    case 'server': return `VPN server ${e.server}${e.current ? ', current' : ''}`;
    case 'sun': return `Weather in ${e.weather.place}${e.weather.temp != null ? ': ' + deg(e.weather.temp) : ''}${e.weather.sky ? ', ' + e.weather.sky : ''}`;
    case 'tram': return `Now, ${clock(now())}. Arrow keys walk the day; Escape returns to now.`;
    case 'castle': { const s = system(); return s ? `CYFR${s.version ? ' ' + s.version : ''}${HEALTH[s.health] ? ', ' + HEALTH[s.health] : ''}` : 'CYFR: open the settings'; }
    case 'vault': return `The vault${vaultWords() ? ', ' + vaultWords() : ''}`;
    case 'work': return `${text(e.comp.type)} ${text(e.comp.name)}${update(e.comp) ? ', update available' : ''}`;
    default: return `App ${e.app.name}${e.app.open ? ', open' : ''}${update(e.comp) ? ', update available' : ''}`;
  }
}

let labelsHtml = '';
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
  const sun = ents.find((e) => e.kind === 'sun');
  if (sun && L.posture !== 'phone') { // the forecast's temperatures beside its small suns
    for (const { x, y, temp } of forecast(sun.weather)) html.push(`<span class="plate quiet${notes.sky && notes.sky.state === 'stale' ? ' dim' : ''}" aria-hidden="true" style="left:${x * s}px;top:${(y - 3) * s}px;transform:translate(8px,-50%);bottom:auto;padding:0 3px">${esc(deg(temp))}</span>`);
  }
  const order = ents.slice().sort((a, b) => (a.hill ? 0 : 1) - (b.hill ? 0 : 1) || a.x - b.x);
  for (const e of order) {
    const b = hitBox(e);
    const lab = labelFor(e);
    // A part whose picture went stale shows it tired until a fresh one comes.
    if (lab && e.part && notes[e.part] && notes[e.part].state === 'stale') lab.cls += ' dim';
    const plate = lab ? `<span class="plate ${lab.cls}${selected === e.id ? ' sel' : ''}" data-band="${lab.band}" data-align="${lab.align || 'center'}">${lab.html}</span>` : '';
    html.push(`<button class="hit" data-id="${esc(e.id)}" aria-label="${esc(ariaFor(e))}" style="left:${b.x}px;top:${b.y}px;width:${Math.max(b.w, 44)}px;height:${Math.max(b.h, 44)}px;margin-left:${b.w < 44 ? (b.w - 44) / 2 : 0}px;margin-top:${b.h < 44 ? (b.h - 44) / 2 : 0}px">${plate}</button>`);
  }
  if (L.posture !== 'phone') { // earlier and later days: one night plate each, a list of things to tap
    html.push(nightPlate('earlier', 'Earlier', dayItems('earlier'), (L.vx0 + 3) * s, (L.paveY - 3) * s, 'left'));
    html.push(nightPlate('later', 'Later', dayItems('later'), (L.vx1 - 3) * s, (L.paveY - 3) * s, 'right'));
  }
  html.push(`<span class="blind" id="blind" style="left:${L.nowX * s}px;top:${(L.roadY - 21) * s - 5}px">${clock(now())}</span>`);
  const next = html.join('');
  if (next === labelsHtml) return;
  labelsHtml = next;
  labels.innerHTML = next;
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
      const align = it.p.dataset.align;
      const hitLeft = it.hit.left - box.left;
      let want = align === 'side' ? hitLeft + it.hit.width + 6 : align === 'west' ? hitLeft - it.w - 4 : it.ax - it.w / 2;
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
      else if (band === 'river' || band === 'sky') { // beside its thing, on the water or in the air
        it.p.style.bottom = 'auto'; it.p.style.top = (band === 'sky' ? 2 : Math.max(2, (it.hit.height - it.p.offsetHeight) / 2)) + 'px';
      }
      else if (band === 'street') { // one baseline for the whole street, just over the heads
        const base = (L.paveY - 7) * L.scale - placed.lane * laneH;
        it.p.style.bottom = 'auto'; it.p.style.top = (base - it.p.offsetHeight - (it.hit.top - box.top)) + 'px';
      } else it.p.style.marginBottom = (2 + placed.lane * laneH) + 'px';
    }
  }
}
function itemText(e) {
  if (e.kind === 'thread') return text(e.th.title) || 'A thread';
  if (e.kind === 'file') return text(e.file.name) || 'a file';
  if (e.kind === 'stop') return (text(e.sched.name) || componentName(text(e.sched.reference))) + (e.sched.status === 'paused' ? ' (paused)' : '');
  if (e.kind === 'ask') { const w = waitingWords(e.a); return `${w.head} ${w.tail}`; }
  return '';
}
function dayItems(id) {
  const kinds = ['thread', 'stop', 'ask', 'file'];
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
let saidOk = false;            // whether that was the outcome asked for
const pending = new Set();     // schedules with a press on its way
const retrying = new Set();    // runs with a Retry on its way
function select(id) {
  said = '';
  if (id.startsWith('server-')) id = 'ferry';   // a buoy is the ferry's: its server is the feed's to choose
  selected = selected === id && id !== 'tram' ? null : id;
  if (id === 'tram') { ding(); selected = null; if (scrub) endScrub(); }
  renderLabels(); renderBoard();
}
const act = (label, fn, cls = '') => ({ label, fn, cls });
const ask = (widget) => act('Ask AQUA', () => sdk && sdk.ask(widget));
// A page by its key, at `ref` when one is given: AQUA's panel at an own thread, the chat at a shared one.
const page = (label, key, cls = '', ref = null) => act(label, () => sdk && (ref == null ? sdk.settings(key) : sdk.settings(key, ref)), cls);
const PAGE_LABEL = { aqua: 'Open AQUA', chat: 'Open the chat', executions: 'Open runs', schedules: 'Open schedules', files: 'Open files' };

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
  said = ''; saidOk = false;
  renderBoard();
  let answer;
  try { answer = await sdk.press(c.control, s.schedule_id); } catch (err) { answer = { outcome: 'refused', reason: (err && err.code) || 'refused' }; }
  pending.delete(s.schedule_id);
  if (answer.outcome === 'refused') said = `CYFR did not ${c.label.toLowerCase()} it: ${text(answer.reason) || 'refused'}.`;
  else if (answer.outcome === 'cancelled') said = answer.reason === 'too_soon' ? `Too soon after your last tap: wait a few seconds, then tap ${c.label} again.` : `Not done: tap ${c.label} again.`;
  else ding(c.label === 'Pause' ? 'paused' : 'resumed');
  renderBoard();
}
// Retry runs a failed run again, as the person, on their tap alone: one press per tap, waiting until it is answered.
const AGAIN_LATER = 'CYFR cannot run it now: try again shortly.';
const RETRY_REFUSED = {
  conflict: 'This run cannot run again: only a run a schedule or a feed started runs again.',
  invalid_argument: 'This run is no longer among the latest runs.',
  not_found: 'This run is gone.',
  forbidden: 'This run is not yours to run again.',
  unavailable: AGAIN_LATER, rate_limited: AGAIN_LATER, timeout: AGAIN_LATER,
  uncertain: 'No answer came: look at Runs before trying again.',
};
function retryAct(id, cls = '') {
  const a = act(retrying.has(id) ? 'Retrying…' : 'Retry', () => pressRetry(id), cls);
  a.disabled = retrying.has(id);
  return a;
}
async function pressRetry(id) {
  if (!sdk || retrying.has(id)) return;
  retrying.add(id);
  said = ''; saidOk = false;
  renderBoard();
  let answer;
  try { answer = await sdk.press('retry-run', id); } catch (err) { answer = { outcome: 'refused', reason: (err && err.code) || 'refused' }; }
  retrying.delete(id);
  if (!isItem(answer)) answer = {};
  if (answer.outcome === 'accepted') { said = 'It runs again.'; saidOk = true; ding('again'); }
  else if (answer.outcome === 'cancelled') said = answer.reason === 'too_soon' ? 'Too soon after your last tap: tap Retry again in a moment.' : 'Nothing ran: tap Retry again.';
  else said = RETRY_REFUSED[answer.reason] || 'It could not be run again.';
  renderBoard();
}
// A failed run that started nothing above it can run again.
const retryable = (r) => r && r.state === 'failed' && r.root;
// A feed's own actions, as its latest result names them; the feed answers with its next result.
function feedActs(f) {
  const actions = Array.isArray(f.actions) ? f.actions.filter((x) => isItem(x) && isStr(x.name)).slice(0, 3) : [];
  return actions.map((x, i) => act(text(x.label) || x.name, () => {
    if (!sdk || !isStr(f.binding)) return;
    sdk.press(f.binding, x.name);
    said = 'Asked: its next result shows here.'; saidOk = true;
    renderBoard();
  }, i === 0 ? 'go' : ''));
}

function signFor(e) {
  switch (e.kind) {
    case 'ask': {
      const a = e.a, w = waitingWords(a), dest = destOf(a);
      const base = { title: `${w.head} ${w.tail}`, facts: [['since', when(e.t)]], acts: [] };
      // Retry, while the failed run is among the runs this street holds.
      const run = a.kind === 'failed_run' && isStr(dest.ref) && one('runs.changes', dest.ref) ? dest.ref : null;
      if (run) base.acts.push(retryAct(run, 'go'));
      if (dest.kind === 'page' && isStr(dest.page)) base.acts.push(page(PAGE_LABEL[dest.page] || 'Open', dest.page, run ? '' : 'go', isStr(dest.ref) ? dest.ref : null));
      if (a.kind === 'failed_schedule') {
        const held = one('schedules.changes', a.id);
        const control = held && scheduleAct(held);
        if (control) base.acts.push(control);
      }
      if (a.kind === 'failed_run') base.facts.push(['reference', text(a.id)]);
      if (a.kind === 'file_offer' && offerOf(a)) base.facts.push(['from', text(offerOf(a).from)]);
      if (a.kind === 'confirmation') base.facts.push(['', 'CYFR asks you in its own dialog']);
      base.acts.push(ask('waiting'));
      return base;
    }
    case 'thread': {
      const th = e.th, own = th.kind === 'own';
      const people = Array.isArray(th.people) ? th.people : [];
      return {
        title: text(th.title) || 'A thread',
        facts: [['kind', own ? 'own, with AQUA' : `shared, ${people.length} ${people.length === 1 ? 'person' : 'people'}`], ['last', when(e.t)], ...(th.unread > 0 ? [['unread', String(th.unread)]] : []), ...(th.waits_on_you ? [['', 'waits on you']] : [])],
        // An own thread is AQUA's, in its panel; a shared one is in the chat.
        acts: [page(own ? 'Open AQUA' : 'Open the chat', own ? 'aqua' : 'chat', 'go', th.id), ask('houses')],
      };
    }
    case 'lamp': {
      const r = e.runs[e.runs.length - 1];
      const again = e.runs.filter(retryable).pop();
      return {
        title: e.runs.length > 1 ? `${e.runs.length} runs at ${when(e.runs[0].t)}–${when(r.t)}` : `${componentName(r.ref)} ${r.state} at ${when(r.t)}`,
        facts: e.runs.slice(0, 8).map((x) => [when(x.t), `${componentName(x.ref)} ${x.state}${secs(x.ms) ? ' ' + secs(x.ms) : ''}${x.state === 'failed' && x.cause && x.cause !== 'failed' ? ' · ' + shortReason(x.cause) : ''}`]),
        acts: [page('Open runs', 'executions', 'go'), ...(again ? [retryAct(again.id)] : []), ask('lamps')],
      };
    }
    case 'stop': {
      const s = e.sched, paused = s.status === 'paused';
      const control = scheduleAct(s);
      return {
        title: text(s.name) || text(s.reference),
        facts: [['cron', text(s.cron_expression)], [paused ? (e.untold ? 'paused' : 'paused, last') : 'next', e.untold ? 'never ran' : when(e.t)], ['runs', text(s.run_count) || '0'], ['errors', text(s.error_count) || '0']],
        acts: [...(control ? [control] : []), page('Open schedules', 'schedules'), ask('stops')],
      };
    }
    case 'file': return {
      title: text(e.file.name) || 'A file', facts: [['type', text(e.file.type)], ['changed', when(e.t)]],
      acts: [page('Open files', 'files', 'go'), ask('files')],
    };
    case 'crew': return {
      title: `${text(e.job.member) || 'Crew'}${text(e.job.title) ? ' · ' + text(e.job.title) : ' at work'}`,
      facts: [['for', text(e.job.asked_by)], ['since', when(e.t)], ['status', text(e.job.status)], ['for now', Math.max(0, Math.round(now() - e.t)) + ' min']],
      acts: [ask('crew')],
    };
    case 'sun': {
      const w = e.weather;
      return {
        title: `${w.place}${w.temp != null ? ' ' + deg(w.temp) : ''}${w.sky ? ', ' + w.sky : ''}`,
        facts: [['wind', w.wind != null ? w.wind + ' km/h' : ''], ['next hours', w.next.map(deg).join(' ')], ['at', w.at != null ? when(w.at) : '']],
        acts: [...feedActs(w.f), ask('sky')],
      };
    }
    case 'ferry': {
      const v = e.vpn;
      return {
        title: v.connected ? `VPN connected${v.server ? ' to ' + v.server : ''}` : v.connecting ? `VPN connecting${v.server ? ' to ' + v.server : ''}…` : `VPN ${v.state === 'unknown' ? 'not connected' : v.state}`,
        facts: [['since', v.since != null ? when(v.since) : ''], ['down', v.connected && v.mbps != null ? v.mbps + ' Mb/s' : '']],
        acts: [...feedActs(v.f), ask('ferry')],
      };
    }
    case 'days': {
      const items = dayItems(e.id);
      return { title: e.id === 'earlier' ? 'Earlier days' : 'Later days', facts: [], picks: items.map((i) => ({ id: i.id, label: `${when(i.t)} ${i.text}` })), acts: [] };
    }
    case 'castle': {
      const s = system();
      const acts = [page('Open settings', 'settings', 'go'), ask('castle')];
      if (!s) return { title: 'CYFR', facts: [['', 'its settings, updates and health']], acts };
      const crew = Number.isInteger(s.crew_total) ? `${Number(s.crew_ready) || 0} of ${s.crew_total} ready` : '';
      return {
        title: `CYFR${s.version ? ' ' + s.version : ''}${HEALTH[s.health] ? ' · ' + HEALTH[s.health] : ''}`,
        facts: [['storage', storageKnown(s) ? (capKnown(s) ? `${gb(s.storage_used)} GB of ${gb(s.storage_cap)} GB` : `${gb(s.storage_used)} GB used`) : ''],
          ['model', s.model_connected == null ? '' : s.model_connected ? 'connected' : 'none'], ['crew', crew], ...(s.update_available === true ? [['', 'update available']] : [])],
        acts,
      };
    }
    case 'vault': {
      const entries = vaultEntries();
      return {
        title: 'Vault', facts: entries.length ? entries.slice(0, 8).map((v) => [text(v.name), v.status === 'fine' ? 'fine' : 'needs re-authorising']) : [['', 'your keys and accounts']],
        acts: [page('Open the vault', 'vault', 'go'), ask('vault')],
      };
    }
    case 'work': {
      const c = e.comp;
      return {
        title: text(c.name) || componentName(c.ref), facts: [['type', text(c.type)], ['version', text(c.version)], ...(update(c) ? [['', 'update available']] : [])],
        acts: [...(update(c) ? [page('Open updates', 'components', 'go')] : []), ask('apps')],
      };
    }
    default: {
      const app = e.app, c = e.comp;
      return {
        title: app.name, facts: [['', app.open ? 'open' : 'on the hill'], ['version', c ? text(c.version) : ''], ...(update(c) ? [['', 'update available']] : [])],
        acts: [act(`Open ${app.name}`, () => sdk && sdk.open(app.ref), 'go'), ...(update(c) ? [page('Open updates', 'components')] : []), ask('apps')],
      };
    }
  }
}
function defaultSign() {
  const waiting = on('waiting') ? H['attention.changes'].items.size : 0;
  const next = all('schedules.changes').filter((s) => s.status === 'active' && mins(s.next_run_at) != null)
    .sort((a, b) => mins(a.next_run_at) - mins(b.next_run_at));
  const job = all('activity.changes')[0];
  return {
    title: waiting ? `${waiting} ${waiting === 1 ? 'thing waits' : 'things wait'} on you` : 'Nothing waits on you',
    facts: [
      ...(next[0] ? [['next stop', `${when(mins(next[0].next_run_at))} ${(text(next[0].name) || text(next[0].reference)).toLowerCase()}`]] : []),
      ...(job && L.posture !== 'phone' ? [['crew', text(job.title) ? `${text(job.member)} is on “${text(job.title)}”` : `${text(job.member)} is at work`]] : []),
      // Each part that cannot show a live picture says how it stands.
      ...PARTS.filter(([k]) => on(k) && notes[k]).map(([k, label]) => [label.toLowerCase(), notes[k].words]),
    ],
    acts: [act('Arrange', openPlan)],
  };
}
function scrubSign() {
  const near = ents.filter((e) => e.t != null && !e.hill && !['tram', 'sun', 'ferry'].includes(e.kind) && Math.abs(e.x - scrub.x) <= 8).sort((a, b) => a.t - b.t);
  return {
    title: `At ${clock(scrub.t)}`,
    facts: near.length ? near.map((e) => [when(e.t), ariaFor(e).split(',')[0]]) : [['', 'nothing stood here']],
    acts: [act('Back to now', endScrub, 'go')],
  };
}
let boardHtml = '';
let boardActs = [];
function renderBoard() {
  if (!L) return;
  const e = selected && (selected === 'earlier' || selected === 'later' ? { id: selected, kind: 'days' } : ents.find((x) => x.id === selected));
  const sign = scrub ? scrubSign() : e ? signFor(e) : defaultSign();
  if (!scrub && e && e.part && notes[e.part]) sign.facts.push(['', notes[e.part].words]);
  const facts = sign.facts.filter((f) => f[1] !== '' && f[1] != null).map(([k, v]) => `${k ? `<span class="k">${esc(k)}</span> ` : ''}${esc(v)}`).join(' · ');
  const picks = sign.picks ? `<div class="tickets">${sign.picks.map((p) => `<button class="ticket" data-pick="${esc(p.id)}">${esc(p.label)}</button>`).join('')}</div>` : '';
  const list = L.posture === 'phone' && !e && !scrub ? phoneList() : '';
  const acts = sign.acts.map((a, i) => `<button class="btn ${a.cls}" data-act="${i}" ${a.disabled ? 'disabled' : ''}>${esc(a.label)}</button>`).join('');
  const back = e ? '<button class="btn" data-back>Close</button>' : '';
  const html = `<div class="say"><h2>${esc(sign.title)}</h2>${facts ? `<p class="facts">${facts}</p>` : ''}${said ? `<p class="said${saidOk ? ' ok' : ''}">${esc(said)}</p>` : ''}${picks}${list}</div><div class="acts">${acts}${back}</div>`;
  boardActs = sign.acts;
  // The same board is not written again: a tap landing while a stream's event redraws would be lost.
  if (html === boardHtml) return;
  boardHtml = html;
  boardEl.innerHTML = html;
  boardEl.querySelectorAll('[data-act]').forEach((b) => b.addEventListener('click', () => boardActs[+b.dataset.act].fn()));
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
  const stops = ents.filter((e) => e.kind === 'stop').sort((a, b) => (a.t ?? -Infinity) - (b.t ?? -Infinity)).slice(0, 3);
  const row = (e, head, sub) => `<li><button data-pick="${esc(e.id)}"><span>${esc(head)}<small>${esc(sub)}</small></span><span class="when">${e.t == null ? '' : when(e.t)}</span></button></li>`;
  const card = (id, head, sub) => `<ul class="list" style="margin:0"><li><button data-pick="${id}"><span>${esc(head)}<small>${esc(sub) || '&nbsp;'}</small></span></button></li></ul>`;
  const sun = ents.find((e) => e.kind === 'sun'), ferry = ents.find((e) => e.kind === 'ferry');
  const cards = [
    sun ? card('sun', `${sun.weather.place}${sun.weather.temp != null ? ' ' + deg(sun.weather.temp) : ''}`, [sun.weather.sky, sun.weather.wind != null ? 'wind ' + sun.weather.wind : ''].filter(Boolean).join(' · ')) : '',
    ferry ? card('ferry', `VPN ${ferry.vpn.connected ? ferry.vpn.server : ferry.vpn.state}`, ferry.vpn.connected && ferry.vpn.mbps != null ? ferry.vpn.mbps + ' Mb/s' : '') : '',
  ].join('');
  return `<ul class="list" aria-label="Waiting on you">${rows || '<li class="empty">Nothing waits on you.</li>'}</ul>
  ${cards ? `<div class="row2" style="margin-top:6px">${cards}</div>` : ''}
  <ul class="list">${crew.map((e) => row(e, text(e.job.title) ? `${text(e.job.member)}: ${text(e.job.title)}` : `${text(e.job.member)} at work`, text(e.job.title) ? 'since ' + when(e.t) : text(e.job.status))).join('')}${stops.map((e) => row(e, text(e.sched.name), e.sched.status)).join('')}${houses.map((e) => row(e, text(e.th.title), threadSub(e.th))).join('')}</ul>`;
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
  const app = apps.find((a) => appKey(a.ref) === key) || workshops().find((c) => c.ref === key);
  return app ? text(app.name) || key : key;
}
function openPlan() {
  if (!draft) draft = { parts: Object.fromEntries(PARTS.map(([k]) => [k, storedOn(k)])), hill: hillKeys(), units: storedUnits() };
  renderPlan();
  rebuild();
}
function renderPlan() {
  const hill = draft.hill;
  plan.innerHTML = `<h2>Arrange the street</h2>
    <div class="grid">${PARTS.map(([k, label]) => `<label><input type="checkbox" data-part="${k}" ${draft.parts[k] !== false ? 'checked' : ''}> ${label}</label>`).join('')}</div>
    <h3>On the hill, left to right</h3>
    <div class="hill">${hill.map((k, i) => `<span><button data-move="${i}" data-d="-1" aria-label="Move ${esc(hillName(k))} left" ${i === 0 ? 'disabled' : ''}>◀</button><b>${esc(hillName(k))}</b><button data-move="${i}" data-d="1" aria-label="Move ${esc(hillName(k))} right" ${i === hill.length - 1 ? 'disabled' : ''}>▶</button></span>`).join('')}</div>
    <h3>Temperatures</h3>
    <div class="units">${[['c', '°C'], ['f', '°F']].map(([u, label]) => `<button class="btn${draft.units === u ? ' go' : ''}" data-units="${u}" aria-pressed="${draft.units === u}">${label}</button>`).join('')}</div>
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
  plan.querySelectorAll('[data-units]').forEach((b) => b.addEventListener('click', () => { draft.units = b.dataset.units; renderPlan(); rebuild(); }));
  plan.querySelector('[data-reset]').addEventListener('click', () => {
    draft = { parts: Object.fromEntries(PARTS.map(([k]) => [k, true])), hill: defaultHill(), units: 'c' };
    planSaid = ''; skyKey = ''; renderPlan(); rebuild();
  });
  plan.querySelector('[data-cancel]').addEventListener('click', closePlan);
  plan.querySelector('[data-done]').addEventListener('click', savePlan);
}
function closePlan() { draft = null; planSaid = ''; plan.hidden = true; skyKey = ''; rebuild(); }
async function savePlan() {
  if (!sdk || saving) return;
  const document = {
    widgets: Object.fromEntries(PARTS.map(([k]) => [k, k === 'sky' ? { on: draft.parts[k] !== false, units: draft.units } : { on: draft.parts[k] !== false }])),
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
  } else if (answer.outcome === 'cancelled') planSaid = answer.reason === 'too_soon' ? 'Too soon after your last tap: wait a few seconds, then tap Done again.' : 'Not saved: tap Done again.';
  else planSaid = `Not saved: ${text(answer.reason) || 'refused'}.`;
  renderPlan();
}

/* ================= the plain page: every list as text, when the drawing cannot run ================= */
function renderFallback() {
  const section = (title, part, items, empty) => `<section><h2>${esc(title)}</h2>${notes[part] ? `<p class="note">${esc(notes[part].words)}</p>` : ''}${items.length ? `<ul>${items.map((i) => `<li>${esc(i)}</li>`).join('')}</ul>` : `<p class="empty">${esc(empty)}</p>`}</section>`;
  const at = (iso, word = '') => { const t = mins(iso); return t == null ? '' : `, ${word}${when(t)}`; };
  const waiting = all('attention.changes').map((item) => { const w = waitingWords(item); return `${w.head} ${w.tail}${at(item.since)}`; });
  const threads = all('threads.changes').map((item) => `${text(item.title) || 'A thread'} (${threadSub(item)})${at(item.last_activity)}`);
  const runs = lampRuns().map((r) => `${componentName(r.ref)} ${r.state}${r.t == null ? '' : ', ' + when(r.t)}${r.state === 'failed' && r.cause && r.cause !== 'failed' ? ' (' + shortReason(r.cause) + ')' : ''}`);
  const schedules = all('schedules.changes').map((s) => `${text(s.name) || text(s.reference)}, ${s.status}${s.status === 'paused' ? '' : at(s.next_run_at, 'next ')}`);
  const crew = all('activity.changes').map((j) => `${text(j.member)}, ${text(j.title) || text(j.status)}${at(j.since, 'since ')}`);
  const files = all('files.changes').map((f) => (f.kind === 'offer' ? `${text(f.from) || 'Someone'} offers ${text(f.name)}` : `${text(f.name)}${at(f.changed_at, 'changed ')}`));
  const w = weatherNow(), v = vpnNow(), s = system();
  const weather = w ? [`${w.place}${w.temp != null ? ' ' + deg(w.temp) : ''}${w.sky ? ', ' + w.sky : ''}`, ...(w.next.length ? ['next hours ' + w.next.map(deg).join(' ')] : [])] : [];
  const vpn = v ? [`${v.state}${v.server ? ' to ' + v.server : ''}${v.connected && v.mbps != null ? ', ' + v.mbps + ' Mb/s' : ''}`] : [];
  const hill = [...apps.map((a) => a.name + (a.open ? ' (open)' : '') + (update(one('components.changes', a.ref)) ? ', update available' : '')),
    ...workshops().map((c) => `${text(c.name)} (${text(c.type)})${update(c) ? ', update available' : ''}`)];
  const vault = vaultEntries().map((e) => `${text(e.name)}: ${e.status === 'fine' ? 'fine' : 'needs re-authorising'}`);
  const cyfr = s ? [`CYFR${s.version ? ' ' + s.version : ''}${HEALTH[s.health] ? ', ' + HEALTH[s.health] : ''}`,
    ...(storageKnown(s) ? [capKnown(s) ? `${gb(s.storage_used)} GB of ${gb(s.storage_cap)} GB` : `${gb(s.storage_used)} GB used`] : []), ...(s.update_available === true ? ['update available'] : [])] : [];
  $('#fallback h1').textContent = person ? `${person}'s street` : 'Your street';
  $('#fallback-when').textContent = `${plaqueTime()}. The street could not be drawn here, so here it is as lists.`;
  $('#fallback-lists').innerHTML = [
    section('Waiting on you', 'waiting', waiting, 'Nothing waits on you.'), section('Threads', 'houses', threads, 'No threads.'),
    section('Runs', 'lamps', runs, 'No runs yet.'), section('Schedules', 'stops', schedules, 'No schedules.'),
    section('Crew at work', 'crew', crew, 'No crew at work.'), section('Files', 'files', files, 'No recent files.'),
    section('Weather', 'sky', weather, 'No weather feed is bound.'), section('VPN', 'ferry', vpn, 'No VPN feed is bound.'),
    section('Apps', 'apps', hill, 'No apps installed.'), section('Vault', 'vault', vault, 'Nothing in the vault.'),
    section('CYFR', 'castle', cyfr, 'Not told yet.'),
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
  // Every declared stream, once each, together, whatever part is on.
  if (sdk && typeof sdk.stream === 'function') for (const h of Object.values(H)) open(h);
  ready();
}
const fontsReady = document.fonts && document.fonts.ready ? Promise.race([document.fonts.ready, new Promise((r) => setTimeout(r, 1500))]) : Promise.resolve();
fontsReady.then(boot, boot);
})();
